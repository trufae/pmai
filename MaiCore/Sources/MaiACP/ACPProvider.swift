import Foundation
import MaiCore

/// A remote ACP agent seen as a MaiCore provider.
///
/// This is the whole trick to "use ACP agents like any other agent": an ACP
/// connection answers `complete` the way an LLM backend does, so an
/// `AgentDefinition` pointing at it flows through `AgentRuntime`, `/agent`,
/// subagents, and delegation with no special cases anywhere else. The external
/// agent's own tools, model, and reasoning live behind the boundary; MaiCore
/// only sees a reply.
public actor ACPProvider: ChatProvider {
  public nonisolated let descriptor: ProviderDescriptor

  private let configuration: ACPClient.Configuration
  private let sessionFile: URL?
  private let onPermission: (@Sendable (JSONValue) async throws -> String?)?
  /// One live agent per working directory: a prompt from a child run in a
  /// different cwd must not land in the parent's session.
  private var clients: [String: ACPClient] = [:]
  private var internetAccess = InternetAccessPolicy()

  public init(
    id: ProviderID, displayName: String, configuration: ACPClient.Configuration,
    sessionFile: URL? = nil, onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil
  ) {
    self.descriptor = ProviderDescriptor(
      id: id,
      displayName: displayName,
      // ACP agents stream, and they carry their own tools, so MaiCore never
      // offers them its tool schema — tool calling stays behind the boundary.
      capabilities: [.streaming, .reasoning])
    self.configuration = configuration
    self.sessionFile = sessionFile
    self.onPermission = onPermission
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    // ACP does not enumerate models; the agent picks its own.
    [ModelDescriptor(id: descriptor.id.rawValue, displayName: descriptor.displayName)]
  }

  public func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    guard configuration.webSocketURL == nil || !internetAccess.isOffline else {
      throw InternetAccessError.offline
    }
    let key = clientKey(
      for: configuration.workingDirectory ?? AgentExecutionScope.directory,
      sessionID: request.sessionID ?? AgentExecutionScope.current?.sessionID)
    let client = try client(
      key: key, workingDirectory: configuration.workingDirectory ?? AgentExecutionScope.directory)
    await client.configureInternetAccess(internetAccess)
    // The runtime hands over the whole transcript each turn, but the ACP agent
    // keeps its own session, so only the latest user turn is new to it.
    let text = ACPProvider.latestUserText(request.messages)
    let collector = TextCollector()
    if sessionFile != nil {
      let remoteID = try await client.connect()
      try saveSession(remoteID, key: key)
    }
    let stopReason = try await client.prompt(text) { event in
      if case .textDelta(let delta) = event { await collector.append(delta) }
      await emit(event)
    }
    let answer = await collector.text
    return ProviderResponse(
      message: .assistant(answer),
      usage: nil,
      stopReason: stopReason)
  }

  public func shutdown() async {
    let previous = Array(clients.values)
    clients.removeAll()
    for client in previous { await client.close() }
  }

  public func configureInternetAccess(_ policy: InternetAccessPolicy) async {
    internetAccess = policy
    guard configuration.webSocketURL != nil else { return }
    let current = Array(clients.values)
    if policy.isOffline { clients.removeAll() }
    for client in current { await client.configureInternetAccess(policy) }
  }

  private func clientKey(for workingDirectory: URL?, sessionID: String?) -> String {
    (workingDirectory?.standardizedFileURL.path ?? ".") + "\u{0}" + (sessionID ?? "default")
  }

  private func client(key: String, workingDirectory: URL?) throws -> ACPClient {
    if let existing = clients[key] { return existing }
    var configuration = self.configuration
    if configuration.workingDirectory == nil { configuration.workingDirectory = workingDirectory }
    if let sessionFile, FileManager.default.fileExists(atPath: sessionFile.path) {
      configuration.sessionID = try JSONDecoder().decode(
        [String: String].self,
        from: Data(contentsOf: sessionFile))[key]
    }
    let client = ACPClient(configuration: configuration, onPermission: onPermission)
    clients[key] = client
    return client
  }

  private func saveSession(_ id: String, key: String) throws {
    guard let sessionFile else { return }
    try ACPStateFiles.createDirectory(sessionFile.deletingLastPathComponent())
    let lock = try ACPFileLock(url: sessionFile.appendingPathExtension("lock"), wait: true)
    defer { withExtendedLifetime(lock) {} }
    var sessions: [String: String] = [:]
    if FileManager.default.fileExists(atPath: sessionFile.path) {
      sessions = try JSONDecoder().decode(
        [String: String].self, from: Data(contentsOf: sessionFile))
    }
    sessions[key] = id
    try ACPStateFiles.write(sessions, to: sessionFile)
  }

  /// The last user message, which is the only turn the agent has not seen.
  /// Its own session holds everything before it.
  static func latestUserText(_ messages: [AgentMessage]) -> String {
    if let last = messages.last(where: { $0.role == .user }) {
      let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { return text }
    }
    return messages.last?.text ?? ""
  }
}

/// Accumulates streamed deltas into the authoritative final answer.
private actor TextCollector {
  private(set) var text = ""
  func append(_ delta: String) { text += delta }
}

/// Registers the ACP provider factory, so a `kind: "acp"` provider in the
/// configuration builds an `ACPProvider` like any other backend.
public struct MaiACPPlugin: MaiPlugin {
  private let onPermission: (@Sendable (JSONValue, String) async throws -> String?)?
  public let manifest = PluginManifest(
    id: "org.mai.acp",
    displayName: "ACP agent provider",
    version: "1.0.0",
    capabilities: [.chatProvider])

  public init(onPermission: (@Sendable (JSONValue, String) async throws -> String?)? = nil) {
    self.onPermission = onPermission
  }

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      providerFactory: ACPConfiguredProviderFactory(onPermission: onPermission), from: manifest.id)
  }
}

/// Builds `ACPProvider`s from configuration. An ACP provider stores its command
/// line in `options`, so no new configuration schema is needed:
///
///     { "id": "gemini", "kind": "acp",
///       "options": { "command": "gemini", "args": ["--acp"],
///                    "permission": "auto" } }
public struct ACPConfiguredProviderFactory: ConfiguredProviderFactory {
  private let onPermission: (@Sendable (JSONValue, String) async throws -> String?)?
  public static let providerKind: ConfiguredProviderKind = "acp"
  public let kind = ACPConfiguredProviderFactory.providerKind

  public init(onPermission: (@Sendable (JSONValue, String) async throws -> String?)? = nil) {
    self.onPermission = onPermission
  }

  public func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    let options = configuration.options
    let url: URL?
    if let address = options["url"]?.stringValue {
      guard let parsed = URL(string: address) else {
        throw JSONRPCError.invalidParams("Invalid ACP WebSocket URL")
      }
      try ACPRemoteConnection.validate(url: parsed)
      guard options["remoteCwd"]?.stringValue?.hasPrefix("/") == true else {
        throw JSONRPCError.invalidParams(
          "WebSocket ACP providers require an absolute options.remoteCwd")
      }
      url = parsed
    } else {
      url = nil
    }
    let command = options["command"]?.stringValue ?? (url == nil ? "" : configuration.id)
    guard !command.isEmpty else {
      throw ACPConfigurationError.missingCommand(configuration.id)
    }
    let arguments = options["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
    var childEnvironment = environment
    for (key, value) in options["env"]?.objectValue ?? [:] {
      childEnvironment[key] = value.coercedStringValue
    }
    let permission =
      options["permission"]?.stringValue.flatMap(ACPPermissionPolicy.init(rawValue:)) ?? .auto
    let workingDirectory = options["cwd"]?.stringValue.map {
      URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
    }
    let tokenFile = options["tokenFile"]?.stringValue.map { URL(fileURLWithPath: $0) }
    let storedToken = try tokenFile.map {
      try String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let permissionHandler: (@Sendable (JSONValue) async throws -> String?)?
    if configuration.id.hasPrefix("remote."), let onPermission {
      let name = configuration.displayName ?? configuration.id
      permissionHandler = { try await onPermission($0, name) }
    } else {
      permissionHandler = nil
    }
    return ACPProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? configuration.id,
      configuration: ACPClient.Configuration(
        command: command,
        arguments: arguments,
        environment: childEnvironment,
        workingDirectory: workingDirectory,
        permission: permission,
        promptTimeout: configuration.timeout ?? 600,
        remoteWorkingDirectory: options["remoteCwd"]?.stringValue,
        readClientFiles: options["readClientFiles"]?.boolValue ?? (url == nil),
        webSocketURL: url,
        bearerToken: options["tokenEnv"]?.stringValue.flatMap { environment[$0] }
          ?? options["token"]?.stringValue ?? storedToken),
      sessionFile: options["sessionFile"]?.stringValue.map { URL(fileURLWithPath: $0) },
      onPermission: permissionHandler)
  }
}

public enum ACPConfigurationError: LocalizedError, Equatable, Sendable {
  case missingCommand(String)

  public var errorDescription: String? {
    switch self {
    case .missingCommand(let id):
      "ACP provider '\(id)' needs options.command or options.url."
    }
  }
}
