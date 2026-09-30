import Foundation
import MaiCore

/// Themes are batches of the same appearance settings accepted by `/set`.
enum TerminalTheme {
  static let builtins: [String: ConfiguredTerminalUI] = [
    "default": .init(),
    "slime": .init(
      backgroundLine: "rgb:021", foreground: "rgb:afa", promptForeground: "rgb:8f8",
      toolResultForeground: "rgb:8c8", bold: true),
    "light": .init(
      backgroundLine: "rgb:eee", foreground: "rgb:222", promptForeground: "rgb:046",
      toolResultForeground: "rgb:850"),
    "ember": .init(
      backgroundLine: "rgb:310", foreground: "rgb:fdb", promptForeground: "rgb:f95",
      toolResultForeground: "rgb:c96"),
  ]

  static var colors: [(String, WritableKeyPath<ConfiguredTerminalUI, String>)] {
    [
      ("ui.bgline", \.backgroundLine), ("ui.fgcolor", \.foreground),
      ("ui.bgcolor", \.background), ("ui.fgprompt", \.promptForeground),
      ("ui.bgprompt", \.promptBackground), ("ui.fgtoolresult", \.toolResultForeground),
    ]
  }

  struct Invalid: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func set(_ key: String, value: String, in ui: inout ConfiguredTerminalUI) throws {
    if key == "ui.bold" {
      switch value.lowercased() {
      case "1", "true", "yes", "on": ui.bold = true
      case "0", "false", "no", "off": ui.bold = false
      default: throw Invalid(message: "Usage: /set ui.bold <on|off>")
      }
    } else if let (_, path) = colors.first(where: { $0.0 == key }) {
      guard let color = TerminalLineEditor.normalizedColor(value) else {
        throw Invalid(
          message: "Unknown color '\(value)'. Use a named ANSI color, rgb:RGB, or none.")
      }
      ui[keyPath: path] = color
    } else {
      throw Invalid(message: "Themes accept UI colors and ui.bold only: '\(key)'.")
    }
  }

  static func script(_ ui: ConfiguredTerminalUI) -> String {
    (colors.map { key, path in
      "/set \(key) \(ui[keyPath: path].isEmpty ? "none" : ui[keyPath: path])"
    } + ["/set ui.bold \(ui.bold ? "on" : "off")"]).joined(separator: "\n") + "\n"
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
        guard parts.count == 3, parts[0] == "/set" else {
          throw Invalid(message: "Expected /set ui.SETTING VALUE.")
        }
        try set(parts[1].lowercased(), value: parts[2], in: &result)
      } catch {
        throw Invalid(message: "Theme '\(name)', line \(index + 1): \(error.localizedDescription)")
      }
    }
    return result
  }
}
