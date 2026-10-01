/// The transport boundary between MaiCore's agent runtime and a model backend.
///
/// Implementations translate the provider-neutral request and event types into
/// their native protocol. They must not depend on a UI, conversation store, or
/// host-specific settings model.
/// An error a provider can throw when the model produced neither text nor a
/// tool call. A run in the middle of a tool loop treats it as a turn to
/// repair with feedback, not as a failure to retry and then give up on.
public protocol ProviderEmptyResponseError: Error {}

/// A malformed model tool call needs corrective feedback, not a transport retry.
/// Nil leaves unrelated cases of a provider's error type on the normal error path.
public protocol ProviderToolCallError: Error {
  var toolCallRepairMessage: String? { get }
}

public protocol ChatProvider: Sendable {
  /// Stable identity and features used by the runtime for capability routing.
  var descriptor: ProviderDescriptor { get }

  /// Returns the provider's current model catalog, or an empty list when the
  /// backend cannot enumerate models.
  func availableModels() async throws -> [ModelDescriptor]

  /// Completes one provider turn. Streaming implementations emit incremental
  /// events while the returned response remains the authoritative final value.
  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse
}

extension ChatProvider {
  public func availableModels() async throws -> [ModelDescriptor] { [] }

  public func complete(_ request: ProviderRequest) async throws -> ProviderResponse {
    try await complete(request) { _ in }
  }
}
