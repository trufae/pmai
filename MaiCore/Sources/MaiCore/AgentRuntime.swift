import Foundation

/// UI-independent orchestration for providers, tools, approvals, MCP tools,
/// and bounded child-agent runs. Hosts own presentation and persistence and
/// observe work through `AgentEvent` values and the shared `AgentSupervisor`.
public actor AgentRuntime {
  // Support extensions share this actor-isolated state. Internal access
  // avoids forwarding accessors; none of it is part of the public API.
  var providers: [ProviderID: any ChatProvider] = [:]
  var tools: [String: any AgentTool] = [:]
  var agents: [String: AgentDefinition] = [:]
  /// The operational part of every request currently running. Transcripts
  /// stay local to their run; hosts may replace these settings between model
  /// and tool calls without cancelling the work already in flight.
  var liveRequests: [AgentPID: AgentRequest] = [:]
  var derivedRuns: [AgentPID: DerivedRun] = [:]
  var runBudgets: [AgentPID: RunBudget] = [:]
  /// Covers the tiny interval after a host starts a task but before the run
  /// has installed its request in this actor.
  var pendingReconfigurations: [AgentPID: AgentRequest] = [:]
  var registeredMCPs: [String: RegisteredMCP] = [:]
  var configuredToolGroups: [ToolGroupDefinition] = []
  let approvalHandler: any ApprovalHandler
  /// Overrides for the delegation brief and the derived worker's instructions.
  /// Nil keeps the built-in text, so MaiCore works without configuration.
  var delegationTemplate: String?
  var workerInstructions: String?
  var plansBeforeDelegating = false
  /// The compaction prompt autocompact renders; nil keeps the built-in one.
  var compactionTemplate: String?
  var smartContextTemplate: String?
  var taskAgents = TaskAgentAssignments()
  /// Durable notes added to the system prompt of top-level runs. A child agent
  /// grepping a file does not need the user's standing preferences, so this
  /// never reaches one.
  var memorySection: String?
  var instructionsSection: String?
  var instructionsDirectory: URL?
  var instructionContexts: [String: AgentInstructionsContext] = [:]
  var toolUsageStore: AgentToolUsageStore?
  var toolUsage = AgentToolUsage()
  /// Where completed provider calls' tokens and timing are folded in.
  /// Nil disables usage recording.
  var usageStats: ModelUsageStore?
  var debugLog: AgentDebugLog?

  /// The process table every run reports into. Hosts read it for `/jobs`,
  /// follow its events for notifications, and stop subtrees through it.
  public nonisolated let supervisor: AgentSupervisor

  public init(
    approvalHandler: any ApprovalHandler = DenyInteractiveApprovals(),
    supervisor: AgentSupervisor = AgentSupervisor()
  ) {
    self.approvalHandler = approvalHandler
    self.supervisor = supervisor
  }

  public func run(
    agentID: String,
    messages: [AgentMessage],
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    guard let definition = agents[agentID] else {
      throw AgentRuntimeError.agentNotRegistered(agentID)
    }
    let request = request(for: definition, messages: messages)
    return try await run(request, emit: emit)
  }

  /// Registers an idle top-level process for a conversation before any turn
  /// runs, so a host can queue messages for it and pass its pid to `run`.
  public func allocateProcess(agentID: String, task: String = "") async -> AgentPID {
    await supervisor.register(
      runID: UUID(),
      parent: nil,
      agentID: agentID,
      displayName: agentID,
      task: task,
      depth: 0)
  }

  /// Runs one turn. Pass the pid an earlier turn returned as `process` to keep
  /// a conversation's identity — and the background children it started —
  /// across turns; a stale or omitted pid starts a fresh process.
  @discardableResult
  public func run(
    _ request: AgentRequest,
    process: AgentPID? = nil,
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    let budget = RunBudget(limits: request.limits)
    let runID = UUID()
    let task = AgentProcessInfo.oneLine(
      request.messages.last { $0.role == .user }?.text ?? "", limit: 60)
    let pid: AgentPID
    if let process, await supervisor.reopen(process, runID: runID, task: task) {
      pid = process
    } else {
      pid = await supervisor.register(
        runID: runID,
        parent: nil,
        agentID: request.agentID,
        displayName: request.agentID,
        task: task,
        depth: 0)
    }
    do {
      let result = try await runInternal(
        request,
        runID: runID,
        pid: pid,
        parentRunID: nil,
        depth: 0,
        budget: budget,
        emit: emit)
      await supervisor.finish(pid, result: result, announce: false)
      return result
    } catch is CancellationError {
      await supervisor.fail(pid, state: .cancelled, message: "Cancelled", announce: false)
      await debugLog?.record("run.cancelled", value: runID)
      throw CancellationError()
    } catch {
      await supervisor.fail(
        pid, state: .failed, message: error.localizedDescription, announce: false)
      await debugLog?.record("run.error", value: "\(runID): \(error.localizedDescription)")
      throw error
    }
  }

  /// Where a paused run waits. A person pauses through the supervisor while
  /// the run is inside a model call or a tool; it gets here at the next
  /// boundary and stays until it is resumed or stopped.
  func holdWhilePaused(_ pid: AgentPID) async throws {
    guard await supervisor.isPaused(pid) else { return }
    // "thinking" or a tool name would describe work that is not happening.
    await supervisor.note(pid, activity: "")
    while await supervisor.isPaused(pid) {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  func runInternal(
    _ initialRequest: AgentRequest,
    runID: UUID,
    pid: AgentPID,
    parentRunID: UUID?,
    depth: Int,
    budget: RunBudget,
    derivedFrom: DerivedRun? = nil,
    registeredAgent: Bool = false,
    emit downstream: @escaping AgentEventHandler
  ) async throws -> AgentResult {
    let emit: AgentEventHandler = { event in
      if depth == 0 { await self.recordDebugEvent(event) }
      await downstream(event)
    }
    try Task.checkCancellation()
    if liveRequests[pid] == nil {
      var installed = initialRequest
      if registeredAgent, let definition = agents[initialRequest.agentID] {
        installed.applyRuntimeSettings(from: definition)
      }
      if let pending = pendingReconfigurations.removeValue(forKey: pid) {
        installed.applyRuntimeSettings(from: pending)
      }
      liveRequests[pid] = installed
    }
    if let derivedFrom { derivedRuns[pid] = derivedFrom }
    runBudgets[pid] = budget
    defer {
      clearLiveRequest(for: pid)
    }
    let request = currentRequest(initialRequest, for: pid)
    guard let initialProvider = providers[request.provider] else {
      throw AgentRuntimeError.providerNotRegistered(request.provider)
    }

    let context = AgentEventContext(
      runID: runID,
      parentRunID: parentRunID,
      agentID: request.agentID,
      depth: depth,
      pid: pid)
    var state = RunState(
      request, context: context, pid: pid, budget: budget,
      activeTaskID: await supervisor.beginActiveTask(in: request.messages, for: pid), emit: emit)
    await emit(.started(context, initialProvider.descriptor))
    await supervisor.note(pid, state: .running, transcript: state.transcript)
    while true {
      try Task.checkCancellation()
      try await holdWhilePaused(pid)
      state.request = currentRequest(state.request, for: pid)
      await budget.update(limits: state.request.limits)
      do {
        try await applyPendingInput(to: &state)
        if try await autocompact(&state) { continue }
        state.request = currentRequest(state.request, for: pid)
        await budget.update(limits: state.request.limits)
        let concreteDefinitions = try visibleDefinitions(for: state.request, depth: depth)
        let definitions = ToolProxy.definitions(
          for: concreteDefinitions,
          exposing: exposedTools(in: concreteDefinitions, request: state.request))
        if state.modelTurns >= state.request.limits.maxModelTurns {
          return await finishRun(
            state, interruption: .modelTurns(limit: state.request.limits.maxModelTurns))
        }
        if let interruption = await budget.exhausted() {
          return await finishRun(state, interruption: interruption)
        }
        let turn = try await prepareTurn(
          concreteDefinitions: concreteDefinitions, definitions: definitions, state: &state)
        // Context preparation spends tokens too; claim only conversation turns.
        if let interruption = await budget.claimModelTurn() {
          return await finishRun(state, interruption: interruption)
        }
        guard let call = try await callProvider(turn, state: &state),
          let response = try await interpretResponse(call, turn: turn, state: &state)
        else { continue }
        let calls = response.message.toolCalls.filter { !$0.name.isEmpty }
        if !calls.isEmpty {
          try await executeToolBatch(calls, state: &state)
          continue
        }
        // Queued input and background children give an answer one more turn,
        // unless its allowance is spent; then their messages stay for the host.
        if state.modelTurns < state.request.limits.maxModelTurns,
          await budget.exhausted() == nil,
          try await AgentProcessTools.awaitChildren(
            of: pid, supervisor: supervisor, excluding: state.request.ignoredQueuedMessageIDs)
        {
          continue
        }
        return await finishRun(state, response: response)
      } catch is RunDeadlineExceeded {
        return await finishRun(state, interruption: await budget.timeInterruption)
      }
    }
  }

  private func finishRun(
    _ state: RunState, response: ProviderResponse? = nil,
    interruption: AgentRunInterruption? = nil
  ) async -> AgentResult {
    // A pause reports only this run's own assistant output, not an old answer.
    let result = AgentResult(
      runID: state.context.runID, agentID: state.request.agentID, provider: state.request.provider,
      response: response?.message
        ?? state.transcript.dropFirst(state.request.messages.count).last { $0.role == .assistant }
        ?? .assistant(""),
      transcript: state.transcript,
      usage: state.totalUsage.merging(await state.budget.approvalUsage),
      stopReason: response?.stopReason ?? .unknown,
      modelTurns: state.modelTurns + (await state.budget.approvalTurns),
      toolCalls: state.toolCalls, interruption: interruption)
    await state.emit(.finished(state.context, result))
    return result
  }

  static let toolBudgetExhaustedPrompt =
    "The tool call budget for this run is exhausted and no tools are available anymore. Do not call tools; give the final answer using the information already gathered."
  static let repeatedCallPrompt =
    "The last turns made no progress: tool calls repeated or could not be parsed, or no reply was produced. No tools are available anymore. Do not call tools; give the final answer using the information already gathered, and say what could not be done."
  /// Consecutive empty or malformed replies before tools are withdrawn.
  static let maximumRepairAttempts = 3

  /// How often one call may run with exactly the same arguments in one run
  /// before it is refused as a loop.
  static let maximumIdenticalCalls = 3

  /// The user messages a turn was started with: everything after the last
  /// assistant reply.
  static func trailingUserMessages(in messages: [AgentMessage]) -> [AgentMessage] {
    var trailing: [AgentMessage] = []
    for message in messages.reversed() {
      if message.role == .assistant { break }
      if message.role == .user { trailing.append(message) }
    }
    return trailing
  }

}
