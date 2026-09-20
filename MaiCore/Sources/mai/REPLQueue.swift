import Foundation
import MaiCore

/// Who a typed message is for.
enum REPLMessageTarget: Equatable {
  /// The chat's own agent.
  case main
  /// A running agent process, by pid.
  case agent(AgentPID)
}

struct REPLMessageError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

extension MaiCLI {
  /// Leading addresses accept `@3,4 text` and `@3 @4 text`; other @words stay in the body.
  static func addressedMessage(_ text: String) throws -> (
    targets: [REPLMessageTarget], body: String
  )? {
    var body = text[...]
    var targets: [REPLMessageTarget] = []
    while body.hasPrefix("@") {
      let parts = body.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      let addresses = parts[0].dropFirst().split(separator: ",", omittingEmptySubsequences: false)
      let parsed: [REPLMessageTarget] = addresses.compactMap { address in
        var value = address.lowercased()
        if value.hasPrefix("@") { value.removeFirst() }
        if ["main", "0", "chat"].contains(value) { return .main }
        if value.hasPrefix("agent") { value = String(value.dropFirst(5)) }
        return AgentPID(text: value).map { .agent($0) }
      }
      guard parsed.count == addresses.count else {
        if addresses.count > 1 {
          throw REPLMessageError(
            message: "Invalid recipients: \(parts[0]). Use @2,3 TEXT or @2 @3 TEXT.")
        }
        break
      }
      targets.append(contentsOf: parsed)
      body = parts.count > 1 ? parts[1] : ""
    }
    guard !targets.isEmpty else { return nil }
    let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      throw REPLMessageError(
        message: "A message is required after the recipients. Use @2,3 TEXT or @2 @3 TEXT.")
    }
    return (targets, message)
  }

  /// Validate the whole list and collapse aliases for the same pid before sending anything.
  static func messageRecipients(
    _ targets: [REPLMessageTarget], main: AgentPID, supervisor: AgentSupervisor
  ) async throws -> [AgentProcessInfo] {
    let processes = Dictionary(
      uniqueKeysWithValues: await supervisor.processes().map { ($0.pid, $0) })
    var seen: Set<AgentPID> = []
    return try targets.compactMap { target in
      let pid = target.pid(main: main)
      guard seen.insert(pid).inserted else { return nil }
      guard let info = processes[pid] else {
        throw REPLMessageError(
          message: "No agent #\(pid.rawValue). /agents tree lists the running ones.")
      }
      guard info.depth == 0 || !info.state.isTerminal else {
        throw REPLMessageError(
          message:
            "agent#\(pid.rawValue) (\(info.agentID)) has finished; /agents log \(pid.rawValue) shows what it did.")
      }
      return info
    }
  }

  /// A pid typed after a command: `3`, `#3`, `agent#3`, or `main`.
  static func focusTarget(_ text: String) -> REPLMessageTarget? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["main", "chat", "0", "off", "none"].contains(value) { return .main }
    if value.hasPrefix("@") { value = String(value.dropFirst()) }
    if value.hasPrefix("agent") { value = String(value.dropFirst(5)) }
    guard let pid = AgentPID(text: value) else { return nil }
    return .agent(pid)
  }

  /// `/queue` shows and edits the messages waiting for the next model turn of
  /// any agent: `push` adds one without sending it, `pop` drops the newest,
  /// `drop` drops them all. A pid narrows `pop` and `drop` to one agent.
  static func handleQueueCommand(
    _ argument: String,
    focus: REPLMessageTarget,
    main: AgentPID,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let supervisor = runtime.supervisor

    switch action {
    case "", "list", "ls":
      let queued = await supervisor.queuedMessages()
      guard !queued.isEmpty else {
        await terminal.line(
          "Nothing is queued. A message typed while a turn runs waits here until the agent's next model turn."
        )
        return
      }
      await terminal.line("Queued messages (\(queued.count)), oldest first:")
      for (index, entry) in queued.enumerated() {
        let info = await supervisor.info(entry.pid)
        let name = info.map { $0.depth == 0 ? "main" : $0.agentID } ?? "?"
        let state = info.map { $0.state.isTerminal ? " (\($0.state.shortLabel))" : "" } ?? ""
        let text = AgentProcessInfo.oneLine(entry.message.text, limit: 100)
        await terminal.line("  \(index + 1). agent#\(entry.pid.rawValue) \(name)\(state)  \(text)")
      }
      await terminal.line(
        "Each is delivered at its agent's next model turn. /queue pop drops the newest, /queue drop drops all."
      )

    case "push", "add":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /queue push [@PID[,PID...]] TEXT")
        return
      }
      do {
        let (targets, body) = try addressedMessage(rest) ?? ([focus], rest)
        let recipients = try await messageRecipients(targets, main: main, supervisor: supervisor)
        for info in recipients {
          await supervisor.post(.user(body), to: info.pid)
          let count = await supervisor.queuedMessages(for: info.pid).count
          await terminal.line(
            "Queued for \(describe(info.pid, main: main, info: info)) (\(count) waiting). It goes out at the agent's next model turn; /continue submits the chat queue; a new message asks what to do."
          )
        }
      } catch {
        await terminal.line(error.localizedDescription)
      }

    case "pop":
      let pid = rest.isEmpty ? nil : focusTarget(rest).map { $0.pid(main: main) }
      if !rest.isEmpty, pid == nil {
        await terminal.line("Usage: /queue pop [PID]")
        return
      }
      guard let dropped = await supervisor.discardLastQueuedMessage(for: pid) else {
        await terminal.line(pid.map { "Nothing is queued for agent#\($0.rawValue)." } ?? "Nothing is queued.")
        return
      }
      await terminal.line(
        "Dropped from agent#\(dropped.pid.rawValue): \(AgentProcessInfo.oneLine(dropped.message.text, limit: 100))"
      )

    case "drop", "flush", "clear":
      let pid = rest.isEmpty ? nil : focusTarget(rest).map { $0.pid(main: main) }
      if !rest.isEmpty, pid == nil {
        await terminal.line("Usage: /queue drop [PID]")
        return
      }
      let dropped = await supervisor.clearQueuedMessages(for: pid)
      guard !dropped.isEmpty else {
        await terminal.line(pid.map { "Nothing is queued for agent#\($0.rawValue)." } ?? "Nothing is queued.")
        return
      }
      await terminal.line("Dropped \(dropped.count) queued message\(dropped.count == 1 ? "" : "s").")

    default:
      await terminal.line(queueHelp)
    }
  }

  static func describe(_ pid: AgentPID, main: AgentPID, info: AgentProcessInfo?) -> String {
    guard pid != main, let info else { return "this chat (agent#\(pid.rawValue))" }
    return "agent#\(pid.rawValue) (\(info.agentID))"
  }

  static let queueHelp = """
    Queue commands. A message typed while a turn runs is queued and joins the
    conversation at the agent's next model turn — in the middle of its tool
    loop — instead of waiting for the turn to end.

      /queue                 List every queued message and the agent it is for
      /queue push TEXT       Queue TEXT for the focused agent without sending it
      /queue push @PID TEXT  Queue TEXT for one agent
      /queue push @2,3 TEXT  Queue the same TEXT for several agents (also @2 @3)
      /queue pop [PID]       Drop the newest queued message (of one agent)
      /queue drop [PID]      Drop every queued message (of one agent)

    Ctrl+C keeps undelivered messages. /continue submits the chat queue.
    If you type a new message with a nonempty queue, choose submit (queue
    first), ignore (keep it for a later turn), or clear (discard it).

    @PID TEXT sends one message to a running agent. @2,3 TEXT or @2 @3 TEXT
    sends one copy to each recipient without changing focus; @main includes
    the chat. /agents tree lists PIDs. Unknown or finished child recipients
    reject the list; repeated PIDs receive only one copy.
    /agents focus PID targets everything you type until /agents focus main.
    """
}

extension REPLMessageTarget {
  func pid(main: AgentPID) -> AgentPID {
    switch self {
    case .main: main
    case .agent(let pid): pid
    }
  }
}
