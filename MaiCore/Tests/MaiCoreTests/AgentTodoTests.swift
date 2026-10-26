import Foundation
import Testing

@testable import MaiCore

@Test("A todo list reads and writes a Markdown task list")
func todoMarkdownRoundTrip() {
  let parsed = AgentTodoList(
    markdown: """
      # Plan

      - [ ] Port the tool
      - [x] Read the code
      * Write tests
      1. [X] Numbered and done
      -no space is not a task
      plain prose is ignored
      """)
  #expect(
    parsed.items.map(\.title) == [
      "Port the tool", "Read the code", "Write tests", "Numbered and done",
    ])
  #expect(parsed.items.map(\.isDone) == [false, true, false, true])
  #expect(parsed.pendingCount == 2)
  #expect(parsed.doneCount == 2)
  #expect(
    parsed.markdown == """
      - [ ] Port the tool
      - [x] Read the code
      - [ ] Write tests
      - [x] Numbered and done
      """)
  #expect(AgentTodoList(markdown: "").isEmpty)
  #expect(AgentTodoList().listing == "No todos.")
  #expect(
    parsed.listing.hasPrefix(
      "Todo (2 pending, 2 done):\n1. [ ] Port the tool\n2. [x] Read the code"))
}

@Test("A todo list round-trips through a file and leaves nothing behind when empty")
func todoFileRoundTrip() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-todo-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent(AgentTodoList.filename)

  #expect(try AgentTodoList.load(from: url).isEmpty)
  var list = AgentTodoList()
  list.add("Ship it")
  list.add("Test it")
  list.markDone(at: 1)
  try list.save(to: url)
  #expect(try String(contentsOf: url, encoding: .utf8) == "- [ ] Ship it\n- [x] Test it\n")
  let loaded = try AgentTodoList.load(from: url)
  #expect(loaded.items.map(\.title) == ["Ship it", "Test it"])
  #expect(loaded.items.map(\.isDone) == [false, true])

  try AgentTodoList().save(to: url)
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test("Items are found by number, title, or fragment, pending first")
func todoMatching() {
  var list = AgentTodoList()
  list.add("Write tests")
  list.add("Run tests")
  list.markDone(at: 0)
  list.add("Write docs")

  #expect(list.index(matching: "2") == 1)
  #expect(list.index(matching: "#3") == 2)
  #expect(list.index(matching: "-1") == 2)
  #expect(list.index(matching: "#-2") == 1)
  #expect(list.index(matching: "-3") == 0)
  #expect(list.index(matching: "-4") == nil)
  #expect(list.index(matching: "0") == nil)
  #expect(list.index(matching: String(Int.min)) == nil)
  #expect(list.index(matching: "4") == nil)
  #expect(list.index(matching: "write tests") == 0)
  // A fragment prefers what is still pending over what is already done.
  #expect(list.index(matching: "write") == 2)
  #expect(list.index(matching: "tests") == 1)
  #expect(list.index(matching: "nope") == nil)
  #expect(list.index(matching: "  ") == nil)
  // Adding a pending duplicate is a no-op; a done one may be planned again.
  #expect(list.add("run tests") == nil)
  #expect(list.add("Write tests") != nil)
  #expect(list.items.count == 4)
}

@Test("Removing an item drops it and renumbers the rest")
func todoRemove() {
  var list = AgentTodoList(items: [
    AgentTodoItem(title: "write tests"),
    AgentTodoItem(title: "ship", isDone: true),
    AgentTodoItem(title: "write docs"),
  ])
  #expect(list.remove(at: 3) == nil)
  #expect(list.remove(at: -1) == nil)
  let removed = list.remove(at: 1)
  #expect(removed?.title == "ship")
  #expect(list.items.map(\.title) == ["write tests", "write docs"])
  #expect(list.doneCount == 0)
  #expect(list.index(matching: "2") == 1)
  #expect(list.index(matching: "docs") == 1)
  #expect(list.listing.contains("2. [ ] write docs"))
}

@Test("Sweeping completed items preserves pending work in order")
func todoRemoveCompleted() {
  var list = AgentTodoList(items: [
    AgentTodoItem(title: "write tests"),
    AgentTodoItem(title: "old task", isDone: true),
    AgentTodoItem(title: "write docs"),
    AgentTodoItem(title: "shipped", isDone: true),
  ])

  #expect(list.removeCompleted() == 2)
  #expect(list.items.map(\.title) == ["write tests", "write docs"])
  #expect(list.pendingCount == 2)
  #expect(list.doneCount == 0)
  #expect(list.removeCompleted() == 0)
}

@Test("The todo tools add, list, and tick off items")
func todoTools() {
  var list = AgentTodoList()
  #expect(MaiTodoTools.execute(name: "todo_list", arguments: [:], list: &list) == "No todos.")
  #expect(
    MaiTodoTools.execute(name: "todo_add", arguments: [:], list: &list)
      == "Error: title is required.")

  // One title per line plans several steps at once, bullets and all.
  let added = MaiTodoTools.execute(
    name: "todo_add",
    arguments: ["title": .string("- [ ] Read the code\n- Port the tool\n\nWrite tests")],
    list: &list)
  #expect(added.hasPrefix("Added 3 items."))
  #expect(list.items.map(\.title) == ["Read the code", "Port the tool", "Write tests"])

  let single = MaiTodoTools.execute(
    name: "todo_add", arguments: ["title": .string("Update docs")], list: &list)
  #expect(single.hasPrefix("Added: Update docs (#4)"))
  #expect(
    MaiTodoTools.execute(
      name: "todo_add", arguments: ["title": .string("update docs")], list: &list
    ).hasPrefix("Already listed: update docs"))

  let done = MaiTodoTools.execute(
    name: "todo_done", arguments: ["task": .string("2")], list: &list)
  #expect(done == "Done: Port the tool. 3 pending.")
  #expect(list.items[1].isDone)
  #expect(
    MaiTodoTools.execute(name: "todo_done", arguments: ["task": .string("port")], list: &list)
      .hasPrefix("Already done: Port the tool"))
  #expect(
    MaiTodoTools.execute(name: "todo_done", arguments: ["number": .number(4)], list: &list)
      .hasPrefix("Done: Update docs."))
  // Several items in one call, by number and by fragment, answered in one line.
  #expect(
    MaiTodoTools.execute(name: "todo_done", arguments: ["task": .string("1, tests")], list: &list)
      == "Done: Read the code; Write tests. 0 pending.")
  #expect(
    MaiTodoTools.execute(name: "todo_done", arguments: ["task": .string("nope")], list: &list)
      .hasPrefix("Error: no todo matched 'nope'."))
  #expect(
    MaiTodoTools.execute(name: "todo_done", arguments: [:], list: &list)
      == "Error: task is required.")

  let listed = MaiTodoTools.execute(name: "todo_list", arguments: [:], list: &list)
  #expect(listed.hasPrefix("Todo (0 pending, 4 done):"))
  #expect(listed.contains("1. [x] Read the code"))
  #expect(listed.contains("4. [x] Update docs"))
  #expect(
    MaiTodoTools.execute(name: "todo_nope", arguments: [:], list: &list)
      == "Error: unknown todo tool 'todo_nope'.")
}

@Test("File-backed todo tools persist every change and see outside edits")
func todoFileBackedTools() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-todo-tools-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent(AgentTodoList.filename)
  let context = ToolExecutionContext(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0),
    modelTurn: 1)

  let tools = MaiTodoTools.makeTools(url: { url })
  #expect(tools.map(\.definition.name) == MaiTodoTools.toolNames)
  let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.name, $0) })

  let added = try await byName["todo_add"]!.call(
    arguments: .object(["title": .string("Ship it")]), context: context)
  #expect(!added.isError)
  #expect(try String(contentsOf: url, encoding: .utf8) == "- [ ] Ship it\n")

  // Someone edits the file in an editor between two calls.
  try Data("- [ ] Ship it\n- [ ] Announce it\n".utf8).write(to: url)
  let done = try await byName["todo_done"]!.call(
    arguments: .object(["task": .string("announce")]), context: context)
  #expect(done.text.hasPrefix("Done: Announce it"))
  #expect(try String(contentsOf: url, encoding: .utf8) == "- [ ] Ship it\n- [x] Announce it\n")

  let missing = try await byName["todo_done"]!.call(
    arguments: .object(["task": .string("nothing")]), context: context)
  #expect(missing.isError)

  // Without a project there is nowhere to keep the list.
  let unavailable = MaiTodoTools.makeTools(url: { nil })
  let refused = try await unavailable[0].call(arguments: .object([:]), context: context)
  #expect(refused.isError)
  #expect(refused.text.hasPrefix("Error: no project is open"))
}
