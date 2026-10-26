import Foundation
import MaiCore
import MaiMarkdown

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
  private var rowCountWidth = 0
  private var totalRowCount = 0
  private var dirtyRowCounts: Set<Int> = []
  /// Reasoning and reply blocks each occupy one logical line. Their source
  /// survives changes to visibility and Markdown rendering.
  private var thinkingBlocks: [Int: TerminalOutputBuffer] = [:]
  private var activeThinking: Set<Int> = []
  private var thinkingDisplay: ThinkingDisplay = .full
  private var replyBlocks: [Int: ReplyBlock] = [:]
  private var toolBlocks: [Int: TerminalToolBlock] = [:]
  private var toolGroupStarts: [Int: Int] = [:]
  private var toolGroupEnds: [Int: Int] = [:]
  private var expandedToolGroups: Set<Int> = []
  private var runningTools: Set<Int> = []
  private var groupTools = false
  private var visiblePositions: [Position] = []
  private var tools = ConfiguredTerminalUI().tools
  private var markdownRenderer: MarkdownTerminalRenderer?
  private var colors: ConfiguredTerminalUI?
  private var cursor = 0
  private var style = ""
  private var escape = ""
  private var top: Position?
  private var selection: TerminalOutputSelection = .all
  private var excludedSelection: TerminalOutputSelection?
  private static let reset = "\u{1B}[0m"

  var isFollowing: Bool { top == nil }
  var isAtBeginning: Bool { top?.line == 0 && top?.glyph == 0 }
  var logicalLineCount: Int { lines.count }
  var readingAnchor: (line: Int, glyph: Int)? { top.map { ($0.line, $0.glyph) } }
  mutating func restoreAnchor(line: Int, glyph: Int) {
    top = Position(line: min(max(0, line), lines.count - 1), glyph: max(0, glyph))
  }

  mutating func follow() { top = nil }

  /// Share retained blocks while keeping this pane's own scroll anchor.
  mutating func updateView(from source: TerminalOutputBuffer, selection: TerminalOutputSelection) {
    let anchor = top
    if selection == .iconlog {
      var output = TerminalOutputBuffer()
      let icons = source.toolBlocks.keys.sorted().compactMap { index in
        source.toolBlocks[index]?.call.map { ToolIcon.emoji(for: $0.name) }
      }.joined()
      if !icons.isEmpty { output.append(icons) }
      self = output
      top = anchor
      return
    }
    self = source
    top = anchor.flatMap { $0.line < lines.count ? $0 : nil }
    if tools == .icons && self.selection != selection {
      for index in toolBlocks.keys { lines[index].cachedWidth = 0 }
    }
    self.selection = selection
    if selection != source.selection {
      for index in lines.indices { invalidateLine(index) }
    }
    configureExcluding(nil)
    if selection != .all { configureToolGroups(false) }
    if selection == .thinking { configureThinking(.full) }
    if selection == .diffs { configureTools(.all) }
  }

  mutating func clear() {
    lines = [Line()]
    rowCounts = []
    totalRowCount = 0
    dirtyRowCounts = []
    thinkingBlocks.removeAll()
    activeThinking.removeAll()
    replyBlocks.removeAll()
    toolBlocks.removeAll()
    toolGroupStarts.removeAll()
    toolGroupEnds.removeAll()
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

  mutating func configureToolGroups(_ enabled: Bool) {
    guard groupTools != enabled else { return }
    groupTools = enabled
    for index in toolBlocks.keys { invalidateLine(index) }
  }

  var hasRunningTools: Bool { !runningTools.isEmpty }

  mutating func refreshToolGroupTimes() {
    for index in runningTools { invalidateToolGroup(containing: index) }
  }

  private mutating func invalidateToolGroup(containing index: Int) {
    guard let start = toolGroupStarts[index], let end = toolGroupEnds[start] else { return }
    invalidateLine(start)
    if let header = (start..<end).first(where: { !isExcluded($0) }) {
      invalidateLine(header)
    }
  }

  /// Hit-test the rows just painted, without laying out the entire transcript.
  mutating func toggleToolGroup(row: Int) -> Bool {
    guard groupTools, tools != .icons, visiblePositions.indices.contains(row) else { return false }
    let position = visiblePositions[row]
    let start = toolGroupStarts[position.line] ?? position.line
    guard position.glyph == 0, let end = toolGroupEnds[start],
      position.line == (start..<end).first(where: { !isExcluded($0) }),
      (start..<end).filter({ !isExcluded($0) }).count > 1 else {
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
    case .diffs:
      guard toolBlocks[index]?.hasAppliedDiff == true else { return [] }
    }
    let originalStart = toolGroupStarts[index] ?? index
    let groupEnd = toolGroupEnds[originalStart] ?? index + 1
    let iconGroup = tools == .icons && toolBlocks[index] != nil
    let groupIndices = iconGroup || groupTools && selection == .all
      ? (originalStart..<groupEnd).filter {
        if isExcluded($0) { return false }
        if case .tools(let name) = selection { return name == nil || toolBlocks[$0]?.call?.name == name }
        return true
      } : [index]
    let groupStart = groupIndices.first ?? index
    let isGroup = groupTools && selection == .all && groupIndices.count > 1
    if iconGroup && index != groupStart { return [] }
    if isGroup && index != groupStart && !expandedToolGroups.contains(originalStart) { return [] }
    if lines[index].cachedWidth == width { return lines[index].rows }
    if let tool = toolBlocks[index] {
      var text = tool.render(display: tools, colors: colors != nil)
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
        let blocks = groupIndices.compactMap { toolBlocks[$0] }
        let failed = blocks.contains { $0.result?.isError == true }
        let color: TerminalThemeStyle = failed ? .errorForeground : .toolCallForeground
        let summary = tool.prefix + (colors != nil ? color.marker : "")
          + (expanded ? "▾ " : "▸ ") + ToolRunTiming.summary(blocks.map(\.timing))
          + (failed ? " · error" : "")
        text = expanded ? summary + "\n" + text : summary
      }
      var output = TerminalOutputBuffer()
      output.configureColors(colors)
      output.append(text)
      if isHeader && !expanded || !isHeader && tools == .lines(0) {
        output.truncateLine(to: width)
      }
      let result = text.isEmpty ? [] : Self.blockRows(&output, index: index, width: width)
      lines[index].cachedWidth = width
      lines[index].rows = result
      return result
    }
    if replyBlocks[index] != nil {
      if replyBlocks[index]!.width != width {
        replyBlocks[index]?.configure(markdownRenderer, width: width, colors: colors)
      }
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
        result = Self.blockRows(&thinkingBlocks[index]!, index: index, width: width)
        if thinkingDisplay != .full { result = Array(result.suffix(thinkingDisplay.lineCount)) }
      }
      lines[index].cachedWidth = width
      lines[index].rows = result
      return result
    }
    var result: [Row] = []
    let base = TerminalThemeStyle.base(colors)
    var row = Row(position: Position(line: index, glyph: 0), text: base)
    var used = 0
    var rowStyle = ""
    for (offset, glyph) in lines[index].glyphs.enumerated() {
      let cells = glyph.width
      if used > 0 && used + cells > width {
        result.append(row)
        row = Row(position: Position(line: index, glyph: offset), text: base)
        used = 0
        rowStyle = ""
      }
      // A wide character cannot be painted in a one-column viewport.
      guard cells <= width else { continue }
      if rowStyle != glyph.style {
        let styled = TerminalThemeStyle.resolve(glyph.style, ui: colors)
          .replacingOccurrences(of: Self.reset, with: Self.reset + base)
        row.text += Self.reset + base + styled
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
    var offsets = [0]
    for line in buffer.lines {
      offsets.append(offsets.last! + line.glyphs.count + 1)
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

  mutating func scroll(lines delta: Int, width: Int, height: Int) {
    let rows = allRows(width: max(1, width))
    let bottom = max(0, rows.count - height)
    let current = topIndex(in: rows, height: height)
    let index = current + max(-current, min(bottom - current, delta))
    top = index == bottom || rows.isEmpty ? nil : rows[index].position
  }

  private mutating func invalidateLine(_ index: Int) {
    lines[index].cachedWidth = 0
    dirtyRowCounts.insert(index)
  }

  /// Measure overflow before reserving a gutter, so the scrollbar cannot create
  /// its own need for scrolling. Stop after a screenful of rows, preserving the
  /// scrollbar's cached counts at the actual drawing width for long transcripts.
  mutating func contentWidth(columns: Int, height: Int, scrollbar: Int) -> Int {
    let columns = max(1, columns)
    let gutter = min(max(0, scrollbar), columns - 1)
    guard gutter > 0, height > 0 else { return columns }
    var remaining = height
    for index in lines.indices {
      remaining -= wrappedLine(index, width: columns).count
      if remaining < 0 { return columns - gutter }
    }
    return columns
  }

  mutating func scrollbar(width: Int, height: Int) -> TerminalScrollbar {
    let width = max(1, width)
    let height = max(1, height)
    if rowCountWidth != width {
      rowCounts = []
      totalRowCount = 0
      rowCountWidth = width
      dirtyRowCounts = []
    }
    for index in rowCounts.count..<lines.count {
      rowCounts.append(0)
      dirtyRowCounts.insert(index)
    }
    for index in dirtyRowCounts {
      let count = wrappedLine(index, width: width).count
      totalRowCount += count - rowCounts[index]
      rowCounts[index] = count
    }
    dirtyRowCounts.removeAll(keepingCapacity: true)
    let bottom = max(0, totalRowCount - height)
    var offset = bottom
    if let top {
      let preceding = rowCounts.prefix(top.line).reduce(0, +)
      let local =
        wrappedLine(top.line, width: width)
        .lastIndex(where: { $0.position.glyph <= top.glyph }).map { $0 + 1 } ?? 0
      offset = min(bottom, max(0, preceding + local - 1))
    }
    return TerminalScrollbar(rows: totalRowCount, top: offset, height: height)
  }

  /// Set an absolute wrapped-row position, retaining the logical anchor on reflow.
  mutating func scroll(to offset: Int, width: Int, height: Int) {
    let rows = allRows(width: max(1, width))
    let bottom = max(0, rows.count - max(1, height))
    let index = min(bottom, max(0, offset))
    top = index == bottom || rows.isEmpty ? nil : rows[index].position
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
          ? rows.lastIndex(where: { $0.position.glyph <= top.glyph }) ?? 0 : 0
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
