import SwiftUI

/// Measure a user bubble's natural width before constraining it to the chat.
/// Its Markdown and metadata may still expand within that fitted width.
public struct MessageBubbleLayout: Layout {
  public var fitsContent: Bool

  public init(fitsContent: Bool) { self.fitsContent = fitsContent }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let width = fitsContent
      ? min(proposal.width ?? .infinity, content.sizeThatFits(.unspecified).width)
      : proposal.width
    return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
  }

  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}
