import Foundation
import MaiCore

#if !os(Windows)
  import CMaiTerminal
  #if canImport(Android)
    import Android
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Glibc)
    import Glibc
  #else
    import Darwin
  #endif
#endif

#if canImport(AppKit)
  import AppKit
#elseif os(Windows)
  import WinSDK
#endif

/// Writes text to the system clipboard. macOS and Windows use native APIs;
/// other platforms try the available clipboard tools.
enum SystemClipboard {
  static func write(_ text: String) async throws {
    try Task.checkCancellation()
    #if canImport(AppKit)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(text, forType: .string) else {
        throw ClipboardError.writeFailed("NSPasteboard rejected the text.")
      }
    #elseif os(Windows)
      try writeWindowsText(text)
    #else
      try await writeUsingExternalTool(text)
    #endif
  }

  #if os(Windows)
  private static func writeWindowsText(_ text: String) throws {
    guard !text.utf16.contains(0) else {
      throw ClipboardError.writeFailed("Windows clipboard text cannot contain a NUL character.")
    }
    // CF_UNICODETEXT uses NUL-terminated UTF-16 and CRLF line endings.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    let units = Array(normalized.utf16) + [0]
    let byteCount = units.count * MemoryLayout<UInt16>.stride
    guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(byteCount)) else {
      throw windowsFailure("Cannot allocate clipboard text")
    }
    var transferred = false
    defer { if !transferred { _ = GlobalFree(memory) } }
    guard let bytes = GlobalLock(memory) else {
      throw windowsFailure("Cannot access clipboard text")
    }
    units.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
    _ = GlobalUnlock(memory)

    // A real owner window is required: EmptyClipboard after OpenClipboard(nil)
    // would leave no owner, causing SetClipboardData to fail.
    let window = "STATIC".withCString(encodedAs: UTF16.self) {
      CreateWindowExW(0, $0, nil, DWORD(WS_POPUPWINDOW), 0, 0, 0, 0, nil, nil, nil, nil)
    }
    guard let window else { throw windowsFailure("Cannot create clipboard owner") }
    defer { _ = DestroyWindow(window) }
    let deadline = GetTickCount64() + 500
    while !OpenClipboard(window) {
      let code = GetLastError()
      guard GetTickCount64() < deadline else {
        throw ClipboardError.unavailable("Windows clipboard is in use (Windows error \(code)).")
      }
      Sleep(10)
    }
    defer { _ = CloseClipboard() }
    guard EmptyClipboard() else { throw windowsFailure("Cannot clear clipboard") }
    guard SetClipboardData(UINT(CF_UNICODETEXT), memory) != nil else {
      throw windowsFailure("Cannot write clipboard text")
    }
    // Windows owns the movable allocation only after SetClipboardData succeeds.
    transferred = true
  }

  private static func windowsFailure(_ operation: String) -> ClipboardError {
    .writeFailed("\(operation) (Windows error \(GetLastError())).")
  }
  #endif

  /// Command lines tried in order on platforms without a native pasteboard API.
  static let externalTools: [[String]] = [
    ["wl-copy", "--type", "text/plain;charset=utf-8"],
    ["xclip", "-selection", "clipboard", "-in", "-silent"],
    ["xsel", "--clipboard", "--input"],
    ["pbcopy"],
    ["clip.exe"],
  ]

  #if !os(Windows)
  static func writeUsingExternalTool(
    _ text: String,
    searchPath: [String] = LocalExecutable.searchPath(),
    timeout: Duration = .seconds(5)
  ) async throws {
    try Task.checkCancellation()
    let commands = externalTools.compactMap { resolve($0, searchPath: searchPath) }
    guard !commands.isEmpty else {
      let names = externalTools.map { $0[0] }.joined(separator: ", ")
      throw ClipboardError.unavailable("No clipboard tool found in PATH (tried \(names)).")
    }

    // A regular file cannot block on a helper that never reads stdin, and
    // avoids SIGPIPE if it exits early. Unlink it immediately to keep copies
    // private and leave no transcript on disk after a crash or cancellation.
    var template = Array(FileManager.default.temporaryDirectory
      .appendingPathComponent("pmai-clipboard-XXXXXX").path.utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? input.close() }
    guard unlink(template) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    try input.write(contentsOf: Data(text.utf8))
    let output = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
    defer { try? output.close() }
    var failures: [String] = []
    for command in commands {
      try Task.checkCancellation()
      try input.seek(toOffset: 0)
      do {
        try await run(command, input: input, output: output, timeout: timeout)
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch ClipboardError.writeFailed(let reason) {
        failures.append(reason)
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    throw ClipboardError.writeFailed(failures.joined(separator: "; "))
  }

  private static func run(
    _ command: [String], input: FileHandle, output: FileHandle, timeout: Duration
  ) async throws {
    let arguments = command.map { strdup($0) } + [nil]
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for pointer in arguments + environment { free(pointer) } }
    // On Linux, Foundation Process tracks exit through an inherited socket.
    // Clipboard daemons retain that socket after forking, so even a successful
    // parent exit may never complete. Reap only the direct child with waitpid.
    let child = mai_process_spawn(
      command[0], arguments, environment, FileManager.default.currentDirectoryPath,
      input.fileDescriptor, output.fileDescriptor, output.fileDescriptor)
    guard child > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var reaped = false
    defer {
      if !reaped {
        // Kill the session's process group as well as the helper, including
        // children that ignore SIGTERM. Successful clipboard owners stay alive.
        _ = kill(-child, SIGKILL)
        _ = kill(child, SIGKILL)
        while waitpid(child, nil, 0) == -1 && errno == EINTR {}
      }
    }
    let deadline = ContinuousClock.now + timeout
    while true {
      try Task.checkCancellation()
      var status: Int32 = 0
      let waited = waitpid(child, &status, WNOHANG)
      if waited == child {
        reaped = true
        guard status == 0 else {
          let signal = status & 0x7f
          let reason = signal == 0
            ? "exited with status \((status >> 8) & 0xff)" : "was terminated by signal \(signal)"
          throw ClipboardError.writeFailed("\(command[0]) \(reason).")
        }
        return
      }
      if waited == -1 && errno != EINTR {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      guard ContinuousClock.now < deadline else {
        throw ClipboardError.writeFailed("\(command[0]) timed out waiting for the clipboard.")
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
  #endif

  private static func resolve(_ command: [String], searchPath: [String]) -> [String]? {
    guard let name = command.first,
      let path = try? LocalExecutable.resolve(name, searchPath: searchPath) else { return nil }
    return [path] + command.dropFirst()
  }
}

enum ClipboardError: LocalizedError {
  case unavailable(String)
  case writeFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason): "Clipboard unavailable: \(reason)"
    case .writeFailed(let reason): "Clipboard write failed: \(reason)"
    }
  }
}
