import Foundation

/// A revisioned wake-up shared by schedulers and hosts. Registering a waiter
/// checks the revision under the same lock as notification, so changes between
/// checking a condition and suspending cannot be lost.
public final class AgentChangeSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

  public init() {}
  public var revision: UInt64 { lock.withLock { generation } }

  public func notify() {
    let pending = lock.withLock {
      generation &+= 1
      let pending = Array(waiters.values)
      waiters.removeAll(keepingCapacity: true)
      return pending
    }
    for waiter in pending { waiter.resume() }
  }

  public func wait(after revision: UInt64, until deadline: ContinuousClock.Instant? = nil) async throws {
    if let deadline {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.wait(after: revision) }
        group.addTask { try await ContinuousClock().sleep(until: deadline) }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        lock.withLock {
          if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
          else if generation != revision { continuation.resume() }
          else { waiters[id] = continuation }
        }
      }
    } onCancel: {
      let pending = self.lock.withLock { self.waiters.removeValue(forKey: id) }
      pending?.resume(throwing: CancellationError())
    }
  }
}
