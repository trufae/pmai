import AppKit
import SwiftUI

/// Page the transcript even while the composer owns keyboard focus.
struct MacChatPaging: NSViewRepresentable {
  var onScroll: (Bool) -> Void

  func makeNSView(context: Context) -> PageKeyView { PageKeyView() }

  func updateNSView(_ view: PageKeyView, context: Context) { view.onScroll = onScroll }

  static func dismantleNSView(_ view: PageKeyView, coordinator: ()) { view.stopMonitoring() }

  final class PageKeyView: NSView {
    var onScroll: ((Bool) -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let handled = MainActor.assumeIsolated { self?.handle(event) == true }
        return handled ? nil : event
      }
    }

    func stopMonitoring() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
      guard let window, event.window === window, window.attachedSheet == nil,
        !isHiddenOrHasHiddenAncestor,
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
        key == NSPageUpFunctionKey || key == NSPageDownFunctionKey,
        let scroll = enclosingScrollView, let document = scroll.documentView else { return false }
      let clip = scroll.contentView
      let minimum = -scroll.contentInsets.top
      let maximum = max(minimum, document.bounds.height - clip.bounds.height + scroll.contentInsets.bottom)
      let page = max(1, (clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom) * 0.9)
      let direction: CGFloat = key == NSPageUpFunctionKey ? -1 : 1
      let y = min(maximum, max(minimum, clip.bounds.minY + direction * page))
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
      scroll.reflectScrolledClipView(clip)
      onScroll?(y >= maximum - 1)
      return true
    }
  }
}
