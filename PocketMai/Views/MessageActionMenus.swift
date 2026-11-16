import SwiftUI
import UIKit

extension View {
  func messageActionsMenu(_ menu: @escaping () -> UIMenu) -> some View {
    modifier(MessageActionsMenu(menu: menu))
  }
}

private struct MessageMenuRequest {
  let id = UUID()
  var windowLocation: CGPoint?
}

private struct MessageActionsMenu: ViewModifier {
  let menu: () -> UIMenu
  @State private var request: MessageMenuRequest?

  func body(content: Content) -> some View {
    content
      .contentShape(.interaction, Rectangle())
      .background(MessageMenuAnchor(request: request, menu: menu))
      .gesture(MessageMenuLongPress { request = MessageMenuRequest(windowLocation: $0) })
      .accessibilityAction(named: "Message actions") { request = MessageMenuRequest() }
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
  let menu: () -> UIMenu

  func makeUIView(context: Context) -> AnchorView { AnchorView() }

  func updateUIView(_ view: AnchorView, context: Context) {
    guard let request, request.id != view.lastRequestID else { return }
    view.lastRequestID = request.id
    let point = request.windowLocation.map { view.convert($0, from: nil) }
      ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
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

    override func layoutSubviews() {
      super.layoutSubviews()
      button.backdrop?.setNeedsLayout()
    }
  }

  final class MenuButton: UIButton {
    var backdrop: MessageMenuBackdrop?

    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
      CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      willDisplayMenuFor configuration: UIContextMenuConfiguration,
      animator: (any UIContextMenuInteractionAnimating)?
    ) {
      super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
      guard let messageView = superview, let window else { return }
      backdrop?.removeFromSuperview()
      let backdrop = MessageMenuBackdrop(messageView: messageView, frame: window.bounds)
      self.backdrop = backdrop
      // Stay above the app content but below UIKit's menu presentation.
      var contentRoot = messageView
      while let parent = contentRoot.superview, parent !== window { contentRoot = parent }
      window.insertSubview(backdrop, aboveSubview: contentRoot)
      backdrop.layoutIfNeeded()
      if let animator {
        backdrop.alpha = 0
        animator.addAnimations { backdrop.alpha = 1 }
      }
    }

    override func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      willEndFor configuration: UIContextMenuConfiguration,
      animator: (any UIContextMenuInteractionAnimating)?
    ) {
      super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
      guard let backdrop else { return }
      self.backdrop = nil
      if let animator {
        animator.addAnimations { backdrop.alpha = 0 }
        animator.addCompletion { backdrop.removeFromSuperview() }
      } else {
        backdrop.removeFromSuperview()
      }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil {
        backdrop?.removeFromSuperview()
        backdrop = nil
      }
    }
  }
}

private final class MessageMenuBackdrop: UIVisualEffectView {
  private weak var messageView: UIView?
  private let cutout = UIView()
  private let shape = CAShapeLayer()
  private var blurAnimator: UIViewPropertyAnimator?

  init(messageView: UIView, frame: CGRect) {
    self.messageView = messageView
    super.init(effect: nil)
    self.frame = frame
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    shape.fillRule = .evenOdd
    cutout.layer.addSublayer(shape)
    mask = cutout
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    blurAnimator?.stopAnimation(true)
    blurAnimator = nil
    guard window != nil else { return }
    effect = nil
    // A partially applied material softly blurs the surroundings without
    // obscuring them. The original message stays live through the mask.
    let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
      self?.effect = UIBlurEffect(style: .systemUltraThinMaterial)
    }
    animator.startAnimation()
    animator.pauseAnimation()
    animator.fractionComplete = 0.08
    blurAnimator = animator
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    cutout.frame = bounds
    shape.frame = bounds
    let path = UIBezierPath(rect: bounds)
    if let messageView {
      var visibleRect = messageView.convert(messageView.bounds, to: self).intersection(bounds)
      var ancestor = messageView.superview
      while let view = ancestor {
        if view.clipsToBounds {
          visibleRect = visibleRect.intersection(view.convert(view.bounds, to: self))
        }
        ancestor = view.superview
      }
      if !visibleRect.isNull && !visibleRect.isEmpty {
        path.append(UIBezierPath(rect: visibleRect))
      }
    }
    shape.path = path.cgPath
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
