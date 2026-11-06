import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  static func handleWorkspaceChatCommand(
    _ argument: String,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    chatTitles: inout [UUID: String],
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    chatProcess: AgentPID? = nil,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = parts.first?.lowercased(), !action.isEmpty else {
      await terminal.line(chatHelp)
      return
    }
    let rest = String(argument.dropFirst(action.count)).trimmingCharacters(
      in: .whitespacesAndNewlines)

    switch action {
    case "list":
      guard let scope = ChatListScope(rest) else {
        await terminal.line("Usage: /chat list [active|archived|all]")
        return
      }
      await terminal.line(chatListing(workspace, scope: scope, selectedID: session.id, terminal: terminal))
    case "new":
      var profile = session.profile
      var title = rest
      var explicitAgent = false
      if title.hasPrefix("--agent ") {
        let values = title.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
          String.init)
        guard values.count >= 2,
          let agent = configuration?.agents.first(where: { $0.id == values[1] })
        else {
          await terminal.line("Usage: /chat new [--agent ID] [TITLE]")
          return
        }
        profile = SessionProfile(definition: agent)
        title = values.count == 3 ? values[2] : ""
        explicitAgent = true
      }
      if title.isEmpty, !explicitAgent, session.chat.isDisposable {
        await terminal.line("Already in a new chat.")
        return
      }
      let chat = workspace.startNewChat(
        primaryAgent: profile.agentDefinition,
        title: title.isEmpty ? nil : title)
      session = REPLSession(chat: chat)
      await terminal.line("Started chat '\(chat.displayTitle)' with agent \(profile.agentID).")
    case "fork":
      let source = session.chat
      let chat = source.forked(title: rest)
      workspace.upsert(chat, selecting: true)
      session = REPLSession(chat: chat)
      await terminal.line("Forked '\(source.displayTitle)' into '\(chat.displayTitle)' and switched to it.")
    case "use":
      guard !rest.isEmpty, let chat = resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat use INDEX|ID|TITLE")
        return
      }
      guard chat.id != session.id else {
        await terminal.line("Already in '\(chat.displayTitle)'.")
        return
      }
      await switchSession(
        to: chat, session: &session, workspace: &workspace,
        terminal: terminal)
    case "next", "previous", "prev":
      let ordered = chronologicalChats(workspace)
      guard ordered.count > 1,
        let current = ordered.firstIndex(where: { $0.id == session.id })
      else {
        await terminal.line("There is only one chat.")
        return
      }
      let offset = action == "next" ? 1 : -1
      let chat = ordered[(current + offset + ordered.count) % ordered.count]
      await switchSession(
        to: chat, session: &session, workspace: &workspace,
        terminal: terminal)
    case "info", "show":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat info [INDEX|ID|TITLE]")
        return
      }
      await terminal.line(chatInfo(chat, workspace: workspace, selectedID: session.id))
    case "session":
      switch rest.lowercased() {
      case "":
        await terminal.line("Session: \(session.sessionID)")
      case "new":
        // A fresh session for the same chat: a backend that meters by session
        // sees a new one from the next message on, and nothing else changes.
        session.commands = runtime.commandHistory.records(sessionID: session.sessionID, saved: session.commands)
        session.sessionID = ChatSession.newID()
        session.touch()
        workspace.upsert(session.chat, selecting: true)
        await terminal.line("Session: \(session.sessionID) (new)")
      default:
        await terminal.line("Usage: /chat session [new]")
      }
    case "title":
      if rest.isEmpty {
        await terminal.line("Chat title = \(chatTitles[session.id] ?? "none")")
        return
      }
      let title = ["none", "off"].contains(rest.lowercased()) ? "" : visibleUITitle(rest)
      chatTitles[session.id] = title.isEmpty ? nil : title
      await terminal.configureTerminalTitle(title)
      await terminal.line(title.isEmpty ? "Chat title cleared." : "Chat title set to '\(title)'.")
    case "rename":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /chat rename TITLE")
        return
      }
      session.title = rest
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      await terminal.line("Chat renamed to '\(rest)'.")
    case "pin", "unpin":
      guard var chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat \(action) [INDEX|ID|TITLE]")
        return
      }
      let pinned = action == "pin"
      guard chat.isPinned != pinned else {
        await terminal.line("'\(chat.displayTitle)' is already \(pinned ? "pinned" : "unpinned").")
        return
      }
      chat.isPinned = pinned
      chat.touch()
      if chat.id == session.id {
        session.isPinned = pinned
        session.updatedAt = chat.updatedAt
      }
      workspace.upsert(chat)
      await terminal.line("\(pinned ? "📌 Pinned" : "Unpinned") '\(chat.displayTitle)'.")
    case "archive":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat archive [INDEX|ID|TITLE]")
        return
      }
      guard !chat.isArchived else {
        await terminal.line("'\(chat.displayTitle)' is already archived.")
        return
      }
      guard !chat.isDisposable else {
        await terminal.line("'\(chat.displayTitle)' is empty; there is nothing to archive.")
        return
      }
      guard chat.id == session.id else {
        workspace.setArchived(true, id: chat.id)
        await terminal.line("Archived '\(chat.displayTitle)'.")
        return
      }
      session.isArchived = true
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      session = REPLSession(
        chat: workspace.startNewChat(primaryAgent: session.profile.agentDefinition))
      await terminal.line("Archived '\(chat.displayTitle)' and started a new chat.")
    case "unarchive", "restore":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat unarchive INDEX|ID|TITLE")
        return
      }
      guard chat.isArchived else {
        await terminal.line("'\(chat.displayTitle)' is not archived.")
        return
      }
      if chat.id == session.id {
        session.isArchived = false
        session.touch()
        workspace.upsert(session.chat, selecting: true)
      } else {
        workspace.setArchived(false, id: chat.id)
      }
      await terminal.line("Restored '\(chat.displayTitle)' to the active chats.")
    case "del", "delete", "rm":
      // Preserve an exact title containing spaces; otherwise resolve every
      // selector before mutating the workspace so numeric indexes cannot shift.
      let selectors = resolveChat(rest, in: workspace) != nil
        ? [rest] : rest.split(whereSeparator: \.isWhitespace).map(String.init)
      let matches = selectors.compactMap { resolveChat($0, in: workspace) }
      guard !selectors.isEmpty, matches.count == selectors.count else {
        await terminal.line("Usage: /chat del INDEX|ID|TITLE [...] (permanent; /chat archive keeps it)")
        return
      }
      var deletedIDs: Set<UUID> = []
      for chat in matches where deletedIDs.insert(chat.id).inserted {
        _ = workspace.removeChat(id: chat.id)
        if chat.id != session.id {
          await terminal.line("Deleted '\(chat.displayTitle)'.")
        }
      }
      guard deletedIDs.contains(session.id) else {
        return
      }
      let title = session.chat.displayTitle
      if let next = workspace.activeChats.first ?? workspace.orderedChats.first {
        _ = workspace.selectChat(id: next.id)
        session = REPLSession(chat: next)
        await terminal.line("Deleted '\(title)'; switched to '\(session.title)'.")
      } else {
        session = REPLSession(
          chat: workspace.startNewChat(primaryAgent: session.profile.agentDefinition))
        await terminal.line("Deleted '\(title)'; started a new chat.")
      }
    case "files":
      guard rest.isEmpty else {
        await terminal.line("Usage: /chat files")
        return
      }
      let files = session.fileAccessLog.snapshot()
      await terminal.line(files.isEmpty ? "No recorded file accesses in this conversation."
        : files.joined(separator: "\n"))
      await terminal.line("Recorded Files tool accesses and attachments; shell-internal accesses are not tracked. Older chats may have incomplete records.")
    case "compact", "recap", "clear":
      await handleChatCommand(
        argument,
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        recapPrompt: configuration?.prompts?.recap,
        chatProcess: chatProcess,
        terminal: terminal)
    case "help":
      await terminal.line(chatHelp)
    case "close":
      await terminal.line("/chat close is now /chat del INDEX|ID|TITLE [...].")
    case "messages", "log", "last", "pins", "pinlist", "edit", "undo", "trim", "rewind", "chop":
      await terminal.line("Message actions moved to /msg: use /msg \(action == "messages" ? "list" : action).")
    default:
      await terminal.line("Unknown /chat action '\(action)'.\n\n\(chatHelp)")
    }
  }

  static func switchSession(
    to chat: AgentChat,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    terminal: TerminalWriter
  ) async {
    _ = workspace.selectChat(id: chat.id)
    session = REPLSession(chat: chat)
    let status = chat.isArchived ? ", archived" : ""
    await terminal.line(
      "Switched to '\(chat.displayTitle)' (agent \(chat.primaryAgent.id)\(status)).")
    let count =
      chat.historyWindow?.conversationCount ?? chat.historyWindow?.totalCount
      ?? chat.conversationMessages.count
    await terminal.line(
      "Started: \(ChatDatePresentation.timestamp(chat.createdAt)) · \(count) message\(count == 1 ? "" : "s")")
  }

  enum ChatListScope {
    case active, archived, all

    init?(_ raw: String) {
      switch raw.lowercased() {
      case "", "all": self = .all
      case "active", "open": self = .active
      case "archived", "archive", "old": self = .archived
      default: return nil
      }
    }
  }

  /// Numeric selectors follow creation order, independent of pin/archive state
  /// and subsequent activity. Grouping only changes where a row is displayed.
  static func chronologicalChats(_ workspace: AgentChatWorkspace) -> [AgentChat] {
    workspace.chats.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  static func chatListing(
    _ workspace: AgentChatWorkspace,
    scope: ChatListScope,
    selectedID: UUID?,
    now: Date = Date(),
    terminal: TerminalWriter
  ) async -> String {
    let ordered = chronologicalChats(workspace)
    var lines: [String] = []
    func append(_ chats: [AgentChat], header: (AgentChat) -> String) async {
      var previous: String?
      for chat in chats {
        let title = header(chat)
        if title != previous {
          lines.append(await terminal.paintHeading(title))
          previous = title
        }
        let index = (ordered.firstIndex { $0.id == chat.id } ?? 0) + 1
        lines.append(await chatRow(chat, index: index, selected: chat.id == selectedID, now: now, terminal: terminal))
      }
    }
    if scope != .archived {
      let active = ordered.filter { !$0.isArchived }
      if active.isEmpty { lines.append("No active chats.") }
      await append(active.filter(\.isPinned)) { _ in "Pinned" }
      await append(active.filter { !$0.isPinned }) {
        ChatDatePresentation.groupTitle(for: $0.createdAt, relativeTo: now)
      }
    }
    if scope != .active {
      let archived = ordered.filter(\.isArchived)
      if archived.isEmpty, scope == .archived { lines.append("No archived chats.") }
      await append(archived) { _ in "Archived" }
    }
    return lines.joined(separator: "\n")
  }

  private static func chatRow(
    _ chat: AgentChat, index: Int, selected: Bool, now: Date, terminal: TerminalWriter
  ) async -> String {
    let marker = selected ? "*" : " "
    let number = index < 10 ? " \(index)" : "\(index)"
    let count =
      chat.historyWindow?.conversationCount ?? chat.historyWindow?.totalCount
      ?? chat.conversationMessages.count
    let size = count == 0 ? "empty" : "\(count) msg"
    return [
      await terminal.paint("\(marker) \(number)", role: selected ? .successForeground : .infoForeground, bold: selected),
      await terminal.paint(String(chat.id.uuidString.prefix(8)), role: .thinkingForeground),
      await terminal.paint(
        padded((chat.isPinned ? "📌 " : "") + chat.displayTitle, width: 40),
        role: selected ? .successForeground : chat.isPinned ? .warningForeground : .foreground,
        bold: selected || chat.isPinned),
      await terminal.paint(padded(chat.primaryAgent.id, width: 10), role: .toolCallForeground),
      await terminal.paint(padded(size, width: 8), role: .thinkingForeground),
      await terminal.paint(
        ChatDatePresentation.compactTimestamp(chat.createdAt, relativeTo: now), role: .thinkingForeground),
    ].joined(separator: "  ")
  }

  private static func chatInfo(
    _ chat: AgentChat,
    workspace: AgentChatWorkspace,
    selectedID: UUID?
  ) -> String {
    let index = (chronologicalChats(workspace).firstIndex { $0.id == chat.id } ?? 0) + 1
    let count =
      chat.historyWindow?.conversationCount ?? chat.historyWindow?.totalCount
      ?? chat.conversationMessages.count
    var status = chat.isArchived ? "archived" : "active"
    if chat.isPinned { status += ", pinned" }
    if chat.id == selectedID { status += ", current" }
    var lines = [
      "Title:    \(chat.displayTitle)",
      "Index:    \(index)",
      "ID:       \(chat.id.uuidString)",
      "Session:  \(chat.sessionID)",
      "Agent:    \(chat.primaryAgent.id) (\(chat.primaryAgent.provider) / \(chat.primaryAgent.model))",
      "Messages: \(count) conversation, \(chat.messages.count) total",
      "Started:  \(ChatDatePresentation.timestamp(chat.createdAt))",
      "Updated:  \(ChatDatePresentation.timestamp(chat.updatedAt)) (\(ChatDatePresentation.groupTitle(for: chat.updatedAt)))",
      "Status:   \(status)",
    ]
    if !chat.pendingContent.isEmpty {
      lines.append("Pending:  \(chat.pendingContent.count) attachment(s) queued")
    }
    if !chat.subagents.isEmpty {
      let running = chat.subagents.filter { !$0.state.isTerminal }.count
      lines.append(
        "Agents:   \(chat.subagents.count) started by its runs"
          + (running > 0 ? ", \(running) still running when last saved" : "")
          + " (/jobs tree lists them)")
    }
    return lines.joined(separator: "\n")
  }

  static func padded(_ text: String, width: Int) -> String {
    let count = text.count
    guard count <= width else { return String(text.prefix(width - 3)) + "..." }
    return text + String(repeating: " ", count: width - count)
  }

  static func resolveChat(
    _ selector: String,
    in workspace: AgentChatWorkspace
  ) -> AgentChat? {
    let ordered = chronologicalChats(workspace)
    if let index = ListIndex.resolve(selector, count: ordered.count) {
      return ordered[index]
    }
    if let id = UUID(uuidString: selector) {
      return ordered.first { $0.id == id }
    }
    let idMatches = ordered.filter {
      $0.id.uuidString.lowercased().hasPrefix(selector.lowercased())
    }
    if idMatches.count == 1 { return idMatches[0] }
    let titleMatches = ordered.filter {
      $0.displayTitle.caseInsensitiveCompare(selector) == .orderedSame
    }
    return titleMatches.count == 1 ? titleMatches[0] : nil
  }

  /// Chat-level transcript actions: summarize or clear the active chat.
  static func handleChatCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    compactPrompt: String?,
    recapPrompt: String?,
    chatProcess: AgentPID? = nil,
    terminal: TerminalWriter,
    announceCompaction: Bool = true
  ) async {
    let parts = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = parts.first?.lowercased() ?? ""
    let actionArgument = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    switch action {
    case "compact", "recap":
      guard action != "recap" || actionArgument.isEmpty else {
        await terminal.line("Usage: /chat recap")
        return
      }
      await summarizeChat(
        recap: action == "recap",
        focus: actionArgument,
        promptTemplate: action == "recap" ? recapPrompt : compactPrompt,
        session: &session,
        runtime: runtime,
        terminal: terminal, announceCompaction: announceCompaction)
    case "clear":
      session.reset()
      if let chatProcess { await runtime.supervisor.clearFinished(under: chatProcess) }
      await terminal.line("Conversation cleared.")
    default:
      await terminal.line(chatHelp)
    }
  }
}
