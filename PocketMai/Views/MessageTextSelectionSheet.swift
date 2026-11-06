import MaiCore
import SwiftUI
import UIKit

struct MessageTextSelectionSheet: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  // The full, unfiltered message text. The editable buffer always operates on
  // this raw form; the filtered view is derived from it on demand.
  let text: String
  // Whether the raw text has hidden sections, i.e. a filtered form that differs
  // from the raw form. Drives whether the Raw/Filtered toggle is offered.
  let canFilter: Bool
  let appearance: AppearanceSettings
  let fontFamily: AppearanceFontFamily
  let lineSpacing: Double
  let isEditable: Bool
  // Title of the button that commits the draft.
  let saveTitle: String
  // When set, committing asks for confirmation with this question first and is
  // offered even for an untouched draft — the reply composer, where the quoted
  // text alone is a valid message.
  let saveConfirmation: String?
  let onSave: ((String) async throws -> Void)?
  @State private var draftText: String
  @State private var fontSize: Double
  @State private var showingPreview: Bool
  @GestureState private var previewMagnification: CGFloat = 1
  // When true the raw text is shown/edited; when false the derived filtered text
  // is shown read-only. Saving is always tied to the raw draft.
  @State private var showingRaw: Bool
  @State private var shareItem: TextShareItem?
  @State private var showingSaveConfirmation = false
  @State private var isSaving = false
  @State private var saveError: String?

  private struct TextShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
  }

  init(
    title: String,
    text: String,
    canFilter: Bool = false,
    appearance: AppearanceSettings = .defaults,
    initialFontSize: Double = AppearanceSettings.defaults.fontSize,
    initialLineSpacing: Double = AppearanceSettings.defaults.lineSpacing,
    fontFamily: AppearanceFontFamily = .system,
    isEditable: Bool = false,
    initiallyShowingPreview: Bool = false,
    saveTitle: String = "Save",
    saveConfirmation: String? = nil,
    onSave: ((String) async throws -> Void)? = nil
  ) {
    self.title = title
    self.text = text
    self.canFilter = canFilter
    self.appearance = appearance
    self.fontFamily = fontFamily
    self.lineSpacing = AppearanceSettings.clampedLineSpacing(initialLineSpacing)
    self.isEditable = isEditable
    self.saveTitle = saveTitle
    self.saveConfirmation = saveConfirmation
    self.onSave = onSave
    _draftText = State(initialValue: text)
    _fontSize = State(initialValue: AppearanceSettings.clampedFontSize(initialFontSize))
    _showingPreview = State(initialValue: initiallyShowingPreview)
    // Editing starts on the raw text; read-only viewing starts on the cleaner
    // filtered text when one is available.
    _showingRaw = State(initialValue: isEditable || !canFilter)
  }

  // Editing uses a monospaced font so markdown source is easy to read and align.
  private var editorFontFamily: AppearanceFontFamily {
    isEditable ? .monospaced : fontFamily
  }

  // The text currently presented: the live raw draft, or its filtered form.
  private var displayedText: String {
    showingRaw ? draftText : MessageContentFilter.render(draftText).visibleText
  }

  private var previewAppearance: AppearanceSettings {
    var settings = appearance
    settings.fontSize = magnifiedFontSize(previewMagnification)
    settings.lineSpacing = lineSpacing
    return settings
  }

  private func magnifiedFontSize(_ magnification: CGFloat) -> Double {
    let rawSize = fontSize * max(Double(magnification), 0.1)
    let steppedSize =
      (rawSize / AppearanceSettings.fontSizeStep).rounded() * AppearanceSettings.fontSizeStep
    return AppearanceSettings.clampedFontSize(steppedSize)
  }

  var body: some View {
    NavigationStack {
      Group {
        if showingPreview {
          ScrollView {
            MarkdownContentView(
              text: displayedText,
              appearance: previewAppearance,
              fontFamily: fontFamily,
              allowsTextSelection: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
          }
          .simultaneousGesture(
            MagnifyGesture()
              .updating($previewMagnification) { value, magnification, _ in
                magnification = value.magnification
              }
              .onEnded { value in
                fontSize = magnifiedFontSize(value.magnification)
              }
          )
        } else if isEditable && showingRaw {
          SelectableMessageTextView(
            text: $draftText,
            fontSize: $fontSize,
            lineSpacing: lineSpacing,
            fontFamily: editorFontFamily,
            isEditable: true
          )
        } else {
          // Read-only: viewing a message, or showing the derived filtered text
          // while editing (edits are made on the raw draft only).
          SelectableMessageTextView(
            text: .constant(displayedText),
            fontSize: $fontSize,
            lineSpacing: lineSpacing,
            fontFamily: editorFontFamily,
            isEditable: false
          )
        }
      }
      .disabled(isSaving)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(isEditable ? "Cancel" : "Done") { dismiss() }
        }
        if canFilter {
          ToolbarItem(placement: .topBarLeading) {
            rawToggleButton
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            UIPasteboard.general.string = displayedText
          } label: {
            Label("Copy All", systemImage: "doc.on.doc")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          shareButton
        }
        if isEditable {
          ToolbarItem(placement: .confirmationAction) {
            Button(isSaving ? "Saving…" : saveTitle) {
              if saveConfirmation == nil {
                saveEdits()
              } else {
                showingSaveConfirmation = true
              }
            }
            .disabled(isSaving || (saveConfirmation == nil && draftText == text))
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingPreview.toggle()
          } label: {
            Label(
              showingPreview ? (isEditable ? "Edit" : "Source") : "Preview",
              systemImage: showingPreview ? "square.and.pencil" : "eye")
          }
        }
      }
      .disabled(isSaving)
      .interactiveDismissDisabled(isSaving)
      .sheet(item: $shareItem) { item in
        ActivityShareSheet(activityItems: item.items)
      }
      .confirmationDialog(
        saveConfirmation ?? "",
        isPresented: $showingSaveConfirmation,
        titleVisibility: .visible
      ) {
        Button(saveTitle) {
          commitEdits()
        }
        Button("Cancel", role: .cancel) {}
      }
      .errorAlert("Could Not Save", message: $saveError)
    }
  }

  private var shareButton: some View {
    Button {
      shareItem = TextShareItem(items: [exportFileURL() ?? displayedText])
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
  }

  /// Writes the displayed text to a temp file named after the sheet title so
  /// the share sheet exports a real file; falls back to sharing plain text.
  private func exportFileURL() -> URL? {
    var filename =
      title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
      .joined(separator: "-")
    if filename.isEmpty { filename = "message" }
    if !filename.dropFirst().contains(".") { filename += ".md" }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    do {
      try Data(displayedText.utf8).write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  // Toggles between the raw message text and its filtered form. Highlighted
  // (filled icon) while the raw text is shown.
  private var rawToggleButton: some View {
    Button {
      showingRaw.toggle()
    } label: {
      Label("Raw", systemImage: showingRaw ? "doc.text.fill" : "doc.text")
    }
  }

  private func saveEdits() {
    guard draftText != text else {
      dismiss()
      return
    }
    commitEdits()
  }

  private func commitEdits() {
    guard !isSaving else { return }
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        try await onSave?(draftText)
        dismiss()
      } catch {
        saveError = error.localizedDescription
      }
    }
  }
}

private struct SelectableMessageTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var fontSize: Double
  let lineSpacing: Double
  let fontFamily: AppearanceFontFamily
  let isEditable: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      fontSize: $fontSize,
      fontFamily: fontFamily,
      lineSpacing: lineSpacing)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.isEditable = isEditable
    textView.isSelectable = true
    applyBareTextInputTraits(to: textView)
    textView.backgroundColor = .clear
    textView.font = fontFamily.uiFont(size: fontSize)
    textView.adjustsFontForContentSizeCategory = true
    textView.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 18, right: 14)
    textView.text = text
    context.coordinator.installPinchGesture(in: textView)
    context.coordinator.applyTextStyle(to: textView, size: fontSize)
    if isEditable {
      DispatchQueue.main.async {
        textView.becomeFirstResponder()
      }
    }
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.text = $text
    context.coordinator.fontSize = $fontSize
    context.coordinator.fontFamily = fontFamily
    context.coordinator.lineSpacing = lineSpacing
    textView.isEditable = isEditable
    applyBareTextInputTraits(to: textView)
    if textView.text != text {
      textView.text = text
    }
    // Skip when the gesture handler already applied the style this run-loop cycle.
    // SwiftUI fires updateUIView after the binding write in updateFontSize, which
    // would cause a second full text-storage re-attribution for every gesture tick.
    if context.coordinator.pendingStyleFromGesture {
      context.coordinator.pendingStyleFromGesture = false
      return
    }
    context.coordinator.applyTextStyle(to: textView, size: fontSize)
  }

  private func applyBareTextInputTraits(to textView: UITextView) {
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.autocorrectionType = .no
    textView.spellCheckingType = .no
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate {
    var text: Binding<String>
    var fontSize: Binding<Double>
    var fontFamily: AppearanceFontFamily
    var lineSpacing: Double

    private weak var textView: UITextView?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var pinchBaseFontSize: Double?
    private var pinchAnchor: TextViewPinchAnchor?
    private var pinchViewportY: CGFloat?
    // Set when applyTextStyle is called directly from the gesture handler so that
    // the redundant updateUIView→applyTextStyle call in the same SwiftUI pass can be skipped.
    var pendingStyleFromGesture = false
    private var originalShowsVerticalScrollIndicator: Bool?
    private var originalShowsHorizontalScrollIndicator: Bool?

    init(
      text: Binding<String>,
      fontSize: Binding<Double>,
      fontFamily: AppearanceFontFamily,
      lineSpacing: Double
    ) {
      self.text = text
      self.fontSize = fontSize
      self.fontFamily = fontFamily
      self.lineSpacing = lineSpacing
    }

    func installPinchGesture(in textView: UITextView) {
      guard pinchGesture == nil else { return }
      let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      gesture.cancelsTouchesInView = false
      gesture.delaysTouchesBegan = false
      gesture.delaysTouchesEnded = false
      gesture.delegate = self
      textView.addGestureRecognizer(gesture)
      self.textView = textView
      pinchGesture = gesture
    }

    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text
    }

    func applyTextStyle(to textView: UITextView, size: Double) {
      let nextFont = fontFamily.uiFont(size: size)
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineSpacing = CGFloat(lineSpacing)
      textView.font = nextFont
      textView.typingAttributes[.font] = nextFont
      textView.typingAttributes[.paragraphStyle] = paragraphStyle
      if textView.textStorage.length > 0 {
        textView.textStorage.addAttributes(
          [
            .font: nextFont,
            .paragraphStyle: paragraphStyle,
          ],
          range: NSRange(location: 0, length: textView.textStorage.length))
      }
      textView.setNeedsLayout()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard let textView else { return }

      switch recognizer.state {
      case .began:
        pinchBaseFontSize = fontSize.wrappedValue
        hideScrollIndicators(in: textView)
        updateFontSize(for: recognizer, in: textView)
      case .changed:
        updateFontSize(for: recognizer, in: textView)
      case .ended, .cancelled, .failed:
        pinchBaseFontSize = nil
        pinchAnchor = nil
        pinchViewportY = nil
        restoreScrollIndicators()
      default:
        break
      }
    }

    private func updateFontSize(
      for recognizer: UIPinchGestureRecognizer,
      in textView: UITextView
    ) {
      let baseSize = pinchBaseFontSize ?? fontSize.wrappedValue
      pinchBaseFontSize = baseSize
      let rawSize = baseSize * max(Double(recognizer.scale), 0.1)
      let steppedSize =
        (rawSize / AppearanceSettings.fontSizeStep).rounded() * AppearanceSettings.fontSizeStep
      let clampedSize = AppearanceSettings.clampedFontSize(steppedSize)
      guard fontSize.wrappedValue != clampedSize else { return }

      // Capture anchor and viewport position once per gesture — the layout lookup
      // (layoutIfNeeded + layoutManager queries) only runs on the first tick.
      let contentPoint = recognizer.location(in: textView)
      let viewportY: CGFloat
      let anchor: TextViewPinchAnchor
      if let cachedAnchor = pinchAnchor, let cachedViewportY = pinchViewportY {
        anchor = cachedAnchor
        viewportY = cachedViewportY
      } else {
        viewportY = contentPoint.y - textView.contentOffset.y
        anchor = makePinchAnchor(in: textView, at: contentPoint)
        pinchAnchor = anchor
        pinchViewportY = viewportY
      }

      fontSize.wrappedValue = clampedSize
      // Mark before applyTextStyle so updateUIView can skip the redundant call that
      // SwiftUI will fire in the same run-loop cycle after the binding write above.
      pendingStyleFromGesture = true
      applyTextStyle(to: textView, size: clampedSize)
      preservePinchPosition(in: textView, anchor: anchor, viewportY: viewportY)
    }

    private func preservePinchPosition(
      in textView: UITextView,
      anchor: TextViewPinchAnchor,
      viewportY: CGFloat
    ) {
      textView.layoutIfNeeded()
      let targetContentY = resolvedContentY(for: anchor, in: textView)
      let targetY = targetContentY - viewportY
      textView.setContentOffset(
        CGPoint(x: textView.contentOffset.x, y: textView.clampedContentOffsetY(targetY)),
        animated: false)
    }

    private func makePinchAnchor(
      in textView: UITextView,
      at contentPoint: CGPoint
    ) -> TextViewPinchAnchor {
      textView.layoutIfNeeded()
      let fallbackContentHeight = max(textView.contentSize.height, 1)
      guard textView.textStorage.length > 0 else {
        return TextViewPinchAnchor(
          characterIndex: nil,
          unitY: 0,
          fallbackContentY: contentPoint.y,
          fallbackContentHeight: fallbackContentHeight)
      }

      let textContainerPoint = CGPoint(
        x: contentPoint.x - textView.textContainerInset.left,
        y: contentPoint.y - textView.textContainerInset.top)
      let layoutManager = textView.layoutManager
      layoutManager.ensureLayout(for: textView.textContainer)
      let characterIndex = layoutManager.characterIndex(
        for: textContainerPoint,
        in: textView.textContainer,
        fractionOfDistanceBetweenInsertionPoints: nil)
      let clampedIndex = min(max(characterIndex, 0), textView.textStorage.length - 1)
      let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedIndex)
      var lineRange = NSRange()
      let lineRect = layoutManager.lineFragmentUsedRect(
        forGlyphAt: glyphIndex,
        effectiveRange: &lineRange)
      let unitY =
        lineRect.height > 1
        ? min(max((textContainerPoint.y - lineRect.minY) / lineRect.height, 0), 1)
        : 0

      return TextViewPinchAnchor(
        characterIndex: clampedIndex,
        unitY: unitY,
        fallbackContentY: contentPoint.y,
        fallbackContentHeight: fallbackContentHeight)
    }

    private func resolvedContentY(
      for anchor: TextViewPinchAnchor,
      in textView: UITextView
    ) -> CGFloat {
      if let characterIndex = anchor.characterIndex, textView.textStorage.length > 0 {
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let clampedIndex = min(max(characterIndex, 0), textView.textStorage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedIndex)
        let lineRect = layoutManager.lineFragmentUsedRect(
          forGlyphAt: glyphIndex, effectiveRange: nil)
        return textView.textContainerInset.top + lineRect.minY + lineRect.height * anchor.unitY
      }

      let newContentHeight = max(textView.contentSize.height, 1)
      return anchor.fallbackContentY * newContentHeight / anchor.fallbackContentHeight
    }

    private func hideScrollIndicators(in textView: UITextView) {
      if originalShowsVerticalScrollIndicator == nil {
        originalShowsVerticalScrollIndicator = textView.showsVerticalScrollIndicator
      }
      if originalShowsHorizontalScrollIndicator == nil {
        originalShowsHorizontalScrollIndicator = textView.showsHorizontalScrollIndicator
      }
      textView.showsVerticalScrollIndicator = false
      textView.showsHorizontalScrollIndicator = false
    }

    private func restoreScrollIndicators() {
      guard let textView else { return }
      if let originalShowsVerticalScrollIndicator {
        textView.showsVerticalScrollIndicator = originalShowsVerticalScrollIndicator
      }
      if let originalShowsHorizontalScrollIndicator {
        textView.showsHorizontalScrollIndicator = originalShowsHorizontalScrollIndicator
      }
      originalShowsVerticalScrollIndicator = nil
      originalShowsHorizontalScrollIndicator = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pinch = gestureRecognizer as? UIPinchGestureRecognizer else { return true }
      return pinch.numberOfTouches >= 2
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

private struct TextViewPinchAnchor {
  let characterIndex: Int?
  let unitY: CGFloat
  let fallbackContentY: CGFloat
  let fallbackContentHeight: CGFloat
}
