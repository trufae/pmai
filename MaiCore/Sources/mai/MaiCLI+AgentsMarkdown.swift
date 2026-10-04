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
  /// Shows the setting or changes it for subsequent model turns.
  static func setAgentsMarkdown(
    parts: [String],
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let directory = AgentExecutionScope.directory
    let mode = configuration?.use.agentsmd ?? .off
    guard parts.count > 1 else {
      await terminal.line(
        "use.agentsmd = \(mode.rawValue) · \(agentsMarkdownSummary(from: directory))")
      return
    }
    guard parts.count == 2, let wanted = AgentsMDMode(rawValue: parts[1].lowercased()) else {
      await terminal.line("Usage: /set use.agentsmd <on|off|ask>")
      return
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.use.agentsmd = wanted
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    await runtime.configureProjectInstructionDirectory(wanted == .on ? directory : nil)
    await terminal.line(
      "Set use.agentsmd = \(wanted.rawValue). \(agentsMarkdownSummary(from: directory))")
  }

  /// Ask once for the current directory when the saved mode requests it.
  /// No answer, including a noninteractive session, leaves instructions off.
  static func askForAgentsMarkdown(
    from directory: URL, editor: TerminalLineEditor, terminal: TerminalWriter
  ) async -> Bool {
    guard isatty(STDIN_FILENO) != 0 else { return false }
    let files = AgentInstructionsFile.locate(from: directory)
    if !files.isEmpty {
      await terminal.line(agentsMarkdownSummary(from: directory))
    }
    let answer = editor.readLine(
      prompt: "Use AGENTS.md instructions found in this workspace? [y/N] ",
      completions: ["yes", "no"], rememberInput: false)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !editor.wasInterrupted && (answer == "y" || answer == "yes")
  }

  private static func agentsMarkdownSummary(from directory: URL) -> String {
    let files = AgentInstructionsFile.locate(from: directory)
    guard !files.isEmpty else {
      return "No AGENTS.md from \(directory.path) up to the repository root."
    }
    let base = directory.standardizedFileURL.pathComponents
    let names = files.map { file -> String in
      let target = file.standardizedFileURL.pathComponents
      let shared = zip(base, target).prefix { $0 == $1 }.count
      let ups = Array(repeating: "..", count: base.count - shared)
      return (ups + target.dropFirst(shared)).joined(separator: "/")
    }
    return "AGENTS.md from here up to the repository root: \(names.joined(separator: ", "))."
  }
}
