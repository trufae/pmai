import Foundation

/// Agent providers expose these per-turn tools over their native transport.
/// The closure is scoped to the run so background requests cannot outlive it.
public enum ProviderToolScope {
  public typealias Handler = @Sendable (ToolCall) async throws -> ToolResult
  @TaskLocal public static var execute: Handler?
}
