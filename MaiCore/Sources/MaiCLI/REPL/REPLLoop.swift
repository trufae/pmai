import Foundation
import MaiCore
import MaiACP
import MaiStandardTools
import MaiVoice

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  /// What outlives one event of the loop: the turn in flight, who typed text
  /// goes to, and the tool calls waiting for an answer.
  private enum REPLTurnKind {
    case chat
    case btw
    case conversation
    case voice
  }

  /// One run in flight. A chat turn also remembers which chat it belongs to
  /// and what that chat held when it was sent, so its reply finds its way
  /// back even after the person edited the chat or moved to another one.
  private struct REPLTurn {
    let task: Task<AgentResult, any Error>
    let interrupt: REPLInterruptID
    let started: ContinuousClock.Instant
    let pid: AgentPID
    let kind: REPLTurnKind
    let chatID: UUID?
    let sent: [AgentMessage]
    let request: AgentRequest
    let redactor: ContentRedactor?
    /// Side questions collect output separately from the chat's stream.
    let output: TerminalWriter
    let redirection: REPLRedirection?
    /// `/hey` replaces this prompt once cancellation has finished.
    var restartPrompt: AgentMessage?
    var notifyParent = false
  }

  private struct REPLRestart {
    let turn: REPLTurn
    var request: AgentRequest
  }

  private struct REPLChatChop {
    let chatID: UUID
    var messageID: String
    let interrupt: REPLInterruptID
  }

  private struct REPLSummary {
    let id: UUID
    let task: Task<Void, Never>
    let interrupt: REPLInterruptID
    let chatID: UUID
    let sent: [AgentMessage]
    let pendingContent: [ContentPart]
    let redirection: REPLRedirection?
  }

  private struct REPLLimitDecision {
    let reason: AgentRunInterruption
    let id = UUID()
  }

  private struct REPLLoop {
    var activeTurn: REPLTurn?
    var btwTurns: [AgentPID: REPLTurn] = [:]
    var conversationTurns: [AgentPID: REPLTurn] = [:]
    var restarting: Set<AgentPID> = []
    var cancelledForRestart: Set<AgentPID> = []
    var restarts: [REPLRestart] = []
    var commandTarget: AgentPID?
    var summary: REPLSummary?
    var foregroundCommand: String?
    var thenLines: [String] = []
    var drainingThen = false
    var focus: REPLMessageTarget = .main
    var recoveredInputs = REPLRecoveredInput()
    var approvals: [(request: ApprovalRequest, reply: REPLApprovalReply)] = []
    var editingApproval: (request: ApprovalRequest, reply: REPLApprovalReply)?
    var compactions: [(request: AutocompactionRequest, reply: REPLCompactionReply)] = []
    var limitDecisions: [UUID: REPLLimitDecision] = [:]
    var pendingQueueMessage: String?
    var pendingQueueRedirection: REPLRedirection?
    var chatChop: REPLChatChop?
    /// Prompt/tab labels belong to this running REPL, never to saved configuration or chats.
    var chatTitles: [UUID: String] = [:]
    var resetID: UUID?
    /// True while the input thread waits for the loop before reading again.
    var readerParked = true
    var readerEnded = false
    var exiting = false

    var hasTurns: Bool {
      activeTurn != nil || !btwTurns.isEmpty || !conversationTurns.isEmpty || summary != nil
        || !restarting.isEmpty || !restarts.isEmpty
    }

    func turn(for pid: AgentPID) -> REPLTurn? {
      activeTurn?.pid == pid ? activeTurn : btwTurns[pid] ?? conversationTurns[pid]
    }

    mutating func update(_ turn: REPLTurn) {
      if turn.kind == .chat { activeTurn = turn }
      else if turn.kind == .btw { btwTurns[turn.pid] = turn }
      else { conversationTurns[turn.pid] = turn }
    }

    func modalPrompt(for chatID: UUID) -> REPLModalPrompt? {
      if let resetID { return .reset(id: resetID) }
      if let chop = chatChop {
        return .chop(id: "\(chop.interrupt.rawValue)-\(chop.messageID)")
      }
      if pendingQueueMessage != nil { return .queue }
      if let editing = editingApproval {
        return .approval(editing.request, id: editing.reply.id, editing: true)
      }
      if let waiting = approvals.first {
        return .approval(waiting.request, id: waiting.reply.id, editing: false)
      }
      if let waiting = compactions.first {
        return .compaction(waiting.request, id: waiting.reply.id)
      }
      if let decision = limitDecisions[chatID] { return .limit(decision.reason, id: decision.id) }
      return nil
    }

    /// Ctrl+C belongs to the most recently started run still in flight.
    var interruptTurn: REPLTurn? {
      (Array(btwTurns.values) + Array(conversationTurns.values) + [activeTurn].compactMap { $0 })
        .max { $0.interrupt.rawValue < $1.interrupt.rawValue }
    }

    var interruptOperation: (id: REPLInterruptID, cancel: @Sendable () -> Void)? {
      let turn = interruptTurn
      if let summary, summary.interrupt.rawValue > (turn?.interrupt.rawValue ?? 0) {
        return (summary.interrupt, { summary.task.cancel() })
      }
      if let turn { return (turn.interrupt, { turn.task.cancel() }) }
      return nil
    }

    mutating func beginExit() {
      exiting = true
      restarts.removeAll()
      activeTurn?.task.cancel()
      summary?.task.cancel()
      for turn in btwTurns.values { turn.task.cancel() }
      for turn in conversationTurns.values { turn.task.cancel() }
      cancelApprovals { _ in true }
      for pending in compactions { pending.reply.fail(CancellationError()) }
      compactions.removeAll()
    }

    mutating func cancelApprovals(matching matches: (ApprovalRequest) -> Bool) {
      approvals.removeAll { waiting in
        guard matches(waiting.request) else { return false }
        waiting.reply.fail(CancellationError())
        return true
      }
      if let waiting = editingApproval, matches(waiting.request) {
        waiting.reply.fail(CancellationError())
        editingApproval = nil
      }
    }
  }

  /// What a command may change under a running turn, taken before it runs
  /// so the person can be told how the change and the run meet.
  private struct REPLCommandSnapshot {
    let chatID: UUID
    let title: String
    let messages: [AgentMessage]
    let agent: AgentDefinition
    let directory: String

    init(session: REPLSession) {
      chatID = session.id
      title = session.title
      messages = session.history.messages
      agent = session.profile.agentDefinition
      directory = FileManager.default.currentDirectoryPath
    }
  }

  /// The value state a slash command may change. Commands run on a child task
  /// so Ctrl+C can cancel them while the event loop remains the sole owner of
  /// the live REPL state.
  struct REPLCommandResult: Sendable {
    var session: REPLSession
    var configuration: MaiConfiguration?
    var catalogs: [MCPServerCatalog]
    var exits: Bool
  }

  /// What a chat holds once a run that started from `sent` comes back with
  /// `result`. Usually nothing touched the chat meanwhile and the run's
  /// transcript is the chat. When the person edited it during the run, their
  /// edits stay and the run's additions follow. If they removed the prompt
  /// that started the run, its reply is discarded with it.
  static func mergedTranscript(
    current: [AgentMessage], sent: [AgentMessage], result: [AgentMessage]
  ) -> [AgentMessage] {
    AgentTranscriptEditor.mergeCompletedRun(current: current, sent: sent, result: result)
  }

  /// The REPL is one loop over one stream of events. Typed lines arrive from
  /// a thread of their own, so the prompt stays on screen while a turn runs;
  /// a turn ending, a tool asking for approval, and a change in the process
  /// table arrive on the same stream. On a terminal the prompt lives on two
  /// reserved rows under the output (`TerminalScreen`); piped input keeps the
  /// one-line-at-a-time behaviour, where a turn finishes before the next line
  /// is read.
  static func runREPL(
    workspace: inout AgentChatWorkspace,
    store: AgentChatStore,
    home: AgentHome,
    project: AgentProject,
    historyURL: URL,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: MaiConfiguration?,
    catalogs: [MCPServerCatalog],
    services: REPLServices,
    remoteTools: RemoteWorkspaceTools,
    pmaiBridge: PmaiCommandBridge,
    promptFileAccess: PromptFileAccess,
    terminal: TerminalWriter, startup: CLIStartupTiming
  ) async {
    startup.mark("REPL entered")
    do { try await AwakeController.shared.setEnabled(configuration?.awake ?? false) }
    catch { await terminal.line("awake: \(error.localizedDescription)", to: .standardError) }
    var configuration = configuration
    var catalogs = catalogs
    var project = project
    var store = store
    var selectedChat = workspace.selectedChat!
    if selectedChat.historyWindow != nil {
      let initialStore = store
      let id = selectedChat.id
      do {
        if let page = try await Task.detached(
          priority: .userInitiated,
          operation: {
            try initialStore.loadChatPage(id: id)
          }
        ).value {
          selectedChat = page
        }
      } catch { await terminal.line(error.localizedDescription, to: .standardError) }
    }
    var session = REPLSession(chat: selectedChat)
    await logDiagnosticConfiguration(
      session: session, configuration: configuration, runtime: runtime, services: services)
    let localProfile = session.profile
    var remoteReturnChatID: UUID?
    var remoteShell: ACPRemoteHost?
    let executable = (try? LocalExecutable.resolve(platformCommandLineArguments(environment: ProcessInfo.processInfo.environment)[0]))
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let remoteServer = RemoteREPLServer(home: home, executable: executable)
    /// Hands the loop's state to `pmai_run`, so a command the model runs
    /// starts from the same session, configuration and MCP catalogs the next
    /// typed command will see.
    func shareStateWithPmaiTools() {
      pmaiBridge.sync(
        session: session,
        configuration: configuration,
        catalogs: catalogs,
        chatProcess: chatProcessIDs[session.id])
    }
    /// Takes back what a command the model ran changed, so the loop keeps it
    /// instead of writing its own older copy over the saved file. A theme the
    /// tool applied repaints here, since the command's own terminal was a
    /// collector rather than the screen.
    func adoptPmaiToolChanges() async {
      guard let changes = pmaiBridge.takeChanges() else { return }
      session.profile = changes.profile
      configuration = changes.configuration
      catalogs = changes.catalogs
      await terminal.configureColors(configuration?.ui ?? .init())
    }
    let editor = TerminalLineEditor(historyURL: historyURL)
    var agentsMarkdownChoice: (directory: URL, mode: AgentsMDMode, approved: Bool)?
    var announcedAttention: Set<AgentPID> = []
    // One process per chat, not per turn: a background agent started three
    // turns ago is still the current run's child, so it stays collectable,
    // and a message typed while a turn runs has a pid to wait in.
    var chatProcessIDs: [UUID: AgentPID] = [:]
    var fileAccessLogs: [UUID: FileAccessLog] = [session.id: session.fileAccessLog]
    // Chats whose saved agents were put back in the process table this
    // session: once is enough, and clearing the table must not bring them
    // back.
    var restoredChatIDs: Set<UUID> = []
    if configuration?.providers.isEmpty != false {
      await terminal.line(aboutMessage)
    } else {
      await terminal.line("pmai — MaiCore agent REPL")
    }
    await terminal.line(
      "Project: \(project.displayName) · \(abbreviatedPath(project.workingDirectory)) · /project shows more"
    )
    await terminal.line(
      "Type /help for commands. \(promptIdentity(session)) · \(session.title)")
    let earlier = workspace.chats.filter { $0.id != session.id && $0.hasConversation }
    if !earlier.isEmpty {
      await terminal.line(
        "\(earlier.count) earlier chat\(earlier.count == 1 ? "" : "s") in this project: /chat list shows them, /chat use N switches."
      )
    }

    let (events, continuation) = AsyncStream<REPLEvent>.makeStream()
    var eventIterator = events.makeAsyncIterator()
    var deferredEvents: [REPLEvent] = []
    let interruptHandler = TerminalInterruptHandler {
      continuation.yield(.interrupt($0, endedInput: $1))
    }
    let reader = REPLInputReader(
      editor: editor,
      continuation: continuation,
      interrupt: { interruptHandler.requestInterrupt(endedInput: true) })
    let screen = TerminalScreen()
    if let screen {
      screen.configure(ui: tintedUI(configuration?.ui ?? .init(), project: project))
      screen.activate()
      TerminalScreen.install(screen)
      editor.install(surface: screen)
      await terminal.attach(screen: screen, supervisor: runtime.supervisor)
      await installInteractiveRunHost(screen: screen, inputGate: editor.inputGate)
      await services.approvalHandler.setPrompter { request in
        // Stream iteration wakes when the waiting agent's task is cancelled.
        let (decisions, pending) = AsyncThrowingStream<ApprovalDecision, any Error>.makeStream()
        let reply = REPLApprovalReply(pending)
        defer { continuation.yield(.approvalFinished(reply)) }
        if case .terminated = continuation.yield(.approval(request, reply)) {
          throw CancellationError()
        }
        var iterator = decisions.makeAsyncIterator()
        guard let decision = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return decision
      }
    }
    if isatty(STDIN_FILENO) != 0 {
      await services.approvalHandler.setCompactionPrompter { request in
        let (decisions, pending) = AsyncThrowingStream<AutocompactionDecision, any Error>.makeStream()
        let reply = REPLCompactionReply(pending)
        defer { continuation.yield(.compactionFinished(reply)) }
        if case .terminated = continuation.yield(.compaction(request, reply)) {
          throw CancellationError()
        }
        var iterator = decisions.makeAsyncIterator()
        guard let decision = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return decision
      }
    }
    let supervisorUpdates = REPLSupervisorUpdates()
    let supervisorFeed = Task {
      for await change in await runtime.supervisor.events() {
        if supervisorUpdates.insert(change) {
          Task {
            try? await Task.sleep(for: .milliseconds(100))
            continuation.yield(.supervisor)
          }
        }
      }
    }
    let progressClock = ContinuousClock()
    var nextSubagentSave = progressClock.now
    var loop = REPLLoop()
    var voiceSession: VoiceSession?
    var voiceID = UUID()
    var voicePID: AgentPID?
    var voiceChatID: UUID?
    var voiceHistory: [AgentMessage] = []
    var voiceContextCount = 0
    var voiceResumeAfterCancel = false
    var voiceDiscardAfterCancel = false
    editor.onVoiceControl = { continuation.yield(.voiceControl($0)) }
    for tool in VoiceAgentTools.tools(supervisor: runtime.supervisor) {
      try? await runtime.register(tool: tool, replacingExisting: true)
    }
    var activityWasInterrupted = false
    var visibleChatID = session.id
    var agentHistoryWindows: [AgentPID: ChatHistoryWindow] = [:]
    if screen != nil {
      editor.onAgentSwitch = { selection in
        let handled = DispatchSemaphore(value: 0)
        if case .terminated = continuation.yield(.switchAgent(selection, reply: { handled.signal() })) {
          return
        }
        handled.wait()
      }
    }

    func loadSessionHistory() async -> Bool {
      guard session.historyWindow != nil else { return true }
      let id = session.id
      let currentStore = store
      do {
        guard
          let chat = try await Task.detached(
            priority: .userInitiated,
            operation: {
              try currentStore.loadChatHistory(id: id)
            }
          ).value
        else { return false }
        session.history = AgentTranscript(messages: chat.messages)
        session.subagents = chat.subagents
        session.commands = chat.commands
        session.historyWindow = nil
        session.historyContextSize = nil
        session.historyChanges = chat.historyChanges
        return true
      } catch {
        await terminal.line(
          "Could not load the complete chat: \(error.localizedDescription)", to: .standardError)
        return false
      }
    }

    var messageViewHistory: (id: UUID, updatedAt: Date, messages: [AgentMessage])?

    func refreshConversation() async {
      if voiceSession != nil, await runtime.internetAccessPolicy().isOffline,
        configuration?.voice.input == "openai" || configuration?.voice.output == "openai" {
        await stopVoice()
      }
      if voiceChatID != nil, voiceChatID != session.id { await stopVoice() }
      if visibleChatID != session.id {
        visibleChatID = session.id
        loop.focus = .main
      }
      if case .agent(let pid) = loop.focus, await runtime.supervisor.info(pid) == nil {
        loop.focus = .main
      }
      if session.historyWindow == nil, session.history.count > 64,
        session.historyChanges.isCommitted(count: session.history.count),
        loop.activeTurn?.chatID != session.id,
        loop.summary?.chatID != session.id,
        loop.conversationTurns.values.allSatisfy({ $0.chatID != session.id })
      {
        let currentStore = store
        let id = session.id
        if let page = try? await Task.detached(
          priority: .utility,
          operation: {
            try currentStore.loadChatPage(id: id)
          }
        ).value {
          session.historyContextSize = AgentContextSize(messages: session.history.messages)
          session.history = AgentTranscript(messages: page.messages)
          session.historyWindow = page.historyWindow
          session.subagents = page.subagents
          workspace.upsert(session.chat)
          await runtime.supervisor.releaseFinishedTranscripts(page.subagents)
        }
      }
      guard let screen else { return }
      if !screen.viewNeedsMessages || session.historyWindow == nil { messageViewHistory = nil }
      if let window = session.historyWindow, window.range.isEmpty {
        let currentStore = store
        let id = session.id
        do {
          if let page = try await Task.detached(
            priority: .userInitiated,
            operation: {
              try currentStore.loadChatPage(id: id)
            }
          ).value {
            session.history = AgentTranscript(messages: page.messages)
            session.historyWindow = page.historyWindow
          }
        } catch { await terminal.line(error.localizedDescription, to: .standardError) }
      }
      if case .agent(let pid) = loop.focus {
        if let page = try? await runtime.supervisor.transcriptPage(
          pid, before: agentHistoryWindows[pid]?.range.upperBound)
        {
          agentHistoryWindows[pid] = page.window
          screen.selectConversation(
            "agent:\(pid.rawValue)",
            messages: session.redactor?.unredact(page.messages) ?? page.messages, window: page.window)
          screen.configureHistory(
            window: page.window, totalCount: page.window?.totalCount ?? page.messages.count
          ) { earlier in
            continuation.yield(.historyPage(earlier))
          }
        }
      } else {
        screen.selectConversation(
          "chat:\(session.id)", messages: session.history.messages, window: session.historyWindow)
        screen.configureHistory(
          window: session.historyWindow,
          totalCount: session.historyWindow?.totalCount ?? session.history.count
        ) { earlier in
          continuation.yield(.historyPage(earlier))
        }
      }
      if screen.viewNeedsMessages {
        let messages: [AgentMessage]
        if case .agent(let pid) = loop.focus {
          let transcript = await runtime.supervisor.transcript(pid)
          messages = session.redactor?.unredact(transcript) ?? transcript
        } else if let turn = loop.activeTurn, turn.chatID == session.id {
          let transcript = await runtime.supervisor.transcript(turn.pid)
          messages = mergedTranscript(
            current: session.history.messages, sent: turn.sent,
            result: turn.redactor?.unredact(transcript) ?? transcript)
        } else if session.historyWindow != nil {
          if messageViewHistory?.id != session.id || messageViewHistory?.updatedAt != session.updatedAt {
            let currentStore = store
            let id = session.id
            do {
              let chat = try await Task.detached(priority: .userInitiated) {
                try currentStore.loadChatHistory(id: id)
              }.value
              messageViewHistory = (id, session.updatedAt, chat?.messages ?? session.history.messages)
            } catch {
              await terminal.line("Could not load the complete chat: \(error.localizedDescription)", to: .standardError)
              return
            }
          }
          messages = messageViewHistory?.messages ?? session.history.messages
        } else {
          messages = session.history.messages
        }
        screen.updateViewMessages(messages)
      }
      if screen.viewNeedsTodo {
        screen.updateViewTodo(await terminal.renderTodoList(services.todo.current))
      }
      if screen.viewNeedsPrompt {
        if case .agent(let pid) = loop.focus {
          if await runtime.supervisor.info(pid)?.state.isTerminal == true {
            screen.updateViewPrompt(await runtime.supervisor.transcript(pid))
          }
        } else if loop.activeTurn?.chatID != session.id {
          screen.updateViewPrompt(session.history.messages)
        }
      }
    }

    func conversationTabs() async -> [AgentProcessInfo] {
      guard let root = chatProcessIDs[session.id] else { return [] }
      return await runtime.supervisor.tree().subtree(of: root).filter { !$0.isArchived }.sorted { $0.pid < $1.pid }
    }

    func refreshTerminalSettings() async {
      await refreshConversation()
      let ui = tintedUI(configuration?.ui ?? .init(), project: project)
      editor.configure(ui: ui)
      screen?.configure(ui: ui)
      await terminal.configureThinking(ui.thinking)
      await terminal.configureTools(ui.tools)
      await terminal.configureColors(ui)
      await terminal.configureSubagentOutput(ui.subagentOutput)
      session.redactor = await runtime.contentRedactor(sessionID: session.sessionID)
      await terminal.configureRedactor(session.redactor)
      await terminal.configureTerminalTitle(loop.chatTitles[session.id] ?? "")
      configureEditor(ui.editor)
      services.memory.focus(project: project, chatID: session.id)
      services.todo.focus(project: project)
      await runtime.configureMemory(services.memory.promptSection)
      let directory = AgentExecutionScope.directory.standardizedFileURL
      let mode = configuration?.use.agentsmd ?? .off
      let approved: Bool
      switch mode {
      case .on:
        agentsMarkdownChoice = nil
        approved = true
      case .off:
        agentsMarkdownChoice = nil
        approved = false
      case .ask, .maybe:
        if let choice = agentsMarkdownChoice,
          choice.directory == directory, choice.mode == mode
        {
          approved = choice.approved
        } else {
          approved = await Self.askForAgentsMarkdown(
            from: directory, editor: editor, terminal: terminal)
          agentsMarkdownChoice = (directory, mode, approved)
        }
      }
      await runtime.configureProjectInstructionDirectory(approved ? directory : nil)
      await runtime.configurePlanning(configuration?.use.plan ?? true)
    }

    func statusLine() async -> (text: String, animating: Bool) {
      if let modal = loop.modalPrompt(for: session.id) {
        return (modal.status, false)
      }
      var facts: [String] = []
      if await runtime.internetAccessPolicy().isOffline { facts.append("✈ offline") }
      var liveContext: AgentContextSize?
      var identitySession = session
      if case .agent(let pid) = loop.focus {
        liveContext = await runtime.supervisor.info(pid)?.contextSize
        if let request = await runtime.conversationSettings(for: pid) {
          identitySession.profile.agentID = request.agentID
          identitySession.profile.provider = request.provider
          identitySession.profile.model = request.model
          identitySession.profile.options = request.options
        } else if let info = await runtime.supervisor.info(pid), info.externalSessionID != nil {
          identitySession.profile.agentID = info.displayName
          identitySession.profile.provider = info.provider ?? identitySession.profile.provider
          identitySession.profile.model = info.model ?? "unknown"
          identitySession.profile.options.reasoningEffort = info.reasoningEffort ?? "unknown"
        }
      } else if let turn = loop.activeTurn, turn.chatID == session.id {
        liveContext = await runtime.supervisor.info(turn.pid)?.contextSize
      }
      let liveProcesses = await runtime.supervisor.liveProcesses()
      let counts = AgentProcessCounts(liveProcesses)
      let running = loop.foregroundCommand != nil || loop.summary != nil || (!activityWasInterrupted && counts.running > 0)
      let activityMarker = running ? "●" : "○"
      let activityPID: AgentPID? = if case .agent(let pid) = loop.focus { pid } else { loop.activeTurn?.pid }
      if let activityPID, let process = await runtime.supervisor.info(activityPID), !process.state.isTerminal {
        if process.pauseRequested || process.state == .paused { facts.append("paused") }
        else if process.state.isWaiting || process.state == .queued { facts.append(process.state.shortLabel) }
        else if ["waiting ", "HTTP headers", "stream data", "receiving "].contains(where: process.activity.hasPrefix) {
          facts.append(process.activity)
        } else { facts.append(process.activity.isEmpty || process.activity == "thinking" ? "thinking" : "running \(process.activity)") }
        if let usage = process.usage {
          facts.append("spent \(ModelUsageFormat.tokens(usage.totalTokens, estimated: usage.isEstimated))")
          if let reasoning = usage.reasoningTokens {
            facts.append("think \(ModelUsageFormat.count(reasoning))")
          }
        }
      }
      if !loop.btwTurns.isEmpty {
        facts.append("\(loop.btwTurns.count) btw running")
      }
      if let command = loop.foregroundCommand { facts.append("running \(command)") }
      if loop.summary != nil { facts.append("summarizing · Ctrl+C to cancel") }
      let children = liveProcesses.filter { $0.depth > 0 }
      if !children.isEmpty { facts.append(AgentProcessCounts(children).summary) }
      let queued = await runtime.supervisor.queuedMessages().count
      if queued > 0 { facts.append("\(queued) queued") }
      if configuration?.ui.broadcast == true {
        facts.append("→ all active")
      } else if case .agent(let pid) = loop.focus {
        facts.append("→ agent#\(pid.rawValue)")
      }
      let tabs = await conversationTabs()
      let selected: AgentPID? = if case .agent(let pid) = loop.focus { pid } else { chatProcessIDs[session.id] }
      let strip = AgentProcessNavigation.strip(tabs, selected: selected)
      let detail = facts.isEmpty ? "" : " · " + facts.joined(separator: " · ")
      return (
        "\(activityMarker)\(strip) \(currentDirectoryName()) \(promptIdentity(identitySession, contextSize: liveContext, includeContext: loop.focus == .main || liveContext != nil))\(detail)",
        running
      )
    }

    func inputPrompt() -> TerminalPrompt {
      if let modal = loop.modalPrompt(for: session.id) { return modal.input }
      let prompt: String
      if let remoteShell {
        prompt = "\(remoteShell.name)> "
      } else if configuration?.ui.broadcast == true {
        prompt = "pmai@*> "
      } else if case .agent(let pid) = loop.focus {
        // The prompt names the process a line goes to: a focused child, or the
        // chat's own once it has run, so its pid is at hand for /jobs commands.
        prompt = "pmai#\(pid.rawValue)> "
      } else if let pid = chatProcessIDs[session.id] {
        prompt = "pmai#\(pid.rawValue)> "
      } else {
        prompt = "pmai> "
      }
      let title = loop.chatTitles[session.id] ?? ""
      let conversationID: String
      if case .agent(let pid) = loop.focus { conversationID = "agent:\(pid.rawValue)" }
      else { conversationID = "chat:\(session.id)" }
      return TerminalPrompt(text: title.isEmpty ? prompt : "[\(title)] \(prompt)", conversationID: conversationID)
    }

    func refreshStatus() async {
      await refreshConversation()
      guard let screen else { return }
      services.modelCatalog.select(session.profile.provider)
      let status = await statusLine()
      reader.update(inputPrompt())
      screen.setStatus(
        status.text, animating: status.animating, attention: loop.modalPrompt(for: session.id) != nil,
        question: loop.modalPrompt(for: session.id)?.question,
        waiting: status.animating || loop.activeTurn != nil || loop.foregroundCommand != nil)
    }

    /// Lets the input thread read the next line. Settings that the editor
    /// reads are refreshed here, while the thread is parked and cannot race.
    func releaseReader(workspace: AgentChatWorkspace, duringForeground: Bool = false) async {
      if isatty(STDIN_FILENO) != 0 {
        services.modelCatalog.select(session.profile.provider)
      }
      guard loop.readerParked, !loop.readerEnded, !loop.exiting,
        !loop.drainingThen || duringForeground else { return }
      await refreshTerminalSettings()
      if screen == nil {
        // Announcing while the classic editor owns the row would corrupt it,
        // so on a plain terminal this happens between prompts.
        await announceAgentAttention(
          runtime: runtime, announced: &announcedAttention, terminal: terminal)
      }
      let status = await statusLine()
      screen?.setStatus(
        status.text, animating: status.animating, attention: loop.modalPrompt(for: session.id) != nil,
        question: loop.modalPrompt(for: session.id)?.question,
        waiting: status.animating || loop.activeTurn != nil || loop.foregroundCommand != nil)
      if screen?.viewNeedsHistory == true {
        screen?.updateViewHistory((try? REPLHistoryCommand.run("", editor: editor)) ?? "No input history.")
      }
      screen?.watchViewDiffs(in: AgentExecutionScope.directory)
      loop.readerParked = false
      let availableProviders = await runtime.availableProviders()
      let availableToolGroups = await runtime.availableToolGroups()
      let completionSession = session
      let completionStore = store
      let completionWorkspace = workspace
      let completionConfiguration = configuration
      let completionOffline = await runtime.internetAccessPolicy().isOffline
      let completionCache = REPLCompletionCache()
      let shellMode = remoteShell != nil
      let focusedMessages: [AgentMessage]?
      if case .agent(let pid) = loop.focus {
        let messages = await runtime.supervisor.transcript(pid)
        focusedMessages = session.redactor?.unredact(messages) ?? messages
      } else {
        focusedMessages = nil
      }
      reader.resume(
        with: REPLInputReader.Prompt(
          presentation: inputPrompt(),
          // Skill and theme discovery belongs to Tab, not the first prompt
          // or every subsequent input handoff.
          completions: [],
          additionalCompletions: { line in
            if shellMode { return ["exit", "/remote shell off", "/remote ls ", "/remote get ", "/remote put "] }
            if line.hasPrefix("/msg unpin ") {
              // Paged histories may have pins outside the visible window.
              let messages = focusedMessages
                ?? (completionSession.historyWindow != nil
                  ? try? completionStore.loadChatHistory(id: completionSession.id)?.messages : nil)
                ?? completionSession.history.messages
              return messages.filter(\.isPinned).map { "/msg unpin \($0.id)" }
            }
            return completionCache.values {
              completionCandidates(
                workspace: completionWorkspace, configuration: completionConfiguration,
                availableProviders: availableProviders, toolGroups: availableToolGroups,
                skills: services.skills.catalog.skills, themesDirectory: services.themesDirectory)
            }
              + services.modelCatalog.completions(for: line, runtime: runtime)
              + services.voiceCatalog.completions(for: line, configuration: completionConfiguration ?? .init(),
                plugins: plugins, offline: completionOffline)
          },
          separator: screen == nil ? status.text : nil))
    }

    /// On a plain terminal a turn owns the screen, so the next line waits for
    /// it; on the persistent screen the prompt is always open.
    func releaseIfIdle(workspace: AgentChatWorkspace) async {
      if screen != nil || !loop.hasTurns || !loop.compactions.isEmpty {
        await releaseReader(workspace: workspace)
      }
    }

    /// Local commands do not change providers, tools, or prompt settings.
    /// Reuse the published prompt instead of waiting on busy agent actors.
    func releaseLocalInput() async {
      guard screen != nil else {
        await releaseIfIdle(workspace: workspace)
        return
      }
      guard loop.readerParked, !loop.readerEnded, !loop.exiting, !loop.drainingThen else { return }
      if screen?.viewNeedsHistory == true {
        screen?.updateViewHistory((try? REPLHistoryCommand.run("", editor: editor)) ?? "No input history.")
      }
      loop.readerParked = false
      reader.resume()
    }

    func mainProcess() async -> AgentPID {
      if let pid = chatProcessIDs[session.id], await runtime.supervisor.info(pid) != nil {
        screen?.bindConversation("chat:\(session.id)", to: pid)
        return pid
      }
      let pid = await runtime.allocateProcess(agentID: session.profile.agentID, task: session.title)
      chatProcessIDs[session.id] = pid
      screen?.bindConversation("chat:\(session.id)", to: pid)
      return pid
    }

    /// Brings every chat's saved agents up to date with the process table:
    /// what runs under a chat's process, live or finished, replaces its
    /// saved copy, and what the table has since forgotten stays as saved.
    /// Called wherever the workspace is about to be written.
    func recordSubagents(only changedChats: Set<UUID>? = nil) async {
      let commands = runtime.commandHistory.records(sessionID: session.sessionID, saved: session.commands)
      if commands != session.commands {
        session.commands = commands
        session.touch()
      }
      fileAccessLogs[session.id] = session.fileAccessLog
      for (id, log) in fileAccessLogs where id != session.id {
        if var chat = workspace.chats.first(where: { $0.id == id }), chat.accessedFiles != log.snapshot() {
          chat.accessedFiles = log.snapshot()
          workspace.upsert(chat)
        }
      }
      if let configuration {
        session.runtimeConfiguration = AgentChatConfiguration(
          configuration: configuration, providerBaseURLs: services.providerBaseURLs.snapshot())
      }
      for (chatID, pid) in chatProcessIDs where changedChats?.contains(chatID) ?? true {
        guard
          let chat = chatID == session.id
            ? session.chat : workspace.chats.first(where: { $0.id == chatID })
        else { continue }
        let redactor = await runtime.contentRedactor(sessionID: chat.sessionID)
        let current = redactor.unredact(await runtime.conversationRecords(under: pid))
        if chatID == session.id {
          let records = AgentProcessRecord.merging(
            saved: session.subagents, current: current)
          if records != session.subagents {
            session.subagents = records
            session.touch()
          }
        } else if var chat = workspace.chats.first(where: { $0.id == chatID }) {
          let records = AgentProcessRecord.merging(saved: chat.subagents, current: current)
          let commands = runtime.commandHistory.records(sessionID: chat.sessionID, saved: chat.commands)
          if records != chat.subagents || commands != chat.commands {
            chat.subagents = records
            chat.commands = commands
            chat.touch()
            workspace.upsert(chat)
          }
        }
      }
    }

    // Provider and task registries are shared by running agents. Build all
    // providers before changing them, and leave a failed switch on its old chat.
    func restoreChatConfiguration(previous: REPLSession, isNewChat: Bool) async throws {
      guard previous.id != session.id else { return }
      fileAccessLogs[previous.id] = previous.fileAccessLog
      if let log = fileAccessLogs[session.id] { session.fileAccessLog = log }
      else { fileAccessLogs[session.id] = session.fileAccessLog }
      if isNewChat {
        session.runtimeConfiguration = previous.runtimeConfiguration
        return
      }
      let base: MaiConfiguration
      if let path = services.configurationPath, FileManager.default.fileExists(atPath: path) {
        base = try MaiConfiguration.load(from: URL(fileURLWithPath: path))
      } else {
        base = configuration ?? MaiConfiguration()
      }
      let draft = session.runtimeConfiguration?.applying(to: base) ?? base
      let saved = AgentChatConfiguration(configuration: draft)
      guard saved != previous.runtimeConfiguration else { return }
      guard await runtime.supervisor.liveProcesses().isEmpty else {
        throw CLIError.chatSettingsWhileRunning
      }
      var providers: [any ChatProvider] = []
      for provider in draft.providers {
        providers.append(
          try await plugins.makeProvider(
            from: provider, environment: ProcessInfo.processInfo.environment))
      }
      for provider in providers { try await runtime.register(provider, replacingExisting: true) }
      for agent in draft.agents {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      await runtime.configureTaskAgents(draft.taskAgents)
      configuration = draft
      services.providerBaseURLs.replace(
        Dictionary(
          uniqueKeysWithValues: draft.providers.compactMap { provider in
            provider.baseURL.map { (provider.id, $0) }
          }))
      services.modelCatalog.invalidate()
      session.runtimeConfiguration = saved
    }

    /// Puts the agents saved with the chat at the prompt back in the process
    /// table, once per chat and session, so `/jobs tree` and `/jobs log`
    /// show what earlier runs started before the chat's next turn.
    func restoreSavedSubagents() async {
      runtime.commandHistory.restore(session.commands)
      guard restoredChatIDs.insert(session.id).inserted, !session.subagents.isEmpty else {
        return
      }
      let pid = await mainProcess()
      let restored = await runtime.restoreConversations(session.subagents, under: pid, sessionID: session.sessionID)
      // Idle between turns, like a chat that has already run: listed as done,
      // cleared with the rest, and reopened by its next turn.
      await runtime.supervisor.complete(pid)
      guard !restored.isEmpty else { return }
      await terminal.line(
        "\(restored.count) agent\(restored.count == 1 ? "" : "s") from earlier runs of this chat: /jobs tree lists them, /jobs log PID reads one, /jobs clear drops them."
      )
    }

    /// Drops the agents saved with the chat at the prompt that the process
    /// table no longer holds, after `/jobs clear`. Answers how many went.
    func dropForgottenSubagents() async -> Int {
      let known = Set(await runtime.supervisor.processes().map(\.runID))
      var dropped = session.subagents.count
      session.subagents.removeAll { !known.contains($0.runID) }
      dropped -= session.subagents.count
      for var chat in workspace.chats
      where chat.id != session.id && restoredChatIDs.contains(chat.id) {
        let before = chat.subagents.count
        chat.subagents.removeAll { !known.contains($0.runID) }
        if before != chat.subagents.count {
          dropped += before - chat.subagents.count
          chat.touch()
          workspace.upsert(chat)
        }
      }
      return dropped
    }

    func beginTurn(
      _ request: AgentRequest, process pid: AgentPID, kind: REPLTurnKind, chatID: UUID? = nil,
      notifyParent: Bool = false
    ) async {
      let chatID = kind == .chat ? (chatID ?? session.id) : nil
      await logDiagnosticConfiguration(
        session: session, configuration: configuration, runtime: runtime, services: services)
      if let chatID { loop.limitDecisions.removeValue(forKey: chatID) }
      let redirection = REPLRedirection.current
      if let chatID { screen?.bindConversation("chat:\(chatID)", to: pid) }
      shareStateWithPmaiTools()
      if chatID == session.id {
        await recordSubagents()
        session.touch()
        workspace.upsert(session.chat, selecting: true)
        await saveWorkspace(&workspace, store: store, terminal: terminal)
      }
      let output = redirection != nil ? TerminalWriter()
        : kind == .btw ? TerminalWriter(capturesOutput: true) : terminal
      if kind == .btw || redirection != nil {
        let ui = configuration?.ui ?? .init()
        await output.configureRedactor(session.redactor)
        await output.configureThinking(ui.thinking)
        await output.configureTools(ui.tools)
        await output.configureSubagentOutput(ui.subagentOutput)
        await output.configureColors(ui)
        if redirection != nil {
          await output.attach(screen: screen)
        }
      }
      if kind != .conversation && kind != .voice { await output.resetResponse() }
      let fileAccessLog = session.fileAccessLog
      let voiceSink = pid == voicePID ? voiceSession : nil
      await voiceSink?.beginReply()
      let task = Task {
        try await withTaskCancellationHandler {
          try await FileAccessLog.$current.withValue(fileAccessLog) {
            try await runtime.run(request, process: pid, deliverToParent: notifyParent) { event in
              await output.consume(event)
              if event.terminalContext.pid == pid {
                await voiceSink?.consume(event)
              }
            }
          }
        } onCancel: {
          redirection?.cancel()
        }
      }
      let interrupt = interruptHandler.activate { task.cancel() }
      activityWasInterrupted = false
      let turn = REPLTurn(
        task: task, interrupt: interrupt, started: ContinuousClock.now, pid: pid, kind: kind,
        chatID: chatID, sent: request.messages, request: request, redactor: session.redactor,
        output: output, redirection: redirection, notifyParent: notifyParent
      )
      if kind == .btw {
        loop.btwTurns[pid] = turn
      } else if kind == .conversation || kind == .voice {
        loop.conversationTurns[pid] = turn
        await runtime.supervisor.attach(task, to: pid)
      } else {
        loop.activeTurn = turn
      }
      if let chop = loop.chatChop { interruptHandler.restore(chop.interrupt) {} }
      Task {
        let outcome: Result<AgentResult, any Error>
        do {
          outcome = .success(try await task.value)
        } catch {
          outcome = .failure(error)
        }
        continuation.yield(.turnFinished(pid, outcome))
      }
      await refreshStatus()
    }

    /// Snapshot every recipient before cancelling a parent can stop its children.
    /// Adopt runtime-owned children into the loop so their old completion is
    /// handled before any replacement starts with the same PID.
    func hey(_ addition: String, recipients: [AgentPID]) async {
      var targets: [REPLTurn] = []
      let tree = await runtime.supervisor.tree()
      for pid in recipients {
        if let turn = loop.turn(for: pid) {
          targets.append(turn)
        } else if let info = tree.info(pid), !info.state.isTerminal,
          let task = await runtime.supervisor.handle(pid),
          let request = await runtime.conversationRequest(for: pid)
        {
          let interrupt = interruptHandler.activate { task.cancel() }
          let turn = REPLTurn(
            task: task, interrupt: interrupt, started: .now, pid: pid, kind: .conversation,
            chatID: nil, sent: request.messages, request: request, redactor: session.redactor,
            output: terminal, redirection: nil, notifyParent: true)
          loop.update(turn)
          Task { continuation.yield(.turnFinished(pid, await task.result)) }
          targets.append(turn)
        } else {
          await terminal.note("No running prompt for agent#\(pid.rawValue).")
        }
      }
      // Cancelled descendants also need to finish before a parent is restarted.
      for pid in Set(targets.flatMap { tree.subtree(of: $0.pid).map(\.pid) }) {
        loop.cancelledForRestart.insert(pid)
        if loop.turn(for: pid) == nil,
          let task = await runtime.supervisor.handle(pid),
          let request = await runtime.conversationRequest(for: pid)
        {
          let interrupt = interruptHandler.activate { task.cancel() }
          loop.update(REPLTurn(
            task: task, interrupt: interrupt, started: .now, pid: pid, kind: .conversation,
            chatID: nil, sent: request.messages, request: request, redactor: session.redactor,
            output: terminal, redirection: nil, notifyParent: true))
          Task { continuation.yield(.turnFinished(pid, await task.result)) }
        }
        if loop.turn(for: pid) != nil { loop.restarting.insert(pid) }
      }
      for var turn in targets {
        guard var prompt = turn.restartPrompt ?? turn.sent.last(where: { $0.role == .user }) else {
          continue
        }
        if !addition.isEmpty {
          if case .text(let previous) = prompt.content.last {
            prompt.content[prompt.content.count - 1] = .text(previous + "\n" + addition)
          } else {
            prompt.content.append(.text(addition))
          }
        }
        turn.restartPrompt = prompt
        loop.update(turn)
        turn.task.cancel()
      }
      for turn in targets {
        let stopped = Set(await runtime.supervisor.stop(turn.pid, reason: "Restarting with /hey"))
        loop.cancelApprovals { $0.run.pid.map(stopped.contains) ?? false }
      }
      activityWasInterrupted = true
      await refreshStatus()
    }

    func startRestarts() async {
      guard loop.restarting.isEmpty, !loop.exiting else { return }
      let cancelled = loop.cancelledForRestart
      loop.cancelledForRestart.removeAll()
      guard !loop.restarts.isEmpty else { return }
      let tree = await runtime.supervisor.tree()
      // Children are running again before their parent can finish an answer.
      let pending = loop.restarts.sorted {
        (tree.info($0.turn.pid)?.depth ?? 0) > (tree.info($1.turn.pid)?.depth ?? 0)
      }
      loop.restarts.removeAll()
      for pid in cancelled {
        if let parent = tree.info(pid)?.parent {
          await AgentProcessTools.discardDelivery(of: pid, for: parent, supervisor: runtime.supervisor)
        }
      }
      for restart in pending {
        let turn = restart.turn
        await REPLRedirection.$current.withValue(nil) {
          guard await preparePromptFileAccess(
            for: restart.request.messages.last?.text ?? "", runtime: runtime, configuration: configuration,
            environment: ProcessInfo.processInfo.environment,
            promptFileAccess: promptFileAccess, approvalHandler: services.approvalHandler,
            terminal: terminal) else { return }
          await beginTurn(
            restart.request, process: turn.pid, kind: turn.kind, chatID: turn.chatID,
            notifyParent: turn.notifyParent)
        }
      }
    }

    /// Starts one turn with whatever is queued for the chat followed by the
    /// texts just typed. The turn runs in its own task; the loop hears about
    /// its end as an event.
    func startTurn(_ texts: [String], ignoringQueue: Bool = false) async {
      guard !session.profile.provider.rawValue.isEmpty else {
        await terminal.line("No provider selected. Type /about for setup commands.")
        return
      }
      for text in texts {
        guard await preparePromptFileAccess(
          for: text, runtime: runtime, configuration: configuration,
          environment: ProcessInfo.processInfo.environment,
          promptFileAccess: promptFileAccess, approvalHandler: services.approvalHandler,
          terminal: terminal)
        else { return }
      }
      let pid = await mainProcess()
      let held =
        ignoringQueue
        ? Set(await runtime.supervisor.queuedMessages(for: pid).map(\.id)) : []
      var messages = await runtime.supervisor.drainInbox(pid, excluding: held)
      messages.append(contentsOf: texts.map { AgentMessage.user($0) })
      guard !messages.isEmpty else { return }
      if !session.pendingContent.isEmpty {
        messages[0].content.append(contentsOf: session.pendingContent)
        session.pendingContent.removeAll()
      }
      for message in messages { session.history.append(message) }
      session.refreshTitle(from: messages[0].text)
      var request = chatRequest()
      request.ignoredQueuedMessageIDs = held
      await beginTurn(request, process: pid, kind: .chat)
    }

    /// The chat's whole local history. The runtime redacts every provider
    /// request, including later tool results, at the inference boundary.
    func chatRequest() -> AgentRequest {
      let profile = session.profile
      return AgentRequest(
        agentID: profile.agentID,
        provider: profile.provider,
        model: profile.model,
        messages: session.history.messages,
        systemContext: profile.systemContext,
        toolNames: profile.toolNames,
        toolGroupNames: profile.toolGroupNames,
        subagentNames: profile.subagentNames,
        toolChoice: profile.toolChoice,
        responseFormat: profile.responseFormat,
        options: profile.options,
        limits: profile.limits,
        stream: profile.stream,
        toolCallingStrategy: profile.toolCallingStrategy,
        useToolProxy: profile.useToolProxy,
        useSystemOne: profile.useSystemOne,
        proxyExposedTools: profile.proxyExposedTools,
        toolPolicy: profile.toolPolicy,
        toolDelegation: profile.toolDelegation,
        retry: profile.retry,
        autocompact: profile.autocompact,
        context: profile.context,
        sessionID: session.sessionID)
    }

    /// Picks a paused or interrupted task up where it stopped: the history is
    /// run again with a fresh budget and nothing new said, so the model sees
    /// its last tool results and carries on. Queued messages go with it, the
    /// way they would with a typed one.
    @discardableResult
    func continueTurn(limits: AgentRunLimits? = nil, withoutTools: Bool = false) async -> Bool {
      let pid = await mainProcess()
      if limits == nil, !withoutTools, await runtime.supervisor.hasQueuedMessages(pid) {
        await startTurn([])
        return true
      }
      guard let last = session.history.messages.last, last.role != .system else {
        await terminal.line("Nothing to continue yet: this chat has no messages.")
        return false
      }
      if last.role == .assistant, last.toolCalls.isEmpty, loop.limitDecisions[session.id] == nil {
        await terminal.line(
          "Nothing to continue: the last reply was complete. Type a message instead.")
        return false
      }
      var request = chatRequest()
      if let limits { request.limits = limits }
      if withoutTools {
        request.limits.maxToolCalls = 0
        request.limits.maxSubagents = 0
        request.toolChoice = .none
        request.useSystemOne = false
      }
      await beginTurn(request, process: pid, kind: .chat)
      return true
    }

    /// Folds what an interrupted run had already added into the chat, with
    /// any tool call it never answered marked as such, so the next turn — a
    /// typed one or /continue — starts from there instead of from before the
    /// run. Returns how many messages were kept.
    func keepPartialTranscript(of turn: REPLTurn, reason: String) async -> Int {
      guard let chatID = turn.chatID, let current = currentMessages(of: chatID) else { return 0 }
      let partial = await runtime.supervisor.transcript(turn.pid)
      guard !partial.isEmpty, partial != current else { return 0 }
      let kept = max(0, partial.count - turn.sent.count)
      settle(
        AgentTranscriptEditor.answeringUnansweredToolCalls(in: partial, reason: reason), from: turn)
      return kept
    }

    /// The messages a chat holds right now: the session's for the chat at the
    /// prompt, the workspace copy for any other. Nil once the chat is closed.
    func currentMessages(of chatID: UUID) -> [AgentMessage]? {
      if chatID == session.id { return session.history.messages }
      return workspace.chats.first { $0.id == chatID }?.messages
    }

    /// Folds a run's transcript into the chat it started from. That is
    /// usually the chat at the prompt, but the person may have moved to
    /// another chat or edited this one while the run was going; the reply
    /// still lands where the run began, after any edits made there meanwhile.
    /// The transcript is unredacted before storage so the local history keeps
    /// the original words.
    /// Answers false when that chat was closed in the meantime.
    @discardableResult
    func settle(_ transcript: [AgentMessage], from turn: REPLTurn) -> Bool {
      guard let chatID = turn.chatID, let current = currentMessages(of: chatID) else {
        return false
      }
      let unredacted = turn.redactor?.unredact(transcript) ?? transcript
      let merged = Self.mergedTranscript(current: current, sent: turn.sent, result: unredacted)
      if chatID == session.id {
        session.history.replaceAll(with: merged)
      } else if var chat = workspace.chats.first(where: { $0.id == chatID }) {
        chat.messages = merged
        chat.touch()
        workspace.upsert(chat)
      }
      return true
    }

    /// Runs a command with the running turn's Ctrl+C set aside, so a program
    /// the command hands the tty to — an editor, a shell — keeps its own
    /// Ctrl+C instead of ending the run.
    func withTurnInterruptSetAside(_ body: () async -> Void) async {
      let operation = loop.interruptOperation
      if let operation { interruptHandler.suspend(operation.id) }
      let shield = interruptHandler.activate(reports: false) {}
      await body()
      _ = interruptHandler.deactivate(shield)
      if let operation { interruptHandler.restore(operation.id, cancellation: operation.cancel) }
    }

    /// Gives Ctrl+C to one non-interactive command. Keep consuming input while
    /// it waits, buffering ordinary submissions until its state is applied.
    /// Commands that own stdin themselves leave resumeInput disabled.
    func runForeground<Value: Sendable>(
      _ name: String,
      resumeInput: Bool = true,
      operation: @escaping @Sendable () async -> Value
    ) async -> (value: Value, interrupted: Bool) {
      let previous = loop.interruptOperation
      if let previous { interruptHandler.suspend(previous.id) }
      let readsInput = screen != nil && resumeInput
      let id = UUID()
      let task = Task {
        let value = await operation()
        if readsInput { continuation.yield(.foregroundFinished(id)) }
        return value
      }
      let interrupt = interruptHandler.activate { task.cancel() }
      loop.foregroundCommand = name
      if readsInput {
        await releaseReader(workspace: workspace, duringForeground: true)
        while let event = await eventIterator.next() {
          if case .foregroundFinished(let finished) = event, finished == id { break }
          switch event {
          case .line(let raw, let heredoc, let promptID, let pasted, _):
            loop.readerParked = true
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !heredoc, text == "/stop" {
              interruptHandler.requestInterrupt()
            } else {
              deferredEvents.append(.line(
                raw, heredoc: heredoc, promptID: promptID, pasted: pasted, inputReleased: true))
              if !heredoc, ["/exit", "/quit"].contains(text) {
                interruptHandler.requestInterrupt()
              } else {
                await terminal.note("Queued until \(name) finishes. Ctrl+C or /stop cancels it.")
              }
            }
            await releaseReader(workspace: workspace, duringForeground: true)
          case .editInput(let draft, let command, _):
            loop.readerParked = true
            deferredEvents.append(.editInput(draft, command: command, inputReleased: true))
            await terminal.note("Editor queued until \(name) finishes.")
            await releaseReader(workspace: workspace, duringForeground: true)
          case .interrupt(let operation, let endedInput):
            if endedInput { loop.readerParked = true }
            // The signal/input path cancelled the registered task already.
            // Replay its other effects without parking the reopened reader.
            deferredEvents.append(.interrupt(operation, endedInput: false))
            await terminal.note("Cancelling \(name)…")
            await releaseReader(workspace: workspace, duringForeground: true)
          case .endOfFile:
            loop.readerEnded = true
            loop.readerParked = true
            interruptHandler.requestInterrupt()
            deferredEvents.append(event)
          case .switchAgent(let selection, let reply):
            // Navigation waits for acknowledgement on the input thread.
            // Queue its state change, but let that thread keep handling keys.
            deferredEvents.append(.switchAgent(selection, reply: {}))
            reply()
            await terminal.note("Agent switch queued until \(name) finishes.")
          default:
            deferredEvents.append(event)
          }
        }
      }
      let value = await task.value
      let interrupted = interruptHandler.deactivate(interrupt)
      loop.foregroundCommand = nil
      if let previous { interruptHandler.restore(previous.id, cancellation: previous.cancel) }
      return (value, interrupted)
    }

    func runRemoteWorkspace(_ action: String, arguments: [String], host: ACPRemoteHost) async throws {
      guard !(await runtime.internetAccessPolicy().isOffline) else {
        throw JSONRPCError.invalidParams("Turn off Airplane Mode before accessing remote hosts.")
      }
      let connection = try remoteServer.hosts.connection(for: host).workspace()
      let directory = AgentExecutionScope.directory
      _ = await runForeground("/remote \(action)", resumeInput: false) {
        do {
          try await RemoteWorkspaceCommand.run(action, arguments: arguments,
            connection: connection, directory: directory, terminal: terminal)
        } catch {
          await terminal.line(Task.isCancelled
            ? "Stopped remote operation; a command on the host may still be running."
            : "error: \(error.localizedDescription)", to: .standardError)
        }
      }
    }

    func openRemoteShell(_ host: ACPRemoteHost, mode: String = "auto") async throws {
      guard !(await runtime.internetAccessPolicy().isOffline) else {
        throw JSONRPCError.invalidParams("Turn off Airplane Mode before accessing remote hosts.")
      }
      if mode == "live", !RemoteTerminalRelay.available {
        throw JSONRPCError.invalidParams("Live shells require a supported terminal; use /remote shell HOST cmd.")
      }
      let connection = try remoteServer.hosts.connection(for: host).workspace()
      let result = await runForeground("/remote shell", resumeInput: false) {
        do {
          let live = mode != "cmd" && RemoteTerminalRelay.available
            ? try await connection.supportsInteractiveTerminal() : false
          if mode == "live", !live {
            throw JSONRPCError.invalidParams("This host supports command execution only; use cmd mode.")
          }
          if live { try await RemoteTerminalRelay.run(connection: connection, name: host.name) }
          await connection.close()
          return Optional(live)
        } catch {
          await connection.close()
          await terminal.line(Task.isCancelled ? "Stopped remote shell." : "error: \(error.localizedDescription)", to: .standardError)
          return Bool?.none
        }
      }
      if result.value == false && !result.interrupted {
        remoteShell = host
        await terminal.line("Remote shell \(host.name). Command mode: each command starts in \(host.cwd) with a fresh environment. Type exit to return to pmai.")
      } else {
        remoteShell = nil
        if result.value == true { await terminal.line("Left remote shell \(host.name).") }
      }
    }

    /// After a command ran under a turn: says how what it changed meets the
    /// run. Chat edits are merged when its reply lands; operational settings
    /// are pushed into the live request and observed at its next safe boundary.
    func noteTurnEffects(since before: REPLCommandSnapshot) async {
      guard let turn = loop.activeTurn else { return }
      if session.id != before.chatID {
        guard turn.chatID == before.chatID else { return }
        if workspace.chats.contains(where: { $0.id == before.chatID }) {
          await terminal.note(
            "The turn running in '\(before.title)' finishes there; its reply lands in that chat.")
        } else {
          await terminal.note(
            "The turn running in '\(before.title)' goes on without its chat; /jobs log \(turn.pid.rawValue) will show its reply, Ctrl+C cancels it."
          )
        }
        return
      }
      if session.history.messages != before.messages, turn.chatID == session.id {
        await terminal.note(
          "A turn is running; what it adds goes after this edit when it finishes.")
      }
      if FileManager.default.currentDirectoryPath != before.directory {
        await terminal.note("A turn is running; its tools now work in the new directory.")
      }
      if session.profile.agentDefinition != before.agent, turn.chatID == session.id,
        await runtime.reconfigure(turn.pid, with: chatRequest())
      {
        await terminal.note(
          "Updated the running agent; the operation already in flight finishes, and the next model or tool call uses these settings."
        )
      }
    }

    /// Runs a one-off prompt with the active profile and no conversation
    /// messages. Its task runs alongside the chat; its output is collected
    /// until completion so two root streams do not share rendering state.
    func startBTW(_ text: String) async {
      guard let request = btwRequest(text, profile: session.profile, sessionID: session.sessionID)
      else {
        await terminal.line("Usage: /btw PROMPT")
        return
      }
      do {
        let request = try await runtime.taskRequest(.btw, from: request)
        let pid = await runtime.allocateProcess(
          agentID: request.agentID, task: "btw: \(text)")
        await terminal.note("btw#\(pid.rawValue) started · Ctrl+C cancels it; /jobs kill \(pid.rawValue) stops it by ID")
        await beginTurn(request, process: pid, kind: .btw)
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    }

    /// Sends typed text where it belongs: to the chat as a new turn when it
    /// is idle, or into an inbox the running agent reads at its next turn.
    func deliver(_ text: String, to target: REPLMessageTarget) async {
      if REPLRedirection.current != nil, target != .main || loop.activeTurn != nil {
        await terminal.note("Redirected prompts need an idle main chat; finish the current turn and use /jobs focus main.", tone: .error)
        return
      }
      switch target {
      case .main:
        guard loop.activeTurn != nil else {
          let pid = await mainProcess()
          let count = await runtime.supervisor.queuedMessages(for: pid).count
          if count > 0 {
            loop.pendingQueueMessage = text
            loop.pendingQueueRedirection = REPLRedirection.current
            await terminal.line(
              "\(count) queued message(s). Submit them before this message, ignore them for this turn, or clear them? [submit/ignore/clear]"
            )
          } else {
            await startTurn([text])
          }
          return
        }
        let pid = await mainProcess()
        await runtime.supervisor.post(.user(text), to: pid)
        let waiting = await runtime.supervisor.queuedMessages(for: pid).count
        await terminal.note(
          "queued (\(waiting) waiting): it joins the conversation at the next model turn · /queue")
      case .agent(let pid):
        guard let info = await runtime.supervisor.info(pid) else {
          await terminal.note("No agent #\(pid.rawValue). /jobs tree lists the running ones.")
          return
        }
        if pid == chatProcessIDs[session.id] {
          await deliver(text, to: .main)
          return
        }
        guard info.externalSessionID == nil else {
          await terminal.note("ACP subagent #\(pid.rawValue) is controlled by its parent. Direct messages are not supported; /jobs log shows its work and /jobs cancel requests cancellation.")
          return
        }
        if pid == voicePID, loop.conversationTurns[pid] == nil {
          await startVoiceTurn(text)
          return
        }
        if info.depth > 0, info.state.isTerminal, loop.conversationTurns[pid] == nil {
          guard await preparePromptFileAccess(
            for: text, runtime: runtime, configuration: configuration,
            environment: ProcessInfo.processInfo.environment,
            promptFileAccess: promptFileAccess, approvalHandler: services.approvalHandler,
            terminal: terminal) else { return }
          guard var request = await runtime.conversationRequest(for: pid) else {
            await terminal.note("This older saved job has no conversation settings. Select main or create a new fork.")
            return
          }
          request.messages = AgentTranscriptEditor.answeringUnansweredToolCalls(
            in: request.messages, reason: "the previous run ended")
          request.messages.append(contentsOf: await runtime.supervisor.drainInbox(pid))
          request.messages.append(.user(text))
          await beginTurn(request, process: pid, kind: .conversation)
          return
        }
        await runtime.supervisor.post(.user(text), to: pid)
        let waiting = await runtime.supervisor.queuedMessages(for: pid).count
        let when =
          await runtime.supervisor.isPaused(pid)
          ? "it is paused, so /jobs continue \(pid.rawValue) delivers it"
          : "delivered at its next model turn"
        await terminal.note(
          "queued for agent#\(pid.rawValue) (\(info.agentID)) (\(waiting) waiting): \(when)"
        )
      }
      await refreshStatus()
    }

    func deliver(_ text: String, to addresses: [REPLMessageAddress]) async {
      do {
        let main = await mainProcess()
        let recipients = try await messageRecipients(
          addresses, main: main, supervisor: runtime.supervisor)
        for info in recipients where info.pid != main {
          await deliver(text, to: .agent(info.pid))
        }
        if recipients.contains(where: { $0.pid == main }) {
          await deliver(text, to: .main)
        }
      } catch {
        await terminal.note(error.localizedDescription)
      }
    }

    func closeChatChop() async {
      guard let chop = loop.chatChop else { return }
      loop.chatChop = nil
      _ = interruptHandler.deactivate(chop.interrupt)
      if let operation = loop.interruptOperation {
        interruptHandler.restore(operation.id, cancellation: operation.cancel)
      }
      await terminal.note("Chat chop closed.")
    }

    func showChatChopMessage() async {
      guard let chop = loop.chatChop,
        let index = session.history.index(ofMessageID: chop.messageID)
      else { return }
      await terminal.line(
        await renderChatMessage(
          session.history[index], index: index, count: session.history.count, terminal: terminal))
    }

    func answerChatChop(_ text: String) async {
      guard let chop = loop.chatChop else { return }
      if ["q", "quit"].contains(text.lowercased()) {
        await closeChatChop()
        return
      }
      guard chop.chatID == session.id,
        let index = session.history.index(ofMessageID: chop.messageID)
      else {
        await terminal.note("The selected message is no longer in this chat.")
        await closeChatChop()
        return
      }
      let before = REPLCommandSnapshot(session: session)
      switch text.lowercased() {
      case "n", "next", "b", "back", "prev", "previous":
        let next = index + (["n", "next"].contains(text.lowercased()) ? 1 : -1)
        guard session.history.messages.indices.contains(next) else {
          await terminal.line(next < 0 ? "Already at the first message." : "Already at the last message.")
          return
        }
        loop.chatChop?.messageID = session.history[next].id
      case "p", "pin", "unpin":
        let message = session.history[index]
        let pinned = text.lowercased() == "p" ? !message.isPinned : text.lowercased() == "pin"
        session.history.setMessagePinned(pinned, id: message.id)
        await terminal.line("\(pinned ? "📌 Pinned" : "Unpinned") message \(index + 1) (id: \(message.id)).")
      case "e", "edit":
        await editChatMessage(at: index, session: &session, terminal: terminal)
      case "d", "delete":
        await removeChatMessage(at: index, session: &session, terminal: terminal)
      case "x", "chop":
        await trimChatMessages(through: index, session: &session, terminal: terminal)
      default:
        await terminal.line("Choose n (next), b (previous), p (pin/unpin), e (edit), d (delete), x (chop after), or q (quit).")
        return
      }
      if session.history.messages != before.messages {
        // Linked tool-message removal can also remove earlier messages. Pick
        // the next surviving neighbor by ID instead of reusing a shifted index.
        if session.history.index(ofMessageID: chop.messageID) == nil {
          let remaining = Set(session.history.messages.map(\.id))
          let neighbor = before.messages.dropFirst(index + 1).first { remaining.contains($0.id) }
            ?? before.messages.prefix(index).last { remaining.contains($0.id) }
          if let neighbor { loop.chatChop?.messageID = neighbor.id }
        }
        session.touch()
        await recordSubagents()
        workspace.upsert(session.chat, selecting: true)
        await saveWorkspace(&workspace, store: store, terminal: terminal)
        await noteTurnEffects(since: before)
      }
      if session.history.isEmpty {
        await terminal.line("No conversation messages left.")
        await closeChatChop()
      } else {
        await showChatChopMessage()
      }
    }

    /// A modal owns ordinary input until answered. Slash commands remain available.
    func answerApproval(_ text: String) async -> Bool {
      if let editing = loop.editingApproval {
        // Settings and inspection remain available while an edit prompt is
        // open; only an ordinary line is interpreted as replacement JSON.
        if text.hasPrefix("/") { return false }
        if let data = text.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          value.objectValue != nil
        {
          loop.editingApproval = nil
          editing.reply.resume(with: .approve(arguments: value))
          await terminal.note("approved \(editing.request.tool.name) with the edited arguments")
        } else {
          await terminal.note(
            "Enter a valid JSON object for \(editing.request.tool.name), or Ctrl+C to cancel.", tone: .warning)
        }
        return true
      }
      guard let waiting = loop.approvals.first else { return false }
      if text.hasPrefix("/") { return false }
      let tool = waiting.request.tool.name
      switch text.lowercased() {
      case "y", "yes":
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool)")
      case "a", "always":
        do {
          try await services.approvalHandler.saveApprovalMode(.yolo, includingPaths: true)
        } catch {
          await terminal.note("Could not save yolo: \(error.localizedDescription). Choose s for this session.", tone: .warning)
          return true
        }
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool); yolo for tools and path approvals (saved for this project)")
      case "s", "session":
        await services.approvalHandler.setApprovalMode(.yolo)
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool); tool.approval = yolo for this session, including path approvals (not saved)")
      case let answer where ["t", "tool", "tool-specific-yolo"].contains(answer)
        && tool != "files_path_access":
        do {
          try await services.approvalHandler.saveToolYolo(tool)
        } catch {
          await terminal.note("Could not save tool-specific yolo: \(error.localizedDescription).", tone: .warning)
          return true
        }
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool); yolo for this tool only (saved for this project); path approvals still apply")
      case "n", "no":
        waiting.reply.resume(with: .deny(reason: "Denied by user."))
        await terminal.note("denied \(tool)")
      case "e" where tool != "files_path_access", "edit" where tool != "files_path_access":
        loop.approvals.removeFirst()
        loop.editingApproval = waiting
        await terminal.note("Type the replacement JSON arguments for \(tool):")
        return true
      case "c", "cancel":
        waiting.reply.resume(with: .cancelRun)
        await terminal.note("cancelling the run that asked for \(tool)")
      default:
        let prompt = REPLModalPrompt.approval(waiting.request, id: waiting.reply.id, editing: false)
        await terminal.note(
          "Answer \(prompt.input.choices.joined(separator: "/")) for \(tool). Slash commands remain available.", tone: .warning)
        return true
      }
      loop.approvals.removeFirst()
      await releasePendingApprovalsIfUnattended()
      return true
    }

    /// Choosing yolo approval while calls already wait for approval releases them as
    /// well as future calls. Otherwise the setting is live but the run still
    /// appears blocked on decisions made under the old value.
    func releasePendingApprovalsIfUnattended() async {
      if let editing = loop.editingApproval,
        await services.approvalHandler.permitsUnattendedApproval(editing.request)
      {
        editing.reply.resume(with: .approve(arguments: editing.request.call.arguments))
        loop.editingApproval = nil
      }
      var pending: [(request: ApprovalRequest, reply: REPLApprovalReply)] = []
      for approval in loop.approvals {
        if await services.approvalHandler.permitsUnattendedApproval(approval.request) {
          pending.append(approval)
        }
      }
      let approvedIDs = Set(pending.map { $0.reply.id })
      loop.approvals.removeAll { approvedIDs.contains($0.reply.id) }
      for approval in pending {
        approval.reply.resume(with: .approve(arguments: approval.request.call.arguments))
      }
      if !pending.isEmpty {
        await terminal.note(
          "approved \(pending.count) waiting tool call\(pending.count == 1 ? "" : "s"); yolo enabled for these tools"
        )
      }
    }

    func handleFocus(_ argument: String) async {
      let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        if configuration?.ui.broadcast == true {
          await terminal.line(
            "Messages go to every active agent. /set ui.broadcast off restores the focus.")
          return
        }
        switch loop.focus {
        case .main:
          await terminal.line(
            "Messages go to this chat. /jobs focus PID sends them to a running agent.")
        case .agent(let pid):
          await terminal.line(
            "Messages go to agent#\(pid.rawValue). /jobs focus main returns to the chat.")
        }
        return
      }
      guard let target = focusTarget(trimmed) else {
        await terminal.line("Usage: /jobs focus <PID|main>")
        return
      }
      switch target {
      case .main:
        loop.focus = .main
        await refreshConversation()
        await terminal.line(
          configuration?.ui.broadcast == true
            ? "Focus saved: main. Broadcast is on; @main TEXT addresses this chat."
            : "Messages go to this chat again.")
      case .agent(let pid):
        guard let info = await runtime.supervisor.info(pid) else {
          await terminal.line("No agent #\(pid.rawValue). /jobs tree lists the running ones.")
          return
        }
        guard info.depth > 0 else {
          if pid == chatProcessIDs[session.id] {
            await handleFocus("main")
          } else {
            await terminal.line("agent#\(pid.rawValue) belongs to another chat; /chat use selects its conversation.")
          }
          return
        }
        guard await conversationTabs().contains(where: { $0.pid == pid }) else {
          await terminal.line("agent#\(pid.rawValue) belongs to another chat; /chat use selects its conversation.")
          return
        }
        loop.focus = .agent(pid)
        await refreshConversation()
        if info.externalSessionID != nil {
          await terminal.line("Viewing ACP subagent #\(pid.rawValue). Its parent controls messages; /jobs cancel requests cancellation.")
          return
        }
        await terminal.line(
          configuration?.ui.broadcast == true
            ? "Focus saved: agent#\(pid.rawValue). Broadcast is on; @\(pid.rawValue) TEXT addresses this agent."
            : "Messages go to agent#\(pid.rawValue) (\(info.agentID)) until /jobs focus main; @main TEXT still reaches the chat."
        )
      }
    }

    func handleConversationCommand(_ name: String, argument: String) async -> Bool {
      guard case .agent(let pid) = loop.focus, let info = await runtime.supervisor.info(pid) else { return false }
      let action = argument.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
      let messageActions: Set<String> = ["list", "log", "last", "edit", "del", "delete", "rm", "undo", "trim", "rewind", "pin", "pins", "pinlist", "unpin"]
      guard name == "/copy" || name == "/last" || name == "/continue"
        || (name == "/msg" && messageActions.contains(action))
        || (name == "/chat" && action == "clear") else { return false }
      if info.externalSessionID != nil, name == "/continue"
        || (name != "/copy" && name != "/last" && !["list", "log", "last", "pins", "pinlist"].contains(action)) {
        await terminal.note("ACP subagent conversations are read-only. Their parent controls new work.")
        return true
      }
      var focused = session
      let messages = await runtime.supervisor.transcript(pid)
      focused.history.replaceAll(with: session.redactor?.unredact(messages) ?? messages)
      focused.title = info.displayName
      if name == "/continue" {
        if await runtime.supervisor.isPaused(pid) {
          await runtime.supervisor.resume(pid)
          await terminal.note("Continued agent#\(pid.rawValue).")
        } else if !info.state.isTerminal || loop.conversationTurns[pid] != nil {
          await terminal.note("agent#\(pid.rawValue) is already running.")
        } else if var request = await runtime.conversationRequest(for: pid) {
          let queued = await runtime.supervisor.drainInbox(pid)
          if queued.isEmpty, let last = request.messages.last,
            last.role == .assistant, last.toolCalls.isEmpty
          {
            await terminal.note("Nothing to continue: the last reply was complete. Type a message instead.")
          } else if request.messages.contains(where: { $0.role != .system }) || !queued.isEmpty {
            request.messages = AgentTranscriptEditor.answeringUnansweredToolCalls(
              in: request.messages, reason: "the previous run ended")
            request.messages.append(contentsOf: queued)
            await beginTurn(request, process: pid, kind: .conversation)
          } else {
            await terminal.note("Nothing to continue yet: this agent has no messages.")
          }
        } else {
          await terminal.note("This older saved job has no conversation settings. Select main or create a new fork.")
        }
      } else if name == "/copy" {
        await copyToClipboard(argument, session: focused, terminal: terminal)
      } else {
        let readOnly = name == "/last" || ["list", "log", "last", "pins", "pinlist"].contains(action)
        guard readOnly || info.state.isTerminal else {
          await terminal.note("Wait for this agent's turn to finish before editing its transcript.")
          return true
        }
        if action == "clear" {
          focused.history.replaceAll(with: focused.history.messages.filter { $0.role == .system })
          await terminal.line("Conversation cleared.")
        } else {
          await withTurnInterruptSetAside {
            await handleMessageCommand(
              name == "/last" ? "last" : argument,
              session: &focused, runtime: runtime, terminal: terminal)
          }
        }
        if !readOnly {
          await runtime.supervisor.note(pid, transcript: focused.history.messages)
          await recordSubagents()
          workspace.upsert(session.chat, selecting: true)
          await saveWorkspace(&workspace, store: store, terminal: terminal)
        }
      }
      return true
    }

    func switchAgent(_ selection: REPLAgentSwitch) async {
      let tabs = await conversationTabs()
      guard !tabs.isEmpty else { return }
      let current: AgentPID? = if case .agent(let pid) = loop.focus { pid } else { chatProcessIDs[session.id] }
      let index = tabs.firstIndex { $0.pid == current } ?? 0
      let target: AgentPID?
      switch selection {
      case .slot(let number):
        target = tabs.indices.contains(number - 1) ? tabs[number - 1].pid : nil
      case .next:
        target = tabs[(index + 1) % tabs.count].pid
      case .previous:
        target = tabs[(index + tabs.count - 1) % tabs.count].pid
      case .parent:
        target = tabs[index].parent ?? tabs.first?.pid
      }
      guard let target else { return }
      loop.focus = target == chatProcessIDs[session.id] ? .main : .agent(target)
      await refreshStatus()
    }

    func handleSubagents(_ argument: String) async {
      let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      switch value.lowercased() {
      case "next": await switchAgent(.next)
      case "previous", "prev": await switchAgent(.previous)
      case "parent": await switchAgent(.parent)
      case "main", "0": await handleFocus("main")
      case "", "list":
        let tabs = await conversationTabs()
        let selected: AgentPID? = if case .agent(let pid) = loop.focus { pid } else { chatProcessIDs[session.id] }
        var lines = ["Agent conversations:"]
        if tabs.isEmpty { lines.append("  1. main (current chat)") }
        for (index, info) in tabs.enumerated() {
          let marker = info.pid == selected ? "*" : " "
          let title = info.parent == nil ? session.title : info.displayName
          lines.append("\(marker) \(index + 1). #\(info.pid.rawValue) \(info.agentID) [\(info.state.shortLabel)] \(title)")
        }
        lines.append("/subagents PID|main|parent|next|prev switches; /fork [--empty] [TITLE] branches here.")
        lines.append("Alt+1…9 selects a slot; Ctrl+Left/Right cycles. Ctrl+1…9 works with extended keyboard protocols.")
        lines.append("Status: selected slot number · running ● · idle . · paused ‖ · attention !")
        await terminal.line(lines.joined(separator: "\n"))
      default:
        await handleFocus(value)
      }
    }

    func forkConversation(_ argument: String) async {
      var title = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      let empty = title == "--empty" || title.hasPrefix("--empty ")
      if empty { title = String(title.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
      let parent: AgentPID
      var request: AgentRequest
      if case .agent(let pid) = loop.focus {
        parent = pid
        guard let snapshot = await runtime.conversationRequest(for: pid) else {
          await terminal.line("This older saved job has no runtime settings. Select main to fork the saved chat.")
          return
        }
        request = snapshot
      } else {
        parent = await mainProcess()
        request = chatRequest()
        if loop.activeTurn?.chatID == session.id,
          let snapshot = await runtime.conversationRequest(for: parent), !snapshot.messages.isEmpty
        {
          request = snapshot
        }
        if loop.activeTurn == nil { await runtime.supervisor.complete(parent) }
      }
      if empty { request.messages = request.messages.filter { $0.role == .system } }
      else {
        request.messages = AgentTranscriptEditor.answeringUnansweredToolCalls(
          in: request.messages, reason: "forked before the tool finished")
      }
      if title.isEmpty { title = empty ? "New conversation" : "Conversation fork" }
      guard let pid = await runtime.forkConversation(request, parent: parent, title: title) else { return }
      loop.focus = .agent(pid)
      await refreshConversation()
      await terminal.line("Forked agent#\(parent.rawValue) into agent#\(pid.rawValue) (\(title)) and switched to it.")
      await recordSubagents()
      workspace.upsert(session.chat, selecting: true)
      await saveWorkspace(&workspace, store: store, terminal: terminal)
    }

    func stopVoice() async {
      voiceID = UUID()
      await voiceSession?.stop()
      voiceSession = nil
      await terminal.setVoiceProcess(nil)
      if let pid = voicePID {
        loop.conversationTurns[pid]?.task.cancel()
        _ = await runtime.supervisor.stop(pid, reason: "Voice disabled")
      }
      voicePID = nil; voiceChatID = nil; voiceHistory = []; voiceResumeAfterCancel = false; voiceDiscardAfterCancel = false
      screen?.setVoiceStatus(nil)
    }

    func startVoiceTurn(_ text: String) async {
      guard voiceSession != nil, voiceChatID == session.id, let pid = voicePID else { return }
      guard loop.conversationTurns[pid] == nil else {
        await runtime.supervisor.post(.user(text), to: pid)
        return
      }
      guard await loadSessionHistory() else { return }
      var request = chatRequest()
      if let parent = chatProcessIDs[session.id], loop.activeTurn?.pid == parent,
        let snapshot = await runtime.conversationRequest(for: parent) { request.messages = snapshot.messages }
      request.messages = AgentTranscriptEditor.answeringUnansweredToolCalls(
        in: request.messages, reason: "voice snapshot while the text conversation continues")
      do { request = try await runtime.taskRequest(.voice, from: request) }
      catch {
        await voiceSession?.finishReply(error: error.localizedDescription)
        return
      }
      let settings = configuration?.voice ?? .init()
      request.agentID = session.profile.agentID + ".voice"
      request.stream = true; request.context = .cache; request.responseFormat = .text
      request.toolNames.formUnion(VoiceAgentTools.names)
      for name in VoiceAgentTools.names { request.toolPolicy.tools[name] = .direct }
      let instructions = (configuration ?? .init()).systemPrompt(named: "voice")?.text
        ?? VoicePrompt.instructions
      if instructions != VoicePrompt.instructions {
        request.messages.removeAll { $0.role == .system && $0.text == VoicePrompt.instructions }
      }
      if !request.messages.contains(where: { $0.role == .system && $0.text == instructions }) {
        request.messages.append(.system(instructions))
      }
      request.messages.append(.system("Voice language: " + settings.languageIdentifier))
      request.messages += voiceHistory
      request.messages.append(contentsOf: await runtime.supervisor.drainInbox(pid))
      request.messages.append(.user(text))
      voiceContextCount = request.messages.count - voiceHistory.count - 1
      await terminal.voiceInput(text, pid: pid)
      await beginTurn(request, process: pid, kind: .voice)
    }

    func handleVoice(_ argument: String) async {
      let command = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["voices", "languages"].contains(command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "") {
        await showVoiceCatalog(argument, configuration: configuration, plugins: plugins, terminal: terminal,
          cache: services.voiceCatalog)
        return
      }
      if command == "help" {
        await terminal.line(voiceHelp); return
      }
      if command == "off" || command == "stop" {
        await stopVoice()
        await terminal.line("Voice: off. Use /voice on to start with the configured settings.")
        return
      }
      if command == "status" {
        let state = await voiceSession?.state.rawValue ?? "off"
        await terminal.line("Voice: \(state)\(voicePID.map { " · agent#\($0.rawValue)" } ?? "")")
        let settings = await voiceSession?.settings ?? configuration?.voice ?? .init()
        await terminal.line("\(voiceSession == nil ? "Configured" : "Active"): mode=\(settings.mode.rawValue), language=\(settings.languageIdentifier), input=\(settings.input), output=\(settings.output), voice=\(settings.voice), speed=\(settings.speed)")
        if settings.input == "openai" || settings.output == "openai" {
          await terminal.line("Audio provider=\(settings.provider ?? "unset"), transcriptionModel=\(settings.transcriptionModel), speechModel=\(settings.speechModel)")
        }
        if let error = await voiceSession?.error { await terminal.line("voice: \(error)", to: .standardError) }
        if voiceSession != nil, settings != (configuration?.voice ?? .init()) {
          await terminal.line("Saved settings differ from active voice. Apply them with /voice off then /voice on.")
        }
        return
      }
      if ["discard", "cancel", "pause", "send", "record", "resume"].contains(command), voiceSession == nil {
        await terminal.line("voice: Cannot \(command): voice is off. Start with /voice on, /voice realtime, or /voice walkie-talkie.", to: .standardError)
        return
      }
      if command == "discard" || command == "cancel" {
        voiceResumeAfterCancel = false
        await voiceSession?.discard()
        if let pid = voicePID, let turn = loop.conversationTurns[pid] {
          voiceDiscardAfterCancel = true
          turn.task.cancel()
        }
        return
      }
      if command == "pause" { await voiceSession?.pause(); return }
      if command == "send", let voiceSession {
        guard await voiceSession.state == .listening else {
          await terminal.line("voice: Nothing to send while \(await voiceSession.state.rawValue). Use /voice record to begin recording.", to: .standardError)
          return
        }
        await voiceSession.send(); return
      }
      if ["record", "resume"].contains(command), let voiceSession {
        if await voiceSession.state == .listening {
          await terminal.line("Voice is already recording. Use /voice send or /voice discard.")
          return
        }
        if let pid = voicePID, let turn = loop.conversationTurns[pid] {
          voiceResumeAfterCancel = true
          await voiceSession.pause()
          turn.task.cancel()
        } else if await voiceSession.canRecord { await voiceSession.record() }
        else {
          await terminal.line("voice: Cannot record while \(await voiceSession.state.rawValue). Wait for the current turn or use /voice discard.", to: .standardError)
        }
        return
      }
      guard ["", "on", "realtime", "walkie-talkie", "walkie", "ptt"].contains(command) else {
        await terminal.line("voice: Unknown command '\(argument)'. Use /voice help.", to: .standardError)
        await terminal.line(voiceHelp); return
      }
      if command == "on", let voiceSession {
        await terminal.line("Voice is already enabled (\(await voiceSession.state.rawValue)). Use /voice resume, or /voice off then /voice on to apply saved settings.")
        return
      }
      if command.isEmpty, voiceSession != nil {
        await stopVoice()
        await terminal.line("Voice: off. Use /voice on to start with the configured settings.")
        return
      }
      await stopVoice()
      guard await loadSessionHistory() else { return }
      var settings = configuration?.voice ?? .init()
      if command == "realtime" { settings.mode = .realtime }
      if ["walkie-talkie", "walkie", "ptt"].contains(command) { settings.mode = .walkieTalkie }
      do {
        try settings.validate()
        let inputFactory = try await plugins.voiceFactory(kind: settings.input)
        let outputFactory = try await plugins.voiceFactory(kind: settings.output)
        let config = configuration ?? .init()
        let environment = ProcessInfo.processInfo.environment
        let input = try await inputFactory.makeInput(settings: settings, configuration: config, environment: environment)
        let output = try await outputFactory.makeOutput(settings: settings, configuration: config, environment: environment)
        var request = try await runtime.taskRequest(.voice, from: chatRequest())
        request.agentID = session.profile.agentID + ".voice"
        let parent = await mainProcess()
        guard let pid = await runtime.forkConversation(request, parent: parent, title: "Voice agent") else { return }
        voicePID = pid; voiceChatID = session.id
        await terminal.setVoiceProcess(pid, parent: "chat:\(session.id)")
        let id = voiceID
        voiceSession = await VoiceSession(settings: settings, input: input, output: output,
          changed: { continuation.yield(.voiceStatus(id, $0)) },
          submit: { continuation.yield(.voiceTranscript(id, $0, $1)) })
        await terminal.note("Voice agent#\(pid.rawValue) · \(settings.mode.rawValue). Ctrl+T sends · Ctrl+G discards · Ctrl+Space records/sends. /voice off stops voice; /subagents \(pid.rawValue) opens its text conversation.")
        await voiceSession?.start()
      } catch { await terminal.line("voice: \(error.localizedDescription)", to: .standardError) }
    }

    await restoreSavedSubagents()
    reader.start()
    await releaseReader(workspace: workspace)
    startup.mark("prompt input released")

    func handleEvent(_ event: REPLEvent) async -> Bool {
      switch event {
      case .voiceControl(let control):
        if let voiceSession {
          switch control {
          case .send: await voiceSession.send()
          case .discard: await handleVoice("discard")
          case .toggleCapture:
            if await voiceSession.state == .listening { await voiceSession.send() }
            else { await handleVoice("record") }
          }
        }
      case .voiceStatus(let id, let status):
        guard id == voiceID else { return false }
        screen?.setVoiceStatus(status)
        if let status, status.contains(" · error · ") {
          await terminal.line("voice: \(await voiceSession?.error ?? status)", to: .standardError)
        } else if screen == nil, let status, !status.contains("listening") { await terminal.note(status) }
      case .voiceTranscript(let id, let token, let text):
        guard id == voiceID, await voiceSession?.acceptsSubmission(token) == true else { return false }
        if voiceChatID != session.id { await stopVoice() }
        else { await startVoiceTurn(text) }
      case .historyPage(let earlier):
        if case .agent(let pid) = loop.focus,
          let window = screen?.historyWindow ?? agentHistoryWindows[pid]
        {
          let before =
            earlier
            ? window.range.lowerBound + 32 : min(window.totalCount, window.range.upperBound + 32)
          do {
            let page = try await runtime.supervisor.transcriptPage(pid, before: before)
            agentHistoryWindows[pid] = page.window
            screen?.replaceHistory(
              messages: session.redactor?.unredact(page.messages) ?? page.messages, window: page.window)
            screen?.configureHistory(
              window: page.window, totalCount: page.window?.totalCount ?? page.messages.count
            ) { direction in
              continuation.yield(.historyPage(direction))
            }
          } catch { await terminal.line(error.localizedDescription, to: .standardError) }
          return false
        }
        guard case .main = loop.focus, let window = screen?.historyWindow ?? session.historyWindow,
          earlier ? window.hasEarlier : window.hasLater
        else { return false }
        let currentStore = store
        let id = session.id
        let before =
          earlier
          ? window.range.lowerBound + 32 : min(window.totalCount, window.range.upperBound + 32)
        do {
          if let page = try await Task.detached(
            priority: .userInitiated,
            operation: {
              try currentStore.loadChatPage(id: id, before: before)
            }
          ).value, session.id == id, (screen?.historyWindow ?? session.historyWindow) == window {
            session.history = AgentTranscript(messages: page.messages)
            session.historyWindow = page.historyWindow
            screen?.replaceHistory(messages: page.messages, window: page.historyWindow)
            await refreshConversation()
          }
        } catch { await terminal.line(error.localizedDescription, to: .standardError) }
      case .switchAgent(let selection, let reply):
        defer { reply() }
        guard loop.modalPrompt(for: session.id) == nil, !loop.exiting else { return false }
        await switchAgent(selection)
      case .foregroundFinished:
        break
      case .readerParked:
        loop.readerParked = true
      case .editInput(let draft, let command, _):
        loop.readerParked = true
        guard loop.modalPrompt(for: session.id) == nil else {
          editor.recoverInput(draft)
          await terminal.note("Finish the current question before editing a message. Your draft is kept.")
          await releaseIfIdle(workspace: workspace)
          return false
        }
        var message: String?
        await withTurnInterruptSetAside {
          message = await composeInput(from: draft, command: command, editor: editor, terminal: terminal)
        }
        if let message { await deliver(message, to: loop.focus) }
        await releaseIfIdle(workspace: workspace)
        return false
      case .line(let raw, let isHeredoc, let promptID, _, let inputReleased):
        var heredoc = isHeredoc
        if !loop.drainingThen && !inputReleased { loop.readerParked = true }
        let typed = heredoc ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heredoc, typed.hasPrefix("@") {
          do {
            if let addressed = try addressedMessage(typed), addressed.body.hasPrefix("/") {
              let main = await mainProcess()
              let recipients = try await messageRecipients(
                addressed.targets, main: main, supervisor: runtime.supervisor, allowFinished: true)
              let fields = addressed.body.split(maxSplits: 1, whereSeparator: \.isWhitespace)
              if fields.first == "/hey" {
                let addition = fields.count > 1
                  ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                await hey(addition, recipients: recipients.map(\.pid))
              } else {
                let focus = loop.focus
                let target = loop.commandTarget
                let draining = loop.drainingThen
                loop.drainingThen = true
                var exits = false
                for recipient in recipients {
                  loop.focus = recipient.pid == main ? .main : .agent(recipient.pid)
                  loop.commandTarget = recipient.pid
                  await terminal.note("agent#\(recipient.pid.rawValue): \(fields[0])")
                  if await handleEvent(.line(addressed.body, heredoc: false, promptID: nil)) {
                    exits = true
                    break
                  }
                }
                loop.focus = focus
                loop.commandTarget = target
                loop.drainingThen = draining
                await refreshStatus()
                if exits { return true }
              }
              await releaseIfIdle(workspace: workspace)
              return false
            }
          } catch {
            await terminal.note(error.localizedDescription)
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if !typed.hasPrefix("/"), promptID != loop.modalPrompt(for: session.id)?.input.id {
          loop.recoveredInputs.keep(raw, promptID: promptID)
          await terminal.note("The prompt changed before submission. Input kept as recovery item \(loop.recoveredInputs.entries.count); /recover lists it for review.", tone: .warning)
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if let host = remoteShell, loop.modalPrompt(for: session.id) == nil, typed != "/quit",
          !typed.hasPrefix("/remote ") || typed == "/remote shell off" {
          if ["exit", "/exit", "/remote shell off"].contains(typed) {
            remoteShell = nil
            await terminal.line("Left remote shell \(host.name).")
          } else {
            if !typed.isEmpty {
              do { try await runRemoteWorkspace("run", arguments: [raw], host: host) }
              catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
            }
          }
          await refreshStatus()
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if typed == "/recover" || typed.hasPrefix("/recover ") {
          let argument = typed.dropFirst("/recover".count).trimmingCharacters(in: .whitespaces)
          if argument == "clear" {
            loop.recoveredInputs.clear()
            await terminal.note("Recovered inputs cleared.")
          } else if let number = Int(argument) {
            if loop.modalPrompt(for: session.id) != nil {
              await terminal.note("Finish or cancel the current prompt before restoring a draft. Your input is still kept.")
            } else if let text = loop.recoveredInputs.take(number) {
              editor.recoverInput(text)
              await terminal.note("Recovered input restored as an editable draft.")
            } else { await terminal.note("No recovered input \(number). /recover lists the available items.") }
          } else {
            let entries = loop.recoveredInputs.entries
            await terminal.line(entries.isEmpty ? "No recovered input." : entries.enumerated().map {
              "\($0.offset + 1). [\($0.element.promptID ?? "message")] \($0.element.text)"
            }.joined(separator: "\n"))
            if !entries.isEmpty { await terminal.note("/recover N restores a draft for review; /recover clear discards kept inputs.") }
          }
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if loop.resetID != nil {
          if !heredoc, typed.lowercased() == "reset" {
            loop.resetID = nil
            let before = REPLCommandSnapshot(session: session)
            await adoptPmaiToolChanges()
            if await resetSettings(
              session: &session, runtime: runtime, plugins: plugins,
              configuration: &configuration, configurationPath: services.configurationPath,
              approvalHandler: services.approvalHandler, catalogs: &catalogs, terminal: terminal,
              remoteTerminalSettingsURL: services.remoteTerminalSettingsURL)
            {
              await stopVoice()
              await recordSubagents()
              workspace.upsert(session.chat, selecting: true)
              await saveWorkspace(&workspace, store: store, terminal: terminal)
              await noteTurnEffects(since: before)
              shareStateWithPmaiTools()
            }
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          } else if !heredoc, typed.lowercased() == "cancel" || typed.hasPrefix("/") {
            loop.resetID = nil
            await terminal.note("Reset cancelled.")
            if !typed.hasPrefix("/") {
              await refreshStatus()
              await releaseIfIdle(workspace: workspace)
              return false
            }
          } else {
            await terminal.line("Choose reset or cancel. Ctrl+C cancels.")
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        // `$NAME [TEXT]` is the short form of `/prompts NAME [TEXT]`.
        var text =
          !heredoc && loop.chatChop == nil && typed.hasPrefix("$")
          ? ("/prompts " + typed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
          : typed
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          await releaseIfIdle(workspace: workspace)
          return false
        }
        let commandFields = text.split(whereSeparator: \Character.isWhitespace).map(String.init)
        let metadataCommands = [
          "/help", "/history", "/version", "/about", "/then", "/unthen", "/stop", "/view", "/highlight",
          "/projects", "/project", "/remote", "/shell", "/exit", "/quit",
        ]
        let chatNavigation =
          commandFields.first == "/chat"
          && [
            "list", "chats", "ls", "use", "switch", "open", "next", "previous", "prev", "info",
            "new", "del", "delete", "rm",
          ].contains(commandFields.dropFirst().first ?? "")
        if session.historyWindow != nil, !metadataCommands.contains(commandFields.first ?? ""),
          !chatNavigation
        {
          guard await loadSessionHistory() else {
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if !heredoc, text == "/stop" {
          if let pid = loop.commandTarget {
            if var turn = loop.turn(for: pid) {
              turn.restartPrompt = nil
              loop.update(turn)
              turn.task.cancel()
            }
            loop.restarts.removeAll { $0.turn.pid == pid }
            let stopped = Set(await runtime.supervisor.stop(pid, reason: "Cancelled"))
            loop.cancelApprovals { $0.run.pid.map(stopped.contains) ?? false }
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          // Use the same event as Ctrl+C, including pending queue decisions.
          interruptHandler.requestInterrupt()
          return false
        }
        if !heredoc {
          let fields = text.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
          if fields.first == "/then" {
            if fields.count > 1 {
              loop.thenLines.append(String(fields[1]))
              await terminal.note("then: queued (\(loop.thenLines.count) waiting)")
            } else {
              await terminal.line(loop.thenLines.isEmpty ? "No /then actions queued."
                : loop.thenLines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if fields.first == "/unthen" {
            loop.thenLines.removeAll()
            await terminal.note("Cleared /then queue.")
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if loop.chatChop != nil {
          if !heredoc, text.hasPrefix("/") {
            await closeChatChop()
          } else {
            await answerChatChop(text)
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if !heredoc, commandFields.first == "/hey" {
          let main = await mainProcess()
          let pid = loop.commandTarget ?? loop.focus.pid(main: main)
          if loop.focus == .main, loop.commandTarget == nil, loop.activeTurn?.chatID != session.id {
            await terminal.note("No running chat prompt to interrupt.")
            await releaseIfIdle(workspace: workspace)
            return false
          }
          let addition = text.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
          await hey(addition, recipients: [pid])
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if !heredoc, case .limit(let reason, _)? = loop.modalPrompt(for: session.id) {
          let fields = text.lowercased().split(whereSeparator: \.isWhitespace)
          switch fields.first {
          case "extend", "e", "continue", "/continue":
            var limits = session.profile.limits
            if fields.count > 1 {
              guard fields.count == 2, let value = Int(fields[1]), value > 0 else {
                await terminal.line("Use extend or extend N, with a positive limit.")
                await releaseIfIdle(workspace: workspace)
                return false
              }
              switch reason {
              case .modelTurns: limits.maxModelTurns = value
              case .toolCalls: limits.maxToolCalls = value
              case .totalTokens: limits.maxTotalTokens = value
              case .time: limits.maxSeconds = value
              }
            }
            await continueTurn(limits: limits)
          case "answer", "a":
            await continueTurn(withoutTools: true)
          case "stop", "s":
            loop.limitDecisions.removeValue(forKey: session.id)
            await terminal.note("Stopped here. The work is saved; /continue resumes it.")
          default:
            if text.hasPrefix("/") { break }
            await terminal.line("Choose extend [N], stop, or answer (continue without tools). Slash commands remain available.")
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if ["extend", "e", "continue", "/continue", "answer", "a", "stop", "s"].contains(fields.first ?? "") {
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if let pending = loop.pendingQueueMessage {
          switch text.lowercased() {
          case "submit", "s":
            loop.pendingQueueMessage = nil
            loop.pendingQueueRedirection = nil
            await startTurn([pending])
          case "ignore", "i":
            loop.pendingQueueMessage = nil
            loop.pendingQueueRedirection = nil
            await startTurn([pending], ignoringQueue: true)
          case "clear", "c":
            loop.pendingQueueMessage = nil
            loop.pendingQueueRedirection = nil
            let pid = await mainProcess()
            await runtime.supervisor.clearQueuedMessages(for: pid)
            await startTurn([pending])
          default:
            await terminal.line(
              "Choose submit, ignore, or clear. Ctrl+C or /stop cancels this new message and keeps the queue."
            )
          }
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if !heredoc, await answerApproval(text) {
          await refreshStatus()
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if !heredoc, let waiting = loop.compactions.first {
          var decision: AutocompactionDecision?
          switch text.lowercased() {
          case "y", "yes", "compact", "s", "summarize": decision = .compact
          case "p", "prune":
            if waiting.request.pruning != nil {
              decision = .pruneToolOutput
            } else {
              await terminal.line("No older tool output can be shortened. Choose y to summarize, n to keep context, or c to stop.")
              await releaseIfIdle(workspace: workspace)
              return false
            }
          case "n", "no", "skip", "continue": decision = .continueWithoutCompacting
          case "c", "cancel", "stop": decision = .cancelRun
          case "m", "model":
            await terminal.line(
              "Use /model NAME to change all models, /model -chat NAME for chat only, or /model -compact NAME for the summarizer. Then choose y to summarize, p to prune available old tool output, or n to keep context."
            )
            await releaseIfIdle(workspace: workspace)
            return false
          case "x", "clear", "/chat clear":
            guard waiting.request.run.pid == chatProcessIDs[session.id] else {
              await terminal.line("Switch to the requesting chat before clearing it; c stops this run.")
              await releaseIfIdle(workspace: workspace)
              return false
            }
            decision = .clearChat
          default:
            if !text.hasPrefix("/") {
              await terminal.line("Choose y (summarize), p (prune available old tool output), n (keep context), m (model), x (clear chat), or c (stop). Slash commands remain available.")
              await releaseIfIdle(workspace: workspace)
              return false
            }
          }
          if let decision {
            loop.compactions.removeFirst()
            if decision == .clearChat {
              await terminal.line("Conversation cleared. Continuing with your latest message.")
            }
            waiting.reply.resume(with: decision)
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if !heredoc, text.split(whereSeparator: \.isWhitespace).first == "." {
          do {
            let paths = try shellWords(String(text.dropFirst()))
            guard paths.count == 1, let path = paths.first, !path.isEmpty else {
              throw JSONRPCError.invalidParams("Usage: . FILE (quote paths containing spaces)")
            }
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: AgentExecutionScope.directory)
            text = try String(contentsOf: url, encoding: .utf8)
            // File contents form one literal prompt, like a heredoc message.
            heredoc = true
          } catch {
            await terminal.line("source: \(error.localizedDescription)", to: .standardError)
            await releaseIfIdle(workspace: workspace)
            return false
          }
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if !heredoc, text == "@" {
          await terminal.line("Usage: @TEXT or @@ TEXT or @PID TEXT or @2,3 TEXT")
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if !heredoc {
          do {
            if let addressed = try addressedMessage(text) {
              await deliver(addressed.body, to: addressed.targets)
              await releaseIfIdle(workspace: workspace)
              return false
            }
          } catch {
            await terminal.note(error.localizedDescription)
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
        if !heredoc, text.hasPrefix("!") {
          if loop.hasTurns {
            await terminal.note("A turn is running; what it prints waits until the command ends.")
          }
          await withTurnInterruptSetAside {
            await runShellCommand(String(text.dropFirst()), terminal: terminal)
          }
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if !heredoc, text.hasPrefix("/") {
          let command = text.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
          let name = String(command[0])
          let argument =
            command.count > 1
            ? command[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
          if name == "/shell" {
            let mode = argument.isEmpty ? "auto" : argument
            if !["local", "auto", "live", "cmd"].contains(mode) {
              await terminal.line("Usage: /shell [local|auto|live|cmd]; /remote shell HOST [auto|live|cmd]", to: .standardError)
            } else if mode != "local", session.profile.provider.rawValue.hasPrefix("remote.") {
              do {
                guard let host = try remoteServer.hosts.hosts().first(where: { $0.providerID == session.profile.provider.rawValue }) else {
                  throw JSONRPCError.invalidParams("The current remote host is no longer paired. Use /remote pair to reconnect, or /shell local.")
                }
                try await openRemoteShell(host, mode: mode)
              } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
            } else if mode == "cmd" {
              await terminal.line("Use !COMMAND for local command/result execution.")
            } else if isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0 {
              await terminal.line("A local shell requires a terminal. Use !COMMAND for command/result execution.", to: .standardError)
            } else {
              await terminal.line("Local shell. Type exit to return to pmai.")
              await withTurnInterruptSetAside {
                #if os(Windows)
                await runShellCommand("cmd", terminal: terminal)
                #else
                #if canImport(Android)
                let fallback = "/system/bin/sh"
                #else
                let fallback = "/bin/sh"
                #endif
                let shellEnvironment = ProcessInfo.processInfo.environment
                let configured = shellEnvironment["SHELL"] ?? fallback
                let shell = (try? LocalExecutable.resolve(configured, environment: shellEnvironment)) ?? fallback
                do { _ = try TerminalCommand.run("exec \(shellQuote(shell)) -i") }
                catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
                #endif
              }
              await terminal.line("Left local shell.")
            }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/reset", argument.isEmpty {
            if configuration == nil || services.configurationPath == nil {
              await terminal.line("error: No writable configuration is active.", to: .standardError)
            } else {
              let id = UUID()
              loop.resetID = id
              await terminal.line(REPLModalPrompt.reset(id: id).question ?? "")
            }
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/view" {
            if let screen, screen.isBufferMode {
              if argument.isEmpty || argument == "help" {
                await terminal.line(viewHelp)
              } else if argument.lowercased() == "clear" {
                screen.clearView()
              } else {
                do {
                  let processes = await conversationTabs()
                  let selection = try viewSource(
                    argument, processes: processes,
                    tools: Set(await runtime.availableTools().map(\.name)),
                    mainConversation: "chat:\(session.id)")
                  for process in processes where process.depth > 0
                    && (selection.source == .conversations
                      || selection.source == .conversation("agent:\(process.pid.rawValue)"))
                  {
                    let messages = await runtime.supervisor.transcript(process.pid)
                    screen.seedConversation(
                      "agent:\(process.pid.rawValue)",
                      messages: session.redactor?.unredact(messages) ?? messages)
                  }
                  if selection.source == .prompt {
                    let instructions = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                    let template = try viewPromptTemplate(
                      String(instructions[1]), catalog: configuration?.promptCatalog() ?? PromptCatalog())
                    var request = chatRequest()
                    request.messages = []
                    let promptRequest = request
                    let redactor = session.redactor
                    screen.runViewPrompt(title: selection.title) { reply in
                      let output = try await runtime.summarize(reply, request: promptRequest) { source in
                        UserPrompt.message(text: template, arguments: source)
                      }
                      return redactor?.unredact(output) ?? output
                    }
                  } else {
                    screen.setView(selection.source, title: selection.title)
                    if selection.source == .jobs {
                      screen.watchViewJobs { width in
                        let processes = await runtime.supervisor.processes()
                        return await terminal.renderJobs(processes, width: width)
                      }
                    }
                  }
                } catch {
                  await terminal.line("error: \(error.localizedDescription)", to: .standardError)
                }
              }
            } else {
              await terminal.line(
                "error: /view requires ui.mode=buffer. Run /set ui.mode buffer in an interactive terminal.",
                to: .standardError)
            }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/history" {
            do {
              await terminal.line(try REPLHistoryCommand.run(argument, editor: editor))
            } catch {
              await terminal.line("error: \(error.localizedDescription)", to: .standardError)
            }
            await releaseLocalInput()
            return false
          }
          if name == "/remote" {
            do {
              let isRun = argument.split(whereSeparator: \.isWhitespace).first?.lowercased() == "run"
              let fields = try shellWords(argument, remainderAfter: isRun ? 2 : .max)
              let action = fields.first?.lowercased() ?? "list"
              let arguments = Array(fields.dropFirst())
              let hosts = remoteServer.hosts
              switch action {
              case "serve":
                guard !(await runtime.internetAccessPolicy().isOffline) else {
                  throw JSONRPCError.invalidParams("Turn off Airplane Mode before serving remote clients.")
                }
                let draft = configuration ?? MaiConfiguration()
                let agent = session.profile.agentDefinition
                let cwd = AgentExecutionScope.directory
                _ = await runForeground("/remote serve", resumeInput: false) {
                  do { try await remoteServer.start(arguments, configuration: draft, agent: agent, runtime: runtime, cwd: cwd, terminal: terminal) }
                  catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
                }
              case "stop":
                await remoteServer.stop()
                await terminal.line("Remote server stopped.")
              case "qr":
                await remoteServer.showPairing(terminal: terminal)
              case "list":
                await terminal.line(remoteServer.status())
                for host in try hosts.hosts() {
                  await terminal.line("\(host.name) · \(host.url.absoluteString) · /remote connect \(shellQuote(host.name))")
                }
              case "pair":
                guard (1...3).contains(arguments.count) else {
                  throw JSONRPCError.invalidParams("Usage: /remote pair URI_OR_QR_FILE [NAME] [CWD]")
                }
                let invitationText = try RemotePairingInput.read(arguments[0])
                if let link = try? OpenCodePairingLink.parse(invitationText) {
                  guard !(await runtime.internetAccessPolicy().isOffline) else {
                    throw JSONRPCError.invalidParams("Turn off Airplane Mode before pairing.")
                  }
                  guard arguments.count == 3, RemoteWorkspacePath.isAbsolute(arguments[2]) else {
                    throw JSONRPCError.invalidParams("Use /remote pair OPENCODE_LINK NAME /absolute/project")
                  }
                  let directory = arguments[2], hostName = arguments[1]
                  _ = await runForeground("/remote pair", resumeInput: false) {
                    do {
                      var profile = RemoteHostConnection(try await link.redeem())
                      profile.cwd = directory
                      let host = try hosts.pair(profile, name: hostName)
                      await terminal.line("Paired \(host.name). /remote connect \(shellQuote(host.name)) opens a chat; /remote ls \(shellQuote(host.name)) lists its files.")
                    } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
                  }
                  break
                }
                var profile = try ACPRemoteConnection.parse(invitationText)
                if arguments.count == 3 { profile.cwd = arguments[2] }
                if profile.requiresApproval == true {
                  guard !(await runtime.internetAccessPolicy().isOffline) else {
                    throw JSONRPCError.invalidParams("Turn off Airplane Mode before pairing.")
                  }
                  let idFile = home.rootURL.appendingPathComponent("client-id.json")
                  let clientID: String
                  if FileManager.default.fileExists(atPath: idFile.path) {
                    clientID = try JSONDecoder().decode(String.self, from: Data(contentsOf: idFile))
                  } else {
                    clientID = UUID().uuidString.lowercased()
                    try ACPStateFiles.write(clientID, to: idFile)
                  }
                  let invitation = profile
                  let pairing = await runForeground("/remote pair", resumeInput: false) {
                    let client = ACPClient(configuration: .init(command: invitation.name,
                      webSocketURL: invitation.url, bearerToken: invitation.token,
                      forwirohInvitation: invitation.forwirohInvitation))
                    await terminal.line("Waiting for \(invitation.name) to accept this client with /remote accept…")
                    do { return Optional(try await client.requestPairing(clientID: clientID, name: ProcessInfo.processInfo.hostName)) }
                    catch { await client.disconnect(); await terminal.line("error: \(error.localizedDescription)", to: .standardError); return String?.none }
                  }
                  guard let token = pairing.value, !pairing.interrupted else {
                    await releaseIfIdle(workspace: workspace)
                    return false
                  }
                  profile.token = token
                  profile.requiresApproval = false
                }
                let host = try hosts.pair(profile, name: arguments.count >= 2 ? arguments[1] : nil)
                await terminal.line("Paired \(host.name). /remote connect \(shellQuote(host.name)) opens a chat.")
              case "tools":
                guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
                  throw JSONRPCError.invalidParams("Usage: /remote tools HOST on|off")
                }
                let host = try hosts.host(arguments[0])
                let enabled = arguments[1] == "on"
                try hosts.setAgentAccess(enabled, for: host)
                if !enabled { await remoteTools.revoke(host: host.id.uuidString.lowercased()) }
                await terminal.line("Agent access to \(host.name): \(enabled ? "on" : "off"). Enable the remote tools for your agent with /tools.")
              case "ls", "get", "put", "run":
                guard let hostName = arguments.first else {
                  throw JSONRPCError.invalidParams("Usage: /remote \(action) HOST. /help remote lists arguments.")
                }
                try await runRemoteWorkspace(action, arguments: Array(arguments.dropFirst()), host: hosts.host(hostName))
              case "shell":
                guard (1...2).contains(arguments.count), arguments.count == 1 || ["auto", "live", "cmd"].contains(arguments[1]),
                  arguments[0] != "off" || arguments.count == 1
                else { throw JSONRPCError.invalidParams("Usage: /remote shell HOST [auto|live|cmd] | off") }
                if arguments[0] == "off" {
                  remoteShell = nil
                  await terminal.line("Returned to pmai.")
                } else {
                  guard !(await runtime.internetAccessPolicy().isOffline) else {
                    throw JSONRPCError.invalidParams("Turn off Airplane Mode before accessing remote hosts.")
                  }
                  let host = try hosts.host(arguments[0])
                  try await openRemoteShell(host, mode: arguments.count == 2 ? arguments[1] : "auto")
                }
              case "pending":
                let waiting = try await remoteServer.pendingClients()
                await terminal.line(waiting.isEmpty ? "No pairing requests are waiting." : waiting.joined(separator: "\n"))
              case "accept", "reject":
                guard arguments.count <= 1 else { throw JSONRPCError.invalidParams("Usage: /remote \(action) [CODE]") }
                await terminal.line(try remoteServer.resolvePairing(arguments.first, allow: action == "accept"))
              case "clients":
                for client in try await remoteServer.forwirohClients() { await terminal.line(client) }
                for client in try await remoteServer.pairingStore.clients() {
                  await terminal.line("\(client.id) · \(client.name)")
                }
              case "del":
                guard arguments.count == 1 else { throw JSONRPCError.invalidParams("Usage: /remote del CLIENT_ID") }
                try await remoteServer.revokeClient(arguments[0])
                await terminal.line("Revoked client \(arguments[0]).")
              case "connect":
                guard arguments.count == 1 else {
                  throw JSONRPCError.invalidParams("Usage: /remote connect NAME")
                }
                guard !loop.hasTurns else {
                  throw JSONRPCError.invalidParams("Finish or stop the current turn before connecting.")
                }
                guard !(await runtime.internetAccessPolicy().isOffline) else {
                  throw JSONRPCError.invalidParams("Turn off Airplane Mode before connecting.")
                }
                let host = try hosts.host(arguments[0])
                let provider = hosts.provider(for: host)
                let probe = try hosts.connection(for: host).makeSession()
                let checked = await runForeground("/remote connect", resumeInput: false) {
                  do { _ = try await probe.workspace(); await probe.disconnect(); return true }
                  catch { await probe.disconnect(); await terminal.line("error: \(error.localizedDescription)", to: .standardError); return false }
                }
                if checked.value && !checked.interrupted {
                  guard let configPath = services.configurationPath else {
                    throw JSONRPCError.invalidParams("No writable configuration is active")
                  }
                  var draft = configuration ?? MaiConfiguration()
                  draft.providers.removeAll { $0.id == provider.id }
                  draft.providers.append(provider)
                  let agent = AgentDefinition(id: host.providerID, displayName: host.name,
                    description: "Remote agent on \(host.name)", instructions: "", provider: .init(host.providerID), model: host.providerID)
                  draft.upsertAgent(agent)
                  let built = try await plugins.makeProvider(from: provider, environment: ProcessInfo.processInfo.environment)
                  try draft.save(to: URL(fileURLWithPath: configPath))
                  try await runtime.register(built, replacingExisting: true)
                  try await runtime.register(agent: agent, replacingExisting: true)
                  configuration = draft
                  services.modelCatalog.invalidate()
                  await recordSubagents()
                  workspace.upsert(session.chat, selecting: true)
                  if !session.profile.provider.rawValue.hasPrefix("remote.") { remoteReturnChatID = session.id }
                  session = REPLSession(chat: workspace.startNewChat(primaryAgent: agent))
                  await saveWorkspace(&workspace, store: store, terminal: terminal)
                  await terminal.line("Connected to \(host.name). Messages run on that host; /remote disconnect returns to your local chat.")
                }
              case "disconnect":
                guard !loop.hasTurns else {
                  throw JSONRPCError.invalidParams("Finish or stop the current turn before disconnecting.")
                }
                workspace.upsert(session.chat, selecting: true)
                let chat = workspace.chats.first { $0.id == remoteReturnChatID }
                  ?? workspace.orderedChats.first { !$0.primaryAgent.provider.rawValue.hasPrefix("remote.") }
                if let chat {
                  await switchSession(to: chat, session: &session, workspace: &workspace, terminal: terminal)
                } else {
                  let agent = configuration?.agents.first { $0.id == configuration?.defaultAgent }
                    ?? localProfile.agentDefinition
                  session = REPLSession(chat: workspace.startNewChat(primaryAgent: agent))
                }
                remoteReturnChatID = nil
                await saveWorkspace(&workspace, store: store, terminal: terminal)
                await terminal.line("Using your local chat.")
              case "help": await terminal.line(remoteHelp)
              default: throw JSONRPCError.invalidParams("Unknown /remote command. /help remote lists commands.")
              }
            } catch {
              await terminal.line("error: \(error.localizedDescription)", to: .standardError)
            }
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/queue" {
            let main = await mainProcess()
            await handleQueueCommand(
              argument,
              defaultAddress: configuration?.ui.broadcast == true ? .active : .target(loop.focus),
              main: main, runtime: runtime, terminal: terminal)
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if await handleConversationCommand(name, argument: argument) {
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/fork" || name == "/subagents" {
            if name == "/fork" { await forkConversation(argument) }
            else { await handleSubagents(argument) }
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          let jobArgument = jobsArgument(for: name, argument: argument)
          let jobFields =
            jobArgument?.split(maxSplits: 1, whereSeparator: \Character.isWhitespace) ?? []
          if jobFields.first?.lowercased() == "focus" {
            await handleFocus(jobFields.count > 1 ? String(jobFields[1]) : "")
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if jobFields.count == 1, jobFields.first?.lowercased() == "clear" {
            let cleared = Set(await runtime.supervisor.clearFinished())
            // A chat whose idle process went with them gets a fresh one at
            // its next turn; nothing it said is lost, the session has it.
            chatProcessIDs = chatProcessIDs.filter { !cleared.contains($0.value) }
            // Clearing is also how the agents saved with this chat are
            // purged: what stays in its file is what the table still holds.
            let dropped = await dropForgottenSubagents()
            if dropped > 0 {
              workspace.upsert(session.chat, selecting: true)
              await saveWorkspace(&workspace, store: store, terminal: terminal)
            }
            let summary =
              switch (cleared.count, dropped) {
              case (0, 0): "No finished agents to clear."
              case (let count, 0):
                "Cleared \(count) finished agent\(count == 1 ? "" : "s"); /jobs tree lists what still runs."
              case (0, let dropped):
                "Dropped \(dropped) agent\(dropped == 1 ? "" : "s") saved with this chat."
              case (let count, let dropped):
                "Cleared \(count) finished agent\(count == 1 ? "" : "s") and dropped \(dropped) saved with this chat; /jobs tree lists what still runs."
              }
            await terminal.line(summary)
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/exit" || name == "/quit" {
            await stopVoice()
            loop.beginExit()
            if loop.hasTurns { return false }
            return true
          }
          if name == "/continue" {
            if loop.activeTurn != nil {
              await terminal.note("A turn is already running; Ctrl+C cancels it.")
            } else {
              await continueTurn()
            }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/last" {
            if let lastMessage = session.history.messages.last {
              if lastMessage.role == .assistant {
                await terminal.line("\n--- Last Response ---")
                await terminal.line(lastMessage.text)
                await terminal.line("---------------------\n")
              } else {
                await terminal.line("The last message was not a response from the assistant.")
              }
            } else {
              await terminal.line("No messages in the chat history.")
            }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/version" {
            await terminal.line(MaiCLI.version)
            await releaseLocalInput()
            return false
          }
          if name == "/prompts" {
            let before = REPLCommandSnapshot(session: session)
            var outcome = PromptsCommandOutcome.handled
            await withTurnInterruptSetAside {
              outcome = await handlePromptsCommand(
                argument,
                session: session,
                configuration: &configuration,
                configurationPath: services.configurationPath,
                skills: services.skills.catalog,
                terminal: terminal)
            }
            switch outcome {
            case .handled:
              break
            case .send(let message, let title):
              session.refreshTitle(from: title)
              await deliver(message, to: loop.focus)
            case .selectSystemPrompt(let promptName, let message):
              await selectSystemPrompt(
                promptName,
                session: &session,
                runtime: runtime,
                configuration: &configuration,
                configurationPath: services.configurationPath,
                terminal: terminal)
              session.touch()
              workspace.upsert(session.chat, selecting: true)
              await saveWorkspace(&workspace, store: store, terminal: terminal)
              await noteTurnEffects(since: before)
              if let message { await deliver(message, to: loop.focus) }
            }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/skills", let request = skillPromptRequest(argument) {
            if request.name.isEmpty {
              await terminal.line("Usage: /skills prompt NAME [TEXT]   (/skills lists the names)")
            } else if let skill = services.skills.catalog.skill(named: request.name) {
              if isSkillEnabled(skill, profile: session.profile) {
                session.refreshTitle(from: "\(skill.name) \(request.arguments)")
                await deliver(skill.prompt(arguments: request.arguments), to: loop.focus)
              } else {
                await terminal.line(
                  "Skill '\(skill.name)' has no enabled tool for this agent. /skills lists availability.")
              }
            } else {
              await terminal.line("Unknown skill '\(request.name)'. /skills lists them.")
            }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/edit", argument.lowercased() == "input" {
            // The editor takes the terminal, as it does for /reply.
            var message: String?
            await withTurnInterruptSetAside {
              message = await composeInput(editor: editor, terminal: terminal)
            }
            if let message { await deliver(message, to: loop.focus) }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/reply" {
            // The editor takes the terminal, so a running turn keeps its
            // Ctrl+C rather than ending on the one meant for the editor.
            var message: String?
            await withTurnInterruptSetAside {
              message = await composeReply(argument, session: session, terminal: terminal)
            }
            if let message { await deliver(message, to: loop.focus) }
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/voice" {
            await handleVoice(argument)
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/btw" {
            await startBTW(argument)
            await releaseIfIdle(workspace: workspace)
            return false
          }
          // Every other command runs now. What it changes and the running
          // turn meet as noteTurnEffects describes, with a note, not a wait.
          let before = REPLCommandSnapshot(session: session)
          if name == "/projects" {
            do {
              let fields = try shellWords(argument)
              let action = fields.first?.lowercased() ?? "list"
              let arguments = Array(fields.dropFirst())
              let index = try home.loadProjectIndex()
              switch action {
              case "list":
                await terminal.line(projectListing(index, home: home, currentID: project.id, now: Date()))
              case "open":
                guard arguments.count == 1 else { throw JSONRPCError.invalidParams("Usage: /projects open INDEX|NAME|PATH") }
                guard loop.activeTurn == nil, await runtime.supervisor.liveProcesses().isEmpty else {
                  throw JSONRPCError.invalidParams("Stop running agents before switching projects.")
                }
                let selector = arguments[0]
                let directory = resolveProject(selector, in: index)?.workingDirectory
                  ?? AgentProject.standardizedPath(AgentHome.expandUserPath(selector))
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                  throw JSONRPCError.invalidParams("No project or directory matches '\(selector)'. /projects lists them.")
                }
                let target = try home.openProject(atWorkingDirectory: URL(fileURLWithPath: directory))
                if target.id == project.id { await terminal.line("Already in '\(project.displayName)'."); break }
                let nextStore = home.chatStore(for: target)
                var nextWorkspace = try nextStore.loadWorkspace()
                if let chat = nextWorkspace.orderedChats.first(where: { !$0.isArchived }) ?? nextWorkspace.orderedChats.first {
                  _ = nextWorkspace.selectChat(id: chat.id)
                } else {
                  let agent = configuration?.agents.first { $0.id == configuration?.defaultAgent } ?? localProfile.agentDefinition
                  nextWorkspace.startNewChat(primaryAgent: agent)
                }
                await recordSubagents()
                workspace.upsert(session.chat, selecting: true)
                let write = await REPLWorkspaceWriter.shared.enqueue(workspace, store: store)
                workspace = try await write.value
                let previousSession = session
                let previousWorkspace = workspace
                session = REPLSession(chat: nextWorkspace.selectedChat!)
                do {
                  try await restoreChatConfiguration(previous: previousSession,
                    isNewChat: nextWorkspace.selectedChat?.isDisposable == true)
                  guard FileManager.default.changeCurrentDirectoryPath(directory) else {
                    throw JSONRPCError.invalidParams("Cannot open directory '\(directory)'.")
                  }
                  try await services.approvalHandler.focusProject(home.storageDirectory(for: target).appendingPathComponent("settings.json"))
                  let debugLog = await services.approvalHandler.isDebugEnabled()
                    ? try AgentDebugLog(url: await services.approvalHandler.debugLogURL()) : nil
                  await runtime.configureDebugLog(debugLog)
                } catch {
                  let attemptedSession = session
                  session = previousSession
                  workspace = previousWorkspace
                  _ = FileManager.default.changeCurrentDirectoryPath(project.workingDirectory)
                  try? await restoreChatConfiguration(previous: attemptedSession, isNewChat: false)
                  try? await services.approvalHandler.focusProject(home.storageDirectory(for: project).appendingPathComponent("settings.json"))
                  throw error
                }
                project = target
                store = nextStore
                workspace = nextWorkspace
                remoteReturnChatID = nil
                services.memory.adopt(project: target, settings: configuration?.memory ?? .init())
                services.todo.focus(project: target)
                services.skills.focus(project: target)
                await restoreSavedSubagents()
                await terminal.line("Opened project '\(target.displayName)' · \(target.workingDirectory) · chat '\(session.title)'.")
              case "rename", "name", "tint", "color", "colour":
                guard arguments.count >= 2, var target = resolveProject(arguments[0], in: index) else {
                  throw JSONRPCError.invalidParams("Usage: /projects \(action) INDEX|NAME|PATH VALUE")
                }
                let value = arguments.dropFirst().joined(separator: " ")
                if action == "rename" || action == "name" { target.rename(to: value) }
                else if ["none", "off", "default", "-"].contains(value.lowercased()) { target.tint = nil }
                else {
                  guard let tint = AgentProjectTint(rawValue: value) else { throw JSONRPCError.invalidParams("Use a preset color, #RRGGBB, or none.") }
                  target.tint = tint
                }
                try home.saveProject(target)
                if target.id == project.id { project = target }
                await terminal.line("Updated project '\(target.displayName)'.")
              case "del":
                guard arguments.count == 1 else { throw JSONRPCError.invalidParams("Usage: /projects del INDEX|NAME|PATH") }
                await handleProjectCommand("del " + arguments[0], project: &project, home: home, store: store, terminal: terminal)
              case "info", "show":
                guard arguments.count == 1, let target = resolveProject(arguments[0], in: index) else {
                  throw JSONRPCError.invalidParams("Usage: /projects info INDEX|NAME|PATH")
                }
                await terminal.line(projectInfo(target, home: home, store: home.chatStore(for: target)))
              case "help": await terminal.line(projectsHelp)
              default: throw JSONRPCError.invalidParams("Unknown /projects command. /help projects lists commands.")
              }
            } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/project" {
            await handleProjectCommand(
              argument,
              project: &project,
              home: home,
              store: store,
              terminal: terminal)
            await releaseIfIdle(workspace: workspace)
            return false
          }
          // Summaries finish through the event loop, so submitted commands
          // and keyboard cancellation remain usable during model inference.
          if screen != nil, name == "/chat", ["compact", "recap"].contains(
            argument.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? "")
          {
            guard loop.summary == nil else {
              await terminal.note("A summary is already running. Ctrl+C cancels it.")
              await releaseIfIdle(workspace: workspace)
              return false
            }
            let id = UUID()
            let source = session
            let compactPrompt = configuration?.prompts?.compact
            let recapPrompt = configuration?.prompts?.recap
            let redirection = REPLRedirection.current
            let task = Task {
              var result = source
              await withTaskCancellationHandler {
                await handleChatCommand(
                  argument, session: &result, runtime: runtime,
                  compactPrompt: compactPrompt, recapPrompt: recapPrompt,
                  terminal: terminal, announceCompaction: false)
              } onCancel: {
                redirection?.cancel()
              }
              continuation.yield(.summaryFinished(
                id, result.history.messages == source.history.messages ? nil : result.history.messages))
            }
            let interrupt = interruptHandler.activate { task.cancel() }
            loop.summary = REPLSummary(
              id: id, task: task, interrupt: interrupt, chatID: source.id,
              sent: source.history.messages, pendingContent: source.pendingContent,
              redirection: redirection)
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/msg" || name == "/chat",
            name == "/msg" || !["compact", "recap"].contains(
              argument.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? "")
          {
            let fields = argument.split(whereSeparator: \.isWhitespace)
            if name == "/msg", fields.first?.lowercased() == "chop" {
              if fields.count != 1 {
                await terminal.line("Usage: /msg chop")
              } else if let message = session.history.messages.last(where: { $0.role != .system }) {
                let interrupt = interruptHandler.activate {}
                loop.chatChop = REPLChatChop(
                  chatID: session.id, messageID: message.id, interrupt: interrupt)
                await terminal.line(
                  "n next · b previous · p pin/unpin · e edit · d delete · x chop everything after this message · q quit\nChanges are saved immediately. /msg pins shows pinned messages. Slash commands leave chop.")
                await showChatChopMessage()
              } else {
                await terminal.line("No conversation messages to chop.")
              }
              await releaseIfIdle(workspace: workspace)
              return false
            }
            await recordSubagents()
            workspace.upsert(session.chat, selecting: true)
            let previousSession = session
            let previousWorkspace = workspace
            if name == "/msg" {
              await handleMessageCommand(
                argument, session: &session, runtime: runtime, terminal: terminal)
            } else {
              await handleWorkspaceChatCommand(
                argument,
                session: &session,
                workspace: &workspace,
                chatTitles: &loop.chatTitles,
                runtime: runtime,
                configuration: configuration,
                chatProcess: chatProcessIDs[session.id],
                terminal: terminal)
            }
            do {
              try await restoreChatConfiguration(
                previous: previousSession,
                isNewChat: !previousWorkspace.chats.contains { $0.id == session.id })
            } catch {
              session = previousSession
              workspace = previousWorkspace
              await terminal.line("error: \(error.localizedDescription)", to: .standardError)
            }
            await recordSubagents()
            await restoreSavedSubagents()
            workspace.upsert(session.chat, selecting: true)
            await saveWorkspace(&workspace, store: store, terminal: terminal)
            await noteTurnEffects(since: before)
            await releaseIfIdle(workspace: workspace)
            return false
          }
          if name == "/import" {
            await recordSubagents()
            workspace.upsert(session.chat, selecting: true)
            await withTurnInterruptSetAside {
              await handleImportCommand(
                argument,
                session: &session,
                workspace: &workspace,
                runtime: runtime,
                plugins: plugins,
                configuration: &configuration,
                catalogs: &catalogs,
                services: services,
                selectImportedChat: loop.activeTurn == nil,
                terminal: terminal)
            }
            await restoreSavedSubagents()
            workspace.upsert(session.chat, selecting: true)
            await saveWorkspace(&workspace, store: store, terminal: terminal)
            await noteTurnEffects(since: before)
            await releaseIfIdle(workspace: workspace)
            return false
          }
          await recordSubagents()
          var exits = false
          var commandWasInterrupted = false
          let editsInTerminal =
            ["/edit", "/attach"].contains(name)
            || argument.split(whereSeparator: \Character.isWhitespace).first?.lowercased() == "edit"
          if editsInTerminal {
            await withTurnInterruptSetAside {
              exits = await handleCommand(
                text,
                session: &session,
                runtime: runtime,
                plugins: plugins,
                ocrProvider: ocrProvider,
                configuration: &configuration,
                catalogs: &catalogs,
                services: services,
                chatProcess: chatProcessIDs[session.id],
                editor: editor,
                terminal: terminal)
            }
          } else {
            let commandSession = session
            let commandConfiguration = configuration
            let commandCatalogs = catalogs
            let commandChatProcess = chatProcessIDs[session.id]
            let changesInput =
              name == "/vdb" || name == "/theme" || name == "/reset" || name == "/highlight" || name == "/set"
              && argument.split(whereSeparator: \.isWhitespace).first?.lowercased()
                .hasPrefix("ui.") == true
            let commandText = text
            let command = await runForeground(name, resumeInput: !changesInput) {
              await runCommand(
                commandText,
                session: commandSession,
                runtime: runtime,
                plugins: plugins,
                ocrProvider: ocrProvider,
                configuration: commandConfiguration,
                catalogs: commandCatalogs,
                services: services,
                chatProcess: commandChatProcess,
                pmaiBridge: pmaiBridge,
                terminal: terminal)
            }
            commandWasInterrupted = command.interrupted
            session = command.value.session
            configuration = command.value.configuration
            catalogs = command.value.catalogs
            exits = command.value.exits
            if commandWasInterrupted { await terminal.note("cancelled \(name)") }
          }
          if await runtime.internetAccessPolicy().isOffline {
            await remoteServer.stop()
            await ForwirohRemote.shared.close()
          }
          if exits {
            loop.exiting = true
            return true
          }
          await recordSubagents()
          await releasePendingApprovalsIfUnattended()
          session.touch()
          workspace.upsert(session.chat, selecting: true)
          await saveWorkspace(&workspace, store: store, terminal: terminal)
          await restoreSavedSubagents()
          await noteTurnEffects(since: before)
          await refreshStatus()
          // A cancellation has an ordered interrupt event waiting behind this
          // command; that event releases exactly one prompt. Signalling here as
          // well would leave an extra semaphore permit and start two readers.
          if name == "/highlight" || (name == "/set" || name == "/reset")
            && argument.lowercased().hasPrefix("ui.highlight")
          {
            screen?.configure(ui: tintedUI(configuration?.ui ?? .init(), project: project))
            screen?.scrollToHighlight()
          }
          if !commandWasInterrupted { await releaseIfIdle(workspace: workspace) }
          return false
        }
        if configuration?.ui.broadcast == true {
          await deliver(text, to: [.active])
        } else {
          await deliver(text, to: loop.focus)
        }
        await releaseIfIdle(workspace: workspace)

      case .interrupt(let cancelledOperation, let endedInput):
        if endedInput { loop.readerParked = true }
        if let cancelledOperation,
          var turn = ([loop.activeTurn].compactMap { $0 } + Array(loop.btwTurns.values)
            + Array(loop.conversationTurns.values)).first(where: { $0.interrupt == cancelledOperation })
        {
          turn.restartPrompt = nil
          loop.update(turn)
        }
        if loop.resetID != nil {
          loop.resetID = nil
          await terminal.note("Reset cancelled.")
          await refreshStatus()
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if let chop = loop.chatChop, cancelledOperation == chop.interrupt {
          await closeChatChop()
          await refreshStatus()
          await releaseIfIdle(workspace: workspace)
          return false
        }
        // Reflect Ctrl+C immediately, rather than waiting for a provider or
        // tool cancellation to make its way through the supervisor.
        activityWasInterrupted = !loop.btwTurns.isEmpty ? false
          : cancelledOperation == loop.activeTurn?.interrupt
        if loop.pendingQueueMessage != nil {
          loop.pendingQueueMessage = nil
          loop.pendingQueueRedirection = nil
          await terminal.note("New message cancelled; the queue is unchanged.")
        } else if case .limit? = loop.modalPrompt(for: session.id) {
          loop.limitDecisions.removeValue(forKey: session.id)
          await terminal.note("Stopped here. The work is saved; /continue resumes it.")
        } else if cancelledOperation != nil {
          // The input or signal path already cancelled exactly the operation
          // that was active when Ctrl+C arrived. Do not let a delayed event
          // cancel whatever became active afterwards.
        } else if loop.editingApproval != nil {
          loop.editingApproval?.reply.resume(with: .deny(reason: "Edit cancelled."))
          loop.editingApproval = nil
        } else if let waiting = loop.approvals.first {
          loop.approvals.removeFirst()
          waiting.reply.fail(CancellationError())
        } else if let waiting = loop.compactions.first {
          loop.compactions.removeFirst()
          waiting.reply.resume(with: .cancelRun)
        } else if screen != nil {
          await terminal.note("Nothing to cancel. /exit or Ctrl+D quits.")
        }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .endOfFile:
        await stopVoice()
        loop.readerEnded = true
        loop.readerParked = true
        await closeChatChop()
        loop.beginExit()
        if loop.hasTurns { return false }
        return true

      case .summaryFinished(let id, let messages):
        guard let summary = loop.summary, summary.id == id else { return false }
        loop.summary = nil
        let interrupted = interruptHandler.deactivate(summary.interrupt)
        if let operation = loop.interruptOperation {
          interruptHandler.restore(operation.id, cancellation: operation.cancel)
        }
        if let chop = loop.chatChop { interruptHandler.restore(chop.interrupt) {} }
        if interrupted {
          await terminal.note("cancelled /chat")
        } else if let messages {
          // A setting change or chat switch must survive completion. Apply
          // only the transcript, and only if nobody edited its source.
          if currentMessages(of: summary.chatID) == summary.sent {
            if session.id == summary.chatID {
              session.history.replaceAll(with: messages)
              if session.pendingContent == summary.pendingContent { session.pendingContent.removeAll() }
              session.touch()
              workspace.upsert(session.chat, selecting: true)
            } else if var chat = workspace.chats.first(where: { $0.id == summary.chatID }) {
              chat.messages = messages
              if chat.pendingContent == summary.pendingContent { chat.pendingContent.removeAll() }
              chat.touch()
              workspace.upsert(chat)
            }
            await saveWorkspace(&workspace, store: store, terminal: terminal)
            await terminal.line("Conversation compacted into a summary.")
          } else {
            await terminal.note("The chat changed while compacting; history was kept. Run /chat compact again.")
          }
        }
        if loop.exiting { return !loop.hasTurns }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .turnFinished(let pid, let outcome):
        // A pmai_run call may have changed the session's profile, the
        // configuration or the MCP servers while the turn was running.
        await adoptPmaiToolChanges()
        let turn: REPLTurn?
        if loop.activeTurn?.pid == pid {
          turn = loop.activeTurn
          loop.activeTurn = nil
        } else {
          turn = loop.btwTurns.removeValue(forKey: pid) ?? loop.conversationTurns.removeValue(forKey: pid)
        }
        if pid == voicePID {
          switch outcome {
          case .success(let result):
            voiceHistory = Array(result.transcript.dropFirst(voiceContextCount))
            await voiceSession?.finishReply()
          case .failure(let error):
            voiceHistory = AgentTranscriptEditor.answeringUnansweredToolCalls(
              in: Array(await runtime.supervisor.transcript(pid).dropFirst(voiceContextCount)),
              reason: "the voice reply was cancelled")
            if voiceResumeAfterCancel || voiceDiscardAfterCancel { await voiceSession?.finishReply() }
            else { await voiceSession?.finishReply(error: error.localizedDescription) }
          }
          voiceDiscardAfterCancel = false
          if voiceResumeAfterCancel {
            voiceResumeAfterCancel = false
            await voiceSession?.record()
          }
        }
        let wasInterrupted = turn.map { interruptHandler.deactivate($0.interrupt) } ?? false
        loop.restarting.remove(pid)
        if let remaining = loop.interruptOperation {
          interruptHandler.restore(remaining.id, cancellation: remaining.cancel)
        }
        if let chop = loop.chatChop { interruptHandler.restore(chop.interrupt) {} }
        var succeeded = false
        var modelStats: ModelCallStats?
        var paused: AgentRunInterruption?
        var kept = 0
        var settled = true
        switch outcome {
        case .success(let result):
          if let turn, turn.chatID != nil, turn.restartPrompt == nil {
            settled = settle(result.transcript, from: turn)
          }
          succeeded = true
          modelStats = result.modelStats
          paused = result.interruption
        case .failure(let error):
          let cancelled = error is CancellationError || wasInterrupted || turn?.restartPrompt != nil
          if cancelled {
            if let turn {
              let stopped = Set(await runtime.supervisor.stop(turn.pid, reason: "Cancelled"))
              loop.cancelApprovals { $0.run.pid.map(stopped.contains) ?? false }
            }
          }
          if let turn, turn.kind == .conversation {
            await terminal.recoverConversation(turn.pid, error: cancelled ? nil : error)
          } else {
            await TerminalConversationScope.$id.withValue(turn?.chatID.map { "chat:\($0)" }) {
              if cancelled { await (turn?.output ?? terminal).recoverAfterCancellation() }
              else { await (turn?.output ?? terminal).recoverAfterError(error) }
            }
          }
          // What the run did before it broke off is not thrown away: the
          // supervisor has its transcript, and /continue picks it up.
          if let turn, turn.chatID != nil, turn.restartPrompt == nil {
            kept = await keepPartialTranscript(
              of: turn, reason: cancelled ? "the run was cancelled" : "the run failed")
          }
        }
        // The run's own chat is usually the one at the prompt; `elsewhere`
        // names it when the person moved to another chat during the run.
        let atPrompt = turn?.chatID == session.id
        if let turn, let prompt = turn.restartPrompt, let chatID = turn.chatID {
          // Keep earlier exchanges and the original message ID/attachments;
          // the interrupted attempt's replies and tool calls are superseded.
          if let current = currentMessages(of: chatID),
            let index = current.firstIndex(where: { $0.id == prompt.id })
          {
            let messages = Array(current.prefix(index)) + [prompt]
            if atPrompt {
              session.history.replaceAll(with: messages)
            } else if var chat = workspace.chats.first(where: { $0.id == chatID }) {
              chat.messages = messages
              chat.touch()
              workspace.upsert(chat)
            }
          } else {
            settled = false
          }
          paused = nil
        }
        var elsewhere: String?
        if let turn, let chatID = turn.chatID, !atPrompt {
          elsewhere = workspace.chats.first { $0.id == chatID }?.displayTitle
        }
        if let turn {
          if turn.kind == .btw, turn.redirection == nil {
            await terminal.btwResponse(await turn.output.drainCaptured(), pid: turn.pid)
          }
          let prefix = turn.kind == .btw ? "btw " : ""
          var took = "\(prefix)took \(elapsedDescription(since: turn.started))"
          let tree = await runtime.supervisor.tree()
          let subtree = tree.subtree(of: turn.pid)
          let tokens = subtree.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }
          let estimated = subtree.contains { $0.usage?.isEstimated == true }
          took += " and \(ModelUsageFormat.tokens(tokens, estimated: estimated))"
          if let stats = modelStats, let speed = stats.tokensPerSecond {
            took += " · avg \(ModelUsageFormat.speed(speed, estimated: stats.tokensEstimated))"
          }
          if let elsewhere {
            took += " · saved in '\(elsewhere)'"
          } else if !settled {
            took += " · its chat was closed; /jobs log \(turn.pid.rawValue) shows the reply"
          }
          let destination = turn.chatID.map { "chat:\($0)" }
            ?? (turn.kind == .conversation ? "agent:\(turn.pid.rawValue)" : nil)
          await TerminalConversationScope.$id.withValue(destination) {
            if let paused {
              await terminal.note("⏸ \(took) · \(paused.summary)", tone: .warning)
            } else {
              await terminal.note(
                succeeded ? "✓ \(took)" : "✗ \(took)", tone: succeeded ? .success : .error)
            }
          }
        }
        if let turn, turn.chatID != nil || turn.kind == .conversation {
          // The agents the run started, and earlier ones still going, are
          // saved with their chat as they stand now.
          await recordSubagents()
          if atPrompt {
            session.touch()
            workspace.upsert(session.chat, selecting: true)
          }
          await saveWorkspace(&workspace, store: store, terminal: terminal)
        }
        if loop.exiting {
          if loop.hasTurns { return false }
          return true
        }
        if let turn, let prompt = turn.restartPrompt, settled {
          var request = await runtime.conversationSettings(for: pid) ?? turn.request
          if let chatID = turn.chatID {
            request.messages = currentMessages(of: chatID) ?? []
          } else if let index = turn.sent.firstIndex(where: { $0.id == prompt.id }) {
            request.messages = Array(turn.sent.prefix(index)) + [prompt]
          }
          await runtime.supervisor.note(pid, transcript: request.messages)
          loop.restarts.append(REPLRestart(turn: turn, request: request))
          await refreshStatus()
          await releaseIfIdle(workspace: workspace)
          return false
        }
        if let turn, turn.kind == .chat {
          let waiting: Int
          if let pid = chatProcessIDs[session.id] {
            waiting = await runtime.supervisor.queuedMessages(for: pid).count
          } else {
            waiting = 0
          }
          // Entries deliberately ignored, or arriving after the last model
          // turn, stay queued until the person chooses to submit them.
          if let paused, settled, let chatID = turn.chatID {
            let decision = REPLLimitDecision(reason: paused)
            loop.limitDecisions[chatID] = decision
            if atPrompt {
              await terminal.line(REPLModalPrompt.limit(paused, id: decision.id).question ?? "")
            }
          }
          if waiting > 0 {
            await terminal.note(
              "\(waiting) queued message\(waiting == 1 ? "" : "s") still waiting: /queue shows them; /continue submits them; a new message asks what to do."
            )
          } else if kept > 0, atPrompt {
            await terminal.note(
              "kept \(kept) message\(kept == 1 ? "" : "s") from the interrupted run · /continue resumes it"
            )
          }
          if let elsewhere {
            let left = await runtime.supervisor.queuedMessages(for: turn.pid).count
            if left > 0 {
              await terminal.note(
                "\(left) queued message\(left == 1 ? "" : "s") wait in '\(elsewhere)'; /continue there submits them; a new message asks what to do."
              )
            } else if paused != nil || kept > 0 {
              await terminal.note(
                "/continue in '\(elsewhere)' picks that task up where it stopped.")
            }
          }
        }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .approval(let request, let reply):
        if loop.exiting {
          reply.fail(CancellationError())
        } else if await services.approvalHandler.permitsUnattendedApproval(request)
        {
          reply.resume(with: .approve(arguments: request.call.arguments))
        } else {
          loop.approvals.append((request, reply))
          await refreshStatus()
          await terminal.approvalRequest(request)
        }
        await refreshStatus()

      case .approvalFinished(let reply):
        loop.approvals.removeAll { $0.reply === reply }
        if loop.editingApproval?.reply === reply { loop.editingApproval = nil }
        await refreshStatus()

      case .compaction(let request, let reply):
        if loop.exiting {
          reply.fail(CancellationError())
        } else {
          loop.compactions.append((request, reply))
          await refreshStatus()
          await terminal.note(
            "Context limit for \(request.run.agentID): about \(request.estimatedTokens) tokens (threshold \(request.threshold)).",
            tone: .warning)
          if let pruning = request.pruning {
            await terminal.line("Pruning preview: \(pruning.summary). Keeps the start and end of each output; the middle is dropped.")
          }
          await terminal.line(
            (request.pruning == nil ? "" : "[p] prune old tool output · ")
              + "[y] summarize older context · [n] keep context this response · [m] change model · [x] clear chat and continue · [c] stop\n/model, /model -chat, and /model -compact remain available before deciding."
          )
        }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .compactionFinished(let reply):
        loop.compactions.removeAll { $0.reply === reply }
        await refreshStatus()

      case .supervisor:
        let batch = supervisorUpdates.take()
        for pid in batch.archived { await terminal.releaseProcess(pid, removing: false) }
        for pid in batch.removed { await terminal.releaseProcess(pid, removing: true) }
        for info in batch.finished.values.sorted(by: { $0.pid < $1.pid }) where info.depth > 0 {
          await terminal.processEnded(info)
        }
        if batch.needsAttention, screen != nil {
          await announceAgentAttention(
            runtime: runtime, announced: &announcedAttention, terminal: terminal,
            skippingApprovals: true)
        }
        // Background children may finish after the main turn. Save their
        // progress at most once a second, and always flush completions and
        // attention. Saving every change makes 80 agents starve typed input.
        let saveDue = progressClock.now >= nextSubagentSave
        if batch.hasChildren, batch.needsAttention || !batch.finished.isEmpty || saveDue
        {
          nextSubagentSave = progressClock.now.advanced(by: .seconds(1))
          let tree = await runtime.supervisor.tree()
          var roots = Set<AgentPID>()
          for pid in batch.changedPIDs {
            var current = tree.info(pid)
            while let parent = current?.parent { current = tree.info(parent) }
            if let root = current?.pid { roots.insert(root) }
          }
          let changedChats = Set(chatProcessIDs.compactMap { roots.contains($0.value) ? $0.key : nil })
          await recordSubagents(only: changedChats)
          workspace.upsert(session.chat, selecting: true)
          await saveWorkspace(&workspace, store: store, terminal: terminal, background: true)
        }
        await refreshStatus()
      }
      return false
    }

    /// A buffered line may run an editor, switch terminal modes, or lend stdin
    /// to a shell. Park the current draft first, just like a fresh submission.
    func parkReader() async {
      guard screen != nil, !loop.readerParked, !loop.readerEnded else { return }
      editor.requestPark(true)
      defer { editor.requestPark(false) }
      while let event = await eventIterator.next() {
        switch event {
        case .readerParked:
          loop.readerParked = true
          return
        case .line(let raw, let heredoc, let promptID, let pasted, _):
          deferredEvents.append(.line(
            raw, heredoc: heredoc, promptID: promptID, pasted: pasted, inputReleased: true))
          loop.readerParked = true
          return
        case .editInput(let draft, let command, _):
          deferredEvents.append(.editInput(draft, command: command, inputReleased: true))
          loop.readerParked = true
          return
        case .interrupt(let operation, let endedInput):
          deferredEvents.append(.interrupt(operation, endedInput: false))
          if endedInput { loop.readerParked = true; return }
        case .endOfFile:
          deferredEvents.append(event)
          loop.readerEnded = true
          loop.readerParked = true
          return
        case .switchAgent(let selection, let reply):
          deferredEvents.append(.switchAgent(selection, reply: {}))
          reply()
        default:
          deferredEvents.append(event)
        }
      }
    }

    func dispatchEvent(_ input: REPLEvent) async -> Bool {
      switch input {
      case .line(_, _, _, _, inputReleased: true), .editInput(_, _, inputReleased: true): await parkReader()
      default: break
      }
      var event = input
      var redirection: REPLRedirection?
      switch event {
      case .line(let raw, let heredoc, let promptID, let pasted, let inputReleased):
        let isCommand = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
        redirection = isCommand ? nil : loop.pendingQueueRedirection
        // A queued line's redirection belongs to its eventual execution.
        let command = raw.split(whereSeparator: \Character.isWhitespace).first
        let shellInput = remoteShell != nil && loop.modalPrompt(for: session.id) == nil && command != "/remote"
        if !heredoc, isCommand, command != "/then", command != "/hey", !shellInput {
          do {
            if let syntax = try REPLRedirectSyntax.parse(raw, pasted: pasted) {
              switch syntax.destination {
              case .file(let path, let append):
                let names = try shellWords(path)
                guard names.count == 1, let name = names.first, !name.isEmpty else {
                  throw REPLRedirectError("Redirection needs one filename; quote paths containing spaces.")
                }
                redirection = try REPLRedirection(path: name, append: append)
              case .process(let command):
                redirection = try REPLRedirection(command: command)
              }
              event = .line(syntax.input, heredoc: false, promptID: promptID, inputReleased: inputReleased)
            }
          } catch {
            if !loop.drainingThen && !inputReleased { loop.readerParked = true }
            await terminal.note("redirection: \(error.localizedDescription)", tone: .error)
            await releaseIfIdle(workspace: workspace)
            return false
          }
        }
      case .turnFinished(let pid, _):
        redirection = loop.activeTurn?.pid == pid
          ? loop.activeTurn?.redirection : (loop.btwTurns[pid] ?? loop.conversationTurns[pid])?.redirection
      case .summaryFinished:
        redirection = loop.summary?.redirection
      case .interrupt, .endOfFile:
        redirection = loop.pendingQueueRedirection
      default: break
      }
      let exits = await REPLRedirection.$current.withValue(redirection) {
        await handleEvent(event)
      }
      if let redirection,
        loop.summary?.redirection !== redirection,
        loop.activeTurn?.redirection !== redirection,
        !loop.btwTurns.values.contains(where: { $0.redirection === redirection }),
        !loop.conversationTurns.values.contains(where: { $0.redirection === redirection }),
        loop.pendingQueueRedirection !== redirection || exits
      {
        _ = await runForeground("redirection", resumeInput: false) { [inputGate = editor.inputGate] in
          await redirection.finish(terminal: terminal, inputGate: inputGate)
        }
      }
      return exits
    }

    while true {
      let event: REPLEvent
      if !deferredEvents.isEmpty { event = deferredEvents.removeFirst() }
      else if let incoming = await eventIterator.next() { event = incoming }
      else { break }
      if await dispatchEvent(event) { break }
      await startRestarts()
      var exits = false
      // Turns must have settled their transcripts, and background children
      // must also have finished, before the next line reaches the dispatcher.
      loop.drainingThen = true
      while !loop.exiting, !loop.hasTurns, loop.modalPrompt(for: session.id) == nil,
        !loop.thenLines.isEmpty,
        await runtime.supervisor.liveProcesses().allSatisfy({
          // Chat roots may have been allocated by /queue before their first
          // turn. With no REPL turn in flight, these are idle placeholders.
          $0.depth == 0 && chatProcessIDs.values.contains($0.pid)
        })
      {
        let line = loop.thenLines.removeFirst()
        await terminal.note("then: \(line)")
        if await dispatchEvent(.line(line, heredoc: false, promptID: nil)) {
          exits = true
          break
        }
      }
      loop.drainingThen = false
      if exits { break }
      await releaseIfIdle(workspace: workspace)
    }

    try? await AwakeController.shared.setEnabled(false)
    await stopVoice()
    loop.beginExit()
    await remoteServer.stop()
    await ForwirohRemote.shared.close()
    await MaiRunTerminalHost.shared.install(runner: nil)
    reader.stop()
    services.modelCatalog.cancel()
    services.voiceCatalog.cancel()
    supervisorFeed.cancel()
    continuation.finish()
    await services.approvalHandler.setPrompter(nil)
    await services.approvalHandler.setCompactionPrompter(nil)
    await recordSubagents()
    workspace.upsert(session.chat, selecting: true)
    await saveWorkspace(&workspace, store: store, terminal: terminal, closing: true)
    await terminal.attach(screen: nil)
    editor.install(surface: nil)
    TerminalScreen.install(nil)
    screen?.deactivate()
  }

  /// Reports background agents that are waiting on somebody, once each. A
  /// process that stops asking and asks again is announced again.
  private static func announceAgentAttention(
    runtime: AgentRuntime,
    announced: inout Set<AgentPID>,
    terminal: TerminalWriter,
    skippingApprovals: Bool = false
  ) async {
    // On the persistent screen an approval is already a question at the
    // prompt, so only the other kinds of attention need a line here.
    let waiting = await runtime.supervisor.processesNeedingAttention().filter { process in
      guard skippingApprovals, case .approval = process.attention else { return true }
      return false
    }
    let pids = Set(waiting.map(\.pid))
    announced.formIntersection(pids)
    for process in waiting where !announced.contains(process.pid) {
      announced.insert(process.pid)
      let verb =
        switch process.attention {
        case .approval: "needs approval"
        case .input: "is waiting for you"
        case .error: "stopped"
        case .finished: "finished"
        case nil: "changed"
        }
      await terminal.line(
        "agent \(process.pid) (\(process.agentID)) \(verb): "
          + "\(process.attention?.summary ?? "")  ·  /jobs log \(process.pid.rawValue)")
    }
  }
}
