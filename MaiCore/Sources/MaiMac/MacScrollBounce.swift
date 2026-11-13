import SwiftUI

/// Keep scroll samples separate from the visual offsets so springs cannot change layout.
private struct MacScrollBounce: Equatable {
  var offset: CGFloat = 0
  var overscroll: CGFloat = 0
  var lag: CGFloat = 0
  var viewportHeight: CGFloat = 1

  init() {}

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

private struct MacScrollBounceKey: EnvironmentKey {
  static let defaultValue = MacScrollBounce()
}

private extension EnvironmentValues {
  var macScrollBounce: MacScrollBounce {
    get { self[MacScrollBounceKey.self] }
    set { self[MacScrollBounceKey.self] = newValue }
  }
}

struct MacChatScrollBounce: ViewModifier {
  let phase: ScrollPhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var bounce = MacScrollBounce()
  @State private var lastSampleTime: TimeInterval?

  func body(content: Content) -> some View {
    content
      .environment(\.macScrollBounce, bounce)
      .scrollBounceBehavior(.always, axes: .vertical)
      .onScrollGeometryChange(for: MacScrollBounce.self) { MacScrollBounce($0) } action: { _, value in
        let now = ProcessInfo.processInfo.systemUptime
        var next = value
        if !reduceMotion, phase == .interacting || phase == .decelerating {
          if let lastSampleTime {
            let elapsed = max(1.0 / 240, now - lastSampleTime)
            let velocity = (value.offset - bounce.offset) / elapsed
            next.lag = min(32, max(-32, velocity * 0.018))
          }
        } else {
          next.overscroll = 0
        }
        bounce = next
        lastSampleTime = now
      }
      .onChange(of: phase) { _, phase in
        if phase == .idle || phase == .animating {
          bounce.lag = 0
          bounce.overscroll = 0
          lastSampleTime = nil
        }
      }
  }
}

struct MacMessageScrollBounce: ViewModifier {
  @Environment(\.macScrollBounce) private var bounce
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let motion = bounce
    let reduced = reduceMotion
    content.animation(reduced ? nil : .spring(response: 0.38, dampingFraction: 0.64)) { content in
      content.visualEffect { effect, geometry in
        let frame = geometry.frame(in: .scrollView(axis: .vertical))
        let position = min(1, max(0, frame.midY / motion.viewportHeight))
        let distance = motion.overscroll < 0 ? position : 1 - position
        // Nearby rows follow the gesture; farther rows trail and spread apart at the edge.
        let resistance = 0.15 + 0.85 * abs(position - 0.5) * 2
        let stretch = 110 * motion.overscroll / (abs(motion.overscroll) + 55)
        return effect.offset(y: reduced ? 0 : motion.lag * resistance - stretch * distance)
      }
    }
  }
}
