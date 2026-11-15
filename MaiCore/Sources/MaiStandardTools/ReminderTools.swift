import Foundation
import MaiCore

public enum ReminderTools {
  public static let groupID = "reminders"
  public static let writeOption = "remindersWriteEnabled"

  public static let group = ToolGroupDefinition(
    id: groupID, displayName: "Reminders",
    description: "List, add, edit, complete, and remove reminders. Schedule a notification or an audible alert for a specific time.",
    toolNames: Set(Operation.allCases.map(\.rawValue)),
    options: [.init(id: writeOption, label: "Allow changing reminders", kind: .boolean,
      defaultValue: .bool(true))])

  public enum Operation: String, CaseIterable, Sendable {
    case list = "reminders_list"
    case add = "reminders_add"
    case update = "reminders_update"
    case remove = "reminders_remove"

    public func definition(appleAvailable: Bool = false) -> ToolDefinition {
      let title = property("string", "Short reminder text.")
      let due = property("string", "ISO 8601 timestamp with seconds and a UTC offset.")
      let alert: JSONValue = .object([
        "type": .string("string"),
        "enum": .array(ReminderAlert.allCases.map { .string($0.rawValue) }),
        "description": .string("none, notification, or alarm (audible alert)."),
      ])
      let id = property("string", "Exact ID returned by reminders_list or reminders_add.")
      var properties: [String: JSONValue] = [:]
      let description: String
      let required: [String]
      switch self {
      case .list:
        description = "List open reminders, with their IDs and dates."
        properties["include_completed"] = property("boolean", "Include completed reminders.")
        required = []
      case .add:
        description = "Create a reminder. A due date defaults to a notification; without a date, the reminder is silent."
        properties = ["title": title, "due": due, "alert": alert]
        required = ["title"]
      case .update:
        description = "Edit a reminder, reschedule it, or mark it complete or open."
        properties = ["id": id, "title": title, "due": due, "alert": alert,
          "completed": property("boolean", "True to complete or false to reopen."),
          "clear_due": property("boolean", "Clear the due date and alert.")]
        required = ["id"]
      case .remove:
        description = "Delete a reminder and cancel its alert."
        properties["id"] = id
        required = ["id"]
      }
      if appleAvailable {
        properties["apple"] = property("boolean", "Use the PocketMai list in Apple Reminders. Defaults to the local PocketMai store.")
      }
      return ToolDefinition(name: rawValue, description: description,
        inputSchema: objectSchema(properties: properties, required: required),
        annotations: ToolAnnotations(readOnly: self == .list, destructive: self == .remove,
          idempotent: self != .add, openWorld: false,
          approval: self == .list && !appleAvailable ? .automatic : .confirm))
    }
  }

  public static func makeTools(store: ReminderStore, writeEnabled: Bool = true) -> [any AgentTool] {
    operations(writeEnabled: writeEnabled).map { Tool(operation: $0, store: store) }
  }

  public static func operations(writeEnabled: Bool) -> [Operation] {
    writeEnabled ? Operation.allCases : [.list]
  }

  public static func execute(_ operation: Operation, arguments: [String: JSONValue],
    backend: any ReminderBackend
  ) async throws -> ToolOutput {
    let date = try arguments["due"]?.stringValue.map(ReminderDate.parse)
    let alert = arguments["alert"]?.stringValue.flatMap(ReminderAlert.init(rawValue:))
    if arguments["alert"] != nil && alert == nil {
      throw InvalidArguments(message: "Use alert none, notification, or alarm.")
    }
    let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let title, title.isEmpty || title.count > 256 { throw ReminderError.invalidTitle }
    let id = arguments["id"]?.stringValue ?? ""
    let result: JSONValue
    switch operation {
    case .list:
      let includeCompleted = arguments["include_completed"]?.boolValue == true
      let reminders = try await backend.list()
      result = .array(reminders.filter { includeCompleted || !$0.completed }.sorted {
        ($0.dueAt ?? .infinity, $0.id) < ($1.dueAt ?? .infinity, $1.id)
      }.map(value))
    case .add:
      guard let title else { throw ReminderError.invalidTitle }
      let new = try await backend.add(title: title, due: date,
        alert: alert ?? (date == nil ? .none : .notification))
      result = value(new)
    case .update:
      let clear = arguments["clear_due"]?.boolValue == true
      guard !clear || (date == nil && (alert == nil || alert == ReminderAlert.none)) else {
        throw InvalidArguments(message: "Clearing the due date also clears the alert.")
      }
      let due: ReminderDueChange = clear ? .clear : date.map(ReminderDueChange.set) ?? .keep
      result = value(try await backend.update(id: id, title: title, due: due,
        alert: clear ? ReminderAlert.none : alert, completed: arguments["completed"]?.boolValue))
    case .remove:
      try await backend.remove(id: id)
      result = .object(["removed": .string(id)])
    }
    return ToolOutput(text: result.compactJSONString)
  }

  private static func value(_ reminder: MaiReminder) -> JSONValue {
    .object(["id": .string(reminder.id), "title": .string(reminder.title),
      "due": reminder.dueDate.map { .string(ReminderDate.format($0)) } ?? .null,
      "alert": .string(reminder.alert.rawValue), "completed": .bool(reminder.completed)])
  }

  private static func property(_ type: String, _ description: String) -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
  }

  private struct InvalidArguments: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private struct Tool: AgentTool {
    let operation: Operation
    let store: ReminderStore
    var definition: ToolDefinition { operation.definition() }

    func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
      try await execute(operation, arguments: arguments.objectValue ?? [:], backend: store)
    }
  }
}
