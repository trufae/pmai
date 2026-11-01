import SwiftUI
import XCTest

@testable import PocketMai

final class ConversationMessageRenderingTests: XCTestCase {
  @MainActor
  func testBalancedTablesWrapAndScrollAcrossAllColumnsAtDifferentWidths() async throws {
    let headers = ["First", "Second", "Third", "Fourth"]
    let text = "A longer cell with enough text to wrap across multiple lines and remain fully readable."
    let table = MarkdownTableView(
      headers: headers, rows: [Array(repeating: text, count: headers.count)],
      alignments: [], appearance: .defaults)
    let host = UIHostingController(rootView: table.frame(maxHeight: .infinity, alignment: .top))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousKeyWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previousKeyWindow?.makeKeyAndVisible()
    }

    func findScrollView(in view: UIView) -> UIScrollView? {
      if let scroll = view as? UIScrollView { return scroll }
      return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    for width in [320.0, 600.0] {
      window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
      try await waitForLayout(host: host) {
        guard let scroll = findScrollView(in: host.view) else { return false }
        return abs(scroll.bounds.width - width) < 1
          && abs(scroll.contentSize.width - width * 4 / 2.5) < 1
      }
      let scroll = try XCTUnwrap(findScrollView(in: host.view))
      // Four columns occupy more than the viewport, with two to three visible.
      let columnWidth = scroll.contentSize.width / CGFloat(headers.count)
      XCTAssertGreaterThan(scroll.bounds.width / columnWidth, 2)
      XCTAssertLessThan(scroll.bounds.width / columnWidth, 3)
      XCTAssertGreaterThan(scroll.contentSize.height, UIFont.systemFont(ofSize: 17).lineHeight * 4)
      let rightEdge = scroll.contentSize.width - scroll.bounds.width
      scroll.setContentOffset(CGPoint(x: rightEdge, y: 0), animated: false)
      XCTAssertEqual(scroll.contentOffset.x + scroll.bounds.width, scroll.contentSize.width, accuracy: 1)

      let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: screenshot)
      attachment.name = "Balanced table at \(Int(width))pt, scrolled to the last column"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  @MainActor
  func testMixedActivityKeepsMessagesActionsAndStableHistoryIdentity() {
    let question = ChatMessage(role: .user, text: "Question")
    let thought = ChatMessage(role: .assistant, text: "<think>Check the file</think>")
    let tool = ChatMessage(role: .tool, text: "<tool_run>Shell tool ():\nError: failed\n</tool_run>")
    let nextThought = ChatMessage(role: .assistant, text: "<think>Try another file</think>")
    let answer = ChatMessage(role: .assistant, text: "Answer")
    let messages = [question, thought, tool, nextThought, answer]
    let id = UUID()
    let runs = ConversationMessageRun.grouped(messages[...], conversationID: id)
    XCTAssertEqual(runs.map(\.messages.count), [1, 3, 1])
    XCTAssertEqual(runs.flatMap(\.messages).map(\.id), messages.map(\.id))
    XCTAssertEqual(runs.map(\.isActivity), [false, true, false])
    XCTAssertEqual(MessageRenderCache.failedToolCount(tool), 1)
    let tail = ConversationMessageRun.grouped(messages[2...], conversationID: id)
    XCTAssertEqual(tail.first?.id, runs[1].id)
    let live = ConversationMessageRun.grouped(messages[1...2], conversationID: id)
    let extended = ConversationMessageRun.grouped(messages[1...3], conversationID: id)
    XCTAssertEqual(live.first?.id, extended.first?.id)
    XCTAssertFalse(MessageRenderCache.isActivity(ChatMessage(role: .error, text: "Connection lost")))
  }

  func testInitialRenderIsBoundedAndIncludesTheLatestMessage() {
    let messages = makeMessages(1_000)
    let window = ConversationMessageRenderWindow()
    let start = window.startIndex(in: messages, conversationID: UUID())
    XCTAssertEqual(Array(messages[start...].map(\.id)), Array(messages.suffix(8).map(\.id)))
    XCTAssertEqual(window.startIndex(in: [], conversationID: nil), 0)
    XCTAssertEqual(window.startIndex(in: Array(messages.prefix(3)), conversationID: UUID()), 0)
  }

  func testFilteredPreviewDoesNotExpandTheInitialFullHistoryRender() {
    var messages = makeMessages(100)
    for index in 10..<99 { messages[index].role = .tool }
    let preview = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(6)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    XCTAssertEqual(window.startIndex(in: Array(preview), conversationID: conversationID), 0)
    window.reset(in: messages, conversationID: conversationID)
    XCTAssertEqual(window.startIndex(in: messages, conversationID: conversationID), 92)
  }

  func testHistoryBatchesReachTheBeginningWithoutDroppingOrReorderingMessages() {
    let messages = makeMessages(43)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reset(in: messages, conversationID: conversationID)
    var previousStart = window.startIndex(in: messages, conversationID: conversationID)
    while window.revealEarlier(in: messages, conversationID: conversationID) {
      let start = window.startIndex(in: messages, conversationID: conversationID)
      XCTAssertEqual(start, max(0, previousStart - ConversationMessageRenderWindow.batchSize))
      XCTAssertEqual(messages[start...].last?.id, messages.last?.id)
      previousStart = start
    }
    XCTAssertEqual(previousStart, 0)
  }

  func testAppendedResponsesDoNotEvictAlreadyRenderedHistory() {
    var messages = makeMessages(40)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reset(in: messages, conversationID: conversationID)
    window.revealEarlier(in: messages, conversationID: conversationID)
    let start = window.startIndex(in: messages, conversationID: conversationID)
    messages.append(contentsOf: makeMessages(10))
    XCTAssertEqual(window.startIndex(in: messages, conversationID: conversationID), start)
    XCTAssertEqual(messages[start...].count, 26)
  }

  func testConversationSwitchAndPreviewReplacementStartWithRecentMessages() {
    let messages = makeMessages(40)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reset(in: messages, conversationID: conversationID)
    while window.revealEarlier(in: messages, conversationID: conversationID) {}
    XCTAssertEqual(window.startIndex(in: messages, conversationID: UUID()), 32)

    window.reset(in: Array(messages.suffix(6)), conversationID: conversationID)
    window.reset(in: messages, conversationID: conversationID)
    XCTAssertEqual(window.startIndex(in: messages, conversationID: conversationID), 32)
  }

  func testNavigationImmediatelyRevealsAnOlderTarget() {
    let messages = makeMessages(100)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reset(in: messages, conversationID: conversationID)
    window.reveal(messages[10].id, in: messages, conversationID: conversationID)
    XCTAssertEqual(window.startIndex(in: messages, conversationID: conversationID), 10)
    window.reveal(messages[99].id, in: messages, conversationID: conversationID)
    window.reveal(UUID(), in: messages, conversationID: conversationID)
    XCTAssertEqual(window.startIndex(in: messages, conversationID: conversationID), 10)
  }

  func testRestartingHistoryLoadingPreservesANavigationTarget() {
    let messages = makeMessages(100)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reveal(messages[10].id, in: messages, conversationID: conversationID)
    window.reset(in: messages, conversationID: conversationID)
    XCTAssertEqual(window.startIndex(in: messages, conversationID: conversationID), 10)
  }

  func testDeletingTheRenderedBoundaryKeepsRevealedHistoryAndNewResponses() {
    var messages = makeMessages(40)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reset(in: messages, conversationID: conversationID)
    window.revealEarlier(in: messages, conversationID: conversationID)
    let retainedIDs = messages[25...].map(\.id)
    messages.append(contentsOf: makeMessages(3))
    messages.remove(at: 24)
    window.reset(in: messages, conversationID: conversationID)
    let start = window.startIndex(in: messages, conversationID: conversationID)
    XCTAssertTrue(Set(retainedIDs).isSubset(of: Set(messages[start...].map(\.id))))
    XCTAssertEqual(messages[start...].last?.id, messages.last?.id)
  }

  func testToolPartsLoadFromTheNewestMessageFirstAndKeepTheirBoundaryWhenAppended() {
    let messages = makeMessages(2)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reset(in: messages, conversationID: conversationID)
    for message in messages { window.prepareParts(for: message.id, count: 25) }
    XCTAssertEqual(window.partStartIndex(for: messages[1].id), 17)
    XCTAssertEqual(
      window.messageWithEarlierParts(in: messages, conversationID: conversationID), messages[1].id)
    window.revealEarlierParts(for: messages[1].id)
    XCTAssertEqual(window.partStartIndex(for: messages[1].id), 9)
    window.prepareParts(for: messages[1].id, count: 40)
    XCTAssertEqual(window.partStartIndex(for: messages[1].id), 9)
    window.revealEarlierParts(for: messages[1].id)
    window.revealEarlierParts(for: messages[1].id)
    XCTAssertEqual(window.partStartIndex(for: messages[1].id), 0)
    XCTAssertEqual(
      window.messageWithEarlierParts(in: messages, conversationID: conversationID), messages[0].id)
    window.reset(in: messages, conversationID: UUID())
    XCTAssertNil(window.partStartIndex(for: messages[1].id))
  }

  func testNavigationRevealsHiddenPartsOfAnAlreadyRenderedMessage() {
    let messages = makeMessages(2)
    let conversationID = UUID()
    var window = ConversationMessageRenderWindow()
    window.reset(in: messages, conversationID: conversationID)
    window.prepareParts(for: messages[1].id, count: 100)
    window.reveal(messages[1].id, in: messages, conversationID: conversationID)
    XCTAssertEqual(window.partStartIndex(for: messages[1].id), 0)
    XCTAssertNil(window.messageWithEarlierParts(in: messages, conversationID: conversationID))
  }

  func testSwitchingConversationDoesNotReusePartBoundariesForCopiedMessages() {
    let messages = makeMessages(2)
    var window = ConversationMessageRenderWindow()
    let originalID = UUID()
    let copyID = UUID()
    window.reset(in: messages, conversationID: originalID)
    window.prepareParts(for: messages[1].id, count: 100)
    window.reveal(messages[1].id, in: messages, conversationID: originalID)
    XCTAssertNil(window.partStartIndex(for: messages[1].id, conversationID: copyID))
    window.reveal(messages[1].id, in: messages, conversationID: copyID)
    XCTAssertEqual(window.conversationID, copyID)
    XCTAssertEqual(window.partStartIndex(for: messages[1].id, conversationID: copyID), 0)
  }

  @MainActor
  func testToolHeavyMessageRendersItsTailFirstAndPreservesTheAnswerWhilePrepending() async throws {
    try await checkToolPartPrepending(readingEarlierMessage: false)
  }

  @MainActor
  func testLoadingToolPartsBelowTheReadingPositionDoesNotMoveTheViewport() async throws {
    try await checkToolPartPrepending(readingEarlierMessage: true)
  }

  @MainActor
  private func checkToolPartPrepending(readingEarlierMessage: Bool) async throws {
    // Interleave visible text so tool grouping does not collapse the fixture.
    // Two batches plus one call exercise repeated prepends without a huge view.
    let toolCount = ConversationMessageRenderWindow.batchSize * 2 + 1
    let tools = (0..<toolCount).map { index in
      "<tool_run>\nShell tool (step \(index)):\nresult \(index)\n</tool_run>\nStep \(index) finished."
    }.joined(separator: "\n")
    let message = ChatMessage(role: .assistant, text: tools + "\n\nFinal answer.")
    let fixture = ToolPartRenderFixture(message: message, hasEarlierMessage: readingEarlierMessage)
    let host = UIHostingController(rootView: ToolPartRenderTestView(fixture: fixture))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }

    func findScrollView(in view: UIView) -> UIScrollView? {
      if let scroll = view as? UIScrollView { return scroll }
      return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }
    func findAnswer(in view: UIView) -> UITextView? {
      if let text = view as? UITextView, text.text.contains("Final answer.") { return text }
      return view.subviews.lazy.compactMap { findAnswer(in: $0) }.first
    }
    try await waitForLayout(host: host) {
      findScrollView(in: host.view)?.contentSize.height ?? 0 > 0
        && findAnswer(in: host.view) != nil
    }
    let scroll = try XCTUnwrap(findScrollView(in: host.view))
    let answer = try XCTUnwrap(findAnswer(in: host.view))
    XCTAssertLessThan(scroll.contentSize.height, readingEarlierMessage ? 2_000 : 1_000)
    let initialHeight = scroll.contentSize.height
    let minimum = -scroll.adjustedContentInset.top
    let bottom = max(
      minimum,
      scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    scroll.setContentOffset(CGPoint(x: 0, y: readingEarlierMessage ? 100 : bottom), animated: false)
    try await Task.sleep(for: .milliseconds(30))
    let originalOffset = scroll.contentOffset.y
    let answerViewportY = answer.convert(.zero, to: scroll).y - scroll.contentOffset.y

    while fixture.renderWindow.partStartIndex(for: message.id) ?? 0 > 0 {
      let height = scroll.contentSize.height
      let offset = scroll.contentOffset.y
      XCTAssertTrue(
        fixture.scrollSession.prepareForPrepend(revision: fixture.renderWindow.revision + 1))
      fixture.renderWindow.revealEarlierParts(for: message.id)
      try await waitForLayout(host: host) { !fixture.scrollSession.isRestoring }
      if readingEarlierMessage {
        XCTAssertEqual(scroll.contentOffset.y, originalOffset, accuracy: 1)
      } else {
        let expected = max(minimum, offset + scroll.contentSize.height - height)
        XCTAssertEqual(scroll.contentOffset.y, expected, accuracy: 1)
        XCTAssertEqual(
          answer.convert(.zero, to: scroll).y - scroll.contentOffset.y,
          answerViewportY, accuracy: 1)
      }
    }
    XCTAssertEqual(fixture.renderWindow.partStartIndex(for: message.id), 0)
    XCTAssertGreaterThan(scroll.contentSize.height, initialHeight)
  }

  @MainActor
  func testCanceledOrStaleRestoresDoNotOverrideNavigation() {
    let session = ConversationHistoryScrollSession()
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
    scroll.contentSize = CGSize(width: 390, height: 1_000)
    let marker = UIView(frame: CGRect(x: 0, y: 999, width: 390, height: 1))
    scroll.addSubview(marker)
    session.attach(marker)
    XCTAssertTrue(session.prepareForPrepend(revision: 2))
    marker.frame.origin.y += 500
    scroll.contentSize.height += 500
    session.restore(revision: 1)
    XCTAssertTrue(session.isRestoring)
    XCTAssertEqual(scroll.contentOffset.y, 0)
    session.cancel()
    scroll.contentOffset.y = 200
    session.restore(revision: 2)
    XCTAssertFalse(session.isRestoring)
    XCTAssertEqual(scroll.contentOffset.y, 200)
  }

  @MainActor
  func testPrependingKeepsTheBottomVisible() async throws {
    try await checkPrepending(rowHeight: 100, scrollUp: 0)
  }

  @MainActor
  func testKeyboardAndComposerResizingKeepsTheBottomVisible() async throws {
    try await checkViewportResize(rowHeight: 120, scrollUp: 0)
  }

  @MainActor
  func testKeyboardResizingPreservesAnOlderReadingPosition() async throws {
    try await checkViewportResize(rowHeight: 120, scrollUp: 300)
  }

  @MainActor
  func testKeyboardResizingKeepsAShortConversationAtTheBottom() async throws {
    try await checkViewportResize(rowHeight: 20, scrollUp: 0)
  }

  @MainActor
  private func checkViewportResize(rowHeight: CGFloat, scrollUp: CGFloat) async throws {
    let fixture = RenderFixture(messages: makeMessages(43), rowHeight: rowHeight)
    fixture.viewportHeight = 700
    let host = UIHostingController(rootView: RenderTestView(fixture: fixture))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }
    func findScrollView(in view: UIView) -> UIScrollView? {
      (view as? UIScrollView) ?? view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }
    try await waitForLayout(host: host) {
      findScrollView(in: host.view)?.contentSize.height ?? 0 > 0
    }
    let scroll = try XCTUnwrap(findScrollView(in: host.view))
    func bottom() -> CGFloat {
      max(
        -scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    }
    let readingOffset = max(-scroll.adjustedContentInset.top, bottom() - scrollUp)
    scroll.setContentOffset(CGPoint(x: 0, y: readingOffset), animated: false)
    for height in [550.0, 360.0, 180.0, 700.0] {
      fixture.viewportHeight = height
      try await waitForLayout(host: host) { abs(scroll.bounds.height - height) < 1 }
      XCTAssertEqual(
        scroll.contentOffset.y, scrollUp == 0 ? bottom() : readingOffset,
        accuracy: 2, "Viewport height \(height) must preserve the reading anchor")
    }
  }

  @MainActor
  func testPrependingPreservesTheReadingPositionAboveTheBottom() async throws {
    try await checkPrepending(rowHeight: 100, scrollUp: 240)
  }

  @MainActor
  func testPrependingPreservesTheReadingPositionWithinATallReply() async throws {
    try await checkPrepending(rowHeight: 1_200, scrollUp: 240)
  }

  @MainActor
  func testPrependingFromAShortConversationPreservesBottomAlignment() async throws {
    try await checkPrepending(rowHeight: 20, scrollUp: 0)
  }

  @MainActor
  private func checkPrepending(rowHeight: CGFloat, scrollUp: CGFloat) async throws {
    let fixture = RenderFixture(messages: makeMessages(43), rowHeight: rowHeight)
    let host = UIHostingController(rootView: RenderTestView(fixture: fixture))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }

    func findScrollView(in view: UIView) -> UIScrollView? {
      if let scroll = view as? UIScrollView { return scroll }
      return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }
    try await waitForLayout(host: host) {
      findScrollView(in: host.view)?.contentSize.height ?? 0 > 0
    }
    let scroll = try XCTUnwrap(findScrollView(in: host.view))
    let minimum = -scroll.adjustedContentInset.top
    let bottom = max(
      minimum,
      scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    scroll.setContentOffset(CGPoint(x: 0, y: max(minimum, bottom - scrollUp)), animated: false)
    try await Task.sleep(for: .milliseconds(30))

    while fixture.renderWindow.startIndex(in: fixture.messages, conversationID: fixture.id) > 0 {
      let height = scroll.contentSize.height
      let offset = scroll.contentOffset.y
      XCTAssertTrue(
        fixture.scrollSession.prepareForPrepend(revision: fixture.renderWindow.revision + 1))
      fixture.renderWindow.revealEarlier(in: fixture.messages, conversationID: fixture.id)
      try await waitForLayout(host: host) { !fixture.scrollSession.isRestoring }
      XCTAssertEqual(
        scroll.contentOffset.y, offset + scroll.contentSize.height - height, accuracy: 1)
    }

    // Ordinary message growth must not trigger history compensation.
    let offset = scroll.contentOffset.y
    fixture.messages.append(contentsOf: makeMessages(2))
    let previousHeight = scroll.contentSize.height
    try await waitForLayout(host: host) { scroll.contentSize.height > previousHeight }
    XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
  }

  @MainActor
  private func waitForLayout(host: UIViewController, until ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    repeat {
      host.view.setNeedsLayout()
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
      if ready() { return }
    } while ContinuousClock.now < deadline
    XCTFail("Conversation layout did not settle")
  }

  private func makeMessages(_ count: Int) -> [ChatMessage] {
    (0..<count).map {
      ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Message \($0)")
    }
  }
}

@MainActor
@Observable
private final class RenderFixture {
  var viewportHeight: CGFloat?
  let id = UUID()
  var messages: [ChatMessage]
  let rowHeight: CGFloat
  var renderWindow = ConversationMessageRenderWindow()
  let scrollSession = ConversationHistoryScrollSession()

  init(messages: [ChatMessage], rowHeight: CGFloat) {
    self.messages = messages
    self.rowHeight = rowHeight
    renderWindow.reset(in: messages, conversationID: id)
  }
}

private struct RenderTestView: View {
  let fixture: RenderFixture

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        let start = fixture.renderWindow.startIndex(
          in: fixture.messages, conversationID: fixture.id)
        VStack(spacing: 14) {
          if start == 0 { Text("Chat Started") }
          ForEach(fixture.messages.suffix(from: start)) { message in
            Text(message.text).frame(height: fixture.rowHeight)
          }
          Color.clear.frame(height: 1)
            .background {
              ConversationHistoryScrollBridge(
                session: fixture.scrollSession, revision: fixture.renderWindow.revision)
            }
        }
        .padding()
        .frame(width: geometry.size.width)
        .frame(minHeight: geometry.size.height, alignment: .bottom)
      }
      .onScrollGeometryChange(for: ConversationScrollViewport.self) {
        ConversationScrollViewport($0)
      } action: { old, new in
        fixture.scrollSession.preserveBottomOnResize(from: old, to: new)
      }
    }
    .frame(height: fixture.viewportHeight)
  }
}

@MainActor
@Observable
private final class ToolPartRenderFixture {
  let message: ChatMessage
  let hasEarlierMessage: Bool
  let earlierMessageID = UUID()
  var renderWindow = ConversationMessageRenderWindow()
  let scrollSession = ConversationHistoryScrollSession()
  let streamingTextStore = StreamingTextStore()

  init(message: ChatMessage, hasEarlierMessage: Bool) {
    self.message = message
    self.hasEarlierMessage = hasEarlierMessage
    renderWindow.reset(in: [message], conversationID: UUID())
    renderWindow.prepareParts(for: message.id, count: MessageRenderCache.partCount(for: message))
  }
}

private struct ToolPartRenderTestView: View {
  let fixture: ToolPartRenderFixture

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 14) {
          if fixture.hasEarlierMessage {
            Text("Earlier message").frame(height: 1_000)
              .background(alignment: .bottom) {
                ConversationHistoryScrollBridge(
                  session: fixture.scrollSession, revision: fixture.renderWindow.revision,
                  messageID: fixture.earlierMessageID
                )
                .frame(height: 1)
              }
          }
          MessageBubble(
            message: fixture.message,
            renderedPartStartIndex: fixture.renderWindow.partStartIndex(for: fixture.message.id),
            toolSettings: .defaults, openAIEndpoints: [], appearance: .defaults,
            actions: MessageBubbleActions(onEdit: { _ in })
          )
          .background(alignment: .bottom) {
            ConversationHistoryScrollBridge(
              session: fixture.scrollSession, revision: fixture.renderWindow.revision,
              messageID: fixture.message.id
            )
            .frame(height: 1)
          }
          Color.clear.frame(height: 1)
            .background {
              ConversationHistoryScrollBridge(
                session: fixture.scrollSession, revision: fixture.renderWindow.revision)
            }
        }
        .padding()
        .frame(width: geometry.size.width)
        .frame(minHeight: geometry.size.height, alignment: .bottom)
      }
    }
    .environmentObject(fixture.streamingTextStore)
  }
}
