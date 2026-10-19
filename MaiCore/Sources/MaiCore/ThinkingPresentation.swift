import Foundation

/// Presentation only. It never changes generation options or stored reasoning.
public enum ThinkingDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
  case status, line, three, five, full
  public var id: String { rawValue }
  public var lineCount: Int {
    switch self {
    case .three: 3
    case .five: 5
    default: 1
    }
  }
  public var displayName: String {
    switch self {
    case .status: "Thinking…"
    case .line: "One scrolling line"
    case .three: "Three scrolling lines"
    case .five: "Five scrolling lines"
    case .full: "Full text"
    }
  }
}

/// A bounded tail for live frontends. Full reasoning belongs to the transcript.
public struct ThinkingPreview: Sendable {
  public private(set) var text = ""
  public static let capacity = 1500
  public init() {}
  public mutating func append(_ delta: String) {
    text = Self.tail(text + delta)
  }
  public static func tail(_ text: String) -> String {
    String(text.suffix(capacity))
  }

  /// A continuous character carousel for compact terminal previews. Once full,
  /// it drops only the oldest characters, keeping the newest row filled.
  public static func carouselLines(
    _ text: String, count: Int, width: Int,
    measure: (String) -> Int = { $0.count }
  ) -> [String] {
    guard count > 0, width > 0 else { return [] }
    let compact = tail(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let characters = compact.compactMap { character -> (String, Int)? in
      let safe = String(character).unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0)
      }
      let value = String(String.UnicodeScalarView(safe))
      guard !value.isEmpty else { return nil }
      let size = measure(value)
      // A glyph wider than the terminal cannot be drawn without wrapping.
      return size <= width ? (value, size) : (" ", 1)
    }
    var rows = [""]
    var used = 0
    for (value, size) in characters {
      if used + size > width {
        rows.append("")
        used = 0
      }
      rows[rows.count - 1] += value
      used += size
    }
    if rows.count <= count { return rows }

    // Pack backwards from the newest character rather than dropping a whole
    // wrapped row whenever one more character arrives.
    var reversedRows: [String] = []
    var row: [String] = []
    used = 0
    for (value, size) in characters.reversed() {
      if used + size > width {
        reversedRows.append(row.reversed().joined())
        if reversedRows.count == count { break }
        row = []
        used = 0
      }
      row.append(value)
      used += size
    }
    if reversedRows.count < count { reversedRows.append(row.reversed().joined()) }
    return reversedRows.reversed()
  }

  /// Newest rows last. Width is supplied by the frontend (terminal cells, for example).
  public static func lines(
    _ text: String, count: Int, width: Int,
    measure: (String) -> Int = { $0.count }
  ) -> [String] {
    var rows = [""]
    var columns = 0
    for character in tail(text) {
      if character == "\n" {
        rows.append("")
        columns = 0
      } else {
        let safe = String(character).unicodeScalars.filter {
          !CharacterSet.controlCharacters.contains($0)
        }
        let value = String(String.UnicodeScalarView(safe))
        let size = measure(value)
        if columns + size > max(1, width), columns > 0 {
          rows.append("")
          columns = 0
        }
        rows[rows.count - 1] += value
        columns += size
      }
    }
    if rows.last == "", rows.count > 1 { rows.removeLast() }
    return Array(rows.suffix(max(1, count)))
  }
}
