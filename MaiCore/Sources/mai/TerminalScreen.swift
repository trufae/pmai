import Foundation
import MaiCore

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
///
/// One lock serialises everything that touches the tty: a block from a child
/// agent, a streamed delta, and a keystroke's redraw are each written whole.
final class TerminalScreen: LineEditorSurface, @unchecked Sendable {
  private static let currentLock = NSLock()
  nonisolated(unsafe) private static var installed: TerminalScreen?

  /// The screen the REPL activated, so a command that hands the terminal to
  /// another program — an editor, visual mode — can step aside and come back.
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
  /// The rotating tab-completion options that take over the status row, or
  /// nil when the row shows `statusText`.
  private var completionMenu: CompletionMenu?
  private var thinkingRows: [String] = []
  /// The input as drawn, one styled string per row below the status line.
  private var inputRows = [""]
  private var caretRow = 0
  private var caretColumn = 0
  private var outputEndedLine = true
  private var active = false
  private var resizeSource: (any DispatchSourceProtocol)?
  private var activitySource: DispatchSourceTimer?
  private var animatingStatus = false
  private var activityStartedAt: UInt64?
  private var activityFrame = 0
  private var displayedActivitySecond: UInt64 = 0
  /// Keystrokes that arrived while the terminal was asked for its cursor
  /// position, kept for the editor.
  private var typeahead: [UInt8] = []

  private static let saveCursor = "\u{1B}7"
  private static let restoreCursor = "\u{1B}8"
  private static let clearLine = "\u{1B}[2K"
  private static let clearBelow = "\u{1B}[J"
  private static let reset = "\u{1B}[0m"
  private static let activityFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  /// Nil unless both stdin and stdout are terminals; piped sessions keep the
  /// plain one-line-at-a-time prompt.
  init?() {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return nil }
  }

  func configure(ui: ConfiguredTerminalUI) {
    lock.withLock {
      self.ui = ui
      guard active else { return }
      drawStatusRow()
      placeCaret()
    }
  }

  /// Usable columns for one row; the last column stays free so nothing wraps.
  var lineWidth: Int {
    lock.withLock { max(1, columns - 1) }
  }

  // MARK: - Lifecycle

  /// True when the last output ended with a newline, so the next thing
  /// printed starts a fresh row.
  var outputIsAtLineStart: Bool {
    lock.withLock { outputEndedLine }
  }

  /// Enters raw mode, reserves the bottom rows, and draws them. Call before the
  /// input thread starts reading: locating the cursor needs stdin for a moment.
  func activate() {
    lock.withLock { activateLocked() }
  }

  /// Takes the terminal back after `deactivate`, with the same status and
  /// input on screen. Only valid while the input thread is parked.
  func resume() {
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
    clampInputRows()
    // One newline per reserved row scrolls exactly as much as it takes for
    // the current row to end up inside the region, whatever row it was on.
    let row = currentCursorRow() ?? rows
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

  private func deactivateLocked() {
    guard active else { return }
    resizeSource?.cancel()
    resizeSource = nil
    activitySource?.cancel()
    activitySource = nil
    write(Self.restoreCursor + (outputEndedLine ? "" : "\n"))
    // Resetting the region homes the cursor, so the last output row is looked
    // up first (the input thread is parked, so stdin is free to answer) and
    // the shell continues right under it, with the reserved rows wiped.
    let row = currentCursorRow() ?? regionBottom
    write(
      "\u{1B}[r" + move(row: max(1, row), column: 1) + "\n" + Self.clearBelow
        + TerminalInputModes.disable)
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &cooked)
    active = false
  }

  // MARK: - Output

  /// Writes into the scroll region, leaving the caret on the input row.
  func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    lock.withLock {
      guard active else {
        handle.write(Data(text.utf8))
        return
      }
      if handle === FileHandle.standardOutput {
        write(Self.restoreCursor + text + Self.saveCursor)
      } else {
        write(Self.restoreCursor)
        handle.write(Data(text.utf8))
        write(Self.saveCursor)
      }
      outputEndedLine = text.hasSuffix("\n")
      placeCaret()
    }
  }

  /// Replaces the status line above the input; an unchanged line is not redrawn.
  func setStatus(_ text: String, animating: Bool = false) {
    lock.withLock {
      let animationChanged = animatingStatus != animating
      animatingStatus = animating
      if animationChanged {
        activityStartedAt = animating ? DispatchTime.now().uptimeNanoseconds : nil
        activityFrame = 0
        displayedActivitySecond = 0
      }
      updateActivityTimer()
      guard text != statusText || animationChanged else { return }
      statusText = text
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
  func setThinking(_ lines: [String]) {
    lock.withLock {
      let lines = Array(lines.suffix(min(3, rows / 4)))
      guard lines != thinkingRows else { return }
      let oldCount = thinkingRows.count
      thinkingRows = lines
      guard active else { return }
      resizeRegion(
        inputRows: inputRows.count + oldCount,
        to: inputRows.count + thinkingRows.count)
      drawStatusRow()
      drawInputRows()
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
      let previousCount = inputRows.count
      inputRows = rows.isEmpty ? [""] : rows
      self.caretRow = caretRow
      self.caretColumn = caretColumn
      guard active else { return }
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
      let previousCount = inputRows.count
      inputRows = [""]
      caretRow = 0
      caretColumn = 0
      guard active else { return }
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
    lock.withLock {
      guard active else { return }
      write("\u{1B}[2J" + move(row: 1, column: 1) + Self.saveCursor)
      outputEndedLine = true
      drawStatusRow()
      drawInputRows()
      placeCaret()
    }
  }

  func emit(_ text: String) {
    write(text, to: .standardOutput)
  }

  func drawSeparator(styled: String?) {
    // The status row is the separator here, and the REPL keeps it current.
  }

  /// Puts the rotating tab-completion options on the status row above the
  /// prompt, with the selected option on a background of its own, or restores
  /// the REPL's status when the menu closes.
  func drawCompletionMenu(_ menu: CompletionMenu?) {
    lock.withLock {
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
    let previousBottom = max(1, rows - 1 - previousCount)
    let bottom = max(1, rows - 1 - count)
    var out = ""
    // Every restore is followed by a save: the saved position must survive
    // being restored more than once, and not every terminal keeps it.
    if bottom < previousBottom {
      write(Self.restoreCursor)
      let outputRow = currentCursorRow() ?? previousBottom
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
    let width = max(1, columns - 1)
    var out = ""
    let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    for (index, line) in thinkingRows.enumerated() {
      out += move(row: regionBottom + index + 1, column: 1) + Self.clearLine
      if colors { out += "\u{1B}[3;38;5;\(244 + index * 3)m" }
      out += Self.truncated(line, width: width) + Self.reset
    }
    write(out)
    drawStatusLine()
  }

  private func drawStatusLine() {
    let width = max(1, columns - 1)
    let status: String
    if animatingStatus, let activityStartedAt {
      let elapsed = (DispatchTime.now().uptimeNanoseconds - activityStartedAt) / 1_000_000_000
      let frame = Self.activityFrames[activityFrame]
      status = "\(frame) \(elapsed / 60)m\(elapsed % 60)s" + String(statusText.dropFirst())
      displayedActivitySecond = elapsed
    } else {
      status = statusText
    }
    let content = Self.truncated(" \(status) ", width: width)
    let padding = String(repeating: " ", count: max(0, width - Self.displayWidth(content)))
    let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    var out = ""
    out += move(row: regionBottom + thinkingRows.count + 1, column: 1) + Self.clearLine
    if let menu = completionMenu {
      out += Self.completionMenuRow(menu, width: width, colors: colors)
    } else if let background = TerminalLineEditor.backgroundColorCode(ui.backgroundLine) {
      out += "\u{1B}[\(background)m" + content + padding + Self.reset
    } else {
      out += "\u{1B}[2m" + content + Self.reset
    }
    write(out)
  }

  /// One row of completion options, joined by two spaces. Each option is shown
  /// short — only the part after the shared prefix, which the input line
  /// already carries — so the repeated common part is not listed once per
  /// match. The selected option gets a background of its own, or plain reverse
  /// video when colors are off.
  private static func completionMenuRow(_ menu: CompletionMenu, width: Int, colors: Bool) -> String {
    let separator = "  "
    let marker = "\u{1B}[7m"  // reverse video, always available
    let selectionBackground = colors ? TerminalLineEditor.backgroundColorCode("blue") : nil
    let labels = menu.options.map { option in
      option.isEmpty ? "↵" : option.components(separatedBy: .controlCharacters).joined(separator: " ")
    }
    guard labels.indices.contains(menu.selected) else { return "" }
    var first = menu.selected
    var needed = min(width, displayWidth(labels[first]))
    while first > 0 {
      let extra = displayWidth(labels[first - 1]) + separator.count
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
      let shown = displayWidth(label) > room
        ? TerminalScreen.truncated(label, width: room) : label
      guard !shown.isEmpty else { break }
      // The highlighted option gets a background of its own — blue behind
      // white text — or reverse video where colors are unavailable.
      if index == menu.selected {
        out += selectionBackground.map { "\u{1B}[\($0)m\u{1B}[97m" } ?? marker
      }
      out += shown + Self.reset
      used += displayWidth(shown)
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
      // The completion menu owns the row; its first cell must not blink.
      guard active, animatingStatus, let activityStartedAt, completionMenu == nil,
        columns > 2
      else { return }
      activityFrame = (activityFrame + 1) % Self.activityFrames.count
      let elapsed = (DispatchTime.now().uptimeNanoseconds - activityStartedAt) / 1_000_000_000
      if elapsed != displayedActivitySecond {
        drawStatusLine()
        placeCaret()
        return
      }
      let marker = Self.activityFrames[activityFrame]
      let style = TerminalLineEditor.backgroundColorCode(ui.backgroundLine) ?? "2"
      write(
        move(row: regionBottom + thinkingRows.count + 1, column: 2)
          + "\u{1B}[\(style)m" + marker + Self.reset)
      placeCaret()
    }
  }

  private func drawInputRows() {
    var out = ""
    for (index, row) in inputRows.enumerated() {
      out += move(row: firstInputRow + index, column: 1) + Self.clearLine + row
    }
    write(out)
  }

  private func placeCaret() {
    write(move(row: firstInputRow + caretRow, column: max(1, 1 + caretColumn)))
  }

  private func move(row: Int, column: Int) -> String {
    "\u{1B}[\(row);\(column)H"
  }

  private func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
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
    thinkingRows = Array(thinkingRows.suffix(min(3, rows / 4)))
    let maximum = maximumInputRowsLocked
    guard inputRows.count > maximum else { return }
    inputRows = Array(inputRows.suffix(maximum))
    caretRow = min(caretRow, maximum - 1)
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
    lock.withLock {
      guard active else { return }
      var size = winsize()
      guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 else { return }
      let newRows = size.ws_row >= 3 ? Int(size.ws_row) : rows
      let newColumns = size.ws_col > 0 ? Int(size.ws_col) : columns
      guard newRows != rows || newColumns != columns else { return }
      rows = newRows
      columns = newColumns
      clampInputRows()
      let bottom = regionBottom
      var out = "\u{1B}[1;\(bottom)r"
      out += move(row: bottom, column: 1) + Self.saveCursor
      write(out)
      outputEndedLine = true
      drawStatusRow()
      drawInputRows()
      placeCaret()
    }
  }

  /// Asks the terminal where the cursor is; nil when it stays quiet. Bytes
  /// that turn out to be keystrokes are kept for the editor, so this is safe
  /// on the input thread as well as while it is parked.
  private func currentCursorRow() -> Int? {
    write("\u{1B}[6n")
    var buffer: [UInt8] = []
    let deadline = Date().addingTimeInterval(0.25)
    defer { typeahead += buffer }
    while Date() < deadline {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
      guard poll(&descriptor, 1, remaining) > 0 else { return nil }
      var byte: UInt8 = 0
      guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
      buffer.append(byte)
      guard byte == UInt8(ascii: "R"), let start = buffer.lastIndex(of: 0x1B),
        start + 1 < buffer.count, buffer[start + 1] == UInt8(ascii: "[")
      else { continue }
      let body = String(decoding: buffer[(start + 2)..<(buffer.count - 1)], as: UTF8.self)
      let fields = body.split(separator: ";")
      guard fields.count == 2, let row = Int(fields[0]), Int(fields[1]) != nil else { continue }
      buffer.removeSubrange(start...)
      return row
    }
    return nil
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
