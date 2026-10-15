#if !os(iOS)
  import Foundation
  import Testing

  @testable import MaiCore
  @testable import MaiMCP
  @testable import MaiTestSupport

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
    #expect(resolved.timeout == 180)
    #expect(MCPStdioServerConfiguration(id: "direct", command: "example-mcp").timeout == 180)
    var overridden = configured
    overridden.timeout = 300
    #expect(try overridden.resolvedStdio(environment: [:]).timeout == 300)
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

  @Test(
    "Stdio partial output reaches the next model turn after timeout or process exit",
    arguments: [false, true])
  func stdioMCPPartialOutput(exits: Bool) async throws {
    let fixture = try stdioFailureFixture(exits: exits)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let client = fixture.client
    do {
      let provider = ScriptedProvider(responses: [
        ProviderResponse(
          message: AgentMessage(
            role: .assistant,
            content: [
              .toolCall(ToolCall(id: "invoice", name: "fixture::lookup", arguments: .object([:])))
            ]), stopReason: .toolCall),
        ProviderResponse(message: .assistant("Used the partial invoice data."), stopReason: .stop),
      ])
      let runtime = AgentRuntime()
      try await runtime.register(provider)
      try await runtime.register(mcp: client)
      _ = try await runtime.run(
        AgentRequest(provider: "scripted", messages: [.user("Find the invoice.")]))

      let requests = await provider.requests
      #expect(requests.count == 2)
      let result = try #require(requests.last?.messages.flatMap(\.toolResults).first)
      #expect(result.isError)
      #expect(result.structuredContent?.objectValue?["partial"] == .bool(true))
      #expect(result.text.contains("Invoice INV-42: EUR 19.00"))
      #expect(result.text.contains("[server log] Read one matching email"))
      #expect(result.text.contains("Incomplete MCP output"))
      #expect(!result.text.contains("unrelated request"))

      if !exits {
        #expect(result.text.contains("timed out"))
        #expect(result.text.contains("[stderr diagnostics]"))
        let next = try await client.callTool(name: "lookup", arguments: .object([:]))
        #expect(!next.isError)
        #expect(next.text == "next request succeeded")
        let messages = try stdioCapturedMessages(at: fixture.capture)
        let cancelled = try #require(
          messages.first { $0["method"]?.stringValue == "notifications/cancelled" })
        #expect(cancelled["id"] == nil)
        #expect(cancelled["params"]?.objectValue?["requestId"] == .integer(4))
        let call = try #require(messages.first { $0["method"]?.stringValue == "tools/call" })
        #expect(call["params"]?.objectValue?["_meta"]?.objectValue?["progressToken"] == .integer(4))
      }
    } catch {
      await client.close()
      throw error
    }
    await client.close()
  }

  @Test("Cancelling a stdio tool notifies the server and keeps client cancellation intact")
  func stdioMCPCancellation() async throws {
    let fixture = try stdioFailureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let client = fixture.client
    do {
      _ = try await client.connect()
      let call = Task { try await client.callTool(name: "lookup", arguments: .object([:])) }
      let deadline = ContinuousClock.now + .seconds(5)
      while !(try stdioCapturedMessages(at: fixture.capture)).contains(where: {
        $0["method"]?.stringValue == "tools/call"
      }) {
        guard ContinuousClock.now < deadline else {
          call.cancel()
          throw TestError.missingResponse
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      call.cancel()
      await #expect(throws: CancellationError.self) { try await call.value }
      let next = try await client.callTool(name: "lookup", arguments: .object([:]))
      #expect(next.text == "next request succeeded")
      let messages = try stdioCapturedMessages(at: fixture.capture)
      let cancelled = try #require(
        messages.first { $0["method"]?.stringValue == "notifications/cancelled" })
      #expect(cancelled["params"]?.objectValue?["requestId"] == .integer(4))
    } catch {
      await client.close()
      throw error
    }
    await client.close()
  }

  @Test("An initialize timeout never sends an MCP cancellation notification")
  func stdioMCPInitializeTimeout() async throws {
    let fixture = try stdioFailureFixture(hangInitialize: true)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    await #expect(throws: MCPStdioTransportError.self) { try await fixture.client.connect() }
    let messages = try stdioCapturedMessages(at: fixture.capture)
    #expect(messages.count == 1)
    #expect(messages.first?["method"]?.stringValue == "initialize")
    await fixture.client.close()
  }

  private func stdioCapturedMessages(at url: URL) throws -> [[String: JSONValue]] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
    }
  }

  private func stdioFailureFixture(exits: Bool = false, hangInitialize: Bool = false) throws
    -> (client: MCPStdioClient, directory: URL, capture: URL)
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let capture = directory.appendingPathComponent("requests.jsonl")
    let script = #"""
      first=1
      while IFS= read -r line
      do
        printf '%s\n' "$line" >> "$MCP_CAPTURE"
        case "$line" in
          *notifications*initialized*) ;;
          *notifications*cancelled*)
            printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"late response must be ignored"}]}}'
            ;;
          *'initialize'*)
            if [ "$MCP_HANG_INITIALIZE" != 1 ]; then
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}'
            fi
            ;;
          *tools*list*)
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"lookup","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}]}}'
            ;;
          *resources*list*)
            printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"resources":[]}}'
            ;;
          *tools*call*)
            if [ "$first" = 1 ]; then
              first=0
              printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":4,"progress":1,"message":"Invoice INV-42: EUR 19.00"}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":999,"progress":1,"message":"unrelated request"}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Read one matching email"}}'
              printf '%s\n' 'Mail server diagnostic' >&2
              if [ "$MCP_EXIT" = 1 ]; then sleep 0.1; exit 7; fi
            else
              printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"next request succeeded"}]}}'
            fi
            ;;
        esac
      done
      """#
    var environment = ProcessInfo.processInfo.environment
    environment["MCP_CAPTURE"] = capture.path
    environment["MCP_EXIT"] = exits ? "1" : "0"
    environment["MCP_HANG_INITIALIZE"] = hangInitialize ? "1" : "0"
    let client = MCPStdioClient(
      configuration: MCPStdioServerConfiguration(
        id: "fixture", command: "/bin/sh", args: ["-c", script], environment: environment,
        timeout: 1, defaultApproval: .automatic))
    return (client, directory, capture)
  }
#endif
