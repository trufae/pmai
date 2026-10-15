import Foundation

public struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
  public static let defaultTimeout: TimeInterval = 180

  public var id: String
  public var displayName: String
  public var url: URL
  public var headers: [String: String]
  public var timeout: TimeInterval
  public var toolNamePrefix: String?
  public var defaultApproval: ToolApprovalRequirement

  public init(
    id: String,
    displayName: String? = nil,
    url: URL,
    headers: [String: String] = [:],
    timeout: TimeInterval = Self.defaultTimeout,
    toolNamePrefix: String? = nil,
    defaultApproval: ToolApprovalRequirement = .confirm
  ) {
    self.id = id
    self.displayName = displayName ?? id
    self.url = url
    self.headers = headers
    self.timeout = max(1, timeout)
    self.toolNamePrefix = toolNamePrefix
    self.defaultApproval = defaultApproval
  }
}

#if !os(iOS)
  public struct MCPStdioServerConfiguration: Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var command: String
    public var args: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var timeout: TimeInterval
    public var toolNamePrefix: String?
    public var defaultApproval: ToolApprovalRequirement

    public init(
      id: String,
      displayName: String? = nil,
      command: String,
      args: [String] = [],
      environment: [String: String] = [:],
      workingDirectory: URL? = nil,
      timeout: TimeInterval = MCPServerConfiguration.defaultTimeout,
      toolNamePrefix: String? = nil,
      defaultApproval: ToolApprovalRequirement = .confirm
    ) {
      self.id = id
      self.displayName = displayName ?? id
      self.command = command
      self.args = args
      self.environment = environment
      self.workingDirectory = workingDirectory
      self.timeout = max(1, timeout)
      self.toolNamePrefix = toolNamePrefix
      self.defaultApproval = defaultApproval
    }
  }
#endif

public struct MCPResourceDescriptor: Codable, Equatable, Identifiable, Sendable {
  public var uri: String
  public var name: String
  public var description: String
  public var mimeType: String?

  public var id: String { uri }

  public init(uri: String, name: String = "", description: String = "", mimeType: String? = nil) {
    self.uri = uri
    self.name = name
    self.description = description
    self.mimeType = mimeType
  }
}

public struct MCPServerCatalog: Codable, Equatable, Sendable {
  public var serverID: String
  public var serverName: String?
  public var protocolVersion: String
  public var tools: [ToolDefinition]
  public var resources: [MCPResourceDescriptor]

  public init(
    serverID: String,
    serverName: String?,
    protocolVersion: String,
    tools: [ToolDefinition],
    resources: [MCPResourceDescriptor]
  ) {
    self.serverID = serverID
    self.serverName = serverName
    self.protocolVersion = protocolVersion
    self.tools = tools
    self.resources = resources
  }
}
