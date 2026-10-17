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
  private var partStartIndices: [UUID: Int] = [:]

  func partStartIndex(for messageID: UUID) -> Int? {
    partStartIndices[messageID]
  }

  func partStartIndex(for messageID: UUID, conversationID: UUID?) -> Int? {
    self.conversationID == conversationID ? partStartIndices[messageID] : nil
  }

  mutating func prepareParts(for messageID: UUID, count: Int) {
    if partStartIndices[messageID] == nil {
      partStartIndices[messageID] = max(0, count - Self.batchSize)
    }
  }

  func messageWithEarlierParts(in messages: [ChatMessage], conversationID: UUID?) -> UUID? {
    messages.suffix(from: startIndex(in: messages, conversationID: conversationID))
      .reversed().first { partStartIndices[$0.id, default: 0] > 0 }?.id
  }

  mutating func revealEarlierParts(for messageID: UUID) {
    guard let start = partStartIndices[messageID], start > 0 else { return }
    partStartIndices[messageID] = max(0, start - Self.batchSize)
    revision += 1
  }

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
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    if self.conversationID != conversationID {
      reset(in: messages, conversationID: conversationID)
    }
    if index < startIndex(in: messages, conversationID: conversationID) {
      setStart(index, in: messages, conversationID: conversationID)
    } else if partStartIndices[messageID] != 0 {
      revision += 1
    }
    // Search and bookmark navigation may target prose before a long tool run.
    partStartIndices[messageID] = 0
  }

  private mutating func setStart(_ start: Int, in messages: [ChatMessage], conversationID: UUID?) {
    if self.conversationID != conversationID { partStartIndices.removeAll() }
    self.conversationID = conversationID
    firstMessageID = messages.indices.contains(start) ? messages[start].id : nil
    lastMessageID = messages.last?.id
    renderedCount = messages.count - start
    revision += 1
  }
}

struct ConversationScrollViewport: Equatable {
  let height: CGFloat
  let isAtBottom: Bool

  init(_ geometry: ScrollGeometry) {
    height = geometry.containerSize.height
    isAtBottom =
      geometry.contentSize.height <= height + 2
      || geometry.visibleRect.maxY >= geometry.contentSize.height - 2
  }
}

/// Preserve the reading position while loading history or resizing the viewport.
@MainActor
final class ConversationHistoryScrollSession {
  private struct WeakMarker {
    weak var view: UIView?
  }

  private weak var scrollView: UIScrollView?
  private var bottomResizeToken: UUID?
  private var pendingBottomResize = false
  private weak var marker: UIView?
  private var messageMarkers: [UUID: WeakMarker] = [:]
  private weak var restorationMarker: UIView?
  private var viewportY: CGFloat?
  private var pendingRevision: Int?

  var isRestoring: Bool { viewportY != nil }

  func attach(_ marker: UIView, messageID: UUID? = nil) {
    var ancestor = marker.superview
    while let view = ancestor {
      if let scrollView = view as? UIScrollView {
        self.scrollView = scrollView
        if let messageID {
          messageMarkers[messageID] = WeakMarker(view: marker)
        } else {
          self.marker = marker
        }
        return
      }
      ancestor = view.superview
    }
  }

  /// Keyboard and composer resizing should keep a fully visible tail on screen.
  /// Read the old viewport: after the resize, that same offset is no longer at the bottom.
  func preserveBottomOnResize(
    from old: ConversationScrollViewport, to new: ConversationScrollViewport
  ) {
    if new.isAtBottom { pendingBottomResize = false }
    guard old.height > 0, new.height > 0, old.height != new.height,
      old.isAtBottom || pendingBottomResize,
      let scroll = scrollView,
      !isRestoring, !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating
    else { return }
    pendingBottomResize = true
    let token = UUID()
    bottomResizeToken = token
    // Let SwiftUI finish applying its new frame before correcting the offset.
    DispatchQueue.main.async { [weak self, weak scroll] in
      guard let self, let scroll, self.scrollView === scroll,
        self.bottomResizeToken == token, !self.isRestoring,
        !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating
      else { return }
      let bottom = max(
        -scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
      scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
    }
  }

  func prepareForPrepend(revision: Int) -> Bool {
    guard !isRestoring, let scrollView, let marker,
      !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating
    else { return false }
    // Parts can be inserted inside a message below the viewport. Anchoring to
    // the chat's bottom would then move text that did not change at all.
    let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top + 1
    let anchor =
      messageMarkers.values.compactMap { entry -> (UIView, CGFloat)? in
        guard let view = entry.view else { return nil }
        let y = view.convert(.zero, to: scrollView).y
        return y >= visibleTop ? (view, y) : nil
      }.min { $0.1 < $1.1 }?.0 ?? marker
    restorationMarker = anchor
    viewportY = anchor.convert(.zero, to: scrollView).y - scrollView.contentOffset.y
    pendingRevision = revision
    return true
  }

  func restore(revision: Int) {
    guard pendingRevision == revision, let viewportY, let scrollView,
      let marker = restorationMarker
    else { return }
    cancel()
    guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else { return }
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

  func stopScrolling() {
    scrollView?.stopScrollingAndZooming()
  }

  func cancel() {
    bottomResizeToken = nil
    pendingBottomResize = false
    viewportY = nil
    pendingRevision = nil
    restorationMarker = nil
  }

  func detach(_ marker: UIView, messageID: UUID? = nil) {
    if let messageID {
      if messageMarkers[messageID]?.view === marker {
        messageMarkers.removeValue(forKey: messageID)
      }
      if restorationMarker === marker { cancel() }
      return
    }
    guard self.marker === marker else { return }
    cancel()
    self.marker = nil
    scrollView = nil
    messageMarkers.removeAll()
  }
}

struct ConversationHistoryScrollBridge: UIViewRepresentable {
  let session: ConversationHistoryScrollSession
  let revision: Int
  var messageID: UUID? = nil

  func makeUIView(context: Context) -> MarkerView {
    let view = MarkerView()
    view.isUserInteractionEnabled = false
    view.session = session
    view.messageID = messageID
    return view
  }

  func updateUIView(_ view: MarkerView, context: Context) {
    view.revision = revision
    // SwiftUI places the marker after updating representables. Restore once
    // that layout has finished, before admitting the next history batch.
    DispatchQueue.main.async { [weak view] in
      guard let view, view.session === session, view.revision == revision else { return }
      session.attach(view, messageID: messageID)
      session.restore(revision: revision)
    }
  }

  static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
    view.session?.detach(view, messageID: view.messageID)
    view.session = nil
  }

  final class MarkerView: UIView {
    weak var session: ConversationHistoryScrollSession?
    var revision = 0
    var messageID: UUID?

    override func didMoveToSuperview() {
      super.didMoveToSuperview()
      session?.attach(self, messageID: messageID)
    }
  }
}
