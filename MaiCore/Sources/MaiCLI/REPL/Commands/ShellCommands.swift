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
  /// `!ls`, `!git diff`, `!vim notes.md`: runs a line in the system shell with
  /// the terminal handed over when needed. Quick commands stay in buffer
  /// mode; output is retained without being sent to the model.
  static func runShellCommand(_ command: String, terminal: TerminalWriter) async {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: !COMMAND")
      return
    }
    let waitStatus: Int32
    do {
      waitStatus = try TerminalCommand.run(trimmed, retainOutput: true)
    } catch {
      await terminal.line(
        "error: Could not run '\(trimmed)': \(error.localizedDescription)",
        to: .standardError)
      return
    }
    #if os(Windows)
    if waitStatus != 0 {
      await terminal.note("exit status \(waitStatus)")
    }
    #else
    // The POSIX wait status packs a signal in the low bits and an exit code above.
    let signalNumber = waitStatus & 0x7f
    if signalNumber != 0 {
      await terminal.note("killed by signal \(signalNumber)")
    } else if (waitStatus >> 8) & 0xff != 0 {
      await terminal.note("exit status \((waitStatus >> 8) & 0xff)")
    }
    #endif
  }

  static func changeWorkingDirectory(_ argument: String, terminal: TerminalWriter) async {
    let path = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      await terminal.line("Usage: /cd PATH")
      return
    }
    let expanded = NSString(string: path).expandingTildeInPath
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let target = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      await terminal.line("error: Not a directory: \(target.path)", to: .standardError)
      return
    }
    guard FileManager.default.changeCurrentDirectoryPath(target.path) else {
      await terminal.line("error: Could not change directory to \(target.path)", to: .standardError)
      return
    }
    await terminal.line(FileManager.default.currentDirectoryPath)
  }

  static func shellWords(
    _ input: String, remainderAfter: Int = .max, shellEscapes: Bool? = nil
  ) throws -> [String] {
    #if os(Windows)
      let shellEscapes = shellEscapes ?? false
    #else
      let shellEscapes = shellEscapes ?? true
    #endif
    enum Quote { case single, double }
    var words: [String] = []
    var word = ""
    var quote: Quote?
    var escaped = false
    var started = false
    for index in input.indices {
      let character = input[index]
      if escaped {
        word.append(character)
        escaped = false
        started = true
        continue
      }
      // Windows paths keep backslashes literal, including before a closing quote.
      if shellEscapes, character == "\\", quote != .single {
        escaped = true
        started = true
        continue
      }
      if character == "'", quote != .double {
        quote = quote == .single ? nil : .single
        started = true
        continue
      }
      if character == "\"", quote != .single {
        quote = quote == .double ? nil : .double
        started = true
        continue
      }
      if character.isWhitespace, quote == nil {
        if started {
          words.append(word)
          if words.count == remainderAfter {
            let remainder = input[index...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? words : words + [remainder]
          }
          word = ""
          started = false
        }
        continue
      }
      word.append(character)
      started = true
    }
    guard quote == nil else { throw MCPCommandError.unterminatedQuote }
    guard !escaped else { throw MCPCommandError.danglingEscape }
    if started { words.append(word) }
    return words
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
}
