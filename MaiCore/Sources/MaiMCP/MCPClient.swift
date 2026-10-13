import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// An agent-facing MCP client built on the shared Streamable HTTP transport.
public actor MCPClient: MCPToolSource {
  public let configuration: MCPServerConfiguration
  private let session: URLSession
  private var catalog: MCPServerCatalog?

  public init(
    configuration: MCPServerConfiguration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
  }

  public func connect() async throws -> MCPServerCatalog {
    if let catalog { return catalog }
    let remote = try await MCPStreamableHTTPTransport.fetchCatalog(
      server: configuration,
      session: session)
    let value = MCPServerCatalog(
      serverID: configuration.id,
      serverName: remote.serverName,
      protocolVersion: remote.protocolVersion ?? "2025-11-25",
      tools: remote.tools.map(canonicalDefinition),
      resources: remote.resources)
    catalog = value
    return value
  }

  public func agentTools() async throws -> [any AgentTool] {
    let catalog = try await connect()
    var tools: [any AgentTool] = catalog.tools.map { definition in
      MCPRemoteTool(
        definition: definition,
        remoteName: remoteName(for: definition.name),
        client: self)
    }
    if !catalog.resources.isEmpty {
      tools.append(
        MCPResourceReadTool(
          definition: ToolDefinition(
            name: "\(namespace)::resources_read",
            description: "Read one resource exposed by \(configuration.displayName).",
            inputSchema: .object([
              "type": .string("object"),
              "properties": .object([
                "uri": .object([
                  "type": .string("string"),
                  "enum": .array(catalog.resources.map { .string($0.uri) }),
                ])
              ]),
              "required": .array([.string("uri")]),
              "additionalProperties": .bool(false),
            ]),
            annotations: ToolAnnotations(
              readOnly: true,
              idempotent: true,
              openWorld: true,
              approval: configuration.defaultApproval, requiresInternet: true)),
          client: self))
    }
    return tools
  }

  public func listResources() async throws -> [MCPResourceDescriptor] {
    try await connect().resources
  }

  public func readResource(uri: String) async throws -> [ContentPart] {
    try await MCPStreamableHTTPTransport.readResource(
      server: configuration,
      uri: uri,
      session: session)
  }

  public func callTool(name: String, arguments: JSONValue) async throws -> ToolOutput {
    try await MCPStreamableHTTPTransport.callTool(
      server: configuration,
      name: remoteName(for: name),
      arguments: arguments,
      session: session)
  }

  public func close() async {
    catalog = nil
    await MCPStreamableHTTPTransport.resetSession(for: configuration.id, session: session)
  }

  public static func isAvailabilityFailure(_ error: Error) -> Bool {
    MCPStreamableHTTPTransport.isAvailabilityFailure(error)
  }

  private var namespace: String {
    let prefix = configuration.toolNamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.flatMap { $0.isEmpty ? nil : $0 } ?? configuration.id
  }

  private func canonicalDefinition(_ definition: ToolDefinition) -> ToolDefinition {
    var definition = definition
    definition.name = "\(namespace)::\(definition.name)"
    return definition
  }

  private func remoteName(for canonicalName: String) -> String {
    guard let separator = canonicalName.range(of: "::") else { return canonicalName }
    return String(canonicalName[separator.upperBound...])
  }
}

private struct MCPRemoteTool: AgentTool {
  let definition: ToolDefinition
  let remoteName: String
  let client: MCPClient

  func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    try await client.callTool(name: remoteName, arguments: arguments)
  }
}

private struct MCPResourceReadTool: AgentTool {
  let definition: ToolDefinition
  let client: MCPClient

  func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    guard let uri = arguments.objectValue?["uri"]?.stringValue else {
      return ToolOutput(text: "Missing resource URI.", isError: true)
    }
    return ToolOutput(content: try await client.readResource(uri: uri))
  }
}

public enum MCPClientError: LocalizedError, Equatable, Sendable {
  case invalidURL(String)
  case invalidResponse(String)
  case httpError(statusCode: Int, message: String)
  case rpcError(code: Int?, message: String)

  public var errorDescription: String? {
    switch self {
    case .invalidURL(let value):
      "Invalid MCP URL: \(value)"
    case .invalidResponse(let message):
      message
    case .httpError(let statusCode, let message):
      "MCP returned HTTP \(statusCode): \(message)"
    case .rpcError(let code, let message):
      "MCP error\(code.map { " \($0)" } ?? ""): \(message)"
    }
  }
}

public struct MaiMCPPlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.mcp",
    displayName: "Mai MCP",
    version: "1.0.0",
    capabilities: [.mcpToolSource])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      mcpFactory: StreamableHTTPMCPFactory(),
      from: manifest.id)
    #if !os(iOS)
      try await registry.register(
        mcpFactory: StdioMCPFactory(),
        from: manifest.id)
    #endif
  }
}

public struct StreamableHTTPMCPFactory: ConfiguredMCPToolSourceFactory {
  public let kind = "streamable-http"

  public init() {}

  public func makeMCPToolSource(
    from configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) throws -> any MCPToolSource {
    MCPClient(configuration: try configuration.resolved(environment: environment))
  }
}
