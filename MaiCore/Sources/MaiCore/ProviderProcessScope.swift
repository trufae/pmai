import Foundation

/// Agent providers register their native children in the same process table.
public struct ProviderProcessScope: Sendable {
  @TaskLocal public static var current: ProviderProcessScope?
  public let supervisor: AgentSupervisor
  public let context: AgentEventContext
  public let provider: ProviderID
  public let emit: AgentEventHandler
  private let diagnostic: @Sendable (String, [String: JSONValue]) async -> Void

  public init(supervisor: AgentSupervisor, context: AgentEventContext, provider: ProviderID,
    emit: @escaping AgentEventHandler,
    diagnostic: @escaping @Sendable (String, [String: JSONValue]) async -> Void = { _, _ in }) {
    self.supervisor = supervisor
    self.context = context
    self.provider = provider
    self.emit = emit
    self.diagnostic = diagnostic
  }

  public func reportTransport(_ phase: String, details: [String: JSONValue] = [:], activity: String? = nil) async {
    await diagnostic(phase, details)
    if let activity, let pid = context.pid { await supervisor.note(pid, activity: activity) }
  }
}
