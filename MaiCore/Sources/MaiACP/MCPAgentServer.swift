import Foundation
import MaiCore

/// Exposes a MaiCore agent to any MCP client as a single tool, so an editor or
/// another agent can call pmai the way it calls any other MCP server. It shares
/// the JSON-RPC transport with the ACP side; only the method vocabulary differs.
///
/// One tool, `<agent>` (or `ask`), takes a `prompt` and returns the agent's
/// reply. The agent's own tools run behind the boundary.
public actor MCPAgentServer {
  public static let protocolVersion = "2025-06-18"

  private let runtime: AgentRuntime
  private let agent: AgentDefinition
  private let toolName: String

  public init(runtime: AgentRuntime, agent: AgentDefinition) {
    self.runtime = runtime
    self.agent = agent
    // MCP tool names allow letters, digits, _, -; fall back to "ask".
    let sanitized = agent.id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    self.toolName = sanitized.isEmpty ? "ask" : sanitized
  }

  public func serve(on transport: any JSONRPCTransport) async {
    let peer = JSONRPCPeer(
      transport: transport,
      onRequest: { [weak self] method, params in
        guard let self else { throw JSONRPCError.internalError("server is gone") }
        return try await self.handle(method: method, params: params)
      })
    await peer.run()
  }

  private func handle(method: String, params: JSONValue?) async throws -> JSONValue {
    switch method {
    case "initialize":
      return .object([
        "protocolVersion": .string(Self.protocolVersion),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object([
          "name": .string("pmai"), "version": .string("1.0.0"),
        ]),
      ])
    case "tools/list":
      return .object(["tools": .array([toolDefinition])])
    case "tools/call":
      return try await callTool(params: params)
    case "ping":
      return .object([:])
    default:
      throw JSONRPCError.methodNotFound(method)
    }
  }

  private var toolDefinition: JSONValue {
    let description =
      agent.description.isEmpty
      ? "Ask the pmai agent '\(agent.id)' and return its reply." : agent.description
    return .object([
      "name": .string(toolName),
      "description": .string(description),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "prompt": .object([
            "type": .string("string"),
            "description": .string("What to ask the agent."),
          ])
        ]),
        "required": .array([.string("prompt")]),
      ]),
    ])
  }

  private func callTool(params: JSONValue?) async throws -> JSONValue {
    guard params?.objectValue?["name"]?.stringValue == toolName else {
      throw JSONRPCError.invalidParams("unknown tool")
    }
    let prompt =
      params?.objectValue?["arguments"]?.objectValue?["prompt"]?.stringValue ?? ""
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw JSONRPCError.invalidParams("prompt is required")
    }
    var messages = AgentChat.initialHistory(for: agent)
    messages.append(.user(prompt))
    let request = AgentRequest(
      agentID: agent.id,
      provider: agent.provider,
      model: agent.model,
      messages: messages,
      toolNames: agent.toolNames,
      toolGroupNames: agent.toolGroupNames,
      subagentNames: agent.subagentNames,
      options: agent.options,
      limits: agent.limits,
      stream: false,
      toolCallingStrategy: agent.toolCallingStrategy,
      useToolProxy: agent.useToolProxy,
      proxyExposedTools: agent.proxyExposedTools,
      toolPolicy: agent.toolPolicy,
      toolDelegation: agent.toolDelegation)
    do {
      let result = try await runtime.run(request)
      var text = result.response.text
      if let interruption = result.interruption {
        text += (text.isEmpty ? "" : "\n\n") + "[stopped: \(interruption.summary)]"
      }
      return .object([
        "content": .array([
          .object(["type": .string("text"), "text": .string(text)])
        ])
      ])
    } catch {
      return .object([
        "content": .array([
          .object([
            "type": .string("text"), "text": .string("Error: \(error.localizedDescription)"),
          ])
        ]),
        "isError": .bool(true),
      ])
    }
  }
}
