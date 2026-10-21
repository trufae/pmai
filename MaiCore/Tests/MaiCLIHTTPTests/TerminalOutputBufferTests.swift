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
