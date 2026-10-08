import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class ConversationSearchToolTests: XCTestCase {
  private var baseURL: URL!
  private var store: AppStore!
  private var sameFolder: Conversation!
  private var otherFolder: Conversation!

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-context-\(UUID().uuidString)", isDirectory: true)
    sameFolder = Conversation()
    sameFolder.title = "Saved same-folder chat"
    sameFolder.messages = [
      ChatMessage(
        role: .user, text: "same-folder needle",
        attachments: [
          .textFile(filename: "notes.txt", text: "same-folder document needle")
        ])
    ]
    otherFolder = Conversation()
    otherFolder.folderID = ConversationFolder.archivedID
    otherFolder.title = "Saved other-folder chat"
    otherFolder.messages = [
      ChatMessage(
        role: .assistant, text: "other-folder needle",
        attachments: [
          .textFile(filename: "private.txt", text: "other-folder document needle")
        ])
    ]
    let persistence = PersistenceStore(localBaseURL: baseURL)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      persistence.saveConversations([sameFolder, otherFolder]) { continuation.resume() }
    }
    store = AppStore(persistence: persistence)
    try await waitUntil {
      store.hasLoadedPersistedSettings
        && store.conversationSummaries.contains { $0.id == sameFolder.id }
        && store.conversationSummaries.contains { $0.id == otherFolder.id }
    }
    store.settings.airplaneModeEnabled = true
    store.updateCurrentConversationSettings {
      $0.title = "Active chat"
      $0.enabledTools = [.context]
      $0.messages = [ChatMessage(role: .user, text: "active-chat needle")]
    }
  }

  override func tearDown() async throws {
    store = nil
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  func testContextCatalogRequiresSelectionAndConfiguredScope() throws {
    var conversation = try XCTUnwrap(store.currentConversation)
    XCTAssertTrue(BuiltInToolID.context.isCallableTool)
    XCTAssertTrue(
      BuiltInToolCatalog.definitions(for: conversation, settings: store.settings).isEmpty)

    store.settings.toolSettings.conversationSearchScope = .currentFolder
    let definitions = ToolAgentRegistry.definitions(for: conversation, settings: store.settings)
    XCTAssertEqual(Set(definitions.map(\.name)), Set(MaiMemoryTools.toolNames))
    XCTAssertTrue(definitions.allSatisfy { $0.annotations.readOnly == true })

    conversation.enabledTools = [.memory]
    XCTAssertTrue(
      BuiltInToolCatalog.definitions(for: conversation, settings: store.settings).isEmpty)
    conversation.enabledTools = [.context]
    conversation.toolsEnabled = false
    XCTAssertTrue(
      ToolAgentRegistry.definitions(for: conversation, settings: store.settings).isEmpty)
  }

  func testCurrentFolderReadsUnloadedSavedChatsAndExcludesOtherFoldersAndCurrentChat() async throws
  {
    XCTAssertNil(store.conversation(withID: sameFolder.id))
    store.settings.toolSettings.conversationSearchScope = .currentFolder
    let listing = try await execute(MaiMemoryTools.listName)
    XCTAssertTrue(listing.contains(sameFolder.title))
    XCTAssertFalse(listing.contains(otherFolder.title))
    XCTAssertFalse(listing.contains("Active chat"))

    let search = try await execute(MaiMemoryTools.searchName, arguments: ["query": "needle"])
    XCTAssertTrue(search.contains("same-folder needle"))
    XCTAssertTrue(search.contains("same-folder document needle"))
    XCTAssertFalse(search.contains("other-folder"))
    XCTAssertFalse(search.contains("active-chat"))

    let transcript = try await execute(
      MaiMemoryTools.readName, arguments: ["chat": sameFolder.id.uuidString])
    XCTAssertTrue(transcript.contains("same-folder needle"))
    let denied = try await execute(
      MaiMemoryTools.readName, arguments: ["chat": otherFolder.id.uuidString])
    XCTAssertTrue(denied.hasPrefix("Error:"))
    let deniedDocument = try await execute(
      MaiMemoryTools.readDocumentName,
      arguments: [
        "chat": otherFolder.id.uuidString, "filename": "private.txt",
      ])
    XCTAssertTrue(deniedDocument.hasPrefix("Error:"))
    XCTAssertFalse(deniedDocument.contains("other-folder document needle"))
  }

  func testAllFoldersAllowsSavedTranscriptsAndDocumentsAcrossFolders() async throws {
    store.settings.toolSettings.conversationSearchScope = .allFolders
    let listing = try await execute(MaiMemoryTools.listName)
    XCTAssertTrue(listing.contains(sameFolder.title))
    XCTAssertTrue(listing.contains(otherFolder.title))
    XCTAssertFalse(listing.contains("Active chat"))
    let transcript = try await execute(
      MaiMemoryTools.readName, arguments: ["chat": otherFolder.id.uuidString])
    XCTAssertTrue(transcript.contains("other-folder needle"))
    let document = try await execute(
      MaiMemoryTools.readDocumentName,
      arguments: [
        "chat": otherFolder.id.uuidString, "filename": "private.txt",
      ])
    XCTAssertTrue(document.contains("other-folder document needle"))
  }

  func testDisabledAccessRejectsCallsEvenAfterChatsHaveBeenLoaded() async throws {
    store.settings.toolSettings.conversationSearchScope = .allFolders
    _ = try await execute(MaiMemoryTools.listName)
    store.settings.toolSettings.conversationSearchScope = .none
    let denied = try await execute(
      MaiMemoryTools.readName, arguments: ["chat": sameFolder.id.uuidString])
    XCTAssertTrue(denied.hasPrefix("Error:"))
    XCTAssertFalse(denied.contains("same-folder needle"))

    store.settings.toolSettings.conversationSearchScope = .allFolders
    store.updateCurrentConversationSettings { $0.enabledTools = [.memory] }
    let disabledTool = try await execute(MaiMemoryTools.listName)
    XCTAssertTrue(disabledTool.hasPrefix("Error:"))
  }

  func testContextSelectionAndAccessScopeSurvivePersistence() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let conversation = try XCTUnwrap(store.currentConversation)
    let reloaded = try decoder.decode(Conversation.self, from: encoder.encode(conversation))
    XCTAssertEqual(reloaded.enabledTools, [.context])
    var settings = store.settings
    settings.defaultEnabledTools = [.context]
    settings.toolSettings.conversationSearchScope = .allFolders
    let reloadedSettings = try decoder.decode(AppSettings.self, from: encoder.encode(settings))
    XCTAssertEqual(reloadedSettings.defaultEnabledTools, [.context])
    XCTAssertEqual(reloadedSettings.toolSettings.conversationSearchScope, .allFolders)
  }

  private func execute(_ name: String, arguments: [String: String] = [:]) async throws -> String {
    await ConversationSearchTool.execute(
      name: name, arguments: arguments.mapValues { .string($0) },
      conversation: try XCTUnwrap(store.currentConversation), store: store)
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(predicate(), "Context test setup did not finish before the deadline")
  }
}
