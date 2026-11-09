import AppKit
import SwiftUI

/// Keep AppKit text editing/IME behavior, with the REPL's Return-to-send rule.
struct MacComposer: NSViewRepresentable {
  @Binding var text: String
  var submit: () -> Void
  private var typography = MacChatTypography()

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let editor = ComposerTextView()
    editor.delegate = context.coordinator
    editor.isRichText = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.font = typography.editorFont
    editor.textColor = .textColor
    editor.drawsBackground = false
    editor.textContainerInset = NSSize(width: 0, height: 6)
    editor.textContainer?.lineFragmentPadding = 0
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.setAccessibilityLabel("Message")
    editor.setAccessibilityHelp("Return sends. Shift-Return adds a new line.")
    scroll.documentView = editor
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scroll.documentView as? ComposerTextView else { return }
    editor.submit = submit
    if editor.font != typography.editorFont { editor.font = typography.editorFont }
    if editor.string != text, !editor.hasMarkedText() {
      editor.string = text
      editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MacComposer
    init(_ parent: MacComposer) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? NSTextView else { return }
      parent.text = editor.string
    }
  }
}

@MainActor private final class ComposerTextView: NSTextView {
  var submit: (() -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    if (event.keyCode == 36 || event.keyCode == 76),
      !event.modifierFlags.contains(.shift), !hasMarkedText() {
      submit?()
      return
    }
    super.keyDown(with: event)
  }
}
