import Foundation
import MaiACP
import MaiCore
import NIOCore
import NIOWebSocket

/// Opt-in pmai connections retain their worker across a socket loss. Credentials
/// scope the resume ID; an invitation never reaches this pool before approval.
actor ACPResumableAgents {
  private struct Entry {
    let token: String
    let agent: ACPResumableAgent
  }
  private var entries: [String: Entry] = [:]
  private var closed = false
  private let configuration: ACPWebSocketGateway.Configuration

  init(configuration: ACPWebSocketGateway.Configuration) { self.configuration = configuration }

  func attach(_ message: JSONRPCMessage, token: String, channel: Channel) async throws
    -> ACPResumableAgent
  {
    guard !closed else { throw JSONRPCTransportError.closed }
    guard message.method == ACP.Method.initialize,
      let id = message.params?.objectValue?["_meta"]?.objectValue?["pmai"]?
        .objectValue?["resumeId"]?.stringValue, UUID(uuidString: id) != nil
    else { throw JSONRPCError.invalidParams("A remote connection requires a resume ID") }
    let key = token + ":" + id
    let agent: ACPResumableAgent
    if let entry = entries[key] {
      agent = entry.agent
    } else {
      if entries.count >= configuration.maximumConnections {
        for (key, entry) in entries {
          if await entry.agent.expireIdle() {
            entries.removeValue(forKey: key)
            break
          }
        }
      }
      guard entries.count < configuration.maximumConnections else {
        throw JSONRPCError.invalidParams("All remote sessions are running. Stop one before opening another chat.")
      }
      agent = try ACPResumableAgent(configuration: configuration)
      entries[key] = Entry(token: token, agent: agent)
      await agent.start()
    }
    try await agent.attach(channel)
    return agent
  }

  func reap() async {
    for (key, entry) in entries {
      let expired = await entry.agent.expireIfNeeded()
      if !configuration.authorizesSession(entry.token) || expired {
        entries.removeValue(forKey: key)
        await entry.agent.close()
      }
    }
  }

  func close() async {
    closed = true
    let agents = entries.values.map(\.agent)
    entries.removeAll()
    for agent in agents { await agent.close() }
  }
}

actor ACPResumableAgent {
  private struct Request {
    let id: JSONValue
    let generation: Int
    let method: String
  }
  private let transport: StdioJSONRPCTransport
  private var reader: Task<Void, Never>?
  private var channel: Channel?
  private var detachedAt: Date?
  private var generation = 0
  private var sessionID: String?
  private var nextID = 1
  private var requests: [Int: Request] = [:]
  private var permissions: [String: JSONRPCMessage] = [:]
  private var closed = false

  init(configuration: ACPWebSocketGateway.Configuration) throws {
    transport = try StdioJSONRPCTransport.spawn(
      command: configuration.command, arguments: configuration.arguments,
      workingDirectory: configuration.workingDirectory)
  }

  func start() {
    let transport = transport
    reader = Task { [weak self] in
      for await message in transport.messages() { await self?.receive(message) }
      await self?.close()
    }
  }

  func attach(_ channel: Channel) throws {
    guard !closed else { throw JSONRPCTransportError.closed }
    if let previous = self.channel, previous !== channel { previous.close(promise: nil) }
    generation += 1
    self.channel = channel
    detachedAt = nil
  }

  func detach(_ channel: Channel) {
    guard self.channel === channel else { return }
    self.channel = nil
    detachedAt = Date()
  }

  func expireIdle() -> Bool {
    guard channel == nil, requests.isEmpty else { return false }
    close()
    return true
  }

  func expireIfNeeded() -> Bool {
    let expired = closed || (detachedAt.map { Date().timeIntervalSince($0) >= 300 } == true && requests.isEmpty)
    if expired { close() }
    return expired
  }

  func send(_ message: JSONRPCMessage, from channel: Channel) throws {
    guard !closed, self.channel === channel else { throw JSONRPCTransportError.closed }
    var message = message
    if message.isRequest, let id = message.id, let method = message.method {
      let serial = nextID
      nextID += 1
      requests[serial] = Request(id: id, generation: generation, method: method)
      message.id = .integer(serial)
      if method == ACP.Method.sessionNew, let sessionID {
        var params = message.params?.objectValue ?? [:]
        params["sessionId"] = .string(sessionID)
        message.method = ACP.Method.sessionLoad
        message.params = .object(params)
      }
    } else if message.isResponse, let id = message.id {
      guard permissions.removeValue(forKey: id.compactJSONString) != nil else { return }
    }
    try transport.send(message)
  }

  private func receive(_ message: JSONRPCMessage) async {
    var message = message
    if message.method == ACP.Method.sessionUpdate,
      let update = message.params?.objectValue?["update"]?.objectValue,
      update["sessionUpdate"]?.stringValue == "_pmai/session_state",
      update["running"]?.boolValue == false {
      let session = message.params?.objectValue?["sessionId"]?.stringValue
      permissions = permissions.filter { $0.value.params?.objectValue?["sessionId"]?.stringValue != session }
    }
    var replayPermissions = false
    if message.isResponse, let id = message.id?.intValue {
      guard let request = requests.removeValue(forKey: id) else { return }
      if request.method == ACP.Method.sessionNew, message.error == nil {
        sessionID = message.result?.objectValue?["sessionId"]?.stringValue ?? sessionID
        if let sessionID, var result = message.result?.objectValue {
          result["sessionId"] = .string(sessionID)
          message.result = .object(result)
        }
      }
      guard channel != nil, request.generation == generation else { return }
      message.id = request.id
      replayPermissions = request.method == ACP.Method.sessionLoad && message.error == nil
    } else if message.isRequest, let id = message.id {
      permissions[id.compactJSONString] = message
    }
    await deliver(message)
    if replayPermissions {
      for request in permissions.values { await deliver(request) }
    }
  }

  private func deliver(_ message: JSONRPCMessage) async {
    guard let channel else { return }
    do {
      let bytes = try JSONEncoder().encode(message)
      guard bytes.count <= 16 * 1024 * 1024 else {
        channel.close(promise: nil)
        detach(channel)
        return
      }
      var buffer = channel.allocator.buffer(capacity: bytes.count)
      buffer.writeBytes(bytes)
      try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer)).get()
    } catch { detach(channel) }
  }

  func close() {
    guard !closed else { return }
    closed = true
    reader?.cancel()
    reader = nil
    channel?.close(promise: nil)
    channel = nil
    transport.close()
    requests.removeAll()
    permissions.removeAll()
  }
}
