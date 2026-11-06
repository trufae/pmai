import UIKit

extension UIScrollView {
  func clampedContentOffsetY(_ y: CGFloat) -> CGFloat {
    let minimumY = -adjustedContentInset.top
    let maximumY = max(
      minimumY, contentSize.height - bounds.height + adjustedContentInset.bottom)
    return min(max(y, minimumY), maximumY)
  }
}
