import Foundation
import MaiCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// The loopback WebSocket leg of an encrypted Forwiroh TCP tunnel.
/// SwiftNIO handles the upgrade and frames consistently on Apple, Linux and Android.
final class ForwirohWebSocketTransport: JSONRPCTransport, @unchecked Sendable {
  private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  fileprivate static let maximumSize = 16 * 1024 * 1024
  private let lock = NSLock()
  private var closed = false
  private var detail = ""
  private var channel: Channel?
  private var tasks: [Task<Void, Never>] = []
  private var upgradeResolved = false
  private let ready: EventLoopPromise<Void>
  private let incoming = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .unbounded)
  private let outgoing = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(256))

  init(url: URL, bearerToken: String?) throws {
    guard url.scheme == "ws", url.host == "127.0.0.1", let port = url.port,
      (1...65535).contains(port), url.path == "/acp", url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil
    else { throw JSONRPCError.invalidParams("Forwiroh requires a loopback ACP listener") }
    guard bearerToken?.contains(where: { $0.isNewline || $0 == "\r" }) != true else {
      throw JSONRPCError.invalidParams("Invalid gateway token")
    }
    ready = Self.group.next().makePromise(of: Void.self)
    let bootstrap = ClientBootstrap(group: Self.group)
      .connectTimeout(.seconds(10))
      .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
      .channelInitializer { [weak self] channel in
        guard let self else { return channel.close() }
        guard self.attach(channel) else { return channel.close() }
        let request = UpgradeRequest(owner: self, port: port, token: bearerToken)
        let upgrader = NIOWebSocketClientUpgrader(
          maxFrameSize: Self.maximumSize, automaticErrorHandling: false
        ) { channel, _ in
          channel.pipeline.addHandler(Frames(owner: self)).map { self.resolveUpgrade(.success(())) }
        }
        let upgrade: NIOHTTPClientUpgradeSendableConfiguration = (
          upgraders: [upgrader],
          completionHandler: { context in
            context.pipeline.removeHandler(request, promise: nil)
          })
        return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: upgrade)
          .flatMap { channel.pipeline.addHandler(request) }
      }
    let ready = ready
    let outgoing = outgoing
    let started: [Task<Void, Never>] = [
      Task { [weak self] in
        do {
          let address = try SocketAddress(ipAddress: "127.0.0.1", port: port)
          let channel = try await bootstrap.connect(to: address).get()
          try await ready.futureResult.get()
          for await bytes in outgoing.stream {
            try Task.checkCancellation()
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await channel.writeAndFlush(Self.frame(.text, data: buffer)).get()
          }
        } catch { self?.fail(error) }
      },
      Task { [weak self] in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self, !self.lock.withLock({ self.upgradeResolved }) else { return }
        self.fail(JSONRPCTransportError.timedOut("WebSocket upgrade"))
      },
    ]
    lock.withLock {
      if closed { for task in started { task.cancel() } } else { tasks = started }
    }
  }

  var isRunning: Bool { lock.withLock { !closed } }
  var recentErrorOutput: String { lock.withLock { detail } }
  func messages() -> AsyncStream<JSONRPCMessage> { incoming.stream }

  func send(_ message: JSONRPCMessage) throws {
    guard isRunning else { throw JSONRPCTransportError.closed }
    let data = try JSONEncoder().encode(message)
    guard data.count <= Self.maximumSize else {
      throw JSONRPCError.invalidParams("ACP message exceeds 16 MiB")
    }
    guard case .enqueued = outgoing.continuation.yield(data) else {
      close()
      throw JSONRPCTransportError.closed
    }
  }

  func close() {
    let previous = lock.withLock { () -> (Channel?, [Task<Void, Never>])? in
      guard !closed else { return nil }
      closed = true
      let result = (channel, tasks)
      channel = nil
      tasks = []
      return result
    }
    guard let previous else { return }
    resolveUpgrade(.failure(JSONRPCTransportError.closed))
    incoming.continuation.finish()
    outgoing.continuation.finish()
    for task in previous.1 { task.cancel() }
    previous.0?.close(promise: nil)
  }

  private func attach(_ channel: Channel) -> Bool {
    lock.withLock {
      guard !closed else { return false }
      self.channel = channel
      return true
    }
  }
  fileprivate func resolveUpgrade(_ result: Result<Void, any Error>) {
    let complete = lock.withLock {
      guard !upgradeResolved else { return false }
      upgradeResolved = true
      return true
    }
    if complete { ready.completeWith(result) }
  }
  fileprivate func fail(_ error: any Error) {
    lock.withLock { if !closed { detail = String(describing: error) } }
    resolveUpgrade(.failure(error))
    close()
  }
  fileprivate func received(_ bytes: Data) throws {
    guard String(data: bytes, encoding: .utf8) != nil else {
      throw JSONRPCError.invalidParams("Expected a UTF-8 WebSocket text message")
    }
    let message = try JSONDecoder().decode(JSONRPCMessage.self, from: bytes)
    incoming.continuation.yield(message)
  }
  fileprivate static func frame(_ opcode: WebSocketOpcode, data: ByteBuffer) -> WebSocketFrame {
    WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: data)
  }
}

private final class UpgradeRequest: ChannelInboundHandler, RemovableChannelHandler, Sendable {
  typealias InboundIn = HTTPClientResponsePart
  typealias OutboundOut = HTTPClientRequestPart
  let owner: ForwirohWebSocketTransport
  let port: Int
  let token: String?
  init(owner: ForwirohWebSocketTransport, port: Int, token: String?) {
    self.owner = owner; self.port = port; self.token = token
  }
  func channelActive(context: ChannelHandlerContext) {
    var headers = HTTPHeaders([("Host", "127.0.0.1:\(port)")])
    if let token { headers.add(name: "Authorization", value: "Bearer \(token)") }
    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/acp", headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if case .head(let response) = unwrapInboundIn(data) {
      owner.fail(JSONRPCError.invalidParams("ACP WebSocket upgrade rejected (\(response.status.code))"))
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { owner.fail(error) }
  func channelInactive(context: ChannelHandlerContext) { owner.close() }
}

private final class Frames: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  let owner: ForwirohWebSocketTransport
  var fragmented: Data?
  var heartbeat: RepeatedTask?
  var waitingForPong = false
  init(owner: ForwirohWebSocketTransport) { self.owner = owner }
  func handlerAdded(context: ChannelHandlerContext) {
    let channel = context.channel
    heartbeat = channel.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(20), delay: .seconds(20)) {
      [weak self] _ in
      guard let self else { return }
      guard !self.waitingForPong else {
        self.owner.fail(JSONRPCTransportError.timedOut("WebSocket heartbeat"))
        return
      }
      self.waitingForPong = true
      channel.writeAndFlush(
        ForwirohWebSocketTransport.frame(.ping, data: channel.allocator.buffer(capacity: 0)), promise: nil)
    }
  }
  func handlerRemoved(context: ChannelHandlerContext) { heartbeat?.cancel() }
  func channelInactive(context: ChannelHandlerContext) { heartbeat?.cancel(); owner.close() }
  func errorCaught(context: ChannelHandlerContext, error: Error) { owner.fail(error) }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    do {
      guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
        throw JSONRPCError.invalidParams("Invalid server WebSocket frame")
      }
      switch frame.opcode {
      case .ping, .pong, .connectionClose:
        guard frame.fin, frame.length <= 125 else {
          throw JSONRPCError.invalidParams("Invalid WebSocket control frame")
        }
        if frame.opcode == .pong { waitingForPong = false }
        else if frame.opcode == .ping {
          context.writeAndFlush(
            wrapOutboundOut(ForwirohWebSocketTransport.frame(.pong, data: frame.data)), promise: nil)
        } else { owner.close() }
      case .text, .continuation:
        guard (frame.opcode == .text && fragmented == nil)
          || (frame.opcode == .continuation && fragmented != nil) else {
          throw JSONRPCError.invalidParams("Invalid WebSocket continuation")
        }
        var bytes = fragmented ?? Data()
        guard bytes.count + frame.data.readableBytes <= ForwirohWebSocketTransport.maximumSize else {
          throw JSONRPCError.invalidParams("ACP message exceeds 16 MiB")
        }
        bytes.append(contentsOf: frame.data.readableBytesView)
        if frame.fin { fragmented = nil; try owner.received(bytes) }
        else { fragmented = bytes }
      default: throw JSONRPCError.invalidParams("Expected a WebSocket text message")
      }
    } catch { owner.fail(error) }
  }
}
