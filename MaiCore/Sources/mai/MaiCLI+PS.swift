import Foundation
import MaiCore

extension MaiCLI {
  static func handlePSCommand(
    _ argument: String, session: REPLSession, runtime: AgentRuntime,
    chatProcess: AgentPID? = nil, terminal: TerminalWriter
  ) async {
    do {
      let options = try AgentPSOptions(argument)
      if options.help {
        await terminal.line(psHelp)
        return
      }
      if let pid = options.killPID {
        let killed = runtime.commandHistory.kill(
          pid: pid, sessionID: session.sessionID, saved: session.commands)
        await terminal.line(
          killed
            ? "Killed process \(pid) and its process group."
            : "No live process \(pid) owned by this chat. /ps -a lists current processes.")
        return
      }
      var records = runtime.commandHistory.records(
        sessionID: session.sessionID, saved: session.commands
      )
      .filter(options.includes)
      // Supervisor IDs are reassigned on restore. Only show a /jobs ID
      // when this chat still has a matching run in its current process tree.
      let jobs =
        if let chatProcess {
          await runtime.supervisor.tree().subtree(of: chatProcess)
        } else { [AgentProcessInfo]() }
      for index in records.indices {
        let runID = records[index].run.runID
        records[index].run.pid = jobs.first { $0.runID == runID }?.pid
      }
      await terminal.line(psLines(records).joined(separator: "\n"))
    } catch {
      await terminal.line(error.localizedDescription)
    }
  }

  static func psLines(_ records: [AgentCommandRecord], at now: Date = Date()) -> [String] {
    guard !records.isEmpty else { return ["No matching commands. /help ps lists options."] }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    func cell(_ value: String) -> String {
      value.replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
        .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        .map(String.init).joined()
    }
    var lines = ["PID\tAGENT\tJOB\tSTATE\tEXIT\tELAPSED\tSTARTED\tCWD\tCOMMAND"]
    for record in records {
      let elapsed =
        record.durationMs == nil
          && (record.startedAt == nil || record.state == .interrupted && record.endedAt == nil)
        ? "unknown" : String(format: "%.3fs", record.duration(at: now))
      let command =
        cell(record.command)
        + (record.arguments.isEmpty
          ? ""
          : " args="
            + cell(JSONValue.array(record.arguments.map(JSONValue.string)).compactJSONString))
      lines.append(
        [
          record.pid.map(String.init) ?? "—", cell(record.run.agentID),
          record.run.pid?.description ?? "—",
          record.state.rawValue, record.exitCode.map(String.init) ?? "—", elapsed,
          record.startedAt.map(formatter.string) ?? "—", cell(record.cwd), command,
        ].joined(separator: "\t"))
    }
    return lines
  }

  static let psHelp = """
    /ps             List this chat's current main-agent shell commands
    /ps -a          Include commands from all subagents, including nested agents
    /ps -p          List past commands with duration and exit status
    /ps -ap         List past commands from the main agent and all subagents
    /ps -k PID      Kill a current command and its process group by OS PID

    Rows show the OS PID, agent name, /jobs ID, state, exit code, elapsed time,
    start time, working directory, command, and positional arguments.
    Commands are saved with the conversation, including exports and restores.
    Older chats recover commands and durations from saved run-tool results;
    PIDs and start times that were not recorded are shown as unknown.
    A restored unfinished command is marked interrupted, with unknown duration.
    Saved PIDs cannot be killed. /jobs manages agents; /ps manages their commands.
    """
}
