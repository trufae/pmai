import SwiftUI
import XCTest

@testable import PocketMai

final class ConversationMessageRenderingTests: XCTestCase {
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
    }
  }
}
