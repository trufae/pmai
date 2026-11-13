import SwiftUI

/// Keep expanded tool activity inside the transcript without letting a long
/// run push the surrounding messages off screen.
public struct ActivityScrollView<Content: View>: View {
  @ViewBuilder private var content: () -> Content
  @State private var contentHeight: CGFloat = 44

  public init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }

  public var body: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 8, content: content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .frame(height: min(contentHeight, 320))
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .scrollBounceBehavior(.basedOnSize)
  }
}

public extension View {
  func activityScrollFrame(accentColor: Color = .accentColor) -> some View {
    padding(12)
      .background(accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).strokeBorder(accentColor.opacity(0.6), lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}
