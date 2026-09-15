import Foundation
import XCTest

@testable import PocketMai

@MainActor
final class ConversationFolderTests: XCTestCase {
  private var baseURL: URL!
  private var persistence: PersistenceStore!
  private var store: AppStore!

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-folders-\(UUID().uuidString)", isDirectory: true)
    persistence = PersistenceStore(localBaseURL: baseURL)
    store = AppStore(persistence: persistence)
    try await waitUntil { store.hasLoadedPersistedSettings }
    store.updateCurrentConversationSettings {
      $0.messages = [ChatMessage(role: .user, text: "Keep this chat")]
    }
  }

  override func tearDown() async throws {
    store = nil
    persistence = nil
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  func testEmptyFoldersPersistAndRemainMoveDestinations() async throws {
    let conversation = try XCTUnwrap(store.currentConversation)
    let folder = try XCTUnwrap(store.createConversationFolder(named: "  Work\n"))
    XCTAssertEqual(folder.name, "Work")
    XCTAssertTrue(store.conversationFolders.contains(folder))
    XCTAssertFalse(store.conversationSummaries.contains { $0.folderID == folder.id })
    try await waitUntil { persistence.loadSettings().conversationFolders == [folder] }

    await store.moveConversation(id: conversation.id, to: folder.id)
    XCTAssertEqual(store.currentConversation?.folderID, folder.id)
    XCTAssertEqual(store.selectedConversationFolderID, folder.id)
    XCTAssertEqual(store.currentConversation?.messages, conversation.messages)
    XCTAssertEqual(store.currentConversation?.provider, conversation.provider)
    XCTAssertEqual(store.currentConversation?.modelID, conversation.modelID)
    XCTAssertEqual(store.currentConversation?.systemPromptID, conversation.systemPromptID)

    store.renameConversationFolder(id: folder.id, to: "Projects")
    XCTAssertEqual(store.folderDisplayName(for: folder.id), "Projects")
    await store.moveConversation(id: conversation.id, to: ConversationFolder.defaultID)
    XCTAssertFalse(store.conversationSummaries.contains { $0.folderID == folder.id })
    XCTAssertTrue(store.conversationFolders.contains { $0.id == folder.id })

    await store.moveConversations([conversation.id], to: folder.id)
    XCTAssertEqual(store.currentConversation?.folderID, folder.id)
    XCTAssertEqual(store.selectedConversationFolderID, folder.id)
    await store.deleteConversationFolder(id: folder.id)
    XCTAssertEqual(store.currentConversation?.folderID, ConversationFolder.defaultID)
    XCTAssertEqual(store.selectedConversationFolderID, ConversationFolder.defaultID)
    XCTAssertFalse(store.conversationFolders.contains { $0.id == folder.id })
    try await waitUntil {
      persistence.loadSettings().conversationFolders.isEmpty
        && persistence.loadConversations().first { $0.id == conversation.id }?.folderID
          == ConversationFolder.defaultID
    }
  }

  func testInvalidFolderNamesAndOfflineCloudMovesLeaveChatUnchanged() async throws {
    let conversation = try XCTUnwrap(store.currentConversation)
    let folder = try XCTUnwrap(store.createConversationFolder(named: "Work"))
    for name in [" \n", " work ", "Wórk", "Default", "iCloud", "Archived"] {
      XCTAssertNil(store.createConversationFolder(named: name), name)
      XCTAssertNotNil(store.errorMessage, name)
      store.errorMessage = nil
    }
    XCTAssertEqual(store.customConversationFolders, [folder])
    XCTAssertEqual(store.currentConversation?.folderID, conversation.folderID)

    store.settings.airplaneModeEnabled = true
    XCTAssertFalse(store.canUseConversationFolder(ConversationFolder.iCloudID))
    XCTAssertTrue(store.canUseConversationFolder(folder.id))
    await store.moveConversation(id: conversation.id, to: ConversationFolder.iCloudID)
    XCTAssertEqual(store.currentConversation?.folderID, conversation.folderID)
    XCTAssertEqual(store.selectedConversationFolderID, conversation.folderID)
    store.saveSettings()
    try await waitUntil { persistence.loadSettings().airplaneModeEnabled }
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(predicate(), "Folder operation did not finish before the deadline")
  }
}
