import Foundation

extension AgentRuntime {
  public static let agentStartToolName = AgentProcessTools.startToolName
  public static let agentStatusToolName = AgentProcessTools.statusToolName
  public static let agentResultToolName = AgentProcessTools.resultToolName
  public static let agentStopToolName = AgentProcessTools.stopToolName
  public static let agentToolNames: Set<String> = AgentProcessTools.toolNames
  public static let agentToolGroup = ToolGroupDefinition(
    id: "agents",
    sourceID: "runtime",
    displayName: "Agents",
    description:
      "Delegate work to child agents that run with a context and tool set of their own. "
      + "agent_start launches one with a brief and either waits for its answer or returns its "
      + "pid, in which case the answer arrives later as a message; children started in one reply "
      + "run at once, and a child may start children of its own; "
      + "agent_status lists the children with their state and can read one's transcript; agent_result "
      + "collects the answer of a child started without waiting; agent_stop ends a child and everything "
      + "it started. Use them for independent subtasks, parallel research, or work whose tool output "
      + "should not fill this conversation.",
    toolNames: agentToolNames)

  /// The groups of the tools MaiCore itself provides, cut to the ones a host
  /// has registered: `agents`, `chats`, `todo`, `context`, and `skills`. A
  /// host's catalog starts with these; whatever else the runtime holds is
  /// grouped by its name prefix.
  public static func builtInToolGroups(for tools: [ToolDefinition]) -> [ToolGroupDefinition] {
    let names = Set(tools.map(\.name))
    var groups = [agentToolGroup]
    for group in [MaiMemoryTools.group, MaiTodoTools.group, MaiContextTools.group] {
      var group = group
      group.toolNames = group.toolNames.intersection(names)
      if !group.toolNames.isEmpty { groups.append(group) }
    }
    let skills = names.filter(MaiSkillTools.isSkillTool)
    if !skills.isEmpty { groups.append(MaiSkillTools.group(toolNames: skills)) }
    return groups
  }
  /// Earlier spellings of `agent_start`. They are still executed so existing
  /// configurations and fine-tuned providers keep working, but they are no
  /// longer offered: six near-identical tools only confuse a model.
  public static let subagentToolName = AgentProcessTools.legacySpawnToolName
  public static let agentLaunchToolName = AgentProcessTools.legacyLaunchToolName

  struct RegisteredMCP: Sendable {
    var source: any MCPToolSource
    var toolNames: Set<String>
  }

  /// Adds any provider implementation to the runtime by its descriptor ID.
  public func register(
    _ provider: any ChatProvider,
    replacingExisting: Bool = false
  ) throws {
    let descriptor = provider.descriptor
    let rawID = descriptor.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawID.isEmpty else { throw AgentRuntimeError.invalidProviderID }
    guard replacingExisting || providers[descriptor.id] == nil else {
      throw AgentRuntimeError.providerAlreadyRegistered(descriptor.id)
    }
    providers[descriptor.id] = provider
  }

  /// Calls already in flight finish with their existing connection; subsequent
  /// calls and live agent references use the renamed provider.
  public func renameProvider(_ id: ProviderID, to provider: any ChatProvider) throws {
    guard providers[id] != nil else { throw AgentRuntimeError.providerNotRegistered(id) }
    let newID = provider.descriptor.id
    guard newID != id else { return }
    try register(provider)
    providers.removeValue(forKey: id)
    for key in Array(agents.keys) where agents[key]?.provider == id {
      agents[key]?.provider = newID
    }
    for pid in Array(liveRequests.keys) where liveRequests[pid]?.provider == id {
      liveRequests[pid]?.provider = newID
    }
    for pid in Array(pendingReconfigurations.keys)
    where pendingReconfigurations[pid]?.provider == id {
      pendingReconfigurations[pid]?.provider = newID
    }
  }

  public func register(
    tool: any AgentTool,
    replacingExisting: Bool = false
  ) throws {
    let name = tool.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AgentToolError.invalidName }
    guard !AgentProcessTools.reservedToolNames.contains(name) else {
      throw AgentRuntimeError.reservedToolName(name)
    }
    guard replacingExisting || tools[name] == nil else {
      throw AgentToolError.duplicateName(name)
    }
    tools[name] = tool
  }

  @discardableResult
  public func register(
    mcp source: any MCPToolSource,
    replacingExistingTools: Bool = false
  ) async throws -> MCPServerCatalog {
    let catalog = try await source.connect()
    let agentTools = try await source.agentTools()
    for tool in agentTools {
      try register(tool: tool, replacingExisting: replacingExistingTools)
    }
    registeredMCPs[catalog.serverID] = RegisteredMCP(
      source: source,
      toolNames: Set(agentTools.map { $0.definition.name }))
    return catalog
  }

  /// Forgets a tool registered directly, so it is no longer offered or run.
  /// Tools that came with an MCP server leave with `unregisterMCP` instead.
  @discardableResult
  public func unregister(toolNamed name: String) -> Bool {
    tools.removeValue(forKey: name) != nil
  }

  /// Disconnects an MCP source and removes the tools discovered from it.
  @discardableResult
  public func unregisterMCP(serverID: String) async -> Set<String> {
    guard let registration = registeredMCPs.removeValue(forKey: serverID) else { return [] }
    for name in registration.toolNames { tools[name] = nil }
    await registration.source.close()
    return registration.toolNames
  }

  public func availableProviders() -> [ProviderDescriptor] {
    providers.values.map(\.descriptor).sorted {
      $0.id.rawValue.localizedStandardCompare($1.id.rawValue) == .orderedAscending
    }
  }

  public func availableModels(provider id: ProviderID) async throws -> [ModelDescriptor] {
    guard let provider = providers[id] else {
      throw AgentRuntimeError.providerNotRegistered(id)
    }
    return try await provider.availableModels().sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

  public func availableTools() -> [ToolDefinition] {
    tools.values.map(\.definition).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// Install plugin-defined memberships; inferred and MCP groups are kept
  /// current by the runtime. Replacing this list also drops stale memberships.
  public func configureToolGroups(_ groups: [ToolGroupDefinition]) {
    configuredToolGroups = groups
  }

  public func availableToolGroups() -> [ToolGroupDefinition] {
    let definitions = availableTools()
    let mcpGroups = registeredMCPs.map { id, registration in
      ToolGroupDefinition(
        id: id, sourceID: "mcp", displayName: "MCP " + id,
        description: "Tools supplied by MCP server " + id + ".",
        toolNames: registration.toolNames)
    }.sorted { $0.catalogID < $1.catalogID }
    let known = Self.builtInToolGroups(for: definitions) + configuredToolGroups + mcpGroups
    return ToolGroupDefinition.catalog(known: known, tools: definitions)
  }

  public func configureToolUsage(_ store: AgentToolUsageStore) async {
    toolUsageStore = store
    toolUsage = await store.usage
  }

  public func toolUsageSnapshot() -> AgentToolUsage { toolUsage }

  func recordToolUse(_ name: String) async {
    if let toolUsageStore {
      toolUsage = await toolUsageStore.record(name)
    } else {
      toolUsage.record(name)
    }
  }

  private func toolModes(for request: AgentRequest) -> [String: AgentToolMode] {
    let groups = availableToolGroups()
    let names = Set(tools.keys).union(Self.agentToolNames)
    var enabled = request.toolNames
    if request.toolGroupNames == nil { enabled.formUnion(Self.agentToolNames) }
    for group in groups
    where group.sourceID == "mcp"
      || request.toolGroupNames?.contains(group.id) == true
      || request.toolGroupNames?.contains(group.catalogID) == true
    { enabled.formUnion(group.toolNames) }
    var result = request.toolPolicy.modes(
      for: names, in: groups, enabledNames: enabled, useToolProxy: request.useToolProxy,
      exposedTools: request.proxyExposedTools, usage: toolUsage)
    if let scope = request.restrictedToolNames {
      for name in names where !scope.contains(name) { result[name] = .disabled }
    }
    return result
  }

  func exposedTools(in definitions: [ToolDefinition], request: AgentRequest) -> Set<String> {
    let modes = toolModes(for: request)
    return Set(definitions.filter { modes[$0.name] == .direct }.map(\.name))
  }

  static func canDeriveWorker(for request: AgentRequest) -> Bool {
    let enabled =
      request.toolDelegation.delegatesTools
      || request.toolGroupNames?.contains(agentToolGroup.id) == true
      || request.toolGroupNames?.contains(agentToolGroup.catalogID) == true
      || agentToolNames.isSubset(of: request.toolNames)
    return request.toolPolicy.mode(
      for: agentStartToolName, in: [agentToolGroup], enabled: enabled,
      useToolProxy: request.useToolProxy, exposedTools: request.proxyExposedTools) != .disabled
  }

  /// Hide start at the depth limit, but keep tools for existing children.
  func visibleDefinitions(
    for request: AgentRequest,
    depth: Int = 0
  ) throws -> [ToolDefinition] {
    for name in request.subagentNames where agents[name] == nil {
      throw AgentRuntimeError.agentNotRegistered(name)
    }
    // A disabled definition stays registered so a host can list it, but it is
    // never offered as a subagent.
    let offeredAgents = request.subagentNames.filter { agents[$0]?.isEnabled == true }
    // What an agent may call is its definition's allow-list, wherever it sits
    // in the tree. Delegation adds a way to hand work to a child that has the
    // same tools; it never takes the tools away. It only takes effect where
    // children are actually permitted.
    let delegating = Self.canDeriveWorker(for: request)
    var definitions: [ToolDefinition] = []
    let modes = toolModes(for: request)
    for name in tools.keys.sorted() where modes[name] != .disabled {
      if let tool = tools[name] { definitions.append(tool.definition) }
    }
    // Raw AgentRequest callers predate tool groups, so nil preserves their
    // behavior. Hosts pass the profile's groups and make this a real per-agent
    // permission; accepting the full name set also honors hand-written files.
    let legacyAgentToolsEnabled =
      request.toolGroupNames.map {
        $0.contains(Self.agentToolGroup.id)
          || $0.contains(Self.agentToolGroup.catalogID)
          || Self.agentToolNames.isSubset(of: request.toolNames)
      } ?? true
    let agentToolsEnabled = Self.agentToolNames.contains {
      request.toolPolicy.mode(
        for: $0, in: [Self.agentToolGroup], enabled: legacyAgentToolsEnabled,
        useToolProxy: request.useToolProxy, exposedTools: request.proxyExposedTools) != .disabled
    }
    if agentToolsEnabled, delegating || !offeredAgents.isEmpty {
      let canStart =
        request.limits.maxSubagents > 0
        && depth < request.limits.maxSubagentDepth
        && (delegating || !offeredAgents.isEmpty)
      definitions.append(
        contentsOf:
          agentToolDefinitions(allowedAgentNames: offeredAgents, delegating: delegating)
          .filter { canStart || $0.name != Self.agentStartToolName })
    }
    return definitions.filter { definition in
      (request.restrictedToolNames?.contains(definition.name) ?? true)
        && (!Self.agentToolNames.contains(definition.name)
          || request.toolPolicy.mode(
            for: definition.name, in: [Self.agentToolGroup], enabled: legacyAgentToolsEnabled,
            useToolProxy: request.useToolProxy, exposedTools: request.proxyExposedTools)
            != .disabled)
    }
  }

  private func agentToolDefinitions(
    allowedAgentNames: Set<String>,
    delegating: Bool
  ) -> [ToolDefinition] {
    let offered = allowedAgentNames.map { name -> AgentProcessTools.OfferedAgent in
      guard let agent = agents[name] else { return AgentProcessTools.OfferedAgent(id: name) }
      let purpose =
        agent.description.isEmpty
        ? (agent.displayName == name ? "" : agent.displayName) : agent.description
      return AgentProcessTools.OfferedAgent(id: name, purpose: purpose)
    }
    return AgentProcessTools.definitions(
      offering: offered, delegating: delegating, planFirst: plansBeforeDelegating)
  }
}
