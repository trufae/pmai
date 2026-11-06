import Foundation
import MaiCore
import MaiACP
import MaiStandardTools

extension MaiCLI {
  private static func listAgentDefinitions(
    session: REPLSession,
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    let agents: [AgentDefinition]
    if let configured = configuration?.agents {
      agents = configured
    } else {
      agents = await runtime.availableAgents()
    }
    guard !agents.isEmpty else {
      await terminal.line("No configured agents.")
      return
    }
    let tasks = AgentTask.allCases.sorted { $0.rawValue < $1.rawValue }
    let acpProviders = Set(configuration?.providers.filter {
      $0.kind == ACPConfiguredProviderFactory.providerKind
    }.map(\.id) ?? [])
    func assignments(_ id: String) -> [AgentTask] {
      tasks.filter { configuration?.taskAgents[$0] == id }
    }
    // Task assignments take precedence, including when a task uses ACP.
    func group(_ agent: AgentDefinition) -> Int {
      if !assignments(agent.id).isEmpty { return 2 }
      let provider = agent.id == session.profile.agentID ? session.profile.provider : agent.provider
      return acpProviders.contains(provider.rawValue) ? 0 : 1
    }
    let groups: [(String, TerminalThemeStyle)] = [
      ("ACP agents", .toolCallForeground),
      ("Local agents (pmai)", .infoForeground),
      ("Task agents", .promptForeground),
    ]
    var lines: [String] = []
    for (index, (title, color)) in groups.enumerated() {
      let members = agents.filter { group($0) == index }.sorted {
        let lhs = $0.id.lowercased(), rhs = $1.id.lowercased()
        return lhs == rhs ? $0.id < $1.id : lhs < rhs
      }
      guard !members.isEmpty else { continue }
      if !lines.isEmpty { lines.append("") }
      lines.append(await terminal.paint(title + ":", role: color, bold: true))
      for agent in members {
        let isCurrent = agent.id == session.profile.agentID
        let displayed = isCurrent ? session.profile.agentDefinition : agent
        let roles = assignments(agent.id)
        let marker = isCurrent ? "*" : (displayed.isEnabled ? " " : "-")
        let name = await terminal.paint(
          "\(marker) \(displayed.id)",
          role: !displayed.isEnabled ? .warningForeground : isCurrent ? .successForeground : color,
          bold: true)
        let purpose = !displayed.description.isEmpty ? displayed.description
          : roles.isEmpty ? displayed.displayName : roles.map(\.description).joined(separator: " ")
        lines.append("\(name) — \(purpose)")
        let provider = configuration?.providers.first { $0.id == displayed.provider.rawValue }
        let model = displayed.model.isEmpty ? provider?.defaultModel ?? "default" : displayed.model
        var details = "\(displayed.provider)::\(model)"
        if displayed.displayName != displayed.id { details += " · \(displayed.displayName)" }
        if !roles.isEmpty { details += " · tasks: \(roles.map(\.rawValue).joined(separator: ", "))" }
        if acpProviders.contains(displayed.provider.rawValue), index == 2 { details += " · ACP" }
        if displayed.toolDelegation.delegatesTools { details += " · delegating" }
        if isCurrent { details += " · current" }
        if !displayed.isEnabled {
          details += await terminal.paint(" · disabled", role: .warningForeground)
        }
        lines.append("    \(details)")
      }
    }
    lines.append("")
    lines.append("/agents describe ID TEXT sets its purpose; /agents show ID shows full settings.")
    await terminal.line(lines.joined(separator: "\n"))
  }

  private static func setAgentEnabled(
    _ id: String,
    enabled: Bool,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == id })
    else {
      await terminal.line("Unknown agent '\(id)', or no writable configuration is active.")
      return
    }
    guard enabled || draft.agents[index].id != session.profile.agentID else {
      await terminal.line(
        "Agent '\(id)' is the one this chat uses. Switch with /agent use ID before disabling it.")
      return
    }
    draft.agents[index].isEnabled = enabled
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: draft.agents[index], replacingExisting: true)
      configuration = draft
      await terminal.line("Agent '\(id)' \(enabled ? "enabled" : "disabled").")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func describeAgent(
    _ id: String,
    text: String?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == id })
    else {
      await terminal.line("Unknown agent '\(id)', or no writable configuration is active.")
      return
    }
    guard let text else {
      let existing = draft.agents[index].description
      await terminal.line(existing.isEmpty ? "Agent '\(id)' has no description." : existing)
      return
    }
    draft.agents[index].description = text.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: draft.agents[index], replacingExisting: true)
      if session.profile.agentID == id {
        session.profile.description = draft.agents[index].description
        session.touch()
      }
      configuration = draft
      await terminal.line("Described agent '\(id)'.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/agent acp` registers an external ACP agent as a provider-backed agent,
  /// so it is selectable and spawnable like any other. `list` shows the builtin
  /// catalog and what is installed; `add NAME [COMMAND ARGS...]` persists one,
  /// defaulting the command from the catalog when only a known name is given.
  private static func handleAgentACPCommand(
    _ fields: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let sub = fields.first?.lowercased() ?? "list"
    switch sub {
    case "list", "":
      for agent in ACPCatalog.agents {
        let mark = agent.isInstalled ? "\u{2705}" : "\u{274C}"
        let configured = configuration?.providers.contains { $0.id == agent.id } == true
        await terminal.line(
          "\(mark) \(agent.id) — \(agent.summary)\(configured ? " [configured]" : "")")
      }
      await terminal.line(
        "Add one with /agent acp add NAME [COMMAND ARG ...]; a known name needs no command.")

    case "add":
      let rest = Array(fields.dropFirst())
      guard let name = rest.first else {
        await terminal.line("Usage: /agent acp add NAME [COMMAND ARG ...]")
        return
      }
      let provider: ConfiguredProvider
      if rest.count >= 2 {
        var options: [String: JSONValue] = ["command": .string(rest[1])]
        let args = Array(rest.dropFirst(2))
        if !args.isEmpty { options["args"] = .array(args.map(JSONValue.string)) }
        provider = ConfiguredProvider(
          id: name, kind: ACPConfiguredProviderFactory.providerKind, displayName: name,
          options: options)
      } else if let catalog = ACPCatalog.agent(name) {
        provider = catalog.configuredProvider()
        if !catalog.isInstalled, let install = catalog.install {
          await terminal.line("note: '\(name)' is not installed. Install it with: \(install)")
        }
      } else {
        await terminal.line(
          "Unknown ACP agent '\(name)'. Give a command, or use a catalog name (/agent acp list).")
        return
      }
      await registerACPAgent(
        provider,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    default:
      await terminal.line("Usage: /agent acp [list|add NAME [COMMAND ARG ...]]")
    }
  }

  /// Persists an ACP provider and a same-named agent, registers both live, and
  /// selects the agent for the current chat — the same shape `/agent add` uses.
  private static func registerACPAgent(
    _ provider: ConfiguredProvider,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    if let index = draft.providers.firstIndex(where: { $0.id == provider.id }) {
      draft.providers[index] = provider
    } else {
      draft.providers.append(provider)
    }
    let definition = AgentDefinition(
      id: provider.id,
      displayName: provider.displayName ?? provider.id,
      description: ACPCatalog.agent(provider.id)?.summary ?? "External ACP agent.",
      instructions: "",
      provider: ProviderID(provider.id),
      model: provider.id)
    if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
      draft.agents[index] = definition
    } else {
      draft.agents.append(definition)
    }
    do {
      let built = try await plugins.makeProvider(
        from: provider, environment: ProcessInfo.processInfo.environment)
      try await runtime.register(built, replacingExisting: true)
      try await runtime.register(agent: definition, replacingExisting: true)
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      session.reset(profile: SessionProfile(definition: definition))
      await terminal.line(
        "ACP agent '\(provider.id)' registered and selected for this chat. It runs like any other agent."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Saved definitions: /agent and /agents use the same handler.
  static func handleAgentCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let words = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    let action = words.first?.lowercased() ?? ""

    if action == "acp" {
      let fields = argument.split(maxSplits: 5, whereSeparator: \Character.isWhitespace).map(
        String.init)
      await handleAgentACPCommand(
        Array(fields.dropFirst()),
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }

    switch action {
    case "", "list":
      guard words.count <= 1 else {
        await terminal.line("Usage: /agents [list]")
        return
      }
      await listAgentDefinitions(
        session: session, runtime: runtime, configuration: configuration,
        terminal: terminal)

    case "enable", "disable":
      guard words.count == 2 else {
        await terminal.line("Usage: /agents \(action) ID")
        return
      }
      await setAgentEnabled(
        words[1],
        enabled: action == "enable",
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "describe":
      let fields = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
        String.init)
      guard fields.count >= 2 else {
        await terminal.line("Usage: /agents describe ID [TEXT]")
        return
      }
      await describeAgent(
        words[1],
        text: fields.count > 2 ? fields[2] : nil,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "default":
      guard words.count == 2, var draft = configuration, let configurationPath,
        let agent = draft.agents.first(where: { $0.id == words[1] }), agent.isEnabled
      else {
        await terminal.line("Usage: /agent default ID (an enabled saved agent)")
        return
      }
      draft.defaultAgent = words[1]
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line("Default agent: \(words[1]) (saved for new chats and runs)")
      } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
    case "effort":
      guard words.count == 3, let effort = ReasoningEffort(name: words[2]) else {
        await terminal.line(
          "Usage: /agent effort ID LEVEL (off, minimal, low, medium, high, max, auto)")
        return
      }
      _ = await updateAgent(
        words[1], session: &session, runtime: runtime,
        configuration: &configuration, configurationPath: configurationPath, terminal: terminal
      ) { definition, _ in
        definition.options.reasoningEffort = effort.rawValue
        return nil
      }
    case "add", "new", "create":
      if words.count == 2 {
        guard configuration?.agents.contains(where: { $0.id == words[1] }) != true else {
          await terminal.line("Agent '\(words[1])' already exists.")
          return
        }
        var definition = session.profile.agentDefinition
        definition.id = words[1]
        definition.displayName = words[1]
        definition.systemPrompt = nil
        if await persistAgentDefinition(
          definition, configuration: &configuration,
          configurationPath: configurationPath, runtime: runtime, terminal: terminal)
        {
          await terminal.line(
            "Added agent '\(words[1])'. /agent model, provider, prompt, effort, and tools edit it; /agent default selects it for new chats."
          )
        }
        return
      }
      await addAgent(
        Array(words.dropFirst()),
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "show":
      await showAgent(
        words.count > 1 ? words[1] : session.profile.agentID,
        session: session,
        configuration: configuration,
        providerBaseURLs: providerBaseURLs.snapshot(),
        terminal: terminal)

    case "tools":
      guard words.count == 3 else {
        await terminal.line(
          "Usage: /agent tools ID GROUPS   (a,b,c replaces; +a,-b adjusts; - clears)")
        return
      }
      guard
        let selection = await resolveToolGroupSpec(
          words[2], runtime: runtime, plugins: plugins, configuration: configuration,
          terminal: terminal)
      else { return }
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, _ in
        selection.apply(to: &definition)
        return nil
      }
      if let saved {
        let groups = saved.toolGroupNames.sorted()
        await terminal.line(
          "Agent '\(saved.id)' tool groups: \(groups.isEmpty ? "none" : groups.joined(separator: ", ")) (\(saved.toolNames.count) tools)."
        )
      }

    case "model":
      guard words.count == 3 else {
        await terminal.line("Usage: /agent model ID MODEL   (- keeps the provider's default)")
        return
      }
      let model = words[2] == "-" ? "" : words[2]
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, draft in
        do {
          if model.isEmpty {
            definition.model = ""
          } else {
            let selected = try draft.modelSelection(model, currentProvider: definition.provider)
            definition.provider = selected.provider
            definition.model = selected.model
          }
          return nil
        } catch { return error.localizedDescription }
      }
      if let saved {
        await terminal.line(
          "Agent '\(saved.id)' model: \(saved.model.isEmpty ? "-" : saved.model).")
      }

    case "provider":
      guard words.count == 3 else {
        await terminal.line("Usage: /agent provider ID PROVIDER")
        return
      }
      let providerID = ProviderID(words[2])
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, draft in
        guard draft.providers.contains(where: { $0.id == providerID.rawValue }) else {
          return
            "Unknown provider '\(providerID)'. /providers lists them; /agent add NAME MODEL GROUPS PROMPT PROVIDER BASE_URL registers a new endpoint."
        }
        definition.provider = providerID
        if let defaultModel = draft.providers.first(where: { $0.id == providerID.rawValue })?
          .defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !defaultModel.isEmpty
        {
          definition.model = defaultModel
        }
        return nil
      }
      if let saved { await terminal.line("Agent '\(saved.id)' provider: \(saved.provider).") }

    case "prompt":
      guard words.count == 3 else {
        await terminal.line("Usage: /agent prompt ID PROMPT")
        return
      }
      let requested = words[2]
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, draft in
        guard let name = resolvedSystemPromptName(requested, configuration: draft),
          let text = draft.systemPrompt(named: name)?.text
        else {
          return
            "Unknown system prompt '\(requested)'. /prompts lists them; /prompt add NAME TEXT creates one."
        }
        definition.systemPrompt = name
        definition.instructions = text
        return nil
      }
      if let saved {
        await terminal.line(
          "Agent '\(saved.id)' uses system prompt '\(saved.systemPrompt ?? "-")'.")
      }

    case "del":
      guard words.count == 2 else {
        await terminal.line("Usage: /agent del ID")
        return
      }
      await removeAgent(
        words[1],
        session: session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "use":
      guard words.count == 2 else {
        await terminal.line("Usage: /agent use ID")
        return
      }
      await selectAgent(
        words[1], session: &session, configuration: configuration, terminal: terminal)

    default:
      await selectAgent(
        words[0], session: &session, configuration: configuration, terminal: terminal)
    }
  }

  /// Planning and implementation share their context in the same chat.
  /// Other switches retain their existing fresh-conversation behavior.
  private static func selectAgent(
    _ id: String,
    session: inout REPLSession,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    guard let definition = configuration?.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. Use /agents.")
      return
    }
    if session.profile.agentID == "plan" || id == "plan" {
      do {
        try applyDefinition(definition, to: &session)
        await terminal.line("Agent: \(id). Conversation preserved for planning and implementation.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    session.reset(profile: SessionProfile(definition: definition))
    await terminal.line(
      "Agent: \(id). It is now the primary agent for chat '\(session.title)'; conversation cleared."
    )
  }

  /// `/agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]`: one line
  /// saves a definition out of things that already exist — a provider, a
  /// named system prompt, tool groups — and a base URL registers a new
  /// OpenAI-compatible provider on the way. Saving does not switch the chat.
  private static func addAgent(
    _ words: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let usage = """
      Usage: /agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]
        MODEL     a model name, or - for the provider's default
        GROUPS    tool groups as a,b,c (see /tools), or - for none
        PROMPT    a named system prompt (see /prompts; /prompt add NAME TEXT creates one)
        PROVIDER  defaults to this chat's provider; with BASE_URL a new OpenAI-compatible one
      """
    guard (4...6).contains(words.count) else {
      await terminal.line(usage)
      return
    }
    guard let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    var draft = configuration ?? MaiConfiguration()
    let name = words[0]
    var model = words[1] == "-" ? "" : words[1]
    var providerID = words.count >= 5 ? ProviderID(words[4]) : session.profile.provider
    if !model.isEmpty {
      do {
        let selection = try ModelSelection(model, currentProvider: providerID)
        providerID = selection.provider
        model = selection.model
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
        return
      }
    }

    var providerChanged = false
    if words.count == 6 {
      guard let baseURL = URL(string: words[5]),
        ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
        baseURL.host != nil
      else {
        await terminal.line("BASE_URL must be an http(s) URL.\n\(usage)")
        return
      }
      if let index = draft.providers.firstIndex(where: { $0.id == providerID.rawValue }) {
        if let configuredURL = draft.providers[index].baseURL, configuredURL != baseURL {
          await terminal.line(
            "Provider '\(providerID)' already uses \(configuredURL.absoluteString). Use a unique provider ID for \(baseURL.absoluteString).",
            to: .standardError)
          return
        }
        if draft.providers[index].baseURL == nil {
          draft.providers[index].baseURL = baseURL
          providerChanged = true
        }
      } else {
        draft.providers.append(
          ConfiguredProvider(
            id: providerID.rawValue,
            kind: .openAICompatible,
            baseURL: baseURL,
            apiKeyEnvironment: apiKeyEnvironmentName(for: providerID.rawValue)))
        providerChanged = true
      }
    } else if !draft.providers.contains(where: { $0.id == providerID.rawValue }) {
      await terminal.line(
        "Unknown provider '\(providerID)'. /providers lists the configured ones; add BASE_URL to register a new OpenAI-compatible endpoint."
      )
      return
    }

    guard let promptName = resolvedSystemPromptName(words[3], configuration: draft),
      let instructions = draft.systemPrompt(named: promptName)?.text
    else {
      let known = draft.systemPrompts.map(\.name)
      await terminal.line(
        "Unknown system prompt '\(words[3])'. Create it first: /prompt add \(words[3]) TEXT, or /prompt edit \(words[3])."
          + (known.isEmpty ? "" : " Known: \(known.joined(separator: ", ")).")
      )
      return
    }
    guard
      let selection = await resolveToolGroupSpec(
        words[2], runtime: runtime, plugins: plugins, configuration: draft, terminal: terminal)
    else { return }

    let isNew = !draft.agents.contains { $0.id == name }
    var definition =
      draft.agents.first { $0.id == name }
      ?? AgentDefinition(id: name, instructions: instructions, provider: providerID, model: model)
    definition.provider = providerID
    definition.model = model
    definition.systemPrompt = promptName
    definition.instructions = instructions
    definition.toolGroupNames = []
    definition.toolNames = []
    selection.apply(to: &definition)
    var changed = draft.upsertAgent(definition)
    changed += MaiAgentPresets.install(in: &draft, using: definition)

    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      if providerChanged,
        let provider = draft.providers.first(where: { $0.id == providerID.rawValue })
      {
        try await runtime.register(
          plugins.makeProvider(from: provider, environment: ProcessInfo.processInfo.environment),
          replacingExisting: true)
      }
      for agent in draft.agents where changed.contains(agent.id) {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      configuration = draft
      if session.profile.agentID == name {
        try applyDefinition(definition, to: &session)
      }
      let groups = definition.toolGroupNames.sorted()
      let summary =
        "\(providerID)\(model.isEmpty ? "" : " \(model)"), "
        + (groups.isEmpty ? "no tool groups" : "tool groups \(groups.joined(separator: ", "))")
        + ", system prompt '\(promptName)'"
      let hint =
        session.profile.agentID == name ? "" : " /agent use \(name) switches this chat to it."
      await terminal.line("\(isNew ? "Added" : "Updated") agent '\(name)': \(summary).\(hint)")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// What `a,b,c`, `+a,-b`, or `-` asks for, resolved against the tool
  /// group catalog.
  private struct ToolGroupSelection {
    var replaces: Bool
    var added: [ToolGroupDefinition] = []
    var removed: [ToolGroupDefinition] = []

    func apply(to definition: inout AgentDefinition) {
      if replaces {
        definition.toolPolicy.groups = [:]
        definition.toolPolicy.tools = [:]
        definition.toolGroupNames = Set(added.map { $0.sourceID == "mcp" ? $0.catalogID : $0.id })
        definition.toolNames = added.reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
        return
      }
      for group in removed {
        definition.toolGroupNames.remove(group.id)
        definition.toolNames.subtract(group.toolNames)
        definition.setToolGroupMode(.disabled, for: group)
      }
      for group in added {
        definition.toolGroupNames.insert(group.id)
        definition.toolNames.formUnion(group.toolNames)
        definition.setToolGroupMode(nil, for: group)
      }
    }
  }

  /// Parses a tool group spec, saying which name was not found.
  private static func resolveToolGroupSpec(
    _ spec: String,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async -> ToolGroupSelection? {
    let catalog: [ToolGroupDefinition]
    do {
      catalog = try await toolGroupCatalog(
        runtime: runtime, plugins: plugins, configuration: configuration)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return nil
    }
    if spec == "-" || spec.lowercased() == "none" { return ToolGroupSelection(replaces: true) }
    let entries = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let relative = !entries.isEmpty && entries.allSatisfy { $0.hasPrefix("+") || $0.hasPrefix("-") }
    var selection = ToolGroupSelection(replaces: !relative)
    for entry in entries {
      let name = relative ? String(entry.dropFirst()) : entry
      guard let group = resolveToolGroup(name, in: catalog) else {
        await terminal.line(
          "Unknown tool group '\(name)'. Available: \(catalog.map(\.id).sorted().joined(separator: ", "))."
        )
        return nil
      }
      if relative, entry.hasPrefix("-") {
        selection.removed.append(group)
      } else {
        selection.added.append(group)
      }
    }
    return selection
  }

  /// Applies one change to a saved definition, writes it back, and keeps the
  /// current chat in step when it is the agent edited — without clearing
  /// the conversation. `change` answers a message to refuse the edit.
  private static func updateAgent(
    _ id: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter,
    change: (inout AgentDefinition, MaiConfiguration) -> String?
  ) async -> AgentDefinition? {
    guard let draft = configuration, configurationPath != nil else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return nil
    }
    guard var definition = draft.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. /agents lists the saved ones.")
      return nil
    }
    if let refusal = change(&definition, draft) {
      await terminal.line(refusal)
      return nil
    }
    guard
      await persistAgentDefinition(
        definition,
        configuration: &configuration,
        configurationPath: configurationPath,
        runtime: runtime,
        terminal: terminal)
    else { return nil }
    if session.profile.agentID == id {
      do {
        try applyDefinition(definition, to: &session)
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    }
    return definition
  }

  /// Brings the current chat in step with a definition just saved, without
  /// clearing the conversation: the system message is rewritten in place.
  static func applyDefinition(
    _ definition: AgentDefinition,
    to session: inout REPLSession
  ) throws {
    let previous = session.profile.instructions
    session.profile = SessionProfile(definition: definition)
    try applySystemInstructions(definition.instructions, replacing: previous, session: &session)
  }

  private static func removeAgent(
    _ id: String,
    session: REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    guard let removed = draft.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. /agents lists the saved ones.")
      return
    }
    guard id != session.profile.agentID else {
      await terminal.line("Agent '\(id)' is this chat's agent; switch with /agent use OTHER first.")
      return
    }
    let parents = draft.agents.filter { $0.subagentNames.contains(id) }.map(\.id)
    let previousDefault = draft.defaultAgent
    draft.removeAgent(id)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      await runtime.unregister(agentID: id)
      await runtime.configureTaskAgents(draft.taskAgents)
      configuration = draft
      var notes = ["Removed agent '\(id)'."]
      if !parents.isEmpty {
        notes.append("It is no longer a subagent of \(parents.joined(separator: ", ")).")
      }
      if let current = draft.defaultAgent, current != previousDefault {
        notes.append("The default agent is now '\(current)'.")
      }
      if let prompt = removed.systemPrompt, draft.agentsUsingSystemPrompt(prompt).isEmpty,
        draft.prompts?.system[prompt] != nil
      {
        notes.append("Its system prompt '\(prompt)' is now unused; /prompt del \(prompt) drops it.")
      }
      await terminal.line(notes.joined(separator: " "))
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Opens one saved definition as JSON. `instructions` is the text of the
  /// prompt named in `systemPrompt`: changing the text changes that prompt
  /// for every agent using it; naming another existing prompt without
  /// touching the text switches to that prompt.
  static func editAgentDefinition(
    named id: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard let draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    guard let current = draft.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. /agents lists the saved ones.")
      return
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(current)
      guard
        let edited = await editTemporaryData(data, suffix: "agent-\(id).json", terminal: terminal)
      else { return }
      var definition = try JSONDecoder().decode(AgentDefinition.self, from: edited)
      guard definition.id == id else {
        await terminal.line("Keep the id '\(id)'; /agent add creates another agent.")
        return
      }
      if let name = definition.systemPrompt, name != current.systemPrompt,
        definition.instructions == current.instructions,
        let text = draft.systemPrompt(named: name)?.text
      {
        definition.instructions = text
      }
      guard
        await persistAgentDefinition(
          definition,
          configuration: &configuration,
          configurationPath: configurationPath,
          runtime: runtime,
          terminal: terminal)
      else { return }
      if session.profile.agentID == id {
        try applyDefinition(definition, to: &session)
      }
      await terminal.line("Agent '\(id)' saved to \(configurationPath).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func showAgent(
    _ id: String,
    session: REPLSession,
    configuration: MaiConfiguration?,
    providerBaseURLs: [String: URL],
    terminal: TerminalWriter
  ) async {
    let definition =
      session.profile.agentID == id
      ? session.profile.agentDefinition : configuration?.agents.first(where: { $0.id == id })
    guard let definition else {
      await terminal.line("Unknown agent '\(id)'. Use /agents.")
      return
    }
    let baseURL =
      providerBaseURLs[definition.provider.rawValue]
      ?? configuration?.providers.first { $0.id == definition.provider.rawValue }?.baseURL
    let groups = definition.toolGroupNames.sorted()
    let subagents = definition.subagentNames.sorted()
    let parked = definition.isEnabled ? "" : " [disabled]"
    await terminal.line("Agent: \(definition.id) (\(definition.displayName))\(parked)")
    if !definition.description.isEmpty {
      await terminal.line("Description: \(definition.description)")
    }
    await terminal.line("Provider: \(definition.provider)")
    await terminal.line("Base URL: \(baseURL?.absoluteString ?? "-")")
    await terminal.line("Model: \(definition.model.isEmpty ? "-" : definition.model)")
    await terminal.line(
      "Tool groups: \(groups.isEmpty ? "-" : groups.joined(separator: ", ")) (\(definition.toolNames.count) tools)"
    )
    await terminal.line("Subagents: \(subagents.isEmpty ? "-" : subagents.joined(separator: ", "))")
    await terminal.line(
      "Delegation: \(definition.toolDelegation.rawValue) · limits \(definition.limits.maxModelTurns) turns, \(definition.limits.maxToolCalls) tools, \(definition.limits.maxSubagents) subagents"
    )
    await terminal.line("Tool calling: \(definition.toolCallingStrategy.rawValue)")
    await terminal.line("System prompt: \(definition.systemPrompt ?? "inline")")
    await terminal.line(
      "Instructions: \(definition.instructions.isEmpty ? "-" : definition.instructions)")
  }

  @discardableResult

  static func persistAgentProfile(
    session: REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    makeDefault: Bool = false,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async -> Bool {
    await persistAgentDefinition(
      session.profile.agentDefinition,
      configuration: &configuration,
      configurationPath: configurationPath,
      makeDefault: makeDefault,
      runtime: runtime,
      terminal: terminal)
  }

  /// Writes one definition to the configuration and the live runtime, along
  /// with every agent sharing its named prompt. Answers false, having said
  /// why, when nothing could be saved.
  @discardableResult

  private static func persistAgentDefinition(
    _ definition: AgentDefinition,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    makeDefault: Bool = false,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async -> Bool {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    var changed = draft.upsertAgent(definition)
    changed += MaiAgentPresets.install(in: &draft, using: definition)
    if makeDefault { draft.defaultAgent = definition.id }
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      for agent in draft.agents where changed.contains(agent.id) {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      configuration = draft
      return true
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return false
    }
  }
}
