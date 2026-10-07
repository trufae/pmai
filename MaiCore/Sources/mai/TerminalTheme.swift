import Foundation
import MaiCore

/// Themes are batches of the appearance settings accepted by `/theme color`.
enum TerminalTheme {
  static let builtins: [String: ConfiguredTerminalUI] = [
    "default": .init(),
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
    "orange": .init(
      backgroundLine: "rgb:320", foreground: "rgb:fed", promptForeground: "rgb:fa4",
      toolResultForeground: "rgb:db8", toolCallForeground: "rgb:fc8",
      errorForeground: "rgb:f77", warningForeground: "rgb:fd6", successForeground: "rgb:bd8",
      infoForeground: "rgb:fa7", thinkingForeground: "rgb:a98",
      diffAddedForeground: "rgb:efb", diffAddedBackground: "rgb:231",
      diffRemovedForeground: "rgb:fca", diffRemovedBackground: "rgb:420",
      diffHeaderForeground: "rgb:fc8", selectionForeground: "rgb:320",
      selectionBackground: "rgb:fa4"),
    "sky": .init(
      backgroundLine: "rgb:013", foreground: "rgb:def", promptForeground: "rgb:7cf",
      toolResultForeground: "rgb:9bd", toolCallForeground: "rgb:9df",
      errorForeground: "rgb:f88", warningForeground: "rgb:ed9", successForeground: "rgb:8ec",
      infoForeground: "rgb:aaf", thinkingForeground: "rgb:89a",
      diffAddedForeground: "rgb:bfe", diffAddedBackground: "rgb:133",
      diffRemovedForeground: "rgb:fbd", diffRemovedBackground: "rgb:324",
      diffHeaderForeground: "rgb:7cf", selectionForeground: "rgb:013",
      selectionBackground: "rgb:7cf"),
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
