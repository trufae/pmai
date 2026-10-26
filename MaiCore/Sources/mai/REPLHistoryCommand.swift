import Foundation
import MaiCore

/// Runs while the input reader is parked, so edits also affect recall and Ctrl+R.
enum REPLHistoryCommand {
  static let help = """
    /history [list] [N]   List saved inputs, or only the latest N, oldest first
    /history search TEXT List inputs containing TEXT (case insensitive)
    /history del N       Delete the input with the displayed number
    /history clear       Clear saved inputs and live Up/Down and Ctrl+R history
    /history path        Print the input history file path
    /history help        Show this help

    Negative entry numbers count from the end: /history del -1 deletes the latest.
    Input history is shared across projects and keeps up to 500 entries.
    Consecutive duplicates, modal replies, /remote pair, and /history commands
    are not added. Other slash commands are included. Multiline inputs keep
    their lines. Deleting or clearing input history leaves chats unchanged.
    --history PATH or PMAI_HISTORY overrides the default history file.
    """

  static func run(_ argument: String, editor: TerminalLineEditor) throws -> String {
    let parts = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    let action = parts.first.map { $0.lowercased() } ?? "list"
    let value = parts.count > 1
      ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    var entries = Array(editor.inputHistory.enumerated())
    switch action {
    case "help" where value.isEmpty:
      return help
    case "path" where value.isEmpty:
      return editor.inputHistoryURL?.path ?? "Input history is not saved to a file."
    case "clear" where value.isEmpty:
      try editor.clearInputHistory()
      return "Input history cleared."
    case "del":
      guard let index = ListIndex.resolve(value, count: entries.count) else {
        return "Usage: /history del N (choose a number from /history)"
      }
      try editor.removeInputHistory(at: index)
      return "Deleted input history entry \(index + 1)."
    case "search":
      guard !value.isEmpty else { return "Usage: /history search TEXT" }
      entries = entries.filter { $0.element.localizedCaseInsensitiveContains(value) }
      if entries.isEmpty { return "No matching input history." }
    default:
      let count = action == "list" ? value : argument
      if !count.isEmpty {
        guard let number = Int(count), number > 0 else {
          return "Usage: /history [list] [N], search TEXT, del N, clear, path, or help"
        }
        entries = Array(entries.suffix(number))
      }
    }
    guard !entries.isEmpty else { return "No input history." }
    return entries.map { entry in
      let text = entry.element.replacingOccurrences(of: "\n", with: "\n     ")
      return "\(entry.offset + 1). \(text)"
    }.joined(separator: "\n")
  }
}
