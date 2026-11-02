import Foundation
import Testing

@testable import MaiCore

// Messages a person queues for a running process reach it between model
// turns; a host that starts turns itself folds them into the next request.

@Test("A queued message joins the transcript after the tool results of the turn it arrived in")
func queuedMessageJoinsRunBetweenTurns() async throws {
  let provider = InboxScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(ToolCall(id: "call-1", name: "echo", arguments: .object(["text": .string("a")])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Done with both."), stopReason: .stop),
  ])
  let recorder = InboxEventRecorder()
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "echo",
        description: "Echo",
        inputSchema: inboxObjectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, context in
      // The person types while the tool runs, so the message is waiting when
      // the run comes back round to the model.
      let pid = try #require(context.run.pid)
      await supervisor.post(.user("also mention b"), to: pid)
      return ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "inbox-scripted",
      model: "fixture",
      messages: [.user("echo a")],
      toolNames: ["echo"])
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Done with both.")
  #expect(result.modelTurns == 2)
  let roles = result.transcript.map(\.role)
  #expect(roles == [.user, .assistant, .tool, .user, .assistant])
  #expect(result.transcript[3].text == "also mention b")
  let requests = await provider.requests
  #expect(requests.count == 2)
  #expect(requests[1].messages.last?.role == .user)
  #expect(requests[1].messages.last?.text == "also mention b")
  let injected = await recorder.events.compactMap { event -> AgentMessage? in
    if case .userMessage(let context, let message) = event, context.depth == 0 { return message }
    return nil
  }
  #expect(injected.map(\.text) == ["also mention b"])
  let pid = try #require(await supervisor.tree().processes.first { $0.runID == result.runID }?.pid)
  #expect(await supervisor.queuedMessages(for: pid).isEmpty)
  #expect(await supervisor.info(pid)?.queuedMessages == 0)
}

@Test("A message queued while the model answers gives the run one more turn")
func queuedMessageBeforeFinalAnswerAddsATurn() async throws {
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  let pid = await runtime.allocateProcess(agentID: "main")
  let provider = InboxScriptedProvider(
    responses: [
      ProviderResponse(message: .assistant("First."), stopReason: .stop),
      ProviderResponse(message: .assistant("Second, with the follow-up."), stopReason: .stop),
    ],
    onRequest: { index in
      if index == 0 { await supervisor.post(.user("follow-up"), to: pid) }
    })
  try await runtime.register(provider)

  let result = try await runtime.run(
    AgentRequest(provider: "inbox-scripted", model: "fixture", messages: [.user("start")]),
    process: pid)

  #expect(result.response.text == "Second, with the follow-up.")
  #expect(result.modelTurns == 2)
  #expect(result.transcript.map(\.text) == ["start", "First.", "follow-up", "Second, with the follow-up."])
  #expect(await supervisor.queuedMessages(for: pid).isEmpty)
  #expect(await supervisor.info(pid)?.state == .completed)
}

@Test("A run out of turns ends and leaves the queued message for its host")
func queuedMessageStaysWhenTurnsRunOut() async throws {
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  let pid = await runtime.allocateProcess(agentID: "main")
  let provider = InboxScriptedProvider(
    responses: [ProviderResponse(message: .assistant("Only answer."), stopReason: .stop)],
    onRequest: { _ in await supervisor.post(.user("too late"), to: pid) })
  try await runtime.register(provider)

  let result = try await runtime.run(
    AgentRequest(
      provider: "inbox-scripted",
      model: "fixture",
      messages: [.user("start")],
      limits: AgentRunLimits(maxModelTurns: 1)),
    process: pid)

  #expect(result.response.text == "Only answer.")
  #expect(result.modelTurns == 1)
  let waiting = await supervisor.queuedMessages(for: pid)
  #expect(waiting.map(\.message.text) == ["too late"])
  #expect(await supervisor.info(pid)?.queuedMessages == 1)
  // The host folds it into the next turn the way a REPL would.
  let folded = await supervisor.drainInbox(pid)
  #expect(folded.map(\.text) == ["too late"])
  #expect(await supervisor.info(pid)?.queuedMessages == 0)
}

@Test("An allocated process is the one a later run reports into")
func allocatedProcessIsReusedByRun() async throws {
  let runtime = AgentRuntime()
  let pid = await runtime.allocateProcess(agentID: "main", task: "chat")
  let before = try #require(await runtime.supervisor.info(pid))
  #expect(before.state == .starting)
  #expect(before.depth == 0)
  #expect(before.agentID == "main")

  let provider = InboxScriptedProvider(responses: [
    ProviderResponse(message: .assistant("Hi."), stopReason: .stop)
  ])
  try await runtime.register(provider)
  let result = try await runtime.run(
    AgentRequest(provider: "inbox-scripted", model: "fixture", messages: [.user("hello")]),
    process: pid)

  let after = try #require(await runtime.supervisor.info(pid))
  #expect(after.runID == result.runID)
  #expect(after.state == .completed)
  #expect(after.modelTurns == 1)
  #expect(await runtime.supervisor.processes().count == 1)
}

@Test("Queued messages can be listed, popped, dropped by id, and flushed before they are read")
func inboxEditing() async throws {
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  let first = await runtime.allocateProcess(agentID: "main")
  let second = await runtime.allocateProcess(agentID: "other")

  #expect(await supervisor.post(.user("nobody"), to: AgentPID(99)) == nil)
  let a = try #require(await supervisor.post(.user("a"), to: first))
  _ = await supervisor.post(.user("b"), to: first)
  _ = await supervisor.post(.user("c"), to: second)
  _ = await supervisor.post(.user("d"), to: first)

  #expect(await supervisor.queuedMessages(for: first).map(\.message.text) == ["a", "b", "d"])
  #expect(await supervisor.queuedMessages().map(\.message.text) == ["a", "b", "c", "d"])
  #expect(await supervisor.info(first)?.queuedMessages == 3)
  #expect(await supervisor.info(second)?.queuedMessages == 1)
  #expect(await supervisor.info(first)?.summaryLine.contains("3 queued") == true)

  #expect(await supervisor.discardLastQueuedMessage(for: first)?.message.text == "d")
  #expect(await supervisor.discardLastQueuedMessage()?.message.text == "c")
  #expect(await supervisor.discardLastQueuedMessage(for: second) == nil)
  #expect(await supervisor.discardQueuedMessage(id: a.id)?.message.text == "a")
  #expect(await supervisor.discardQueuedMessage(id: a.id) == nil)
  #expect(await supervisor.queuedMessages().map(\.message.text) == ["b"])

  _ = await supervisor.post(.user("e"), to: second)
  let flushed = await supervisor.clearQueuedMessages()
  #expect(flushed.map(\.message.text) == ["b", "e"])
  #expect(await supervisor.queuedMessages().isEmpty)
  #expect(await supervisor.info(first)?.queuedMessages == 0)
  #expect(await supervisor.info(second)?.queuedMessages == 0)
}

@Test("A background child's own stream reaches the host handler, tagged with its pid")
func backgroundChildEventsReachTheHost() async throws {
  let provider = BackgroundChildProvider()
  let recorder = InboxEventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllInboxApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      instructions: "Research carefully.",
      provider: "background-child",
      model: "fixture"))

  let launch = try await runtime.run(
    AgentRequest(
      provider: "background-child",
      model: "fixture",
      messages: [.user("delegate")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(maxModelTurns: 4, maxToolCalls: 2, maxSubagents: 1, maxSubagentDepth: 1))
  ) { event in
    await recorder.append(event)
  }
  #expect(launch.response.text == "Parent carries on")

  let childPID = try #require(
    await runtime.supervisor.processes().first { $0.depth == 1 }?.pid)
  for _ in 0..<50 {
    if await runtime.supervisor.info(childPID)?.state.isTerminal == true { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(await runtime.supervisor.info(childPID)?.state == .completed)

  let events = await recorder.events
  let childText = events.compactMap { event -> String? in
    if case .provider(let context, .textDelta(let text)) = event, context.depth == 1,
      context.pid == childPID
    {
      return text
    }
    return nil
  }
  #expect(childText == ["Child text"])
  #expect(
    events.contains {
      if case .finished(let context, let result) = $0, context.pid == childPID {
        return result.response.text == "Child text"
      }
      return false
    })
  #expect(
    events.contains {
      if case .modelStarted(let context, let turn) = $0 { return context.pid == childPID && turn == 1 }
      return false
    })
}

// MARK: - Fixtures

// A person can hold a running process and let it go on later. The run ends
// the model call or tool it is in, then waits at its next step; what was
// queued meanwhile reaches it when it continues.

@Test("A paused run ends the step it is in, waits, and reads its inbox when it continues")
func pausedRunWaitsAtTheNextStep() async throws {
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  let pid = await runtime.allocateProcess(agentID: "main")
  let provider = InboxScriptedProvider(
    responses: [
      ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(id: "call-1", name: "echo", arguments: .object(["text": .string("a")])))
          ]),
        stopReason: .toolCall),
      ProviderResponse(message: .assistant("Done, with the note."), stopReason: .stop),
    ],
    onRequest: { index in
      // The person pauses while the model is still answering the first turn.
      if index == 0 { await supervisor.pause(pid) }
    })
  try await runtime.register(provider)
  let echoes = InboxCounter()
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "echo",
        description: "Echo",
        inputSchema: inboxObjectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      await echoes.increment()
      return ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
    })

  let run = Task {
    try await runtime.run(
      AgentRequest(
        provider: "inbox-scripted",
        model: "fixture",
        messages: [.user("echo a")],
        toolNames: ["echo"]),
      process: pid)
  }
  defer { run.cancel() }

  // The model call it was in completes; the tool it asked for waits.
  try await inboxWaitUntil {
    await supervisor.info(pid).map { $0.state == .paused && $0.activity.isEmpty } ?? false
  }
  #expect(await supervisor.info(pid)?.modelTurns == 1)
  #expect(await provider.requests.count == 1)
  #expect(await echoes.value == 0)
  await supervisor.post(.user("also note b"), to: pid)
  #expect(await supervisor.info(pid)?.queuedMessages == 1)
  #expect(await supervisor.resume(pid) == [pid])

  let result = try await run.value
  #expect(result.response.text == "Done, with the note.")
  #expect(result.modelTurns == 2)
  #expect(await echoes.value == 1)
  #expect(result.transcript.map(\.role) == [.user, .assistant, .tool, .user, .assistant])
  #expect(result.transcript[3].text == "also note b")
  #expect(await supervisor.info(pid)?.state == .completed)
  #expect(await supervisor.isPaused(pid) == false)
}

@Test("A paused run that is cancelled ends where it waits")
func cancelledWhilePausedRunEnds() async throws {
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  let pid = await runtime.allocateProcess(agentID: "main")
  let provider = InboxScriptedProvider(
    responses: [
      ProviderResponse(message: .assistant("First."), stopReason: .stop),
      ProviderResponse(message: .assistant("Never asked for."), stopReason: .stop),
    ],
    onRequest: { index in
      if index == 0 {
        await supervisor.pause(pid)
        // A follow-up keeps the run going for a second turn, which is where it parks.
        await supervisor.post(.user("more"), to: pid)
      }
    })
  try await runtime.register(provider)

  let run = Task {
    try await runtime.run(
      AgentRequest(provider: "inbox-scripted", model: "fixture", messages: [.user("start")]),
      process: pid)
  }
  defer { run.cancel() }
  try await inboxWaitUntil {
    await supervisor.info(pid).map { $0.state == .paused && $0.activity.isEmpty } ?? false
  }
  #expect(await provider.requests.count == 1)

  run.cancel()
  await #expect(throws: CancellationError.self) { try await run.value }
  #expect(await supervisor.info(pid)?.state == .cancelled)
  #expect(await supervisor.isPaused(pid) == false)
  #expect(await provider.requests.count == 1)
}

private actor InboxCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private func inboxWaitUntil(
  timeout: Duration = .seconds(30),
  _ condition: @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while await !condition() {
    guard clock.now < deadline else { throw InboxTestError.timedOut }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private actor InboxScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "inbox-scripted",
    displayName: "Inbox scripted",
    capabilities: [.streaming, .nativeToolCalling])
  private var responses: [ProviderResponse]
  private let onRequest: (@Sendable (Int) async -> Void)?
  private(set) var requests: [ProviderRequest] = []

  init(responses: [ProviderResponse], onRequest: (@Sendable (Int) async -> Void)? = nil) {
    self.responses = responses
    self.onRequest = onRequest
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let index = requests.count
    requests.append(request)
    await onRequest?(index)
    guard !responses.isEmpty else { throw InboxTestError.missingResponse }
    let response = responses.removeFirst()
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}

/// A parent that starts one background child and carries on; the child
/// answers with plain text after a short pause.
private actor BackgroundChildProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "background-child",
    displayName: "Background child fixture",
    capabilities: [.streaming, .nativeToolCalling])

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    if request.messages.first?.text == "Research carefully." {
      try await Task.sleep(for: .milliseconds(50))
      await emit(.textDelta("Child text"))
      return ProviderResponse(message: .assistant("Child text"), stopReason: .stop)
    }
    if request.messages.flatMap(\.toolResults).isEmpty {
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: "start-1",
                name: AgentRuntime.agentStartToolName,
                arguments: .object([
                  "agent": .string("researcher"),
                  "task": .string("Look into it"),
                  "output": .string("One line"),
                  "wait": .bool(false),
                ])))
          ]),
        stopReason: .toolCall)
    }
    await emit(.textDelta("Parent carries on"))
    return ProviderResponse(message: .assistant("Parent carries on"), stopReason: .stop)
  }
}

private struct AllowAllInboxApprovals: ApprovalHandler {
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .approve(arguments: request.call.arguments)
  }
}

private actor InboxEventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

private enum InboxTestError: Error {
  case missingResponse
  case timedOut
}

private func inboxObjectSchema(required: [String]) -> JSONValue {
  .object([
    "type": .string("object"),
    "properties": .object(
      Dictionary(uniqueKeysWithValues: required.map { ($0, JSONValue.object(["type": .string("string")])) })),
    "required": .array(required.map(JSONValue.string)),
  ])
}

@Test("Cancelling a long tool preserves each agent's inbox and continuing consumes only its own")
func cancelledToolPreservesAgentQueues() async throws {
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  let pid = await runtime.allocateProcess(agentID: "main")
  let other = await runtime.allocateProcess(agentID: "other")
  let provider = InboxScriptedProvider(responses: [
    ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: "slow", name: "slow", arguments: .object([:])))
    ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("Continued."), stopReason: .stop),
  ])
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(definition: ToolDefinition(
    name: "slow", description: "Wait", annotations: ToolAnnotations(approval: .automatic)
  )) { _, _ in
    await supervisor.post(.user("keep main"), to: pid)
    await supervisor.post(.user("keep other"), to: other)
    try await Task.sleep(for: .seconds(60))
    return ToolOutput(text: "done")
  })
  let run = Task {
    try await runtime.run(AgentRequest(
      provider: "inbox-scripted", model: "fixture", messages: [.user("start")],
      toolNames: ["slow"]), process: pid)
  }
  try await inboxWaitUntil { await supervisor.hasQueuedMessages(pid) }
  run.cancel()
  await #expect(throws: CancellationError.self) { try await run.value }
  #expect(await supervisor.queuedMessages(for: pid).map(\.message.text) == ["keep main"])
  #expect(await supervisor.queuedMessages(for: other).map(\.message.text) == ["keep other"])
  let partial = AgentTranscriptEditor.answeringUnansweredToolCalls(
    in: await supervisor.transcript(pid), reason: "Cancelled")
  let resumed = try await runtime.run(AgentRequest(
    provider: "inbox-scripted", model: "fixture", messages: partial), process: pid)
  #expect(resumed.transcript.filter { $0.text == "keep main" }.count == 1)
  #expect(await supervisor.queuedMessages(for: pid).isEmpty)
  #expect(await supervisor.queuedMessages(for: other).map(\.message.text) == ["keep other"])
}

@Test("Ignoring a queue holds only existing entries and does not spend extra model turns")
func ignoredInboxSurvivesRun() async throws {
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  let pid = await runtime.allocateProcess(agentID: "main")
  let held = try #require(await supervisor.post(.user("later"), to: pid))
  let provider = InboxScriptedProvider(responses: [
    ProviderResponse(message: .assistant("First"), stopReason: .stop),
    ProviderResponse(message: .assistant("Steered"), stopReason: .stop),
    ProviderResponse(message: .assistant("Resumed"), stopReason: .stop),
  ], onRequest: { index in
    if index == 0 { await supervisor.post(.user("new steering"), to: pid) }
  })
  try await runtime.register(provider)
  var request = AgentRequest(provider: "inbox-scripted", model: "fixture", messages: [.user("now")])
  request.ignoredQueuedMessageIDs = [held.id]
  let result = try await runtime.run(request, process: pid)
  #expect(result.modelTurns == 2)
  #expect(!result.transcript.contains { $0.text == "later" })
  #expect(result.transcript.filter { $0.text == "new steering" }.count == 1)
  #expect(await supervisor.queuedMessages(for: pid).map(\.id) == [held.id])
  let continued = try await runtime.run(AgentRequest(
    provider: "inbox-scripted", model: "fixture", messages: result.transcript), process: pid)
  #expect(continued.transcript.filter { $0.text == "later" }.count == 1)
  #expect(await supervisor.queuedMessages(for: pid).isEmpty)
}

@Test("Cancellation while waiting to drain an inbox leaves its entries untouched")
func cancelledInboxDrainKeepsMessages() async throws {
  let runtime = AgentRuntime()
  let pid = await runtime.allocateProcess(agentID: "main")
  await runtime.supervisor.post(.user("keep"), to: pid)
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return await runtime.supervisor.drainInbox(pid)
  }
  #expect(await task.value.isEmpty)
  #expect(await runtime.supervisor.queuedMessages(for: pid).map(\.message.text) == ["keep"])
}
