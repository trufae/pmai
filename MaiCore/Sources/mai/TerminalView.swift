import Foundation
import MaiCore
import MaiMarkdown

/// A view either follows the conversation at the prompt or watches a fixed agent.
enum TerminalViewSource: Equatable {
  case current
  case conversation(String)
  case conversations
  case thinking
  case pins
  case log
  case todo
  case iconlog
  case tools(String?)
  case diffs

  var selection: TerminalOutputSelection {
    switch self {
    case .thinking: .thinking
    case .tools(let name): .tools(name)
    case .iconlog: .iconlog
    case .diffs: .diffs
    default: .all
    }
  }
}

enum TerminalOutputSelection: Equatable {
  case all, thinking
  case iconlog
  case tools(String?)
  case diffs
}

struct TerminalMouseEvent {
  enum Action { case press, drag, release }
  var action: Action
  var column: Int
  var row: Int
}

/// Input focus is separate from agent focus: inspecting a view never redirects messages.
struct TerminalView {
  var source: TerminalViewSource
  var title: String
  var focused = false
  var preferredHeight: Int?
  var preferredWidth: Int?
  var vertical = false
  var fullscreen = false
  var markdown: MarkdownTerminalRenderer?
  var buffer = TerminalOutputBuffer()
  var messages: [AgentMessage]?
  var todoText: String?

  /// These sources use model messages, rather than rendered terminal output.
  var needsMessages: Bool { source == .pins || source == .log }

  mutating func updateTodo(_ text: String) {
    guard source == .todo, todoText != text else { return }
    todoText = text
    var output = TerminalOutputBuffer()
    output.append(text)
    buffer.updateView(from: output, selection: .all)
  }

  mutating func updateMessages(_ messages: [AgentMessage]) {
    guard needsMessages, self.messages != messages else { return }
    self.messages = messages
    let text: String
    if source == .pins {
      let pinned = messages.enumerated().filter { $0.element.isPinned }
      text =
        pinned.isEmpty
        ? "No pinned messages. Use /chat pin INDEX or MESSAGE_ID."
        : pinned.map { index, message in
          let body = TranscriptCopy.render(message)
          return
            "[\(index + 1)] 📌 \(message.role.rawValue):\n\(body.isEmpty ? "[empty message]" : body)"
        }.joined(separator: "\n\n")
    } else {
      text =
        messages.isEmpty
        ? "No conversation messages yet."
        : messages.map { message in
          let line = TranscriptCopy.render(message).components(separatedBy: .newlines).first ?? ""
          return "\(message.role.rawValue): \(line.isEmpty ? "[empty message]" : line)"
        }.joined(separator: "\n")
    }
    var output = TerminalOutputBuffer()
    output.configureMarkdown(markdown)
    if markdown != nil {
      let block = output.appendReply(text)
      output.finishReply(block)
    } else {
      output.append(text)
    }
    buffer.updateView(from: output, selection: .all)
  }

  mutating func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    markdown = renderer
    buffer.configureMarkdown(renderer)
  }

  /// Leave a separator and at least one row for the main conversation.
  static func height(availableRows: Int, preferredHeight: Int? = nil) -> Int {
    guard availableRows >= 3 else { return 0 }
    return max(1, min(availableRows - 2, preferredHeight ?? (availableRows - 1) / 2))
  }
}
