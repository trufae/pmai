import Foundation

extension AgentRuntime {
  /// The CLI may change this while an agent runs. The next event or model
  /// call observes the new destination.
  public func configureDebugLog(_ log: AgentDebugLog?) {
    debugLog = log
  }

  func recordDebugEvent(_ event: AgentEvent) async {
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

  struct ProviderCall {
    var response: ProviderResponse
    var timing: StreamTimingObservation
    var ended: Date

    /// Calls without reported usage still spend tokens and count toward limits.
    func usage(for messages: [AgentMessage]) -> TokenUsage {
      response.usage
        ?? .estimated(
          inputTokens: ModelCallStats.estimatedTokenCount(of: messages),
          outputTokens: ModelCallStats.estimatedTokenCount(
            forCharacterCount: response.message.text.count))
    }
  }

  func recordModelCall(
    _ call: ProviderCall, provider: ProviderID, request: ProviderRequest,
    userMessages: [AgentMessage]? = nil
  ) async {
    guard let usageStats else { return }
    // The user's own words count only on the conversation's first call;
    // compaction, approval and later turns only resend context.
    let userInputTokens = userMessages.map {
      ModelCallStats.estimatedTokenCount(of: Self.trailingUserMessages(in: $0))
    }
    await usageStats.record(
      ModelCallStats.measured(
        providerLabel: provider.rawValue, modelID: request.model,
        messages: request.messages, response: call.response,
        timing: call.timing, end: call.ended, userInputTokens: userInputTokens),
      at: call.ended)
  }

  func resolvedModel(_ model: String, for provider: any ChatProvider) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? provider.descriptor.defaultModel ?? model : model
  }

  /// One provider call under the run's retry policy and deadline. A failure
  /// that is not a cancellation is repeated after the policy's delay, up to
  /// its attempts, each announced with `retrying`; the deadline cuts a call
  /// short with `RunDeadlineExceeded`. Cancellation passes through untouched.
  func complete(
    _ providerRequest: ProviderRequest,
    with provider: any ChatProvider,
    retry: AgentRetryPolicy,
    budget: RunBudget,
    context: AgentEventContext,
    pid: AgentPID,
    retriesEmptyReply: Bool = true,
    emit: @escaping AgentEventHandler,
    onEvent: @escaping ProviderEventHandler
  ) async throws -> ProviderCall {
    var attempt = 0
    while true {
      let timing = StreamTimingRecorder()
      await debugLog?.record(
        "model.request", context: context, provider: provider.descriptor.id.rawValue,
        attempt: attempt + 1, value: providerRequest)
      do {
        let response = try await withDeadline(budget) {
          try await provider.complete(providerRequest) { event in
            timing.note(event)
            await onEvent(event)
          }
        }
        await debugLog?.record(
          "model.response", context: context, provider: provider.descriptor.id.rawValue,
          attempt: attempt + 1, value: response)
        return ProviderCall(response: response, timing: timing.observation, ended: Date())
      } catch is CancellationError {
        await debugLog?.record("model.cancelled", context: context, value: "cancelled")
        throw CancellationError()
      } catch is RunDeadlineExceeded {
        await debugLog?.record("model.deadline", context: context, value: "deadline exceeded")
        throw RunDeadlineExceeded()
      } catch is ProviderEmptyResponseError where !retriesEmptyReply {
        await debugLog?.record("model.empty", context: context, value: "empty response")
        throw ProviderEmptyReply()
      } catch let error as ToolApprovalUnavailable {
        throw error
      } catch let error as any ProviderToolCallError where error.toolCallRepairMessage != nil {
        throw error
      } catch {
        await debugLog?.record(
          "model.error", context: context, provider: provider.descriptor.id.rawValue,
          attempt: attempt + 1, value: error.localizedDescription)
        let delayStarted = ContinuousClock.now
        let policy = liveRequests[pid]?.retry ?? retry
        guard attempt < policy.attempts else { throw error }
        attempt += 1
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
      let policy = liveRequests[pid]?.retry ?? fallback
      if attempt > policy.attempts { return policy }
      if await budget.deadlinePassed { throw RunDeadlineExceeded() }
      if policy.delaySeconds <= 0
        || ContinuousClock.now >= started + .seconds(policy.delaySeconds)
      {
        return policy
      }
      try await Task.sleep(for: .milliseconds(50))
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
          if await budget.deadlinePassed { throw RunDeadlineExceeded() }
          try await Task.sleep(for: .milliseconds(50))
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
