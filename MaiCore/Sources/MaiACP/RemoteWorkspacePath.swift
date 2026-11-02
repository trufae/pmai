import Foundation

/// Wire paths belong to the remote operating system, which may differ from
/// this client's. Drive-relative and root-relative Windows paths are ambiguous.
public enum RemoteWorkspacePath {
  public static func isAbsolute(_ path: String) -> Bool {
    guard !path.isEmpty, !path.contains("\0") else { return false }
    return path.hasPrefix("/") || isWindowsAbsolute(path)
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
