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

/// Everything the REPL prints goes through here, so a streamed reply, a tool
/// line, and a block from a child agent are written one at a time and never
/// interleave.
///
/// The top-level agent streams as it always has. Children are different: each
/// one's text is collected until a natural boundary — a tool call, the next
/// model turn, the end of the run — and then printed as one block, every line
/// prefixed with the child's pid (`agent#3`), so two children working at once
/// stay readable and the prefix says who said what.
actor TerminalWriter {
  private var thinkingDisplay: ThinkingDisplay = .status
  private var thinkingPreview = ThinkingPreview()
  private var thinkingActive = false
  private var lastThinkingDraw = Date.distantPast
  private var thinkingDrawTask: Task<Void, Never>?
  private var childReasoning: [AgentPID: String] = [:]
  private var wroteRootDelta = false
  private var rootLineOpen = false
  /// When set, output is collected for another surface instead of hitting the tty.
  private let capturesOutput: Bool
  private var captured: [String] = []
  /// Styles assistant markdown when set; nil prints replies verbatim.
  private var markdown: MarkdownTerminalRenderer?
  private var outputEndedLine = true
  private var toolResultLines = ConfiguredTerminalUI().toolResultLines
  /// Compact calls are printed once their outcome is known. Scope IDs by run
  /// because different agents can issue the same provider-generated call ID.
  private var compactToolCalls: [UUID: [String: String]] = [:]
  private var ui = ConfiguredTerminalUI()
  private var subagentOutput = ConfiguredTerminalUI().subagentOutput
  /// Last requested title. A first empty value leaves the shell's title alone.
  private var terminalTitle: String?
  private var redactor: ContentRedactor?
  private let colorsStatus: Bool
  /// Whether stdout is a color terminal, for command output painted inline.
  private let colorsOutput: Bool
  /// ANSI control sequences are useful on a tty even when colors are disabled.
  private let terminalOutput: Bool
  /// The persistent screen, when the REPL runs on a terminal. Output written
  /// through it lands above the prompt instead of on top of it.
  private var screen: TerminalScreen?
  /// Text each child has streamed since its last block boundary.
  private var childText: [AgentPID: String] = [:]
  private var childAgents: [AgentPID: String] = [:]
  private var childToolCalls: [AgentPID: Int] = [:]
  private var childTokens: [AgentPID: Int] = [:]
  /// The usage of each child's call in progress; it joins `childTokens` when
  /// the next call starts, so a provider announcing usage more than once per
  /// call cannot inflate the count.
  private var childCallTokens: [AgentPID: Int] = [:]
  /// Children whose end has been printed, so a supervisor notice does not
  /// repeat what the run's own event already said.
  private var childrenEnded: Set<AgentPID> = []

  init(capturesOutput: Bool = false) {
    self.capturesOutput = capturesOutput
    let environment = ProcessInfo.processInfo.environment
    let noColor = environment["NO_COLOR"] != nil || environment["TERM"] == "dumb"
    colorsStatus = !capturesOutput && isatty(STDERR_FILENO) != 0 && !noColor
    terminalOutput = !capturesOutput && isatty(STDOUT_FILENO) != 0
    colorsOutput = terminalOutput && !noColor
  }

  /// True when `paint` will add color: output goes to a color terminal rather
  /// than a pipe or a captured surface such as the visual workspace.
  var paintsOutput: Bool { colorsOutput && REPLRedirection.current == nil }

  /// Styles a piece of stdout text, or returns it untouched where
  /// escapes would show as noise.
  func paint(_ text: String, color: String? = nil, bold: Bool = false) -> String {
    guard paintsOutput else { return text }
    let codes = [bold ? "1" : nil, color.flatMap(TerminalLineEditor.foregroundColorCode)]
      .compactMap { $0 }
    guard !codes.isEmpty else { return text }
    return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
  }

  func paintHeading(_ text: String) -> String {
    paint(text, color: ui.infoForeground, bold: true)
  }

  func drainCaptured() -> String {
    let text = captured.joined()
    captured.removeAll()
    return text
  }

  func attach(screen: TerminalScreen?) {
    self.screen = capturesOutput ? nil : screen
  }

  /// Installs the renderer for replies. Captured output stays verbatim because
  /// it is shown by surfaces that do not interpret escape sequences.
  func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    markdown = capturesOutput ? nil : renderer
  }

  func configureToolResultLines(_ display: ToolResultDisplay) {
    toolResultLines = display
  }

  func configureColors(_ ui: ConfiguredTerminalUI) {
    self.ui = ui
  }

  func configureSubagentOutput(_ level: SubagentOutputLevel) {
    subagentOutput = level
  }

  func configureRedactor(_ redactor: ContentRedactor?) {
    self.redactor = redactor
  }

  func configureThinking(_ mode: ThinkingDisplay) {
    finishThinking()
    thinkingDisplay = mode
  }

  /// Sets the terminal/tab title with OSC 0. Control characters are removed
  /// so a value loaded from configuration cannot inject another ANSI command.
  func configureTerminalTitle(_ title: String) {
    let safe = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard safe != terminalTitle else { return }
    let previous = terminalTitle
    terminalTitle = safe
    guard terminalOutput, !safe.isEmpty || previous?.isEmpty == false else { return }
    let sequence = "\u{1B}]0;\(safe)\u{7}"
    if let screen {
      screen.emitControlSequence(sequence)
    } else {
      FileHandle.standardOutput.write(Data(sequence.utf8))
    }
  }

  var markdownRenderer: MarkdownTerminalRenderer? {
    REPLRedirection.current == nil ? markdown : nil
  }

  /// Renders a complete text the way replies are rendered.
  func render(_ text: String) -> String {
    markdownRenderer?.render(text) ?? text
  }

  func renderTodoList(_ list: AgentTodoList) -> String {
    guard let options = markdownRenderer?.options, !list.isEmpty else { return list.listing }
    let lines = list.items.enumerated().map { index, item in
      "\(index + 1). \(options.taskMarker(checked: item.isDone)) \(item.title)"
    }
    return "Todo (\(list.pendingCount) pending, \(list.doneCount) done):\n"
      + lines.joined(separator: "\n")
  }

  func resetResponse() {
    finishThinking()
    wroteRootDelta = false
    rootLineOpen = false
    markdown?.reset()
  }

  func consume(_ event: AgentEvent) {
    switch event {
    case .modelStarted(let context, let turn) where context.depth == 0:
      if turn > 1 {
        finishReply()
        closeRootLine()
      }
      if thinkingDisplay != .full { showThinking("") }
    case .provider(let context, .reasoningDelta(let text)) where context.depth == 0:
      showThinking(text)
    case .provider(let context, .toolCallDelta) where context.depth == 0:
      finishThinking()
    case .provider(let context, .textDelta(let text)) where context.depth == 0:
      finishThinking()
      let visible = text
      if var renderer = markdownRenderer {
        let output = renderer.feed(visible)
        markdown = renderer
        write(output)
      } else {
        write(visible)
      }
      wroteRootDelta = true
      rootLineOpen = true
    case .toolStarted(let context, let call) where context.depth == 0:
      finishReply()
      closeRootLine()
      toolStarted(call, context: context)
    case .toolFinished(let context, let result) where context.depth == 0:
      toolFinished(result, context: context)
    case .userMessage(let context, let message) where context.depth == 0:
      finishReply()
      closeRootLine()
      status("⇐ you: \(message.text)", color: ui.promptForeground)
    case .transcriptEdited(let context, let report) where context.depth == 0:
      finishReply()
      closeRootLine()
      status("✂ context: \(report.summary)", color: ui.infoForeground)
    case .compactionStarted(let context, let estimated) where context.depth == 0:
      finishReply()
      closeRootLine()
      status(
        "✂ context: \(ModelUsageFormat.tokens(estimated, estimated: true)), compacting…",
        color: ui.infoForeground)
    case .compactionFailed(let context, let message) where context.depth == 0:
      status("✂ context: compaction failed: \(message)", color: ui.errorForeground)
    case .retrying(let context, let attempt, let limit, let delay, let error)
    where context.depth == 0:
      finishReply()
      closeRootLine()
      status(
        "↻ retry \(attempt)/\(limit) in \(ModelUsageFormat.duration(delay)): \(error)",
        color: ui.warningForeground)
    case .finished(let context, let result) where context.depth == 0:
      compactToolCalls[context.runID] = nil
      finishThinking()
      let responseText = redactor?.unredact(result.response.text) ?? result.response.text
      if wroteRootDelta {
        finishReply()
      } else if result.interruption == nil {
        write(render(responseText))
      }
      closeRootLine(force: true)
    case .childStarted(let parent, let child):
      guard let pid = child.pid else { return }
      childAgents[pid] = child.agentID
      childToolCalls[pid] = 0
      childTokens[pid] = 0
      childCallTokens[pid] = 0
      childText[pid] = nil
      childrenEnded.remove(pid)
      guard subagentOutput != .none else { return }
      let starter = parent.pid.map { parent.depth > 0 ? " by agent#\($0.rawValue)" : "" } ?? ""
      childBlock(pid, "↳ \(child.agentID) started\(starter)")
    case .childQueued(let parent, let child):
      guard let pid = child.pid else { return }
      childAgents[pid] = child.agentID
      childToolCalls[pid] = 0
      childTokens[pid] = 0
      childCallTokens[pid] = 0
      childText[pid] = nil
      childrenEnded.remove(pid)
      guard subagentOutput != .none else { return }
      let starter = parent.pid.map { parent.depth > 0 ? " by agent#\($0.rawValue)" : "" } ?? ""
      childBlock(pid, "↳ \(child.agentID) queued\(starter): waiting for a free agent slot")
    case .childFinished:
      // The child's own `finished` event already printed its answer.
      break
    case .modelStarted(let context, let turn):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      childTokens[pid, default: 0] += childCallTokens[pid] ?? 0
      childCallTokens[pid] = 0
      guard subagentOutput == .stats else { return }
      var facts = ["turn \(turn)"]
      let tools = childToolCalls[pid] ?? 0
      if tools > 0 { facts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
      if let tokens = childTokens[pid], tokens > 0 { facts.append(ModelUsageFormat.tokens(tokens)) }
      childBlock(pid, "· " + facts.joined(separator: " · "))
    case .provider(let context, .reasoningDelta(let text)):
      guard let pid = context.pid, subagentOutput == .all else { return }
      if childReasoning[pid] == nil { flushChildText(pid) }
      childReasoning[pid, default: ""] += text
      if thinkingDisplay != .full {
        childReasoning[pid] = ThinkingPreview.tail(childReasoning[pid] ?? "")
      }
    case .provider(let context, .textDelta(let text)):
      if let pid = context.pid { flushChildReasoning(pid) }
      guard let pid = context.pid, subagentOutput == .all else { return }
      childText[pid, default: ""] += text
    case .provider(let context, .usage(let usage)):
      guard let pid = context.pid else { return }
      childCallTokens[pid] = usage.totalTokens
    case .toolStarted(let context, let call):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      childToolCalls[pid, default: 0] += 1
      guard subagentOutput == .all || subagentOutput == .tools else { return }
      toolStarted(call, context: context)
    case .toolFinished(let context, let result):
      guard context.pid != nil, subagentOutput == .all || subagentOutput == .tools else {
        compactToolCalls[context.runID]?[result.callID] = nil
        return
      }
      toolFinished(result, context: context)
    case .userMessage(let context, let message):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(pid, "⇐ you: \(message.text)", color: ui.promptForeground)
    case .transcriptEdited(let context, let report):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(pid, "✂ context: \(report.summary)", color: ui.infoForeground)
    case .compactionStarted(let context, let estimated):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(
        pid, "✂ context: \(ModelUsageFormat.tokens(estimated, estimated: true)), compacting…",
        color: ui.infoForeground)
    case .compactionFailed(let context, let message):
      guard let pid = context.pid, subagentOutput != .none else { return }
      childBlock(pid, "✂ context: compaction failed: \(message)", color: ui.errorForeground)
    case .retrying(let context, let attempt, let limit, let delay, let error):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(
        pid, "↻ retry \(attempt)/\(limit) in \(ModelUsageFormat.duration(delay)): \(error)",
        color: ui.warningForeground)
    case .finished(let context, let result):
      compactToolCalls[context.runID] = nil
      guard let pid = context.pid else { return }
      flushChildText(pid)
      childrenEnded.insert(pid)
      guard subagentOutput != .none else { return }
      if let interruption = result.interruption {
        childBlock(pid, "↲ stopped: \(interruption.summary)", color: ui.errorForeground)
        return
      }
      var facts: [String] = []
      if result.modelTurns > 0 {
        facts.append("\(result.modelTurns) turn\(result.modelTurns == 1 ? "" : "s")")
      }
      if result.toolCalls > 0 {
        facts.append("\(result.toolCalls) tool\(result.toolCalls == 1 ? "" : "s")")
      }
      if let usage = result.usage, usage.totalTokens > 0 {
        facts.append(ModelUsageFormat.tokens(usage.totalTokens, estimated: usage.isEstimated))
      }
      let summary = facts.isEmpty ? "" : " · " + facts.joined(separator: " · ")
      let answer = AgentProcessInfo.oneLine(
        redactor?.unredact(result.response.text) ?? result.response.text, limit: 120)
      childBlock(pid, "↲ done\(summary)" + (answer.isEmpty ? "" : ": \(answer)"))
    default:
      break
    }
  }

  /// A child ended without an answer — it failed or was stopped — which the
  /// run itself never reports, so the supervisor's notice is printed instead.
  func processEnded(_ info: AgentProcessInfo) {
    compactToolCalls[info.runID] = nil
    guard info.depth > 0, !childrenEnded.contains(info.pid) else { return }
    childrenEnded.insert(info.pid)
    flushChildText(info.pid)
    guard subagentOutput != .none else { return }
    let reason = info.failure.map { ": \($0)" } ?? ""
    childBlock(info.pid, "✗ \(info.state.shortLabel)\(reason)", color: ui.errorForeground)
  }

  /// Prints what a tool call is waiting on, for the person to answer at the
  /// prompt whenever they get to it.
  func approvalRequest(_ request: ApprovalRequest) {
    finishReply()
    closeRootLine()
    let who = request.run.depth > 0 ? request.run.pid.map { "agent#\($0.rawValue) " } ?? "" : ""
    let kind = request.tool.annotations.approval.rawValue
    let choices = "? answer " + REPLModalPrompt.approvalHelp(request) + "; slash commands remain available"
    status(
      """
      ? \(who)wants to run \(kind) tool '\(request.tool.name)'
      ? arguments: \(request.call.arguments.compactJSONString)
      \(choices)
      """,
      color: ui.warningForeground)
  }

  func recoverAfterError(_ error: any Error) {
    finishReply()
    closeRootLine()
    let message = redactor?.unredact(error.localizedDescription) ?? error.localizedDescription
    status("error: \(message)", color: ui.errorForeground)
    if error is ProviderPolicyError {
      status(
        "Automatic retries skipped for this policy rejection.",
        color: ui.warningForeground)
    }
  }

  func recoverAfterCancellation() {
    finishReply()
    closeRootLine()
    status("cancelled", color: ui.warningForeground)
  }

  func prompt(_ value: String) { write(value) }

  /// Print a side question as one labelled block without resetting the
  /// main reply's streaming renderer or its delta bookkeeping.
  func btwResponse(_ text: String, pid: AgentPID) {
    finishReply()
    closeRootLine()
    let body = render(text.trimmingCharacters(in: .whitespacesAndNewlines))
      .components(separatedBy: "\n").map { "btw#\(pid.rawValue) │ " + $0 }.joined(separator: "\n")
    write(body + "\n")
  }

  enum Tone {
    case error, warning, success, info
  }

  func note(_ value: String, tone: Tone? = nil) {
    let color: String?
    switch tone {
    case .error: color = ui.errorForeground
    case .warning: color = ui.warningForeground
    case .success: color = ui.successForeground
    case .info: color = ui.infoForeground
    case nil: color = nil
    }
    status(value, color: color)
  }

  func line(_ value: String = "", to handle: FileHandle = .standardOutput) {
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    // CLI diagnostics consistently use these prefixes on stderr. Keep stdout
    // (including quoted tool/assistant text) untouched.
    var output = value
    if handle === FileHandle.standardError, colorsStatus {
      let color =
        value.hasPrefix("error:")
        ? ui.errorForeground
        : value.hasPrefix("warning:") ? ui.warningForeground : ""
      output = value.components(separatedBy: "\n").map {
        Self.styled($0, foreground: color)
      }.joined(separator: "\n")
    }
    emit(output + "\n", to: handle)
    if handle === FileHandle.standardOutput { outputEndedLine = true }
  }

  /// A completed shell filter's bytes, with no extra newline or styling.
  func rawOutput(_ data: Data, to handle: FileHandle = .standardOutput) {
    guard !data.isEmpty else { return }
    emit(String(decoding: data, as: UTF8.self), to: handle)
    if handle === FileHandle.standardOutput { outputEndedLine = data.last == 10 }
  }

  // MARK: - Tool output

  private func toolStarted(_ call: ToolCall, context: AgentEventContext) {
    let preview = ToolCallPreview.render(call)
    if toolResultLines == .lines(0) {
      compactToolCalls[context.runID, default: [:]][call.id] = String(preview.dropFirst(2))
    } else {
      toolStatus(preview, context: context, color: ui.toolCallForeground)
    }
  }

  private func toolFinished(_ result: ToolResult, context: AgentEventContext) {
    let call = compactToolCalls[context.runID]?.removeValue(forKey: result.callID)
    if compactToolCalls[context.runID]?.isEmpty == true {
      compactToolCalls[context.runID] = nil
    }
    // Finish a compact call in the same format even if the display setting
    // changed while it ran. Some rejected calls arrive without a start event.
    if call != nil || toolResultLines == .lines(0) {
      let marker = result.isError ? "✘" : "✔"
      toolStatus(
        "\(marker) \(call ?? (result.isError ? "error" : "done"))",
        context: context, color: result.isError ? ui.errorForeground : ui.toolCallForeground)
    } else {
      toolStatus(
        ToolResultPreview.render(result, display: toolResultLines), context: context,
        color: result.isError ? ui.errorForeground : ui.toolResultForeground, diff: true)
    }
  }

  private func toolStatus(
    _ text: String, context: AgentEventContext, color: String, diff: Bool = false
  ) {
    if context.depth > 0, let pid = context.pid {
      childBlock(pid, text, color: color, diff: diff)
    } else {
      status(text, color: color, diff: diff)
    }
  }

  // MARK: - Child blocks

  private func flushChildReasoning(_ pid: AgentPID) {
    guard let text = childReasoning.removeValue(forKey: pid) else { return }
    let visible =
      thinkingDisplay == .full
      ? text
      : thinkingDisplay == .status
        ? "Thinking…"
        : ThinkingPreview.lines(text, count: thinkingDisplay.lineCount, width: 70).joined(
          separator: "\n")
    childBlock(pid, visible, color: ui.thinkingForeground, italic: true)
  }

  private func flushChildText(_ pid: AgentPID) {
    flushChildReasoning(pid)
    guard let text = childText.removeValue(forKey: pid) else { return }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var trimmed = lines
    while trimmed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      trimmed.removeLast()
    }
    while trimmed.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      trimmed.removeFirst()
    }
    guard !trimmed.isEmpty else { return }
    childBlock(pid, trimmed.map { "│ " + $0 }.joined(separator: "\n"))
  }

  /// One block from one child: every line carries the pid, and the whole
  /// block is written in one go so nothing else lands in the middle of it.
  private func childBlock(
    _ pid: AgentPID, _ text: String, color: String? = nil, italic: Bool = false, diff: Bool = false
  ) {
    finishReply()
    closeRootLine()
    let prefix = childPrefix(pid)
    let body = styledLines(text, color: color, diff: diff).map { line in
      prefix + (italic && colorsStatus ? "\u{1B}[3m\(line)\u{1B}[23m" : line)
    }.joined(separator: "\n")
    emitStatus(body)
  }

  private func childPrefix(_ pid: AgentPID) -> String {
    let label = "agent#\(pid.rawValue) "
    guard colorsStatus, let code = TerminalLineEditor.foregroundColorCode(Self.childColor(pid))
    else { return label }
    return "\u{1B}[\(code)m\(label)\u{1B}[0m"
  }

  private static let childColors = [
    "cyan", "magenta", "blue", "green", "bright-cyan", "bright-magenta", "bright-blue",
    "bright-green",
  ]

  private static func childColor(_ pid: AgentPID) -> String {
    childColors[abs(pid.rawValue) % childColors.count]
  }

  // MARK: - Writing

  /// Writes what the markdown renderer still holds for the current reply.
  private func finishReply() {
    finishThinking()
    guard var renderer = markdownRenderer else { return }
    let output = renderer.flush()
    markdown = renderer
    write(output)
  }

  private func showThinking(_ delta: String) {
    if !thinkingActive {
      finishReply()
      closeRootLine()
      thinkingActive = true
      thinkingPreview = ThinkingPreview()
      lastThinkingDraw = .distantPast
      if thinkingDisplay != .full && screen == nil {
        status("Thinking…", color: ui.thinkingForeground)
      }
    }
    if thinkingDisplay == .full {
      let safe = delta.unicodeScalars.filter {
        $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
      }
      let text = String(String.UnicodeScalarView(safe))
      write(
        paintsOutput ? Self.styled(text, foreground: ui.thinkingForeground, italic: true) : text)
      outputEndedLine = text.hasSuffix("\n")
    } else {
      thinkingPreview.append(delta)
      let now = Date()
      if now.timeIntervalSince(lastThinkingDraw) >= 0.05 {
        thinkingDrawTask?.cancel()
        drawThinking()
      } else if thinkingDrawTask == nil {
        thinkingDrawTask = Task {
          try? await Task.sleep(for: .milliseconds(50))
          guard !Task.isCancelled else { return }
          drawThinking()
        }
      }
    }
  }

  private func drawThinking() {
    thinkingDrawTask = nil
    screen?.setThinking(thinkingPreview.text, display: thinkingDisplay)
    lastThinkingDraw = Date()
  }

  private func finishThinking() {
    guard thinkingActive else { return }
    thinkingDrawTask?.cancel()
    thinkingDrawTask = nil
    screen?.setThinking(nil)
    if thinkingDisplay == .full && !outputEndedLine { write("\n") }
    thinkingActive = false
    thinkingPreview = ThinkingPreview()
  }

  private func write(_ value: String) {
    guard !value.isEmpty else { return }
    outputEndedLine = value.hasSuffix("\n")
    if capturesOutput {
      captured.append(value)
      return
    }
    emit(value, to: .standardOutput)
  }

  private func emit(_ value: String, to handle: FileHandle) {
    if handle === FileHandle.standardOutput, let redirection = REPLRedirection.current {
      redirection.write(value)
      return
    }
    if let screen {
      screen.write(value, to: handle)
    } else {
      handle.write(Data(value.utf8))
    }
  }

  private func status(_ value: String, color: String? = nil, diff: Bool = false) {
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    emitStatus(styledLines(value, color: color, diff: diff).joined(separator: "\n"))
  }

  private func emitStatus(_ styled: String) {
    if capturesOutput {
      captured.append(styled + "\n")
      return
    }
    emit(styled + "\n", to: .standardError)
  }

  private static func styled(
    _ text: String, foreground: String?, background: String? = nil, italic: Bool = false
  ) -> String {
    var codes = [
      foreground.flatMap(TerminalLineEditor.foregroundColorCode),
      background.flatMap(TerminalLineEditor.backgroundColorCode),
    ].compactMap { $0 }
    if italic { codes.insert("3", at: 0) }
    guard !codes.isEmpty else { return text }
    return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
  }

  /// Tool previews add a two-character prefix. Remove only that prefix when
  /// inspecting a diff, preserving its context marker and source indentation.
  private func styledLines(_ value: String, color: String?, diff: Bool) -> [String] {
    let lines = value.components(separatedBy: "\n")
    guard colorsStatus else { return lines }
    let content = diff ? lines.map { String($0.dropFirst(2)) } : lines
    let hasUnifiedDiff =
      diff
      && content.indices.dropLast().contains { index in
        content[index].hasPrefix("--- ") && content[index + 1].hasPrefix("+++ ")
      }
    return lines.indices.map { index in
      let line = lines[index]
      let marker = content[index]
      if hasUnifiedDiff {
        if marker.hasPrefix("--- ") || marker.hasPrefix("+++ ")
          || marker.hasPrefix("@@ ") || marker.hasPrefix("diff --git ")
          || marker.hasPrefix("index ")
        {
          return Self.styled(line, foreground: ui.diffHeaderForeground)
        }
        if marker.hasPrefix("-") {
          return Self.styled(
            line, foreground: ui.diffRemovedForeground, background: ui.diffRemovedBackground)
        }
        if marker.hasPrefix("+") {
          return Self.styled(
            line, foreground: ui.diffAddedForeground, background: ui.diffAddedBackground)
        }
      }
      return Self.styled(line, foreground: color)
    }
  }

  private func closeRootLine(force: Bool = false) {
    // The screen sees every write, including the echo of a submitted line,
    // so it knows better than this actor whether the output row is open.
    let ended = REPLRedirection.current != nil ? outputEndedLine
      : screen?.outputIsAtLineStart ?? outputEndedLine
    if (rootLineOpen || force) && !ended {
      write("\n")
    }
    rootLineOpen = false
  }
}
