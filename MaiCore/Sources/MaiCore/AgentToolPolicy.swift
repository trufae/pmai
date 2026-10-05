import Foundation

/// Presentation and availability are separate from a tool's approval policy.
/// Direct and proxied tools use the same validation, approvals, and executor.
public enum AgentToolMode: String, Codable, CaseIterable, Sendable {
  case direct
  case proxy
  case disabled
}

/// Per-agent overrides. Exact tool names win over groups; qualified group
/// identifiers win over short names. Entries survive catalog refreshes, so a
/// disabled member stays disabled when an enabled group gains new tools.
public struct AgentToolPolicy: Codable, Equatable, Sendable {
  /// Promote frequently used inherited proxy tools; explicit overrides always win.
  public var automatic: Bool
  public var groups: [String: AgentToolMode]
  public var tools: [String: AgentToolMode]

  public init(
    automatic: Bool = true, groups: [String: AgentToolMode] = [:], tools: [String: AgentToolMode] = [:]
  ) {
    self.automatic = automatic
    self.groups = groups
    self.tools = tools
  }

  private enum CodingKeys: String, CodingKey { case automatic, groups, tools }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
    groups = try values.decodeIfPresent([String: AgentToolMode].self, forKey: .groups) ?? [:]
    tools = try values.decodeIfPresent([String: AgentToolMode].self, forKey: .tools) ?? [:]
  }

  public func mode(
    for name: String,
    in catalog: [ToolGroupDefinition],
    enabled: Bool,
    useToolProxy: Bool,
    exposedTools: Set<String>? = nil
  ) -> AgentToolMode {
    if let mode = override(for: name, in: catalog) { return mode }
    guard enabled else { return .disabled }
    return Self.defaultMode(for: name, useToolProxy: useToolProxy, exposedTools: exposedTools)
  }

  public func override(for name: String, in catalog: [ToolGroupDefinition]) -> AgentToolMode? {
    if let mode = tools[name] { return mode }
    let membership = catalog.filter { $0.toolNames.contains(name) }.sorted {
      $0.catalogID < $1.catalogID
    }
    for group in membership {
      if let mode = groups[group.catalogID] { return mode }
    }
    for group in membership where group.sourceID != "mcp" {
      if let mode = groups[group.id] { return mode }
    }
    // `mcp` controls all servers; `mcp/SERVER` controls just one.
    if membership.contains(where: { $0.sourceID == "mcp" }), let mode = groups["mcp"] {
      return mode
    }
    return nil
  }

  public func modes(
    for names: Set<String>, in catalog: [ToolGroupDefinition], enabledNames: Set<String>,
    useToolProxy: Bool, exposedTools: Set<String>? = nil, usage: AgentToolUsage = .init()
  ) -> [String: AgentToolMode] {
    var result = Dictionary(uniqueKeysWithValues: names.map { name in
      (name, mode(for: name, in: catalog, enabled: enabledNames.contains(name),
                  useToolProxy: useToolProxy, exposedTools: exposedTools))
    })
    if automatic && useToolProxy && exposedTools == nil {
      let eligible = Set(names.filter {
        result[$0] == .proxy && override(for: $0, in: catalog) == nil
      })
      for name in usage.promotedTools(among: eligible) { result[name] = .direct }
    }
    return result
  }

  public static func defaultMode(
    for name: String, useToolProxy: Bool, exposedTools: Set<String>? = nil
  ) -> AgentToolMode {
    !useToolProxy || (exposedTools ?? ToolProxy.defaultExposedNames).contains(name)
      ? .direct : .proxy
  }
}

extension AgentDefinition {
  /// The effective state shown by hosts. Connected MCP servers are available
  /// by default, while ordinary tools and skills follow the agent's allowlist.
  public func toolMode(
    for name: String, in groups: [ToolGroupDefinition], usage: AgentToolUsage = .init()
  ) -> AgentToolMode {
    toolModes(in: groups, usage: usage)[name] ?? .disabled
  }

  public func toolModes(
    in groups: [ToolGroupDefinition], usage: AgentToolUsage = .init()
  ) -> [String: AgentToolMode] {
    var enabled = toolNames
    for group in groups where group.sourceID == "mcp"
      || toolGroupNames.contains(group.id) || toolGroupNames.contains(group.catalogID)
    { enabled.formUnion(group.toolNames) }
    return toolPolicy.modes(
      for: Set(groups.flatMap(\.toolNames)).union(toolNames), in: groups, enabledNames: enabled,
      useToolProxy: useToolProxy, exposedTools: proxyExposedTools, usage: usage)
  }

  public mutating func setToolMode(_ mode: AgentToolMode?, for name: String) {
    toolPolicy.tools[name] = mode
  }

  public mutating func setToolGroupMode(_ mode: AgentToolMode?, for group: ToolGroupDefinition) {
    // MCP IDs are qualified so a GitHub server cannot shadow the native group.
    let key = group.sourceID == "mcp" ? group.catalogID : group.id
    toolPolicy.groups[group.catalogID] = nil
    toolPolicy.groups[key] = mode
  }
}

extension AgentRequest {
  public var usesToolProxy: Bool {
    useToolProxy || toolPolicy.tools.values.contains(.proxy) || toolPolicy.groups.values.contains(.proxy)
  }
}
