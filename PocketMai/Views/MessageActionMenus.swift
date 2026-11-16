import SwiftUI
import UIKit

extension View {
  func messageActionsMenu(showsButton: Bool, _ menu: @escaping () -> UIMenu) -> some View {
    modifier(MessageActionsMenu(showsButton: showsButton, menu: menu))
  }
}

private struct MessageMenuRequest {
  let id = UUID()
  var windowLocation: CGPoint?
}

private struct MessageActionsMenu: ViewModifier {
  let showsButton: Bool
  let menu: () -> UIMenu
  @State private var request: MessageMenuRequest?

  func body(content: Content) -> some View {
    content
      .frame(minHeight: showsButton ? 44 : nil, alignment: .top)
      .padding(.trailing, showsButton ? 44 : 0)
      .contentShape(.interaction, Rectangle())
      .background(MessageMenuAnchor(request: request, showsButton: showsButton, menu: menu))
      .gesture(MessageMenuLongPress { request = MessageMenuRequest(windowLocation: $0) })
      .accessibilityAction(named: "Message actions") { request = MessageMenuRequest() }
      .overlay(alignment: .topTrailing) {
        if showsButton {
          Button { request = MessageMenuRequest() } label: {
            Image(systemName: "ellipsis")
              .foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Message actions")
        }
      }
  }
}

private struct MessageMenuLongPress: UIGestureRecognizerRepresentable {
  let onPress: (CGPoint) -> Void

  func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
    let recognizer = UILongPressGestureRecognizer()
    recognizer.minimumPressDuration *= 0.5
    return recognizer
  }

  func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
    if recognizer.state == .began {
      onPress(recognizer.location(in: nil))
    }
  }
}

private struct MessageMenuAnchor: UIViewRepresentable {
  let request: MessageMenuRequest?
  let showsButton: Bool
  let menu: () -> UIMenu

  func makeUIView(context: Context) -> AnchorView { AnchorView() }

  func updateUIView(_ view: AnchorView, context: Context) {
    guard let request, request.id != view.lastRequestID else { return }
    view.lastRequestID = request.id
    let point = request.windowLocation.map { view.convert($0, from: nil) } ?? (showsButton
      ? CGPoint(x: view.bounds.maxX - 22, y: view.bounds.minY + 22)
      : CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    view.button.center = point
    view.button.menu = menu()
    view.button.performPrimaryAction()
  }

  final class AnchorView: UIView {
    let button = MenuButton(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    var lastRequestID: UUID?

    override init(frame: CGRect) {
      super.init(frame: frame)
      // Present a pull-down menu from its own anchor. The message is never a
      // context-menu preview, so UIKit cannot lift, hide, or scale it.
      button.showsMenuAsPrimaryAction = true
      button.preferredMenuElementOrder = .fixed
      button.isAccessibilityElement = false
      addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Links, attachments, and scrolling continue to receive their normal taps.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
  }

  final class MenuButton: UIButton {
    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
      CGPoint(x: bounds.midX, y: bounds.midY)
    }
  }
}

@MainActor
enum MessageActionMenus {
  static func action(
    _ title: String, systemImage: String, enabled: Bool = true, destructive: Bool = false,
    perform: @escaping () -> Void
  ) -> UIAction {
    var attributes: UIMenuElement.Attributes = enabled ? [] : [.disabled]
    if destructive { attributes.insert(.destructive) }
    return UIAction(title: title, image: UIImage(systemName: systemImage), attributes: attributes) {
      _ in perform()
    }
  }

  static func details(message: ChatMessage, conversationCreatedAt: Date?) -> UIMenu {
    var rows = [
      "Sender: \(message.role.displayName)",
      "Sent: \(ConversationDatePresentation.timestamp(message.createdAt))",
    ]
    if let conversationCreatedAt {
      rows.append("Chat started: \(ConversationDatePresentation.timestamp(conversationCreatedAt))")
    }
    if let stats = message.stats {
      rows += ["Provider: \(stats.providerLabel)", "Model: \(stats.modelID)", stats.summary]
    }
    if !message.attachments.isEmpty {
      rows.append("Attachments: \(message.attachments.count.formatted())")
    }
    return UIMenu(title: "Details", image: UIImage(systemName: "info.circle"), children: rows.map {
      UIAction(title: $0, attributes: .disabled) { _ in }
    })
  }

  static func speech(
    onSpeakMessage: @escaping (String?) -> Void,
    onSpeakFromHere: ((String?) -> Void)?
  ) -> UIMenu {
    var language: String?
    let choices: [(String, String?)] = [("Default Voices", nil), ("System Default", "")]
      + SystemLanguageSupport.textToSpeechLanguageIdentifiers.map {
        (SystemLanguageSupport.languageDisplayName($0), $0)
      }
    let languages = UIMenu(title: "Language", options: .singleSelection, children: choices.map {
      title, identifier in
      UIAction(
        title: title, attributes: .keepsMenuPresented, state: identifier == nil ? .on : .off
      ) { _ in language = identifier }
    })
    var playback: [UIMenuElement] = [
      action("Only This Message", systemImage: "text.bubble") { onSpeakMessage(language) }
    ]
    if let onSpeakFromHere {
      playback.append(action("All Messages From Here", systemImage: "text.bubble.fill") {
        onSpeakFromHere(language)
      })
    }
    return UIMenu(title: "Speak", image: UIImage(systemName: "speaker.wave.2"), children: [
      languages, UIMenu(options: .displayInline, children: playback),
    ])
  }
}
