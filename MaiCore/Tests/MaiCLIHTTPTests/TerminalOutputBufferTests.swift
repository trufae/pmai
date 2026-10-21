import Foundation
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
