import SwiftUI
import XCTest

@testable import PocketMai

final class ReasoningRenderBufferTests: XCTestCase {
  func testStreamUpdatesKeepHistoryStableUntilConsolidated() {
    let history = String(repeating: "Earlier reasoning.\n", count: 10_000)
    var buffer = ReasoningRenderBuffer(history)
    for index in 1...50 {
      let delta = String(repeating: "x", count: index)
      buffer.update(history + delta, isStreaming: true)
      XCTAssertEqual(buffer.settledText, history)
      XCTAssertEqual(buffer.tail, delta)
    }

    buffer.consolidate()
    let consolidated = history + String(repeating: "x", count: 50)
    XCTAssertEqual(buffer.settledText, consolidated)
    XCTAssertEqual(buffer.tail, "")

    buffer.update(consolidated + " next", isStreaming: true)
    XCTAssertEqual(buffer.settledText, consolidated)
    XCTAssertEqual(buffer.tail, " next")
  }

  func testLargeBurstsBoundTheTailWithoutDroppingText() {
    var buffer = ReasoningRenderBuffer("Start")
    let burst = String(repeating: "🐈", count: ReasoningRenderBuffer.tailCapacity)
    buffer.update("Start" + burst, isStreaming: true)
    XCTAssertLessThan(buffer.tail.utf8.count, ReasoningRenderBuffer.tailCapacity)
    XCTAssertEqual(buffer.settledText + buffer.tail, "Start" + burst)
  }

  func testCompletionFlushesPendingMarkdownEvenWithoutNewText() {
    var buffer = ReasoningRenderBuffer("**partial")
    buffer.update("**partial text**", isStreaming: true)
    XCTAssertEqual(buffer.tail, " text**")

    buffer.update("**partial text**", isStreaming: false)
    XCTAssertEqual(buffer.settledText, "**partial text**")
    XCTAssertEqual(buffer.tail, "")
  }

  func testPeriodicConsolidationKeepsUnfinishedParagraphAndCodeTogether() {
    let history = "First paragraph.\n\n"
    var buffer = ReasoningRenderBuffer(history + "Next sentence", isStreaming: true)
    XCTAssertEqual(buffer.settledText, history)
    XCTAssertEqual(buffer.tail, "Next sentence")
    buffer.consolidateCompletedParagraphs()
    XCTAssertEqual(buffer.settledText, history)

    let code = "Next sentence.\n\n```swift\nlet a = 1\n\nlet b = 2"
    buffer.update(history + code, isStreaming: true)
    buffer.consolidateCompletedParagraphs()
    XCTAssertEqual(buffer.settledText, history + "Next sentence.\n\n")
    XCTAssertEqual(buffer.tail, "```swift\nlet a = 1\n\nlet b = 2")

    let finished = history + code + "\n```\n\nLast paragraph"
    buffer.update(finished, isStreaming: true)
    buffer.consolidateCompletedParagraphs()
    XCTAssertEqual(buffer.tail, "Last paragraph")
    XCTAssertEqual(buffer.settledText + buffer.tail, finished)
    buffer.update(finished, isStreaming: false)
    XCTAssertEqual(buffer.settledText, finished)
  }

  func testReplacementTruncationAndEmptyContentResetHistory() {
    var buffer = ReasoningRenderBuffer("Original")
    buffer.update("Original tail", isStreaming: true)
    for replacement in ["Different response", "Different", ""] {
      buffer.update(replacement, isStreaming: true)
      XCTAssertEqual(buffer.settledText, replacement)
      XCTAssertEqual(buffer.tail, "")
    }
  }

  func testUnicodeAndGraphemeExtensionsPreserveExactBytes() {
    var buffer = ReasoningRenderBuffer("日本語 🐈 e")
    let text = "日本語 🐈 e\u{301} 👩\u{200D}💻"
    buffer.update(text, isStreaming: true)
    XCTAssertEqual(Array((buffer.settledText + buffer.tail).utf8), Array(text.utf8))
    XCTAssertEqual(buffer.tail, "")
    buffer.consolidate()
    XCTAssertEqual(Array(buffer.settledText.utf8), Array(text.utf8))

    let normalized = "日本語 🐈 é 👩\u{200D}💻"
    buffer.update(normalized, isStreaming: true)
    XCTAssertEqual(Array(buffer.settledText.utf8), Array(normalized.utf8))
    XCTAssertEqual(buffer.tail, "")
  }

  @MainActor
  func testExpandedReasoningScrollsWithinBoundedFrame() async throws {
    try await checkExpandedLayout(text: String(repeating: "A reasoning line.\n", count: 200)) {
      scrollView in
      XCTAssertEqual(scrollView.bounds.height, 240, accuracy: 1)
      XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height * 2)
      let bottom = scrollView.contentSize.height - scrollView.bounds.height
      scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
      XCTAssertEqual(scrollView.contentOffset.y, bottom, accuracy: 1)
    }
  }

  @MainActor
  func testShortExpandedReasoningFitsItsContent() async throws {
    try await checkExpandedLayout(text: "A short thought.") { scrollView in
      XCTAssertGreaterThan(scrollView.bounds.height, 20)
      XCTAssertLessThan(scrollView.bounds.height, 100)
      XCTAssertEqual(scrollView.bounds.height, scrollView.contentSize.height, accuracy: 1)
    }
  }

  @MainActor
  private func checkExpandedLayout(text: String, check: (UIScrollView) -> Void) async throws {
    let suite = "ReasoningLayoutTests.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    preferences.set("full", forKey: "thinkingDisplay")
    defer { preferences.removePersistentDomain(forName: suite) }

    let message = ChatMessage(role: .assistant, text: "<think>\n\(text)\n</think>")
    let root = MessageBubble(
      message: message, toolSettings: .defaults, openAIEndpoints: [],
      appearance: .defaults, renderMarkdown: false, showThinking: true
    )
    .environmentObject(StreamingTextStore())
    .defaultAppStorage(preferences)
    .frame(width: 360)
    let host = UIHostingController(rootView: root)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }
    host.view.layoutIfNeeded()
    // Allow SwiftUI's geometry preference to size short content on the next pass.
    try await Task.sleep(for: .milliseconds(200))
    host.view.layoutIfNeeded()

    func scrollView(in view: UIView) -> UIScrollView? {
      if let scroll = view as? UIScrollView { return scroll }
      return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
    check(try XCTUnwrap(scrollView(in: host.view)))
  }
}
