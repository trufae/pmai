import Foundation
import MaiCore
import MaiACP

extension MaiCLI {
  static func handleToolsCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 3, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? "list"
    if fields.count == 1, action == "on" || action == "off" {
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        draft.toolsEnabled = action == "on"
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await runtime.configureToolsEnabled(draft.toolsEnabled)
        await terminal.line("All tools globally: \(action). Individual tool settings are preserved; calls already executing may finish.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    if configuration?.providers.first(where: { $0.id == session.profile.provider.rawValue })?.kind == "acp" {
      await terminal.line("ACP: these are pmai tools. Local agents access them through MCP; native agent tools run in the agent and appear in chat as activity. Remote agents use their host's tools.")
    }
    let groups: [ToolGroupDefinition]
    do {
      groups = try await toolGroupCatalog(
        runtime: runtime,
        plugins: plugins,
        configuration: configuration)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }

    let tools = await runtime.availableTools()
    let usage = await runtime.toolUsageSnapshot()
    let internetAccess = await runtime.internetAccessPolicy()
    var modesByName = internetAccess.restricting(
      session.profile.agentDefinition.toolModes(in: groups, usage: usage), tools: tools, groups: groups)
    let globallyEnabled = await runtime.toolsAreEnabled()
    if !globallyEnabled { modesByName = modesByName.mapValues { _ in .disabled } }
    let names = Set(tools.map(\.name)).union(AgentRuntime.agentToolNames)
    if action == "list" || action == "full" || fields.isEmpty {
      let full = action == "full"
      if full {
        await terminal.line("All tools globally: \(globallyEnabled ? "on" : "off"). /tools on|off changes the global switch.")
        await terminal.line("Tool proxy default: \(toolProxySetting(session.profile)); automatic exposure: \(session.profile.toolPolicy.automatic ? "on" : "off"). Per-tool overrides take precedence.")
      }
      await terminal.table(toolGroupsTable(groups, modes: modesByName, usage: usage))
      if full {
        for group in groups {
          await terminal.line()
          await terminal.line(await terminal.paintHeading(group.catalogID))
          await terminal.table(toolDetailsTable(group, modes: modesByName, usage: usage))
        }
      }
      await terminal.line("/tools show GROUP lists a group's tools and details; /tools full lists all groups with their tools.")
      return
    }

    guard fields.count >= 2,
      let selection = AgentToolSelection.resolve(fields[1], groups: groups, names: names)
    else {
      if fields.count >= 2 { await terminal.line("Unknown or ambiguous tool/group '\(fields[1])'. Use /tools or a qualified name.") }
      await terminal.line(toolHelp)
      return
    }
    if ["enable", "on", "disable", "off", "direct", "proxy", "hide", "inherit"].contains(action) {
      var definition = session.profile.agentDefinition
      switch selection {
      case .tool(let name):
        if action == "enable" || action == "on" {
          definition.toolNames.insert(name)
          definition.setToolMode(nil, for: name)
          if definition.toolMode(for: name, in: groups) == .disabled {
            definition.setToolMode(AgentToolPolicy.defaultMode(
              for: name, useToolProxy: definition.useToolProxy,
              exposedTools: definition.proxyExposedTools), for: name)
          }
        } else {
          let mode: AgentToolMode? = action == "inherit" ? nil
            : action == "direct" ? .direct : action == "proxy" ? .proxy
            : action == "hide" ? .hidden : .disabled
          definition.setToolMode(mode, for: name)
        }
      case .group(let group):
        if action == "enable" || action == "on" {
          definition.toolGroupNames.insert(group.sourceID == "mcp" ? group.catalogID : group.id)
          definition.toolNames.formUnion(group.toolNames)
          definition.setToolGroupMode(nil, for: group)
          if group.sourceID == "mcp", definition.toolPolicy.groups["mcp"] == .disabled {
            definition.setToolGroupMode(definition.useToolProxy ? .proxy : .direct, for: group)
          }
        } else {
          let mode: AgentToolMode? = action == "inherit" ? nil
            : action == "direct" ? .direct : action == "proxy" ? .proxy
            : action == "hide" ? .hidden : .disabled
          definition.setToolGroupMode(mode, for: group)
        }
      }
      session.profile = SessionProfile(definition: definition)
      session.touch()
      if await persistAgentProfile(
        session: session, configuration: &configuration, configurationPath: configurationPath,
        runtime: runtime, terminal: terminal)
      {
        await terminal.line("Tool selection '\(fields[1])': \(action) for agent \(session.profile.agentID).")
      }
      return
    }
    if case .tool(let name) = selection {
      guard action == "show", let tool = (tools + AgentProcessTools.definitions(
        offering: [], delegating: true, planFirst: configuration?.use.plan ?? true))
        .first(where: { $0.name == name }) else {
        await terminal.line(toolHelp)
        return
      }
      let mode = modesByName[name] ?? .disabled
      let boldName = await terminal.paint(name, bold: true)
      let badge = await terminal.toolModeBadge(mode)
      await terminal.line("\(ToolIcon.emoji(for: name)) \(boldName) \(badge) \(usage.counts[name, default: 0]) calls")
      for line in ToolGroupHelp.lines(for: tool, paint: { text, style in
        style == .tool ? boldName : text
      }) { await terminal.line(line) }
      return
    }
    guard case .group(let group) = selection else { return }
    switch action {
    case "show":
      let count = group.toolNames.count
      let badge = await terminal.toolGroupBadge(
        AgentToolModeSummary(names: group.toolNames, modes: modesByName))
      let ui = configuration?.ui ?? .init()
      let heading = TerminalLineEditor.foregroundColorCode(ui.infoForeground)
      let tool = TerminalLineEditor.foregroundColorCode(ui.toolCallForeground)
      let warning = TerminalLineEditor.foregroundColorCode(ui.warningForeground)
      let error = TerminalLineEditor.foregroundColorCode(ui.errorForeground)
      let colors = await terminal.paintsOutput
      let retainsThemeStyles = await terminal.retainsThemeStyles
      func paint(_ text: String, _ code: String?, role: TerminalThemeStyle? = nil) -> String {
        guard colors else { return text }
        let style = code.map { "\u{1B}[\($0)m" } ?? ""
        let annotation = retainsThemeStyles ? role?.marker ?? "" : ""
        return style + annotation + text + "\u{1B}[0m"
      }
      await terminal.line(
        paint(group.displayName, heading.map { "1;" + $0 } ?? "1", role: .infoForeground) + " "
          + paint("(\(group.catalogID))", "2")
          + ": \(count) tool\(count == 1 ? "" : "s"), \(usage.count(for: group)) calls, "
          + badge
          + " for agent \(session.profile.agentID)")
      // The agent family is synthesized per run rather than registered, so
      // its help comes from the definitions the model would see.
      var tools = await runtime.availableTools()
      if group.id == AgentRuntime.agentToolGroup.id {
        tools += AgentProcessTools.definitions(
          offering: [], delegating: true, planFirst: configuration?.use.plan ?? true)
      }
      for name in group.toolNames.sorted() {
        let mode = modesByName[name] ?? .disabled
        let boldName = await terminal.paint(name, bold: true)
        let badge = await terminal.toolModeBadge(mode)
        await terminal.line("  \(ToolIcon.emoji(for: name)) \(boldName) \(badge) \(usage.counts[name, default: 0]) calls")
      }
      let helpLines = ToolGroupHelp.lines(for: group, tools: tools) { text, style in
        switch style {
        case .group: return paint(text, heading, role: .infoForeground)
        case .tool: return paint(text, heading.map { "1;" + $0 } ?? "1", role: .infoForeground)
        case .trait: return paint(text, warning, role: .warningForeground)
        case .description, .parameterDetail: return text
        case .parameter: return paint(text, tool, role: .toolCallForeground)
        case .parameterType, .note: return paint(text, "2")
        case .missing: return paint(text, error, role: .errorForeground)
        }
      }
      for line in helpLines {
        await terminal.line(line)
      }
      guard !group.options.isEmpty else { return }
      let options = configuredOptions(for: group, configuration: configuration)
      await terminal.line("")
      await terminal.line(
        paint("Settings", heading.map { "1;" + $0 } ?? "1", role: .infoForeground)
          + paint(", changed with /tools set \(group.id) OPTION VALUE:", "2"))
      for option in group.options {
        let value = options[option.id] ?? option.defaultValue
        var line =
          "  " + paint(option.id, tool, role: .toolCallForeground) + " = "
          + paint(displayedOption(value, kind: option.kind), "1")
          + "  " + paint("\(option.label).", "2")
        if let help = option.help?.trimmingCharacters(in: .whitespacesAndNewlines), !help.isEmpty {
          line += " " + paint(help, "2")
        }
        await terminal.line(line)
      }
    case "set", "config":
      guard fields.count == 4,
        let option = group.options.first(where: { $0.id == fields[2] }),
        let value = parseToolOption(fields[3], definition: option)
      else {
        await terminal.line("Usage: /tools set GROUP OPTION VALUE")
        return
      }
      await reconfigureToolGroup(
        group,
        option: option.id,
        value: value,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    case "unset":
      guard fields.count == 3,
        group.options.contains(where: { $0.id == fields[2] })
      else {
        await terminal.line("Usage: /tools unset GROUP OPTION")
        return
      }
      await reconfigureToolGroup(
        group,
        option: fields[2],
        value: nil,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    default:
      await terminal.line(toolHelp)
    }
  }

  static func toolGroupCatalog(
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?
  ) async throws -> [ToolGroupDefinition] {
    var groups: [ToolGroupDefinition] = []
    for source in configuration?.toolSources.filter(\.enabled) ?? [] {
      groups.append(
        contentsOf: try await plugins.toolGroups(
          kind: source.kind,
          context: source.context(environment: ProcessInfo.processInfo.environment)))
    }
    await runtime.configureToolGroups(groups)
    return await runtime.availableToolGroups()
  }

  static func resolveToolGroup(
    _ selector: String,
    in groups: [ToolGroupDefinition]
  ) -> ToolGroupDefinition? {
    AgentToolSelection.group(named: selector, in: groups)
  }

  private static func isToolGroupEnabled(
    _ group: ToolGroupDefinition,
    profile: SessionProfile
  ) -> Bool {
    group.toolNames.contains {
      profile.agentDefinition.toolMode(for: $0, in: [group]) != .disabled
    }
  }

  private static func configuredOptions(
    for group: ToolGroupDefinition,
    configuration: MaiConfiguration?
  ) -> [String: JSONValue] {
    let source = configuration?.toolSources.first { $0.id == group.sourceID }
    return Dictionary(
      uniqueKeysWithValues: group.options.compactMap { option in
        source?.options[option.id].map { (option.id, $0) }
          ?? option.defaultValue.map { (option.id, $0) }
      })
  }

  private static func displayedOption(
    _ value: JSONValue?,
    kind: ToolGroupOptionKind
  ) -> String {
    guard let value else { return "-" }
    if kind == .secret { return value.stringValue?.isEmpty == false ? "(configured)" : "-" }
    if let string = value.stringValue { return string }
    if let integer = value.intValue { return String(integer) }
    if let number = value.numberValue { return String(number) }
    if let boolean = value.boolValue { return String(boolean) }
    return value.compactJSONString
  }

  private static func parseToolOption(
    _ rawValue: String,
    definition: ToolGroupOptionDefinition
  ) -> JSONValue? {
    switch definition.kind {
    case .text, .secret:
      return .string(rawValue)
    case .boolean:
      return booleanSetting(rawValue).map(JSONValue.bool)
    case .number:
      return Double(rawValue).map(JSONValue.number)
    case .choice:
      guard definition.choices.contains(rawValue) else { return nil }
      return .string(rawValue)
    }
  }

  private static func reconfigureToolGroup(
    _ group: ToolGroupDefinition,
    option: String,
    value: JSONValue?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let sourceIndex = draft.toolSources.firstIndex(where: { $0.id == group.sourceID })
    else {
      await terminal.line("This runtime-only group has no persistent settings.")
      return
    }
    if let value {
      draft.toolSources[sourceIndex].options[option] = value
    } else {
      draft.toolSources[sourceIndex].options.removeValue(forKey: option)
    }
    let source = draft.toolSources[sourceIndex]
    do {
      let context = source.context(environment: ProcessInfo.processInfo.environment)
      let tools = try await plugins.makeTools(kind: source.kind, context: context)
      let groups = try await plugins.toolGroups(kind: source.kind, context: context)
      let replacement = groups.first(where: { $0.id == group.id })
      for index in draft.agents.indices
      where draft.agents[index].toolGroupNames.contains(group.id)
        || group.toolNames.isSubset(of: draft.agents[index].toolNames)
      {
        draft.agents[index].toolGroupNames.insert(group.id)
        draft.agents[index].toolNames.subtract(group.toolNames)
        if let replacement {
          draft.agents[index].toolNames.formUnion(replacement.toolNames)
        }
      }
      if isToolGroupEnabled(group, profile: session.profile),
        let replacement
      {
        session.profile.toolGroupNames.insert(group.id)
        session.profile.toolNames.subtract(group.toolNames)
        session.profile.toolNames.formUnion(replacement.toolNames)
      }
      let definition = session.profile.agentDefinition
      if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
        draft.agents[index] = definition
      } else {
        draft.agents.append(definition)
      }
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      for tool in tools {
        try await runtime.register(tool: tool, replacingExisting: true)
      }
      for agent in draft.agents {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      configuration = draft
      _ = try await toolGroupCatalog(runtime: runtime, plugins: plugins, configuration: draft)
      await terminal.line("Saved \(group.id).\(option).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
