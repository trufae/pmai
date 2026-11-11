#if canImport(SwiftUI)
import SwiftUI
import QuartzCore

/// Shared motion tuning for SwiftUI text and native link/justified text.
public enum StreamingTextRevealStyle {
  public static let duration = 0.72
  public static let maximumBatches = 12

  public static func opacity(progress: Double, position: Double) -> Double {
    let delay = min(1, max(0, position)) * 0.22
    let t = min(1, max(0, (progress - delay) / (1 - delay)))
    // Smootherstep has zero velocity and acceleration at either end. Each
    // glyph gently gathers ink without a sudden start or an abrupt finish.
    let eased = t * t * t * (t * (t * 6 - 15) + 10)
    return 0.22 + 0.78 * eased
  }
}

struct StreamingTextArrival {
  var count: Int
  let time: TimeInterval
}

private struct StreamingResponseKey: EnvironmentKey {
  static let defaultValue = false
}

public extension EnvironmentValues {
  var isStreamingResponse: Bool {
    get { self[StreamingResponseKey.self] }
    set { self[StreamingResponseKey.self] = newValue }
  }
}

public extension View {
  /// Apply to a single text leaf, after its font/color modifiers. Images,
  /// controls and Markdown parsing stay outside the animation subtree.
  func streamingTextReveal(_ source: String) -> some View {
    modifier(StreamingTextReveal(source: source))
  }

  /// Restrict inherited streaming effects to the unfinished Markdown branch.
  func streamingResponseTail(_ isTail: Bool) -> some View {
    modifier(StreamingResponseTail(isTail: isTail))
  }
}

private struct StreamingResponseTail: ViewModifier {
  @Environment(\.isStreamingResponse) private var streaming
  let isTail: Bool

  func body(content: Content) -> some View {
    content.environment(\.isStreamingResponse, streaming && isTail)
  }
}

private struct StreamingTextReveal: ViewModifier {
  let source: String
  @Environment(\.isStreamingResponse) private var streaming
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var arrivals: [StreamingTextArrival] = []
  @State private var revision = 0
  @State private var revealing = false

  private var enabled: Bool { streaming && !reduceMotion && scenePhase == .active }

  func body(content: Content) -> some View {
    Group {
      if enabled {
        // Only this drawing subtree ticks. A real monotonic clock lets new
        // chunks join the fade without restarting or rewinding older ink.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !revealing)) { _ in
          content.textRenderer(StreamingTextRenderer(
            time: revealing ? CACurrentMediaTime()
              : (arrivals.last?.time ?? 0) + StreamingTextRevealStyle.duration,
            arrivals: arrivals))
        }
        .transaction { $0.animation = nil }
      } else {
        content
      }
    }
      .onChange(of: source, initial: true) { old, new in
        guard enabled else { arrivals = []; revealing = false; return }
        // Only arrivals animate. Replacements, final formatting, search and
        // history restoration must never conceal existing text.
        let appended: Substring
        if old == new, revision == 0 {
          appended = new.suffix(StreamingTextRenderer.maximumTail)
        } else if new.utf8.starts(with: old.utf8) {
          appended = new.dropFirst(old.count)
        } else {
          arrivals = []
          revealing = false
          return
        }
        let count = appended.suffix(StreamingTextRenderer.maximumTail).filter { !$0.isNewline }.count
        guard count > 0 else { return }
        let now = CACurrentMediaTime()
        arrivals.removeAll { now - $0.time >= StreamingTextRevealStyle.duration }
        arrivals.append(StreamingTextArrival(count: count, time: now))
        arrivals = Array(arrivals.suffix(StreamingTextRevealStyle.maximumBatches))
        var budget = StreamingTextRenderer.maximumTail
        for index in arrivals.indices.reversed() {
          arrivals[index].count = min(arrivals[index].count, budget)
          budget -= arrivals[index].count
        }
        arrivals.removeAll { $0.count == 0 }
        revealing = true
        revision &+= 1
      }
      .onChange(of: enabled) { _, enabled in
        if !enabled { arrivals = []; revealing = false }
      }
      .task(id: enabled ? revision : nil) {
        guard enabled, let latest = arrivals.last else { return }
        let remaining = max(0, latest.time + StreamingTextRevealStyle.duration - CACurrentMediaTime())
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        guard !Task.isCancelled, arrivals.last?.time == latest.time else { return }
        revealing = false
      }
  }
}

/// A finite, drawing-only animation. SwiftUI retains the laid-out text; no
/// parsing, string operations or view state mutations run in the renderer.
/// Settled lines/runs use their normal batched draw. At most 96 new glyphs get
/// individual opacity values, regardless of the response length.
struct StreamingTextRenderer: TextRenderer {
  static let maximumTail = 96
  var time: TimeInterval
  var arrivals: [StreamingTextArrival]

  var animatableData: Double {
    get { time }
    set { time = newValue }
  }

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    guard let latest = arrivals.last, time < latest.time + StreamingTextRevealStyle.duration else {
      for line in layout { context.draw(line) }
      return
    }
    let tailCount = arrivals.reduce(0) { $0 + $1.count }
    // Walk backwards only far enough to locate the small animated tail.
    var remaining = min(tailCount, Self.maximumTail)
    var firstLine = layout.endIndex
    for index in layout.indices.reversed() {
      firstLine = index
      for run in layout[index] { remaining -= run.count }
      if remaining <= 0 { break }
    }
    var offset = min(0, remaining)
    var arrivalIndex = 0
    var arrivalStart = 0
    for index in layout.indices {
      let line = layout[index]
      guard index >= firstLine else { context.draw(line); continue }
      for run in line {
        if offset + run.count <= 0 {
          context.draw(run)
          offset += run.count
          continue
        }
        let stable = min(run.count, max(0, -offset))
        let rtl = run.layoutDirection == .rightToLeft
        if stable > 0 {
          context.draw(rtl ? run[(run.count - stable)..<run.count] : run[0..<stable])
        }
        for glyph in stable..<run.count {
          // A soft leading-to-trailing gradient, preserving each glyph's
          // original foreground (including syntax colors and link styles).
          let index = max(0, offset + glyph) + max(0, remaining)
          while arrivalIndex < arrivals.count - 1,
            index >= arrivalStart + arrivals[arrivalIndex].count {
            arrivalStart += arrivals[arrivalIndex].count
            arrivalIndex += 1
          }
          let arrival = arrivals[arrivalIndex]
          let position = Double(index - arrivalStart) / Double(max(1, arrival.count - 1))
          var ink = context
          ink.opacity *= StreamingTextRevealStyle.opacity(
            progress: (time - arrival.time) / StreamingTextRevealStyle.duration, position: position)
          ink.draw(run[rtl ? run.count - 1 - glyph : glyph])
        }
        offset += run.count
      }
    }
  }
}
#endif
