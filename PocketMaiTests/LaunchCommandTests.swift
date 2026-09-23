import Foundation
import XCTest

@testable import PocketMai

@MainActor
final class LaunchCommandTests: XCTestCase {
  private var baseURL: URL!
  private var previousConversation = Conversation()

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-launch-\(UUID().uuidString)", isDirectory: true)
    let conversationsURL = baseURL.appendingPathComponent("conversations", isDirectory: true)
    try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
    previousConversation.messages = [
      ChatMessage(role: .user, text: "Previous chat", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    ]

    var settings = AppSettings.defaults
    settings.startupBehavior = .lastConversation
    settings.lastSelectedConversationID = previousConversation.id
    settings.streamByDefault = false
    settings.defaultEnabledMCPServers = []
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(settings).write(to: baseURL.appendingPathComponent("settings.json"))
    try encoder.encode(previousConversation).write(
      to: conversationsURL.appendingPathComponent("\(previousConversation.id.uuidString).json"))
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  func testNewPromptStartsFreshAndPreservesPreviousConversation() async throws {
    let store = AppStore(persistence: PersistenceStore(localBaseURL: baseURL))
    try await waitForStartup(store)
    store.setDraftText("Keep this draft", for: previousConversation.id)
    let url = try XCTUnwrap(URL(string: "pocketmai://prompt"))
    let widgetCommand = try XCTUnwrap(PocketMaiDeepLink.command(from: url))

    for command in [widgetCommand, .newPrompt(text: "Shortcut prompt")] {
      await store.selectConversation(id: previousConversation.id)
      store.handleLaunchCommand(command)

      let fresh = try XCTUnwrap(store.currentConversation)
      XCTAssertNotEqual(fresh.id, previousConversation.id)
      XCTAssertTrue(fresh.messages.isEmpty)
      XCTAssertEqual(store.draftText(for: fresh.id), "")
      XCTAssertEqual(store.pendingLaunchAction, command)
      XCTAssertEqual(
        store.conversation(withID: previousConversation.id)?.messages, previousConversation.messages)
      XCTAssertEqual(store.draftText(for: previousConversation.id), "Keep this draft")

      store.handleLaunchCommand(.newPrompt(text: nil))
      XCTAssertEqual(store.currentConversation?.id, fresh.id)
    }
  }

  func testWidgetLaunchOverridesLastConversationDuringStartup() async throws {
    let store = AppStore(persistence: PersistenceStore(localBaseURL: baseURL))
    let placeholderID = try XCTUnwrap(store.currentConversation?.id)
    store.handleLaunchCommand(.newPrompt(text: nil))
    store.pendingLaunchAction = nil
    try await waitForStartup(store)

    XCTAssertEqual(store.currentConversation?.id, placeholderID)
    XCTAssertTrue(try XCTUnwrap(store.currentConversation).messages.isEmpty)
    XCTAssertEqual(store.currentConversation?.usesStreaming, false)
    XCTAssertTrue(store.conversationSummaries.contains { $0.id == previousConversation.id })
  }

  func testNormalLaunchStillRestoresLastConversation() async throws {
    let store = AppStore(persistence: PersistenceStore(localBaseURL: baseURL))
    try await waitForStartup(store)

    XCTAssertEqual(store.currentConversation?.id, previousConversation.id)
    XCTAssertEqual(store.currentConversation?.messages, previousConversation.messages)
    XCTAssertNil(store.pendingLaunchAction)
  }

  private func waitForStartup(
    _ store: AppStore, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(5)
    while store.draftStorageRevision == 0, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThan(store.draftStorageRevision, 0, file: file, line: line)
  }
}
