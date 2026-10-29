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
  private var tools = ConfiguredTerminalUI().tools
  /// Compact calls are printed once their outcome is known. Scope IDs by run
  /// because different agents can issue the same provider-generated call ID.
  private var compactToolCalls: [UUID: [String: (text: String, display: ToolCallDisplay)]] = [:]
  private var iconToolCalls: [UUID: Set<String>] = [:]
  private var iconLinePrefix: String?
  private var bufferToolCalls: [UUID: [String: Int]] = [:]
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
  private var supervisor: AgentSupervisor?
  private var rootDestination: String?
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
  private var conversationWriters: [AgentPID: TerminalWriter] = [:]
  private var voiceProcess: AgentPID?
  private var voiceOutput: TerminalWriter?
  private var conversationConfigured = false
  private var replyOwner: String?

  func setVoiceProcess(_ pid: AgentPID?, parent: String? = nil) {
    voiceProcess = pid
    voiceOutput = nil
    if let pid, let parent { screen?.setVoiceConversation("agent:\(pid.rawValue)", parent: parent) }
  }

  func voiceInput(_ text: String, pid: AgentPID) {
    if let screen, screen.isBufferMode {
      TerminalConversationScope.$id.withValue("agent:\(pid.rawValue)") {
        status("you: \(text)", color: .promptForeground)
      }
      guard let destination = screen.voiceOutputDestination else { return }
      TerminalConversationScope.$id.withValue(destination) {
        status("voice#\(pid.rawValue) you: \(text)", color: .promptForeground)
      }
    } else {
      status("voice#\(pid.rawValue) you: \(text)", color: .promptForeground)
    }
  }

  init(capturesOutput: Bool = false) {
    self.capturesOutput = capturesOutput
    let environment = ProcessInfo.processInfo.environment
    let noColor = environment["NO_COLOR"] != nil || environment["TERM"] == "dumb"
    colorsStatus = !capturesOutput && isatty(STDERR_FILENO) != 0 && !noColor
    terminalOutput = !capturesOutput && isatty(STDOUT_FILENO) != 0
    colorsOutput = terminalOutput && !noColor
  }

  /// True when `paint` will add color: output goes to a color terminal rather
  /// than a pipe or captured command output.
  var paintsOutput: Bool { colorsOutput && REPLRedirection.current == nil }

  /// Styles a piece of stdout text, or returns it untouched where
  /// escapes would show as noise.
  func paint(_ text: String, color: String? = nil, role: TerminalThemeStyle? = nil, bold: Bool = false) -> String {
    guard paintsOutput else { return text }
    let codes = [bold ? "1" : nil, (role.map { $0.value(in: ui) } ?? color).flatMap(TerminalLineEditor.foregroundColorCode)]
      .compactMap { $0 }
    let annotation = retainsThemeStyles ? role?.marker ?? "" : ""
    guard !codes.isEmpty || !annotation.isEmpty else { return text }
    let style = codes.isEmpty ? "" : "\u{1B}[\(codes.joined(separator: ";"))m"
    return style + annotation + text + "\u{1B}[0m"
  }

  func paintHeading(_ text: String) -> String {
    paint(text, role: .infoForeground, bold: true)
  }

  func toolModeBadge(_ mode: AgentToolMode) -> String {
    let symbol = mode == .disabled ? "○" : mode == .hidden ? "◐" : "●"
    let role: TerminalThemeStyle = mode == .disabled ? .errorForeground
      : mode == .hidden ? .warningForeground : .successForeground
    return paint("[\(symbol) \(mode.rawValue)]", role: role, bold: true)
  }

  func toolGroupBadge(_ summary: AgentToolModeSummary) -> String {
    if summary.enabled == 0 {
      return paint("[○ disabled]", role: .errorForeground, bold: true)
    }
    if summary.disabled > 0 {
      return paint("[◐ mixed]", role: .warningForeground, bold: true)
    }
    if summary.hidden == summary.total {
      return paint("[◐ hidden]", role: .warningForeground, bold: true)
    }
    return paint("[● enabled]", role: .successForeground, bold: true)
  }

  func drainCaptured() -> String {
    let text = captured.joined()
    captured.removeAll()
    return text
  }

  func attach(screen: TerminalScreen?, supervisor: AgentSupervisor? = nil) {
    self.supervisor = supervisor
    self.screen = capturesOutput ? nil : screen
    self.screen?.configureMarkdown(markdown)
  }

  func checkpointSupervisor() -> AgentSupervisor? { supervisor }

  func releaseProcess(_ pid: AgentPID, removing: Bool) {
    conversationWriters[pid] = nil
    childText[pid] = nil
    childReasoning[pid] = nil
    childAgents[pid] = nil
    childToolCalls[pid] = nil
    childTokens[pid] = nil
    childCallTokens[pid] = nil
    childrenEnded.remove(pid)
    screen?.releaseConversation(for: pid, removing: removing)
  }

  func clearScreen() {
    guard terminalOutput, REPLRedirection.current == nil else { return }
    if let screen {
      screen.clearScreen(clearOutput: true)
    } else {
      FileHandle.standardOutput.write(Data("\u{1B}[2J\u{1B}[H".utf8))
    }
    outputEndedLine = true
  }

  /// Installs the renderer for replies. Captured output stays verbatim because
  /// it is shown by surfaces that do not interpret escape sequences.
  func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    var renderer = renderer
    renderer?.options.tableBorders = ui.tableBorders
    renderer?.theme.boldColor = TerminalLineEditor.foregroundColorCode(ui.boldForeground) ?? ""
    renderer?.theme.italicColor = TerminalLineEditor.foregroundColorCode(ui.italicForeground) ?? ""
    renderer?.theme.colorOverrides = Dictionary(
      uniqueKeysWithValues: [
        ("90", ui.thinkingForeground), ("32", ui.toolCallForeground),
        ("92", ui.toolCallForeground), ("93", ui.warningForeground),
        ("94", ui.infoForeground), ("95", ui.promptForeground),
        ("96", ui.diffHeaderForeground), ("34", ui.infoForeground),
        ("36", ui.infoForeground),
      ].map { ($0.0, TerminalLineEditor.foregroundColorCode($0.1) ?? "") })
    markdown = capturesOutput ? nil : renderer
    screen?.configureMarkdown(markdown)
  }

  func configureTools(_ display: ToolResultDisplay) {
    if tools != display { finishIconLine() }
    tools = display
    screen?.configureTools(display)
  }

  func configureColors(_ ui: ConfiguredTerminalUI) {
    guard self.ui != ui else { return }
    self.ui = ui
    configureMarkdown(markdown)
  }

  func configureSubagentOutput(_ level: SubagentOutputLevel) {
    subagentOutput = level
  }

  func configureRedactor(_ redactor: ContentRedactor?) {
    self.redactor = redactor
  }

  func configureThinking(_ mode: ThinkingDisplay) {
    guard mode != thinkingDisplay else { return }
    TerminalConversationScope.$id.withValue(rootDestination) { finishThinking() }
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
    finishIconLine()
    finishThinking()
    wroteRootDelta = false
    rootLineOpen = false
    markdown?.reset()
  }

  func consume(_ event: AgentEvent) async {
    let context = event.terminalContext
    let destination = screen?.conversationID(for: context)
    if let voiceProcess, context.pid == voiceProcess, context.depth > 0, screen?.isBufferMode != true {
      if voiceOutput == nil { voiceOutput = TerminalWriter() }
      await voiceOutput?.consumeConversation(
        event.terminalForegroundEvent, destination: nil, screen: screen,
        ui: ui, markdown: markdown, redactor: redactor)
      return
    }
    if case .started = event, let destination { screen?.activateConversation(destination) }
    if context.depth == 0 { rootDestination = destination }
    if let screen, screen.isBufferMode, context.depth > 0,
      let pid = context.pid, REPLRedirection.current == nil
    {
      if case .modelStarted = event, let supervisor, let destination {
        let messages = await supervisor.transcript(pid)
        screen.seedConversation(destination, messages: redactor?.unredact(messages) ?? messages)
      }
      let writer: TerminalWriter
      if let existing = conversationWriters[pid] { writer = existing }
      else {
        writer = TerminalWriter()
        conversationWriters[pid] = writer
      }
      await writer.consumeConversation(
        event.terminalForegroundEvent, destination: destination, screen: screen,
        ui: ui, markdown: markdown, redactor: redactor)
      if let voiceProcess, context.pid == voiceProcess, let echo = screen.voiceOutputDestination {
        if voiceOutput == nil { voiceOutput = TerminalWriter() }
        await voiceOutput?.consumeConversation(
          event.terminalForegroundEvent, destination: echo, screen: screen,
          ui: ui, markdown: markdown, redactor: redactor, replyOwner: "voice:\(voiceProcess.rawValue)")
      }
      return
    }
    TerminalConversationScope.$id.withValue(destination) { consumeEvent(event) }
  }

  private func consumeConversation(
    _ event: AgentEvent, destination: String?, screen: TerminalScreen?,
    ui: ConfiguredTerminalUI, markdown: MarkdownTerminalRenderer?, redactor: ContentRedactor?,
    replyOwner: String? = nil
  ) {
    if !conversationConfigured {
      self.markdown = markdown.map { MarkdownTerminalRenderer(theme: $0.theme, options: $0.options) }
      conversationConfigured = true
    }
    self.screen = screen
    self.ui = ui
    if let theme = markdown?.theme { self.markdown?.theme = theme }
    self.redactor = redactor
    self.replyOwner = replyOwner
    tools = ui.tools
    thinkingDisplay = ui.thinking
    subagentOutput = ui.subagentOutput
    TerminalConversationScope.$id.withValue(destination) {
      TerminalConversationScope.$replyOwner.withValue(replyOwner) {
        if case .started = event { resetResponse() }
        consumeEvent(event)
      }
    }
  }

  private func consumeEvent(_ event: AgentEvent) {
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
      writeReply(text)
      wroteRootDelta = true
      rootLineOpen = true
    case .toolStarted(let context, let call) where context.depth == 0:
      finishReply()
      closeRootLine()
      toolStarted(call, context: context)
    case .toolFinished(let context, let result) where context.depth == 0:
      toolFinished(result, context: context)
    case .toolUpdated(let context, let call) where context.depth == 0:
      toolStarted(call, context: context, updating: true)
    case .userMessage(let context, let message) where context.depth == 0:
      finishReply()
      closeRootLine()
      status("⇐ you: \(message.text)", color: .promptForeground)
    case .transcriptEdited(let context, let report) where context.depth == 0:
      finishReply()
      closeRootLine()
      status("✂ context: \(report.summary)", color: .infoForeground)
    case .compactionStarted(let context, let estimated) where context.depth == 0:
      finishReply()
      closeRootLine()
      status(
        "✂ context: \(ModelUsageFormat.tokens(estimated, estimated: true)), compacting…",
        color: .infoForeground)
    case .compactionFailed(let context, let message) where context.depth == 0:
      status("✂ context: compaction failed: \(message)", color: .errorForeground)
    case .retrying(let context, let attempt, let limit, let delay, let error)
    where context.depth == 0:
      finishReply()
      closeRootLine()
      status(
        "↻ retry \(attempt)/\(limit) in \(ModelUsageFormat.duration(delay)): \(error)",
        color: .warningForeground)
    case .finished(let context, let result) where context.depth == 0:
      finishIconLine()
      compactToolCalls[context.runID] = nil
      iconToolCalls[context.runID] = nil
      bufferToolCalls[context.runID] = nil
      finishThinking()
      let responseText = redactor?.unredact(result.response.text) ?? result.response.text
      if wroteRootDelta {
        finishReply()
      } else if result.interruption == nil {
        writeReply(responseText)
        finishReply()
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
      if thinkingDisplay != .full && screen == nil {
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
    case .toolUpdated(let context, let call):
      guard context.pid != nil, subagentOutput == .all || subagentOutput == .tools else { return }
      toolStarted(call, context: context, updating: true)
    case .userMessage(let context, let message):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(pid, "⇐ you: \(message.text)", color: .promptForeground)
    case .transcriptEdited(let context, let report):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(pid, "✂ context: \(report.summary)", color: .infoForeground)
    case .compactionStarted(let context, let estimated):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(
        pid, "✂ context: \(ModelUsageFormat.tokens(estimated, estimated: true)), compacting…",
        color: .infoForeground)
    case .compactionFailed(let context, let message):
      guard let pid = context.pid, subagentOutput != .none else { return }
      childBlock(pid, "✂ context: compaction failed: \(message)", color: .errorForeground)
    case .retrying(let context, let attempt, let limit, let delay, let error):
      guard let pid = context.pid else { return }
      flushChildText(pid)
      guard subagentOutput != .none else { return }
      childBlock(
        pid, "↻ retry \(attempt)/\(limit) in \(ModelUsageFormat.duration(delay)): \(error)",
        color: .warningForeground)
    case .finished(let context, let result):
      compactToolCalls[context.runID] = nil
      iconToolCalls[context.runID] = nil
      bufferToolCalls[context.runID] = nil
      guard let pid = context.pid else { return }
      flushChildText(pid)
      childrenEnded.insert(pid)
      guard subagentOutput != .none else { return }
      if let interruption = result.interruption {
        childBlock(pid, "↲ stopped: \(interruption.summary)", color: .errorForeground)
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
    if let screen, screen.isBufferMode {
      guard info.state != .completed else { return }
      TerminalConversationScope.$id.withValue("agent:\(info.pid.rawValue)") {
        status("✗ \(info.state.shortLabel)" + (info.failure.map { ": \($0)" } ?? ""), color: .errorForeground)
      }
      return
    }
    compactToolCalls[info.runID] = nil
    iconToolCalls[info.runID] = nil
    guard info.depth > 0, !childrenEnded.contains(info.pid) else { return }
    childrenEnded.insert(info.pid)
    flushChildText(info.pid)
    guard subagentOutput != .none else { return }
    let reason = info.failure.map { ": \($0)" } ?? ""
    childBlock(info.pid, "✗ \(info.state.shortLabel)\(reason)", color: .errorForeground)
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
      color: .warningForeground)
  }

  func recoverAfterError(_ error: any Error) {
    finishReply()
    closeRootLine()
    let message = redactor?.unredact(error.localizedDescription) ?? error.localizedDescription
    status("error: \(message)", color: .errorForeground)
    if error is ProviderPolicyError {
      status(
        "Automatic retries skipped for this policy rejection.",
        color: .warningForeground)
    }
  }

  func recoverAfterCancellation() {
    finishReply()
    closeRootLine()
    status("cancelled", color: .warningForeground)
  }

  func recoverConversation(_ pid: AgentPID, error: (any Error)?) async {
    let writer = conversationWriters[pid] ?? self
    await TerminalConversationScope.$id.withValue("agent:\(pid.rawValue)") {
      if let error { await writer.recoverAfterError(error) }
      else { await writer.recoverAfterCancellation() }
    }
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
    let color: TerminalThemeStyle?
    switch tone {
    case .error: color = .errorForeground
    case .warning: color = .warningForeground
    case .success: color = .successForeground
    case .info: color = .infoForeground
    case nil: color = nil
    }
    status(value, color: color)
  }

  func line(_ value: String = "", to handle: FileHandle = .standardOutput) {
    finishIconLine()
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    // CLI diagnostics consistently use these prefixes on stderr. Keep stdout
    // (including quoted tool/assistant text) untouched.
    var output = value
    if handle === FileHandle.standardError, colorsStatus {
      let color: TerminalThemeStyle? =
        value.hasPrefix("error:")
        ? .errorForeground
        : value.hasPrefix("warning:") ? .warningForeground : nil
      output = value.components(separatedBy: "\n").map {
        styled($0, foreground: color)
      }.joined(separator: "\n")
    }
    emit(output + "\n", to: handle)
    if handle === FileHandle.standardOutput { outputEndedLine = true }
  }

  /// Prints a complete command document without sharing the reply stream's
  /// parser. Retain Markdown on the screen for resize and rendering changes;
  /// pipes, captures, and disabled Markdown can use a plain-text alternative.
  func markdown(_ value: String, plainText: String? = nil) {
    guard let renderer = markdownRenderer else {
      line(plainText ?? value)
      return
    }
    finishReply()
    closeRootLine()
    let source = value.hasSuffix("\n") ? value : value + "\n"
    let rendered = renderer.render(source)
    if let screen {
      screen.writeMarkdown(source, rendered: rendered)
    } else {
      emit(rendered, to: .standardOutput)
    }
    outputEndedLine = true
  }

  /// Command tables share reply layout and remain reflowable in buffer mode.
  /// Captures, redirects and Markdown-off output still get aligned plain text.
  func table(_ table: MarkdownTable) {
    let plain = MarkdownTableLayout.lines(
      for: table,
      width: terminalOutput ? TerminalLineEditor.terminalColumns() : Int.max,
      unicode: MarkdownTerminalEnvironment.detect(ProcessInfo.processInfo.environment).unicode,
      borders: ui.tableBorders
    ).map { $0.map(\.text).joined() }.joined(separator: "\n")
    markdown(table.markdown, plainText: plain)
  }

  /// A completed shell filter's bytes, with no extra newline or styling.
  func rawOutput(_ data: Data, to handle: FileHandle = .standardOutput) {
    guard !data.isEmpty else { return }
    emit(String(decoding: data, as: UTF8.self), to: handle)
    if handle === FileHandle.standardOutput { outputEndedLine = data.last == 10 }
  }

  // MARK: - Tool output

  private func toolStarted(_ call: ToolCall, context: AgentEventContext, updating: Bool = false) {
    if let screen, screen.isBufferMode, REPLRedirection.current == nil {
      finishReply()
      closeRootLine()
      let prefix = context.depth > 0 ? context.pid.map { childPrefix($0) } ?? "" : ""
      let previous = updating ? bufferToolCalls[context.runID]?[call.id] : nil
      let block = screen.writeTool(call: call, result: nil, prefix: prefix, block: previous)
      bufferToolCalls[context.runID, default: [:]][call.id] = block
      return
    }
    let preview = ToolCallPreview.render(call, display: ui.toolCalls)
    if tools == .icons {
      if updating { return }
      iconToolCalls[context.runID, default: []].insert(call.id)
      toolIcon(ToolIcon.emoji(for: call.name), context: context)
    } else if tools == .lines(0) {
      compactToolCalls[context.runID, default: [:]][call.id] = (String(preview.dropFirst(2)), ui.toolCalls)
    } else {
      toolStatus(preview, context: context, color: .toolCallForeground, background: .toolCallBackground,
        truncate: ui.toolCalls == .truncate)
    }
  }

  private func toolFinished(_ result: ToolResult, context: AgentEventContext) {
    let block = bufferToolCalls[context.runID]?.removeValue(forKey: result.callID)
    if bufferToolCalls[context.runID]?.isEmpty == true { bufferToolCalls[context.runID] = nil }
    if let screen, screen.isBufferMode, REPLRedirection.current == nil {
      finishReply()
      closeRootLine()
      let prefix = context.depth > 0 ? context.pid.map { childPrefix($0) } ?? "" : ""
      _ = screen.writeTool(call: nil, result: result, prefix: prefix, block: block)
      return
    }
    let call = compactToolCalls[context.runID]?.removeValue(forKey: result.callID)
    if compactToolCalls[context.runID]?.isEmpty == true {
      compactToolCalls[context.runID] = nil
    }
    let wasIcon = iconToolCalls[context.runID]?.remove(result.callID) != nil
    if iconToolCalls[context.runID]?.isEmpty == true { iconToolCalls[context.runID] = nil }
    if wasIcon { return }
    if tools == .icons {
      toolIcon(ToolIcon.emoji(for: ""), context: context)
      return
    }
    // Finish a compact call in the same format even if the display setting
    // changed while it ran. Some rejected calls arrive without a start event.
    if call != nil || tools == .lines(0) {
      let marker = result.isError ? "✘" : "✔"
      toolStatus(
        "\(marker) \(call?.text ?? (result.isError ? "error" : "done"))",
        context: context, color: result.isError ? .errorForeground : .toolCallForeground,
        background: .toolCallBackground, truncate: (call?.display ?? ui.toolCalls) == .truncate)
    } else {
      toolStatus(
        ToolResultPreview.render(result, display: tools), context: context,
        color: result.isError ? .errorForeground : .toolResultForeground,
        background: .toolResultBackground, diff: true)
    }
  }

  private func toolStatus(
    _ text: String, context: AgentEventContext, color: TerminalThemeStyle,
    background: TerminalThemeStyle, diff: Bool = false, truncate: Bool = false
  ) {
    let prefix = context.depth > 0 ? context.pid.map { childPrefix($0) } ?? "" : ""
    let text = truncate && terminalOutput && REPLRedirection.current == nil
      ? TerminalToolBlock.truncatedCall(text, width: TerminalLineEditor.terminalColumns(), prefix: prefix)
      : text
    if context.depth > 0, let pid = context.pid {
      childBlock(pid, text, color: color, background: background, diff: diff)
    } else {
      status(text, color: color, background: background, diff: diff)
    }
  }

  /// Keep consecutive classic-mode calls on a single live output line.
  private func toolIcon(_ icon: String, context: AgentEventContext) {
    let prefix = context.depth > 0 ? context.pid.map { childPrefix($0) } ?? "" : ""
    if iconLinePrefix != prefix { finishIconLine() }
    let text = (iconLinePrefix == nil ? prefix : "") + icon
    iconLinePrefix = prefix
    if capturesOutput { captured.append(text) }
    else { emit(text, to: .standardError, continuingIcons: true) }
  }

  private func finishIconLine() {
    guard iconLinePrefix != nil else { return }
    iconLinePrefix = nil
    if capturesOutput { captured.append("\n") }
    else { emit("\n", to: .standardError, continuingIcons: true) }
  }

  // MARK: - Child blocks

  private func flushChildReasoning(_ pid: AgentPID) {
    guard let text = childReasoning.removeValue(forKey: pid) else { return }
    if let screen, screen.isBufferMode, REPLRedirection.current == nil {
      finishReply()
      closeRootLine()
      let body = styledLines(text, color: .thinkingForeground, diff: false).map {
        childPrefix(pid) + (colorsStatus ? "\u{1B}[3m\($0)\u{1B}[23m" : $0)
      }.joined(separator: "\n")
      screen.appendThinkingBlock(body)
      return
    }
    let visible =
      thinkingDisplay == .full
      ? text
      : thinkingDisplay == .status
        ? "Thinking…"
        : ThinkingPreview.lines(text, count: thinkingDisplay.lineCount, width: 70).joined(
          separator: "\n")
    childBlock(pid, visible, color: .thinkingForeground, italic: true)
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
    _ pid: AgentPID, _ text: String, color: TerminalThemeStyle? = nil,
    background: TerminalThemeStyle? = nil, italic: Bool = false, diff: Bool = false
  ) {
    finishReply()
    closeRootLine()
    let prefix = childPrefix(pid)
    let body = styledLines(text, color: color, background: background, diff: diff).map { line in
      prefix + (italic && colorsStatus ? "\u{1B}[3m\(line)\u{1B}[23m" : line)
    }.joined(separator: "\n")
    emitStatus(body)
  }

  private func childPrefix(_ pid: AgentPID) -> String {
    let label = "agent#\(pid.rawValue) "
    guard colorsStatus else { return label }
    return styled(label, foreground: Self.childColors[abs(pid.rawValue) % Self.childColors.count])
  }

  private static let childColors: [TerminalThemeStyle] = [
    .promptForeground, .infoForeground, .toolCallForeground, .successForeground,
    .diffHeaderForeground, .toolResultForeground, .warningForeground, .thinkingForeground,
  ]

  // MARK: - Writing

  /// Writes what the markdown renderer still holds for the current reply.
  private func finishReply() {
    finishThinking()
    var output = ""
    if var renderer = markdownRenderer {
      output = renderer.flush()
      markdown = renderer
    }
    if let screen, REPLRedirection.current == nil {
      screen.finishReply(rendered: output)
    } else {
      write(output)
    }
  }

  private func writeReply(_ text: String) {
    if !text.isEmpty { finishIconLine() }
    var output = text
    if var renderer = markdownRenderer {
      output = renderer.feed(text)
      markdown = renderer
    }
    if let screen, REPLRedirection.current == nil {
      screen.writeReply(text, rendered: output)
      if !output.isEmpty { outputEndedLine = output.hasSuffix("\n") }
    } else {
      write(output)
    }
  }

  private func showThinking(_ delta: String) {
    guard replyOwner == nil else { return }
    if !thinkingActive {
      finishReply()
      closeRootLine()
      thinkingActive = true
      thinkingPreview = ThinkingPreview()
      lastThinkingDraw = .distantPast
      if thinkingDisplay != .full && screen == nil {
        status("Thinking…", color: .thinkingForeground)
      }
    }
    let safe = delta.unicodeScalars.filter {
      $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
    }
    let text = String(String.UnicodeScalarView(safe))
    let styled =
      paintsOutput
      ? styled(text, foreground: .thinkingForeground, italic: true) : text
    if !text.isEmpty {
      if let screen, REPLRedirection.current == nil {
        screen.writeThinking(styled, full: thinkingDisplay == .full)
      } else if thinkingDisplay == .full {
        write(styled)
      }
    }
    if thinkingDisplay == .full {
      if !text.isEmpty { outputEndedLine = text.hasSuffix("\n") }
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
    if let screen, REPLRedirection.current == nil {
      screen.finishThinking()
      outputEndedLine = true
    } else if thinkingDisplay == .full && !outputEndedLine {
      write("\n")
    }
    thinkingActive = false
    thinkingPreview = ThinkingPreview()
  }

  private func write(_ value: String) {
    guard !value.isEmpty else { return }
    finishIconLine()
    outputEndedLine = value.hasSuffix("\n")
    if capturesOutput {
      captured.append(value)
      return
    }
    emit(value, to: .standardOutput)
  }

  private func emit(_ value: String, to handle: FileHandle, continuingIcons: Bool = false) {
    if !value.isEmpty && !continuingIcons { finishIconLine() }
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

  private func status(_ value: String, color: TerminalThemeStyle? = nil,
    background: TerminalThemeStyle? = nil, diff: Bool = false) {
    finishIconLine()
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    emitStatus(styledLines(value, color: color, background: background, diff: diff).joined(separator: "\n"))
  }

  private func emitStatus(_ styled: String) {
    finishIconLine()
    if capturesOutput {
      captured.append(styled + "\n")
      return
    }
    emit(styled + "\n", to: .standardError)
  }

  var retainsThemeStyles: Bool { screen != nil && REPLRedirection.current == nil }

  private func styled(
    _ text: String, foreground: TerminalThemeStyle?, background: TerminalThemeStyle? = nil,
    italic: Bool = false
  ) -> String {
    let toolCall = background == .toolCallBackground
    let annotation = retainsThemeStyles
      ? [foreground, background, toolCall ? .toolCallBold : nil].compactMap { $0?.marker }.joined() : ""
    return Self.styled(text, foreground: foreground?.value(in: ui),
      background: background?.value(in: ui), bold: toolCall && ui.toolCallBold,
      italic: italic, annotation: annotation)
  }

  private static func styled(
    _ text: String, foreground: String?, background: String? = nil, bold: Bool = false,
    italic: Bool = false, annotation: String = ""
  ) -> String {
    var codes = [
      foreground.flatMap(TerminalLineEditor.foregroundColorCode),
      background.flatMap(TerminalLineEditor.backgroundColorCode),
    ].compactMap { $0 }
    if italic { codes.insert("3", at: 0) }
    if bold { codes.insert("1", at: 0) }
    guard !codes.isEmpty || !annotation.isEmpty else { return text }
    let style = codes.isEmpty ? "" : "\u{1B}[\(codes.joined(separator: ";"))m"
    return style + annotation + text + "\u{1B}[0m"
  }

  /// Tool previews add a two-character prefix. Remove only that prefix when
  /// inspecting a diff, preserving its context marker and source indentation.
  private func styledLines(_ value: String, color: TerminalThemeStyle?,
    background: TerminalThemeStyle? = nil, diff: Bool) -> [String] {
    let lines = value.components(separatedBy: "\n")
    guard colorsStatus else { return lines }
    return TerminalThemeStyle.lineRoles(value, color: color, background: background, diff: diff).map {
      styled($0.text, foreground: $0.foreground, background: $0.background)
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
