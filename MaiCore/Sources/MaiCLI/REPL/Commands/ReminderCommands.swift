import Foundation
import MaiACP
import MaiCore
import MaiStandardTools

extension MaiCLI {
  static let remindersHelp = """
    /reminders [all]                List reminders and their IDs
    /reminders add TITLE            Add an undated reminder
    /reminders at DATE TITLE        Add a reminder with a notification
    /reminders alarm DATE TITLE     Add a reminder with a terminal bell
    /reminders move ID DATE         Reschedule a reminder
    /reminders rename ID TITLE      Change a reminder's title
    /reminders done|reopen|remove ID
    /reminders alerts [on|off]      Show or change local notifications
    Use ISO 8601 dates, for example 2027-03-15T09:00:00+01:00.
    Terminal alerts arrive while the REPL is running, with overdue alerts on startup.
    """

  static func handleRemindersCommand(_ argument: String, store: ReminderStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
    let action = fields.first ?? "list"
    let rest = fields.dropFirst().joined(separator: " ")
    do {
      let operation: ReminderTools.Operation
      let arguments: [String: JSONValue]
      switch action {
      case "list", "all":
        guard fields.count <= 1 else { throw JSONRPCError.invalidParams(remindersHelp) }
        operation = .list
        arguments = ["include_completed": .bool(action == "all")]
      case "add" where !rest.isEmpty:
        operation = .add
        arguments = ["title": .string(rest)]
      case "at", "alarm":
        guard fields.count == 3 else { throw JSONRPCError.invalidParams(remindersHelp) }
        operation = .add
        arguments = ["due": .string(fields[1]), "title": .string(fields[2]),
          "alert": .string(action == "alarm" ? "alarm" : "notification")]
      case "done", "reopen", "remove":
        guard fields.count == 2 else { throw JSONRPCError.invalidParams(remindersHelp) }
        operation = action == "remove" ? .remove : .update
        arguments = action == "remove" ? ["id": .string(fields[1])]
          : ["id": .string(fields[1]), "completed": .bool(action == "done")]
      case "move", "rename":
        guard fields.count == 3 else { throw JSONRPCError.invalidParams(remindersHelp) }
        operation = .update
        arguments = ["id": .string(fields[1]),
          (action == "move" ? "due" : "title"): .string(fields[2])]
      case "alerts":
        switch rest {
        case "on", "off": try await store.setNotificationsEnabled(rest == "on")
        case "": break
        default: throw JSONRPCError.invalidParams(remindersHelp)
        }
        let snapshot = try store.snapshot()
        await terminal.line("Reminder alerts: \(snapshot.notificationsEnabled ? "on" : "off")")
        return
      default:
        await terminal.line(remindersHelp)
        return
      }
      let result = try await ReminderTools.execute(operation, arguments: arguments, backend: store)
      await terminal.line(result.text)
    } catch {
      await terminal.line("reminders: \(error.localizedDescription)", to: .standardError)
    }
  }

  static func deliverReminderAlerts(store: ReminderStore, terminal: TerminalWriter) async {
    var lastError: String?
    while !Task.isCancelled {
      do {
        for reminder in try await store.claimTerminalAlerts() {
          let title = reminder.title.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
          }
          await terminal.reminderAlert(String(String.UnicodeScalarView(title)),
            audible: reminder.alert == .alarm)
        }
        lastError = nil
      } catch {
        if Task.isCancelled { return }
        if error.localizedDescription != lastError {
          lastError = error.localizedDescription
          await terminal.line("reminders: \(error.localizedDescription)", to: .standardError)
        }
      }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }
}
