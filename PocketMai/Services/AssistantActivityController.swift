import ActivityKit
import Foundation
import UIKit

/// Mirrors in-flight assistant turns into one Live Activity so the Lock Screen
/// and the Dynamic Island show what PocketMai is doing while the app is not on
/// screen. Updates are coalesced: ActivityKit throttles frequent pushes and each
/// one is an IPC round trip, so streamed text is sampled rather than forwarded
/// chunk by chunk.
@MainActor
final class AssistantActivityController {
  static let maxTasks = 4
  private static let minimumUpdateInterval: TimeInterval = 1.5
  /// How long a finished card stays on the Lock Screen when the user is away.
  private static let finishedDismissalDelay: TimeInterval = 3 * 60

  var isEnabled = false {
    didSet {
      guard !isEnabled else { return }
      endActivity(dismissalPolicy: .immediate)
    }
  }

  private var tasksByID: [UUID: AssistantActivityTask] = [:]
  private var taskOrder: [UUID] = []
  private var streamingTextByID: [UUID: String] = [:]
  private var activity: ActivityHandle?
  private var lastPushedTasks: [AssistantActivityTask]?
  private var lastPushDate = Date.distantPast
  private var scheduledFlush: Task<Void, Never>?
  private var flushChain: Task<Void, Never>?

  init() {
    dismissLeftoverActivities()
  }

  // MARK: - Turn bookkeeping

  func begin(id: UUID, title: String, phase: AssistantActivityTask.Phase) {
    streamingTextByID[id] = nil
    if tasksByID[id] == nil {
      taskOrder.append(id)
    }
    tasksByID[id] = AssistantActivityTask(id: id, title: title, phase: phase)
    requestFlush(urgent: true)
  }

  func setPhase(id: UUID, phase: AssistantActivityTask.Phase, detail: String) {
    guard var task = tasksByID[id], !task.phase.isTerminal else { return }
    let summary = AssistantActivityTask.leadingSummary(detail)
    guard task.phase != phase || task.detail != summary else { return }
    let phaseChanged = task.phase != phase
    task.phase = phase
    task.detail = summary
    tasksByID[id] = task
    if phase != .streaming {
      streamingTextByID[id] = nil
    }
    requestFlush(urgent: phaseChanged)
  }

  func setStreamingText(id: UUID, text: String) {
    guard var task = tasksByID[id], !task.phase.isTerminal else { return }
    streamingTextByID[id] = text
    guard task.phase != .streaming else {
      requestFlush(urgent: false)
      return
    }
    task.phase = .streaming
    tasksByID[id] = task
    requestFlush(urgent: true)
  }

  func finish(id: UUID, phase: AssistantActivityTask.Phase, detail: String) {
    guard var task = tasksByID[id] else { return }
    task.phase = phase
    task.detail = AssistantActivityTask.leadingSummary(detail)
    task.finishedAt = Date()
    tasksByID[id] = task
    streamingTextByID[id] = nil
    requestFlush(urgent: true)
  }

  func remove(id: UUID) {
    guard tasksByID.removeValue(forKey: id) != nil else { return }
    taskOrder.removeAll { $0 == id }
    streamingTextByID[id] = nil
    requestFlush(urgent: true)
  }

  /// The user is back in the app: finished turns no longer need a card.
  func appDidBecomeActive() {
    pruneFinishedTasks()
    if tasksByID.isEmpty {
      endActivity(dismissalPolicy: .immediate)
      // A card that ended while the phone was locked is still on the Lock
      // Screen; the user has seen the reply now.
      dismissLeftoverActivities()
    } else {
      requestFlush(urgent: true)
    }
  }

  // MARK: - Coalescing

  private func requestFlush(urgent: Bool) {
    let elapsed = Date().timeIntervalSince(lastPushDate)
    if urgent || elapsed >= Self.minimumUpdateInterval {
      scheduledFlush?.cancel()
      scheduledFlush = nil
      enqueueFlush()
      return
    }
    guard scheduledFlush == nil else { return }
    let delay = Self.minimumUpdateInterval - elapsed
    scheduledFlush = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.scheduledFlush = nil
      self.enqueueFlush()
    }
  }

  /// ActivityKit calls are async; chaining them keeps updates in order.
  private func enqueueFlush() {
    let previous = flushChain
    flushChain = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      await self.flush()
    }
  }

  private func flush() async {
    guard isEnabled else { return }
    let state = makeState()
    guard state.tasks != lastPushedTasks else { return }
    lastPushDate = Date()

    if let activity, activity.state == .active {
      lastPushedTasks = state.tasks
      let content = ActivityContent(state: state, staleDate: nil)
      if state.isFinished {
        await finishActivity(activity, content: content)
      } else {
        await activity.update(content)
      }
      return
    }

    // Nothing worth starting a card for, or the system refuses to start one
    // from the background. Turns that already ended without ever getting a
    // card must not resurface as rows on the next one.
    guard !state.tasks.isEmpty, !state.isFinished else {
      pruneFinishedTasks()
      return
    }
    guard UIApplication.shared.applicationState != .background else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    dismissLeftoverActivities()
    do {
      let requested = try Activity.request(
        attributes: AssistantActivityAttributes(startedAt: Date()),
        content: ActivityContent(state: state, staleDate: nil),
        pushType: nil)
      activity = ActivityHandle(requested)
      lastPushedTasks = state.tasks
    } catch {
      activity = nil
    }
  }

  private func finishActivity(
    _ activity: ActivityHandle,
    content: ActivityContent<AssistantActivityAttributes.ContentState>
  ) async {
    // Someone watching the app saw the reply land; only keep the card for a
    // while when the phone was locked or the user was elsewhere.
    let dismissalPolicy: ActivityUIDismissalPolicy =
      UIApplication.shared.applicationState == .active
      ? .immediate
      : .after(Date().addingTimeInterval(Self.finishedDismissalDelay))
    await activity.end(content, dismissalPolicy: dismissalPolicy)
    if self.activity?.id == activity.id {
      self.activity = nil
      lastPushedTasks = nil
    }
    pruneFinishedTasks()
  }

  private func endActivity(dismissalPolicy: ActivityUIDismissalPolicy) {
    guard let activity else { return }
    self.activity = nil
    lastPushedTasks = nil
    Task {
      await activity.end(nil, dismissalPolicy: dismissalPolicy)
    }
  }

  /// Cards left behind by a previous process (crash, force quit) would otherwise
  /// sit on the Lock Screen until the system garbage collects them.
  private func dismissLeftoverActivities() {
    let currentID = activity?.id
    for leftover in Activity<AssistantActivityAttributes>.activities where leftover.id != currentID
    {
      let handle = ActivityHandle(leftover)
      Task {
        await handle.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  private func pruneFinishedTasks() {
    for id in taskOrder where tasksByID[id]?.phase.isTerminal == true {
      tasksByID[id] = nil
      streamingTextByID[id] = nil
    }
    taskOrder.removeAll { tasksByID[$0] == nil }
  }

  private func makeState() -> AssistantActivityAttributes.ContentState {
    var tasks = taskOrder.compactMap { tasksByID[$0] }
    for index in tasks.indices where tasks[index].phase == .streaming {
      guard let text = streamingTextByID[tasks[index].id] else { continue }
      let visible = MessageContentFilter.markdownPlainText(
        from: MessageContentFilter.render(text).visibleText)
      if visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // Only reasoning or tool envelopes so far: still thinking as far as the user is concerned.
        tasks[index].phase = .thinking
        tasks[index].detail = ""
      } else {
        tasks[index].detail = AssistantActivityTask.trailingSummary(visible)
      }
    }
    if tasks.count > Self.maxTasks {
      let attention = tasks.filter { $0.phase.needsAttention }
      let active = tasks.filter { !$0.phase.isTerminal && !$0.phase.needsAttention }
      let finished = tasks.filter { $0.phase.isTerminal }.reversed()
      tasks = Array((attention + active + finished).prefix(Self.maxTasks))
    }
    return AssistantActivityAttributes.ContentState(tasks: tasks, updatedAt: Date())
  }
}

/// `Activity` is not `Sendable`, and its `update`/`end` methods run outside
/// the main actor. Owning it through this box keeps those awaits legal under
/// Swift 6 isolation checking; the controller is the only user of the handle.
private final class ActivityHandle: @unchecked Sendable {
  private let activity: Activity<AssistantActivityAttributes>

  init(_ activity: Activity<AssistantActivityAttributes>) {
    self.activity = activity
  }

  var id: String { activity.id }
  var state: ActivityState { activity.activityState }

  func update(_ content: ActivityContent<AssistantActivityAttributes.ContentState>) async {
    await activity.update(content)
  }

  func end(
    _ content: ActivityContent<AssistantActivityAttributes.ContentState>?,
    dismissalPolicy: ActivityUIDismissalPolicy
  ) async {
    await activity.end(content, dismissalPolicy: dismissalPolicy)
  }
}
