#if canImport(SwiftUI)
import SwiftUI

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
  private enum Phase: CaseIterable { case idle, start, finish }
  let source: String
  @Environment(\.isStreamingResponse) private var streaming
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var tailCount = 0
  @State private var revision = 0

  private var enabled: Bool { streaming && !reduceMotion && scenePhase == .active }

  func body(content: Content) -> some View {
    Group {
      if enabled {
        content.phaseAnimator(Phase.allCases, trigger: revision) { text, phase in
          text.textRenderer(StreamingTextRenderer(
            progress: phase == .start ? 0 : 1, tailCount: tailCount))
        } animation: { phase in
          phase == .finish ? .easeOut(duration: 0.28) : nil
        }
      } else {
        content
      }
    }
      .onChange(of: source, initial: true) { old, new in
        guard enabled else { tailCount = 0; return }
        // Only arrivals animate. Replacements, final formatting, search and
        // history restoration must never conceal existing text.
        let appended: Substring
        if old == new, revision == 0 {
          appended = new.suffix(StreamingTextRenderer.maximumTail)
        } else if new.utf8.starts(with: old.utf8) {
          appended = new.dropFirst(old.count)
        } else {
          tailCount = 0
          return
        }
        tailCount = appended.suffix(StreamingTextRenderer.maximumTail).filter { !$0.isNewline }.count
        if tailCount > 0 { revision &+= 1 }
      }
      .onChange(of: enabled) { _, enabled in
        if !enabled { tailCount = 0 }
      }
  }
}

/// A finite, drawing-only animation. SwiftUI retains the laid-out text; no
/// timers, tasks, parsing, string operations or view state mutations run here.
/// Settled lines/runs use their normal batched draw. At most 96 new glyphs get
/// individual opacity values, regardless of the response length.
struct StreamingTextRenderer: TextRenderer {
  static let maximumTail = 96
  var progress: Double
  var tailCount: Int

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    guard progress < 1, tailCount > 0 else {
      for line in layout { context.draw(line) }
      return
    }
    // Walk backwards only far enough to locate the small animated tail.
    var remaining = min(tailCount, Self.maximumTail)
    var firstLine = layout.endIndex
    for index in layout.indices.reversed() {
      firstLine = index
      for run in layout[index] { remaining -= run.count }
      if remaining <= 0 { break }
    }
    let count = min(tailCount, Self.maximumTail) - max(0, remaining)
    var offset = min(0, remaining)
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
          let position = Double(max(0, offset + glyph)) / Double(max(1, count))
          let alpha = min(1, max(0, progress * 1.8 - position * 0.8))
          var ink = context
          ink.opacity *= 0.18 + 0.82 * alpha * alpha * (3 - 2 * alpha)
          ink.draw(run[rtl ? run.count - 1 - glyph : glyph])
        }
        offset += run.count
      }
    }
  }
}
#endif
