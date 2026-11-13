import Observation
import SwiftUI

private struct MacScrollPresentation: Equatable {
  var gesture = 0
  var overscroll: CGFloat = 0
  var lag: CGFloat = 0
  var viewportHeight: CGFloat = 1
}

private struct MacScrollSample: Equatable {
  let offset: CGFloat
  let overscroll: CGFloat
  let viewportHeight: CGFloat

  init(_ geometry: ScrollGeometry) {
    let top = -geometry.contentInsets.top
    let bottom = max(top, geometry.contentSize.height - geometry.containerSize.height
      + geometry.contentInsets.bottom)
    let y = geometry.contentOffset.y
    offset = y
    overscroll = y - min(max(y, top), bottom)
    viewportHeight = max(1, geometry.containerSize.height)
  }
}

/// Publish only visual changes to the row modifiers. Raw scroll coordinates and
/// timing must not invalidate the transcript or propagate a new environment.
@MainActor @Observable
private final class MacScrollMotion {
  private(set) var presentation = MacScrollPresentation()
  @ObservationIgnored private var previous: (offset: CGFloat, time: TimeInterval)?
  @ObservationIgnored private var lag: CGFloat = 0
  @ObservationIgnored private var gesture = 0

  func update(_ sample: MacScrollSample) {
    let now = ProcessInfo.processInfo.systemUptime
    if let previous {
      let elapsed = max(1.0 / 240, now - previous.time)
      let target = min(10, max(-10, (sample.offset - previous.offset) / elapsed * 0.006))
      lag += (target - lag) * min(1, elapsed / 0.04)
    } else {
      gesture += 1
    }
    previous = (sample.offset, now)
    // Half-point precision avoids redrawing for imperceptible velocity changes.
    let next = MacScrollPresentation(gesture: gesture, overscroll: (sample.overscroll * 2).rounded() / 2,
      lag: (lag * 2).rounded() / 2, viewportHeight: sample.viewportHeight)
    if next != presentation { presentation = next }
  }

  func reset() {
    previous = nil
    lag = 0
    let resting = MacScrollPresentation(gesture: gesture)
    if presentation != resting { presentation = resting }
  }
}

private struct MacScrollBounceKey: EnvironmentKey {
  static let defaultValue: MacScrollMotion? = nil
}

private extension EnvironmentValues {
  var macScrollBounce: MacScrollMotion? {
    get { self[MacScrollBounceKey.self] }
    set { self[MacScrollBounceKey.self] = newValue }
  }
}

struct MacChatScrollBounce: ViewModifier {
  let phase: ScrollPhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var motion = MacScrollMotion()

  func body(content: Content) -> some View {
    content
      .environment(\.macScrollBounce, motion)
      .scrollBounceBehavior(.always, axes: .vertical)
      .onScrollGeometryChange(for: MacScrollSample.self) { MacScrollSample($0) } action: { _, value in
        if !reduceMotion, phase == .interacting || phase == .decelerating {
          motion.update(value)
        } else {
          motion.reset()
        }
      }
      .onChange(of: phase) { _, phase in
        if phase == .idle || phase == .animating { motion.reset() }
      }
      .onChange(of: reduceMotion) { _, reduced in if reduced { motion.reset() } }
      .onDisappear { motion.reset() }
  }
}

struct MacMessageScrollBounce: ViewModifier {
  private struct Placement: Equatable {
    let gesture: Int
    let position: CGFloat
  }

  @Environment(\.macScrollBounce) private var bounce
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isVisible = false
  @State private var placement: Placement?

  func body(content: Content) -> some View {
    // Offscreen rows do not subscribe to per-frame motion updates.
    let motion = isVisible && !reduceMotion ? bounce?.presentation ?? MacScrollPresentation() : MacScrollPresentation()
    let position = placement?.position ?? 0.5
    let distance = motion.overscroll < 0 ? position : 1 - position
    let resistance = 0.15 + 0.85 * abs(position - 0.5) * 2
    let stretch = 110 * motion.overscroll / (abs(motion.overscroll) + 55)
    let offset = reduceMotion ? 0 : motion.lag * resistance - stretch * distance
    let capture = isVisible && !reduceMotion && placement?.gesture != motion.gesture ? motion.gesture : nil
    content.animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.88)) { content in
      content.offset(y: offset)
    }
    .background {
      // Measure once per gesture (or when entering the viewport), not on every
      // animation frame. This background stays in the row's unshifted layout.
      Color.clear.onGeometryChange(for: Placement?.self) { geometry in
        guard let capture else { return nil }
        let y = geometry.frame(in: .scrollView(axis: .vertical)).midY
        return Placement(gesture: capture, position: min(1, max(0, y / motion.viewportHeight)))
      } action: { _, value in
        if let value { placement = value }
      }
    }
    .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
  }
}
