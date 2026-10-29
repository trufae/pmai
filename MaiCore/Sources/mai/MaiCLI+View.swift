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
    case "voice" where rest.isEmpty: return (.voice, "voice")
    case "todo" where rest.isEmpty: return (.todo, "project todo")
    case "iconlog" where rest.isEmpty: return (.iconlog, "tool icons")
    case "thinking" where rest.isEmpty, "reasoning" where rest.isEmpty:
      return (.thinking, "thinking")
    case "diff" where rest.isEmpty, "diffs" where rest.isEmpty: return (.diffs, "git diff")
    case "agents" where rest.isEmpty, "conversations" where rest.isEmpty:
      return (.conversations, "agent conversations")
    case "tool", "tools":
      guard rest.isEmpty || tools.contains(rest) else {
        throw JSONRPCError.invalidParams("Unknown tool '\(rest)'. /tools full lists tool names.")
      }
      return (.tools(rest.isEmpty ? nil : rest), rest.isEmpty ? "tools" : "tool \(rest)")
    default: break
    }
    let target = name == "agent" ? rest : argument
    guard !target.isEmpty else {
      throw JSONRPCError.invalidParams(
        "Usage: /view <off|current|pins|log|history|todo|iconlog|thinking|voice|tools [NAME]|diffs|prompt TEXT|agents|AGENT>. /help view")
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
    /view voice            Show voice animation, input, replies and tool calls/results
    /view tools [NAME]     Show tool calls/results, optionally filtered by tool name
    /view TOOL_NAME        A tool name is also accepted directly
    /view diffs            Show git diff (unstaged tracked changes), refreshed every 5 seconds
    /view prompt $NAME     Apply a saved prompt after each reply (e.g. $tldr)
    /view prompt TEXT      Apply instructions after each reply, using the compact model
    /view off              Close the view
    """
}

