import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class BTWTests: XCTestCase {
  private var store: AppStore!
  private var root: URL!

  override func setUp() async throws {
    try await super.setUp()
    StubChatEndpoint.install()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("btw-\(UUID())")
    store = AppStore(persistence: PersistenceStore(localBaseURL: root), monitorNetwork: false)
    try await waitUntil { self.store.hasLoadedPersistedSettings }
    await store.loadStoredConversationsForSearch()
    let endpoint = OpenAIEndpoint(
      name: "BTW fixture", baseURL: "https://\(StubChatEndpoint.host)/v1", defaultModel: "stub")
    store.settings.openAIEndpoints = [endpoint]
    store.settings.defaultProvider = .openAICompatible
    store.settings.selectedEndpointID = endpoint.id
    store.settings.agents[0].canSpawnSubagents = false
    store.settings.streamByDefault = false
    store.settings.followUps.autoGenerate = false
    store.settings.background.liveActivityEnabled = false
    store.newConversation()
    store.updateCurrentConversation {
      $0.provider = .openAICompatible
      $0.modelID = "stub"
      $0.endpointID = endpoint.id
      $0.usesStreaming = false
      $0.toolsEnabled = false
      $0.enabledTools = []
      $0.enabledMCPServers = []
      $0.messages = [ChatMessage(role: .user, text: "Previous private context")]
    }
  }

  override func tearDown() async throws {
    store.dismissBTWQuestions()
    if let id = store.currentConversation?.id { store.cancelResponse(in: id) }
    try await waitUntil { self.store.btwTasks.isEmpty && !self.store.isResponding }
    StubChatEndpoint.uninstall()
    store = nil
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition() {
      guard Date() < deadline else {
        XCTFail("Timed out waiting for fixture")
        throw NSError(domain: "BTWTests", code: 1)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testSideQuestionsFinishWhileMainTurnRunsAndNeverEnterHistory() async throws {
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let prompt = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
      // The provider folds consecutive user messages into one message.
      return (StubChatEndpoint.completion(content: "Answer: \(prompt)"), prompt.hasSuffix("main") ? 3 : 0)
    }
    let id = try XCTUnwrap(store.currentConversation?.id)
    let acceptedMain = await store.send(prompt: "main")
    XCTAssertTrue(acceptedMain)
    try await waitUntil { !StubChatEndpoint.requests.isEmpty }
    let acceptedSide = await store.send(prompt: "/btw side")
    XCTAssertTrue(acceptedSide)
    // Other submission paths also bypass the queue for /btw.
    XCTAssertTrue(store.enqueueUserMessage(prompt: "/btw another", in: id))
    try await waitUntil { self.store.btwQuestions.count == 2 && self.store.btwQuestions.allSatisfy { !$0.isRunning } }
    XCTAssertTrue(store.isResponding(in: id), "Side answers waited for the main turn: \(StubChatEndpoint.requests)")
    XCTAssertEqual(store.btwQuestions.map(\.answer), ["Answer: side", "Answer: another"])
    XCTAssertTrue(store.queuedUserMessages(in: id).isEmpty)
    for request in StubChatEndpoint.requests.dropFirst() {
      let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
      let users = messages.filter { $0["role"] as? String == "user" }
      XCTAssertEqual(users.count, 1)
      XCTAssertTrue(["side", "another"].contains(users[0]["content"] as? String ?? ""), "\(users)")
      XCTAssertFalse(messages.contains { $0["role"] as? String == "assistant" })
    }
    try await waitUntil { !self.store.isResponding(in: id) }
    let history = try XCTUnwrap(store.currentConversation?.messages)
    XCTAssertEqual(history.filter { $0.role == .user }.map(\.text), ["Previous private context", "main"])
    let acceptedIdle = await store.send(prompt: "/btw idle")
    XCTAssertTrue(acceptedIdle)
    try await waitUntil { self.store.btwQuestions.last?.isRunning == false }
    XCTAssertEqual(store.btwQuestions.last?.answer, "Answer: idle")
    XCTAssertEqual(store.currentConversation?.messages, history)
    XCTAssertEqual(store.currentConversation?.id, id)
  }

  func testStopAndDismissSideQuestionLeaveMainTaskRunning() async throws {
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let prompt = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
      return (StubChatEndpoint.completion(content: "Done"), prompt.hasSuffix("main") ? 3 : 1)
    }
    let id = try XCTUnwrap(store.currentConversation?.id)
    _ = await store.send(prompt: "main")
    _ = await store.send(prompt: "/btw stop me")
    try await waitUntil { StubChatEndpoint.requests.count == 2 }
    let sideID = try XCTUnwrap(store.btwQuestions.first?.id)
    store.stopBTW(sideID)
    try await waitUntil { self.store.btwQuestions.first?.isRunning == false }
    XCTAssertEqual(store.btwQuestions.first?.error, "Stopped")
    XCTAssertTrue(store.isResponding(in: id))
    store.dismissBTW(sideID)
    XCTAssertTrue(store.btwQuestions.isEmpty)
    // Let delayed fixture callbacks finish before uninstalling the protocol.
    try await waitUntil { !self.store.isResponding(in: id) }
    XCTAssertFalse(store.currentConversation?.messages.contains { $0.text.contains("stop me") } ?? true)
  }

  func testRequestKeepsProfileButDropsTranscriptAttachmentsAndSession() throws {
    var source = try XCTUnwrap(store.currentConversation)
    source.toolsEnabled = true
    source.enabledTools = [.calculator, .files]
    source.systemPromptID = UUID()
    source.reasoningLevel = .high
    let request = BTWQuestion.conversation(from: source, prompt: "Question")
    XCTAssertNotEqual(request.id, source.id)
    XCTAssertNotEqual(request.sessionID, source.sessionID)
    XCTAssertEqual(request.messages.map(\.text), ["Question"])
    XCTAssertTrue(request.messages[0].attachments.isEmpty)
    XCTAssertEqual(request.provider, source.provider)
    XCTAssertEqual(request.modelID, source.modelID)
    XCTAssertEqual(request.endpointID, source.endpointID)
    XCTAssertEqual(request.systemPromptID, source.systemPromptID)
    XCTAssertEqual(request.enabledTools, source.enabledTools)
    XCTAssertEqual(request.reasoningLevel, source.reasoningLevel)
    XCTAssertNil(BTWQuestion.prompt(in: "/btwhatever hi"))
    XCTAssertNil(BTWQuestion.prompt(in: "$btw hi"))
    XCTAssertEqual(BTWQuestion.prompt(in: " /btw\nhello "), "hello")
  }

  func testEmptyQuestionDoesNotStartATurn() async throws {
    let history = store.currentConversation?.messages
    let accepted = await store.send(prompt: "/btw   ")
    XCTAssertFalse(accepted)
    XCTAssertEqual(store.errorMessage, "Usage: /btw QUESTION")
    XCTAssertTrue(store.btwQuestions.isEmpty)
    XCTAssertTrue(StubChatEndpoint.requests.isEmpty)
    XCTAssertEqual(store.currentConversation?.messages, history)
  }
}
