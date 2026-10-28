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
  private let colorsEnabled: Bool
  private let bufferColorsEnabled: Bool
  private var voiceStatus: String?
  private var voiceConversation: String?
  private var voiceParentConversation: String?
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
  private var cursorHidden = false
  private var outputEndedLine: Bool {
    get { outputConversation.outputEndedLine }
    set { outputConversation.outputEndedLine = newValue }
  }
  /// Retained in both modes so switching to buffer includes earlier output.
  private var conversations: [String: TerminalConversation] = [:]
  private var archivedConversations: Set<String> = []
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
    conversation.transcript.configureColors(bufferColorsEnabled ? ui : nil)
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
      if ui.mode == .buffer, let source = view?.source {
        if source == .conversations {
          requestScrollDraw()
        } else if source == .voice, voiceConversation == TerminalConversationScope.id {
          requestScrollDraw()
        } else if case .conversation(let watched) = source,
          watched == TerminalConversationScope.id {
          requestScrollDraw()
        }
      }
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
    get {
      if let owner = TerminalConversationScope.replyOwner {
        return outputConversation.auxiliaryReplyBlocks[owner]
      }
      return outputConversation.replyBlock
    }
    set {
      if let owner = TerminalConversationScope.replyOwner {
        outputConversation.auxiliaryReplyBlocks[owner] = newValue
      } else { outputConversation.replyBlock = newValue }
    }
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
  private var lastOutputDraw: UInt64 = 0
  private var scrollDrawScheduled = false
  private var scrollDrawGeneration: UInt64 = 0
  private var outputBatch: String?
  private var view: TerminalView?
  private var aggregateSections: [String: (Int, TerminalOutputBuffer.Version)] = [:]
  private var aggregateOrder: [String] = []
  private var viewTask: Task<Void, Never>?
  private var viewDiffDirectory: URL?
  private var viewGeneration = UUID()
  private var viewPromptOperation: (@Sendable (String) async throws -> String)?
  private var viewPromptReply: (conversation: String, id: String, text: String)?
  private var viewSearching = false
  private var draggingViewSeparator = false
  private var scrollbarDrag: (view: Bool, grab: Int, row: Int)?
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
  private static let disableMouse = "\u{1B}[?1002l\u{1B}[?1006l\u{1B}[?1000l"

  private var mouseTracking: String {
    Self.enableMouse + Self.enableDragMouse
  }

  /// Nil unless both stdin and stdout are terminals; piped sessions keep the
  /// plain one-line-at-a-time prompt.
  init?() {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return nil }
    let environment = ProcessInfo.processInfo.environment
    colorsEnabled = environment["NO_COLOR"] == nil
    bufferColorsEnabled = colorsEnabled && environment["TERM"] != "dumb"
  }

  func configure(ui: ConfiguredTerminalUI) {
    lock.withLock {
      refreshSize()
      guard self.ui != ui else { return }
      let highlightChanged = self.ui.highlight != ui.highlight
      let previousMode = self.ui.mode
      let previousUI = self.ui
      self.ui = ui
      if ui.scrollbar != previousUI.scrollbar { scrollbarDrag = nil }
      if ui.mode != .buffer {
        view = nil
        stopViewTask()
        viewPromptOperation = nil
        viewPromptReply = nil
        draggingViewSeparator = false
        scrollbarDrag = nil
      }
      for conversation in conversations.values {
        conversation.transcript.configureThinking(ui.thinking)
        conversation.transcript.configureTools(ui.tools)
        conversation.transcript.configureToolGroups(ui.toolGroups)
        conversation.transcript.configureColors(bufferColorsEnabled ? ui : nil)
      }
      transcript.configureThinking(ui.thinking)
      transcript.configureTools(ui.tools)
      transcript.configureToolGroups(ui.toolGroups)
      transcript.configureColors(bufferColorsEnabled ? ui : nil)
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
        if highlightChanged { highlightFirstHit() }
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

  func activateConversation(_ id: String) {
    lock.withLock { archivedConversations.remove(id) }
  }

  func releaseConversation(for pid: AgentPID, removing: Bool) {
    lock.withLock {
      let id = processConversations[pid] ?? "agent:\(pid.rawValue)"
      archivedConversations.insert(id)
      if removing {
        processConversations[pid] = nil
        conversations[id] = nil
        archivedConversations.remove(id)
        if selectedConversation == id { selectedConversation = "initial" }
      } else {
        evictArchivedConversations()
      }
    }
  }

  private func evictArchivedConversations() {
    guard view?.source != .conversations else { return }
    for id in archivedConversations where id != selectedConversation {
      if id == voiceConversation { continue }
      if view?.source == .conversation(id) { continue }
      // A deliberately anchored reading position stays pinned until released.
      if conversations[id]?.transcript.isFollowing == true { conversations[id] = nil }
    }
  }

  func conversationID(for context: AgentEventContext) -> String? {
    lock.withLock {
      guard let pid = context.pid else { return nil }
      return processConversations[pid] ?? (context.depth > 0 ? "agent:\(pid.rawValue)" : nil)
    }
  }

  /// Seed resumed and newly forked threads once; subsequent switches retain
  /// their streaming blocks, command output and exact scroll position.
  func selectConversation(
    _ id: String, messages: [AgentMessage], window: ChatHistoryWindow? = nil
  ) {
    lock.withLock {
      guard selectedConversation != id else { return }
      selectedConversation = id
      evictArchivedConversations()
      scrollbarDrag = nil
      if let source = view?.source {
        switch source {
        case .current, .pins, .log, .iconlog, .thinking, .tools: view?.buffer.follow()
        default: break
        }
      }
      let isNew = conversations[id] == nil
      seedConversationLocked(id, messages: messages)
      if isNew { outputConversation.historyWindow = window }
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

  var historyWindow: ChatHistoryWindow? {
    lock.withLock { conversations[selectedConversation]?.historyWindow }
  }

  func configureHistory(
    window: ChatHistoryWindow?, totalCount: Int, loader: @escaping @Sendable (Bool) -> Void
  ) {
    lock.withLock {
      let conversation = outputConversation
      if var window {
        // Releasing inference context to disk must not change the page being
        // read, or discard command output and replies retained on the screen.
        let previous = conversation.historyWindow
        let lower = min(previous?.range.lowerBound ?? 0, window.totalCount)
        let upper: Int
        if let previous, previous.hasLater {
          upper = min(previous.range.upperBound, window.totalCount)
        } else {
          upper = window.totalCount
        }
        window.range = lower..<max(lower, upper)
        conversation.historyWindow = window
      } else if let previous = conversation.historyWindow, totalCount < previous.totalCount {
        conversation.historyWindow = nil
      }
      conversation.historyLoader = conversation.historyWindow == nil ? nil : loader
    }
  }

  /// Replace a bounded transcript window, anchoring to a message shared by
  /// both windows. Disk I/O is done by the REPL event loop before this call.
  func replaceHistory(messages: [AgentMessage], window: ChatHistoryWindow?) {
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
      current.historyWindow = window
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

  var viewNeedsMessages: Bool {
    lock.withLock { view?.needsMessages == true }
  }

  var viewNeedsTodo: Bool {
    lock.withLock { view?.source == .todo }
  }

  func updateViewTodo(_ text: String) {
    lock.withLock {
      view?.updateTodo(text)
      if active, ui.mode == .buffer { drawViewRows(); placeCaret() }
    }
  }

  func updateViewMessages(_ messages: [AgentMessage]) {
    lock.withLock {
      view?.updateMessages(messages)
      if active, ui.mode == .buffer { drawViewRows(); placeCaret() }
    }
  }

  var viewNeedsHistory: Bool { lock.withLock { view?.source == .history } }

  func updateViewHistory(_ text: String) {
    lock.withLock {
      guard view?.source == .history else { return }
      view?.updateText(text)
      if active, ui.mode == .buffer { drawViewRows(); placeCaret() }
    }
  }

  /// Cancel and invalidate before replacing a view, including a same-source reopen.
  private func stopViewTask() {
    viewTask?.cancel()
    viewTask = nil
    viewGeneration = UUID()
  }

  func watchViewDiffs(in directory: URL) {
    lock.withLock { watchViewDiffsLocked(in: directory) }
  }

  private func watchViewDiffsLocked(in directory: URL) {
    guard active, view?.source == .diffs else { return }
    guard viewTask == nil || viewDiffDirectory != directory else { return }
    stopViewTask()
    viewDiffDirectory = directory
    let generation = viewGeneration
    viewTask = Task.detached(priority: .utility) { [weak self] in
      while !Task.isCancelled {
        let text = await TerminalGitDiff.text(in: directory)
        guard !Task.isCancelled else { return }
        self?.updateViewDiff(text, generation: generation)
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
      }
    }
  }

  var viewNeedsPrompt: Bool { lock.withLock { view?.source == .prompt } }

  func runViewPrompt(title: String, operation: @escaping @Sendable (String) async throws -> String) {
    setView(.prompt, title: title)
    lock.withLock {
      guard view?.source == .prompt else { return }
      viewPromptOperation = operation
      view?.updateText("Waiting for a completed reply…")
      if active, ui.mode == .buffer { drawViewRows(); placeCaret() }
    }
  }

  /// Called with the selected conversation's transcript after its turn settles.
  /// Message identity ensures identical replies in separate turns still run the prompt.
  func updateViewPrompt(_ messages: [AgentMessage]) {
    lock.withLock {
      guard view?.source == .prompt, let operation = viewPromptOperation,
        let reply = try? TranscriptCopy.text(for: .lastAssistantReply, in: messages),
        let message = reply.messages.first else { return }
      if let previous = viewPromptReply,
        previous.conversation == selectedConversation, previous.id == message.id,
        previous.text == reply.text { return }
      stopViewTask()
      viewPromptReply = (selectedConversation, message.id, reply.text)
      let generation = viewGeneration
      view?.updateText("Running prompt…")
      viewTask = Task { [weak self] in
        let text: String
        do { text = try await operation(reply.text) }
        catch { text = "Prompt failed: \(error.localizedDescription)" }
        guard !Task.isCancelled else { return }
        self?.updateViewText(text, source: .prompt, generation: generation)
      }
      if active, ui.mode == .buffer { drawViewRows(); placeCaret() }
    }
  }

  private func updateViewDiff(_ text: String, generation: UUID) {
    updateViewText(text, source: .diffs, generation: generation)
  }

  private func updateViewText(_ text: String, source: TerminalViewSource, generation: UUID) {
    lock.withLock {
      guard generation == viewGeneration, view?.source == source else { return }
      view?.updateText(text)
      if active, ui.mode == .buffer { drawViewRows(); placeCaret() }
    }
  }

  func setView(_ source: TerminalViewSource?, title: String = "") {
    lock.withLock {
      guard ui.mode == .buffer else { return }
      let label = title.components(separatedBy: .controlCharacters).joined(separator: " ")
      stopViewTask()
      viewPromptOperation = nil
      viewPromptReply = nil
      aggregateSections = [:]
      aggregateOrder = []
      let previous = view
      view = source.map {
        TerminalView(source: $0, title: label, preferredHeight: previous?.preferredHeight,
          preferredWidth: previous?.preferredWidth, vertical: previous?.vertical ?? false,
          fullscreen: previous?.fullscreen ?? false, markdown: markdownTemplate)
      }
      evictArchivedConversations()
      draggingViewSeparator = false
      scrollbarDrag = nil
      clampInputRows()
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
      guard view?.fullscreen != true else { return }
      if isVerticalView {
        let width = max(1, min(columns - 2, viewColumns + lines))
        view?.preferredWidth = width
      } else {
        let height = TerminalView.height(
          availableRows: regionBottom, preferredHeight: viewHeight + lines)
        view?.preferredHeight = height
      }
      redrawBuffer()
    }
  }

  func setViewSearching(_ searching: Bool) {
    lock.withLock {
      viewSearching = searching
      placeCaret()
    }
  }

  func toggleViewLayout() {
    lock.withLock {
      guard view != nil else { return }
      view?.vertical.toggle()
      draggingViewSeparator = false
      scrollbarDrag = nil
      redrawBuffer()
    }
  }

  func toggleViewFullscreen() {
    lock.withLock {
      guard view != nil else { return }
      view?.fullscreen.toggle()
      draggingViewSeparator = false
      scrollbarDrag = nil
      redrawBuffer()
    }
  }

  /// Setting changes apply to every pane; only the focused pane jumps to its first hit.
  private func highlightFirstHit() {
    TerminalConversationScope.$id.withValue(nil) {
      transcript.configureHighlight(ui.highlight)
      updateViewBuffer()
      view?.buffer.configureHighlight(ui.highlight)
      if view?.focused == true, viewHeight > 0 {
        let width = paneContentWidth(inView: true)
        _ = view?.buffer.scrollToFirstHighlight(width: width)
      } else {
        _ = transcript.scrollToFirstHighlight(width: paneContentWidth(inView: false))
      }
    }
  }

  func scrollToHighlight() {
    lock.withLock {
      guard active, ui.mode == .buffer else { return }
      refreshSize()
      highlightFirstHit()
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
      let height = viewContentHeight
      let width = paneContentWidth(inView: true)
      view?.buffer.scroll(lines: lines, width: width, height: height)
      drawViewRows()
      placeCaret()
    }
  }

  func handleMouse(_ event: TerminalMouseEvent) {
    var historyRequest: (loader: @Sendable (Bool) -> Void, earlier: Bool)?
    lock.withLock {
      guard active, ui.mode == .buffer else { return }
      refreshSize()
      // Mouse hit-testing must use the viewport after any queued wheel reports.
      if scrollDrawScheduled { drawScrollFrame() }
      let targetsView = scrollbarDrag?.view ?? isInView(event)
      if handleScrollbarMouse(event) {
        if !targetsView, let conversation = conversations[selectedConversation],
          let window = conversation.historyWindow, let loader = conversation.historyLoader
        {
          if event.row <= outputOrigin, conversation.transcript.isAtBeginning, window.hasEarlier {
            historyRequest = (loader, true)
          } else if event.row >= regionBottom, conversation.transcript.isFollowing, window.hasLater
          {
            historyRequest = (loader, false)
          }
        }
        return
      }
      let outputWidth = paneContentWidth(inView: false)
      let contentColumn = outputColumn + (ui.scrollbar < 0 ? outputColumns - outputWidth : 0)
      if case .press = event.action, outputHeight > 0,
        event.column >= contentColumn,
        event.column < contentColumn + outputWidth,
        event.row >= outputOrigin, event.row < outputOrigin + outputHeight,
        transcript.toggleToolGroup(row: event.row - outputOrigin)
      {
        drawOutputRows()
        placeCaret()
        return
      }
      guard viewHeight > 0, view?.fullscreen != true else { draggingViewSeparator = false; return }
      switch event.action {
      case .press:
        draggingViewSeparator = isVerticalView
          ? event.column == viewColumn - 1 && event.row <= regionBottom
          : event.row == viewHeight + 1 && event.column <= columns
        return
      case .drag:
        guard draggingViewSeparator else { return }
      case .release:
        guard draggingViewSeparator else { return }
        draggingViewSeparator = false
      }
      if isVerticalView {
        view?.preferredWidth = max(1, min(columns - 2, columns - event.column))
      } else {
        view?.preferredHeight = TerminalView.height(
          availableRows: regionBottom, preferredHeight: event.row - 1)
      }
      redrawBuffer()
    }
    if let historyRequest { historyRequest.loader(historyRequest.earlier) }
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
    if let directory = viewDiffDirectory { watchViewDiffsLocked(in: directory) }
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
    lock.withLock { stopViewTask(); deactivateLocked() }
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
    scrollDrawScheduled = false
    scrollDrawGeneration &+= 1
    draggingViewSeparator = false
    scrollbarDrag = nil
    refreshSize()
    setCursorHidden(false)
    if view?.source == .diffs { stopViewTask() }
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
        requestScrollDraw()
        if ui.mode != .buffer { placeCaret() }
      }
      return handle
    }
  }

  func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    lock.withLock {
      markdownTemplate = renderer
      for conversation in conversations.values { conversation.transcript.configureMarkdown(renderer) }
      transcript.configureMarkdown(renderer)
      view?.configureMarkdown(renderer)
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
        requestScrollDraw()
      } else if !rendered.isEmpty {
        write(Self.restoreCursor + rendered + Self.saveCursor)
        outputEndedLine = rendered.hasSuffix("\n")
      }
      if ui.mode != .buffer { placeCaret() }
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
        requestScrollDraw()
      } else {
        write(Self.restoreCursor + rendered + Self.saveCursor)
      }
      outputEndedLine = true
      if ui.mode != .buffer { placeCaret() }
    }
  }

  func finishReply(rendered: String) {
    lock.withLock {
      guard let replyBlock else { return }
      transcript.finishReply(replyBlock)
      self.replyBlock = nil
      guard prepareOutputDrawing() else { return }
      if ui.mode == .buffer {
        requestScrollDraw()
      } else if !rendered.isEmpty {
        write(Self.restoreCursor + rendered + Self.saveCursor)
        outputEndedLine = rendered.hasSuffix("\n")
      }
      if ui.mode != .buffer { placeCaret() }
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
        requestScrollDraw()
      } else if full {
        write(Self.restoreCursor + text + Self.saveCursor)
        outputEndedLine = text.hasSuffix("\n")
      }
      if ui.mode != .buffer { placeCaret() }
    }
  }

  func finishThinking() {
    lock.withLock {
      guard let thinkingBlock else { return }
      transcript.finishThinking(thinkingBlock)
      self.thinkingBlock = nil
      guard prepareOutputDrawing() else { return }
      if ui.mode == .buffer {
        requestScrollDraw()
      } else if !outputEndedLine {
        write(Self.restoreCursor + "\n" + Self.saveCursor)
        outputEndedLine = true
      }
      if ui.mode != .buffer { placeCaret() }
    }
  }

  func appendThinkingBlock(_ text: String) {
    lock.withLock {
      refreshSize()
      let block = transcript.appendThinking(text)
      transcript.finishThinking(block)
      guard ui.mode == .buffer, prepareOutputDrawing() else { return }
      requestScrollDraw()
      if ui.mode != .buffer { placeCaret() }
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

  func setVoiceConversation(_ id: String, parent: String) {
    lock.withLock {
      voiceConversation = id
      voiceParentConversation = parent
      seedConversationLocked(id, messages: [])
      if active, ui.mode == .buffer { redrawBuffer() }
    }
  }

  /// Echo voice activity into the text conversation unless it is already being watched.
  var voiceOutputDestination: String? {
    lock.withLock {
      guard !(view?.source == .voice && viewHeight > 0),
        selectedConversation != voiceConversation else { return nil }
      return voiceParentConversation
    }
  }

  /// Voice gets a dedicated reserved row, or a fixed header in its view.
  func setVoiceStatus(_ text: String?) {
    lock.withLock {
      guard voiceStatus != text else { return }
      refreshSize()
      let previous = panelRows
      voiceStatus = text
      layoutPanel()
      guard active else { return }
      if previous.count != panelRows.count {
        resizeRegion(inputRows: inputRows.count + previous.count,
          to: inputRows.count + panelRows.count)
        drawStatusRow()
        drawInputRows()
      } else { drawPanelRows() }
      if ui.mode == .buffer, view?.source == .voice { drawViewRows() }
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
        outputConversation.auxiliaryReplyBlocks.removeAll()
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

  /// Called under the screen lock, before tool-group and divider hit-testing.
  private func handleScrollbarMouse(_ event: TerminalMouseEvent) -> Bool {
    if case .press = event.action {
      scrollbarDrag = nil
      let inView = isInView(event)
      let inOutput = outputHeight > 0 && event.row >= outputOrigin && event.row < outputOrigin + outputHeight
        && event.column >= outputColumn && event.column < outputColumn + outputColumns
      guard inView || inOutput else { return false }
      if inView { updateViewBuffer() }
      let width = paneContentWidth(inView: inView)
      let origin = inView ? viewColumn : outputColumn
      let paneWidth = inView ? viewColumns : outputColumns
      let barColumn = origin + (ui.scrollbar < 0 ? 0 : width)
      guard event.column >= barColumn, event.column < barColumn + paneWidth - width else { return false }
      draggingViewSeparator = false
      let height = inView ? viewContentHeight : outputHeight
      let row = event.row - (inView ? 1 + viewHeaderRows : outputOrigin)
      guard row >= 0 else { return false }
      let bar = TerminalConversationScope.$id.withValue(nil) {
        inView
          ? view!.buffer.scrollbar(width: width, height: height)
          : transcript.scrollbar(width: width, height: height)
      }
      let grab = bar.thumb.contains(row) ? row - bar.thumb.lowerBound : bar.thumb.count / 2
      scrollbarDrag = (inView, grab, event.row)
      // Preserve the grabbed cell rather than jumping when pressing the handle.
      if bar.thumb.contains(row) { return true }
    }
    guard let drag = scrollbarDrag else { return false }
    if case .release = event.action { scrollbarDrag = nil }
    switch event.action {
    case .drag, .release:
      if event.row == drag.row { return true }
    case .press: break
    }
    scrollbarDrag?.row = event.row
    let height = drag.view ? viewContentHeight : outputHeight
    if drag.view { updateViewBuffer() }
    let width = paneContentWidth(inView: drag.view)
    guard height > 0, width < (drag.view ? viewColumns : outputColumns) else {
      scrollbarDrag = nil
      return true
    }
    TerminalConversationScope.$id.withValue(nil) {
      let row = event.row - (drag.view ? 1 + viewHeaderRows : outputOrigin)
      if drag.view {
        let bar = view!.buffer.scrollbar(width: width, height: height)
        view?.buffer.scroll(to: bar.offset(at: row, grab: drag.grab), width: width, height: height)
      } else {
        let bar = transcript.scrollbar(width: width, height: height)
        transcript.scroll(to: bar.offset(at: row, grab: drag.grab), width: width, height: height)
      }
    }
    drawOutputRows()
    drawStatusRow()
    placeCaret()
    return true
  }

  func scrollOutput(wheel: Int, pages: Int) {
    let loader: (@Sendable (Bool) -> Void)? = lock.withLock {
      outputConversation.historyLoader
    }
    var loadEarlier: Bool?
    lock.withLock {
      guard active, ui.mode == .buffer else { return }
      refreshSize()
      let changed: Bool
      if view?.focused == true, viewHeight > 0 {
        updateViewBuffer()
        let height = viewContentHeight
        let width = paneContentWidth(inView: true)
        changed = view?.buffer.scroll(
          lines: wheel * max(1, ui.scroll) + pages * max(1, height - 1),
          width: width, height: height) ?? false
      } else {
        changed = TerminalConversationScope.$id.withValue(nil) {
          let width = paneContentWidth(inView: false)
          return transcript.scroll(
            lines: wheel * max(1, ui.scroll) + pages * max(1, outputHeight - 1),
            width: width, height: outputHeight)
        }
      }
      let conversation = outputConversation
      if view?.focused != true, let window = conversation.historyWindow {
        if wheel + pages < 0, transcript.isAtBeginning, window.hasEarlier { loadEarlier = true }
        if wheel + pages > 0, transcript.isFollowing, window.hasLater { loadEarlier = false }
      }
      if changed {
        if wheel != 0 && pages == 0 {
          requestScrollDraw()
        } else {
          drawScrollFrame()
        }
      }
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

  private var isVerticalView: Bool {
    view?.vertical == true && view?.fullscreen != true && columns >= 3 && regionBottom >= 3
  }

  private var viewHeight: Int {
    guard ui.mode == .buffer, let view else { return 0 }
    if view.fullscreen { return max(0, regionBottom - 1) }
    if isVerticalView { return regionBottom - 1 }
    return TerminalView.height(availableRows: regionBottom, preferredHeight: view.preferredHeight)
  }

  private var viewHeaderRows: Int { view?.source == .voice ? 1 : 0 }
  private var viewContentHeight: Int { max(1, viewHeight - viewHeaderRows) }

  private var viewColumns: Int {
    isVerticalView ? max(1, min(columns - 2, view?.preferredWidth ?? (columns - 1) / 2)) : columns
  }
  private var viewColumn: Int { isVerticalView ? outputColumns + 2 : 1 }
  private var outputColumn: Int { 1 }
  private var outputColumns: Int { isVerticalView ? columns - viewColumns - 1 : columns }
  private var outputOrigin: Int { viewHeight > 0 && !isVerticalView ? viewHeight + 2 : 1 }
  private var outputHeight: Int {
    if view?.fullscreen == true, viewHeight > 0 { return 0 }
    return isVerticalView ? regionBottom - 1 : max(0, regionBottom - outputOrigin + 1)
  }

  private func isInView(_ event: TerminalMouseEvent) -> Bool {
    event.row >= 1 && event.row <= viewHeight
      && event.column >= viewColumn && event.column < viewColumn + viewColumns
  }

  private func paneContentWidth(inView: Bool) -> Int {
    TerminalConversationScope.$id.withValue(nil) {
      if inView {
        let height = viewContentHeight
        let columns = viewColumns
        return view?.buffer.contentWidth(
          columns: columns, height: height, scrollbar: ui.scrollbar) ?? columns
      }
      return transcript.contentWidth(
        columns: outputColumns, height: outputHeight, scrollbar: ui.scrollbar)
    }
  }

  private var firstInputRow: Int { rows - inputRows.count + 1 }

  /// Moves the region's bottom edge for an input area of another height.
  ///
  /// When the input grows, the region loses rows: its content scrolls up only
  /// as far as the last output needs to stay inside, and the saved output
  /// cursor follows it. When the input shrinks, the region takes the freed
  /// rows back as blank ones below the output, where the next output lands.
  private func resizeRegion(inputRows previousCount: Int, to count: Int) {
    if ui.mode == .buffer {
      scrollbarDrag = nil
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
    scrollDrawScheduled = false
    scrollDrawGeneration &+= 1
    lastOutputDraw = DispatchTime.now().uptimeNanoseconds
    drawViewRows()
    guard outputHeight > 0 else { paintedOutputRows = []; return }
    var width = outputColumns
    var visible = TerminalConversationScope.$id.withValue(nil) {
      let selection = viewHeight > 0 ? view?.source.selection : nil
      transcript.configureExcluding(selection == .all ? nil : selection)
      transcript.configureHighlight(ui.highlight)
      width = paneContentWidth(inView: false)
      return transcript.visibleRows(width: width, height: outputHeight)
    }
    visible += Array(repeating: "", count: max(0, outputHeight - visible.count))
    let bar = TerminalConversationScope.$id.withValue(nil) {
      transcript.scrollbar(width: width, height: outputHeight)
    }
    visible = visible.enumerated().map { index, text in
      paneRow(text, row: outputOrigin + index, index: index, column: outputColumn,
        columns: outputColumns, width: width, bar: bar)
    }
    var out = ""
    for (index, text) in visible.enumerated() {
      if index < paintedOutputRows.count, paintedOutputRows[index] == text { continue }
      out += clearPaneRow(row: outputOrigin + index, column: outputColumn, width: outputColumns)
        + text + Self.reset
    }
    paintedOutputRows = visible
    writeFixedRows(out)
  }

  private var scrollbarColors: ConfiguredTerminalUI? {
    bufferColorsEnabled ? ui : nil
  }

  private func paneRow(
    _ text: String, row: Int, index: Int, column: Int, columns: Int, width: Int,
    bar: TerminalScrollbar
  ) -> String {
    let gutter = columns - width
    guard gutter > 0 else { return text }
    let cell = bar.cell(at: index, width: gutter, ui: scrollbarColors)
    if ui.scrollbar < 0 {
      return cell + move(row: row, column: column + gutter) + text
    }
    return text + Self.reset + move(row: row, column: column + width) + cell
  }

  private func updateViewBuffer() {
    guard let source = view?.source else { return }
    if view?.needsMessages == true || source == .todo || source == .history || source == .diffs || source == .prompt { return }
    if source == .conversations {
      let ids = Set(conversations.keys.filter { $0 != "initial" })
      if aggregateOrder.contains(where: { !ids.contains($0) }) {
        view?.buffer.clear()
        aggregateSections = [:]
        aggregateOrder = []
      }
      for id in ids.subtracting(aggregateOrder).sorted(by: {
        $0.localizedStandardCompare($1) == .orderedAscending
      }) {
        view?.buffer.append("── \(id) ──\n")
        let buffer = conversations[id]!.transcript
        if let block = view?.buffer.retain(buffer) {
          aggregateSections[id] = (block, buffer.contentVersion)
          aggregateOrder.append(id)
        }
      }
      for id in aggregateOrder {
        guard let section = aggregateSections[id], let buffer = conversations[id]?.transcript,
          section.1 != buffer.contentVersion else { continue }
        view?.buffer.retain(buffer, at: section.0)
        aggregateSections[id] = (section.0, buffer.contentVersion)
      }
    } else {
      let id: String
      if source == .voice { id = voiceConversation ?? "voice:off" }
      else if case .conversation(let watched) = source { id = watched }
      else { id = selectedConversation }
      view?.buffer.updateView(
        from: conversations[id]?.transcript ?? TerminalOutputBuffer(), selection: source.selection)
    }
  }

  private func drawViewRows() {
    let height = viewHeight
    guard height > 0 else { view?.focused = false; draggingViewSeparator = false; return }
    updateViewBuffer()
    if view?.source == .diffs { view?.buffer.configureColors(scrollbarColors) }
    view?.buffer.configureHighlight(ui.highlight)
    let width = paneContentWidth(inView: true)
    let voiceHeader = view?.source == .voice
      ? Self.truncated(voiceStatus ?? "Voice is off. Use /voice on to start.", width: width) : nil
    let headerRows = voiceHeader == nil ? 0 : 1
    let contentHeight = max(1, height - headerRows)
    var visible = height > headerRows
      ? view?.buffer.visibleRows(width: width, height: contentHeight) ?? [] : []
    if let voiceHeader { visible.insert(voiceHeader, at: 0) }
    if visible.isEmpty { visible = [Self.truncated("No matching output yet.", width: width)] }
    visible += Array(repeating: "", count: max(0, height - visible.count))
    let bar = view!.buffer.scrollbar(width: width, height: contentHeight)
    visible = visible.enumerated().map { index, text in
      if index < headerRows { return text }
      return paneRow(text, row: index + 1, index: index - headerRows, column: viewColumn,
        columns: viewColumns, width: width, bar: bar)
    }
    let focused = view?.focused == true
    let focus = focused
      ? "view focused · Space layout · Enter fullscreen · / search · j/k scroll · J/K page · g/G top/bottom · v/V resize · q close · Tab prompt"
      : "Tab on empty prompt to focus"
    let label = "── view: \(view?.title ?? "") · \(focus) · drag to resize ──"
    let separatorWidth = columns
    let text = Self.truncated(label, width: separatorWidth)
    let padded = text + String(repeating: " ", count: max(0, separatorWidth - Self.displayWidth(text)))
    let background = TerminalLineEditor.backgroundColorCode(focused ? ui.selectionBackground : ui.backgroundLine)
    let foreground = TerminalLineEditor.foregroundColorCode(focused ? ui.selectionForeground : ui.foreground)
    let emphasis = focused ? "1" : nil
    let codes = background == nil ? [focused ? "7" : "2"]
      : [background, foreground, emphasis].compactMap { $0 }
    visible.append("\u{1B}[" + codes.joined(separator: ";") + "m" + padded + Self.reset)
    var out = ""
    for (index, text) in visible.enumerated() {
      if index < paintedViewRows.count, paintedViewRows[index] == text { continue }
      let paneWidth = index == height ? columns : viewColumns
      let column = index == height ? 1 : viewColumn
      out += clearPaneRow(row: index + 1, column: column, width: paneWidth) + text + Self.reset
    }
    if isVerticalView {
      for row in 1...height {
        out += move(row: row, column: viewColumn - 1) + Self.reset + "│"
      }
    }
    paintedViewRows = visible
    writeFixedRows(out)
  }

  private func clearPaneRow(row: Int, column: Int, width: Int) -> String {
    let origin = move(row: row, column: column)
    return origin + Self.reset + (isVerticalView && width < columns
      ? String(repeating: " ", count: width) + origin : Self.clearLine)
  }

  private func drawPanelRows() {
    let width = max(1, columns - 1)
    let origin = regionBottom + 1
    if origin != paintedPanelOrigin || width != paintedPanelWidth {
      paintedPanelRows = []
    }
    var out = ""
    var painted: [String] = []
    let colors = colorsEnabled
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
    let width = columns
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
    let colors = colorsEnabled
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
    let hidden = view?.focused == true && !viewSearching && viewHeight > 0
    setCursorHidden(hidden)
    guard !hidden else { return }
    write(
      move(
        row: min(rows, firstInputRow + caretRow),
        column: min(columns, max(1, 1 + caretColumn))))
  }

  private func setCursorHidden(_ hidden: Bool) {
    guard hidden != cursorHidden else { return }
    cursorHidden = hidden
    write(hidden ? "\u{1B}[?25l" : "\u{1B}[?25h")
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
    guard !text.isEmpty else { return }
    if outputBatch != nil {
      outputBatch! += text
      return
    }
    FileHandle.standardOutput.write(Data(TerminalThemeStyle.resolve(text).utf8))
  }

  /// Keep the first wheel response immediate and paint queued reports at up to
  /// 120 Hz. Each event still updates its anchor, including direction changes
  /// and clamping at the ends; only redundant terminal frames are coalesced.
  private func requestScrollDraw() {
    let now = DispatchTime.now().uptimeNanoseconds
    let interval: UInt64 = 8_333_333
    let elapsed = now - lastOutputDraw
    if elapsed >= interval {
      drawScrollFrame()
      return
    }
    guard !scrollDrawScheduled else { return }
    scrollDrawScheduled = true
    scrollDrawGeneration &+= 1
    let generation = scrollDrawGeneration
    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(interval - elapsed))) { [weak self] in
      guard let self else { return }
      self.lock.withLock {
        guard self.scrollDrawScheduled, self.scrollDrawGeneration == generation else { return }
        self.scrollDrawScheduled = false
        guard self.active, self.ui.mode == .buffer else { return }
        self.refreshSize()
        self.drawScrollFrame()
      }
    }
  }

  private func drawScrollFrame() {
    // One write carries the viewport, footer and caret together, reducing
    // syscalls and preventing intermediate frames from reaching the terminal.
    outputBatch = ""
    TerminalConversationScope.$id.withValue(nil) {
      drawOutputRows()
      drawStatusRow()
      placeCaret()
    }
    let frame = outputBatch!
    outputBatch = nil
    write(frame)
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
    defer {
      if let voiceStatus, rows >= 4,
        !(ui.mode == .buffer && view?.source == .voice
          && TerminalView.height(availableRows: rows - 1 - inputRows.count) > 0) {
        panelRows.append(Self.truncated(voiceStatus, width: max(1, columns - 1)))
      }
    }
    if let questionText {
      panelRows = REPLModalPrompt.questionRows(
        questionText, width: max(1, columns - 1), height: max(0, min(rows / 2, rows - 3)))
      return
    }
    if ui.mode == .buffer, view?.source == .thinking,
      TerminalView.height(availableRows: rows - 1 - inputRows.count) > 0
    {
      panelRows = []
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
    scrollbarDrag = nil
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

