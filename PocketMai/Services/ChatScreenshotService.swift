import SwiftUI
import UIKit

@MainActor
final class ChatScreenshotService: NSObject, ObservableObject, UIScreenshotServiceDelegate {
  weak var store: AppStore?
  private weak var installedScene: UIWindowScene?

  func install(on scene: UIWindowScene?) {
    guard installedScene !== scene else { return }
    if installedScene?.screenshotService?.delegate === self {
      installedScene?.screenshotService?.delegate = nil
    }
    installedScene = scene
    scene?.screenshotService?.delegate = self
  }

  func screenshotService(
    _ screenshotService: UIScreenshotService,
    generatePDFRepresentationWithCompletion completionHandler:
      @escaping (
        Data?, Int, CGRect
      ) -> Void
  ) {
    guard
      let store,
      let document = FullChatScreenshotRenderer.makePDF(
        conversation: store.currentConversation,
        showThinking: store.effectiveShowThinking(for: store.currentConversation),
        toolSettings: store.settings.toolSettings,
        appearance: store.settings.appearance,
        renderMarkdown: store.settings.renderMarkdownInChat,
        renderImages: store.settings.renderMarkdownImagesInChat,
        streamingTextStore: store.streamingTextStore,
        scale: installedScene?.screen.scale ?? 1
      )
    else {
      completionHandler(nil, 0, .zero)
      return
    }

    completionHandler(document.data, 0, .zero)
  }
}

struct ChatScreenshotServiceInstaller: UIViewRepresentable {
  let service: ChatScreenshotService

  func makeUIView(context: Context) -> WindowTrackingView {
    let view = WindowTrackingView()
    view.onWindowChange = { [weak service] window in
      MainActor.assumeIsolated {
        service?.install(on: window?.windowScene)
      }
    }
    return view
  }

  func updateUIView(_ uiView: WindowTrackingView, context: Context) {
    uiView.onWindowChange = { [weak service] window in
      MainActor.assumeIsolated {
        service?.install(on: window?.windowScene)
      }
    }
    uiView.notifyWindowChanged()
  }

  final class WindowTrackingView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      notifyWindowChanged()
    }

    func notifyWindowChanged() {
      onWindowChange?(window)
    }
  }
}

private struct FullChatScreenshotDocument {
  let data: Data
}

@MainActor
private enum FullChatScreenshotRenderer {
  fileprivate static let width: CGFloat = 430

  static func makePDF(
    conversation: Conversation?,
    showThinking: Bool,
    toolSettings: NativeToolSettings,
    appearance: AppearanceSettings,
    renderMarkdown: Bool,
    renderImages: Bool,
    streamingTextStore: StreamingTextStore,
    scale: CGFloat
  ) -> FullChatScreenshotDocument? {
    guard let conversation, !conversation.messages.isEmpty else { return nil }

    let content = FullChatScreenshotView(
      conversation: conversation,
      showThinking: showThinking,
      toolSettings: toolSettings,
      appearance: appearance,
      renderMarkdown: renderMarkdown,
      renderImages: renderImages,
      streamingTextStore: streamingTextStore
    )
    .frame(width: width)

    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
    renderer.scale = scale

    var pdfData: Data?
    renderer.render { size, renderInContext in
      guard size.width > 0, size.height > 0 else { return }
      let bounds = CGRect(origin: .zero, size: size)
      let pdfRenderer = UIGraphicsPDFRenderer(bounds: bounds)
      pdfData = pdfRenderer.pdfData { context in
        context.beginPage()
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: 0, y: bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        renderInContext(context.cgContext)
        context.cgContext.restoreGState()
      }
    }

    guard let pdfData else { return nil }
    return FullChatScreenshotDocument(data: pdfData)
  }
}

private struct FullChatScreenshotView: View {
  let conversation: Conversation
  let showThinking: Bool
  let toolSettings: NativeToolSettings
  let appearance: AppearanceSettings
  let renderMarkdown: Bool
  let renderImages: Bool
  let streamingTextStore: StreamingTextStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      VStack(spacing: 14) {
        ForEach(conversation.messages) { message in
          MessageBubble(
            message: message,
            toolSettings: toolSettings,
            openAIEndpoints: [],
            appearance: appearance,
            renderMarkdown: renderMarkdown,
            renderImages: renderImages,
            showThinking: showThinking
          )
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .frame(width: FullChatScreenshotRenderer.width, alignment: .topLeading)
    .background(Color(uiColor: .systemBackground))
    .environmentObject(streamingTextStore)
    .environment(\.isFullChatScreenshotRendering, true)
    .tint(appearance.tintColor)
    .accentColor(appearance.tintColor)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(conversation.displayTitle)
        .font(.headline)
        .lineLimit(2)
      Text("\(conversation.messages.count) messages")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.top, 18)
    .padding(.bottom, 12)
    .background(Color(uiColor: .secondarySystemBackground))
  }
}
