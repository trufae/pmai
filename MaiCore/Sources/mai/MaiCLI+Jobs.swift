import Foundation
import MaiCore

extension MaiCLI {
  /// Canonical job commands and the old explicit runtime subcommands share
  /// one route. Bare /agents and /agent always list definitions.
  static func jobsArgument(for command: String, argument: String) -> String? {
    switch command {
    case "/jobs", "/job":
      return argument
    case "/agents", "/agent":
      let action = argument.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
      return legacyJobActions.contains(action) ? argument : nil
    default:
      return nil
    }
  }

  private static let legacyJobActions: Set<String> = [
    "tree", "ps", "log", "kill", "stop", "pause", "suspend", "continue", "cont", "resume",
    "clear", "focus",
  ]

  /// Process operations shared by the prompt and command host. Focus and
  /// durable clearing also need the prompt's session state.
  static func handleJobsCommand(
    _ argument: String,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""

    switch action {
    case "", "tree", "ps":
      guard fields.count <= 1 else {
        await terminal.line("Usage: /jobs [tree]")
        return
      }
      let lines = await jobsTreeLines(runtime: runtime)
      await terminal.line(lines.isEmpty ? "No jobs recorded." : lines.joined(separator: "\n"))

    case "clear":
      guard fields.count == 1 else {
        await terminal.line("Usage: /jobs clear")
        return
      }
      // The REPL loop also updates its chat pids; hosted commands only
      // clear the supervisor records.
      let cleared = await runtime.supervisor.clearFinished()
      await terminal.line(
        cleared.isEmpty
          ? "No finished agents to clear."
          : "Cleared \(cleared.count) finished agent\(cleared.count == 1 ? "" : "s").")

    case "log":
      guard fields.count == 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /jobs log PID")
        return
      }
      let messages = await runtime.supervisor.transcript(pid)
      guard !messages.isEmpty else {
        let known = await runtime.supervisor.info(pid) != nil
        await terminal.line(
          known ? "\(pid) has not produced a transcript yet." : "No agent \(pid).")
        return
      }
      var lines: [String] = []
      for (index, message) in messages.enumerated() {
        lines.append("## [\(index + 1)] \(message.role.rawValue.capitalized)")
        lines.append(message.content.map { renderFullContent($0) }.joined(separator: "\n"))
      }
      await terminal.line(lines.joined(separator: "\n"))

    case "kill":
      guard fields.count >= 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /jobs kill PID [REASON]")
        return
      }
      guard await runtime.supervisor.info(pid) != nil else {
        await terminal.line("No agent \(pid).")
        return
      }
      let reason = fields.count > 2 ? fields[2] : "Stopped from the REPL"
      let stopped = await runtime.supervisor.stop(pid, reason: reason)
      await terminal.line(
        "Stopped \(stopped.map(\.description).joined(separator: ", ")).")

    case "stop", "pause", "suspend":
      guard fields.count == 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /jobs stop PID")
        return
      }
      guard let info = await runtime.supervisor.info(pid) else {
        await terminal.line("No agent \(pid).")
        return
      }
      guard info.depth > 0 else {
        await terminal.line("\(pid) is this chat; Ctrl+C cancels its turn.")
        return
      }
      guard !info.state.isTerminal else {
        await terminal.line(
          "\(pid) (\(info.agentID)) has finished; /jobs log \(pid.rawValue) shows what it did.")
        return
      }
      let held = await runtime.supervisor.pause(pid)
      guard !held.isEmpty else {
        await terminal.line(
          "\(pid) (\(info.agentID)) is already paused; /jobs continue \(pid.rawValue) lets it go on."
        )
        return
      }
      await terminal.line(
        "Paused \(held.map(\.description).joined(separator: ", ")): it finishes the step it is in, then waits. Messages queued meanwhile are read when /jobs continue \(pid.rawValue) lets it go on."
      )

    case "continue", "cont", "resume":
      guard fields.count == 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /jobs continue PID")
        return
      }
      guard let info = await runtime.supervisor.info(pid) else {
        await terminal.line("No agent \(pid).")
        return
      }
      let released = await runtime.supervisor.resume(pid)
      guard !released.isEmpty else {
        await terminal.line(
          info.state.isTerminal
            ? "\(pid) (\(info.agentID)) has finished; /jobs log \(pid.rawValue) shows what it did."
            : "\(pid) (\(info.agentID)) is not paused.")
        return
      }
      await terminal.line("Continued \(released.map(\.description).joined(separator: ", ")).")

    case "focus":
      await terminal.line("/jobs focus is available at the interactive prompt.")

    default:
      await terminal.line(jobsHelp)
    }
  }

  private static func jobsTreeLines(runtime: AgentRuntime) async -> [String] {
    let tree = await runtime.supervisor.tree()
    guard !tree.isEmpty else { return [] }
    return ["Jobs:"] + tree.lines() + [jobTreeTotal(tree)]
  }

  /// One row summing what the whole tree has spent so far. Tokens are every
  /// model call's input and output added up, the way a provider bills them,
  /// formatted like the rows above it.
  static func jobTreeTotal(_ tree: AgentProcessTree) -> String {
    let turns = tree.processes.reduce(0) { $0 + $1.modelTurns }
    let tools = tree.processes.reduce(0) { $0 + $1.toolCalls }
    let tokens = tree.processes.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }
    let estimated = tree.processes.contains { $0.usage?.isEstimated == true }
    return
      "Total: \(turns) turn\(turns == 1 ? "" : "s"), \(tools) tool\(tools == 1 ? "" : "s"), \(ModelUsageFormat.tokens(tokens, estimated: estimated))"
  }

  static let jobsHelp = """
    Job commands (/job is an alias). Jobs are running or saved agent processes;
    /agents manages the definitions they started from.

      /jobs                     List the process tree, including finished and saved jobs
      /jobs tree                Same as /jobs; /jobs ps also works
      /jobs log PID             Print a process's transcript
      /jobs stop PID            Pause a child and its descendants after their current step
      /jobs continue PID        Resume paused processes and deliver queued messages
      /jobs kill PID [REASON]   Cancel a process and its descendants
      /jobs focus [PID|main]    Switch input and the buffer to an agent conversation
      /jobs clear               Forget finished processes and their saved chat records

    PIDs accept 4 or #4. Tree states include run, paused, queued, done, failed,
    killed, stopped, blocked, approve?, and input?. /help queue explains addressing.
    Pausing waits at runtime boundaries; killing requests cancellation.
    /jobs stop does not pause the main chat; Ctrl+C cancels its turn.
    Finished conversations accept new messages. Saved conversations with runtime
    settings can start new turns; older jobs remain available for inspection.

    @PID TEXT addresses one process once; @2,3 TEXT or @2 @3 TEXT addresses several.
    @* TEXT, @@ TEXT, and bare @ TEXT reach every active process, including the
    running main chat and paused children. /queue lists waiting messages.
    /set ui.broadcast on makes ordinary messages reach every active process;
    off restores the focus. /set ui.subagents controls child output.

    The old /agents and /agent runtime subcommands remain compatibility aliases.
    """

  static let conversationsHelp = """
    /subagents                    List conversations with their tab slots and PIDs
    /subagents PID|main           Switch to a conversation (also /jobs focus PID)
    /subagents parent|next|prev    Navigate the conversation tree
    /fork [TITLE]                 Copy this conversation into an idle child and switch
    /fork --empty [TITLE]         Start a child with the same settings and fresh history

    Buffer mode replaces the whole conversation and retains each thread's scroll
    position and input draft. Other agents continue running in the background.
    Alt+1…9 selects a slot; Ctrl+Left/Right cycles. Extended keyboard protocols
    also support Ctrl+1…9 and Ctrl+Tab/Ctrl+Shift+Tab. Terminals may reserve keys.
    The status strip uses one cell per agent: the selected slot number, ● running,
    . idle, ‖ paused, ! needing attention. Slots follow PID order; clearing jobs
    removes their slots. /chat fork still creates a separate saved chat.
    """
}
