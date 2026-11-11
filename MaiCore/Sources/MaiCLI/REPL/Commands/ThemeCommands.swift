import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  static func handleThemeCommand(
    _ argument: String,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    directory: URL,
    terminal: TerminalWriter
  ) async {
    let parts = argument.replacingOccurrences(of: "=", with: " ")
      .split(whereSeparator: \.isWhitespace).map(String.init)
    let ui = configuration?.ui ?? .init()
    if parts.first == "color" {
      await handleThemeColorCommand(
        Array(parts.dropFirst()), configuration: &configuration,
        configurationPath: configurationPath, terminal: terminal)
      return
    }
    if parts.isEmpty || parts == ["list"] {
      await terminal.line(TerminalTheme.names(directory: directory, color: ui.color).joined(separator: "\n"))
      await terminal.line("/theme show [NAME] · /theme use NAME · /theme color · /theme save NAME · \(directory.path)")
      return
    }
    if parts.first == "show", parts.count <= 2 {
      let names = parts.count == 2 ? [parts[1]] : TerminalTheme.names(directory: directory, color: ui.color)
      let colors = await terminal.paintsOutput
      var previews: [(name: String, ui: ConfiguredTerminalUI)] = []
      for name in names {
        do {
          let previewUI = try TerminalTheme.load(name, directory: directory, ui: ui, requiredColor: ui.color)
          previews.append((name, previewUI))
        } catch {
          await terminal.line("error: \(error.localizedDescription)", to: .standardError)
        }
      }
      if !previews.isEmpty {
        await terminal.line(TerminalTheme.showcase(previews,
          columns: TerminalLineEditor.terminalColumns(), colors: colors))
      }
      return
    }
    guard parts.count == 2, ["use", "save"].contains(parts[0]) else {
      await terminal.line(themeHelp)
      return
    }
    do {
      if parts[0] == "save" {
        let url = try TerminalTheme.file(parts[1], directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try TerminalTheme.script(configuration?.ui ?? .init())
          .write(to: url, atomically: true, encoding: .utf8)
        await terminal.line("Saved theme '\(parts[1])' to \(url.path).")
      } else {
        guard var draft = configuration, let configurationPath else {
          throw TerminalTheme.Invalid(message: "No writable configuration is active.")
        }
        draft.ui = try TerminalTheme.load(parts[1], directory: directory, ui: draft.ui, requiredColor: ui.color)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.configureColors(draft.ui)
        await terminal.line("Applied theme '\(parts[1])'.")
      }
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  static func handleThemeColorCommand(
    _ parts: [String],
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let ui = configuration?.ui ?? .init()
    guard let key = parts.first?.lowercased() else {
      for key in TerminalTheme.keys {
        await terminal.line("\(key) = \(TerminalTheme.value(key, in: ui) ?? "none")")
      }
      return
    }
    guard parts.count <= 2 else {
      await terminal.line("Usage: /theme color [KEY [VALUE]]")
      return
    }
    guard let current = TerminalTheme.value(key, in: ui) else {
      await terminal.line("Unknown theme color '\(key)'. Use /theme color to list settings.")
      return
    }
    guard parts.count == 2 else {
      await terminal.line("\(key) = \(current)")
      return
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    do {
      try TerminalTheme.set(key, value: parts[1], in: &draft.ui)
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.configureColors(draft.ui)
      await terminal.line(
        "Set theme color \(key) = \(TerminalTheme.value(key, in: draft.ui) ?? "none").")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
