import Foundation

/// One task on a project's todo list.
public struct AgentTodoItem: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var isDone: Bool
  public var createdAt: Date

  public init(id: UUID = UUID(), title: String, isDone: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.isDone = isDone
    self.createdAt = createdAt
  }
}

/// The tasks an agent and the person it works with are tracking: what is
/// still to do and what is already done, in the order it was planned.
///
/// pmai keeps one per project in `.pmai/todo.md` and PocketMai keeps one in
/// its settings, but the list, the Markdown it is stored as, and the tools
/// that drive it are all here, so both hosts behave the same.
public struct AgentTodoList: Codable, Equatable, Sendable {
  /// Markdown, not JSON: a GitHub task list people can read and edit by hand.
  public static let filename = "todo.md"

  public var items: [AgentTodoItem]

  public init(items: [AgentTodoItem] = []) {
    self.items = items
  }

  public var isEmpty: Bool { items.isEmpty }
  public var pendingCount: Int { items.filter { !$0.isDone }.count }
  public var doneCount: Int { items.count - pendingCount }

  // MARK: Markdown

  /// Reads a task list: one `- [ ] title` or `- [x] title` per line. Bullets
  /// without a checkbox count as pending; headings and prose are ignored.
  public init(markdown: String, createdAt: Date = Date()) {
    items = markdown.components(separatedBy: .newlines).compactMap {
      Self.parseItem($0, createdAt: createdAt)
    }
  }

  public var markdown: String {
    items.map { "- [\($0.isDone ? "x" : " ")] \($0.title)" }.joined(separator: "\n")
  }

  private static func parseItem(_ line: String, createdAt: Date) -> AgentTodoItem? {
    var rest = Substring(line.trimmingCharacters(in: .whitespaces))
    if let first = rest.first, "-*+".contains(first) {
      rest = rest.dropFirst()
    } else {
      let digits = rest.prefix { $0.isNumber }
      guard !digits.isEmpty, let marker = rest.dropFirst(digits.count).first,
        marker == "." || marker == ")"
      else { return nil }
      rest = rest.dropFirst(digits.count + 1)
    }
    guard rest.first?.isWhitespace == true else { return nil }
    rest = rest.drop { $0.isWhitespace }
    var isDone = false
    if rest.hasPrefix("["), rest.count >= 3 {
      let mark = rest[rest.index(after: rest.startIndex)]
      let close = rest[rest.index(rest.startIndex, offsetBy: 2)]
      if close == "]", mark == " " || mark == "x" || mark == "X" {
        isDone = mark != " "
        rest = rest.dropFirst(3)
      }
    }
    let title = rest.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }
    return AgentTodoItem(title: title, isDone: isDone, createdAt: createdAt)
  }

  /// Reads the list file, answering an empty list when there is none.
  public static func load(from url: URL) throws -> AgentTodoList {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return AgentTodoList() }
    let modified =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
      ?? nil
    return AgentTodoList(markdown: text, createdAt: modified ?? Date())
  }

  /// Writes the list, removing the file when it is empty so an untouched
  /// project leaves nothing behind.
  public func save(to url: URL) throws {
    guard !isEmpty else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((markdown + "\n").utf8).write(to: url, options: .atomic)
  }

  // MARK: Reading

  /// The numbered rendering models and people see; numbers are what
  /// `todo_done` takes, so they must match what `todo_list` printed.
  public var listing: String {
    guard !isEmpty else { return "No todos." }
    let lines = items.enumerated().map { index, item in
      "\(index + 1). [\(item.isDone ? "x" : " ")] \(item.title)"
    }
    return "Todo (\(pendingCount) pending, \(doneCount) done):\n" + lines.joined(separator: "\n")
  }

  /// Finds an item by its 1-based number, an id prefix of at least eight
  /// characters, an exact title, or a title fragment. Negative numbers count
  /// from the end; fragments prefer pending items.
  public func index(matching query: String) -> Int? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let number = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    if let index = ListIndex.resolve(number, count: items.count) {
      return index
    }
    let lower = trimmed.lowercased()
    if lower.count >= 8,
      let found = items.firstIndex(where: { $0.id.uuidString.lowercased().hasPrefix(lower) })
    {
      return found
    }
    return items.firstIndex { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
      ?? items.firstIndex { !$0.isDone && $0.title.localizedCaseInsensitiveContains(trimmed) }
      ?? items.firstIndex { $0.title.localizedCaseInsensitiveContains(trimmed) }
  }

  // MARK: Editing

  /// Appends one pending item, or nothing when the title is blank or a
  /// pending item already says the same thing.
  @discardableResult
  public mutating func add(_ title: String, at date: Date = Date()) -> AgentTodoItem? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard
      !items.contains(where: {
        !$0.isDone && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
      })
    else { return nil }
    let item = AgentTodoItem(title: trimmed, createdAt: date)
    items.append(item)
    return item
  }

  public mutating func markDone(at index: Int) {
    guard items.indices.contains(index) else { return }
    items[index].isDone = true
  }

  /// Drops one item; the ones after it move up a number.
  @discardableResult
  public mutating func remove(at index: Int) -> AgentTodoItem? {
    guard items.indices.contains(index) else { return nil }
    return items.remove(at: index)
  }

  /// Drops every completed item while preserving the order of pending work.
  @discardableResult
  public mutating func removeCompleted() -> Int {
    let count = doneCount
    items.removeAll(where: \.isDone)
    return count
  }

  public mutating func removeAll() {
    items.removeAll()
  }
}

/// Tools that let an agent keep a task list: plan the steps of a piece of
/// work, see what is left, and tick items off as it goes.
///
/// The caller owns the list — pmai a file, PocketMai its settings — and
/// passes it in by reference, so nothing here needs to know where it lives.
public enum MaiTodoTools {
  public static let listName = "todo_list"
  public static let addName = "todo_add"
  public static let doneName = "todo_done"

  public static let toolNames = [listName, addName, doneName]
  public static let groupID = "todo"

  /// What `/tools` shows for the family.
  public static let group = ToolGroupDefinition(
    id: groupID,
    sourceID: "runtime",
    displayName: "Todo",
    description:
      "Keep a task list for work of several steps, so nothing is lost across turns or chats: todo_add "
      + "plans the items (one title per line), todo_list shows what is done and what is left, todo_done "
      + "ticks items off by number or title. The list belongs to the project and persists between "
      + "chats; a short task does not need one.",
    toolNames: Set(toolNames))

  public static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description: "List this project's todo items, numbered, [x] marking the done ones.",
      parameters: [],
      annotations: ToolAnnotations(
        readOnly: true, idempotent: true, openWorld: false, approval: .automatic)),
    ToolDefinition(
      name: addName,
      description:
        "Add todo items for work of five or more steps or an agreed planning handoff, one title per line. The list persists across chats.",
      parameters: [
        ToolParameterDef(
          name: "title", type: "string",
          description: "Tasks to add, one per line.",
          required: true)
      ],
      annotations: ToolAnnotations(
        readOnly: false, idempotent: false, openWorld: false, approval: .automatic)),
    ToolDefinition(
      name: doneName,
      description: "Mark todo items done, several at once.",
      parameters: [
        ToolParameterDef(
          name: "task", type: "string",
          description: "Item numbers or title fragments, separated by newlines or commas.",
          required: true)
      ],
      annotations: ToolAnnotations(
        readOnly: false, idempotent: true, openWorld: false, approval: .automatic)),
  ]

  public static func execute(
    name: String,
    arguments: [String: JSONValue],
    list: inout AgentTodoList
  ) -> String {
    switch name {
    case listName: list.listing
    case addName: add(arguments: arguments, list: &list)
    case doneName: markDone(arguments: arguments, list: &list)
    default: "Error: unknown todo tool '\(name)'."
    }
  }

  /// The tools over a list kept in a file the person may edit between calls,
  /// so every call reads the file afresh and writes it back when it changed.
  /// `url` answers nil while no list is available, such as before a project
  /// is open.
  public static func makeTools(url: @escaping @Sendable () -> URL?) -> [any AgentTool] {
    let file = TodoFile(url: url)
    return definitions.map { definition in
      ClosureTool(definition: definition) { arguments, _ in
        let text = try await file.perform(name: definition.name, arguments: arguments)
        return ToolOutput(text: text, isError: text.hasPrefix("Error:"))
      }
    }
  }

  private static func add(arguments: [String: JSONValue], list: inout AgentTodoList) -> String {
    var titles = arguments["titles"]?.arrayValue?.compactMap(\.stringValue) ?? []
    if titles.isEmpty {
      let text =
        arguments["title"]?.stringValue ?? arguments["task"]?.stringValue
        ?? arguments["text"]?.stringValue ?? ""
      titles = text.components(separatedBy: .newlines)
    }
    titles = titles.map(stripBullet).filter { !$0.isEmpty }
    guard !titles.isEmpty else { return "Error: title is required." }
    var added: [String] = []
    var skipped: [String] = []
    for title in titles {
      if list.add(title) != nil { added.append(title) } else { skipped.append(title) }
    }
    // One line: the numbers the items got, and how many are open. The full
    // list is a todo_list call away and need not ride along on every add.
    var parts: [String] = []
    if added.count == 1 {
      parts.append("Added: \(added[0]) (#\(list.items.count)).")
    } else if !added.isEmpty {
      let first = list.items.count - added.count + 1
      parts.append("Added \(added.count) items. (#\(first)-#\(list.items.count))")
    }
    if !skipped.isEmpty {
      parts.append("Already listed: \(skipped.joined(separator: "; ")).")
    }
    parts.append("\(list.pendingCount) pending.")
    return parts.joined(separator: " ")
  }

  /// Several items at once, by number or title fragment, answered in one line:
  /// a model ticking off seven steps one call at a time, each call returning
  /// the whole list, spent more tokens on bookkeeping than on the work.
  private static func markDone(arguments: [String: JSONValue], list: inout AgentTodoList) -> String
  {
    var queries = arguments["tasks"]?.arrayValue?.compactMap(\.stringValue) ?? []
    if queries.isEmpty {
      let text =
        arguments["task"]?.stringValue ?? arguments["title_or_id"]?.stringValue
        ?? arguments["id"]?.stringValue ?? arguments["title"]?.stringValue
        ?? arguments["number"].flatMap { $0.intValue.map(String.init) ?? $0.stringValue }
        ?? ""
      queries = text.split { $0 == "\n" || $0 == "," }.map(String.init)
    }
    queries = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !queries.isEmpty else { return "Error: task is required." }
    guard !list.isEmpty else { return "Error: the todo list is empty." }
    var done: [String] = []
    var already: [String] = []
    var unmatched: [String] = []
    for query in queries {
      guard let index = list.index(matching: query) else {
        unmatched.append(query)
        continue
      }
      let item = list.items[index]
      if item.isDone {
        already.append(item.title)
      } else {
        list.markDone(at: index)
        done.append(item.title)
      }
    }
    var parts: [String] = []
    if !done.isEmpty { parts.append("Done: \(done.joined(separator: "; ")).") }
    if !already.isEmpty { parts.append("Already done: \(already.joined(separator: "; ")).") }
    if !unmatched.isEmpty {
      parts.append("No todo matched: \(unmatched.joined(separator: "; ")).")
    }
    if done.isEmpty && already.isEmpty {
      return "Error: no todo matched '\(queries.joined(separator: ", "))'."
    }
    parts.append("\(list.pendingCount) pending.")
    return parts.joined(separator: " ")
  }

  /// Models sometimes send the list the way people write it; the bullet is
  /// not part of the task.
  private static func stripBullet(_ title: String) -> String {
    var trimmed = Substring(title.trimmingCharacters(in: .whitespacesAndNewlines))
    if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
      trimmed = trimmed.dropFirst(2)
    }
    if trimmed.hasPrefix("[ ] ") || trimmed.hasPrefix("[x] ") || trimmed.hasPrefix("[X] ") {
      trimmed = trimmed.dropFirst(4)
    }
    return trimmed.trimmingCharacters(in: .whitespaces)
  }
}

/// Serializes the read-modify-write of one list file, so two tool calls
/// landing together cannot lose each other's change.
private actor TodoFile {
  private let url: @Sendable () -> URL?

  init(url: @escaping @Sendable () -> URL?) {
    self.url = url
  }

  func perform(name: String, arguments: JSONValue) throws -> String {
    guard let url = url() else {
      return "Error: no project is open, so there is no todo list."
    }
    var list = try AgentTodoList.load(from: url)
    let before = list
    let text = MaiTodoTools.execute(
      name: name, arguments: arguments.objectValue ?? [:], list: &list)
    if list != before { try list.save(to: url) }
    return text
  }
}
