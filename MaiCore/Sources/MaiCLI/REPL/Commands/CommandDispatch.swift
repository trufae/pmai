import Foundation
import MaiCore
import MaiLocalProviders

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
  /// Runs the large command switch against copies. The event loop applies the
  /// returned values once the task ends, keeping mutable REPL state in one
  /// place while letting Ctrl+C cancel network and other cooperative waits.
  static func runCommand(
    _ input: String,
    session: REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: MaiConfiguration?,
    catalogs: [MCPServerCatalog],
    services: REPLServices,
    chatProcess: AgentPID?,
    pmaiBridge: PmaiCommandBridge? = nil,
    terminal: TerminalWriter
  ) async -> REPLCommandResult {
    var session = session
    var configuration = configuration
    var catalogs = catalogs
    // A command the model ran before this one changed the state the loop was
    // holding; take it back before running a typed command off the same base.
    if let changes = pmaiBridge?.takeChanges() {
      session.profile = changes.profile
      configuration = changes.configuration
      catalogs = changes.catalogs
    }
    let exits = await handleCommand(
      input,
      session: &session,
      runtime: runtime,
      plugins: plugins,
      ocrProvider: ocrProvider,
      configuration: &configuration,
      catalogs: &catalogs,
      services: services,
      chatProcess: chatProcess,
      terminal: terminal)
    return REPLCommandResult(
      session: session, configuration: configuration, catalogs: catalogs, exits: exits)
  }

  /// What `pmai_run` and `pmai_help` call: the REPL's own command switch, with
  /// the output collected instead of printed, so the model reads exactly what
  /// the person would have seen at the prompt. Whatever the command changed is
  /// left on the bridge for the loop to adopt when the turn ends.
  static func pmaiCommand(
    _ line: String,
    bridge: PmaiCommandBridge,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    services: REPLServices
  ) async throws -> String {
    let command = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
    if command.first == "/remote" {
      return "Only the person at the REPL can pair, connect, or serve remote hosts. /help remote describes the commands."
    }
    if command.first == "/projects" {
      return "Only the person at the REPL can switch or manage projects. /help projects describes the commands."
    }
    if command.first == "/cd" {
      return
        "Only the person at the REPL can change the working directory and implicit Files workspace."
    }
    if command.first == "/reset" {
      return "Only the person at the REPL can reset settings. Type /reset, then choose reset or cancel."
    }
    if command.first == "/tools", command.count > 1 {
      let options = command[1].split(whereSeparator: \Character.isWhitespace)
      if options.count == 1, ["on", "off"].contains(options[0].lowercased()) {
        return "Only the person at the REPL can switch tools globally."
      }
      if options.count >= 3, ["set", "config", "unset"].contains(String(options[0])),
        options[2] == "filesRoot"
      {
        return
          "Only the person at the REPL can change the Files workspace; /path shows its permissions."
      }
    }
    if command.first == "/path", command.count > 1,
      !["list", "ls", "help"].contains(
        command[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    {
      return
        "Only the person at the REPL can change /path policy. /path lists the current permissions."
    }
    guard let state = bridge.begin() else { throw PmaiCommandError.noSession }
    var session = state.session
    var configuration = state.configuration
    var catalogs = state.catalogs
    let terminal = TerminalWriter(capturesOutput: true)
    let exits = await handleCommand(
      line,
      session: &session,
      runtime: runtime,
      plugins: plugins,
      ocrProvider: ocrProvider,
      configuration: &configuration,
      catalogs: &catalogs,
      services: services,
      chatProcess: state.chatProcess,
      terminal: terminal)
    bridge.finish(session: session, configuration: configuration, catalogs: catalogs)
    let output = await terminal.drainCaptured()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // A command that ends the session ends the person's prompt, not this one:
    // the turn the model is inside of is still going.
    let closing = exits ? "\n\n\(line) would have closed the session; the person is still in it." : ""
    return output.isEmpty ? "\(line) printed nothing.\(closing)" : output + closing
  }

  static func handleCommand(
    _ input: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    services: REPLServices,
    chatProcess: AgentPID? = nil,
    editor: TerminalLineEditor? = nil,
    terminal: TerminalWriter
  ) async -> Bool {
    let parts = input.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
    let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if let argument = jobsArgument(for: parts[0], argument: argument) {
      await handleJobsCommand(argument, runtime: runtime, terminal: terminal)
      return false
    }
    let previousProviders = configuration?.providers
    let previousURLs = services.providerBaseURLs.snapshot()
    defer {
      if configuration?.providers != previousProviders
        || services.providerBaseURLs.snapshot() != previousURLs
      {
        services.modelCatalog.invalidate()
      }
    }

    // Keep noun-first edits on the same path as /edit TARGET, including the
    // plural catalog commands. Existing prompt/skill/chat editors keep their
    // own argument syntax.
    let editTargets = [
      "/provider": "provider", "/providers": "provider",
      "/agent": "agent", "/agents": "agent",
      "/mcp": "mcp", "/mcps": "mcps",
    ]
    let editArguments = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    if let target = editTargets[parts[0]], editArguments.first?.lowercased() == "edit" {
      let rest = editArguments.count > 1 ? " " + editArguments[1] : ""
      await handleEditCommand(
        target + rest, session: &session, runtime: runtime, plugins: plugins,
        memory: services.memory, skills: services.skills, configuration: &configuration,
        configurationPath: services.configurationPath,
        providerBaseURLs: services.providerBaseURLs, chatProcess: chatProcess, terminal: terminal)
      return false
    }

    switch parts[0] {
    case "/view":
      await terminal.line(
        "error: /view requires ui.mode=buffer. Run /set ui.mode buffer in an interactive terminal.",
        to: .standardError)
    case "/ps":
      runtime.commandHistory.restore(session.commands)
      await handlePSCommand(
        argument, session: session, runtime: runtime, chatProcess: chatProcess, terminal: terminal)
    case "/exit", "/quit":
      return true
    case "/version":
      await terminal.line(version)
    case "/about":
      await terminal.line(aboutMessage)
    case "/help":
      switch argument.lowercased() {
      case "":
        await terminal.line(replHelp)
      case "about", "/about":
        await terminal.line(aboutMessage)
      case "model", "/model":
        await terminal.markdown(modelHelp)
      case "voice", "/voice":
        await terminal.line(voiceHelp)
      case "models", "/models":
        await terminal.line(REPLModelListOptions.usage)
      case "keys", "/keys":
        await terminal.line(keysHelp)
      case "shell", "/shell":
        await terminal.line(shellHelp)
      case "history", "/history":
        await terminal.line(REPLHistoryCommand.help)
      case "set", "/set":
        await terminal.line(setHelp)
      case "reset", "/reset":
        await terminal.line(resetHelp)
      case "provider", "providers", "baseurl", "/provider", "/providers", "/baseurl":
        await terminal.line(providerHelp)
      case "theme", "/theme":
        await terminal.line(themeHelp)
      case "memory", "/memory":
        await terminal.line(memoryHelp)
      case "todo", "/todo":
        await terminal.line(todoHelp)
      case "vdb", "/vdb":
        await terminal.line(vdbHelp)
      case "prompt", "prompts", "/prompt", "/prompts":
        await terminal.line(promptHelp)
      case "agents", "agent", "/agents", "/agent":
        await terminal.line(agentsHelp)
      case "subagents", "fork", "/subagents", "/fork":
        await terminal.line(conversationsHelp)
      case "jobs", "job", "/jobs", "/job":
        await terminal.line(jobsHelp)
      case "ps", "/ps":
        await terminal.line(psHelp)
      case "view", "/view":
        await terminal.line(viewHelp)
      case "mcp", "/mcp":
        await terminal.line(mcpCommandHelp)
      case "remote", "/remote":
        await terminal.line(remoteHelp)
      case "projects", "/projects":
        await terminal.line(projectsHelp)
      case "project", "/project":
        await terminal.line(projectHelp)
      case "chat", "/chat":
        await terminal.line(chatHelp)
      case "msg", "/msg":
        await terminal.line(msgHelp)
      case "edit", "/edit":
        await terminal.line(editHelp)
      case "tools", "/tools":
        await terminal.line(toolHelp)
      case "queue", "/queue":
        await terminal.line(queueHelp)
      case "hey", "/hey":
        await terminal.line(heyHelp)
      case "export", "/export":
        await terminal.line(exportHelp)
      case "import", "/import":
        await terminal.line(importHelp)
      case "reply", "/reply":
        await terminal.line(replyHelp)
      case "copy", "/copy":
        await terminal.line(copyHelp)
      case "stats", "/stats":
        await terminal.line(statsHelp)
      case "skills", "/skills":
        await terminal.line(skillsHelp)
      case "path", "/path":
        await terminal.line(pathHelp)
      default:
        await terminal.line(
          "Unknown help topic '\(argument)'. Try /help, /help COMMAND, /help shell, or /help keys."
        )
      }
    case "/keys":
      await terminal.line(keysHelp)
    case "/cwd", "/pwd":
      await terminal.line(FileManager.default.currentDirectoryPath)
    case "/history":
      await terminal.line("Input history is available at the REPL prompt. /help history lists commands.")
    case "/remote":
      await terminal.line(remoteHelp)
    case "/projects":
      await terminal.line(projectsHelp)
    case "/path":
      await handlePathCommand(
        argument, runtime: runtime, configuration: &configuration,
        configurationPath: services.configurationPath,
        access: services.promptFileAccess, terminal: terminal)
    case "/cd":
      await changeWorkingDirectory(argument, terminal: terminal)
    case "/nothink":
      await handleEffortCommand(
        "off", session: &session, runtime: runtime, configuration: &configuration,
        configurationPath: services.configurationPath, terminal: terminal)
    case "/set", "/highlight":
      let setting = parts[0] == "/highlight"
        ? "ui.highlight " + (argument.isEmpty ? "none" : argument) : argument
      await handleSetCommand(
        setting,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        providerBaseURLs: services.providerBaseURLs,
        approvalHandler: services.approvalHandler,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        catalogs: &catalogs,
        terminal: terminal, remoteTerminalSettingsURL: services.remoteTerminalSettingsURL)
    case "/reset":
      guard !argument.isEmpty else {
        await terminal.line("Type /reset at the REPL prompt, then choose reset or cancel.")
        break
      }
      do {
        let setting = try resetSetting(argument, profile: session.profile)
        if setting.theme {
          await handleThemeColorCommand(
            [setting.key, setting.value], configuration: &configuration,
            configurationPath: services.configurationPath, terminal: terminal)
        } else {
          if setting.key == "tool.proxy" { session.profile.proxyExposedTools = nil }
          await handleSetCommand(
            "\(setting.key) \(setting.value)", session: &session, runtime: runtime,
            plugins: plugins, providerBaseURLs: services.providerBaseURLs,
            approvalHandler: services.approvalHandler, configuration: &configuration,
            configurationPath: services.configurationPath, catalogs: &catalogs, terminal: terminal,
            restoringDefault: true, remoteTerminalSettingsURL: services.remoteTerminalSettingsURL)
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "/theme":
      await handleThemeCommand(
        argument, configuration: &configuration, configurationPath: services.configurationPath,
        directory: services.themesDirectory, terminal: terminal)
    case "/providers":
      let providers = await runtime.availableProviders()
      if providers.isEmpty {
        await terminal.line("No providers configured. Type /about for setup commands.")
      }
      for provider in providers {
        let selected = provider.id == session.profile.provider ? "*" : " "
        let baseURL =
          (services.providerBaseURLs.url(for: provider.id.rawValue)
          ?? configuration?.providers.first { $0.id == provider.id.rawValue }?.baseURL)
          .map { " — \($0.absoluteString)" } ?? ""
        let defaultModel = provider.defaultModel.map { " — default model \($0)" } ?? ""
        let kind = configuration?.providers.first { $0.id == provider.id.rawValue }?.kind
        let availability = kind.flatMap { MaiLocalProvidersPlugin.availabilityMessage(for: $0) }
          .map { " — unavailable: \($0)" } ?? ""
        await terminal.line("\(selected) \(provider.id) — \(provider.displayName)\(baseURL)\(defaultModel)\(availability)")
      }
    case "/plugins":
      for plugin in await plugins.installedPlugins() {
        let capabilities = plugin.manifest.capabilities.map(\.rawValue).sorted().joined(
          separator: ", ")
        let origin = plugin.origin.map { " — \($0)" } ?? ""
        await terminal.line(
          "\(plugin.manifest.id) \(plugin.manifest.version) [\(capabilities)]\(origin)")
      }
    case "/models":
      if ["--help", "-h"].contains(argument) {
        await terminal.line(REPLModelListOptions.usage)
        return false
      }
      do {
        let providers = Set(await runtime.availableProviders().map(\.id))
        let options = try REPLModelListOptions(argument, current: session.profile.provider, providers: providers)
        let models = try await runtime.availableModels(provider: options.provider)
        services.modelCatalog.store(models, for: options.provider)
        let matches = options.filter.applying(to: models)
        await terminal.line("\(matches.count) of \(models.count) models · \(options.provider)")
        if models.isEmpty {
          await terminal.line("Provider '\(options.provider)' returned no models.")
        } else if matches.isEmpty {
          await terminal.line("No matching models. Try fewer filters; missing metadata is unknown.")
        }
        for model in matches {
          let selected = options.provider == session.profile.provider && model.id == session.profile.model
          await terminal.line(await terminal.modelCatalogRow(model, selected: selected))
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "/voice":
      await terminal.line(voiceHelp)
    case "/btw":
      await handleBTWCommand(argument, session: session, runtime: runtime, terminal: terminal)
    case "/todo":
      await handleTodoCommand(argument, todo: services.todo, terminal: terminal)
    case "/vdb":
      await handleVectorDatabaseCommand(
        argument, configuration: configuration, environment: ProcessInfo.processInfo.environment,
        access: services.promptFileAccess, terminal: terminal)
    case "/skills":
      await handleSkillsCommand(
        argument,
        session: &session,
        runtime: runtime,
        skills: services.skills,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        terminal: terminal)
    case "/memory":
      await handleMemoryCommand(
        argument,
        session: session,
        runtime: runtime,
        memory: services.memory,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        terminal: terminal)
    case "/prompts":
      // The REPL loop answers /prompts before it gets here, so a prompt can
      // be sent; from anywhere else the catalog is listed and kept.
      switch await handlePromptsCommand(
        argument,
        session: session,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        skills: services.skills.catalog,
        terminal: terminal)
      {
      case .handled:
        break
      case .send, .selectSystemPrompt:
        await terminal.line("Use $NAME [TEXT] or /prompts NAME [TEXT] at the chat prompt.")
      }
    case "/prompt":
      await handlePromptCommand(
        argument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        skills: services.skills.catalog,
        terminal: terminal)
    case "/chat":
      await handleChatCommand(
        argument,
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        recapPrompt: configuration?.prompts?.recap,
        chatProcess: chatProcess,
        terminal: terminal)
    case "/msg":
      await handleMessageCommand(argument, session: &session, runtime: runtime, terminal: terminal)
    case "/edit":
      await handleEditCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        memory: services.memory,
        skills: services.skills,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        providerBaseURLs: services.providerBaseURLs,
        chatProcess: chatProcess,
        terminal: terminal)
    case "/provider":
      await handleProviderCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        providerBaseURLs: services.providerBaseURLs,
        credentialsDirectory: services.themesDirectory.deletingLastPathComponent()
          .appendingPathComponent("chatgpt"),
        terminal: terminal)
    case "/baseurl":
      await handleBaseURLCommand(
        argument,
        currentProvider: session.profile.provider,
        configuration: configuration,
        providerBaseURLs: services.providerBaseURLs,
        terminal: terminal)
    case "/model":
      await handleModelCommand(
        argument, session: &session, runtime: runtime, configuration: &configuration,
        configurationPath: services.configurationPath, terminal: terminal)
    case "/agents", "/agent":
      await handleAgentCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        providerBaseURLs: services.providerBaseURLs,
        terminal: terminal)
    case "/tools":
      await handleToolsCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        terminal: terminal)
    case "/mcp":
      await handleMCPCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        catalogs: &catalogs,
        terminal: terminal)
    case "/mcps":
      await handleMCPCommand(
        "list",
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: services.configurationPath,
        catalogs: &catalogs,
        terminal: terminal)
    case "/image":
      let imageArguments = argument.split(
        maxSplits: 1, whereSeparator: \Character.isWhitespace
      ).map(String.init)
      guard imageArguments.count == 2,
        let mode = ImageAttachmentMode(rawValue: imageArguments[0].lowercased())
      else {
        await terminal.line("Usage: /image <tiny|small|medium|big|full|ocr> PATH")
        return false
      }
      do {
        let path = imageArguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        session.pendingContent.append(
          try await imageContent(path: path, mode: mode, ocrProvider: ocrProvider))
        if mode == .ocr {
          let markdownName = (path as NSString).lastPathComponent
          await terminal.line(
            "OCR text queued as \((markdownName as NSString).deletingPathExtension).md")
        } else {
          await terminal.line("Image queued at \(mode.rawValue) size: \(path)")
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "/attach":
      await attachDocument(
        argument,
        session: &session,
        ocrProvider: ocrProvider,
        editor: editor,
        terminal: terminal)
    case "/copy":
      await copyToClipboard(argument, session: session, terminal: terminal)
    case "/export":
      await handleExportCommand(
        argument,
        session: session,
        runtime: runtime,
        process: chatProcess,
        configuration: configuration,
        skills: services.skills.catalog,
        services: services,
        terminal: terminal)
    case "/import":
      await terminal.line("Use /import PATH at the interactive chat prompt.")
    case "/stats":
      await handleStatsCommand(argument, store: services.usageStats, terminal: terminal)
    case "/clear":
      await terminal.clearScreen()
    case "/queue":
      await terminal.line("The message queue lives at the terminal prompt.\n" + queueHelp)
    case "/reply":
      await terminal.line(
        "Use /reply at the chat prompt; it opens the last reply quoted in $EDITOR.")
    case "/stop":
      await terminal.line(
        "Use /stop at the chat prompt to interrupt the running turn and keep its queue.")
    case "/hey":
      await terminal.line("Use /hey at the chat prompt.\n" + heyHelp)
    case "/continue":
      // Hosted commands can queue input, but resuming belongs to the chat prompt.
      if argument.isEmpty {
        await terminal.line("Use /continue at the chat prompt.")
      } else {
        session.history.append(AgentMessage.user(argument))
        await terminal.line("Message added to history; use /continue at the chat prompt to resume.")
      }
    default:
      await terminal.line("Unknown command. Type /help.")
    }
    return false
  }
}
