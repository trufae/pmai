import Foundation
import MaiCore

/// Themes are batches of the appearance settings accepted by `/theme color`.
enum TerminalTheme {
  static let builtins: [String: ConfiguredTerminalUI] = [
    "default": .init(),
    "ansi": .init(
      backgroundLine: "", foreground: "white", background: "",
      promptForeground: "yellow", promptBackground: "",
      toolResultForeground: "yellow", toolCallForeground: "green",
      errorForeground: "red", warningForeground: "yellow", successForeground: "green",
      infoForeground: "white", thinkingForeground: "cyan",
      diffAddedForeground: "green", diffAddedBackground: "",
      diffRemovedForeground: "red", diffRemovedBackground: "",
      diffHeaderForeground: "cyan", selectionForeground: "",
      selectionBackground: ""),
    "mono": .init(
      backgroundLine: "black", foreground: "white", background: "",
      promptForeground: "white", promptBackground: "",
      toolResultForeground: "white", toolCallForeground: "white",
      errorForeground: "white", warningForeground: "white", successForeground: "white",
      infoForeground: "white", thinkingForeground: "white",
      diffAddedForeground: "white", diffAddedBackground: "",
      diffRemovedForeground: "white", diffRemovedBackground: "",
      diffHeaderForeground: "white", selectionForeground: "black",
      selectionBackground: "white", bold: true),
    "plum": .init(
      backgroundLine: "#30213f", foreground: "#e6dcf5", background: "#1c1428",
      promptForeground: "#bd9aff", promptBackground: "#30213f",
      toolResultForeground: "#b6a6cf", toolCallForeground: "#c7b4ff",
      errorForeground: "#ff969f", warningForeground: "#e8c67e", successForeground: "#a9d5ae",
      infoForeground: "#c4a0e8", thinkingForeground: "#a193b2",
      diffAddedForeground: "#c8ead3", diffAddedBackground: "#263a32",
      diffRemovedForeground: "#f2c0cd", diffRemovedBackground: "#482939",
      diffHeaderForeground: "#c7b4ff", selectionForeground: "#1c1428",
      selectionBackground: "#bd9aff"),
    "sand": .init(
      backgroundLine: "#e8d9b5", foreground: "#463a28", background: "#f6eedb",
      promptForeground: "#775b12", promptBackground: "#e8d9b5",
      toolResultForeground: "#6c5940", toolCallForeground: "#53652b",
      errorForeground: "#a13e35", warningForeground: "#80601b", successForeground: "#476333",
      infoForeground: "#6f557b", thinkingForeground: "#82745c",
      diffAddedForeground: "#34502b", diffAddedBackground: "#dfe8c8",
      diffRemovedForeground: "#86382e", diffRemovedBackground: "#f1d8c7",
      diffHeaderForeground: "#775b12", selectionForeground: "#f6eedb",
      selectionBackground: "#775b12"),
    "slime": .init(
      backgroundLine: "rgb:021", foreground: "rgb:afa", promptForeground: "rgb:8f8",
      toolResultForeground: "rgb:8c8", toolCallForeground: "rgb:8f8",
      errorForeground: "rgb:f88", warningForeground: "rgb:dc8", successForeground: "rgb:8fb",
      infoForeground: "rgb:8cc", thinkingForeground: "rgb:798",
      diffAddedForeground: "rgb:bfd", diffAddedBackground: "rgb:132",
      diffRemovedForeground: "rgb:fbb", diffRemovedBackground: "rgb:321",
      diffHeaderForeground: "rgb:8cc", selectionForeground: "rgb:021",
      selectionBackground: "rgb:8f8", bold: true),
    "light": .init(
      backgroundLine: "rgb:eee", foreground: "rgb:222", promptForeground: "rgb:046",
      toolResultForeground: "rgb:850", toolCallForeground: "rgb:163",
      errorForeground: "rgb:a22", warningForeground: "rgb:850", successForeground: "rgb:067",
      infoForeground: "rgb:726", thinkingForeground: "rgb:666",
      diffAddedForeground: "rgb:153", diffAddedBackground: "rgb:dfd",
      diffRemovedForeground: "rgb:811", diffRemovedBackground: "rgb:fdd",
      diffHeaderForeground: "rgb:046", selectionForeground: "rgb:fff",
      selectionBackground: "rgb:046"),
    "ember": .init(
      backgroundLine: "rgb:310", foreground: "rgb:fdb", promptForeground: "rgb:f95",
      toolResultForeground: "rgb:c96", toolCallForeground: "rgb:fb7",
      errorForeground: "rgb:f77", warningForeground: "rgb:fc7", successForeground: "rgb:bd9",
      infoForeground: "rgb:eb9", thinkingForeground: "rgb:a87",
      diffAddedForeground: "rgb:dfb", diffAddedBackground: "rgb:231",
      diffRemovedForeground: "rgb:fcb", diffRemovedBackground: "rgb:421",
      diffHeaderForeground: "rgb:fb7", selectionForeground: "rgb:310",
      selectionBackground: "rgb:f95"),
    "pink": .init(
      backgroundLine: "rgb:302", foreground: "rgb:fdf", promptForeground: "rgb:f8c",
      toolResultForeground: "rgb:d9c", toolCallForeground: "rgb:fad",
      errorForeground: "rgb:f77", warningForeground: "rgb:fc9", successForeground: "rgb:9dc",
      infoForeground: "rgb:daf", thinkingForeground: "rgb:a8a",
      diffAddedForeground: "rgb:cfe", diffAddedBackground: "rgb:143",
      diffRemovedForeground: "rgb:fbd", diffRemovedBackground: "rgb:413",
      diffHeaderForeground: "rgb:f8c", selectionForeground: "rgb:302",
      selectionBackground: "rgb:f8c"),
    "night": .init(
      backgroundLine: "rgb:013", foreground: "rgb:def", promptForeground: "rgb:7cf",
      toolResultForeground: "rgb:9bd", toolCallForeground: "rgb:9df",
      errorForeground: "rgb:f88", warningForeground: "rgb:ed9", successForeground: "rgb:fff",
      infoForeground: "rgb:aaf", thinkingForeground: "rgb:89a",
      diffAddedForeground: "rgb:bfe", diffAddedBackground: "rgb:133",
      diffRemovedForeground: "rgb:fbd", diffRemovedBackground: "rgb:324",
      diffHeaderForeground: "rgb:7cf", selectionForeground: "rgb:013",
      selectionBackground: "rgb:5ac"),
    // Inspired by Visual Studio Code's Dark+ and Light+ palettes.
    "codark": .init(
      backgroundLine: "#252526", foreground: "#d4d4d4", background: "",
      promptForeground: "#569cd6", promptBackground: "#252526",
      toolResultForeground: "#ce9178", toolCallForeground: "#9cdcfe",
      errorForeground: "#f44747", warningForeground: "#dcdcaa", successForeground: "#4ec9b0",
      infoForeground: "#569cd6", thinkingForeground: "#858585",
      diffAddedForeground: "#b5cea8", diffAddedBackground: "#203820",
      diffRemovedForeground: "#f48771", diffRemovedBackground: "#4b2525",
      diffHeaderForeground: "#9cdcfe", selectionForeground: "#ffffff",
      selectionBackground: "#264f78"),
    "colit": .init(
      backgroundLine: "#f3f3f3", foreground: "#333333", background: "#ffffff",
      promptForeground: "#005fb8", promptBackground: "#f3f3f3",
      toolResultForeground: "#a31515", toolCallForeground: "#001080",
      errorForeground: "#a1260d", warningForeground: "#795e26", successForeground: "#008000",
      infoForeground: "#0451a5", thinkingForeground: "#6a737d",
      diffAddedForeground: "#006400", diffAddedBackground: "#e6ffec",
      diffRemovedForeground: "#a31515", diffRemovedBackground: "#ffeef0",
      diffHeaderForeground: "#0451a5", selectionForeground: "#000000",
      selectionBackground: "#add6ff"),
  ]

  static var colors: [(String, WritableKeyPath<ConfiguredTerminalUI, String>)] {
    [
      ("bgline", \.backgroundLine), ("fgcolor", \.foreground),
      ("bgcolor", \.background), ("fgprompt", \.promptForeground),
      ("bgprompt", \.promptBackground), ("fgtoolresult", \.toolResultForeground),
      ("fgtoolcall", \.toolCallForeground), ("fgerror", \.errorForeground),
      ("fgwarning", \.warningForeground), ("fgsuccess", \.successForeground),
      ("fginfo", \.infoForeground), ("fgthinking", \.thinkingForeground),
      ("fgdiffadd", \.diffAddedForeground), ("bgdiffadd", \.diffAddedBackground),
      ("fgdiffdel", \.diffRemovedForeground), ("bgdiffdel", \.diffRemovedBackground),
      ("fgdiffheader", \.diffHeaderForeground),
      ("fgselection", \.selectionForeground), ("bgselection", \.selectionBackground),
    ]
  }

  static var keys: [String] { colors.map(\.0) + ["bold"] }

  static func showcase(_ themes: [(name: String, ui: ConfiguredTerminalUI)], columns: Int,
    colors: Bool) -> String
  {
    let perRow = columns >= 79 && themes.count > 1 ? 2 : 1
    let cardColumns = perRow == 2 ? (columns - 1) / 2 : columns
    let cards = themes.map {
      preview($0.name, ui: $0.ui, columns: cardColumns, colors: colors)
        .components(separatedBy: "\n")
    }
    return stride(from: 0, to: cards.count, by: perRow).map { index in
      if perRow == 2, index + 1 < cards.count {
        return zip(cards[index], cards[index + 1]).map { $0 + "  " + $1 }.joined(separator: "\n")
      }
      return cards[index].joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  /// Use literal colors so buffer recoloring keeps each preview's own palette.
  private static func preview(_ name: String, ui: ConfiguredTerminalUI, columns: Int, colors: Bool)
    -> String
  {
    let width = max(1, min(60, columns - 5))
    func styled(_ text: String, foreground: String, background: String, bold: Bool = false)
      -> String
    {
      guard colors else { return text }
      let codes = [
        "0", TerminalLineEditor.foregroundColorCode(foreground) ?? "39",
        TerminalLineEditor.backgroundColorCode(background) ?? "49", bold ? "1" : "22",
      ]
      return "\u{1B}[\(codes.joined(separator: ";"))m" + text + "\u{1B}[0m"
    }
    func frame(_ text: String) -> String {
      styled(text, foreground: ui.infoForeground, background: ui.background)
    }
    func row(_ text: String, foreground: String, background: String? = nil,
      bold: Bool = false, prompt: Bool = false) -> String
    {
      // Names and sample text are ASCII, so character counts equal cell widths.
      let text = String(text.prefix(width))
      let padded = text + String(repeating: " ", count: width - text.count)
      let content: String
      if prompt {
        let prefix = String(padded.prefix(6))
        content = styled(prefix, foreground: ui.promptForeground, background: ui.promptBackground)
          + styled(String(padded.dropFirst(prefix.count)), foreground: foreground,
            background: background ?? ui.background, bold: bold)
      } else {
        content = styled(padded, foreground: foreground,
          background: background ?? ui.background, bold: bold)
      }
      return frame("| ") + content + frame(" |")
    }
    let border = frame("+" + String(repeating: "-", count: width + 2) + "+")
    return [
      border,
      row(name, foreground: ui.infoForeground, background: ui.backgroundLine, bold: true),
      border,
      row("pmai> List the project files", foreground: ui.foreground, bold: ui.bold, prompt: true),
      row("Thinking... inspecting the project", foreground: ui.thinkingForeground),
      row("-> files_list .", foreground: ui.toolCallForeground),
      row("<- README.md  Sources/  Tests/", foreground: ui.toolResultForeground),
      row("pmai: Project files listed. Ready!", foreground: ui.successForeground),
      border,
    ].joined(separator: "\n")
  }

  static func value(_ key: String, in ui: ConfiguredTerminalUI) -> String? {
    if key == "bold" { return ui.bold ? "on" : "off" }
    guard let (_, path) = colors.first(where: { $0.0 == key }) else { return nil }
    let color = ui[keyPath: path]
    return color.isEmpty ? "none" : color
  }

  struct Invalid: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func set(_ key: String, value: String, in ui: inout ConfiguredTerminalUI) throws {
    if key == "bold" {
      switch value.lowercased() {
      case "1", "true", "yes", "on": ui.bold = true
      case "0", "false", "no", "off": ui.bold = false
      default: throw Invalid(message: "Usage: /theme color bold <on|off>")
      }
    } else if let (_, path) = colors.first(where: { $0.0 == key }) {
      guard let color = TerminalLineEditor.normalizedColor(value) else {
        throw Invalid(
          message: "Unknown color '\(value)'. Use a named ANSI color, rgb:RGB, or none.")
      }
      ui[keyPath: path] = color
    } else {
      throw Invalid(message: "Unknown theme color '\(key)'. Use /theme color to list settings.")
    }
  }

  static func script(_ ui: ConfiguredTerminalUI) -> String {
    (colors.map { key, path in
      "/theme color \(key) \(ui[keyPath: path].isEmpty ? "none" : ui[keyPath: path])"
    } + ["/theme color bold \(ui.bold ? "on" : "off")"]).joined(separator: "\n") + "\n"
  }

  static func validName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".")
      && name.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
      }
  }

  static func file(_ name: String, directory: URL) throws -> URL {
    guard validName(name) else {
      throw Invalid(
        message:
          "Use a theme name containing letters, digits, '.', '_' or '-', without a leading '.'.")
    }
    return directory.appendingPathComponent(name)
  }

  static func names(directory: URL) -> [String] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    let custom = files.filter {
      validName($0.lastPathComponent)
        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.map(\.lastPathComponent)
    return Set(builtins.keys).union(custom).sorted()
  }

  static func load(_ name: String, directory: URL, ui: ConfiguredTerminalUI) throws
    -> ConfiguredTerminalUI
  {
    let url = try file(name, directory: directory)
    let source: String
    if FileManager.default.fileExists(atPath: url.path) {
      source = try String(contentsOf: url, encoding: .utf8)
    } else if let builtin = builtins[name] {
      source = script(builtin)
    } else {
      throw Invalid(message: "Unknown theme '\(name)'. Use /theme list.")
    }
    var result = ui
    for (index, line) in source.components(separatedBy: .newlines).enumerated() {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let parts = line.replacingOccurrences(of: "=", with: " ")
        .split(whereSeparator: \.isWhitespace).map(String.init)
      do {
        if parts.count == 4, parts[0] == "/theme", parts[1].lowercased() == "color" {
          try set(parts[2].lowercased(), value: parts[3], in: &result)
        } else if parts.count == 3, parts[0] == "/set",
          parts[1].lowercased().hasPrefix("ui.")
        {
          // Saved themes from before /theme color retain their original spelling.
          try set(String(parts[1].lowercased().dropFirst(3)), value: parts[2], in: &result)
        } else {
          throw Invalid(message: "Expected /theme color SETTING VALUE.")
        }
      } catch {
        throw Invalid(message: "Theme '\(name)', line \(index + 1): \(error.localizedDescription)")
      }
    }
    return result
  }
}
