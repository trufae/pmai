import Foundation

/// A mutable conversation transcript independent from any UI or persistence layer.
///
/// Index-based methods use Swift's zero-based collection indexing. User interfaces
/// can present their own numbering or use stable `AgentMessage.id` values.
public struct AgentTranscript: Codable, Equatable, Sendable {
  public private(set) var messages: [AgentMessage]

  public init(messages: [AgentMessage] = []) {
    self.messages = messages
  }

  public var count: Int { messages.count }
  public var isEmpty: Bool { messages.isEmpty }

  public subscript(index: Int) -> AgentMessage { messages[index] }

  public func index(ofMessageID id: String) -> Int? {
    messages.firstIndex { $0.id == id }
  }

  @discardableResult
  public mutating func setMessagePinned(_ pinned: Bool, id: String) -> Bool {
    messages.setMessagePinned(pinned, id: id)
  }

  public mutating func append(_ message: AgentMessage) {
    messages.append(message)
  }

  public mutating func replaceAll(with messages: [AgentMessage]) {
    self.messages = messages
  }

  @discardableResult
  public mutating func editMessage(at index: Int, text: String) throws -> AgentMessage {
    try validate(index)
    let previous = messages[index]
    messages[index].replaceEditableText(with: text)
    return previous
  }

  @discardableResult
  public mutating func editMessage(id: String, text: String) throws -> AgentMessage {
    guard let index = index(ofMessageID: id) else {
      throw AgentTranscriptError.messageNotFound(id)
    }
    return try editMessage(at: index, text: text)
  }

  /// Removes a message. Removing either side of a tool transaction also removes
  /// its linked assistant tool-call message and sibling tool results.
  @discardableResult
  public mutating func removeMessage(at index: Int) throws -> [AgentMessage] {
    try validate(index)
    let indexes = linkedRemovalIndexes(for: index)
    let removed = indexes.sorted().map { messages[$0] }
    messages = messages.enumerated().compactMap { offset, message in
      indexes.contains(offset) ? nil : message
    }
    return removed
  }

  @discardableResult
  public mutating func removeMessage(id: String) throws -> [AgentMessage] {
    guard let index = index(ofMessageID: id) else {
      throw AgentTranscriptError.messageNotFound(id)
    }
    return try removeMessage(at: index)
  }

  /// Keeps the selected message and everything before it.
  ///
  /// If the boundary splits a tool transaction, that incomplete transaction is
  /// removed as well so the remaining transcript can still be sent to a provider.
  @discardableResult
  public mutating func trim(through index: Int) throws -> [AgentMessage] {
    try validate(index)
    var lastKeptIndex = index
    if let danglingStart = danglingToolTransactionStart(through: index) {
      lastKeptIndex = danglingStart - 1
    }
    let removalStart = lastKeptIndex + 1
    guard removalStart < messages.count else { return [] }
    let removed = Array(messages[removalStart...])
    messages = removalStart == 0 ? [] : Array(messages[..<removalStart])
    return removed
  }

  @discardableResult
  public mutating func trim(throughMessageID id: String) throws -> [AgentMessage] {
    guard let index = index(ofMessageID: id) else {
      throw AgentTranscriptError.messageNotFound(id)
    }
    return try trim(through: index)
  }

  @discardableResult
  public mutating func removeAll() -> [AgentMessage] {
    let removed = messages
    messages.removeAll()
    return removed
  }

  private func validate(_ index: Int) throws {
    guard messages.indices.contains(index) else {
      throw AgentTranscriptError.indexOutOfRange(index: index, count: messages.count)
    }
  }

  private func linkedRemovalIndexes(for index: Int) -> Set<Int> {
    var indexes: Set<Int> = [index]
    var callIDs = Set(messages[index].toolCalls.map(\.id))
    let resultIDs = Set(messages[index].toolResults.map(\.callID))

    if !resultIDs.isEmpty {
      for (offset, message) in messages.enumerated() {
        let candidateIDs = Set(message.toolCalls.map(\.id))
        guard !candidateIDs.isDisjoint(with: resultIDs) else { continue }
        indexes.insert(offset)
        callIDs.formUnion(candidateIDs)
      }
    }
    if !callIDs.isEmpty {
      for (offset, message) in messages.enumerated() {
        let candidateIDs = Set(message.toolResults.map(\.callID))
        if !candidateIDs.isDisjoint(with: callIDs) { indexes.insert(offset) }
      }
    }
    return indexes
  }

  private func danglingToolTransactionStart(through index: Int) -> Int? {
    var pending: (start: Int, callIDs: Set<String>)?
    for offset in 0...index {
      let message = messages[offset]
      let calls = Set(message.toolCalls.map(\.id))
      if !calls.isEmpty { pending = (offset, calls) }
      guard var current = pending else { continue }
      current.callIDs.subtract(message.toolResults.map(\.callID))
      pending = current.callIDs.isEmpty ? nil : current
    }
    return pending?.start
  }
}

public enum AgentTranscriptError: LocalizedError, Equatable, Sendable {
  case indexOutOfRange(index: Int, count: Int)
  case messageNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .indexOutOfRange(let index, let count):
      "Message index \(index) is out of range for a transcript containing \(count) messages."
    case .messageNotFound(let id):
      "Message '\(id)' was not found in the transcript."
    }
  }
}

extension AgentMessage {
  fileprivate mutating func replaceEditableText(with text: String) {
    if role == .tool,
      let index = content.firstIndex(where: { part in
        if case .toolResult = part { return true }
        return false
      }),
      case .toolResult(var result) = content[index]
    {
      result.content = result.content.replacingTextParts(with: text)
      content[index] = .toolResult(result)
      return
    }
    content = content.replacingTextParts(with: text)
  }
}

extension Array where Element == ContentPart {
  fileprivate func replacingTextParts(with text: String) -> [ContentPart] {
    var replaced = false
    var result: [ContentPart] = []
    for part in self {
      if case .text = part {
        if !replaced {
          result.append(.text(text))
          replaced = true
        }
      } else {
        result.append(part)
      }
    }
    if !replaced { result.insert(.text(text), at: 0) }
    return result
  }
}
