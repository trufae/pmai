import SwiftUI

/// Covers the full header with a translucent veil, fading only below its controls.
struct HeaderFadeBlur: View {
  var fadeLength: CGFloat = 56

  var body: some View {
    GeometryReader { proxy in
      Rectangle()
        .fill(.ultraThinMaterial)
        .frame(height: proxy.size.height + fadeLength)
        .mask {
          VStack(spacing: 0) {
            Color.black.opacity(0.8)
              .frame(height: proxy.size.height)
            LinearGradient(
              stops: [
                .init(color: .black.opacity(0.8), location: 0),
                .init(color: .black.opacity(0.6), location: 0.4),
                .init(color: .black.opacity(0.2), location: 0.75),
                .init(color: .clear, location: 1),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
            .frame(height: fadeLength)
          }
        }
    }
    .ignoresSafeArea(.container, edges: .top)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
