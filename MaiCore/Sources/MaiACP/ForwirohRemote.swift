import Foundation
import MaiCore

#if canImport(Forwiroh)
  import struct Forwiroh.CoreEvent
  import class Forwiroh.Forwiroh
  import struct Forwiroh.PeerPolicy
  #if os(iOS)
    import Security
  #endif
#endif

public struct ForwirohConnectionError: LocalizedError, Sendable {
  public enum Stage: String, Sendable {
    case peerDial = "peer_dial"
    case streamSetup = "stream_setup"
    case peerNotPaired = "peer_not_paired"
    case remoteTCP = "remote_tcp"
    case serviceNotAuthorized = "service_not_authorized"
    case webSocket
    case bridge
    case unknown
  }

  public let stage: Stage
  public let retryable: Bool
  public let detail: String

  public var errorDescription: String? {
    switch stage {
    case .peerDial: "Forwiroh could not reach the host. \(detail)"
    case .streamSetup: "Forwiroh could not open the tunnel. \(detail)"
    case .peerNotPaired: "Forwiroh device approval is missing. Scan a fresh host QR and approve this device on the host."
    case .remoteTCP: "Forwiroh reached the host but could not open its pmai service. \(detail)"
    case .serviceNotAuthorized: "The host's Forwiroh policy does not grant access to pmai."
    case .webSocket: "The ACP WebSocket over Forwiroh failed. \(detail)"
    case .bridge: "The Forwiroh tunnel closed. \(detail)"
    case .unknown: "Forwiroh connection failed. \(detail)"
    }
  }
}

public struct ForwirohPeerSummary: Sendable {
  public let id: String
  public let name: String
  public var connected: Bool = false
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
    private var eventReader: Task<Void, Never>?
    private var reportServerError: (@Sendable (String) async -> Void)?
    private struct TunnelDiagnostics {
      var failure: ForwirohConnectionError?
    }
    private var tunnelDiagnostics: [String: TunnelDiagnostics] = [:]
    private var startingTunnels = 0

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
        let events = node.events
        eventReader = Task { [weak self] in
          for await event in events {
            guard let self, !Task.isCancelled else { return }
            await self.handle(event, generation: attempt)
          }
        }
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

    private func handle(_ event: CoreEvent, generation: Int) async {
      guard generation == self.generation else { return }
      let payload = event.payload
      if let id = payload["tunnel"]?.string {
        if event.name == "tunnel_error" {
          let retryable: Bool? = if case .bool(let value)? = payload["retryable"] { value } else { nil }
          tunnelDiagnostics[id]?.failure = Self.failure(
            detail: payload["error"]?.string, stage: payload["stage"]?.string, retryable: retryable)
        } else if event.name == "tunnel_ready" {
          tunnelDiagnostics[id]?.failure = nil
        }
      }
      if ["connection_error", "stream_error", "tunnel_error"].contains(event.name),
        let reportServerError, let detail = payload["error"]?.string
      {
        // Events can carry remote-controlled values. Log one bounded line without the raw payload.
        let stage = payload["stage"]?.string ?? event.name
        let peer = payload["peer"]?.string.map { " peer \($0)" } ?? ""
        let line = "\(stage)\(peer): \(detail)".split(whereSeparator: \.isNewline).joined(separator: " ")
        await reportServerError(String(line.prefix(1024)))
      }
    }

    private static func failure(detail: String?, stage: String?, retryable: Bool?) -> ForwirohConnectionError? {
      guard let detail else { return nil }
      let stage = stage.flatMap(ForwirohConnectionError.Stage.init(rawValue:))
      let legacyDial = detail.hasPrefix("peer connection timed out") || detail.hasPrefix("peer connection failed")
      let legacyRetry = stage == nil && (legacyDial || detail == "deadline has elapsed")
      return ForwirohConnectionError(
        stage: stage ?? (legacyDial ? .peerDial : .unknown), retryable: retryable ?? legacyRetry, detail: detail)
    }

    public struct Tunnel: Sendable {
      public let url: URL
      private let owner: ForwirohRemote
      private let node: Forwiroh
      private let id: String
      fileprivate init(url: URL, owner: ForwirohRemote, node: Forwiroh, id: String) {
        self.url = url
        self.owner = owner
        self.node = node
        self.id = id
      }

      func failure() async -> ForwirohConnectionError? {
        // The core records the failure before closing the loopback socket. Query it directly
        // if socket EOF wins the race with delivery of that event to the Swift actor.
        if let payload = try? await node.command(["op": .string("tunnel_failure"), "id": .string(id)]) {
          let retryable: Bool? = if case .bool(let value)? = payload["retryable"] { value } else { nil }
          if let failure = ForwirohRemote.failure(
            detail: payload["error"]?.string, stage: payload["stage"]?.string, retryable: retryable
          ) { return failure }
        }
        return await owner.tunnelFailure(id)
      }

      public func close() async {
        await owner.forgetTunnel(id)
        try? await node.stopTunnel(id: id)
      }
    }

    private func tunnelFailure(_ id: String) -> ForwirohConnectionError? {
      tunnelDiagnostics[id]?.failure
    }

    private func forgetTunnel(_ id: String) {
      tunnelDiagnostics[id] = nil
    }

    public func connect(url: URL) async throws -> Tunnel {
      let peer = try Self.peerID(in: url)
      startingTunnels += 1
      defer { startingTunnels -= 1 }
      let node = try await endpoint()
      let attempt = generation
      let id: String
      do {
        id = try await node.forward(peer: peer, service: "pmai-acp")
      } catch {
        if let status = try? await node.status(), !status.peers.contains(where: { $0.id == peer }) {
          throw ForwirohConnectionError(stage: .peerNotPaired, retryable: false, detail: error.localizedDescription)
        }
        throw error
      }
      do {
        try Task.checkCancellation()
        let tunnels = try await node.status().tunnels
        guard let detail = tunnels.first(where: { $0.id == id })?.detail,
          let address = detail.components(separatedBy: " → ").first,
          address.hasPrefix("127.0.0.1:"),
          let port = Int(address.dropFirst("127.0.0.1:".count)), (1...65535).contains(port),
          let local = URL(string: "ws://127.0.0.1:\(port)/acp")
        else { throw JSONRPCError.internalError("Forwiroh did not return its local TCP listener") }
        guard attempt == generation else { throw CancellationError() }
        tunnelDiagnostics[id] = TunnelDiagnostics()
        return Tunnel(url: local, owner: self, node: node, id: id)
      } catch {
        try? await node.stopTunnel(id: id)
        throw error
      }
    }

    /// Only the ACP gateway is reachable; SOCKS, reverse listeners and VPN remain disabled.
    public func serve(port: Int, onError: (@Sendable (String) async -> Void)? = nil) async throws -> URL {
      guard (1...65535).contains(port) else { throw JSONRPCError.invalidParams("Invalid ACP port") }
      reportServerError = onError
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
      try await endpoint().status().peers.map { .init(id: $0.id, name: $0.name, connected: $0.connected) }
    }
    public func revoke(id: String) async throws { try await endpoint().revoke(peer: id) }

    public func close() async {
      if let closing {
        await closing.value
        return
      }
      generation += 1
      eventReader?.cancel()
      eventReader = nil
      tunnelDiagnostics.removeAll()
      reportServerError = nil
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
        "Forwiroh is available on macOS, iOS, Linux, Android and Windows. Use a direct ACP gateway on this platform."
      )
    }
    public func configure(directory: URL, identity: Data? = nil, name: String? = nil) throws {}
    public static func peerID(in url: URL) throws -> String { throw unavailable }
    public func pair(url: URL, invitation: String?) async throws { throw Self.unavailable }
    public struct Tunnel: Sendable {
      public let url: URL
      func failure() async -> ForwirohConnectionError? { nil }
      public func close() async {}
    }
    public func connect(url: URL) async throws -> Tunnel { throw Self.unavailable }
    public func serve(port: Int, onError: (@Sendable (String) async -> Void)? = nil) async throws -> URL {
      throw Self.unavailable
    }
    public func invite() async throws -> String { throw Self.unavailable }
    public func pending() async throws -> [ForwirohPeerSummary] { throw Self.unavailable }
    public func approve(id: String, accept: Bool) async throws { throw Self.unavailable }
    public func peers() async throws -> [ForwirohPeerSummary] { throw Self.unavailable }
    public func revoke(id: String) async throws { throw Self.unavailable }
    public func close() async {}
  }
#endif
