import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class GenerationStatsTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000)

  func testStreamedTimingSplitsPromptAndGeneration() {
    var observation = StreamTimingObservation(requestStart: start)
    observation.noteTokenChunk(at: start.addingTimeInterval(0.8))
    observation.noteTokenChunk(at: start.addingTimeInterval(2.0))
    observation.noteTokenChunk(at: start.addingTimeInterval(4.5))
    observation.noteTokenChunk(at: start.addingTimeInterval(6.8))

    let resolved = GenerationStats.resolveTiming(
      observation, end: start.addingTimeInterval(7.1))

    XCTAssertEqual(resolved.firstTokenSeconds ?? -1, 0.8, accuracy: 0.0001)
    XCTAssertEqual(resolved.promptSeconds, 0.8, accuracy: 0.0001)
    // First→last token window; the trailing usage/[DONE] wait is excluded.
    XCTAssertEqual(resolved.generationSeconds, 6.0, accuracy: 0.0001)
  }

  func testBurstDeliveryFallsBackToTotalWallTime() {
    // A local endpoint can hand over the whole SSE body in one network burst.
    // Dividing tokens by the near-zero first→last window would report absurd
    // speeds (thousands of tok/s), so total wall time must be used instead.
    var observation = StreamTimingObservation(requestStart: start)
    observation.noteTokenChunk(at: start.addingTimeInterval(9.98))
    observation.noteTokenChunk(at: start.addingTimeInterval(9.99))

    let resolved = GenerationStats.resolveTiming(
      observation, end: start.addingTimeInterval(10.0))

    XCTAssertEqual(resolved.promptSeconds, 0)
    XCTAssertEqual(resolved.generationSeconds, 10.0, accuracy: 0.0001)
    // Time to first byte of the answer is still real and worth reporting.
    XCTAssertEqual(resolved.firstTokenSeconds ?? -1, 9.98, accuracy: 0.0001)
  }

  func testShortWindowWithManyChunksStillFallsBack() {
    var observation = StreamTimingObservation(requestStart: start)
    for offset in stride(from: 5.00, through: 5.10, by: 0.01) {
      observation.noteTokenChunk(at: start.addingTimeInterval(offset))
    }

    let resolved = GenerationStats.resolveTiming(
      observation, end: start.addingTimeInterval(5.2))

    XCTAssertEqual(resolved.promptSeconds, 0)
    XCTAssertEqual(resolved.generationSeconds, 5.2, accuracy: 0.0001)
  }

  func testNonStreamingUsesTotalWallTimeWithoutFirstToken() {
    let observation = StreamTimingObservation(requestStart: start)

    let resolved = GenerationStats.resolveTiming(
      observation, end: start.addingTimeInterval(3.0))

    XCTAssertNil(resolved.firstTokenSeconds)
    XCTAssertEqual(resolved.promptSeconds, 0)
    XCTAssertEqual(resolved.generationSeconds, 3.0, accuracy: 0.0001)
  }

  func testResolvedRateStaysPlausibleForBurstDelivery() {
    // 500 tokens generated over 10s but delivered all at once must read as
    // ~50 tok/s, never tokens divided by the burst window.
    var observation = StreamTimingObservation(requestStart: start)
    observation.noteTokenChunk(at: start.addingTimeInterval(9.95))
    observation.noteTokenChunk(at: start.addingTimeInterval(10.0))
    let resolved = GenerationStats.resolveTiming(
      observation, end: start.addingTimeInterval(10.0))

    let stats = GenerationStats(
      providerLabel: "Ollama",
      modelID: "llama3",
      inputTokens: 100,
      outputTokens: 500,
      promptSeconds: resolved.promptSeconds,
      generationSeconds: resolved.generationSeconds,
      firstTokenSeconds: resolved.firstTokenSeconds)

    XCTAssertEqual(stats.tokensPerSecond ?? -1, 50.0, accuracy: 0.01)
  }

  func testTokensPerSecondIncludesReasoningAndIgnoresTextEstimate() {
    let stats = GenerationStats(
      providerLabel: "p",
      modelID: "m",
      outputTokens: 300,
      receivedTextTokens: 5,
      reasoningTokens: 100,
      generationSeconds: 10)

    XCTAssertEqual(stats.tokensPerSecond ?? -1, 30.0, accuracy: 0.0001)
  }

  func testTokensPerSecondIsNilWithoutDuration() {
    let stats = GenerationStats(
      providerLabel: "p",
      modelID: "m",
      outputTokens: 300,
      generationSeconds: 0)

    XCTAssertNil(stats.tokensPerSecond)
  }

  func testMergeKeepsEarliestFirstTokenSeconds() {
    var first = GenerationStats(
      providerLabel: "p", modelID: "m", outputTokens: 10, firstTokenSeconds: 0.9)
    let second = GenerationStats(
      providerLabel: "p", modelID: "m", outputTokens: 20, firstTokenSeconds: 0.2)

    first.merge(second)

    XCTAssertEqual(first.firstTokenSeconds ?? -1, 0.9, accuracy: 0.0001)
    XCTAssertEqual(first.outputTokens, 30)

    var missing = GenerationStats(providerLabel: "p", modelID: "m", outputTokens: 5)
    missing.merge(second)
    XCTAssertEqual(missing.firstTokenSeconds ?? -1, 0.2, accuracy: 0.0001)
  }

  func testModelTotalsDecodeWithoutFirstTokenFields() throws {
    // Totals persisted by earlier app versions have no first-token keys.
    let legacy = """
      {"providerLabel":"Ollama","modelID":"llama3","inputTokens":10,
       "outputTokens":20,"cachedTokens":0,"promptSeconds":1,
       "generationSeconds":2,"callCount":1,"estimatedCallCount":0,
       "lastUsedAt":0}
      """
    let decoded = try JSONDecoder().decode(
      UsageStatsStore.ModelTotals.self, from: Data(legacy.utf8))

    XCTAssertNil(decoded.lastFirstTokenSeconds)
    XCTAssertNil(decoded.averageFirstTokenSeconds)
    XCTAssertEqual(decoded.outputTokens, 20)
  }

  func testModelTotalsAverageFirstTokenSeconds() {
    var totals = UsageStatsStore.ModelTotals(providerLabel: "p", modelID: "m")
    totals.firstTokenSecondsTotal = 3.0
    totals.firstTokenSampleCount = 2

    XCTAssertEqual(totals.averageFirstTokenSeconds ?? -1, 1.5, accuracy: 0.0001)
  }
}
