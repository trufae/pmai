@preconcurrency import EventKit
import Foundation
import MaiCore

@MainActor enum PocketMaiReminders {
  static let store = ReminderStore(directory: URL.applicationSupportDirectory)
  static let notifications = AppleReminderNotifications(store: store)
  static let apple = AppleRemindersStore()
}

/// All Apple operations are confined to the list created by PocketMai.
@MainActor final class AppleRemindersStore: ReminderBackend {
  private let store = EKEventStore()
  private let calendarKey = "pocketmai.reminders.calendar"
  private let preferences = UserDefaults.standard

  func requestAccess() async throws {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if status == .fullAccess { return }
    if status == .notDetermined, try await store.requestFullAccessToReminders() { return }
    throw AppleReminderError.access
  }

  func list() async throws -> [MaiReminder] {
    try await requestAccess()
    guard let calendar = try listCalendar(create: false) else { return [] }
    let predicate = store.predicateForReminders(in: [calendar])
    return try await withCheckedThrowingContinuation { continuation in
      let complete: @Sendable ([EKReminder]?) -> Void = { reminders in
        guard let reminders else {
          continuation.resume(throwing: AppleReminderError.read)
          return
        }
        continuation.resume(returning: reminders.map(Self.value))
      }
      _ = store.fetchReminders(matching: predicate, completion: complete)
    }
  }

  func add(title: String, due: Date?, alert: ReminderAlert) async throws -> MaiReminder {
    try await requestAccess()
    guard let calendar = try listCalendar(create: true) else { throw AppleReminderError.list }
    let item = EKReminder(eventStore: store)
    item.calendar = calendar
    item.title = title
    try setAlert(on: item, due: due, alert: alert)
    setDueDate(on: item, due: due)
    try store.save(item, commit: true)
    return Self.value(item)
  }

  func update(id: String, title: String?, due: ReminderDueChange, alert: ReminderAlert?,
    completed: Bool?
  ) async throws -> MaiReminder {
    try await requestAccess()
    let item = try findItem(id)
    if let title { item.title = title }
    if let completed { item.isCompleted = completed }
    let old = Self.value(item)
    switch due {
    case .keep:
      if let alert { try setAlert(on: item, due: old.dueDate, alert: alert) }
    case .set(let date):
      if let alert {
        try setAlert(on: item, due: date, alert: alert)
      } else if let previous = old.dueDate,
        let dueAlarm = item.alarms?.first(where: { $0.absoluteDate == previous }) {
        item.removeAlarm(dueAlarm)
        item.addAlarm(EKAlarm(absoluteDate: roundForEventKit(date)))
      }
      setDueDate(on: item, due: date)
    case .clear:
      try setAlert(on: item, due: nil, alert: .none)
      setDueDate(on: item, due: nil)
    }
    try store.save(item, commit: true)
    return Self.value(item)
  }

  func remove(id: String) async throws {
    try await requestAccess()
    try store.remove(try findItem(id), commit: true)
  }

  private func findItem(_ id: String) throws -> EKReminder {
    guard let calendar = try listCalendar(create: false),
      let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
      reminder.calendar.calendarIdentifier == calendar.calendarIdentifier
    else { throw ReminderError.unknownID }
    return reminder
  }

  private func listCalendar(create: Bool) throws -> EKCalendar? {
    if let id = preferences.string(forKey: calendarKey),
      let list = store.calendar(withIdentifier: id) {
      return list
    }
    guard create else { return nil }
    guard let source = store.defaultCalendarForNewReminders()?.source else {
      throw AppleReminderError.list
    }
    let list = EKCalendar(for: .reminder, eventStore: store)
    list.title = "PocketMai"
    list.source = source
    try store.saveCalendar(list, commit: true)
    preferences.set(list.calendarIdentifier, forKey: calendarKey)
    return list
  }

  private func setDueDate(on item: EKReminder, due: Date?) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    item.dueDateComponents = due.map {
      calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
        from: roundForEventKit($0))
    }
  }

  private func setAlert(on item: EKReminder, due: Date?, alert: ReminderAlert) throws {
    if alert != .none && due == nil { throw ReminderError.missingDueDate }
    item.alarms = nil
    if alert != .none, let due { item.addAlarm(EKAlarm(absoluteDate: roundForEventKit(due))) }
  }

  private func roundForEventKit(_ date: Date) -> Date {
    Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
  }

  nonisolated private static func value(_ item: EKReminder) -> MaiReminder {
    let components = item.dueDateComponents
    let due = components.flatMap { ($0.calendar ?? .current).date(from: $0) }
    let alert: ReminderAlert = item.hasAlarms ? .notification : .none
    return MaiReminder(id: item.calendarItemIdentifier, title: item.title ?? "",
      due: due, alert: alert, completed: item.isCompleted)
  }

  private enum AppleReminderError: LocalizedError {
    case access, list, read
    var errorDescription: String? {
      switch self {
      case .access: "Allow PocketMai full access to Reminders in iOS Settings."
      case .list: "Set up a writable default list in Apple Reminders first."
      case .read: "Apple Reminders couldn't read the PocketMai list."
      }
    }
  }
}
