import Foundation
import MaiCore

/// Accumulates token usage and generation speed per provider/model across the
/// whole app. Providers report every completed model call (chat turns, tool-loop
/// rounds, title generation), so totals reflect real consumption. The arithmetic
/// and the persistence are MaiCore's `ModelUsageLedger` and
/// `UserDefaultsModelUsagePersistence`, the same code behind the pmai REPL's
/// `/stats`; this store adds the main-actor publishing SwiftUI needs and the
/// per-message stats kept briefly so the tool loop can stamp them onto the
/// assistant message before it is persisted.
@MainActor
final class UsageStatsStore: ObservableObject {
  static let shared = UsageStatsStore()

  typealias ModelTotals = ModelUsageTotals

  @Published private(set) var ledger: ModelUsageLedger
  private(set) var contexts: [UUID: ChatContextSnapshot] = [:]
  @Published private(set) var contextRevision = 0
  @Published private(set) var quota: MaiProviderStatus?
  private let quotaStore = ProviderStatusStore()
  private var quotaChecked: (endpoint: OpenAIEndpoint, date: Date)?

  func refreshQuota(conversation: Conversation, settings: AppSettings) async {
    guard !settings.isOffline, conversation.provider == .openAICompatible,
      let endpoint = OpenAICompatibleProvider.selectedEndpoint(for: conversation, settings: settings)
    else { return }
    guard quotaChecked?.endpoint != endpoint
      || Date().timeIntervalSince(quotaChecked?.date ?? .distantPast) >= 60 else { return }
    let changed = quotaChecked?.endpoint != endpoint
    if changed { quota = nil }
    quotaChecked = (endpoint, Date())
    let configuration = ConfiguredProvider(id: endpoint.id.uuidString, kind: endpoint.kind,
      displayName: endpoint.name, baseURL: URL(string: endpoint.baseURL), apiKey: endpoint.apiKey,
      headers: endpoint.effectiveHeaders)
    let status = try? await quotaStore.status(for: configuration, model: conversation.modelID, refresh: changed)
    guard quotaChecked?.endpoint == endpoint else { return }
    guard !Task.isCancelled else { quotaChecked = nil; return }
    quota = status
  }

  struct ChatContextSnapshot {
    var usage: ContextUsage
    var request: ChatCompletionRequest
    var assistantText: String? = nil

    func matches(_ conversation: Conversation, settings: AppSettings) -> Bool {
      let source = request.conversation
      return conversation.messages.contains(where: {
        $0.id == request.assistantMessageID && (assistantText == nil || $0.text.hasSuffix(assistantText ?? ""))
      })
        && source.provider == conversation.provider && source.modelID == conversation.modelID
        && source.endpointID == conversation.endpointID && request.settings == settings
        && source.contextWindowMode == conversation.contextWindowMode
        && source.contextWindowTokens == conversation.contextWindowTokens
        && source.mlxMaxKVSize == conversation.mlxMaxKVSize
        && source.systemPromptID == conversation.systemPromptID
        && source.reasoningLevel == conversation.reasoningLevel
        && source.toolSelection == conversation.toolSelection
        && source.toolsEnabled == conversation.toolsEnabled
        && source.toolCallingMode == conversation.toolCallingMode
        && Self.evidence(source, excluding: request.assistantMessageID)
          == Self.evidence(conversation, excluding: request.assistantMessageID)
    }

    private static func evidence(_ conversation: Conversation, excluding id: UUID) -> [ChatMessage] {
      conversation.messages.filter { $0.id != id }.compactMap(\.contextVersion)
    }
  }

  static func recordContext(_ usage: ContextUsage, request: ChatCompletionRequest, assistantText: String? = nil) {
    if case .followUpSuggestions = request.oneShotResponseFormat { return }
    // Auxiliary title/summary calls have transient conversation IDs. Retain only
    // a bounded set; this is live telemetry, never a duplicate durable history.
    if shared.contexts[request.conversation.id] == nil, shared.contexts.count >= 8 {
      shared.contexts.removeAll()
    }
    var snapshotRequest = request
    snapshotRequest.context = ""
    snapshotRequest.nativeContinuationMessages = []
    snapshotRequest.nativeTools = nil
    snapshotRequest.toolPrompt = ""
    shared.contexts[request.conversation.id] = .init(usage: usage, request: snapshotRequest, assistantText: assistantText)
    shared.contextRevision &+= 1
  }


  var totals: [ModelTotals] { ledger.totals }

  private var pendingByMessageID: [UUID: GenerationStats] = [:]
  private var pendingOrder: [UUID] = []
  private static let pendingLimit = 64
  /// The key every release has stored the totals under; the ledger reads the
  /// numeric dates earlier releases wrote as well as the ISO 8601 dates now.
  private static let persistence = UserDefaultsModelUsagePersistence(key: "usageStats.totals.v1")

  private init() {
    ledger = (try? Self.persistence.load()) ?? ModelUsageLedger()
  }

  static func record(_ stats: GenerationStats, assistantMessageID: UUID?) {
    shared.record(stats, assistantMessageID: assistantMessageID)
  }

  func record(_ stats: GenerationStats, assistantMessageID: UUID?) {
    guard ledger.record(stats) != nil else { return }
    persistLedger()

    if let assistantMessageID {
      if var pending = pendingByMessageID[assistantMessageID] {
        pending.merge(stats)
        pendingByMessageID[assistantMessageID] = pending
      } else {
        pendingByMessageID[assistantMessageID] = stats
        pendingOrder.append(assistantMessageID)
        if pendingOrder.count > Self.pendingLimit {
          pendingByMessageID.removeValue(forKey: pendingOrder.removeFirst())
        }
      }
    }
  }

  /// Accumulated stats for an assistant message across all tool-loop rounds so far.
  func pendingStats(for messageID: UUID) -> GenerationStats? {
    pendingByMessageID[messageID]
  }

  func reset() {
    ledger.reset()
    persistLedger()
  }

  /// Drops one model (its row id) or every model of a provider (its label).
  func remove(matching target: String) {
    ledger.remove(matching: target)
    persistLedger()
  }

  private func persistLedger() {
    try? Self.persistence.save(ledger)
  }
}
