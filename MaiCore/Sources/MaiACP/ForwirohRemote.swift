import Foundation
import MaiCore

#if canImport(Forwiroh)
  import class Forwiroh.Forwiroh
  import struct Forwiroh.PeerPolicy
  #if os(iOS)
    import Security
  #endif
#endif

public struct ForwirohPeerSummary: Sendable {
  public let id: String
  public let name: String
}

#if canImport(Forwiroh)

  /// Shared client endpoint; each ACP connection owns and closes its own TCP tunnel.
  /// Servers use a separate instance/state directory so client trust never grants hosting access.
  public actor ForwirohRemote {
    public static let shared = ForwirohRemote(directory: defaultDirectory)
    private var directory: URL
    private var identity: Data?
    private var core: Forwiroh?
    private var opening: Task<Forwiroh, any Error>?
    private var closing: Task<Void, Never>?
    private var generation = 0
    private var name: String
    private var invitationID: String?

    private static var defaultDirectory: URL {
      #if os(iOS) || os(Android)
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("Forwiroh")
      #else
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          ".mai/forwiroh-client")
      #endif
    }

    public init(directory: URL, name: String = "PocketMai", identity: Data? = nil) {
      self.directory = directory
      self.name = name
      self.identity = identity
    }

    /// Configure before the first connection (CLI --home or Android's private storage).
    public func configure(directory: URL, identity: Data? = nil, name: String? = nil) throws {
      guard core == nil, opening == nil, closing == nil else {
        throw JSONRPCError.invalidParams(
          "Disconnect Forwiroh before changing its identity directory")
      }
      self.directory = directory
      self.identity = identity
      if let name { self.name = name }
    }

    private func endpoint() async throws -> Forwiroh {
      if let closing { await closing.value }
      if let core { return core }
      if let opening {
        let attempt = generation
        let node = try await opening.value
        guard generation == attempt else { throw CancellationError() }
        return node
      }
      let directory = directory
      let name = name
      var seed = identity
      #if os(iOS)
        if seed == nil { seed = try Self.keychainIdentity() }
      #endif
      let identity = seed
      let task = Task {
        let node = try await Forwiroh.open(
          stateDirectory: directory, name: name, identity: identity)
        do {
          try await node.setPairingPolicy(PeerPolicy(restricted: true))
          return node
        } catch {
          await node.close()
          throw error
        }
      }
      opening = task
      let attempt = generation
      do {
        let node = try await task.value
        guard generation == attempt else { throw CancellationError() }
        core = node
        opening = nil
        return node
      } catch {
        if generation == attempt { opening = nil }
        throw error
      }
    }

    public static func peerID(in url: URL) throws -> String {
      guard url.scheme == "forwiroh", let peer = url.host,
        peer.count == 64,
        peer.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        url.port == nil, url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil, url.path == "/acp"
      else { throw JSONRPCError.invalidParams("Use forwiroh://PEER_ID/acp from a pmai pairing QR") }
      return peer
    }

    public func pair(url: URL, invitation: String?) async throws {
      let id = try Self.peerID(in: url)
      let node = try await endpoint()
      if try await node.status().peers.contains(where: { $0.id == id }) { return }
      guard let invitation, !invitation.isEmpty else {
        throw JSONRPCError.invalidParams("Scan a fresh Forwiroh connection QR from this host")
      }
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let paired = try await node.pair(invitation: invitation, device: "pmai")
        guard paired == id else {
          try? await node.revoke(peer: paired)
          throw JSONRPCError.invalidParams("The invitation belongs to a different Forwiroh host")
        }
        try Task.checkCancellation()
      } onCancel: {
        Task { try? await node.cancelPair() }
      }
    }

    public struct Tunnel: Sendable {
      public let url: URL
      private let node: Forwiroh
      private let id: String
      fileprivate init(url: URL, node: Forwiroh, id: String) {
        self.url = url
        self.node = node
        self.id = id
      }
      public func close() async { try? await node.stopTunnel(id: id) }
    }

    public func connect(url: URL) async throws -> Tunnel {
      let peer = try Self.peerID(in: url)
      let node = try await endpoint()
      let id = try await node.forward(peer: peer, service: "pmai-acp")
      do {
        try Task.checkCancellation()
        let tunnels = try await node.status().tunnels
        guard let detail = tunnels.first(where: { $0.id == id })?.detail,
          let address = detail.components(separatedBy: " → ").first,
          address.hasPrefix("127.0.0.1:"),
          let port = Int(address.dropFirst("127.0.0.1:".count)), (1...65535).contains(port),
          let local = URL(string: "ws://127.0.0.1:\(port)/acp")
        else { throw JSONRPCError.internalError("Forwiroh did not return its local TCP listener") }
        return Tunnel(url: local, node: node, id: id)
      } catch {
        try? await node.stopTunnel(id: id)
        throw error
      }
    }

    /// Only the ACP gateway is reachable; SOCKS, reverse listeners and VPN remain disabled.
    public func serve(port: Int) async throws -> URL {
      guard (1...65535).contains(port) else { throw JSONRPCError.invalidParams("Invalid ACP port") }
      let node = try await endpoint()
      let policy = PeerPolicy(restricted: true, services: ["pmai-acp": "127.0.0.1:\(port)"])
      try await node.setPairingPolicy(policy)
      let status = try await node.status()
      for peer in status.peers { try await node.setPolicy(peer: peer.id, policy: policy) }
      return URL(string: "forwiroh://\(status.id)/acp")!
    }

    public func invite() async throws -> String {
      let node = try await endpoint()
      if let invitationID { try await node.cancelInvitation(id: invitationID) }
      let invitation = try await node.invite()
      invitationID = invitation.id
      return invitation.uri
    }
    public func pending() async throws -> [ForwirohPeerSummary] {
      try await endpoint().pendingPairings().map { .init(id: $0.id, name: $0.name) }
    }
    public func approve(id: String, accept: Bool) async throws {
      try await endpoint().approve(id: id, accept: accept)
    }
    public func peers() async throws -> [ForwirohPeerSummary] {
      try await endpoint().status().peers.map { .init(id: $0.id, name: $0.name) }
    }
    public func revoke(id: String) async throws { try await endpoint().revoke(peer: id) }

    public func close() async {
      if let closing {
        await closing.value
        return
      }
      generation += 1
      invitationID = nil
      let existing = core
      let startup = opening
      core = nil
      opening = nil
      let task = Task {
        var node = existing
        if node == nil { node = try? await startup?.value }
        await node?.close()
      }
      closing = task
      await task.value
      closing = nil
    }

    #if os(Android)
      public nonisolated static func initializeAndroid(
        environment: UnsafeMutableRawPointer, application: UnsafeMutableRawPointer
      ) {
        Forwiroh.initializeAndroid(environment: environment, application: application)
      }
    #endif

    #if os(iOS)
      private static func keychainIdentity() throws -> Data {
        let query: [CFString: Any] = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrService: "io.github.trufae.mai.forwiroh", kSecAttrAccount: "identity",
        ]
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else {
          throw JSONRPCError.internalError(
            "Cannot read Forwiroh identity from Keychain (\(status))")
        }
        var seed = Data(count: 32)
        let randomStatus = seed.withUnsafeMutableBytes {
          SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
          throw JSONRPCError.internalError("Cannot create Forwiroh identity")
        }
        var item = query
        item[kSecValueData] = seed
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
          throw JSONRPCError.internalError("Cannot save Forwiroh identity in Keychain")
        }
        return seed
      }
    #endif
  }

#else
  /// Other pmai transports remain available on platforms without SDK binaries.
  public actor ForwirohRemote {
    public static let shared = ForwirohRemote(directory: URL(fileURLWithPath: "."))
    public init(directory: URL, name: String = "PocketMai", identity: Data? = nil) {}
    private static var unavailable: JSONRPCError {
      .invalidParams(
        "Forwiroh is available on macOS, iOS, Linux and Android. Use a direct ACP gateway on this platform."
      )
    }
    public func configure(directory: URL, identity: Data? = nil, name: String? = nil) throws {}
    public static func peerID(in url: URL) throws -> String { throw unavailable }
    public func pair(url: URL, invitation: String?) async throws { throw Self.unavailable }
    public struct Tunnel: Sendable {
      public let url: URL
      public func close() async {}
    }
    public func connect(url: URL) async throws -> Tunnel { throw Self.unavailable }
    public func serve(port: Int) async throws -> URL { throw Self.unavailable }
    public func invite() async throws -> String { throw Self.unavailable }
    public func pending() async throws -> [ForwirohPeerSummary] { throw Self.unavailable }
    public func approve(id: String, accept: Bool) async throws { throw Self.unavailable }
    public func peers() async throws -> [ForwirohPeerSummary] { throw Self.unavailable }
    public func revoke(id: String) async throws { throw Self.unavailable }
    public func close() async {}
  }
#endif
