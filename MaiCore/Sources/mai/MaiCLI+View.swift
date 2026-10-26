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
    case "prompt" where !rest.isEmpty: return (.prompt, "prompt \(rest)")
    case "off" where rest.isEmpty: return (nil, "")
    case "current" where rest.isEmpty, "conversation" where rest.isEmpty:
      return (.current, "current conversation")
    case "main" where rest.isEmpty: return (.conversation(mainConversation), "main")
    case "pins" where rest.isEmpty: return (.pins, "pinned messages")
    case "history" where rest.isEmpty: return (.history, "input history")
    case "log" where rest.isEmpty: return (.log, "message log")
    case "todo" where rest.isEmpty: return (.todo, "project todo")
    case "iconlog" where rest.isEmpty: return (.iconlog, "tool icons")
    case "thinking" where rest.isEmpty, "reasoning" where rest.isEmpty:
      return (.thinking, "thinking")
    case "diff" where rest.isEmpty, "diffs" where rest.isEmpty: return (.diffs, "git diff")
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
        "Usage: /view <off|current|pins|log|history|todo|iconlog|thinking|tools [NAME]|diffs|prompt TEXT|agents|AGENT>. /help view")
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

  static func viewPromptTemplate(_ argument: String, catalog: PromptCatalog) throws -> String {
    let argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !argument.isEmpty else {
      throw JSONRPCError.invalidParams("Usage: /view prompt $NAME or /view prompt INSTRUCTIONS")
    }
    guard argument.hasPrefix("$") else { return argument }
    let parts = argument.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard let name = parts.first, let entry = catalog.entry(named: String(name)), entry.kind != .skill else {
      throw JSONRPCError.invalidParams("Unknown prompt '\(argument)'. /prompts lists prompt names.")
    }
    let extra = parts.count > 1 ? String(parts[1]) : ""
    // Reserve $ARGUMENTS for the last reply, including when extra instructions follow the name.
    return entry.text + (extra.isEmpty ? "" : "\n\n" + extra)
  }

  static let viewHelp = """
    /view current          Watch the conversation selected at the prompt
    /view main             Watch the main conversation while working with another agent
    /view AGENT            Watch an agent's conversation by name, agent#PID, or PID
    /view agent NAME       Explicit agent selector (also accepts a display name)
    /view agents           Show retained agent conversations, including the main chat
    /view pins             Show all pinned messages in full, in transcript order
    /view log              Show the first line of every message as role: text
    /view history          Show saved inputs, as in /history
    /view todo             Show the project's todo list, as in /todo
    /view iconlog          Show tool calls as a continuous row of emojis
    /view thinking         Show the current agent's full retained reasoning
    /view tools [NAME]     Show tool calls/results, optionally filtered by tool name
    /view TOOL_NAME        A tool name is also accepted directly
    /view diffs            Show git diff (unstaged tracked changes), refreshed every 5 seconds
    /view prompt $NAME     Apply a saved prompt to the last reply (e.g. $tldr)
    /view prompt TEXT      Apply instructions to the last reply, using the compact model
    /view off              Close the view

    Requires /set ui.mode buffer and an interactive terminal. The read-only view
    starts in the top half of the output area, with the conversation below it.
    With the view focused, Space toggles between top/bottom and left/right panes,
    with the view on the right and the conversation on the left.
    Enter toggles the view fullscreen above the prompt; Enter again restores the split.
    Drag the separator with the left mouse button to resize either layout. Both
    panes keep at least one row/column; sizes are kept when sources change.
    Replies, pinned messages, logs and thinking follow ui.markdown and reflow to fit.
    Overflowing panes show a scrollbar on the right (one character by default).
    /set ui.scrollbar N sets its width: positive on the right, negative on the left,
    and 0 hides it. Drag its handle or click its track to scroll; the handle size
    reflects the amount of visible content.
    Ctrl+W switches focus between the prompt and the view, keeping any draft.
    Tab with an empty prompt also switches focus.
    In the view, j/k or Down/Up scroll one row; J/K page down/up like Page Down/Up.
    g/G jump to the top/bottom; G resumes following new output.
    v/V grow/shrink the view by one row or column; q closes it, like /view off.
    / opens a search prompt: type literal text and Enter to highlight every match
    and scroll the focused pane to the first hit. Escape or Ctrl+C cancels the search.
    /highlight WORD at the normal prompt and /set ui.highlight WORD set the same
    saved word for both panes. /highlight or /set ui.highlight none clears it.
    Matching is case-sensitive, including within words, with black text on white.
    The mouse wheel scrolls the focused pane. Tab returns to typing; completion works as usual
    when the prompt contains text. Agent message destinations stay the same.
    Pins/log/iconlog/thinking/tools follow the selected agent; an explicit agent stays fixed.
    Prompt output stays in the view; closing or replacing the view cancels the request.
    History refreshes after commands; diffs uses the current directory and keeps its scroll position.
    Todo shows the current project's shared list and refreshes as commands and tools run.
    The tools view follows ui.tools, including changes made while the view is open.
    Thinking/tools/iconlog views hide matching blocks in the conversation until the view closes
    or changes source. The thinking view also replaces the live thinking preview.
    Iconlog always shows icons, independently of ui.tools. /tools lists their meanings.
    On very short terminals the view is hidden until there is room for both panes.
    Switching to classic mode closes the view.
    """
}

