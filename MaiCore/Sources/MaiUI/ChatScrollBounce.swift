import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

private struct ScrollPresentation: Equatable {
  var gesture = 0
  var overscroll: CGFloat = 0
  var lag: CGFloat = 0
  var viewportHeight: CGFloat = 1
}

private struct ScrollSample: Equatable {
  let offset: CGFloat
  let overscroll: CGFloat
  let viewportHeight: CGFloat

  init(offset: CGFloat, overscroll: CGFloat, viewportHeight: CGFloat) {
    self.offset = offset
    self.overscroll = overscroll
    self.viewportHeight = max(1, viewportHeight)
  }

  init(_ geometry: ScrollGeometry) {
    let top = -geometry.contentInsets.top
    // The container excludes safe-area insets; visibleRect is the full viewport.
    let bottom = max(top, geometry.contentSize.height - geometry.visibleRect.height
      + geometry.contentInsets.bottom)
    let y = geometry.contentOffset.y
    offset = y
    overscroll = y - min(max(y, top), bottom)
    viewportHeight = max(1, geometry.visibleRect.height)
  }
}

/// Publish only visual changes to the row modifiers. Raw scroll coordinates and
/// timing must not invalidate the transcript or propagate a new environment.
@MainActor @Observable
private final class ScrollMotion {
  private(set) var presentation = ScrollPresentation()
  private(set) var edgePresentation = ScrollPresentation()
  @ObservationIgnored private var previous: (offset: CGFloat, overscroll: CGFloat, time: TimeInterval)?
  @ObservationIgnored private var lag: CGFloat = 0
  @ObservationIgnored private var gesture = 0
  @ObservationIgnored let isList: Bool
  @ObservationIgnored let coordinateSpace = UUID()
#if os(macOS)
  @ObservationIgnored var listObserver: NativeListScrollObserver?
#endif

  init(isList: Bool = false) {
    self.isList = isList
  }

  func update(_ sample: ScrollSample) {
    let now = ProcessInfo.processInfo.systemUptime
    if let previous {
      // Recapture the visible rows when a long gesture reaches an edge.
      if previous.overscroll == 0, sample.overscroll != 0 { gesture += 1 }
      let elapsed = max(1.0 / 240, now - previous.time)
      let target = min(16, max(-16, (sample.offset - previous.offset) / elapsed * 0.010))
      lag += (target - lag) * min(1, elapsed / 0.04)
    } else {
      gesture += 1
    }
    previous = (sample.offset, sample.overscroll, now)
    // Half-point precision avoids redrawing for imperceptible velocity changes.
    let next = ScrollPresentation(gesture: gesture, overscroll: (sample.overscroll * 2).rounded() / 2,
      lag: (lag * 2).rounded() / 2, viewportHeight: sample.viewportHeight)
    if next != presentation { presentation = next }
    // Offscreen neighbors must stretch too, otherwise a visible bubble can
    // overlap them as it moves beyond the viewport. They ignore normal scrolling.
    if next.overscroll != 0 || edgePresentation.overscroll != 0 {
      let edge = ScrollPresentation(gesture: gesture, overscroll: next.overscroll,
        viewportHeight: next.viewportHeight)
      if edge != edgePresentation { edgePresentation = edge }
    }
  }

  func reset() {
    previous = nil
    lag = 0
    let resting = ScrollPresentation(gesture: gesture)
    if presentation != resting { presentation = resting }
    if edgePresentation != resting { edgePresentation = resting }
  }
}

private struct ScrollBounceKey: EnvironmentKey {
  static let defaultValue: ScrollMotion? = nil
}

private extension EnvironmentValues {
  var chatScrollMotion: ScrollMotion? {
    get { self[ScrollBounceKey.self] }
    set { self[ScrollBounceKey.self] = newValue }
  }
}

private struct ChatScrollBounce: ViewModifier {
  let phase: ScrollPhase
  let enabled: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var motion = ScrollMotion()

  func body(content: Content) -> some View {
    content
      .environment(\.chatScrollMotion, motion)
      .scrollBounceBehavior(.always, axes: .vertical)
      .onScrollGeometryChange(for: ScrollSample.self) { ScrollSample($0) } action: { _, value in
        if enabled, !reduceMotion, phase == .interacting || phase == .decelerating {
          motion.update(value)
        } else {
          motion.reset()
        }
      }
      .onChange(of: phase) { _, phase in
        if phase == .idle || phase == .animating { motion.reset() }
      }
      .onChange(of: reduceMotion) { _, reduced in if reduced { motion.reset() } }
      .onChange(of: enabled) { _, active in if !active { motion.reset() } }
      .onDisappear { motion.reset() }
  }
}

private struct MessageScrollBounce: ViewModifier {
  private struct Placement: Equatable {
    let gesture: Int
    let position: CGFloat
  }

  @Environment(\.chatScrollMotion) private var bounce
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isVisible = false
  @State private var placement: Placement?

  @ViewBuilder func body(content: Content) -> some View {
    if bounce != nil {
      bouncing(content)
    } else {
      content
    }
  }

  private func bouncing(_ content: Content) -> some View {
    // Offscreen rows only follow edge stretching, not per-frame velocity changes.
    let motion = reduceMotion ? ScrollPresentation()
      : (isVisible ? bounce?.presentation : bounce?.edgePresentation) ?? ScrollPresentation()
    let position = placement?.position ?? 0.5
    let distance = motion.overscroll < 0 ? position : 1 - position
    let resistance = 0.15 + 0.85 * abs(position - 0.5) * 2
    let stretch = 180 * motion.overscroll / (abs(motion.overscroll) + 55)
    let offset = reduceMotion ? 0 : motion.lag * resistance - stretch * distance
    let capture = !reduceMotion && (isVisible || motion.overscroll != 0)
      && placement?.gesture != motion.gesture ? motion.gesture : nil
    let listSpace = bounce.flatMap { $0.isList ? $0.coordinateSpace : nil }
    // A bubble or activity panel moves as one unit. Its descendants must not
    // apply the same motion again, even when they contain Markdown blocks.
    return content.environment(\.chatScrollMotion, nil)
    .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.80)) { content in
      content.offset(y: offset)
    }
    .background {
      // Measure once per gesture/edge (or when entering the viewport), not on every
      // animation frame. This background stays in the row's unshifted layout.
      Color.clear.onGeometryChange(for: Placement?.self) { geometry in
        guard let capture else { return nil }
        let y: CGFloat
        if let listSpace {
          y = geometry.frame(in: .named(listSpace)).midY
        } else {
          y = geometry.frame(in: .scrollView(axis: .vertical)).midY
        }
        return Placement(gesture: capture, position: min(1, max(0, y / motion.viewportHeight)))
      } action: { _, value in
        if let value { placement = value }
      }
      .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
      // Native lists recycle their row views but don't publish scroll visibility.
      .onAppear { if bounce?.isList == true { isVisible = true } }
      .onDisappear { isVisible = false }
#if os(macOS)
      if let bounce, bounce.isList {
        NativeListScrollAnchor(motion: bounce).frame(width: 0, height: 0)
      }
#endif
    }
  }
}

#if os(macOS)
/// Keep native List selection and menus while feeding the same spring motion
/// from AppKit's live-scroll notifications, which include momentum scrolling.
private struct NativeListScrollBounce: ViewModifier {
  @State private var motion = ScrollMotion(isList: true)

  func body(content: Content) -> some View {
    content
      .environment(\.chatScrollMotion, motion)
      .coordinateSpace(name: motion.coordinateSpace)
      .scrollBounceBehavior(.always, axes: .vertical)
      .onDisappear {
        motion.listObserver?.detach()
        motion.reset()
      }
  }
}

@MainActor
private final class NativeListScrollObserver: NSObject {
  private weak var motion: ScrollMotion?
  private weak var scroll: NSScrollView?
  private var isScrolling = false

  init(motion: ScrollMotion) { self.motion = motion }

  func attach(to scroll: NSScrollView) {
    guard self.scroll !== scroll else { return }
    detach()
    self.scroll = scroll
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(started),
      name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    center.addObserver(self, selector: #selector(ended),
      name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    center.addObserver(self, selector: #selector(changed),
      name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    scroll.contentView.postsBoundsChangedNotifications = true
  }

  func detach() {
    NotificationCenter.default.removeObserver(self)
    scroll = nil
    isScrolling = false
    motion?.reset()
  }

  @objc private func started(_ notification: Notification) {
    isScrolling = true
    changed(notification)
  }

  @objc private func ended(_ notification: Notification) {
    isScrolling = false
    motion?.reset()
  }

  @objc private func changed(_ notification: Notification) {
    guard isScrolling, let scroll, let document = scroll.documentView else { return }
    let viewport = scroll.contentView.bounds
    let top = -scroll.contentInsets.top
    let bottom = max(top, document.bounds.height - viewport.height + scroll.contentInsets.bottom)
    let offset = viewport.minY
    motion?.update(ScrollSample(offset: offset,
      overscroll: offset - min(max(offset, top), bottom), viewportHeight: viewport.height))
  }

  deinit { NotificationCenter.default.removeObserver(self) }
}

private struct NativeListScrollAnchor: NSViewRepresentable {
  let motion: ScrollMotion

  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) {
    view.motion = motion
    view.attach()
  }

  final class Anchor: NSView {
    var motion: ScrollMotion?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attach()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      attach()
    }

    func attach() {
      guard let motion, let scroll = enclosingScrollView else { return }
      if motion.listObserver == nil { motion.listObserver = NativeListScrollObserver(motion: motion) }
      motion.listObserver?.attach(to: scroll)
      // Let the row move beyond its hosting cell during edge stretching.
      var ancestor = superview
      while let view = ancestor, view !== scroll.documentView {
        view.clipsToBounds = false
        ancestor = view.superview
      }
    }
  }
}
#endif

public extension View {
#if os(macOS)
  func listScrollBounce() -> some View {
    modifier(NativeListScrollBounce())
  }
#endif
  /// Animate visible chat rows without publishing raw scroll coordinates to the view tree.
  func chatScrollBounce(phase: ScrollPhase, enabled: Bool = true) -> some View {
    modifier(ChatScrollBounce(phase: phase, enabled: enabled))
  }

  /// Disable on response containers to let their individual blocks move instead.
  @ViewBuilder func messageScrollBounce(enabled: Bool = true) -> some View {
    if enabled {
      modifier(MessageScrollBounce())
    } else {
      self
    }
  }
}
