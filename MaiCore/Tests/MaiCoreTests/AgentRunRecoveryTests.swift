import Foundation
import Testing

@testable import MaiCore

@Test("Interleaved runs on one runtime keep transcripts, usage and allowances independent")
func interleavedRunsKeepTheirOwnState() async throws {
  let provider = InterleavedRunProvider()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: echoTool())
  async let first = runtime.run(
    AgentRequest(
      agentID: "first", provider: provider.descriptor.id, messages: [.user("first task")],
      toolNames: ["echo"], limits: AgentRunLimits(maxModelTurns: 1), retry: .none,
      sessionID: "first"))
  async let second = runtime.run(
    AgentRequest(
      agentID: "second", provider: provider.descriptor.id, messages: [.user("second task")],
      toolNames: ["echo"], limits: AgentRunLimits(maxModelTurns: 3), retry: .none,
      sessionID: "second"))
  let (paused, finished) = try await (first, second)
  #expect(paused.interruption == .modelTurns(limit: 1))
  #expect(paused.modelTurns == 1 && paused.toolCalls == 1)
  #expect(paused.usage?.totalTokens == 10)
  #expect(finished.interruption == nil && finished.response.text == "second finished")
  #expect(finished.modelTurns == 2 && finished.toolCalls == 1)
  #expect(finished.usage?.totalTokens == 40)
  for (result, id) in [(paused, "first"), (finished, "second")] {
    #expect(result.transcript.filter { $0.role == .user }.map(\.text) == ["\(id) task"])
    #expect(result.transcript.flatMap(\.toolResults).map(\.text) == ["echo: \(id)"])
  }
}

@Test("A settings change during one sequential tool applies to the next call in that reply")
func sequentialToolBatchRefreshesSettings() async throws {
  let provider = RecoveryProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(ToolCall(id: "change", name: "change", arguments: .object([:]))),
          .toolCall(
            ToolCall(id: "echo", name: "echo", arguments: .object(["text": .string("blocked")]))),
        ]), stopReason: .toolCall),
    textReply("finished"),
  ])
  let runtime = AgentRuntime()
  let request = AgentRequest(
    provider: "recovery", messages: [.user("work")], toolNames: ["change", "echo"], retry: .none)
  try await runtime.register(provider)
  try await runtime.register(tool: echoTool())
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "change", description: "Change settings",
        annotations: ToolAnnotations(approval: .automatic))
    ) { _, context in
      var updated = request
      updated.toolNames = ["change"]
      let pid = try #require(context.run.pid)
      #expect(await runtime.reconfigure(pid, with: updated))
      return ToolOutput(text: "settings changed")
    })
  let result = try await runtime.run(request)
  let outputs = result.transcript.flatMap(\.toolResults)
  #expect(outputs.map(\.callID) == ["change", "echo"])
  #expect(outputs[0].text == "settings changed" && !outputs[0].isError)
  #expect(outputs[1].isError && outputs[1].text.contains("not available to this agent"))
  #expect(result.toolCalls == 2 && result.response.text == "finished")
  let next = try #require(await provider.requests.last)
  #expect(next.tools.map(\.name) == ["change"])
}

private actor InterleavedRunProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "interleaved", displayName: "Interleaved fixture", capabilities: [.nativeToolCalling])
  private var started: Set<String> = []

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    let id = request.sessionID ?? "missing"
    var response: ProviderResponse
    if started.insert(id).inserted {
      let deadline = ContinuousClock.now + .seconds(2)
      while started.count < 2 {
        guard ContinuousClock.now < deadline else { throw RecoveryTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
      }
      response = echoCall(id)
    } else {
      response = textReply("\(id) finished")
    }
    response.usage = TokenUsage(
      inputTokens: 1, outputTokens: 1, totalTokens: id == "first" ? 10 : 20)
    return response
  }
}

// Long tasks used to die with "Agent run exceeded its model turns limit" and
// lose everything the run had done. These tests pin down the replacement: a
// limit pauses the run at a turn boundary with a transcript that can be run
// again, model calls are retried, children queue for a slot instead of being
// refused, and a conversation past a token threshold is summarized in place.

@Test("The model turn limit pauses a run at a boundary it can be continued from")
func modelTurnLimitPausesRun() async throws {
  let provider = RecoveryProvider(responses: [
    echoCall("c1"), echoCall("c2"), echoCall("c3"), textReply("finished"),
  ])
  let recorder = RecoveryEventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllRecoveryApprovals())
  try await runtime.register(provider)
  try await runtime.register(tool: echoTool())

  let paused = try await runtime.run(
    AgentRequest(
      provider: "recovery",
      model: "fixture",
      messages: [.user("start")],
      toolNames: ["echo"],
      limits: AgentRunLimits(maxModelTurns: 2),
      retry: .none)
  ) { event in
    await recorder.append(event)
  }

  #expect(paused.interruption == .modelTurns(limit: 2))
  #expect(!paused.isComplete)
  #expect(paused.modelTurns == 2)
  #expect(paused.toolCalls == 2)
  // The pause lands after the tool results, never between a call and its
  // answer, so the transcript is still one a provider accepts.
  #expect(paused.transcript.last?.role == .tool)
  #expect(paused.transcript.count == 5)
  let pid = try #require(
    await runtime.supervisor.tree().processes.first { $0.runID == paused.runID }?.pid)
  let info = try #require(await runtime.supervisor.info(pid))
  #expect(info.state == .interrupted)
  #expect(info.failure == "model turn limit (2) reached")
  let events = await recorder.events
  #expect(
    events.contains {
      if case .finished(_, let result) = $0 { return result.interruption != nil }
      return false
    })

  // Running the paused transcript again, on the same process, carries on
  // with a fresh budget: one more tool call, then the answer.
  let resumed = try await runtime.run(
    AgentRequest(
      provider: "recovery",
      model: "fixture",
      messages: paused.transcript,
      toolNames: ["echo"],
      limits: AgentRunLimits(maxModelTurns: 2),
      retry: .none),
    process: pid)
  #expect(resumed.isComplete)
  #expect(resumed.response.text == "finished")
  #expect(resumed.transcript.count == 8)
  #expect(await runtime.supervisor.info(pid)?.state == .completed)
  let requests = await provider.requests
  #expect(requests.count == 4)
  #expect(requests[2].messages.map { $0.id } == paused.transcript.map { $0.id })
}

@Test("The token budget stops the next model call instead of failing the run")
func tokenBudgetPausesRun() async throws {
  let usage = TokenUsage(inputTokens: 40, outputTokens: 20)
  let provider = RecoveryProvider(responses: [
    ProviderResponse(message: echoCall("c1").message, usage: usage, stopReason: .toolCall),
    ProviderResponse(message: .assistant("never sent"), usage: usage, stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: echoTool())

  let paused = try await runtime.run(
    AgentRequest(
      provider: "recovery",
      model: "fixture",
      messages: [.user("start")],
      toolNames: ["echo"],
      limits: AgentRunLimits(maxTotalTokens: 50),
      retry: .none))

  #expect(paused.interruption == .totalTokens(limit: 50))
  #expect(paused.modelTurns == 1)
  #expect(paused.transcript.last?.role == .tool)
  #expect(await provider.requests.count == 1)
}

@Test("The time limit cuts a model call short and pauses with the transcript intact")
func timeLimitPausesRun() async throws {
  let provider = RecoveryProvider(responses: [textReply("late")], delay: .seconds(10))
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let clock = ContinuousClock()
  let started = clock.now

  let paused = try await runtime.run(
    AgentRequest(
      provider: "recovery",
      model: "fixture",
      messages: [.user("slow")],
      limits: AgentRunLimits(maxSeconds: 1),
      retry: .none))

  #expect(clock.now - started < .seconds(5))
  #expect(paused.interruption == .time(limitSeconds: 1))
  #expect(paused.interruption?.summary == "time limit (1s) reached")
  #expect(paused.transcript.map(\.id) == [paused.transcript[0].id])
  #expect(paused.transcript.first?.text == "slow")
  #expect(paused.modelTurns == 1)
  #expect(!paused.interruption!.isCheckpoint)
  #expect(AgentRunInterruption.modelTurns(limit: 3).isCheckpoint)
}

@Test("Failed model calls are retried under the agent's policy")
func retryRepeatsFailedCalls() async throws {
  let provider = RecoveryProvider(responses: [textReply("ok")], failuresBeforeSuccess: 2)
  let recorder = RecoveryEventRecorder()
  let runtime = AgentRuntime()
  try await runtime.register(provider)

  let result = try await runtime.run(
    AgentRequest(
      provider: "recovery",
      model: "fixture",
      messages: [.user("flaky")],
      retry: AgentRetryPolicy(attempts: 2, delaySeconds: 0))
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "ok")
  #expect(result.modelTurns == 1)
  #expect(await provider.requests.count == 3)
  let retries = await recorder.events.compactMap { event -> (Int, Int, String)? in
    guard case .retrying(_, let attempt, let limit, _, let error) = event else { return nil }
    return (attempt, limit, error)
  }
  #expect(retries.map(\.0) == [1, 2])
  #expect(retries.map(\.1) == [2, 2])
  #expect(retries.first?.2.contains("flaky") == true)

  // One failure too many is the provider's error, not a limit.
  let stubborn = RecoveryProvider(responses: [textReply("ok")], failuresBeforeSuccess: 2)
  let strict = AgentRuntime()
  try await strict.register(stubborn)
  await #expect(throws: RecoveryTestError.flaky) {
    try await strict.run(
      AgentRequest(
        provider: "recovery",
        model: "fixture",
        messages: [.user("flaky")],
        retry: AgentRetryPolicy(attempts: 1, delaySeconds: 0)))
  }
  #expect(await stubborn.requests.count == 2)
}

@Test("A child past the subagent limit waits in the queue and starts when a slot frees up")
func queuedChildrenStartWhenSlotFrees() async throws {
  let parentProvider = RecoveryProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(startCall("s1", task: "first")),
          .toolCall(startCall("s2", task: "second")),
        ]),
      stopReason: .toolCall),
    textReply("Both handed out"),
    // The run holds for both background children and asks once more with
    // the two answers delivered.
    textReply("Both delivered"),
  ])
  let childProvider = SlowChildProvider()
  let recorder = RecoveryEventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllRecoveryApprovals())
  try await runtime.register(parentProvider)
  try await runtime.register(childProvider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "worker",
      instructions: "Work.",
      provider: "slow-child",
      model: "fixture",
      retry: .none))

  let result = try await runtime.run(
    AgentRequest(
      provider: "recovery",
      model: "fixture",
      messages: [.user("delegate twice")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["worker"],
      limits: AgentRunLimits(maxSubagents: 1, maxSubagentDepth: 1),
      retry: .none)
  ) { event in
    await recorder.append(event)
  }

  #expect(result.transcript.contains { $0.role == .assistant && $0.text == "Both handed out" })
  #expect(result.response.text == "Both delivered")
  let starts = result.transcript.flatMap(\.toolResults)
  #expect(starts.count == 2)
  #expect(!starts[1].isError)
  #expect(starts[0].structuredContent?.objectValue?["status"] == .string("running"))
  #expect(starts[1].structuredContent?.objectValue?["status"] == .string("queued"))
  #expect(starts[1].text.hasPrefix("Queued worker as"))
  let firstPID = try #require(
    starts[0].structuredContent?.objectValue?["pid"]?.stringValue.flatMap(AgentPID.init(text:)))
  let secondPID = try #require(
    starts[1].structuredContent?.objectValue?["pid"]?.stringValue.flatMap(AgentPID.init(text:)))
  // Both answers were delivered before the run ended, so neither is live.
  #expect(await runtime.supervisor.info(secondPID)?.isCollected == true)
  #expect(!(await runtime.supervisor.liveProcesses().contains { $0.pid == secondPID }))

  try await waitForRecovery(timeout: .seconds(5)) {
    let first = await runtime.supervisor.info(firstPID)?.state
    let second = await runtime.supervisor.info(secondPID)?.state
    return first == .completed && second == .completed
  }
  #expect(await runtime.supervisor.result(secondPID)?.response.text == "Child text")
  let events = await recorder.events
  let queued = events.compactMap { event -> AgentPID? in
    guard case .childQueued(_, let child) = event else { return nil }
    return child.pid
  }
  let started = events.compactMap { event -> AgentPID? in
    guard case .childStarted(_, let child) = event else { return nil }
    return child.pid
  }
  #expect(queued == [secondPID])
  #expect(started == [firstPID, secondPID])
  // The second child only ran once the first was out of the way.
  let order = await childProvider.startedAt
  #expect(order.count == 2)
  #expect(order[1] >= order[0] + .milliseconds(100))
}

@Test("Autocompact folds the older exchanges once the conversation is past the threshold")
func autocompactFoldsOlderMessages() async throws {
  let usage = TokenUsage(inputTokens: 1_000, outputTokens: 10)
  let provider = RecoveryProvider(
    responses: [
      ProviderResponse(message: echoCall("c1").message, usage: usage, stopReason: .toolCall),
      ProviderResponse(message: echoCall("c2").message, usage: usage, stopReason: .toolCall),
      ProviderResponse(message: .assistant("done"), usage: usage, stopReason: .stop),
    ],
    summary: "Compacted state")
  let recorder = RecoveryEventRecorder()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: echoTool())

  let result = try await runtime.run(
    AgentRequest(
      provider: "recovery",
      model: "fixture",
      messages: [.user("start")],
      toolNames: ["echo"],
      retry: .none,
      autocompact: AgentAutocompact(tokens: 500, preserveRecentTokens: 0))
  ) { event in
    await recorder.append(event)
  }

  #expect(result.isComplete)
  #expect(result.response.text == "done")
  // The first tool exchange became a summary. The user's request and the
  // exchange the model had not acted on yet stayed verbatim.
  #expect(result.transcript.count == 5)
  #expect(result.transcript[0].role == .user)
  #expect(result.transcript[1].text == "start")
  #expect(result.transcript[0].text.hasPrefix("Summary of earlier parts of this conversation"))
  #expect(result.transcript[0].text.hasSuffix("Compacted state"))
  #expect(result.transcript[2].toolCalls.first?.id == "c2")
  let events = await recorder.events
  let compactions = events.compactMap { event -> Int? in
    guard case .compactionStarted(_, let estimated) = event else { return nil }
    return estimated
  }
  #expect(compactions == [1_012])
  let edits = events.compactMap { event -> AgentTranscriptEditReport? in
    guard case .transcriptEdited(_, let report) = event else { return nil }
    return report
  }
  #expect(edits.count == 1)
  #expect(edits.first?.compacted == 2)
  let requests = await provider.requests
  #expect(requests.count == 4)
  let compaction = try #require(requests.first { $0.tools.isEmpty && $0.messages.count == 1 })
  let prompt = compaction.messages[0].text
  #expect(prompt.contains("Compact the transcript"))
  #expect(prompt.contains("This compaction runs automatically"))
  #expect(prompt.contains("[tool call echo"))
  #expect(!prompt.contains("c2"))
  #expect(requests.last?.messages.count == 4)
  #expect(requests.last?.messages.contains { $0.text.hasSuffix("Compacted state") } == true)
}

@Test("Autocompact leaves the newest exchange alone and needs something to fold")
func autocompactSelection() {
  let user = AgentMessage.user("hello")
  let tail = echoCall("c1").message
  let toolResult = AgentMessage(
    role: .tool, content: [.toolResult(ToolResult(callID: "c1", text: "x"))])
  #expect(AgentAutocompaction.selection(in: [.system("sys"), user, tail, toolResult]) == nil)
  let older = echoCall("c0").message
  let olderResult = AgentMessage(
    role: .tool, content: [.toolResult(ToolResult(callID: "c0", text: "y"))])
  let selection = AgentAutocompaction.selection(
    in: [.system("sys"), user, older, olderResult, tail, toolResult], preservingRecentTokens: 0)
  #expect(selection == [older.id, olderResult.id])
  #expect(
    AgentAutocompaction.estimatedTokens(
      of: [user], lastUsage: TokenUsage(inputTokens: 300, outputTokens: 7)) == 307)
}

@Test("A transcript cut off inside a tool exchange is answered so it can be run again")
func unansweredToolCallsAreSettled() {
  let call = echoCall("c1").message
  let earlier = echoCall("c0").message
  let earlierResult = AgentMessage(
    role: .tool, content: [.toolResult(ToolResult(callID: "c0", text: "done"))])
  let cut = [AgentMessage.user("go"), earlier, earlierResult, call]
  let repaired = AgentTranscriptEditor.answeringUnansweredToolCalls(
    in: cut, reason: "the run was cancelled")
  #expect(repaired.count == 5)
  #expect(repaired[4].role == .tool)
  let result = repaired[4].toolResults.first
  #expect(result?.callID == "c1")
  #expect(result?.isError == true)
  #expect(result?.text == "Error: not executed; the run was cancelled.")
  // A transcript that ends cleanly is left alone.
  #expect(
    AgentTranscriptEditor.answeringUnansweredToolCalls(in: Array(cut.prefix(3)), reason: "x")
      == Array(cut.prefix(3)))
}

@Test("Run limits, retry, and autocompact settings survive the configuration file")
func recoverySettingsRoundTrip() throws {
  let definition = AgentDefinition(
    id: "worker",
    instructions: "Work.",
    provider: "p",
    model: "m",
    limits: AgentRunLimits(maxModelTurns: 80, maxSeconds: 600),
    retry: AgentRetryPolicy(attempts: 3, delaySeconds: 2.5),
    autocompact: AgentAutocompact(tokens: 120_000))
  let data = try JSONEncoder().encode(definition)
  let decoded = try JSONDecoder().decode(AgentDefinition.self, from: data)
  #expect(decoded == definition)
  #expect(decoded.limits.maxSeconds == 600)

  let minimal = try JSONDecoder().decode(
    AgentDefinition.self, from: Data(#"{"id":"a","provider":"p"}"#.utf8))
  #expect(minimal.retry == AgentRetryPolicy(attempts: 2, delaySeconds: 5))
  #expect(minimal.autocompact == AgentAutocompact())
  #expect(minimal.autocompact.isEnabled)
  #expect(minimal.autocompact.tokens == 64_000)
  #expect(minimal.limits.maxSeconds == nil)
  #expect(minimal.toolCallingStrategy == .automatic)
  #expect(definition.toolCallingStrategy == .automatic)
  #expect(AgentRequest(provider: "p", model: "m", messages: []).toolCallingStrategy == .automatic)
  let explicit = try JSONDecoder().decode(
    AgentDefinition.self,
    from: Data(#"{"id":"a","provider":"p","toolCallingStrategy":"native"}"#.utf8))
  #expect(explicit.toolCallingStrategy == .native)
  #expect(AgentRunLimits(maxSeconds: 0).maxSeconds == nil)
  #expect(AgentProcessState.queued.shortLabel == "queued")
  #expect(AgentProcessState.interrupted.isTerminal)
  #expect(!AgentProcessState.queued.isTerminal)
}

// MARK: - Fixtures

private func echoTool() -> ClosureTool {
  ClosureTool(
    definition: ToolDefinition(
      name: "echo",
      description: "Echo",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
      ]),
      annotations: ToolAnnotations(approval: .automatic))
  ) { arguments, _ in
    ToolOutput(text: "echo: \(arguments.objectValue?["text"]?.stringValue ?? "")")
  }
}

private func textReply(_ text: String) -> ProviderResponse {
  ProviderResponse(message: .assistant(text), stopReason: .stop)
}

private func echoCall(_ id: String) -> ProviderResponse {
  ProviderResponse(
    message: AgentMessage(
      role: .assistant,
      content: [
        .toolCall(ToolCall(id: id, name: "echo", arguments: .object(["text": .string(id)])))
      ]),
    stopReason: .toolCall)
}

private func startCall(_ id: String, task: String) -> ToolCall {
  ToolCall(
    id: id,
    name: AgentRuntime.agentStartToolName,
    arguments: .object([
      "agent": .string("worker"),
      "task": .string(task),
      "output": .string("one line"),
      "wait": .bool(false),
    ]))
}

private func waitForRecovery(
  timeout: Duration,
  _ condition: @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while await !condition() {
    guard clock.now < deadline else { throw RecoveryTestError.timedOut }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private enum RecoveryTestError: LocalizedError, Equatable {
  case flaky
  case missingResponse
  case timedOut

  var errorDescription: String? {
    switch self {
    case .flaky: "flaky connection"
    case .missingResponse: "no scripted response left"
    case .timedOut: "timed out waiting for the condition"
    }
  }
}

private struct AllowAllRecoveryApprovals: ApprovalHandler {
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .approve(arguments: request.call.arguments)
  }
}

private actor RecoveryEventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

/// Plays scripted responses, optionally failing first, sleeping before each
/// answer, and answering a compaction prompt with a fixed summary.
private actor RecoveryProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "recovery",
    displayName: "Recovery fixture",
    capabilities: [.streaming, .nativeToolCalling])
  private var responses: [ProviderResponse]
  private var failures: Int
  private let delay: Duration?
  private let summary: String?
  private(set) var requests: [ProviderRequest] = []

  init(
    responses: [ProviderResponse],
    failuresBeforeSuccess: Int = 0,
    delay: Duration? = nil,
    summary: String? = nil
  ) {
    self.responses = responses
    failures = failuresBeforeSuccess
    self.delay = delay
    self.summary = summary
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    if let summary, request.tools.isEmpty, request.messages.count == 1,
      request.messages[0].text.hasPrefix("Compact")
    {
      return ProviderResponse(message: .assistant(summary), stopReason: .stop)
    }
    if failures > 0 {
      failures -= 1
      throw RecoveryTestError.flaky
    }
    if let delay { try await Task.sleep(for: delay) }
    guard !responses.isEmpty else { throw RecoveryTestError.missingResponse }
    let response = responses.removeFirst()
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}

/// A child that takes a moment, so a sibling started meanwhile has to queue.
private actor SlowChildProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "slow-child",
    displayName: "Slow child fixture",
    capabilities: [.streaming, .nativeToolCalling])
  private(set) var startedAt: [ContinuousClock.Instant] = []

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    startedAt.append(ContinuousClock.now)
    try await Task.sleep(for: .milliseconds(150))
    await emit(.textDelta("Child text"))
    return ProviderResponse(message: .assistant("Child text"), stopReason: .stop)
  }
}
