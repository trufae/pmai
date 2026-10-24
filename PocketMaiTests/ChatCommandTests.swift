import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class ChatCommandTests: XCTestCase {
  private var store: AppStore!
  private var root: URL!

  override func setUp() async throws {
    try await super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("commands-\(UUID())")
    store = AppStore(persistence: PersistenceStore(localBaseURL: root), monitorNetwork: false)
    let deadline = Date().addingTimeInterval(5)
    while !store.hasLoadedPersistedSettings {
      guard Date() < deadline else { throw URLError(.timedOut) }
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.loadStoredConversationsForSearch()
    store.newConversation()
  }

  override func tearDown() async throws {
    store = nil
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  func testVersionDoesNotStartOrQueueAModelTurn() async throws {
    let conversation = try XCTUnwrap(store.currentConversation)
    for busy in [false, true] {
      store.respondingConversationIDs = busy ? [conversation.id] : []
      store.showingVersion = false
      let accepted = await store.send(prompt: " /version\n")
      XCTAssertTrue(accepted)
      XCTAssertTrue(store.showingVersion)
      XCTAssertEqual(store.currentConversation?.messages, conversation.messages)
      XCTAssertEqual(store.isResponding, busy)
      XCTAssertTrue(store.queuedUserMessages(in: conversation.id).isEmpty)
    }
    store.showingVersion = false
    XCTAssertTrue(store.enqueueUserMessage(prompt: "/version", in: conversation.id))
    XCTAssertTrue(store.showingVersion)
    XCTAssertTrue(store.queuedUserMessages(in: conversation.id).isEmpty)
    XCTAssertEqual(store.currentConversation?.messages, conversation.messages)
  }

  func testDollarPromptsKeepCommandNamesAvailable() async throws {
    let prompt = SystemPrompt(name: "version", text: "Custom instructions")
    store.settings.systemPrompts = [prompt]
    let accepted = await store.send(prompt: "$version")
    XCTAssertTrue(accepted)
    XCTAssertEqual(store.currentConversation?.systemPromptID, prompt.id)
    XCTAssertFalse(store.showingVersion)
    XCTAssertTrue(store.currentConversation?.messages.isEmpty == true)
  }
}
