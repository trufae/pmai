#if os(iOS) || os(macOS)
import Foundation
import UserNotifications

/// Reconciles the OS queue from the portable store. Apple Reminders items
/// never enter this queue: EventKit and the Reminders app own their delivery.
@MainActor
public final class AppleReminderNotifications {
  nonisolated private static let prefix = "pmai.reminder."
  private let center = UNUserNotificationCenter.current()
  private let preferences = UserDefaults.standard
  private var ledgerKey: String { "pmai.reminders.scheduled." + store.url.path }
  private var refreshing = false
  private var refreshAgain = false
  public let store: ReminderStore
  public private(set) var status = ""

  public init(store: ReminderStore) { self.store = store }

  nonisolated public static func owns(_ identifier: String) -> Bool {
    identifier.hasPrefix(prefix)
  }

  public func requestAuthorization() async throws {
    let granted = try await center.requestAuthorization(options: [.alert, .sound])
    await refresh()
    if !granted { throw NotificationError.permissionRequired }
  }

  /// Refill the pending queue while the app is open. The Mac GUI also reads
  /// edits from independent ACP workers through this file.
  public func monitor() async {
    var observed: ReminderStore.Snapshot?
    var lastRefresh = Date.distantPast
    while !Task.isCancelled {
      let next = try? store.snapshot()
      if next != observed || Date().timeIntervalSince(lastRefresh) >= 60 {
        await refresh()
        observed = next
        lastRefresh = Date()
      }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }

  public func refresh() async {
    if refreshing { refreshAgain = true; return }
    refreshing = true
    defer { refreshing = false }
    repeat {
      refreshAgain = false
      do {
        status = try await reconcile()
      } catch {
        status = error.localizedDescription
      }
    } while refreshAgain
  }

  private func reconcile() async throws -> String {
    let snapshot = try store.snapshot()
    let candidates = snapshot.scheduled.sorted { ($0.dueAt ?? 0) < ($1.dueAt ?? 0) }
    let authorization = await center.notificationSettings().authorizationStatus
    var ledger = preferences.dictionary(forKey: ledgerKey) as? [String: Double] ?? [:]
    let knownIDs = Set(snapshot.reminders.map(\.id))
    ledger = ledger.filter { knownIDs.contains($0.key) }
    let pending = await center.pendingNotificationRequests().filter { Self.owns($0.identifier) }
    var available = authorization == .authorized || authorization == .provisional
    #if os(iOS)
    available = available || authorization == .ephemeral
    #endif
    let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
    let delivered = await center.deliveredNotifications().map(\.request).filter { Self.owns($0.identifier) }
    let activeDates = Dictionary(uniqueKeysWithValues: candidates.compactMap { item in
      item.dueAt.map { (Self.prefix + item.id, $0) }
    })
    for request in delivered {
      if let due = request.content.userInfo["due"] as? Double, activeDates[request.identifier] == due {
        ledger[String(request.identifier.dropFirst(Self.prefix.count))] = due
      }
    }
    let now = Date()
    let eligible = available ? candidates.filter { item in
      guard let due = item.dueAt else { return false }
      let pendingDate = existing[Self.prefix + item.id]?.content.userInfo["due"] as? Double
      return due > now.timeIntervalSince1970 || ledger[item.id] != due || pendingDate == due
    } : []
    // Leave room for other app notifications in the system's pending queue.
    let queued = eligible.prefix(48)
    let desired = Set(queued.map { Self.prefix + $0.id })
    let obsolete = pending.filter { !desired.contains($0.identifier) }.map(\.identifier)
    center.removePendingNotificationRequests(withIdentifiers: obsolete)
    for id in obsolete { ledger.removeValue(forKey: String(id.dropFirst(Self.prefix.count))) }
    center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
      activeDates[$0.identifier] != ($0.content.userInfo["due"] as? Double)
    }.map(\.identifier))
    for reminder in queued {
      guard let due = reminder.dueAt else { continue }
      let id = Self.prefix + reminder.id
      if let previous = existing[id], previous.content.title == reminder.title,
        previous.content.userInfo["due"] as? Double == due,
        previous.content.userInfo["alert"] as? String == reminder.alert.rawValue
      { continue }
      let content = UNMutableNotificationContent()
      content.title = reminder.title
      content.threadIdentifier = "pmai.reminders"
      content.userInfo = ["due": due, "alert": reminder.alert.rawValue]
      if reminder.alert == .alarm { content.sound = .default }
      let trigger: UNNotificationTrigger?
      if due > now.timeIntervalSince1970 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day,
          .hour, .minute, .second], from: Date(timeIntervalSince1970: ceil(due)))
        trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
      } else {
        trigger = nil
      }
      try await center.add(.init(identifier: id, content: content, trigger: trigger))
      ledger[reminder.id] = due
      preferences.set(ledger, forKey: ledgerKey)
    }
    preferences.set(ledger, forKey: ledgerKey)
    if !snapshot.notificationsEnabled { return "PocketMai reminder alerts are off." }
    if !available { return "Allow notifications to receive PocketMai alerts." }
    if eligible.count > queued.count {
      return "The next 48 reminders are queued. Open PocketMai again to queue later alerts."
    }
    return "PocketMai reminder alerts are enabled."
  }

  private enum NotificationError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { "Enable notifications for this app in System Settings." }
  }
}
#endif
