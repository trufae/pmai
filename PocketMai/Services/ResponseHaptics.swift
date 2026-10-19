import Foundation
import UIKit

@MainActor
final class ResponseHaptics {
  /// A throttled, randomized impact tap. Reused for both the response "typing"
  /// stream and the lighter "thinking" stream — each keeps its own cadence.
  private struct StreamTap {
    let intervalRange: ClosedRange<TimeInterval>
    let intensityRange: ClosedRange<Double>
    private var lastFiredAt = Date.distantPast
    private var nextInterval: TimeInterval = 0

    init(intervalRange: ClosedRange<TimeInterval>, intensityRange: ClosedRange<Double>) {
      self.intervalRange = intervalRange
      self.intensityRange = intensityRange
    }

    /// Returns the intensity to play, or `nil` when still inside the throttle window.
    mutating func nextIntensity() -> CGFloat? {
      let now = Date()
      guard now.timeIntervalSince(lastFiredAt) >= nextInterval else { return nil }
      lastFiredAt = now
      nextInterval = .random(in: intervalRange)
      return CGFloat(Double.random(in: intensityRange))
    }
  }

  private let streamSoftGenerator = UIImpactFeedbackGenerator(style: .soft)
  private let streamLightGenerator = UIImpactFeedbackGenerator(style: .light)
  private let streamMediumGenerator = UIImpactFeedbackGenerator(style: .medium)
  private let thinkingGenerator = UIImpactFeedbackGenerator(style: .rigid)
  private let sidebarGenerator = UISelectionFeedbackGenerator()
  private var responseTap = StreamTap(intervalRange: 0.09...0.28, intensityRange: 0.25...0.85)
  private var thinkingTap = StreamTap(intervalRange: 0.18...0.42, intensityRange: 0.12...0.4)
  private var lastVisibleLength = 0

  init() {
    streamSoftGenerator.prepare()
    streamLightGenerator.prepare()
    streamMediumGenerator.prepare()
    thinkingGenerator.prepare()
    sidebarGenerator.prepare()
  }

  /// Drives streaming haptics from a full snapshot of the assistant message.
  /// The "typing" tap plays only while visible response text grows; while the
  /// model emits reasoning (think) tokens, the lighter thinking tap plays.
  func streamSnapshotReceived(_ snapshot: String) {
    let visibleLength = MessageContentFilter.render(snapshot).visibleText.count
    let printingResponse = visibleLength > lastVisibleLength
    lastVisibleLength = visibleLength
    if printingResponse {
      if let intensity = responseTap.nextIntensity() {
        fire(streamGenerator(for: intensity), intensity: intensity)
      }
    } else if let intensity = thinkingTap.nextIntensity() {
      fire(thinkingGenerator, intensity: intensity)
    }
  }

  func responseCompleted() {
    lastVisibleLength = 0
    fire(streamSoftGenerator, intensity: 0.4)
  }

  func sidebarVisibilitySettled() {
    sidebarGenerator.prepare()
    sidebarGenerator.selectionChanged()
    sidebarGenerator.prepare()
  }

  private func fire(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
    generator.prepare()
    generator.impactOccurred(intensity: intensity)
    generator.prepare()
  }

  private func streamGenerator(for intensity: CGFloat) -> UIImpactFeedbackGenerator {
    switch intensity {
    case ..<0.46:
      return streamSoftGenerator
    case ..<0.76:
      return streamLightGenerator
    default:
      return streamMediumGenerator
    }
  }
}
