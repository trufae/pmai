import Foundation
import MaiCore

/// Cross-process leases also protect sessions served by separate Tailcat
/// child processes. The kernel releases a lease when its owner exits.
public final class ACPFileLock: @unchecked Sendable {
  private let lock: MaiFileLock

  public init(url: URL, wait: Bool = false) throws {
    do {
      lock = try MaiFileLock(url: url, wait: wait)
    } catch MaiFileLockError.busy {
      throw JSONRPCError.invalidParams("State is in use by another connection.")
    } catch {
      throw JSONRPCError.internalError("Cannot lock state: \(error.localizedDescription)")
    }
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
