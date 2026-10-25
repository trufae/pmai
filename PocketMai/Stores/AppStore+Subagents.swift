import Foundation
import MaiCore

/// The app's side of the agent process table: which process a conversation
/// runs as, what its children are doing, and the controls the chat offers
/// over them. Processes are session state, like pmai's; durable records are
/// merged into `Conversation.subagents` and restored under fresh pids.
extension AppStore {
  /// Mirrors the supervisor's table into `agentProcesses` as it changes, so
  /// views follow children without polling.
  func startAgentSupervisorFeed() {
    Task { [weak self] in
      guard let self else { return }
      let events = await agentSupervisor.events()
      for await event in events {
        await refreshAgentProcesses()
        if case .finished(let process) = event {
          await saveAgentProcessRecords(containing: process.pid)
          drainThenQueue()
        }
      }
    }
  }

  func refreshAgentProcesses() async {
    let processes = await agentSupervisor.processes()
    if processes != agentProcesses {
      agentProcesses = processes
    }
  }

  /// Rehydrates a saved process tree when its conversation becomes active.
  /// The regular `agentProcessID` path also calls this before a later turn,
  /// so records are available even when a host opens the chat indirectly.
  func restoreAgentProcessRecordsIfNeeded(for conversation: Conversation) async {
    guard !conversation.subagents.isEmpty else { return }
    _ = await agentProcessID(
      for: conversation,
      agentName: settings.selectedAgent.name)
  }

  // MARK: - Conversation processes

  /// The process a conversation's turns run as, registered the first time an
  /// agent tool asks for it. Children hang off it, and `agent_status` lists
  /// them from it.
  func agentProcessID(for conversation: Conversation, agentName: String) async -> AgentPID {
    if let pid = agentProcessIDs[conversation.id], await agentSupervisor.info(pid) != nil {
      return pid
    }
    let pid = await agentSupervisor.register(
      runID: UUID(),
      parent: nil,
      agentID: agentName,
      displayName: agentName,
      task: conversation.displayTitle,
      depth: 0)
    // Two agent calls of one reply ask at once; the first registration to
    // land is the chat's process and the other is dropped, so every child
    // hangs off the same root.
    if let existing = agentProcessIDs[conversation.id], existing != pid,
      await agentSupervisor.info(existing) != nil
    {
      await agentSupervisor.forget(pid)
      return existing
    }
    agentProcessIDs[conversation.id] = pid
    if !conversation.subagents.isEmpty {
      await agentSupervisor.restore(conversation.subagents, under: pid)
      await refreshAgentProcesses()
    }
    return pid
  }

  func registerAgentProcess(_ pid: AgentPID, for conversationID: UUID) {
    agentProcessIDs[conversationID] = pid
  }

  func forgetAgentProcess(for conversationID: UUID) {
    agentProcessIDs[conversationID] = nil
  }

  /// Puts a conversation's process back to work for a new turn, keeping the
  /// children earlier turns started.
  func reopenAgentProcess(for conversationID: UUID) {
    guard let pid = agentProcessIDs[conversationID] else { return }
    let task = conversation(withID: conversationID)?.displayTitle ?? ""
    Task {
      if await !agentSupervisor.reopen(pid, runID: UUID(), task: task) {
        agentProcessIDs[conversationID] = nil
      }
    }
  }

  /// Marks a conversation's process idle at the end of a turn. Background
  /// children carry on; the next turn can still collect them.
  func completeAgentProcess(for conversationID: UUID) {
    guard let pid = agentProcessIDs[conversationID] else { return }
    Task {
      await agentSupervisor.complete(pid)
      await saveAgentProcessRecords(for: conversationID, under: pid)
    }
  }

  /// The exportable conversation with the latest live process records folded
  /// into its durable records. Records already pruned from this session stay
  /// present, while current copies replace the same durable run identity.
  func conversationIncludingAgentRecords(_ conversation: Conversation) async -> Conversation {
    var result = conversation
    guard let pid = agentProcessIDs[conversation.id], await agentSupervisor.info(pid) != nil else {
      return result
    }
    result.subagents = AgentProcessRecord.merging(
      saved: result.subagents,
      current: await agentSupervisor.records(under: pid))
    return result
  }

  private func saveAgentProcessRecords(containing pid: AgentPID) async {
    let tree = await agentSupervisor.tree()
    guard let entry = agentProcessIDs.first(where: { _, root in
      tree.subtree(of: root).contains { $0.pid == pid }
    }) else { return }
    await saveAgentProcessRecords(for: entry.key, under: entry.value)
  }

  private func saveAgentProcessRecords(for conversationID: UUID, under pid: AgentPID) async {
    let current = await agentSupervisor.records(under: pid)
    mergeAgentProcessRecords(current, into: conversationID)
  }

  /// A child started without waiting reports into the chat's inbox. When the
  /// model has answered with such a child still working, the turn holds here
  /// instead of ending with the work unfinished — or breaks off for a message
  /// the person queued meanwhile — then folds what the children delivered
  /// into the chat as user messages with a fresh assistant message after
  /// them, the way queued user messages are folded in. Nil when nothing is
  /// on its way: a chat that never used an agent tool has no process and is
  /// untouched.
  func awaitAgentDeliveriesAndAppendAssistant(in conversationID: UUID) async throws -> UUID? {
    guard let pid = agentProcessIDs[conversationID] else { return nil }
    // Holds while any child works, so one turn takes every delivery in
    // rather than one turn per child — unless a person's message is waiting,
    // in the chat's own queue or in the process's inbox, which wins.
    while true {
      if hasQueuedUserMessages(in: conversationID) {
        return injectQueuedUserMessagesAndAppendAssistant(in: conversationID)
      }
      let queued = await agentSupervisor.queuedMessages(for: pid)
      if queued.contains(where: { AgentProcessTools.deliveredChildPID(of: $0.message) == nil }) {
        break
      }
      let working = await agentSupervisor.tree().children(of: pid).contains {
        !$0.state.isTerminal
      }
      guard working else {
        guard !queued.isEmpty else { return nil }
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let delivered = await agentSupervisor.drainInbox(pid).filter { $0.role == .user }
    for message in delivered {
      if let child = AgentProcessTools.deliveredChildPID(of: message) {
        await agentSupervisor.collect(child)
      }
    }
    return appendUserMessagesAndAssistant(delivered.map(\.text), in: conversationID)
  }

  /// Kills everything a conversation started, for a chat that is going away.
  func stopAgentProcesses(for conversationID: UUID, reason: String = "Chat closed") {
    guard let pid = agentProcessIDs.removeValue(forKey: conversationID) else { return }
    Task {
      let stopped = await agentSupervisor.stop(pid, reason: reason)
      await saveAgentProcessRecords(for: conversationID, under: pid)
      for victim in stopped.reversed() {
        await agentSupervisor.forget(victim)
      }
      await refreshAgentProcesses()
    }
  }

  func stopAllAgentProcesses(reason: String = "Chats cleared") {
    for conversationID in Array(agentProcessIDs.keys) {
      stopAgentProcesses(for: conversationID, reason: reason)
    }
  }

  // MARK: - What the chat shows

  /// The children of a conversation, parents before their own children, in
  /// the order they were started.
  func agentChildren(of conversationID: UUID?) -> [AgentProcessInfo] {
    guard let conversationID, let root = agentProcessIDs[conversationID] else { return [] }
    return Array(AgentProcessTree(agentProcesses).subtree(of: root).dropFirst())
  }

  func hasLiveAgentChildren(in conversationID: UUID?) -> Bool {
    agentChildren(of: conversationID).contains { !$0.state.isTerminal }
  }

  func agentTranscript(_ pid: AgentPID) async -> [AgentMessage] {
    await agentSupervisor.transcript(pid)
  }

  func agentTranscriptPage(_ pid: AgentPID, before: Int? = nil) async -> AgentTranscriptPage? {
    do { return try await agentSupervisor.transcriptPage(pid, before: before) } catch {
      errorMessage = error.localizedDescription; return nil
    }
  }

  // MARK: - Controls

  func stopAgentProcess(_ pid: AgentPID) {
    Task { await agentSupervisor.stop(pid, reason: "Stopped from the chat") }
  }

  func pauseAgentProcess(_ pid: AgentPID) {
    Task { await agentSupervisor.pause(pid) }
  }

  func resumeAgentProcess(_ pid: AgentPID) {
    Task { await agentSupervisor.resume(pid) }
  }

  /// Stops and removes one child subtree from both the live supervisor and
  /// the conversation's durable records. Interrupting alone deliberately
  /// keeps the transcript; deletion is the explicit destructive operation.
  func deleteAgentProcess(_ pid: AgentPID, from conversationID: UUID?) {
    guard let conversationID,
      let selected = agentProcesses.first(where: { $0.pid == pid })
    else { return }
    Task {
      let subtree = await agentSupervisor.tree().subtree(of: pid)
      var deletedRunIDs = Set(subtree.map(\.runID))
      deletedRunIDs.insert(selected.runID)
      let stopped = await agentSupervisor.stop(pid, reason: "Deleted from the chat")
      for victim in stopped.reversed() {
        await agentSupervisor.forget(victim)
      }
      await refreshAgentProcesses()

      removeAgentProcessRecordSubtrees(
        rootedAt: deletedRunIDs, from: conversationID)
    }
  }

  /// Queues a message a running child reads before its next model turn.
  func sendMessageToAgentProcess(_ pid: AgentPID, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    Task { await agentSupervisor.post(.user(trimmed), to: pid) }
  }

  /// Forgets the finished children of a conversation, so its process list
  /// shows only what is running.
  func clearFinishedAgentProcesses(in conversationID: UUID?) {
    let tree = AgentProcessTree(agentProcesses)
    // A finished child whose background children still run stays listed
    // with them, so nothing is orphaned.
    let finished = agentChildren(of: conversationID).filter { child in
      tree.subtree(of: child.pid).allSatisfy(\.state.isTerminal)
    }
    guard !finished.isEmpty else { return }
    Task {
      if let conversationID, let root = agentProcessIDs[conversationID] {
        await saveAgentProcessRecords(for: conversationID, under: root)
      }
      for process in finished.reversed() {
        await agentSupervisor.forget(process.pid)
      }
      await refreshAgentProcesses()
    }
  }
}
