import Foundation

public enum ReminderAlert: String, Codable, CaseIterable, Sendable {
  case none
  case notification
  case alarm
}

public struct MaiReminder: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public private(set) var title: String
  public private(set) var dueAt: Double?
  public private(set) var alert: ReminderAlert
  public private(set) var completed: Bool
  fileprivate var terminalAlerted = false

  public var dueDate: Date? { dueAt.map(Date.init(timeIntervalSince1970:)) }

  public init(id: String = UUID().uuidString.lowercased(), title: String, due: Date?,
    alert: ReminderAlert, completed: Bool = false
  ) {
    self.id = id
    self.title = title
    dueAt = due?.timeIntervalSince1970
    self.alert = alert
    self.completed = completed
  }

  public mutating func update(title: String?, due: ReminderDueChange,
    alert: ReminderAlert?, completed: Bool?
  ) throws {
    if let title { self.title = title }
    switch due {
    case .keep: break
    case .clear: dueAt = nil
    case .set(let date):
      if dueAt != date.timeIntervalSince1970 { terminalAlerted = false }
      dueAt = date.timeIntervalSince1970
    }
    if let alert { self.alert = alert }
    if let completed { self.completed = completed }
    try validate()
  }

  fileprivate func validate() throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      title.count <= 256 else { throw ReminderError.invalidTitle }
    if alert != .none && dueAt == nil { throw ReminderError.missingDueDate }
    if let date = dueDate { try ReminderDate.validate(date) }
  }
}

public enum ReminderDueChange: Sendable {
  case keep
  case clear
  case set(Date)
}

public enum ReminderDate {
  public static func parse(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fractional = formatter.date(from: value)
    formatter.formatOptions = [.withInternetDateTime]
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#,
      options: .regularExpression) != nil,
      let date = fractional ?? formatter.date(from: value)
    else { throw ReminderError.invalidDate }
    try validate(date)
    return date
  }

  fileprivate static func validate(_ date: Date) throws {
    guard (0..<253_402_300_800).contains(date.timeIntervalSince1970) else {
      throw ReminderError.invalidDate
    }
  }

  public static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    if date.timeIntervalSince1970.rounded(.down) != date.timeIntervalSince1970 {
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    return formatter.string(from: date)
  }
}

public enum ReminderError: LocalizedError {
  case invalidTitle, invalidDate, missingDueDate, unknownID

  public var errorDescription: String? {
    switch self {
    case .invalidTitle: "Enter a reminder title of 1–256 characters."
    case .invalidDate: "Use an ISO 8601 date and time with seconds and a UTC offset, such as 2027-03-15T09:00:00+01:00."
    case .missingDueDate: "A notification or alarm requires a due date. Set alert to none to clear the date."
    case .unknownID: "Reminder not found. List reminders to get its current ID."
    }
  }
}

/// Hosts can expose another destination through the same tools. An Apple
/// Reminders item lives in EventKit, so edits there don't leave a second alarm.
public protocol ReminderBackend: Sendable {
  func list() async throws -> [MaiReminder]
  func add(title: String, due: Date?, alert: ReminderAlert) async throws -> MaiReminder
  func update(id: String, title: String?, due: ReminderDueChange, alert: ReminderAlert?,
    completed: Bool?) async throws -> MaiReminder
  func remove(id: String) async throws
}

public struct ReminderStore: ReminderBackend {
  public struct Snapshot: Codable, Equatable, Sendable {
    public fileprivate(set) var notificationsEnabled = true
    public fileprivate(set) var reminders: [MaiReminder] = []

    public init() {}

    public var scheduled: [MaiReminder] {
      guard notificationsEnabled else { return [] }
      return reminders.filter { !$0.completed && $0.alert != .none && $0.dueAt != nil }
    }
  }

  public let url: URL

  public init(directory: URL) {
    url = directory.appendingPathComponent("reminders.json")
  }

  public func snapshot() throws -> Snapshot {
    do {
      return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return Snapshot()
    }
  }

  public func list() async throws -> [MaiReminder] { try snapshot().reminders }

  public func add(title: String, due: Date?, alert: ReminderAlert) async throws -> MaiReminder {
    let reminder = MaiReminder(title: title, due: due, alert: alert)
    try reminder.validate()
    return try await change { value in
      value.reminders.append(reminder)
      return reminder
    }
  }

  public func update(id: String, title: String?, due: ReminderDueChange, alert: ReminderAlert?,
    completed: Bool?
  ) async throws -> MaiReminder {
    try await change { value in
      guard let index = value.reminders.firstIndex(where: { $0.id == id }) else {
        throw ReminderError.unknownID
      }
      try value.reminders[index].update(title: title, due: due, alert: alert, completed: completed)
      return value.reminders[index]
    }
  }

  public func remove(id: String) async throws {
    try await change { value in
      guard let index = value.reminders.firstIndex(where: { $0.id == id }) else {
        throw ReminderError.unknownID
      }
      value.reminders.remove(at: index)
    }
  }

  public func setNotificationsEnabled(_ enabled: Bool) async throws {
    try await change { $0.notificationsEnabled = enabled }
  }

  /// Several REPLs may share one home. Only one claims a due alert.
  public func claimTerminalAlerts(at now: Date = Date()) async throws -> [MaiReminder] {
    func isDue(_ item: MaiReminder) -> Bool {
      !item.terminalAlerted && (item.dueDate ?? .distantFuture) <= now
    }
    guard try snapshot().scheduled.contains(where: isDue) else { return [] }
    return try await change { value in
      let due = value.scheduled.filter(isDue)
      let ids = Set(due.map(\.id))
      for index in value.reminders.indices where ids.contains(value.reminders[index].id) {
        value.reminders[index].terminalAlerted = true
      }
      return due
    }
  }

  private func change<Result>(_ edit: (inout Snapshot) throws -> Result) async throws -> Result {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let lock = try await MaiFileLock.acquire(url: url.appendingPathExtension("lock"))
    defer { withExtendedLifetime(lock) {} }
    var value = try snapshot()
    let old = value
    let result = try edit(&value)
    if value != old { try JSONEncoder().encode(value).write(to: url, options: .atomic) }
    return result
  }
}
