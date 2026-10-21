import Foundation
import MaiCore

/// A stable identity separates a question's input from chat drafts and other questions.
struct TerminalPrompt: Equatable, Sendable {
  var text: String
  var id: String? = nil
  var choices: [String] = []

  var isModal: Bool { id != nil }
}

/// The same active modal supplies the editor, status row, and input routing.
enum REPLModalPrompt {
  case approval(ApprovalRequest, id: UUID, editing: Bool)
  case compaction(AutocompactionRequest, id: UUID)
  case queue
  case chop(id: String)

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
    case .chop(let id):
      return TerminalPrompt(text: "chop [n/p/e/d/x/q]> ", id: "chop-\(id)", choices: ["n", "p", "e", "d", "x", "q"])
    }
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
    case .chop:
      return "CHAT CHOP · n next · p previous · d delete · x chop after · q / Ctrl+C quit"
    }
  }
}
