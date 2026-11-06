import Foundation
import MaiCore

#if canImport(AppKit)
  import AppKit
#elseif os(Windows)
  import WinSDK
#endif

/// Writes text to the system clipboard. macOS and Windows use native APIs;
/// other platforms shell out to the first available clipboard tool.
enum SystemClipboard {
  static func write(_ text: String) throws {
    #if canImport(AppKit)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(text, forType: .string) else {
        throw ClipboardError.writeFailed("NSPasteboard rejected the text.")
      }
    #elseif os(Windows)
      try writeWindowsText(text)
    #else
      try writeUsingExternalTool(text)
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
    ["wl-copy"],
    ["xclip", "-selection", "clipboard"],
    ["xsel", "--clipboard", "--input"],
    ["pbcopy"],
    ["clip.exe"],
  ]

  static func writeUsingExternalTool(
    _ text: String,
    searchPath: [String] = LocalExecutable.searchPath()
  ) throws {
    guard let command = externalTools.compactMap({ resolve($0, searchPath: searchPath) }).first
    else {
      let names = externalTools.map { $0[0] }.joined(separator: ", ")
      throw ClipboardError.unavailable("No clipboard tool found in PATH (tried \(names)).")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(text.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ClipboardError.writeFailed(
        "\(command[0]) exited with status \(process.terminationStatus).")
    }
  }

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
