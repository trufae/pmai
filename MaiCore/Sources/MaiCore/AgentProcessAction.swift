import Foundation

/// Shared action vocabulary for terminal commands and graphical controls.
public enum AgentProcessAction: String, CaseIterable, Sendable {
  case pause, resume, cancel, archive, delete

  public var title: String { rawValue.capitalized }
  public func isAvailable(for process: AgentProcessInfo) -> Bool {
    switch self {
    case .pause: return !process.state.isTerminal && !process.pauseRequested && process.state != .paused
    case .resume: return !process.state.isTerminal && (process.pauseRequested || process.state == .paused)
    case .cancel: return !process.state.isTerminal
    case .archive: return process.state.isTerminal && !process.isArchived
    case .delete: return true
    }
  }
}

extension AgentSupervisor {
  @discardableResult
  public func perform(_ action: AgentProcessAction, on pid: AgentPID) -> [AgentPID] {
    switch action {
    case .pause: return pause(pid)
    case .resume: return resume(pid)
    case .cancel: return stop(pid, reason: "Cancelled by user")
    case .archive: return archiveFinished(under: pid, includingRoot: true)
    case .delete:
      let deleted = stop(pid, reason: "Deleted by user")
      for victim in deleted.reversed() { forget(victim) }
      return deleted
    }
  }
}
