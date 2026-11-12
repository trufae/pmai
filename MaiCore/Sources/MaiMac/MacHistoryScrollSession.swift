import AppKit
import SwiftUI

/// Keep the same text under the reader while prepended Markdown finishes layout.
@MainActor
final class MacHistoryScrollSession {
  private let markers = NSMapTable<NSUUID, NSView>.strongToWeakObjects()
  private weak var anchor: NSView?
  private var viewportY: CGFloat = 0

  func attach(_ view: NSView, id: UUID) { markers.setObject(view, forKey: id as NSUUID) }
  func cancel() { anchor = nil }

  func prepareForPrepend(id: UUID) -> Bool {
    // Keep the original anchor if another page is needed to fill the viewport.
    if let anchor {
      return (anchor.enclosingScrollView?.contentView.bounds.minY ?? .infinity) < 160
    }
    guard let view = markers.object(forKey: id as NSUUID),
      let scroll = view.enclosingScrollView, let document = scroll.documentView,
      scroll.contentView.bounds.minY < 160 else { return false }
    anchor = view
    viewportY = view.convert(.zero, to: document).y - scroll.contentView.bounds.minY
    return true
  }

  func restore() {
    guard let anchor, let scroll = anchor.enclosingScrollView,
      let document = scroll.documentView else { return }
    let clip = scroll.contentView
    let target = anchor.convert(.zero, to: document).y - viewportY
    let minimum = -scroll.contentInsets.top
    let maximum = max(minimum, document.bounds.height - clip.bounds.height + scroll.contentInsets.bottom)
    let y = min(max(minimum, target), maximum)
    guard abs(y - clip.bounds.minY) > 0.5 else { return }
    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
    scroll.reflectScrolledClipView(clip)
  }
}

struct MacHistoryScrollMarker: NSViewRepresentable {
  let session: MacHistoryScrollSession
  let id: UUID

  func makeNSView(context: Context) -> NSView { MarkerView() }

  func updateNSView(_ view: NSView, context: Context) {
    session.attach(view, id: id)
  }

  private final class MarkerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
