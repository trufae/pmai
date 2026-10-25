import Foundation

public struct RenderedMessageContent: Sendable {
  public let visibleText: String
  public let hiddenSections: [HiddenMessageSection]
  public let parts: [RenderedMessagePart]
}

public struct HiddenMessageSection: Identifiable, Sendable {
  public let id: Int
  public let tag: String
  public let content: String
  public let toolTiming: ToolRunTiming?
}

public struct RenderedMessagePart: Identifiable, Sendable {
  public enum Kind: Sendable {
    case visible(String)
    case hidden(HiddenMessageSection)
  }

  public let id: Int
  public let kind: Kind
}

public enum MessageContentFilter {
  private static let hiddenTags = [
    "context", "tool_context", "tool_run", "tool_call", "think", "conversation", "speech",
  ]
  private static let hiddenTagSet = Set(hiddenTags)
  private static let promptStripTags: Set<String> = [
    "context", "tool_context", "conversation", "think", "tool_call",
  ]

  public static func render(_ text: String) -> RenderedMessageContent {
    guard text.contains("<") else {
      return RenderedMessageContent(
        visibleText: normalizedVisibleText(text),
        hiddenSections: [],
        parts: visibleParts(from: text)
      )
    }

    return scan(text, hiding: hiddenTagSet)
  }

  public static func promptSafeText(from text: String) -> String {
    conversationContextText(from: text)
  }

  /// Removes model reasoning while preserving every other response byte, including tool-call
  /// envelopes that downstream parsers still need to inspect.
  public static func removingReasoningSections(from text: String) -> String {
    guard text.contains("<") else { return text }
    return scan(text, hiding: ["think"], normalizeVisibleText: false).visibleText
  }

  /// Reasoning-free text for the long-press actions: drops the think blocks and
  /// tidies up the blank lines they leave behind, keeping everything else intact.
  public static func textWithoutReasoning(from text: String) -> String {
    let stripped = removingReasoningSections(from: text)
    guard stripped != text else { return text }
    return collapseBlankLines(stripped.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public static func conversationContextText(
    from text: String,
    includeReasoning: Bool = false
  ) -> String {
    let tags = includeReasoning ? promptStripTags.subtracting(["think"]) : promptStripTags
    guard text.contains("<"), !tags.isEmpty else {
      return normalizedVisibleText(text)
    }
    return scan(text, hiding: tags).visibleText
  }

  public static func previewText(from text: String, maxLength: Int = 160) -> String {
    var result = render(text).visibleText
    let plainToolCallPattern = "(?im)^\\s*TOOL_CALL\\s*$[\\s\\S]*?(?:^\\s*END_TOOL_CALL\\s*$|\\z)"
    result = result.replacingOccurrences(
      of: plainToolCallPattern, with: "", options: [.regularExpression, .caseInsensitive])
    let trimmed = collapseBlankLines(result).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.prefix(maxLength))
  }

  /// Rewrites `text` so its user-facing prose becomes `replacement` while every
  /// hidden section (tool runs, reasoning, transcripts) is kept verbatim. Lets the
  /// message editor work on what the bubble shows without dropping the tool data
  /// that the same message carries for the model.
  public static func replacingVisibleText(in text: String, with replacement: String) -> String {
    let spans = hiddenSpans(in: text, hiding: hiddenTagSet)
    guard !spans.isEmpty else { return replacement }

    let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    var pieces: [String] = []
    var insertedReplacement = false
    var cursor = text.startIndex
    for span in spans {
      if !insertedReplacement,
        !text[cursor..<span.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        if !trimmedReplacement.isEmpty { pieces.append(trimmedReplacement) }
        insertedReplacement = true
      }
      pieces.append(String(text[span]))
      cursor = span.upperBound
    }
    if !insertedReplacement, !trimmedReplacement.isEmpty {
      pieces.append(trimmedReplacement)
    }
    return pieces.joined(separator: "\n\n")
  }

  /// Removes one rendered hidden section without disturbing an identical block
  /// elsewhere in the message. `occurrence` is counted only among sections with
  /// the same tag and content, which lets a UI delete the exact reasoning or
  /// tool row that was pressed.
  public static func removingHiddenSection(
    tag: String,
    content: String,
    occurrence: Int,
    from text: String
  ) -> String? {
    guard occurrence >= 0 else { return nil }
    let normalizedTag = tag.lowercased()
    guard hiddenTagSet.contains(normalizedTag) else { return nil }

    var cursor = text.startIndex
    var remaining = occurrence
    while let block = nextHiddenBlock(in: text, from: cursor, hiding: hiddenTagSet) {
      cursor = block.range.upperBound
      guard block.tag == normalizedTag,
        block.content.map({ String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) })
          == content.trimmingCharacters(in: .whitespacesAndNewlines)
      else { continue }
      if remaining > 0 {
        remaining -= 1
        continue
      }

      let before = text[..<block.range.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let after = text[block.range.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if before.isEmpty { return after }
      if after.isEmpty { return before }
      return "\(before)\n\n\(after)"
    }
    return nil
  }

  /// Ranges of the hidden blocks, tags included, in the order they appear.
  private static func hiddenSpans(
    in text: String,
    hiding tags: Set<String>
  ) -> [Range<String.Index>] {
    guard text.contains("<") else { return [] }
    var spans: [Range<String.Index>] = []
    var cursor = text.startIndex
    while let block = nextHiddenBlock(in: text, from: cursor, hiding: tags) {
      spans.append(block.range)
      cursor = block.range.upperBound
    }
    return spans
  }

  /// True when `text` opens with reasoning that is only delimited by a bare `</think>`,
  /// the opening tag never having been emitted. Incremental renderers use it to notice
  /// that a prefix they already showed as prose has just turned into reasoning.
  public static func beginsWithUnopenedReasoning(_ text: String) -> Bool {
    guard text.contains("<") else { return false }
    return nextHiddenBlock(in: text, from: text.startIndex, hiding: ["think"])?.isUnopened == true
  }

  public static func markdownPlainText(from text: String) -> String {
    // Foundation's Markdown initializer for AttributedString is unavailable on
    // Linux Foundation. Keep this intentionally small, portable conversion for
    // notification, search, and speech text rather than making those features
    // depend on platform-specific rich text support.
    text.components(separatedBy: .newlines).map(markdownPlainTextLine).joined(separator: "\n")
  }

  private static func markdownPlainTextLine(_ line: String) -> String {
    var result = line
    result = result.replacingOccurrences(
      of: "^\\s{0,3}(?:#{1,6}\\s+|>\\s?|[-+*]\\s+|\\d+[.)]\\s+)",
      with: "",
      options: .regularExpression)
    result = result.replacingOccurrences(
      of: "!?(?:\\[([^]]*)\\]\\([^)]*\\)|\\[([^]]*)\\]\\[[^]]*\\])",
      with: "$1$2",
      options: .regularExpression)
    result = result.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
    result = result.replacingOccurrences(of: "(\\*\\*|__|\\*|_|~~)", with: "", options: .regularExpression)
    return result
  }

  private static func scan(
    _ text: String,
    hiding tags: Set<String>,
    normalizeVisibleText shouldNormalizeVisibleText: Bool = true
  ) -> RenderedMessageContent {
    var cursor = text.startIndex
    var visible = ""
    var hiddenSections: [HiddenMessageSection] = []
    var parts: [RenderedMessagePart] = []

    while let block = nextHiddenBlock(in: text, from: cursor, hiding: tags) {
      appendVisibleSegment(
        text[cursor..<block.range.lowerBound],
        visible: &visible,
        parts: &parts)
      if let content = block.content,
        let section = appendHiddenSection(
          tag: block.tag,
          content: String(text[content]),
          toolTiming: block.tag == "tool_run"
            ? ToolRunTiming(openingTag: text[block.range.lowerBound..<content.lowerBound]) : nil,
          hiddenSections: &hiddenSections)
      {
        appendHiddenPart(section, parts: &parts)
      }
      cursor = block.range.upperBound
    }

    appendVisibleSegment(text[cursor..<text.endIndex], visible: &visible, parts: &parts)
    return RenderedMessageContent(
      visibleText: shouldNormalizeVisibleText ? normalizedVisibleText(visible) : visible,
      hiddenSections: hiddenSections,
      parts: parts
    )
  }

  private struct TagToken {
    let tag: String
    let isClosing: Bool
    let isSelfClosing: Bool
    let range: Range<String.Index>
  }

  /// One hidden block: the tag, its whole span (tags included) and the inner content
  /// span, which is nil for self-closing tags. `isUnopened` marks reasoning that only
  /// has a closing tag.
  private struct HiddenBlock {
    let tag: String
    let range: Range<String.Index>
    let content: Range<String.Index>?
    var isUnopened = false
  }

  private static func nextHiddenBlock(
    in text: String,
    from cursor: String.Index,
    hiding tags: Set<String>
  ) -> HiddenBlock? {
    var searchStart = cursor
    var sawThinkOpening = false
    while let token = nextTagToken(in: text, from: searchStart, matching: tags) {
      searchStart = token.range.upperBound
      if token.isClosing {
        // Chat templates that pre-fill `<think>` (Qwen 3.5+, DeepSeek) make the model
        // emit its reasoning followed by a bare `</think>`, so a closing tag with no
        // opening before it ends a reasoning block that started at the cursor.
        if token.tag == "think", !sawThinkOpening, isUnopenedClosing(token, in: text) {
          return HiddenBlock(
            tag: "think",
            range: cursor..<token.range.upperBound,
            content: cursor..<token.range.lowerBound,
            isUnopened: true)
        }
        continue
      }
      if token.tag == "think" { sawThinkOpening = true }
      guard isStructuralOpening(token, in: text) else { continue }
      if token.isSelfClosing {
        return HiddenBlock(tag: token.tag, range: token.range, content: nil)
      }
      if let closing = matchingClose(for: token, in: text) {
        return HiddenBlock(
          tag: token.tag,
          range: token.range.lowerBound..<closing.range.upperBound,
          content: token.range.upperBound..<closing.range.lowerBound)
      }
      return HiddenBlock(
        tag: token.tag,
        range: token.range.lowerBound..<text.endIndex,
        content: token.range.upperBound..<text.endIndex)
    }
    return nil
  }

  private static func matchingClose(for opening: TagToken, in text: String) -> TagToken? {
    var searchStart = opening.range.upperBound
    var nestedOpenings: [TagToken] = []
    let tags = Set([opening.tag])
    while let token = nextTagToken(in: text, from: searchStart, matching: tags) {
      searchStart = token.range.upperBound
      if token.isClosing {
        let nestedOpening = nestedOpenings.last ?? opening
        guard isStructuralClosing(token, for: nestedOpening, in: text) else {
          continue
        }
        if nestedOpenings.isEmpty {
          return token
        }
        nestedOpenings.removeLast()
      } else if !token.isSelfClosing && isStructuralOpening(token, in: text) {
        nestedOpenings.append(token)
      }
    }
    return lineDelimitedClose(for: opening, in: text)
  }

  private static func lineDelimitedClose(for opening: TagToken, in text: String) -> TagToken? {
    var searchStart = opening.range.upperBound
    var nestedDepth = 0
    let tags = Set([opening.tag])
    while let token = nextTagToken(
      in: text,
      from: searchStart,
      matching: tags,
      respectsMarkdown: false)
    {
      searchStart = token.range.upperBound
      guard isLineDelimited(token, in: text) else { continue }
      if token.isClosing {
        if nestedDepth == 0 { return token }
        nestedDepth -= 1
      } else if !token.isSelfClosing {
        nestedDepth += 1
      }
    }
    return nil
  }

  private static func nextTagToken(
    in text: String,
    from start: String.Index,
    matching tags: Set<String>,
    respectsMarkdown: Bool = true
  ) -> TagToken? {
    var index = start
    var fenceMarker: Character?
    var fenceLength = 0
    var inlineBackticks = 0

    while index < text.endIndex {
      if respectsMarkdown, inlineBackticks == 0,
        let fence = markdownFenceDelimiter(in: text, at: index)
      {
        if let marker = fenceMarker {
          if marker == fence.marker && fence.length >= fenceLength {
            fenceMarker = nil
            fenceLength = 0
          }
        } else {
          fenceMarker = fence.marker
          fenceLength = fence.length
        }
        index = fence.end
        continue
      }

      if respectsMarkdown, fenceMarker != nil {
        text.formIndex(after: &index)
        continue
      }

      if respectsMarkdown, text[index] == "`" {
        let run = repeatedCharacterRun(in: text, from: index, matching: "`")
        if inlineBackticks == 0 {
          inlineBackticks = run.length
        } else if run.length >= inlineBackticks {
          inlineBackticks = 0
        }
        index = run.end
        continue
      }

      if respectsMarkdown, inlineBackticks != 0 {
        text.formIndex(after: &index)
        continue
      }

      if text[index] == "<", let token = parseTagToken(in: text, at: index, matching: tags) {
        return token
      }
      text.formIndex(after: &index)
    }
    return nil
  }

  private static func parseTagToken(
    in text: String,
    at start: String.Index,
    matching tags: Set<String>
  ) -> TagToken? {
    guard text[start] == "<" else { return nil }
    var index = text.index(after: start)
    skipTagWhitespace(in: text, from: &index)

    var isClosing = false
    if index < text.endIndex, text[index] == "/" {
      isClosing = true
      text.formIndex(after: &index)
      skipTagWhitespace(in: text, from: &index)
    }

    let nameStart = index
    while index < text.endIndex, isTagNameCharacter(text[index]) {
      text.formIndex(after: &index)
    }
    guard nameStart < index else { return nil }

    let tag = String(text[nameStart..<index]).lowercased()
    guard tags.contains(tag) else { return nil }

    if isClosing {
      skipTagWhitespace(in: text, from: &index)
      guard index < text.endIndex, text[index] == ">" else { return nil }
      let end = text.index(after: index)
      return TagToken(tag: tag, isClosing: true, isSelfClosing: false, range: start..<end)
    }

    guard index == text.endIndex || isTagBoundary(text[index]) else { return nil }
    var end = index
    var lastNonWhitespace = index
    while end < text.endIndex, text[end] != ">" {
      if !isTagWhitespace(text[end]) {
        lastNonWhitespace = end
      }
      text.formIndex(after: &end)
    }
    guard end < text.endIndex else { return nil }
    let tokenEnd = text.index(after: end)
    let isSelfClosing = lastNonWhitespace < end && text[lastNonWhitespace] == "/"
    return TagToken(
      tag: tag, isClosing: false, isSelfClosing: isSelfClosing, range: start..<tokenEnd)
  }

  private static func isStructuralOpening(_ token: TagToken, in text: String) -> Bool {
    guard token.tag == "think" else { return true }
    return isLinePrefixWhitespace(in: text, before: token.range.lowerBound)
  }

  private static func isStructuralClosing(
    _ token: TagToken,
    for opening: TagToken,
    in text: String
  ) -> Bool {
    guard token.tag == "think" else { return true }
    return isLinePrefixWhitespace(in: text, before: token.range.lowerBound)
      || isSameLine(in: text, from: opening.range.lowerBound, to: token.range.lowerBound)
      || (isImmediatelyAfterNonWhitespace(in: text, at: token.range.lowerBound)
        && isLineSuffixWhitespace(in: text, after: token.range.upperBound))
  }

  private static func isUnopenedClosing(_ token: TagToken, in text: String) -> Bool {
    isLinePrefixWhitespace(in: text, before: token.range.lowerBound)
      || (isImmediatelyAfterNonWhitespace(in: text, at: token.range.lowerBound)
        && isLineSuffixWhitespace(in: text, after: token.range.upperBound))
  }

  private static func isLineDelimited(_ token: TagToken, in text: String) -> Bool {
    isLinePrefixWhitespace(in: text, before: token.range.lowerBound)
      && isLineSuffixWhitespace(in: text, after: token.range.upperBound)
  }

  private static func skipTagWhitespace(in text: String, from index: inout String.Index) {
    while index < text.endIndex, isTagWhitespace(text[index]) {
      text.formIndex(after: &index)
    }
  }

  private static func isTagNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-"
  }

  private static func isTagBoundary(_ character: Character) -> Bool {
    isTagWhitespace(character) || character == ">" || character == "/"
  }

  private static func isTagWhitespace(_ character: Character) -> Bool {
    character == " " || character == "\t" || character == "\n" || character == "\r"
  }

  private static func markdownFenceDelimiter(
    in text: String,
    at index: String.Index
  ) -> (marker: Character, length: Int, end: String.Index)? {
    guard isLinePrefixWhitespace(in: text, before: index),
      text[index] == "`" || text[index] == "~"
    else {
      return nil
    }
    let run = repeatedCharacterRun(in: text, from: index, matching: text[index])
    guard run.length >= 3 else { return nil }
    return (text[index], run.length, run.end)
  }

  private static func repeatedCharacterRun(
    in text: String,
    from start: String.Index,
    matching character: Character
  ) -> (length: Int, end: String.Index) {
    var index = start
    var length = 0
    while index < text.endIndex, text[index] == character {
      length += 1
      text.formIndex(after: &index)
    }
    return (length, index)
  }

  private static func isLinePrefixWhitespace(in text: String, before index: String.Index) -> Bool {
    var cursor = index
    while cursor > text.startIndex {
      let previous = text.index(before: cursor)
      if text[previous] == "\n" || text[previous] == "\r" {
        return true
      }
      if !text[previous].isWhitespace {
        return false
      }
      cursor = previous
    }
    return true
  }

  private static func isLineSuffixWhitespace(in text: String, after index: String.Index) -> Bool {
    var cursor = index
    while cursor < text.endIndex {
      if text[cursor] == "\n" || text[cursor] == "\r" {
        return true
      }
      if !text[cursor].isWhitespace {
        return false
      }
      text.formIndex(after: &cursor)
    }
    return true
  }

  private static func isImmediatelyAfterNonWhitespace(
    in text: String,
    at index: String.Index
  ) -> Bool {
    guard index > text.startIndex else { return false }
    let previous = text.index(before: index)
    return !text[previous].isWhitespace
  }

  private static func isSameLine(
    in text: String,
    from start: String.Index,
    to end: String.Index
  ) -> Bool {
    var cursor = start
    while cursor < end {
      if text[cursor] == "\n" || text[cursor] == "\r" {
        return false
      }
      text.formIndex(after: &cursor)
    }
    return true
  }

  private static func appendHiddenSection(
    tag: String,
    content: String,
    toolTiming: ToolRunTiming?,
    hiddenSections: inout [HiddenMessageSection]
  ) -> HiddenMessageSection? {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let section = HiddenMessageSection(
      id: hiddenSections.count, tag: tag, content: trimmed, toolTiming: toolTiming)
    hiddenSections.append(section)
    return section
  }

  private static func appendVisibleSegment(
    _ segment: Substring,
    visible: inout String,
    parts: inout [RenderedMessagePart]
  ) {
    guard !segment.isEmpty else { return }
    visible += segment
    let normalized = normalizedVisibleText(String(segment))
    guard !normalized.isEmpty else { return }
    parts.append(RenderedMessagePart(id: parts.count, kind: .visible(normalized)))
  }

  private static func appendHiddenPart(
    _ section: HiddenMessageSection,
    parts: inout [RenderedMessagePart]
  ) {
    parts.append(RenderedMessagePart(id: parts.count, kind: .hidden(section)))
  }

  private static func visibleParts(from text: String) -> [RenderedMessagePart] {
    let visible = normalizedVisibleText(text)
    guard !visible.isEmpty else { return [] }
    return [RenderedMessagePart(id: 0, kind: .visible(visible))]
  }

  private static func normalizedVisibleText(_ text: String) -> String {
    collapseBlankLines(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func collapseBlankLines(_ text: String) -> String {
    var output = text
    while output.contains("\n\n\n") {
      output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return output
  }
}
