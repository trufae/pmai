import Foundation

/// Shared action vocabulary for terminal commands and graphical controls.
public enum AgentProcessAction: String, CaseIterable, Sendable {
  case pause, resume, cancel, archive, delete

  public var title: String { rawValue.capitalized }
  public func isAvailable(for process: AgentProcessInfo) -> Bool {
    switch self {
    case .pause: return process.externalSessionID == nil && !process.state.isTerminal && !process.pauseRequested && process.state != .paused
    case .resume: return process.externalSessionID == nil && !process.state.isTerminal && (process.pauseRequested || process.state == .paused)
    case .cancel: return !process.state.isTerminal && process.supportsCancellation
    case .archive: return process.state.isTerminal && !process.isArchived
    case .delete: return process.externalSessionID == nil || process.state.isTerminal
    }
  }
}

extension AgentSupervisor {
  @discardableResult
  public func perform(_ action: AgentProcessAction, on pid: AgentPID) async -> [AgentPID] {
    switch action {
    case .pause: return pause(pid)
    case .resume: return resume(pid)
    case .cancel: return await stop(pid, reason: "Cancelled by user")
    case .archive: return archiveFinished(under: pid, includingRoot: true)
    case .delete:
      _ = await stop(pid, reason: "Deleted by user")
      var deleted: [AgentPID] = []
      for process in tree().subtree(of: pid).reversed()
      where tree().subtree(of: process.pid).allSatisfy(\.state.isTerminal) {
        forget(process.pid)
        deleted.append(process.pid)
      }
      return deleted.reversed()
    }
  }
}
