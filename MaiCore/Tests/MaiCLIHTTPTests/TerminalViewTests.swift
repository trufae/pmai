import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("View selectors resolve agents and tools without changing the conversation")
func terminalViewSelectors() throws {
  let processes = [
    AgentProcessInfo(pid: 1, runID: UUID(), agentID: "main"),
    AgentProcessInfo(
      pid: 2, parent: 1, runID: UUID(), agentID: "worker", displayName: "Review code", depth: 1),
  ]
  func source(_ input: String) throws -> TerminalViewSource? {
    try MaiCLI.viewSource(
      input, processes: processes, tools: ["files_read"], mainConversation: "chat:test"
    ).source
  }
  #expect(try source("off") == nil)
  #expect(try source("current") == .current)
  #expect(try source("main") == .conversation("chat:test"))
  #expect(try source("1") == .conversation("chat:test"))
  for name in ["worker", "Review code", "agent Review code", "2", "#2", "agent#2"] {
    #expect(try source(name) == .conversation("agent:2"))
  }
  #expect(try source("thinking") == .thinking)
  #expect(try source("diffs") == .diffs)
  #expect(try source("agents") == .conversations)
  #expect(try source("pins") == .pins)
  #expect(try source(" LOG ") == .log)
  #expect(try source(" TODO ") == .todo)
  #expect(try source("tools") == .tools(nil))
  for name in ["files_read", "tool files_read", "tools files_read"] {
    #expect(try source(name) == .tools("files_read"))
  }
  for name in [
    "", "missing", "tools missing", "thinking extra", "pins extra", "log extra", "off extra",
    "agent", "todo extra",
  ] {
    #expect(throws: (any Error).self) { try source(name) }
  }
  let duplicate = AgentProcessInfo(pid: 3, parent: 1, runID: UUID(), agentID: "worker", depth: 1)
  #expect(throws: (any Error).self) {
    try MaiCLI.viewSource(
      "worker", processes: processes + [duplicate], tools: [], mainConversation: "chat:test")
  }
}

@Test("Todo views show the command rendering and retain their scroll anchor on updates")
func terminalViewTodo() async {
  let terminal = TerminalWriter(capturesOutput: true)
  var list = AgentTodoList()
  var view = TerminalView(source: .todo, title: "project todo")
  view.updateTodo(await terminal.renderTodoList(list))
  #expect(view.buffer.visibleRows(width: 80, height: 10) == ["No todos."])
  for index in 1...30 { list.add("Task \(index)") }
  view.updateTodo(await terminal.renderTodoList(list))
  view.buffer.scroll(lines: -10, width: 80, height: 4)
  let anchor = view.buffer.visibleRows(width: 80, height: 4)
  list.markDone(at: 29)
  list.add("New task")
  view.updateTodo(await terminal.renderTodoList(list))
  #expect(view.buffer.visibleRows(width: 80, height: 4) == anchor)
  view.buffer.follow()
  #expect(
    view.buffer.visibleRows(width: 80, height: 4).suffix(2) == [
      "30. [x] Task 30", "31. [ ] New task",
    ])
  view.buffer.scroll(lines: -Int.max, width: 80, height: 4)
  #expect(view.buffer.visibleRows(width: 80, height: 4).first == "Todo (30 pending, 1 done):")
  view.updateTodo(await terminal.renderTodoList(AgentTodoList()))
  #expect(view.buffer.visibleRows(width: 80, height: 10) == ["No todos."])
}

@Test("Message views keep transcript order, full pins and one first line per message")
func terminalViewMessages() {
  let messages: [AgentMessage] = [
    .system("Instructions\nMore instructions"),
    AgentMessage(role: .user, content: [.text("Question\r\nSECOND_USER_LINE")], isPinned: true),
    .assistant("Answer\nSECOND_ASSISTANT_LINE\n\nLast paragraph"),
    AgentMessage(
      role: .assistant,
      content: [
        .toolCall(
          ToolCall(id: "read", name: "files_read", arguments: .object([:])))
      ]),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(
          ToolResult(callID: "read", text: "Result\nSECOND_TOOL_LINE"))
      ]),
    AgentMessage(role: .assistant, content: [], isPinned: true),
  ]
  var log = TerminalView(source: .log, title: "log")
  log.updateMessages(messages)
  let rows = log.buffer.visibleRows(width: 160, height: 100)
  #expect(
    rows == [
      "system: Instructions", "user: Question", "assistant: Answer",
      "assistant: [tool call files_read {}]", "tool: [tool result] Result",
      "assistant: [empty message]",
    ])
  var pins = TerminalView(source: .pins, title: "pins")
  pins.updateMessages(messages)
  let text = pins.buffer.visibleRows(width: 160, height: 100).joined(separator: "\n")
  #expect(text.contains("[2] 📌 user:\nQuestion\nSECOND_USER_LINE"))
  #expect(text.contains("[6] 📌 assistant:\n[empty message]"))
  #expect(!text.contains("Answer") && !text.contains("Instructions"))
  var changed = messages
  changed[1].isPinned = false
  changed[2].isPinned = true
  pins.updateMessages(changed)
  let updated = pins.buffer.visibleRows(width: 160, height: 100).joined(separator: "\n")
  #expect(!updated.contains("Question"))
  #expect(updated.contains("[3] 📌 assistant:\nAnswer\nSECOND_ASSISTANT_LINE\n\nLast paragraph"))
  pins.updateMessages([])
  #expect(pins.buffer.visibleRows(width: 160, height: 100).joined().contains("No pinned messages."))
  log.updateMessages([])
  #expect(log.buffer.visibleRows(width: 160, height: 100) == ["No conversation messages yet."])
}

@Test("Message views retain their scroll anchor as messages arrive and are edited")
func terminalViewMessageScroll() {
  var messages = (0..<100).map { AgentMessage.user("Message \($0)\nsecond line") }
  var view = TerminalView(source: .log, title: "log")
  view.updateMessages(messages)
  view.buffer.scroll(lines: -15, width: 80, height: 4)
  let anchor = view.buffer.visibleRows(width: 80, height: 4)
  messages.append(.assistant("New reply"))
  view.updateMessages(messages)
  #expect(view.buffer.visibleRows(width: 80, height: 4) == anchor)
  view.buffer.scroll(lines: -Int.max, width: 80, height: 4)
  #expect(view.buffer.visibleRows(width: 80, height: 4).first == "user: Message 0")
  messages[0] = .user("Edited message")
  view.updateMessages(messages)
  #expect(view.buffer.visibleRows(width: 80, height: 4).first == "user: Edited message")
  view.buffer.follow()
  #expect(view.buffer.visibleRows(width: 80, height: 4).last == "assistant: New reply")
}

@Test("View projections reveal hidden thinking and respect tool result settings")
func terminalViewProjections() {
  var source = TerminalOutputBuffer()
  source.configureThinking(.status)
  source.configureTools(.lines(0))
  source.append("prompt\n")
  let thinking = source.appendThinking("thought one\nthought two")
  let tool = source.appendTool(
    call: ToolCall(id: "read", name: "files_read", arguments: .object([:])), result: nil)
  source.appendReply("answer")
  let original = source.visibleRows(width: 80, height: 50)
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .thinking)
  #expect(view.visibleRows(width: 80, height: 50) == ["thought one", "thought two"])
  view.updateView(from: source, selection: .tools(nil))
  #expect(view.visibleRows(width: 80, height: 50).isEmpty)
  source.appendThinking(" streamed", to: thinking)
  source.appendTool(
    call: nil,
    result: ToolResult(callID: "read", text: "result one\nresult two\nresult three\nresult four"),
    to: tool)
  for (display, count) in [
    (ToolResultDisplay.lines(0), 0), (.lines(1), 1), (.relevant, 3), (.all, 4), (.lines(0), 0),
  ] {
    source.configureTools(display)
    for selection in [TerminalOutputSelection.tools(nil), .tools("files_read")] {
      view.updateView(from: source, selection: selection)
      let rows = view.visibleRows(width: 80, height: 50).joined(separator: "\n")
      for (index, line) in ["result one", "result two", "result three", "result four"].enumerated()
      {
        #expect(rows.contains(line) == (index < count))
      }
      #expect(rows.contains("files_read"))
      #expect(!rows.contains("answer") && !rows.contains("thought"))
    }
  }
  view.updateView(from: source, selection: .tools("missing"))
  #expect(view.visibleRows(width: 80, height: 50).isEmpty)
  view.scroll(lines: -10, width: 80, height: 5)
  view.updateView(from: source, selection: .thinking)
  #expect(view.visibleRows(width: 80, height: 50).last == "thought two streamed")
  let after = source.visibleRows(width: 80, height: 50).joined(separator: "\n")
  #expect(!after.contains("thought") && !after.contains("result"))
  #expect(original.contains("answer"))
}

@Test("Diff views include successful applied changes and exclude errors, reads and no-ops")
func terminalViewDiffs() {
  var source = TerminalOutputBuffer()
  let diff = "Updated file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new"
  for (changed, error, text) in [
    (true, false, diff), (true, true, diff), (false, false, diff), (true, false, "no diff"),
  ] {
    source.appendTool(
      call: ToolCall(id: "edit", name: "files_patch", arguments: .object([:])),
      result: ToolResult(
        callID: "edit", content: [.text(text)],
        structuredContent: .object(["changed": .bool(changed)]), isError: error))
  }
  source.appendTool(call: nil, result: ToolResult(callID: "read", text: diff))
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .diffs)
  let rows = view.visibleRows(width: 80, height: 100)
  #expect(rows.filter { $0 == "  +new" }.count == 1)
  #expect(!rows.joined().contains("no diff"))
}

@Test("View scrolling stays independent across live updates, reflow and clearing")
func terminalViewScroll() {
  var source = TerminalOutputBuffer()
  source.append((0..<40).map { "row \($0)" }.joined(separator: "\n"))
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .all)
  view.scroll(lines: -15, width: 20, height: 4)
  let anchor = view.visibleRows(width: 20, height: 4)
  source.append("\nnew row")
  view.updateView(from: source, selection: .all)
  #expect(view.visibleRows(width: 20, height: 4) == anchor)
  #expect(source.visibleRows(width: 20, height: 4).last == "new row")
  #expect(view.visibleRows(width: 4, height: 4).first == "row ")
  source.clear()
  view.updateView(from: source, selection: .all)
  #expect(view.visibleRows(width: 20, height: 4) == [""])
  for available in 1...100 {
    let height = TerminalView.height(availableRows: available)
    #expect(height == 0 || height + 2 <= available)
  }
  #expect(TerminalView.height(availableRows: 22, preferredHeight: 6) == 6)
  #expect(TerminalView.height(availableRows: 3, preferredHeight: 6) == 1)
  #expect(TerminalView.height(availableRows: 2, preferredHeight: 6) == 0)
  #expect(TerminalView.height(availableRows: 22, preferredHeight: 0) == 1)
  #expect(TerminalView.height(availableRows: 22, preferredHeight: 100) == 20)
}
