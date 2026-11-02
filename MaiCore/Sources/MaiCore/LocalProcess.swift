#if !os(iOS)
import Foundation
#if os(Windows)
import WinSDK
#endif

/// Configures a local subprocess without interpreting its arguments as shell text.
public enum LocalProcess {
  public static func mergedEnvironment(
    _ environment: [String: String], overrides: [String: String] = [:]
  ) -> [String: String] {
    #if os(Windows)
    var result: [String: String] = [:]
    for source in [environment, overrides] {
      // Resolve conflicting spellings deterministically, preferring uppercase.
      for key in source.keys.sorted().reversed() {
        let canonical = key.lowercased() == "path" ? "Path" : key.uppercased()
        result[canonical] = source[key]
      }
    }
    return result
    #else
    return environment.merging(overrides) { _, configured in configured }
    #endif
  }

  public static func configure(
    _ process: Process, command: String, arguments: [String] = [],
    environment: [String: String]? = nil, workingDirectory: URL? = nil
  ) throws {
    let executable = NSString(string: command).expandingTildeInPath
    let base = workingDirectory
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    #if os(Windows)
    let childEnvironment = mergedEnvironment(environment ?? ProcessInfo.processInfo.environment)
    process.executableURL = try windowsExecutable(executable, environment: childEnvironment, base: base)
    process.arguments = arguments
    process.environment = childEnvironment
    #else
    if executable.contains("/") {
      let url = URL(fileURLWithPath: executable, relativeTo: base).standardizedFileURL
      guard url.isFileURL else { throw LaunchError.invalidPath(command) }
      process.executableURL = url
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable] + arguments
    }
    process.environment = environment
    #endif
    process.currentDirectoryURL = workingDirectory
  }

  private enum LaunchError: LocalizedError {
    case invalidPath(String)
    case notFound(String)
    case batchScript(String)

    var errorDescription: String? {
      switch self {
      case .invalidPath(let command): "Expected a local executable path: \(command)"
      case .notFound(let command): "Local executable not found: \(command)"
      case .batchScript(let command):
        "\(command) is a batch script. Configure cmd.exe explicitly with /d /s /c and a shell command, or run the underlying executable directly (for example node.exe with the server script)."
      }
    }
  }

  #if os(Windows)
  private static func windowsExecutable(
    _ command: String, environment: [String: String], base: URL
  ) throws -> URL {
    guard !command.isEmpty, !command.contains("\0") else { throw LaunchError.invalidPath(command) }
    let ext = (command as NSString).pathExtension.lowercased()
    if ext == "cmd" || ext == "bat" { throw LaunchError.batchScript(command) }
    let hasPath = command.contains("/") || command.contains("\\") || command.contains(":")
    let basePath = base.withUnsafeFileSystemRepresentation { pointer in
      pointer.map { String(cString: $0) }
    } ?? base.path
    let directories = hasPath ? [basePath] : [basePath]
      + (environment["Path"] ?? "").components(separatedBy: ";").map {
        // PATH entries are often quoted by Windows installers.
        $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
    let suffixes = ext.isEmpty ? [".exe", ".com"] : [""]
    for directory in directories {
      let root = try windowsFullPath(directory.isEmpty ? "." : directory, relativeTo: basePath)
      for suffix in suffixes {
        let path = try windowsFullPath(command + suffix, relativeTo: root)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
          return URL(fileURLWithPath: path)
        }
      }
    }
    if ext.isEmpty {
      for directory in directories {
        let root = try windowsFullPath(directory.isEmpty ? "." : directory, relativeTo: basePath)
        for suffix in [".cmd", ".bat"] {
          let path = try windowsFullPath(command + suffix, relativeTo: root)
          if FileManager.default.fileExists(atPath: path) { throw LaunchError.batchScript(path) }
        }
      }
    }
    throw LaunchError.notFound(command)
  }

  private static func windowsFullPath(_ path: String, relativeTo base: String) throws -> String {
    var path = path.replacingOccurrences(of: "/", with: "\\")
    let base = base.replacingOccurrences(of: "/", with: "\\")
    // URL.path may use RFC 8089's /C:/ spelling; Win32 wants C:\.
    if path.utf16.count >= 3, path.hasPrefix("\\"), Array(path.utf16)[2] == 58 {
      path.removeFirst()
    }
    let characters = Array(path.utf16)
    let hasDrive = characters.count >= 2 && characters[1] == 58
    let absolute: String
    if path.hasPrefix("\\\\") || hasDrive && characters.count >= 3 && characters[2] == 92 {
      absolute = path
    } else if path.hasPrefix("\\") {
      let volume = base.hasPrefix("\\\\")
        ? "\\\\" + base.split(separator: "\\").prefix(2).joined(separator: "\\")
        : String(base.prefix(2))
      absolute = volume + path
    } else if hasDrive {
      absolute = path.prefix(2).lowercased() == base.prefix(2).lowercased()
        ? base + "\\" + String(path.dropFirst(2)) : path
    } else {
      absolute = base + "\\" + path
    }
    var buffer = [WCHAR](repeating: 0, count: 32768)
    let count = absolute.withCString(encodedAs: UTF16.self) {
      GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil)
    }
    guard count > 0, Int(count) < buffer.count else { throw LaunchError.invalidPath(path) }
    return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
  }
  #endif
}
#endif
