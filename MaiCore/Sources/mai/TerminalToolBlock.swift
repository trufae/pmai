import Foundation
import MaiCore

/// Complete tool data is retained independently of its current preview size.
struct TerminalToolBlock {
  var call: ToolCall?
  var result: ToolResult?
  var prefix: String
  var timing = ToolRunTiming()

  var hasAppliedDiff: Bool {
    guard let result, !result.isError,
      case .object(let metadata) = result.structuredContent,
      metadata["changed"] == .bool(true)
    else { return false }
    return result.text.contains("\n--- ") && result.text.contains("\n+++ ")
      && result.text.contains("\n@@ ")
  }

  func render(display: ToolResultDisplay, colors: Bool) -> String {
    func styled(_ text: String, color: TerminalThemeStyle, diff: Bool = false) -> String {
      TerminalThemeStyle.lineRoles(text, color: color, diff: diff).map { line in
        let markers =
          colors ? [line.foreground, line.background].compactMap { $0?.marker }.joined() : ""
        return prefix + markers + line.text + (colors ? "\u{1B}[0m" : "")
      }.joined(separator: "\n")
    }
    if display == .lines(0) {
      guard let result else { return "" }
      let label =
        call.map { String(ToolCallPreview.render($0).dropFirst(2)) }
        ?? (result.isError ? "error" : "done")
      return styled(
        "\(result.isError ? "✘" : "✔") \(label)",
        color: result.isError ? .errorForeground : .toolCallForeground)
    }
    var output: [String] = []
    if let call { output.append(styled(ToolCallPreview.render(call), color: .toolCallForeground)) }
    if let result {
      output.append(
        styled(
          ToolResultPreview.render(result, display: display),
          color: result.isError ? .errorForeground : .toolResultForeground, diff: true))
    }
    return output.joined(separator: "\n")
  }
}
