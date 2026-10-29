import Foundation
import MaiCore
import MaiMarkdown

/// The visible terminal transcript, independent of model context and input history.
/// Logical lines retain styling and are wrapped again when the window changes size.
/// Only SGR styling is replayed: output cannot move the cursor into the fixed footer.
struct TerminalOutputBuffer {
  struct Version: Equatable {
    var identity: UUID
    var revision: UInt64
  }
  var contentVersion: Version { Version(identity: identity, revision: revision) }
  private let identity = UUID()
  private var revision: UInt64 = 0
  private var projection: (identity: UUID, revision: UInt64, selection: TerminalOutputSelection)?
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

  private struct ReplyBlock {
    var source = ""
    var output = TerminalOutputBuffer()
    var renderer: MarkdownTerminalRenderer?
    var width = 0
    var finished = false

    mutating func append(_ text: String) {
      source += text
      // Unseen conversations are laid out from source when first painted.
      guard width > 0 else { return }
      output.append(renderer?.feed(text) ?? text)
    }

    mutating func configure(
      _ template: MarkdownTerminalRenderer?, width: Int, colors: ConfiguredTerminalUI?
    ) {
      renderer = template.map {
        var options = $0.options
        options.width = width
        return MarkdownTerminalRenderer(theme: $0.theme, options: options)
      }
      self.width = width
      output = TerminalOutputBuffer()
      output.configureColors(colors)
      output.append(renderer?.feed(source) ?? source)
      if finished { output.append(renderer?.flush() ?? "") }
    }
  }

  private var lines = [Line()]
  // Keep exact wrapped-row counts without rewalking old text on each streamed delta.
  private var rowCounts: [Int] = []
  /// Prefix counts support navigation without flattening the retained transcript.
  private var rowOffsets = [0]
  private var rowCountWidth = 0
  private var totalRowCount = 0
  private var dirtyRowCounts: Set<Int> = []
  private var overflowMeasurement: (columns: Int, height: Int, overflows: Bool, throughLine: Int)?
  /// Reasoning and reply blocks each occupy one logical line. Their source
  /// survives changes to visibility and Markdown rendering.
  private var thinkingBlocks: [Int: TerminalOutputBuffer] = [:]
  private var activeThinking: Set<Int> = []
  private var thinkingDisplay: ThinkingDisplay = .full
  private var replyBlocks: [Int: ReplyBlock] = [:]
  private var retainedBlocks: [Int: TerminalOutputBuffer] = [:]
  private var toolBlocks: [Int: TerminalToolBlock] = [:]
  private var toolGroupStarts: [Int: Int] = [:]
  private var toolGroupEnds: [Int: Int] = [:]
  private var toolGroupMembers: [Int: [Int]] = [:]
  private var toolGroupSummaries: [Int: (text: String, failed: Bool)] = [:]
  private var expandedToolGroups: Set<Int> = []
  private var runningTools: Set<Int> = []
  private var groupTools = false
  private var visiblePositions: [Position] = []
  private var tools = ConfiguredTerminalUI().tools
  private var toolCalls = ConfiguredTerminalUI().toolCalls
  private var markdownRenderer: MarkdownTerminalRenderer?
  private var colors: ConfiguredTerminalUI?
  private var fillsLineBackgrounds = false
  private var highlight = ""
  static let highlightStyle = "\u{1B}[0;30;47m"
  private var cursor = 0
  private var style = ""
  private var escape = ""
  private var top: Position?
  private var selection: TerminalOutputSelection = .all
  private var renderThinkingMarkdown = false
  private var excludedSelection: TerminalOutputSelection?
  private static let reset = "\u{1B}[0m"

  var isFollowing: Bool { top == nil }
  var isAtBeginning: Bool { top?.line == 0 && top?.glyph == 0 }
  var logicalLineCount: Int { lines.count }
  /// The last painted top row also pins a viewport that was following the tail.
  var viewportAnchor: (line: Int, glyph: Int)? {
    (top ?? visiblePositions.first).map { ($0.line, $0.glyph) }
  }
  var readingAnchor: (line: Int, glyph: Int)? { top.map { ($0.line, $0.glyph) } }
  mutating func restoreAnchor(line: Int, glyph: Int) {
    top = Position(line: min(max(0, line), lines.count - 1), glyph: max(0, glyph))
  }

  mutating func follow() { top = nil }

  /// Share retained blocks while keeping this pane's own scroll anchor.
  mutating func updateView(from source: TerminalOutputBuffer, selection: TerminalOutputSelection) {
    if let projection, projection.identity == source.identity,
      projection.revision == source.revision, projection.selection == selection { return }
    let anchor = top
    if selection == .iconlog {
      var output = TerminalOutputBuffer()
      let icons = source.toolBlocks.keys.sorted().compactMap { index in
        source.toolBlocks[index]?.call.map { ToolIcon.emoji(for: $0.name) }
      }.joined()
      if !icons.isEmpty { output.append(icons) }
      self = output
      top = anchor
      projection = (source.identity, source.revision, selection)
      return
    }
    self = source
    if !renderThinkingMarkdown {
      renderThinkingMarkdown = true
      for index in thinkingBlocks.keys { invalidateLine(index) }
    }
    top = anchor.flatMap { $0.line < lines.count ? $0 : nil }
    if tools == .icons && self.selection != selection {
      for index in toolBlocks.keys { invalidateLine(index) }
    }
    self.selection = selection
    if selection != source.selection {
      toolGroupMembers = [:]
      for index in lines.indices { invalidateLine(index) }
    }
    configureExcluding(nil)
    if selection != .all { configureToolGroups(false) }
    if selection == .thinking { configureThinking(.full) }
    // Preserve this pane's layout caches and anchor until the source changes.
    projection = (source.identity, source.revision, selection)
  }

  mutating func clear() {
    revision &+= 1
    projection = nil
    lines = [Line()]
    rowCounts = []
    rowOffsets = [0]
    totalRowCount = 0
    dirtyRowCounts = []
    overflowMeasurement = nil
    thinkingBlocks.removeAll()
    activeThinking.removeAll()
    replyBlocks.removeAll()
    retainedBlocks.removeAll()
    toolBlocks.removeAll()
    toolGroupStarts.removeAll()
    toolGroupEnds.removeAll()
    toolGroupMembers.removeAll()
    toolGroupSummaries.removeAll()
    expandedToolGroups.removeAll()
    runningTools.removeAll()
    visiblePositions.removeAll()
    cursor = 0
    style = ""
    escape = ""
    top = nil
  }

  mutating func configureColors(_ ui: ConfiguredTerminalUI?) {
    guard colors != ui else { return }
    colors = ui
    for index in lines.indices { invalidateLine(index) }
    for index in thinkingBlocks.keys { thinkingBlocks[index]?.configureColors(ui) }
    for index in replyBlocks.keys { replyBlocks[index]?.output.configureColors(ui) }
  }

  mutating func configureThinking(_ display: ThinkingDisplay) {
    guard display != thinkingDisplay else { return }
    thinkingDisplay = display
    for index in thinkingBlocks.keys { invalidateLine(index) }
  }

  /// Keep the source intact so closing a dedicated view restores its blocks.
  mutating func configureExcluding(_ selection: TerminalOutputSelection?) {
    guard excludedSelection != selection else { return }
    excludedSelection = selection
    toolGroupMembers = [:]
    toolGroupSummaries = [:]
    for index in thinkingBlocks.keys { invalidateLine(index) }
    for index in toolBlocks.keys { invalidateLine(index) }
  }

  private func isExcluded(_ index: Int) -> Bool {
    switch excludedSelection {
    case .thinking: return thinkingBlocks[index] != nil
    case .iconlog: return toolBlocks[index] != nil
    case .tools(let name):
      return toolBlocks[index].map { name == nil || $0.call?.name == name } ?? false
    default: return false
    }
  }

  @discardableResult
  mutating func appendThinking(_ text: String, to block: Int? = nil) -> Int {
    let index: Int
    if let block {
      index = block
    } else {
      if !lines[lines.count - 1].glyphs.isEmpty { append("\n") }
      index = lines.count - 1
      thinkingBlocks[index] = TerminalOutputBuffer()
      thinkingBlocks[index]?.configureColors(colors)
      activeThinking.insert(index)
      lines.append(Line())
      cursor = 0
    }
    thinkingBlocks[index]?.append(text)
    invalidateLine(index)
    return index
  }

  mutating func finishThinking(_ block: Int) {
    activeThinking.remove(block)
    invalidateLine(block)
  }

  mutating func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    markdownRenderer = renderer
    for index in thinkingBlocks.keys { invalidateLine(index) }
    for index in replyBlocks.keys {
      replyBlocks[index]?.width = 0
      invalidateLine(index)
    }
  }

  mutating func configureTools(_ display: ToolResultDisplay) {
    guard tools != display else { return }
    tools = display
    for index in toolBlocks.keys { invalidateLine(index) }
  }

  mutating func configureToolCalls(_ display: ToolCallDisplay) {
    guard toolCalls != display else { return }
    toolCalls = display
    for index in toolBlocks.keys { invalidateLine(index) }
  }

  mutating func configureToolGroups(_ enabled: Bool) {
    guard groupTools != enabled else { return }
    groupTools = enabled
    for index in toolBlocks.keys { invalidateLine(index) }
  }

  var hasRunningTools: Bool { !runningTools.isEmpty }

  mutating func refreshToolGroupTimes() {
    for start in Set(runningTools.compactMap { toolGroupStarts[$0] }) {
      invalidateToolGroup(containing: start)
    }
  }

  private mutating func groupMembers(start: Int, end: Int) -> [Int] {
    if let members = toolGroupMembers[start] { return members }
    let members = (start..<end).filter {
      guard !isExcluded($0) else { return false }
      if case .tools(let name) = selection { return name == nil || toolBlocks[$0]?.call?.name == name }
      return true
    }
    toolGroupMembers[start] = members
    return members
  }

  private mutating func invalidateToolGroup(containing index: Int) {
    guard let start = toolGroupStarts[index], let end = toolGroupEnds[start] else { return }
    toolGroupSummaries[start] = nil
    invalidateLine(start)
    if let header = groupMembers(start: start, end: end).first, header != start {
      invalidateLine(header)
    }
  }

  /// Hit-test the rows just painted, without laying out the entire transcript.
  mutating func toggleToolGroup(row: Int) -> Bool {
    guard groupTools, tools != .icons, visiblePositions.indices.contains(row) else { return false }
    let position = visiblePositions[row]
    let start = toolGroupStarts[position.line] ?? position.line
    guard position.glyph == 0, let end = toolGroupEnds[start] else { return false }
    let members = groupMembers(start: start, end: end)
    guard position.line == members.first, members.count > 1 else {
      return false
    }
    if top == nil { top = visiblePositions.first }
    if !expandedToolGroups.insert(start).inserted { expandedToolGroups.remove(start) }
    for index in start..<end { invalidateLine(index) }
    return true
  }

  @discardableResult
  mutating func appendTool(
    call: ToolCall?, result: ToolResult?, prefix: String = "", to block: Int? = nil
  ) -> Int {
    let index: Int
    if let block {
      index = block
    } else {
      if !lines[lines.count - 1].glyphs.isEmpty { append("\n") }
      index = lines.count - 1
      let start = toolBlocks[index - 1]?.prefix == prefix
        ? toolGroupStarts[index - 1] ?? index : index
      toolGroupStarts[index] = start
      toolGroupEnds[start] = index + 1
      toolGroupMembers[start] = nil
      toolBlocks[index] = TerminalToolBlock(call: call, result: nil, prefix: prefix)
      runningTools.insert(index)
      invalidateLine(start)
      lines.append(Line())
      cursor = 0
    }
    if let result {
      toolBlocks[index]?.result = result
      toolBlocks[index]?.timing.finishedAt = Date()
      runningTools.remove(index)
    }
    invalidateToolGroup(containing: index)
    invalidateLine(index)
    return index
  }

  @discardableResult
  mutating func appendReply(_ text: String, to block: Int? = nil) -> Int {
    let index: Int
    if let block {
      index = block
    } else {
      if !lines[lines.count - 1].glyphs.isEmpty { append("\n") }
      index = lines.count - 1
      replyBlocks[index] = ReplyBlock()
      lines.append(Line())
      cursor = 0
    }
    replyBlocks[index]?.append(text)
    invalidateLine(index)
    return index
  }

  mutating func finishReply(_ block: Int) {
    if var reply = replyBlocks.removeValue(forKey: block) {
      reply.output.append(reply.renderer?.flush() ?? "")
      reply.finished = true
      replyBlocks[block] = reply
    }
    invalidateLine(block)
  }

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
              invalidateLine(last)
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
        revision &+= 1
        invalidateOverflow(from: lines.count - 1)
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

  /// Compose retained sections without serializing styled rows back into text.
  @discardableResult
  mutating func retain(_ buffer: TerminalOutputBuffer, at block: Int? = nil) -> Int {
    let index: Int
    if let block { index = block }
    else {
      if !lines[lines.count - 1].glyphs.isEmpty { append("\n") }
      index = lines.count - 1
      lines.append(Line())
      cursor = 0
    }
    retainedBlocks[index] = buffer
    invalidateLine(index)
    return index
  }

  private mutating func put(_ text: String) {
    let last = lines.count - 1
    // A provider may split an accent or an emoji sequence across deltas.
    if cursor > 0, cursor == lines[last].glyphs.count {
      let combined = lines[last].glyphs[cursor - 1].text + text
      if combined.count == 1 {
        lines[last].glyphs[cursor - 1].text = combined
        invalidateLine(last)
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
    invalidateLine(last)
  }

  private mutating func wrappedLine(_ index: Int, width: Int) -> [Row] {
    guard !isExcluded(index) else { return [] }
    switch selection {
    case .all: break
    case .iconlog: return []  // Materialized as one logical line by updateView.
    case .thinking:
      guard thinkingBlocks[index] != nil else { return [] }
    case .tools(let name):
      guard let tool = toolBlocks[index], name == nil || tool.call?.name == name else { return [] }
    }
    let originalStart = toolGroupStarts[index] ?? index
    let groupEnd = toolGroupEnds[originalStart] ?? index + 1
    let iconGroup = tools == .icons && toolBlocks[index] != nil
    let groupIndices = iconGroup || groupTools && selection == .all
      ? groupMembers(start: originalStart, end: groupEnd) : [index]
    let groupStart = groupIndices.first ?? index
    let isGroup = groupTools && selection == .all && groupIndices.count > 1
    if iconGroup && index != groupStart { return [] }
    if isGroup && index != groupStart && !expandedToolGroups.contains(originalStart) { return [] }
    if lines[index].cachedWidth == width { return lines[index].rows }
    if retainedBlocks[index] != nil {
      retainedBlocks[index]?.configureHighlight(highlight)
      let result = Self.blockRows(&retainedBlocks[index]!, index: index, width: width)
      lines[index].cachedWidth = width
      lines[index].rows = result
      return result
    }
    if let tool = toolBlocks[index] {
      var text = tool.render(display: tools, calls: toolCalls, colors: colors != nil, width: width)
      if iconGroup {
        text = tool.prefix + groupIndices.compactMap { toolBlocks[$0] }.map { block in
          // Prefix once per row; each glyph keeps its own error styling.
          var block = block
          block.prefix = ""
          return block.render(display: .icons, colors: colors != nil)
        }.joined()
      }
      let isHeader = !iconGroup && isGroup && index == groupStart
      let expanded = expandedToolGroups.contains(originalStart)
      if isHeader {
        let summary: (text: String, failed: Bool)
        if let cached = toolGroupSummaries[originalStart] { summary = cached }
        else {
          let blocks = groupIndices.compactMap { toolBlocks[$0] }
          summary = (ToolRunTiming.summary(blocks.map(\.timing)), blocks.contains { $0.result?.isError == true })
          toolGroupSummaries[originalStart] = summary
        }
        let failed = summary.failed
        let color: TerminalThemeStyle = failed ? .errorForeground : .toolCallForeground
        let header = tool.prefix + (colors != nil ? color.marker
          + TerminalThemeStyle.toolCallBackground.marker + TerminalThemeStyle.toolCallBold.marker : "")
          + (expanded ? "▾ " : "▸ ") + summary.text
          + (failed ? " · error" : "")
        text = expanded ? header + "\n" + text : header
      }
      var output = TerminalOutputBuffer()
      output.configureColors(colors)
      output.fillsLineBackgrounds = true
      output.append(text)
      if isHeader && !expanded || !isHeader && tools == .lines(0) && toolCalls == .truncate {
        output.truncateLine(to: width)
      }
      output.configureHighlight(highlight)
      let result = text.isEmpty ? [] : Self.blockRows(&output, index: index, width: width)
      lines[index].cachedWidth = width
      lines[index].rows = result
      return result
    }
    if replyBlocks[index] != nil {
      if replyBlocks[index]!.width != width {
        replyBlocks[index]?.configure(markdownRenderer, width: width, colors: colors)
      }
      replyBlocks[index]?.output.configureHighlight(highlight)
      let result = Self.blockRows(&replyBlocks[index]!.output, index: index, width: width)
      lines[index].cachedWidth = width
      lines[index].rows = result
      return result
    }
    if thinkingBlocks[index] != nil {
      var result: [Row] = []
      if thinkingDisplay == .full
        || (thinkingDisplay != .status && !activeThinking.contains(index))
      {
        if renderThinkingMarkdown, let template = markdownRenderer {
          let source = thinkingBlocks[index]!.lines.map { $0.glyphs.map(\.text).joined() }
            .joined(separator: "\n")
          var options = template.options
          options.width = width
          var renderer = MarkdownTerminalRenderer(theme: template.theme, options: options)
          var output = TerminalOutputBuffer()
          output.configureColors(colors)
          output.configureHighlight(highlight)
          output.append(renderer.feed(source) + renderer.flush())
          result = Self.blockRows(&output, index: index, width: width)
        } else {
          thinkingBlocks[index]?.configureHighlight(highlight)
          result = Self.blockRows(&thinkingBlocks[index]!, index: index, width: width)
        }
        if thinkingDisplay != .full { result = Array(result.suffix(thinkingDisplay.lineCount)) }
      }
      lines[index].cachedWidth = width
      lines[index].rows = result
      return result
    }
    var result: [Row] = []
    let backgrounds: [TerminalThemeStyle] = [
      .diffAddedBackground, .diffRemovedBackground, .toolCallBackground, .toolResultBackground,
    ]
    let background = fillsLineBackgrounds ? backgrounds.first { role in
      lines[index].glyphs.contains { $0.style.contains(role.marker) }
    }.flatMap { role in
      colors.flatMap { TerminalLineEditor.backgroundColorCode(role.value(in: $0)) }
    } : nil
    let base = TerminalThemeStyle.base(colors) + (background.map { "\u{1B}[\($0)m" } ?? "")
    func filled(_ row: Row, used: Int) -> Row {
      guard background != nil else { return row }
      return Row(position: row.position,
        text: row.text + Self.reset + base + String(repeating: " ", count: max(0, width - used)))
    }
    var row = Row(position: Position(line: index, glyph: 0), text: base)
    var used = 0
    var rowStyle = ""
    let matches = highlightedGlyphs(in: lines[index].glyphs)
    for (offset, glyph) in lines[index].glyphs.enumerated() {
      let cells = glyph.width
      if used > 0 && used + cells > width {
        result.append(filled(row, used: used))
        row = Row(position: Position(line: index, glyph: offset), text: base)
        used = 0
        rowStyle = ""
      }
      // A wide character cannot be painted in a one-column viewport.
      guard cells <= width else { continue }
      let glyphStyle = glyph.style + (matches.contains(offset) ? Self.highlightStyle : "")
      if rowStyle != glyphStyle {
        let styled = TerminalThemeStyle.resolve(glyphStyle, ui: colors)
          .replacingOccurrences(of: Self.reset, with: Self.reset + base)
        row.text += Self.reset + base + styled
        rowStyle = glyphStyle
      }
      row.text += glyph.text
      used += cells
    }
    result.append(filled(row, used: used))
    lines[index].cachedWidth = width
    lines[index].rows = result
    return result
  }

  mutating func configureHighlight(_ text: String) {
    guard highlight != text else { return }
    highlight = text
    for index in lines.indices { invalidateLine(index) }
  }

  /// Match before wrapping and styling so ANSI transitions and narrow panes do not split hits.
  private func highlightedGlyphs(in glyphs: [Glyph]) -> IndexSet {
    guard !highlight.isEmpty else { return [] }
    let text = glyphs.map(\.text).joined()
    var matches = IndexSet()
    var start = text.startIndex
    while start < text.endIndex, let range = text.range(of: highlight, range: start..<text.endIndex) {
      let lower = text.distance(from: text.startIndex, to: range.lowerBound)
      let upper = text.distance(from: text.startIndex, to: range.upperBound)
      matches.insert(integersIn: lower..<upper)
      start = text.index(after: range.lowerBound)
    }
    return matches
  }

  @discardableResult
  mutating func scrollToFirstHighlight(width: Int) -> Bool {
    guard !highlight.isEmpty else { return false }
    let rows = allRows(width: max(1, width))
    guard let row = rows.first(where: { $0.text.contains(Self.highlightStyle) }) else { return false }
    top = row.position
    return true
  }

  /// Compact tool entries occupy one row. Clip parsed glyphs so ANSI colors,
  /// child prefixes and wide characters all count toward the same cell budget.
  /// The original tool block is rendered again when the terminal grows.
  private mutating func truncateLine(to width: Int) {
    let glyphs = lines[0].glyphs
    guard glyphs.reduce(0, { $0 + $1.width }) > width else { return }
    var used = 0
    let visible = glyphs.prefix { glyph in
      guard used + glyph.width < width else { return false }
      used += glyph.width
      return true
    }
    lines[0].glyphs = Array(visible) + [Glyph(text: "…", style: visible.last?.style ?? "")]
  }

  /// Block-local row positions become positions in their parent logical line.
  private static func blockRows(_ buffer: inout TerminalOutputBuffer, index: Int, width: Int)
    -> [Row]
  {
    let rows = buffer.allRows(width: width)
    var spans = buffer.lines.map { $0.glyphs.count }
    for row in rows {
      spans[row.position.line] = max(spans[row.position.line], row.position.glyph + 1)
    }
    var offsets = [0]
    for span in spans {
      offsets.append(offsets.last! + span + 1)
    }
    var result = rows.map { row in
      Row(
        position: Position(line: index, glyph: offsets[row.position.line] + row.position.glyph),
        text: row.text)
    }
    if !result.isEmpty && buffer.lines.last?.glyphs.isEmpty == true { result.removeLast() }
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

  @discardableResult
  mutating func scroll(lines delta: Int, width: Int, height: Int) -> Bool {
    let previous = top
    let width = max(1, width)
    updateRowCounts(width: width)
    let bottom = max(0, totalRowCount - max(1, height))
    let current = scrollOffset(width: width, bottom: bottom)
    let index = current + max(-current, min(bottom - current, delta))
    top = index == bottom ? nil : position(at: index, width: width)
    return top != previous
  }

  private mutating func invalidateLine(_ index: Int) {
    revision &+= 1
    lines[index].cachedWidth = 0
    dirtyRowCounts.insert(index)
    invalidateOverflow(from: index)
  }

  private mutating func invalidateOverflow(from index: Int) {
    // Once a stable prefix fills the screen, later output cannot make it fit.
    // Keep that proof while replies or command output append below it.
    if let measured = overflowMeasurement,
      !measured.overflows || index <= measured.throughLine { overflowMeasurement = nil }
  }

  /// Measure overflow before reserving a gutter, so the scrollbar cannot create
  /// its own need for scrolling. Stop after a screenful of rows, preserving the
  /// scrollbar's cached counts at the actual drawing width for long transcripts.
  mutating func contentWidth(columns: Int, height: Int, scrollbar: Int) -> Int {
    let columns = max(1, columns)
    let gutter = Int(min(scrollbar.magnitude, UInt(columns - 1)))
    guard gutter > 0, height > 0 else { return columns }
    if let measured = overflowMeasurement, measured.columns == columns, measured.height == height {
      return measured.overflows ? columns - gutter : columns
    }
    // Probing the full width and then drawing with a gutter used to reflow
    // entire reply blocks twice on every wheel event. Only probe after edits
    // or geometry changes; scrolling does not change whether content fits.
    var remaining = height
    for index in lines.indices {
      remaining -= wrappedLine(index, width: columns).count
      if remaining < 0 {
        overflowMeasurement = (columns, height, true, index)
        return columns - gutter
      }
    }
    overflowMeasurement = (columns, height, false, lines.count - 1)
    return columns
  }

  private mutating func updateRowCounts(width: Int) {
    if rowCountWidth != width {
      rowCounts = []
      rowOffsets = [0]
      totalRowCount = 0
      rowCountWidth = width
      dirtyRowCounts = []
    }
    for index in rowCounts.count..<lines.count {
      rowCounts.append(0)
      rowOffsets.append(totalRowCount)
      dirtyRowCounts.insert(index)
    }
    var firstChanged = rowCounts.count
    for index in dirtyRowCounts {
      let count = wrappedLine(index, width: width).count
      if count != rowCounts[index] { firstChanged = min(firstChanged, index) }
      totalRowCount += count - rowCounts[index]
      rowCounts[index] = count
    }
    dirtyRowCounts.removeAll(keepingCapacity: true)
    for index in firstChanged..<rowCounts.count {
      rowOffsets[index + 1] = rowOffsets[index] + rowCounts[index]
    }
  }

  /// Last row starting at or before an anchor, also for blocks with many rows.
  private func localRow(_ rows: [Row], glyph: Int) -> Int {
    var lower = 0
    var upper = rows.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if rows[middle].position.glyph <= glyph { lower = middle + 1 }
      else { upper = middle }
    }
    return max(0, lower - 1)
  }

  private mutating func scrollOffset(width: Int, bottom: Int) -> Int {
    guard let top else { return bottom }
    let rows = wrappedLine(top.line, width: width)
    // Hidden logical lines anchor to the last preceding visible row.
    let local = rows.isEmpty ? -1 : localRow(rows, glyph: top.glyph)
    return min(bottom, max(0, rowOffsets[top.line] + local))
  }

  private mutating func position(at offset: Int, width: Int) -> Position? {
    guard totalRowCount > 0 else { return nil }
    var lower = 0
    var upper = rowCounts.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if rowOffsets[middle + 1] <= offset { lower = middle + 1 }
      else { upper = middle }
    }
    let rows = wrappedLine(lower, width: width)
    return rows[offset - rowOffsets[lower]].position
  }

  mutating func scrollbar(width: Int, height: Int) -> TerminalScrollbar {
    let width = max(1, width)
    let height = max(1, height)
    updateRowCounts(width: width)
    let bottom = max(0, totalRowCount - height)
    let offset = scrollOffset(width: width, bottom: bottom)
    return TerminalScrollbar(rows: totalRowCount, top: offset, height: height)
  }

  /// Set an absolute wrapped-row position, retaining the logical anchor on reflow.
  mutating func scroll(to offset: Int, width: Int, height: Int) {
    let width = max(1, width)
    updateRowCounts(width: width)
    let bottom = max(0, totalRowCount - max(1, height))
    let index = min(bottom, max(0, offset))
    top = index == bottom ? nil : position(at: index, width: width)
  }

  mutating func visibleRows(width: Int, height: Int) -> [String] {
    let rows = visibleLayout(width: width, height: height)
    visiblePositions = rows.map(\.position)
    return rows.map(\.text)
  }

  private mutating func visibleLayout(width: Int, height: Int) -> [Row] {
    let width = max(1, width)
    let height = max(1, height)
    if top == nil {
      // Streaming only visits enough cached logical lines to fill the viewport.
      var tail: [Row] = []
      for index in lines.indices.reversed() {
        let rows = wrappedLine(index, width: width)
        tail.insert(contentsOf: rows.suffix(height - tail.count), at: 0)
        if tail.count == height { break }
      }
      return tail
    }
    // Browsing a long transcript should not traverse its entire history for
    // every streamed token. Only lay out lines in the anchored viewport.
    if let top {
      var visible: [Row] = []
      for index in top.line..<lines.count {
        let rows = wrappedLine(index, width: width)
        let first =
          index == top.line
          ? localRow(rows, glyph: top.glyph) : 0
        visible += rows.dropFirst(first).prefix(height - visible.count)
        if visible.count == height { return visible }
      }
    }
    // Growing the window near the end may expose more rows above the anchor.
    let rows = allRows(width: width)
    let index = topIndex(in: rows, height: height)
    return Array(rows[index..<min(rows.count, index + height)])
  }
}

