import Foundation
import MaiCore
import XCTest

@testable import PocketMai

final class ConversationPagingTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func conversation(count: Int) -> Conversation {
    var result = Conversation()
    result.title = "Paged chat"
    result.createdAt = Date(timeIntervalSince1970: 1000)
    result.updatedAt = Date(timeIntervalSince1970: 2000)
    result.messages = (0..<count).map {
      ChatMessage(role: .user, text: "message \($0)", createdAt: result.createdAt)
    }
    return result
  }

  func testPicturesStayOnDiskUntilRequestedAndPortableExportKeepsTheirBytes() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ChatFileStore<Conversation>(
      directoryURL: root, coding: PersistenceStore.conversationCoding)
    var chat = conversation(count: 65)
    // Base64 is four bytes over the 64 KiB inline threshold.
    let bytes = Data(repeating: 42, count: 48 * 1024 + 1)
    chat.messages[64].attachments = [
      .image(filename: "image.jpg", data: bytes, width: 100, height: 100)
    ]
    try files.save(chat)
    let page = try XCTUnwrap(try files.loadChatPage(id: chat.id))
    let attachment = try XCTUnwrap(page.messages.last?.attachments.first)
    XCTAssertNil(attachment.dataBase64)
    XCTAssertNotNil(attachment.storageDataURL)
    let loaded = await AttachmentImageLoader.shared.data(for: attachment)
    XCTAssertEqual(loaded, bytes)
    let portable = root.appendingPathComponent("export.json")
    try files.exportChat(id: chat.id, to: portable)
    let exported = try PersistenceStore.conversationCoding.makeDecoder().decode(
      Conversation.self, from: Data(contentsOf: portable))
    XCTAssertEqual(exported, chat)
    var withoutLength = attachment
    withoutLength.storedDataLength = nil
    let loadedWithoutLength = await AttachmentImageLoader.shared.data(for: withoutLength)
    XCTAssertEqual(loadedWithoutLength, bytes)
    // A warm image remains available without reopening its on-disk blob (for
    // example, while cloud storage temporarily makes the file unavailable).
    try FileManager.default.removeItem(at: XCTUnwrap(attachment.storageDataURL))
    let cached = await AttachmentImageLoader.shared.data(for: attachment)
    XCTAssertEqual(cached, bytes)
  }

  @MainActor
  func testPreviewReadsCompleteHistoryWithoutChangingTheActiveChat() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = PersistenceStore(localBaseURL: root)
    let chat = conversation(count: 65)
    let activeChat = conversation(count: 1)
    let saved = expectation(description: "initial save")
    persistence.saveConversations([chat, activeChat]) { saved.fulfill() }
    await fulfillment(of: [saved], timeout: 5)
    let store = AppStore(persistence: persistence)
    let deadline = Date().addingTimeInterval(5)
    while !store.conversationSummaries.contains(where: { $0.id == chat.id }), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.selectConversation(id: activeChat.id)
    let preview = try await store.conversationPreview(id: chat.id)
    XCTAssertEqual(preview.messages, chat.messages)
    XCTAssertNil(preview.historyWindow)
    XCTAssertEqual(store.selectedConversationID, activeChat.id)
    XCTAssertEqual(store.currentConversation?.messages, activeChat.messages)
    XCTAssertNil(store.conversation(withID: chat.id))

    await store.selectConversation(id: chat.id)
    let window = try XCTUnwrap(store.currentConversation?.historyWindow)
    let pagedPreview = try await store.conversationPreview(id: chat.id)
    XCTAssertEqual(pagedPreview.messages, chat.messages)
    XCTAssertNil(pagedPreview.historyWindow)
    XCTAssertEqual(store.selectedConversationID, chat.id)
    XCTAssertEqual(store.currentConversation?.historyWindow, window)

    await store.preloadConversation(id: chat.id)
    let loadedPreview = try await store.conversationPreview(id: chat.id)
    XCTAssertEqual(loadedPreview.messages, store.currentConversation?.messages)
  }

  @MainActor
  func testBrowsingKeepsABoundedWindowAndEditingHydratesBeforeSaving() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = PersistenceStore(localBaseURL: root)
    var chat = conversation(count: 129)
    chat.messages[0].role = .system
    chat.messages[2].role = .tool
    let saved = expectation(description: "initial save")
    persistence.saveConversations([chat]) { saved.fulfill() }
    await fulfillment(of: [saved], timeout: 5)
    let store = AppStore(persistence: persistence)
    let deadline = Date().addingTimeInterval(5)
    while !store.conversationSummaries.contains(where: { $0.id == chat.id }), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.selectConversation(id: chat.id)
    XCTAssertEqual(store.currentConversation?.messages.count, 64)
    XCTAssertEqual(store.currentConversation?.historyWindow?.range, 65..<129)
    let opening = try await store.conversationOpeningMessages(id: chat.id)
    XCTAssertEqual(opening.map(\.text), ["message 1", "message 3", "message 4"])
    XCTAssertEqual(store.selectedConversationID, chat.id)
    XCTAssertEqual(store.currentConversation?.historyWindow?.range, 65..<129)
    await store.pageConversationHistory(earlier: true)
    XCTAssertEqual(store.currentConversation?.messages.count, 64)
    XCTAssertEqual(store.currentConversation?.historyWindow?.range, 33..<97)
    let removed = try XCTUnwrap(store.currentConversation?.messages.first)
    store.deleteMessage(removed)
    let writeDeadline = Date().addingTimeInterval(5)
    var persisted: Conversation?
    repeat {
      try await Task.sleep(for: .milliseconds(50))
      persisted = persistence.loadConversation(id: chat.id)
    } while persisted?.messages.count != 128 && Date() < writeDeadline
    XCTAssertEqual(persisted?.messages.count, 128)
    XCTAssertFalse(persisted?.messages.contains(where: { $0.id == removed.id }) ?? true)
    XCTAssertEqual(persisted?.messages.first?.id, chat.messages.first?.id)
    XCTAssertEqual(persisted?.messages.last?.id, chat.messages.last?.id)
    let loadedOpening = try await store.conversationOpeningMessages(id: chat.id)
    XCTAssertEqual(loadedOpening.map(\.id), opening.map(\.id))
  }
}
