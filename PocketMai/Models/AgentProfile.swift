import Foundation
import MaiCore

/// The settings that belong to one agent: which model answers, which system
/// prompt it starts from, which tools and MCP servers it may use, and how the
/// tool loop runs. Everything else in `AppSettings` is shared between agents:
/// appearance, the prompt libraries, the endpoint and MCP server definitions,
/// tool credentials, voice, folders, and the rest of the app state.
struct AgentSettings: Codable, Equatable, Sendable {
  var defaultProvider: ProviderKind = .mlx
  var appleModelID: String = AppSettings.appleDefaultModelID
  var localMLXModelID: String = AppSettings.localMLXDefaultModelID
  var selectedEndpointID: UUID? = nil
  var openAIModelID: String = ""
  var defaultReasoningLevel: ReasoningLevel = .automatic
  var streamByDefault: Bool = true
  var showThinkingByDefault: Bool = false
  var defaultSystemPromptID: UUID = AppSettings.defaultSystemPrompt.id
  var defaultEnabledTools: Set<BuiltInToolID> = AppSettings.defaultTools
  var defaultEnabledMCPServers: Set<UUID> = AppSettings.defaultMCPServers
  var defaultEnabledMCPTools: Set<String> = AppSettings.defaultMCPTools
  var mcpRequestTimeoutSeconds: Int = AppSettings.defaultMCPRequestTimeoutSeconds
  var llmRequestTimeoutSeconds: Int = AppSettings.defaultLLMRequestTimeoutSeconds
  var toolCallingMode: ToolCallingMode = .text
  var maxToolCallsPerTurn: Int = AppSettings.defaultMaxToolCallsPerTurn
  var yoloModeEnabled: Bool = true
  var useToolProxy: Bool = false
  var useSystemOne: Bool = false
  var contextWindowMode: ContextWindowMode = .full
  var includeAssistantResponsesInContext: Bool = true
  var includeReasoningContentInContext: Bool = false
  var mlxMaxKVSize: MLXKVCacheSize = .auto
  var mlxAutoCompact: Bool = false

  init() {}

  enum CodingKeys: String, CodingKey {
    case defaultProvider, appleModelID, localMLXModelID, selectedEndpointID, openAIModelID
    case defaultReasoningLevel, streamByDefault, showThinkingByDefault
    case defaultSystemPromptID, defaultEnabledTools
    case defaultEnabledMCPServers, defaultEnabledMCPTools
    case mcpRequestTimeoutSeconds, llmRequestTimeoutSeconds
    case toolCallingMode, maxToolCallsPerTurn, yoloModeEnabled, useToolProxy, useSystemOne
    case contextWindowMode, includeAssistantResponsesInContext, includeReasoningContentInContext
    case mlxMaxKVSize, mlxAutoCompact
  }

  /// Every field falls back to its default on its own, so a file written by
  /// another version never loses the whole agent.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = AgentSettings()
    defaultProvider =
      (try? c.decode(ProviderKind.self, forKey: .defaultProvider)) ?? defaults.defaultProvider
    appleModelID = (try? c.decode(String.self, forKey: .appleModelID)) ?? defaults.appleModelID
    localMLXModelID =
      (try? c.decode(String.self, forKey: .localMLXModelID)) ?? defaults.localMLXModelID
    selectedEndpointID = try? c.decode(UUID.self, forKey: .selectedEndpointID)
    openAIModelID = (try? c.decode(String.self, forKey: .openAIModelID)) ?? ""
    defaultReasoningLevel =
      (try? c.decode(ReasoningLevel.self, forKey: .defaultReasoningLevel))
      ?? defaults.defaultReasoningLevel
    streamByDefault =
      (try? c.decode(Bool.self, forKey: .streamByDefault)) ?? defaults.streamByDefault
    showThinkingByDefault =
      (try? c.decode(Bool.self, forKey: .showThinkingByDefault)) ?? defaults.showThinkingByDefault
    defaultSystemPromptID =
      (try? c.decode(UUID.self, forKey: .defaultSystemPromptID)) ?? defaults.defaultSystemPromptID
    defaultEnabledTools = BuiltInToolID.knownTools(
      from: try? c.decode([String].self, forKey: .defaultEnabledTools))
    defaultEnabledMCPServers =
      (try? c.decode(Set<UUID>.self, forKey: .defaultEnabledMCPServers))
      ?? defaults.defaultEnabledMCPServers
    defaultEnabledMCPTools =
      (try? c.decode(Set<String>.self, forKey: .defaultEnabledMCPTools))
      ?? defaults.defaultEnabledMCPTools
    mcpRequestTimeoutSeconds = AppSettings.clampedMCPRequestTimeoutSeconds(
      (try? c.decode(Int.self, forKey: .mcpRequestTimeoutSeconds))
        ?? defaults.mcpRequestTimeoutSeconds)
    llmRequestTimeoutSeconds = AppSettings.normalizedLLMRequestTimeoutSeconds(
      (try? c.decode(Int.self, forKey: .llmRequestTimeoutSeconds))
        ?? defaults.llmRequestTimeoutSeconds)
    toolCallingMode =
      (try? c.decode(ToolCallingMode.self, forKey: .toolCallingMode)) ?? defaults.toolCallingMode
    maxToolCallsPerTurn = AppSettings.clampedMaxToolCallsPerTurn(
      (try? c.decode(Int.self, forKey: .maxToolCallsPerTurn)) ?? defaults.maxToolCallsPerTurn)
    yoloModeEnabled =
      (try? c.decode(Bool.self, forKey: .yoloModeEnabled)) ?? defaults.yoloModeEnabled
    useSystemOne = (try? c.decode(Bool.self, forKey: .useSystemOne)) ?? false
    useToolProxy = (try? c.decode(Bool.self, forKey: .useToolProxy)) ?? defaults.useToolProxy
    contextWindowMode =
      (try? c.decode(ContextWindowMode.self, forKey: .contextWindowMode))
      ?? defaults.contextWindowMode
    includeAssistantResponsesInContext =
      (try? c.decode(Bool.self, forKey: .includeAssistantResponsesInContext))
      ?? defaults.includeAssistantResponsesInContext
    includeReasoningContentInContext =
      (try? c.decode(Bool.self, forKey: .includeReasoningContentInContext))
      ?? defaults.includeReasoningContentInContext
    mlxMaxKVSize =
      (try? c.decode(MLXKVCacheSize.self, forKey: .mlxMaxKVSize)) ?? defaults.mlxMaxKVSize
    mlxAutoCompact = (try? c.decode(Bool.self, forKey: .mlxAutoCompact)) ?? defaults.mlxAutoCompact
  }
}

/// An agent: a name, a description of what it is for, whether it may hand
/// work to child agents, and its own set of agent settings. The stock agent
/// always exists and cannot be removed, so there is always something to fall
/// back to.
struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
  static let stockID = UUID(uuidString: "5B1F0B0C-2A4E-4C7D-9F3A-6D2E8B1C0A11")!
  static let stockName = "Main"

  var id: UUID
  var name: String
  var description: String
  /// Whether this agent may start child agents once the app runs them; the
  /// flag is kept with the agent so delegation can be switched per agent.
  var canSpawnSubagents: Bool
  var settings: AgentSettings

  init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    canSpawnSubagents: Bool = false,
    settings: AgentSettings
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.canSpawnSubagents = canSpawnSubagents
    self.settings = settings
  }

  var isStock: Bool { id == Self.stockID }

  static func stock(settings: AgentSettings = AgentSettings()) -> AgentProfile {
    AgentProfile(id: stockID, name: stockName, settings: settings)
  }

  enum CodingKeys: String, CodingKey { case id, name, description, canSpawnSubagents, settings }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = (try? c.decode(String.self, forKey: .name)) ?? ""
    description = (try? c.decode(String.self, forKey: .description)) ?? ""
    canSpawnSubagents = (try? c.decode(Bool.self, forKey: .canSpawnSubagents)) ?? false
    settings = (try? c.decode(AgentSettings.self, forKey: .settings)) ?? AgentSettings()
  }
}

extension AppSettings {
  /// The agent-scoped part of the live settings. Reading it snapshots the
  /// fields the selected agent owns; writing it replaces them, which is how a
  /// switch between agents happens.
  var agentSettings: AgentSettings {
    get {
      var agent = AgentSettings()
      agent.defaultProvider = defaultProvider
      agent.appleModelID = appleModelID
      agent.localMLXModelID = localMLXModelID
      agent.selectedEndpointID = selectedEndpointID
      agent.openAIModelID = openAIModelID
      agent.defaultReasoningLevel = defaultReasoningLevel
      agent.streamByDefault = streamByDefault
      agent.showThinkingByDefault = showThinkingByDefault
      agent.defaultSystemPromptID = defaultSystemPromptID
      agent.defaultEnabledTools = defaultEnabledTools
      agent.defaultEnabledMCPServers = defaultEnabledMCPServers
      agent.defaultEnabledMCPTools = defaultEnabledMCPTools
      agent.mcpRequestTimeoutSeconds = mcpRequestTimeoutSeconds
      agent.llmRequestTimeoutSeconds = llmRequestTimeoutSeconds
      agent.toolCallingMode = toolCallingMode
      agent.maxToolCallsPerTurn = maxToolCallsPerTurn
      agent.yoloModeEnabled = yoloModeEnabled
      agent.useToolProxy = useToolProxy
      agent.useSystemOne = useSystemOne
      agent.contextWindowMode = contextWindowMode
      agent.includeAssistantResponsesInContext = includeAssistantResponsesInContext
      agent.includeReasoningContentInContext = includeReasoningContentInContext
      agent.mlxMaxKVSize = mlxMaxKVSize
      agent.mlxAutoCompact = mlxAutoCompact
      return agent
    }
    set {
      defaultProvider = newValue.defaultProvider
      appleModelID = newValue.appleModelID
      localMLXModelID = newValue.localMLXModelID
      selectedEndpointID = newValue.selectedEndpointID
      openAIModelID = newValue.openAIModelID
      defaultReasoningLevel = newValue.defaultReasoningLevel
      streamByDefault = newValue.streamByDefault
      showThinkingByDefault = newValue.showThinkingByDefault
      defaultSystemPromptID = newValue.defaultSystemPromptID
      defaultEnabledTools = newValue.defaultEnabledTools
      defaultEnabledMCPServers = newValue.defaultEnabledMCPServers
      defaultEnabledMCPTools = newValue.defaultEnabledMCPTools
      mcpRequestTimeoutSeconds = newValue.mcpRequestTimeoutSeconds
      llmRequestTimeoutSeconds = newValue.llmRequestTimeoutSeconds
      toolCallingMode = newValue.toolCallingMode
      maxToolCallsPerTurn = newValue.maxToolCallsPerTurn
      yoloModeEnabled = newValue.yoloModeEnabled
      useToolProxy = newValue.useToolProxy
      useSystemOne = newValue.useSystemOne
      contextWindowMode = newValue.contextWindowMode
      includeAssistantResponsesInContext = newValue.includeAssistantResponsesInContext
      includeReasoningContentInContext = newValue.includeReasoningContentInContext
      mlxMaxKVSize = newValue.mlxMaxKVSize
      mlxAutoCompact = newValue.mlxAutoCompact
    }
  }

  /// The agent whose settings the live fields currently hold.
  var selectedAgent: AgentProfile {
    agents.first(where: { $0.id == selectedAgentID })
      ?? agents.first(where: \.isStock)
      ?? .stock(settings: agentSettings)
  }

  /// Keeps the agent list usable: one entry per id with a non-empty name, the
  /// stock agent present, the selection pointing at an existing agent, and the
  /// selected agent's snapshot equal to the live settings. A file from before
  /// agents existed gets a stock agent holding the settings it already had.
  mutating func normalizeAgents() {
    var seen = Set<UUID>()
    var normalized: [AgentProfile] = []
    for var agent in agents where !seen.contains(agent.id) {
      seen.insert(agent.id)
      agent.name = Self.normalizedAgentName(
        agent.name,
        fallback: agent.isStock ? AgentProfile.stockName : "Agent \(normalized.count + 1)")
      agent.description = Self.normalizedAgentDescription(agent.description)
      normalized.append(agent)
    }
    if !normalized.contains(where: \.isStock) {
      normalized.insert(.stock(settings: agentSettings), at: 0)
    }
    agents = normalized
    if !agents.contains(where: { $0.id == selectedAgentID }) {
      selectedAgentID = AgentProfile.stockID
    }
    for task in AgentTask.allCases {
      if let id = taskAgents[task],
        !agents.contains(where: { $0.id.uuidString.lowercased() == id.lowercased() })
      {
        taskAgents[task] = nil
      }
    }
    syncSelectedAgent()
  }

  /// Copies the live settings into the selected agent's snapshot, so a later
  /// switch away and back restores exactly what was configured.
  mutating func syncSelectedAgent() {
    guard let index = agents.firstIndex(where: { $0.id == selectedAgentID }) else { return }
    let live = agentSettings
    if agents[index].settings != live {
      agents[index].settings = live
    }
  }

  /// Makes `id` the selected agent: the live settings are stored on the agent
  /// being left and replaced by the settings of the one being entered.
  @discardableResult
  mutating func selectAgent(_ id: UUID) -> Bool {
    guard let target = agents.first(where: { $0.id == id }) else { return false }
    syncSelectedAgent()
    selectedAgentID = id
    agentSettings = target.settings
    return true
  }

  /// Adds an agent that starts as a copy of the selected agent's settings.
  @discardableResult
  mutating func addAgent(
    named name: String,
    description: String = "",
    canSpawnSubagents: Bool = false
  ) -> AgentProfile {
    syncSelectedAgent()
    let agent = AgentProfile(
      name: Self.normalizedAgentName(name, fallback: "Agent \(agents.count + 1)"),
      description: Self.normalizedAgentDescription(description),
      canSpawnSubagents: canSpawnSubagents,
      settings: agentSettings)
    agents.append(agent)
    return agent
  }

  /// Removes an agent other than the stock one. Removing the selected agent
  /// selects the stock agent and applies its settings.
  @discardableResult
  mutating func removeAgent(_ id: UUID) -> Bool {
    guard id != AgentProfile.stockID, let index = agents.firstIndex(where: { $0.id == id })
    else { return false }
    agents.remove(at: index)
    taskAgents.removeReferences(to: id.uuidString.lowercased())
    if selectedAgentID == id {
      selectedAgentID = AgentProfile.stockID
      if let stock = agents.first(where: \.isStock) {
        agentSettings = stock.settings
      }
    }
    return true
  }

  /// Changes what identifies an agent; a blank name keeps the current one.
  mutating func updateAgent(
    _ id: UUID,
    name: String,
    description: String,
    canSpawnSubagents: Bool
  ) {
    guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
    agents[index].name = Self.normalizedAgentName(name, fallback: agents[index].name)
    agents[index].description = Self.normalizedAgentDescription(description)
    agents[index].canSpawnSubagents = canSpawnSubagents
  }

  /// Task inference uses the named agent but keeps the caller's tool grants.
  /// Missing references in imported/older settings mean the current agent.
  func taskAgent(_ task: AgentTask) -> AgentProfile? {
    guard let id = taskAgents[task] else { return nil }
    guard var agent = agents.first(where: { $0.id.uuidString.lowercased() == id.lowercased() })
    else { return nil }
    if agent.id == selectedAgentID { agent.settings = agentSettings }
    return agent
  }

  func taskConversation(_ task: AgentTask, from original: Conversation) -> Conversation {
    guard let agent = taskAgent(task) else { return original }
    let profile = agent.settings
    var result = original
    result.provider = profile.defaultProvider
    result.endpointID = profile.selectedEndpointID
    switch profile.defaultProvider {
    case .apple: result.modelID = profile.appleModelID
    case .mlx: result.modelID = profile.localMLXModelID
    case .openAICompatible:
      result.modelID =
        profile.openAIModelID.isEmpty
        ? openAIEndpoints.first(where: { $0.id == profile.selectedEndpointID })?.defaultModel ?? ""
        : profile.openAIModelID
    }
    result.systemPromptID = profile.defaultSystemPromptID
    result.reasoningLevel = profile.defaultReasoningLevel
    result.usesStreaming = profile.streamByDefault
    result.mlxMaxKVSize = profile.mlxMaxKVSize
    return result
  }

  static func normalizedAgentName(_ name: String, fallback: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  static func normalizedAgentDescription(_ description: String) -> String {
    description.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
