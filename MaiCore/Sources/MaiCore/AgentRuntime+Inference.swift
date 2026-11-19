import Foundation

extension AgentRuntime {
  /// The CLI may change this while an agent runs. The next event or model
  /// call observes the new destination.
  public func configureDebugLog(_ log: AgentDebugLog?) {
    debugLog = log
  }

  public func recordDebugConfiguration(_ value: JSONValue) async {
    await debugLog?.record("configuration.snapshot", value: DebugDiagnostics.sanitize(value))
  }

  func recordDebugEvent(_ event: AgentEvent) async {
    // Retain useful metadata independently of the optional verbose file log.
    switch event {
    case .started(let context, let provider):
      noteDiagnostic("run.started", context: context, value: .object([
        "provider": .string(provider.id.rawValue),
      ]))
    case .toolStarted(let context, let call):
      noteDiagnostic("tool.started", context: context, value: .object([
        "tool": .string(call.name), "toolCallID": .string(call.id),
      ]))
    case .toolFinished(let context, let result):
      noteDiagnostic("tool.finished", context: context, value: .object([
        "toolCallID": .string(result.callID), "isError": .bool(result.isError),
        "outputCharacters": .integer(result.text.count),
      ]))
    case .transcriptEdited(let context, let report):
      noteDiagnostic("context.edited", context: context, value: .object([
        "report": .string(report.summary), "beforeCharacters": .integer(report.charactersBefore),
        "afterCharacters": .integer(report.charactersAfter),
      ]))
    case .childStarted(let context, let child), .childQueued(let context, let child):
      noteDiagnostic("child.scheduled", context: context,
        value: (try? DebugDiagnostics.value(child)) ?? .null)
    case .finished(let context, let result):
      noteDiagnostic("run.finished", context: context, value: .object([
        "modelTurns": .integer(result.modelTurns), "toolCalls": .integer(result.toolCalls),
        "usage": (try? DebugDiagnostics.value(result.usage)) ?? .null,
        "stopReason": .string(result.stopReason.rawValue),
        "interruption": result.interruption.map { .string($0.summary) } ?? .null,
      ]))
    default: break
    }
    guard let debugLog else { return }
    switch event {
    case .started(let context, let provider):
      await debugLog.record("run.started", context: context, value: provider)
    case .modelStarted(let context, let turn):
      await debugLog.record("model.started", context: context, value: turn)
    case .provider:
      // The complete provider response is recorded once, after streaming.
      break
    case .toolStarted(let context, let call):
      await debugLog.record("tool.started", context: context, value: call)
    case .toolUpdated(let context, let call):
      await debugLog.record("tool.updated", context: context, value: call)
    case .toolFinished(let context, let result):
      await debugLog.record("tool.finished", context: context, value: result)
    case .approvalRequested(let context, let request):
      await debugLog.record("approval.requested", context: context, value: request.call)
    case .approvalDecided(let context, let decision):
      await debugLog.record(
        "approval.decided", context: context, value: String(describing: decision))
    case .childStarted(let context, let child):
      await debugLog.record("child.started", context: context, value: child)
    case .childQueued(let context, let child):
      await debugLog.record("child.queued", context: context, value: child)
    case .childFinished(let context, let child):
      await debugLog.record(
        "child.finished", context: context,
        value: "\(child.agentID): \(child.modelTurns) model turns, \(child.toolCalls) tool calls")
    case .userMessage(let context, let message):
      await debugLog.record("user.message", context: context, value: message)
    case .transcriptEdited(let context, let report):
      await debugLog.record(
        "transcript.edited", context: context, value: String(describing: report))
    case .retrying(let context, let attempt, let limit, let delay, let error):
      await debugLog.record(
        "model.retrying", context: context, attempt: attempt,
        value: "\(error) (limit \(limit), delay \(delay)s)")
    case .compactionStarted(let context, let tokens):
      await debugLog.record("compaction.started", context: context, value: tokens)
    case .compactionFailed(let context, let error):
      await debugLog.record("compaction.failed", context: context, value: error)
    case .finished(let context, let result):
      await debugLog.record(
        "run.finished", context: context,
        value:
          "\(result.modelTurns) model turns, \(result.toolCalls) tool calls, stop \(result.stopReason), interruption \(String(describing: result.interruption))"
      )
    }
  }

  /// Installs the ledger every provider call reports into: tokens from the
  /// provider's usage payload (estimated from text length when it has none)
  /// and the wall-clock timing of the call. Nil stops recording.
  public func configureUsageStats(_ store: ModelUsageStore?) {
    usageStats = store
  }

  /// The ledger installed with `configureUsageStats`, for `/stats` screens.
  public func usageStatsStore() -> ModelUsageStore? {
    usageStats
  }

  /// Installs the limits a host reads for `/status`. `configuration` returns
  /// the settings in force right now, because a host may switch provider or
  /// key mid-session.
  public func registerProviderStatus(
    _ store: ProviderStatusStore, configuration: @escaping @Sendable () -> MaiConfiguration?
  ) {
    providerStatusStore = store
    providerStatusConfiguration = configuration
  }

  /// A host that only answers `_pmai/status` needs no tool: its sessions run
  /// with their own provider and never read the host's key.
  public func registerProviderStatus(_ settings: ConfigurationBox) {
    registerProviderStatus(ProviderStatusStore(), configuration: { settings.value })
  }

  /// The status of one configured provider, or nil when it publishes none.
  public func providerStatus(
    for providerID: String, model: String? = nil, refresh: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> MaiProviderStatus? {
    guard let store = providerStatusStore,
      let provider = providerStatusConfiguration?()?.providers.first(where: { $0.id == providerID })
    else { return nil }
    return try await store.status(
      for: provider, model: model, refresh: refresh, environment: environment)
  }

  struct ProviderCall {
    var response: ProviderResponse
    var timing: StreamTimingObservation
    var ended: Date

    /// Calls without reported usage still spend tokens and count toward limits.
    func usage(for request: ProviderRequest) -> TokenUsage {
      response.usage
        ?? .estimated(
          inputTokens: AgentRuntime.contextTokens(request),
          outputTokens: ModelCallStats.estimatedTokenCount(
            forCharacterCount: AgentTranscriptEditor.characterCount(of: response.message)))
    }
  }

  @discardableResult
  func recordModelCall(
    _ call: ProviderCall, provider: ProviderID, request: ProviderRequest,
    userMessages: [AgentMessage]? = nil
  ) async -> ModelCallStats {
    // The user's own words count only on the conversation's first call;
    // compaction, approval and later turns only resend context.
    let userInputTokens = userMessages.map {
      ModelCallStats.estimatedTokenCount(of: Self.trailingUserMessages(in: $0))
    }
    var stats = ModelCallStats.measured(
      providerLabel: provider.rawValue, modelID: request.model,
      messages: request.messages, response: call.response,
      timing: call.timing, end: call.ended, userInputTokens: userInputTokens)
    if call.response.usage == nil {
      let usage = call.usage(for: request)
      stats.inputTokens = usage.inputTokens
      stats.outputTokens = usage.outputTokens
    }
    await usageStats?.record(stats, at: call.ended)
    return stats
  }

  func resolvedModel(_ model: String, for provider: any ChatProvider) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? provider.descriptor.defaultModel ?? model : model
  }

  /// One provider call under the run's retry policy and deadline. A failure
  /// that is not a cancellation or policy rejection is repeated after the
  /// policy's delay, up to its attempts, each announced with `retrying`.
  /// The deadline cuts a call short with `RunDeadlineExceeded`.
  /// Cancellation passes through untouched.
  func complete(
    _ providerRequest: ProviderRequest,
    with provider: any ChatProvider,
    retry: AgentRetryPolicy,
    budget: RunBudget,
    context: AgentEventContext,
    pid: AgentPID,
    retriesEmptyReply: Bool = true,
    systemContext: Bool? = nil,
    purpose: String = "conversation",
    emit: @escaping AgentEventHandler,
    onEvent: @escaping ProviderEventHandler
  ) async throws -> ProviderCall {
    var attempt = 0
    let callID = UUID()
    let callPurpose = AgentDiagnosticScope.current?.purpose ?? purpose
    var lastTransportError: ProviderTransportError?
    while true {
      var outbound = providerRequest
      if redactionMode != .off, let redactor = ContentRedactor.current {
        if systemContext != false, !redactionRules.isEmpty {
          outbound.messages.insert(
            .system(ContentRedactor.placeholderInstructions), at: 0)
        }
        let filtered = redactor.redact(outbound)
        outbound = filtered.request
        if redactionMode == .warn, filtered.count > 0 {
          await redactionWarning?(filtered.count)
        }
      }
      let outgoingRequest = outbound
      let display = ContentRedactor.current.map { RedactionStream($0) }
      await provider.configureInternetAccess(internetAccess)
      let timing = StreamTimingRecorder()
      var requestDetails = Self.diagnosticRequest(outgoingRequest)
      requestDetails["attempt"] = .integer(attempt + 1)
      requestDetails["provider"] = .string(provider.descriptor.id.rawValue)
      noteDiagnostic("model.request", context: context, sessionID: outgoingRequest.sessionID,
        purpose: callPurpose, callID: callID, value: .object(requestDetails))
      await debugLog?.record(
        "model.request", context: context, provider: provider.descriptor.id.rawValue,
        attempt: attempt + 1, value: outgoingRequest)
      let attemptNumber = attempt + 1
      let scope = ProviderProcessScope(
        supervisor: supervisor, context: context, provider: provider.descriptor.id, emit: emit,
        diagnostic: { phase, details in
          await self.recordTransportDiagnostic(phase, details: details, context: context,
            provider: provider.descriptor.id, attempt: attemptNumber,
            callID: callID, purpose: callPurpose, sessionID: outgoingRequest.sessionID)
        })
      do {
        let response = try await withDeadline(budget) {
          try await ProviderProcessScope.$current.withValue(
            scope
          ) {
            try await provider.complete(outgoingRequest) { event in
              if timing.note(event) {
                let kind: String
                switch event {
                case .reasoningDelta: kind = "reasoning"
                case .toolCallDelta: kind = "tool_call"
                default: kind = "text"
                }
                await scope.reportTransport("first_output", details: [
                  "kind": .string(kind),
                  "elapsedSeconds": .number(Date().timeIntervalSince(timing.observation.requestStart)),
                ], activity: "receiving model output")
              }
              if let display {
                if let visible = await display.feed(event) { await onEvent(visible) }
              } else {
                await onEvent(event)
              }
            }
          }
        }
        if let display {
          for event in await display.finish() { await onEvent(event) }
        }
        await debugLog?.record(
          "model.response", context: context, provider: provider.descriptor.id.rawValue,
          attempt: attempt + 1, value: response)
        let usage = response.usage ?? .estimated(
          inputTokens: Self.contextTokens(outgoingRequest),
          outputTokens: ModelCallStats.estimatedTokenCount(
            forCharacterCount: AgentTranscriptEditor.characterCount(of: response.message)))
        var details: [String: JSONValue] = [
          "attempt": .integer(attempt + 1), "provider": .string(provider.descriptor.id.rawValue),
          "model": .string(outgoingRequest.model),
          "durationMs": .integer(Int(Date().timeIntervalSince(timing.observation.requestStart) * 1000)),
          "usage": (try? DebugDiagnostics.value(usage)) ?? .null,
          "usageEstimated": .bool(usage.isEstimated),
          "stopReason": (try? DebugDiagnostics.value(response.stopReason)) ?? .null,
          "responseCharacters": .integer(response.message.text.count),
          "reasoningCharacters": .integer(response.message.reasoning.count),
          "toolCalls": .integer(response.message.toolCalls.count),
        ]
        if AgentDiagnosticScope.current != nil {
          details["summary"] = .string(MessageContentFilter.textWithoutReasoning(from: response.message.text))
        }
        noteDiagnostic("model.response", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID, value: .object(details))
        return ProviderCall(response: response, timing: timing.observation, ended: Date())
      } catch is CancellationError {
        noteDiagnostic("model.cancelled", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID, value: .object(["attempt": .integer(attempt + 1)]))
        await debugLog?.record("model.cancelled", context: context, value: "cancelled")
        throw CancellationError()
      } catch is RunDeadlineExceeded {
        noteDiagnostic("model.deadline", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID, value: .object(["attempt": .integer(attempt + 1)]))
        await debugLog?.record("model.deadline", context: context, value: "deadline exceeded")
        throw RunDeadlineExceeded()
      } catch let error as any ProviderEmptyResponseError where !retriesEmptyReply {
        noteDiagnostic("model.error", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID,
          value: .object(["attempt": .integer(attempt + 1), "error": .string(error.localizedDescription)]))
        await debugLog?.record("model.empty", context: context, value: error.localizedDescription)
        throw ProviderEmptyReply()
      } catch let error as ToolApprovalUnavailable {
        noteDiagnostic("model.error", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID, value: .object(["attempt": .integer(attempt + 1), "error": .string(error.localizedDescription)]))
        throw error
      } catch let error as any ProviderToolCallError where error.toolCallRepairMessage != nil {
        noteDiagnostic("model.error", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID, value: .object(["attempt": .integer(attempt + 1), "error": .string(error.localizedDescription)]))
        throw error
      } catch {
        noteDiagnostic("model.error", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID,
          value: .object(["attempt": .integer(attempt + 1), "error": .string(error.localizedDescription)]))
        await debugLog?.record(
          "model.error", context: context, provider: provider.descriptor.id.rawValue,
          attempt: attempt + 1, value: error.localizedDescription)
        if error is ProviderPolicyError { throw error }
        if let overflow = ProviderContextLimitError.recognize(error) {
          if let window = overflow.contextWindowTokens {
            let previous = contextWindows[provider.descriptor.id]?[providerRequest.model] ?? window
            contextWindows[provider.descriptor.id, default: [:]][providerRequest.model] = min(
              previous, window)
          }
          throw overflow
        }
        if let transport = error as? ProviderTransportError {
          if let lastTransportError, transport.repeats(lastTransportError) { throw error }
          lastTransportError = transport
        } else {
          lastTransportError = nil
        }
        let delayStarted = ContinuousClock.now
        let policy = liveRequests[pid]?.retry ?? retry
        guard attempt < policy.attempts else { throw error }
        attempt += 1
        noteDiagnostic("model.retry", context: context, sessionID: outgoingRequest.sessionID,
          purpose: callPurpose, callID: callID, value: .object([
            "attempt": .integer(attempt + 1), "limit": .integer(policy.attempts),
            "delaySeconds": .number(policy.delaySeconds), "error": .string(error.localizedDescription),
          ]))
        await emit(
          .retrying(
            context, attempt: attempt, limit: policy.attempts, delaySeconds: policy.delaySeconds,
            error: error.localizedDescription))
        await supervisor.note(pid, activity: "retrying")
        let updatedPolicy = try await waitForRetry(
          attempt: attempt,
          started: delayStarted,
          process: pid,
          fallback: policy,
          budget: budget)
        // Lowering retry.attempts while the delay is in progress cancels the
        // pending retry at once instead of making the run wait and call again.
        guard attempt <= updatedPolicy.attempts else { throw error }
      }
    }
  }

  private func recordTransportDiagnostic(
    _ phase: String, details: [String: JSONValue], context: AgentEventContext,
    provider: ProviderID, attempt: Int, callID: UUID, purpose: String, sessionID: String?
  ) async {
    noteDiagnostic("model.transport.\(phase)", context: context, sessionID: sessionID,
      purpose: purpose, callID: callID,
      value: .object(details.merging(["attempt": .integer(attempt)]) { _, latest in latest }))
    await debugLog?.record("model.transport.\(phase)", context: context,
      provider: provider.rawValue, attempt: attempt, value: DebugDiagnostics.sanitize(.object(details)))
  }

  func callProvider(_ turn: ModelTurn, state: inout RunState) async throws -> ProviderCall? {
    let context = state.context
    let emit = state.emit
    state.modelTurns += 1
    state.modelRequest = turn.request
    state.modelRequestTranscriptCount = state.transcript.count
    state.modelInputTokens = nil
    await emit(.modelStarted(context, turn: state.modelTurns))
    await supervisor.note(
      state.pid, modelTurns: state.modelTurns, activity: "thinking",
      contextSize: state.contextSize)
    let repairsEmptyReply =
      (state.toolCalls > 0 || (!turn.definitions.isEmpty && !turn.toolBudgetExhausted))
      && state.request.limits.allowsModelTurn(used: state.modelTurns)
    let request = state.request
    let budget = state.budget
    let pid = state.pid
    let modelTurn = state.modelTurns
    let scope = AgentExecutionScope.current
    let redactor = ContentRedactor.current
    let toolCount = ProviderToolCount(used: state.toolCalls)
    do {
      let response = try await ProviderToolScope.$execute.withValue({ call in
        try await self.holdWhilePaused(pid)
        let current = await self.currentRequest(request, for: pid)
        await budget.update(limits: current.limits)
        guard !(await budget.deadlinePassed),
          await toolCount.claim(limits: current.limits)
        else {
          return ToolResult(
            callID: call.id, text: "Error: the run's tool or time budget is exhausted.",
            isError: true)
        }
        let definitions = try await self.visibleDefinitions(for: current, depth: context.depth)
        return try await AgentExecutionScope.$current.withValue(scope) {
          try await ContentRedactor.$current.withValue(redactor) {
            try await self.execute(
              call, definitions: definitions, request: current,
              execution: ToolExecutionContext(run: context, modelTurn: modelTurn), budget: budget,
              emit: { event in
                await toolCount.record(event)
                await emit(event)
              })
          }
        }
      }) {
        try await complete(
          turn.request, with: turn.provider, retry: turn.retry, budget: state.budget,
          context: context, pid: state.pid, retriesEmptyReply: !repairsEmptyReply,
          systemContext: state.request.systemContext,
          purpose: turn.selectingTools ? "tool-selection" : "conversation", emit: emit
        ) { event in
          if turn.selectingTools {
            switch event {
            case .textDelta, .reasoningDelta: return
            default: break
            }
          }
          if turn.usesTextToolProtocol, case .textDelta = event { return }
          switch event {
          case .toolStarted(let call):
            let activity = AgentEvent.toolStarted(context, call)
            await toolCount.record(activity)
            await emit(activity)
          case .toolFinished(let result):
            let activity = AgentEvent.toolFinished(context, result)
            await toolCount.record(activity)
            await emit(activity)
          case .toolUpdated(let call):
            let activity = AgentEvent.toolUpdated(context, call)
            await toolCount.record(activity)
            await emit(activity)
          default: await emit(.provider(context, event))
          }
        }
      }
      state.toolCalls = await toolCount.used
      state.transcript += await toolCount.transcript
      state.rejectedContextTokens = nil
      state.contextRecoveryAttempts = 0
      return response
    } catch let error as ProviderContextLimitError {
      state.toolCalls = await toolCount.used
      guard state.contextRecoveryAttempts < 2 else { throw error }
      state.contextRecoveryAttempts += 1
      let window = contextWindow(
        provider: turn.provider.descriptor.id, model: turn.request.model,
        options: turn.request.options)
      let threshold =
        window.map {
          Self.inputTokenBudget(window: $0, options: turn.request.options) * 3 / 4
        } ?? max(1, Self.contextTokens(turn.request) / 2)
      if state.request.context == .smart || state.request.context == .adaptive,
        !turn.provider.descriptor.capabilities.contains(.managedToolLoop), !turn.deciding
      {
        state.adaptiveThreshold = min(state.adaptiveThreshold ?? Int.max, threshold)
        state.rejectedContextTokens = Self.contextTokens(turn.request)
        state.smartContext = AgentSmartContext()
        return nil
      }
      let before = AgentTranscriptEditor.characterCount(of: state.workingMessages)
      _ = try await autocompact(
        &state, requiredThreshold: threshold,
        preparedTokens: max(threshold, Self.contextTokens(turn.request)))
      guard AgentTranscriptEditor.characterCount(of: state.workingMessages) < before else { throw error }
      return nil
    } catch let error as any ProviderToolCallError
      where error.toolCallRepairMessage != nil && !turn.definitions.isEmpty
      && !turn.toolBudgetExhausted
    {
      state.recordRepair(error.toolCallRepairMessage!)
      await supervisor.note(state.pid, transcript: state.transcript)
      return nil
    } catch is ProviderEmptyResponseError where repairsEmptyReply {
      // A model that answers a tool result with nothing at all is told what
      // is expected of it, as after a malformed call; retrying the same
      // request twice and then failing the whole run threw the work away.
      var feedback =
        state.toolCalls == 0
        ? AgentToolLoopPolicy.emptyToolCallFeedback
        : AgentToolLoopPolicy.repairFeedbackAfterToolResult(mode: turn.textToolMode ?? .native)
      if state.request.usesToolProxy { feedback += "\n" + ToolProxy.repairHint }
      state.recordRepair(feedback)
      await supervisor.note(state.pid, transcript: state.transcript)
      return nil
    }
  }

  /// Waits under the live retry policy. Changing retry.delay may shorten,
  /// lengthen or remove a delay already in progress, and lowering the attempt
  /// count stops a pending retry without an artificial wait.
  private func waitForRetry(
    attempt: Int,
    started: ContinuousClock.Instant,
    process pid: AgentPID,
    fallback: AgentRetryPolicy,
    budget: RunBudget
  ) async throws -> AgentRetryPolicy {
    while true {
      let revision = supervisor.changes.revision
      let policy = liveRequests[pid]?.retry ?? fallback
      if attempt > policy.attempts { return policy }
      if await budget.deadlinePassed { throw RunDeadlineExceeded() }
      if policy.delaySeconds <= 0
        || ContinuousClock.now >= started + .seconds(policy.delaySeconds)
      {
        return policy
      }
      try await supervisor.changes.wait(after: revision,
        until: min(started + .seconds(policy.delaySeconds), await budget.deadline ?? (started + .seconds(policy.delaySeconds))))
    }
  }

  /// Runs `body`, or throws once the run's live deadline passes. Reading the
  /// budget while waiting means raising, lowering or disabling maxSeconds
  /// also affects a provider call already in flight.
  private func withDeadline<T: Sendable>(
    _ budget: RunBudget,
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await body() }
      group.addTask {
        while true {
          let revision = budget.changes.revision
          if await budget.deadlinePassed { throw RunDeadlineExceeded() }
          try await budget.changes.wait(after: revision, until: await budget.deadline)
        }
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw RunDeadlineExceeded() }
      return first
    }
  }
}

/// Rethrown by the run loop's completion wrapper for an empty model reply it
/// was told not to retry.
struct ProviderEmptyReply: ProviderEmptyResponseError {}

/// Thrown inside a run when `limits.maxSeconds` passes; never leaves the
/// runtime, which turns it into a paused result.
struct RunDeadlineExceeded: Error {}

private actor ProviderToolCount {
  private(set) var used: Int
  private var calls: [ToolCall] = []
  private var results: [ToolResult] = []

  func record(_ event: AgentEvent) {
    switch event {
    case .toolStarted(_, let call): calls.append(call)
    case .toolUpdated(_, let call):
      if let index = calls.firstIndex(where: { $0.id == call.id }) { calls[index] = call }
    case .toolFinished(_, let result): results.append(result)
    default: break
    }
  }

  var transcript: [AgentMessage] {
    let finished = Set(results.map(\.callID))
    let completed = calls.filter { finished.contains($0.id) }
    guard !completed.isEmpty else { return [] }
    return [
      AgentMessage(role: .assistant, content: completed.map { .toolCall($0) }),
      AgentMessage(role: .tool, content: results.map { .toolResult($0) }),
    ]
  }

  init(used: Int) { self.used = used }
  func claim(limits: AgentRunLimits) -> Bool {
    guard limits.remainingToolCalls(used: used) > 0 else { return false }
    used += 1
    return true
  }
}
