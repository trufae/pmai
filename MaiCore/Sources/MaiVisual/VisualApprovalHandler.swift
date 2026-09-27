import Foundation
import MaiCore

/// Routes interactive tool approvals to the visual workspace while it owns the
/// terminal. Hosts install it as the delegate of their usual approval handler
/// and detach it when the workspace exits; pending requests are then denied.
public actor VisualApprovalHandler: ApprovalHandler {
  public struct Pending: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let request: ApprovalRequest
  }

  public struct PendingCompaction: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let request: AutocompactionRequest
  }

  private var compactionPresenter: (@Sendable (PendingCompaction) async -> Void)?
  private var compactionDismiss: (@Sendable (UUID) async -> Void)?
  private var compactions: [UUID: AsyncThrowingStream<AutocompactionDecision, any Error>.Continuation] = [:]

  private var presenter: (@Sendable (Pending) async -> Void)?
  private var continuations: [UUID: CheckedContinuation<ApprovalDecision, any Error>] = [:]
  private let onAlwaysApprove: @Sendable () async -> Void
  private var alwaysApproves = false

  public init(onAlwaysApprove: @escaping @Sendable () async -> Void = {}) {
    self.onAlwaysApprove = onAlwaysApprove
  }

  public var pendingCount: Int { continuations.count }

  func attach(presenter: @escaping @Sendable (Pending) async -> Void) {
    self.presenter = presenter
  }

  func detach() {
    presenter = nil
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting.values {
      continuation.resume(returning: .deny(reason: "Visual mode ended before the approval."))
    }
    compactionPresenter = nil
    compactionDismiss = nil
    let pending = compactions
    compactions.removeAll()
    for continuation in pending.values { continuation.finish(throwing: CancellationError()) }
  }

  func attachCompaction(
    presenter: @escaping @Sendable (PendingCompaction) async -> Void,
    dismiss: @escaping @Sendable (UUID) async -> Void
  ) {
    compactionPresenter = presenter
    compactionDismiss = dismiss
  }

  public func decideCompaction(_ request: AutocompactionRequest) async throws -> AutocompactionDecision {
    guard let compactionPresenter else { return .cancelRun }
    let dismiss = compactionDismiss
    let pending = PendingCompaction(id: UUID(), request: request)
    let (stream, continuation) = AsyncThrowingStream<AutocompactionDecision, any Error>.makeStream()
    compactions[pending.id] = continuation
    await compactionPresenter(pending)
    do {
      var iterator = stream.makeAsyncIterator()
      let decision = try await iterator.next()
      compactions[pending.id] = nil
      await dismiss?(pending.id)
      try Task.checkCancellation()
      return decision ?? .cancelRun
    } catch {
      compactions[pending.id] = nil
      await dismiss?(pending.id)
      throw error
    }
  }

  public func resolveCompaction(_ id: UUID, with decision: AutocompactionDecision) {
    guard let continuation = compactions.removeValue(forKey: id) else { return }
    continuation.yield(decision)
    continuation.finish()
  }

  public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    if alwaysApproves {
      return .approve(arguments: request.call.arguments)
    }
    guard let presenter else {
      return .deny(reason: "No interactive approval surface is available.")
    }
    let pending = Pending(id: UUID(), request: request)
    return try await withCheckedThrowingContinuation { continuation in
      continuations[pending.id] = continuation
      Task { await presenter(pending) }
    }
  }

  /// Completes a pending request. Unknown identifiers are ignored so a dismissed
  /// sheet can safely deny a request that was already answered.
  public func resolve(_ id: UUID, with decision: ApprovalDecision) {
    continuations.removeValue(forKey: id)?.resume(returning: decision)
  }

  /// Enables automatic approval and approves every request already visible or queued.
  public func resolveAlways(_ pending: [Pending]) async {
    alwaysApproves = true
    await onAlwaysApprove()
    for item in pending {
      continuations.removeValue(forKey: item.id)?.resume(
        returning: .approve(arguments: item.request.call.arguments))
    }
  }
}
