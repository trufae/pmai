import Foundation
import MaiCore

/// Private SGR annotations carry a theme role through composed terminal text.
/// The buffer resolves them when painting; other terminal output removes them.
enum TerminalThemeStyle: Int, CaseIterable {
  case foreground = 9000
  case background, promptForeground, promptBackground, bold
  case toolResultForeground, toolCallForeground, errorForeground, warningForeground
  case successForeground, infoForeground, thinkingForeground
  case diffAddedForeground, diffAddedBackground, diffRemovedForeground, diffRemovedBackground
  case diffHeaderForeground

  var marker: String { "\u{1B}[?\(rawValue)m" }

  func value(in ui: ConfiguredTerminalUI) -> String {
    switch self {
    case .foreground: ui.foreground
    case .background: ui.background
    case .promptForeground: ui.promptForeground
    case .promptBackground: ui.promptBackground
    case .bold: ""
    case .toolResultForeground: ui.toolResultForeground
    case .toolCallForeground: ui.toolCallForeground
    case .errorForeground: ui.errorForeground
    case .warningForeground: ui.warningForeground
    case .successForeground: ui.successForeground
    case .infoForeground: ui.infoForeground
    case .thinkingForeground: ui.thinkingForeground
    case .diffAddedForeground: ui.diffAddedForeground
    case .diffAddedBackground: ui.diffAddedBackground
    case .diffRemovedForeground: ui.diffRemovedForeground
    case .diffRemovedBackground: ui.diffRemovedBackground
    case .diffHeaderForeground: ui.diffHeaderForeground
    }
  }

  private func code(in ui: ConfiguredTerminalUI) -> String {
    switch self {
    case .bold: return ui.bold ? "1" : "22"
    case .background, .promptBackground, .diffAddedBackground, .diffRemovedBackground:
      return TerminalLineEditor.backgroundColorCode(value(in: ui)) ?? "49"
    default:
      return TerminalLineEditor.foregroundColorCode(value(in: ui)) ?? "39"
    }
  }

  static func resolve(_ text: String, ui: ConfiguredTerminalUI? = nil) -> String {
    guard text.contains("\u{1B}[?") else { return text }
    return allCases.reduce(text) { result, role in
      result.replacingOccurrences(
        of: role.marker, with: ui.map { "\u{1B}[\(role.code(in: $0))m" } ?? "")
    }
  }

  static func base(_ ui: ConfiguredTerminalUI?) -> String {
    guard let ui else { return "" }
    let codes = [
      TerminalLineEditor.foregroundColorCode(ui.foreground),
      TerminalLineEditor.backgroundColorCode(ui.background),
    ].compactMap { $0 }
    return codes.isEmpty ? "" : "\u{1B}[\(codes.joined(separator: ";"))m"
  }

  /// Tool previews add a two-character prefix before the original diff marker.
  static func lineRoles(_ value: String, color: Self?, diff: Bool)
    -> [(text: String, foreground: Self?, background: Self?)]
  {
    let lines = value.components(separatedBy: "\n")
    let content = diff ? lines.map { String($0.dropFirst(2)) } : lines
    let unified =
      diff
      && content.indices.dropLast().contains { index in
        content[index].hasPrefix("--- ") && content[index + 1].hasPrefix("+++ ")
      }
    return lines.indices.map { index in
      let marker = content[index]
      if unified {
        if marker.hasPrefix("--- ") || marker.hasPrefix("+++ ") || marker.hasPrefix("@@ ")
          || marker.hasPrefix("diff --git ") || marker.hasPrefix("index ")
        {
          return (lines[index], .diffHeaderForeground, nil)
        }
        if marker.hasPrefix("-") {
          return (lines[index], .diffRemovedForeground, .diffRemovedBackground)
        }
        if marker.hasPrefix("+") {
          return (lines[index], .diffAddedForeground, .diffAddedBackground)
        }
      }
      return (lines[index], color, nil)
    }
  }
}
