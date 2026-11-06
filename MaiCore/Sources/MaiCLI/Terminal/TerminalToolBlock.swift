import Foundation
import MaiCore

/// Complete tool data is retained independently of its current preview size.
struct TerminalToolBlock {
  var call: ToolCall?
  var result: ToolResult?
  var prefix: String
  var timing = ToolRunTiming()

  func render(
    display: ToolResultDisplay, calls: ToolCallDisplay = .truncate, colors: Bool, width: Int = .max
  ) -> String {
    func styled(_ text: String, color: TerminalThemeStyle,
      background: TerminalThemeStyle = .toolCallBackground, diff: Bool = false,
      truncate: Bool = false) -> String {
      TerminalThemeStyle.lineRoles(text, color: color, background: background, diff: diff).map { line in
        let markers =
          colors ? [line.background,
            background == .toolCallBackground ? .toolCallBold : nil, line.foreground]
            .compactMap { $0?.marker }.joined() : ""
        let row = truncate ? Self.truncatedCall(prefix + line.text, width: width) : prefix + line.text
        let styledRow = row.hasPrefix(prefix)
          ? prefix + markers + row.dropFirst(prefix.count) : markers + row
        return styledRow + (colors ? "\u{1B}[0m" : "")
      }.joined(separator: "\n")
    }
    if display == .icons {
      return styled(
        ToolIcon.emoji(for: call?.name ?? ""),
        color: result?.isError == true ? .errorForeground : .toolCallForeground)
    }
    if display == .lines(0) {
      guard let result else { return "" }
      let label =
        call.map { String(ToolCallPreview.render($0, display: calls).dropFirst(2)) }
        ?? (result.isError ? "error" : "done")
      return styled(
        "\(result.isError ? "✘" : "✔") \(label)",
        color: result.isError ? .errorForeground : .toolCallForeground, truncate: calls == .truncate)
    }
    var output: [String] = []
    if let call {
      output.append(styled(ToolCallPreview.render(call, display: calls), color: .toolCallForeground,
        truncate: calls == .truncate))
    }
    if let result {
      output.append(
        styled(
          ToolResultPreview.render(result, display: display),
          color: result.isError ? .errorForeground : .toolResultForeground,
          background: .toolResultBackground, diff: true))
    }
    return output.joined(separator: "\n")
  }

  /// Clip before styling, reserving cells for the child prefix and ellipsis.
  static func truncatedCall(_ text: String, width: Int, prefix: String = "") -> String {
    let available = max(0, width - TerminalLineEditor.displayWidth(of: prefix))
    guard available > 0 else { return "" }
    guard TerminalLineEditor.displayWidth(of: text) > available else { return text }
    var used = 0
    var visible = ""
    for character in text {
      let cells = TerminalLineEditor.displayWidth(of: String(character))
      guard used + cells < available else { break }
      visible.append(character)
      used += cells
    }
    return visible + "…"
  }
}

