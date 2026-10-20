import Foundation
import MaiACP
import MaiACPGateway
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

enum RemoteAddress {
  static func localIPv4() throws -> String {
    #if os(Windows)
      throw JSONRPCError.invalidParams("Supply /remote serve --address YOUR_IP on this platform.")
    #else
      var interfaces: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&interfaces) == 0, let first = interfaces else {
        throw JSONRPCError.internalError("Cannot enumerate network interfaces")
      }
      defer { freeifaddrs(interfaces) }
      #if canImport(Android)
        // Android imports these flags as C enum values instead of integers.
        let upFlag = UInt32(IFF_UP.rawValue)
        let loopbackFlag = UInt32(IFF_LOOPBACK.rawValue)
      #else
        let upFlag = UInt32(IFF_UP)
        let loopbackFlag = UInt32(IFF_LOOPBACK)
      #endif
      var candidates: [(Int, String, String)] = []
      var cursor: UnsafeMutablePointer<ifaddrs>? = first
      while let item = cursor {
        defer { cursor = item.pointee.ifa_next }
        let flags = item.pointee.ifa_flags
        let interfaceName: UnsafeMutablePointer<CChar>? = item.pointee.ifa_name
        guard let address = item.pointee.ifa_addr,
          let interfaceName,
          Int32(address.pointee.sa_family) == AF_INET,
          flags & upFlag != 0, flags & loopbackFlag == 0
        else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard
          getnameinfo(
            address, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer,
            .init(buffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { continue }
        let ip = String(
          decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let name = String(cString: interfaceName)
        guard !ip.hasPrefix("169.254."), !ip.hasPrefix("127.") else { continue }
        let physical = name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wl")
        candidates.append((physical ? 0 : 1, name, ip))
      }
      guard
        let address = candidates.sorted(by: {
          if $0.0 != $1.0 { return $0.0 < $1.0 }
          return $0.1 < $1.1
        }).first?.2
      else {
        throw JSONRPCError.invalidParams(
          "No network address found. Connect to a network or use /remote serve --address YOUR_IP.")
      }
      return address
    #endif
  }
}

/// A REPL owns the listener's lifetime. It runs independently of local turns;
/// each connected client gets the same existing ACP/runtime/workspace adapter.
actor RemoteREPLServer {
  let home: AgentHome
  let hosts: ACPRemoteHostStore
  private let executable: String
  private var task: Task<Void, Never>?
  private var profile: ACPRemoteConnection?
  private var failure: String?
  private var generation = 0
  private var lease: ACPFileLock?
  private var publisher: RemoteOpenTunnel?
  private var forwiroh: ForwirohRemote?
  private var forwirohWatcher: Task<Void, Never>?
  private var servingTerminal: TerminalWriter?
  private struct PendingClient {
    var clientID: String
    var name: String
    var reply: CheckedContinuation<String, any Error>
  }
  private var pending: [String: PendingClient] = [:]
  var pairingStore: ACPPairingStore {
    .init(directory: home.rootURL.appendingPathComponent("remote-server"))
  }

  init(home: AgentHome, executable: String) {
    self.home = home
    self.hosts = ACPRemoteHostStore(directory: home.rootURL.appendingPathComponent("remotes"))
    self.executable = executable
  }

  func start(
    _ arguments: [String], configuration: MaiConfiguration, agent: AgentDefinition,
    cwd: URL, terminal: TerminalWriter
  ) async throws {
    if task != nil {
      guard arguments.isEmpty else {
        throw JSONRPCError.invalidParams(
          "Already serving. Run /remote stop before changing paths or options.")
      }
      await showPairing(terminal: terminal)
      return
    }
    var flags: [String: String] = [:]
    var paths: [String] = []
    var loopback = false
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      if key == "--loopback", !loopback {
        loopback = true
        index += 1
        continue
      }
      if key == "--path" || key == "--paths" {
        index += 1
        let start = index
        while index < arguments.count, !arguments[index].hasPrefix("--") {
          paths.append(AgentProject.standardizedPath(AgentHome.expandUserPath(arguments[index])))
          index += 1
        }
        guard index > start else {
          throw JSONRPCError.invalidParams("--path requires at least one directory")
        }
        continue
      }
      guard ["--protocol", "--port", "--address", "--name", "--url"].contains(key),
        index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), flags[key] == nil
      else {
        throw JSONRPCError.invalidParams(
          "Usage: /remote serve [--protocol local|opentunnel|forwiroh] [--path PATH ...] [--port PORT] [--loopback] [--address IP | --url URL] [--name NAME]"
        )
      }
      flags[key] = arguments[index + 1]
      index += 2
    }
    guard let port = Int(flags["--port"] ?? "19283"), (1...65535).contains(port) else {
      throw JSONRPCError.invalidParams("Port must be between 1 and 65535")
    }
    guard let connectionProtocol = ACPRemoteProtocol(rawValue: flags["--protocol"] ?? "local")
    else {
      throw JSONRPCError.invalidParams(
        "Unknown serving protocol. Use --protocol local, opentunnel or forwiroh.")
    }
    guard connectionProtocol != .tailcat else {
      throw JSONRPCError.invalidParams(
        "For Tailcat, pair the worker with pmai tailcat pair, then run pmai acp-gateway -- pmai tailcat connect NAME."
      )
    }
    guard flags["--url"] == nil || flags["--address"] == nil else {
      throw JSONRPCError.invalidParams("Use either --url or --address to advertise the connection")
    }
    guard connectionProtocol != .opentunnel || flags["--address"] == nil else {
      throw JSONRPCError.invalidParams(
        "OpenTunnel chooses its public address. Use --url for an existing tunnel.")
    }
    guard connectionProtocol != .forwiroh || (flags["--url"] == nil && flags["--address"] == nil)
    else {
      throw JSONRPCError.invalidParams(
        "Forwiroh uses its paired device address; omit --url and --address")
    }
    loopback = loopback || connectionProtocol == .opentunnel || connectionProtocol == .forwiroh
    let bindAddress = loopback ? "127.0.0.1" : "0.0.0.0"
    let url: URL
    if let advertised = flags["--url"] {
      guard let parsed = URL(string: advertised), parsed.path == "/acp" else {
        throw JSONRPCError.invalidParams("Use a gateway URL ending in /acp")
      }
      try ACPRemoteConnection.validate(url: parsed)
      guard connectionProtocol != .opentunnel || parsed.scheme?.lowercased() == "wss" else {
        throw JSONRPCError.invalidParams("OpenTunnel connections require a wss:// gateway URL")
      }
      url = parsed
    } else {
      let address = try flags["--address"] ?? (loopback ? bindAddress : RemoteAddress.localIPv4())
      guard let parsed = URL(string: "ws://\(address):\(port)/acp") else {
        throw JSONRPCError.invalidParams("Invalid host address")
      }
      url = parsed
    }
    let directory = home.rootURL.appendingPathComponent("remote-server")
    try ACPStateFiles.createDirectory(directory)
    let serverLease = try ACPFileLock(url: directory.appendingPathComponent("serve.lock"))
    let tokenFile = directory.appendingPathComponent("token")
    let token = try ACPGatewayCLI.loadToken(tokenFile)
    let defaultDirectory =
      paths.isEmpty
        || paths.contains {
          cwd.path == $0 || cwd.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
        } ? cwd.path : paths[0]
    var connection = try ACPRemoteConnection(
      name: flags["--name"] ?? ProcessInfo.processInfo.hostName,
      url: url, token: token, cwd: defaultDirectory)
    connection.requiresApproval = true
    var snapshot = configuration
    snapshot.defaultAgent = agent.id
    snapshot.agents.removeAll { $0.id == agent.id }
    snapshot.agents.append(agent)
    let configFile = directory.appendingPathComponent("settings.json")
    try snapshot.save(to: configFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    var childArguments = [
      "--acp", "--home", home.rootURL.path, "--config", configFile.path,
      "--agent", agent.id,
    ]
    for path in paths {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw JSONRPCError.invalidParams("Not a directory: \(path)")
      }
      childArguments += ["--acp-path", path]
    }
    let clients = pairingStore
    let pairing = ACPWebSocketGateway.Pairing(
      authorizes: { clients.authorizes($0) },
      request: { [weak self] id, name, source in
        guard let self else { throw CancellationError() }
        return try await self.requestPairing(id: id, name: name, source: source, terminal: terminal)
      })
    let gateway = ACPWebSocketGateway.Configuration(
      host: bindAddress, port: port,
      tokenFile: tokenFile, command: executable, arguments: childArguments, workingDirectory: cwd,
      pairing: pairing)
    let tunnel =
      try connectionProtocol == .opentunnel && flags["--url"] == nil
      ? RemoteOpenTunnel(directory: directory) : nil
    let (ready, signal) = AsyncStream<Result<Void, any Error>>.makeStream()
    generation += 1
    let attempt = generation
    failure = nil
    task = Task { [weak self] in
      defer { signal.finish() }
      do {
        try await ACPWebSocketGateway.serve(gateway) { _ in signal.yield(.success(())) }
      } catch {
        signal.yield(.failure(error))
        if !Task.isCancelled {
          await self?.ended(attempt, error: error.localizedDescription, terminal: terminal)
        }
      }
    }
    var iterator = ready.makeAsyncIterator()
    guard let result = await iterator.next() else {
      await stop()
      throw CancellationError()
    }
    do { try result.get() } catch {
      await stop()
      throw error
    }
    lease = serverLease
    publisher = tunnel
    servingTerminal = terminal
    do {
      if let tunnel {
        await terminal.line(
          "Connecting OpenTunnel; first-time certificate provisioning can take a few minutes…")
        connection.url = try await tunnel.start(port: port)
      }
      if connectionProtocol == .forwiroh {
        let node = ForwirohRemote(
          directory: directory.appendingPathComponent("forwiroh"), name: connection.name)
        forwiroh = node
        connection.url = try await node.serve(port: port)
        forwirohWatcher = Task { [weak self] in
          var seen = Set<String>()
          while !Task.isCancelled {
            do {
              let requests = try await node.pending()
              for request in requests where seen.insert(request.id).inserted {
                await terminal.line(
                  "Forwiroh pairing: \(request.name) · /remote accept fw-\(request.id) or /remote reject fw-\(request.id). After accepting, approve the ACP request too."
                )
              }
              try await Task.sleep(for: .seconds(1))
            } catch {
              if !Task.isCancelled {
                await self?.ended(attempt, error: error.localizedDescription, terminal: terminal)
              }
              return
            }
          }
        }
      }
      try Task.checkCancellation()
      guard generation == attempt, task != nil else { throw CancellationError() }
      connection.connectionProtocol = connectionProtocol
      try connection.validate()
      profile = connection
      await terminal.line(
        "Serving \(connection.url.absoluteString) via \(connectionProtocol.rawValue) · \(paths.isEmpty ? "all indexed projects" : paths.joined(separator: ", "))"
      )
      await showPairing(terminal: terminal)
    } catch {
      let publisherAlreadyEnded = publisher == nil
      await stop()
      // The listener may have failed while the publisher was still starting.
      if publisherAlreadyEnded, let tunnel { try? await tunnel.stop() }
      throw error
    }
  }

  private func ended(_ attempt: Int, error: String, terminal: TerminalWriter) async {
    guard generation == attempt else { return }
    task = nil
    profile = nil
    failure = error
    for code in Array(pending.keys) { cancelPairing(code) }
    await stopPublisher()
    lease = nil
    await terminal.line("error: Remote server stopped: \(error)", to: .standardError)
  }

  func showPairing(terminal: TerminalWriter) async {
    guard var profile else {
      await terminal.line(
        failure.map { "Remote server stopped: " + $0 }
          ?? "Remote server is stopped. /remote serve starts it.")
      return
    }
    do {
      if let forwiroh { profile.forwirohInvitation = try await forwiroh.invite() }
      let uri = try profile.uri()
      let file = home.rootURL.appendingPathComponent("remote-server/connection.txt")
      try Data((uri + "\n").utf8).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      await terminal.line(
        "Scan this QR in PocketMai → Hosts, or use /remote pair on another pmai. Accept the client here with /remote accept:"
      )
      var qr = ""
      try TailcatQR.show(uri, output: nil, write: { qr += $0 + "\n" })
      await terminal.line(qr)
      await terminal.line(uri)
      await terminal.line("Connection profile: \(file.path) · /remote stop stops sharing.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  func status() -> String {
    profile.map {
      "Serving \($0.url.absoluteString) via \(($0.connectionProtocol ?? .local).rawValue)"
    }
      ?? (task != nil ? "Starting remote server…" : nil) ?? failure.map { "Stopped: \($0)" }
      ?? "Remote server is stopped."
  }

  private func requestPairing(id: String, name: String, source: String, terminal: TerminalWriter)
    async throws -> String
  {
    let code = String(UUID().uuidString.lowercased().prefix(8))
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { reply in
        guard !Task.isCancelled else {
          reply.resume(throwing: CancellationError())
          return
        }
        pending[code] = .init(clientID: id, name: name, reply: reply)
        Task {
          await terminal.line(
            "Pairing request \(code): \(name) from \(source). /remote accept \(code) or /remote reject \(code)."
          )
        }
      }
    } onCancel: {
      Task { await self.cancelPairing(code) }
    }
  }

  private func cancelPairing(_ code: String) {
    pending.removeValue(forKey: code)?.reply.resume(throwing: CancellationError())
  }

  func pendingClients() async throws -> [String] {
    var result = pending.sorted { $0.key < $1.key }.map { "\($0.key) · \($0.value.name) (ACP)" }
    if let forwiroh {
      result += try await forwiroh.pending().map { "fw-\($0.id) · \($0.name) (Forwiroh)" }
    }
    return result
  }

  func resolvePairing(_ code: String?, allow: Bool) async throws -> String {
    if let forwiroh, code?.hasPrefix("fw-") == true || (code == nil && pending.isEmpty) {
      let requests = try await forwiroh.pending()
      let matches = requests.filter { request in
        code.map { request.id.hasPrefix(String($0.dropFirst(3))) } ?? true
      }
      guard matches.count == 1, let request = matches.first else {
        throw JSONRPCError.invalidParams("Choose a Forwiroh request from /remote pending")
      }
      try await forwiroh.approve(id: request.id, accept: allow)
      return allow
        ? "Paired \(request.name) over Forwiroh. Accept the next ACP request to grant chat access."
        : "Rejected \(request.name)."
    }
    let matches = pending.keys.filter { key in code.map { key.hasPrefix($0.lowercased()) } ?? true }
    guard matches.count == 1, let key = matches.first, let client = pending[key] else {
      throw JSONRPCError.invalidParams(
        pending.isEmpty
          ? "No pairing requests are waiting." : "Choose a request code from /remote pending.")
    }
    if allow {
      let token = try pairingStore.approve(id: client.clientID, name: client.name)
      pending.removeValue(forKey: key)?.reply.resume(returning: token)
      return "Accepted \(client.name)."
    }
    pending.removeValue(forKey: key)?.reply.resume(
      throwing: JSONRPCError(
        code: JSONRPCError.authRequired,
        message: "The server rejected pairing."))
    return "Rejected \(client.name)."
  }

  func stop() async {
    generation += 1
    let running = task
    task = nil
    profile = nil
    for code in Array(pending.keys) { cancelPairing(code) }
    running?.cancel()
    await running?.value
    await stopPublisher()
    lease = nil
  }

  func forwirohClients() async throws -> [String] {
    guard let forwiroh else { return [] }
    return try await forwiroh.peers().map { "fw-\($0.id) · \($0.name)" }
  }

  func revokeClient(_ id: String) async throws {
    if id.hasPrefix("fw-") {
      guard let forwiroh else {
        throw JSONRPCError.invalidParams(
          "Start /remote serve --protocol forwiroh before revoking a paired device")
      }
      try await forwiroh.revoke(id: String(id.dropFirst(3)))
    } else {
      try pairingStore.revoke(id: id)
    }
  }

  private func stopPublisher() async {
    forwirohWatcher?.cancel()
    forwirohWatcher = nil
    let node = forwiroh
    forwiroh = nil
    await node?.close()
    let tunnel = publisher
    let terminal = servingTerminal
    publisher = nil
    servingTerminal = nil
    if let tunnel {
      do { try await tunnel.stop() } catch {
        await terminal?.line(
          "error: Cannot stop OpenTunnel: \(error.localizedDescription)", to: .standardError)
      }
    }
  }
}
