import Foundation

/// A view either follows the conversation at the prompt or watches a fixed agent.
enum TerminalViewSource: Equatable {
  case current
  case conversation(String)
  case conversations
  case thinking
  case tools(String?)
  case diffs

  var selection: TerminalOutputSelection {
    switch self {
    case .thinking: .thinking
    case .tools(let name): .tools(name)
    case .diffs: .diffs
    default: .all
    }
  }
}

enum TerminalOutputSelection: Equatable {
  case all, thinking
  case tools(String?)
  case diffs
}

/// Input focus is separate from agent focus: inspecting a view never redirects messages.
struct TerminalView {
  var source: TerminalViewSource
  var title: String
  var focused = false
  var buffer = TerminalOutputBuffer()

  /// Leave a separator and at least one row for the main conversation.
  static func height(availableRows: Int) -> Int {
    availableRows >= 3 ? max(1, (availableRows - 1) / 2) : 0
  }
}
