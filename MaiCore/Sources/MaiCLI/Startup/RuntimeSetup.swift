import Foundation
import MaiCore
import MaiLocalProviders
import MaiPluginHost
import MaiStandardTools
import MaiVisionOCR

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

struct RuntimeSetup {
  var catalogs: [MCPServerCatalog]
  var implicitProviders: [ConfiguredProvider] = []
  var providerBaseURLs: [String: URL] = [:]
}

extension MaiCLI {
  static func loadNativePlugins(
    options: CLIOptions,
    loadedConfigurationPath: String?,
    configuration: MaiConfiguration?,
    environment: [String: String],
    host: NativePluginHost,
    registry: PluginRegistry
  ) async throws {
    let currentDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true)
    let configDirectory =
      loadedConfigurationPath.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent()
      } ?? currentDirectory
    let configured =
      configuration?.plugins.filter(\.enabled).map {
        (entry: $0, baseURL: configDirectory)
      } ?? []
    let commandLine = options.pluginPaths.map {
      (entry: ConfiguredPlugin(path: $0), baseURL: currentDirectory)
    }

    for item in configured + commandLine {
      let expanded = AgentHome.expandUserPath(item.entry.path, environment: environment)
      let url = URL(fileURLWithPath: expanded, relativeTo: item.baseURL).standardizedFileURL
      do {
        _ = try await host.loadPlugin(at: url, into: registry)
      } catch {
        if item.entry.required { throw error }
        FileHandle.standardError.write(
          Data(
            "warning: optional plugin '\(url.path)' was not loaded: \(error.localizedDescription)\n"
              .utf8))
      }
    }
  }

  static func registerTools(
    in runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    environment: [String: String]
  ) async throws {
    let sources = configuration?.toolSources ?? []
    let configuredStandardTools = sources.filter {
      $0.kind == MaiStandardToolsPlugin.factoryKind
    }
    if configuredStandardTools.isEmpty {
      let tools = try await plugins.makeTools(
        kind: MaiStandardToolsPlugin.factoryKind,
        context: PluginFactoryContext(id: "standard-tools", environment: environment))
      try await runtime.register(tools: tools)
    } else {
      for source in configuredStandardTools where source.enabled {
        let tools = try await plugins.makeTools(
          kind: source.kind,
          context: source.context(environment: environment))
        try await runtime.register(tools: tools)
      }
    }

    for source in sources
    where source.enabled && source.kind != MaiStandardToolsPlugin.factoryKind {
      let tools = try await plugins.makeTools(
        kind: source.kind,
        context: source.context(environment: environment))
      try await runtime.register(tools: tools)
    }
  }

  /// Tool and group names that changed; agent records saved under the old
  /// name are moved to the new one the next time the configuration is read.
  private static let renamedToolNames = ["calculator": MaiCalculatorTool.name]

  /// Tool names remain in the agent record for provider/runtime portability;
  /// group names let a host expand newly added plugin tools without requiring
  /// users to toggle an already enabled group off and on again.
  static func synchronizeToolGroupSelections(
    configuration: inout MaiConfiguration?,
    configurationPath: String,
    plugins: PluginRegistry,
    runtime: AgentRuntime
  ) async throws {
    let catalog = try await toolGroupCatalog(
      runtime: runtime, plugins: plugins, configuration: configuration)
    guard var draft = configuration else { return }
    var toolsByGroup: [String: Set<String>] = [
      AgentRuntime.agentToolGroup.id: AgentRuntime.agentToolGroup.toolNames
    ]
    let sourceIDs = Set(draft.toolSources.filter(\.enabled).map(\.id))
    for group in catalog where sourceIDs.contains(group.sourceID) {
      toolsByGroup[group.id, default: []].formUnion(group.toolNames)
    }
    // Tools pmai registers itself — todo, chats — belong to no plugin, so
    // their groups are inferred the way /tools lists them; otherwise a group
    // named in the configuration would show as enabled yet offer nothing.
    let grouped = Set(toolsByGroup.values.flatMap { $0 })
    let hostTools = await runtime.availableTools().filter { !grouped.contains($0.name) }
    for group in ToolGroupDefinition.inferred(from: hostTools) {
      toolsByGroup[group.id, default: []].formUnion(group.toolNames)
    }
    for group in catalog {
      toolsByGroup[group.catalogID, default: []].formUnion(group.toolNames)
    }
    var changed = false
    for index in draft.agents.indices {
      let previous = draft.agents[index].toolNames
      let previousGroups = draft.agents[index].toolGroupNames
      for (old, new) in renamedToolNames {
        if draft.agents[index].toolNames.remove(old) != nil {
          draft.agents[index].toolNames.insert(new)
        }
        if draft.agents[index].toolGroupNames.remove(old) != nil {
          draft.agents[index].toolGroupNames.insert(new)
        }
      }
      for groupName in draft.agents[index].toolGroupNames {
        draft.agents[index].toolNames.formUnion(toolsByGroup[groupName] ?? [])
      }
      changed =
        changed || previous != draft.agents[index].toolNames
        || previousGroups != draft.agents[index].toolGroupNames
    }
    guard changed else { return }
    try draft.save(to: URL(fileURLWithPath: configurationPath))
    configuration = draft
  }

  /// Picks the configured OCR backend, falling back to whatever this platform
  /// can offer (Apple Vision, then a local tesseract binary). OCR never blocks
  /// startup: when nothing is usable the returned provider explains why the
  /// first time OCR is requested.
  static func configuredOCRProvider(
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    environment: [String: String]
  ) async -> any OCRProvider {
    var failures: [String] = []
    if let configured = configuration?.ocrProviders.first(where: \.enabled) {
      do {
        return try await plugins.makeOCRProvider(
          kind: configured.kind,
          context: configured.context(environment: environment))
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    var fallbackKinds = [MaiVisionOCRPlugin.preferredFactoryKind]
    for kind in ["vision", TesseractOCRProvider.factoryKind] where !fallbackKinds.contains(kind) {
      fallbackKinds.append(kind)
    }
    for kind in fallbackKinds {
      do {
        return try await plugins.makeOCRProvider(
          kind: kind,
          context: PluginFactoryContext(id: kind, environment: environment))
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    return UnavailableOCRProvider(
      reason: failures.isEmpty
        ? "no OCR provider is registered on this platform."
        : failures.joined(separator: " "))
  }

  /// Exposes the shared `chats_*` tools over this session's reachable chats.
  /// They are registered before configured agents are filtered against the
  /// known tool names, so an agent may list them like any other tool.
  static func registerMemoryTools(
    in runtime: AgentRuntime,
    state: MemoryState
  ) async throws {
    for definition in MaiMemoryTools.definitions {
      let name = definition.name
      try await runtime.register(
        tool: ClosureTool(definition: definition) { arguments, _ in
          guard state.readsOtherChats else {
            return ToolOutput(
              text:
                "Error: reading other chats is disabled. Enable it with /memory scope project or /memory scope all.",
              isError: true)
          }
          return ToolOutput(
            text: MaiMemoryTools.execute(
              name: name,
              arguments: arguments.objectValue ?? [:],
              chats: state.reachableChats()))
        })
    }
  }

  /// Exposes the shared `todo_*` tools over the current project's list file.
  /// Like the memory tools they are registered before agents are filtered
  /// against the known tool names, so an agent may list them like any other.
  static func registerTodoTools(
    in runtime: AgentRuntime,
    state: TodoState
  ) async throws {
    for tool in MaiTodoTools.makeTools(url: { state.url }) {
      try await runtime.register(tool: tool)
    }
  }

  static func configureRuntime(
    _ runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    options: CLIOptions,
    selectedProvider: ProviderID,
    resumingChat: Bool,
    environment: [String: String], startup: CLIStartupTiming
  ) async throws -> RuntimeSetup {
    await runtime.configureInternetAccess(.init(airplaneModeEnabled: configuration?.airplane ?? false))
    await runtime.configureToolsEnabled(configuration?.toolsEnabled ?? true)
    // Flags deliberately override a connection. Ambient variables only fill
    // missing settings; a named provider owns its endpoint and credentials.
    func resolvedBaseURL(_ configured: URL?) throws -> URL? {
      if let explicit = options.baseURLOverride { return explicit }
      if let configured { return configured }
      guard !resumingChat || configuration == nil,
        let raw = environmentValue(
          ["PMAI_BASE_URL", "MAI_BASE_URL", "OPENAI_BASE_URL"], in: environment)
      else { return nil }
      guard let url = URL(string: raw),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
      else { throw CLIError.invalidURL(raw) }
      return url
    }

    var providers = configuration?.providers ?? []
    var implicitProviders: [ConfiguredProvider] = []
    // An explicit flag or environment setting can still bootstrap a connection.
    // An unconfigured launch leaves the list empty until /provider add.
    if providers.isEmpty, !selectedProvider.rawValue.isEmpty {
      let provider: ConfiguredProvider
      if selectedProvider == .hello {
        provider = ConfiguredProvider(id: "hello", kind: .hello)
      } else if let local = MaiLocalProvidersPlugin.defaultProviders.first(where: {
        $0.id == selectedProvider.rawValue
      }) {
        provider = local
      } else {
        provider = ConfiguredProvider(
          id: selectedProvider.rawValue, kind: .openAICompatible,
          baseURL: try resolvedBaseURL(nil) ?? URL(string: "http://127.0.0.1:11434/v1")!,
          apiKey: try options.apiKeyOverride ?? environmentAPIKey(in: environment))
      }
      providers = [provider]
      var draft = provider
      if provider.kind == .openAICompatible {
        draft.apiKey = nil
        draft.apiKeyEnvironment = environmentName(
          ["PMAI_API_KEY", "MAI_API_KEY", "OPENAI_API_KEY"], in: environment)
        draft.apiKeyFile = environment["PMAI_API_KEY_FILE"].flatMap {
          $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
      }
      implicitProviders = [draft]
    }
    var providerBaseURLs: [String: URL] = [:]
    for var provider in providers {
      if provider.id == selectedProvider.rawValue, ![.apple, .mlx, .chatGPT].contains(provider.kind) {
        provider.baseURL = try resolvedBaseURL(provider.baseURL)
        let hasCredentials =
          provider.apiKey != nil
          || !(provider.apiKeyEnvironment ?? "").isEmpty
          || !(provider.apiKeyFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let apiKeyOverride =
          try options.apiKeyOverride
          ?? (hasCredentials ? nil : environmentAPIKey(in: environment))
        if let apiKeyOverride {
          provider.apiKey = apiKeyOverride
          provider.apiKeyEnvironment = nil
          provider.apiKeyFile = nil
        }
      }
      providerBaseURLs[provider.id] = provider.baseURL
      try await runtime.register(plugins.makeProvider(from: provider, environment: environment))
      startup.mark("provider \(provider.id) registered")
    }
    var catalogs: [MCPServerCatalog] = []
    if let configuration {
      for server in configuration.mcpServers where server.enabled {
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind, configuration: server, environment: environment)
        if !(await runtime.internetAccessPolicy()).allows(source) { continue }
        catalogs.append(try await runtime.register(mcp: source))
        startup.mark("MCP \(server.id) connected")
      }
      await runtime.configureDelegation(
        prompt: configuration.prompts?.delegation,
        workerInstructions: configuration.prompts?.worker)
      await runtime.configureCompaction(prompt: configuration.prompts?.compact)
      await runtime.configureSmartContext(prompt: configuration.prompts?.smart)
      await runtime.configureTaskAgents(configuration.taskAgents)
      let knownTools = Set(await runtime.availableTools().map(\.name))
      for var agent in configuration.agents {
        agent.toolNames.formIntersection(knownTools)
        try await runtime.register(agent: agent)
      }
    }
    return RuntimeSetup(
      catalogs: catalogs, implicitProviders: implicitProviders, providerBaseURLs: providerBaseURLs)
  }

  static func selectedProfile(
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) throws -> SessionProfile {
    // Environment defaults bootstrap an installation. Once an agent is saved,
    // its selections survive restarts even when the shell still exports old defaults.
    let defaultsEnvironment = configuration?.agents.isEmpty == false ? [:] : environment
    let providerOverride =
      options.providerOverride
      ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: defaultsEnvironment).map {
        ProviderID($0)
      }
    let modelDefault = environmentValue(
      ["PMAI_MODEL", "MAI_MODEL", "OPENAI_MODEL"], in: defaultsEnvironment)
    var profile: SessionProfile
    if let configuration, !configuration.agents.isEmpty {
      let selectedID =
        options.agentOverride ?? configuration.defaultAgent
        ?? configuration.agents.first?.id
      guard let definition = configuration.agents.first(where: { $0.id == selectedID }) else {
        throw MaiConfigurationError.unknownAgent(selectedID ?? "")
      }
      profile = SessionProfile(definition: definition)
    } else {
      let hasAdHocProvider = options.providerOverride != nil || options.modelOverride != nil
        || options.baseURLOverride != nil || options.apiKeyOverride != nil
        || environmentValue([
          "PMAI_PROVIDER", "MAI_PROVIDER", "PMAI_MODEL", "MAI_MODEL", "OPENAI_MODEL",
          "PMAI_BASE_URL", "MAI_BASE_URL", "OPENAI_BASE_URL", "PMAI_API_KEY", "MAI_API_KEY",
          "OPENAI_API_KEY", "PMAI_API_KEY_FILE",
        ], in: defaultsEnvironment) != nil
      let provider = providerOverride
        ?? configuration?.providers.first.map { ProviderID($0.id) }
        ?? (hasAdHocProvider ? .openAI : ProviderID(""))
      profile = SessionProfile(
        provider: provider,
        model: configuration?.providers.first(where: { $0.id == provider.rawValue })?.defaultModel
          ?? (provider.rawValue.isEmpty ? "" : "gpt-oss:20b"),
        instructions: options.systemOverride ?? SystemPrompt.defaultInstructions,
        stream: options.stream)
    }
    if let providerOverride { profile.provider = providerOverride }
    // Flag selectors were already split by CLIOptions; parsing them again
    // would reinterpret a double colon that belongs to the remaining model ID.
    if options.modelOverride == nil, let modelDefault {
      let selection = try ModelSelection(modelDefault, currentProvider: profile.provider)
      profile.provider = options.providerOverride ?? selection.provider
      profile.model = selection.model
    }
    options.applyOverrides(to: &profile)
    if options.modelOverride == nil, modelDefault == nil,
      let defaultModel = (configuration?.providers ?? MaiLocalProvidersPlugin.defaultProviders).first(where: {
        $0.id == profile.provider.rawValue
      })?.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines),
      !defaultModel.isEmpty, providerOverride != nil || profile.model.isEmpty
    {
      profile.model = defaultModel
    }
    return profile
  }
}
