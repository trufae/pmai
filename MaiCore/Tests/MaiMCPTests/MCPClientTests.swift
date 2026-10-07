import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import MaiCore
@testable import MaiMCP

@testable import MaiTestSupport

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
