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

/// Completion suffixes and the option currently applied to the input line.
struct CompletionMenu: Equatable {
  var options: [String]
  var selected: Int
}

/// Where a line editor draws. The classic surface owns the rows at the end of
/// a scrolling terminal, the way a shell prompt does; `TerminalScreen` owns
/// rows that stay below the output while agents print.
protocol LineEditorSurface: AnyObject {
  /// Rows the input may take before it scrolls inside its own area.
  func maximumInputRows() -> Int
  /// Draws the whole input area: one styled string per row, cleared first,
  /// with the caret on `caretRow` after `caretColumn` cells.
  func drawInput(rows: [String], caretRow: Int, caretColumn: Int)
  /// The input was accepted: `styled`, which may span lines, stays on screen
  /// as a record and the area is free again.
  func acceptInput(styled: String)
  /// Ctrl+C threw the input away.
  func cancelInput()
  /// Clears the display while keeping the input and terminal layout.
  func clearScreen()
  /// Text that belongs with the output, such as completion candidates.
  func emit(_ text: String)
  /// The line drawn above a fresh prompt, or nothing.
  func drawSeparator(styled: String?)
  func bell()
  /// Shows the rotating tab-completion options above the prompt, replacing
  /// the status line, or clears them when `menu` is nil.
  func drawCompletionMenu(_ menu: CompletionMenu?)
  /// Hands the terminal back to the shell for Ctrl+Z and takes it again.
  func suspendProcess()
  /// Keystrokes the surface read from the terminal while it asked it
  /// something, in the order they were typed; the editor consumes them first.
  func pendingInput() -> [UInt8]
}

extension LineEditorSurface {
  func pendingInput() -> [UInt8] { [] }
  /// Surfaces with no status row simply do not show the menu.
  func drawCompletionMenu(_ menu: CompletionMenu?) {}
}

/// Terminal modes the editor turns on while it reads: bracketed paste, so a
/// pasted text arrives whole with its newlines instead of as typed lines, and
/// the kitty keyboard protocol's disambiguation, so Shift+Enter is told apart
/// from Enter on terminals that need asking. Terminals without either ignore
/// the sequences.
enum TerminalInputModes {
  static let enable = "\u{1B}[?2004h\u{1B}[>1u"
  static let disable = "\u{1B}[<u\u{1B}[?2004l"
}

/// The surface of a plain scrolling terminal: the input starts on the row the
/// cursor is on and grows downwards, and the editor owns the tty mode while
/// it reads.
private final class ClassicEditorSurface: LineEditorSurface {
  private var cooked: termios
  private var raw: termios
  /// The row of the input area the caret was left on, which is how far up
  /// the area starts at the next draw.
  private var caretRow = 0
  private var drawnRows = 0
  /// Avoid reprinting the fallback list while Tab cycles through it.
  private var lastMenuKey: String?

  init(cooked: termios, raw: termios) {
    self.cooked = cooked
    self.raw = raw
  }

  func maximumInputRows() -> Int {
    max(1, TerminalLineEditor.terminalRows() - 1)
  }

  func drawInput(rows: [String], caretRow: Int, caretColumn: Int) {
    var out = "\r" + up(self.caretRow)
    for (index, row) in rows.enumerated() {
      out += "\u{1B}[2K" + row
      if index < rows.count - 1 { out += "\n" }
    }
    out += "\u{1B}[J"
    out += up(rows.count - 1 - caretRow) + "\r\u{1B}[\(caretColumn + 1)G"
    write(out)
    self.caretRow = caretRow
    drawnRows = rows.count
  }

  func acceptInput(styled: String) {
    write("\r" + up(caretRow) + "\u{1B}[J" + styled + "\n")
    caretRow = 0
    drawnRows = 0
  }

  func cancelInput() {
    acceptInput(styled: "^C")
  }

  func clearScreen() {
    write("\u{1B}[2J\u{1B}[H")
    caretRow = 0
    drawnRows = 0
  }

  func emit(_ text: String) {
    write("\r" + down(max(0, drawnRows - 1 - caretRow)) + "\n" + text)
    caretRow = 0
    drawnRows = 0
  }

  func drawSeparator(styled: String?) {
    guard let styled else { return }
    write("\r\u{1B}[2K" + styled + "\n")
  }

  func bell() {
    write("\u{7}")
  }

  /// The classic surface has no status row; show a plain list once.
  func drawCompletionMenu(_ menu: CompletionMenu?) {
    guard let menu else {
      lastMenuKey = nil
      return
    }
    let key = menu.options.joined(separator: "\u{0}")
    guard key != lastMenuKey else { return }
    lastMenuKey = key
    let options = menu.options.map { $0.isEmpty ? "↵" : $0 }
    emit(options.joined(separator: "  ") + "\n")
  }

  func suspendProcess() {
    // ISIG is disabled while editing so Ctrl+Z arrives as a byte. Restore the
    // shell's terminal mode before stopping, then re-enter raw mode after `fg`.
    // The Windows console has no job control, so Ctrl+Z is simply ignored.
    #if !os(Windows)
      write("\r" + up(caretRow) + "\u{1B}[J^Z\n" + TerminalInputModes.disable)
      caretRow = 0
      drawnRows = 0
      _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked)
      // The input thread can inherit a blocked SIGTSTP. SIGSTOP cannot be
      // blocked, so raw mode is restored only after the shell resumes us.
      _ = raise(SIGSTOP)
      _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
      write(TerminalInputModes.enable)
    #endif
  }

  private func up(_ rows: Int) -> String {
    rows > 0 ? "\u{1B}[\(rows)A" : ""
  }

  private func down(_ rows: Int) -> String {
    rows > 0 ? "\u{1B}[\(rows)B" : ""
  }

  private func write(_ value: String) {
    FileHandle.standardOutput.write(Data(value.utf8))
  }
}

/// Small dependency-free line editor for the REPL. Non-interactive input keeps
/// normal `readLine` behaviour, while terminals gain history, completion, and
/// input spanning several lines: Shift+Enter (Alt+Enter or Ctrl+J where the
/// terminal cannot tell Shift+Enter apart) breaks the line, a paste keeps its
/// newlines, and Enter submits the whole text.
final class TerminalLineEditor {
  private struct ReverseSearchState {
    var query: [UInt8] = []
    var matchIndex: Int?
    var failed: Bool
  }

  private enum ReverseSearchResult {
    case accepted(line: [UInt8], historyIndex: Int?, cursor: Int)
    case cancelled
    case interrupted
    case submitted([UInt8])
    case endOfFile
  }

  /// One keystroke, or a pasted block, decoded from the terminal's bytes.
  private enum Key {
    /// A plain byte: a control character or the first byte of a character.
    case byte(UInt8)
    /// A whole character the terminal reported through an escape sequence.
    case text([UInt8])
    case up, down, left, right, home, end, delete
    /// Shift+Enter or Alt+Enter: a line break inside the input.
    case newline
    /// A bracketed paste, as sent.
    case paste([UInt8])
    /// A lone Escape, or a sequence the editor has no use for.
    case ignored
  }

  private let historyURL: URL?
  private var history: [String]
  private let maximumHistory = 500
  private var ui = ConfiguredTerminalUI()
  private(set) var wasInterrupted = false
  /// A surface that owns the tty for the whole session. While one is
  /// installed the editor neither changes the terminal mode nor draws a
  /// separator; the surface keeps the row and the status line.
  private var persistentSurface: LineEditorSurface?
  /// Where the current `readLine` draws.
  private var surface: LineEditorSurface?
  /// The first of the input's lines shown when there are more than fit.
  private var viewTop = 0
  /// Bytes read ahead of the editor, consumed before the terminal is read.
  private var typeahead: [UInt8] = []
  /// The rotation Tab is walking, and the full matches it came from, kept
  /// while the input still belongs to it.
  private var completionMenu: CompletionMenu?
  private var completionMatches: [String] = []

  init(historyURL: URL? = nil) {
    self.historyURL = historyURL
    history = Self.loadHistory(from: historyURL)
  }

  func configure(ui: ConfiguredTerminalUI) {
    self.ui = ui
  }

  func install(surface: LineEditorSurface?) {
    persistentSurface = surface
  }

  func readLine(
    prompt: String,
    completions: [String],
    separator: String? = nil,
    rememberInput: Bool = true
  ) -> String? {
    wasInterrupted = false
    if let persistentSurface {
      surface = persistentSurface
      defer { surface = nil }
      return readInteractive(
        prompt: prompt, completions: completions, separator: nil, rememberInput: rememberInput)
    }
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
      FileHandle.standardOutput.write(Data(prompt.utf8))
      guard let line = Swift.readLine(strippingNewline: true) else { return nil }
      if rememberInput { remember(line) }
      return line
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      FileHandle.standardOutput.write(Data(prompt.utf8))
      guard let line = Swift.readLine(strippingNewline: true) else { return nil }
      if rememberInput { remember(line) }
      return line
    }
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
    defer { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
    FileHandle.standardOutput.write(Data(TerminalInputModes.enable.utf8))
    defer { FileHandle.standardOutput.write(Data(TerminalInputModes.disable.utf8)) }
    surface = ClassicEditorSurface(cooked: original, raw: raw)
    defer { surface = nil }
    return readInteractive(
      prompt: prompt, completions: completions, separator: separator, rememberInput: rememberInput)
  }

  private func readInteractive(
    prompt: String,
    completions: [String],
    separator: String?,
    rememberInput: Bool
  ) -> String? {
    var bytes: [UInt8] = []
    var cursor = 0
    var historyIndex: Int?
    var draft: [UInt8] = []
    viewTop = 0
    completionMenu = nil
    completionMatches = []
    drawSeparator(separator)
    redraw(prompt: prompt, bytes: bytes, cursor: cursor)

    func insert(_ text: [UInt8]) {
      guard !text.isEmpty else { return }
      bytes.insert(contentsOf: text, at: cursor)
      cursor += text.count
      historyIndex = nil
      redraw(prompt: prompt, bytes: bytes, cursor: cursor)
    }

    /// Up and Down walk the input's lines first and the history at its edges.
    func moveToPreviousLine() {
      if moveUp(in: bytes, cursor: &cursor) {
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        return
      }
      guard
        recallPreviousHistoryEntry(
          bytes: &bytes, cursor: &cursor, historyIndex: &historyIndex, draft: &draft)
      else { return }
      redraw(prompt: prompt, bytes: bytes, cursor: cursor)
    }

    func moveToNextLine() {
      if moveDown(in: bytes, cursor: &cursor) {
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        return
      }
      guard
        recallNextHistoryEntry(
          bytes: &bytes, cursor: &cursor, historyIndex: &historyIndex, draft: &draft)
      else { return }
      redraw(prompt: prompt, bytes: bytes, cursor: cursor)
    }

    while let key = readKey() {
      // Any key but Tab closes the rotating completion menu: the next edit
      // starts a fresh completion, and the status row comes back.
      if !isTabKey(key) { dismissCompletion() }
      switch key {
      case .byte(let byte):
        switch byte {
        case 1:  // Ctrl+A: start of the line
          cursor = lineStart(in: bytes, at: cursor)
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case 2:  // Ctrl+B, like Left
          cursor = previousCharacterStart(in: bytes, before: cursor)
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case 3:  // Ctrl+C
          wasInterrupted = true
          surface?.cancelInput()
          return ""
        case 4:  // Ctrl+D
          if bytes.isEmpty {
            surface?.acceptInput(styled: "")
            return nil
          }
        case 5:  // Ctrl+E: end of the line
          cursor = lineEnd(in: bytes, at: cursor)
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case 6:  // Ctrl+F, like Right
          cursor = nextCharacterEnd(in: bytes, after: cursor)
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case 9:  // Tab
          complete(
            prompt: prompt,
            bytes: &bytes,
            cursor: &cursor,
            candidates: completions)
        case 10:  // Ctrl+J: a line break, for terminals that send Enter for Shift+Enter
          insert([10])
        case 12:  // Ctrl+L
          surface?.clearScreen()
          drawSeparator(separator)
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case 14:  // Ctrl+N
          moveToNextLine()
        case 16:  // Ctrl+P
          moveToPreviousLine()
        case 18:  // Ctrl+R
          switch reverseSearch(original: bytes, startingAt: historyIndex) {
          case .accepted(let line, let index, let acceptedCursor):
            if historyIndex == nil, index != nil { draft = bytes }
            bytes = line
            cursor = acceptedCursor
            historyIndex = index
            redraw(prompt: prompt, bytes: bytes, cursor: cursor)
          case .cancelled:
            redraw(prompt: prompt, bytes: bytes, cursor: cursor)
          case .interrupted:
            wasInterrupted = true
            surface?.cancelInput()
            return ""
          case .submitted(let line):
            renderSubmittedLine(prompt: prompt, bytes: line)
            let submitted = String(decoding: line, as: UTF8.self)
            if rememberInput { remember(submitted) }
            return submitted
          case .endOfFile:
            surface?.acceptInput(styled: "")
            return nil
          }
        case 23:  // Ctrl+W
          guard cursor > 0 else { continue }
          let start = previousWordStart(in: bytes, before: cursor)
          bytes.removeSubrange(start..<cursor)
          cursor = start
          historyIndex = nil
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case 26:  // Ctrl+Z
          surface?.suspendProcess()
          drawSeparator(separator)
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case 13:  // Enter submits the whole input
          renderSubmittedLine(prompt: prompt, bytes: bytes)
          let line = String(decoding: bytes, as: UTF8.self)
          if rememberInput { remember(line) }
          return line
        case 127, 8:
          guard cursor > 0 else { continue }
          let previous = previousCharacterStart(in: bytes, before: cursor)
          bytes.removeSubrange(previous..<cursor)
          cursor = previous
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        default:
          guard byte >= 32 else { continue }
          insert(readCharacter(startingWith: byte))
        }
      case .text(let character):
        insert(character)
      case .newline:
        insert([10])
      case .paste(let pasted):
        insert(normalizedPaste(pasted))
      case .up:
        moveToPreviousLine()
      case .down:
        moveToNextLine()
      case .left:
        cursor = previousCharacterStart(in: bytes, before: cursor)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case .right:
        cursor = nextCharacterEnd(in: bytes, after: cursor)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case .home:
        cursor = lineStart(in: bytes, at: cursor)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case .end:
        cursor = lineEnd(in: bytes, at: cursor)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case .delete:
        guard cursor < bytes.count else { continue }
        let end = nextCharacterEnd(in: bytes, after: cursor)
        bytes.removeSubrange(cursor..<end)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case .ignored:
        continue
      }
    }
    dismissCompletion()
    surface?.acceptInput(styled: "")
    return nil
  }

  // MARK: - Keys

  private func readKey() -> Key? {
    guard let byte = readByte() else { return nil }
    guard byte == 27 else { return .byte(byte) }
    return readEscapeSequence()
  }

  /// What follows an Escape byte: a CSI or SS3 sequence, Alt+Enter, or
  /// nothing within a moment, which is the Escape key on its own.
  private func readEscapeSequence() -> Key {
    guard let next = readByte(timeoutMilliseconds: 50) else {
      return swallowTornReplyOrReseatKeys()
    }
    switch next {
    case 10, 13:
      return .newline
    case UInt8(ascii: "["):
      return readControlSequence()
    case UInt8(ascii: "O"):
      guard let final = readByte() else { return .ignored }
      return cursorKey(final: final) ?? .ignored
    default:
      return .ignored
    }
  }

  /// The Escape key was left alone for 50 ms. A reply torn into pieces by
  /// the sender can continue here (e.g. a cursor report `ESC [ 8 ; 1 R`
  /// split into two writes). A complete control sequence arriving right
  /// after a lone Escape is such a reply, never text, so it is dropped.
  /// Anything that does not form a sequence is put back for the editor to
  /// read as ordinary keystrokes.
  private func swallowTornReplyOrReseatKeys() -> Key {
    guard let next = readByte(timeoutMilliseconds: 200) else { return .ignored }
    guard next == UInt8(ascii: "[") else {
      typeahead.insert(next, at: 0)
      return .ignored
    }
    var consumed: [UInt8] = [next]
    while consumed.count < 32, let byte = readByte(timeoutMilliseconds: 50) {
      consumed.append(byte)
      if (0x40...0x7E).contains(byte) {
        // A complete sequence: a torn reply, swallowed.
        return .ignored
      }
    }
    typeahead.insert(contentsOf: consumed, at: 0)
    return .ignored
  }

  /// The parameters and final byte of a CSI sequence, `ESC [` already read.
  private func readControlSequence() -> Key {
    var parameters: [UInt8] = []
    while let byte = readByte(timeoutMilliseconds: parameters.isEmpty ? nil : 250) {
      if (0x40...0x7E).contains(byte) {
        return decodeControlSequence(
          parameters: String(decoding: parameters, as: UTF8.self), final: byte)
      }
      if byte == 27 {
        // A new Escape cancels a sequence still waiting for its final byte,
        // the way a terminal's parser does. A cursor report that arrives
        // whole after a torn prefix then parses from its own Escape.
        return readEscapeSequence()
      }
      guard parameters.count < 64 else { return .ignored }
      parameters.append(byte)
    }
    return .ignored
  }

  private func decodeControlSequence(parameters: String, final: UInt8) -> Key {
    let fields = parameters.split(separator: ";", omittingEmptySubsequences: false)
      .map(String.init)
    if let key = cursorKey(final: final) { return key }
    switch final {
    case UInt8(ascii: "~"):
      switch fields.first.flatMap({ Int($0) }) {
      case 1, 7: return .home
      case 4, 8: return .end
      case 3: return .delete
      case 200: return .paste(readPastedBytes())
      case 27:
        // xterm's modifyOtherKeys form: CSI 27 ; modifiers ; key ~
        guard fields.count >= 3, let modifiers = Int(fields[1]), let code = Int(fields[2])
        else { return .ignored }
        return decodeKeyCode(code, shifted: nil, modifiers: modifiers, event: 1)
      default: return .ignored
      }
    case UInt8(ascii: "u"):
      // The kitty keyboard protocol: CSI key[:shifted[:base]] ; modifiers[:event] u
      let keyFields = fields[0].split(separator: ":", omittingEmptySubsequences: false)
      guard let code = keyFields.first.flatMap({ Int($0) }) else { return .ignored }
      let shifted = keyFields.count > 1 ? Int(keyFields[1]) : nil
      let modifierFields =
        fields.count > 1 ? fields[1].split(separator: ":", omittingEmptySubsequences: false) : []
      let modifiers = modifierFields.first.flatMap { Int($0) } ?? 1
      let event = modifierFields.count > 1 ? Int(modifierFields[1]) ?? 1 : 1
      return decodeKeyCode(code, shifted: shifted, modifiers: modifiers, event: event)
    default:
      return .ignored
    }
  }

  private func cursorKey(final: UInt8) -> Key? {
    switch final {
    case UInt8(ascii: "A"): .up
    case UInt8(ascii: "B"): .down
    case UInt8(ascii: "C"): .right
    case UInt8(ascii: "D"): .left
    case UInt8(ascii: "H"): .home
    case UInt8(ascii: "F"): .end
    default: nil
    }
  }

  /// A key reported with its modifiers, the way the kitty protocol and
  /// xterm's modifyOtherKeys do, mapped to what the editor knows: modified
  /// Enter breaks the line, Ctrl+letter is its control byte, and a plain
  /// character is text.
  private func decodeKeyCode(_ code: Int, shifted: Int?, modifiers: Int, event: Int) -> Key {
    guard event != 3 else { return .ignored }  // a key release
    // Shift 1, Alt 2, Ctrl 4, Super 8, Hyper 16, Meta 32; lock keys are ignored.
    let held = max(0, modifiers - 1) & 0x3F
    let shift = held & 1 != 0
    let ctrl = held & 4 != 0
    let others = held & ~5 != 0
    switch code {
    case 13, 57414:  // Enter, keypad Enter
      return held == 0 ? .byte(13) : .newline
    case 27: return .ignored
    case 9: return held == 0 ? .byte(9) : .ignored
    case 127, 8: return .byte(127)
    case 57349: return .delete
    case 57350: return .left
    case 57351: return .right
    case 57352: return .up
    case 57353: return .down
    case 57356: return .home
    case 57357: return .end
    default:
      if ctrl, !others {
        guard (97...122).contains(code) || (65...90).contains(code) else { return .ignored }
        return .byte(UInt8(code & 0x1F))
      }
      guard !ctrl, !others, code >= 32, let scalar = Unicode.Scalar(shift ? shifted ?? code : code)
      else { return .ignored }
      return .text(Array(String(Character(scalar)).utf8))
    }
  }

  /// Everything up to the paste's closing `ESC [ 201 ~`.
  /// Reads a whole cursor report `ESC [ rows ; cols R` that arrived inside a
  /// paste. Returns an empty array when the next bytes are such a report
  /// (drop it); returns nil when the bytes do not form a report (so the
  /// caller keeps the original Escape as paste content); puts any peeked bytes
  /// back on the typeahead when returning nil.
  private func readCursorReportMidPaste() -> [UInt8]? {
    // The byte after the Escape was already consumed by readPastedBytes.
    // Peek one byte without blocking to see if this could be a CPR.
    guard let bracket = readByte(timeoutMilliseconds: 0) else { return nil }
    guard bracket == UInt8(ascii: "[") else {
      typeahead.insert(bracket, at: 0)
      return nil
    }
    var parameters: [UInt8] = []
    while let byte = readByte(timeoutMilliseconds: 0) {
      if byte == UInt8(ascii: "R"),
        !parameters.isEmpty,
        parameters.allSatisfy({ $0 == 59 || (48...57).contains($0) })
      {
        return []
      }
      guard parameters.count < 16, byte == 59 || (48...57).contains(byte) else {
        typeahead.insert(contentsOf: [bracket] + parameters + [byte], at: 0)
        return nil
      }
      parameters.append(byte)
    }
    typeahead.insert(bracket, at: 0)
    return nil
  }

  /// Pasted bytes until the bracketed-paste terminator.  Stray cursor-position
  /// replies are dropped; everything else, including ESC bytes that do not form
  /// a report, is kept as paste content.  No timeout is applied, so slow pastes
  /// still work.
  private func readPastedBytes() -> [UInt8] {
    let terminator: [UInt8] = [27, 91, 50, 48, 49, 126]
    var result: [UInt8] = []
    while let byte = readByte() {
      if byte == 27 {
        // A cursor report can arrive inside a bracketed paste. It is a reply
        // to a query the editor did not send, not paste content, so drop it.
        // Other sequences stay as paste content without being consumed.
        if let trailing = readCursorReportMidPaste(), trailing.isEmpty {
          continue
        }
      }
      result.append(byte)
      if byte == 126, result.count >= terminator.count,
        result.suffix(terminator.count).elementsEqual(terminator)
      {
        result.removeLast(terminator.count)
        return result
      }
    }
    return result
  }
  /// Pasted text with its line ends as newlines and other control characters
  /// dropped; tabs stay.
  private func normalizedPaste(_ pasted: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(pasted.count)
    var index = 0
    while index < pasted.count {
      let byte = pasted[index]
      index += 1
      switch byte {
      case 13:
        result.append(10)
        if index < pasted.count, pasted[index] == 10 { index += 1 }
      case 9, 10:
        result.append(byte)
      case 0..<32, 127:
        continue
      default:
        result.append(byte)
      }
    }
    return result
  }

  private func recallPreviousHistoryEntry(
    bytes: inout [UInt8],
    cursor: inout Int,
    historyIndex: inout Int?,
    draft: inout [UInt8]
  ) -> Bool {
    guard !history.isEmpty else { return false }
    if historyIndex == nil {
      draft = bytes
      historyIndex = history.count - 1
    } else if historyIndex! > 0 {
      historyIndex! -= 1
    }
    bytes = Array(history[historyIndex!].utf8)
    cursor = bytes.count
    return true
  }

  private func recallNextHistoryEntry(
    bytes: inout [UInt8],
    cursor: inout Int,
    historyIndex: inout Int?,
    draft: inout [UInt8]
  ) -> Bool {
    guard let index = historyIndex else { return false }
    if index + 1 < history.count {
      historyIndex = index + 1
      bytes = Array(history[index + 1].utf8)
    } else {
      historyIndex = nil
      bytes = draft
    }
    cursor = bytes.count
    return true
  }

  private func reverseSearch(original: [UInt8], startingAt historyIndex: Int?)
    -> ReverseSearchResult
  {
    let initialIndex = historyIndex ?? history.indices.last
    var state = ReverseSearchState(
      matchIndex: initialIndex,
      failed: initialIndex == nil)
    var undoStack: [ReverseSearchState] = []
    redrawReverseSearch(state, original: original)

    func extendQuery(_ character: [UInt8]) {
      undoStack.append(state)
      state.query.append(contentsOf: character)
      if let match = matchingHistoryIndex(
        for: state.query,
        atOrBefore: state.matchIndex ?? history.count - 1)
      {
        state.matchIndex = match
        state.failed = false
      } else {
        state.failed = true
        surface?.bell()
      }
    }

    while let key = readKey() {
      let selection = reverseSearchSelection(state, original: original)
      switch key {
      case .byte(let byte):
        switch byte {
        case 1:  // Ctrl+A accepts the match and moves to its beginning.
          return .accepted(line: selection, historyIndex: state.matchIndex, cursor: 0)
        case 2:  // Ctrl+B accepts the match one character from its end, like Left.
          return .accepted(
            line: selection,
            historyIndex: state.matchIndex,
            cursor: previousCharacterStart(in: selection, before: selection.count))
        case 3:  // Ctrl+C cancels the whole input.
          return .interrupted
        case 5, 6:  // Ctrl+E and Ctrl+F accept the match and move to its end.
          return .accepted(
            line: selection,
            historyIndex: state.matchIndex,
            cursor: selection.count)
        case 7:  // Ctrl+G restores the line from before the search.
          return .cancelled
        case 9, 10:  // Tab and Ctrl+J accept the match for editing.
          return .accepted(
            line: selection,
            historyIndex: state.matchIndex,
            cursor: selection.count)
        case 12:  // Ctrl+L keeps the current search.
          surface?.clearScreen()
        case 13:
          return .submitted(selection)
        case 18:  // Ctrl+R repeats the search before the current match.
          if let index = state.matchIndex,
            let match = matchingHistoryIndex(for: state.query, atOrBefore: index - 1)
          {
            state.matchIndex = match
            state.failed = false
          } else {
            state.failed = true
            surface?.bell()
          }
        case 127, 8:
          guard let previous = undoStack.popLast() else {
            surface?.bell()
            continue
          }
          state = previous
        default:
          guard byte >= 32 else {
            surface?.bell()
            continue
          }
          extendQuery(readCharacter(startingWith: byte))
        }
      case .text(let character):
        extendQuery(character)
      case .left:  // Any other key accepts the match for editing.
        return .accepted(
          line: selection,
          historyIndex: state.matchIndex,
          cursor: previousCharacterStart(in: selection, before: selection.count))
      case .right, .up, .down, .home, .end, .delete, .newline, .paste, .ignored:
        return .accepted(
          line: selection,
          historyIndex: state.matchIndex,
          cursor: selection.count)
      }
      redrawReverseSearch(state, original: original)
    }
    return .endOfFile
  }

  private func matchingHistoryIndex(for query: [UInt8], atOrBefore upperBound: Int) -> Int? {
    guard upperBound >= 0, !history.isEmpty else { return nil }
    let needle = String(decoding: query, as: UTF8.self)
    if needle.isEmpty { return min(upperBound, history.count - 1) }
    for index in stride(from: min(upperBound, history.count - 1), through: 0, by: -1) {
      if history[index].contains(needle) { return index }
    }
    return nil
  }

  private func reverseSearchSelection(_ state: ReverseSearchState, original: [UInt8]) -> [UInt8] {
    guard let index = state.matchIndex else { return original }
    return Array(history[index].utf8)
  }

  private func redrawReverseSearch(_ state: ReverseSearchState, original: [UInt8]) {
    let mode = state.failed ? "failed reverse-i-search" : "reverse-i-search"
    let query = String(decoding: state.query, as: UTF8.self)
    let selection = reverseSearchSelection(state, original: original)
    redraw(
      prompt: "(\(mode))`\(query)': ",
      bytes: selection,
      cursor: selection.count)
  }

  /// Tab cycles matches; the menu highlights the text currently in the prompt.
  private func complete(
    prompt: String,
    bytes: inout [UInt8],
    cursor: inout Int,
    candidates: [String]
  ) {
    guard cursor == bytes.count, !bytes.contains(10) else {
      dismissCompletion()
      return
    }

    if let menu = completionMenu, !completionMatches.isEmpty {
      let applied = (menu.selected + 1) % completionMatches.count
      bytes = Array(completionMatches[applied].utf8)
      cursor = bytes.count
      completionMenu = CompletionMenu(
        options: menu.options,
        selected: applied)
      surface?.drawCompletionMenu(completionMenu)
      redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      return
    }

    let line = String(decoding: bytes, as: UTF8.self)
    let matches = Set(candidates.filter { $0.hasPrefix(line) }).sorted()
    guard !matches.isEmpty else {
      surface?.bell()
      return
    }
    if matches.count == 1 {
      let value = matches[0] + (matches[0].hasSuffix(" ") ? "" : " ")
      bytes = Array(value.utf8)
      cursor = bytes.count
      redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      return
    }

    let prefix = commonPrefix(matches)
    completionMatches = matches
    completionMenu = CompletionMenu(
      options: matches.map { String($0.dropFirst(prefix.count)) },
      selected: 0)
    bytes = Array(matches[0].utf8)
    cursor = bytes.count
    surface?.drawCompletionMenu(completionMenu)
    redraw(prompt: prompt, bytes: bytes, cursor: cursor)
  }

  /// Closes the rotating menu, leaving what is on the line. The status row
  /// returns to the REPL's own text.
  private func dismissCompletion() {
    guard completionMenu != nil || !completionMatches.isEmpty else { return }
    completionMenu = nil
    completionMatches = []
    surface?.drawCompletionMenu(nil)
  }

  /// True for the Tab byte, the only key that keeps a menu open.
  private func isTabKey(_ key: Key) -> Bool {
    if case .byte(9) = key { return true }
    return false
  }

  // MARK: - Drawing

  /// Draws the input, one row per line: the prompt heads the first visible
  /// row, the others are indented to it, and each row scrolls sideways on
  /// its own so the caret's line stays in view.
  private func redraw(prompt: String, bytes: [UInt8], cursor: Int) {
    // Leave the terminal's final column unused: printing into it can trigger an
    // automatic wrap, after which clearing one row no longer erases the input.
    let lineWidth = max(1, Self.terminalColumns() - 1)
    let minimumInputWidth = min(12, max(1, lineWidth / 2))
    let visiblePrompt = truncatedPrompt(prompt, maximumWidth: lineWidth - minimumInputWidth)
    let promptWidth = displayWidth(visiblePrompt)
    let inputWidth = max(1, lineWidth - promptWidth)
    let lines = lineRanges(in: bytes)
    let cursorLine = lines.firstIndex { cursor <= $0.upperBound } ?? lines.count - 1
    let maximumRows = max(1, surface?.maximumInputRows() ?? 1)
    if cursorLine < viewTop { viewTop = cursorLine }
    if cursorLine >= viewTop + maximumRows { viewTop = cursorLine - maximumRows + 1 }
    viewTop = max(0, min(viewTop, lines.count - maximumRows))
    let promptStyle = style(foreground: ui.promptForeground, background: ui.promptBackground)
    let inputStyle = style(foreground: ui.foreground, background: ui.background, bold: ui.bold)
    let hasInputBackground = Self.colorCode(ui.background, background: true) != nil
    let indent = String(repeating: " ", count: promptWidth)
    var rows: [String] = []
    var caretColumn = promptWidth
    for (offset, line) in lines[viewTop..<min(lines.count, viewTop + maximumRows)].enumerated() {
      let isCursorLine = viewTop + offset == cursorLine
      let visibleRange = visibleInputRange(
        in: bytes, line: line, cursor: isCursorLine ? cursor : line.lowerBound,
        maximumWidth: inputWidth)
      let visibleInput = renderable(bytes[visibleRange])
      let paddingWidth =
        hasInputBackground ? max(0, inputWidth - displayWidth(visibleInput)) : 0
      let padding = String(repeating: " ", count: paddingWidth)
      let head = offset == 0 ? promptStyle + visiblePrompt + resetStyle : indent
      rows.append(head + inputStyle + visibleInput + padding + resetStyle)
      if isCursorLine {
        caretColumn = promptWidth + displayWidth(bytes[visibleRange.lowerBound..<cursor])
      }
    }
    surface?.drawInput(rows: rows, caretRow: cursorLine - viewTop, caretColumn: caretColumn)
  }

  /// The prompt and text as they appear once accepted, for the surface to
  /// keep; further lines are indented to the prompt.
  func styledLine(prompt: String, text: String) -> String {
    let promptStyle = style(foreground: ui.promptForeground, background: ui.promptBackground)
    let inputStyle = style(foreground: ui.foreground, background: ui.background, bold: ui.bold)
    let indent = String(repeating: " ", count: displayWidth(prompt))
    let body = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { inputStyle + $0 + resetStyle }
      .joined(separator: "\n" + indent)
    return promptStyle + prompt + resetStyle + body
  }

  private func renderSubmittedLine(prompt: String, bytes: [UInt8]) {
    surface?.acceptInput(
      styled: styledLine(prompt: prompt, text: String(decoding: bytes, as: UTF8.self)))
  }

  private func drawSeparator(_ text: String?) {
    guard persistentSurface == nil,
      let background = Self.colorCode(ui.backgroundLine, background: true)
    else { return }
    let width = max(1, Self.terminalColumns() - 1)
    let content = truncatedPrompt(text.map { " \($0) " } ?? "", maximumWidth: width)
    let padding = String(repeating: " ", count: max(0, width - displayWidth(content)))
    surface?.drawSeparator(
      styled: "\u{1B}[\(background)m" + content + padding + resetStyle)
  }

  private var resetStyle: String { "\u{1B}[0m" }

  private func style(foreground: String, background: String, bold: Bool = false) -> String {
    var codes: [String] = []
    if bold { codes.append("1") }
    if let foreground = Self.colorCode(foreground, background: false) { codes.append(foreground) }
    if let background = Self.colorCode(background, background: true) { codes.append(background) }
    return codes.isEmpty ? "" : "\u{1B}[" + codes.joined(separator: ";") + "m"
  }

  private static func colorCode(_ rawValue: String, background: Bool) -> String? {
    let value = rawValue.lowercased()
    if value.hasPrefix("#"), value.count == 7 {
      let hex = String(value.dropFirst())
      guard hex.allSatisfy(\.isHexDigit), let packed = Int(hex, radix: 16) else { return nil }
      let red = (packed >> 16) & 0xFF
      let green = (packed >> 8) & 0xFF
      let blue = packed & 0xFF
      return "\(background ? 48 : 38);2;\(red);\(green);\(blue)"
    }
    if value.hasPrefix("rgb:"), value.count == 7 {
      let hex = String(value.dropFirst(4))
      guard hex.allSatisfy(\.isHexDigit), let packed = Int(hex, radix: 16) else { return nil }
      let red = ((packed >> 8) & 0xF) * 17
      let green = ((packed >> 4) & 0xF) * 17
      let blue = (packed & 0xF) * 17
      return "\(background ? 48 : 38);2;\(red);\(green);\(blue)"
    }
    let offset = background ? 10 : 0
    switch value {
    case "black": return "\(30 + offset)"
    case "red": return "\(31 + offset)"
    case "green": return "\(32 + offset)"
    case "yellow", "brown": return "\(33 + offset)"
    case "blue", "dark-blue": return "\(34 + offset)"
    case "magenta", "purple": return "\(35 + offset)"
    case "cyan": return "\(36 + offset)"
    case "white": return "\(37 + offset)"
    case "grey", "bright-black": return "\(90 + offset)"
    case "bright-red": return "\(91 + offset)"
    case "bright-green": return "\(92 + offset)"
    case "bright-yellow", "orange": return "\(93 + offset)"
    case "bright-blue": return "\(94 + offset)"
    case "bright-magenta", "violet", "pink": return "\(95 + offset)"
    case "bright-cyan": return "\(96 + offset)"
    case "bright-white": return "\(97 + offset)"
    default: return nil
    }
  }

  static func normalizedColor(_ rawValue: String) -> String? {
    let value = rawValue.lowercased()
    if ["none", "default", "off", "-"].contains(value) { return "" }
    return colorCode(value, background: false) == nil ? nil : value
  }

  static func foregroundColorCode(_ value: String) -> String? {
    colorCode(value, background: false)
  }

  static func backgroundColorCode(_ value: String) -> String? {
    colorCode(value, background: true)
  }

  static func terminalColumns() -> Int {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return 80 }
    return Int(size.ws_col)
  }

  static func terminalRows() -> Int {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_row > 0 else { return 24 }
    return Int(size.ws_row)
  }

  private func truncatedPrompt(_ prompt: String, maximumWidth: Int) -> String {
    guard maximumWidth > 0 else { return "" }
    guard displayWidth(prompt) > maximumWidth else { return prompt }
    guard maximumWidth > 2 else { return String(repeating: " ", count: maximumWidth) }
    let contentWidth = maximumWidth - 2
    var result = ""
    var width = 0
    for character in prompt {
      let characterWidth = displayWidth(String(character))
      guard width + characterWidth <= contentWidth else { break }
      result.append(character)
      width += characterWidth
    }
    return result + "… "
  }

  /// The part of one line that fits `maximumWidth` cells around the cursor:
  /// as much before it as possible, then as much after it as still fits.
  private func visibleInputRange(
    in bytes: [UInt8],
    line: Range<Int>,
    cursor: Int,
    maximumWidth: Int
  ) -> Range<Int> {
    let boundaries = characterBoundaries(in: bytes[line])
    let cursorIndex = boundaries.firstIndex { $0 >= cursor } ?? boundaries.count - 1
    var start = cursorIndex
    var end = cursorIndex
    var width = 0
    while start > 0 {
      let characterWidth = displayWidth(bytes[boundaries[start - 1]..<boundaries[start]])
      guard width + characterWidth <= maximumWidth else { break }
      start -= 1
      width += characterWidth
    }
    while end < boundaries.count - 1 {
      let characterWidth = displayWidth(bytes[boundaries[end]..<boundaries[end + 1]])
      guard width + characterWidth <= maximumWidth else { break }
      end += 1
      width += characterWidth
    }
    return boundaries[start]..<boundaries[end]
  }

  /// Input bytes as drawn: a tab takes one cell, shown as a space.
  private func renderable(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes.map { $0 == 9 ? 32 : $0 }, as: UTF8.self)
  }

  private func displayWidth(_ bytes: ArraySlice<UInt8>) -> Int {
    displayWidth(String(decoding: bytes, as: UTF8.self))
  }

  private func displayWidth(_ value: String) -> Int {
    Self.displayWidth(of: value)
  }

  /// Terminal columns a string occupies: wide and emoji characters take two,
  /// combining marks none.
  static func displayWidth(of value: String) -> Int {
    value.reduce(into: 0) { width, character in
      let scalars = character.unicodeScalars
      if scalars.allSatisfy({
        switch $0.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: true
        default: false
        }
      }) {
        return
      }
      let emojiPresentation =
        scalars.contains { $0.properties.isEmojiPresentation }
        || (scalars.contains { $0.value == 0xFE0F } && scalars.contains { $0.properties.isEmoji })
      width += emojiPresentation || scalars.contains { isWide($0.value) } ? 2 : 1
    }
  }

  private static func isWide(_ value: UInt32) -> Bool {
    switch value {
    case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
      0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
      0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
      true
    default:
      false
    }
  }

  // MARK: - Bytes

  private func readCharacter(startingWith first: UInt8) -> [UInt8] {
    let count: Int
    switch first {
    case 0xC0...0xDF: count = 2
    case 0xE0...0xEF: count = 3
    case 0xF0...0xF7: count = 4
    default: return [first]
    }
    var result = [first]
    while result.count < count, let byte = readByte() { result.append(byte) }
    return result
  }

  /// The next byte of input, from what the surface read ahead first; with a
  /// timeout, nil when nothing arrives in time.
  private func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
    if typeahead.isEmpty, let surface { typeahead = surface.pendingInput() }
    if !typeahead.isEmpty { return typeahead.removeFirst() }
    if let timeoutMilliseconds {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return nil }
    }
    var byte: UInt8 = 0
    return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
  }

  // MARK: - Lines

  /// The lines of the input, split at newlines, as ranges of its bytes.
  private func lineRanges(in bytes: [UInt8]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start = 0
    for (index, byte) in bytes.enumerated() where byte == 10 {
      ranges.append(start..<index)
      start = index + 1
    }
    ranges.append(start..<bytes.count)
    return ranges
  }

  /// Where the line holding `position` starts: just after the previous newline.
  private func lineStart(in bytes: [UInt8], at position: Int) -> Int {
    var index = position
    while index > 0, bytes[index - 1] != 10 { index -= 1 }
    return index
  }

  /// Where the line holding `position` ends: at the next newline or the end.
  private func lineEnd(in bytes: [UInt8], at position: Int) -> Int {
    var index = position
    while index < bytes.count, bytes[index] != 10 { index += 1 }
    return index
  }

  /// The position `column` cells into the line starting at `start`, or where
  /// that line ends when it is shorter.
  private func position(in bytes: [UInt8], lineStart start: Int, column: Int) -> Int {
    let boundaries = characterBoundaries(in: bytes[start..<lineEnd(in: bytes, at: start)])
    var index = 0
    var width = 0
    while index < boundaries.count - 1 {
      let characterWidth = displayWidth(bytes[boundaries[index]..<boundaries[index + 1]])
      guard width + characterWidth <= column else { break }
      index += 1
      width += characterWidth
    }
    return boundaries[index]
  }

  /// Moves the cursor to the same column one line up; false on the first line.
  private func moveUp(in bytes: [UInt8], cursor: inout Int) -> Bool {
    let start = lineStart(in: bytes, at: cursor)
    guard start > 0 else { return false }
    let column = displayWidth(bytes[start..<cursor])
    cursor = position(in: bytes, lineStart: lineStart(in: bytes, at: start - 1), column: column)
    return true
  }

  /// Moves the cursor to the same column one line down; false on the last line.
  private func moveDown(in bytes: [UInt8], cursor: inout Int) -> Bool {
    let end = lineEnd(in: bytes, at: cursor)
    guard end < bytes.count else { return false }
    let column = displayWidth(bytes[lineStart(in: bytes, at: cursor)..<cursor])
    cursor = position(in: bytes, lineStart: end + 1, column: column)
    return true
  }

  // MARK: - Characters

  private func previousCharacterStart(in bytes: [UInt8], before position: Int) -> Int {
    guard position > 0 else { return 0 }
    return characterBoundaries(in: bytes[...]).last(where: { $0 < position }) ?? 0
  }

  private func nextCharacterEnd(in bytes: [UInt8], after position: Int) -> Int {
    guard position < bytes.count else { return bytes.count }
    return characterBoundaries(in: bytes[...]).first(where: { $0 > position }) ?? bytes.count
  }

  /// Where the characters of a slice start and end, as indices of the array
  /// it comes from, first and last included.
  private func characterBoundaries(in bytes: ArraySlice<UInt8>) -> [Int] {
    var boundaries = [bytes.startIndex]
    var offset = bytes.startIndex
    for character in String(decoding: bytes, as: UTF8.self) {
      offset += character.utf8.count
      boundaries.append(min(offset, bytes.endIndex))
    }
    if boundaries.last != bytes.endIndex { boundaries.append(bytes.endIndex) }
    return boundaries
  }

  private func previousWordStart(in bytes: [UInt8], before position: Int) -> Int {
    var index = position
    while index > 0 {
      let previous = previousCharacterStart(in: bytes, before: index)
      guard isWhitespace(bytes[previous..<index]) else { break }
      index = previous
    }
    while index > 0 {
      let previous = previousCharacterStart(in: bytes, before: index)
      guard !isWhitespace(bytes[previous..<index]) else { break }
      index = previous
    }
    return index
  }

  private func isWhitespace(_ bytes: ArraySlice<UInt8>) -> Bool {
    String(decoding: bytes, as: UTF8.self).allSatisfy(\.isWhitespace)
  }

  private func commonPrefix(_ values: [String]) -> String {
    guard var prefix = values.first else { return "" }
    for value in values.dropFirst() {
      while !value.hasPrefix(prefix), !prefix.isEmpty { prefix.removeLast() }
    }
    return prefix
  }

  // MARK: - History

  private func remember(_ line: String) {
    guard !line.isEmpty else { return }
    if history.last != line { history.append(line) }
    if history.count > maximumHistory {
      history.removeFirst(history.count - maximumHistory)
    }
    guard let historyURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: historyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    } catch {
      // Input must remain usable even if history persistence is unavailable.
    }
  }

  private static func loadHistory(from url: URL?) -> [String] {
    guard let url, let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }
}
