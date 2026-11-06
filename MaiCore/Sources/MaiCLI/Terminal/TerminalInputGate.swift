import Foundation

/// Parks the line editor between byte reads without losing its unfinished
/// line. A handoff waits for the current bounded poll before lending stdin.
final class TerminalInputGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var suspended = false
  private var reading = false

  func read<T>(_ body: () -> T) -> T {
    condition.lock()
    while suspended { condition.wait() }
    reading = true
    condition.unlock()
    defer {
      condition.lock()
      reading = false
      condition.broadcast()
      condition.unlock()
    }
    return body()
  }

  func withSuspendedInput(_ body: () throws -> Void) rethrows {
    condition.lock()
    while suspended { condition.wait() }
    suspended = true
    while reading { condition.wait() }
    condition.unlock()
    defer {
      condition.lock()
      suspended = false
      condition.broadcast()
      condition.unlock()
    }
    try body()
  }
}
