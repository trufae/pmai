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
/// that never scroll: a question or thinking panel, a status line and the input,
/// one row per line being typed. Output is written at the region's saved cursor and the caret goes
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
  private var questionText: String?
  /// The active question takes precedence over the live thinking preview.
  private var panelRows: [String] = []
  private var thinkingText: String? {
    get { outputConversation.thinkingText }
    set { outputConversation.thinkingText = newValue }
  }
  private var thinkingDisplay: ThinkingDisplay {
    get { outputConversation.thinkingDisplay }
    set { outputConversation.thinkingDisplay = newValue }
  }
  private var paintedPanelRows: [String] = []
  private var paintedPanelOrigin = 0
  private var paintedPanelWidth = 0
  /// The input as drawn, one styled string per row below the status line.
  private var inputRows = [""]
  private var caretRow = 0
  private var caretColumn = 0
  private var outputEndedLine: Bool {
    get { outputConversation.outputEndedLine }
    set { outputConversation.outputEndedLine = newValue }
  }
  /// Retained in both modes so switching to buffer includes earlier output.
  private var conversations: [String: TerminalConversation] = [:]
  private var selectedConversation = "initial"
  private var processConversations: [AgentPID: String] = [:]
  private var markdownTemplate: MarkdownTerminalRenderer?
  private var outputConversation: TerminalConversation {
    let id = TerminalConversationScope.id ?? selectedConversation
    if let conversation = conversations[id] { return conversation }
    let conversation = TerminalConversation()
    conversation.transcript.configureThinking(ui.thinking)
    conversation.transcript.configureTools(ui.tools)
    conversation.transcript.configureToolGroups(ui.toolGroups)
    conversation.transcript.configureMarkdown(markdownTemplate)
    let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
      && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    conversation.transcript.configureColors(colors ? ui : nil)
    conversations[id] = conversation
    return conversation
  }
  private var isOutputVisible: Bool {
    ui.mode != .buffer || TerminalConversationScope.id == nil
      || TerminalConversationScope.id == selectedConversation
  }

  /// Hidden agents may still be watched in the view without replacing the prompt's output.
  private func prepareOutputDrawing() -> Bool {
    guard active else { return false }
    guard isOutputVisible else {
      if ui.mode == .buffer { drawViewRows(); placeCaret() }
      return false
    }
    return true
  }
  private var transcript: TerminalOutputBuffer {
    get { outputConversation.transcript }
    set { outputConversation.transcript = newValue }
    _modify {
      let conversation = outputConversation
      yield &conversation.transcript
    }
  }
  private var thinkingBlock: Int? {
    get { outputConversation.thinkingBlock }
    set { outputConversation.thinkingBlock = newValue }
  }
  private var replyBlock: Int? {
    get { outputConversation.replyBlock }
    set { outputConversation.replyBlock = newValue }
  }
  private var toolBlocks: [Int: Int] {
    get { outputConversation.toolBlocks }
    set { outputConversation.toolBlocks = newValue }
    _modify {
      let conversation = outputConversation
      yield &conversation.toolBlocks
    }
  }
  /// Tool handles remain unique across conversations and /clear.
  private var nextToolBlock = 0
  private var paintedOutputRows: [String] = []
  private var view: TerminalView?
  private var draggingViewSeparator = false
  private var paintedViewRows: [String] = []
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
  private static let enableDragMouse = "\u{1B}[?1002h"
  private static let disableDragMouse = "\u{1B}[?1002l"
  private static let disableMouse = "\u{1B}[?1002l\u{1B}[?1006l\u{1B}[?1000l"

  private var mouseTracking: String {
    Self.disableDragMouse + Self.enableMouse + (view == nil ? "" : Self.enableDragMouse)
  }

  /// Nil unless both stdin and stdout are terminals; piped sessions keep the
  /// plain one-line-at-a-time prompt.
  init?() {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return nil }
  }

  func configure(ui: ConfiguredTerminalUI) {
    lock.withLock {
      refreshSize()
      guard self.ui != ui else { return }
      let previousMode = self.ui.mode
      let previousUI = self.ui
      self.ui = ui
      if ui.mode != .buffer { view = nil; draggingViewSeparator = false }
      for conversation in conversations.values {
        conversation.transcript.configureThinking(ui.thinking)
        conversation.transcript.configureTools(ui.tools)
        conversation.transcript.configureToolGroups(ui.toolGroups)
        let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
          && ProcessInfo.processInfo.environment["TERM"] != "dumb"
        conversation.transcript.configureColors(colors ? ui : nil)
      }
      transcript.configureThinking(ui.thinking)
      transcript.configureTools(ui.tools)
      transcript.configureToolGroups(ui.toolGroups)
      let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        && ProcessInfo.processInfo.environment["TERM"] != "dumb"
      transcript.configureColors(colors ? ui : nil)
      guard active else { return }
      if ui.mode != previousMode {
        transcript.follow()
        if ui.mode == .buffer {
          write(Self.enterBuffer + mouseTracking)
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
      paintedPanelRows = []
      drawStatusRow()
      placeCaret()
    }
  }

  func bindConversation(_ id: String, to pid: AgentPID) {
    lock.withLock { processConversations[pid] = id }
  }

  func conversationID(for context: AgentEventContext) -> String? {
    lock.withLock {
      guard let pid = context.pid else { return nil }
      return processConversations[pid] ?? (context.depth > 0 ? "agent:\(pid.rawValue)" : nil)
    }
  }

  /// Seed resumed and newly forked threads once; subsequent switches retain
  /// their streaming blocks, command output and exact scroll position.
  func selectConversation(_ id: String, messages: [AgentMessage]) {
    lock.withLock {
      guard selectedConversation != id else { return }
      selectedConversation = id
      if let source = view?.source {
        switch source {
        case .current, .thinking, .tools, .diffs: view?.buffer.follow()
        default: break
        }
      }
      seedConversationLocked(id, messages: messages)
      layoutPanel()
      paintedPanelRows = []
      guard active, ui.mode == .buffer else { return }
      refreshSize()
      redrawBuffer()
    }
  }

  func seedConversation(_ id: String, messages: [AgentMessage]) {
    lock.withLock { seedConversationLocked(id, messages: messages) }
  }

  private func seedConversationLocked(_ id: String, messages: [AgentMessage]) {
    TerminalConversationScope.$id.withValue(id) {
      if conversations[id] == nil {
        var calls: [String: Int] = [:]
        for message in messages where message.role != .system {
          outputConversation.messageLines.append(
            (message.id, max(0, transcript.logicalLineCount - 1)))
          if message.role == .assistant {
            if !message.reasoning.isEmpty {
              let block = transcript.appendThinking(message.reasoning)
              transcript.finishThinking(block)
            }
            if !message.text.isEmpty {
              let block = transcript.appendReply(message.text)
              transcript.finishReply(block)
            }
            for call in message.toolCalls {
              calls[call.id] = transcript.appendTool(call: call, result: nil)
            }
          } else if !message.text.isEmpty {
            transcript.append("\(message.role == .user ? "you" : message.role.rawValue): \(message.text)\n")
          }
          for result in message.toolResults {
            transcript.appendTool(call: nil, result: result, to: calls.removeValue(forKey: result.callID))
          }
        }
      }
    }
  }

  func configureHistory(window: ChatHistoryWindow?, loader: @escaping @Sendable (Bool) -> Void) {
    lock.withLock {
      outputConversation.historyWindow = window
      outputConversation.historyLoader = window == nil ? nil : loader
    }
  }

  /// Replace a bounded transcript window, anchoring to a message shared by
  /// both windows. Disk I/O is done by the REPL event loop before this call.
  func replaceHistory(messages: [AgentMessage]) {
    lock.withLock {
      let old = outputConversation
      let anchor = old.transcript.readingAnchor
      let marker = anchor.flatMap { point in old.messageLines.last { $0.1 <= point.line } }
      let id = selectedConversation
      conversations[id] = nil
      seedConversationLocked(id, messages: messages)
      let current = outputConversation
      if let anchor, let marker,
        let line = current.messageLines.first(where: { $0.0 == marker.0 })?.1
      {
        current.transcript.restoreAnchor(line: line + anchor.line - marker.1, glyph: anchor.glyph)
      }
      current.historyWindow = old.historyWindow
      current.historyLoader = old.historyLoader
      if active, ui.mode == .buffer { redrawBuffer() }
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

  func setView(_ source: TerminalViewSource?, title: String = "") {
    lock.withLock {
      guard ui.mode == .buffer else { return }
      let label = title.components(separatedBy: .controlCharacters).joined(separator: " ")
      let height = view?.preferredHeight
      view = source.map { TerminalView(source: $0, title: label, preferredHeight: height) }
      draggingViewSeparator = false
      guard active else { return }
      refreshSize()
      write(mouseTracking)
      redrawBuffer()
    }
  }

  var viewHasFocus: Bool {
    lock.withLock { ui.mode == .buffer && view?.focused == true && viewHeight > 0 }
  }

  func closeView() { setView(nil) }

  func resizeView(lines: Int) {
    lock.withLock {
      guard active, ui.mode == .buffer, view != nil else { return }
      refreshSize()
      guard viewHeight > 0 else { return }
      let height = TerminalView.height(
        availableRows: regionBottom, preferredHeight: viewHeight + lines)
      guard height != viewHeight else { return }
      view?.preferredHeight = height
      redrawBuffer()
    }
  }

  func toggleViewFocus() -> Bool {
    lock.withLock {
      guard active, ui.mode == .buffer, view != nil, viewHeight > 0 else { return false }
      view?.focused.toggle()
      drawViewRows()
      placeCaret()
      return true
    }
  }

  func focusPrompt() {
    lock.withLock {
      guard view?.focused == true else { return }
      view?.focused = false
      guard active else { return }
      drawViewRows()
      placeCaret()
    }
  }

  func scrollView(lines: Int) {
    lock.withLock {
      guard active, ui.mode == .buffer, viewHeight > 0 else { return }
      refreshSize()
      updateViewBuffer()
      let height = viewHeight
      view?.buffer.scroll(lines: lines, width: max(1, columns - 1), height: height)
      drawViewRows()
      placeCaret()
    }
  }

  func handleMouse(_ event: TerminalMouseEvent) {
    lock.withLock {
      guard active, ui.mode == .buffer else { return }
      refreshSize()
      if case .press = event.action, event.row >= outputOrigin, event.row <= regionBottom,
        transcript.toggleToolGroup(row: event.row - outputOrigin)
      {
        drawOutputRows()
        placeCaret()
        return
      }
      guard viewHeight > 0 else { draggingViewSeparator = false; return }
      switch event.action {
      case .press:
        draggingViewSeparator = event.row == viewHeight + 1 && event.column <= columns
        return
      case .drag:
        guard draggingViewSeparator else { return }
      case .release:
        guard draggingViewSeparator else { return }
        draggingViewSeparator = false
      }
      let height = TerminalView.height(availableRows: regionBottom, preferredHeight: event.row - 1)
      guard height != viewHeight else { return }
      view?.preferredHeight = height
      redrawBuffer()
    }
  }

  /// Enters raw mode, reserves the bottom rows, and draws them. Call before the
  /// input thread starts reading: locating the cursor needs stdin for a moment.
  func activate() {
    lock.withLock { activateLocked() }
  }

  private func activateLocked(enterBuffer: Bool = true) {
    guard !active else { return }
    measure()
    var raw = termios()
    guard tcgetattr(STDIN_FILENO, &cooked) == 0 else { return }
    raw = cooked
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
    active = true
    paintedPanelRows = []
    clampInputRows()
    if ui.mode == .buffer {
      write(TerminalInputModes.enable + (enterBuffer ? Self.enterBuffer : "") + mouseTracking)
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

  /// Restore cooked input immediately, but keep the buffer visible until the
  /// command requests a handoff. Short commands can return without switching
  /// screens; interactive programs start with the correct tty settings.
  func suspendTerminal(deferBufferHandoff action: (_ handoff: () -> Void) -> Void) {
    lock.withLock {
      guard active, ui.mode == .buffer else {
        action({})
        return
      }
      deactivateLocked(leaveBuffer: false)
      var handedOff = false
      action {
        guard !handedOff else { return }
        write(Self.leaveBuffer)
        handedOff = true
      }
      activateLocked(enterBuffer: handedOff)
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

  private func deactivateLocked(leaveBuffer: Bool = true) {
    guard active else { return }
    draggingViewSeparator = false
    refreshSize()
    resizeSource?.cancel()
    resizeSource = nil
    activitySource?.cancel()
    activitySource = nil
    if ui.mode == .buffer {
      write(Self.disableMouse + (leaveBuffer ? Self.leaveBuffer : "") + TerminalInputModes.disable)
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
      guard ui.tools != display else { return }
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
      if ui.mode == .buffer, prepareOutputDrawing() {
        outputEndedLine = true
        drawOutputRows()
        placeCaret()
      }
      return handle
    }
  }

  func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    lock.withLock {
      markdownTemplate = renderer
      for conversation in conversations.values { conversation.transcript.configureMarkdown(renderer) }
      transcript.configureMarkdown(renderer)
      guard ui.mode == .buffer, prepareOutputDrawing() else { return }
      redrawBuffer()
    }
  }

  func writeReply(_ text: String, rendered: String) {
    lock.withLock {
      refreshSize()
      replyBlock = transcript.appendReply(text, to: replyBlock)
      guard prepareOutputDrawing() else { return }
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

  /// A command document is a separate completed block, so later reply deltas
  /// cannot be appended into its table or list.
  func writeMarkdown(_ text: String, rendered: String) {
    lock.withLock {
      refreshSize()
      let block = transcript.appendReply(text)
      transcript.finishReply(block)
      guard prepareOutputDrawing() else { return }
      if ui.mode == .buffer {
        drawOutputRows()
      } else {
        write(Self.restoreCursor + rendered + Self.saveCursor)
      }
      outputEndedLine = true
      placeCaret()
    }
  }

  func finishReply(rendered: String) {
    lock.withLock {
      guard let replyBlock else { return }
      transcript.finishReply(replyBlock)
      self.replyBlock = nil
      guard prepareOutputDrawing() else { return }
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
      guard prepareOutputDrawing() else { return }
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
      guard prepareOutputDrawing() else { return }
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
      guard ui.mode == .buffer, prepareOutputDrawing() else { return }
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
      guard prepareOutputDrawing() else { return }
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
  func setStatus(
    _ text: String, animating: Bool = false, attention: Bool = false, question: String? = nil,
    waiting: Bool? = nil
  ) {
    setStatus(
      text, animating: animating, style: nil, attention: attention, question: question, waiting: waiting)
  }

  /// Replaces the status line and optionally switches the Braille animation style.
  func setStatus(
    _ text: String, animating: Bool, style: BrailleAnimator.Style?, attention: Bool = false,
    question: String? = nil, waiting: Bool? = nil
  ) {
    lock.withLock {
      refreshSize()
      let questionChanged = questionText != question
      if questionChanged {
        let previousCount = inputRows.count + panelRows.count
        questionText = question
        clampInputRows()
        if active {
          resizeRegion(inputRows: previousCount, to: inputRows.count + panelRows.count)
          paintedPanelRows = []
          drawInputRows()
        }
      }
      let attentionChanged = statusNeedsAttention != attention
      statusNeedsAttention = attention
      let animationChanged = animatingStatus != animating
      animatingStatus = animating
      activityRestarted = animationChanged && animating
      let isWaiting = waiting ?? animating
      let waitingChanged = isWaiting != (activityStartedAt != nil)
      if waitingChanged {
        activityStartedAt = isWaiting ? DispatchTime.now().uptimeNanoseconds : nil
        displayedActivitySecond = 0
      }
      if animationChanged {
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
      guard text != statusText || animationChanged || waitingChanged || activityRestarted || attentionChanged || questionChanged
      else { return }
      statusText = text
      activityRestarted = false
      // A tab-completion menu owns the row until it closes; the status is
      // still kept so the row can be restored when it does.
      guard active else { return }
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
      let previousRows = panelRows
      thinkingText = text
      thinkingDisplay = display
      guard isOutputVisible, questionText == nil else { return }
      layoutPanel()
      guard panelRows != previousRows else { return }
      guard active else { return }
      if panelRows.count != previousRows.count {
        resizeRegion(
          inputRows: inputRows.count + previousRows.count,
          to: inputRows.count + panelRows.count)
        drawStatusRow()
        drawInputRows()
      } else {
        drawPanelRows()
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
    max(1, min(rows / 2, rows - 5, rows - 2 - panelRows.count))
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
          inputRows: previousCount + panelRows.count, to: inputRows.count + panelRows.count)
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
        resizeRegion(inputRows: previousCount + panelRows.count, to: 1 + panelRows.count)
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
      paintedPanelRows = []
      drawStatusRow()
      drawInputRows()
      placeCaret()
    }
  }

  func emit(_ text: String) {
    write(text, to: .standardOutput)
  }

  func scrollOutput(wheel: Int, pages: Int) {
    let loader: (@Sendable (Bool) -> Void)? = lock.withLock {
      outputConversation.historyLoader
    }
    var loadEarlier: Bool?
    lock.withLock {
      guard active, ui.mode == .buffer else { return }
      refreshSize()
      if view?.focused == true, viewHeight > 0 {
        updateViewBuffer()
        let height = viewHeight
        view?.buffer.scroll(
          lines: wheel * max(1, ui.scroll) + pages * max(1, height - 1),
          width: max(1, columns - 1), height: height)
      } else {
        TerminalConversationScope.$id.withValue(nil) {
          transcript.scroll(
            lines: wheel * max(1, ui.scroll) + pages * max(1, outputHeight - 1),
            width: max(1, columns - 1), height: outputHeight)
        }
      }
      let conversation = outputConversation
      if view?.focused != true, let window = conversation.historyWindow {
        if wheel + pages < 0, transcript.isAtBeginning, window.hasEarlier { loadEarlier = true }
        if wheel + pages > 0, transcript.isFollowing, window.hasLater { loadEarlier = false }
      }
      drawOutputRows()
      drawStatusRow()
      placeCaret()
    }
    if let loadEarlier { loader?(loadEarlier) }
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

  /// The pinned question or thinking preview, status row, and input rows.
  private var reservedRows: Int { 1 + panelRows.count + inputRows.count }

  private var regionBottom: Int { max(1, rows - reservedRows) }

  private var viewHeight: Int {
    ui.mode == .buffer && view != nil
      ? TerminalView.height(availableRows: regionBottom, preferredHeight: view?.preferredHeight) : 0
  }

  private var outputOrigin: Int { viewHeight > 0 ? viewHeight + 2 : 1 }
  private var outputHeight: Int { regionBottom - outputOrigin + 1 }

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
      paintedViewRows = []
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
    drawPanelRows()
    drawStatusLine()
  }

  private func redrawBuffer() {
    paintedOutputRows = []
    paintedViewRows = []
    paintedPanelRows = []
    write("\u{1B}[1;\(regionBottom)r")
    drawOutputRows()
    drawStatusRow()
    drawInputRows()
    placeCaret()
  }

  private func drawOutputRows() {
    drawViewRows()
    var visible = TerminalConversationScope.$id.withValue(nil) {
      transcript.visibleRows(width: max(1, columns - 1), height: outputHeight)
    }
    visible += Array(repeating: "", count: max(0, outputHeight - visible.count))
    var out = ""
    for (index, text) in visible.enumerated() {
      if index < paintedOutputRows.count, paintedOutputRows[index] == text { continue }
      out += move(row: outputOrigin + index, column: 1) + Self.reset + Self.clearLine + text + Self.reset
    }
    paintedOutputRows = visible
    writeFixedRows(out)
  }

  private func updateViewBuffer() {
    guard let source = view?.source else { return }
    if source == .conversations {
      var combined = TerminalOutputBuffer()
      for id in conversations.keys.sorted() where id != "initial" {
        combined.append("── \(id) ──\n")
        var buffer = conversations[id]!.transcript
        buffer.follow()
        // Copy rendered rows through the same parser that strips terminal controls.
        combined.append(buffer.visibleRows(width: max(1, columns - 1), height: Int.max).joined(separator: "\n"))
        combined.append("\n")
      }
      view?.buffer.updateView(from: combined, selection: .all)
    } else {
      let id: String
      if case .conversation(let watched) = source { id = watched }
      else { id = selectedConversation }
      view?.buffer.updateView(
        from: conversations[id]?.transcript ?? TerminalOutputBuffer(), selection: source.selection)
    }
  }

  private func drawViewRows() {
    let height = viewHeight
    guard height > 0 else { view?.focused = false; draggingViewSeparator = false; return }
    updateViewBuffer()
    let width = max(1, columns - 1)
    var visible = view?.buffer.visibleRows(width: width, height: height) ?? []
    if visible.isEmpty { visible = ["No matching output yet."] }
    visible += Array(repeating: "", count: max(0, height - visible.count))
    let focus = view?.focused == true
      ? "view focused · j/k scroll · J/K page · g/G top/bottom · v/V resize · q close · Tab prompt"
      : "Tab on empty prompt to focus"
    let label = "── view: \(view?.title ?? "") · \(focus) · drag to resize ──"
    let text = Self.truncated(label, width: width)
    let padded = text + String(repeating: " ", count: max(0, width - Self.displayWidth(text)))
    let background = TerminalLineEditor.backgroundColorCode(ui.backgroundLine)
    let foreground = TerminalLineEditor.foregroundColorCode(ui.foreground)
    let emphasis = view?.focused == true ? "1" : nil
    let codes = background == nil ? [view?.focused == true ? "7" : "2"]
      : [background, foreground, emphasis].compactMap { $0 }
    visible.append("\u{1B}[" + codes.joined(separator: ";") + "m" + padded + Self.reset)
    var out = ""
    for (index, text) in visible.enumerated() {
      if index < paintedViewRows.count, paintedViewRows[index] == text { continue }
      out += move(row: index + 1, column: 1) + Self.reset + Self.clearLine + text + Self.reset
    }
    paintedViewRows = visible
    writeFixedRows(out)
  }

  private func drawPanelRows() {
    let width = max(1, columns - 1)
    let origin = regionBottom + 1
    if origin != paintedPanelOrigin || width != paintedPanelWidth {
      paintedPanelRows = []
    }
    var out = ""
    var painted: [String] = []
    let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    for (index, line) in panelRows.enumerated() {
      let content = Self.truncated(line, width: width)
      let padded =
        content + String(repeating: " ", count: max(0, width - Self.displayWidth(content)))
      painted.append(padded)
      let previous = index < paintedPanelRows.count ? paintedPanelRows[index] : ""
      guard previous != padded else { continue }
      let prefix = zip(previous, padded).prefix { $0 == $1 }.count
      let suffix = zip(previous.dropFirst(prefix).reversed(), padded.dropFirst(prefix).reversed())
        .prefix { $0 == $1 }.count
      let column = Self.displayWidth(String(padded.prefix(prefix))) + 1
      out += move(row: origin + index, column: column) + Self.reset
      if questionText != nil {
        let codes = colors ? [
          TerminalLineEditor.foregroundColorCode(ui.selectionForeground),
          TerminalLineEditor.backgroundColorCode(ui.selectionBackground),
        ].compactMap { $0 } : []
        out += "\u{1B}[" + (codes.isEmpty ? "7" : codes.joined(separator: ";")) + "m"
      } else if colors {
        let code = TerminalLineEditor.foregroundColorCode(ui.thinkingForeground)
        out += "\u{1B}[3" + (code.map { ";" + $0 } ?? "") + "m"
      }
      // Overwrite only the changed span. Padding removes stale glyphs without
      // clearing a visible row before its replacement reaches the terminal.
      out += padded.dropFirst(prefix).dropLast(suffix) + Self.reset
      if previous.isEmpty { out += "\u{1B}[K" }
    }
    paintedPanelRows = painted
    paintedPanelOrigin = origin
    paintedPanelWidth = width
    writeFixedRows(out)
  }

  private func drawStatusLine(clear: Bool = true) {
    let width = max(1, columns - 1)
    let status: String
    let timer: String
    if let activityStartedAt {
      let elapsed = (DispatchTime.now().uptimeNanoseconds - activityStartedAt) / 1_000_000_000
      status = animatingStatus ? animator.next() + String(statusText.dropFirst()) : statusText
      timer = " \(elapsed / 60)m\(elapsed % 60)s "
      displayedActivitySecond = elapsed
    } else {
      status = statusText
      timer = ""
    }
    let scrollHint = ui.mode == .buffer && !transcript.isFollowing ? "↑ scroll · PgDn to latest · " : ""
    let right = Self.truncated(timer, width: width)
    let left = Self.truncated(" \(scrollHint)\(status) ", width: max(0, width - Self.displayWidth(right)))
    let content = left + String(repeating: " ", count: max(0,
      width - Self.displayWidth(left) - Self.displayWidth(right))) + right
    let colors = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    var out = ""
    out += move(row: regionBottom + panelRows.count + 1, column: 1)
    if clear { out += Self.clearLine }
    if let menu = completionMenu {
      out += completionMenuRow(menu, width: width, colors: colors)
    } else if statusNeedsAttention {
      let warning = colors ? TerminalLineEditor.foregroundColorCode(ui.warningForeground) : nil
      let codes = ["1", "7"] + [warning].compactMap { $0 }
      out += "\u{1B}[" + codes.joined(separator: ";") + "m" + content + Self.reset
    } else if let background = TerminalLineEditor.backgroundColorCode(ui.backgroundLine) {
      out += "\u{1B}[\(background)m" + content + Self.reset
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
    guard active, activityStartedAt != nil else {
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
      guard active, let activityStartedAt, completionMenu == nil,
        columns > 2
      else { return }
      activityFrame = (activityFrame + 1) % 10
      let elapsed = (DispatchTime.now().uptimeNanoseconds - activityStartedAt) / 1_000_000_000
      if elapsed != displayedActivitySecond {
        if ui.mode == .buffer, ui.toolGroups, transcript.hasRunningTools {
          transcript.refreshToolGroupTimes()
          drawOutputRows()
        }
        drawStatusLine(clear: false)
        placeCaret()
        return
      }
      guard animatingStatus else { return }
      let marker = animator.next()
      let style = TerminalLineEditor.backgroundColorCode(ui.backgroundLine) ?? "2"
      let scrollHintWidth = ui.mode == .buffer && !transcript.isFollowing
        ? Self.displayWidth("↑ scroll · PgDn to latest · ") : 0
      let timerWidth = Self.displayWidth(" \(elapsed / 60)m\(elapsed % 60)s ")
      guard 2 + scrollHintWidth < columns - timerWidth else { return }
      writeFixedRows(
        move(row: regionBottom + panelRows.count + 1, column: 2 + scrollHintWidth)
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
    if view?.focused == true, viewHeight > 0 {
      write(move(row: viewHeight + 1, column: 1))
      return
    }
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
    layoutPanel()
    let maximum = maximumInputRowsLocked
    guard inputRows.count > maximum else { return }
    inputRows = Array(inputRows.suffix(maximum))
    caretRow = min(caretRow, maximum - 1)
  }

  private func layoutPanel() {
    if let questionText {
      panelRows = REPLModalPrompt.questionRows(
        questionText, width: max(1, columns - 1), height: max(0, min(rows / 2, rows - 3)))
      return
    }
    guard let thinkingText else {
      panelRows = []
      return
    }
    let count = min(thinkingDisplay.lineCount, rows / 4)
    guard count > 0 else {
      panelRows = []
      return
    }
    panelRows =
      thinkingDisplay == .status
      ? ["Thinking…"]
      : ThinkingPreview.carouselLines(
        thinkingText, count: count, width: max(1, columns - 1), measure: Self.displayWidth)
    panelRows += Array(repeating: "", count: max(0, count - panelRows.count))
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
    TerminalConversationScope.$id.withValue(nil) { refreshVisibleSize() }
  }

  private func refreshVisibleSize() {
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
    paintedPanelRows = []
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
