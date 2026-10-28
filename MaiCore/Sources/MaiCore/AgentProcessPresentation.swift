import Foundation

public enum AgentProcessFilter: String, CaseIterable, Sendable {
  case all, active, attention, finished
  public var title: String { rawValue.capitalized }
  public func includes(_ process: AgentProcessInfo) -> Bool {
    switch self {
    case .all: return true
    case .active: return !process.state.isTerminal
    case .attention: return process.needsAttention
    case .finished: return process.state.isTerminal
    }
  }
}

public struct AgentProcessCounts: Equatable, Sendable {
  public private(set) var running = 0
  public private(set) var queued = 0
  public private(set) var paused = 0
  public private(set) var waiting = 0
  public private(set) var finished = 0
  public private(set) var attention = 0

  public init(_ processes: [AgentProcessInfo]) {
    for process in processes where !process.isArchived {
      if process.needsAttention { attention += 1 }
      if process.state.isTerminal { finished += 1 }
      else if process.pauseRequested || process.state == .paused { paused += 1 }
      else if process.state == .queued { queued += 1 }
      else if process.state.isWaiting { waiting += 1 }
      else if process.depth > 0 || process.state != .starting { running += 1 }
    }
  }

  public var summary: String {
    let live = [(running, "running"), (queued, "queued"), (paused, "paused"), (waiting, "waiting")]
      .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
    return live.isEmpty ? "\(finished) finished" : live.joined(separator: " · ")
  }
}

public enum AgentProcessNavigation {
  /// Keep a bounded window around the selected process. Position shortcuts
  /// retain their original numbering; the selected PID remains explicit.
  public static func strip(_ processes: [AgentProcessInfo], selected: AgentPID?, capacity: Int = 12) -> String {
    guard processes.count > 1 else { return "" }
    let capacity = max(3, capacity)
    let selectedIndex = selected.flatMap { pid in processes.firstIndex { $0.pid == pid } } ?? 0
    let lower = max(0, min(selectedIndex - capacity / 2, processes.count - capacity))
    let upper = min(processes.count, lower + capacity)
    let cells = (lower..<upper).map { index -> String in
      let process = processes[index]
      if process.pid == selected { return index < 9 ? String(index + 1) : "*" }
      if process.needsAttention { return "!" }
      if process.pauseRequested || process.state == .paused { return "‖" }
      if process.state == .queued { return "q" }
      return process.state.isTerminal ? "." : "●"
    }.joined()
    let context = processes.count > capacity ? " \(selected?.description ?? "")/\(processes.count)" : ""
    return " [" + (lower > 0 ? "‹" : "") + cells + (upper < processes.count ? "›" : "") + "]" + context
  }
}
