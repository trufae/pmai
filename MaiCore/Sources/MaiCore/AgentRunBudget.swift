import Foundation

/// The limits for one agent run. Every delegated child receives its own
/// instance from that child's definition. Concurrency of children is the
/// supervisor's business, since background children outlive the run.
actor RunBudget {
  private var limits: AgentRunLimits
  private var modelTurns = 0
  private(set) var approvalUsage: TokenUsage?
  private(set) var approvalTurns = 0

  func noteApprovalTurn() { approvalTurns += 1 }
  func recordApproval(_ usage: TokenUsage) {
    approvalUsage = approvalUsage.merging(usage)
    tokens += max(0, usage.totalTokens)
  }
  private var tokens = 0
  private let startedAt = ContinuousClock.now

  init(limits: AgentRunLimits) {
    self.limits = limits
  }

  var deadlinePassed: Bool {
    limits.maxSeconds.map { ContinuousClock.now >= startedAt + .seconds($0) } ?? false
  }

  var timeInterruption: AgentRunInterruption {
    .time(limitSeconds: limits.maxSeconds ?? 0)
  }

  func update(limits: AgentRunLimits) {
    self.limits = limits
  }

  /// Nil once a turn is claimed; otherwise the limit that stops the run.
  func claimModelTurn() -> AgentRunInterruption? {
    if let interruption = exhausted() { return interruption }
    modelTurns += 1
    return nil
  }

  /// The limit already reached, if any, without claiming anything.
  func exhausted() -> AgentRunInterruption? {
    if deadlinePassed { return timeInterruption }
    if let maximum = limits.maxTotalTokens, tokens >= maximum {
      return .totalTokens(limit: maximum)
    }
    if modelTurns >= limits.maxModelTurns { return .modelTurns(limit: limits.maxModelTurns) }
    return nil
  }

  func allowsToolCall(used: Int) -> Bool {
    used < limits.maxToolCalls
  }

  func record(tokens newTokens: Int) {
    tokens += max(0, newTokens)
  }
}

extension Optional where Wrapped == TokenUsage {
  func merging(_ other: TokenUsage?) -> TokenUsage? {
    guard let other else { return self }
    guard let current = self else { return other }
    return TokenUsage(
      inputTokens: current.inputTokens + other.inputTokens,
      outputTokens: current.outputTokens + other.outputTokens,
      totalTokens: current.totalTokens + other.totalTokens,
      cachedTokens: merge(current.cachedTokens, other.cachedTokens),
      reasoningTokens: merge(current.reasoningTokens, other.reasoningTokens),
      isEstimated: current.isEstimated || other.isEstimated)
  }

  private func merge(_ first: Int?, _ second: Int?) -> Int? {
    guard first != nil || second != nil else { return nil }
    return (first ?? 0) + (second ?? 0)
  }
}
