import Foundation

// Portable selection policy; FoundationModels conversion stays in the Apple provider.
public struct AppleConversationInput: Sendable {
  public private(set) var instructions: String
  public private(set) var history: [[AgentMessage]] = []
  public let prompt: String
  private let protectedHistoryTurns: Int

  public init(
    instructions: String, messages: [AgentMessage], context: String = "", messageLimit: Int? = nil
  ) {
    var instructions = [instructions]
    var turns: [[AgentMessage]] = []
    var startsTurn = true
    for message in messages {
      let isEmpty = message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      switch message.role {
      case .system, .developer:
        if !isEmpty { instructions.append(message.text) }
      case .user:
        guard !isEmpty else { continue }
        if startsTurn {
          turns.append([message])
        } else {
          turns[turns.count - 1].append(message)
        }
        startsTurn = false
      case .assistant, .tool:
        startsTurn = true
        guard !isEmpty, !turns.isEmpty else { continue }
        turns[turns.count - 1].append(message)
      }
    }
    self.instructions = instructions.filter { !$0.isEmpty }.joined(separator: "\n\n")
    var current: [AgentMessage] = []
    if let last = turns.last, !last.contains(where: { $0.role == .assistant }) {
      current = turns.removeLast()
    }
    protectedHistoryTurns = current.isEmpty && !turns.isEmpty ? 1 : 0
    var promptParts = context.isEmpty ? [] : ["Context:\n\(context)"]
    promptParts += current.map(Self.promptText)
    if current.isEmpty, !turns.isEmpty { promptParts.append("Continue from the last response.") }
    prompt = promptParts.joined(separator: "\n\n")
    history = turns
    if let messageLimit {
      var count = history.reduce(Set(current.map(\.id)).count) { $0 + Set($1.map(\.id)).count }
      while count > max(0, messageLimit), history.count > protectedHistoryTurns,
        let first = history.first
      {
        count -= Set(first.map(\.id)).count
        history.removeFirst()
      }
    }
  }

  public var messages: [AgentMessage] {
    [.system(instructions)]
      + history.flatMap { $0 }.map { message in
        message.role == .tool ? .user(Self.promptText(message)) : message
      } + (prompt.isEmpty ? [] : [.user(prompt)])
  }

  public var characterCount: Int {
    instructions.count + prompt.count
      + history.flatMap { $0 }.reduce(0) { $0 + Self.promptText($1).count }
  }

  @discardableResult
  public mutating func trimToFit(
    contextSize: Int, reservingTokens: Int,
    tokenCount: (AppleConversationInput) async throws -> Int
  ) async throws -> Int {
    while true {
      let available = max(0, contextSize - (try await tokenCount(self)))
      if available >= reservingTokens || !trimForRetry() { return available }
    }
  }

  @discardableResult
  public mutating func trimForRetry(lastAttempt: Bool = false) -> Bool {
    guard history.count > protectedHistoryTurns else { return false }
    let count = lastAttempt ? protectedHistoryTurns : max(protectedHistoryTurns, history.count / 2)
    history = Array(history.suffix(count))
    return true
  }

  private static func promptText(_ message: AgentMessage) -> String {
    message.role == .tool ? "Host tool results:\n\(message.text)" : message.text
  }
}
