import SwiftUI

/// The native scroll view supplies rubber banding; rows add a little independent stretch.
private struct MacScrollBounce: Equatable {
  var overscroll: CGFloat = 0
  var viewportHeight: CGFloat = 1

  init() {}

  init(_ geometry: ScrollGeometry) {
    let top = -geometry.contentInsets.top
    let bottom = max(top, geometry.contentSize.height - geometry.containerSize.height
      + geometry.contentInsets.bottom)
    let y = geometry.contentOffset.y
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var bounce = MacScrollBounce()
  @State private var isUserScrolling = false

  func body(content: Content) -> some View {
    content
      .environment(\.macScrollBounce, bounce)
      .scrollBounceBehavior(.always, axes: .vertical)
      .onScrollGeometryChange(for: MacScrollBounce.self) { MacScrollBounce($0) } action: { _, value in
        bounce = isUserScrolling && !reduceMotion ? value : MacScrollBounce()
      }
      .onScrollPhaseChange { _, phase, context in
        isUserScrolling = phase == .interacting || phase == .decelerating
        bounce = isUserScrolling && !reduceMotion ? MacScrollBounce(context.geometry) : MacScrollBounce()
      }
  }
}

struct MacMessageScrollBounce: ViewModifier {
  @Environment(\.macScrollBounce) private var bounce
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let motion = bounce
    let reduced = reduceMotion
    content.animation(reduced ? nil : .spring(response: 0.34, dampingFraction: 0.72)) { content in
      content.visualEffect { effect, geometry in
        let frame = geometry.frame(in: .scrollView(axis: .vertical))
        let position = min(1, max(0, frame.midY / motion.viewportHeight))
        let distance = motion.overscroll < 0 ? position : 1 - position
        // Saturation keeps long pulls gentle, with more give farther from the pulled edge.
        let stretch = 44 * motion.overscroll / (abs(motion.overscroll) + 100)
        return effect.offset(y: reduced ? 0 : -stretch * (0.2 + 0.8 * distance))
      }
    }
  }
}
