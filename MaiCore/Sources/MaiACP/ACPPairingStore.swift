import Foundation

public struct ACPPairedClient: Codable, Sendable {
  public var id: String
  public var name: String
  public var token: String
}

/// Only operator-approved clients appear here. A QR invitation is never an
/// agent credential. Keeping this outside the gateway also supports app hosts.
public struct ACPPairingStore: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }
  private var file: URL { directory.appendingPathComponent("clients.json") }

  public func clients() throws -> [ACPPairedClient] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try JSONDecoder().decode([ACPPairedClient].self, from: Data(contentsOf: file))
  }

  public func authorizes(_ token: String) -> Bool {
    (try? clients())?.contains { client in
      let a = Array(token.utf8)
      let b = Array(client.token.utf8)
      return a.count == b.count && zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    } == true
  }

  public func approve(id: String, name: String) throws -> String {
    try ACPStateFiles.createDirectory(directory)
    let lock = try ACPFileLock(url: file.appendingPathExtension("lock"), wait: true)
    defer { withExtendedLifetime(lock) {} }
    var clients = try clients().filter { $0.id != id }
    let token = UUID().uuidString + UUID().uuidString
    clients.append(.init(id: id, name: name, token: token))
    try ACPStateFiles.write(clients, to: file)
    return token
  }

  public func revoke(id: String) throws {
    try ACPStateFiles.createDirectory(directory)
    let lock = try ACPFileLock(url: file.appendingPathExtension("lock"), wait: true)
    defer { withExtendedLifetime(lock) {} }
    try ACPStateFiles.write(try clients().filter { $0.id != id }, to: file)
  }
}
