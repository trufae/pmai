import Foundation

/// Agent providers register their native children in the same process table.
public struct ProviderProcessScope: Sendable {
  @TaskLocal public static var current: ProviderProcessScope?
  public let supervisor: AgentSupervisor
  public let context: AgentEventContext
  public let provider: ProviderID
  public let emit: AgentEventHandler

  public init(supervisor: AgentSupervisor, context: AgentEventContext, provider: ProviderID, emit: @escaping AgentEventHandler) {
    self.supervisor = supervisor
    self.context = context
    self.provider = provider
    self.emit = emit
  }
}
