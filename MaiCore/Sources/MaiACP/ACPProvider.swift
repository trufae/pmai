import Foundation
import MaiCore

/// A remote ACP agent seen as a MaiCore provider.
///
/// This is the whole trick to "use ACP agents like any other agent": an ACP
/// connection answers `complete` the way an LLM backend does, so an
/// `AgentDefinition` pointing at it flows through `AgentRuntime`, `/agent`,
/// subagents, and delegation with no special cases anywhere else. The external
/// agent manages its native tool loop. MaiCore selects its model, forwards
/// tool activity, and exposes local runtime tools through MCP.
public actor ACPProvider: ChatProvider {
  public nonisolated let descriptor: ProviderDescriptor

  private let configuration: ACPClient.Configuration
  private let sessionFile: URL?
  private let onPermission: (@Sendable (JSONValue) async throws -> String?)?
  /// One live agent per working directory: a prompt from a child run in a
  /// different cwd must not land in the parent's session.
  private var clients: [String: ACPClient] = [:]
  private var bridges: [String: ACPToolBridge] = [:]
  private var activeKeys: Set<String> = []
  private var userHistory: [String: [String]] = [:]
  private var systemPrompts: [String: String] = [:]
  private var internetAccess = InternetAccessPolicy()

  public init(
    id: ProviderID, displayName: String, configuration: ACPClient.Configuration,
    sessionFile: URL? = nil, onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil
  ) {
    self.descriptor = ProviderDescriptor(
      id: id,
      displayName: displayName,
      // Local agents receive MaiCore tools over a per-session MCP bridge.
      capabilities: [.streaming, .reasoning, .nativeToolCalling, .managedToolLoop])
    self.configuration = configuration
    self.sessionFile = sessionFile
    self.onPermission = onPermission
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    let client = ACPClient(configuration: configuration, onPermission: onPermission)
    await client.configureInternetAccess(internetAccess)
    do {
      let models = try await client.availableModels()
      await client.close()
      return models.isEmpty
        ? [ModelDescriptor(id: descriptor.id.rawValue, displayName: descriptor.displayName)]
        : models
    } catch {
      await client.close()
      throw error
    }
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
    guard activeKeys.insert(key).inserted else {
      throw JSONRPCError.invalidParams("An ACP prompt is already running for this conversation")
    }
    defer { activeKeys.remove(key) }
    let messages = ReasoningEffort.messages(
      request.messages, options: request.options, model: request.model)
    let instructions = messages.filter { $0.role == .system || $0.role == .developer }
      .map(\.text).joined(separator: "\n\n")
    let users = request.messages.filter { $0.role == .user }.map(\.text)
    let promptChanged = configuration.replacePrompt && systemPrompts[key] != instructions
    if configuration.replaceContext || promptChanged
      || userHistory[key].map({ !users.starts(with: $0) }) == true
    {
      await clients.removeValue(forKey: key)?.close()
      await bridges.removeValue(forKey: key)?.close()
      userHistory[key] = nil
    }
    let client = try await client(
      key: key, workingDirectory: configuration.workingDirectory ?? AgentExecutionScope.directory,
      forwardTools: request.toolChoice != .none && !request.tools.isEmpty,
      systemPrompt: configuration.replacePrompt ? instructions : nil)
    systemPrompts[key] = instructions
    await bridges[key]?.configure(
      tools: request.toolChoice == .none ? [] : request.tools,
      execute: ProviderToolScope.execute)
    await client.configureInternetAccess(internetAccess)
    // Agent-owned context only needs new user text. Replacement and native
    // prompt changes seed a fresh session from the host's prepared transcript.
    let text: String
    if let previous = userHistory[key] {
      text = users.dropFirst(previous.count).joined(separator: "\n\n")
    } else if !configuration.replaceContext && !configuration.replacePrompt
      && (configuration.sessionID != nil || sessionFile != nil)
    {
      text = ACPProvider.latestUserText(request.messages)
    } else {
      text = request.messages.filter { $0.role != .system && $0.role != .developer }.map {
        "[\($0.role.rawValue)\($0.isPinned ? " pinned" : "")]\n"
          + $0.content.map(Self.contextText).filter { !$0.isEmpty }.joined(separator: "\n")
      }.joined(separator: "\n\n")
    }
    let prompt =
      configuration.replacePrompt || instructions.isEmpty
      ? text : "[pmai instructions]\n\(instructions)\n\n\(text)"
    let collector = TextCollector()
    let stopReason: ProviderStopReason
    do {
      if !request.model.isEmpty, request.model != descriptor.id.rawValue {
        try await client.selectModel(request.model)
      }
      try await client.selectReasoningEffort(request.options.reasoningEffort)
      if sessionFile != nil && !configuration.replaceContext && !configuration.replacePrompt {
        let remoteID = try await client.connect()
        try saveSession(remoteID, key: key)
      }
      stopReason = try await client.prompt(prompt) { event in
        switch event {
        case .textDelta(let delta): await collector.append(delta)
        case .reasoningDelta(let delta): await collector.appendReasoning(delta)
        default: break
        }
        await emit(event)
      }
      userHistory[key] = users
      await bridges[key]?.configure(tools: [], execute: nil)
    } catch {
      await bridges[key]?.configure(tools: [], execute: nil)
      throw error
    }
    let message = await collector.message
    return ProviderResponse(
      message: message,
      usage: nil,
      stopReason: stopReason)
  }

  public func shutdown() async {
    let previous = Array(clients.values)
    clients.removeAll()
    for client in previous { await client.close() }
    let previousBridges = Array(bridges.values)
    bridges.removeAll()
    userHistory.removeAll()
    systemPrompts.removeAll()
    for bridge in previousBridges { await bridge.close() }
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

  private func client(
    key: String, workingDirectory: URL?, forwardTools: Bool, systemPrompt: String?
  ) async throws
    -> ACPClient
  {
    let needsBridge =
      configuration.webSocketURL == nil && configuration.forwardTools
      && forwardTools && ProviderToolScope.execute != nil
    if let existing = clients[key] {
      if !needsBridge || bridges[key] != nil { return existing }
      await existing.close()
      clients[key] = nil
      userHistory[key] = nil
    }
    var configuration = self.configuration
    configuration.systemPrompt = systemPrompt
    if configuration.replaceContext || configuration.replacePrompt { configuration.sessionID = nil }
    if configuration.workingDirectory == nil { configuration.workingDirectory = workingDirectory }
    if !configuration.replaceContext && !configuration.replacePrompt,
      let sessionFile, FileManager.default.fileExists(atPath: sessionFile.path)
    {
      configuration.sessionID = try JSONDecoder().decode(
        [String: String].self,
        from: Data(contentsOf: sessionFile))[key]
    }
    if needsBridge {
      let bridge = ACPToolBridge()
      do { configuration.mcpServers.append(try await bridge.start()) } catch {
        await bridge.close()
        throw error
      }
      bridges[key] = bridge
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

  /// A text handoff preserves tool evidence without executing historical calls.
  private static func contextText(_ part: ContentPart) -> String {
    switch part {
    case .text(let text): return text
    case .reasoning: return ""
    case .toolCall(let call):
      return "[tool call \(call.id) \(call.name)] \(call.arguments.compactJSONString)"
    case .toolResult(let result):
      let structured = result.structuredContent.map { "\n\($0.compactJSONString)" } ?? ""
      return "[tool result \(result.callID)\(result.isError ? " error" : "")]\n"
        + result.content.map(contextText).joined(separator: "\n") + structured
    case .file(let file): return "[file \(file.name)]\n\(file.text ?? "[binary attachment]")"
    case .resource(let resource):
      return "[resource \(resource.uri)]\n\(resource.text ?? "[binary attachment]")"
    case .image(let image): return "[image \(image.name ?? image.mimeType)]"
    case .audio(let audio): return "[audio \(audio.name ?? audio.mimeType)]"
    }
  }
}

/// Accumulates streamed deltas into the authoritative final answer.
private actor TextCollector {
  private var text = ""
  private var reasoning = ""
  func append(_ delta: String) { text += delta }
  func appendReasoning(_ delta: String) { reasoning += delta }
  var message: AgentMessage {
    AgentMessage(
      role: .assistant, content: (reasoning.isEmpty ? [] : [.reasoning(reasoning)]) + [.text(text)])
  }
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
    if let onPermission {
      let name = configuration.displayName ?? configuration.id
      permissionHandler = { try await onPermission($0, name) }
    } else {
      permissionHandler = nil
    }
    var clientConfiguration = ACPClient.Configuration(
      command: command, arguments: arguments, environment: childEnvironment,
      workingDirectory: workingDirectory, permission: permission,
      promptTimeout: configuration.timeout,
      remoteWorkingDirectory: options["remoteCwd"]?.stringValue,
      readClientFiles: options["readClientFiles"]?.boolValue ?? (url == nil),
      webSocketURL: url,
      bearerToken: options["tokenEnv"]?.stringValue.flatMap { environment[$0] }
        ?? options["token"]?.stringValue ?? storedToken)
    clientConfiguration.mcpServers = options["mcpServers"]?.arrayValue ?? []
    for key in ["context", "prompt"] {
      if let value = options[key], value != .string("agent") && value != .string("replace") {
        throw JSONRPCError.invalidParams("ACP options.\(key) must be agent or replace.")
      }
    }
    clientConfiguration.replaceContext = options["context"] == .string("replace")
    clientConfiguration.replacePrompt = options["prompt"] == .string("replace")
    clientConfiguration.forwardTools =
      options["forwardTools"]?.boolValue
      ?? (URL(fileURLWithPath: command).lastPathComponent != "ssh")
    return ACPProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? configuration.id,
      configuration: clientConfiguration,
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
