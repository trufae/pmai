import Foundation

// MARK: - Timing

/// Wall-clock observations collected while one streamed provider call is read.
/// Chunk timestamps are recorded so the timing resolver can tell a genuinely
/// paced stream apart from a whole response delivered in one network burst.
public struct StreamTimingObservation: Equatable, Sendable {
  public var requestStart: Date
  public var firstTokenAt: Date?
  public var lastTokenAt: Date?
  public var tokenChunkCount: Int

  public init(
    requestStart: Date = Date(),
    firstTokenAt: Date? = nil,
    lastTokenAt: Date? = nil,
    tokenChunkCount: Int = 0
  ) {
    self.requestStart = requestStart
    self.firstTokenAt = firstTokenAt
    self.lastTokenAt = lastTokenAt
    self.tokenChunkCount = tokenChunkCount
  }

  public mutating func noteTokenChunk(at date: Date = Date()) {
    if firstTokenAt == nil { firstTokenAt = date }
    lastTokenAt = date
    tokenChunkCount += 1
  }
}

/// Timing split derived from a `StreamTimingObservation` once a call finishes.
public struct ResolvedGenerationTiming: Equatable, Sendable {
  public var promptSeconds: TimeInterval
  public var generationSeconds: TimeInterval
  /// Seconds from sending the request until the first streamed token arrived.
  /// Nil when the response was not streamed.
  public var firstTokenSeconds: TimeInterval?

  public init(
    promptSeconds: TimeInterval,
    generationSeconds: TimeInterval,
    firstTokenSeconds: TimeInterval?
  ) {
    self.promptSeconds = promptSeconds
    self.generationSeconds = generationSeconds
    self.firstTokenSeconds = firstTokenSeconds
  }
}

/// Collects `StreamTimingObservation` from a provider's event callback, which
/// may run on any executor, so the observation can be read once the call ends.
public final class StreamTimingRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: StreamTimingObservation

  public init(requestStart: Date = Date()) {
    stored = StreamTimingObservation(requestStart: requestStart)
  }

  public func noteTokenChunk(at date: Date = Date()) {
    lock.withLock { stored.noteTokenChunk(at: date) }
  }

  /// Counts every event that carries generated content; usage payloads are
  /// bookkeeping the model did not generate and never move the window.
  public func note(_ event: ProviderEvent, at date: Date = Date()) {
    switch event {
    case .textDelta, .reasoningDelta, .toolCallDelta: noteTokenChunk(at: date)
    case .usage: break
    }
  }

  public var observation: StreamTimingObservation {
    lock.withLock { stored }
  }

  public func resolve(end: Date = Date()) -> ResolvedGenerationTiming {
    ModelCallStats.resolveTiming(observation, end: end)
  }
}

// MARK: - One call

/// Metrics for one or more model calls behind an assistant message. Token counts
/// come from provider usage payloads (OpenAI-compatible `usage`, MLX completion
/// info); `tokensEstimated` marks backends that only expose text, where counts
/// are derived from character length (~4 chars/token). The property names are
/// the persisted JSON keys, shared by every host that stores these.
public struct ModelCallStats: Codable, Equatable, Sendable {
  public var providerLabel: String
  public var modelID: String
  public var inputTokens: Int
  /// Estimated tokens in the user-authored message(s) for this turn only.
  public var userInputTokens: Int?
  /// Provider completion total, including hidden reasoning when reported that way.
  public var outputTokens: Int
  /// Estimated tokens in response text actually received, excluding hidden reasoning.
  public var receivedTextTokens: Int?
  /// Provider-reported hidden reasoning tokens, when the backend exposes them.
  public var reasoningTokens: Int?
  /// Number of image inputs actually sent to a vision-capable provider.
  public var imageInputs: Int?
  public var cachedTokens: Int
  /// Prompt processing (local inference) or time to first streamed token
  /// (network providers). Zero when the response arrived as one burst and the
  /// split is unknowable.
  public var promptSeconds: TimeInterval
  public var generationSeconds: TimeInterval
  /// Seconds until the provider emitted the first token of the response. Nil for
  /// non-streaming calls, where no first-token signal exists.
  public var firstTokenSeconds: TimeInterval?
  public var tokensEstimated: Bool
  public var callCount: Int

  public init(
    providerLabel: String,
    modelID: String,
    inputTokens: Int = 0,
    userInputTokens: Int? = nil,
    outputTokens: Int = 0,
    receivedTextTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    imageInputs: Int? = nil,
    cachedTokens: Int = 0,
    promptSeconds: TimeInterval = 0,
    generationSeconds: TimeInterval = 0,
    firstTokenSeconds: TimeInterval? = nil,
    tokensEstimated: Bool = false,
    callCount: Int = 1
  ) {
    self.providerLabel = providerLabel
    self.modelID = modelID
    self.inputTokens = inputTokens
    self.userInputTokens = userInputTokens
    self.outputTokens = outputTokens
    self.receivedTextTokens = receivedTextTokens
    self.reasoningTokens = reasoningTokens
    self.imageInputs = imageInputs
    self.cachedTokens = cachedTokens
    self.promptSeconds = promptSeconds
    self.generationSeconds = generationSeconds
    self.firstTokenSeconds = firstTokenSeconds
    self.tokensEstimated = tokensEstimated
    self.callCount = callCount
  }

  /// Approximate tokens in the answer the user received. Some local servers
  /// include unreported thinking in completion_tokens, so that total cannot
  /// stand in for displayed text. Keep the provider's count as an upper bound.
  public var visibleOutputTokens: Int {
    let reportedVisible = max(0, outputTokens - (reasoningTokens ?? 0))
    return receivedTextTokens.map { min($0, reportedVisible) } ?? reportedVisible
  }

  public var visibleOutputTokensEstimated: Bool {
    guard let receivedTextTokens else { return tokensEstimated }
    return tokensEstimated || receivedTextTokens < max(0, outputTokens - (reasoningTokens ?? 0))
  }

  public var tokensPerSecond: Double? {
    guard visibleOutputTokens > 0, generationSeconds > 0 else { return nil }
    return Double(visibleOutputTokens) / generationSeconds
  }

  public var promptTokensPerSecond: Double? {
    guard inputTokens > 0, promptSeconds > 0, !tokensEstimated else { return nil }
    return Double(inputTokens) / promptSeconds
  }

  /// Seconds the model was busy with this call: waiting for the first token
  /// plus streaming the rest.
  public var totalSeconds: TimeInterval { promptSeconds + generationSeconds }

  /// What a message footer says about the call(s) behind it:
  /// `42.1 tok/s · first tok 0.85s · ~1.2k in · 300 cached · ~450 out · 3 calls`.
  public var summary: String {
    let approx = tokensEstimated ? "~" : ""
    return [
      tokensPerSecond.map { ModelUsageFormat.speed($0, estimated: visibleOutputTokensEstimated) },
      firstTokenSeconds.map { "first tok \(ModelUsageFormat.seconds($0))" },
      "\(approx)\(ModelUsageFormat.count(inputTokens)) in",
      cachedTokens > 0 ? "\(ModelUsageFormat.count(cachedTokens)) cached" : nil,
      "\(approx)\(ModelUsageFormat.count(outputTokens)) out",
      callCount > 1 ? "\(callCount) calls" : nil,
    ].compactMap { $0 }.joined(separator: " · ")
  }

  /// A stream whose first→last token window is shorter than this never showed
  /// the client any real generation pacing, so the window cannot be a divisor.
  public static let minimumStreamedGenerationSeconds: TimeInterval = 0.2
  /// Below this many observed chunks the whole response arrived in a burst or
  /// two, so first→last chunk timing says nothing about generation speed.
  public static let minimumStreamedTokenChunks = 3

  /// Splits one call's wall time into prompt wait and generation time. Speed is
  /// measured over the first→last received token window, so cold starts and the
  /// trailing usage/[DONE] wait never pollute tok/s. When the body arrived as a
  /// burst (buffered delivery is common on localhost endpoints) that window is
  /// near zero and dividing by it explodes tok/s, so total wall time — an
  /// honest lower bound — is used instead, matching non-streaming calls.
  public static func resolveTiming(
    _ observation: StreamTimingObservation,
    end: Date
  ) -> ResolvedGenerationTiming {
    let totalSeconds = max(0, end.timeIntervalSince(observation.requestStart))
    guard let firstTokenAt = observation.firstTokenAt else {
      return ResolvedGenerationTiming(
        promptSeconds: 0, generationSeconds: totalSeconds, firstTokenSeconds: nil)
    }
    let firstTokenSeconds = max(0, firstTokenAt.timeIntervalSince(observation.requestStart))
    let lastTokenAt = observation.lastTokenAt ?? end
    let streamedSeconds = max(0, lastTokenAt.timeIntervalSince(firstTokenAt))
    guard
      streamedSeconds >= minimumStreamedGenerationSeconds,
      observation.tokenChunkCount >= minimumStreamedTokenChunks
    else {
      return ResolvedGenerationTiming(
        promptSeconds: 0, generationSeconds: totalSeconds, firstTokenSeconds: firstTokenSeconds)
    }
    return ResolvedGenerationTiming(
      promptSeconds: firstTokenSeconds,
      generationSeconds: streamedSeconds,
      firstTokenSeconds: firstTokenSeconds)
  }

  public mutating func merge(_ other: ModelCallStats) {
    providerLabel = other.providerLabel
    modelID = other.modelID
    inputTokens += other.inputTokens
    outputTokens += other.outputTokens
    cachedTokens += other.cachedTokens
    promptSeconds += other.promptSeconds
    generationSeconds += other.generationSeconds
    accumulate(&userInputTokens, other.userInputTokens)
    accumulate(&receivedTextTokens, other.receivedTextTokens)
    accumulate(&reasoningTokens, other.reasoningTokens)
    accumulate(&imageInputs, other.imageInputs)
    // The first round's latency is the one the user felt waiting for output.
    firstTokenSeconds = firstTokenSeconds ?? other.firstTokenSeconds
    tokensEstimated = tokensEstimated || other.tokensEstimated
    callCount += other.callCount
  }

  public static func estimatedTokenCount(forCharacterCount count: Int) -> Int {
    count <= 0 ? 0 : max(1, count / 4)
  }

  /// Estimated tokens of the text carried by a set of messages.
  public static func estimatedTokenCount(of messages: [AgentMessage]) -> Int {
    estimatedTokenCount(forCharacterCount: messages.reduce(0) { $0 + $1.text.count })
  }

  /// The stats of one provider call the runtime just completed. Counts come
  /// from the response's usage when the provider reported any, and are
  /// estimated from text length otherwise.
  public static func measured(
    providerLabel: String,
    modelID: String,
    messages: [AgentMessage],
    response: ProviderResponse,
    timing: StreamTimingObservation,
    end: Date = Date(),
    userInputTokens: Int? = nil
  ) -> ModelCallStats {
    let images = messages.reduce(0) { total, message in
      total
        + message.content.filter {
          if case .image = $0 { return true }
          return false
        }.count
    }
    return measured(
      providerLabel: providerLabel,
      modelID: modelID,
      usage: response.usage,
      estimatedInputTokens: estimatedTokenCount(of: messages),
      outputCharacterCount: response.message.text.count,
      timing: timing,
      end: end,
      userInputTokens: userInputTokens,
      imageInputs: images > 0 ? images : nil)
  }

  /// The stats of one call from what every host has at hand once a call
  /// ends: the provider's usage payload (nil when it reported none), the
  /// input estimate to fall back on, the length of the text received, and
  /// the stream timing. PocketMai's providers and the runtime both go
  /// through here, so a call is measured the same way on every host.
  public static func measured(
    providerLabel: String,
    modelID: String,
    usage: TokenUsage?,
    estimatedInputTokens: Int,
    outputCharacterCount: Int,
    timing: StreamTimingObservation,
    end: Date = Date(),
    userInputTokens: Int? = nil,
    imageInputs: Int? = nil
  ) -> ModelCallStats {
    let resolved = resolveTiming(timing, end: end)
    let receivedTextTokens = estimatedTokenCount(forCharacterCount: outputCharacterCount)
    return ModelCallStats(
      providerLabel: providerLabel,
      modelID: modelID,
      inputTokens: usage?.inputTokens ?? estimatedInputTokens,
      userInputTokens: userInputTokens,
      outputTokens: usage?.outputTokens ?? receivedTextTokens,
      receivedTextTokens: receivedTextTokens,
      reasoningTokens: usage?.reasoningTokens,
      imageInputs: imageInputs,
      cachedTokens: usage?.cachedTokens ?? 0,
      promptSeconds: resolved.promptSeconds,
      generationSeconds: resolved.generationSeconds,
      firstTokenSeconds: resolved.firstTokenSeconds,
      tokensEstimated: usage?.isEstimated ?? true)
  }
}

/// `lhs += rhs` for optional counts: nil stays nil until a value arrives, so
/// a provider that never reports a number never shows a zero for it.
private func accumulate(_ lhs: inout Int?, _ rhs: Int?) {
  if let rhs { lhs = (lhs ?? 0) + rhs }
}

/// `count` when it is positive, else nil, for facts worth a line only then.
private func positive(_ count: Int?) -> Int? {
  count.flatMap { $0 > 0 ? $0 : nil }
}

// MARK: - Lifetime totals

/// Running totals for one provider/model pair across every call a host made.
/// Average speed is visible output tokens divided by total generation seconds,
/// so hidden reasoning does not inflate it. The property names are the
/// persisted JSON keys; the optional ones are absent from rows persisted
/// before they existed and from providers that never report them.
public struct ModelUsageTotals: Codable, Identifiable, Equatable, Sendable {
  public var providerLabel: String
  public var modelID: String
  public var inputTokens = 0
  /// Estimated tokens in user-authored messages, excluding resent context.
  public var userInputTokens: Int?
  public var outputTokens = 0
  /// Estimated tokens in response text received, excluding hidden reasoning.
  public var receivedTextTokens: Int?
  public var reasoningTokens: Int?
  public var imageInputs: Int?
  public var cachedTokens = 0
  public var promptSeconds: TimeInterval = 0
  public var generationSeconds: TimeInterval = 0
  public var callCount = 0
  public var estimatedCallCount = 0
  /// Speed of the most recent call, over visible output tokens.
  public var lastOutputTokensPerSecond: Double?
  /// Nil on old ledgers, whose saved last speed used all completion tokens.
  public var lastOutputSpeedEstimated: Bool?
  public var lastFirstTokenSeconds: TimeInterval?
  /// Sum and count of observed first-token latencies, for the average.
  public var firstTokenSecondsTotal: TimeInterval?
  public var firstTokenSampleCount: Int?
  public var lastUsedAt = Date.distantPast

  public init(providerLabel: String, modelID: String) {
    self.providerLabel = providerLabel
    self.modelID = modelID
  }

  public static func id(providerLabel: String, modelID: String) -> String {
    "\(providerLabel)|\(modelID)"
  }

  public var id: String { Self.id(providerLabel: providerLabel, modelID: modelID) }

  /// `provider — model`, or just the provider when the model adds nothing.
  public var title: String {
    modelID.isEmpty || modelID == providerLabel
      ? providerLabel
      : "\(providerLabel) — \(modelID)"
  }

  public var visibleOutputTokens: Int {
    let reportedVisible = max(0, outputTokens - (reasoningTokens ?? 0))
    return receivedTextTokens.map { min($0, reportedVisible) } ?? reportedVisible
  }
  public var visibleOutputTokensEstimated: Bool {
    guard let receivedTextTokens else { return estimatedCallCount > 0 }
    return estimatedCallCount > 0
      || receivedTextTokens < max(0, outputTokens - (reasoningTokens ?? 0))
  }
  public var totalTokens: Int { inputTokens + outputTokens }
  /// Seconds this model has been busy answering: prompt waits plus generation.
  public var totalSeconds: TimeInterval { promptSeconds + generationSeconds }

  public var averageTokensPerSecond: Double? {
    guard visibleOutputTokens > 0, generationSeconds > 0 else { return nil }
    return Double(visibleOutputTokens) / generationSeconds
  }

  public var averagePromptTokensPerSecond: Double? {
    guard inputTokens > 0, promptSeconds > 0, estimatedCallCount == 0 else { return nil }
    return Double(inputTokens) / promptSeconds
  }

  public var averageFirstTokenSeconds: TimeInterval? {
    guard let total = firstTokenSecondsTotal, let count = firstTokenSampleCount, count > 0
    else { return nil }
    return total / Double(count)
  }

  /// The efficiency score `totalTokens / (totalSeconds × callCount)`: how many
  /// tokens each request moved per second the model was in use.
  public var efficiency: Double? {
    Self.efficiency(tokens: totalTokens, seconds: totalSeconds, requests: callCount)
  }

  /// Nil until tokens moved, time passed, and a request was made.
  public static func efficiency(tokens: Int, seconds: TimeInterval, requests: Int) -> Double? {
    guard tokens > 0, seconds > 0, requests > 0 else { return nil }
    return Double(tokens) / (seconds * Double(requests))
  }

  /// Folds one completed call into the totals.
  public mutating func record(_ stats: ModelCallStats, at date: Date = Date()) {
    inputTokens += stats.inputTokens
    outputTokens += stats.outputTokens
    cachedTokens += stats.cachedTokens
    promptSeconds += stats.promptSeconds
    generationSeconds += stats.generationSeconds
    accumulate(&userInputTokens, stats.userInputTokens)
    accumulate(&receivedTextTokens, stats.receivedTextTokens)
    accumulate(&reasoningTokens, stats.reasoningTokens)
    accumulate(&imageInputs, stats.imageInputs)
    callCount += stats.callCount
    if stats.tokensEstimated { estimatedCallCount += stats.callCount }
    lastOutputTokensPerSecond = stats.tokensPerSecond
    lastOutputSpeedEstimated = stats.tokensPerSecond.map { _ in stats.visibleOutputTokensEstimated }
    if let firstTokenSeconds = stats.firstTokenSeconds {
      lastFirstTokenSeconds = firstTokenSeconds
      firstTokenSecondsTotal = (firstTokenSecondsTotal ?? 0) + firstTokenSeconds
      firstTokenSampleCount = (firstTokenSampleCount ?? 0) + 1
    }
    lastUsedAt = date
  }

  /// One line under the model's name with the facts the rankings leave out:
  /// `~1.2k sent · ~3.4k recv · 45 req · 12m34s in use · prompt 800.0 tok/s · first tok 0.85s`.
  public var summary: String {
    (ModelUsageSums([self]).summaryParts
      + [
        averagePromptTokensPerSecond.map { "prompt \(ModelUsageFormat.speed($0))" },
        averageFirstTokenSeconds.map { "first tok \(ModelUsageFormat.seconds($0))" },
      ].compactMap { $0 }).joined(separator: " · ")
  }

  private var lastOutputSpeedText: String? {
    guard let speed = lastOutputTokensPerSecond else { return nil }
    if let estimated = lastOutputSpeedEstimated {
      return ModelUsageFormat.speed(speed, estimated: estimated)
    }
    // Older rows may have saved a last speed inflated by unreported thinking.
    return receivedTextTokens == nil ? ModelUsageFormat.speed(speed) : nil
  }

  /// Everything recorded about the row, one fact per line, for a detail
  /// sheet or `/stats show PROVIDER:MODEL`.
  public var detailLines: [String] {
    let estimated = estimatedCallCount > 0
    let facts: [(String, String?)] = [
      ("Text sent", positive(userInputTokens).map { ModelUsageFormat.tokens($0, estimated: true) }),
      (
        "Text received",
        positive(receivedTextTokens).map { ModelUsageFormat.tokens($0, estimated: true) }
      ),
      ("Prompt tokens", ModelUsageFormat.tokens(inputTokens, estimated: estimated)),
      ("Completion tokens", ModelUsageFormat.tokens(outputTokens, estimated: estimated)),
      ("Thinking tokens", positive(reasoningTokens).map { ModelUsageFormat.tokens($0) }),
      ("Images sent", positive(imageInputs).map(String.init)),
      ("Cached tokens", positive(cachedTokens).map { ModelUsageFormat.tokens($0) }),
      ("Requests", String(callCount)),
      ("Estimated counts", estimated ? "\(estimatedCallCount) req" : nil),
      ("Average output speed", averageTokensPerSecond.map {
        ModelUsageFormat.speed($0, estimated: visibleOutputTokensEstimated)
      }),
      ("Last output speed", lastOutputSpeedText),
      ("Prompt processing speed", averagePromptTokensPerSecond.map(ModelUsageFormat.speed)),
      ("Last time to first token", lastFirstTokenSeconds.map(ModelUsageFormat.seconds)),
      ("Average time to first token", averageFirstTokenSeconds.map(ModelUsageFormat.seconds)),
      (
        "Generation time",
        generationSeconds > 0 ? ModelUsageFormat.duration(generationSeconds) : nil
      ),
      ("Time in use", totalSeconds > 0 ? ModelUsageFormat.duration(totalSeconds) : nil),
      ("Efficiency", efficiency.map(ModelUsageFormat.efficiency)),
      (
        "Last used",
        lastUsedAt > .distantPast
          ? lastUsedAt.formatted(date: .abbreviated, time: .shortened) : nil
      ),
    ]
    return facts.compactMap { label, value in value.map { "\(label): \($0)" } }
  }
}

/// Sums over a set of rows — a provider's models, a selection, or the whole
/// ledger — with the derived numbers a single row has. `ModelUsageLedger` and
/// `ProviderUsageTotals` forward their members here.
public struct ModelUsageSums: Equatable, Sendable {
  public var rows: [ModelUsageTotals]

  public init(_ rows: [ModelUsageTotals]) {
    self.rows = rows
  }

  public var modelCount: Int { rows.count }
  public var inputTokens: Int { rows.sum(\.inputTokens) }
  public var userInputTokens: Int { rows.sum(\.userInputTokens) }
  public var outputTokens: Int { rows.sum(\.outputTokens) }
  public var receivedTextTokens: Int { rows.sum(\.receivedTextTokens) }
  public var reasoningTokens: Int { rows.sum(\.reasoningTokens) }
  public var imageInputs: Int { rows.sum(\.imageInputs) }
  public var cachedTokens: Int { rows.sum(\.cachedTokens) }
  public var callCount: Int { rows.sum(\.callCount) }
  public var estimatedCallCount: Int { rows.sum(\.estimatedCallCount) }
  public var totalTokens: Int { inputTokens + outputTokens }
  public var totalSeconds: TimeInterval { rows.reduce(0) { $0 + $1.totalSeconds } }
  public var lastUsedAt: Date { rows.map(\.lastUsedAt).max() ?? .distantPast }

  public var efficiency: Double? {
    ModelUsageTotals.efficiency(tokens: totalTokens, seconds: totalSeconds, requests: callCount)
  }

  /// `~1.2k sent · ~3.4k recv · 100 thinking · 1 image · 200 cached · 45 req · 12m34s in use`
  public var summaryParts: [String] {
    [
      positive(userInputTokens).map { "~\(ModelUsageFormat.count($0)) sent" },
      positive(receivedTextTokens).map { "~\(ModelUsageFormat.count($0)) recv" },
      positive(reasoningTokens).map { "\(ModelUsageFormat.count($0)) thinking" },
      positive(imageInputs).map { "\($0) image\($0 == 1 ? "" : "s")" },
      positive(cachedTokens).map { "\(ModelUsageFormat.count($0)) cached" },
      "\(callCount) req",
      totalSeconds > 0 ? "\(ModelUsageFormat.duration(totalSeconds)) in use" : nil,
    ].compactMap { $0 }
  }
}

extension Array where Element == ModelUsageTotals {
  fileprivate func sum(_ key: KeyPath<ModelUsageTotals, Int>) -> Int {
    reduce(0) { $0 + $1[keyPath: key] }
  }

  fileprivate func sum(_ key: KeyPath<ModelUsageTotals, Int?>) -> Int {
    reduce(0) { $0 + ($1[keyPath: key] ?? 0) }
  }
}

/// Every model of one provider summed, for provider-level listings.
@dynamicMemberLookup
public struct ProviderUsageTotals: Identifiable, Equatable, Sendable {
  public var providerLabel: String
  public var sums: ModelUsageSums

  public init(providerLabel: String, models: [ModelUsageTotals]) {
    self.providerLabel = providerLabel
    sums = ModelUsageSums(models)
  }

  public var id: String { providerLabel }

  public subscript<T>(dynamicMember key: KeyPath<ModelUsageSums, T>) -> T {
    sums[keyPath: key]
  }

  /// `3 models · ~1.2k sent · ~3.4k recv · 45 req · 12m34s in use`
  public var summary: String {
    (["\(sums.modelCount) model\(sums.modelCount == 1 ? "" : "s")"] + sums.summaryParts)
      .joined(separator: " · ")
  }
}

// MARK: - Ledger

/// The whole usage table: one totals row per provider/model pair. Encodes as a
/// bare JSON array of rows, the shape PocketMai has always persisted. The
/// sums over every row (`callCount`, `totalTokens`, …) read through `sums`.
@dynamicMemberLookup
public struct ModelUsageLedger: Codable, Equatable, Sendable {
  public var totals: [ModelUsageTotals]

  public init(totals: [ModelUsageTotals] = []) {
    self.totals = totals
  }

  public init(from decoder: Decoder) throws {
    totals = try decoder.singleValueContainer().decode([ModelUsageTotals].self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(totals)
  }

  public var isEmpty: Bool { totals.isEmpty }
  public var sums: ModelUsageSums { ModelUsageSums(totals) }

  public subscript<T>(dynamicMember key: KeyPath<ModelUsageSums, T>) -> T {
    sums[keyPath: key]
  }

  public func totals(id: String) -> ModelUsageTotals? {
    totals.first { $0.id == id }
  }

  /// The rows a user names on a command line: a row id, a provider label
  /// (every model of it), or `PROVIDER:MODEL`.
  public func totals(matching target: String) -> [ModelUsageTotals] {
    if let row = totals(id: target) { return [row] }
    let byProvider = totals.filter { $0.providerLabel == target }
    if !byProvider.isEmpty { return byProvider }
    guard let separator = target.firstIndex(of: ":") else { return [] }
    let id = ModelUsageTotals.id(
      providerLabel: String(target[..<separator]),
      modelID: String(target[target.index(after: separator)...]))
    return totals(id: id).map { [$0] } ?? []
  }

  /// Folds one call into its provider/model row, creating the row on first
  /// use. Calls that moved no tokens at all are ignored. Returns the updated
  /// row, or nil when nothing was recorded.
  @discardableResult
  public mutating func record(_ stats: ModelCallStats, at date: Date = Date())
    -> ModelUsageTotals?
  {
    guard stats.inputTokens > 0 || stats.outputTokens > 0 else { return nil }
    let id = ModelUsageTotals.id(providerLabel: stats.providerLabel, modelID: stats.modelID)
    let index = totals.firstIndex { $0.id == id } ?? totals.endIndex
    if index == totals.endIndex {
      totals.append(ModelUsageTotals(providerLabel: stats.providerLabel, modelID: stats.modelID))
    }
    totals[index].record(stats, at: date)
    return totals[index]
  }

  public mutating func reset() {
    totals.removeAll()
  }

  /// Drops the rows `totals(matching:)` names. Returns how many rows went.
  @discardableResult
  public mutating func remove(matching target: String) -> Int {
    let ids = Set(totals(matching: target).map(\.id))
    totals.removeAll { ids.contains($0.id) }
    return ids.count
  }

  /// Every row ranked for one metric, best first; rows without it come last,
  /// longest in use first.
  public func sorted(by metric: ModelUsageReport.Metric) -> [ModelUsageTotals] {
    totals.sorted {
      (metric.number(of: $0) ?? -1, $0.totalSeconds) > (
        metric.number(of: $1) ?? -1, $1.totalSeconds
      )
    }
  }

  public var sortedByLastUsed: [ModelUsageTotals] {
    totals.sorted { $0.lastUsedAt > $1.lastUsedAt }
  }

  public var providerTotals: [ProviderUsageTotals] {
    Dictionary(grouping: totals, by: \.providerLabel)
      .map { ProviderUsageTotals(providerLabel: $0.key, models: $0.value) }
      .sorted {
        $0.providerLabel.localizedCaseInsensitiveCompare($1.providerLabel) == .orderedAscending
      }
  }

  // MARK: Persistence

  /// Reads a ledger written by any host: ISO 8601 dates from MaiCore files and
  /// the numeric dates PocketMai's earlier releases stored are both accepted.
  public static func decode(_ data: Data, coding: MaiJSONCoding = .default) throws
    -> ModelUsageLedger
  {
    try coding.makeDecoder().decode(ModelUsageLedger.self, from: data)
  }

  public func encoded(coding: MaiJSONCoding = .default) throws -> Data {
    try coding.makeEncoder().encode(self)
  }

  public static func load(from url: URL, coding: MaiJSONCoding = .default) throws
    -> ModelUsageLedger
  {
    guard FileManager.default.fileExists(atPath: url.path) else { return ModelUsageLedger() }
    return try decode(Data(contentsOf: url), coding: coding)
  }

  public func save(to url: URL, coding: MaiJSONCoding = .default) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded(coding: coding).write(to: url, options: .atomic)
  }
}

/// Where a `ModelUsageStore` keeps its ledger between launches.
public protocol ModelUsagePersistence: Sendable {
  func load() throws -> ModelUsageLedger
  func save(_ ledger: ModelUsageLedger) throws
}

/// One JSON file, the way pmai keeps `~/.pmai/stats.json`.
public struct FileModelUsagePersistence: ModelUsagePersistence {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() throws -> ModelUsageLedger {
    try ModelUsageLedger.load(from: url)
  }

  public func save(_ ledger: ModelUsageLedger) throws {
    try ledger.save(to: url)
  }
}

/// One value in the standard `UserDefaults`, the way PocketMai keeps its totals.
public struct UserDefaultsModelUsagePersistence: ModelUsagePersistence {
  public let key: String

  public init(key: String) {
    self.key = key
  }

  public func load() throws -> ModelUsageLedger {
    try UserDefaults.standard.data(forKey: key).map { try ModelUsageLedger.decode($0) }
      ?? ModelUsageLedger()
  }

  public func save(_ ledger: ModelUsageLedger) throws {
    UserDefaults.standard.set(try ledger.encoded(), forKey: key)
  }
}

/// The shared, concurrency-safe home of a host's usage ledger. The runtime
/// records into it after every provider call; commands and screens read it.
/// Every change is written through the persistence at once, so a crash never
/// loses more than the call in flight.
public actor ModelUsageStore {
  public private(set) var ledger: ModelUsageLedger
  /// The last persistence failure, for hosts that want to show it.
  public private(set) var lastPersistenceError: String?
  private let persistence: (any ModelUsagePersistence)?
  private var subscribers: [UUID: AsyncStream<ModelUsageLedger>.Continuation] = [:]

  public init(persistence: (any ModelUsagePersistence)? = nil) {
    self.persistence = persistence
    ledger = (try? persistence?.load()) ?? ModelUsageLedger()
  }

  public init(url: URL) {
    self.init(persistence: FileModelUsagePersistence(url: url))
  }

  /// The file behind the ledger, when it is kept in one.
  public var location: URL? {
    (persistence as? FileModelUsagePersistence)?.url
  }

  public func totals() -> [ModelUsageTotals] { ledger.totals }

  @discardableResult
  public func record(_ stats: ModelCallStats, at date: Date = Date()) -> ModelUsageTotals? {
    guard let entry = ledger.record(stats, at: date) else { return nil }
    persist()
    return entry
  }

  public func reset() {
    ledger.reset()
    persist()
  }

  /// Drops the rows a command-line target names; see `ModelUsageLedger.totals(matching:)`.
  @discardableResult
  public func remove(matching target: String) -> Int {
    let removed = ledger.remove(matching: target)
    if removed > 0 { persist() }
    return removed
  }

  /// Every ledger written after subscribing, for screens that stay open.
  public func changes() -> AsyncStream<ModelUsageLedger> {
    let id = UUID()
    return AsyncStream { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.unsubscribe(id) }
      }
    }
  }

  private func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  private func persist() {
    do {
      try persistence?.save(ledger)
      lastPersistenceError = nil
    } catch {
      lastPersistenceError = error.localizedDescription
    }
    for continuation in subscribers.values { continuation.yield(ledger) }
  }
}

// MARK: - Presentation

/// An sRGB color in 0...1 components, so every host can paint a provider the
/// same way without sharing a UI framework.
public struct ModelUsageColor: Hashable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = min(1, max(0, red))
    self.green = min(1, max(0, green))
    self.blue = min(1, max(0, blue))
  }

  /// `#rrggbb`, the spelling terminal color settings accept.
  public var hex: String {
    String(
      format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()),
      Int((blue * 255).rounded()))
  }
}

/// A label-derived hue gives every model, and every provider, a distinct,
/// repeatable chart color that is the same in PocketMai, the REPL, and the
/// visual workspace. Rows are keyed by `provider|model`, so two models of one
/// provider never share a bar color and a model keeps its color across the
/// speed, time, and efficiency rankings.
public enum ModelUsagePalette {
  public static let saturation = 0.68
  public static let brightness = 0.88

  /// Hue in 0..<1 from an FNV-1a hash of any label.
  public static func hue(for label: String) -> Double {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in label.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Double(hash % 360) / 360
  }

  /// The color of a provider as a whole, for provider-level rows.
  public static func color(forProviderLabel label: String) -> ModelUsageColor {
    color(hue: hue(for: label), saturation: saturation, brightness: brightness)
  }

  /// The color of one `provider|model` row (`ModelUsageTotals.id`), the one
  /// its bars are drawn in.
  public static func color(forModel id: String) -> ModelUsageColor {
    color(hue: hue(for: id), saturation: saturation, brightness: brightness)
  }

  /// HSB to sRGB, all components in 0...1.
  public static func color(hue: Double, saturation: Double, brightness: Double)
    -> ModelUsageColor
  {
    let h = (hue - hue.rounded(.down)) * 6
    let sector = Int(h.rounded(.down)) % 6
    let fraction = h - h.rounded(.down)
    let p = brightness * (1 - saturation)
    let q = brightness * (1 - saturation * fraction)
    let t = brightness * (1 - saturation * (1 - fraction))
    switch sector {
    case 0: return ModelUsageColor(red: brightness, green: t, blue: p)
    case 1: return ModelUsageColor(red: q, green: brightness, blue: p)
    case 2: return ModelUsageColor(red: p, green: brightness, blue: t)
    case 3: return ModelUsageColor(red: p, green: q, blue: brightness)
    case 4: return ModelUsageColor(red: t, green: p, blue: brightness)
    default: return ModelUsageColor(red: brightness, green: p, blue: q)
    }
  }
}

/// Text spellings shared by every host: speeds, durations, counts, and bars.
public enum ModelUsageFormat {
  /// `42.1 tok/s`
  public static func speed(_ tokensPerSecond: Double) -> String {
    String(format: "%.1f tok/s", tokensPerSecond)
  }

  public static func speed(_ tokensPerSecond: Double, estimated: Bool) -> String {
    (estimated ? "~" : "") + speed(tokensPerSecond)
  }

  /// `0.85s` under ten seconds, `12.3s` above.
  public static func seconds(_ seconds: TimeInterval) -> String {
    String(format: seconds >= 10 ? "%.1fs" : "%.2fs", seconds)
  }

  /// `3.2 tok/s/req`: tokens per second in use, per request.
  public static func efficiency(_ score: Double) -> String {
    String(format: "%.1f tok/s/req", score)
  }

  /// `<1s`, `5s`, `1m4s`, or `2h3m4s`: how long something took or has been
  /// running, rounded to whole seconds.
  public static func duration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "<1s" }
    let total = Int(seconds.rounded())
    guard total >= 1 else { return "<1s" }
    let (hours, minutes, remainder) = (total / 3600, total % 3600 / 60, total % 60)
    if hours > 0 { return "\(hours)h\(minutes)m\(remainder)s" }
    if minutes > 0 { return "\(minutes)m\(remainder)s" }
    return "\(remainder)s"
  }

  /// `950`, `1.2k`, `12.0k`, `552.2k`, `3.4M`: a count short enough for a
  /// status line. Every token count a host prints goes through here, so the
  /// same number reads the same everywhere.
  public static func count(_ count: Int) -> String {
    guard count >= 1_000 else { return String(count) }
    let thousandths = (count + 50) / 100
    guard thousandths >= 10_000 else { return "\(thousandths / 10).\(thousandths % 10)k" }
    let millionths = (count + 50_000) / 100_000
    return "\(millionths / 10).\(millionths % 10)M"
  }

  /// A token count with its unit, `~` first when the number was estimated
  /// rather than reported by the provider: `12.0k tok`, `~552.2k tok`.
  public static func tokens(_ count: Int, estimated: Bool = false) -> String {
    "\(estimated ? "~" : "")\(Self.count(count)) tok"
  }

  /// A horizontal bar of `width` cells filled to `fraction`, using eighth
  /// blocks for the last cell so short bars still differ.
  public static func bar(fraction: Double, width: Int) -> String {
    guard width > 0 else { return "" }
    let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
    let eighths = Int((clamped * Double(width) * 8).rounded())
    let full = eighths / 8
    let partial = eighths % 8
    let partials = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
    var bar = String(repeating: "█", count: min(full, width))
    if full < width {
      bar += partials[partial]
      bar += String(repeating: " ", count: max(0, width - full - 1))
    }
    return bar
  }

  /// `text` cut to `width` cells with a trailing ellipsis, for a label column.
  public static func clip(_ text: String, to width: Int) -> String {
    guard text.count > width, width > 1 else { return text }
    return String(text.prefix(width - 1)) + "…"
  }

  /// `text` padded with spaces to `width` cells, on the left when `leading`.
  public static func pad(_ text: String, to width: Int, leading: Bool = false) -> String {
    let missing = max(0, width - text.count)
    guard missing > 0 else { return text }
    let fill = String(repeating: " ", count: missing)
    return leading ? fill + text : text + fill
  }
}

/// The usage ledger arranged for display: rows ranked by speed, each with
/// its bar fraction per metric and its color, plus the totals for a headline.
/// Hosts render the rows with their own widgets or print `lines`, the
/// plain-text rendering the REPL and the visual workspace share.
public struct ModelUsageReport: Equatable, Sendable {
  /// One ranking. Adding a metric is one entry here: its name, how it is
  /// explained, how its number is read off a row, and how it is spelled.
  public struct Metric: Hashable, Sendable, CaseIterable {
    public let id: String
    /// The heading over the bars: `Average output speed`.
    public let title: String
    /// How the number is computed, for help text and footers.
    public let explanation: String
    /// What a row without the number says.
    private let missing: String
    private let compute: @Sendable (ModelUsageTotals) -> Double?
    private let format: @Sendable (Double) -> String

    public static let speed = Metric(
      id: "speed", title: "Average output speed",
      explanation: "answer text tokens over the streaming window of each call; ~ means estimated from text length",
      missing: "no speed", compute: { $0.averageTokensPerSecond }, format: ModelUsageFormat.speed)
    public static let time = Metric(
      id: "time", title: "Time in use",
      explanation: "the wait for the first token plus generation time, summed over every call",
      missing: "<1s", compute: { $0.totalSeconds }, format: ModelUsageFormat.duration)
    public static let efficiency = Metric(
      id: "efficiency", title: "Efficiency",
      explanation: "total tokens divided by seconds in use and by requests",
      missing: "no score", compute: { $0.efficiency }, format: ModelUsageFormat.efficiency)
    /// The sum of a model's positions in speed, time in use, and efficiency.
    /// Lower is better: first place in every category is 3 points.
    public static let ranking = Metric(
      id: "ranking", title: "Ranking",
      explanation: "the sum of its positions in speed, time in use, and efficiency; lower is better",
      missing: "no ranking", compute: { _ in nil }, format: { "\(Int($0)) points" })
    /// The three measured categories that contribute to the combined ranking.
    public static let allCases = [speed, time, efficiency]
    /// Metrics shown by `/stats` and chart pickers, including the combined ranking.
    public static let displayCases = [ranking, speed, time, efficiency]

    /// The metric a user named on a command line: `ranking`, `speed`, `time`, or `efficiency`.
    public static func named(_ id: String) -> Metric? {
      displayCases.first { $0.id == id }
    }

    /// `Speed`, for a picker.
    public var label: String { id.capitalized }

    public func number(of totals: ModelUsageTotals) -> Double? { compute(totals) }

    /// The number spelled out — `42.1 tok/s`, `12m34s`, `3.2 tok/s/req` —
    /// or what a row without it says.
    public func text(_ value: Double?) -> String { value.map(format) ?? missing }

    public static func == (lhs: Metric, rhs: Metric) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
  }

  public struct Row: Identifiable, Equatable, Sendable {
    public var totals: ModelUsageTotals
    public var color: ModelUsageColor
    /// Each metric's number relative to the best row, 0...1; zero without one.
    public var fractions: [Metric: Double]
    /// The 1-based position in each measured category.
    public var positions: [Metric: Int]
    /// The sum of `positions`; a smaller score is a better overall ranking.
    public var rankingScore: Int

    public var id: String { totals.id }
    public var title: String { totals.title }

    public func number(_ metric: Metric) -> Double? {
      metric == .ranking ? Double(rankingScore) : metric.number(of: totals)
    }
    public func fraction(_ metric: Metric) -> Double { fractions[metric] ?? 0 }

    /// The bar's number: `42.1 tok/s`, `12m34s`, or `3.2 tok/s/req`.
    public func value(_ metric: Metric) -> String {
      if metric == .speed, let speed = number(metric) {
        return ModelUsageFormat.speed(speed, estimated: totals.visibleOutputTokensEstimated)
      }
      return metric.text(number(metric))
    }

    /// What the row says after its bar — the other metrics, then requests and
    /// tokens — so every ranking reads whole: `12m34s · 3.2 tok/s/req · 45 req · 120.3k tok`.
    public func detail(_ metric: Metric) -> String {
      if metric == .ranking {
        return Metric.allCases.compactMap { category in
          positions[category].map { "\(category.label) #\($0)" }
        }.joined(separator: " · ")
      }
      return (Metric.allCases.filter { $0 != metric }.compactMap { other in
        number(other).map { _ in value(other) }
      }
        + [
          "\(totals.callCount) req",
          ModelUsageFormat.tokens(totals.totalTokens, estimated: totals.estimatedCallCount > 0),
        ]).joined(separator: " · ")
    }
  }

  public var ledger: ModelUsageLedger
  /// Every row, fastest first.
  public var rows: [Row]

  public init(_ ledger: ModelUsageLedger) {
    self.ledger = ledger
    let best = Metric.allCases.map { metric in
      (metric, ledger.totals.compactMap(metric.number(of:)).max() ?? 0)
    }
    let entries = ledger.sorted(by: .speed)
    let positions = Dictionary(uniqueKeysWithValues: Metric.allCases.map { metric in
      (metric, Dictionary(uniqueKeysWithValues: Self.sorted(entries, by: metric).enumerated().map {
        ($0.element.id, $0.offset + 1)
      }))
    })
    let scores = Dictionary(uniqueKeysWithValues: entries.map { entry in
      (entry.id, Metric.allCases.reduce(0) { $0 + (positions[$1]?[entry.id] ?? 0) })
    })
    let bestScore = scores.values.min() ?? 0
    let worstScore = scores.values.max() ?? 0
    rows = entries.map { entry in
      Row(
        totals: entry,
        color: ModelUsagePalette.color(forModel: entry.id),
        fractions: Dictionary(
          uniqueKeysWithValues: best.map { metric, top in
            (metric, top > 0 ? (metric.number(of: entry) ?? 0) / top : 0)
          }).merging([.ranking: bestScore == worstScore ? 1 : Double(worstScore - (scores[entry.id] ?? 0)) / Double(worstScore - bestScore)],
                     uniquingKeysWith: { _, ranking in ranking }),
        positions: Dictionary(uniqueKeysWithValues: Metric.allCases.map {
          ($0, positions[$0]?[entry.id] ?? 0)
        }),
        rankingScore: scores[entry.id] ?? 0)
    }
  }

  public init(totals: [ModelUsageTotals]) {
    self.init(ModelUsageLedger(totals: totals))
  }

  public var isEmpty: Bool { rows.isEmpty }

  /// Rows ranked for one metric, best first; rows without it keep their
  /// speed ranking at the end.
  public func rows(for metric: Metric) -> [Row] {
    if metric == .ranking {
      return rows.sorted { lhs, rhs in
        lhs.rankingScore == rhs.rankingScore ? lhs.id < rhs.id : lhs.rankingScore < rhs.rankingScore
      }
    }
    return rows.sorted { lhs, rhs in
      let lhsValue = lhs.number(metric) ?? -1
      let rhsValue = rhs.number(metric) ?? -1
      return lhsValue == rhsValue ? lhs.id < rhs.id : lhsValue > rhsValue
    }
  }

  private static func sorted(_ entries: [ModelUsageTotals], by metric: Metric) -> [ModelUsageTotals] {
    entries.sorted { lhs, rhs in
      let lhsValue = metric.number(of: lhs) ?? -1
      let rhsValue = metric.number(of: rhs) ?? -1
      return lhsValue == rhsValue ? lhs.id < rhs.id : lhsValue > rhsValue
    }
  }

  /// `2 models · 57 requests · 15m36s in use · 150.4k tokens · efficiency 2.8 tok/s/req`
  public var headline: String {
    let sums = ledger.sums
    return [
      "\(sums.modelCount) model\(sums.modelCount == 1 ? "" : "s")",
      "\(sums.callCount) request\(sums.callCount == 1 ? "" : "s")",
      "\(ModelUsageFormat.duration(sums.totalSeconds)) in use",
      "\(sums.estimatedCallCount > 0 ? "~" : "")\(ModelUsageFormat.count(sums.totalTokens)) tokens",
      positive(sums.reasoningTokens).map { "\(ModelUsageFormat.count($0)) thinking" },
      sums.efficiency.map { "efficiency \(ModelUsageFormat.efficiency($0))" },
    ].compactMap { $0 }.joined(separator: " · ")
  }

  public static let emptyMessage =
    "No model usage recorded yet. Statistics appear after the first model response."

  /// What a run of report text is, so a terminal can color it: headings, the
  /// model-colored label and bar, the number, and the muted rest.
  public enum Style: Equatable, Sendable {
    case heading
    case headline
    case label(ModelUsageColor)
    case bar(ModelUsageColor)
    case value
    case detail
    case note
  }

  /// One run of a report line; `style` is nil for spacing.
  public struct Run: Equatable, Sendable {
    public var text: String
    public var style: Style?

    public init(_ text: String, _ style: Style? = nil) {
      self.text = text
      self.style = style
    }
  }

  /// The report as styled runs, one array per line: a headline, then one
  /// bar per model for each metric, sized to fit `width` columns.
  public func runs(width: Int = 80, metrics: [Metric] = Metric.displayCases) -> [[Run]] {
    guard !isEmpty else { return [[Run(Self.emptyMessage)]] }
    var lines: [[Run]] = [[Run("Model usage: ", .heading), Run(headline, .headline)]]
    let labelWidth = min(28, rows.map { $0.title.count }.max() ?? 0)
    for metric in metrics {
      lines.append([Run(metric.title, .heading)])
      let metricRows = rows(for: metric)
      let valueWidth = metricRows.map { $0.value(metric).count }.max() ?? 0
      let detailWidth = metricRows.map { $0.detail(metric).count }.max() ?? 0
      let barWidth = max(4, min(30, width - labelWidth - valueWidth - detailWidth - 5))
      for row in metricRows {
        lines.append([
          Run("  "),
          Run(
            ModelUsageFormat.pad(ModelUsageFormat.clip(row.title, to: labelWidth), to: labelWidth),
            .label(row.color)),
          Run(" "),
          Run(
            ModelUsageFormat.bar(fraction: row.fraction(metric), width: barWidth), .bar(row.color)),
          Run(" "),
          Run(ModelUsageFormat.pad(row.value(metric), to: valueWidth, leading: true), .value),
          Run(" "),
          Run(row.detail(metric), .detail),
        ])
      }
    }
    if ledger.estimatedCallCount > 0 || rows.contains(where: { $0.totals.visibleOutputTokensEstimated }) {
      lines.append([
        Run(
          "~ marks estimates from text length (about 4 characters per token).",
          .note)
      ])
    }
    return lines
  }

  /// The plain-text report. `paint` may wrap a styled run in color for
  /// terminals that show it; the text stays free of escapes otherwise, so
  /// any surface can print it.
  public func lines(
    width: Int = 80,
    metrics: [Metric] = Metric.displayCases,
    paint: (String, Style) -> String = { text, _ in text }
  ) -> [String] {
    runs(width: width, metrics: metrics).map { line in
      line.map { run in run.style.map { paint(run.text, $0) } ?? run.text }.joined()
    }
  }
}
