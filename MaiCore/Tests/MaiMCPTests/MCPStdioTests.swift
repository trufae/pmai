#if !os(iOS)
  import Foundation
  import Testing

  @testable import MaiCore
  @testable import MaiMCP

  @Test("Stdio MCP configuration uses the conventional command, args, env, and cwd fields")
  func stdioMCPConfiguration() throws {
    let data = Data(
      #"""
      {
        "id": "local-tools",
        "command": "example-mcp",
        "args": ["--mode", "stdio"],
        "env": {"MCP_TOKEN": "configured", "OVERRIDE": "new"},
        "cwd": "."
      }
      """#.utf8)
    let configured = try JSONDecoder().decode(ConfiguredMCPServer.self, from: data)

    #expect(configured.kind == "stdio")
    #expect(configured.command == "example-mcp")
    #expect(configured.args == ["--mode", "stdio"])
    let resolved = try configured.resolvedStdio(
      environment: ["PATH": "/usr/bin:/bin", "OVERRIDE": "old"])
    #expect(resolved.command == "example-mcp")
    #expect(resolved.environment["PATH"] == "/usr/bin:/bin")
    #expect(resolved.environment["MCP_TOKEN"] == "configured")
    #expect(resolved.environment["OVERRIDE"] == "new")
    #expect(resolved.workingDirectory != nil)
  }

  @Test("Stdio MCP launches a process, discovers tools, and calls them")
  func stdioMCPClient() async throws {
    let script = #"""
      while IFS= read -r line
      do
        case "$line" in
          *notifications*initialized*)
            ;;
          *'initialize'*)
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"Stdio Fixture"}}}'
            ;;
          *tools*list*)
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"lookup","description":"Lookup","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}]}}'
            ;;
          *resources*list*)
            printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"resources":[]}}'
            ;;
          *tools*call*)
            printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"stdio result"}],"structuredContent":{"count":1}}}'
            ;;
          *)
            printf 'unexpected input: %s\n' "$line" >&2
            ;;
        esac
      done
      """#
    let client = MCPStdioClient(
      configuration: MCPStdioServerConfiguration(
        id: "fixture",
        command: "/bin/sh",
        args: ["-c", script],
        environment: ProcessInfo.processInfo.environment,
        timeout: 2))

    do {
      let catalog = try await client.connect()
      #expect(catalog.serverName == "Stdio Fixture")
      #expect(catalog.tools.map(\.name) == ["fixture::lookup"])
      let tool = try #require(
        try await client.agentTools().first { $0.definition.name == "fixture::lookup" })
      let output = try await tool.call(
        arguments: .object(["query": .string("test")]),
        context: ToolExecutionContext(
          run: AgentEventContext(
            runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
          modelTurn: 1))
      #expect(output.text == "stdio result")
      #expect(output.structuredContent == .object(["count": .integer(1)]))
    } catch {
      await client.close()
      throw error
    }
    await client.close()
  }
#endif
