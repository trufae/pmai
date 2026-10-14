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
    try await waitUntil {
      persistence.loadSettings().conversationFolders.map(\.id) == [folder.id]
    }
    XCTAssertEqual(persistence.loadSettings().conversationFolders.first?.name, folder.name)

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

  func testNewChatUsesSelectedFolderAndItsDefaults() async throws {
    let previous = try XCTUnwrap(store.currentConversation)
    let folder = try XCTUnwrap(store.createConversationFolder(named: "Work"))
    let endpoint = OpenAIEndpoint(
      name: "Work", baseURL: "http://localhost:11434", defaultModel: "work-model")
    store.settings.networkAvailable = true
    store.settings.openAIEndpoints.append(endpoint)
    store.setConversationFolderDefaults(
      ConversationFolderDefaults(
        provider: .openAICompatible, endpointID: endpoint.id, modelID: "work-model"),
      for: folder.id)

    store.selectConversationFolder(folder.id)
    XCTAssertEqual(store.currentConversation?.id, previous.id, "Browsing must not move a chat")
    store.newConversation()
    let created = try XCTUnwrap(store.currentConversation)
    XCTAssertNotEqual(created.id, previous.id)
    XCTAssertEqual(created.folderID, folder.id)
    XCTAssertEqual(created.provider, .openAICompatible)
    XCTAssertEqual(created.endpointID, endpoint.id)
    XCTAssertEqual(created.modelID, "work-model")
    XCTAssertEqual(store.conversation(withID: previous.id), previous)

    store.updateCurrentConversation {
      $0.messages = [ChatMessage(role: .user, text: "In Work")]
    }
    XCTAssertTrue(
      store.conversationSummaries.contains { $0.id == created.id && $0.folderID == folder.id })
    try await waitUntil {
      persistence.loadConversations().contains { $0.id == created.id && $0.folderID == folder.id }
    }
  }

  func testNewChatReplacesEmptyPlaceholderFromAnotherFolder() throws {
    store.newConversation()
    let placeholder = try XCTUnwrap(store.currentConversation)
    store.newConversation()
    XCTAssertEqual(
      store.currentConversation?.id, placeholder.id, "Reuse an untouched matching chat")

    let folder = try XCTUnwrap(store.createConversationFolder(named: "Work"))
    store.selectConversationFolder(folder.id)
    store.newConversation()
    let created = try XCTUnwrap(store.currentConversation)
    XCTAssertNotEqual(created.id, placeholder.id)
    XCTAssertEqual(created.folderID, folder.id)
    XCTAssertNil(store.conversation(withID: placeholder.id))

    store.selectConversationFolder(ConversationFolder.defaultID)
    store.newConversation()
    XCTAssertEqual(store.currentConversation?.folderID, ConversationFolder.defaultID)
    XCTAssertNil(store.conversation(withID: created.id))
  }

  func testNewChatPreservesUnsentDraftInItsOriginalFolder() async throws {
    store.newConversation()
    let draft = try XCTUnwrap(store.currentConversation)
    store.setDraftText("Unsent work", for: draft.id)
    let folder = try XCTUnwrap(store.createConversationFolder(named: "Work"))
    store.selectConversationFolder(folder.id)
    store.newConversation()
    XCTAssertNotEqual(store.currentConversation?.id, draft.id)
    XCTAssertEqual(store.currentConversation?.folderID, folder.id)
    XCTAssertEqual(store.draftText(for: store.selectedConversationID), "")
    XCTAssertEqual(store.conversation(withID: draft.id)?.folderID, draft.folderID)
    XCTAssertEqual(store.draftText(for: draft.id), "Unsent work")

    await store.selectConversation(id: draft.id)
    XCTAssertEqual(store.selectedConversationFolderID, draft.folderID)
    store.newConversation()
    XCTAssertNotEqual(
      store.currentConversation?.id, draft.id, "New Chat also leaves a draft in the same folder")
    XCTAssertEqual(store.currentConversation?.folderID, draft.folderID)
    XCTAssertEqual(store.draftText(for: draft.id), "Unsent work")
  }

  func testNewChatPreservesNamedAndPinnedEmptyChats() throws {
    let folder = try XCTUnwrap(store.createConversationFolder(named: "Work"))
    for pinned in [false, true] {
      store.selectConversationFolder(ConversationFolder.defaultID)
      store.newConversation()
      store.updateCurrentConversationSettings {
        if pinned {
          $0.isPinned = true
        } else {
          $0.title = "Saved empty chat"
        }
      }
      let saved = try XCTUnwrap(store.currentConversation)
      store.selectConversationFolder(folder.id)
      store.newConversation()
      XCTAssertNotEqual(store.currentConversation?.id, saved.id)
      XCTAssertEqual(store.currentConversation?.folderID, folder.id)
      XCTAssertEqual(store.conversation(withID: saved.id), saved)
    }
  }

  func testNewChatAfterDeletingSelectedFolderUsesDefault() async throws {
    let folder = try XCTUnwrap(store.createConversationFolder(named: "Work"))
    store.selectConversationFolder(folder.id)
    store.newConversation()
    await store.deleteConversationFolder(id: folder.id)
    store.newConversation()
    XCTAssertEqual(store.selectedConversationFolderID, ConversationFolder.defaultID)
    XCTAssertEqual(store.currentConversation?.folderID, ConversationFolder.defaultID)
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(
      predicate(), "Folder operation did not finish before the deadline", file: file, line: line)
  }
}
