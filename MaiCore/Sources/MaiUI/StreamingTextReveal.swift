#if canImport(SwiftUI)
import SwiftUI
import QuartzCore

/// Shared motion tuning for SwiftUI text and native link/justified text.
public enum StreamingTextRevealStyle {
  public static let duration = 2.00
  public static let maximumBatches = 12

  public static func opacity(progress: Double, position: Double = 0) -> Double {
    let delay = min(1, max(0, position)) * 0.22
    let t = min(1, max(0, (progress - delay) / (1 - delay)))
    let eased = t * t * (3 - 2 * t)
    return 0.22 + 0.78 * eased
  }
}

/// One fading wave follows the stream, retaining its position across appends.
struct StreamingTextWave {
  static let maximumTail = 96
  static let width = 24.0
  let count: Int
  let distance: Double
  let time: TimeInterval

  init(count: Int, time: TimeInterval, previous: Self?) {
    self.count = min(Self.maximumTail, (previous?.count ?? 0) + count)
    // Moving the end also moves the wave's distance by the same amount,
    // leaving the opacity of text already on screen unchanged.
    distance = min(Double(Self.maximumTail) + Self.width,
      (previous?.remaining(at: time) ?? Self.width) + Double(count))
    self.time = time
  }

  func remaining(at time: TimeInterval) -> Double {
    let t = min(1, max(0, (time - self.time) / StreamingTextRevealStyle.duration))
    return distance * (1 - t) * (1 - t)
  }
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
  @State private var wave: StreamingTextWave?

  private var enabled: Bool { streaming && !reduceMotion && scenePhase == .active }

  func body(content: Content) -> some View {
    Group {
      if enabled {
        // Only the drawing subtree ticks, and only while the wave is moving.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: wave == nil)) { _ in
          content.textRenderer(StreamingTextRenderer(
            remaining: wave?.remaining(at: CACurrentMediaTime()) ?? 0,
            tailCount: wave?.count ?? 0))
        }
        .transaction { $0.animation = nil }
      } else {
        content
      }
    }
      .onChange(of: source, initial: true) { old, new in
        guard enabled else { wave = nil; return }
        // Only arrivals animate. Replacements, final formatting, search and
        // history restoration must never conceal existing text.
        let appended: Substring
        if old == new {
          appended = new.suffix(StreamingTextWave.maximumTail)
        } else if new.utf8.starts(with: old.utf8) {
          appended = new.dropFirst(old.count)
        } else {
          wave = nil
          return
        }
        let count = appended.suffix(StreamingTextWave.maximumTail).filter { !$0.isNewline }.count
        guard count > 0 else { return }
        let now = CACurrentMediaTime()
        let previous = wave.flatMap { now - $0.time < StreamingTextRevealStyle.duration ? $0 : nil }
        wave = StreamingTextWave(count: count, time: now, previous: previous)
      }
      .onChange(of: enabled) { _, enabled in
        if !enabled { wave = nil }
      }
      .task(id: wave?.time) {
        guard let wave else { return }
        let remaining = max(0, wave.time + StreamingTextRevealStyle.duration - CACurrentMediaTime())
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        guard !Task.isCancelled, self.wave?.time == wave.time else { return }
        self.wave = nil
      }
  }
}

/// A finite, drawing-only animation. SwiftUI retains the laid-out text; no
/// parsing, string operations or view state mutations run in the renderer.
/// Settled lines/runs use their normal batched draw. Only the small tail fades,
/// in groups of four glyphs to keep drawing work low regardless of response length.
struct StreamingTextRenderer: TextRenderer {
  var remaining: Double
  var tailCount: Int

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    guard remaining > 0, tailCount > 0 else {
      for line in layout { context.draw(line) }
      return
    }
    // Walk backwards only far enough to locate the small animated tail.
    let fadingCount = min(tailCount, StreamingTextWave.maximumTail, Int(ceil(remaining)))
    var glyphsToEnd = 0
    var firstLine = layout.endIndex
    for index in layout.indices.reversed() {
      firstLine = index
      for run in layout[index] { glyphsToEnd += run.count }
      if glyphsToEnd >= fadingCount { break }
    }
    for index in layout.indices {
      let line = layout[index]
      guard index >= firstLine else { context.draw(line); continue }
      // Layout runs are in visual order. Reorder mixed/RTL lines by source
      // position so only the newly appended end fades, in either direction.
      let logicalRuns = line.contains { $0.layoutDirection == .rightToLeft } ? line.sorted {
        guard let lhs = $0.characterIndices.min(), let rhs = $1.characterIndices.min() else { return false }
        return lhs < rhs
      } : nil
      for runIndex in line.indices {
        let run = logicalRuns?[runIndex] ?? line[runIndex]
        let stable = min(run.count, max(0, glyphsToEnd - fadingCount))
        defer { glyphsToEnd -= run.count }
        if stable == run.count {
          context.draw(run)
          continue
        }
        let rtl = run.layoutDirection == .rightToLeft
        if stable > 0 {
          context.draw(rtl ? run[(run.count - stable)..<run.count] : run[0..<stable])
        }
        // Anchor groups to the run so the fading boundary can move without
        // reshuffling every group on each frame.
        for group in stride(from: stable / 4 * 4, to: run.count, by: 4) {
          let start = max(stable, group)
          let end = min(run.count, group + 4)
          let distance = Double(glyphsToEnd - 1 - group)
          var ink = context
          ink.opacity *= StreamingTextRevealStyle.opacity(
            progress: 1 + (distance - remaining) / StreamingTextWave.width)
          ink.draw(rtl ? run[(run.count - end)..<(run.count - start)] : run[start..<end])
        }
      }
    }
  }
}
#endif
