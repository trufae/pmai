import Foundation

/// Network availability is transient; the user's airplane setting is durable.
public struct InternetAccessPolicy: Equatable, Sendable {
  public var airplaneModeEnabled: Bool
  public var networkAvailable: Bool

  public init(airplaneModeEnabled: Bool = false, networkAvailable: Bool = true) {
    self.airplaneModeEnabled = airplaneModeEnabled
    self.networkAvailable = networkAvailable
  }

  public var isOffline: Bool { airplaneModeEnabled || !networkAvailable }

  public mutating func setAirplaneMode(_ enabled: Bool) { airplaneModeEnabled = enabled }
  public mutating func toggleAirplaneMode() { airplaneModeEnabled.toggle() }

  public func allows(_ source: any MCPToolSource) -> Bool {
    !isOffline || !source.requiresInternet
  }

  public func allows(_ tool: ToolDefinition, in groups: [ToolGroupDefinition] = []) -> Bool {
    !isOffline
      || (!tool.annotations.requiresInternet
        && !groups.contains {
          $0.networkRequirement == .internet && $0.toolNames.contains(tool.name)
        })
  }

  public func restricting(
    _ modes: [String: AgentToolMode], tools: [ToolDefinition], groups: [ToolGroupDefinition] = []
  ) -> [String: AgentToolMode] {
    guard isOffline else { return modes }
    var modes = modes
    let blocked = Set(groups.filter { $0.networkRequirement == .internet }.flatMap(\.toolNames))
      .union(tools.filter { $0.annotations.requiresInternet }.map(\.name))
    for name in blocked { modes[name] = .disabled }
    return modes
  }
}

public enum InternetAccessError: LocalizedError {
  case offline
  public var errorDescription: String? { "Internet access is disabled while offline." }
}
