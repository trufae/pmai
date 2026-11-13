import SwiftUI
import UIKit

/// Install the session in the app's scene, independently of sheets or chat navigation.
struct WebXDCPresentationHost: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    WebXDCWindowAttachment(session: store.activeWebXDCSession).allowsHitTesting(false)
  }
}

private struct WebXDCWindowAttachment: UIViewRepresentable {
  let session: WebXDCRunningSession?

  func makeUIView(context: Context) -> AttachmentView { AttachmentView() }
  func updateUIView(_ view: AttachmentView, context: Context) {
    view.session = session
    view.attach()
  }

  final class AttachmentView: UIView {
    weak var session: WebXDCRunningSession?
    override func didMoveToWindow() { super.didMoveToWindow(); attach() }
    func attach() { if let window { session?.attach(to: window) } }
  }
}

@MainActor
final class WebXDCPresentationController {
  private weak var session: WebXDCRunningSession?
  private weak var previousWindow: UIWindow?
  private let window: WebXDCOverlayWindow
  private var activationObserver: NSObjectProtocol?

  init(session: WebXDCRunningSession, store: AppStore, scene: UIWindowScene, previousWindow: UIWindow) {
    self.session = session
    self.previousWindow = previousWindow
    window = WebXDCOverlayWindow(windowScene: scene)
    window.windowLevel = .normal + 1
    window.backgroundColor = .clear
    let content = WebXDCRunnerOverlay(session: session) { [weak window] frame in
      window?.hitRegion = frame
    }
    .environmentObject(store)
    .preferredColorScheme(store.settings.appearance.theme.colorScheme)
    let host = UIHostingController(rootView: content)
    host.view.backgroundColor = .clear
    window.rootViewController = host
    activationObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak session] _ in
      MainActor.assumeIsolated {
        if session?.pendingApprovalMessage != nil { session?.present(.fullScreen) }
      }
    }
  }

  func update() {
    guard let session else { return }
    let hidden = session.presentation == .closed || session.presentation == .pictureInPicture
    let wasKey = window.isKeyWindow
    window.isHidden = hidden
    if hidden {
      if wasKey { previousWindow?.makeKey() }
    } else if session.presentation == .fullScreen {
      window.makeKeyAndVisible()
    } else {
      window.endEditing(true)
      previousWindow?.makeKey()
    }
  }

  func stop() {
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    activationObserver = nil
    let wasKey = window.isKeyWindow
    window.isHidden = true
    window.rootViewController = nil
    if wasKey { previousWindow?.makeKey() }
  }
}

private final class WebXDCOverlayWindow: UIWindow {
  var hitRegion = CGRect.zero

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    // Sheets and permission dialogs remain modal. The rest of the floating
    // window lets touches reach the chat, including its composer and scrolling.
    if rootViewController?.presentedViewController == nil, !hitRegion.contains(point) { return nil }
    let hit = super.hitTest(point, with: event)
    if hit != nil, event?.type == .touches, !isKeyWindow { makeKey() }
    return hit
  }
}

private struct WebXDCRunnerOverlay: View {
  @ObservedObject var session: WebXDCRunningSession
  let onFrame: (CGRect) -> Void
  @State private var origin: CGPoint?
  @State private var dragOrigin: CGPoint?
  @State private var floatingSize = CGSize(width: 320, height: 400)
  @State private var resizeStart: CGSize?

  var body: some View {
    GeometryReader { geometry in
      let compact = session.presentation != .fullScreen
      let size = compact
        ? CGSize(width: min(floatingSize.width, geometry.size.width - 16),
            height: min(floatingSize.height, geometry.size.height - 16))
        : geometry.size
      let position = compact ? bounded(origin ?? CGPoint(x: geometry.size.width - size.width - 8, y: 8),
        size: size, in: geometry.size) : .zero
      WebXDCRunnerSheet(session: session) { translation, ended in
        guard compact else { return }
        let start = dragOrigin ?? position
        dragOrigin = start
        origin = bounded(CGPoint(x: start.x + translation.width, y: start.y + translation.height),
          size: size, in: geometry.size)
        if ended { dragOrigin = nil }
      }
      .overlay(alignment: .bottomTrailing) {
        if compact {
          Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.caption).padding(10).background(.regularMaterial, in: Circle())
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
              let start = resizeStart ?? size
              resizeStart = start
              floatingSize = CGSize(width: max(240, start.width + value.translation.width),
                height: max(220, start.height + value.translation.height))
            }.onEnded { _ in resizeStart = nil })
            .accessibilityLabel("Resize floating app")
            .accessibilityAdjustableAction { direction in
              let delta: CGFloat = direction == .increment ? 40 : -40
              floatingSize = CGSize(width: max(240, size.width + delta), height: max(220, size.height + delta))
            }
        }
      }
      .frame(width: max(1, size.width), height: max(1, size.height))
      .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 0))
      .overlay { if compact { RoundedRectangle(cornerRadius: 18).stroke(.tint.opacity(0.5), lineWidth: 1) } }
      .shadow(color: .black.opacity(compact ? 0.22 : 0), radius: 14, y: 4)
      .offset(x: position.x, y: position.y)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
    }
  }

  private func bounded(_ point: CGPoint, size: CGSize, in available: CGSize) -> CGPoint {
    CGPoint(x: min(max(8, point.x), max(8, available.width - size.width - 8)),
      y: min(max(8, point.y), max(8, available.height - size.height - 8)))
  }
}
