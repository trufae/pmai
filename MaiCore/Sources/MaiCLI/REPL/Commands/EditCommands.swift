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

extension MaiCLI {
  /// Opens a text value from the active REPL session in the user's terminal
  /// editor. Transcript and configuration edits deliberately go through the
  /// same core types used by the iOS app and the persistent chat workspace.
  static func handleEditCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    memory: MemoryState,
    skills: SkillState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    chatProcess: AgentPID? = nil,
    terminal: TerminalWriter
  ) async {
    let target = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      await terminal.line(editHelp)
      return
    }
    let fields = target.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let actionArgument = fields.count == 2 ? fields[1] : ""
    let action = fields[0].lowercased() == "prompt" && actionArgument.lowercased() == "smart"
      ? "smart" : fields[0].lowercased()

    switch action {
    case "chat":
      if actionArgument.isEmpty {
        if let chatProcess, let info = await runtime.supervisor.info(chatProcess), !info.state.isTerminal {
          await terminal.line("Wait for this chat's turn to finish before editing its context.")
          return
        }
        await editConversation(session: &session, terminal: terminal)
        return
      }
      guard let index = editableMessageIndex(actionArgument, in: session.history) else {
        await terminal.line("Usage: /edit chat INDEX|MESSAGE_ID")
        return
      }
      await editChatMessage(at: index, session: &session, terminal: terminal)

    case "skill", "skills":
      await handleSkillMutation(
        "edit", argument: actionArgument, session: &session, runtime: runtime,
        skills: skills, plugins: plugins, configuration: &configuration,
        configurationPath: configurationPath, terminal: terminal)

    case "soul":
      await handleEditSoulCommand(terminal: terminal)

    case "redact":
      guard actionArgument.isEmpty else {
        await terminal.line("Usage: /edit redact")
        return
      }
      do {
        let url = await runtime.redactionRulesURL()
        try ensureRedactionFile(at: url)
        guard await launchEditor(at: url, terminal: terminal) else { return }
        let rules = try ContentRedactor.parse(String(contentsOf: url, encoding: .utf8))
        try await runtime.configureRedaction(configuration?.redact ?? .off)
        await terminal.line(
          "Saved \(rules.count) redaction rule\(rules.count == 1 ? "" : "s") to \(url.path).")
      } catch {
        await terminal.line(
          "error: \(error.localizedDescription) Previous redaction rules remain active.",
          to: .standardError)
      }

    case "system":
      await editSystemPrompt(
        named: actionArgument.isEmpty
          ? session.profile.systemPrompt ?? session.profile.agentID : actionArgument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "user", "userprompt":
      guard !actionArgument.isEmpty else {
        await terminal.line("Usage: /edit user NAME")
        return
      }
      await editUserPrompt(
        named: actionArgument,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "prompt":
      // Without a name, the current agent's system prompt. With one, the
      // prompt of that name, whichever kind it is; a system prompt and a
      // user prompt are different things, so a new one is created with
      // /edit system NAME or /edit user NAME.
      guard !actionArgument.isEmpty else {
        await editSystemPrompt(
          named: session.profile.systemPrompt ?? session.profile.agentID,
          session: &session,
          runtime: runtime,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
        return
      }
      let wanted = PromptSlashCommand.normalized(actionArgument)
      if wanted == "recap" {
        await editRecapPrompt(
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
      } else if let name = resolvedSystemPromptName(actionArgument, configuration: configuration) {
        await editSystemPrompt(
          named: name,
          session: &session,
          runtime: runtime,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
      } else if let name = configuration?.userPromptName(matching: actionArgument) {
        await editUserPrompt(
          named: name,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
      } else if UserPrompt.builtins.contains(where: {
        PromptSlashCommand.normalized($0.commandName) == wanted
      }) {
        await editUserPrompt(
          named: actionArgument,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
      } else {
        await terminal.line(
          "No prompt named '\(actionArgument)'. /edit system NAME creates a system prompt, /edit user NAME a user prompt; /prompts lists both."
        )
      }

    case "agent":
      await editAgentDefinition(
        named: actionArgument.isEmpty ? session.profile.agentID : actionArgument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "provider":
      await editConfiguredProvider(
        named: actionArgument.isEmpty ? session.profile.provider.rawValue : actionArgument,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)

    case "input":
      // The chat prompt intercepts this one, because the message it writes is
      // sent from there; here it can only say where it works.
      await terminal.line(
        "Use /edit input at the chat prompt; it opens an empty file, then asks before sending."
      )

    case "compact", "smart":
      let smart = action == "smart"
      let defaultPrompt = smart ? AgentSmartContextPrompt.template : defaultCompactPrompt
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let previous = (smart ? draft.prompts?.smart : draft.prompts?.compact) ?? defaultPrompt
      guard
        let edited = await editTemporaryText(
          previous, suffix: "\(action)-prompt.md", terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      guard candidate.isEmpty || candidate.contains("{{transcript}}") else {
        await terminal.line(
          "error: The \(action) prompt must contain {{transcript}}; no changes were saved.",
          to: .standardError)
        return
      }
      let customPrompt =
        candidate.isEmpty || candidate == defaultPrompt ? nil : candidate
      var prompts = draft.prompts ?? ConfiguredPrompts()
      if smart { prompts.smart = customPrompt } else { prompts.compact = customPrompt }
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        if smart {
          await runtime.configureSmartContext(prompt: customPrompt)
        } else {
          await runtime.configureCompaction(prompt: customPrompt)
        }
        configuration = draft
        await terminal.line(
          customPrompt == nil
            ? "\(action.capitalized) prompt restored to the built-in default."
            : "\(action.capitalized) prompt saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "memory":
      guard
        let edited = await editTemporaryText(
          memory.current.text, suffix: "memory.md", terminal: terminal)
      else { return }
      await store(AgentMemory(text: edited), in: memory, runtime: runtime, terminal: terminal)

    case "memory-prompt", "learn":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      var prompts = draft.prompts ?? ConfiguredPrompts()
      guard
        let edited = await editTemporaryText(
          prompts.memory ?? AgentMemoryPrompt.template,
          suffix: "memory-prompt.md",
          terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      if let missing = AgentMemoryPrompt.missingPlaceholder(in: candidate) {
        await terminal.line(
          "error: The memory prompt must contain \(missing); no changes were saved.",
          to: .standardError)
        return
      }
      prompts.memory =
        candidate.isEmpty || candidate == AgentMemoryPrompt.template ? nil : candidate
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line(
          prompts.memory == nil
            ? "The memory prompt was restored to the built-in default."
            : "The memory prompt was saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "delegation", "worker":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      var prompts = draft.prompts ?? ConfiguredPrompts()
      let isBrief = action == "delegation"
      let builtIn =
        isBrief ? AgentDelegationPrompt.template : AgentDelegationPrompt.workerInstructions
      let previous = (isBrief ? prompts.delegation : prompts.worker) ?? builtIn
      guard
        let edited = await editTemporaryText(
          previous, suffix: "\(action)-prompt.md", terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      if isBrief, let missing = AgentDelegationPrompt.missingPlaceholder(in: candidate) {
        await terminal.line(
          "error: The delegation prompt must contain \(missing); no changes were saved.",
          to: .standardError)
        return
      }
      let custom = candidate.isEmpty || candidate == builtIn ? nil : candidate
      if isBrief { prompts.delegation = custom } else { prompts.worker = custom }
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        await runtime.configureDelegation(
          prompt: prompts.delegation, workerInstructions: prompts.worker)
        configuration = draft
        await terminal.line(
          custom == nil
            ? "The \(action) prompt was restored to the built-in default."
            : "The \(action) prompt was saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "config":
      guard let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let url = URL(fileURLWithPath: configurationPath)
      guard await launchEditor(at: url, terminal: terminal) else { return }
      do {
        var editedConfiguration = try MaiConfiguration.load(from: url)
        if editedConfiguration.associateSystemPrompts() {
          try editedConfiguration.save(to: url)
        }
        for agent in editedConfiguration.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        await runtime.configureDelegation(
          prompt: editedConfiguration.prompts?.delegation,
          workerInstructions: editedConfiguration.prompts?.worker)
        await runtime.configureCompaction(prompt: editedConfiguration.prompts?.compact)
        await runtime.configureSmartContext(prompt: editedConfiguration.prompts?.smart)
        await runtime.configureTaskAgents(editedConfiguration.taskAgents)
        if let agent = editedConfiguration.agents.first(where: {
          $0.id == session.profile.agentID
        }) {
          session.profile.limits = agent.limits
          session.profile.toolCallingStrategy = agent.toolCallingStrategy
          session.profile.toolDelegation = agent.toolDelegation
          session.profile.retry = agent.retry
          session.profile.autocompact = agent.autocompact
          session.profile.systemPrompt = agent.systemPrompt
          session.profile.systemContext = agent.systemContext
          try applySystemInstructions(
            agent.instructions,
            replacing: session.profile.instructions,
            session: &session)
        }
        try await runtime.configureRedaction(editedConfiguration.redact)
        configuration = editedConfiguration
        await terminal.line(
          "Configuration saved. Agent limits and tool-calling strategy were applied; "
            + "restart pmai to apply provider, plugin, tool, or MCP changes.")
      } catch {
        await terminal.line(
          "error: The edited configuration was not loaded: \(error.localizedDescription)",
          to: .standardError)
      }

    case "mcps", "mcp":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft.mcpServers)
        guard let edited = await editTemporaryData(data, suffix: "mcps.json", terminal: terminal)
        else {
          return
        }
        draft.mcpServers = try JSONDecoder().decode([ConfiguredMCPServer].self, from: edited)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line("MCP configuration saved. Restart pmai to reconnect MCP servers.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      if let name = resolvedSystemPromptName(target, configuration: configuration) {
        await editSystemPrompt(
          named: name,
          session: &session,
          runtime: runtime,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
        return
      }
      if let name = configuration?.userPromptName(matching: target) {
        await editUserPrompt(
          named: name,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
        return
      }
      guard let index = editableMessageIndex(target, in: session.history) else {
        await terminal.line("Unknown edit target '\(target)'.\n\n\(editHelp)")
        return
      }
      await editChatMessage(at: index, session: &session, terminal: terminal)
    }
  }

  static func editChatMessage(
    at index: Int,
    session: inout REPLSession,
    terminal: TerminalWriter
  ) async {
    let message = session.history[index]
    guard
      let edited = await editTemporaryText(message.text, suffix: "message.md", terminal: terminal)
    else { return }
    do {
      try session.history.editMessage(at: index, text: edited)
      await terminal.line("Edited message \(index + 1) (id: \(message.id)).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  static func editConversation(session: inout REPLSession, terminal: TerminalWriter) async {
    let original = session.history.messages
    let document = AgentConversationMarkdown.text(for: original)
    guard let edited = await editTemporaryText(document, suffix: "conversation.md", terminal: terminal),
      edited != document else { return }
    do {
      let messages = try AgentConversationMarkdown.applying(edited, to: original)
      session.history.replaceAll(with: messages)
      session.sessionID = ChatSession.newID()
      session.touch()
      await terminal.line("Conversation context updated. Original messages retained.")
    } catch {
      await terminal.line("error: \(error.localizedDescription) No conversation changes were saved.", to: .standardError)
    }
  }

  private static func editableMessageIndex(_ target: String, in transcript: AgentTranscript) -> Int?
  {
    if let index = chatIndex(target, count: transcript.count) { return index }
    return transcript.index(ofMessageID: target)
  }

  static func editTemporaryText(
    _ text: String, suffix: String, command: String? = nil, terminal: TerminalWriter
  ) async -> String? {
    guard let data = text.data(using: .utf8),
      let edited = await editTemporaryData(data, suffix: suffix, command: command, terminal: terminal)
    else { return nil }
    guard let result = String(data: edited, encoding: .utf8) else {
      await terminal.line("error: Editor output must be UTF-8 text.", to: .standardError)
      return nil
    }
    return result
  }

  static func editTemporaryData(
    _ data: Data, suffix: String, command: String? = nil, terminal: TerminalWriter
  ) async -> Data? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pmai-edit-\(UUID().uuidString)-\(suffix)")
    do {
      try data.write(to: url, options: .atomic)
      defer { try? FileManager.default.removeItem(at: url) }
      guard await launchEditor(at: url, command: command, terminal: terminal) else { return nil }
      return try Data(contentsOf: url)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return nil
    }
  }

  static func ensureRedactionFile(at url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let template = """
      # One case-insensitive word or /regular expression/ per line.
      # Optional =label names a unique placeholder; blank lines and # comments are ignored.
      # Enable with /set redact on or /set redact warn.

      """
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private static func handleEditSoulCommand(terminal: TerminalWriter) async {
    let soulPath = AgentHome.expandUserPath("~/.pmai/SOUL.md")
    let url = URL(fileURLWithPath: soulPath)

    let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

    guard
      let edited = await editTemporaryText(
        previous, suffix: "soul.md", terminal: terminal)
    else { return }

    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try edited.write(to: url, atomically: true, encoding: .utf8)
      await terminal.line("Soul saved to \(soulPath).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
