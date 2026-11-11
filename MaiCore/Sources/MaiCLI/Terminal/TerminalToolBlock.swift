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
      var text = text.components(separatedBy: "\n").map { line in
        truncate ? Self.truncatedCall(line, width: width, prefix: prefix) : line
      }.joined(separator: "\n")
      if colors, background == .toolCallBackground, display != .icons, let call {
        text = Self.highlightedCall(text, call: call, display: calls, color: color)
      }
      return TerminalThemeStyle.lineRoles(text, color: color, background: background, diff: diff).map { line in
        let markers =
          colors ? [line.background,
            background == .toolCallBackground ? .toolCallBold : nil, line.foreground]
            .compactMap { $0?.marker }.joined() : ""
        let visiblePrefix = truncate && TerminalLineEditor.displayWidth(of: prefix) >= width
          ? Self.truncatedCall(prefix + " ", width: width) : prefix
        return visiblePrefix + markers + line.text + (colors ? "\u{1B}[0m" : "")
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

  /// Apply semantic colors after clipping, preserving the status glyph and ellipsis.
  /// Values may contain spaces, equals signs or JSON, so do not tokenize the preview.
  static func highlightedCall(_ text: String, call: ToolCall, display: ToolCallDisplay,
    color: TerminalThemeStyle = .toolCallForeground,
    style: (TerminalThemeStyle) -> String = { $0.marker }) -> String
  {
    var remaining = text[...]
    return ToolCallPreview.parts(call, display: display).map { part in
      let shown = remaining.prefix(part.text.count)
      remaining = remaining.dropFirst(shown.count)
      guard !shown.isEmpty else { return "" }
      let role: TerminalThemeStyle = switch part.role {
      case .name: color
      case .parameter: .infoForeground
      case .value: .foreground
      }
      return shown.components(separatedBy: "\n").map { style(role) + $0 }.joined(separator: "\n")
    }.joined()
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

