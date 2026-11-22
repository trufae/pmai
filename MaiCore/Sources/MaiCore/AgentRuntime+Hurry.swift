import Foundation

extension AgentRuntime {
  struct HurryRequested: Error {}

  static let hurryPrompt = """
    We are late. Stop calling tools now: do not run more tests, do more research, or start more agents. Collect the information and results already available and finish the current task in the most efficient and correct way possible without calling more tools. Use brief reasoning, report what was completed, and clearly state any remaining gaps instead of claiming unperformed work is done.
    """

  /// Interrupts current operations, not the runs that own their transcripts.
  /// Repeating the command leaves the final answers already in flight alone.
  @discardableResult
  public func hurry(processes roots: [AgentPID]? = nil) async -> [AgentPID] {
    let tree = await supervisor.tree()
    let candidates = roots.map { roots in
      roots.flatMap { tree.subtree(of: $0) }
    } ?? tree.processes
    // Allocated conversations can be idle in `starting` before their first run.
    let targets = Set(candidates.filter {
      !$0.state.isTerminal && ($0.state != .starting || liveRequests[$0.pid] != nil)
    }.map(\.pid))
    let added = targets.subtracting(hurriedRuns)
    hurriedRuns.formUnion(targets)
    for pid in added {
      for cancel in hurryInterrupts[pid]?.values ?? [:].values { cancel() }
    }
    for pid in added {
      _ = await supervisor.postIfRunning(.user(Self.hurryPrompt), to: pid)
      _ = await supervisor.resume(pid)
    }
    return targets.sorted { $0.rawValue < $1.rawValue }
  }

  /// An unstructured operation can be interrupted while its owning turn
  /// stays alive to collect results. Parent cancellation still propagates.
  func withHurryInterrupt<Value: Sendable>(
    for pid: AgentPID,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let id = UUID()
    let alreadyHurried = hurriedRuns.contains(pid)
    let task = Task { try await operation() }
    if !alreadyHurried { hurryInterrupts[pid, default: [:]][id] = { task.cancel() } }
    defer {
      hurryInterrupts[pid]?[id] = nil
      if hurryInterrupts[pid]?.isEmpty == true { hurryInterrupts[pid] = nil }
    }
    do {
      return try await withTaskCancellationHandler {
        let value = try await task.value
        try Task.checkCancellation()
        return value
      } onCancel: {
        task.cancel()
      }
    } catch {
      try Task.checkCancellation()
      if !alreadyHurried, task.isCancelled, hurriedRuns.contains(pid) {
        throw HurryRequested()
      }
      throw error
    }
  }

  func hurryOptions(_ options: GenerationOptions) -> GenerationOptions {
    var options = options
    switch options.reasoningEffort.flatMap(ReasoningEffort.init(name:)) {
    case .disabled?, .minimal?: break
    default: options.reasoningEffort = ReasoningEffort.low.rawValue
    }
    options.reasoningGuidance = Self.hurryPrompt
    // Raw provider fields otherwise take precedence over the effort setting.
    for key in ["reasoning_effort", "reasoning", "thinking", "think", "thinking_budget",
      "enable_thinking", "chat_template_kwargs", "tools", "tool_choice"] {
      options.additional[key] = nil
    }
    return options
  }

  func executeHurryAware(
    _ call: ToolCall, definitions: [ToolDefinition], request: AgentRequest,
    execution: ToolExecutionContext, budget: RunBudget,
    launched: @escaping @Sendable () -> Void = {}, emit: @escaping AgentEventHandler
  ) async throws -> ToolResult {
    let context = execution.run
    let operation: @Sendable () async throws -> ToolResult = {
      try await self.execute(call, definitions: definitions, request: request,
        execution: execution, budget: budget, launched: launched, emit: emit)
    }
    guard let pid = context.pid else { return try await operation() }
    if hurriedRuns.contains(pid) {
      launched()
      return await fail(call, "skipped by /hurry; no more tools may run for this task.", parent: context, emit: emit)
    }
    // Collecting an already running child must not cancel that child's
    // final answer. Each child receives its own hurry interruption.
    if AgentProcessTools.isAgentTool(call.name) {
      return try await operation()
    }
    do {
      return try await withHurryInterrupt(for: pid, operation: operation)
    } catch is HurryRequested {
      launched()
      return await fail(call, "interrupted by /hurry; finish using the available information without more tools.", parent: context, emit: emit)
    }
  }
}
