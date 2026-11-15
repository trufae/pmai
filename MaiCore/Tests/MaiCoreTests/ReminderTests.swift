import Foundation
import Testing
@testable import MaiCore

@Test func reminderAlertsSurviveRestartsAndRescheduling() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let writer = ReminderStore(directory: directory)
  let reader = ReminderStore(directory: directory)
  let due = try ReminderDate.parse("2027-01-02T09:00:00+01:00")
  let reminder = try await writer.add(title: "Call home", due: due, alert: .alarm)

  #expect(try await reader.claimTerminalAlerts(at: due.addingTimeInterval(-1)).isEmpty)
  try await writer.setNotificationsEnabled(false)
  #expect(try await reader.claimTerminalAlerts(at: due).isEmpty)
  try await writer.setNotificationsEnabled(true)
  async let first = writer.claimTerminalAlerts(at: due)
  async let second = reader.claimTerminalAlerts(at: due)
  let alerts = try await first + second
  #expect(alerts.map(\.id) == [reminder.id])

  let moved = due.addingTimeInterval(3_600)
  _ = try await writer.update(id: reminder.id, title: nil, due: .set(moved), alert: nil, completed: nil)
  #expect(try await reader.claimTerminalAlerts(at: due).isEmpty)
  _ = try await writer.update(id: reminder.id, title: nil, due: .keep, alert: nil, completed: true)
  #expect(try await reader.claimTerminalAlerts(at: moved).isEmpty)
  _ = try await writer.update(id: reminder.id, title: nil, due: .keep, alert: nil, completed: false)
  #expect(try await reader.claimTerminalAlerts(at: moved).map(\.id) == [reminder.id])
  try await writer.remove(id: reminder.id)
  #expect(try await reader.list().isEmpty)
  #expect(try reader.snapshot().scheduled.isEmpty)
}

@Test func invalidReminderScheduleLeavesSavedReminderAlone() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ReminderStore(directory: directory)
  let utc = try ReminderDate.parse("2027-01-02T08:00:00Z")
  #expect(try ReminderDate.parse("2027-01-02T09:00:00+01:00") == utc)
  #expect(throws: ReminderError.self) { try ReminderDate.parse("2027-01-02T09:00:00") }
  let item = try await store.add(title: "Pay rent", due: utc, alert: .notification)
  await #expect(throws: ReminderError.self) {
    try await store.update(id: item.id, title: "Changed", due: .clear, alert: nil, completed: nil)
  }
  #expect(try await store.list() == [item])
}
