import UIKit

/// UITextView's link/justified-text counterpart to MaiUI's text renderer.
/// Resolve a bounded suffix once after layout, then let Core Animation blend
/// the mask colors. TextKit and attributed text are never touched per frame.
@MainActor
final class StreamingTextMask {
  private var source = ""
  private var pendingRange: NSRange?
  private weak var maskedLayer: CALayer?

  func update(_ text: String, enabled: Bool) {
    defer { source = text }
    guard enabled else { clear(); return }
    guard text != source else { return }
    clear()
    guard text.utf8.starts(with: source.utf8) else { return }
    let length = (text as NSString).length
    let start = max((source as NSString).length, length - 192)
    guard start < length else { return }
    pendingRange = (text as NSString).rangeOfComposedCharacterSequences(
      for: NSRange(location: start, length: length - start))
  }

  func layout(in view: UITextView) {
    if let maskedLayer, maskedLayer.mask?.bounds != view.bounds { clear() }
    guard let range = pendingRange, !view.bounds.isEmpty, view.window != nil else { return }
    pendingRange = nil
    guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
      let end = view.position(from: start, offset: range.length),
      let selection = view.textRange(from: start, to: end)
    else { return }
    let rects = view.selectionRects(for: selection).filter { !$0.rect.isEmpty }.suffix(4)
    guard !rects.isEmpty else { return }

    let mask = CALayer()
    mask.frame = view.bounds
    let settled = CAShapeLayer()
    settled.frame = mask.bounds
    let path = UIBezierPath(rect: mask.bounds)
    for selection in rects { path.append(UIBezierPath(rect: selection.rect)) }
    settled.path = path.cgPath
    settled.fillRule = .evenOdd
    settled.fillColor = UIColor.white.cgColor
    mask.addSublayer(settled)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self, weak view, weak mask] in
      guard let self, let view, let mask, view.layer.mask === mask else { return }
      self.clear()
    }
    for selection in rects {
      let gradient = CAGradientLayer()
      gradient.frame = selection.rect
      let rtl = selection.writingDirection == .rightToLeft
      gradient.startPoint = CGPoint(x: rtl ? 1 : 0, y: 0.5)
      gradient.endPoint = CGPoint(x: rtl ? 0 : 1, y: 0.5)
      gradient.colors = [UIColor.white.cgColor, UIColor.white.cgColor]
      mask.addSublayer(gradient)
      let reveal = CABasicAnimation(keyPath: "colors")
      reveal.fromValue = [UIColor.white.withAlphaComponent(0.5).cgColor,
        UIColor.white.withAlphaComponent(0.18).cgColor]
      reveal.toValue = gradient.colors
      reveal.duration = 0.28
      reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
      gradient.add(reveal, forKey: "streamingReveal")
    }
    view.layer.mask = mask
    maskedLayer = view.layer
    CATransaction.commit()
  }

  func clear() {
    maskedLayer?.mask = nil
    maskedLayer = nil
    pendingRange = nil
  }
}
