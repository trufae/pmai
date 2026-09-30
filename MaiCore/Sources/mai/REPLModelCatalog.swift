import Foundation
import MaiCore

/// Model discovery never waits on the input thread. Tab reads the latest
/// catalog, including a /models result that arrived while editing this line.
final class REPLModelCatalog: @unchecked Sendable {
  private let lock = NSLock()
  private var currentProvider: ProviderID = .openAI
  private var models: [ProviderID: [ModelDescriptor]] = [:]
  private var pending: [ProviderID: Task<Void, Never>] = [:]
  private var retryAfter: [ProviderID: Date] = [:]

  func select(_ provider: ProviderID, runtime: AgentRuntime) {
    lock.withLock { currentProvider = provider }
    prefetch(provider, runtime: runtime)
  }

  /// Explicit listings replace the cache; an older background fetch must
  /// never overwrite the catalog the person just saw.
  func store(_ catalog: [ModelDescriptor], for provider: ProviderID) {
    lock.withLock {
      models[provider] = catalog
      pending.removeValue(forKey: provider)?.cancel()
      retryAfter[provider] = nil
    }
  }

  func cancel() {
    lock.withLock {
      for task in pending.values { task.cancel() }
      pending.removeAll()
    }
  }

  func completions(for line: String, runtime: AgentRuntime) -> [String] {
    guard
      let prefix = ["/model-compact ", "/model-tool ", "/model-aproval ", "/model "].first(where: {
        line.hasPrefix($0)
      }) else { return [] }
    let current = lock.withLock { currentProvider }
    let selector = String(line.dropFirst(prefix.count))
    let provider = selector.range(of: "::").map {
      ProviderID(String(selector[..<$0.lowerBound]))
    } ?? current
    prefetch(provider, runtime: runtime)
    let catalogs = lock.withLock { models }
    return catalogs.flatMap { id, catalog in
      catalog.flatMap { model in
        let qualified = prefix + id.rawValue + "::" + model.id
        return id == current ? [prefix + model.id, qualified] : [qualified]
      }
    }
  }

  private func prefetch(_ provider: ProviderID, runtime: AgentRuntime) {
    lock.withLock {
      guard models[provider] == nil, pending[provider] == nil,
        retryAfter[provider].map({ $0 <= Date() }) ?? true
      else { return }
      pending[provider] = Task { [weak self] in
        let catalog = try? await runtime.availableModels(provider: provider)
        guard !Task.isCancelled, let self else { return }
        self.lock.withLock {
          guard self.pending.removeValue(forKey: provider) != nil else { return }
          if let catalog {
            self.models[provider] = catalog
          } else {
            // Silent discovery failures must not cause a request per keypress.
            self.retryAfter[provider] = Date().addingTimeInterval(30)
          }
        }
      }
    }
  }
}
