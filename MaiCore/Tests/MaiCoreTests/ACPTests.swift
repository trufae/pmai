import Foundation
import Testing

@testable import MaiACP
@testable import MaiCore

/// An in-memory transport pair, so two peers can talk without spawning a
/// process. Whatever one end sends, the other end receives.
private final class PipeTransport: JSONRPCTransport, @unchecked Sendable {
  private let outbound: AsyncStream<JSONRPCMessage>.Continuation
  private let inbound: AsyncStream<JSONRPCMessage>
  private let peerContinuation: AsyncStream<JSONRPCMessage>.Continuation

  private init(
    inbound: AsyncStream<JSONRPCMessage>,
    outbound: AsyncStream<JSONRPCMessage>.Continuation,
    peerContinuation: AsyncStream<JSONRPCMessage>.Continuation
  ) {
    self.inbound = inbound
    self.outbound = outbound
    self.peerContinuation = peerContinuation
  }

  static func pair() -> (PipeTransport, PipeTransport) {
    let (aStream, aCont) = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .unbounded)
    let (bStream, bCont) = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .unbounded)
    // a sends into b's stream and reads from a's stream.
    let a = PipeTransport(inbound: aStream, outbound: bCont, peerContinuation: aCont)
    let b = PipeTransport(inbound: bStream, outbound: aCont, peerContinuation: bCont)
    return (a, b)
  }

  func messages() -> AsyncStream<JSONRPCMessage> { inbound }
  func send(_ message: JSONRPCMessage) throws { outbound.yield(message) }
  func close() {
    outbound.finish()
    peerContinuation.finish()
  }
}

@Test("A JSON-RPC message keeps the 2.0 envelope and result/error shape")
func jsonRPCEncoding() throws {
  let request = JSONRPCMessage.request(id: 7, method: "session/prompt", params: .object([:]))
  let requestJSON = try JSONEncoder().encode(request)
  let requestObject = try JSONDecoder().decode(JSONValue.self, from: requestJSON).objectValue
  #expect(requestObject?["jsonrpc"]?.stringValue == "2.0")
  #expect(requestObject?["id"]?.intValue == 7)
  #expect(request.isRequest)

  // A response always carries a result key, even when null.
  let response = JSONRPCMessage.response(id: .integer(7), result: .null)
  let responseObject = try JSONDecoder().decode(
    JSONValue.self, from: JSONEncoder().encode(response)
  ).objectValue
  #expect(responseObject?.keys.contains("result") == true)
  #expect(responseObject?.keys.contains("method") == false)

  let failure = JSONRPCMessage.failure(id: .integer(7), error: .methodNotFound("x"))
  #expect(failure.error?.code == JSONRPCError.methodNotFound)
}

@Test("Two peers exchange requests, replies, and errors over a transport")
func jsonRPCPeerRoundTrip() async throws {
  let (clientTransport, serverTransport) = PipeTransport.pair()
  let server = JSONRPCPeer(
    transport: serverTransport,
    onRequest: { method, params in
      switch method {
      case "echo": return params ?? .null
      default: throw JSONRPCError.methodNotFound(method)
      }
    })
  await server.start()
  let client = JSONRPCPeer(transport: clientTransport)
  await client.start()

  let echoed = try await client.request("echo", params: .string("hi"), timeout: 5)
  #expect(echoed.stringValue == "hi")

  await #expect(throws: JSONRPCError.self) {
    _ = try await client.request("missing", timeout: 5)
  }
  await client.close()
  await server.close()
}

@Test("A stdio transport closed before reading returns a finished stream")
func closedStdioTransportFinishesMessages() async {
  let input = Pipe()
  let output = Pipe()
  let transport = StdioJSONRPCTransport(
    input: input.fileHandleForReading,
    output: output.fileHandleForWriting)

  transport.close()
  var messages = transport.messages().makeAsyncIterator()

  #expect(await messages.next() == nil)
}

@Test("A JSON-RPC request without a reply times out")
func jsonRPCRequestTimeout() async {
  let (clientTransport, serverTransport) = PipeTransport.pair()
  let client = JSONRPCPeer(transport: clientTransport)
  await client.start()

  await #expect(throws: JSONRPCTransportError.timedOut("never")) {
    _ = try await client.request("never", timeout: 0.01)
  }

  await client.close()
  serverTransport.close()
}

@Test("Cancellation cannot overtake JSON-RPC request registration")
func jsonRPCRequestCancellation() async {
  let (clientTransport, serverTransport) = PipeTransport.pair()
  let client = JSONRPCPeer(transport: clientTransport)
  await client.start()
  let request = Task { try await client.request("never") }

  request.cancel()
  await #expect(throws: CancellationError.self) {
    _ = try await request.value
  }

  await client.close()
  serverTransport.close()
}

@Test("ACP content blocks flatten a prompt and read agent updates")
func acpContentBlocks() {
  let prompt: JSONValue = .array([
    .object(["type": .string("text"), "text": .string("summarize")]),
    .object(["type": .string("resource_link"), "name": .string("README"), "uri": .string("f.md")]),
  ])
  #expect(ACP.promptText(prompt) == "summarize\n\nREADME: f.md")

  // Updates carry content as a single block or an array; both read.
  #expect(ACP.ContentBlock.text(from: .object(["text": .string("hi")])) == "hi")
  #expect(
    ACP.ContentBlock.text(
      from: .array([.object(["text": .string("a")]), .object(["text": .string("b")])])) == "ab")

  #expect(ACP.StopReason(.cancelled) == .cancelled)
  #expect(ACP.StopReason.endTurn.providerStopReason == .stop)
}

@Test("The permission policy picks the once option matching the verdict")
func acpPermissionPolicy() {
  let options: [JSONValue] = [
    .object(["optionId": .string("allow_once"), "kind": .string("allow_once")]),
    .object(["optionId": .string("allow_always"), "kind": .string("allow_always")]),
    .object(["optionId": .string("reject_once"), "kind": .string("reject_once")]),
  ]
  #expect(ACPPermissionPolicy.allow.optionID(from: options, kind: "edit") == "allow_once")
  #expect(ACPPermissionPolicy.reject.optionID(from: options, kind: "read") == "reject_once")
  // auto approves read-only kinds and rejects the rest.
  #expect(ACPPermissionPolicy.auto.optionID(from: options, kind: "read") == "allow_once")
  #expect(ACPPermissionPolicy.auto.optionID(from: options, kind: "edit") == "reject_once")
}

@Test("A catalog agent becomes an acp-kind provider record")
func acpCatalog() {
  let gemini = ACPCatalog.agent("gemini")
  #expect(gemini?.command == "gemini")
  let provider = gemini?.configuredProvider()
  #expect(provider?.kind == ACPConfiguredProviderFactory.providerKind)
  #expect(provider?.options["command"]?.stringValue == "gemini")
  #expect(provider?.options["args"]?.arrayValue?.first?.stringValue == "--acp")
  #expect(ACPCatalog.agent("nope") == nil)
}

@Test("pmai's ACP server answers initialize, session/new, and session/prompt")
func acpServerServesARuntime() async throws {
  // A scripted provider stands in for a model; the server should stream its
  // reply as agent_message_chunk and answer session/prompt with a stop reason.
  let provider = ACPScriptedProvider(responses: [
    ProviderResponse(message: .assistant("Hello from pmai"), stopReason: .stop)
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  let agent = AgentDefinition(
    id: "main", instructions: "Be brief.", provider: "scripted", model: "fixture")
  try await runtime.register(agent: agent)

  let (clientTransport, serverTransport) = PipeTransport.pair()
  let server = ACPServer(runtime: runtime, agent: agent, bridge: ACPPermissionBridge())
  let serving = Task { await server.serve(on: serverTransport) }

  let chunks = ChunkRecorder()
  let client = JSONRPCPeer(
    transport: clientTransport,
    onNotification: { method, params in
      guard method == ACP.Method.sessionUpdate else { return }
      let update = params?.objectValue?["update"]?.objectValue
      if update?["sessionUpdate"]?.stringValue == ACP.Update.agentMessageChunk.rawValue {
        await chunks.append(ACP.ContentBlock.text(from: update?["content"]))
      }
    })
  await client.start()

  let initialize = try await client.request(
    ACP.Method.initialize, params: .object(["protocolVersion": .integer(1)]), timeout: 5)
  #expect(initialize.objectValue?["protocolVersion"]?.intValue == 1)
  #expect(initialize.objectValue?["agentInfo"]?.objectValue?["name"]?.stringValue == "pmai")

  let session = try await client.request(
    ACP.Method.sessionNew, params: .object(["cwd": .string("/tmp")]), timeout: 5)
  let sessionID = try #require(session.objectValue?["sessionId"]?.stringValue)

  let result = try await client.request(
    ACP.Method.sessionPrompt,
    params: .object([
      "sessionId": .string(sessionID),
      "prompt": .array([.object(["type": .string("text"), "text": .string("hi")])]),
    ]),
    timeout: 5)
  #expect(result.objectValue?["stopReason"]?.stringValue == ACP.StopReason.endTurn.rawValue)
  #expect(await chunks.joined == "Hello from pmai")

  await client.close()
  serving.cancel()
}

@Test("pmai's MCP server exposes the agent as one prompt tool")
func mcpServerExposesAgent() async throws {
  let provider = ACPScriptedProvider(responses: [
    ProviderResponse(message: .assistant("42"), stopReason: .stop)
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  let agent = AgentDefinition(
    id: "oracle", description: "Answers questions.", instructions: "",
    provider: "scripted", model: "fixture")
  try await runtime.register(agent: agent)

  let (clientTransport, serverTransport) = PipeTransport.pair()
  let server = MCPAgentServer(runtime: runtime, agent: agent)
  let serving = Task { await server.serve(on: serverTransport) }
  let client = JSONRPCPeer(transport: clientTransport)
  await client.start()

  _ = try await client.request("initialize", timeout: 5)
  let tools = try await client.request("tools/list", timeout: 5)
  let tool = try #require(tools.objectValue?["tools"]?.arrayValue?.first?.objectValue)
  #expect(tool["name"]?.stringValue == "oracle")
  #expect(tool["description"]?.stringValue == "Answers questions.")

  let call = try await client.request(
    "tools/call",
    params: .object([
      "name": .string("oracle"),
      "arguments": .object(["prompt": .string("what is the answer?")]),
    ]),
    timeout: 5)
  let text = call.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
  #expect(text == "42")

  await client.close()
  serving.cancel()
}

private actor ACPScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "scripted", displayName: "Scripted", capabilities: [.streaming, .nativeToolCalling])
  private var responses: [ProviderResponse]
  init(responses: [ProviderResponse]) { self.responses = responses }

  func complete(
    _ request: ProviderRequest, emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let response =
      responses.isEmpty ? ProviderResponse(message: .assistant("")) : responses.removeFirst()
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}

private actor ChunkRecorder {
  private var chunks: [String] = []
  func append(_ chunk: String) { chunks.append(chunk) }
  var joined: String { chunks.joined() }
}

@Test("ACP sessions persist across connections, replay history, and hold exclusive leases")
func acpSessionRecovery() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-session-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let agent = AgentDefinition(id: "main", instructions: "", provider: .hello, model: "hello")
  func connection() async -> (JSONRPCPeer, Task<Void, Never>, ChunkRecorder) {
    let (clientTransport, serverTransport) = PipeTransport.pair()
    let server = ACPServer(runtime: runtime, agent: agent, bridge: ACPPermissionBridge(),
      sessionDirectory: root.appendingPathComponent("sessions"), workspaceRoot: root)
    let serving = Task { await server.serve(on: serverTransport) }
    let recorder = ChunkRecorder()
    let client = JSONRPCPeer(transport: clientTransport, onNotification: { _, params in
      let update = params?.objectValue?["update"]?.objectValue
      await recorder.append(ACP.ContentBlock.text(from: update?["content"]))
    })
    await client.start()
    return (client, serving, recorder)
  }
  let (first, firstServer, _) = await connection()
  let initialized = try await first.request("initialize", params: .object(["protocolVersion": .integer(1)]), timeout: 5)
  #expect(initialized.objectValue?["agentCapabilities"]?.objectValue?["loadSession"] == .bool(true))
  let created = try await first.request("session/new", params: .object(["cwd": .string(root.path)]), timeout: 5)
  let id = try #require(created.objectValue?["sessionId"]?.stringValue)
  _ = try await first.request("session/prompt", params: .object([
    "sessionId": .string(id), "prompt": .array([ACP.ContentBlock.text("remember this").json])
  ]), timeout: 5)
  let (second, secondServer, replay) = await connection()
  _ = try await second.request("initialize", params: .object(["protocolVersion": .integer(1)]), timeout: 5)
  let load: JSONValue = .object(["sessionId": .string(id), "cwd": .string(root.path)])
  await #expect(throws: JSONRPCError.self) { try await second.request("session/load", params: load, timeout: 5) }
  await first.close()
  await firstServer.value
  _ = try await second.request("session/load", params: load, timeout: 5)
  #expect(await replay.joined.contains("remember this"))
  await #expect(throws: JSONRPCError.self) {
    try await second.request("session/new", params: .object(["cwd": .string("/etc")]), timeout: 5)
  }
  await #expect(throws: JSONRPCError.self) {
    try await second.request("session/load", params: .object(["sessionId": .string("../secret"), "cwd": .string(root.path)]), timeout: 5)
  }
  await second.close()
  await secondServer.value
}

@Test("Concurrent ACP sessions use their own cwd and permission session IDs")
func acpSessionIsolation() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-cwd-\(UUID())")
  let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
  try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let provider = ACPCwdProvider()
  let bridge = ACPPermissionBridge()
  let runtime = AgentRuntime(approvalHandler: bridge.approvalHandler)
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(definition: ToolDefinition(
    name: "cwd", description: "Report the scoped directory", parameters: [],
    annotations: ToolAnnotations(readOnly: true, approval: .confirm))) { _, _ in
      ToolOutput(text: AgentExecutionScope.directory.path)
    })
  let agent = AgentDefinition(id: "main", instructions: "", provider: "cwd-provider", model: "",
    toolNames: ["cwd"])
  let (clientTransport, serverTransport) = PipeTransport.pair()
  let server = ACPServer(runtime: runtime, agent: agent, bridge: bridge)
  let serving = Task { await server.serve(on: serverTransport) }
  let permissions = ACPPermissionRecorder()
  let client = JSONRPCPeer(transport: clientTransport, onRequest: { method, params in
    #expect(method == "session/request_permission")
    let fields = try #require(params?.objectValue)
    let id = try #require(fields["sessionId"]?.stringValue)
    let call = try #require(fields["toolCall"]?.objectValue?["toolCallId"]?.stringValue)
    await permissions.record(id: id, call: call)
    return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("allow_once")])])
  })
  await client.start()
  _ = try await client.request("initialize", params: .object(["protocolVersion": .integer(1)]), timeout: 5)
  var ids: [String] = []
  for directory in [left, right] {
    let session = try await client.request("session/new", params: .object(["cwd": .string(directory.path)]), timeout: 5)
    ids.append(try #require(session.objectValue?["sessionId"]?.stringValue))
  }
  try await withThrowingTaskGroup(of: Void.self) { group in
    for id in ids {
      group.addTask {
        _ = try await client.request("session/prompt", params: .object([
          "sessionId": .string(id), "prompt": .array([ACP.ContentBlock.text(id).json])
        ]), timeout: 5)
      }
    }
    try await group.waitForAll()
  }
  #expect(await permissions.calls == Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }))
  let outputs = await provider.outputs
  #expect(outputs[ids[0]] == left.resolvingSymlinksInPath().path)
  #expect(outputs[ids[1]] == right.resolvingSymlinksInPath().path)
  await client.close()
  await serving.value
}

private actor ACPPermissionRecorder {
  var calls: [String: String] = [:]
  func record(id: String, call: String) { calls[id] = call }
}

private actor ACPCwdProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(id: "cwd-provider", displayName: "Cwd", capabilities: [.nativeToolCalling])
  var outputs: [String: String] = [:]
  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    let id = request.messages.last(where: { $0.role == .user })!.text
    if let result = request.messages.flatMap(\.toolResults).last {
      outputs[id] = result.text
      return ProviderResponse(message: .assistant("done"), stopReason: .stop)
    }
    return ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: id, name: "cwd", arguments: .object([:])))
    ]), stopReason: .toolCall)
  }
}
