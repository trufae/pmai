import Foundation

/// A host-independent projection of discovery and policy for CLI and GUI lists.
/// Membership and counts come from the catalog, never from a second tool list.
public struct AgentToolCatalog: Sendable {
  public var groups: [ToolGroupDefinition]
  public var tools: [ToolDefinition]
  public var modes: [String: AgentToolMode]

  public init(
    groups: [ToolGroupDefinition], tools: [ToolDefinition], modes: [String: AgentToolMode],
    internetAccess: InternetAccessPolicy = .init()
  ) {
    self.groups = groups
    var seen = Set<String>()
    self.tools = tools.filter { seen.insert($0.name).inserted }
    self.modes = internetAccess.restricting(modes, tools: self.tools, groups: groups)
  }

  public var enabledDefinitions: [ToolDefinition] {
    tools.filter { modes[$0.name, default: .disabled] != .disabled }
  }

  /// Definitions eligible for model discovery; hidden tools remain enabled.
  public var listedDefinitions: [ToolDefinition] {
    enabledDefinitions.filter { modes[$0.name] != .hidden }
  }

  public var visibleDefinitions: [ToolDefinition] {
    ToolProxy.definitions(
      for: enabledDefinitions,
      exposing: Set(modes.compactMap { $0.value == .direct ? $0.key : nil }),
      hiding: Set(modes.compactMap { $0.value == .hidden ? $0.key : nil }))
  }

  /// Proxy visibility saves prompt space; it does not disable direct execution.
  public var callableDefinitions: [ToolDefinition] {
    let enabled = enabledDefinitions
    let names = Set(enabled.map(\.name))
    return enabled + visibleDefinitions.filter { !names.contains($0.name) }
  }

  public func definitions(in group: ToolGroupDefinition) -> [ToolDefinition] {
    tools.filter { group.toolNames.contains($0.name) }.sorted { $0.name < $1.name }
  }

  public func summary(for group: ToolGroupDefinition? = nil) -> AgentToolModeSummary {
    AgentToolModeSummary(
      names: group?.toolNames ?? Set(tools.map(\.name)), modes: modes)
  }
}

public struct AgentToolModeSummary: Equatable, Sendable {
  public var direct = 0
  public var proxy = 0
  public var hidden = 0
  public var disabled = 0

  public init(names: Set<String>, modes: [String: AgentToolMode]) {
    for name in names {
      switch modes[name, default: .disabled] {
      case .direct: direct += 1
      case .proxy: proxy += 1
      case .hidden: hidden += 1
      case .disabled: disabled += 1
      }
    }
  }

  public var enabled: Int { direct + proxy + hidden }
  public var total: Int { enabled + disabled }
  public var description: String {
    "\(direct) direct, \(proxy) proxy, \(hidden) hidden, \(disabled) disabled"
  }
}
