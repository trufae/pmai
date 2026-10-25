import Foundation

public struct MarkdownLayoutOptions: Equatable, Sendable {
  /// Columns available for tables and rules.
  public var width: Int
  /// Use box drawing and bullet glyphs instead of ASCII.
  public var unicode: Bool
  /// Print link destinations after link text.
  public var linkDestinations: Bool

  public init(width: Int = 80, unicode: Bool = true, linkDestinations: Bool = true) {
    self.width = width
    self.unicode = unicode
    self.linkDestinations = linkDestinations
  }

  /// The checkbox used by Markdown tasks and numbered todo listings.
  public func taskMarker(checked: Bool) -> String {
    // Pad the symbol glyph so it leaves a visible gap before the caller's separator.
    if unicode { return checked ? "􁁛 " : "􀟈 " }
    return checked ? "[x]" : "[ ]"
  }
}

/// Turns markdown into styled lines as it arrives. Lines are emitted as soon
/// as their kind is known and their inline markup is complete up to a word
/// boundary; code fences, tables, and rules wait for the lines they need.
/// Feeding a whole document at once yields exactly the same events as feeding
/// it in pieces, so one-shot rendering is just streaming everything.
public struct MarkdownStreamLayout: Equatable, Sendable {
  public var options: MarkdownLayoutOptions

  private var pending: [Character] = []
  private var carriageReturn = false
  private var base: MarkdownLineBase?
  private var contentStarted = false
  private var held = false
  private var inFence = false
  private var table: [String] = []

  public init(options: MarkdownLayoutOptions = MarkdownLayoutOptions()) {
    self.options = options
  }

  public mutating func reset() {
    self = MarkdownStreamLayout(options: options)
  }

  public mutating func feed(_ chunk: String) -> [MarkdownLayoutEvent] {
    var events: [MarkdownLayoutEvent] = []
    var appended = false
    for char in chunk {
      if char == "\n" || char == "\r\n" {
        carriageReturn = false
        events += completeLine()
        appended = false
        continue
      }
      if char == "\r" {
        carriageReturn = true
        continue
      }
      if carriageReturn {
        carriageReturn = false
        events += completeLine()
      }
      pending.append(char)
      appended = true
    }
    if appended { events += advancePartial() }
    return events
  }

  /// Ends the document: renders whatever is still buffered and resets.
  public mutating func flush() -> [MarkdownLayoutEvent] {
    var events: [MarkdownLayoutEvent] = []
    if !pending.isEmpty || base != nil || held {
      let line = String(pending)
      let lineBase = base
      let started = contentStarted
      pending = []
      base = nil
      contentStarted = false
      held = false
      if inFence {
        if !started, isClosingFence(line) {
          inFence = false
          events.append(.spans([MarkdownSpan(line, role: .fence)]))
        } else if !line.isEmpty {
          events.append(.spans([MarkdownSpan(line, role: .code)]))
        }
      } else if let lineBase {
        events += contentEvents(line, base: lineBase, started: started)
      } else if !table.isEmpty, MarkdownTable.isCandidateLine(line) {
        table.append(line)
        events += flushTable()
      } else {
        events += flushTable()
        events += finishLine(line, terminated: false)
      }
    } else {
      events += flushTable()
    }
    reset()
    return events
  }

  // MARK: - Lines

  private mutating func completeLine() -> [MarkdownLayoutEvent] {
    let line = String(pending)
    let lineBase = base
    let started = contentStarted
    pending = []
    base = nil
    contentStarted = false
    held = false

    if inFence {
      if !started, isClosingFence(line) {
        inFence = false
        return [.spans([MarkdownSpan(line, role: .fence)]), .lineBreak]
      }
      return line.isEmpty ? [.lineBreak] : [.spans([MarkdownSpan(line, role: .code)]), .lineBreak]
    }
    if let lineBase {
      return contentEvents(line, base: lineBase, started: started) + [.lineBreak]
    }

    var events: [MarkdownLayoutEvent] = []
    if !table.isEmpty {
      if MarkdownTable.isCandidateLine(line) {
        table.append(line)
        return []
      }
      events += flushTable()
    }
    if MarkdownTable.isCandidateLine(line) {
      table = [line]
      return events
    }
    return events + finishLine(line, terminated: true)
  }

  private mutating func finishLine(_ line: String, terminated: Bool) -> [MarkdownLayoutEvent] {
    let chars = Array(line)
    let end: [MarkdownLayoutEvent] = terminated ? [.lineBreak] : []
    switch MarkdownLineClassifier.analyze(chars, complete: true) {
    case .blank:
      return end
    case .rule:
      return [.spans([ruleSpan()])] + end
    case .fence:
      inFence = true
      return [.spans([MarkdownSpan(line, role: .fence)])] + end
    case .decided(let lineBase, let contentStart):
      return markerEvents(lineBase)
        + contentEvents(String(chars[contentStart...]), base: lineBase, started: false) + end
    case .needMore, .hold:
      return contentEvents(line, base: .paragraph, started: false) + end
    }
  }

  private mutating func advancePartial() -> [MarkdownLayoutEvent] {
    if inFence { return advanceCode() }
    if held { return [] }
    var events: [MarkdownLayoutEvent] = []
    if base == nil {
      switch MarkdownLineClassifier.analyze(pending, complete: false) {
      case .needMore:
        return []
      case .hold:
        held = true
        return []
      case .decided(let lineBase, let contentStart):
        base = lineBase
        events += markerEvents(lineBase)
        pending.removeFirst(contentStart)
      case .blank, .rule, .fence:
        return []
      }
    }
    guard let lineBase = base else { return events }
    if !contentStarted, lineBase.trimsLeadingContent {
      pending.removeFirst(pending.prefix(while: { $0 == " " || $0 == "\t" }).count)
    }
    guard !pending.isEmpty else { return events }
    let length = MarkdownInlineParser.streamableLength(of: String(pending))
    guard length > 0 else { return events }
    let piece = String(pending[..<length])
    pending.removeFirst(length)
    events += contentEvents(piece, base: lineBase, started: true)
    contentStarted = true
    return events
  }

  private mutating func advanceCode() -> [MarkdownLayoutEvent] {
    if !contentStarted {
      let trimmed = pending.drop(while: { $0 == " " || $0 == "\t" })
      // Spaces or backticks alone may still turn into the closing fence.
      if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "`" }) || trimmed.starts(with: "```") {
        return []
      }
    }
    let text = String(pending)
    pending = []
    contentStarted = true
    return text.isEmpty ? [] : [.spans([MarkdownSpan(text, role: .code)])]
  }

  private mutating func flushTable() -> [MarkdownLayoutEvent] {
    guard !table.isEmpty else { return [] }
    let lines = table
    table = []
    if let parsed = MarkdownTable.parse(lines) {
      let laidOut = MarkdownTableLayout.lines(
        for: parsed,
        width: options.width,
        unicode: options.unicode,
        linkDestinations: options.linkDestinations)
      return laidOut.flatMap { [.spans($0), .lineBreak] }
    }
    var events: [MarkdownLayoutEvent] = []
    for line in lines { events += finishLine(line, terminated: true) }
    return events
  }

  // MARK: - Pieces

  private func isClosingFence(_ line: String) -> Bool {
    line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("```")
  }

  private func ruleSpan() -> MarkdownSpan {
    MarkdownSpan(
      String(repeating: options.unicode ? "─" : "-", count: max(3, options.width)), role: .rule)
  }

  private func markerEvents(_ base: MarkdownLineBase) -> [MarkdownLayoutEvent] {
    switch base {
    case .paragraph, .heading:
      return []
    case .quote:
      return [.spans([MarkdownSpan(options.unicode ? "│ " : "| ", role: .quote)])]
    case .bullet(let indent):
      let glyph: String
      if options.unicode {
        glyph = indent == 0 ? "•" : indent == 1 ? "◦" : "▪"
      } else {
        glyph = indent == 0 ? "-" : indent == 1 ? "*" : "+"
      }
      return [.spans([MarkdownSpan(indentation(indent) + glyph + " ", role: .listMarker)])]
    case .ordered(let indent, let label):
      return [.spans([MarkdownSpan(indentation(indent) + label + " ", role: .listMarker)])]
    case .task(let indent, let checked):
      let box = options.taskMarker(checked: checked)
      return [
        .spans([MarkdownSpan(indentation(indent) + box + " ", role: .taskMarker(checked: checked))])
      ]
    case .footnote(let key):
      return [.spans([MarkdownSpan("[^\(key)] ", role: .footnoteLabel)])]
    }
  }

  private func indentation(_ level: Int) -> String {
    String(repeating: " ", count: 2 * level)
  }

  private func contentEvents(
    _ text: String,
    base: MarkdownLineBase,
    started: Bool
  ) -> [MarkdownLayoutEvent] {
    var content = Substring(text)
    if !started, base.trimsLeadingContent {
      content = content.drop(while: { $0 == " " || $0 == "\t" })
    }
    guard !content.isEmpty else { return [] }
    let role: MarkdownTextRole
    switch base {
    case .heading(let level): role = .heading(level)
    case .quote: role = .quote
    default: role = .body
    }
    let spans = MarkdownSpan.spans(
      for: MarkdownInlineParser.runs(from: String(content)),
      role: role,
      linkDestinations: options.linkDestinations)
    return MarkdownSpan.events(for: spans)
  }
}
