import Foundation
#if os(Windows)
import WinSDK
#endif

/// Finds local programs without interpreting commands or arguments as shell text.
public enum LocalExecutable {
  public enum ResolutionError: LocalizedError, Sendable {
    case invalidPath(String)
    case notFound(String)
    case batchScript(String)

    public var errorDescription: String? {
      switch self {
      case .invalidPath(let command): "Expected a local executable path: \(command)"
      case .notFound(let command): "Local executable not found: \(command)"
      case .batchScript(let command):
        "\(command) is a batch script. Configure cmd.exe explicitly with /d /s /c and a shell command, or run the underlying executable directly (for example node.exe with the server script)."
      }
    }
  }

  /// PATH directories in search order. Empty entries refer to the working directory.
  public static func searchPath(
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    #if os(Windows)
    return (LocalProcess.mergedEnvironment(environment)["Path"] ?? "")
      .components(separatedBy: ";").map(unquotedDirectory)
    #elseif os(Android)
    return (environment["PATH"] ?? "/system/bin:/system/xbin").components(separatedBy: ":")
    #else
    return (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").components(separatedBy: ":")
    #endif
  }

  /// Returns an absolute native filesystem path, suitable for APIs and subprocess arguments.
  /// Explicit search directories replace PATH and disable Windows' implicit cwd search.
  /// Windows resolves native .exe/.com programs; batch wrappers require an explicit shell.
  public static func resolve(
    _ command: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    workingDirectory: URL? = nil,
    searchPath: [String]? = nil
  ) throws -> String {
    guard !command.isEmpty, !command.contains("\0") else {
      throw ResolutionError.invalidPath(command)
    }
    let executable = AgentHome.expandUserPath(command, environment: environment)
    let base = (workingDirectory
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
      .appendingPathComponent("", isDirectory: true).standardizedFileURL
    let basePath = base.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? base.path
    #if os(Windows)
    let ext = (executable as NSString).pathExtension.lowercased()
    if ext == "cmd" || ext == "bat" { throw ResolutionError.batchScript(command) }
    let hasPath = executable.contains("/") || executable.contains("\\") || executable.contains(":")
    let directories = hasPath ? [basePath]
      : searchPath.map { $0.map(unquotedDirectory) } ?? [basePath] + self.searchPath(in: environment)
    let suffixes = ext.isEmpty ? [".exe", ".com"] : [""]
    #else
    let directories = executable.contains("/") ? [basePath] : searchPath ?? self.searchPath(in: environment)
    let suffixes = [""]
    #endif
    for directory in directories {
      #if os(Windows)
      let root = try windowsFullPath(directory.isEmpty ? "." : directory, relativeTo: basePath)
      #else
      let root = URL(fileURLWithPath: directory.isEmpty ? "." : directory, isDirectory: true, relativeTo: base)
      #endif
      for suffix in suffixes {
        #if os(Windows)
        let path = try windowsFullPath(executable + suffix, relativeTo: root)
        #else
        let path = URL(fileURLWithPath: executable + suffix, relativeTo: root).standardizedFileURL.path
        #endif
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { continue }
        #if !os(Windows)
        guard FileManager.default.isExecutableFile(atPath: path) else { continue }
        #endif
        return path
      }
    }
    #if os(Windows)
    if ext.isEmpty {
      for directory in directories {
        let root = try windowsFullPath(directory.isEmpty ? "." : directory, relativeTo: basePath)
        for suffix in [".cmd", ".bat"] {
          let path = try windowsFullPath(executable + suffix, relativeTo: root)
          var isDirectory: ObjCBool = false
          if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ResolutionError.batchScript(path)
          }
        }
      }
    }
    #endif
    throw ResolutionError.notFound(command)
  }

  #if os(Windows)
  private static func unquotedDirectory(_ directory: String) -> String {
    directory.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
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
    guard count > 0, Int(count) < buffer.count else { throw ResolutionError.invalidPath(path) }
    return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
  }
  #endif
}
