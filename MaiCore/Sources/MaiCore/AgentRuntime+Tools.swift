import Foundation

extension AgentRuntime {
  private func reviewToolApproval(
    _ approval: ApprovalRequest, request: AgentRequest,
    budget: RunBudget, emit: @escaping AgentEventHandler
  ) async throws -> ApprovalDecision {
    do {
      guard let pid = approval.run.pid else {
        return .deny(reason: "Approval review has no run context.")
      }
      let transcript = await supervisor.transcript(pid)
      let environment =
        try tools[approval.tool.name]?.approvalEnvironment(arguments: approval.call.arguments)
        ?? ToolApprovalEnvironment.current
      let review = ToolApprovalReview(
        tool: approval.tool, arguments: approval.call.arguments,
        task: transcript.last(where: { $0.role == .user })?.text
          ?? request.messages.last(where: { $0.role == .user })?.text ?? "",
        environment: environment)
      let inference = try taskRequest(.approval, from: request)
      func evaluate(_ selected: AgentRequest) async throws -> ApprovalDecision {
        var inference = selected
        guard let provider = providers[inference.provider] else {
          throw AgentRuntimeError.providerNotRegistered(inference.provider)
        }
        inference.model = resolvedModel(inference.model, for: provider)
        if let interruption = await budget.claimModelTurn() {
          return .deny(reason: "Approval review cannot run: \(interruption).")
        }
        await budget.noteApprovalTurn()
        let providerRequest = SmartToolApproval.request(
          review: review, model: inference.model,
          options: inference.options, sessionID: request.sessionID,
          additionalInstructions: taskAgents.approval.flatMap { agents[$0]?.instructions } ?? "")
        let call = try await complete(
          providerRequest, with: provider, retry: inference.retry,
          budget: budget, context: approval.run, pid: pid, emit: emit
        ) { _ in }
        let usage = call.usage(for: providerRequest.messages)
        await budget.recordApproval(usage)
        await recordModelCall(call, provider: provider.descriptor.id, request: providerRequest)
        return SmartToolApproval.decision(call.response, arguments: approval.call.arguments)
      }
      do { return try await evaluate(inference) } catch is ToolApprovalUnavailable {
        guard let primary = providers[request.provider],
          !primary.descriptor.capabilities.contains(.toolDecision)
        else {
          return .deny(
            reason: "System One approval is unavailable and no chat model can review the call.")
        }
        return try await evaluate(request)
      }
    } catch is CancellationError { throw CancellationError() } catch {
      return .deny(reason: "Approval review failed: \(error.localizedDescription)")
    }
  }

  func execute(
    _ call: ToolCall,
    definitions: [ToolDefinition],
    request: AgentRequest,
    execution: ToolExecutionContext,
    budget: RunBudget,
    launched: @escaping @Sendable () -> Void = {},
    emit: @escaping AgentEventHandler
  ) async throws -> ToolResult {
    let context = execution.run
    // A proxied model that names a hidden tool directly still gets it run:
    // the proxy saves tokens, it is not a permission boundary.
    var resolvedCall: ToolCall
    if request.usesToolProxy, call.name == ToolProxy.callName {
      let resolved = ToolProxy.resolveCall(
        arguments: call.arguments.objectValue ?? [:], definitions: definitions)
      guard let target = resolved.call else {
        let result = ToolResult(
          callID: call.id,
          text: resolved.error ?? "Error: invalid proxied tool call.",
          isError: true)
        await emit(.toolFinished(context, result))
        return result
      }
      resolvedCall = ToolCall(
        id: call.id, name: target.name, arguments: .object(target.argumentValues))
    } else {
      resolvedCall = call
    }

    // Legacy names resolve to the definition of the tool that replaced them,
    // and a name the provider could not map (text protocols offer no tools, so
    // its resolver is empty) gets the same alias and glued-suffix treatment.
    let definitionName = AgentProcessTools.canonicalName(resolvedCall.name)
    let isLegacyName = definitionName != resolvedCall.name
    let definition =
      (request.usesToolProxy && definitionName == ToolProxy.listName
        ? ToolProxy.listDefinition(
          for: ToolProxy.hiddenDefinitions(
            in: definitions, exposing: exposedTools(in: definitions, request: request)))
        : nil)
      ?? definitions.first(where: { $0.name == definitionName })
      ?? AgentToolNameResolver(tools: definitions).canonicalName(for: definitionName)
      .flatMap { canonical in definitions.first(where: { $0.name == canonical }) }
    guard let definition else {
      if definitionName == Self.agentStartToolName,
        definitions.contains(where: { $0.name == Self.agentStatusToolName })
      {
        await emit(.toolStarted(context, resolvedCall))
        return await fail(
          resolvedCall,
          request.limits.maxSubagents == 0
            ? "this agent may not start children (limits.maxSubagents is 0)."
            : "the subagent depth limit for this run is reached.",
          parent: context, emit: emit)
      }
      // A call that never runs is still shown, so the person sees what the
      // model tried rather than an error out of nowhere.
      await emit(.toolStarted(context, resolvedCall))
      let result = ToolResult(
        callID: resolvedCall.id,
        text: AgentTooling.unavailableToolError(name: resolvedCall.name, tools: definitions),
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    // Use the resolved name for approval and dispatch as well as validation.
    // Retired agent-start names still select their legacy argument format.
    if !isLegacyName { resolvedCall.name = definition.name }
    resolvedCall.arguments = ToolSchemaValidator.repairArgumentKeys(
      resolvedCall.arguments, definition: definition)
    resolvedCall.arguments = ToolSchemaValidator.coerceBooleans(
      resolvedCall.arguments, schema: definition.inputSchema)
    if !isLegacyName,
      let validationError = ToolSchemaValidator.validate(
        arguments: resolvedCall.arguments,
        definition: definition)
    {
      await emit(.toolStarted(context, resolvedCall))
      return await fail(resolvedCall, "\(validationError).", parent: context, emit: emit)
    }

    let approvedCall: ToolCall
    let approvalMode = await approvalHandler.toolApprovalMode()
    if approvalMode == .yolo
      || (approvalMode == nil && definition.annotations.approval == .automatic)
    {
      approvedCall = resolvedCall
    } else {
      let approval = ApprovalRequest(run: context, tool: definition, call: resolvedCall)
      await emit(.approvalRequested(context, approval))
      if let pid = context.pid { await supervisor.raise(.approval(approval), for: pid) }
      let decision: ApprovalDecision
      do {
        if approvalMode == .smart {
          decision = try await reviewToolApproval(
            approval, request: request, budget: budget, emit: emit)
        } else {
          decision = try await approvalHandler.decide(approval)
        }
      } catch {
        if let pid = context.pid { await supervisor.clearAttention(for: pid) }
        throw error
      }
      if let pid = context.pid { await supervisor.clearAttention(for: pid) }
      await emit(.approvalDecided(context, decision))
      switch decision {
      case .approve(let arguments):
        approvedCall = ToolCall(
          id: resolvedCall.id, name: resolvedCall.name, arguments: arguments)
      case .deny(let reason):
        return await fail(call, "tool call denied. \(reason)", parent: context, emit: emit)
      case .cancelRun:
        throw CancellationError()
      }
    }

    if !isLegacyName,
      let validationError = ToolSchemaValidator.validate(
        arguments: approvedCall.arguments,
        definition: definition)
    {
      return await fail(
        approvedCall, "approved arguments are invalid: \(validationError).",
        parent: context, emit: emit)
    }
    if observeProjectInstructions(
      approvedCall, request: request, context: context), !definition.annotations.readOnly
    {
      await emit(.toolStarted(context, approvedCall))
      let result = ToolResult(
        callID: approvedCall.id,
        text:
          "Additional AGENTS.md instructions apply to this path. Review the new project instructions and repeat the call.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    await emit(.toolStarted(context, approvedCall))
    if definition.name != ToolProxy.listName,
      tools[definition.name] != nil || Self.agentToolNames.contains(definition.name)
    {
      await recordToolUse(definition.name)
    }
    let result: ToolResult
    switch definition.name {
    case ToolProxy.listName where request.usesToolProxy:
      result = ToolResult(
        callID: approvedCall.id,
        text: ToolProxy.listTools(
          arguments: approvedCall.arguments.objectValue ?? [:],
          definitions: ToolProxy.hiddenDefinitions(
            in: definitions, exposing: exposedTools(in: definitions, request: request))))
    case Self.agentStartToolName:
      return await startAgent(
        approvedCall,
        legacyName: resolvedCall.name,
        request: request,
        parent: context,
        depth: context.depth,
        launched: launched,
        emit: emit)
    case Self.agentStatusToolName:
      result = await AgentProcessTools.status(
        arguments: approvedCall.arguments.objectValue ?? [:], callID: approvedCall.id,
        caller: context.pid, supervisor: supervisor)
    case Self.agentResultToolName:
      result = await AgentProcessTools.result(
        arguments: approvedCall.arguments.objectValue ?? [:], callID: approvedCall.id,
        caller: context.pid, supervisor: supervisor)
    case Self.agentStopToolName:
      result = await AgentProcessTools.stop(
        arguments: approvedCall.arguments.objectValue ?? [:], callID: approvedCall.id,
        caller: context.pid, supervisor: supervisor, stoppedBy: context.agentID)
    default:
      guard let tool = tools[approvedCall.name] else {
        return await fail(
          approvedCall, "tool '\(approvedCall.name)' is not registered.",
          parent: context, emit: emit)
      }
      launched()
      do {
        let output = try await tool.call(
          arguments: approvedCall.arguments,
          context: execution)
        result = ToolResult(
          callID: approvedCall.id,
          content: output.content,
          structuredContent: output.structuredContent,
          isError: output.isError,
          importance: definition.annotations.resultImportance)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result = ToolResult(
          callID: approvedCall.id, text: "Error: \(error.localizedDescription)", isError: true)
      }
    }
    await emit(.toolFinished(context, result))
    return result
  }

  func fail(
    _ call: ToolCall,
    _ message: String,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let result = AgentProcessTools.failure(callID: call.id, message)
    await emit(.toolFinished(parent, result))
    return result
  }
  func executeToolBatch(_ calls: [ToolCall], state: inout RunState) async throws {
    let context = state.context
    let depth = context.depth
    let pid = state.pid
    let budget = state.budget
    let emit = state.emit
    // The reply's calls run in order, except that a call to a concurrent
    // tool — the agent family, or any tool that says so — is started and
    // left running while the calls after it start, so children started in
    // one reply work side by side and a blocking start never holds back
    // the rest. The results join the transcript in call order once the
    // last of them is in.
    let modelTurn = state.modelTurns
    let usedTokens = AgentAutocompaction.estimatedTokens(
      of: state.contextMessages,
      lastUsage: state.lastUsage, lastUsageMessageCount: state.lastUsageMessageCount)
    var results = [ToolResult?](repeating: nil, count: calls.count)
    var changesState = [Bool](repeating: false, count: calls.count)
    try await withThrowingTaskGroup(of: (Int, ToolResult).self) { group in
      for (index, call) in calls.enumerated() {
        try Task.checkCancellation()
        try await holdWhilePaused(pid)
        // A prior sequential tool may have taken minutes. Refresh again for
        // every call so commands typed while it ran affect the next one.
        state.request = currentRequest(state.request, for: pid)
        await budget.update(limits: state.request.limits)
        let callRequest = state.request
        let suggestedOutputBytes = ToolExecutionContext.suggestedOutputBytes(
          contextTokens: callRequest.autocompact.tokens, usedTokens: usedTokens,
          toolCalls: calls.count)
        let execution = ToolExecutionContext(
          run: context, modelTurn: modelTurn, suggestedOutputBytes: suggestedOutputBytes)
        let callDefinitions = try visibleDefinitions(for: callRequest, depth: depth)
        let name = AgentProcessTools.canonicalName(call.name)
        let pollable = AgentProcessTools.reservedToolNames.contains(name)
        changesState[index] =
          !pollable
          && callDefinitions.contains { $0.name == name && !$0.annotations.readOnly }
        if await budget.deadlinePassed {
          // Out of time between two calls: the rest are answered rather
          // than run, so the transcript stays sendable and the pause at
          // the top of the loop is clean.
          await emit(.toolStarted(context, call))
          let result = AgentProcessTools.failure(
            callID: call.id,
            "the run's time limit was reached before this call ran; it was not executed.")
          await emit(.toolFinished(context, result))
          results[index] = result
          continue
        }
        guard state.toolCalls < callRequest.limits.maxToolCalls,
          await budget.allowsToolCall(used: state.toolCalls)
        else {
          let result = AgentProcessTools.failure(
            callID: call.id,
            "the tool call budget for this run (\(callRequest.limits.maxToolCalls)) is exhausted; this call was not executed. Answer with the information already gathered."
          )
          await emit(.toolFinished(context, result))
          results[index] = result
          continue
        }
        state.toolCalls += 1
        await supervisor.note(pid, toolCalls: state.toolCalls, activity: call.name)
        // Repeating a call is often right — the directory changed, a file
        // was written, a child is being polled — so only a call that keeps
        // coming back with the same arguments is stopped, and never one of
        // the agent tools, which exist to be polled.
        let key = ToolCallKey(call)
        let repeats = state.repeatedCalls[key, default: 0]
        guard pollable || repeats < Self.maximumIdenticalCalls else {
          state.repeatGuardTripped = true
          await emit(.toolStarted(context, call))
          let result = AgentProcessTools.failure(
            callID: call.id,
            "this exact call has already run \(repeats) times with the same arguments; change them, or answer with what you have."
          )
          await emit(.toolFinished(context, result))
          results[index] = result
          continue
        }
        state.repeatedCalls[key] = repeats + 1
        if callDefinitions.contains(where: { $0.name == name && $0.annotations.concurrent }) {
          let gate = LaunchGate()
          group.addTask {
            defer { gate.open() }
            return (
              index,
              try await self.execute(
                call,
                definitions: callDefinitions,
                request: callRequest,
                execution: execution,
                budget: budget,
                launched: { gate.open() },
                emit: emit)
            )
          }
          // The next call starts once this one is under way, so children
          // started together get their pids, and their slots, in call order.
          await gate.wait()
        } else {
          results[index] = try await execute(
            call,
            definitions: callDefinitions,
            request: callRequest,
            execution: execution,
            budget: budget,
            emit: emit)
        }
      }
      for try await (index, result) in group {
        results[index] = result
      }
    }
    for (index, call) in calls.enumerated() {
      guard let result = results[index] else { continue }
      state.transcript.append(AgentMessage(role: .tool, content: [.toolResult(result)]))
      // A call that changed something makes repeating an earlier call
      // reasonable again — the tests run after each fix are the common
      // case — so every other call's identical-call count starts over.
      if !result.isError, changesState[index] {
        let own = ToolCallKey(call)
        state.repeatedCalls = state.repeatedCalls.filter { $0.key == own }
      }
    }
    await supervisor.note(
      pid, transcript: state.transcript,
      contextSize: AgentContextSize(messages: state.contextMessages))
  }

  /// A one-shot signal a concurrent call gives once it is under way — a
  /// child registered, a tool called — so the reply's next call can start.
  /// `wait` returns at once when the signal was already given, and the call's
  /// end gives it too, so an early error never holds the reply up.
  private final class LaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
      lock.lock()
      opened = true
      let resumed = waiters
      waiters = []
      lock.unlock()
      for waiter in resumed { waiter.resume() }
    }

    func wait() async {
      await withCheckedContinuation { continuation in
        lock.lock()
        if opened {
          lock.unlock()
          continuation.resume()
        } else {
          waiters.append(continuation)
          lock.unlock()
        }
      }
    }
  }

}
