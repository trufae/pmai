import MaiUI
import UIKit

/// UITextView's link/justified-text counterpart to MaiUI's text renderer.
/// Resolve a bounded suffix once after layout, then let Core Animation blend
/// the mask colors. TextKit and attributed text are never touched per frame.
@MainActor
final class StreamingTextMask {
  private struct Arrival {
    var range: NSRange
    let time: TimeInterval
  }

  private struct Fragment {
    let rect: CGRect
    let rtl: Bool
    let time: TimeInterval
    let start: Double
    let end: Double
  }

  private var source = ""
  private var arrivals: [Arrival] = []
  private var needsLayout = false
  private weak var maskedLayer: CALayer?

  func update(_ text: String, enabled: Bool) {
    defer { source = text }
    guard enabled else { clear(); return }
    guard text != source else { return }
    guard text.utf8.starts(with: source.utf8) else { clear(); return }
    let now = CACurrentMediaTime()
    let length = (text as NSString).length
    let start = max((source as NSString).length, length - 192)
    guard start < length else { return }
    let range = (text as NSString).rangeOfComposedCharacterSequences(
      for: NSRange(location: start, length: length - start))
    // Carry the original arrival times across chunks instead of completing
    // their fades early. Retain only a small, recent suffix.
    arrivals.removeAll {
      now - $0.time >= StreamingTextRevealStyle.duration || NSMaxRange($0.range) <= length - 192
    }
    for index in arrivals.indices {
      let lower = max(arrivals[index].range.location, length - 192)
      let upper = min(NSMaxRange(arrivals[index].range), range.location)
      arrivals[index].range = NSRange(location: lower, length: max(0, upper - lower))
    }
    arrivals.removeAll { $0.range.length == 0 }
    arrivals.append(Arrival(range: range, time: now))
    arrivals = Array(arrivals.suffix(StreamingTextRevealStyle.maximumBatches))
    needsLayout = true
  }

  func layout(in view: UITextView) {
    if !needsLayout, let maskedLayer, maskedLayer.mask?.bounds != view.bounds { clear() }
    guard needsLayout, !view.bounds.isEmpty, view.window != nil else { return }
    needsLayout = false
    let now = CACurrentMediaTime()
    var fragments: [Fragment] = []
    for arrival in arrivals where now - arrival.time < StreamingTextRevealStyle.duration {
      guard let start = view.position(from: view.beginningOfDocument, offset: arrival.range.location),
        let end = view.position(from: start, offset: arrival.range.length),
        let selection = view.textRange(from: start, to: end) else { continue }
      let rects = view.selectionRects(for: selection).filter { !$0.rect.isEmpty }.suffix(4)
      let width = max(1, rects.reduce(0) { $0 + $1.rect.width })
      var offset: CGFloat = 0
      for selection in rects {
        fragments.append(Fragment(rect: selection.rect, rtl: selection.writingDirection == .rightToLeft,
          time: arrival.time, start: offset / width, end: (offset + selection.rect.width) / width))
        offset += selection.rect.width
      }
    }
    // Bound compositor work even if the provider emits many tiny chunks.
    fragments = Array(fragments.suffix(16))
    guard !fragments.isEmpty else { clear(); return }

    let mask = CALayer()
    mask.frame = view.bounds
    let settled = CAShapeLayer()
    settled.frame = mask.bounds
    let path = UIBezierPath(rect: mask.bounds)
    for fragment in fragments { path.append(UIBezierPath(rect: fragment.rect)) }
    settled.path = path.cgPath
    settled.fillRule = .evenOdd
    settled.fillColor = UIColor.white.cgColor
    mask.addSublayer(settled)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self, weak view, weak mask] in
      guard let self, let view, let mask, view.layer.mask === mask, !self.needsLayout else { return }
      self.clear()
    }
    for fragment in fragments {
      let gradient = CAGradientLayer()
      gradient.frame = fragment.rect
      gradient.startPoint = CGPoint(x: fragment.rtl ? 1 : 0, y: 0.5)
      gradient.endPoint = CGPoint(x: fragment.rtl ? 0 : 1, y: 0.5)
      gradient.colors = [UIColor.white.cgColor, UIColor.white.cgColor]
      mask.addSublayer(gradient)
      let reveal = CAKeyframeAnimation(keyPath: "colors")
      reveal.values = (0...8).map { step in
        [fragment.start, fragment.end].map { position in
          UIColor.white.withAlphaComponent(StreamingTextRevealStyle.opacity(
            progress: Double(step) / 8, position: position)).cgColor
        }
      }
      reveal.duration = StreamingTextRevealStyle.duration
      reveal.beginTime = gradient.convertTime(fragment.time, from: nil)
      gradient.add(reveal, forKey: "streamingReveal")
    }
    view.layer.mask = mask
    maskedLayer = view.layer
    CATransaction.commit()
  }

  func clear() {
    maskedLayer?.mask = nil
    maskedLayer = nil
    arrivals = []
    needsLayout = false
  }
}
