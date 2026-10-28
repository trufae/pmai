import Foundation
import MaiCore

/// Output carries its destination across actor hops; input always uses the
/// selected conversation. The screen lock protects all retained buffers.
enum TerminalConversationScope {
  @TaskLocal static var id: String?
  @TaskLocal static var replyOwner: String?
}

final class TerminalConversation {
  var transcript = TerminalOutputBuffer()
  var messageLines: [(String, Int)] = []
  var historyWindow: ChatHistoryWindow?
  var historyLoader: (@Sendable (Bool) -> Void)?
  var thinkingBlock: Int?
  var replyBlock: Int?
  var auxiliaryReplyBlocks: [String: Int] = [:]
  var toolBlocks: [Int: Int] = [:]
  var thinkingText: String?
  var thinkingDisplay: ThinkingDisplay = .status
  var outputEndedLine = true
}

enum REPLAgentSwitch: Sendable {
  case slot(Int)
  case next, previous, parent
}

extension AgentEvent {
  var terminalContext: AgentEventContext {
    switch self {
    case .started(let c, _), .modelStarted(let c, _), .provider(let c, _),
      .approvalRequested(let c, _), .approvalDecided(let c, _), .toolStarted(let c, _),
      .toolFinished(let c, _), .childStarted(let c, _), .childQueued(let c, _),
      .childFinished(let c, _), .userMessage(let c, _), .transcriptEdited(let c, _),
      .compactionStarted(let c, _), .compactionFailed(let c, _), .finished(let c, _),
      .retrying(let c, _, _, _, _): return c
    }
  }

  /// A thread's own output uses the same renderer as the main conversation.
  var terminalForegroundEvent: AgentEvent {
    var c = terminalContext
    c.depth = 0
    switch self {
    case .started(_, let v): return .started(c, v)
    case .modelStarted(_, let v): return .modelStarted(c, turn: v)
    case .provider(_, let v): return .provider(c, v)
    case .approvalRequested(_, let v): return .approvalRequested(c, v)
    case .approvalDecided(_, let v): return .approvalDecided(c, v)
    case .toolStarted(_, let v): return .toolStarted(c, v)
    case .toolFinished(_, let v): return .toolFinished(c, v)
    case .childStarted(_, let v): return .childStarted(c, child: v)
    case .childQueued(_, let v): return .childQueued(c, child: v)
    case .childFinished(_, let v): return .childFinished(c, child: v)
    case .userMessage(_, let v): return .userMessage(c, v)
    case .transcriptEdited(_, let v): return .transcriptEdited(c, v)
    case .compactionStarted(_, let v): return .compactionStarted(c, estimatedTokens: v)
    case .compactionFailed(_, let v): return .compactionFailed(c, v)
    case .finished(_, let v): return .finished(c, v)
    case .retrying(_, let a, let l, let d, let e):
      return .retrying(c, attempt: a, limit: l, delaySeconds: d, error: e)
    }
  }
}
