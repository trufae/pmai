import Foundation
import MaiCore
import NIOCore
import NIOHTTP1
import NIOPosix

/// A loopback MCP endpoint for one local ACP session. Only the current turn's
/// tools are callable, through the runtime's normal execution and approval path.
actor ACPToolBridge {
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private var channel: Channel?
  private let path = "/" + UUID().uuidString
  private var tools: [ToolDefinition] = []
  private var execute: ProviderToolScope.Handler?
  private var running: [UUID: Task<ToolResult, Error>] = [:]

  func start() async throws -> JSONValue {
    let path = self.path
    let handle: @Sendable (JSONRPCMessage) async throws -> JSONRPCMessage? = {
      [weak self] message in
      guard let self else { throw JSONRPCError.internalError("Tool bridge closed") }
      return try await self.handle(message)
    }
    let channel = try await ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(
            MCPHTTPHandler(path: path, handle: handle))
        }
      }.bind(host: "127.0.0.1", port: 0).get()
    self.channel = channel
    guard let port = channel.localAddress?.port else {
      throw JSONRPCError.internalError("Cannot bind ACP tools")
    }
    return .object([
      "type": .string("http"), "name": .string("pmai"),
      "url": .string("http://127.0.0.1:\(port)\(path)"), "headers": .array([]),
    ])
  }

  func configure(tools: [ToolDefinition], execute: ProviderToolScope.Handler?) {
    self.tools = tools
    self.execute = execute
    if execute == nil {
      for task in running.values { task.cancel() }
    }
  }

  func close() async {
    configure(tools: [], execute: nil)
    try? await channel?.close()
    channel = nil
    try? await group.shutdownGracefully()
  }

  private func handle(_ message: JSONRPCMessage) async throws -> JSONRPCMessage? {
    guard let id = message.id else { return nil }
    let result: JSONValue
    switch message.method {
    case "initialize":
      result = .object([
        "protocolVersion": .string(MCPAgentServer.protocolVersion),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object(["name": .string("pmai"), "version": .string("1.0.0")]),
      ])
    case "ping": result = .object([:])
    case "tools/list":
      result = .object([
        "tools": .array(
          tools.map {
            .object([
              "name": .string($0.name), "description": .string($0.description),
              "inputSchema": $0.inputSchema,
            ])
          })
      ])
    case "tools/call":
      guard let name = message.params?.objectValue?["name"]?.stringValue,
        tools.contains(where: { $0.name == name }), let execute
      else { throw JSONRPCError.invalidParams("Tool unavailable outside an active pmai turn") }
      let call = ToolCall(
        id: UUID().uuidString, name: name,
        arguments: message.params?.objectValue?["arguments"] ?? .object([:]))
      let taskID = UUID()
      let task = Task { try await execute(call) }
      running[taskID] = task
      defer { running[taskID] = nil }
      let output = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      result = .object([
        "content": .array([.object(["type": .string("text"), "text": .string(output.text)])]),
        "isError": .bool(output.isError),
      ])
    default: throw JSONRPCError.methodNotFound(message.method ?? "")
    }
    return .response(id: id, result: result)
  }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  private let path: String
  private let handle: @Sendable (JSONRPCMessage) async throws -> JSONRPCMessage?
  private var head: HTTPRequestHead?
  private var body = Data()
  private var rejected = false

  init(path: String, handle: @escaping @Sendable (JSONRPCMessage) async throws -> JSONRPCMessage?) {
    self.path = path
    self.handle = handle
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      self.head = head
      body.removeAll(keepingCapacity: true)
      rejected = head.method != .POST || head.uri != path || !head.headers["origin"].isEmpty
    case .body(var buffer):
      if body.count + buffer.readableBytes > 4 * 1024 * 1024 { rejected = true }
      if !rejected, let bytes = buffer.readBytes(length: buffer.readableBytes) {
        body.append(contentsOf: bytes)
      }
    case .end:
      let channel = context.channel
      guard !rejected, head != nil else {
        respond(channel, status: .forbidden, data: Data())
        return
      }
      let bytes = body
      let handle = self.handle
      Task {
        do {
          let message = try JSONDecoder().decode(JSONRPCMessage.self, from: bytes)
          let response: JSONRPCMessage?
          do { response = try await handle(message) } catch {
            response = .failure(
              id: message.id,
              error: (error as? JSONRPCError) ?? .internalError(error.localizedDescription))
          }
          let data = try response.map { try JSONEncoder().encode($0) } ?? Data()
          self.respond(channel, status: response == nil ? .accepted : .ok, data: data)
        } catch {
          self.respond(channel, status: .badRequest, data: Data())
        }
      }
    }
  }

  private func respond(_ channel: Channel, status: HTTPResponseStatus, data: Data) {
    channel.eventLoop.execute {
      var headers = HTTPHeaders()
      headers.add(name: "content-type", value: "application/json")
      headers.add(name: "content-length", value: String(data.count))
      headers.add(name: "connection", value: "close")
      channel.write(
        HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: headers)),
        promise: nil)
      if !data.isEmpty {
        channel.write(
          HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: data))),
          promise: nil)
      }
      channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
        channel.close(promise: nil)
      }
    }
  }
}
