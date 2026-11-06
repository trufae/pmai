import Foundation
import MaiCore
import MaiACP
import MaiStandardTools

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
  /// Use the same defaults and setters as a full reset, without changing sibling settings.
  static func resetSetting(_ argument: String, profile: SessionProfile) throws
    -> (key: String, value: String, theme: Bool)
  {
    let words = argument.split(whereSeparator: \.isWhitespace)
    guard words.count == 1 else {
      throw JSONRPCError.invalidParams("Usage: /reset SETTING (or /reset to reset everything)")
    }
    let requested = String(words[0]).lowercased()
    var key = (limitSettingKeys[requested] ?? recoverySettingKeys[requested] ?? requested).lowercased()
    if delegationSettingKeys.contains(key) { key = "delegation" }
    if toolCallingStrategyKeys.contains(key) { key = "tool.calling" }
    if toolProxyKeys.contains(key) { key = "tool.proxy" }
    if ["tools.auto", "tool.automatic"].contains(key) { key = "tool.auto" }
    if key == "ui.toolresultlines" { key = "ui.tools" }
    let configuration = MaiConfiguration()
    let themeKey = key.hasPrefix("ui.") ? String(key.dropFirst(3)) : key
    if let value = TerminalTheme.value(themeKey, in: configuration.ui) {
      return (themeKey, value, true)
    }
    var defaults = profile
    defaults.resetSettings()
    let special = [
      "tool.aproval": configuration.approvals.mode.rawValue,
      "debug": "false", "debugfile": "default", "airplane": "off", "awake": "off",
      "acp.timeout": "off",
      "acp.context": "agent", "acp.prompt": "agent",
      "http.transport": "auto",
      "limits.terminaltimeout": "0",
      "redact": configuration.redact.rawValue, "delegation": defaults.toolDelegation.rawValue,
      "effort": defaults.options.reasoningEffort ?? "auto", "ui.editor": "none",
      "ctx.compact": defaults.autocompact.isEnabled ? String(defaults.autocompact.tokens) : "off",
    ]
    if let value = special[key] { return (key, value, false) }
    let settings = limitSettings(defaults.limits) + recoverySettings(defaults)
      + toolSettings(defaults) + uiSettings(configuration.ui)
      + exportSettings(configuration.documentExport) + useSettings(configuration.use)
      + (try voiceSettings(configuration.voice))
    for setting in settings {
      guard let separator = setting.range(of: " = ") else { continue }
      let name = String(setting[..<separator.lowerBound])
      if name.lowercased() == key {
        return (name, String(setting[separator.upperBound...]), false)
      }
    }
    throw JSONRPCError.invalidParams("Unknown setting '\(argument)'. /set lists settings.")
  }

  /// Called only after the person answers the REPL's reset confirmation.
  static func resetSettings(
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    approvalHandler: TerminalApprovalHandler,
    catalogs: inout [MCPServerCatalog],
    terminal: TerminalWriter, remoteTerminalSettingsURL: URL? = nil
  ) async -> Bool {
    guard let original = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    let defaults = MaiConfiguration()
    var draft = original
    draft.voice = defaults.voice
    draft.ui = defaults.ui
    draft.documentExport = defaults.documentExport
    draft.use = defaults.use
    draft.airplane = defaults.airplane
    draft.awake = defaults.awake
    draft.redact = defaults.redact
    draft.approvals.mode = defaults.approvals.mode
    draft.remoteTerminalTimeoutSeconds = defaults.remoteTerminalTimeoutSeconds
    var profile = session.profile
    profile.resetSettings()
    // Do not create a configured agent on an install with no provider selected.
    if !profile.provider.rawValue.isEmpty {
      draft.upsertAgent(profile.agentDefinition)
    }
    let url = URL(fileURLWithPath: configurationPath)
    var resetProvider: (any ChatProvider)?
    do {
      if let index = draft.providers.firstIndex(where: {
        $0.id == profile.provider.rawValue && $0.kind == ACPConfiguredProviderFactory.providerKind
      }), draft.providers[index].timeout != nil
        || draft.providers[index].options["context"] != nil
        || draft.providers[index].options["prompt"] != nil
      {
        draft.providers[index].timeout = nil
        draft.providers[index].options["context"] = nil
        draft.providers[index].options["prompt"] = nil
        resetProvider = try await plugins.makeProvider(
          from: draft.providers[index], environment: ProcessInfo.processInfo.environment)
      }
      if let index = draft.providers.firstIndex(where: {
        $0.id == profile.provider.rawValue && $0.kind == .openAI
      }), draft.providers[index].options["httpTransport"] != nil {
        draft.providers[index].options["httpTransport"] = nil
        resetProvider = try await plugins.makeProvider(
          from: draft.providers[index], environment: ProcessInfo.processInfo.environment)
      }
      try draft.save(to: url)
      do {
        if let remoteTerminalSettingsURL {
          try ACPStateFiles.createDirectory(remoteTerminalSettingsURL.deletingLastPathComponent())
          try ACPStateFiles.write(0, to: remoteTerminalSettingsURL)
        }
        try await approvalHandler.resetSettings()
      } catch {
        try original.save(to: url)
        if let remoteTerminalSettingsURL { try? ACPStateFiles.write(original.remoteTerminalTimeoutSeconds, to: remoteTerminalSettingsURL) }
        throw error
      }
    } catch {
      await terminal.line("error: Could not reset settings: \(error.localizedDescription)", to: .standardError)
      return false
    }
    configuration = draft
    try? await AwakeController.shared.setEnabled(false)
    if let resetProvider {
      do { try await runtime.register(resetProvider, replacingExisting: true) }
      catch {
        await terminal.line("warning: Settings were saved but the provider could not reload: \(error.localizedDescription)", to: .standardError)
      }
    }
    session.profile = profile
    session.touch()
    if !profile.provider.rawValue.isEmpty {
      do {
        try await runtime.register(agent: profile.agentDefinition, replacingExisting: true)
      } catch {
        await terminal.line("warning: Settings were saved but the agent could not reload: \(error.localizedDescription)", to: .standardError)
      }
    }
    await runtime.configureDebugLog(nil)
    do { try await runtime.configureRedaction(draft.redact) }
    catch { await terminal.line("warning: \(error.localizedDescription)", to: .standardError) }
    await runtime.configureProjectInstructionDirectory(nil)
    await runtime.configurePlanning(draft.use.plan)
    session.redactor = await runtime.contentRedactor(sessionID: session.sessionID)
    await terminal.configureRedactor(session.redactor)
    await terminal.configureMarkdown(markdownRenderer(
      enabled: draft.ui.markdown, forced: false, environment: ProcessInfo.processInfo.environment))
    var internet = await runtime.internetAccessPolicy()
    internet.setAirplaneMode(draft.airplane)
    await runtime.configureInternetAccess(internet)
    if !internet.isOffline {
      for server in draft.mcpServers where server.enabled && !catalogs.contains(where: { $0.serverID == server.id }) {
        do {
          let source = try await plugins.makeMCPToolSource(
            kind: server.kind, configuration: server, environment: ProcessInfo.processInfo.environment)
          catalogs.append(try await runtime.register(mcp: source))
        } catch {
          await terminal.line("warning: MCP '\(server.id)' could not reconnect: \(error.localizedDescription)", to: .standardError)
        }
      }
    }
    await terminal.line("Reset all /set options to stock defaults. Voice is off; /voice on starts it with the defaults.")
    return true
  }

  static func currentSetSettings(
    profile: SessionProfile, configuration: MaiConfiguration?,
    runtime: AgentRuntime, approvalHandler: TerminalApprovalHandler
  ) async throws -> [String] {
    let voice = try voiceSettings(configuration?.voice ?? .init())
    return [
        "tool.approval = \(await approvalHandler.currentApprovalMode().rawValue)",
        "debug = \(await approvalHandler.isDebugEnabled() ? "true" : "false")",
        "debugfile = \(await approvalHandler.debugLogURL().path)",
        "airplane = \(await runtime.internetAccessPolicy().airplaneModeEnabled ? "on ✈" : "off")",
        "awake = \(await AwakeController.shared.isEnabled ? "on" : "off")",
        "redact = \((configuration?.redact ?? .off).rawValue)",
        "limits.terminalTimeout = \(configuration?.remoteTerminalTimeoutSeconds ?? 0)",
        "delegation = \(profile.toolDelegation.rawValue)",
        effortDescription(profile.options),
      ] + acpSettings(provider: profile.provider, configuration: configuration)
        + httpSettings(provider: profile.provider, configuration: configuration)
        + limitSettings(profile.limits) + recoverySettings(profile)
        + toolSettings(profile) + uiSettings(configuration?.ui ?? .init())
        + exportSettings(configuration?.documentExport ?? .init())
        + useSettings(configuration?.use ?? .init()) + voice
  }

  static func diagnosticConfiguration(
    session: REPLSession, configuration: MaiConfiguration?, runtime: AgentRuntime,
    providerBaseURLs: ProviderBaseURLStore, approvalHandler: TerminalApprovalHandler
  ) async throws -> JSONValue {
    let profile = session.profile
    let lines = try await currentSetSettings(
      profile: profile, configuration: configuration, runtime: runtime,
      approvalHandler: approvalHandler)
    let settings = Dictionary(uniqueKeysWithValues: lines.compactMap { line -> (String, JSONValue)? in
      guard let range = line.range(of: " = ") else { return nil }
      return (String(line[..<range.lowerBound]), .string(String(line[range.upperBound...])))
    })
    var providers: [JSONValue] = []
    for provider in configuration?.providers ?? [] {
      let url = providerBaseURLs.url(for: provider.id) ?? provider.baseURL
      providers.append(.object([
        "id": .string(provider.id), "kind": .string(provider.kind.rawValue),
        "baseURL": url.map { .string($0.absoluteString) } ?? .null,
        "timeout": provider.timeout.map(JSONValue.number) ?? .null,
        "httpTransport": .string(provider.options["httpTransport"]?.stringValue ?? "auto"),
        "resolvedHTTPTransport": .string((ProviderHTTPTransport(rawValue:
          provider.options["httpTransport"]?.stringValue?.lowercased() ?? "auto") ?? .automatic).resolved.rawValue),
        "headerNames": .array(Set(provider.headers.keys).union(provider.headerEnvironment.keys)
          .sorted().map(JSONValue.string)),
      ]))
    }
    var tasks: [String: JSONValue] = [:]
    for task in AgentTask.allCases {
      let id = configuration?.taskAgents[task]
      let agent = id.flatMap { selected in configuration?.agents.first { $0.id == selected } }
      tasks[task.rawValue] = .object([
        "agent": .string(id ?? profile.agentID),
        "provider": .string(agent?.provider.rawValue ?? profile.provider.rawValue),
        "model": .string(agent?.model ?? profile.model),
        "options": try DebugDiagnostics.value(agent?.options ?? profile.options),
      ])
    }
    return DebugDiagnostics.sanitize(.object([
      "platform": .string(ProcessInfo.processInfo.operatingSystemVersionString),
      "pmaiVersion": .string(version),
      "workingDirectory": .string(FileManager.default.currentDirectoryPath),
      "agent": .string(profile.agentID), "provider": .string(profile.provider.rawValue),
      "model": .string(profile.model), "stream": .bool(profile.stream),
      "options": try DebugDiagnostics.value(profile.options),
      "providers": .array(providers), "taskModels": .object(tasks),
      "settings": .object(settings),
    ]))
  }

  static func logDiagnosticConfiguration(
    session: REPLSession, configuration: MaiConfiguration?, runtime: AgentRuntime,
    services: REPLServices
  ) async {
    do {
      let value = try await diagnosticConfiguration(
        session: session, configuration: configuration, runtime: runtime,
        providerBaseURLs: services.providerBaseURLs, approvalHandler: services.approvalHandler)
      await runtime.recordDebugConfiguration(value)
    } catch {
      // Diagnostics must not interrupt a conversation.
    }
  }

  /// Lowercased `/set` keys mapped to their canonical spelling.
  static let limitSettingKeys = [
    "limits.maxtoolcalls": "limits.maxToolCalls",
    "limits.maxmodelturns": "limits.maxModelTurns",
    "limits.maxsubagents": "limits.maxSubagents",
    "limits.maxsubagentdepth": "limits.maxSubagentDepth",
    "limits.maxtotaltokens": "limits.maxTotalTokens",
    "limits.maxtokens": "limits.maxTotalTokens",
    "limits.maxseconds": "limits.maxSeconds",
    "limits.runtimeoutseconds": "limits.runTimeoutSeconds",
    "limits.maxtime": "limits.maxSeconds",
  ]

  /// Lowercased `/set` keys for retry and context-compaction policies.
  static let recoverySettingKeys = [
    "retry.attempts": "retry.attempts",
    "retry.count": "retry.attempts",
    "retries": "retry.attempts",
    "retry.delay": "retry.delay",
    "retry.delayseconds": "retry.delay",
    "ctx.compact": "ctx.compact",
    "ctx.recent": "ctx.recent",
    "ctx.window": "ctx.window",
  ]

  static let delegationSettingKeys: Set<String> = [
    "delegation", "tools.delegation", "tooldelegation", "subagents",
  ]

  static let toolCallingStrategyKeys: Set<String> = [
    "tool.calling", "tools.calling", "toolcalling", "toolcallingstrategy",
  ]

  static let toolProxyKeys: Set<String> = [
    "tool.proxy", "tools.proxy", "toolproxy", "usetoolproxy",
  ]

  static func listSettings(_ settings: [String], terminal: TerminalWriter) async {
    for setting in settings.sorted(by: { $0.lowercased() < $1.lowercased() }) {
      await terminal.line(setting)
    }
  }

  static func acpSettings(
    provider: ProviderID, configuration: MaiConfiguration?
  ) -> [String] {
    guard let configured = configuration?.providers.first(where: {
      $0.id == provider.rawValue && $0.kind == ACPConfiguredProviderFactory.providerKind
    }) else { return [] }
    return [
      "acp.timeout = \(configured.timeout.map { ModelUsageFormat.duration($0) } ?? "off")",
      "acp.context = \(configured.options["context"]?.stringValue ?? "agent")",
      "acp.prompt = \(configured.options["prompt"]?.stringValue ?? "agent")",
    ]
  }

  static func httpSettings(
    provider: ProviderID, configuration: MaiConfiguration?
  ) -> [String] {
    guard let configured = configuration?.providers.first(where: {
      $0.id == provider.rawValue && $0.kind == .openAI
    }) else { return [] }
    return ["http.transport = \(configured.options["httpTransport"]?.stringValue ?? "auto")"]
  }

  static func toolSettings(_ profile: SessionProfile) -> [String] {
    [
      "tool.calling = \(profile.toolCallingStrategy.rawValue)",
      "tool.proxy = \(toolProxySetting(profile))",
      "tool.auto = \(profile.toolPolicy.automatic)",
      "tool.systemone = \(profile.useSystemOne)",
    ]
  }

  /// Approval policy is saved for the current project unless scoped to this session.
  static func setToolApproval(
    parts: [String], approvalHandler: TerminalApprovalHandler,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("tool.approval = \(await approvalHandler.currentApprovalMode().rawValue)")
      let tools = await approvalHandler.yoloTools()
      if !tools.isEmpty {
        await terminal.line("Tool-specific yolo (saved for this project): \(tools.joined(separator: ", ")). /set tool.approval ask clears these approvals.")
      }
      return
    }
    guard (parts.count == 2 || (parts.count == 3 && parts[2].lowercased() == "session")),
      let mode = ToolApprovalMode(rawValue: parts[1].lowercased())
    else {
      await terminal.line("Usage: /set tool.approval <yolo|ask|smart> [session]")
      return
    }
    if parts.count == 3 {
      await approvalHandler.setApprovalMode(mode)
      await terminal.line("tool.approval = \(mode.rawValue) for this session (not saved\(mode == .yolo ? "; includes path approvals" : ""))")
      return
    }
    do {
      try await approvalHandler.saveApprovalMode(mode)
      await terminal.line("tool.approval = \(mode.rawValue) (saved for this project)")
    } catch {
      await terminal.line(
        "Could not save tool.approval = \(mode.rawValue): \(error.localizedDescription)",
        to: .standardError)
    }
  }

  /// Changes the inherited exposure default without erasing per-tool overrides.
  static func setToolProxy(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("tool.proxy = \(toolProxySetting(session.profile))")
      return
    }
    // on (or hybrid) keeps the common tools native and proxies the rest;
    // all proxies every inherited tool; explicit modes are preserved.
    let value: String
    switch parts.count == 2 ? parts[1].lowercased() : "" {
    case "all":
      session.profile.useToolProxy = true
      session.profile.proxyExposedTools = []
      value = "all"
    case "hybrid":
      session.profile.useToolProxy = true
      session.profile.proxyExposedTools = nil
      value = "on"
    case let word:
      guard let enabled = booleanSetting(word) else {
        await terminal.line("Usage: /set tool.proxy <on|hybrid|all|off>")
        return
      }
      session.profile.useToolProxy = enabled
      value = enabled ? "on" : "off"
    }
    session.touch()
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("Set tool.proxy = \(value) for this chat.")
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line("Set tool.proxy = \(value) for agent '\(session.profile.agentID)'.")
    }
  }

  /// `ctx.strategy` persists the agent's context mode.
  static func setContextMode(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("\(parts[0]) = \(session.profile.context.rawValue)")
      return
    }
    guard parts.count == 2, let mode = AgentContextMode(rawValue: parts[1].lowercased()) else {
      await terminal.line("Usage: /set \(parts[0]) <cache|size|smart|tools|adaptive>")
      return
    }
    session.profile.context = mode
    session.touch()
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("Set \(parts[0]) = \(mode.rawValue) for this chat.")
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line(
        "Set \(parts[0]) = \(mode.rawValue) for agent '\(session.profile.agentID)'.")
    }
  }

  static func setToolCallingStrategy(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("tool.calling = \(session.profile.toolCallingStrategy.rawValue)")
      return
    }
    let rawValue = parts[1].lowercased()
    let strategy =
      rawValue == "auto" ? ToolCallingStrategy.automatic : ToolCallingStrategy(rawValue: rawValue)
    guard parts.count == 2, let strategy else {
      await terminal.line(
        "Usage: /set tool.calling <off|automatic|native|text|xml|json>")
      return
    }
    session.profile.toolCallingStrategy = strategy
    session.touch()
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line("Set tool.calling = \(strategy.rawValue) for this chat.")
      return
    }
    draft.agents[index].toolCallingStrategy = strategy
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: session.profile.agentDefinition, replacingExisting: true)
      configuration = draft
      await terminal.line(
        "Set tool.calling = \(strategy.rawValue) for agent '\(session.profile.agentID)'.")
    } catch {
      await terminal.line(
        "Set tool.calling = \(strategy.rawValue) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  private static let limitSettingOrder = [
    "limits.maxToolCalls", "limits.maxModelTurns", "limits.maxSubagents",
    "limits.maxSubagentDepth", "limits.maxTotalTokens", "limits.maxSeconds",
    "limits.runTimeoutSeconds",
  ]

  static func limitSettings(_ limits: AgentRunLimits) -> [String] {
    limitSettingOrder.map { "\($0) = \(limitValue($0, in: limits))" }
  }

  static func limitValue(_ key: String, in limits: AgentRunLimits) -> String {
    switch key {
    case "limits.maxToolCalls": String(limits.maxToolCalls)
    case "limits.maxSubagents": String(limits.maxSubagents)
    case "limits.maxSubagentDepth": String(limits.maxSubagentDepth)
    case "limits.maxTotalTokens": limits.maxTotalTokens.map(String.init) ?? "off"
    case "limits.maxSeconds":
      limits.maxSeconds.map { ModelUsageFormat.duration(Double($0)) } ?? "off"
    case "limits.runTimeoutSeconds":
      limits.runTimeoutSeconds.map { ModelUsageFormat.duration(Double($0)) } ?? "default"
    default: String(limits.maxModelTurns)
    }
  }

  private static func recoverySettings(_ profile: SessionProfile) -> [String] {
    [
      "retry.attempts = \(profile.retry.attempts)",
      "retry.delay = \(durationSetting(profile.retry.delaySeconds))",
      "ctx.compact = \(autocompactSetting(profile.autocompact))",
      "ctx.recent = \(profile.autocompact.preserveRecentTokens.map(String.init) ?? "auto")",
      "ctx.window = \(profile.options.contextWindowTokens.map(String.init) ?? "auto")",
      "ctx.strategy = \(profile.context.rawValue)",
    ]
  }

  static func durationSetting(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? "\(Int(seconds))s" : "\(seconds)s"
  }

  /// `off`, `on` (the common tools native, the rest proxied) or `all`.
  static func toolProxySetting(_ profile: SessionProfile) -> String {
    guard profile.useToolProxy else { return "off" }
    return profile.proxyExposedTools?.isEmpty == true ? "all" : "on"
  }

  static func autocompactSetting(_ autocompact: AgentAutocompact) -> String {
    autocompact.isEnabled ? "\(autocompact.tokens) tokens" : "off"
  }

  /// `90`, `90s`, `10m`, `1h`, `1h30m`: a duration in seconds, or nil.
  static func parseDurationSeconds(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if let plain = Int(text) { return plain > 0 ? plain : nil }
    var total = 0
    var digits = ""
    var units = 0
    for character in text {
      if character.isNumber {
        digits.append(character)
        continue
      }
      guard let value = Int(digits) else { return nil }
      let multiplier: Int
      switch character {
      case "h": multiplier = 3600
      case "m": multiplier = 60
      case "s": multiplier = 1
      default: return nil
      }
      let part = value.multipliedReportingOverflow(by: multiplier)
      let sum = total.addingReportingOverflow(part.partialValue)
      guard !part.overflow, !sum.overflow else { return nil }
      total = sum.partialValue
      digits = ""
      units += 1
    }
    guard units > 0, digits.isEmpty, total > 0 else { return nil }
    return total
  }

  /// `120000`, `120k`, `1.5m`: a token count, or nil.
  static func parseTokenCount(_ raw: String) -> Int? {
    var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    text.removeAll { $0 == "_" || $0 == "," }
    if let plain = Int(text) { return plain >= 0 ? plain : nil }
    let multiplier: Double
    if text.hasSuffix("k") {
      multiplier = 1_000
    } else if text.hasSuffix("m") {
      multiplier = 1_000_000
    } else {
      return nil
    }
    guard let value = Double(text.dropLast()), value >= 0 else { return nil }
    return Int((value * multiplier).rounded())
  }

  /// Lets the current agent hand tool work to a child, or not. Turning
  /// delegation on with no subagent budget would silently do nothing, so it
  /// raises the budget too.
  static func setToolDelegation(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("delegation = \(session.profile.toolDelegation.rawValue)")
      return
    }
    let raw = parts[1].lowercased()
    let mode: AgentToolDelegation? =
      switch raw {
      case "off", "none", "self", "inline": .inline
      case "on", "child", "subagent", "subagents": .subagent
      default: nil
      }
    guard parts.count == 2, let mode else {
      await terminal.line("Usage: /set delegation <off|subagent>")
      return
    }
    session.profile.toolDelegation = mode
    var raised = false
    if mode == .subagent, session.profile.limits.maxSubagents < 1 {
      session.profile.limits.maxSubagents = 1
      raised = true
    }
    session.touch()
    var notes = [
      mode == .subagent
        ? "This agent keeps its tools and can also hand work to a child that has them; only the child's answer lands here."
        : "This agent runs every tool call itself."
    ]
    if raised { notes.append("Raised limits.maxSubagents to 1.") }
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line(
        (["Set delegation = \(mode.rawValue) for this chat."] + notes).joined(separator: " "))
      return
    }
    draft.agents[index].toolDelegation = mode
    draft.agents[index].limits = session.profile.limits
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: session.profile.agentDefinition, replacingExisting: true)
      configuration = draft
      await terminal.line(
        (["Set delegation = \(mode.rawValue) for agent '\(session.profile.agentID)'."] + notes)
          .joined(separator: " "))
    } catch {
      await terminal.line(
        "Set delegation = \(mode.rawValue) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  /// Changes one run limit for the current chat and, when the chat uses a
  /// configured agent, persists it into that agent's definition. The token
  /// and time caps take `off`; time takes `10m` and `1h` as well as seconds.
  static func setLimit(
    _ key: String,
    parts: [String],
    session: inout REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    var limits = session.profile.limits
    guard parts.count > 1 else {
      await terminal.line("\(key) = \(limitValue(key, in: limits))")
      return
    }
    let raw = parts.count == 2 ? parts[1].lowercased() : ""
    let cleared = ["off", "none", "unlimited", "0"].contains(raw)
    switch key {
    case "limits.runTimeoutSeconds":
      if raw == "default" {
        limits.runTimeoutSeconds = nil
      } else if let seconds = parseDurationSeconds(raw),
        seconds <= Int(MaiRunConfiguration.maximumTimeout)
      {
        limits.runTimeoutSeconds = seconds
      } else {
        await terminal.line(
          "Usage: /set limits.runTimeoutSeconds <default|N|Nm>  (1-600 seconds per shell call)")
        return
      }
    case "limits.maxSeconds":
      if cleared {
        limits.maxSeconds = nil
      } else if let seconds = parseDurationSeconds(raw) {
        limits.maxSeconds = seconds
      } else {
        await terminal.line(
          "Usage: /set limits.maxSeconds <off|N|Nm|Nh>  (wall-clock time per run)")
        return
      }
    case "limits.maxTotalTokens":
      if cleared {
        limits.maxTotalTokens = nil
      } else if let tokens = parseTokenCount(raw), tokens > 0 {
        limits.maxTotalTokens = tokens
      } else {
        await terminal.line("Usage: /set limits.maxTotalTokens <off|N|Nk>  (tokens per run)")
        return
      }
    default:
      guard let value = Int(raw), value >= 0 else {
        await terminal.line("Usage: /set \(key) N  (a non-negative integer)")
        return
      }
      switch key {
      case "limits.maxToolCalls": limits.maxToolCalls = value
      case "limits.maxSubagents": limits.maxSubagents = value
      case "limits.maxSubagentDepth": limits.maxSubagentDepth = value
      default: limits.maxModelTurns = max(1, value)
      }
    }
    session.profile.limits = limits
    session.touch()
    let applied = limitValue(key, in: limits)
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line("Set \(key) = \(applied) for this chat.")
      return
    }
    draft.agents[index].limits = limits
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line("Set \(key) = \(applied) for agent '\(session.profile.agentID)'.")
    } catch {
      await terminal.line(
        "Set \(key) = \(applied) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  /// `retry.attempts`, `retry.delay`, and `ctx.compact`: what a run does when
  /// a model call fails, and when it summarizes its own conversation. Saved
  /// on the chat's agent like the limits.
  static func setRecoverySetting(
    _ key: String,
    parts: [String],
    session: inout REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    var retry = session.profile.retry
    var autocompact = session.profile.autocompact
    var options = session.profile.options
    func current() -> String {
      switch key {
      case "retry.attempts": String(retry.attempts)
      case "retry.delay": durationSetting(retry.delaySeconds)
      case "ctx.recent": autocompact.preserveRecentTokens.map(String.init) ?? "auto"
      case "ctx.window": options.contextWindowTokens.map(String.init) ?? "auto"
      default: autocompactSetting(autocompact)
      }
    }
    guard parts.count > 1 else {
      await terminal.line("\(key) = \(current())")
      if key == "ctx.compact" {
        await terminal.line(autocompact.isEnabled
          ? "At this threshold, choose pruning, summarization, keeping context, or stopping."
          : "The context action prompt is disabled. /set ctx.compact 64k enables it; ctx.strategy size can still prune old reads independently.")
      }
      return
    }
    let raw = parts.count == 2 ? parts[1].lowercased() : ""
    switch key {
    case "ctx.window":
      if raw == "auto" {
        options.contextWindowTokens = nil
      } else if let tokens = parseTokenCount(raw), tokens > 0 {
        options.contextWindowTokens = tokens
      } else {
        await terminal.line(
          "Usage: /set ctx.window <auto|N|Nk>  (total model context, including its reply)")
        return
      }
    case "ctx.recent":
      if raw == "auto" {
        autocompact.preserveRecentTokens = nil
      } else if let tokens = parseTokenCount(raw), tokens >= 0 {
        autocompact.preserveRecentTokens = tokens
      } else {
        await terminal.line("Usage: /set ctx.recent <auto|N|Nk>  (recent tokens kept verbatim when summarizing)")
        return
      }
    case "retry.attempts":
      guard let value = Int(raw), value >= 0 else {
        await terminal.line("Usage: /set retry.attempts N  (0 fails on the first error)")
        return
      }
      retry.attempts = value
    case "retry.delay":
      if let seconds = Double(raw), seconds >= 0 {
        retry.delaySeconds = seconds
      } else if let seconds = parseDurationSeconds(raw) {
        retry.delaySeconds = Double(seconds)
      } else {
        await terminal.line("Usage: /set retry.delay SECONDS  (the wait before each retry)")
        return
      }
    default:
      if ["off", "none", "0"].contains(raw) {
        autocompact.tokens = 0
      } else if let tokens = parseTokenCount(raw), tokens > 0 {
        autocompact.tokens = tokens
      } else {
        await terminal.line(
          "Usage: /set ctx.compact <off|N|Nk>  (prompt to prune or summarize once the chat holds about N tokens)")
        return
      }
    }
    session.profile.retry = retry
    session.profile.autocompact = autocompact
    session.profile.options = options
    session.touch()
    var notes: [String] = []
    if key == "ctx.compact", autocompact.isEnabled {
      notes.append(
        "Before a model turn at about \(autocompact.tokens) tokens, choose pruning old tool output, summarizing older context, keeping context, or stopping. The newest exchange is kept verbatim."
      )
    }
    let applied = current()
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line(
        (["Set \(key) = \(applied) for this chat."] + notes).joined(separator: " "))
      return
    }
    draft.agents[index].retry = retry
    draft.agents[index].autocompact = autocompact
    draft.agents[index].options = options
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line(
        (["Set \(key) = \(applied) for agent '\(session.profile.agentID)'."] + notes)
          .joined(separator: " "))
    } catch {
      await terminal.line(
        "Set \(key) = \(applied) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  static func useSettings(_ use: ConfiguredUse) -> [String] {
    [
      "use.agentsmd = \(use.agentsmd.rawValue)",
      "use.plan = \(use.plan ? "on" : "off")",
    ]
  }

  /// `/set use.plan [on|off]`: shows or changes whether an agent that can
  /// start children is asked to open a multi-step request with a plan before
  /// its first `agent_start`.
  static func setPlanning(
    parts: [String],
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let enabled = configuration?.use.plan ?? true
    guard parts.count > 1 else {
      await terminal.line("use.plan = \(enabled ? "on" : "off")")
      return
    }
    guard parts.count == 2, let wanted = booleanSetting(parts[1]) else {
      await terminal.line("Usage: /set use.plan <on|off>")
      return
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.use.plan = wanted
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    await runtime.configurePlanning(wanted)
    await terminal.line(
      "Set use.plan = \(wanted ? "on" : "off"). "
        + (wanted
          ? "An agent with children opens a request of several steps with a numbered plan."
          : "Agents delegate without planning first."))
  }

  static func exportSettings(
    _ options: DocumentExportOptions
  ) -> [String] {
    [
      "export.tools = \(options.includeToolCalls ? "on" : "off")",
      "export.thinking = \(options.includeThinking ? "on" : "off")",
    ]
  }

  static func uiSettings(_ ui: ConfiguredTerminalUI) -> [String] {
    let keys = [
      "ui.mode", "ui.line", "ui.scroll", "ui.scrollbar", "ui.highlight", "ui.editor", "ui.markdown", "ui.tools", "ui.toolcalls", "ui.toolgroups",
      "ui.subagents", "ui.thinking", "ui.tableborders",
      "ui.broadcast",
      "ui.fgbold", "ui.fgitalic",
    ]
    return keys.map { "\($0) = \(uiSetting($0, in: ui))" }
  }

  static func uiSetting(_ key: String, in ui: ConfiguredTerminalUI) -> String {
    let value: String
    switch key.lowercased() {
    case "ui.mode": return ui.mode.rawValue
    case "ui.line": return ui.line.rawValue
    case "ui.scroll": return String(ui.scroll)
    case "ui.scrollbar": return String(ui.scrollbar)
    case "ui.highlight": value = ui.highlight
    // Unset is worth showing as what it resolves to, since that is the editor
    // that actually opens.
    case "ui.editor":
      return ui.editor.isEmpty ? "\(resolvedEditor()) (from the environment)" : ui.editor
    case "ui.markdown": return ui.markdown ? "on" : "off"
    case "ui.fgbold", "ui.fgitalic":
      return TerminalTheme.value(String(key.dropFirst(3)), in: ui) ?? "none"
    case "ui.tableborders": return ui.tableBorders ? "on" : "off"
    case "ui.tools": return ui.tools.description
    case "ui.toolcalls": return ui.toolCalls.description
    case "ui.toolgroups": return ui.toolGroups ? "on" : "off"
    case "ui.thinking": return ui.thinking.rawValue
    case "ui.subagents": return ui.subagentOutput.rawValue
    case "ui.broadcast": return ui.broadcast ? "on" : "off"
    default: return "-"
    }
    return value.isEmpty ? "none" : value
  }

  static func booleanSetting(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "1", "true", "yes", "on": true
    case "0", "false", "no", "off": false
    default: nil
    }
  }
}
