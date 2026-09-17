import Foundation

/// The short, typeable identifier of one running agent. Definitions are named
/// (`researcher`); the instances started from them are numbered, so people can
/// address one of several concurrent children the way they address a process.
public struct AgentPID: RawRepresentable, Hashable, Codable, Sendable, Comparable,
  CustomStringConvertible, ExpressibleByIntegerLiteral
{
  public let rawValue: Int

  public init(rawValue: Int) { self.rawValue = rawValue }
  public init(_ rawValue: Int) { self.init(rawValue: rawValue) }
  public init(integerLiteral value: Int) { self.init(rawValue: value) }

  /// Accepts what a person or a model types: `4`, `#4`, or `pid 4`.
  public init?(text: String) {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix("pid") { value = String(value.dropFirst(3)) }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value = String(value.dropFirst()) }
    guard let number = Int(value), number > 0 else { return nil }
    self.init(rawValue: number)
  }

  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(Int.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { "#\(rawValue)" }

  public static func < (lhs: AgentPID, rhs: AgentPID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where one agent process is in its life. `blocked` covers a run that stopped
/// making progress for a reason the host should show, such as a network error
/// that has not yet ended the run; the reason travels in `AgentAttention`.
/// `paused` is a run a person held with `AgentSupervisor.pause`: it finishes
/// the model call or tool it is in, then waits at its next turn boundary
/// until `resume`, keeping its transcript, its children, and its inbox.
public enum AgentProcessState: String, Codable, Equatable, Sendable {
  case starting
  /// Registered, but every subagent slot of its parent is taken; the run
  /// starts by itself when a sibling ends.
  case queued
  case running
  case waitingForApproval
  case waitingForInput
  case blocked
  case paused
  case completed
  case failed
  case cancelled
  /// A run limit stopped the process at a turn boundary. Its transcript is
  /// whole, so a host can run it again to carry on.
  case interrupted

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled, .interrupted: true
    default: false
    }
  }

  /// True while the process cannot progress without somebody acting on it.
  public var isWaiting: Bool {
    switch self {
    case .waitingForApproval, .waitingForInput, .blocked, .paused: true
    default: false
    }
  }

  /// A fixed-width label so a tree listing stays aligned.
  public var shortLabel: String {
    switch self {
    case .starting: "start"
    case .queued: "queued"
    case .running: "run"
    case .waitingForApproval: "approve?"
    case .waitingForInput: "input?"
    case .blocked: "blocked"
    case .paused: "paused"
    case .completed: "done"
    case .failed: "failed"
    case .cancelled: "killed"
    case .interrupted: "stopped"
    }
  }
}

/// Why a process wants a human. Hosts turn these into badges, notifications, or
/// a line in the terminal; nothing in MaiCore decides how they are shown.
public enum AgentAttention: Equatable, Sendable {
  /// A tool call is waiting for approval.
  case approval(ApprovalRequest)
  /// The process asked its user a question and cannot continue.
  case input(String)
  /// Progress stopped for a reason worth reporting, such as a network failure.
  case error(String)
  /// A background process finished and nobody has collected its answer.
  case finished(String)

  public var summary: String {
    switch self {
    case .approval(let request): "approve \(request.tool.name)"
    case .input(let prompt): prompt
    case .error(let message): message
    case .finished(let answer): answer
    }
  }

  /// The state a process enters while this attention stands. `finished` keeps
  /// whatever terminal state the run reached.
  var implicitState: AgentProcessState? {
    switch self {
    case .approval: .waitingForApproval
    case .input: .waitingForInput
    case .error: .blocked
    case .finished: nil
    }
  }
}

/// Everything a host needs to list, follow, or act on one running agent.
/// Deliberately not `Codable`: a process is live session state, and a resumed
/// child would answer a question its parent has already forgotten.
public struct AgentProcessInfo: Equatable, Sendable, Identifiable {
  public var pid: AgentPID
  public var parent: AgentPID?
  public var runID: UUID
  /// The definition this process was started from.
  public var agentID: String
  public var displayName: String
  /// A one-line summary of the brief, for listings.
  public var task: String
  public var state: AgentProcessState
  public var attention: AgentAttention?
  public var depth: Int
  public var startedAt: Date
  /// When the current run began. A chat process is reopened for every turn,
  /// so this moves while `startedAt` stays at the process's first run.
  public var runStartedAt: Date
  public var updatedAt: Date
  public var finishedAt: Date?
  public var modelTurns: Int
  public var toolCalls: Int
  public var usage: TokenUsage?
  /// The most recent thing the process did, such as the tool it is running.
  public var activity: String
  public var failure: String?
  /// True once a parent has taken the answer through `agent_result`.
  public var isCollected: Bool
  /// Messages a person queued for this process that it has not read yet.
  public var queuedMessages: Int

  public var id: AgentPID { pid }

  public init(
    pid: AgentPID,
    parent: AgentPID? = nil,
    runID: UUID,
    agentID: String,
    displayName: String? = nil,
    task: String = "",
    state: AgentProcessState = .starting,
    attention: AgentAttention? = nil,
    depth: Int = 0,
    startedAt: Date = Date(),
    runStartedAt: Date? = nil,
    updatedAt: Date? = nil,
    finishedAt: Date? = nil,
    modelTurns: Int = 0,
    toolCalls: Int = 0,
    usage: TokenUsage? = nil,
    activity: String = "",
    failure: String? = nil,
    isCollected: Bool = false,
    queuedMessages: Int = 0
  ) {
    self.pid = pid
    self.parent = parent
    self.runID = runID
    self.agentID = agentID
    self.displayName = displayName ?? agentID
    self.task = task
    self.state = state
    self.attention = attention
    self.depth = depth
    self.startedAt = startedAt
    self.runStartedAt = runStartedAt ?? startedAt
    self.updatedAt = updatedAt ?? startedAt
    self.finishedAt = finishedAt
    self.modelTurns = modelTurns
    self.toolCalls = toolCalls
    self.usage = usage
    self.activity = activity
    self.failure = failure
    self.isCollected = isCollected
    self.queuedMessages = queuedMessages
  }

  public var needsAttention: Bool { attention != nil }

  /// How long the current run has been going, or how long the last one took
  /// once the process ended.
  public func elapsedSeconds(at now: Date = Date()) -> TimeInterval {
    max(0, (finishedAt ?? now).timeIntervalSince(runStartedAt))
  }

  /// `#3 coder  run  5 turns · 2 tools · 2.1k tok · 1m4s — reading Parser.swift`
  public var summaryLine: String {
    summaryLine(at: Date())
  }

  public func summaryLine(at now: Date) -> String {
    var line = "\(pid) \(agentID)  [\(state.shortLabel)]"
    var facts: [String] = []
    if modelTurns > 0 { facts.append("\(modelTurns) turn\(modelTurns == 1 ? "" : "s")") }
    if toolCalls > 0 { facts.append("\(toolCalls) tool\(toolCalls == 1 ? "" : "s")") }
    if let usage, usage.totalTokens > 0 {
      facts.append(ModelUsageFormat.tokens(usage.totalTokens, estimated: usage.isEstimated))
    }
    if state != .starting || finishedAt != nil {
      facts.append(ModelUsageFormat.duration(elapsedSeconds(at: now)))
    }
    if queuedMessages > 0 { facts.append("\(queuedMessages) queued") }
    if !facts.isEmpty { line += "  " + facts.joined(separator: " · ") }
    let detail = attention?.summary ?? failure ?? activity
    let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { line += " — \(Self.oneLine(trimmed, limit: 60))" }
    return line
  }

  /// One line of at most `limit` characters, whitespace collapsed.
  public static func oneLine(_ text: String, limit: Int) -> String {
    let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard compact.count > limit else { return compact }
    return String(compact.prefix(max(1, limit - 1))) + "…"
  }

  /// `950`, `1.2k`, `12.0k`, `3.4M`: `ModelUsageFormat.count`, kept here
  /// for callers that reached it through the process info.
  public static func compactCount(_ count: Int) -> String {
    ModelUsageFormat.count(count)
  }
}

/// A snapshot of the process table, arranged as the tree it really is.
public struct AgentProcessTree: Equatable, Sendable {
  public var processes: [AgentProcessInfo]

  public init(_ processes: [AgentProcessInfo] = []) {
    self.processes = processes.sorted { $0.pid < $1.pid }
  }

  public var isEmpty: Bool { processes.isEmpty }

  public func info(_ pid: AgentPID) -> AgentProcessInfo? {
    processes.first { $0.pid == pid }
  }

  public func contains(_ pid: AgentPID) -> Bool { info(pid) != nil }

  public func children(of pid: AgentPID?) -> [AgentProcessInfo] {
    processes.filter { $0.parent == pid }
  }

  public var roots: [AgentProcessInfo] {
    processes.filter { process in
      guard let parent = process.parent else { return true }
      return !contains(parent)
    }
  }

  /// A process and every descendant, parents before children.
  public func subtree(of pid: AgentPID) -> [AgentProcessInfo] {
    guard let root = info(pid) else { return [] }
    var collected = [root]
    var index = 0
    while index < collected.count {
      collected.append(contentsOf: children(of: collected[index].pid))
      index += 1
    }
    return collected
  }

  /// Every running child of any process using this definition, across chats
  /// and nesting levels. A queued child holds no slot yet and is not counted.
  public func liveChildren(ofAgent agentID: String) -> [AgentProcessInfo] {
    processes.filter { process in
      guard !process.state.isTerminal, process.state != .queued, let parent = process.parent
      else { return false }
      return info(parent)?.agentID == agentID
    }
  }

  /// Children of the named agent still waiting for a subagent slot, oldest
  /// first: the order in which they will start.
  public func queuedChildren(ofAgent agentID: String) -> [AgentProcessInfo] {
    processes
      .filter { process in
        guard process.state == .queued, let parent = process.parent else { return false }
        return info(parent)?.agentID == agentID
      }
      .sorted { $0.pid < $1.pid }
  }

  public func isDescendant(_ pid: AgentPID, of ancestor: AgentPID) -> Bool {
    var current = info(pid)?.parent
    while let parent = current {
      if parent == ancestor { return true }
      current = info(parent)?.parent
    }
    return false
  }

  /// Box-drawn lines, one per process, ready to print.
  public func lines(
    from root: AgentPID? = nil,
    describe: (AgentProcessInfo) -> String = \.summaryLine
  ) -> [String] {
    var output: [String] = []
    let top = root.flatMap(info).map { [$0] } ?? roots
    for (index, process) in top.enumerated() {
      append(
        process, prefix: "", isLast: index == top.count - 1, isRoot: true, into: &output,
        describe: describe)
    }
    return output
  }

  private func append(
    _ process: AgentProcessInfo,
    prefix: String,
    isLast: Bool,
    isRoot: Bool,
    into output: inout [String],
    describe: (AgentProcessInfo) -> String
  ) {
    let branch = isRoot ? "" : (isLast ? "└── " : "├── ")
    output.append(prefix + branch + describe(process))
    let childPrefix = isRoot ? "" : prefix + (isLast ? "    " : "│   ")
    let children = self.children(of: process.pid)
    for (index, child) in children.enumerated() {
      append(
        child,
        prefix: childPrefix,
        isLast: index == children.count - 1,
        isRoot: false,
        into: &output,
        describe: describe)
    }
  }
}

/// One process of a chat's runs as a host keeps it once the session that ran
/// it is over: what `AgentProcessInfo` knew, plus the transcript. Chat files
/// carry these so a resumed chat can still list, read, and export the agents
/// its earlier runs started; the debug export carries the same records.
///
/// Pids are session-scoped, so `pid` and `parent` are only what they were
/// when the record was written. `runID` is the durable identity, and
/// `parentRunID` names the record a child hangs off — nil for a direct child
/// of the chat's own process — so a tree restores under fresh pids.
public struct AgentProcessRecord: Codable, Equatable, Sendable, Identifiable {
  public var runID: UUID
  public var parentRunID: UUID?
  public var pid: AgentPID
  public var parent: AgentPID?
  public var agentID: String
  public var displayName: String
  public var task: String
  public var state: AgentProcessState
  public var depth: Int
  public var startedAt: Date
  public var updatedAt: Date
  public var finishedAt: Date?
  public var modelTurns: Int
  public var toolCalls: Int
  public var usage: TokenUsage?
  public var failure: String?
  public var messages: [AgentMessage]

  public var id: UUID { runID }

  public init(process: AgentProcessInfo, messages: [AgentMessage], parentRunID: UUID? = nil) {
    runID = process.runID
    self.parentRunID = parentRunID
    pid = process.pid
    parent = process.parent
    agentID = process.agentID
    displayName = process.displayName
    task = process.task
    state = process.state
    depth = process.depth
    startedAt = process.startedAt
    updatedAt = process.updatedAt
    finishedAt = process.finishedAt
    modelTurns = process.modelTurns
    toolCalls = process.toolCalls
    usage = process.usage
    failure = process.failure
    self.messages = messages
  }

  private enum CodingKeys: String, CodingKey {
    case runID, parentRunID, pid, parent, agentID, displayName, task, state, depth
    case startedAt, updatedAt, finishedAt, modelTurns, toolCalls, usage, failure, messages
  }

  /// Records written before `runID`, `parentRunID`, and `updatedAt` existed
  /// still decode: such a record gets an identity of its own and hangs off
  /// the chat's process.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    runID = try container.decodeIfPresent(UUID.self, forKey: .runID) ?? UUID()
    parentRunID = try container.decodeIfPresent(UUID.self, forKey: .parentRunID)
    pid = try container.decode(AgentPID.self, forKey: .pid)
    parent = try container.decodeIfPresent(AgentPID.self, forKey: .parent)
    agentID = try container.decode(String.self, forKey: .agentID)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? agentID
    task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
    state = try container.decode(AgentProcessState.self, forKey: .state)
    depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 1
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    updatedAt =
      try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? finishedAt ?? startedAt
    modelTurns = try container.decodeIfPresent(Int.self, forKey: .modelTurns) ?? 0
    toolCalls = try container.decodeIfPresent(Int.self, forKey: .toolCalls) ?? 0
    usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
    failure = try container.decodeIfPresent(String.self, forKey: .failure)
    messages = try container.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
  }

  /// `saved` brought up to date with `current`, the records of the processes
  /// a supervisor holds right now: a process in both is replaced by its
  /// current copy, one only in `current` is appended, and one only in
  /// `saved` — forgotten by the table since it was written — is kept as it
  /// was. Parents stay before children when both inputs have them so.
  public static func merging(
    saved: [AgentProcessRecord],
    current: [AgentProcessRecord]
  ) -> [AgentProcessRecord] {
    var merged = saved
    var indexByRunID: [UUID: Int] = [:]
    for (index, record) in merged.enumerated() { indexByRunID[record.runID] = index }
    for record in current {
      if let index = indexByRunID[record.runID] {
        merged[index] = record
      } else {
        indexByRunID[record.runID] = merged.count
        merged.append(record)
      }
    }
    return merged
  }
}
