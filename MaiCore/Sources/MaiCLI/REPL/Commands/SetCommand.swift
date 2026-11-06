import Foundation
import MaiCore
import MaiACP

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
  static func handleSetCommand(
    _ argument: String, session: inout REPLSession, runtime: AgentRuntime,
    plugins: PluginRegistry, providerBaseURLs: ProviderBaseURLStore,
    approvalHandler: TerminalApprovalHandler, configuration: inout MaiConfiguration?,
    configurationPath: String?, catalogs: inout [MCPServerCatalog], terminal: TerminalWriter,
    restoringDefault: Bool = false, remoteTerminalSettingsURL: URL? = nil
  ) async {
    await applySetCommand(
      argument, session: &session, runtime: runtime, plugins: plugins,
      providerBaseURLs: providerBaseURLs, approvalHandler: approvalHandler,
      configuration: &configuration, configurationPath: configurationPath, catalogs: &catalogs,
      terminal: terminal, restoringDefault: restoringDefault,
      remoteTerminalSettingsURL: remoteTerminalSettingsURL)
    do {
      let snapshot = try await diagnosticConfiguration(
        session: session, configuration: configuration, runtime: runtime,
        providerBaseURLs: providerBaseURLs, approvalHandler: approvalHandler)
      await runtime.recordDebugConfiguration(snapshot)
    } catch {
      // Diagnostics must not change the result of /set.
    }
  }

  private static func applySetCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    providerBaseURLs: ProviderBaseURLStore,
    approvalHandler: TerminalApprovalHandler,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    catalogs: inout [MCPServerCatalog],
    terminal: TerminalWriter,
    restoringDefault: Bool = false,
    remoteTerminalSettingsURL: URL? = nil
  ) async {
    // Recognize old provider URL spellings so they point to the editor rather
    // than being mistaken for an unrelated setting.
    var providerValue = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    var providerKey = String(providerValue.prefix { !$0.isWhitespace && $0 != "=" })
    providerValue = String(providerValue.dropFirst(providerKey.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if providerKey.lowercased() == "provider" {
      let child = String(providerValue.prefix { !$0.isWhitespace && $0 != "=" })
      providerKey += "." + child
      providerValue = String(providerValue.dropFirst(child.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if providerKey.lowercased() == "provider.baseurl" {
      if providerValue.hasPrefix("=") {
        providerValue = String(providerValue.dropFirst())
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      await handleBaseURLCommand(
        providerValue, currentProvider: session.profile.provider,
        configuration: configuration, providerBaseURLs: providerBaseURLs, terminal: terminal
      )
      return
    }
    let voiceKey = String(argument.prefix { !$0.isWhitespace && $0 != "=" })
    if voiceKey.lowercased() == "voice" || voiceKey.lowercased().hasPrefix("voice.") {
      do {
        let settings = configuration?.voice ?? .init()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if ["voice", "voice."].contains(voiceKey.lowercased()) {
          guard argument.dropFirst(voiceKey.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.unavailable("Choose a setting: /set voice.KEY VALUE. Use /set voice. to list keys; /voice help explains controls.")
          }
          await listSettings(try voiceSettings(settings), terminal: terminal)
          await terminal.line("Use /set voice.KEY to see its value and help; /set voice.KEY VALUE saves it. /voice help explains controls.")
          return
        }
        let requested = String(voiceKey.dropFirst(6))
        if requested.lowercased() == "instructions" {
          await terminal.line("Use /edit prompt voice to edit voice instructions; /prompts show voice displays them.")
          return
        }
        guard let key = ConfiguredVoice.settingNames.first(where: { $0.lowercased() == requested.lowercased() }) else {
          throw VoiceError.unavailable("Unknown voice setting. /set voice lists settings.")
        }
        var value = String(argument.dropFirst(voiceKey.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("=") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        let object = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(settings))
        if value.isEmpty {
          await terminal.line("voice.\(key) = \(String(decoding: try encoder.encode(object[key] ?? .null), as: UTF8.self))")
          await terminal.line(voiceSettingHelp(key, settings: settings))
          return
        }
        guard var draft = configuration, let configurationPath else {
          throw VoiceError.unavailable("No writable configuration is active.")
        }
        draft.voice = try updatedVoiceSettings(settings, key: key, value: value)
        if !restoringDefault && (key == "input" || key == "output") {
          let kind = key == "input" ? draft.voice.input : draft.voice.output
          let kinds = await plugins.voiceProviderKinds()
          guard kinds.contains(kind) else {
            throw VoiceError.unavailable("Unknown voice.\(key) backend '\(kind)'. Available: \(kinds.joined(separator: ", ")).")
          }
        }
        if key == "provider", let id = draft.voice.provider,
          !draft.providers.contains(where: { $0.id == id }) {
          throw VoiceError.unavailable("Unknown voice.provider '\(id)'. Choose a configured provider ID from /providers, or null to clear it.")
        }
        if !restoringDefault, key == "voice", draft.voice.output == "system" {
          let factory = try await plugins.voiceFactory(kind: "system")
          _ = try await factory.makeOutput(settings: draft.voice, configuration: draft,
            environment: ProcessInfo.processInfo.environment)
        }
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line("Set voice.\(key). To apply to active voice: /voice off then /voice on.")
        if ["language", "output"].contains(key), draft.voice.voice != "default" {
          await terminal.line("Speech still uses voice ID '\(draft.voice.voice)'. Use /set voice.voice default to follow the language, or /voice voices to choose an ID for output=\(draft.voice.output).")
        }
        if !restoringDefault, ["language", "input"].contains(key), draft.voice.input == "system" {
          let factory = try await plugins.voiceFactory(kind: "system")
          let catalog = try await factory.catalog(for: .input, settings: draft.voice, configuration: draft,
            environment: ProcessInfo.processInfo.environment)
          if let language = catalog.languages.first(where: { $0.id == draft.voice.languageIdentifier }),
            let reason = language.unavailableReason {
            await terminal.line("Saved language \(language.id), but system input is unavailable: \(reason). Use /voice languages \(language.id) for details, or configure command/openai input.")
          }
        }
      } catch { await terminal.line("voice: \(error.localizedDescription)", to: .standardError) }
      return
    }
    let parts: [String]
    let settingName = argument.prefix { !$0.isWhitespace && $0 != "=" }
    if settingName.lowercased() == "ui.highlight" {
      var value = argument.dropFirst(settingName.count).trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("=") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
      parts = [String(settingName)] + (value.isEmpty ? [] : [value])
    } else {
      parts = argument.replacingOccurrences(of: "=", with: " ")
        .split(whereSeparator: \Character.isWhitespace).map(String.init)
    }
    if parts.isEmpty || (parts.count == 1 && parts[0].hasSuffix(".")) {
      let settings: [String]
      do {
        settings = try await currentSetSettings(
          profile: session.profile, configuration: configuration, runtime: runtime,
          approvalHandler: approvalHandler)
      } catch {
        await terminal.line("settings: \(error.localizedDescription)", to: .standardError)
        return
      }
      let prefix = parts.first?.lowercased() ?? ""
      let matching = settings.filter { $0.lowercased().hasPrefix(prefix) }
      if !matching.isEmpty {
        await listSettings(matching, terminal: terminal)
        return
      }
    }
    let requestedKey = parts[0].lowercased()
    let key = requestedKey == "ui.toolresultlines" ? "ui.tools" : requestedKey
    let displayedKey = key
    if key == "http.transport" {
      guard var draft = configuration,
        let index = draft.providers.firstIndex(where: {
          $0.id == session.profile.provider.rawValue && $0.kind == .openAI
        })
      else {
        await terminal.line("http.transport requires a selected OpenAI-compatible provider. Use /provider or /model to select one.")
        return
      }
      guard parts.count > 1 else {
        await listSettings(httpSettings(provider: session.profile.provider, configuration: draft), terminal: terminal)
        await terminal.line("auto uses winhttp on Windows and urlsession elsewhere. curl uses the curl executable; winhttp is Windows-only. Saved for this provider; applies to the next request.")
        return
      }
      guard parts.count == 2, let transport = ProviderHTTPTransport(rawValue: parts[1].lowercased()) else {
        await terminal.line("Usage: /set http.transport <auto|curl|winhttp|urlsession>")
        return
      }
      #if !os(Windows)
      guard transport != .winHTTP else {
        await terminal.line("error: WinHTTP is only available on Windows.", to: .standardError)
        return
      }
      #endif
      guard let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      draft.providers[index].options["httpTransport"] = transport == .automatic ? nil : .string(transport.rawValue)
      do {
        let provider = try await plugins.makeProvider(
          from: draft.providers[index], environment: ProcessInfo.processInfo.environment)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        try await runtime.register(provider, replacingExisting: true)
        configuration = draft
        await listSettings(httpSettings(provider: session.profile.provider, configuration: draft), terminal: terminal)
        await terminal.line("Saved for provider '\(draft.providers[index].id)'; applies to the next request.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if key == "limits.terminaltimeout" {
      guard parts.count > 1 else {
        await terminal.line("limits.terminalTimeout = \(configuration?.remoteTerminalTimeoutSeconds ?? 0) (seconds; 0 keeps sessions until closed)")
        return
      }
      guard parts.count == 2, let seconds = parts[1] == "0" ? 0 : parseDurationSeconds(parts[1]), seconds <= 31_536_000 else {
        await terminal.line("Usage: /set limits.terminalTimeout <0|SECONDS|3m20s|1h20m> (0 disables idle expiry)")
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        draft.remoteTerminalTimeoutSeconds = seconds
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        if let remoteTerminalSettingsURL {
          try ACPStateFiles.createDirectory(remoteTerminalSettingsURL.deletingLastPathComponent())
          try ACPStateFiles.write(seconds, to: remoteTerminalSettingsURL)
        }
        configuration = draft
        await terminal.line("Set limits.terminalTimeout = \(seconds) seconds. Applies to running remote terminals; 0 disables idle expiry.")
      } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
      return
    }
    if ["acp.timeout", "acp.context", "acp.prompt"].contains(key) {
      guard var draft = configuration,
        let index = draft.providers.firstIndex(where: {
          $0.id == session.profile.provider.rawValue
            && $0.kind == ACPConfiguredProviderFactory.providerKind
        })
      else {
        await terminal.line("\(key) requires a selected ACP provider. Use /provider or /model to select one.")
        return
      }
      guard parts.count > 1 else {
        await listSettings(acpSettings(provider: session.profile.provider, configuration: draft).filter { $0.hasPrefix(key + " = ") }, terminal: terminal)
        switch key {
        case "acp.context":
          await terminal.line("agent keeps the external conversation; replace starts a new session with pmai's full prepared conversation each turn. Saved for this provider.")
        case "acp.prompt":
          await terminal.line("agent sends pmai instructions as user text; replace uses them as the native system prompt. Edit the text with /prompt edit. Saved for this provider.")
        default:
          await terminal.line("Whole ACP turn timeout, separate from limits.maxSeconds. Use off or a duration such as 30m; saved for this provider.")
        }
        return
      }
      let raw = parts.count == 2 ? parts[1].lowercased() : ""
      if key != "acp.timeout" {
        let mode: String
        if ["agent", "off", "false", "default"].contains(raw) { mode = "agent" }
        else if ["replace", "on", "true"].contains(raw) { mode = "replace" }
        else {
          await terminal.line("Usage: /set \(key) <agent|replace>")
          return
        }
        draft.providers[index].options[String(key.dropFirst(4))] = mode == "agent" ? nil : .string(mode)
      } else if ["off", "none", "unlimited", "0", "default"].contains(raw) {
        draft.providers[index].timeout = nil
      } else if let seconds = parseDurationSeconds(raw) {
        draft.providers[index].timeout = TimeInterval(seconds)
      } else {
        await terminal.line("Usage: /set acp.timeout <off|N|Nm|Nh>")
        return
      }
      guard let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let provider = try await plugins.makeProvider(
          from: draft.providers[index], environment: ProcessInfo.processInfo.environment)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        try await runtime.register(provider, replacingExisting: true)
        configuration = draft
        await listSettings(acpSettings(provider: session.profile.provider, configuration: draft), terminal: terminal)
        await terminal.line(key == "acp.timeout"
          ? "Saved for provider '\(draft.providers[index].id)'; applies to new requests with a fresh timeout."
          : "Saved for provider '\(draft.providers[index].id)'; applies to the next request with a new ACP session.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if key == "awake" {
      guard parts.count > 1 else {
        await terminal.line("awake = \(await AwakeController.shared.isEnabled ? "on" : "off")")
        return
      }
      guard parts.count == 2, ["on", "off"].contains(parts[1].lowercased()) else {
        await terminal.line("Usage: /set awake [on|off]")
        return
      }
      let enabled = parts[1].lowercased() == "on"
      let previous = await AwakeController.shared.isEnabled
      do {
        try await AwakeController.shared.setEnabled(enabled)
        if var draft = configuration, let configurationPath {
          draft.awake = enabled
          do { try draft.save(to: URL(fileURLWithPath: configurationPath)) }
          catch {
            try? await AwakeController.shared.setEnabled(previous)
            throw error
          }
          configuration = draft
        }
        await terminal.line("awake = \(enabled ? "on" : "off")")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if key == "airplane" {
      guard parts.count > 1 else {
        await terminal.line("airplane = \(await runtime.internetAccessPolicy().airplaneModeEnabled ? "on ✈" : "off")")
        return
      }
      guard parts.count == 2 else {
        await terminal.line("Usage: /set airplane <on|off|toggle>")
        return
      }
      var policy = await runtime.internetAccessPolicy()
      if parts[1].lowercased() == "toggle" {
        policy.toggleAirplaneMode()
      } else if let enabled = booleanSetting(parts[1]) {
        policy.setAirplaneMode(enabled)
      } else {
        await terminal.line("Usage: /set airplane <on|off|toggle>")
        return
      }
      let enabled = policy.airplaneModeEnabled
      if var draft = configuration, let configurationPath {
        draft.airplane = enabled
        do {
          try draft.save(to: URL(fileURLWithPath: configurationPath))
          configuration = draft
        } catch {
          await terminal.line("error: \(error.localizedDescription)", to: .standardError)
          return
        }
      }
      await runtime.configureInternetAccess(policy)
      if !enabled {
        for server in configuration?.mcpServers ?? [] where server.enabled && !catalogs.contains(where: { $0.serverID == server.id }) {
          do {
            let source = try await plugins.makeMCPToolSource(kind: server.kind, configuration: server,
              environment: ProcessInfo.processInfo.environment)
            catalogs.append(try await runtime.register(mcp: source))
          } catch {
            await terminal.line("warning: MCP '\(server.id)' could not reconnect: \(error.localizedDescription)", to: .standardError)
          }
        }
      }
      await terminal.line("airplane = \(enabled ? "on ✈ (internet tools disabled)" : "off")")
      return
    }
    if key == "export" || key == "export." {
      await listSettings(exportSettings(configuration?.documentExport ?? .init()), terminal: terminal)
      return
    }
    if key == "export.tools" || key == "export.thinking" {
      var options = configuration?.documentExport ?? .init()
      guard parts.count > 1 else {
        let enabled = key == "export.tools" ? options.includeToolCalls : options.includeThinking
        await terminal.line("\(key) = \(enabled ? "on" : "off")")
        return
      }
      guard parts.count == 2, let enabled = booleanSetting(parts[1]) else {
        await terminal.line("Usage: /set \(key) <on|off>")
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      if key == "export.tools" {
        options.includeToolCalls = enabled
      } else {
        options.includeThinking = enabled
      }
      draft.documentExport = options
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line("Set \(key) = \(enabled ? "on" : "off").")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if key == "debugfile" {
      // Preserve spaces and '=' in paths; the other /set values are tokenized.
      let remainder = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        .dropFirst(parts[0].count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let rawPath =
        remainder.hasPrefix("=")
        ? String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        : remainder
      guard !rawPath.isEmpty else {
        await terminal.line("debugfile = \(await approvalHandler.debugLogURL().path)")
        return
      }
      let destination: URL?
      if rawPath.lowercased() == "default" {
        destination = nil
      } else {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
          await terminal.line("Usage: /set debugfile <PATH|default>")
          return
        }
        destination =
          URL(
            fileURLWithPath: expanded,
            relativeTo: URL(
              fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
          )
          .standardizedFileURL
      }
      let selectedURL: URL
      if let destination {
        selectedURL = destination
      } else {
        selectedURL = await approvalHandler.defaultDebugLogURL()
      }
      do {
        let enabled = await approvalHandler.isDebugEnabled()
        let log = enabled ? try AgentDebugLog(url: selectedURL) : nil
        try await approvalHandler.saveDebugFile(destination)
        if enabled { await runtime.configureDebugLog(log) }
        await terminal.line("debugfile = \(selectedURL.path)")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if key == "redact" {
      guard parts.count > 1 else {
        await terminal.line("redact = \((configuration?.redact ?? .off).rawValue)")
        return
      }
      guard parts.count == 2, let mode = RedactionMode(rawValue: parts[1].lowercased()) else {
        await terminal.line("Usage: /set redact on|off|warn (edit rules with /edit redact)")
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let url = await runtime.redactionRulesURL()
        if mode != .off {
          try ensureRedactionFile(at: url)
          _ = try ContentRedactor.parse(String(contentsOf: url, encoding: .utf8))
        }
        draft.redact = mode
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        try await runtime.configureRedaction(mode)
        configuration = draft
        session.redactor = await runtime.contentRedactor(sessionID: session.sessionID)
        await terminal.configureRedactor(session.redactor)
        await terminal.line("redact = \(mode.rawValue)")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if key == "debug" {
      guard parts.count > 1 else {
        let enabled = await approvalHandler.isDebugEnabled()
        await terminal.line("debug = \(enabled ? "true" : "false")")
        if enabled { await terminal.line("Log: \(await approvalHandler.debugLogURL().path)") }
        return
      }
      guard parts.count == 2, let enabled = booleanSetting(parts[1]) else {
        await terminal.line("Usage: /set debug <true|false>")
        return
      }
      do {
        let log = enabled ? try AgentDebugLog(url: await approvalHandler.debugLogURL()) : nil
        try await approvalHandler.saveDebugEnabled(enabled)
        await runtime.configureDebugLog(log)
        await terminal.line("debug = \(enabled ? "true" : "false")")
        if enabled { await terminal.line("Log: \(await approvalHandler.debugLogURL().path)") }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if key == "effort" {
      await handleEffortCommand(
        parts.dropFirst().joined(separator: " "),
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "ui" || key == "ui." {
      await listSettings(uiSettings(configuration?.ui ?? .init()), terminal: terminal)
      return
    }
    if key == "use" || key == "use." {
      await listSettings(useSettings(configuration?.use ?? .init()), terminal: terminal)
      return
    }
    if key == "use.agentsmd" {
      await setAgentsMarkdown(
        parts: parts,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "use.plan" {
      await setPlanning(
        parts: parts,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "limits" || key == "limits." {
      await listSettings(limitSettings(session.profile.limits)
        + ["limits.terminalTimeout = \(configuration?.remoteTerminalTimeoutSeconds ?? 0)"], terminal: terminal)
      return
    }
    if let limitKey = limitSettingKeys[key] {
      await setLimit(
        limitKey,
        parts: parts,
        session: &session,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if let recoveryKey = recoverySettingKeys[key] {
      await setRecoverySetting(
        recoveryKey,
        parts: parts,
        session: &session,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if delegationSettingKeys.contains(key) {
      await setToolDelegation(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "tool" || key == "tool." || key == "tools" || key == "tools." {
      await terminal.line("tool.approval = \(await approvalHandler.currentApprovalMode().rawValue)")
      await listSettings(toolSettings(session.profile), terminal: terminal)
      return
    }
    if toolCallingStrategyKeys.contains(key) {
      await setToolCallingStrategy(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "tool.systemone" {
      guard parts.count > 1 else {
        await terminal.line("tool.systemone = \(session.profile.useSystemOne)")
        return
      }
      guard parts.count == 2, let enabled = booleanSetting(parts[1]) else {
        await terminal.line("Usage: /set tool.systemone <true|false>")
        return
      }
      session.profile.useSystemOne = enabled
      session.touch()
      if configuration != nil, configurationPath != nil {
        _ = await persistAgentProfile(
          session: session, configuration: &configuration,
          configurationPath: configurationPath, runtime: runtime, terminal: terminal)
      }
      await terminal.line("tool.systemone = \(enabled)")
      return
    }
    if ["tool.auto", "tools.auto", "tool.automatic"].contains(key) {
      if parts.count == 1 {
        await terminal.line("tool.auto = \(session.profile.toolPolicy.automatic)")
        return
      }
      guard parts.count == 2, let enabled = booleanSetting(parts[1]) else {
        await terminal.line("Usage: /set tool.auto <on|off>")
        return
      }
      session.profile.toolPolicy.automatic = enabled
      session.touch()
      _ = await persistAgentProfile(
        session: session, configuration: &configuration, configurationPath: configurationPath,
        runtime: runtime, terminal: terminal)
      await terminal.line("tool.auto = \(enabled)")
      return
    }
    if toolProxyKeys.contains(key) {
      await setToolProxy(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "ctx.strategy" {
      await setContextMode(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "tool.approval" || key == "tool.aproval" {
      await setToolApproval(
        parts: parts,
        approvalHandler: approvalHandler,
        terminal: terminal)
      return
    }

    let emphasisColorKeys = ["ui.fgbold", "ui.fgitalic"]
    if key.hasPrefix("ui."), TerminalTheme.keys.contains(String(key.dropFirst(3))),
      !emphasisColorKeys.contains(key)
    {
      await terminal.line("Use /theme color \(key.dropFirst(3)) [VALUE].")
      return
    }
    let booleanKeys = ["ui.markdown", "ui.tableborders", "ui.broadcast", "ui.toolgroups"]
    let countKeys = ["ui.tools", "ui.toolcalls", "ui.scroll", "ui.scrollbar"]
    let levelKeys = ["ui.subagents", "ui.thinking", "ui.mode", "ui.line"]
    if key == "ui.title" {
      await terminal.line("Use /chat title [TEXT|none] for a temporary prompt and terminal/tab title.")
      return
    }
    let textKeys = ["ui.editor", "ui.highlight"]
    guard
      emphasisColorKeys.contains(key) || booleanKeys.contains(key) || countKeys.contains(key)
        || levelKeys.contains(key) || textKeys.contains(key)
    else {
      await terminal.line(
        "Unknown setting '\(parts[0])'. Available settings: debug, debugfile, airplane, effort, http.transport, acp.timeout, acp.context, acp.prompt, tool.approval, delegation, tool.calling, tool.proxy, tool.systemone, limits.maxToolCalls, limits.maxModelTurns, limits.maxSubagents, limits.maxSubagentDepth, limits.maxTotalTokens, limits.maxSeconds, limits.runTimeoutSeconds, retry.attempts, retry.delay, ctx.compact, ctx.recent, ctx.window, ctx.strategy, \((textKeys + booleanKeys + countKeys + levelKeys).joined(separator: ", ")), export.tools, export.thinking, redact, use.agentsmd, use.plan"
      )
      return
    }
    var ui = configuration?.ui ?? .init()
    guard parts.count > 1 else {
      await terminal.line("\(displayedKey) = \(uiSetting(key, in: ui))")
      return
    }
    guard parts.count == 2 || textKeys.contains(key) else {
      await terminal.line("Usage: /set \(key) VALUE")
      return
    }
    if emphasisColorKeys.contains(key) {
      do {
        try TerminalTheme.set(String(key.dropFirst(3)), value: parts[1], in: &ui)
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
        return
      }
    } else if textKeys.contains(key) {
      let text = parts.dropFirst().joined(separator: " ")
      // "none" clears highlighting or falls back to $EDITOR.
      let value = ["none", "off"].contains(text.lowercased()) ? "" : text
      if key == "ui.highlight" {
        ui.highlight = value
      } else {
        ui.editor = value
      }
    } else if key == "ui.scroll" {
      guard let value = Int(parts[1]), value > 0 else {
        await terminal.line("Usage: /set ui.scroll <positive integer>")
        return
      }
      ui.scroll = value
    } else if key == "ui.scrollbar" {
      guard let value = Int(parts[1]) else {
        await terminal.line("Usage: /set ui.scrollbar <integer: positive right, negative left, 0 hidden>")
        return
      }
      ui.scrollbar = value
    } else if key == "ui.toolcalls" {
      guard let value = ToolCallDisplay(setting: parts[1]) else {
        await terminal.line("Usage: /set ui.toolcalls <truncate|first|N> (N > 0)")
        return
      }
      ui.toolCalls = value
    } else if key == "ui.tools" {
      guard let value = ToolResultDisplay(setting: parts[1]) else {
        await terminal.line("Usage: /set ui.tools <all|relevant|icons|N>")
        return
      }
      ui.tools = value
      await terminal.configureTools(value)
    } else if key == "ui.line" {
      guard let mode = TerminalInputLineMode(rawValue: parts[1].lowercased()) else {
        await terminal.line("Usage: /set ui.line <single|multi>")
        return
      }
      ui.line = mode
    } else if key == "ui.mode" {
      guard let mode = TerminalOutputMode(rawValue: parts[1].lowercased()) else {
        await terminal.line("Usage: /set ui.mode <classic|buffer>")
        return
      }
      ui.mode = mode
    } else if key == "ui.thinking" {
      guard let mode = ThinkingDisplay(rawValue: parts[1].lowercased()) else {
        await terminal.line("Usage: /set ui.thinking <status|line|three|five|full>")
        return
      }
      ui.thinking = mode
      await terminal.configureThinking(mode)
    } else if levelKeys.contains(key) {
      guard let level = SubagentOutputLevel(rawValue: parts[1].lowercased()) else {
        await terminal.line(
          "Usage: /set ui.subagents <\(SubagentOutputLevel.allCases.map(\.rawValue).joined(separator: "|"))>"
        )
        return
      }
      ui.subagentOutput = level
      await terminal.configureSubagentOutput(level)
    } else if booleanKeys.contains(key) {
      guard let enabled = booleanSetting(parts[1]) else {
        await terminal.line("Usage: /set \(key) <on|off>")
        return
      }
      if key == "ui.toolgroups" {
        ui.toolGroups = enabled
        if enabled { ui.mode = .buffer }
      } else if key == "ui.broadcast" {
        ui.broadcast = enabled
      } else if key == "ui.tableborders" {
        ui.tableBorders = enabled
      } else {
        ui.markdown = enabled
        await terminal.configureMarkdown(
          markdownRenderer(
            enabled: enabled, forced: false, environment: ProcessInfo.processInfo.environment))
      }
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.ui = ui
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.configureColors(ui)
      if key == "ui.editor" { configureEditor(ui.editor) }
      await terminal.line("Set \(displayedKey) = \(uiSetting(key, in: ui)).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
