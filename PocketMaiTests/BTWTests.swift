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
    defer { StubChatEndpoint.releaseHeldReplies() }
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let prompt = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
      // The provider folds consecutive user messages into one message.
      return (StubChatEndpoint.completion(content: "Answer: \(prompt)"), prompt.hasSuffix("main") ? -1 : 0)
    }
    let id = try XCTUnwrap(store.currentConversation?.id)
    let acceptedMain = await store.send(prompt: "main")
    XCTAssertTrue(acceptedMain)
    try await waitUntil { StubChatEndpoint.heldReplyCount == 1 }
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
    StubChatEndpoint.releaseHeldReplies()
    try await waitUntil { !self.store.isResponding(in: id) }
    let history = try XCTUnwrap(store.currentConversation?.messages)
    XCTAssertEqual(history.filter { $0.role == .user }.map(\.text), ["Previous private context", "main"])
    let acceptedIdle = await store.send(prompt: "/btw idle")
    XCTAssertTrue(acceptedIdle)
    try await waitUntil { self.store.btwQuestions.last?.isRunning == false }
    XCTAssertEqual(store.btwQuestions.last?.answer, "Answer: idle")
    XCTAssertEqual(store.btwQuestions.map(\.answer), ["Answer: side", "Answer: another", "Answer: idle"])
    let dismissed = store.btwQuestions[1].id
    store.dismissBTW(dismissed)
    XCTAssertEqual(store.btwQuestions.map(\.answer), ["Answer: side", "Answer: idle"])
    XCTAssertEqual(store.currentConversation?.messages, history)
    XCTAssertEqual(store.currentConversation?.id, id)
  }

  func testStopAndDismissSideQuestionLeaveMainTaskRunning() async throws {
    defer { StubChatEndpoint.releaseHeldReplies() }
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Done"), -1) }
    let id = try XCTUnwrap(store.currentConversation?.id)
    _ = await store.send(prompt: "main")
    _ = await store.send(prompt: "/btw stop me")
    try await waitUntil { StubChatEndpoint.heldReplyCount == 2 }
    let sideID = try XCTUnwrap(store.btwQuestions.first?.id)
    store.stopBTW(sideID)
    try await waitUntil { self.store.btwQuestions.first?.isRunning == false }
    XCTAssertEqual(store.btwQuestions.first?.error, "Stopped")
    XCTAssertTrue(store.isResponding(in: id))
    store.dismissBTW(sideID)
    XCTAssertTrue(store.btwQuestions.isEmpty)
    StubChatEndpoint.releaseHeldReplies()
    // Finish fixture callbacks before uninstalling the protocol.
    try await waitUntil { !self.store.isResponding(in: id) }
    XCTAssertFalse(store.currentConversation?.messages.contains { $0.text.contains("stop me") } ?? true)
  }

  // Prevent losing a partial reply or silently replaying work after suspension.
  func testBackgroundExpirationSavesPartialReplyAndStopsMainAndSideQuestions() async throws {
    defer { StubChatEndpoint.releaseHeldReplies() }
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Done"), -1) }
    let id = try XCTUnwrap(store.currentConversation?.id)
    _ = await store.send(prompt: "main")
    _ = await store.send(prompt: "/btw side")
    try await waitUntil { StubChatEndpoint.heldReplyCount == 2 }
    let assistantID = try XCTUnwrap(store.currentConversation?.messages.last?.id)
    store.receiveStreamingAssistantText("Partial reply", for: assistantID, vibrate: false)

    store.handleScenePhaseChange(.background)
    let persistence = PersistenceStore(localBaseURL: root)
    XCTAssertEqual(
      persistence.loadConversations().first { $0.id == id }?.messages.last?.text,
      "Partial reply", "Background entry must save the streaming buffer before suspension")

    store.handleBackgroundExecutionExpired()
    let saved = try XCTUnwrap(
      persistence.loadConversations().first { $0.id == id }?.messages.last)
    XCTAssertTrue(saved.text.hasPrefix("Partial reply\n\n"))
    XCTAssertTrue(saved.text.contains("background time expired"))
    try await waitUntil { !self.store.isResponding && self.store.btwTasks.isEmpty }
    XCTAssertEqual(store.currentConversation?.messages.last?.text, saved.text)
    XCTAssertEqual(store.btwQuestions.first?.error, "Stopped")

    store.handleScenePhaseChange(.active)
    // A fresh explicit request also confirms the app remains usable after cancellation.
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Fresh reply"), 0) }
    _ = await store.send(prompt: "continue explicitly")
    try await waitUntil { !self.store.isResponding }
    XCTAssertEqual(store.currentConversation?.messages.last?.text, "Fresh reply")
    XCTAssertEqual(StubChatEndpoint.requests.count, 3)
  }

  func testThenQueueWaitsForForegroundAfterBackgroundExpiration() async throws {
    defer { StubChatEndpoint.releaseHeldReplies() }
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Done"), -1) }
    _ = await store.send(prompt: "main")
    _ = await store.send(prompt: "/then follow up")
    try await waitUntil { StubChatEndpoint.heldReplyCount == 1 }
    store.handleScenePhaseChange(.background)
    store.handleBackgroundExecutionExpired()
    try await waitUntil { !self.store.isResponding }
    _ = await store.send(prompt: "/then")
    XCTAssertEqual(store.commandOutput, "1. follow up")
    XCTAssertEqual(StubChatEndpoint.requests.count, 1)

    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Queued reply"), 0) }
    store.handleScenePhaseChange(.active)
    try await waitUntil { StubChatEndpoint.requests.count == 2 && !self.store.isResponding }
    XCTAssertEqual(store.currentConversation?.messages.last?.text, "Queued reply")
    XCTAssertEqual(StubChatEndpoint.requests.count, 2)
  }

  func testExpirationAfterReturningToForegroundDoesNotInterruptReply() async throws {
    defer { StubChatEndpoint.releaseHeldReplies() }
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Finished reply"), -1) }
    _ = await store.send(prompt: "main")
    try await waitUntil { StubChatEndpoint.heldReplyCount == 1 }
    store.handleScenePhaseChange(.background)
    store.handleScenePhaseChange(.active)
    store.handleBackgroundExecutionExpired()
    StubChatEndpoint.releaseHeldReplies()
    try await waitUntil { !self.store.isResponding }
    XCTAssertEqual(store.currentConversation?.messages.last?.text, "Finished reply")
    XCTAssertEqual(StubChatEndpoint.requests.count, 1)
  }

  func testBackgroundTimeoutWaitsForAnExplicitDecision() async throws {
    store.handleScenePhaseChange(.background)
    let decision = Task {
      await self.store.requestLongRunningOperationDecision(
        LongRunningOperationContext(
          kind: .modelResponse, conversationID: self.store.currentConversation?.id,
          assistantMessageID: nil, operationName: "Reply", conversationTitle: nil,
          timeoutInterval: 600))
    }
    defer { decision.cancel() }
    try await waitUntil { self.store.activeLongRunningOperationTimeoutRequest != nil }
    store.handleScenePhaseChange(.active)
    let request = try XCTUnwrap(store.activeLongRunningOperationTimeoutRequest)
    store.interruptLongRunningOperation(id: request.id)
    let result = await decision.value
    guard case .interrupt = result else {
      XCTFail("Leaving the app must not consent to extending the timeout")
      return
    }
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

  func testAssignedModelOnlyAppliesToSideQuestions() async throws {
    var agent = store.settings.addAgent(named: "Quick")
    agent.settings.openAIModelID = "side-model"
    store.settings.agents[store.settings.agents.count - 1] = agent
    store.settings.taskAgents.btw = agent.id.uuidString.lowercased()
    let source = try XCTUnwrap(store.currentConversation)
    XCTAssertTrue(store.startBTW("custom", in: source.id))
    try await waitUntil { self.store.btwQuestions.last?.isRunning == false }
    XCTAssertNil(store.btwQuestions.last?.error)
    XCTAssertEqual(StubChatEndpoint.requests.last?["model"] as? String, "side-model")
    XCTAssertEqual(store.currentConversation?.modelID, source.modelID)
    XCTAssertEqual(store.currentConversation?.messages, source.messages)
    store.settings.taskAgents.btw = nil
    XCTAssertTrue(store.startBTW("fallback", in: source.id))
    try await waitUntil { self.store.btwQuestions.last?.isRunning == false }
    XCTAssertEqual(StubChatEndpoint.requests.last?["model"] as? String, source.modelID)
  }

  func testThenRunsSeparateTurnsInOrderAndDispatchesModelCommand() async throws {
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let prompt = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
      return (StubChatEndpoint.completion(content: "Done: \(prompt)"), prompt.hasSuffix("main") ? 1 : 0)
    }
    let id = try XCTUnwrap(store.currentConversation?.id)
    _ = await store.send(prompt: "main")
    try await waitUntil { StubChatEndpoint.requests.count == 1 }
    _ = await store.send(prompt: "/then first")
    XCTAssertTrue(store.enqueueUserMessage(prompt: "/then /model next", in: id))
    _ = await store.send(prompt: "/then second")
    _ = await store.send(prompt: "/then")
    XCTAssertEqual(store.commandOutput, "1. first\n2. /model next\n3. second")
    XCTAssertEqual(StubChatEndpoint.requests.count, 1)
    XCTAssertTrue(store.queuedUserMessages(in: id).isEmpty)
    try await waitUntil {
      StubChatEndpoint.requests.count == 3 && !self.store.isResponding
    }
    XCTAssertEqual(StubChatEndpoint.requests.compactMap { $0["model"] as? String }, ["stub", "stub", "next"])
    let history = try XCTUnwrap(store.conversation(withID: id)?.messages)
    XCTAssertEqual(history.filter { $0.role == .user }.map(\.text),
      ["Previous private context", "main", "first", "second"])
    let firstRequest = StubChatEndpoint.requests[1]["messages"] as? [[String: Any]] ?? []
    XCTAssertTrue(firstRequest.contains { $0["role"] as? String == "assistant" })
    _ = await store.send(prompt: "/then")
    XCTAssertEqual(store.commandOutput, "No /then actions queued.")
  }

  func testUnthenClearsPendingCommandsDuringCompaction() async throws {
    store.isCompacting = true
    _ = await store.send(prompt: "/then dropped")
    _ = await store.send(prompt: "/then /model dropped")
    _ = await store.send(prompt: "/unthen")
    store.isCompacting = false
    _ = await store.send(prompt: "/then")
    XCTAssertEqual(store.commandOutput, "No /then actions queued.")
    XCTAssertEqual(store.currentConversation?.modelID, "stub")
    XCTAssertTrue(StubChatEndpoint.requests.isEmpty)
  }

  func testThenWaitsForSideQuestionsAndBackgroundAgentsAndKeepsOriginChat() async throws {
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Done"), 0) }
    let id = try XCTUnwrap(store.currentConversation?.id)
    let child = await store.agentSupervisor.register(
      runID: UUID(), parent: nil, agentID: "background", depth: 1)
    _ = await store.send(prompt: "/btw side")
    _ = await store.send(prompt: "/then /model origin-model")
    _ = await store.send(prompt: "/then origin")
    try await waitUntil { self.store.btwTasks.isEmpty }
    XCTAssertEqual(StubChatEndpoint.requests.count, 1)
    store.newConversation()
    let selectedID = try XCTUnwrap(store.currentConversation?.id)
    await store.agentSupervisor.complete(child)
    try await waitUntil { StubChatEndpoint.requests.count == 2 && !self.store.isResponding }
    XCTAssertEqual(store.currentConversation?.id, selectedID)
    XCTAssertEqual(store.conversation(withID: id)?.modelID, "origin-model")
    XCTAssertEqual(store.conversation(withID: id)?.messages.last { $0.role == .user }?.text, "origin")
    XCTAssertTrue(store.currentConversation?.messages.isEmpty == true)
    XCTAssertEqual(StubChatEndpoint.requests.last?["model"] as? String, "origin-model")
  }

  func testIdleThenRunsEnabledSkillAsANormalTurn() async throws {
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Done"), 0) }
    let skill = try SkillTools.create(name: "then-\(UUID().uuidString.lowercased())",
      description: "Queue fixture", prompt: "SKILL-$ARGUMENTS")
    defer { try? SkillTools.remove(skill, conversation: store.currentConversation, settings: store.settings) }
    store.settings.enabledSkillTools.insert(skill.toolName)
    store.updateCurrentConversation { $0.toolsEnabled = true }
    _ = await store.send(prompt: "/then /skills prompt \(skill.name) payload")
    try await waitUntil { StubChatEndpoint.requests.count == 1 && !self.store.isResponding }
    XCTAssertTrue(store.currentConversation?.messages.contains {
      $0.role == .user && $0.text.contains("SKILL-payload")
    } == true)
    XCTAssertFalse(store.currentConversation?.messages.contains { $0.text.hasPrefix("/then") } ?? true)
  }


  func testThenDoesNotSendUnknownCommandsToTheModel() async throws {
    _ = await store.send(prompt: "/then /not-a-command")
    try await waitUntil { self.store.errorMessage != nil }
    XCTAssertEqual(store.errorMessage, "Unknown command '/not-a-command'.")
    XCTAssertTrue(StubChatEndpoint.requests.isEmpty)
    XCTAssertEqual(store.currentConversation?.messages.map(\.text), ["Previous private context"])
  }

}
