import Foundation

/// A round-trip editing format, distinct from the presentation-only Markdown
/// export. Non-text content stays in the source transcript, keyed by message ID.
public enum AgentConversationMarkdown {
  private static let marker = "<!-- pmai-message "
  private static let preamble = """
    # pmai conversation v1

    Edit text inside the Markdown fences. Keep message IDs, roles and order.
    Set context to active or excluded; removing a block excludes it from context.
    Originals, attachments and tool records are retained. To append a message,
    copy a block with id new and role user or assistant. Cancel by leaving unchanged.

    """

  private struct Header: Codable {
    var id: String
    var role: AgentRole
    var context: String
  }

  public static func text(for history: [AgentMessage]) -> String {
    return preamble + history.map { original in
      let message = version(of: original)
      let header = JSONValue.object([
        "id": .string(message.id), "role": .string(message.role.rawValue),
        "context": .string(original.context?.excluded == true ? "excluded" : "active")])
      let text = editableText(message)
      let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
      let fence = String(repeating: "`", count: max(3, longest + 1))
      return marker + header.compactJSONString + " -->\n"
        + fence + "markdown\n" + text + "\n" + fence + "\n"
    }.joined(separator: "\n")
  }

  public static func applying(_ text: String, to history: [AgentMessage]) throws -> [AgentMessage] {
    guard text.hasPrefix(preamble) else { throw EditError.invalid("Keep the conversation format instructions unchanged.") }
    let lines = String(text.dropFirst(preamble.count)).components(separatedBy: "\n")
    let originals = Dictionary(history.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    guard originals.count == history.count else { throw EditError.invalid("The conversation has duplicate message IDs.") }
    var updated = history
    var working: [AgentMessage] = []
    var seen: Set<String> = []
    var lastIndex = -1
    var appendedNew = false
    var offset = 0
    while offset < lines.count {
      let line = lines[offset]
      if line.trimmingCharacters(in: .whitespaces).isEmpty { offset += 1; continue }
      guard line.hasPrefix(marker), line.hasSuffix(" -->") else {
        throw EditError.invalid("Expected a message header at line \(offset + 1).")
      }
      let json = String(line.dropFirst(marker.count).dropLast(4))
      let header = try JSONDecoder().decode(Header.self, from: Data(json.utf8))
      guard ["active", "excluded"].contains(header.context) else {
        throw EditError.invalid("Context must be active or excluded.")
      }
      offset += 1
      guard offset < lines.count else { throw EditError.invalid("Missing message fence.") }
      let opening = lines[offset]
      let fence = String(opening.prefix { $0 == "`" })
      guard fence.count >= 3, opening == fence + "markdown" else {
        throw EditError.invalid("Expected a Markdown fence after the message header.")
      }
      offset += 1
      let start = offset
      while offset < lines.count && lines[offset] != fence { offset += 1 }
      guard offset < lines.count else { throw EditError.invalid("Unclosed message fence.") }
      let body = lines[start..<offset].joined(separator: "\n")
      offset += 1

      var message: AgentMessage
      if header.id == "new" {
        appendedNew = true
        guard header.role == .user || header.role == .assistant else {
          throw EditError.invalid("New messages must have user or assistant role.")
        }
        message = AgentMessage(role: header.role, content: body)
        updated.append(message)
      } else {
        guard !appendedNew, let index = originals[header.id], seen.insert(header.id).inserted,
          index > lastIndex else { throw EditError.invalid("Unknown, duplicate or reordered message ID: \(header.id).") }
        lastIndex = index
        message = version(of: history[index])
        guard header.role == message.role else { throw EditError.invalid("Keep existing message roles unchanged.") }
        if body != editableText(message) {
          var transcript = AgentTranscript(messages: [message])
          try transcript.editMessage(at: 0, text: body)
          message = transcript[0]
          var context = updated[index].context ?? AgentMessageContext()
          context.replacement = AgentMessageContext.Revision(message)
          updated[index].context = context
        }
      }
      if header.context == "active" { working.append(message) }
    }
    try validateToolExchanges(working)
    return AgentConversationContext.replacing(updated, with: working)
  }

  private static func version(of original: AgentMessage) -> AgentMessage {
    var included = original
    included.context?.excluded = false
    return AgentConversationContext.messages(from: [included])[0]
  }

  private static func editableText(_ message: AgentMessage) -> String {
    let content = message.role == .tool ? message.toolResults.first?.content ?? message.content : message.content
    return content.compactMap { part in
      if case .text(let text) = part { return text }
      return nil
    }.joined(separator: "\n")
  }

  private static func validateToolExchanges(_ messages: [AgentMessage]) throws {
    var pending: Set<String> = []
    var calls: Set<String> = []
    for message in messages {
      if !pending.isEmpty && message.role != .tool {
        throw EditError.invalid("Keep tool calls and their results together in context.")
      }
      for call in message.toolCalls {
        guard calls.insert(call.id).inserted else { throw EditError.invalid("Duplicate tool call: \(call.id).") }
        pending.insert(call.id)
      }
      for result in message.toolResults {
        guard pending.remove(result.callID) != nil else {
          throw EditError.invalid("Tool result has no preceding call: \(result.callID).")
        }
      }
    }
    guard pending.isEmpty else { throw EditError.invalid("A tool call is missing its result.") }
  }

  private enum EditError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
  }
}
