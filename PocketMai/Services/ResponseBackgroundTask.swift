import UIKit

/// A finite opportunity to finish an in-flight reply after leaving the app.
/// This allowance cannot make a streaming connection survive suspension.
@MainActor
final class ResponseBackgroundTask {
  private var task: UIBackgroundTaskIdentifier = .invalid
  private var generation: UUID?
  private var isFinished = false
  private let onExpiration: @MainActor () -> Void

  init(onExpiration: @escaping @MainActor () -> Void) {
    self.onExpiration = onExpiration
  }

  func renewFiniteTask() {
    guard !isFinished, task == .invalid else { return }
    let generation = UUID()
    self.generation = generation
    task = UIApplication.shared.beginBackgroundTask(withName: "PocketMai assistant response") {
      [weak self] in
      guard let self, !self.isFinished, self.generation == generation else { return }
      // UIKit invokes this on the main actor. Checkpoint and cancel before
      // returning to the system, while the allowance is still held.
      self.onExpiration()
      self.endFiniteTask()
    }
  }

  func finish() {
    guard !isFinished else { return }
    isFinished = true
    endFiniteTask()
  }

  private func endFiniteTask() {
    guard task != .invalid else { return }
    let identifier = task
    task = .invalid
    generation = nil
    UIApplication.shared.endBackgroundTask(identifier)
  }
}
