import Foundation

/// The block-level role of a span, which decides its colour in a theme.
public enum MarkdownTextRole: Hashable, Sendable {
  case body
  case heading(Int)
  case quote
  /// A line inside a fenced code block.
  case code
  /// The opening and closing fence lines of a code block.
  case fence
  case listMarker
  case taskMarker(checked: Bool)
  /// The destination printed after a link's text.
  case linkDestination
  case tableBorder
  case tableHeader
  case rule
  case footnoteLabel
}

public struct MarkdownSpanStyle: Hashable, Sendable {
  public var role: MarkdownTextRole
  public var inline: MarkdownInlineStyle

  public init(role: MarkdownTextRole = .body, inline: MarkdownInlineStyle = []) {
    self.role = role
    self.inline = inline
  }

  public static let plain = MarkdownSpanStyle()
}

/// Rendered text with the style it should be drawn in. Spans never contain
/// newlines; line structure lives in ``MarkdownLayoutEvent``.
public struct MarkdownSpan: Equatable, Sendable {
  public var text: String
  public var style: MarkdownSpanStyle
  public var destination: String?

  public init(_ text: String, _ style: MarkdownSpanStyle = .plain, destination: String? = nil) {
    self.text = text
    self.style = style
    self.destination = destination
  }

  public init(_ text: String, role: MarkdownTextRole) {
    self.init(text, MarkdownSpanStyle(role: role))
  }
}

public typealias MarkdownStyledLine = [MarkdownSpan]

/// What a layout emits: text for the current line, or the end of that line.
public enum MarkdownLayoutEvent: Equatable, Sendable {
  case spans([MarkdownSpan])
  case lineBreak
}

extension MarkdownSpan {
  /// Converts inline runs to spans with a role; links are followed by their
  /// destination when it adds information.
  public static func spans(
    for runs: [MarkdownInlineRun],
    role: MarkdownTextRole,
    linkDestinations: Bool
  ) -> [MarkdownSpan] {
    var spans: [MarkdownSpan] = []
    var index = 0
    while index < runs.count {
      let run = runs[index]
      spans.append(
        MarkdownSpan(
          run.text, MarkdownSpanStyle(role: role, inline: run.style), destination: run.destination))
      index += 1
      guard linkDestinations, run.style.contains(.link), let destination = run.destination else {
        continue
      }
      // A link's text may span several runs (emphasis inside the label); the
      // destination goes after the last of them.
      var linkText = run.text
      while index < runs.count, runs[index].style.contains(.link),
        runs[index].destination == destination
      {
        let next = runs[index]
        spans.append(
          MarkdownSpan(
            next.text, MarkdownSpanStyle(role: role, inline: next.style), destination: destination))
        linkText += next.text
        index += 1
      }
      let trimmed = destination.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty, trimmed != linkText.trimmingCharacters(in: .whitespaces),
        "mailto:" + linkText.trimmingCharacters(in: .whitespaces) != trimmed
      {
        spans.append(MarkdownSpan(" (\(trimmed))", role: .linkDestination))
      }
    }
    return spans
  }

  /// Splits spans containing `<br>` line breaks into layout events.
  public static func events(for spans: [MarkdownSpan]) -> [MarkdownLayoutEvent] {
    var events: [MarkdownLayoutEvent] = []
    var current: [MarkdownSpan] = []
    for span in spans {
      guard span.text.contains("\n") else {
        current.append(span)
        continue
      }
      let pieces = span.text.split(separator: "\n", omittingEmptySubsequences: false)
      for (offset, piece) in pieces.enumerated() {
        if offset > 0 {
          if !current.isEmpty { events.append(.spans(current)) }
          events.append(.lineBreak)
          current = []
        }
        if !piece.isEmpty {
          current.append(MarkdownSpan(String(piece), span.style, destination: span.destination))
        }
      }
    }
    if !current.isEmpty { events.append(.spans(current)) }
    return events
  }
}

/// Terminal cell widths: wide East Asian and emoji glyphs take two cells,
/// combining marks and zero-width characters take none.
public enum MarkdownDisplayWidth {
  public static func width(of text: String) -> Int {
    var total = 0
    for char in text { total += width(of: char) }
    return total
  }

  public static func width(of line: MarkdownStyledLine) -> Int {
    line.reduce(0) { $0 + width(of: $1.text) }
  }

  public static func width(of char: Character) -> Int {
    let scalars = char.unicodeScalars
    if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
    if let first = scalars.first, first.properties.isEmojiPresentation { return 2 }
    return scalars.reduce(0) { $0 + width(of: $1) }
  }

  public static func width(of scalar: Unicode.Scalar) -> Int {
    let value = scalar.value
    if value < 0x20 || (0x7F..<0xA0).contains(value) { return 0 }
    if value == 0x200B || value == 0x200C || value == 0x200D || value == 0xFEFF
      || (0xFE00...0xFE0F).contains(value) || value == 0x00AD
    {
      return 0
    }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format:
      return 0
    default:
      break
    }
    return isWide(value) ? 2 : 1
  }

  private static func isWide(_ value: UInt32) -> Bool {
    for range in wideRanges where range.contains(value) { return true }
    return false
  }

  private static let wideRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0,
    0x23F3...0x23F3, 0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
    0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
    0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5,
    0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728,
    0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
    0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55,
    0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
    0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
    0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E,
    0x1F191...0x1F19A, 0x1F200...0x1F251, 0x1F300...0x1F64F, 0x1F680...0x1F6FF,
    0x1F7E0...0x1F7EB, 0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD,
  ]
}
