import Foundation

/// Selects transcript messages for copying into a clipboard or a file and
/// renders them as plain text. Instructions (system and developer messages) are never copied.
public enum TranscriptCopy {
  /// A compact paragraph for transcript navigation, without flattening the
  /// entire message or cutting a paragraph off at an arbitrary character count.
  public static func firstParagraph(_ text: String) -> String {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    return lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
      .prefix(while: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
      .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
  }

  public enum Selection: Equatable, Sendable {
    /// The most recent assistant reply, as pasteable text without reasoning.
    case lastAssistantReply
    /// The last `count` conversation messages, oldest first.
    case lastMessages(Int)
  }

  public struct Result: Equatable, Sendable {
    public var text: String
    public var messages: [AgentMessage]

    public init(text: String, messages: [AgentMessage]) {
      self.text = text
      self.messages = messages
    }
  }

  /// A parsed `/copy` command: which messages to copy and, when a path was
  /// given, the file to write them to instead of the clipboard.
  public struct Command: Equatable, Sendable {
    public var selection: Selection
    public var path: String?

    public init(selection: Selection, path: String? = nil) {
      self.selection = selection
      self.path = path
    }
  }

  /// Parses the argument of a `/copy` command: an optional message count, then
  /// an optional file path. Empty copies the last assistant reply, `3` the last
  /// three messages, `notes.txt` the last reply into that file, and
  /// `3 notes.txt` the last three messages into it. A first word that reads as
  /// an integer is always a count, so `0` is an error rather than a file name.
  public static func command(parsing argument: String) throws -> Command {
    let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Command(selection: .lastAssistantReply) }
    let fields = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
    guard let count = Int(fields[0]) else {
      return Command(selection: .lastAssistantReply, path: trimmed)
    }
    guard count > 0 else { throw TranscriptCopyError.invalidCount(fields[0]) }
    let path = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return Command(selection: .lastMessages(count), path: path.isEmpty ? nil : path)
  }

  public static func text(
    for selection: Selection,
    in messages: [AgentMessage]
  ) throws -> Result {
    let conversation = messages.filter { $0.role != .system && $0.role != .developer }
    switch selection {
    case .lastAssistantReply:
      guard
        let reply = conversation.last(where: { message in
          message.role == .assistant && !visibleText(of: message).isEmpty
        })
      else { throw TranscriptCopyError.noAssistantReply }
      return Result(text: visibleText(of: reply), messages: [reply])
    case .lastMessages(let count):
      guard count > 0 else { throw TranscriptCopyError.invalidCount(String(count)) }
      guard !conversation.isEmpty else { throw TranscriptCopyError.noMessages }
      let selected = Array(conversation.suffix(count))
      if selected.count == 1 {
        return Result(text: render(selected[0]), messages: selected)
      }
      let blocks = selected.map { message in
        "\(label(for: message.role)): \(render(message))"
      }
      return Result(text: blocks.joined(separator: "\n\n"), messages: selected)
    }
  }

  /// The pasteable text of one message: visible prose without reasoning, with
  /// attachments, tool calls, and tool results summarized on their own lines.
  public static func render(_ message: AgentMessage) -> String {
    var lines: [String] = []
    let prose = visibleText(of: message)
    if !prose.isEmpty { lines.append(prose) }
    for part in message.content {
      switch part {
      case .text, .reasoning:
        continue
      case .file(let file) where file.text != nil:
        continue
      case .image(let image):
        lines.append("[image \(image.name ?? image.mimeType)]")
      case .file(let file):
        lines.append("[file \(file.name)]")
      case .audio(let audio):
        lines.append("[audio \(audio.name ?? audio.mimeType)]")
      case .resource(let resource) where resource.text == nil:
        lines.append("[resource \(resource.name ?? resource.uri)]")
      case .resource:
        continue
      case .toolCall(let call):
        lines.append("[tool call \(call.name) \(call.arguments.compactJSONString)]")
      case .toolResult(let result):
        let status = result.isError ? " error" : ""
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(text.isEmpty ? "[tool result\(status)]" : "[tool result\(status)] \(text)")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func visibleText(of message: AgentMessage) -> String {
    MessageContentFilter.textWithoutReasoning(from: message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func label(for role: AgentRole) -> String {
    switch role {
    case .user: "User"
    case .assistant: "Assistant"
    case .tool: "Tool"
    case .system: "System"
    case .developer: "Developer"
    }
  }
}

public enum TranscriptCopyError: LocalizedError, Equatable, Sendable {
  case invalidCount(String)
  case noAssistantReply
  case noMessages

  public var errorDescription: String? {
    switch self {
    case .invalidCount(let value):
      "'\(value)' is not a positive message count."
    case .noAssistantReply:
      "The conversation has no assistant reply to copy."
    case .noMessages:
      "The conversation has no messages to copy."
    }
  }
}
