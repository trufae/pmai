import Foundation
import MaiCore

/// Saved profiles and the chat's independently editable copy.
public struct ACPAgentProfiles: Codable, Sendable {
  public var agents: [AgentDefinition]
  public var current: AgentDefinition
}
