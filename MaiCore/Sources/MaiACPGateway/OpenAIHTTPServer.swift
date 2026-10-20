import Foundation
import MaiCore
import NIOCore
import NIOHTTP1
import NIOPosix

public struct ProxyHTTPRequest: Sendable {
  public var method: String
  public var path: String
  public var headers: [String: String]
  public var body: Data
  public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
    self.method = method
    self.path = path
    self.headers = headers
    self.body = body
  }
}

public struct ProxyHTTPResponse: Sendable {
  public var status: Int
  public var contentType: String
  public var body: Data
  public var stream: AsyncThrowingStream<Data, Error>?
  public init(
    status: Int = 200, contentType: String = "application/json", body: Data = Data(),
    stream: AsyncThrowingStream<Data, Error>? = nil
  ) {
    self.status = status
    self.contentType = contentType
    self.body = body
    self.stream = stream
  }
  public static func json(_ value: JSONValue, status: Int = 200) -> Self {
    Self(status: status, body: (try? JSONEncoder().encode(value)) ?? Data())
  }
  public static func error(_ message: String, status: Int = 400) -> Self {
    .json(
      .object([
        "error": .object(["message": .string(message), "type": .string("invalid_request_error")])
      ]), status: status)
  }
}

/// A one-request-per-connection HTTP host; audio streams use HTTP chunk framing.
public enum OpenAIHTTPServer {
  public typealias Handler = @Sendable (ProxyHTTPRequest) async -> ProxyHTTPResponse
  public static func serve(
    host: String = "127.0.0.1", port: Int = 11435,
    handler: @escaping Handler, onListening: @escaping @Sendable () -> Void = {}
  ) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
      let channel = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
          channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            channel.pipeline.addHandler(ProxyConnection(handler: handler))
          }
        }.bind(host: host, port: port).get()
      onListening()
      try await withTaskCancellationHandler {
        try await channel.closeFuture.get()
      } onCancel: {
        channel.close(promise: nil)
      }
      try await group.shutdownGracefully()
    } catch {
      try? await group.shutdownGracefully()
      throw error
    }
  }
}

private final class ProxyConnection: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let handler: OpenAIHTTPServer.Handler
  var head: HTTPRequestHead?
  var body = Data()
  var processing = false
  var task: Task<Void, Never>?
  init(handler: @escaping OpenAIHTTPServer.Handler) { self.handler = handler }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !processing else { return }
    switch unwrapInboundIn(data) {
    case .head(let head):
      self.head = head
      if head.headers.first(name: "expect")?.lowercased() == "100-continue" {
        context.writeAndFlush(
          wrapOutboundOut(.head(.init(version: head.version, status: .continue))), promise: nil)
      }
    case .body(var bytes):
      guard body.count + bytes.readableBytes <= 25 * 1024 * 1024 else {
        processing = true
        respond(.error("Audio upload exceeds 25 MiB.", status: 413), channel: context.channel)
        return
      }
      body.append(contentsOf: bytes.readBytes(length: bytes.readableBytes) ?? [])
    case .end:
      guard let head else { return }
      processing = true
      var headers: [String: String] = [:]
      for (key, value) in head.headers { headers[key.lowercased()] = value }
      let request = ProxyHTTPRequest(
        method: head.method.rawValue, path: head.uri, headers: headers, body: body)
      let channel = context.channel
      let handler = self.handler
      task = Task {
        let response = await handler(request)
        await Self.send(response, channel: channel, version: head.version)
      }
    }
  }
  private func respond(_ response: ProxyHTTPResponse, channel: any Channel) {
    task = Task { await Self.send(response, channel: channel) }
  }
  private static func send(
    _ response: ProxyHTTPResponse, channel: any Channel, version: HTTPVersion = .http1_1
  ) async {
    do {
      var headers = HTTPHeaders([("content-type", response.contentType), ("connection", "close")])
      if response.stream == nil {
        headers.add(name: "content-length", value: String(response.body.count))
      } else if version == .http1_1 {
        headers.add(name: "transfer-encoding", value: "chunked")
      }
      try await channel.writeAndFlush(
        HTTPServerResponsePart.head(
          .init(
            version: version,
            status: .init(statusCode: response.status), headers: headers))
      ).get()
      if !response.body.isEmpty {
        try await write(response.body, channel: channel)
      }
      if let stream = response.stream {
        for try await chunk in stream {
          try Task.checkCancellation()
          if !chunk.isEmpty { try await write(chunk, channel: channel) }
        }
      }
      try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
    } catch { /* A disconnected consumer cancels the producer through channelInactive. */  }
    channel.close(promise: nil)
  }
  private static func write(_ data: Data, channel: any Channel) async throws {
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
  }
  func channelInactive(context: ChannelHandlerContext) {
    task?.cancel()
    task = nil
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
