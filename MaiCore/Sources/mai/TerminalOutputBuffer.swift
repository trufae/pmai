import Foundation

/// The visible terminal transcript, independent of model context and input history.
/// Logical lines retain styling and are wrapped again when the window changes size.
/// Only SGR styling is replayed: output cannot move the cursor into the fixed footer.
struct TerminalOutputBuffer {
  private struct Glyph {
    var text: String
    var style: String
    var width: Int { TerminalLineEditor.displayWidth(of: text) }
  }

  private struct Position: Equatable {
    var line: Int
    var glyph: Int
  }

  private struct Row {
    var position: Position
    var text: String
  }

  private struct Line {
    var glyphs: [Glyph] = []
    var cachedWidth = 0
    var rows: [Row] = []
  }

  private var lines = [Line()]
  private var cursor = 0
  private var style = ""
  private var escape = ""
  private var top: Position?
  private static let reset = "\u{1B}[0m"

  var isFollowing: Bool { top == nil }

  mutating func follow() { top = nil }

  mutating func append(_ text: String) {
    for character in text {
      if !escape.isEmpty {
        escape.append(character)
        if escape.hasPrefix("\u{1B}[") {
          if escape.count > 2, let scalar = character.asciiValue, (0x40...0x7E).contains(scalar) {
            if character == "m" {
              let parameters = String(escape.dropFirst(2).dropLast())
              if parameters.isEmpty || parameters == "0" || parameters.hasPrefix("0;") {
                style = escape
              } else {
                style += escape
              }
            } else if character == "K" {
              let parameters = String(escape.dropFirst(2).dropLast())
              let last = lines.count - 1
              if parameters == "2" {
                lines[last].glyphs = []
                cursor = 0
              } else if parameters.isEmpty || parameters == "0" {
                lines[last].glyphs.removeSubrange(cursor...)
              }
              lines[last].cachedWidth = 0
            }
            escape = ""
          }
        } else if escape.hasPrefix("\u{1B}]") {
          if character == "\u{7}" || escape.hasSuffix("\u{1B}\\") { escape = "" }
        } else if escape.count > 1 {
          escape = ""
        }
        // Discard malformed/unterminated controls without growing forever.
        if escape.utf8.count > 4096 { escape = "" }
        continue
      }
      switch character {
      case "\u{1B}": escape = String(character)
      case "\n", "\r\n":
        lines.append(Line())
        cursor = 0
      case "\r": cursor = 0
      case "\u{8}": cursor = max(0, cursor - 1)
      case "\t":
        let column = lines[lines.count - 1].glyphs.prefix(cursor).reduce(0) { $0 + $1.width }
        for _ in 0..<(8 - column % 8) { put(" ") }
      default:
        if character.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
          put(String(character))
        }
      }
    }
  }

  private mutating func put(_ text: String) {
    let last = lines.count - 1
    // A provider may split an accent or an emoji sequence across deltas.
    if cursor > 0, cursor == lines[last].glyphs.count {
      let combined = lines[last].glyphs[cursor - 1].text + text
      if combined.count == 1 {
        lines[last].glyphs[cursor - 1].text = combined
        lines[last].cachedWidth = 0
        return
      }
    }
    let glyph = Glyph(text: text, style: style)
    if cursor < lines[last].glyphs.count {
      lines[last].glyphs[cursor] = glyph
    } else {
      lines[last].glyphs.append(glyph)
    }
    cursor += 1
    lines[last].cachedWidth = 0
  }

  private mutating func wrappedLine(_ index: Int, width: Int) -> [Row] {
    if lines[index].cachedWidth == width { return lines[index].rows }
    var result: [Row] = []
    var row = Row(position: Position(line: index, glyph: 0), text: "")
    var used = 0
    var rowStyle = ""
    for (offset, glyph) in lines[index].glyphs.enumerated() {
      let cells = glyph.width
      if used > 0 && used + cells > width {
        result.append(row)
        row = Row(position: Position(line: index, glyph: offset), text: "")
        used = 0
        rowStyle = ""
      }
      // A wide character cannot be painted in a one-column viewport.
      guard cells <= width else { continue }
      if rowStyle != glyph.style {
        row.text += Self.reset + glyph.style
        rowStyle = glyph.style
      }
      row.text += glyph.text
      used += cells
    }
    result.append(row)
    lines[index].cachedWidth = width
    lines[index].rows = result
    return result
  }

  private mutating func allRows(width: Int) -> [Row] {
    lines.indices.flatMap { wrappedLine($0, width: width) }
  }

  private func topIndex(in rows: [Row], height: Int) -> Int {
    let bottom = max(0, rows.count - height)
    guard let top else { return bottom }
    let index =
      rows.lastIndex {
        $0.position.line < top.line
          || ($0.position.line == top.line && $0.position.glyph <= top.glyph)
      } ?? 0
    return min(index, bottom)
  }

  mutating func scroll(lines delta: Int, width: Int, height: Int) {
    let rows = allRows(width: max(1, width))
    let bottom = max(0, rows.count - height)
    let index = max(0, min(bottom, topIndex(in: rows, height: height) + delta))
    top = index == bottom ? nil : rows[index].position
  }

  mutating func visibleRows(width: Int, height: Int) -> [String] {
    let width = max(1, width)
    let height = max(1, height)
    if top == nil {
      // Streaming only visits enough cached logical lines to fill the viewport.
      var tail: [String] = []
      for index in lines.indices.reversed() {
        let rows = wrappedLine(index, width: width).map(\.text)
        tail.insert(contentsOf: rows.suffix(height - tail.count), at: 0)
        if tail.count == height { break }
      }
      return tail
    }
    // Browsing a long transcript should not traverse its entire history for
    // every streamed token. Only lay out lines in the anchored viewport.
    if let top {
      var visible: [String] = []
      for index in top.line..<lines.count {
        let rows = wrappedLine(index, width: width)
        let first =
          index == top.line
          ? rows.lastIndex(where: { $0.position.glyph <= top.glyph }) ?? 0 : 0
        visible += rows.dropFirst(first).prefix(height - visible.count).map(\.text)
        if visible.count == height { return visible }
      }
    }
    // Growing the window near the end may expose more rows above the anchor.
    let rows = allRows(width: width)
    let index = topIndex(in: rows, height: height)
    return rows[index..<min(rows.count, index + height)].map(\.text)
  }
}
