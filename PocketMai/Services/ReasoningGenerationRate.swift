import Foundation
import MaiCore

/// Estimate only text observed arriving while the reasoning header is visible.
/// Old history is a baseline, and later tool/answer time never dilutes the rate.
struct ReasoningGenerationRate {
  private var firstCount = 0
  private var lastCount = 0
  private var firstAt: Date?
  private var lastAt: Date?
  private var samples = 0

  mutating func observe(characterCount: Int, at date: Date) {
    if firstAt == nil || characterCount < lastCount {
      firstCount = characterCount
      lastCount = characterCount
      firstAt = date
      lastAt = date
      samples = 1
    } else if characterCount > lastCount {
      lastCount = characterCount
      lastAt = date
      samples += 1
    }
  }

  var tokensPerSecond: Double? {
    guard let firstAt, let lastAt, samples >= ModelCallStats.minimumStreamedTokenChunks else { return nil }
    let elapsed = lastAt.timeIntervalSince(firstAt)
    guard elapsed >= ModelCallStats.minimumStreamedGenerationSeconds else { return nil }
    let tokens = ModelCallStats.estimatedTokenCount(forCharacterCount: lastCount - firstCount)
    return Double(tokens) / elapsed
  }
}
