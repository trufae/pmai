import MaiCore
import Testing

@testable import MaiCLI

@Test("Scrollbar handles are proportional and map both endpoints exactly")
func terminalScrollbarGeometry() {
  for height in 1...30 {
    for rows in [0, 1, height, height + 1, height * 2, height * 100] {
      let maximum = max(0, rows - height)
      for top in [0, maximum / 2, maximum] {
        let bar = TerminalScrollbar(rows: rows, top: top, height: height)
        #expect(bar.thumb.count >= 1 && bar.thumb.upperBound <= height)
        if rows <= height { #expect(bar.thumb == 0..<height) }
        if top == 0 { #expect(bar.thumb.lowerBound == 0) }
        if top == maximum { #expect(bar.thumb.upperBound == height) }
        if height > 1 && maximum > 0 {
          #expect(bar.offset(at: -100, grab: 0) == 0)
          #expect(bar.offset(at: height + 100, grab: 0) == maximum)
        }
      }
    }
  }
  #expect(TerminalScrollbar(rows: 40, top: 0, height: 20).thumb.count == 10)
  let bar = TerminalScrollbar(rows: 100, top: 40, height: 20)
  #expect(bar.offset(at: bar.thumb.lowerBound + 2, grab: 2) == 40)
  #expect(bar.cell(at: bar.thumb.lowerBound) == "\u{1B}[7m \u{1B}[0m")
  #expect(bar.cell(at: 0) == "\u{1B}[2;7m \u{1B}[0m")
  #expect(bar.cell(at: 0, width: 3) == "\u{1B}[2;7m   \u{1B}[0m")
  #expect(bar.cell(at: 0, width: 0).isEmpty)
  #expect(TerminalScrollbar(rows: 20, top: 0, height: 20).cell(at: 0).isEmpty)
}

@Test("Scrollbar gutters appear only for overflow and leave a content column")
func terminalScrollbarContentWidth() {
  var buffer = TerminalOutputBuffer()
  #expect(buffer.contentWidth(columns: 10, height: 2, scrollbar: 1) == 10)
  // Exactly two full-width rows fit, even though reserving a gutter would wrap
  // them to three rows. Measuring with the gutter must not force a scrollbar.
  buffer.append("abcdefghijklmnopqrst")
  for gutter in [Int.min, -5, -2, -1, 0, 1, 2, 5, Int.max] {
    #expect(buffer.contentWidth(columns: 10, height: 2, scrollbar: gutter) == 10)
  }
  buffer.append("u")
  for gutter in [Int.min, -5, -2, -1, 0, 1, 2, 5, Int.max] {
    let width = buffer.contentWidth(columns: 10, height: 2, scrollbar: gutter)
    #expect(width == 10 - Int(min(gutter.magnitude, 9)))
    let rows = buffer.visibleRows(width: width, height: 2)
    #expect(rows.count == 2)
    #expect(buffer.scrollbar(width: width, height: 2).maximum > 0)
    buffer.scroll(to: 0, width: width, height: 2)
    #expect(buffer.scrollbar(width: width, height: 2).thumb.lowerBound == 0)
  }
  #expect(buffer.contentWidth(columns: 1, height: 2, scrollbar: Int.max) == 1)
  #expect(buffer.contentWidth(columns: 10, height: 3, scrollbar: 2) == 10)
  #expect(buffer.contentWidth(columns: 11, height: 2, scrollbar: 2) == 11)
  buffer.clear()
  #expect(buffer.contentWidth(columns: 10, height: 2, scrollbar: 2) == 10)
}

@Test("Scrollbar counts wrapped rows and updates through streaming, reflow and clear")
func terminalScrollbarBuffer() {
  var buffer = TerminalOutputBuffer()
  buffer.append((0..<40).map { _ in "abcdefghij" }.joined(separator: "\n"))
  #expect(buffer.scrollbar(width: 10, height: 20).thumb == 10..<20)
  buffer.scroll(to: 0, width: 10, height: 20)
  #expect(buffer.scrollbar(width: 10, height: 20).thumb == 0..<10)
  buffer.append("\nnew row")
  #expect(buffer.scrollbar(width: 10, height: 20).maximum == 21)
  #expect(buffer.scrollbar(width: 5, height: 20).maximum == 62)
  buffer.scroll(to: Int.max, width: 5, height: 20)
  #expect(buffer.isFollowing)
  #expect(buffer.scrollbar(width: 5, height: 20).thumb.upperBound == 20)
  buffer.clear()
  #expect(buffer.scrollbar(width: 5, height: 20).thumb == 0..<20)
}

@Test("Scrollbar counts follow thinking visibility, filters and tool group expansion")
func terminalScrollbarProjections() {
  var source = TerminalOutputBuffer()
  let thinking = source.appendThinking((0..<40).map { "thought \($0)" }.joined(separator: "\n"))
  source.finishThinking(thinking)
  #expect(source.scrollbar(width: 80, height: 10).maximum == 31)
  source.configureThinking(.status)
  #expect(source.scrollbar(width: 80, height: 10).maximum == 0)
  #expect(source.contentWidth(columns: 80, height: 10, scrollbar: 2) == 80)
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .thinking)
  #expect(view.scrollbar(width: 80, height: 10).maximum == 30)
  #expect(view.contentWidth(columns: 80, height: 10, scrollbar: 2) == 78)
  view.scroll(to: 0, width: 80, height: 10)
  source.append("answer")
  view.updateView(from: source, selection: .thinking)
  #expect(view.scrollbar(width: 80, height: 10).thumb.lowerBound == 0)
  #expect(source.scrollbar(width: 80, height: 10).maximum == 0)

  source.clear()
  source.configureToolGroups(true)
  for index in 0..<20 {
    source.appendTool(
      call: ToolCall(id: "\(index)", name: "files_read", arguments: .object([:])),
      result: ToolResult(callID: "\(index)", text: "result"))
  }
  #expect(source.scrollbar(width: 80, height: 10).maximum == 0)
  _ = source.visibleRows(width: 80, height: 10)
  let expanded = source.toggleToolGroup(row: 0)
  #expect(expanded)
  #expect(source.scrollbar(width: 80, height: 10).maximum > 0)
  #expect(source.contentWidth(columns: 80, height: 10, scrollbar: 2) == 78)
}

@Test("Scrollbar colors follow builtin and custom theme changes")
func terminalScrollbarColors() {
  let bar = TerminalScrollbar(rows: 100, top: 40, height: 20)
  for ui in TerminalTheme.builtins.values {
    let handle = TerminalLineEditor.backgroundColorCode(ui.selectionBackground)!
    let track = TerminalLineEditor.backgroundColorCode(ui.backgroundLine)!
    #expect(bar.cell(at: bar.thumb.lowerBound, ui: ui) == "\u{1B}[\(handle)m \u{1B}[0m")
    #expect(bar.cell(at: 0, width: 3, ui: ui) == "\u{1B}[\(track)m   \u{1B}[0m")
  }
  let custom = ConfiguredTerminalUI(backgroundLine: "#123456", selectionBackground: "#abcdef")
  #expect(bar.cell(at: 0, ui: custom) == "\u{1B}[48;2;18;52;86m \u{1B}[0m")
  #expect(bar.cell(at: bar.thumb.lowerBound, ui: custom) == "\u{1B}[48;2;171;205;239m \u{1B}[0m")
  let uncolored = ConfiguredTerminalUI(backgroundLine: "", selectionBackground: "")
  #expect(bar.cell(at: 0, ui: uncolored) == bar.cell(at: 0))
  #expect(bar.cell(at: bar.thumb.lowerBound, ui: uncolored) == bar.cell(at: bar.thumb.lowerBound))
}
