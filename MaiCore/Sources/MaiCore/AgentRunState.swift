import Foundation

extension AgentRuntime {
  /// Owned by one invocation, never stored on the runtime actor or shared
  /// with child runs. Actor reentrancy must not mix transcripts or counters.
  struct RunState {
    var request: AgentRequest
    let context: AgentEventContext
    let pid: AgentPID
    let budget: RunBudget
    let activeTaskID: String?
    let emit: AgentEventHandler
    var transcript: [AgentMessage]
    var toolContext: AgentToolResultContext
    var smartContext = AgentSmartContext()
    var totalUsage: TokenUsage?
    /// Provider usage describes the previous context until an edit changes it.
    var lastUsage: TokenUsage?
    var lastUsageMessageCount = 0
    var skipAutocompaction = false
    var modelTurns = 0
    var toolCalls = 0
    /// A specialist hands results to the primary for the remainder of a reply.
    var pendingDecision: ToolChoice?
    var usingPrimary = false
    var repeatedCalls: [ToolCallKey: Int] = [:]
    var repeatGuardTripped = false
    var consecutiveRepairs = 0

    init(
      _ request: AgentRequest, context: AgentEventContext, pid: AgentPID,
      budget: RunBudget, activeTaskID: String?, emit: @escaping AgentEventHandler
    ) {
      self.request = request
      self.context = context
      self.pid = pid
      self.budget = budget
      self.activeTaskID = activeTaskID
      self.emit = emit
      transcript = request.messages
      toolContext = AgentToolResultContext(messages: request.context == .tools ? transcript : [])
    }

    var contextMessages: [AgentMessage] {
      request.context == .tools ? toolContext.messages(from: transcript) : transcript
    }

    var estimatedTokens: Int {
      AgentAutocompaction.estimatedTokens(
        of: transcript, lastUsage: lastUsage, lastUsageMessageCount: lastUsageMessageCount)
    }

    mutating func recordRepair(_ feedback: String) {
      consecutiveRepairs += 1
      if consecutiveRepairs >= AgentRuntime.maximumRepairAttempts { repeatGuardTripped = true }
      transcript.append(.assistant(feedback))
    }
  }
}
