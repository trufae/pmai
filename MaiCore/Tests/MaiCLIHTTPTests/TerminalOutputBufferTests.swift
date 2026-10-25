import Foundation
import MaiCore
import MaiMarkdown
import Testing

@testable import MaiCLI

@Test("Terminal buffer reflows styled lines and controls split across writes")
func terminalBufferReflow() {
  var buffer = TerminalOutputBuffer()
  buffer.append("\u{1B}[")
  buffer.append("31mabcdef\n界e")
  buffer.append("\u{301}👩")
  buffer.append("\u{200D}💻\u{1B}[0m")
  let narrow = buffer.visibleRows(width: 4, height: 10)
  #expect(
    narrow == [
      "\u{1B}[0m\u{1B}[31mabcd", "\u{1B}[0m\u{1B}[31mef",
      "\u{1B}[0m\u{1B}[31m界e\u{301}", "\u{1B}[0m\u{1B}[31m👩‍💻",
    ])
  #expect(
    buffer.visibleRows(width: 20, height: 10) == [
      "\u{1B}[0m\u{1B}[31mabcdef", "\u{1B}[0m\u{1B}[31m界e\u{301}👩‍💻",
    ])
}

@Test("Terminal buffer anchors history while output streams and resumes at the end")
func terminalBufferScroll() {
  var buffer = TerminalOutputBuffer()
  buffer.append((0..<30).map { "line \($0)" }.joined(separator: "\n"))
  #expect(buffer.visibleRows(width: 40, height: 5).first == "line 25")
  buffer.scroll(lines: -10, width: 40, height: 5)
  let history = buffer.visibleRows(width: 40, height: 5)
  #expect(history.first == "line 15")
  buffer.append("\nnew output\nmore output")
  #expect(!buffer.isFollowing)
  #expect(buffer.visibleRows(width: 40, height: 5) == history)
  // The logical anchor survives a width change, including long wrapped lines.
  #expect(buffer.visibleRows(width: 4, height: 5).first == "line")
  #expect(buffer.visibleRows(width: 40, height: 5) == history)
  buffer.scroll(lines: 1000, width: 40, height: 5)
  #expect(buffer.isFollowing)
  #expect(buffer.visibleRows(width: 40, height: 5).last == "more output")
  buffer.scroll(lines: -1000, width: 40, height: 5)
  #expect(buffer.visibleRows(width: 40, height: 5).first == "line 0")
  buffer.follow()
  #expect(buffer.visibleRows(width: 40, height: 5).last == "more output")
}

@Test("Terminal buffer handles progress lines and strips cursor and title controls")
func terminalBufferControls() {
  var buffer = TerminalOutputBuffer()
  buffer.append("old progress\rnew\u{1B}[K\n\u{1B}[2J\u{1B}[99;1Hsafe")
  buffer.append("\u{1B}]0;ignored title")
  buffer.append("\u{1B}\\\tend")
  #expect(buffer.visibleRows(width: 80, height: 10) == ["new", "safe    end"])
}

@Test("Terminal thinking blocks can be hidden, shortened and restored without losing text")
func terminalBufferThinking() {
  var buffer = TerminalOutputBuffer()
  buffer.append("prompt\n")
  let block = buffer.appendThinking("one\ntwo\nthree\nfour\nfive\nsix\n")
  buffer.finishThinking(block)
  buffer.append("answer")
  for display in [ThinkingDisplay.full, .line, .three, .five, .status, .full] {
    buffer.configureThinking(display)
    let reasoning = ["one", "two", "three", "four", "five", "six"]
    let expected =
      display == .status
      ? []
      : display == .full ? reasoning : Array(reasoning.suffix(display.lineCount))
    #expect(buffer.visibleRows(width: 80, height: 40) == ["prompt"] + expected + ["answer"])
  }
  // Compact height counts wrapped terminal rows.
  buffer.configureThinking(.three)
  #expect(
    buffer.visibleRows(width: 3, height: 40) == [
      "pro", "mpt", "fiv", "e", "six", "ans", "wer",
    ])
}

@Test("Compact live thinking uses the footer and each completed block has its own limit")
func terminalBufferLiveThinking() {
  var buffer = TerminalOutputBuffer()
  buffer.configureThinking(.line)
  buffer.append("prompt\n")
  let first = buffer.appendThinking("first\nlast")
  #expect(buffer.visibleRows(width: 80, height: 40) == ["prompt", ""])
  buffer.configureThinking(.full)
  #expect(buffer.visibleRows(width: 80, height: 40) == ["prompt", "first", "last", ""])
  buffer.configureThinking(.line)
  buffer.appendThinking(" delta", to: first)
  buffer.finishThinking(first)
  buffer.append("tool result\n")
  let second = buffer.appendThinking("child first\nchild last")
  buffer.finishThinking(second)
  buffer.append("answer")
  #expect(
    buffer.visibleRows(width: 80, height: 40) == [
      "prompt", "last delta", "tool result", "child last", "answer",
    ])
  buffer.configureThinking(.status)
  #expect(buffer.visibleRows(width: 80, height: 40) == ["prompt", "tool result", "answer"])
}

@Test("Thinking presentation changes preserve history anchors and reflow retained text")
func terminalBufferThinkingAnchor() {
  var buffer = TerminalOutputBuffer()
  let block = buffer.appendThinking("abcdef\nghijkl")
  buffer.finishThinking(block)
  buffer.append((0..<30).map { "line \($0)" }.joined(separator: "\n"))
  buffer.scroll(lines: -10, width: 40, height: 5)
  let history = buffer.visibleRows(width: 40, height: 5)
  for display in [ThinkingDisplay.status, .line, .full] {
    buffer.configureThinking(display)
    #expect(buffer.visibleRows(width: 40, height: 5) == history)
  }
  buffer.scroll(lines: -1000, width: 40, height: 5)
  #expect(buffer.visibleRows(width: 3, height: 5).prefix(4) == ["abc", "def", "ghi", "jkl"])
  buffer.configureThinking(.line)
  #expect(buffer.visibleRows(width: 3, height: 5).first == "jkl")
  buffer.configureThinking(.status)
  #expect(buffer.visibleRows(width: 40, height: 5).first == "line 0")
}

@Test("Buffer markdown settings redraw retained replies and preserve literal output")
func terminalBufferMarkdown() {
  var buffer = TerminalOutputBuffer()
  buffer.append("literal **tool output**\n")
  let reply = buffer.appendReply("# Heading\n\n**bold** and `code`\n")
  buffer.finishReply(reply)
  buffer.append("done")
  let raw = buffer.visibleRows(width: 80, height: 40)
  #expect(raw.contains("# Heading"))
  #expect(raw.contains("**bold** and `code`"))
  for _ in 0..<2 {
    buffer.configureMarkdown(MarkdownTerminalRenderer(theme: .plain))
    let styled = buffer.visibleRows(width: 80, height: 40)
    #expect(styled.first == "literal **tool output**")
    #expect(styled.contains { $0.contains("Heading") && !$0.contains("#") })
    #expect(styled.contains { $0.contains("bold") && !$0.contains("**") && !$0.contains("`") })
    #expect(styled.last == "done")
    buffer.configureMarkdown(nil)
    #expect(buffer.visibleRows(width: 80, height: 40) == raw)
  }
}

@Test("Markdown can be toggled during a stream and reflows after resize")
func terminalBufferLiveMarkdown() {
  var buffer = TerminalOutputBuffer()
  let reply = buffer.appendReply("**bold")
  buffer.configureMarkdown(MarkdownTerminalRenderer(theme: .plain))
  _ = buffer.visibleRows(width: 20, height: 40)
  buffer.appendReply("** and tail\n", to: reply)
  buffer.finishReply(reply)
  let styled = buffer.visibleRows(width: 20, height: 40)
  #expect(styled.contains { $0.contains("bold") && !$0.contains("**") })
  buffer.configureMarkdown(nil)
  #expect(buffer.visibleRows(width: 80, height: 40) == ["**bold** and tail", ""])
  #expect(buffer.visibleRows(width: 4, height: 40).prefix(2) == ["**bo", "ld**"])
}

@Test("Buffer theme roles recolor independently even when their original colors match")
func terminalBufferThemeRoles() {
  var buffer = TerminalOutputBuffer()
  let initial = ConfiguredTerminalUI()
  buffer.configureColors(initial)
  for role in [TerminalThemeStyle.promptForeground, .toolResultForeground, .warningForeground] {
    buffer.append("\u{1B}[33m" + role.marker + "text\u{1B}[0m\n")
  }
  var theme = initial
  theme.promptForeground = "red"
  theme.toolResultForeground = "green"
  theme.warningForeground = "blue"
  buffer.configureColors(theme)
  let rows = buffer.visibleRows(width: 80, height: 20)
  #expect(rows[0].contains("\u{1B}[31mtext"))
  #expect(rows[1].contains("\u{1B}[32mtext"))
  #expect(rows[2].contains("\u{1B}[34mtext"))
  #expect(!rows.joined().contains("\u{1B}[?"))
  theme.promptForeground = ""
  buffer.configureColors(theme)
  #expect(buffer.visibleRows(width: 80, height: 20)[0].contains("\u{1B}[39mtext"))
}

@Test(
  "Themes recolor cached reasoning, replies and wrapped history without changing literal colors")
func terminalBufferThemeHistory() {
  var buffer = TerminalOutputBuffer()
  buffer.configureColors(ConfiguredTerminalUI())
  let thinking = buffer.appendThinking(
    "\u{1B}[3;90m" + TerminalThemeStyle.thinkingForeground.marker + "reasoning\u{1B}[0m")
  buffer.finishThinking(thinking)
  let reply = buffer.appendReply("reply")
  buffer.finishReply(reply)
  buffer.append("\u{1B}[35mliteral\u{1B}[0m\n")
  _ = buffer.visibleRows(width: 80, height: 20)
  var theme = ConfiguredTerminalUI()
  theme.thinkingForeground = "cyan"
  theme.foreground = "blue"
  buffer.configureColors(theme)
  let rows = buffer.visibleRows(width: 80, height: 20)
  #expect(rows[0].contains("\u{1B}[36mreasoning"))
  #expect(rows[0].contains("\u{1B}[3;90m"))
  #expect(rows[1].contains("\u{1B}[34mreply"))
  #expect(rows[2].contains("\u{1B}[35mliteral"))
  let narrow = buffer.visibleRows(width: 3, height: 20).joined()
  #expect(narrow.contains("\u{1B}[36mrea"))
  #expect(!narrow.contains("\u{1B}[?"))
  buffer.configureThinking(.status)
  buffer.configureColors(ConfiguredTerminalUI(thinkingForeground: "green"))
  buffer.configureThinking(.full)
  #expect(buffer.visibleRows(width: 80, height: 20)[0].contains("\u{1B}[32mreasoning"))
}

@Test(
  "Tool previews retain complete results when switching between compact, limited and full output")
func terminalBufferTools() {
  var buffer = TerminalOutputBuffer()
  let call = ToolCall(
    id: "read", name: "files_read", arguments: .object(["path": .string("file.txt")]))
  buffer.append("prompt\n")
  buffer.configureTools(.lines(0))
  let block = buffer.appendTool(call: call, result: nil)
  #expect(buffer.visibleRows(width: 80, height: 40) == ["prompt", ""])
  buffer.configureTools(.all)
  #expect(buffer.visibleRows(width: 80, height: 40).contains("→ files_read file.txt"))
  let result = ToolResult(callID: "read", text: "one\ntwo\nthree\nfour\nfive")
  buffer.appendTool(call: nil, result: result, to: block)
  buffer.append("answer")
  for display in [ToolResultDisplay.lines(0), .lines(1), .relevant, .all, .lines(0), .all] {
    buffer.configureTools(display)
    let rows = buffer.visibleRows(width: 80, height: 40)
    #expect(rows.first == "prompt")
    #expect(rows.last == "answer")
    if display == .lines(0) {
      #expect(rows == ["prompt", "✔ files_read file.txt", "answer"])
    } else {
      #expect(rows.contains("→ files_read file.txt"))
      #expect(rows.contains("← one"))
      #expect(rows.contains("  five") == (display == .all))
      #expect(rows.contains("  three") == (display != .lines(1)))
    }
  }
}

@Test("Compact tool entries fit one row and reveal retained text after resize", arguments: [false, true])
func terminalBufferCompactToolWidth(isError: Bool) {
  for prefix in ["", "\u{1B}[36magent#3 \u{1B}[0m"] {
    var buffer = TerminalOutputBuffer()
    buffer.configureColors(ConfiguredTerminalUI())
    let path = String(repeating: "界🙂e\u{301}", count: 10) + ".txt"
    buffer.appendTool(
      call: ToolCall(id: "read", name: "files_read", arguments: .object(["path": .string(path)])),
      result: ToolResult(callID: "read", text: "HIDDEN_TOOL_RESULT", isError: isError), prefix: prefix)
    buffer.append("z")
    let fullWidth = buffer.visibleRows(width: 200, height: 40)
    #expect(fullWidth.count == 2)
    #expect(fullWidth[0].contains(path))
    #expect(fullWidth[0].contains(isError ? "\u{1B}[31m✘" : "\u{1B}[32m✔"))
    for width in [80, 24, 8, 1, 120, 24] {
      let rows = buffer.visibleRows(width: width, height: 40)
      #expect(rows.count == 2)
      let plain = rows[0].replacingOccurrences(
        of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
      #expect(TerminalLineEditor.displayWidth(of: plain) <= width)
      if width <= 24 { #expect(plain.hasSuffix("…")) }
      #expect(!rows.joined().contains("HIDDEN_TOOL_RESULT"))
    }
    #expect(buffer.visibleRows(width: 200, height: 40) == fullWidth)
    buffer.configureTools(.all)
    let expanded = buffer.visibleRows(width: 24, height: 40)
    #expect(expanded.count > 2)
    let plainExpanded = expanded.joined().replacingOccurrences(
      of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    #expect(plainExpanded.contains("HIDDEN_TOOL_RESULT"))
    buffer.configureTools(.lines(0))
    #expect(buffer.visibleRows(width: 200, height: 40) == fullWidth)
  }
}

@Test("Relevant buffer output expands important results and errors and keeps child prefixes")
func terminalBufferRelevantTools() {
  for important in [true, false] {
    var buffer = TerminalOutputBuffer()
    buffer.configureTools(.relevant)
    buffer.appendTool(
      call: nil,
      result: ToolResult(
        callID: "result", text: "one\ntwo\nthree\nfour", isError: !important,
        importance: important ? .important : .normal), prefix: "agent#3 ")
    let full = buffer.visibleRows(width: 80, height: 40)
    #expect(full.contains("agent#3   four"))
    buffer.configureTools(.lines(1))
    let limited = buffer.visibleRows(width: 80, height: 40)
    #expect(!limited.contains("agent#3   four"))
    #expect(limited.contains("agent#3   … 3 more lines"))
    buffer.configureTools(.relevant)
    #expect(buffer.visibleRows(width: 80, height: 40) == full)
  }
}

@Test("Consecutive tools collapse, expand on click, and retain errors and full output")
func terminalBufferToolGroups() {
  var buffer = TerminalOutputBuffer()
  buffer.configureToolGroups(true)
  buffer.configureTools(.all)
  buffer.append("prompt\n")
  let first = buffer.appendTool(
    call: ToolCall(id: "1", name: "files_read", arguments: .object([:])), result: nil)
  let second = buffer.appendTool(
    call: ToolCall(id: "2", name: "run", arguments: .object([:])), result: nil)
  let live = buffer.visibleRows(width: 80, height: 20)
  #expect(live.contains { $0.contains("2 tool calls") && $0.contains("running") })
  buffer.appendTool(call: nil, result: ToolResult(callID: "1", text: "contents"), to: first)
  buffer.appendTool(
    call: nil, result: ToolResult(callID: "2", text: "failure details", isError: true), to: second)
  let collapsed = buffer.visibleRows(width: 80, height: 20)
  #expect(collapsed.count == 3)
  #expect(collapsed[1].contains("2 tool calls") && collapsed[1].contains("error"))
  #expect(!collapsed.joined().contains("contents"))
  #expect(!collapsed.joined().contains("running"))
  #expect(!buffer.hasRunningTools)
  #expect(buffer.toggleToolGroup(row: 0) == false)
  #expect(buffer.toggleToolGroup(row: 1) == true)
  let expanded = buffer.visibleRows(width: 80, height: 20).joined(separator: "\n")
  #expect(expanded.contains("contents") && expanded.contains("failure details"))
  #expect(buffer.toggleToolGroup(row: 1) == true)
  #expect(buffer.visibleRows(width: 80, height: 20) == collapsed)
  buffer.configureToolGroups(false)
  #expect(buffer.visibleRows(width: 80, height: 20).joined().contains("contents"))
  buffer.configureToolGroups(true)
  #expect(buffer.visibleRows(width: 8, height: 20).allSatisfy {
    TerminalLineEditor.displayWidth(of: $0) <= 8
  })
  buffer.clear()
  #expect(buffer.toggleToolGroup(row: 1) == false)
}

@Test("Prose, reasoning and agent prefixes break tool groups; tool views keep full details")
func terminalBufferToolGroupBoundaries() {
  var buffer = TerminalOutputBuffer()
  buffer.configureToolGroups(true)
  buffer.configureTools(.all)
  func call(_ id: String) -> ToolCall {
    ToolCall(id: id, name: "files_read", arguments: .object([:]))
  }
  buffer.appendTool(call: call("1"), result: ToolResult(callID: "1", text: "one"))
  buffer.appendTool(call: call("2"), result: ToolResult(callID: "2", text: "two"))
  buffer.appendReply("prose")
  buffer.appendTool(call: call("3"), result: ToolResult(callID: "3", text: "three"))
  buffer.appendTool(call: call("4"), result: ToolResult(callID: "4", text: "four"))
  buffer.appendThinking("reasoning")
  buffer.appendTool(call: call("5"), result: ToolResult(callID: "5", text: "five"))
  buffer.appendTool(
    call: call("6"), result: ToolResult(callID: "6", text: "six"), prefix: "agent#2 ")
  let rows = buffer.visibleRows(width: 80, height: 40)
  #expect(rows.filter { $0.contains("2 tool calls") }.count == 2)
  #expect(rows.contains("prose") && rows.joined().contains("five") && rows.joined().contains("six"))
  var view = TerminalOutputBuffer()
  view.updateView(from: buffer, selection: .tools(nil))
  let details = view.visibleRows(width: 80, height: 40).joined()
  #expect(!details.contains("tool calls"))
  #expect(details.contains("one") && details.contains("four"))
}
