import Foundation
import MaiStandardTools

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

struct REPLRedirectSyntax {
  enum Destination { case file(String, append: Bool), process(String) }
  let input: String
  let destination: Destination

  /// Only operators typed at the prompt count. Quotes, escapes, pasted bytes,
  /// heredocs, and commands already delegated to the shell remain literal.
  static func parse(_ input: String, pasted: IndexSet = []) throws -> Self? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    let command = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
    if command.count >= 2, command[0] == "/remote", command[1].lowercased() == "run" { return nil }
    let bytes = Array(input.utf8)
    var quote: UInt8?
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 92, quote != 39 { index += 2; continue }
      if let active = quote {
        if byte == active { quote = nil }
        index += 1
        continue
      }
      if byte == 34 || byte == 39 || byte == 96 {
        // An apostrophe inside a word is ordinary prose, e.g. "what's new".
        if byte != 39 || index == 0 || bytes[index - 1] <= 32 {
          quote = byte
        }
        index += 1
        continue
      }
      var length = 0
      var file = false
      var append = false
      if byte == 62 {
        file = true
        append = index + 1 < bytes.count && bytes[index + 1] == 62
        length = append ? 2 : 1
      } else if byte == 124,
        (index == 0 || bytes[index - 1] != 124),
        (index + 1 == bytes.count || bytes[index + 1] != 124)
      {
        length = 1
      }
      if length > 0, !pasted.intersects(integersIn: index..<(index + length)) {
        let command = String(decoding: bytes[..<index], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = String(decoding: bytes[(index + length)...], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !target.isEmpty else {
          throw REPLRedirectError("Usage: /COMMAND > FILE, /COMMAND >> FILE, or /COMMAND | SHELL_COMMAND")
        }
        return Self(input: command, destination: file ? .file(target, append: append) : .process(target))
      }
      index += max(1, length)
    }
    return nil
  }
}

struct REPLRedirectError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

/// A task-local stdout destination: unrelated turns and stderr keep their own
/// output. The input event or the turn it starts closes the destination.
final class REPLRedirection: @unchecked Sendable {
  @TaskLocal static var current: REPLRedirection?
  private let lock = NSLock()
  private let handle: FileHandle
  private var closed = false
  private var failure: (any Error)?
  private let process: Process?
  private let output: Task<Data, Never>?
  private let errors: Task<Data, Never>?
  private var terminalCommand: String?
  private var temporaryInput: URL?

  init(path: String, append: Bool) throws {
    let expanded = NSString(string: path).expandingTildeInPath
    #if os(Windows)
      if !FileManager.default.fileExists(atPath: expanded) {
        guard FileManager.default.createFile(atPath: expanded, contents: nil) else {
          throw REPLRedirectError("Cannot create \(expanded)")
        }
      }
      handle = try FileHandle(forWritingTo: URL(fileURLWithPath: expanded))
      if append { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
    #else
      let fd = open(expanded, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0o666)
      guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    #endif
    process = nil
    output = nil
    errors = nil
  }

  init(command: String) throws {
    // A pager must see the tty, and the editor must not consume its keys.
    // Spool first so a full pipe cannot block the command before the handoff.
    #if !os(Windows)
    if isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-pipe-\(UUID())")
      guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw REPLRedirectError("Cannot create pipeline input")
      }
      handle = try FileHandle(forWritingTo: url)
      process = nil
      output = nil
      errors = nil
      terminalCommand = command
      temporaryInput = url
      return
    }
    #endif
    let child = Process()
    #if canImport(Android)
      child.executableURL = URL(fileURLWithPath: "/system/bin/sh")
    #elseif os(Windows)
      child.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COMSPEC"] ?? "cmd.exe")
    #else
      child.executableURL = URL(fileURLWithPath: "/bin/sh")
    #endif
    #if os(Windows)
      child.arguments = ["/c", command]
    #else
      child.arguments = ["-c", command]
    #endif
    let input = Pipe(), stdout = Pipe(), stderr = Pipe()
    child.standardInput = input
    child.standardOutput = stdout
    child.standardError = stderr
    child.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    handle = input.fileHandleForWriting
    #if canImport(Darwin)
      _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    #elseif !os(Windows)
      signal(SIGPIPE, SIG_IGN)
    #endif
    try child.run()
    process = child
    // Drain both pipes concurrently so a filter producing more than a pipe's
    // capacity cannot deadlock the producer. Display its output on completion.
    output = Self.drain(stdout.fileHandleForReading)
    errors = Self.drain(stderr.fileHandleForReading)
  }

  private static func drain(_ handle: FileHandle) -> Task<Data, Never> {
    Task.detached {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          defer { try? handle.close() }
          continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
        }
      }
    }
  }

  func write(_ text: String) {
    lock.withLock {
      guard !closed, failure == nil else { return }
      do { try handle.write(contentsOf: Data(text.utf8)) }
      catch {
        // A filter such as head may successfully finish before its producer.
        if process == nil || (error as NSError).code != Int(POSIXErrorCode.EPIPE.rawValue) { failure = error }
      }
    }
  }

  func cancel() {
    guard let process, process.isRunning else { return }
    #if !os(Windows)
      let pid = process.processIdentifier
      if getpgid(pid) == pid { _ = kill(-pid, SIGKILL); return }
    #endif
    process.terminate()
  }

  /// Park the editor without pre-emptively releasing the buffer. The filter's
  /// actual terminal use decides whether a pager needs the full-screen handoff.
  private static func runFilter(_ command: String, inputGate: TerminalInputGate?) async throws
    -> Int32
  {
    try await withCheckedThrowingContinuation { reply in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          var status: Int32 = 0
          let run = {
            status = try TerminalCommand.run(
              command, retainOutput: true, bufferHandoff: .terminalControl)
          }
          if let inputGate { try inputGate.withSuspendedInput(run) } else { try run() }
          reply.resume(returning: status)
        } catch { reply.resume(throwing: error) }
      }
    }
  }

  func finish(terminal: TerminalWriter, inputGate: TerminalInputGate? = nil) async {
    let didClose = lock.withLock {
      guard !closed else { return false }
      closed = true
      do { try handle.close() } catch { if failure == nil { failure = error } }
      return true
    }
    guard didClose else { return }
    if let command = terminalCommand, let url = temporaryInput {
      defer { try? FileManager.default.removeItem(at: url) }
      let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
      do {
        let status = try await Self.runFilter("(\(command)) < \(quoted)", inputGate: inputGate)
        if status != 0 { throw REPLRedirectError("pipe exited with status \(status >> 8)") }
      } catch {
        await terminal.note("redirection: \(error.localizedDescription)", tone: .error)
      }
    }
    if let process {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            continuation.resume()
          }
        }
      } onCancel: {
        self.cancel()
      }
      if let output { await terminal.rawOutput(await output.value) }
      if let errors { await terminal.rawOutput(await errors.value, to: .standardError) }
      if process.terminationStatus != 0 {
        await terminal.note("pipe exited with status \(process.terminationStatus)", tone: .error)
      }
    }
    if let failure = lock.withLock({ failure }) {
      await terminal.note("redirection: \(failure.localizedDescription)", tone: .error)
    }
  }
}
