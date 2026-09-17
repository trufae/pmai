import Foundation

/// What a host learns about the process table without polling it.
public enum AgentSupervisorEvent: Equatable, Sendable {
  case started(AgentProcessInfo)
  case changed(AgentProcessInfo)
  /// Raised when a process needs a human, and again with a nil attention when
  /// it stops needing one.
  case attention(AgentProcessInfo)
  case finished(AgentProcessInfo)
}

/// A user message waiting for the next model turn of one process.
public struct AgentQueuedMessage: Equatable, Sendable, Identifiable {
  public var id: UUID
  public var pid: AgentPID
  public var message: AgentMessage
  public var queuedAt: Date

  public init(id: UUID = UUID(), pid: AgentPID, message: AgentMessage, queuedAt: Date = Date()) {
    self.id = id
    self.pid = pid
    self.message = message
    self.queuedAt = queuedAt
  }
}

/// The process table for one session: which agents are running, how they are
/// related, what they are waiting for, and how to stop them.
///
/// `AgentRuntime` writes to it as runs progress; hosts read it for `/agents`,
/// follow `events` for notifications, and call `stop` to kill a subtree.
/// Nothing here is persisted — pids are session-scoped by design. A host that
/// wants a chat's agents back after a restart saves `records(under:)` with
/// the chat and hands them to `restore(_:under:)`, which lists them again
/// under fresh pids without ever running them.
public actor AgentSupervisor {
  private struct Entry {
    var info: AgentProcessInfo
    var handle: Task<AgentResult, Error>?
    var transcript: [AgentMessage] = []
    var result: AgentResult?
  }

  /// How many finished processes to keep for inspection before the oldest are
  /// dropped. A finished process with live descendants is always kept.
  private let finishedRetention: Int
  private var entries: [AgentPID: Entry] = [:]
  /// Messages posted to a process that its run has not read yet, oldest first.
  private var inboxes: [AgentPID: [AgentQueuedMessage]] = [:]
  /// Context edits a process asked for and its run has not applied yet.
  private var transcriptEdits: [AgentPID: [AgentTranscriptEdit]] = [:]
  /// Processes a person has held; their runs wait at the next turn boundary.
  private var paused: Set<AgentPID> = []
  private var nextPID = 1
  private var subscribers: [UUID: AsyncStream<AgentSupervisorEvent>.Continuation] = [:]

  public init(finishedRetention: Int = 32) {
    self.finishedRetention = max(1, finishedRetention)
  }

  // MARK: - Host API

  public func tree() -> AgentProcessTree {
    AgentProcessTree(entries.values.map(\.info))
  }

  public func processes() -> [AgentProcessInfo] {
    entries.values.map(\.info).sorted { $0.pid < $1.pid }
  }

  public func info(_ pid: AgentPID) -> AgentProcessInfo? {
    entries[pid]?.info
  }

  /// Processes still running or waiting, newest first.
  public func liveProcesses() -> [AgentProcessInfo] {
    processes().filter { !$0.state.isTerminal }.reversed()
  }

  /// Processes waiting on somebody, so a host can badge or announce them.
  public func processesNeedingAttention() -> [AgentProcessInfo] {
    processes().filter(\.needsAttention)
  }

  /// The child's own conversation, for `/agents log`. Empty until it produces
  /// one; a finished process keeps the transcript it ended with.
  public func transcript(_ pid: AgentPID) -> [AgentMessage] {
    entries[pid]?.transcript ?? []
  }

  public func result(_ pid: AgentPID) -> AgentResult? {
    entries[pid]?.result
  }

  /// A stream of table changes. Each subscriber gets its own buffered stream;
  /// dropping it unsubscribes.
  public func events() -> AsyncStream<AgentSupervisorEvent> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.unsubscribe(id) }
      }
    }
  }

  /// Cancels a process and everything under it, so no orphan keeps running
  /// with nobody waiting for its answer. Returns what was stopped.
  @discardableResult
  public func stop(_ pid: AgentPID, reason: String = "Stopped") -> [AgentPID] {
    let doomed = tree().subtree(of: pid).map(\.pid)
    for victim in doomed.reversed() {
      guard var entry = entries[victim] else { continue }
      entry.handle?.cancel()
      entry.handle = nil
      entries[victim] = entry
      paused.remove(victim)
      guard !entry.info.state.isTerminal else { continue }
      transition(victim, to: .cancelled, failure: reason, attention: nil, finished: true)
    }
    return doomed
  }

  /// Holds a process and everything under it, the way SIGSTOP holds a Unix
  /// process. Each run finishes the model call or tool it is in, then waits
  /// at its next turn boundary until `resume`, keeping its transcript, its
  /// children, and its inbox; messages posted meanwhile are read when it
  /// continues. A process already waiting on a person keeps showing that and
  /// pauses once they have answered. Returns what was held.
  @discardableResult
  public func pause(_ pid: AgentPID) -> [AgentPID] {
    var held: [AgentPID] = []
    for process in tree().subtree(of: pid)
    where !process.state.isTerminal && !paused.contains(process.pid) {
      paused.insert(process.pid)
      held.append(process.pid)
      guard var entry = entries[process.pid], entry.info.attention == nil else { continue }
      entry.info.state = .paused
      entry.info.updatedAt = Date()
      entries[process.pid] = entry
      publish(.changed(entry.info))
    }
    return held
  }

  /// Lets a paused process and everything under it carry on from where they
  /// stopped. Returns what was released.
  @discardableResult
  public func resume(_ pid: AgentPID) -> [AgentPID] {
    var released: [AgentPID] = []
    for process in tree().subtree(of: pid) where paused.contains(process.pid) {
      paused.remove(process.pid)
      released.append(process.pid)
      guard var entry = entries[process.pid], entry.info.state == .paused else { continue }
      entry.info.state = .running
      entry.info.updatedAt = Date()
      entries[process.pid] = entry
      publish(.changed(entry.info))
    }
    return released
  }

  public func isPaused(_ pid: AgentPID) -> Bool {
    paused.contains(pid)
  }

  /// Forgets terminal processes that nothing depends on any more.
  public func prune() {
    pruneFinished()
  }

  /// Forgets every finished process whose whole subtree has finished and
  /// that nothing is queued for, so a listing shows only what is running.
  /// Returns the pids dropped, lowest first. A host that kept one of them
  /// for a chat gets a fresh process at that chat's next turn, the way it
  /// does for any stale pid.
  @discardableResult
  public func clearFinished() -> [AgentPID] {
    let removable = removableFinished()
    for process in removable { forget(process.pid) }
    return removable.map(\.pid)
  }

  /// Forgets the finished processes under `pid` that nothing depends on any
  /// more, keeping `pid` itself, so a chat whose conversation was cleared
  /// lists only what still runs for it. Returns the pids dropped.
  @discardableResult
  public func clearFinished(under pid: AgentPID) -> [AgentPID] {
    let within = Set(tree().subtree(of: pid).dropFirst().map(\.pid))
    let removable = removableFinished().filter { within.contains($0.pid) }
    for process in removable { forget(process.pid) }
    return removable.map(\.pid)
  }

  // MARK: - Saving and restoring

  /// The processes under `pid`, parents before children, as records a host
  /// saves with its chat: what the table knows of each, plus its transcript.
  /// `parentRunID` names a record's parent among them; nil marks a direct
  /// child of `pid`, whose own run id changes with every turn.
  public func records(under pid: AgentPID) -> [AgentProcessRecord] {
    let snapshot = tree()
    return snapshot.subtree(of: pid).dropFirst().map { process in
      let parentRunID = process.parent.flatMap { $0 == pid ? nil : snapshot.info($0)?.runID }
      return AgentProcessRecord(
        process: process,
        messages: entries[process.pid]?.transcript ?? [],
        parentRunID: parentRunID)
    }
  }

  /// What a restored process that was still running when its record was
  /// written says for itself: the session that ran it is gone.
  public static let restoredWhileRunning = "its run ended with the session that started it"

  /// Puts records a host saved back in the table under `parent` — a chat's
  /// own process — with fresh pids, so they are listed, read, and exported
  /// like the processes of this session. Records come parents before
  /// children, and a child whose `parentRunID` is not among them hangs off
  /// `parent`. A process that was still running when it was saved is listed
  /// as cancelled, with `restoredWhileRunning` as its reason, since the run
  /// that owned it is gone; nothing restored is ever run again. Answers the
  /// pids given, in the records' order; an unknown `parent` restores nothing.
  @discardableResult
  public func restore(_ records: [AgentProcessRecord], under parent: AgentPID) -> [AgentPID] {
    guard let root = entries[parent] else { return [] }
    var pidsByRunID: [UUID: AgentPID] = [:]
    var assigned: [AgentPID] = []
    for record in records {
      let pid = AgentPID(nextPID)
      nextPID += 1
      let parentPID = record.parentRunID.flatMap { pidsByRunID[$0] } ?? parent
      let depth = (entries[parentPID]?.info.depth ?? root.info.depth) + 1
      let ended = record.state.isTerminal
      let info = AgentProcessInfo(
        pid: pid,
        parent: parentPID,
        runID: record.runID,
        agentID: record.agentID,
        displayName: record.displayName,
        task: record.task,
        state: ended ? record.state : .cancelled,
        depth: depth,
        startedAt: record.startedAt,
        runStartedAt: record.startedAt,
        updatedAt: record.updatedAt,
        finishedAt: record.finishedAt ?? record.updatedAt,
        modelTurns: record.modelTurns,
        toolCalls: record.toolCalls,
        usage: record.usage,
        failure: ended ? record.failure : Self.restoredWhileRunning,
        isCollected: true)
      entries[pid] = Entry(info: info, transcript: record.messages)
      pidsByRunID[record.runID] = pid
      assigned.append(pid)
      publish(.started(info))
    }
    pruneFinished()
    return assigned
  }

  // MARK: - Inbox

  /// Queues a message for a process. The run reads it at its next model turn —
  /// in the middle of a tool loop if that is where it is — so a person can
  /// steer a running agent instead of waiting for it to finish. A message for
  /// an idle top-level process stays queued until its host starts the next
  /// turn. Returns nil when the pid is unknown.
  @discardableResult
  public func post(_ message: AgentMessage, to pid: AgentPID) -> AgentQueuedMessage? {
    guard entries[pid] != nil else { return nil }
    let queued = AgentQueuedMessage(pid: pid, message: message)
    inboxes[pid, default: []].append(queued)
    noteInboxChanged(pid)
    return queued
  }

  /// What is waiting for one process, oldest first.
  public func queuedMessages(for pid: AgentPID) -> [AgentQueuedMessage] {
    inboxes[pid] ?? []
  }

  /// Everything waiting for any process, oldest first.
  public func queuedMessages() -> [AgentQueuedMessage] {
    inboxes.values.flatMap { $0 }.sorted { $0.queuedAt < $1.queuedAt }
  }

  public func hasQueuedMessages(_ pid: AgentPID) -> Bool {
    !(inboxes[pid]?.isEmpty ?? true)
  }

  /// Drops one queued message before the run reads it.
  @discardableResult
  public func discardQueuedMessage(id: UUID) -> AgentQueuedMessage? {
    for (pid, queue) in inboxes {
      guard let index = queue.firstIndex(where: { $0.id == id }) else { continue }
      let removed = queue[index]
      inboxes[pid]?.remove(at: index)
      noteInboxChanged(pid)
      return removed
    }
    return nil
  }

  /// Drops the most recently queued message of a process — or of any process
  /// when no pid is given — before the run reads it.
  @discardableResult
  public func discardLastQueuedMessage(for pid: AgentPID? = nil) -> AgentQueuedMessage? {
    let target = pid ?? queuedMessages().last?.pid
    guard let target, let removed = inboxes[target]?.popLast() else { return nil }
    noteInboxChanged(target)
    return removed
  }

  /// Empties the inbox of one process, or of every process when no pid is
  /// given. Returns what was dropped.
  @discardableResult
  public func clearQueuedMessages(for pid: AgentPID? = nil) -> [AgentQueuedMessage] {
    let targets = pid.map { [$0] } ?? Array(inboxes.keys)
    var dropped: [AgentQueuedMessage] = []
    for target in targets {
      guard let queue = inboxes.removeValue(forKey: target), !queue.isEmpty else { continue }
      dropped.append(contentsOf: queue)
      noteInboxChanged(target)
    }
    return dropped.sorted { $0.queuedAt < $1.queuedAt }
  }

  /// Takes everything queued for a process, for the run to append to its
  /// transcript. Hosts that start a turn themselves use this to fold queued
  /// messages into the request.
  public func drainInbox(_ pid: AgentPID, excluding held: Set<UUID> = []) -> [AgentMessage] {
    // Cancellation can arrive while the caller is waiting to enter this actor.
    guard !Task.isCancelled, let queue = inboxes[pid], !queue.isEmpty else { return [] }
    let delivered = queue.filter { !held.contains($0.id) }
    inboxes[pid] = queue.filter { held.contains($0.id) }
    noteInboxChanged(pid)
    return delivered.map(\.message)
  }

  // MARK: - Context edits

  /// Queues an edit of a process's own transcript, applied by its run before
  /// the next model turn. Returns false when the pid is unknown.
  @discardableResult
  public func post(edit: AgentTranscriptEdit, to pid: AgentPID) -> Bool {
    guard entries[pid] != nil else { return false }
    transcriptEdits[pid, default: []].append(edit)
    return true
  }

  public func pendingTranscriptEdits(_ pid: AgentPID) -> [AgentTranscriptEdit] {
    transcriptEdits[pid] ?? []
  }

  /// Takes the queued edits, for the run to apply.
  public func drainTranscriptEdits(_ pid: AgentPID) -> [AgentTranscriptEdit] {
    transcriptEdits.removeValue(forKey: pid) ?? []
  }

  private func noteInboxChanged(_ pid: AgentPID) {
    guard var entry = entries[pid] else { return }
    let count = inboxes[pid]?.count ?? 0
    guard entry.info.queuedMessages != count else { return }
    entry.info.queuedMessages = count
    entry.info.updatedAt = Date()
    entries[pid] = entry
    publish(.changed(entry.info))
  }

  // MARK: - Run API

  // What a run reports as it goes. `AgentRuntime` calls these for the runs it
  // drives; a host with a tool loop of its own calls them the same way, so
  // its processes are listed, stopped, and steered like any other.

  public func register(
    runID: UUID,
    parent: AgentPID?,
    agentID: String,
    displayName: String? = nil,
    task: String = "",
    depth: Int
  ) -> AgentPID {
    let pid = AgentPID(nextPID)
    nextPID += 1
    let info = AgentProcessInfo(
      pid: pid,
      parent: parent,
      runID: runID,
      agentID: agentID,
      displayName: displayName,
      task: task,
      state: .starting,
      depth: depth)
    entries[pid] = Entry(info: info)
    publish(.started(info))
    pruneFinished()
    return pid
  }

  /// Puts an existing process back to work for another turn, keeping its pid
  /// and its children. A chat is one process across its whole life, so a
  /// background child started three turns ago is still addressable by the run
  /// that started it. Answers false when the pid is gone.
  public func reopen(_ pid: AgentPID, runID: UUID, task: String) -> Bool {
    guard var entry = entries[pid] else { return false }
    entry.info.runID = runID
    entry.info.task = task
    entry.info.state = effectiveState(.running, for: pid)
    entry.info.attention = nil
    entry.info.failure = nil
    entry.info.finishedAt = nil
    entry.info.runStartedAt = Date()
    entry.info.isCollected = false
    entry.info.modelTurns = 0
    entry.info.toolCalls = 0
    entry.info.activity = ""
    entry.info.updatedAt = Date()
    entry.result = nil
    entries[pid] = entry
    publish(.changed(entry.info))
    return true
  }

  public func attach(_ handle: Task<AgentResult, Error>, to pid: AgentPID) {
    entries[pid]?.handle = handle
  }

  /// Lets a registered child run when fewer than `limit` of its parent
  /// agent's other children are running and no older sibling is still
  /// waiting; otherwise marks it `queued` and answers false. The runtime asks
  /// again from the child's own task until the answer is yes, the way a
  /// paused run polls `isPaused`, so a slot that frees up is taken in pid
  /// order and a stopped child simply stops asking.
  public func admit(_ pid: AgentPID, limit: Int) -> Bool {
    guard var entry = entries[pid], !entry.info.state.isTerminal else { return false }
    guard let parent = entry.info.parent else {
      return true
    }
    // Recursive instances share a definition, but each parent has its own slots.
    let siblings = entries.values.lazy.map(\.info).filter {
      $0.parent == parent && $0.pid != pid && !$0.state.isTerminal
    }
    let running = siblings.filter { $0.state != .queued }.count
    let olderWaiting = siblings.contains { $0.state == .queued && $0.pid < pid }
    if running < limit, !olderWaiting {
      guard entry.info.state == .queued else { return true }
      entry.info.state = .starting
      // The wait was not the run; what a listing shows as elapsed starts now.
      entry.info.runStartedAt = Date()
      entry.info.updatedAt = Date()
      entries[pid] = entry
      publish(.changed(entry.info))
      return true
    }
    guard entry.info.state != .queued else { return false }
    entry.info.state = .queued
    entry.info.updatedAt = Date()
    entries[pid] = entry
    publish(.changed(entry.info))
    return false
  }

  /// The task running one process, so a caller can await it without holding
  /// the supervisor for the whole run.
  public func handle(_ pid: AgentPID) -> Task<AgentResult, Error>? {
    entries[pid]?.handle
  }

  /// Records progress. Every argument is optional so callers update only what
  /// they know, and an unchanged table publishes nothing.
  public func note(
    _ pid: AgentPID,
    state: AgentProcessState? = nil,
    modelTurns: Int? = nil,
    toolCalls: Int? = nil,
    usage: TokenUsage? = nil,
    activity: String? = nil,
    transcript: [AgentMessage]? = nil
  ) {
    guard var entry = entries[pid] else { return }
    let previous = entry.info
    if let state, !entry.info.state.isTerminal {
      entry.info.state = effectiveState(state, for: pid)
    }
    if let modelTurns { entry.info.modelTurns = modelTurns }
    if let toolCalls { entry.info.toolCalls = toolCalls }
    if let usage { entry.info.usage = usage }
    if let activity { entry.info.activity = activity }
    if let transcript { entry.transcript = transcript }
    entry.info.updatedAt = Date()
    entries[pid] = entry
    if previous != entry.info { publish(.changed(entry.info)) }
  }

  /// Marks a process as needing a human. The matching state follows from the
  /// kind of attention, so a run blocked on a synchronous approval prompt still
  /// shows as `approve?` in a listing.
  public func raise(_ attention: AgentAttention, for pid: AgentPID) {
    guard var entry = entries[pid] else { return }
    entry.info.attention = attention
    if let state = attention.implicitState, !entry.info.state.isTerminal {
      entry.info.state = state
    }
    entry.info.updatedAt = Date()
    entries[pid] = entry
    publish(.attention(entry.info))
  }

  public func clearAttention(for pid: AgentPID, resuming state: AgentProcessState? = .running) {
    guard var entry = entries[pid], entry.info.attention != nil else { return }
    entry.info.attention = nil
    if let state, !entry.info.state.isTerminal {
      entry.info.state = effectiveState(state, for: pid)
    }
    entry.info.updatedAt = Date()
    entries[pid] = entry
    publish(.attention(entry.info))
  }

  public func finish(_ pid: AgentPID, result: AgentResult, announce: Bool) {
    guard var entry = entries[pid] else { return }
    entry.transcript = result.transcript
    entry.result = result
    entry.info.modelTurns = result.modelTurns
    entry.info.toolCalls = result.toolCalls
    entry.info.usage = result.usage ?? entry.info.usage
    entry.handle = nil
    entries[pid] = entry
    // A process somebody stopped keeps saying so, whatever its run reports
    // on the way out; the transcript it ended with is kept for inspection.
    guard !entry.info.state.isTerminal else { return }
    // A run a limit paused is listed as stopped, with the limit as its reason,
    // so a person can tell it from one that answered.
    if let interruption = result.interruption {
      transition(
        pid,
        to: .interrupted,
        failure: interruption.summary,
        attention: announce ? .error(interruption.summary) : nil,
        finished: true)
      return
    }
    // A background answer nobody asked for yet is exactly the case a host
    // should surface; a blocking child's answer goes straight to its parent.
    let attention: AgentAttention? =
      announce ? .finished(AgentProcessInfo.oneLine(result.response.text, limit: 80)) : nil
    transition(pid, to: .completed, failure: nil, attention: attention, finished: true)
  }

  public func fail(_ pid: AgentPID, state: AgentProcessState, message: String, announce: Bool) {
    entries[pid]?.handle = nil
    // A stop's reason outlives the run's own cancellation report.
    guard let entry = entries[pid], !entry.info.state.isTerminal else { return }
    transition(
      pid,
      to: state,
      failure: message,
      attention: announce ? .error(message) : nil,
      finished: true)
  }

  /// Ends a turn of a process a host runs itself, when there is no
  /// `AgentResult` to finish it with: the process shows as completed, keeps
  /// its children and its inbox, and `reopen` puts it back to work for the
  /// next turn.
  public func complete(_ pid: AgentPID) {
    guard let entry = entries[pid], !entry.info.state.isTerminal else { return }
    entries[pid]?.handle = nil
    transition(pid, to: .completed, failure: nil, attention: nil, finished: true)
  }

  /// Marks the answer as taken, so it stops asking for attention.
  public func collect(_ pid: AgentPID) {
    guard var entry = entries[pid] else { return }
    entry.info.isCollected = true
    entry.info.attention = nil
    entries[pid] = entry
    publish(.changed(entry.info))
    pruneFinished()
  }

  public func forget(_ pid: AgentPID) {
    entries[pid] = nil
    inboxes[pid] = nil
    transcriptEdits[pid] = nil
    paused.remove(pid)
  }

  // MARK: - Internals

  private func transition(
    _ pid: AgentPID,
    to state: AgentProcessState,
    failure: String?,
    attention: AgentAttention?,
    finished: Bool
  ) {
    guard var entry = entries[pid] else { return }
    entry.info.state = state
    entry.info.failure = failure ?? entry.info.failure
    entry.info.attention = attention
    entry.info.updatedAt = Date()
    if finished {
      entry.info.finishedAt = Date()
      // "thinking" or a tool name describes a run in progress, not one that ended.
      entry.info.activity = ""
    }
    if state.isTerminal { paused.remove(pid) }
    entries[pid] = entry
    publish(finished ? .finished(entry.info) : .changed(entry.info))
    if attention != nil { publish(.attention(entry.info)) }
    pruneFinished()
  }

  /// A run reports itself running as it makes progress; while a person holds
  /// it, that progress is the last step before it waits, so the process keeps
  /// showing as paused until `resume`.
  private func effectiveState(_ state: AgentProcessState, for pid: AgentPID)
    -> AgentProcessState
  {
    state == .running && paused.contains(pid) ? .paused : state
  }

  private func publish(_ event: AgentSupervisorEvent) {
    for continuation in subscribers.values { continuation.yield(event) }
  }

  private func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  /// Drops the oldest terminal processes past the retention limit, never one
  /// that still has a live descendant hanging off it.
  private func pruneFinished() {
    let removable = removableFinished()
    guard removable.count > finishedRetention else { return }
    let ordered = removable.sorted {
      ($0.finishedAt ?? $0.updatedAt) < ($1.finishedAt ?? $1.updatedAt)
    }
    for process in ordered.prefix(removable.count - finishedRetention) {
      forget(process.pid)
    }
  }

  /// Finished processes that can be dropped: nothing under them still runs,
  /// and nobody has queued a message they would read at their next turn.
  private func removableFinished() -> [AgentProcessInfo] {
    let snapshot = tree()
    return snapshot.processes.filter { process in
      guard process.state.isTerminal, inboxes[process.pid, default: []].isEmpty else {
        return false
      }
      return !snapshot.subtree(of: process.pid).dropFirst().contains { !$0.state.isTerminal }
    }
  }

}
