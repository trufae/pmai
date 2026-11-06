import Foundation
import MaiCore

extension MaiCLI {
  /// The editor every `/edit` hands the terminal to: `/set ui.editor` when it
  /// is set, then `$EDITOR`, `$VISUAL`, and vim as the last resort.
  private static let editorLock = NSLock()

  nonisolated(unsafe) private static var configuredEditor = ""

  static func configureEditor(_ command: String) {
    editorLock.withLock {
      configuredEditor = command.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  static func resolvedEditor(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    let configured = editorLock.withLock { configuredEditor }
    for candidate in [configured, environment["EDITOR"] ?? "", environment["VISUAL"] ?? ""] {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return "vim"
  }

  static func launchEditor(
    at url: URL, command: String? = nil, terminal: TerminalWriter
  ) async -> Bool {
    let command = command ?? resolvedEditor()
    #if os(Windows)
      let shellCommand = "\"\(command) \"\(url.path)\"\""
    #else
      let shellCommand = "\(command) \(shellQuote(url.path))"
    #endif
    let waitStatus: Int32
    do {
      waitStatus = try TerminalCommand.run(shellCommand)
    } catch {
      await terminal.line(
        "error: Could not launch editor '\(command)': \(error.localizedDescription)",
        to: .standardError)
      return false
    }
    #if os(Windows)
      let exitStatus = waitStatus
    #else
      let exitStatus = waitStatus & 0x7f == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
    #endif
    guard exitStatus == 0 else {
      await terminal.line(
        "error: Editor exited with status \(exitStatus).", to: .standardError)
      return false
    }
    return true
  }

  static func fallbackEditor(environment: [String: String]) -> String? {
    let editors = ["vim", "nano", "notepad"]
    #if os(Windows)
      let normalized = LocalProcess.mergedEnvironment(environment)
      let systemDirectories = (normalized["SYSTEMROOT"] ?? normalized["WINDIR"]).map {
        [URL(fileURLWithPath: $0).appendingPathComponent("System32").path]
      } ?? []
    #else
      let systemDirectories: [String] = []
    #endif
    let directories = LocalExecutable.searchPath(in: environment) + systemDirectories
    for editor in editors {
      guard let path = try? LocalExecutable.resolve(editor, environment: environment, searchPath: directories)
      else { continue }
      #if os(Windows)
        return "\"\(path)\""
      #else
        return shellQuote(path)
      #endif
    }
    return nil
  }
}
