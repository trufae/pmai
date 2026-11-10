import AppKit
import MaiCore
import SwiftUI

struct MacComposer: View {
  @Binding var text: String
  var prompts: PromptCatalog
  var submit: () -> Void
  @State private var completion = MacPromptCompletion()

  var body: some View {
    MacComposerEditor(text: $text, prompts: prompts, completion: completion, submit: submit)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .topLeading) {
        if !completion.matches.isEmpty {
          MacPromptCompletionList(completion: completion)
            // The editor proposes only one line of height. Measure the popup
            // independently before aligning its bottom above that line.
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.top) { $0[.bottom] + 14 }
        }
      }
  }
}

/// Keep AppKit text editing/IME behavior, with the REPL's Return-to-send rule.
private struct MacComposerEditor: NSViewRepresentable {
  @Binding var text: String
  var prompts: PromptCatalog
  var completion: MacPromptCompletion
  var submit: () -> Void
  private var typography = MacChatTypography()

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    let editor = ComposerTextView()
    editor.completion = completion
    completion.choose = { [weak editor] index in editor?.applyCompletion(at: index, finish: true) }
    editor.delegate = context.coordinator
    editor.isRichText = false
    editor.writingToolsBehavior = .none
    editor.allowsUndo = true
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
    editor.minSize = .zero
    editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.setAccessibilityLabel("Message")
    editor.setAccessibilityHelp("Return sends. Shift-Return adds a new line. Type / or $ for prompts and skills; Tab completes.")
    scroll.documentView = editor
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scroll.documentView as? ComposerTextView else { return }
    editor.submit = submit
    let catalogChanged = editor.prompts != prompts
    editor.prompts = prompts
    if editor.font != typography.editorFont { editor.font = typography.editorFont }
    var replaced = false
    if editor.string != text, !editor.hasMarkedText() {
      editor.updatingCompletion = true
      editor.string = text
      editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
      editor.updatingCompletion = false
      replaced = true
    }
    if replaced || catalogChanged {
      // Publishing popup state during updateNSView would reenter SwiftUI's
      // update. Read the editor's latest state on the next main-actor turn.
      Task { @MainActor [weak editor] in editor?.refreshCompletions() }
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0,
      let editor = scroll.documentView as? ComposerTextView else { return nil }
    return CGSize(width: width, height: editor.fittingHeight(for: width))
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MacComposerEditor
    init(_ parent: MacComposerEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? ComposerTextView else { return }
      parent.text = editor.string
      editor.refreshCompletions()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      (notification.object as? ComposerTextView)?.refreshCompletions()
    }
  }
}

@MainActor private final class ComposerTextView: NSTextView {
  var submit: (() -> Void)?
  var prompts = PromptCatalog(builtins: [])
  var completion: MacPromptCompletion?
  var updatingCompletion = false

  func refreshCompletions() {
    guard !updatingCompletion else { return }
    guard !hasMarkedText(), window?.firstResponder === self else { completion?.dismiss(); return }
    completion?.update(text: string, selection: selectedRange(), catalog: prompts)
  }

  func applyCompletion(at index: Int, finish: Bool) {
    guard let completion, completion.matches.indices.contains(index), !hasMarkedText() else { return }
    let range = completion.replacementRange
    guard let token = Range(range, in: string), String(string[token].prefix(1)) == completion.prefix else { return }
    var replacement = completion.prefix + completion.matches[index].commandName
    if finish, NSMaxRange(range) == (string as NSString).length { replacement += " " }
    guard shouldChangeText(in: range, replacementString: replacement) else { return }
    updatingCompletion = true
    textStorage?.replaceCharacters(in: range, with: replacement)
    setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    didChangeText()
    scrollRangeToVisible(selectedRange())
    updatingCompletion = false
    completion.replacementRange.length = (replacement as NSString).length
    completion.selected = index
    if finish { completion.dismiss() }
    window?.makeFirstResponder(self)
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      Task { @MainActor [weak self] in
        guard let self, window?.firstResponder !== self else { return }
        completion?.dismiss()
      }
    }
    return resigned
  }

  func fittingHeight(for width: CGFloat) -> CGFloat {
    guard let font, let textStorage else { return 0 }
    // SwiftUI probes multiple widths, including very narrow ones. Measuring
    // must never resize the live editor: the last probe need not be the width
    // SwiftUI finally chooses, and would leave its text wrapping too early.
    let storage = NSTextStorage(attributedString: textStorage)
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(
      width: max(1, width - textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    let lineHeight = layout.defaultLineHeight(for: font)
    let textHeight = max(layout.usedRect(for: container).height, layout.extraLineFragmentRect.maxY)
    return ceil(min(max(textHeight, lineHeight), lineHeight * 5) + textContainerInset.height * 2)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48, !hasMarkedText(), completion?.matches.isEmpty == true,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      refreshCompletions()
    }
    if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let completion, !completion.matches.isEmpty {
      if event.keyCode == 53 { completion.dismiss(); return }
      if event.keyCode == 48 {
        applyCompletion(at: max(0, completion.selected), finish: true)
        return
      }
      if event.keyCode == 125 || event.keyCode == 126 {
        let backwards = event.keyCode == 126
        let count = completion.matches.count
        let next = completion.selected < 0 ? (backwards ? count - 1 : 0)
          : (completion.selected + (backwards ? count - 1 : 1)) % count
        completion.selected = next
        return
      }
    }
    if (event.keyCode == 36 || event.keyCode == 76),
      !event.modifierFlags.contains(.shift), !hasMarkedText() {
      completion?.dismiss()
      submit?()
      return
    }
    super.keyDown(with: event)
  }
}
