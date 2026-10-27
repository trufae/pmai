import Foundation
import MaiCore

/// A stable identity separates a question's input from chat drafts and other questions.
struct TerminalPrompt: Equatable, Sendable {
  var text: String
  var conversationID: String? = nil
  var id: String? = nil
  var choices: [String] = []

  var isModal: Bool { id != nil }
}

/// The same active modal supplies the editor, pinned question, status row, and input routing.
enum REPLModalPrompt {
  case approval(ApprovalRequest, id: UUID, editing: Bool)
  case compaction(AutocompactionRequest, id: UUID)
  case queue
  case limit(AgentRunInterruption, id: UUID)
  case chop(id: String)
  case reset(id: UUID)

  static func approvalHelp(_ request: ApprovalRequest) -> String {
    request.tool.name == "files_path_access"
      ? "y (yes, this access) · n (no) · c (cancel run); /path allow PATH grants ongoing access"
      : "y (yes) · a (always) · n (no) · e (edit arguments) · c (cancel run)"
  }

  var input: TerminalPrompt {
    switch self {
    case .approval(let request, let id, let editing):
      if editing {
        return TerminalPrompt(text: "json> ", id: "edit-\(id)")
      }
      let choices = request.tool.name == "files_path_access" ? ["y", "n", "c"] : ["y", "a", "n", "e", "c"]
      return TerminalPrompt(text: "approve [\(choices.joined(separator: "/"))]> ", id: "approval-\(id)", choices: choices)
    case .compaction(let request, let id):
      let choices = request.pruning == nil ? ["y", "n", "m", "x", "c"] : ["p", "y", "n", "m", "x", "c"]
      return TerminalPrompt(text: "compact [\(choices.joined(separator: "/"))]> ", id: "compaction-\(id)", choices: choices)
    case .queue:
      return TerminalPrompt(text: "queue [submit/ignore/clear]> ", id: "queue", choices: ["submit", "ignore", "clear"])
    case .limit(_, let id):
      return TerminalPrompt(text: "limit [extend/stop/answer]> ", id: "limit-\(id)", choices: ["extend", "stop", "answer"])
    case .chop(let id):
      return TerminalPrompt(text: "chop [n/b/p/e/d/x/q]> ", id: "chop-\(id)", choices: ["n", "b", "p", "e", "d", "x", "q"])
    case .reset(let id):
      return TerminalPrompt(text: "reset [reset/cancel]> ", id: "reset-\(id)", choices: ["reset", "cancel"])
    }
  }

  var question: String? {
    switch self {
    case .approval(let request, _, let editing):
      let who = request.run.pid.map { "Agent#\($0.rawValue): " } ?? ""
      return "\(who)Approve \(request.tool.annotations.approval.rawValue) tool '\(request.tool.name)'?\nArguments: \(request.call.arguments.compactJSONString)\n"
        + (editing ? "Enter the replacement arguments as a JSON object." : Self.approvalHelp(request))
    case .compaction(let request, _):
      let pruning = request.pruning.map { "\nPruning preview: \($0.summary)." } ?? ""
      return "Context limit for \(request.run.agentID): about \(request.estimatedTokens) tokens (threshold \(request.threshold)). What should happen next?\(pruning)\n"
        + (request.pruning == nil ? "" : "p prune tool output · ")
        + "y summarize · n keep context · m change model · x clear chat · c stop"
    case .queue:
      return "Submit queued messages before this message, ignore them for this turn, or clear them?\nsubmit · ignore · clear"
    case .limit(let reason, _):
      return "\(reason.summary). What should happen next?\nextend [N] renews the run budget (optionally with a new \(reason.settingKey)) · stop keeps the work so far · answer continues without tools"
    case .chop:
      return nil
    case .reset:
      return "Restore all /set options to stock defaults for the current agent, global settings, and this project's approval/debug settings?\nActive voice will stop. Providers, credentials, chats, prompts, and tool selections are kept.\nreset · cancel (Ctrl+C cancels)"
    }
  }

  /// Wrap plain question text without allowing terminal controls into the footer.
  static func questionRows(_ text: String, width: Int, height: Int) -> [String] {
    guard height > 0 else { return [] }
    let plain = text.components(separatedBy: "\n").map {
      $0.components(separatedBy: .controlCharacters).joined(separator: " ")
    }.joined(separator: "\n")
    var buffer = TerminalOutputBuffer()
    buffer.append(plain)
    let rows = buffer.visibleRows(width: max(1, width), height: Int.max)
    guard rows.count > height else { return rows }
    var visible = Array(rows.prefix(height))
    visible[height - 1] = width >= 22 && height > 1
      ? "… full details in chat" : String(visible[height - 1].dropLast()) + "…"
    return visible
  }

  var status: String {
    switch self {
    case .approval(let request, _, let editing):
      let who = request.run.pid.map { " · agent#\($0.rawValue)" } ?? ""
      return "\(editing ? "EDIT ARGUMENTS" : "APPROVAL REQUIRED") · \(request.tool.name)\(who) · \(editing ? "JSON object" : "answer below") · Ctrl+C cancels"
    case .compaction(let request, _):
      return "CONTEXT DECISION · \(request.run.agentID) · answer below · Ctrl+C cancels"
    case .queue:
      return "QUEUED MESSAGES · choose below · Ctrl+C cancels new message"
    case .limit:
      return "RUN LIMIT · choose below · Ctrl+C stops"
    case .chop:
      return "CHAT CHOP · n next · b previous · p pin/unpin · e edit · d delete · x chop after · q / Ctrl+C quit"
    case .reset:
      return "RESET SETTINGS · choose reset or cancel · Ctrl+C cancels"
    }
  }
}
