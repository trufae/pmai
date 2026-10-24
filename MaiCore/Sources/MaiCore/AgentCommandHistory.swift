import Foundation

/// One host command launched by a run tool. OS pids are historical data;
/// only the in-memory launcher handle may be used to stop a process.
public struct AgentCommandRecord: Codable, Equatable, Sendable, Identifiable {
  public enum State: String, Codable, Sendable {
    case running, exited, timedOut, cancelled, killed, interrupted
  }

  public var id: UUID
  public var sessionID: String
  public var run: AgentEventContext
  public var callID: String
  public var tool: String
  public var pid: Int32?
  public var command: String
  public var arguments: [String]
  public var cwd: String
  public var startedAt: Date?
  public var endedAt: Date?
  public var durationMs: Int?
  public var exitCode: Int32?
  public var state: State

  public func duration(at now: Date = Date()) -> TimeInterval {
    if let durationMs { return Double(durationMs) / 1000 }
    guard let startedAt else { return 0 }
    return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
  }

  /// Copies are history, even if their source chat is still running.
  public func copied(to sessionID: String) -> Self {
    var record = self
    record.id = UUID()
    record.sessionID = sessionID
    if record.state == .running { record.state = .interrupted }
    return record
  }
}

/// Installed only around the concrete tool call, including proxied tools.
public struct AgentCommandScope: Sendable {
  @TaskLocal public static var current: AgentCommandScope?
  public let history: AgentCommandHistory
  public let sessionID: String
  public let run: AgentEventContext
  public let callID: String
  public let tool: String

  public init(
    history: AgentCommandHistory, sessionID: String, run: AgentEventContext,
    callID: String, tool: String
  ) {
    self.history = history
    self.sessionID = sessionID
    self.run = run
    self.callID = callID
    self.tool = tool
  }

  public func started(
    pid: Int32, command: String, arguments: [String], cwd: String,
    stop: @escaping @Sendable () -> Bool
  ) -> UUID {
    let record = AgentCommandRecord(
      id: UUID(), sessionID: sessionID, run: run, callID: callID, tool: tool,
      pid: pid, command: command, arguments: arguments, cwd: cwd,
      startedAt: Date(), state: .running)
    history.started(record, stop: stop)
    return record.id
  }
}

/// Shared by a runtime's tools and host. A lock lets synchronous process
/// termination callbacks update history before the tool returns.
public final class AgentCommandHistory: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [UUID: AgentCommandRecord] = [:]
  private var handles: [UUID: @Sendable () -> Bool] = [:]

  public init() {}

  fileprivate func started(_ record: AgentCommandRecord, stop: @escaping @Sendable () -> Bool) {
    lock.withLock {
      entries[record.id] = record
      handles[record.id] = stop
    }
  }

  public func finished(
    _ id: UUID, exitCode: Int32?, state: AgentCommandRecord.State, at date: Date = Date()
  ) {
    lock.withLock {
      guard var entry = entries[id], entry.state == .running else { return }
      entry.endedAt = date
      entry.durationMs = Int(entry.duration(at: date) * 1000)
      entry.exitCode = exitCode
      entry.state = state
      entries[id] = entry
      handles[id] = nil
    }
  }

  public func records(sessionID: String, saved: [AgentCommandRecord] = []) -> [AgentCommandRecord] {
    lock.withLock {
      var combined: [UUID: AgentCommandRecord] = [:]
      var savedOrder: [UUID: Int] = [:]
      for (index, record) in saved.enumerated() {
        combined[record.id] = entries[record.id] ?? record
        savedOrder[record.id] = index
      }
      for record in entries.values where record.sessionID == sessionID {
        combined[record.id] = record
      }
      return combined.values.sorted {
        if $0.startedAt != $1.startedAt {
          return ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        }
        if $0.startedAt == nil, savedOrder[$0.id] != savedOrder[$1.id] {
          return (savedOrder[$0.id] ?? .max) < (savedOrder[$1.id] ?? .max)
        }
        return $0.id.uuidString < $1.id.uuidString
      }
    }
  }

  /// A restored running record has no owned process handle. Never probe or
  /// signal its saved pid, which may now belong to an unrelated process.
  public func restore(_ records: [AgentCommandRecord]) {
    lock.withLock {
      for var record in records where entries[record.id] == nil {
        if record.state == .running { record.state = .interrupted }
        entries[record.id] = record
      }
    }
  }

  @discardableResult
  public func kill(pid: Int32, sessionID: String, saved: [AgentCommandRecord] = []) -> Bool {
    guard pid > 0 else { return false }
    let savedIDs = Set(saved.map(\.id))
    let stop = lock.withLock {
      entries.values.first {
        $0.pid == pid && ($0.sessionID == sessionID || savedIDs.contains($0.id))
          && $0.state == .running
      }
      .flatMap { handles[$0.id] }
    }
    // Do not hold the history lock while entering the launcher's lock.
    return stop?() ?? false
  }
}
