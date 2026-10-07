import Foundation
import SwiftTUICLI
import SwiftTUIRuntime
import Testing

@testable import MaiCore
@testable import MaiVisual

@Test("Message blocks render markdown with markers, styled runs, and tables")
@MainActor
func messageBlockRendersMarkdown() {
  let text = """
    # Title
    A **bold** word and `code`.
    - one
    - two

    | A | B |
    |---|---|
    | x | **y** |
    """
  let output = RenderOnce.render(
    MessageBlock(id: "m1", label: "Assistant", text: text, isLive: false, width: 40)
      .frame(height: 14),
    width: 40,
    environment: ["NO_COLOR": "1", "LANG": "en_US.UTF-8"],
    isStdoutTTY: false)
  #expect(output.contains("Assistant"))
  #expect(output.contains("Title"))
  #expect(output.contains("A bold word and code."))
  #expect(output.contains("• one"))
  // The offline renderer substitutes ASCII for box-drawing glyphs.
  #expect(output.contains("┌─────┬─────┐") || output.contains("+-----+-----+"))
  #expect(output.contains("│ x   │ y   │") || output.contains("| x   | y   |"))
  #expect(!output.contains("**"))
}

@Test("Long markdown paragraphs wrap to the pane width")
@MainActor
func markdownParagraphsWrap() {
  let words = Array(repeating: "wrapped **words** keep flowing", count: 8).joined(separator: " ")
  let output = RenderOnce.render(
    MessageBlock(id: "m2", label: "Assistant", text: words, isLive: false, width: 30)
      .frame(width: 30, height: 20),
    width: 30,
    environment: ["NO_COLOR": "1"],
    isStdoutTTY: false)
  let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
  #expect(lines.allSatisfy { $0.count <= 30 })
  #expect(output.contains("wrapped words keep flowing"))
  #expect(!output.contains("**"))
}

@Test("Unified diff lines distinguish changes from file headers")
func unifiedDiffLinesAreClassifiedForBackgrounds() {
  #expect(UnifiedDiffText.hasUnifiedDiff(["summary", "--- a/source.c", "+++ b/source.c"]))
  #expect(!UnifiedDiffText.hasUnifiedDiff(["- ordinary tool output"]))
  #expect(UnifiedDiffText.isRemoval("-old value"))
  #expect(UnifiedDiffText.isAddition("+new value"))
  #expect(!UnifiedDiffText.isRemoval("--- a/source.c"))
  #expect(!UnifiedDiffText.isAddition("+++ b/source.c"))
  #expect(!UnifiedDiffText.isAddition(" unchanged"))
}

@Test("Streaming replies reuse the cached layout for the unchanged prefix")
@MainActor
func renderCacheIsIncremental() {
  let first = MarkdownRenderCache.lines(id: "live", text: "Hello **wor", width: 40)
  #expect(first.map { $0.map(\.text).joined() } == ["Hello **wor"])
  let second = MarkdownRenderCache.lines(
    id: "live", text: "Hello **world** done\n- item", width: 40)
  #expect(second.map { $0.map(\.text).joined() } == ["Hello world done", "• item"])
  let restarted = MarkdownRenderCache.lines(id: "live", text: "New reply", width: 40)
  #expect(restarted.map { $0.map(\.text).joined() } == ["New reply"])
}
