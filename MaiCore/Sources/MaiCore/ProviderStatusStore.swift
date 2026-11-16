import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Fetches a configured provider's limits at a person's request and caches the
/// answer, so the REPL, an ACP client, and a phone host all read the same one
/// and none of them polls the provider more than once a minute (the endpoint
/// allows ten requests a minute across every key and device).
public final class ProviderStatusStore: @unchecked Sendable {
  /// How long a fetched status is reused. Ollama recommends polling at most
  /// once a minute and its usage also lags behind the requests.
  public static let defaultMinimumAge: TimeInterval = 60

  private let lock = NSLock()
  private var cached: MaiProviderStatus?
  private var fetchedAt: Date?
  private let minimumAge: TimeInterval

  public init(minimumAge: TimeInterval = ProviderStatusStore.defaultMinimumAge) {
    self.minimumAge = minimumAge
  }

  public func cachedStatus() -> MaiProviderStatus? {
    lock.withLock { cached }
  }

  /// The cached status when it is fresh enough, the provider's answer
  /// otherwise. A provider without a status endpoint reports nil.
  public func status(
    for provider: ConfiguredProvider,
    model: String? = nil,
    refresh: Bool = false,
    now: Date = Date(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    session: URLSession = .shared
  ) async throws -> MaiProviderStatus? {
    let fresh = lock.withLock { () -> MaiProviderStatus? in
      guard !refresh, let cached, let fetchedAt,
        now.timeIntervalSince(fetchedAt) < minimumAge, cached.provider == provider.id
      else { return nil }
      return cached
    }
    if let fresh { return fresh }
    let status = try await MaiProviderStatusService.status(
      for: provider, model: model, environment: environment, session: session)
    lock.withLock {
      cached = status
      fetchedAt = Date()
    }
    return status
  }
}

/// The settings the CLI last adopted, read by the `provider_status` tool after
/// a command changes the provider or its key. A tool runs off the actor and
/// cannot touch the REPL's copy.
public final class ConfigurationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: MaiConfiguration?

  public init(_ value: MaiConfiguration? = nil) { stored = value }

  public var value: MaiConfiguration? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
