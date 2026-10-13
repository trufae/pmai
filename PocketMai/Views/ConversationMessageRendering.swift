import SwiftUI
import UIKit

/// Keep a stable suffix while live messages are appended to the conversation.
struct ConversationMessageRenderWindow {
  static let batchSize = 8

  private(set) var conversationID: UUID?
  private(set) var firstMessageID: UUID?
  private(set) var revision = 0
  private var lastMessageID: UUID?
  private var renderedCount = Self.batchSize

  func startIndex(in messages: [ChatMessage], conversationID: UUID?) -> Int {
    if self.conversationID == conversationID, let firstMessageID {
      if let index = messages.firstIndex(where: { $0.id == firstMessageID }) {
        return index
      }
      // Deleting the boundary row must not hide already revealed history.
      let end =
        lastMessageID.flatMap { id in messages.firstIndex(where: { $0.id == id }) }
        .map { $0 + 1 } ?? messages.count
      return max(0, end - renderedCount)
    }
    return max(0, messages.count - Self.batchSize)
  }

  mutating func reset(in messages: [ChatMessage], conversationID: UUID?) {
    // A restarted loading task can follow a preview replacement or deletion.
    // Preserve history that was already revealed by loading or navigation.
    let start = min(
      max(0, messages.count - Self.batchSize),
      startIndex(in: messages, conversationID: conversationID))
    setStart(start, in: messages, conversationID: conversationID)
  }

  @discardableResult
  mutating func revealEarlier(in messages: [ChatMessage], conversationID: UUID?) -> Bool {
    let start = startIndex(in: messages, conversationID: conversationID)
    guard start > 0 else { return false }
    setStart(max(0, start - Self.batchSize), in: messages, conversationID: conversationID)
    return true
  }

  mutating func reveal(_ messageID: UUID, in messages: [ChatMessage], conversationID: UUID?) {
    guard let index = messages.firstIndex(where: { $0.id == messageID }),
      index < startIndex(in: messages, conversationID: conversationID)
    else { return }
    setStart(index, in: messages, conversationID: conversationID)
  }

  private mutating func setStart(_ start: Int, in messages: [ChatMessage], conversationID: UUID?) {
    self.conversationID = conversationID
    firstMessageID = messages.indices.contains(start) ? messages[start].id : nil
    lastMessageID = messages.last?.id
    renderedCount = messages.count - start
    revision += 1
  }
}

/// Compensate only for prepended history, leaving ordinary response scrolling alone.
@MainActor
final class ConversationHistoryScrollSession {
  private weak var scrollView: UIScrollView?
  private weak var marker: UIView?
  private var viewportY: CGFloat?
  private var pendingRevision: Int?

  var isRestoring: Bool { viewportY != nil }

  func attach(_ marker: UIView) {
    var ancestor = marker.superview
    while let view = ancestor {
      if let scrollView = view as? UIScrollView {
        self.scrollView = scrollView
        self.marker = marker
        return
      }
      ancestor = view.superview
    }
  }

  func prepareForPrepend(revision: Int) -> Bool {
    guard !isRestoring, let scrollView, let marker,
      !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating
    else { return false }
    viewportY = marker.convert(.zero, to: scrollView).y - scrollView.contentOffset.y
    pendingRevision = revision
    return true
  }

  func restore(revision: Int) {
    guard pendingRevision == revision, let viewportY, let scrollView, let marker else { return }
    cancel()
    let target = marker.convert(.zero, to: scrollView).y - viewportY
    let minimum = -scrollView.adjustedContentInset.top
    let maximum = max(
      minimum,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom)
    scrollView.setContentOffset(
      CGPoint(x: scrollView.contentOffset.x, y: min(max(target, minimum), maximum)),
      animated: false)
  }

  func cancel() {
    viewportY = nil
    pendingRevision = nil
  }

  func detach(_ marker: UIView) {
    guard self.marker === marker else { return }
    cancel()
    self.marker = nil
    scrollView = nil
  }
}

struct ConversationHistoryScrollBridge: UIViewRepresentable {
  let session: ConversationHistoryScrollSession
  let revision: Int

  func makeUIView(context: Context) -> MarkerView {
    let view = MarkerView()
    view.isUserInteractionEnabled = false
    view.session = session
    return view
  }

  func updateUIView(_ view: MarkerView, context: Context) {
    view.revision = revision
    // SwiftUI places the marker after updating representables. Restore once
    // that layout has finished, before admitting the next history batch.
    DispatchQueue.main.async { [weak view] in
      guard let view, view.session === session, view.revision == revision else { return }
      session.attach(view)
      session.restore(revision: revision)
    }
  }

  static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
    view.session?.detach(view)
    view.session = nil
  }

  final class MarkerView: UIView {
    weak var session: ConversationHistoryScrollSession?
    var revision = 0

    override func didMoveToSuperview() {
      super.didMoveToSuperview()
      session?.attach(self)
    }
  }
}
