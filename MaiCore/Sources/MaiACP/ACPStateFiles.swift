import Foundation
#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Cross-process leases also protect sessions served by separate Tailcat
/// child processes. The kernel releases a lease when its owner exits.
public final class ACPFileLock: @unchecked Sendable {
  private let descriptor: Int32

  public init(url: URL, wait: Bool = false) throws {
    #if os(Windows)
      throw JSONRPCError.internalError("Persistent ACP state requires POSIX file locking.")
    #else
      let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw JSONRPCError.internalError("Cannot open state lock.") }
      guard flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
        close(fd)
        throw JSONRPCError.invalidParams("State is in use by another connection.")
      }
      descriptor = fd
    #endif
  }

  deinit {
    #if !os(Windows)
      _ = flock(descriptor, LOCK_UN)
      close(descriptor)
    #endif
  }
}

public enum ACPStateFiles {
  public static func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  public static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public static func component(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
  }
}
