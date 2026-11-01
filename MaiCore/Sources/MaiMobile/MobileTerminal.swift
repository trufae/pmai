import Foundation
import MaiCore
import Observation

@MainActor @Observable final class MobileTerminal {
  private(set) var id = ""
  private(set) var running = false
  private(set) var output = ""
  private(set) var isError = false
  private var operation: Task<Void, Never>?

  @discardableResult
  func run(id: String, action: @escaping @MainActor () async throws -> ToolResult) -> Bool {
    guard !id.isEmpty, !running else { return false }
    self.id = id
    running = true
    output = ""
    isError = false
    operation = Task {
      do {
        try Task.checkCancellation()
        let result = try await action()
        try Task.checkCancellation()
        guard self.id == id else { return }
        update(id: id, output: result.text)
        isError = result.isError
      } catch {
        guard self.id == id else { return }
        update(id: id, output: output + (output.isEmpty ? "" : "\n") + (Task.isCancelled
          ? "[stopped; remote command may still be running]" : "Error: \(error.localizedDescription)"))
        isError = true
      }
      guard self.id == id else { return }
      running = false
      operation = nil
    }
    return true
  }

  func update(id: String, output: String) {
    guard self.id == id, running else { return }
    let limit = 128_000
    self.output = output.utf8.count > limit
      ? "[earlier output trimmed]\n" + String(decoding: output.utf8.suffix(limit), as: UTF8.self)
      : output
  }

  func stop() { operation?.cancel() }

  func close() {
    id = ""
    running = false
    operation?.cancel()
    operation = nil
    output = ""
  }

  var snapshot: [String: Any] {
    ["id": id, "running": running, "output": output, "isError": isError]
  }
}
