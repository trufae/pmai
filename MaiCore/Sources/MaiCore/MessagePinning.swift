/// Message pins belong to a transcript; global bookmark libraries are separate.
public protocol PinnableMessage: Identifiable {
  var isPinned: Bool { get set }
}

extension Array where Element: PinnableMessage {
  /// Transcript order, so message numbers and navigation remain predictable.
  public var pinnedMessages: [Element] { filter(\.isPinned) }

  @discardableResult
  public mutating func setMessagePinned(_ pinned: Bool, id: Element.ID) -> Bool {
    guard let index = firstIndex(where: { $0.id == id }) else { return false }
    self[index].isPinned = pinned
    return true
  }
}
