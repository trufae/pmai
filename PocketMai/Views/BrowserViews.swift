import SwiftUI
import WebKit

/// Hosts the session's web view at its fixed viewport size and scales it to
/// whatever frame SwiftUI provides, so the page layout and the coordinates the
/// model works with stay the same in the card and in the expanded view.
struct BrowserWebViewHost: UIViewRepresentable {
  let session: BrowserSession
  let interactive: Bool
  /// Mirrors `session.isExpanded`. SwiftUI only calls `updateUIView` when a
  /// field changed, and this is the change that moves the page between hosts.
  let isExpanded: Bool

  func makeUIView(context: Context) -> BrowserHostView {
    BrowserHostView()
  }

  func updateUIView(_ view: BrowserHostView, context: Context) {
    // Exactly one host owns the page at a time: the expanded view while it is
    // open, the card otherwise. The other host leaves the view alone so they
    // do not keep stealing it from each other on every re-render.
    guard !session.isClosed, interactive == isExpanded else { return }
    view.adopt(session.webView, viewportSize: session.viewportSize, interactive: interactive)
  }

  static func dismantleUIView(_ view: BrowserHostView, coordinator: ()) {
    view.release()
  }
}

final class BrowserHostView: UIView {
  private weak var webView: WKWebView?
  private var viewportSize: CGSize = .zero

  func adopt(_ webView: WKWebView, viewportSize: CGSize, interactive: Bool) {
    self.viewportSize = viewportSize
    if webView.superview !== self {
      addSubview(webView)
    }
    self.webView = webView
    webView.isHidden = false
    webView.isUserInteractionEnabled = interactive
    clipsToBounds = true
    setNeedsLayout()
  }

  /// Lets go of the page when this host disappears so a torn-down view
  /// hierarchy never keeps it; the surviving host re-adopts it.
  func release() {
    guard let webView, webView.superview === self else { return }
    webView.removeFromSuperview()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let webView, webView.superview === self,
      viewportSize.width > 0, viewportSize.height > 0,
      bounds.width > 0, bounds.height > 0
    else {
      return
    }
    let scale = min(bounds.width / viewportSize.width, bounds.height / viewportSize.height)
    webView.transform = .identity
    webView.frame = CGRect(origin: .zero, size: viewportSize)
    webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }
}

/// Stays mounted even when the card is minimized, keeping the fullscreen
/// presenter independent of the card's visibility and the selected chat.
struct BrowserPresentationOverlay: View {
  @ObservedObject var session: BrowserSession
  let onClose: () -> Void

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .bottomTrailing) {
        if session.presentation != .minimized {
          BrowserPiPCard(session: session, availableSize: proxy.size, onClose: onClose)
            .padding(12)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
    }
    .fullScreenCover(isPresented: expandedBinding) {
      BrowserExpandedView(session: session)
    }
  }

  private var expandedBinding: Binding<Bool> {
    Binding {
      session.isExpanded
    } set: { expanded in
      if expanded {
        session.presentation = .expanded
      } else if session.isExpanded {
        session.presentation = .pictureInPicture
      }
    }
  }
}

/// A persistent toolbar entry, including while the page is minimized.
struct BrowserToolbarButton: View {
  @ObservedObject var session: BrowserSession
  let onClose: () -> Void
  @State private var showingCloseConfirmation = false

  var body: some View {
    Button {
      withAnimation(.snappy) {
        session.presentation = session.presentation == .minimized ? .pictureInPicture : .minimized
      }
    } label: {
      Image(systemName: "safari")
    }
    .accessibilityLabel(session.presentation == .minimized ? "Reopen browser" : "Minimize browser")
    .help(session.displayHost)
    .contextMenu {
      Button("Show Picture in Picture", systemImage: "pip") {
        session.presentation = .pictureInPicture
      }
      Button("Expand Browser", systemImage: "arrow.up.left.and.arrow.down.right") {
        session.presentation = .expanded
      }
      Button("Minimize to Toolbar", systemImage: "minus") {
        session.presentation = .minimized
      }
      Button("Close Browser…", systemImage: "xmark", role: .destructive) {
        showingCloseConfirmation = true
      }
    }
    .modifier(BrowserCloseConfirmation(isPresented: $showingCloseConfirmation, onClose: onClose))
  }
}

private struct BrowserCloseConfirmation: ViewModifier {
  @Binding var isPresented: Bool
  let onClose: () -> Void

  func body(content: Content) -> some View {
    content.alert("Close browser?", isPresented: $isPresented) {
      Button("Cancel", role: .cancel) {}
      Button("Close Browser", role: .destructive, action: onClose)
    } message: {
      Text(
        "This will end the current browser session. You can reopen the last page from the chat toolbar."
      )
    }
  }
}

/// The live preview can be dragged and pinched between three sizes. Its
/// position and size are retained by the session when the card disappears.
struct BrowserPiPCard: View {
  @ObservedObject var session: BrowserSession
  let availableSize: CGSize
  let onClose: () -> Void

  @GestureState private var dragTranslation: CGSize = .zero
  @GestureState private var magnification: CGFloat = 1
  @State private var showingCloseConfirmation = false

  private let captionHeight: CGFloat = 26

  private var cardSize: CGSize {
    let width = min(max(session.pipSize.width * magnification, 150), 280)
    let aspectRatio = session.viewportSize.height / session.viewportSize.width
    let fittedWidth = max(
      1,
      min(
        width, availableSize.width - 24,
        (availableSize.height - 24 - captionHeight) / aspectRatio))
    return CGSize(width: fittedWidth, height: fittedWidth * aspectRatio + captionHeight)
  }

  private var offset: CGSize {
    Self.clampedOffset(
      CGSize(
        width: session.pipOffset.width + dragTranslation.width,
        height: session.pipOffset.height + dragTranslation.height),
      cardSize: cardSize, availableSize: availableSize)
  }

  /// Offsets are relative to the bottom-right corner of the available area.
  static func clampedOffset(_ offset: CGSize, cardSize: CGSize, availableSize: CGSize) -> CGSize {
    CGSize(
      width: min(0, max(offset.width, -max(0, availableSize.width - cardSize.width - 24))),
      height: min(0, max(offset.height, -max(0, availableSize.height - cardSize.height - 24))))
  }

  var body: some View {
    VStack(spacing: 0) {
      BrowserWebViewHost(session: session, interactive: false, isExpanded: session.isExpanded)
        .frame(width: cardSize.width, height: cardSize.height - captionHeight)
        .allowsHitTesting(false)
      HStack(spacing: 5) {
        if session.isLoading {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "safari")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(session.lastActivity.isEmpty ? session.displayHost : session.lastActivity)
          .font(.caption2)
          .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .frame(height: captionHeight)
      .background(.thinMaterial)
    }
    .frame(width: cardSize.width, height: cardSize.height)
    .background(Color(uiColor: .systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.quaternary)
    )
    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    .overlay(alignment: .topTrailing) {
      HStack(spacing: 6) {
        Button {
          withAnimation(.snappy) { session.presentation = .minimized }
        } label: {
          Image(systemName: "minus.circle.fill")
        }
        .accessibilityLabel("Minimize browser to toolbar")
        Button {
          showingCloseConfirmation = true
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .accessibilityLabel("Close browser")
      }
      .font(.title3)
      .symbolRenderingMode(.palette)
      .foregroundStyle(.white, .black.opacity(0.55))
      .buttonStyle(.plain)
      .padding(6)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      session.presentation = .expanded
    }
    .offset(x: offset.width, y: offset.height)
    .gesture(
      DragGesture(minimumDistance: 6)
        .updating($dragTranslation) { value, translation, _ in
          translation = value.translation
        }
        .onEnded { value in
          session.pipOffset = Self.clampedOffset(
            CGSize(
              width: session.pipOffset.width + value.translation.width,
              height: session.pipOffset.height + value.translation.height),
            cardSize: cardSize, availableSize: availableSize)
        }
    )
    .simultaneousGesture(
      MagnifyGesture()
        .updating($magnification) { value, magnification, _ in
          magnification = value.magnification
        }
        .onEnded { value in
          withAnimation(.snappy) {
            session.pipSize = session.pipSize.resized(for: value.magnification)
          }
        }
    )
    .modifier(BrowserCloseConfirmation(isPresented: $showingCloseConfirmation, onClose: onClose))
    .accessibilityAction(named: "Increase preview size") {
      session.pipSize = session.pipSize.resized(for: 1.3)
    }
    .accessibilityAction(named: "Decrease preview size") {
      session.pipSize = session.pipSize.resized(for: 0.7)
    }
    .accessibilityAction(named: "Minimize to toolbar") {
      session.presentation = .minimized
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "Browser preview of \(session.displayHost). Tap to expand, pinch to resize.")
  }
}

/// Full-size, hand-operated presentation of the page.
struct BrowserExpandedView: View {
  @ObservedObject var session: BrowserSession

  @Environment(\.dismiss) private var dismiss
  @State private var addressText = ""
  @FocusState private var addressFocused: Bool

  var body: some View {
    NavigationStack {
      BrowserWebViewHost(session: session, interactive: true, isExpanded: session.isExpanded)
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
          addressBar
        }
        .navigationTitle(session.title.isEmpty ? "Browser" : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              session.presentation = .pictureInPicture
              dismiss()
            } label: {
              Label("Minimize", systemImage: "pip.exit")
            }
            .help("Back to the small card")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              session.presentation = .pictureInPicture
              dismiss()
            } label: {
              Label("Close", systemImage: "xmark")
            }
            .accessibilityLabel("Return browser to picture in picture")
            .help("Back to the small card")
          }
        }
    }
    .onAppear {
      addressText = session.currentURL?.absoluteString ?? ""
    }
    .onChange(of: session.currentURL) { _, url in
      guard !addressFocused else { return }
      addressText = url?.absoluteString ?? ""
    }
  }

  private var addressBar: some View {
    HStack(spacing: 8) {
      Button {
        Task { await session.goBack() }
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled(!session.canGoBack)
      Button {
        session.goForward()
      } label: {
        Image(systemName: "chevron.right")
      }
      .disabled(!session.canGoForward)
      TextField("Address", text: $addressText)
        .textFieldStyle(.roundedBorder)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .focused($addressFocused)
        .onSubmit {
          session.load(urlString: addressText)
          addressFocused = false
        }
      if session.isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Button {
          session.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }
}
