import BackgroundTasks
import UIKit

/// Owns the execution allowance for one assistant turn. A Live Activity alone
/// does not keep the process (or its streaming connection) running.
@MainActor
final class ResponseBackgroundTask {
  private var finiteTask: UIBackgroundTaskIdentifier = .invalid
  private var finiteGeneration: UUID?
  private var continuedTask: BGTask?
  private var requestIdentifier: String?
  private var isFinished = false
  private let onExpiration: @MainActor () -> Void
  private let onCancellation: @MainActor () -> Void

  var isContinuing: Bool { continuedTask != nil }

  init(
    onExpiration: @escaping @MainActor () -> Void,
    onCancellation: @escaping @MainActor () -> Void
  ) {
    self.onExpiration = onExpiration
    self.onCancellation = onCancellation
  }

  func start(title: String, useContinuedProcessing: Bool) {
    renewFiniteTask()
    guard #available(iOS 26.0, *), useContinuedProcessing,
      UIApplication.shared.applicationState == .active
    else { return }

    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let identifier = "\(bundleID).response.\(UUID().uuidString)"
    let scheduler = BGTaskScheduler.shared
    guard
      scheduler.register(
        forTaskWithIdentifier: identifier, using: .main,
        launchHandler: {
          [weak self] task in
          MainActor.assumeIsolated {
            guard let self, !self.isFinished, let task = task as? BGContinuedProcessingTask else {
              task.setTaskCompleted(success: false)
              return
            }
            self.continuedTask = task
            task.progress.totalUnitCount = 1
            task.expirationHandler = { [weak self] in
              Task { @MainActor in
                guard let self, !self.isFinished else { return }
                // Includes cancellation from the system's Live Activity. Do not
                // silently restart a request or replay tools after this signal.
                self.onCancellation()
                self.finish(success: false)
              }
            }
          }
        })
    else { return }

    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: title, subtitle: "Thinking")
    // The reply is already running; a queued request could outlive its turn.
    request.strategy = .fail
    do {
      try scheduler.submit(request)
      requestIdentifier = identifier
    } catch {
      // The finite allowance still covers devices/system states that decline
      // continued processing, including the simulator.
    }
  }

  func renewFiniteTask() {
    guard !isFinished, finiteTask == .invalid else { return }
    let generation = UUID()
    finiteGeneration = generation
    finiteTask = UIApplication.shared.beginBackgroundTask(withName: "PocketMai assistant response")
    {
      [weak self] in
      Task { @MainActor in
        guard let self, !self.isFinished, self.finiteGeneration == generation else { return }
        self.endFiniteTask()
        self.onExpiration()
      }
    }
  }

  /// Count actual stream/tool updates, keeping one outstanding unit until the
  /// turn finishes: neither the final token count nor tool count is known yet.
  /// A timer must not manufacture progress for a stalled provider.
  func recordProgress() {
    guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else {
      return
    }
    task.progress.totalUnitCount = task.progress.completedUnitCount + 2
    task.progress.completedUnitCount += 1
  }

  func finish(success: Bool = false) {
    guard !isFinished else { return }
    isFinished = true
    if let requestIdentifier {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestIdentifier)
      self.requestIdentifier = nil
    }
    continuedTask?.expirationHandler = nil
    if #available(iOS 26.0, *), success,
      let task = continuedTask as? BGContinuedProcessingTask
    {
      task.progress.completedUnitCount = task.progress.totalUnitCount
    }
    continuedTask?.setTaskCompleted(success: success)
    continuedTask = nil
    endFiniteTask()
  }

  private func endFiniteTask() {
    guard finiteTask != .invalid else { return }
    let task = finiteTask
    finiteTask = .invalid
    finiteGeneration = nil
    UIApplication.shared.endBackgroundTask(task)
  }
}
