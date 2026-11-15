import Foundation

/// Wire paths belong to the remote operating system, which may differ from
/// this client's. Drive-relative and root-relative Windows paths are ambiguous.
public enum RemoteWorkspacePath {
  public static func isAbsolute(_ path: String) -> Bool {
    guard !path.isEmpty, !path.contains("\0") else { return false }
    return path.hasPrefix("/") || isWindowsAbsolute(path)
  }

  public static func parent(of path: String) -> String? {
    guard let path = resolve(path, relativeTo: path) else { return nil }
    let root = rootPrefix(of: path)
    guard path != root, let separator = path.lastIndex(of: "/") else { return nil }
    return path.distance(from: path.startIndex, to: separator) < root.count
      ? root : String(path[..<separator])
  }

  /// Normalize the host's paths without asking the client's filesystem about them.
  static func resolve(_ path: String, relativeTo directory: String) -> String? {
    guard isAbsolute(directory), !path.contains("\0") else { return nil }
    let windows = isWindowsAbsolute(directory)
    let path = windows ? path.replacingOccurrences(of: "\\", with: "/") : path
    let directory = windows ? directory.replacingOccurrences(of: "\\", with: "/") : directory
    let absolute = path.hasPrefix("/") || (windows && isWindowsAbsolute(path))
      ? path : directory + (directory.hasSuffix("/") ? "" : "/") + path
    let root = rootPrefix(of: absolute)
    var components: [Substring] = []
    for component in absolute.dropFirst(root.count).split(separator: "/") {
      switch component {
      case ".": continue
      case "..": _ = components.popLast()
      default: components.append(component)
      }
    }
    return root + components.joined(separator: "/")
  }

  private static func rootPrefix(of path: String) -> String {
    if path.hasPrefix("//"), isWindowsAbsolute(path) {
      return "//" + path.dropFirst(2).split(separator: "/").prefix(2).joined(separator: "/") + "/"
    }
    return path.hasPrefix("/") ? "/" : String(path.prefix(3))
  }

  static func isLocalAbsolute(_ path: String) -> Bool {
    guard !path.isEmpty, !path.contains("\0") else { return false }
    #if os(Windows)
    // Foundation's URL.path can spell a drive path as /C:/directory.
    let native = (path.hasPrefix("/") && !path.hasPrefix("//")) ? String(path.dropFirst()) : path
    return isWindowsAbsolute(native)
    #else
    return path.hasPrefix("/") && NSString(string: path).isAbsolutePath
    #endif
  }

  private static func isWindowsAbsolute(_ path: String) -> Bool {
    let bytes = Array(path.utf8)
    if bytes.count >= 3,
      (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]), bytes[1] == 58,
      bytes[2] == 47 || bytes[2] == 92 { return true }
    let native = path.replacingOccurrences(of: "/", with: "\\")
    guard native.hasPrefix("\\\\") else { return false }
    let parts = native.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
    return parts.count >= 2 && !parts[0].isEmpty && !parts[1].isEmpty
  }
}
