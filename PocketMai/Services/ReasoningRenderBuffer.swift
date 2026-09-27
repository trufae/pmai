import Foundation

/// Keeps expensive text layout stable between consolidations. Only the small
/// tail changes on ordinary stream updates; the transcript is never truncated.
struct ReasoningRenderBuffer {
  static let tailCapacity = 4096
  static let consolidationInterval: Duration = .seconds(1)

  private(set) var settledText: String
  private(set) var tail = ""
  private var source: String
  private var settledUTF8Count: Int
  private var settledAtParagraphBoundary: Bool
  private var needsConsolidation = false

  init(_ text: String, isStreaming: Bool = false) {
    settledText = isStreaming ? "" : text
    source = text
    settledUTF8Count = settledText.utf8.count
    settledAtParagraphBoundary = isStreaming
    if isStreaming {
      tail = text
      needsConsolidation = true
      if tail.utf8.count >= Self.tailCapacity {
        consolidate()
      } else {
        consolidateCompletedParagraphs()
      }
    }
  }

  /// Prefer paragraph boundaries so the two widgets do not introduce a line
  /// break in the middle of a sentence. Match the Markdown renderer's fences.
  mutating func consolidateCompletedParagraphs() {
    guard needsConsolidation else { return }
    needsConsolidation = false
    // Ordinary promotions scan only the live tail. A forced mid-paragraph
    // consolidation needs the full prefix once to recover the fence state.
    let byteIndex = source.utf8.index(source.utf8.startIndex, offsetBy: settledUTF8Count)
    let scanStart =
      settledAtParagraphBoundary
      ? (String.Index(byteIndex, within: source) ?? source.startIndex) : source.startIndex
    var inCode = false
    var boundary = scanStart
    source.enumerateSubstrings(in: scanStart..., options: .byLines) {
      line, _, enclosingRange, _ in
      let trimmed = (line ?? "").trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") { inCode.toggle() }
      if !inCode, trimmed.isEmpty {
        boundary = enclosingRange.upperBound
      }
    }
    let byteCount = source[..<boundary].utf8.count
    guard byteCount > settledUTF8Count else { return }
    settledText = String(source[..<boundary])
    settledUTF8Count = byteCount
    settledAtParagraphBoundary = true
    tail = String(source[boundary...])
  }

  mutating func update(_ text: String, isStreaming: Bool) {
    guard !text.utf8.elementsEqual(source.utf8) else {
      if !isStreaming { consolidate() }
      return
    }

    // Edits, regenerated responses and Unicode normalization can replace the
    // prefix. Byte comparison also catches changes to the last grapheme.
    let isAppend = text.utf8.starts(with: source.utf8)
    source = text
    needsConsolidation = true
    guard isStreaming, isAppend else {
      consolidate()
      return
    }

    let byteIndex = text.utf8.index(text.utf8.startIndex, offsetBy: settledUTF8Count)
    guard let start = String.Index(byteIndex, within: text) else {
      // An appended accent or emoji joiner can extend the history's final
      // grapheme. Keep that grapheme in one widget rather than splitting it.
      consolidate()
      return
    }
    tail = String(text[start...])
    if tail.utf8.count >= Self.tailCapacity {
      // A burst or a very long paragraph must not turn the live widget into
      // another unbounded text layout before the next periodic consolidation.
      consolidate()
    }
  }

  mutating func consolidate() {
    settledText = source
    settledUTF8Count = source.utf8.count
    settledAtParagraphBoundary = false
    needsConsolidation = false
    tail = ""
  }
}
