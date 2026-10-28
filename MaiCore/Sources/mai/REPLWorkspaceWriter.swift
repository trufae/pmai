import Foundation
import MaiCore

/// Ordered writes per store. Progress checkpoints can enqueue immutable values
/// without blocking input; foreground changes and shutdown await the same queue.
actor REPLWorkspaceWriter {
  static let shared = REPLWorkspaceWriter()
  private var writers: [URL: (UUID, Task<AgentChatWorkspace, any Error>)] = [:]

  func enqueue(_ workspace: AgentChatWorkspace, store: AgentChatStore)
    -> Task<AgentChatWorkspace, any Error>
  {
    let path = store.directoryURL.standardizedFileURL
    let previous = writers[path]?.1
    let id = UUID()
    let task = Task.detached(priority: .utility) {
      if let previous { _ = await previous.result }
      var snapshot = workspace
      try store.commit(&snapshot)
      return snapshot
    }
    writers[path] = (id, task)
    Task { [weak self] in
      _ = await task.result
      await self?.finished(id, at: path)
    }
    return task
  }

  private func finished(_ id: UUID, at path: URL) {
    if writers[path]?.0 == id { writers[path] = nil }
  }
}
