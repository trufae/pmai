import Foundation

/// Inline emphasis flags carried by a run of text.
public struct MarkdownInlineStyle: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let bold = MarkdownInlineStyle(rawValue: 1 << 0)
  public static let italic = MarkdownInlineStyle(rawValue: 1 << 1)
  public static let code = MarkdownInlineStyle(rawValue: 1 << 2)
  public static let strikethrough = MarkdownInlineStyle(rawValue: 1 << 3)
  public static let link = MarkdownInlineStyle(rawValue: 1 << 4)
  public static let image = MarkdownInlineStyle(rawValue: 1 << 5)
}

/// A stretch of inline text that shares one style.
public struct MarkdownInlineRun: Equatable, Sendable {
  public var text: String
  public var style: MarkdownInlineStyle
  /// The link or image destination when `style` contains `.link`.
  public var destination: String?

  public init(_ text: String, style: MarkdownInlineStyle = [], destination: String? = nil) {
    self.text = text
    self.style = style
    self.destination = destination
  }
}

/// The result of parsing one line of inline markdown.
public struct MarkdownInlineParse: Equatable, Sendable {
  public var runs: [MarkdownInlineRun]
  /// Character offsets right after top-level whitespace. Cutting the source at
  /// one of them renders both halves exactly as the whole would.
  public var splitOffsets: [Int]
  /// Character offset of the earliest construct a later chunk could still
  /// complete: an emphasis opener, an unclosed code span, link, tag, or entity.
  public var unresolvedOffset: Int?
}

/// A small CommonMark-style inline parser: emphasis with the delimiter-run
/// rules, code spans, links, images, autolinks, `<br>`, escapes, and entities.
/// It is deterministic and self-contained, and lets the streaming renderer emit
/// a line while the rest of it is still arriving.
public enum MarkdownInlineParser {
  public static func parse(_ text: String) -> MarkdownInlineParse {
    parse(Array(text), allowsLinks: true)
  }

  public static func runs(from text: String) -> [MarkdownInlineRun] {
    parse(text).runs
  }

  public static func plainText(_ text: String) -> String {
    runs(from: text).map(\.text).joined()
  }

  /// The number of leading characters of `text` that can be rendered now
  /// without waiting for more of the line. Zero means hold everything.
  public static func streamableLength(of text: String) -> Int {
    let parsed = parse(text)
    let limit = parsed.unresolvedOffset ?? text.count
    return parsed.splitOffsets.last(where: { $0 <= limit }) ?? 0
  }

  static func parse(_ chars: [Character], allowsLinks: Bool) -> MarkdownInlineParse {
    let (nodes, unresolved) = parseNodes(chars, allowsLinks: allowsLinks)
    var flattener = Flattener(unresolved: unresolved)
    flattener.walk(nodes, style: [], destination: nil, depth: 0)
    return MarkdownInlineParse(
      runs: coalesce(flattener.runs),
      splitOffsets: flattener.splits,
      unresolvedOffset: flattener.unresolved)
  }

  private static func parseNodes(_ chars: [Character], allowsLinks: Bool) -> ([InlineNode], Int?) {
    var scanner = InlineScanner(chars: chars, allowsLinks: allowsLinks)
    scanner.scan()
    return (processEmphasis(scanner.nodes), scanner.unresolved)
  }

  private static func coalesce(_ runs: [MarkdownInlineRun]) -> [MarkdownInlineRun] {
    var result: [MarkdownInlineRun] = []
    for run in runs where !run.text.isEmpty {
      if let last = result.last, last.style == run.style, last.destination == run.destination {
        result[result.count - 1].text += run.text
      } else {
        result.append(run)
      }
    }
    return result
  }

  // MARK: - Nodes

  private indirect enum InlineNode {
    /// `sourceStart` is set when every character maps 1:1 onto the source.
    case text(String, sourceStart: Int?)
    /// A rendered LaTex expression maps many source characters to one run, but
    /// the original closing delimiter is still a safe streaming boundary.
    case math(String, sourceEnd: Int)
    case code(String)
    case lineBreak
    case link([InlineNode], destination: String)
    case image(String, destination: String)
    case emphasis(MarkdownInlineStyle, [InlineNode])
    case delimiter(Delimiter)
  }

  private struct Delimiter {
    var character: Character
    var count: Int
    var canOpen: Bool
    var canClose: Bool
    var offset: Int
    let originalCount: Int
  }

  private enum LinkScan {
    case link(label: [Character], destination: String, end: Int)
    case notLink
    case incomplete
  }

  // MARK: - Scanner

  private struct InlineScanner {
    let chars: [Character]
    let allowsLinks: Bool
    var index = 0
    var nodes: [InlineNode] = []
    var unresolved: Int?
    private var literal: [Character] = []
    private var literalStart = 0

    init(chars: [Character], allowsLinks: Bool) {
      self.chars = chars
      self.allowsLinks = allowsLinks
    }

    mutating func scan() {
      while index < chars.count {
        let char = chars[index]
        switch char {
        case "\\": scanEscape()
        case "`": scanCodeSpan()
        case "$": scanMath()
        case "*", "_", "~": scanDelimiterRun()
        case "[" where allowsLinks: scanLink(open: index, isImage: false)
        case "!" where allowsLinks: scanImage()
        case "<": scanAngle()
        case "&": scanEntity()
        default:
          appendLiteral(char, at: index)
          index += 1
        }
      }
      flushLiteral()
    }

    mutating func markUnresolved(_ offset: Int) {
      if let existing = unresolved, existing <= offset { return }
      unresolved = offset
    }

    private mutating func appendLiteral(_ char: Character, at offset: Int) {
      if literal.isEmpty { literalStart = offset }
      literal.append(char)
    }

    private mutating func flushLiteral() {
      guard !literal.isEmpty else { return }
      nodes.append(.text(String(literal), sourceStart: literalStart))
      literal.removeAll()
    }

    private mutating func appendNode(_ node: InlineNode) {
      flushLiteral()
      nodes.append(node)
    }

    /// Math must be scanned as one unit so streaming never writes its opening
    /// delimiter and `\\text{` commands before the closing delimiter arrives.
    private mutating func scanMath() {
      let delimiterLength = index + 1 < chars.count && chars[index + 1] == "$" ? 2 : 1
      let start = index
      var cursor = index + delimiterLength
      // Pandoc's rule keeps prices out of maths: a single `$` opens a formula
      // only before a non-space, and closes one only after a non-space and
      // not before a digit, so "$5 and $10" stays text.
      let opensInline =
        delimiterLength == 2 || (cursor < chars.count && !chars[cursor].isWhitespace)
      while opensInline, cursor < chars.count {
        if chars[cursor] == "\\" {
          cursor += 2
          continue
        }
        guard chars[cursor] == "$" else {
          cursor += 1
          continue
        }
        if delimiterLength == 2 {
          guard cursor + 1 < chars.count, chars[cursor + 1] == "$" else {
            cursor += 1
            continue
          }
        } else {
          let followedByDigit = cursor + 1 < chars.count && chars[cursor + 1].isNumber
          guard !chars[cursor - 1].isWhitespace, !followedByDigit else {
            cursor += 1
            continue
          }
        }
        let end = cursor + delimiterLength
        let source = String(chars[start..<end])
        if let rendered = MarkdownMath.render(delimited: source) {
          appendNode(.math(rendered, sourceEnd: end))
          index = end
          return
        }
        break
      }
      // A `$` expression may be split across provider deltas. Keeping it
      // unresolved holds the whole formula, while a complete line still shows
      // malformed source literally instead of silently deleting it.
      markUnresolved(start)
      appendLiteral("$", at: start)
      index = start + 1
    }

    private mutating func scanEscape() {
      guard index + 1 < chars.count else {
        markUnresolved(index)
        appendLiteral("\\", at: index)
        index += 1
        return
      }
      let next = chars[index + 1]
      if isASCIIPunctuation(next) {
        appendNode(.text(String(next), sourceStart: nil))
        index += 2
      } else {
        appendLiteral("\\", at: index)
        index += 1
      }
    }

    private mutating func scanCodeSpan() {
      let start = index
      let end = backtickRunEnd(from: start)
      let length = end - start
      var cursor = end
      while cursor < chars.count {
        guard chars[cursor] == "`" else {
          cursor += 1
          continue
        }
        let closeEnd = backtickRunEnd(from: cursor)
        if closeEnd - cursor == length {
          var content = String(chars[end..<cursor])
          if content.count >= 2, content.first == " ", content.last == " ",
            !content.allSatisfy({ $0 == " " })
          {
            content = String(content.dropFirst().dropLast())
          }
          if closeEnd == chars.count { markUnresolved(start) }
          appendNode(.code(content))
          index = closeEnd
          return
        }
        cursor = closeEnd
      }
      markUnresolved(start)
      for offset in start..<end { appendLiteral("`", at: offset) }
      index = end
    }

    private func backtickRunEnd(from start: Int) -> Int {
      var end = start
      while end < chars.count, chars[end] == "`" { end += 1 }
      return end
    }

    private mutating func scanDelimiterRun() {
      let char = chars[index]
      var end = index
      while end < chars.count, chars[end] == char { end += 1 }
      let previous: Character = index > 0 ? chars[index - 1] : " "
      let touchesEnd = end == chars.count
      let next: Character = touchesEnd ? " " : chars[end]
      let leftFlanking =
        !next.isWhitespace
        && (!isPunctuation(next) || previous.isWhitespace || isPunctuation(previous))
      let rightFlanking =
        !previous.isWhitespace
        && (!isPunctuation(previous) || next.isWhitespace || isPunctuation(next))
      let canOpen: Bool
      let canClose: Bool
      if char == "_" {
        canOpen = leftFlanking && (!rightFlanking || isPunctuation(previous))
        canClose = rightFlanking && (!leftFlanking || isPunctuation(next))
      } else {
        canOpen = leftFlanking
        canClose = rightFlanking
      }
      if touchesEnd { markUnresolved(index) }
      appendNode(
        .delimiter(
          Delimiter(
            character: char,
            count: end - index,
            canOpen: canOpen,
            canClose: canClose,
            offset: index,
            originalCount: end - index)))
      index = end
    }

    private mutating func scanImage() {
      guard index + 1 < chars.count else {
        markUnresolved(index)
        appendLiteral("!", at: index)
        index += 1
        return
      }
      guard chars[index + 1] == "[" else {
        appendLiteral("!", at: index)
        index += 1
        return
      }
      scanLink(open: index + 1, isImage: true)
    }

    private mutating func scanLink(open: Int, isImage: Bool) {
      switch findLink(open: open) {
      case .link(let label, let destination, let end):
        if isImage {
          let alt = MarkdownInlineParser.parse(label, allowsLinks: false).runs.map(\.text).joined()
          appendNode(.image(alt, destination: destination))
        } else {
          let (children, _) = MarkdownInlineParser.parseNodes(label, allowsLinks: false)
          appendNode(.link(children, destination: destination))
        }
        index = end
      case .incomplete:
        markUnresolved(index)
        appendLiteral(chars[index], at: index)
        index += 1
      case .notLink:
        appendLiteral(chars[index], at: index)
        index += 1
      }
    }

    private func findLink(open: Int) -> LinkScan {
      var depth = 0
      var cursor = open + 1
      while cursor < chars.count {
        let char = chars[cursor]
        if char == "\\" {
          cursor += 2
          continue
        }
        if char == "`" {
          let end = backtickRunEnd(from: cursor)
          let length = end - cursor
          var probe = end
          var closed: Int?
          while probe < chars.count {
            guard chars[probe] == "`" else {
              probe += 1
              continue
            }
            let closeEnd = backtickRunEnd(from: probe)
            if closeEnd - probe == length {
              closed = closeEnd
              break
            }
            probe = closeEnd
          }
          cursor = closed ?? end
          continue
        }
        if char == "[" {
          depth += 1
        } else if char == "]" {
          if depth == 0 { break }
          depth -= 1
        }
        cursor += 1
      }
      guard cursor < chars.count else { return .incomplete }
      let labelEnd = cursor
      guard labelEnd + 1 < chars.count else { return .incomplete }
      guard chars[labelEnd + 1] == "(" else { return .notLink }

      var position = labelEnd + 2
      while position < chars.count, chars[position] == " " { position += 1 }
      guard position < chars.count else { return .incomplete }

      var destination = ""
      if chars[position] == "<" {
        var end = position + 1
        while end < chars.count, chars[end] != ">", chars[end] != "<" { end += 1 }
        guard end < chars.count, chars[end] == ">" else { return .incomplete }
        destination = String(chars[(position + 1)..<end])
        position = end + 1
      } else {
        var parenDepth = 0
        let start = position
        while position < chars.count {
          let char = chars[position]
          if char == "\\" {
            position += 2
            continue
          }
          if char.isWhitespace { break }
          if char == "(" {
            parenDepth += 1
          } else if char == ")" {
            if parenDepth == 0 { break }
            parenDepth -= 1
          }
          position += 1
        }
        guard position < chars.count else { return .incomplete }
        destination = unescape(String(chars[start..<position]))
      }

      while position < chars.count, chars[position] == " " { position += 1 }
      guard position < chars.count else { return .incomplete }
      if chars[position] == "\"" || chars[position] == "'" {
        let quote = chars[position]
        var end = position + 1
        while end < chars.count, chars[end] != quote {
          if chars[end] == "\\" { end += 1 }
          end += 1
        }
        guard end < chars.count else { return .incomplete }
        position = end + 1
        while position < chars.count, chars[position] == " " { position += 1 }
        guard position < chars.count else { return .incomplete }
      }
      guard chars[position] == ")" else { return .notLink }
      return .link(
        label: Array(chars[(open + 1)..<labelEnd]),
        destination: destination,
        end: position + 1)
    }

    private mutating func scanAngle() {
      var end = index + 1
      while end < chars.count, chars[end] != ">", chars[end] != "<", end - index < 256 {
        end += 1
      }
      guard end < chars.count, chars[end] == ">" else {
        if end == chars.count { markUnresolved(index) }
        appendLiteral("<", at: index)
        index += 1
        return
      }
      let raw = String(chars[(index + 1)..<end])
      let tag = raw.trimmingCharacters(in: .whitespaces).lowercased()
      if tag == "br" || tag == "br/" || tag == "br /" {
        appendNode(.lineBreak)
        index = end + 1
        return
      }
      if isAutolink(raw) {
        appendNode(.link([.text(raw, sourceStart: nil)], destination: raw))
        index = end + 1
        return
      }
      appendLiteral("<", at: index)
      index += 1
    }

    private mutating func scanEntity() {
      var end = index + 1
      var body = ""
      while end < chars.count, end - index <= 32 {
        let char = chars[end]
        if char == ";" { break }
        guard char.isLetter || char.isNumber || char == "#" else { break }
        body.append(char)
        end += 1
      }
      if end < chars.count, chars[end] == ";", let decoded = decodeEntity(body) {
        appendNode(.text(decoded, sourceStart: nil))
        index = end + 1
        return
      }
      if end == chars.count, end - index <= 32 { markUnresolved(index) }
      appendLiteral("&", at: index)
      index += 1
    }
  }

  // MARK: - Emphasis

  private static func processEmphasis(_ input: [InlineNode]) -> [InlineNode] {
    var nodes = input
    var index = 0
    while index < nodes.count {
      guard case .delimiter(var closer) = nodes[index], closer.canClose else {
        index += 1
        continue
      }
      var openerIndex: Int?
      var probe = index - 1
      while probe >= 0 {
        if case .delimiter(let opener) = nodes[probe], opener.character == closer.character,
          opener.canOpen
        {
          let bothFlanking = opener.canClose || closer.canOpen
          let sum = opener.originalCount + closer.originalCount
          let ruleOfThree =
            bothFlanking && sum % 3 == 0
            && !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
          if !ruleOfThree {
            openerIndex = probe
            break
          }
        }
        probe -= 1
      }
      guard let openerIndex, case .delimiter(var opener) = nodes[openerIndex] else {
        index += 1
        continue
      }
      let use = opener.count >= 2 && closer.count >= 2 ? 2 : 1
      let style: MarkdownInlineStyle
      if closer.character == "~" {
        style = .strikethrough
      } else {
        style = use == 2 ? .bold : .italic
      }
      let inner = Array(nodes[(openerIndex + 1)..<index])
      opener.count -= use
      closer.count -= use
      var rebuilt = Array(nodes[..<openerIndex])
      if opener.count > 0 { rebuilt.append(.delimiter(opener)) }
      rebuilt.append(.emphasis(style, inner))
      let closerIndex = rebuilt.count
      if closer.count > 0 { rebuilt.append(.delimiter(closer)) }
      rebuilt.append(contentsOf: nodes[(index + 1)...])
      nodes = rebuilt
      index = closerIndex
    }
    return nodes
  }

  // MARK: - Flattening

  private struct Flattener {
    var runs: [MarkdownInlineRun] = []
    var splits: [Int] = []
    var unresolved: Int?

    init(unresolved: Int?) {
      self.unresolved = unresolved
    }

    mutating func walk(
      _ nodes: [InlineNode],
      style: MarkdownInlineStyle,
      destination: String?,
      depth: Int
    ) {
      for node in nodes {
        switch node {
        case .text(let text, let sourceStart):
          runs.append(MarkdownInlineRun(text, style: style, destination: destination))
          if depth == 0, style.isEmpty, let sourceStart {
            for (offset, char) in text.enumerated() where char.isWhitespace {
              splits.append(sourceStart + offset + 1)
            }
          }
        case .math(let text, let sourceEnd):
          runs.append(MarkdownInlineRun(text, style: style, destination: destination))
          if depth == 0, style.isEmpty { splits.append(sourceEnd) }
        case .code(let code):
          runs.append(MarkdownInlineRun(code, style: style.union(.code), destination: destination))
        case .lineBreak:
          runs.append(MarkdownInlineRun("\n", style: style, destination: destination))
        case .link(let children, let target):
          walk(children, style: style.union(.link), destination: target, depth: depth + 1)
        case .image(let alt, let target):
          runs.append(
            MarkdownInlineRun(
              alt.isEmpty ? "image" : alt,
              style: style.union([.link, .image]),
              destination: target))
        case .emphasis(let inline, let children):
          walk(children, style: style.union(inline), destination: destination, depth: depth + 1)
        case .delimiter(let delimiter):
          runs.append(
            MarkdownInlineRun(
              String(repeating: delimiter.character, count: delimiter.count),
              style: style,
              destination: destination))
          if delimiter.canOpen, unresolved.map({ delimiter.offset < $0 }) ?? true {
            unresolved = delimiter.offset
          }
        }
      }
    }
  }

  // MARK: - Helpers

  private static func isPunctuation(_ char: Character) -> Bool {
    char.isPunctuation || char.isSymbol
  }

  private static func isASCIIPunctuation(_ char: Character) -> Bool {
    guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1, scalar.isASCII
    else { return false }
    return "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(scalar)
  }

  private static func unescape(_ text: String) -> String {
    var result = ""
    var iterator = text.makeIterator()
    while let char = iterator.next() {
      if char == "\\", let next = iterator.next() {
        if !isASCIIPunctuation(next) { result.append("\\") }
        result.append(next)
      } else {
        result.append(char)
      }
    }
    return result
  }

  private static func isAutolink(_ raw: String) -> Bool {
    guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) else {
      return false
    }
    guard let colon = raw.firstIndex(of: ":") else {
      return raw.contains("@") && raw.filter({ $0 == "@" }).count == 1
    }
    let scheme = raw[..<colon]
    guard let first = scheme.first, first.isLetter, scheme.count >= 2, scheme.count <= 32 else {
      return false
    }
    return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
  }

  private static func decodeEntity(_ body: String) -> String? {
    if body.hasPrefix("#") {
      let digits = body.dropFirst()
      let value: UInt32?
      if digits.hasPrefix("x") || digits.hasPrefix("X") {
        value = UInt32(digits.dropFirst(), radix: 16)
      } else {
        value = UInt32(digits)
      }
      guard let value, value > 0, let scalar = Unicode.Scalar(value) else { return nil }
      return String(Character(scalar))
    }
    switch body {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos": return "'"
    case "nbsp": return "\u{A0}"
    case "copy": return "©"
    case "reg": return "®"
    case "trade": return "™"
    case "mdash": return "—"
    case "ndash": return "–"
    case "hellip": return "…"
    case "laquo": return "«"
    case "raquo": return "»"
    case "ldquo": return "“"
    case "rdquo": return "”"
    case "lsquo": return "‘"
    case "rsquo": return "’"
    case "times": return "×"
    case "middot": return "·"
    case "bull": return "•"
    default: return nil
    }
  }
}
