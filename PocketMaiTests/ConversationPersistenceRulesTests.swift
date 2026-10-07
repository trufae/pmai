import Foundation
import MaiCore
import XCTest

@testable import PocketMai

/// The placeholder rule shared with pmai, applied to the app's own files:
/// nothing that already exists on disk is ever dropped, and nothing empty is
/// added unless the app asks for it.
final class ConversationPersistenceRulesTests: XCTestCase {
  private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Conversation writes are debounced on a background queue.
  private func waitForWrites(_ write: (XCTestExpectation) -> Void) {
    let done = expectation(description: "debounced write")
    write(done)
    wait(for: [done], timeout: 5)
  }

  private func conversationFileURL(in baseURL: URL, id: UUID) -> URL {
    baseURL.appendingPathComponent("conversations/\(id.uuidString).json")
  }

  private func fileExists(in baseURL: URL, id: UUID) -> Bool {
    FileManager.default.fileExists(atPath: conversationFileURL(in: baseURL, id: id).path)
  }

  private func makeConversation(messages: [ChatMessage] = []) -> Conversation {
    var conversation = Conversation()
    conversation.createdAt = epoch
    conversation.updatedAt = epoch
    conversation.messages = messages
    return conversation
  }

  private func indexedIDs(in baseURL: URL) throws -> [String] {
    let data = try Data(contentsOf: baseURL.appendingPathComponent("conversations/index.json"))
    let index = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(index["ids"] as? [String])
  }

  func testConversationsFollowTheSharedPlaceholderRule() {
    let placeholder = makeConversation()
    XCTAssertTrue(placeholder.isDisposable)
    XCTAssertEqual(placeholder.title, AgentChat.placeholderTitle)

    var pinned = placeholder
    pinned.isPinned = true
    XCTAssertFalse(pinned.isDisposable)

    var named = placeholder
    named.title = "Kept on purpose"
    XCTAssertFalse(named.isDisposable)

    var used = placeholder
    used.messages = [ChatMessage(role: .user, text: "  Fix the\n  linker  ")]
    used.refreshTitle(from: used.messages[0].text)
    XCTAssertFalse(used.isDisposable)
    XCTAssertEqual(used.title, "Fix the linker")
    used.refreshTitle(from: "second message")
    XCTAssertEqual(used.title, "Fix the linker", "titles are derived once")
  }

  func testEmptyPlaceholdersAreNotWrittenUnlessRetained() throws {
    let baseURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseURL) }

    let used = makeConversation(messages: [ChatMessage(role: .user, text: "hello")])
    let placeholder = makeConversation()
    let drafted = makeConversation()
    XCTAssertTrue(placeholder.isDisposable)
    XCTAssertTrue(drafted.isDisposable)

    let store = PersistenceStore(localBaseURL: baseURL)
    waitForWrites { done in
      store.saveConversations([used, placeholder, drafted], retaining: [drafted.id]) { done.fulfill() }
    }

    XCTAssertTrue(fileExists(in: baseURL, id: used.id))
    XCTAssertFalse(fileExists(in: baseURL, id: placeholder.id), "an untouched chat earns no file")
    XCTAssertTrue(fileExists(in: baseURL, id: drafted.id), "a chat holding a draft is kept")
    XCTAssertEqual(Set(try indexedIDs(in: baseURL)), [used.id.uuidString, drafted.id.uuidString])

    let reloaded = PersistenceStore(localBaseURL: baseURL)
    XCTAssertEqual(Set(reloaded.loadConversationSummaries().map(\.id)), [used.id, drafted.id])
    XCTAssertEqual(Set(reloaded.loadConversations().map(\.id)), [used.id, drafted.id])
  }

  // Earlier versions wrote every conversation, placeholders included. Those
  // files must keep loading, stay indexed, and survive save cycles unchanged.
  func testPlaceholderFilesFromEarlierVersionsAreNeverDropped() throws {
    let baseURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let conversationsURL = baseURL.appendingPathComponent("conversations", isDirectory: true)
    try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)

    let legacyPlaceholder = makeConversation()
    XCTAssertTrue(legacyPlaceholder.isDisposable)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let original = try encoder.encode(legacyPlaceholder)
    let fileURL = conversationFileURL(in: baseURL, id: legacyPlaceholder.id)
    try original.write(to: fileURL, options: .atomic)

    let store = PersistenceStore(localBaseURL: baseURL)
    let loaded = store.loadConversations()
    XCTAssertEqual(loaded, [legacyPlaceholder])
    XCTAssertEqual(try indexedIDs(in: baseURL), [legacyPlaceholder.id.uuidString])
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    waitForWrites { done in store.saveConversations(loaded) { done.fulfill() } }
    waitForWrites { done in
      store.saveLoadedConversations(loaded, summaries: loaded.map(ConversationSummary.init)) { done.fulfill() }
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertEqual(try indexedIDs(in: baseURL), [legacyPlaceholder.id.uuidString])
    XCTAssertEqual(PersistenceStore(localBaseURL: baseURL).loadConversations(), [legacyPlaceholder])
    XCTAssertEqual(
      PersistenceStore(localBaseURL: baseURL).loadConversationSummaries().map(\.id),
      [legacyPlaceholder.id])
  }

  func testDeletingConversationFilesRemovesOnlyTheNamedOnes() throws {
    let baseURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseURL) }

    let first = makeConversation(messages: [ChatMessage(role: .user, text: "first")])
    let second = makeConversation(messages: [ChatMessage(role: .user, text: "second")])
    let store = PersistenceStore(localBaseURL: baseURL)
    waitForWrites { done in store.saveConversations([first, second]) { done.fulfill() } }
    XCTAssertTrue(fileExists(in: baseURL, id: first.id))
    XCTAssertTrue(fileExists(in: baseURL, id: second.id))

    waitForWrites { done in store.deleteConversationFiles(ids: [first.id]) { done.fulfill() } }
    XCTAssertFalse(fileExists(in: baseURL, id: first.id))
    XCTAssertTrue(fileExists(in: baseURL, id: second.id))
    XCTAssertEqual(
      PersistenceStore(localBaseURL: baseURL).loadConversations().map(\.id), [second.id])
  }

  func testCorruptedFilesAreQuarantinedAndRecoverable() throws {
    let baseURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let conversationsURL = baseURL.appendingPathComponent("conversations", isDirectory: true)
    try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)

    let good = makeConversation(messages: [ChatMessage(role: .user, text: "good")])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let goodData = try encoder.encode(good)
    try goodData.write(to: conversationFileURL(in: baseURL, id: good.id), options: .atomic)
    let badID = UUID()
    let badData = Data(#"{"validJSON":true,"but":"not a conversation"}"#.utf8)
    try badData.write(to: conversationFileURL(in: baseURL, id: badID), options: .atomic)

    let store = PersistenceStore(localBaseURL: baseURL)
    XCTAssertEqual(store.loadConversations().map(\.id), [good.id])
    let quarantined = conversationFileURL(in: baseURL, id: badID).appendingPathExtension("corrupt")
    XCTAssertEqual(try Data(contentsOf: quarantined), badData)
    XCTAssertEqual(store.corruptedConversationCount(), 1)
    XCTAssertEqual(store.corruptedConversationDocuments().map(\.filename), [quarantined.lastPathComponent])

    // A quarantined file that decodes again is put back and indexed.
    try FileManager.default.removeItem(at: quarantined)
    let recoverable = conversationFileURL(in: baseURL, id: good.id).appendingPathExtension("corrupt")
    try FileManager.default.removeItem(at: conversationFileURL(in: baseURL, id: good.id))
    try goodData.write(to: recoverable, options: .atomic)
    let result = store.recoverCorruptedConversations()
    XCTAssertEqual(result.recoveredConversations.map(\.id), [good.id])
    XCTAssertEqual(result.remainingCount, 0)
    XCTAssertTrue(fileExists(in: baseURL, id: good.id))
    XCTAssertEqual(try indexedIDs(in: baseURL), [good.id.uuidString])
  }
}
