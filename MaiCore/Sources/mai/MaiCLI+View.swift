import Foundation
import MaiACP
import MaiCore

extension MaiCLI {
  static func viewSource(
    _ argument: String, processes: [AgentProcessInfo], tools: Set<String>, mainConversation: String
  ) throws -> (source: TerminalViewSource?, title: String) {
    let argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
    let name = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    switch name {
    case "off" where rest.isEmpty: return (nil, "")
    case "current" where rest.isEmpty, "conversation" where rest.isEmpty:
      return (.current, "current conversation")
    case "main" where rest.isEmpty: return (.conversation(mainConversation), "main")
    case "pins" where rest.isEmpty: return (.pins, "pinned messages")
    case "log" where rest.isEmpty: return (.log, "message log")
    case "thinking" where rest.isEmpty, "reasoning" where rest.isEmpty:
      return (.thinking, "thinking")
    case "diff" where rest.isEmpty, "diffs" where rest.isEmpty: return (.diffs, "applied diffs")
    case "agents" where rest.isEmpty, "conversations" where rest.isEmpty:
      return (.conversations, "agent conversations")
    case "tool", "tools":
      guard rest.isEmpty || tools.contains(rest) else {
        throw JSONRPCError.invalidParams("Unknown tool '\(rest)'. /tools lists tool names.")
      }
      return (.tools(rest.isEmpty ? nil : rest), rest.isEmpty ? "tools" : "tool \(rest)")
    default: break
    }
    let target = name == "agent" ? rest : argument
    guard !target.isEmpty else {
      throw JSONRPCError.invalidParams(
        "Usage: /view <off|current|pins|log|thinking|tools [NAME]|diffs|agents|AGENT>. /help view")
    }
    let rawPID = target.replacingOccurrences(of: "agent#", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "#@"))
    let matches = processes.filter {
      if let pid = Int(rawPID) { return $0.pid.rawValue == pid }
      return $0.agentID == target || $0.displayName == target
    }
    if matches.count > 1 {
      throw JSONRPCError.invalidParams(
        "Several agents match '\(target)'; use /view agent#PID from /subagents.")
    }
    if let process = matches.first {
      let id = process.depth == 0 ? mainConversation : "agent:\(process.pid.rawValue)"
      return (.conversation(id), "\(process.displayName) #\(process.pid.rawValue)")
    }
    if name != "agent", tools.contains(argument) { return (.tools(argument), "tool \(argument)") }
    throw JSONRPCError.invalidParams(
      "Unknown view or agent '\(target)'. /subagents lists conversations; /help view lists sources."
    )
  }

  static let viewHelp = """
    /view current          Watch the conversation selected at the prompt
    /view main             Watch the main conversation while working with another agent
    /view AGENT            Watch an agent's conversation by name, agent#PID, or PID
    /view agent NAME       Explicit agent selector (also accepts a display name)
    /view agents           Show retained agent conversations, including the main chat
    /view pins             Show all pinned messages in full, in transcript order
    /view log              Show the first line of every message as role: text
    /view thinking         Show the current agent's full retained reasoning
    /view tools [NAME]     Show tool calls/results, optionally filtered by tool name
    /view TOOL_NAME        A tool name is also accepted directly
    /view diffs            Show successful tool results containing applied file diffs
    /view off              Close the view

    Requires /set ui.mode buffer and an interactive terminal. The read-only view
    starts in the top half of the output area, with the conversation below it.
    Drag the separator with the left mouse button to resize the panes. Both
    panes keep at least one row; the chosen height is kept when sources change.
    Tab with an empty prompt switches focus between the prompt and the view.
    In the view, j/k or Down/Up scroll one row; J/K page down/up like Page Down/Up.
    g/G jump to the top/bottom; G resumes following new output.
    v/V move the divider down/up one row; q closes the view, like /view off.
    The mouse wheel scrolls the focused pane. Tab returns to typing; completion works as usual
    when the prompt contains text. Agent message destinations stay the same.
    Pins/log/thinking/tools/diffs follow the selected agent; an explicit agent stays fixed.
    The tools view follows ui.tools, including changes made while the view is open.
    On very short terminals the view is hidden until there is room for both panes.
    Switching to classic mode closes the view.
    """
}
