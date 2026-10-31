import Foundation
import MaiACP
import MaiCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// Authenticated WebSocket -> ACP stdio bridge. Resumable pmai connections
/// retain their worker; standard ACP connections own a child until disconnect.
public enum ACPWebSocketGateway {
  public struct Pairing: Sendable {
    public var authorizes: @Sendable (String) -> Bool
    public var request: @Sendable (String, String, String) async throws -> String
    public init(
      authorizes: @escaping @Sendable (String) -> Bool,
      request: @escaping @Sendable (String, String, String) async throws -> String
    ) {
      self.authorizes = authorizes
      self.request = request
    }
  }
  public struct Configuration: Sendable {
    public var host: String
    public var port: Int
    public var tokenFile: URL
    public var command: String
    public var arguments: [String]
    public var workingDirectory: URL
    public var maximumConnections: Int
    public var pairing: Pairing?
    public var resumable: Bool

    public init(
      host: String = "127.0.0.1", port: Int = 19283, tokenFile: URL,
      command: String, arguments: [String], workingDirectory: URL, maximumConnections: Int = 16,
      pairing: Pairing? = nil, resumable: Bool = false
    ) {
      self.host = host
      self.port = port
      self.tokenFile = tokenFile
      self.command = command
      self.arguments = arguments
      self.workingDirectory = workingDirectory
      self.maximumConnections = maximumConnections
      self.pairing = pairing
      self.resumable = resumable
    }

    func authorizesSession(_ token: String) -> Bool {
      pairing.map { $0.authorizes(token) } ?? invitationMatches(token)
    }

    fileprivate func authorizes(_ token: String) -> Bool {
      invitationMatches(token) || pairing?.authorizes(token) == true
    }

    fileprivate func invitationMatches(_ token: String) -> Bool {
      guard
        let stored = try? String(contentsOf: tokenFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines), stored.utf8.count >= 32
      else { return false }
      let lhs = Array(stored.utf8)
      let rhs = Array(token.utf8)
      guard lhs.count == rhs.count else { return false }
      return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
  }

  public static func serve(
    _ configuration: Configuration,
    onListening: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let agents = ACPResumableAgents(configuration: configuration)
    let reaper = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        await agents.reap()
      }
    }
    defer { reaper.cancel() }
    let slots = ConnectionSlots(maximum: configuration.maximumConnections)
    do {
      let channel = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 64)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
        .childChannelOption(
          ChannelOptions.writeBufferWaterMark,
          value: ChannelOptions.Types.WriteBufferWaterMark(low: 1024 * 1024, high: 32 * 1024 * 1024)
        )
        .childChannelInitializer { channel in
          guard slots.acquire() else { return channel.close() }
          channel.closeFuture.whenComplete { _ in slots.release() }
          let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            channel.close(promise: nil)
          }
          channel.closeFuture.whenComplete { _ in timeout.cancel() }
          let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 16 * 1024 * 1024,
            shouldUpgrade: { channel, request in
              // Native clients use an Authorization header. No browser origins,
              // query-string credentials, or arbitrary upstream routes are accepted.
              let headers = request.headers["authorization"]
              let value = headers.count == 1 ? headers[0] : ""
              let accepted =
                request.method == .GET && request.uri == "/acp"
                && request.headers["origin"].isEmpty && value.hasPrefix("Bearer ")
                && configuration.authorizes(String(value.dropFirst(7)))
              return channel.eventLoop.makeSucceededFuture(accepted ? HTTPHeaders() : nil)
            },
            upgradePipelineHandler: { channel, request in
              timeout.cancel()
              let token = String((request.headers.first(name: "authorization") ?? "").dropFirst(7))
              return channel.pipeline.addHandler(
                AgentBridge(configuration: configuration, token: token, agents: agents))
            })
          return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (
              upgraders: [upgrader],
              completionHandler: { context in
                context.pipeline.removeHandler(name: "http-rejection", promise: nil)
              }
            )
          ).flatMap { channel.pipeline.addHandler(HTTPRejection(), name: "http-rejection") }
        }
        .bind(host: configuration.host, port: configuration.port).get()
      onListening(
        channel.localAddress?.description ?? "\(configuration.host):\(configuration.port)")
      try await withTaskCancellationHandler {
        try await channel.closeFuture.get()
      } onCancel: {
        channel.close(promise: nil)
      }
      await agents.close()
      try await group.shutdownGracefully()
    } catch {
      await agents.close()
      try? await group.shutdownGracefully()
      throw error
    }
  }
}

private final class ConnectionSlots: @unchecked Sendable {
  let maximum: Int
  let lock = NSLock()
  var active = 0
  init(maximum: Int) { self.maximum = maximum }
  func acquire() -> Bool {
    lock.withLock {
      guard active < maximum else { return false }
      active += 1
      return true
    }
  }
  func release() { lock.withLock { active -= 1 } }
}

private final class HTTPRejection: ChannelInboundHandler, RemovableChannelHandler, Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .head = unwrapInboundIn(data) else { return }
    var headers = HTTPHeaders()
    headers.add(name: "content-length", value: "0")
    headers.add(name: "connection", value: "close")
    context.write(
      wrapOutboundOut(
        .head(HTTPResponseHead(version: .http1_1, status: .unauthorized, headers: headers))),
      promise: nil)
    let channel = context.channel
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

// NIO confines handler state to the channel event loop. The two Tasks capture
// only the Sendable channel/transport/streams, never mutable handler state.
private final class AgentBridge: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  let configuration: ACPWebSocketGateway.Configuration
  let token: String
  let agents: ACPResumableAgents
  var transport: StdioJSONRPCTransport?
  var reader: Task<Void, Never>?
  var writer: Task<Void, Never>?
  var heartbeat: RepeatedTask?
  var waitingForPong = false
  var fragmented: Data?
  var pairingOnly = false
  let outbound = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .bufferingOldest(256))

  init(configuration: ACPWebSocketGateway.Configuration, token: String, agents: ACPResumableAgents) {
    self.configuration = configuration
    self.token = token
    self.agents = agents
  }

  func handlerAdded(context: ChannelHandlerContext) {
    guard configuration.authorizes(token) else {
      context.close(promise: nil)
      return
    }
    if let policy = configuration.pairing, !policy.authorizes(token) {
      pairingOnly = true
      return
    }
    if configuration.resumable {
      let channel = context.channel
      writer = Task { [agents, token, configuration, outbound] in
        var agent: ACPResumableAgent?
        var transport: StdioJSONRPCTransport?
        var reader: Task<Void, Never>?
        do {
          for await message in outbound.stream {
            guard channel.isActive else { break }
            if agent == nil && transport == nil {
              if message.params?.objectValue?["_meta"]?.objectValue?["pmai"]?
                .objectValue?["resumeId"]?.stringValue != nil {
                agent = try await agents.attach(message, token: token, channel: channel)
              } else {
                let child = try StdioJSONRPCTransport.spawn(
                  command: configuration.command, arguments: configuration.arguments,
                  workingDirectory: configuration.workingDirectory)
                transport = child
                reader = Task {
                  for await reply in child.messages() { await Self.reply(reply, channel: channel) }
                  channel.close(promise: nil)
                }
              }
            }
            if let agent { try await agent.send(message, from: channel) }
            else { try transport?.send(message) }
          }
        } catch { channel.close(promise: nil) }
        if let agent { await agent.detach(channel) }
        reader?.cancel()
        transport?.close()
      }
      startHeartbeat(channel: channel)
      return
    }
    do {
      // Only authenticated upgrades reach this point. The command is fixed by
      // the operator; clients cannot select executables or supply environment.
      let transport = try StdioJSONRPCTransport.spawn(
        command: configuration.command,
        arguments: configuration.arguments, workingDirectory: configuration.workingDirectory)
      self.transport = transport
      let channel = context.channel
      reader = Task {
        do {
          for await message in transport.messages() {
            let data = try JSONEncoder().encode(message)
            guard data.count <= 16 * 1024 * 1024 else { break }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer))
              .get()
          }
        } catch { /* closing the socket makes the client fail pending calls */  }
        try? await channel.close().get()
      }
      writer = Task.detached { [outbound] in
        do {
          for await message in outbound.stream { try transport.send(message) }
        } catch { try? await channel.close().get() }
      }
      startHeartbeat(channel: channel)
    } catch { context.close(promise: nil) }
  }

  private func startHeartbeat(channel: Channel) {
    heartbeat = channel.eventLoop.scheduleRepeatedTask(
      initialDelay: .seconds(20), delay: .seconds(20)
    ) { [weak self] _ in
      guard let self else { return }
      guard self.configuration.authorizes(self.token), !self.waitingForPong else {
        channel.close(promise: nil)
        return
      }
      self.waitingForPong = true
      channel.writeAndFlush(
        WebSocketFrame(
          fin: true, opcode: .ping,
          data: channel.allocator.buffer(capacity: 0)), promise: nil)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    guard frame.maskKey != nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
      context.close(promise: nil)
      return
    }
    switch frame.opcode {
    case .ping:
      guard frame.fin, frame.length <= 125 else {
        context.close(promise: nil)
        return
      }
      context.writeAndFlush(
        wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)),
        promise: nil)
    case .pong:
      guard frame.fin, frame.length <= 125 else {
        context.close(promise: nil)
        return
      }
      waitingForPong = false
    case .connectionClose:
      let channel = context.channel
      context.writeAndFlush(
        wrapOutboundOut(
          WebSocketFrame(
            fin: true, opcode: .connectionClose,
            data: context.channel.allocator.buffer(capacity: 0)))
      ).whenComplete { _ in channel.close(promise: nil) }
    case .text, .continuation:
      guard
        (frame.opcode == .text && fragmented == nil)
          || (frame.opcode == .continuation && fragmented != nil)
      else {
        context.close(promise: nil)
        return
      }
      var bytes = fragmented ?? Data()
      let payload = frame.unmaskedData
      guard bytes.count + payload.readableBytes <= 16 * 1024 * 1024 else {
        context.close(promise: nil)
        return
      }
      bytes.append(contentsOf: payload.readableBytesView)
      if !frame.fin {
        fragmented = bytes
        return
      }
      fragmented = nil
      guard String(data: bytes, encoding: .utf8) != nil,
        let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: bytes),
        message.method != nil || message.id != nil
      else {
        context.close(promise: nil)
        return
      }
      if pairingOnly, let pairing = configuration.pairing {
        pair(message, policy: pairing, channel: context.channel)
        return
      }
      if case .enqueued = outbound.continuation.yield(message) { return }
      context.close(promise: nil)
    default: context.close(promise: nil)
    }
  }

  private func pair(
    _ message: JSONRPCMessage, policy: ACPWebSocketGateway.Pairing, channel: Channel
  ) {
    guard reader == nil, configuration.invitationMatches(token) else {
      channel.close(promise: nil)
      return
    }
    guard let id = message.id else {
      channel.close(promise: nil)
      return
    }
    guard message.method == "_pmai/pair",
      let clientID = message.params?.objectValue?["clientID"]?.stringValue,
      let name = message.params?.objectValue?["name"]?.stringValue,
      !clientID.isEmpty, clientID.count <= 200, !name.isEmpty, name.count <= 200,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !clientID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      let response = JSONRPCMessage.failure(
        id: id,
        error: .init(
          code: JSONRPCError.authRequired,
          message: "Pairing must be accepted in the serving REPL before connecting."))
      reader = Task { await Self.reply(response, channel: channel) }
      return
    }
    let source = channel.remoteAddress?.description ?? "remote client"
    reader = Task {
      let response: JSONRPCMessage
      do {
        let token = try await policy.request(clientID, name, source)
        response = .response(id: id, result: .object(["token": .string(token)]))
      } catch {
        response = .failure(
          id: id,
          error: error as? JSONRPCError
            ?? .init(code: JSONRPCError.authRequired, message: error.localizedDescription))
      }
      await Self.reply(response, channel: channel)
    }
  }

  private static func reply(_ message: JSONRPCMessage, channel: Channel) async {
    guard let data = try? JSONEncoder().encode(message) else { return }
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    try? await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer)).get()
  }

  func channelWritabilityChanged(context: ChannelHandlerContext) {
    // Bound memory if a remote app stops consuming output. Recovery is via
    // session/load, never by silently dropping a tool request or a delta.
    if !context.channel.isWritable { context.close(promise: nil) }
    context.fireChannelWritabilityChanged()
  }

  func channelInactive(context: ChannelHandlerContext) {
    heartbeat?.cancel()
    reader?.cancel()
    outbound.continuation.finish()
    if !configuration.resumable { writer?.cancel() }
    transport?.close()
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
