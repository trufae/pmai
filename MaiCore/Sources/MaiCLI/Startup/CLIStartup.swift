import Foundation
import MaiCore
import MaiACP
import MaiLocalProviders
import MaiMCP
import MaiOpenAI
import MaiPluginHost
import MaiStandardTools
import MaiVisionOCR
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
  @MainActor static func run() async {
    #if os(Windows)
    WindowsConsole.configureUTF8Output()
    #endif
    let started = ContinuousClock.now
    let environment = ProcessInfo.processInfo.environment
    let startup = CLIStartupTiming(started: started, environment: environment)
    startup.mark("main entered")
    let commandLineArguments = platformCommandLineArguments(environment: environment)
    if commandLineArguments.dropFirst().starts(with: ["app", "run"]) {
      let arguments = commandLineArguments.dropFirst(3)
      if Array(arguments) == ["--help"] {
        print(CLIApp.usage)
        return
      }
      do {
        guard arguments.first == "--allow-exec", let directory = arguments.dropFirst().first else {
          throw CLIApp.Failure(message: CLIApp.usage)
        }
        exit(try CLIApp.run(directory: directory, arguments: Array(arguments.dropFirst(2)),
          environment: environment))
      } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(2)
      }
    }
    if commandLineArguments.dropFirst().first == "acp-gateway" {
      do {
        try await ACPGatewayCLI.run(Array(commandLineArguments.dropFirst(2)), environment: environment)
      } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(2)
      }
      return
    }
    if commandLineArguments.dropFirst().first == "tailcat" {
      do {
        try await TailcatCLI.run(Array(commandLineArguments.dropFirst(2)),
          executable: commandLineArguments[0], environment: environment)
      } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(2)
      }
      return
    }
    if commandLineArguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
      printUsage()
      return
    }
    if commandLineArguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
      print(version)
      return
    }

    do {
      let options = try CLIOptions(
        arguments: Array(commandLineArguments.dropFirst()),
        environment: environment)
      if let action = options.vimAction {
        try VimIntegration.run(action, directory: options.vimDirectory, environment: environment)
        return
      }
      if options.editConfig {
        try await editConfiguration(environment: environment)
        return
      }
      if options.update {
        try await CLIUpdater.run(
          currentVersion: version, executable: commandLineArguments[0], environment: environment)
        return
      }
      if options.printConfig {
        FileHandle.standardOutput.write(try sampleConfiguration().encoded())
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
      }
      if options.listProjects {
        let home = resolvedHome(options: options, environment: environment)
        print(projectListing(try home.loadProjectIndex(), home: home, currentID: nil, now: Date()))
        return
      }
      if options.listChats {
        let home = resolvedHome(options: options, environment: environment)
        let project = try home.openProject(
          atWorkingDirectory: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        let store = resolvedChatStore(
          options: options, home: home, project: project, environment: environment)
        let workspace = try store.loadWorkspace { error in
          FileHandle.standardError.write(
            Data("warning: skipped a chat file. \(error.localizedDescription)\n".utf8))
        }
        print(await chatListing(workspace, scope: .all, selectedID: nil, terminal: TerminalWriter()))
        return
      }

      let loaded = try loadConfiguration(options: options, environment: environment)
      let configurationPath = loaded?.path ?? defaultConfigurationPath(environment: environment)
      var configuration = loaded?.configuration
      if var existing = configuration {
        var changed = existing.associateSystemPrompts()
        if !MaiAgentPresets.install(in: &existing).isEmpty { changed = true }
        if existing.fileAccess == nil {
          existing.fileAccess = .init()
          changed = true
        }
        if !existing.toolSources.contains(where: {
          $0.kind == MaiStandardToolsPlugin.factoryKind
        }) {
          existing.toolSources.append(
            ConfiguredToolSource(
              id: "standard-tools",
              kind: MaiStandardToolsPlugin.factoryKind))
          changed = true
        }
        if changed { try existing.save(to: URL(fileURLWithPath: configurationPath)) }
        configuration = existing
      }
      let home = resolvedHome(options: options, environment: environment)
      startup.mark("configuration loaded")
      try await ForwirohRemote.shared.configure(
        directory: home.rootURL.appendingPathComponent("forwiroh-client"),
        name: ProcessInfo.processInfo.hostName)
      let project = try home.openProject(
        atWorkingDirectory: URL(
          fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
      let approvalHandler = try TerminalApprovalHandler(
        configuration: configuration?.approvals ?? .init(),
        projectSettingsURL: home.storageDirectory(for: project).appendingPathComponent(
          "settings.json"),
        mode: options.approvalMode)
      startup.mark("project opened")
      // Chat history owns these records until /jobs clear. The runtime's
      // bounded default can evict a parent before its subtree is saved.
      let runtime = AgentRuntime(
        approvalHandler: approvalHandler, supervisor: AgentSupervisor(finishedRetention: .max),
        pausesOnToolLimit: options.initialPrompt == nil && options.serve == nil)
      let promptFileAccess = PromptFileAccess(
        approvalHandler: approvalHandler, settings: configuration?.fileAccess ?? .init(),
        environment: environment, home: home)
      if await approvalHandler.isDebugEnabled() {
        do {
          await runtime.configureDebugLog(
            try AgentDebugLog(url: approvalHandler.debugLogURL()))
        } catch {
          FileHandle.standardError.write(
            Data("warning: debug log unavailable: \(error.localizedDescription)\n".utf8))
        }
      }
      let plugins = PluginRegistry()
      try await plugins.install(MaiVoicePlugin(), origin: "built-in")
      try await plugins.install(MaiCoreBuiltinsPlugin(), origin: "built-in")
      try await plugins.install(MaiMCPPlugin(), origin: "built-in")
      try await plugins.install(
        MaiOpenAIPlugin(
          credentialsDirectory:
            home.rootURL.appendingPathComponent("chatgpt", isDirectory: true)), origin: "built-in")
      try await plugins.install(MaiLocalProvidersPlugin(), origin: "built-in")
      try await plugins.install(
        MaiACPPlugin(onPermission: { params, host in
          try await approvalHandler.decideRemote(params, host: host)
      }), origin: "built-in")
      do {
        try await plugins.install(MaiVisionOCRPlugin(), origin: "built-in")
      } catch {
        // OCR is optional: a platform without a usable backend must not stop
        // the CLI from starting.
        FileHandle.standardError.write(
          Data("warning: OCR plugin unavailable: \(error.localizedDescription)\n".utf8))
      }
      try await plugins.install(MaiStandardToolsPlugin(configureFiles: { files in
        var files = files
        files.projectHomeURL = home.rootURL
        files.pathAccessPolicy = promptFileAccess.policy
        files.additionalAllowedURLs = await promptFileAccess.all()
        return files
      }), origin: "built-in")
      let nativePluginHost = NativePluginHost()
      try await loadNativePlugins(
        options: options,
        loadedConfigurationPath: loaded?.path,
        configuration: configuration,
        environment: environment,
        host: nativePluginHost,
        registry: plugins)
      startup.mark("plugins installed")
      let memoryState = MemoryState(
        home: resolvedHome(options: options, environment: environment))
      let todoState = TodoState(
        home: resolvedHome(options: options, environment: environment))
      let skillState = SkillState(
        home: resolvedHome(options: options, environment: environment))
      try await registerTools(
        in: runtime,
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      try await registerMemoryTools(in: runtime, state: memoryState)
      let remoteHosts = ACPRemoteHostStore(directory:
        resolvedHome(options: options, environment: environment).rootURL.appendingPathComponent("remotes"))
      let remoteTools = RemoteWorkspaceTools {
        try remoteHosts.hosts().filter { $0.agentAccess == true }.map {
          RemoteWorkspaceHost(id: $0.id.uuidString.lowercased(), connection: try remoteHosts.connection(for: $0))
        }
      }
      try await runtime.register(tools: remoteTools.tools())
      try await registerTodoTools(in: runtime, state: todoState)
      try await runtime.register(tools: MaiContextTools.makeTools(supervisor: runtime.supervisor))
      try await registerSkillTools(in: runtime, state: skillState)
      startup.mark("tools and skills registered")
      try await synchronizeToolGroupSelections(
        configuration: &configuration,
        configurationPath: configurationPath,
        plugins: plugins,
        runtime: runtime)
      let ocrProvider = await configuredOCRProvider(
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      startup.mark("tool groups and OCR configured")
      if let provider = options.providerOverride, let url = options.baseURLOverride,
        var draft = configuration, !draft.providers.contains(where: { $0.id == provider.rawValue })
      {
        draft.providers.append(
          ConfiguredProvider(id: provider.rawValue, kind: .openAICompatible, baseURL: url))
        configuration = draft
      }
      var profile = try selectedProfile(
        configuration: configuration,
        options: options,
        environment: environment)
      let store = resolvedChatStore(
        options: options, home: home, project: project, environment: environment)
      importLegacyChats(into: store, project: project, options: options, environment: environment)
      let restored = try loadChatWorkspace(
        from: store,
        initialProfile: profile,
        configuredAgents: configuration?.agents ?? [],
        options: options)
      var workspace = restored.workspace
      startup.mark("chat workspace loaded")
      profile = SessionProfile(definition: workspace.selectedChat!.primaryAgent)
      if let saved = workspace.selectedChat?.runtimeConfiguration {
        configuration = saved.applying(to: configuration ?? MaiConfiguration())
      }
      let setup = try await configureRuntime(
        runtime,
        plugins: plugins,
        configuration: configuration,
        options: options,
        selectedProvider: profile.provider,
        resumingChat: restored.resumed,
        environment: environment, startup: startup)
      startup.mark("providers and MCP configured")
      if configuration == nil
        || configuration?.providers.isEmpty == true && !setup.implicitProviders.isEmpty
      {
        var created = configuration ?? initialConfiguration()
        created.providers = setup.implicitProviders
        if !created.providers.isEmpty {
          created.defaultAgent = profile.agentID
          created.upsertAgent(profile.agentDefinition)
          MaiAgentPresets.install(in: &created)
        }
        try created.save(to: URL(fileURLWithPath: configurationPath))
        configuration = created
        if let definition = created.agents.first {
          profile = SessionProfile(definition: definition)
        }
        var chat = workspace.selectedChat!
        chat.primaryAgent = profile.agentDefinition
        workspace.upsert(chat)
      }
      if var draft = configuration {
        if let selector = options.compactAgent {
          try draft.assignTask(.compact, selector: selector, current: profile.agentDefinition)
        }
        if let selector = options.toolAgent {
          try draft.assignTask(.tool, selector: selector, current: profile.agentDefinition)
        }
        if options.saveDefaults {
          draft.upsertAgent(profile.agentDefinition)
          draft.defaultAgent = profile.agentID
          if let index = draft.providers.firstIndex(where: { $0.id == profile.provider.rawValue }),
            let url = options.baseURLOverride
          {
            draft.providers[index].baseURL = url
          }
          try draft.save(to: URL(fileURLWithPath: configurationPath))
        }
        configuration = draft
        for agent in draft.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        await runtime.configureTaskAgents(draft.taskAgents)
      }
      let usageStats = ModelUsageStore(url: home.usageStatsURL)
      await runtime.configureUsageStats(usageStats)
      await runtime.configureToolUsage(AgentToolUsageStore(url: home.toolUsageURL))
      memoryState.adopt(project: project, settings: configuration?.memory ?? .init())
      todoState.focus(project: project)
      skillState.focus(project: project)
      let terminal = TerminalWriter()
      await terminal.configureColors(configuration?.ui ?? .init())
      await runtime.configureMemory(memoryState.promptSection)
      await runtime.configureWorkingDirectoryContext(true)
      await runtime.configureProjectInstructionDirectory(
        configuration?.use.agentsmd == .on ? AgentExecutionScope.directory : nil)
      await runtime.configurePlanning(configuration?.use.plan ?? true)
      let selectedChat: AgentChat
      if options.initialPrompt != nil, workspace.selectedChat?.historyWindow != nil {
        selectedChat =
          try store.loadChatHistory(id: workspace.selectedChat!.id) ?? workspace.selectedChat!
      } else {
        selectedChat = workspace.selectedChat!
      }
      var session = REPLSession(chat: selectedChat)
      if let configuration {
        session.runtimeConfiguration = AgentChatConfiguration(
          configuration: configuration, providerBaseURLs: setup.providerBaseURLs)
      }
      session.pendingContent.append(contentsOf: try options.imagePaths.map(imageContent))
      if options.readStdin {
        session.pendingContent.append(
          try stdinAttachment(reopeningTerminal: options.initialPrompt == nil))
      }
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      let themesDirectory = home.rootURL.appendingPathComponent("themes", isDirectory: true)
      // Shared by the REPL and by the pmai_run/pmai_help tools, so a command
      // either of them runs reaches the same session, configuration and themes.
      let services = REPLServices(
        approvalHandler: approvalHandler,
        promptFileAccess: promptFileAccess,
        configurationPath: configurationPath,
        remoteTerminalSettingsURL: resolvedHome(options: options, environment: environment).rootURL.appendingPathComponent("remote-server/terminal-timeout.json"),
        providerBaseURLs: ProviderBaseURLStore(setup.providerBaseURLs),
        memory: memoryState,
        todo: todoState,
        skills: skillState,
        themesDirectory: themesDirectory,
        usageStats: usageStats)
      if let theme = environmentValue(["PMAI_THEME"], in: environment) {
        do {
          let ui = try TerminalTheme.load(
            theme, directory: themesDirectory, ui: configuration?.ui ?? .init())
          configuration?.ui = ui
        } catch {
          await terminal.line("warning: \(error.localizedDescription)", to: .standardError)
        }
      }
      await terminal.configureMarkdown(
        markdownRenderer(
          enabled: options.markdown ?? configuration?.ui.markdown ?? true,
          forced: options.markdown == true,
          environment: environment))
      await terminal.configureThinking(configuration?.ui.thinking ?? .status)
      await terminal.configureTools(
        configuration?.ui.tools ?? ConfiguredTerminalUI().tools)
      await terminal.configureColors(configuration?.ui ?? .init())
      await terminal.configureSubagentOutput(
        configuration?.ui.subagentOutput ?? ConfiguredTerminalUI().subagentOutput)
      try await runtime.configureRedaction(
        configuration?.redact ?? .off, file: home.rootURL.appendingPathComponent("redact.txt")
      ) { count in
        await terminal.line(
          "warning: redacted \(count) match\(count == 1 ? "" : "es") before sending to the model.",
          to: .standardError)
      }
      session.redactor = await runtime.contentRedactor(sessionID: session.sessionID)
      await terminal.configureRedactor(session.redactor)
      configureEditor(configuration?.ui.editor ?? "")
      await logDiagnosticConfiguration(
        session: session, configuration: configuration, runtime: runtime, services: services)
      startup.mark("session and terminal configured")

      if let mode = options.serve {
        try await runServer(
          mode,
          runtime: runtime,
          approvalHandler: approvalHandler,
          agent: profile.agentDefinition,
          configuration: configuration,
          options: options, environment: environment)
        return
      }
      if loaded == nil, FileManager.default.fileExists(atPath: configurationPath) {
        await terminal.line("Created \(configurationPath)", to: .standardError)
      }
      // The bridge is what a pmai_run call runs its command on. The loop keeps
      // it current; here, with one prompt and no loop, the session is handed
      // over once before the run and collected once after it.
      let pmaiBridge = PmaiCommandBridge()
      await PmaiCommandHost.shared.install { line in
        try await pmaiCommand(
          line,
          bridge: pmaiBridge,
          runtime: runtime,
          plugins: plugins,
          ocrProvider: ocrProvider,
          services: services)
      }
      defer { Task { await PmaiCommandHost.shared.install(runner: nil) } }
      if let prompt = options.initialPrompt {
        guard !profile.provider.rawValue.isEmpty else { throw CLIError.noProvider }
        await installInteractiveRunHost()
        defer { Task { await MaiRunTerminalHost.shared.install(runner: nil) } }
        if configuration?.use.agentsmd == .ask || configuration?.use.agentsmd == .maybe {
          let directory = AgentExecutionScope.directory
          let approved = await askForAgentsMarkdown(
            from: directory, editor: TerminalLineEditor(), terminal: terminal)
          await runtime.configureProjectInstructionDirectory(approved ? directory : nil)
        }
        var oneShotProcess: AgentPID? = await runtime.allocateProcess(
          agentID: session.profile.agentID, task: session.title)
        await runtime.restoreConversations(session.subagents, under: oneShotProcess!, sessionID: session.sessionID)
        runtime.commandHistory.restore(session.commands)
        pmaiBridge.sync(
          session: session,
          configuration: configuration,
          catalogs: setup.catalogs,
          chatProcess: oneShotProcess)
        let succeeded = await submit(
          prompt,
          session: &session,
          runtime: runtime,
          process: &oneShotProcess,
          terminal: terminal,
          promptFileAccess: promptFileAccess,
          approvalHandler: approvalHandler,
          configuration: configuration,
          environment: environment,
          checkpoint: { chat in
            workspace.upsert(chat, selecting: true)
            try store.commit(&workspace)
          })
        if let changes = pmaiBridge.takeChanges() {
          session.profile = changes.profile
          configuration = changes.configuration
        }
        if let process = oneShotProcess {
          session.subagents = AgentProcessRecord.merging(
            saved: session.subagents,
            current: await runtime.conversationRecords(under: process))
          if !succeeded {
            let partial = await runtime.supervisor.transcript(process)
            if !partial.isEmpty {
              session.history.replaceAll(
                with: AgentTranscriptEditor.answeringUnansweredToolCalls(
                  in: session.redactor?.unredact(partial) ?? partial,
                  reason: "The previous run was interrupted."))
            }
          }
        }
        session.commands = runtime.commandHistory.records(sessionID: session.sessionID, saved: session.commands)
        session.touch()
        workspace.upsert(session.chat, selecting: true)
        try store.commit(&workspace)
        await runtime.flushToolUsage()
        if !succeeded { exit(1) }
        return
      }
      await runREPL(
        workspace: &workspace,
        store: store,
        home: home,
        project: project,
        historyURL: resolvedHistoryURL(options: options, home: home, environment: environment),
        runtime: runtime,
        plugins: plugins,
        ocrProvider: ocrProvider,
        configuration: configuration,
        catalogs: setup.catalogs,
        services: services,
        remoteTools: remoteTools,
        pmaiBridge: pmaiBridge,
        promptFileAccess: promptFileAccess,
        terminal: terminal, startup: startup)
      await runtime.flushToolUsage()
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(2)
    }
  }
}
