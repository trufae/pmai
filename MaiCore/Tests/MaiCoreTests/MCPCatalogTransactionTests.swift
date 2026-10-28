import Foundation
import Testing

@testable import MaiCore

private struct CatalogFixture: MCPToolSource {
  var id: String
  var names: [String]
  var requiresInternet: Bool { false }
  func connect() async throws -> MCPServerCatalog {
    MCPServerCatalog(serverID: id, serverName: id, protocolVersion: "test",
      tools: names.map { ToolDefinition(name: $0, description: id) }, resources: [])
  }
  func agentTools() async throws -> [any AgentTool] {
    names.map { name in
      ClosureTool(definition: ToolDefinition(name: name, description: id)) { _, _ in
        ToolOutput(text: name)
      }
    }
  }
  func close() async {}
}

@Test("MCP catalog registration rolls back collisions and tracks replacement ownership")
func mcpCatalogTransaction() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(mcp: CatalogFixture(id: "first", names: ["shared", "old"]))
  do {
    try await runtime.register(mcp: CatalogFixture(id: "second", names: ["new", "shared"]))
    Issue.record("A colliding catalog must fail")
  } catch {}
  #expect(await runtime.availableTools().map(\.name) == ["old", "shared"])
  try await runtime.register(mcp: CatalogFixture(id: "second", names: ["shared"]),
    replacingExistingTools: true)
  await runtime.unregisterMCP(serverID: "first")
  #expect(await runtime.availableTools().map(\.name) == ["shared"])
  try await runtime.register(mcp: CatalogFixture(id: "second", names: ["replacement"]))
  #expect(await runtime.availableTools().map(\.name) == ["replacement"])
  await runtime.unregisterMCP(serverID: "second")
  #expect(await runtime.availableTools().isEmpty)
}

@Test("Replacing an MCP tool directly transfers its ownership")
func mcpDirectReplacement() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(mcp: CatalogFixture(id: "server", names: ["shared"]))
  try await runtime.register(tool: ClosureTool(
    definition: ToolDefinition(name: "shared", description: "native")) { _, _ in
      ToolOutput(text: "native")
    }, replacingExisting: true)
  await runtime.unregisterMCP(serverID: "server")
  #expect(await runtime.availableTools().first?.description == "native")
}
