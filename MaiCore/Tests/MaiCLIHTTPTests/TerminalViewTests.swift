import Foundation
import MaiCore
import MaiMarkdown
import Testing

@testable import MaiCLI

@Test("Aggregate views retain independent sections and reflow nested blocks")
func terminalAggregateSections() {
  var first = TerminalOutputBuffer()
  let reply = first.appendReply("abcdefghijklmnop\nsecond line")
  first.finishReply(reply)
  var second = TerminalOutputBuffer()
  second.append("last section")
  var aggregate = TerminalOutputBuffer()
  aggregate.append("first\n")
  let block = aggregate.retain(first)
  aggregate.append("second\n")
  aggregate.retain(second)
  for width in [4, 80, 7] {
    let rows = aggregate.visibleRows(width: width, height: 100)
    aggregate.scroll(to: 0, width: width, height: 3)
    #expect(aggregate.visibleRows(width: width, height: 3) == Array(rows.prefix(3)))
    aggregate.follow()
  }
  first.append("\nnew output")
  aggregate.retain(first, at: block)
  let text = aggregate.visibleRows(width: 80, height: 100).joined(separator: "\n")
  #expect(text.contains("new output"))
  #expect(text.contains("last section"))
}

@Test("View snapshots preserve pane state and track edits and source replacement")
func terminalViewSnapshotUpdates() {
  var source = TerminalOutputBuffer()
  source.append((0..<40).map { "row \($0)" }.joined(separator: "\n"))
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .all)
  view.scroll(to: 5, width: 20, height: 5)
  view.configureHighlight("row")
  let before = view.visibleRows(width: 20, height: 5)
  view.updateView(from: source, selection: .all)
  #expect(view.visibleRows(width: 20, height: 5) == before)
  source.append("\nnew row")
  view.updateView(from: source, selection: .all)
  #expect(view.visibleRows(width: 20, height: 5).first == "row 5")
  view.follow()
  #expect(view.visibleRows(width: 20, height: 5).last == "new row")
  source.clear()
  view.updateView(from: source, selection: .all)
  #expect(view.visibleRows(width: 20, height: 5) == [""])
  var replacement = TerminalOutputBuffer()
  replacement.append("replacement")
  view.updateView(from: replacement, selection: .all)
  #expect(view.visibleRows(width: 20, height: 5) == ["replacement"])
}

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
  #expect(try source("voice") == .voice)
  #expect(try source("diffs") == .diffs)
  #expect(try source("history") == .history)
  #expect(try source("prompt $tldr") == .prompt)
  #expect(try source("agents") == .conversations)
  #expect(try source("pins") == .pins)
  #expect(try source(" LOG ") == .log)
  #expect(try source(" TODO ") == .todo)
  #expect(try source(" ICONLOG ") == .iconlog)
  #expect(try source("tools") == .tools(nil))
  for name in ["files_read", "tool files_read", "tools files_read"] {
    #expect(try source(name) == .tools("files_read"))
  }
  for name in [
    "", "missing", "tools missing", "thinking extra", "pins extra", "log extra", "off extra",
    "agent", "todo extra", "iconlog extra", "prompt", "history extra", "voice extra",
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

@Test("Thinking and pinned views render Markdown and reflow without changing the source")
func terminalViewMarkdown() {
  let renderer = MarkdownTerminalRenderer(theme: .plain)
  var source = TerminalOutputBuffer()
  source.configureMarkdown(renderer)
  source.appendThinking("# Reasoning\n\n**needle** and `code`\n")
  var projected = TerminalOutputBuffer()
  projected.updateView(from: source, selection: .thinking)
  let styled = projected.visibleRows(width: 80, height: 30).joined(separator: "\n")
  #expect(styled.contains("Reasoning") && !styled.contains("# Reasoning"))
  #expect(styled.contains("needle") && !styled.contains("**needle**"))
  #expect(!styled.contains("`code`"))
  #expect(source.visibleRows(width: 80, height: 30).joined().contains("**needle**"))
  projected.updateView(from: source, selection: .all)
  #expect(!projected.visibleRows(width: 80, height: 30).joined().contains("**needle**"))
  projected.configureMarkdown(nil)
  #expect(projected.visibleRows(width: 80, height: 30).joined().contains("**needle**"))

  var pins = TerminalView(source: .pins, title: "pins", markdown: renderer)
  pins.updateMessages([AgentMessage(role: .assistant, content: [.text("# Heading\n\n**bold** text")], isPinned: true)])
  let text = pins.buffer.visibleRows(width: 80, height: 30).joined(separator: "\n")
  #expect(text.contains("Heading") && !text.contains("# Heading"))
  #expect(text.contains("bold") && !text.contains("**bold**"))
  pins.configureMarkdown(nil)
  #expect(pins.buffer.visibleRows(width: 80, height: 30).joined().contains("**bold**"))
}


@Test("Git snapshots retain a scrolled viewport when output changes or shrinks")
func terminalViewGitScroll() {
  var view = TerminalView(source: .diffs, title: "git diff")
  let lines = (0..<40).map { "diff line \($0)" }
  view.updateText(lines.joined(separator: "\n"))
  #expect(view.buffer.visibleRows(width: 80, height: 4).first == "diff line 0")
  view.buffer.scroll(lines: 12, width: 80, height: 4)
  let before = view.buffer.visibleRows(width: 80, height: 4)
  view.updateText((lines + ["new diff"]).joined(separator: "\n"))
  #expect(view.buffer.visibleRows(width: 80, height: 4) == before)
  view.buffer.follow()
  let tail = view.buffer.visibleRows(width: 80, height: 4)
  view.updateText((lines + ["new diff", "another diff"]).joined(separator: "\n"))
  #expect(view.buffer.visibleRows(width: 80, height: 4) == tail)
  view.updateText("No unstaged changes to tracked files.")
  #expect(view.buffer.visibleRows(width: 80, height: 4) == ["No unstaged changes to tracked files."])
}

@Test("Git views use live theme colors for headers, additions and removals")
func terminalViewGitColors() {
  var view = TerminalView(source: .diffs, title: "git diff")
  view.updateText("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n context")
  let ui = ConfiguredTerminalUI(
    diffAddedForeground: "green", diffAddedBackground: "black",
    diffRemovedForeground: "red", diffRemovedBackground: "black",
    diffHeaderForeground: "cyan")
  view.buffer.configureColors(ui)
  let rows = view.buffer.visibleRows(width: 80, height: 10)
  #expect(rows[0].contains("\u{1B}[36m"))
  #expect(rows[4].contains("\u{1B}[31m\u{1B}[40m-old"))
  #expect(rows[5].contains("\u{1B}[32m\u{1B}[40m+new"))
  var changed = ui
  changed.diffAddedForeground = "blue"
  view.buffer.configureColors(changed)
  #expect(view.buffer.visibleRows(width: 80, height: 10)[5].contains("\u{1B}[34m"))
  view.buffer.configureColors(nil)
  let plain = view.buffer.visibleRows(width: 80, height: 10).joined(separator: "\n")
  #expect(!plain.contains("\u{1B}[32m") && !plain.contains("\u{1B}[?"))
  #expect(plain.contains("+new") && plain.contains("-old"))
}

@Test("Prompt views resolve builtins and overrides, preserving the reply placeholder")
func terminalViewPromptTemplate() throws {
  let custom = UserPrompt(name: "tldr", text: "Short: $ARGUMENTS")
  let template = try MaiCLI.viewPromptTemplate("$tldr", catalog: PromptCatalog(user: [custom]))
  #expect(UserPrompt.message(text: template, arguments: "Last reply") == "Short: Last reply")
  let builtin = try MaiCLI.viewPromptTemplate("$tldr", catalog: PromptCatalog())
  #expect(!builtin.isEmpty)
  #expect(try MaiCLI.viewPromptTemplate("Explain briefly", catalog: PromptCatalog()) == "Explain briefly")
  #expect(throws: (any Error).self) {
    try MaiCLI.viewPromptTemplate("$missing", catalog: PromptCatalog())
  }
  var view = TerminalView(source: .prompt, title: "prompt", markdown: .init(theme: .plain))
  view.updateText("# Summary\n\n**short** reply")
  let rows = view.buffer.visibleRows(width: 80, height: 10).joined(separator: "\n")
  #expect(rows.contains("Summary") && !rows.contains("# Summary"))
  #expect(rows.contains("short") && !rows.contains("**short**"))
}

#if os(macOS) || os(Linux)
@Test("Git view captures working-tree diffs and reports an empty tree or Git errors")
func terminalViewGitCommand() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("view git \(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  func git(_ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + args
    process.currentDirectoryURL = directory
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
  let error = await TerminalGitDiff.text(in: directory)
  #expect(error.localizedCaseInsensitiveContains("not a git repository"))
  try git(["init", "-q"])
  #expect(await TerminalGitDiff.text(in: directory) == "No unstaged changes to tracked files.")
  let file = directory.appendingPathComponent("file.txt")
  try "old\n".write(to: file, atomically: true, encoding: .utf8)
  try git(["add", "file.txt"])
  try "new\n".write(to: file, atomically: true, encoding: .utf8)
  let diff = await TerminalGitDiff.text(in: directory)
  #expect(diff.contains("-old") && diff.contains("+new"))
}
#endif
