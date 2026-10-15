import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import MaiCore
@testable import MaiMCP

@testable import MaiTestSupport

@Test("HTTP MCP defaults apply to legacy configuration and preserve explicit timeouts")
func mcpDefaultTimeoutConfiguration() throws {
  let url = try #require(URL(string: "https://mcp-timeout.example.test/mcp"))
  #expect(MCPServerConfiguration(id: "direct", url: url).timeout == 180)
  var configured = try JSONDecoder().decode(
    ConfiguredMCPServer.self,
    from: Data(#"{"id":"legacy","url":"https://mcp-timeout.example.test/mcp"}"#.utf8))
  #expect(try configured.resolved(environment: [:]).timeout == 180)
  configured.timeout = 300
  #expect(try configured.resolved(environment: [:]).timeout == 300)
}

@Test(
  "HTTP MCP retains partial progress on failure and returns completed results",
  arguments: ["timeout", "ended", "complete"])
func mcpHTTPPartialOutput(scenario: String) async throws {
  let timesOut = scenario == "timeout"
  let completes = scenario == "complete"
  let host = "partial-\(scenario).example.test"
  StubURLProtocol.install(forHost: host) { request in
    let body = try jsonObject(try requestBodyData(request))
    let method = try #require(body["method"] as? String)
    let id = body["id"] as? Int
    switch method {
    case "initialize":
      return try httpResponse(
        request, contentType: "application/json",
        body: rpc(
          id: id,
          result: #"{"protocolVersion":"2025-11-25","serverInfo":{"name":"Partial fixture"}}"#))
    case "notifications/initialized":
      return try httpResponse(request, status: 202, contentType: "application/json", body: "")
    case "tools/call":
      let params = try #require(body["params"] as? [String: Any])
      let meta = try #require(params["_meta"] as? [String: Any])
      #expect(meta["progressToken"] as? Int == id)
      let progress = """
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":\(id ?? 0),"progress":1,"message":"Invoice INV-42: EUR 19.00"}}

        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":-1,"progress":1,"message":"unrelated request"}}

        """
      var stream = (timesOut ? "id: progress-event\nretry: 5000\n" : "") + progress + "\n"
      if completes {
        stream += "data: " + rpc(
          id: id, result: #"{"content":[{"type":"text","text":"completed result"}]}"#) + "\n\n"
        stream = stream.replacingOccurrences(of: "\n", with: "\r\n")
      } else if !timesOut {
        stream = stream.replacingOccurrences(of: "\n", with: "\r")
      }
      return try httpResponse(
        request, contentType: "text/event-stream",
        body: stream)
    default:
      throw TestError.missingResponse
    }
  }
  defer { StubURLProtocol.reset(host: host) }
  let client = MCPClient(
    configuration: MCPServerConfiguration(
      id: host, url: try #require(URL(string: "https://\(host)/mcp")), timeout: 1),
    session: stubSession())
  do {
    let output = try await client.callTool(name: "lookup", arguments: .object([:]))
    if completes {
      #expect(!output.isError)
      #expect(output.text == "completed result")
      #expect(output.structuredContent == nil)
      await client.close()
      return
    }
    #expect(output.isError)
    #expect(output.structuredContent?.objectValue?["partial"] == .bool(true))
    #expect(output.text.contains("Invoice INV-42: EUR 19.00"))
    #expect(output.text.contains("Incomplete MCP output"))
    #expect(!output.text.contains("unrelated request"))
  } catch {
    await client.close()
    throw error
  }
  await client.close()
}

@Test("MCP partial output is bounded and explicit cancellation stays a cancellation")
func mcpPartialOutputBounds() throws {
  var output = MCPPartialOutput()
  output.record(
    method: "notifications/progress",
    params: [
      "message": .string(String(repeating: "invoice ", count: 20_000))
    ])
  let failure = try #require(output.preserving(URLError(.timedOut)) as? MCPPartialOutputError)
  #expect(failure.toolOutput.text.utf8.count < 66_000)
  #expect(failure.toolOutput.text.contains("partial output truncated"))
  #expect(output.preserving(CancellationError()) is CancellationError)
}

@Test("MCP registration enables all server tools and ignores stale tool references")
func mcpToolsAreEnabledAsAGroup() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("enabled"), stopReason: .stop),
    ProviderResponse(message: .assistant("disabled"), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let catalog = try await runtime.register(mcp: FixtureMCPSource())

  #expect(Set(catalog.tools.map(\.name)) == ["r2mcp::analyze", "r2mcp::disassemble"])
  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("inspect")],
      toolNames: ["--::obsolete_tool"]))

  let removed = await runtime.unregisterMCP(serverID: "r2mcp")
  #expect(removed == ["r2mcp::analyze", "r2mcp::disassemble"])
  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("inspect again")],
      toolNames: ["r2mcp::analyze"]))

  let requests = await provider.requests
  #expect(requests.count == 2)
  #expect(
    Set(requests[0].tools.map(\.name)) == ["r2mcp::analyze", "r2mcp::disassemble"])
  #expect(requests[1].tools.isEmpty)
}

@Test("MCP client negotiates, catalogs, and preserves structured tool content")
func mcpClient() async throws {
  let recorder = MethodRecorder()
  StubURLProtocol.install(forHost: "mcp.example.test") { request in
    let body = try jsonObject(try requestBodyData(request))
    let method = try #require(body["method"] as? String)
    recorder.record(method)
    let id = body["id"] as? Int
    let payload: String
    switch method {
    case "initialize":
      payload = rpc(
        id: id,
        result: """
          {"protocolVersion":"2025-11-25","serverInfo":{"name":"Fixture"}}
          """)
    case "notifications/initialized":
      payload = ""
    case "tools/list":
      payload = rpc(
        id: id,
        result: """
          {"tools":[{"name":"lookup","description":"Lookup","inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]},"annotations":{"readOnlyHint":true}}]}
          """)
    case "resources/list":
      payload = rpc(
        id: id,
        result: """
          {"resources":[{"uri":"fixture://readme","name":"Readme","mimeType":"text/plain"}]}
          """)
    case "tools/call":
      payload = rpc(
        id: id,
        result: """
          {"content":[{"type":"text","text":"found"},{"type":"image","data":"AQI=","mimeType":"image/png"}],"structuredContent":{"count":1},"isError":false}
          """)
    default:
      payload = rpc(id: id, result: "{}")
    }
    return try httpResponse(
      request,
      contentType: "application/json",
      body: payload,
      headers: method == "initialize" ? ["Mcp-Session-Id": "session-1"] : [:])
  }
  defer { StubURLProtocol.reset(host: "mcp.example.test") }

  let client = MCPClient(
    configuration: MCPServerConfiguration(
      id: "fixture",
      url: try #require(URL(string: "https://mcp.example.test/mcp"))),
    session: stubSession())
  let catalog = try await client.connect()
  #expect(catalog.serverName == "Fixture")
  #expect(catalog.tools.first?.name == "fixture::lookup")
  #expect(catalog.resources.first?.uri == "fixture://readme")
  let agentTools = try await client.agentTools()
  #expect(agentTools.contains { $0.definition.name == "fixture::resources_read" })
  let tool = try #require(agentTools.first)
  let output = try await tool.call(
    arguments: .object(["q": .string("test")]),
    context: ToolExecutionContext(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
      modelTurn: 1))
  #expect(output.content.first == .text("found"))
  #expect(output.content.contains { if case .image = $0 { true } else { false } })
  #expect(output.structuredContent == .object(["count": .integer(1)]))
  #expect(recorder.methods.contains("notifications/initialized"))
  #expect(recorder.methods.contains("tools/call"))
}

private struct FixtureMCPSource: MCPToolSource {
  private var definitions: [ToolDefinition] {
    [
      ToolDefinition(name: "r2mcp::analyze", description: "Analyze a binary"),
      ToolDefinition(name: "r2mcp::disassemble", description: "Disassemble a function"),
    ]
  }

  func connect() async throws -> MCPServerCatalog {
    MCPServerCatalog(
      serverID: "r2mcp",
      serverName: "r2mcp",
      protocolVersion: "2025-03-26",
      tools: definitions,
      resources: [])
  }

  func agentTools() async throws -> [any AgentTool] {
    definitions.map { definition in
      ClosureTool(definition: definition) { _, _ in ToolOutput(text: "ok") }
        as any AgentTool
    }
  }

  func close() async {}
}

/// An orchestrator that delegates one file read, and the worker that performs
/// it. Both carry the file tool; only the orchestrator can start agents, and
/// that is how the fixture tells which side is answering.
@Test("MCP server and member policy applies to discovery, execution, and restricted child scopes")
func mcpToolPolicyExecution() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: "blocked", name: ToolProxy.callName,
        arguments: .object(["name": .string("r2mcp::disassemble"), "arguments": .object([:])]))),
    ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("done"), stopReason: .stop),
    ProviderResponse(message: .assistant("restricted"), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(mcp: FixtureMCPSource())
  var request = AgentRequest(
    provider: "scripted", messages: [.user("analyze")], toolGroupNames: [],
    toolPolicy: .init(groups: ["mcp": .disabled, "mcp/r2mcp": .proxy],
                     tools: ["r2mcp::analyze": .direct, "r2mcp::disassemble": .disabled]))
  let result = try await runtime.run(request)
  #expect(result.transcript.flatMap(\.toolResults).first?.isError == true)
  #expect(await provider.requests.first?.tools.map(\.name) == ["r2mcp::analyze"])
  #expect(await runtime.toolUsageSnapshot().counts.isEmpty)
  request.restrictedToolNames = []
  _ = try await runtime.run(request)
  #expect(await provider.requests.last?.tools.isEmpty == true)
  let groups = await runtime.availableToolGroups()
  #expect(groups.contains { $0.catalogID == "mcp/r2mcp" && $0.toolNames.count == 2 })
}
