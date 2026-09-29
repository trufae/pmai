import Foundation
import MaiCore

public struct TailcatInvite: Codable, Equatable, Sendable {
  public var version = 1
  public var workerID: String
  public var name: String
  public var address: String
  public var token: String
  public var expires: TimeInterval

  public var url: String {
    let data = try! JSONEncoder().encode(self)
    return "pmai-tailcat://pair/" + data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public init(workerID: String, name: String, address: String, token: String, expires: TimeInterval) {
    self.workerID = workerID
    self.name = name
    self.address = address
    self.token = token
    self.expires = expires
  }

  public init(url: String, now: Date = Date()) throws {
    let prefix = "pmai-tailcat://pair/"
    guard url.hasPrefix(prefix), url.utf8.count <= 8192 else {
      throw JSONRPCError.invalidParams("Expected a pmai Tailcat pairing invite.")
    }
    var encoded = String(url.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded),
      let invite = try? JSONDecoder().decode(Self.self, from: data),
      invite.version == 1, UUID(uuidString: invite.workerID) != nil,
      Self.validAddress(invite.address), invite.token.utf8.count >= 32,
      invite.expires.isFinite, invite.expires > now.timeIntervalSince1970 else {
      throw JSONRPCError.invalidParams("Invalid or expired pairing invite. Generate another on the worker.")
    }
    self = invite
  }

  public static func validAddress(_ address: String) -> Bool {
    address.hasPrefix("tc") && (20...4096).contains(address.utf8.count)
      && address.utf8.allSatisfy { byte in
        (65...90).contains(byte) || (97...122).contains(byte)
          || (48...57).contains(byte) || byte == 45 || byte == 95
      }
  }
}

public struct TailcatPeer: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var nodeKey: String
  public var pairedAt: Date
  public var revoked = false
}

public struct TailcatWorker: Codable, Sendable {
  public var id: String
  public var name: String
  public var workspace: String
  public var address: String?
  public var invite: TailcatInvite?
  public var claimedBy: String?
  public var peers: [TailcatPeer] = []
}

public struct TailcatRemote: Codable, Sendable {
  public var name: String
  public var workerID: String
  public var address: String
  public var workspace: String
  public var lastSeen: Date?

  public init(name: String, workerID: String, address: String, workspace: String) {
    self.name = name
    self.workerID = workerID
    self.address = address
    self.workspace = workspace
  }
}

/// Private local registry. Transactions use an OS lock because Tailcat launches
/// a separate pmai process per connection; an actor alone cannot consume a token once.
public struct TailcatStore: Sendable {
  public struct State: Codable, Sendable {
    public var version = 1
    public var worker: TailcatWorker?
    public var remotes: [String: TailcatRemote] = [:]
  }

  public let directory: URL

  public init(directory: URL) { self.directory = directory }

  public func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
    try ACPStateFiles.createDirectory(directory)
    let lock = try ACPFileLock(url: directory.appendingPathComponent("registry.lock"), wait: true)
    return try withExtendedLifetime(lock) {
      var state = try read()
      let result = try body(&state)
      try ACPStateFiles.write(state, to: directory.appendingPathComponent("registry.json"))
      return result
    }
  }

  public func read() throws -> State {
    let url = directory.appendingPathComponent("registry.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return State() }
    let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    guard state.version == 1 else { throw JSONRPCError.invalidParams("Unsupported Tailcat registry version") }
    return state
  }

  @discardableResult
  public func initializeWorker(name: String, workspace: URL) throws -> TailcatWorker {
    let path = workspace.resolvingSymlinksInPath().standardizedFileURL.path
    return try transaction { state in
      if let worker = state.worker {
        guard worker.workspace == path else {
          throw JSONRPCError.invalidParams("This Tailcat home serves \(worker.workspace). Use a separate --home for another workspace.")
        }
        return worker
      }
      let worker = TailcatWorker(id: UUID().uuidString, name: name, workspace: path)
      state.worker = worker
      return worker
    }
  }

  public func invite(lifetime: TimeInterval = 300, now: Date = Date()) throws -> TailcatInvite {
    guard lifetime.isFinite, (30...3600).contains(lifetime) else {
      throw JSONRPCError.invalidParams("Invite lifetime must be between 30 and 3600 seconds")
    }
    return try transaction { state in
      guard let worker = state.worker, let address = worker.address,
        TailcatInvite.validAddress(address) else {
        throw JSONRPCError.invalidParams("Start pmai tailcat serve before creating an invite")
      }
      let invite = TailcatInvite(
        workerID: worker.id, name: worker.name, address: address,
        token: UUID().uuidString + UUID().uuidString,
        expires: now.addingTimeInterval(lifetime).timeIntervalSince1970)
      state.worker?.invite = invite
      state.worker?.claimedBy = nil
      return invite
    }
  }

  public func enroll(token: String, nodeKey: String, name: String, now: Date = Date()) throws -> TailcatWorker {
    guard Self.validNodeKey(nodeKey), !name.isEmpty, name.utf8.count <= 128,
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw JSONRPCError.invalidParams("Invalid peer identity")
    }
    let worker: TailcatWorker = try transaction { state in
      guard var worker = state.worker, let invite = worker.invite,
        invite.expires > now.timeIntervalSince1970,
        Self.equalToken(invite.token, token),
        worker.claimedBy == nil || worker.claimedBy == nodeKey else {
        throw JSONRPCError.invalidParams("Invite is invalid, expired, or already redeemed")
      }
      if let index = worker.peers.firstIndex(where: { $0.nodeKey == nodeKey }) {
        // A retry by the same peer is harmless; a revoked peer requires a new invite.
        guard !worker.peers[index].revoked || worker.claimedBy == nil else {
          throw JSONRPCError.invalidParams("Peer has been revoked")
        }
        worker.peers[index].revoked = false
        worker.peers[index].name = name
      } else {
        worker.peers.append(TailcatPeer(
          id: UUID().uuidString, name: name, nodeKey: nodeKey, pairedAt: now))
      }
      worker.claimedBy = nodeKey
      state.worker = worker
      return worker
    }
    try audit("paired", nodeKey: nodeKey)
    return worker
  }

  public func authorize(_ nodeKey: String) throws -> TailcatPeer {
    guard Self.validNodeKey(nodeKey),
      let peer = try read().worker?.peers.first(where: { $0.nodeKey == nodeKey && !$0.revoked }) else {
      throw JSONRPCError(code: -32001, message: "Tailcat peer is not paired or has been revoked")
    }
    return peer
  }

  public func revoke(_ selector: String) throws {
    let key: String = try transaction { state in
      let matches = state.worker?.peers.indices.filter {
        let peer = state.worker!.peers[$0]
        return peer.id == selector || peer.name == selector || peer.nodeKey == selector
      } ?? []
      guard matches.count == 1, let index = matches.first else {
        throw JSONRPCError.invalidParams("Choose one peer ID from pmai tailcat status")
      }
      state.worker!.peers[index].revoked = true
      return state.worker!.peers[index].nodeKey
    }
    try audit("revoked", nodeKey: key)
  }

  public func audit(_ event: String, nodeKey: String) throws {
    let lock = try ACPFileLock(url: directory.appendingPathComponent("audit.lock"), wait: true)
    try withExtendedLifetime(lock) {
      let url = directory.appendingPathComponent("audit.jsonl")
      if !FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
          throw JSONRPCError.internalError("Cannot create Tailcat audit log")
        }
      }
      let record: JSONValue = .object([
        "time": .number(Date().timeIntervalSince1970), "event": .string(event), "peer": .string(nodeKey)
      ])
      var data = try JSONEncoder().encode(record)
      data.append(10)
      let file = try FileHandle(forWritingTo: url)
      defer { try? file.close() }
      try file.seekToEnd()
      try file.write(contentsOf: data)
    }
  }

  public static func validNodeKey(_ key: String) -> Bool {
    key.hasPrefix("nodekey:") && key.utf8.count == 72
      && key.dropFirst(8).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func equalToken(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
