import Foundation

public enum MarkdownTableAlignment: Equatable, Sendable {
  case leading
  case center
  case trailing
}

/// A pipe table: a header row, an alignment row, and body rows whose cells
/// still hold inline markdown.
public struct MarkdownTable: Equatable, Sendable {
  public var headers: [String]
  public var alignments: [MarkdownTableAlignment]
  public var rows: [[String]]

  public init(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]]) {
    self.headers = headers
    self.alignments = alignments
    self.rows = rows
  }

  /// Standard pipe-table source, preserving inline Markdown in each cell.
  public var markdown: String {
    func row(_ cells: [String]) -> String {
      "| " + cells.map {
        $0.replacingOccurrences(of: "|", with: "&#124;")
          .replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "\r", with: "\n")
          .replacingOccurrences(of: "\n", with: "<br>")
      }.joined(separator: " | ") + " |"
    }
    let separators = headers.indices.map { column in
      switch column < alignments.count ? alignments[column] : .leading {
      case .leading: "---"
      case .center: ":---:"
      case .trailing: "---:"
      }
    }
    return ([row(headers), row(separators)] + rows.map(row)).joined(separator: "\n")
  }

  /// Whether a line could belong to a table: it has pipes at its edges or at
  /// least two of them, and is not a code fence.
  public static func isCandidateLine(_ line: String) -> Bool {
    let trimmed = normalizePipes(line).trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.contains("|"), !trimmed.hasPrefix("```") else { return false }
    return trimmed.hasPrefix("|") || trimmed.hasSuffix("|")
      || trimmed.filter({ $0 == "|" }).count > 1
  }

  public static func isSeparatorLine(_ line: String) -> Bool {
    alignments(of: line) != nil
  }

  public static func parse(_ lines: [String]) -> MarkdownTable? {
    guard lines.count >= 2, let alignments = alignments(of: lines[1]) else { return nil }
    let headers = splitRow(lines[0])
    guard !headers.isEmpty, headers.count == alignments.count else { return nil }
    var rows: [[String]] = []
    for line in lines.dropFirst(2) {
      var cells = splitRow(line)
      while cells.count < headers.count { cells.append("") }
      if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
      rows.append(cells)
    }
    return MarkdownTable(headers: headers, alignments: alignments, rows: rows)
  }

  static func splitRow(_ line: String) -> [String] {
    var text = normalizePipes(line).trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
    var cells: [String] = []
    var cell = ""
    var escaped = false
    for char in text {
      if escaped {
        if char != "|" { cell.append("\\") }
        cell.append(char)
        escaped = false
        continue
      }
      switch char {
      case "\\":
        escaped = true
      case "|":
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        cell = ""
      default:
        cell.append(char)
      }
    }
    if escaped { cell.append("\\") }
    cells.append(cell.trimmingCharacters(in: .whitespaces))
    return cells
  }

  static func alignments(of line: String) -> [MarkdownTableAlignment]? {
    let normalized = normalizePipes(line)
    guard normalized.contains("|"), normalized.contains("-") else { return nil }
    let cells = splitRow(normalized)
    guard !cells.isEmpty else { return nil }
    var alignments: [MarkdownTableAlignment] = []
    for cell in cells {
      let leading = cell.hasPrefix(":")
      let trailing = cell.hasSuffix(":")
      let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
      if leading && trailing {
        alignments.append(.center)
      } else if trailing {
        alignments.append(.trailing)
      } else {
        alignments.append(.leading)
      }
    }
    return alignments
  }

  /// Models sometimes draw tables with box-drawing or full-width bars.
  private static func normalizePipes(_ line: String) -> String {
    var result = line
    for bar in ["\u{2502}", "\u{2503}", "\u{FF5C}"] where result.contains(bar) {
      result = result.replacingOccurrences(of: bar, with: "|")
    }
    return result
  }
}

/// Lays a table out as lines that fit a width, wrapping cells at
/// word boundaries while keeping every span's style.
public enum MarkdownTableLayout {
  public static func lines(
    for table: MarkdownTable,
    width: Int,
    unicode: Bool,
    linkDestinations: Bool = true,
    borders: Bool = true
  ) -> [MarkdownStyledLine] {
    let columns = table.headers.count
    guard columns > 0 else { return [] }
    let header = table.headers.map {
      cellSpans($0, role: .tableHeader, linkDestinations: linkDestinations)
    }
    let body = table.rows.map { row in
      row.map { cellSpans($0, role: .body, linkDestinations: linkDestinations) }
    }
    let widths = columnWidths(header: header, rows: body, available: width, borders: borders)
    let glyphs: Glyphs? = borders ? (unicode ? .unicode : .ascii) : nil

    var lines: [MarkdownStyledLine] = []
    if let glyphs {
      lines.append(border(widths, glyphs.topLeft, glyphs.topMiddle, glyphs.topRight, glyphs))
    }
    lines += rowLines(header, widths: widths, alignments: table.alignments, glyphs: glyphs)
    if let glyphs {
      lines.append(border(widths, glyphs.middleLeft, glyphs.cross, glyphs.middleRight, glyphs))
    }
    let rows = body.map {
      rowLines($0, widths: widths, alignments: table.alignments, glyphs: glyphs)
    }
    let separateRows = rows.contains { $0.count > 1 }
    for (index, row) in rows.enumerated() {
      if index > 0, separateRows, let glyphs {
        lines.append(border(widths, glyphs.middleLeft, glyphs.cross, glyphs.middleRight, glyphs))
      }
      lines += row
    }
    if let glyphs {
      lines.append(border(widths, glyphs.bottomLeft, glyphs.bottomMiddle, glyphs.bottomRight, glyphs))
    }
    return lines
  }

  private struct Glyphs {
    var horizontal: String
    var vertical: String
    var topLeft: String
    var topMiddle: String
    var topRight: String
    var middleLeft: String
    var cross: String
    var middleRight: String
    var bottomLeft: String
    var bottomMiddle: String
    var bottomRight: String

    static let unicode = Glyphs(
      horizontal: "─", vertical: "│", topLeft: "┌", topMiddle: "┬", topRight: "┐",
      middleLeft: "├", cross: "┼", middleRight: "┤", bottomLeft: "└", bottomMiddle: "┴",
      bottomRight: "┘")
    static let ascii = Glyphs(
      horizontal: "-", vertical: "|", topLeft: "+", topMiddle: "+", topRight: "+",
      middleLeft: "+", cross: "+", middleRight: "+", bottomLeft: "+", bottomMiddle: "+",
      bottomRight: "+")
  }

  private static let minimumColumnWidth = 3

  private static func cellSpans(
    _ text: String,
    role: MarkdownTextRole,
    linkDestinations: Bool
  ) -> [MarkdownSpan] {
    MarkdownSpan.spans(
      for: MarkdownInlineParser.runs(from: text),
      role: role,
      linkDestinations: linkDestinations)
  }

  private static func columnWidths(
    header: [[MarkdownSpan]],
    rows: [[[MarkdownSpan]]],
    available: Int,
    borders: Bool
  ) -> [Int] {
    var widths = [Int](repeating: minimumColumnWidth, count: header.count)
    for row in [header] + rows {
      for (column, cell) in row.enumerated() where column < widths.count {
        widths[column] = max(widths[column], naturalWidth(of: cell))
      }
    }
    let minimum = renderedWidth(widths.map { _ in minimumColumnWidth }, borders: borders)
    let limit = max(available, minimum)
    while renderedWidth(widths, borders: borders) > limit {
      var widest = 0
      for column in widths.indices where widths[column] > widths[widest] { widest = column }
      guard widths[widest] > minimumColumnWidth else { break }
      widths[widest] -= 1
    }
    return widths
  }

  /// The width of the widest forced-break segment of a cell.
  private static func naturalWidth(of spans: [MarkdownSpan]) -> Int {
    var widest = 0
    var current = 0
    for span in spans {
      for char in span.text {
        if char == "\n" {
          widest = max(widest, current)
          current = 0
        } else {
          current += MarkdownDisplayWidth.width(of: char)
        }
      }
    }
    return max(widest, current)
  }

  private static func renderedWidth(_ widths: [Int], borders: Bool) -> Int {
    widths.reduce(0, +) + (borders ? 3 * widths.count + 1 : 2 * max(0, widths.count - 1))
  }

  private static func border(
    _ widths: [Int],
    _ left: String,
    _ middle: String,
    _ right: String,
    _ glyphs: Glyphs
  ) -> MarkdownStyledLine {
    var text = left
    for (index, width) in widths.enumerated() {
      text += String(repeating: glyphs.horizontal, count: width + 2)
      text += index == widths.count - 1 ? right : middle
    }
    return [MarkdownSpan(text, role: .tableBorder)]
  }

  private static func rowLines(
    _ cells: [[MarkdownSpan]],
    widths: [Int],
    alignments: [MarkdownTableAlignment],
    glyphs: Glyphs?
  ) -> [MarkdownStyledLine] {
    var wrapped: [[[MarkdownSpan]]] = []
    for (column, width) in widths.enumerated() {
      let cell = column < cells.count ? cells[column] : []
      wrapped.append(wrap(cell, width: width))
    }
    let height = wrapped.map(\.count).max() ?? 1
    var lines: [MarkdownStyledLine] = []
    for row in 0..<height {
      var line: MarkdownStyledLine = []
      if let glyphs { line.append(MarkdownSpan(glyphs.vertical, role: .tableBorder)) }
      for (column, width) in widths.enumerated() {
        let content = row < wrapped[column].count ? wrapped[column][row] : []
        let alignment = column < alignments.count ? alignments[column] : .leading
        if glyphs != nil {
          line.append(MarkdownSpan(" "))
        } else if column > 0 {
          line.append(MarkdownSpan("  "))
        }
        line += aligned(content, width: width, alignment: alignment)
        if let glyphs {
          line.append(MarkdownSpan(" "))
          line.append(MarkdownSpan(glyphs.vertical, role: .tableBorder))
        }
      }
      lines.append(line)
    }
    return lines
  }

  private static func aligned(
    _ spans: [MarkdownSpan],
    width: Int,
    alignment: MarkdownTableAlignment
  ) -> [MarkdownSpan] {
    let padding = max(0, width - MarkdownDisplayWidth.width(of: spans))
    guard padding > 0 else { return spans }
    switch alignment {
    case .leading:
      return spans + [MarkdownSpan(String(repeating: " ", count: padding))]
    case .trailing:
      return [MarkdownSpan(String(repeating: " ", count: padding))] + spans
    case .center:
      let left = padding / 2
      return [MarkdownSpan(String(repeating: " ", count: left))] + spans
        + [MarkdownSpan(String(repeating: " ", count: padding - left))]
    }
  }

  private enum Token {
    case word([MarkdownSpan])
    case space
    case newline
  }

  /// Wraps styled text at whitespace, keeping style boundaries inside words.
  static func wrap(_ spans: [MarkdownSpan], width: Int) -> [[MarkdownSpan]] {
    let width = max(1, width)
    var tokens: [Token] = []
    var word: [MarkdownSpan] = []
    var piece = ""
    var pieceStyle = MarkdownSpanStyle.plain
    var pieceDestination: String?

    func closePiece() {
      guard !piece.isEmpty else { return }
      word.append(MarkdownSpan(piece, pieceStyle, destination: pieceDestination))
      piece = ""
    }
    func closeWord() {
      closePiece()
      guard !word.isEmpty else { return }
      tokens.append(.word(word))
      word = []
    }

    for span in spans {
      pieceStyle = span.style
      pieceDestination = span.destination
      for char in span.text {
        if char == "\n" {
          closeWord()
          tokens.append(.newline)
        } else if char.isWhitespace {
          closeWord()
          if case .space? = tokens.last {
            continue
          }
          tokens.append(.space)
        } else {
          piece.append(char)
        }
      }
      closePiece()
    }
    closeWord()

    var lines: [[MarkdownSpan]] = []
    var current: [MarkdownSpan] = []
    var currentWidth = 0
    var pendingSpace = false
    for token in tokens {
      switch token {
      case .space:
        pendingSpace = !current.isEmpty
      case .newline:
        lines.append(current)
        current = []
        currentWidth = 0
        pendingSpace = false
      case .word(let spans):
        let wordWidth = MarkdownDisplayWidth.width(of: spans)
        if wordWidth > width {
          if !current.isEmpty {
            lines.append(current)
            current = []
            currentWidth = 0
          }
          let pieces = chunks(of: spans, width: width)
          for chunk in pieces.dropLast() { lines.append(chunk) }
          current = pieces.last ?? []
          currentWidth = MarkdownDisplayWidth.width(of: current)
        } else if current.isEmpty {
          current = spans
          currentWidth = wordWidth
        } else if currentWidth + (pendingSpace ? 1 : 0) + wordWidth <= width {
          if pendingSpace {
            // A space keeps the style only when both neighbours share it, so
            // a bold phrase stays continuous but underlines end with the link.
            let previous = current.last
            let next = spans.first
            let shared =
              previous?.style == next?.style && previous?.destination == next?.destination
            current.append(
              MarkdownSpan(
                " ", shared ? previous?.style ?? .plain : .plain,
                destination: shared ? previous?.destination : nil))
            currentWidth += 1
          }
          current += spans
          currentWidth += wordWidth
        } else {
          lines.append(current)
          current = spans
          currentWidth = wordWidth
        }
        pendingSpace = false
      }
    }
    lines.append(current)
    return lines
  }

  private static func chunks(of spans: [MarkdownSpan], width: Int) -> [[MarkdownSpan]] {
    var chunks: [[MarkdownSpan]] = []
    var current: [MarkdownSpan] = []
    var currentWidth = 0
    for span in spans {
      var text = ""
      for char in span.text {
        let charWidth = MarkdownDisplayWidth.width(of: char)
        if currentWidth + charWidth > width, currentWidth > 0 {
          if !text.isEmpty {
            current.append(MarkdownSpan(text, span.style, destination: span.destination))
            text = ""
          }
          chunks.append(current)
          current = []
          currentWidth = 0
        }
        text.append(char)
        currentWidth += charWidth
      }
      if !text.isEmpty {
        current.append(MarkdownSpan(text, span.style, destination: span.destination))
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }
}
