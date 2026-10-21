import Foundation
import MaiCore
import MaiMarkdown

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Keeps the prompt on screen while agents print.
///
/// The terminal is split into a scroll region — every row but the last few —
/// where replies, tool lines, and child-agent blocks land, and rows below it
/// that never scroll: a status line and the input, one row per line being
/// typed. Output is written at the region's saved cursor and the caret goes
/// back to the input, so a person keeps typing while a run streams and nothing
/// lands in their text. The region starts at the top row, which is what
/// terminals require to keep scrolled-out lines in the scrollback.
/// Buffer mode instead paints that region from a retained transcript on the
/// alternate screen, allowing navigation and reflow without moving the footer.
///
/// One lock serialises everything that touches the tty: a block from a child
/// agent, a streamed delta, and a keystroke's redraw are each written whole.
final class TerminalScreen: LineEditorSurface, @unchecked Sendable {
  private static let currentLock = NSLock()
  nonisolated(unsafe) private static var installed: TerminalScreen?

  /// The screen the REPL activated, so a command that hands the terminal to
  /// another program, such as an editor, can step aside and come back.
  static var current: TerminalScreen? {
    currentLock.withLock { installed }
  }

  static func install(_ screen: TerminalScreen?) {
    currentLock.withLock { installed = screen }
  }

  private let lock = NSLock()
  private var cooked = termios()
  private var rows = 24
  private var columns = 80
  private var ui = ConfiguredTerminalUI()
  private var statusText = ""
  private var statusNeedsAttention = false
  /// The rotating tab-completion options that take over the status row, or
  /// nil when the row shows `statusText`.
  private var completionMenu: CompletionMenu?
  private var thinkingRows: [String] = []
  private var thinkingText: String?
  private var thinkingDisplay: ThinkingDisplay = .status
  private var paintedThinkingRows: [String] = []
  private var paintedThinkingOrigin = 0
  private var paintedThinkingWidth = 0
  /// The input as drawn, one styled string per row below the status line.
  private var inputRows = [""]
  private var caretRow = 0
  private var caretColumn = 0
  private var outputEndedLine = true
  /// Retained in both modes so switching to buffer includes earlier output.
  private var transcript = TerminalOutputBuffer()
  private var thinkingBlock: Int?
  private var replyBlock: Int?
  /// Tool handles remain unique when /clear discards their transcript lines.
  private var toolBlocks: [Int: Int] = [:]
  private var nextToolBlock = 0
  private var paintedOutputRows: [String] = []
  private var active = false
  private var resizeSource: (any DispatchSourceProtocol)?
  private var activitySource: DispatchSourceTimer?
  private var animatingStatus = false
  private var activityStartedAt: UInt64?
  private var activityFrame = 0
  private var displayedActivitySecond: UInt64 = 0
  private var animator = BrailleAnimator.randomStyle()
  /// Whether `setStatus` also restarted the animator; used to avoid
  /// advancing the frame on a line that has not changed.
  private var activityRestarted = false
  /// Keystrokes that arrived while the terminal was asked for its cursor
  /// position, kept for the editor.
  private var typeahead: [UInt8] = []

  private static let saveCursor = "\u{1B}7"
  private static let restoreCursor = "\u{1B}8"
  private static let clearLine = "\u{1B}[2K"
  private static let clearBelow = "\u{1B}[J"
  private static let reset = "\u{1B}[0m"
  private static let enterBuffer = "\u{1B}[?1049h\u{1B}[2J"
  private static let leaveBuffer = "\u{1B}[r\u{1B}[?1049l"
  private static let enableMouse = "\u{1B}[?1000h\u{1B}[?1006h"
  private static let disableMouse = "\u{1B}[?1006l\u{1B}[?1000l"

  /// Nil unless both stdin and stdout are terminals; piped sessions keep the
  /// plain one-line-at-a-time prompt.
  init?() {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return nil }
  }

  func configure(ui: ConfiguredTerminalUI) {
    lock.withLock {
      refreshSize()
      let previousMode = self.ui.mode
      let previousUI = self.ui
      self.ui = ui
      transcript.configureThinking(ui.thinking)
      transcript.configureTools(ui.tools)
      let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        && ProcessInfo.processInfo.environment["TERM"] != "dumb"
      transcript.configureColors(colors ? ui : nil)
      guard active else { return }
      if ui.mode != previousMode {
        transcript.follow()
        if ui.mode == .buffer {
          write(Self.enterBuffer + Self.enableMouse)
          redrawBuffer()
          return
        }
        write(Self.disableMouse + Self.leaveBuffer)
        write("\u{1B}[1;\(regionBottom)r" + move(row: regionBottom, column: 1) + Self.saveCursor)
        outputEndedLine = true
        drawInputRows()
      }
      if ui.mode == .buffer && ui != previousUI {
        redrawBuffer()
        return
      }
      paintedThinkingRows = []
      drawStatusRow()
      placeCaret()
    }
  }

  // MARK: - Lifecycle

  /// True when the last output ended with a newline, so the next thing
  /// printed starts a fresh row.
  var outputIsAtLineStart: Bool {
    lock.withLock { outputEndedLine }
  }

  var isBufferMode: Bool {
    lock.withLock { ui.mode == .buffer }
  }

  /// Enters raw mode, reserves the bottom rows, and draws them. Call before the
  /// input thread starts reading: locating the cursor needs stdin for a moment.
  func activate() {
    lock.withLock { activateLocked() }
  }

  private func activateLocked() {
    guard !active else { return }
    measure()
    var raw = termios()
    guard tcgetattr(STDIN_FILENO, &cooked) == 0 else { return }
    raw = cooked
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
    active = true
    paintedThinkingRows = []
    clampInputRows()
    if ui.mode == .buffer {
      write(TerminalInputModes.enable + Self.enterBuffer + Self.enableMouse)
      redrawBuffer()
      watchResizes()
      updateActivityTimer()
      return
    }
    // One newline per reserved row scrolls exactly as much as it takes for
    // the current row to end up inside the region, whatever row it was on.
    let row = currentOutputRow(fallback: rows)
    let bottom = regionBottom
    var out = TerminalInputModes.enable
    out += String(repeating: "\n", count: reservedRows)
    out += "\u{1B}[1;\(bottom)r"
    out += move(row: min(row, bottom), column: 1)
    out += Self.saveCursor
    write(out)
    outputEndedLine = true
    drawStatusRow()
    drawInputRows()
    placeCaret()
    watchResizes()
    updateActivityTimer()
  }

  /// Gives the whole terminal back: the region is released, the reserved rows
  /// are cleared, and the tty returns to the mode the shell left it in.
  func deactivate() {
    lock.withLock { deactivateLocked() }
  }

  /// Steps aside for another program that needs the tty, then comes back with
  /// the same status and input on screen.
  func suspendTerminal(_ action: () -> Void) {
    lock.withLock {
      let wasActive = active
      if wasActive { deactivateLocked() }
      action()
      if wasActive { activateLocked() }
    }
  }

  /// Tool handoffs require the REPL to own the terminal.
  func handOverTerminal(_ action: () throws -> Void) throws {
    try lock.withLock {
      guard active else {
        throw NSError(domain: "pmai.terminal", code: 1, userInfo: [
          NSLocalizedDescriptionKey: "The terminal is currently owned by another interface. Return to the pmai prompt before running an interactive program."
        ])
      }
      deactivateLocked()
      defer { activateLocked() }
      try action()
    }
  }

  private func deactivateLocked() {
    guard active else { return }
    refreshSize()
    resizeSource?.cancel()
    resizeSource = nil
    activitySource?.cancel()
    activitySource = nil
    if ui.mode == .buffer {
      write(Self.disableMouse + Self.leaveBuffer + TerminalInputModes.disable)
      _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &cooked)
      active = false
      return
    }
    write(Self.restoreCursor + (outputEndedLine ? "" : "\n"))
    // Resetting the region homes the cursor.  We use our tracked row so we
    // never have to ask the terminal for its cursor position (which risks
    // leaking CPR responses like `[9;1R` into the prompt).
    let row = currentOutputRow(fallback: regionBottom)
    write(
      "\u{1B}[r" + move(row: max(1, row), column: 1) + "\n" + Self.clearBelow
        + TerminalInputModes.disable)
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &cooked)
    active = false
  }

  // MARK: - Output

  func configureTools(_ display: ToolResultDisplay) {
    lock.withLock {
      ui.tools = display
      transcript.configureTools(display)
      guard active, ui.mode == .buffer else { return }
      redrawBuffer()
    }
  }

  func writeTool(call: ToolCall?, result: ToolResult?, prefix: String, block: Int?) -> Int {
    lock.withLock {
      refreshSize()
      let line = block.flatMap { toolBlocks.removeValue(forKey: $0) }
      let index = transcript.appendTool(call: call, result: result, prefix: prefix, to: line)
      let handle = nextToolBlock
      nextToolBlock += 1
      if result == nil { toolBlocks[handle] = index }
      if active, ui.mode == .buffer {
        outputEndedLine = true
        drawOutputRows()
        placeCaret()
      }
      return handle
    }
  }

  func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    lock.withLock {
      transcript.configureMarkdown(renderer)
      guard active, ui.mode == .buffer else { return }
      redrawBuffer()
    }
  }

  func writeReply(_ text: String, rendered: String) {
    lock.withLock {
      refreshSize()
      replyBlock = transcript.appendReply(text, to: replyBlock)
      guard active else { return }
      if ui.mode == .buffer {
        outputEndedLine = true
        drawOutputRows()
      } else if !rendered.isEmpty {
        write(Self.restoreCursor + rendered + Self.saveCursor)
        outputEndedLine = rendered.hasSuffix("\n")
      }
      placeCaret()
    }
  }

  func finishReply(rendered: String) {
    lock.withLock {
      guard let replyBlock else { return }
      transcript.finishReply(replyBlock)
      self.replyBlock = nil
      guard active else { return }
      if ui.mode == .buffer {
        drawOutputRows()
      } else if !rendered.isEmpty {
        write(Self.restoreCursor + rendered + Self.saveCursor)
        outputEndedLine = rendered.hasSuffix("\n")
      }
      placeCaret()
    }
  }

  /// Retains reasoning separately from replies, including when only the live
  /// footer preview is visible. Full mode streams it into the output region.
  func writeThinking(_ text: String, full: Bool) {
    guard !text.isEmpty else { return }
    lock.withLock {
      refreshSize()
      thinkingBlock = transcript.appendThinking(text, to: thinkingBlock)
      guard active else { return }
      if ui.mode == .buffer {
        outputEndedLine = true
        drawOutputRows()
      } else if full {
        write(Self.restoreCursor + text + Self.saveCursor)
        outputEndedLine = text.hasSuffix("\n")
      }
      placeCaret()
    }
  }

  func finishThinking() {
    lock.withLock {
      guard let thinkingBlock else { return }
      transcript.finishThinking(thinkingBlock)
      self.thinkingBlock = nil
      guard active else { return }
      if ui.mode == .buffer {
        drawOutputRows()
      } else if !outputEndedLine {
        write(Self.restoreCursor + "\n" + Self.saveCursor)
        outputEndedLine = true
      }
      placeCaret()
    }
  }

  func appendThinkingBlock(_ text: String) {
    lock.withLock {
      refreshSize()
      let block = transcript.appendThinking(text)
      transcript.finishThinking(block)
      guard active, ui.mode == .buffer else { return }
      drawOutputRows()
      placeCaret()
    }
  }

  /// Writes into the scroll region, leaving the caret on the input row.
  func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    lock.withLock {
      guard active else {
        handle.write(Data(TerminalThemeStyle.resolve(text).utf8))
        return
      }
      refreshSize()
      transcript.append(text)
      if ui.mode == .buffer {
        outputEndedLine = text.hasSuffix("\n")
        drawOutputRows()
        placeCaret()
        return
      }
      if handle === FileHandle.standardOutput {
        write(Self.restoreCursor + text + Self.saveCursor)
      } else {
        write(Self.restoreCursor)
        handle.write(Data(TerminalThemeStyle.resolve(text).utf8))
        write(Self.saveCursor)
      }
      outputEndedLine = text.hasSuffix("\n")
      placeCaret()
    }
  }

  /// Replaces the status line above the input; an unchanged line is not redrawn.
  func setStatus(_ text: String, animating: Bool = false, attention: Bool = false) {
    setStatus(text, animating: animating, style: nil, attention: attention)
  }

  /// Replaces the status line and optionally switches the Braille animation style.
  func setStatus(_ text: String, animating: Bool, style: BrailleAnimator.Style?, attention: Bool = false) {
    lock.withLock {
      refreshSize()
      let attentionChanged = statusNeedsAttention != attention
      statusNeedsAttention = attention
      let animationChanged = animatingStatus != animating
      animatingStatus = animating
      activityRestarted = animationChanged && animating
      if animationChanged {
        activityStartedAt = animating ? DispatchTime.now().uptimeNanoseconds : nil
        activityFrame = 0
        displayedActivitySecond = 0
        if animating {
          animator = BrailleAnimator.randomStyle()
          animator.start()
        }
      }
      if let style {
        animator = style == .random ? BrailleAnimator.randomStyle() : BrailleAnimator(style: style)
        animator.start()
        activityRestarted = true
      }
      updateActivityTimer()
      guard text != statusText || animationChanged || activityRestarted || attentionChanged else { return }
      statusText = text
      activityRestarted = false
      // A tab-completion menu owns the row until it closes; the status is
      // still kept so the row can be restored when it does.
      guard active, completionMenu == nil else { return }
      drawStatusRow()
      placeCaret()
    }
  }

  /// Emits an ANSI command without treating it as scrolling output.
  func emitControlSequence(_ sequence: String) {
    lock.withLock { write(sequence) }
  }

  /// A transient reasoning window above the status and editable prompt.
  func setThinking(_ text: String?, display: ThinkingDisplay = .status) {
    lock.withLock {
      refreshSize()
      let previousRows = thinkingRows
      thinkingText = text
      thinkingDisplay = display
      layoutThinking()
      guard thinkingRows != previousRows else { return }
      guard active else { return }
      if thinkingRows.count != previousRows.count {
        resizeRegion(
          inputRows: inputRows.count + previousRows.count,
          to: inputRows.count + thinkingRows.count)
        drawStatusRow()
        drawInputRows()
      } else {
        drawThinkingRows()
      }
      placeCaret()
    }
  }

  // MARK: - LineEditorSurface

  /// Up to half the screen, so the output keeps room of its own.
  func maximumInputRows() -> Int {
    lock.withLock { maximumInputRowsLocked }
  }

  private var maximumInputRowsLocked: Int {
    max(1, min(rows / 2, rows - 5))
  }

  func drawInput(rows: [String], caretRow: Int, caretColumn: Int) {
    lock.withLock {
      refreshSize()
      let previousCount = inputRows.count
      inputRows = rows.isEmpty ? [""] : rows
      self.caretRow = caretRow
      self.caretColumn = caretColumn
      guard active else { return }
      clampInputRows()
      if inputRows.count != previousCount {
        resizeRegion(
          inputRows: previousCount + thinkingRows.count, to: inputRows.count + thinkingRows.count)
        drawStatusRow()
      }
      drawInputRows()
      placeCaret()
    }
  }

  func acceptInput(styled: String) {
    lock.withLock {
      refreshSize()
      let previousCount = inputRows.count
      inputRows = [""]
      caretRow = 0
      caretColumn = 0
      guard active else { return }
      let submitted = (outputEndedLine ? "" : "\n") + styled + "\n"
      transcript.append(submitted)
      if ui.mode == .buffer {
        transcript.follow()
        outputEndedLine = true
        redrawBuffer()
        return
      }
      var out = Self.restoreCursor
      if !outputEndedLine { out += "\n" }
      out += styled + "\n" + Self.saveCursor
      write(out)
      outputEndedLine = true
      if previousCount != 1 {
        resizeRegion(inputRows: previousCount + thinkingRows.count, to: 1 + thinkingRows.count)
        drawStatusRow()
      }
      drawInputRows()
      placeCaret()
    }
  }

  func cancelInput() {
    acceptInput(styled: "^C")
  }

  func clearScreen() {
    clearScreen(clearOutput: false)
  }

  func clearScreen(clearOutput: Bool) {
    lock.withLock {
      guard active else { return }
      refreshSize()
      if clearOutput {
        transcript.clear()
        thinkingBlock = nil
        replyBlock = nil
        toolBlocks.removeAll()
      }
      if ui.mode == .buffer {
        transcript.follow()
        write("\u{1B}[2J")
        redrawBuffer()
        return
      }
      write("\u{1B}[2J" + move(row: 1, column: 1) + Self.saveCursor)
      outputEndedLine = true
      paintedThinkingRows = []
      drawStatusRow()
      drawInputRows()
      placeCaret()
    }
  }

  func emit(_ text: String) {
    write(text, to: .standardOutput)
  }

  func scrollOutput(wheel: Int, pages: Int) {
    lock.withLock {
      guard active, ui.mode == .buffer else { return }
      refreshSize()
      transcript.scroll(
        lines: wheel * max(1, ui.scroll) + pages * max(1, regionBottom - 1),
        width: max(1, columns - 1), height: regionBottom)
      drawOutputRows()
      drawStatusRow()
      placeCaret()
    }
  }

  func drawSeparator(styled: String?) {
    // The status row is the separator here, and the REPL keeps it current.
  }

  /// Puts the rotating tab-completion options on the status row above the
  /// prompt, with the selected option on a background of its own, or restores
  /// the REPL's status when the menu closes.
  func drawCompletionMenu(_ menu: CompletionMenu?) {
    lock.withLock {
      refreshSize()
      guard completionMenu != menu else { return }
      completionMenu = menu
      guard active else { return }
      drawStatusRow()
      placeCaret()
    }
  }

  func bell() {
    lock.withLock { write("\u{7}") }
  }

  func suspendProcess() {
    // The Windows console has no job control, so Ctrl+Z is simply ignored.
    #if !os(Windows)
      suspendTerminal {
        // The input thread can inherit a blocked SIGTSTP. SIGSTOP cannot be
        // blocked, so raw mode is restored only after the shell resumes us.
        _ = raise(SIGSTOP)
      }
    #endif
  }

  func pendingInput() -> [UInt8] {
    lock.withLock {
      let pending = typeahead
      typeahead = []
      return pending
    }
  }

  // MARK: - Drawing

  /// The status row and the input rows.
  private var reservedRows: Int { 1 + thinkingRows.count + inputRows.count }

  private var regionBottom: Int { max(1, rows - reservedRows) }

  private var firstInputRow: Int { rows - inputRows.count + 1 }

  /// Moves the region's bottom edge for an input area of another height.
  ///
  /// When the input grows, the region loses rows: its content scrolls up only
  /// as far as the last output needs to stay inside, and the saved output
  /// cursor follows it. When the input shrinks, the region takes the freed
  /// rows back as blank ones below the output, where the next output lands.
  private func resizeRegion(inputRows previousCount: Int, to count: Int) {
    if ui.mode == .buffer {
      paintedOutputRows = []
      write("\u{1B}[1;\(regionBottom)r")
      drawOutputRows()
      return
    }
    let previousBottom = max(1, rows - 1 - previousCount)
    let bottom = max(1, rows - 1 - count)
    var out = ""
    // Every restore is followed by a save: the saved position must survive
    // being restored more than once, and not every terminal keeps it.
    if bottom < previousBottom {
      write(Self.restoreCursor)
      let outputRow = currentOutputRow(fallback: previousBottom)
      out += Self.saveCursor
      let scroll = max(0, min(outputRow, previousBottom) - bottom)
      if scroll > 0 {
        out += move(row: previousBottom, column: 1) + String(repeating: "\n", count: scroll)
        out += Self.restoreCursor + "\u{1B}[\(scroll)A" + Self.saveCursor
      }
      out += "\u{1B}[1;\(bottom)r" + Self.restoreCursor + Self.saveCursor
    } else if bottom > previousBottom {
      out += "\u{1B}[1;\(bottom)r"
      for row in (previousBottom + 1)...bottom {
        out += move(row: row, column: 1) + Self.clearLine
      }
      out += Self.restoreCursor + Self.saveCursor
    }
    write(out)
  }

  private func drawStatusRow() {
    drawThinkingRows()
    drawStatusLine()
  }

  private func redrawBuffer() {
    paintedOutputRows = []
    paintedThinkingRows = []
    write("\u{1B}[1;\(regionBottom)r")
    drawOutputRows()
    drawStatusRow()
    drawInputRows()
    placeCaret()
  }

  private func drawOutputRows() {
    var visible = transcript.visibleRows(width: max(1, columns - 1), height: regionBottom)
    visible += Array(repeating: "", count: max(0, regionBottom - visible.count))
    var out = ""
    for (index, text) in visible.enumerated() {
      if index < paintedOutputRows.count, paintedOutputRows[index] == text { continue }
      out += move(row: index + 1, column: 1) + Self.reset + Self.clearLine + text + Self.reset
    }
    paintedOutputRows = visible
    writeFixedRows(out)
  }

  private func drawThinkingRows() {
    let width = max(1, columns - 1)
    let origin = regionBottom + 1
    if origin != paintedThinkingOrigin || width != paintedThinkingWidth {
      paintedThinkingRows = []
    }
    var out = ""
    var painted: [String] = []
    let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    for (index, line) in thinkingRows.enumerated() {
      let content = Self.truncated(line, width: width)
      let padded =
        content + String(repeating: " ", count: max(0, width - Self.displayWidth(content)))
      painted.append(padded)
      let previous = index < paintedThinkingRows.count ? paintedThinkingRows[index] : ""
      guard previous != padded else { continue }
      let prefix = zip(previous, padded).prefix { $0 == $1 }.count
      let suffix = zip(previous.dropFirst(prefix).reversed(), padded.dropFirst(prefix).reversed())
        .prefix { $0 == $1 }.count
      let column = Self.displayWidth(String(padded.prefix(prefix))) + 1
      out += move(row: origin + index, column: column) + Self.reset
      if colors {
        let code = TerminalLineEditor.foregroundColorCode(ui.thinkingForeground)
        out += "\u{1B}[3" + (code.map { ";" + $0 } ?? "") + "m"
      }
      // Overwrite only the changed span. Padding removes stale glyphs without
      // clearing a visible row before its replacement reaches the terminal.
      out += padded.dropFirst(prefix).dropLast(suffix) + Self.reset
      if previous.isEmpty { out += "\u{1B}[K" }
    }
    paintedThinkingRows = painted
    paintedThinkingOrigin = origin
    paintedThinkingWidth = width
    writeFixedRows(out)
  }

  private func drawStatusLine(clear: Bool = true) {
    let width = max(1, columns - 1)
    let status: String
    if animatingStatus, let activityStartedAt {
      let elapsed = (DispatchTime.now().uptimeNanoseconds - activityStartedAt) / 1_000_000_000
      let frame = animator.next()
      status = "\(frame) \(elapsed / 60)m\(elapsed % 60)s" + String(statusText.dropFirst())
      displayedActivitySecond = elapsed
    } else {
      status = statusText
    }
    let scrollHint = ui.mode == .buffer && !transcript.isFollowing ? "↑ scroll · PgDn to latest · " : ""
    let content = Self.truncated(" \(scrollHint)\(status) ", width: width)
    let padding = String(repeating: " ", count: max(0, width - Self.displayWidth(content)))
    let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    var out = ""
    out += move(row: regionBottom + thinkingRows.count + 1, column: 1)
    if clear { out += Self.clearLine }
    if let menu = completionMenu {
      out += completionMenuRow(menu, width: width, colors: colors)
    } else if statusNeedsAttention {
      let warning = colors ? TerminalLineEditor.foregroundColorCode(ui.warningForeground) : nil
      let codes = ["1", "7"] + [warning].compactMap { $0 }
      out += "\u{1B}[" + codes.joined(separator: ";") + "m" + content + padding + Self.reset
    } else if let background = TerminalLineEditor.backgroundColorCode(ui.backgroundLine) {
      out += "\u{1B}[\(background)m" + content + padding + Self.reset
    } else {
      out += "\u{1B}[2m" + content + Self.reset
    }
    writeFixedRows(out)
  }

  /// One row of completion options, joined by two spaces. Each option is shown
  /// short — only the part after the shared prefix, which the input line
  /// already carries — so the repeated common part is not listed once per
  /// match. The selected option gets a background of its own, or plain reverse
  /// video when colors are off.
  private func completionMenuRow(_ menu: CompletionMenu, width: Int, colors: Bool) -> String
  {
    let separator = "  "
    let marker = "\u{1B}[7m"  // reverse video, always available
    let selectionCodes = colors ? [
      TerminalLineEditor.foregroundColorCode(ui.selectionForeground),
      TerminalLineEditor.backgroundColorCode(ui.selectionBackground),
    ].compactMap { $0 } : []
    let selection = selectionCodes.isEmpty
      ? marker : "\u{1B}[" + selectionCodes.joined(separator: ";") + "m"
    let labels = menu.options.map { option in
      option.isEmpty ? "↵" : option.components(separatedBy: .controlCharacters).joined(separator: " ")
    }
    guard labels.indices.contains(menu.selected) else { return "" }
    var first = menu.selected
    var needed = min(width, Self.displayWidth(labels[first]))
    while first > 0 {
      let extra = Self.displayWidth(labels[first - 1]) + separator.count
      guard needed + extra <= width else { break }
      first -= 1
      needed += extra
    }
    var out = ""
    var used = 0
    for index in first..<labels.count {
      if index > first {
        guard used + separator.count <= width else { break }
        out += separator
        used += separator.count
      }
      let room = max(0, width - used)
      guard room > 0 else { break }
      let label = labels[index]
      let shown =
        Self.displayWidth(label) > room
        ? TerminalScreen.truncated(label, width: room) : label
      guard !shown.isEmpty else { break }
      if index == menu.selected {
        out += selection
      }
      out += shown + Self.reset
      used += Self.displayWidth(shown)
    }
    let pad = String(repeating: " ", count: max(0, width - used))
    return out + pad
  }

  private func updateActivityTimer() {
    guard active, animatingStatus else {
      activitySource?.cancel()
      activitySource = nil
      return
    }
    guard activitySource == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: .global())
    source.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
    source.setEventHandler { [weak self] in self?.drawActivity() }
    activitySource = source
    source.resume()
  }

  // Animate one cell without rebuilding the status or traversing the transcript.
  private func drawActivity() {
    lock.withLock {
      refreshSize()
      // The completion menu owns the row; its first cell must not blink.
      guard active, animatingStatus, let activityStartedAt, completionMenu == nil,
        columns > 2
      else { return }
      activityFrame = (activityFrame + 1) % 10
      let elapsed = (DispatchTime.now().uptimeNanoseconds - activityStartedAt) / 1_000_000_000
      if elapsed != displayedActivitySecond {
        drawStatusLine(clear: false)
        placeCaret()
        return
      }
      let marker = animator.next()
      let style = TerminalLineEditor.backgroundColorCode(ui.backgroundLine) ?? "2"
      let scrollHintWidth = ui.mode == .buffer && !transcript.isFollowing
        ? Self.displayWidth("↑ scroll · PgDn to latest · ") : 0
      guard 2 + scrollHintWidth < columns else { return }
      writeFixedRows(
        move(row: regionBottom + thinkingRows.count + 1, column: 2 + scrollHintWidth)
          + "\u{1B}[\(style)m" + marker + Self.reset)
      placeCaret()
    }
  }

  private func drawInputRows() {
    var out = ""
    let width = max(1, columns - 1)
    for (index, row) in inputRows.enumerated() {
      out +=
        move(row: firstInputRow + index, column: 1) + Self.clearLine
        + Self.clippedInputRow(row, width: width) + Self.reset
    }
    writeFixedRows(out)
  }

  private func placeCaret() {
    write(
      move(
        row: min(rows, firstInputRow + caretRow),
        column: min(columns, max(1, 1 + caretColumn))))
  }

  /// A resize can still happen between measuring and writing. Fixed rows must
  /// never wrap into the transcript or scroll the prompt, even in that window.
  /// Scrolling output keeps normal autowrap.
  private func writeFixedRows(_ text: String) {
    guard !text.isEmpty else { return }
    write("\u{1B}[?7l" + text + "\u{1B}[?7h")
  }

  private func move(row: Int, column: Int) -> String {
    "\u{1B}[\(row);\(column)H"
  }

  private func write(_ text: String) {
    FileHandle.standardOutput.write(Data(TerminalThemeStyle.resolve(text).utf8))
  }

  private func measure() {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 else { return }
    if size.ws_row >= 3 { rows = Int(size.ws_row) }
    if size.ws_col > 0 { columns = Int(size.ws_col) }
  }

  /// Keeps the input area within what the screen allows; the editor draws
  /// it again in full at its next keystroke.
  private func clampInputRows() {
    layoutThinking()
    let maximum = maximumInputRowsLocked
    guard inputRows.count > maximum else { return }
    inputRows = Array(inputRows.suffix(maximum))
    caretRow = min(caretRow, maximum - 1)
  }

  private func layoutThinking() {
    guard let thinkingText else {
      thinkingRows = []
      return
    }
    let count = min(thinkingDisplay.lineCount, rows / 4)
    guard count > 0 else {
      thinkingRows = []
      return
    }
    thinkingRows =
      thinkingDisplay == .status
      ? ["Thinking…"]
      : ThinkingPreview.carouselLines(
        thinkingText, count: count, width: max(1, columns - 1), measure: Self.displayWidth)
    thinkingRows += Array(repeating: "", count: max(0, count - thinkingRows.count))
  }

  private func watchResizes() {
    #if os(Windows)
      // The console sends no resize signal, so a timer looks for size changes.
      let source = DispatchSource.makeTimerSource(queue: .global())
      source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
      source.setEventHandler { [weak self] in self?.resizedIfNeeded() }
    #else
      signal(SIGWINCH, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
      source.setEventHandler { [weak self] in self?.resizedIfNeeded() }
    #endif
    source.resume()
    resizeSource = source
  }

  private func resizedIfNeeded() {
    lock.withLock { refreshSize() }
  }

  /// Called under `lock` before drawing: SIGWINCH delivery can lag behind a
  /// keystroke, streamed output, or an animation tick during a window drag.
  private func refreshSize() {
    guard active else { return }
    let previousRows = rows
    let previousColumns = columns
    measure()
    guard rows != previousRows || columns != previousColumns else { return }
    clampInputRows()
    if ui.mode == .buffer {
      redrawBuffer()
      return
    }
    let bottom = regionBottom
    // The saved output position follows the terminal's resize. Erase the old
    // footer from that boundary, including rows reflowed above the new footer
    // and rows left behind when growing the window. Keep partial output intact.
    var out = Self.restoreCursor + Self.clearBelow
    out += "\u{1B}[1;\(bottom)r"
    out += move(row: bottom, column: 1) + Self.saveCursor
    write(out)
    outputEndedLine = true
    paintedThinkingRows = []
    drawStatusRow()
    drawInputRows()
    placeCaret()
  }

  /// Cached input may have been styled at a wider size. Keep complete SGR
  /// sequences while clipping its characters until the editor lays it out again.
  private static func clippedInputRow(_ text: String, width: Int) -> String {
    var result = ""
    var used = 0
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "\u{1B}" {
        guard let end = text[index...].firstIndex(of: "m") else { break }
        result += text[index...end]
        index = text.index(after: end)
        continue
      }
      let characterWidth = displayWidth(String(character))
      guard used + characterWidth <= width else { break }
      result.append(character)
      used += characterWidth
      index = text.index(after: index)
    }
    return result
  }

  /// Returns the best-guess output row without querying the terminal.
  /// We used to ask the terminal for its cursor position (CPR), but that risks
  /// leaking responses like `[9;1R` into the input prompt when timing races or
  /// unexpected bytes land on stdin while we are waiting for the reply.
  private func currentOutputRow(fallback: Int) -> Int {
    fallback
  }

  private static func truncated(_ text: String, width: Int) -> String {
    guard displayWidth(text) > width else { return text }
    guard width > 2 else { return String(repeating: " ", count: max(0, width)) }
    var result = ""
    var used = 0
    for character in text {
      let characterWidth = displayWidth(String(character))
      guard used + characterWidth <= width - 2 else { break }
      result.append(character)
      used += characterWidth
    }
    return result + "… "
  }

  static func displayWidth(_ value: String) -> Int {
    TerminalLineEditor.displayWidth(of: value)
  }
}
