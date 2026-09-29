import Foundation
import MaiCore

/// Drives one external ACP agent: starts it, negotiates a session, sends a
/// prompt, and forwards the streamed reply. It answers the agent's own
/// requests — permission and file reads — from a fixed policy, so a background
/// run never blocks on a question nobody is watching.
///
/// One client owns one child process and one ACP session, reused across
/// prompts so the agent keeps its context. `ACPProvider` pools them per
/// working directory.
public actor ACPClient {
  public struct Configuration: Sendable {
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var workingDirectory: URL?
    public var remoteWorkingDirectory: String?
    public var readClientFiles: Bool
    public var permission: ACPPermissionPolicy
    public var promptTimeout: TimeInterval

    public init(
      command: String,
      arguments: [String] = [],
      environment: [String: String]? = nil,
      workingDirectory: URL? = nil,
      permission: ACPPermissionPolicy = .auto,
      promptTimeout: TimeInterval = 600,
      remoteWorkingDirectory: String? = nil,
      readClientFiles: Bool = true
    ) {
      self.command = command
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory
      self.permission = permission
      self.promptTimeout = promptTimeout
      self.remoteWorkingDirectory = remoteWorkingDirectory
      self.readClientFiles = readClientFiles
    }
  }

  private let configuration: Configuration
  private var transport: StdioJSONRPCTransport?
  private var peer: JSONRPCPeer?
  private var sessionID: String?
  private var sessionLoaded = false
  private var supportsLoad = false
  private var busy = false
  /// The delta sink for the prompt in flight; only one prompt runs at a time.
  private var activeSink: (@Sendable (ProviderEvent) async -> Void)?

  public init(configuration: Configuration) {
    self.configuration = configuration
  }

  /// Runs one prompt to completion, streaming assistant and reasoning deltas
  /// through `emit`, and returns the agent's stop reason.
  public func prompt(
    _ text: String,
    emit: @escaping @Sendable (ProviderEvent) async -> Void
  ) async throws -> ProviderStopReason {
    guard !busy else { throw JSONRPCError.invalidParams("An ACP prompt is already running") }
    busy = true
    defer { busy = false }
    let peer = try await connectedPeer()
    let sessionID = try await ensureSession(peer: peer)
    activeSink = emit
    defer { activeSink = nil }
    let params: JSONValue = .object([
      "sessionId": .string(sessionID),
      "prompt": .array([ACP.ContentBlock.text(text).json]),
    ])
    do {
      let result = try await peer.request(
        ACP.Method.sessionPrompt, params: params, timeout: configuration.promptTimeout)
      let raw = result.objectValue?["stopReason"]?.stringValue ?? ACP.StopReason.endTurn.rawValue
      return (ACP.StopReason(rawValue: raw) ?? .endTurn).providerStopReason
    } catch is CancellationError {
      try? peer.notify(
        ACP.Method.sessionCancel, params: .object(["sessionId": .string(sessionID)]))
      await disconnect()
      throw CancellationError()
    } catch {
      // Do not resend a prompt: the worker may already have executed tools.
      await disconnect()
      throw error
    }
  }

  public func close() async {
    await disconnect()
    sessionID = nil
  }

  private func disconnect() async {
    await peer?.close()
    transport?.close()
    peer = nil
    transport = nil
    sessionLoaded = false
  }

  // MARK: - Connection

  private func connectedPeer() async throws -> JSONRPCPeer {
    if let peer, transport?.isRunning == true { return peer }
    await disconnect()
    let transport = try StdioJSONRPCTransport.spawn(
      command: configuration.command,
      arguments: configuration.arguments,
      environment: configuration.environment,
      workingDirectory: configuration.workingDirectory)
    let peer = JSONRPCPeer(
      transport: transport,
      onRequest: { [weak self] method, params in
        guard let self else { throw JSONRPCError.internalError("client is gone") }
        return try await self.handleAgentRequest(method: method, params: params)
      },
      onNotification: { [weak self] method, params in
        await self?.handleAgentNotification(method: method, params: params)
      })
    await peer.start()
    self.transport = transport
    self.peer = peer
    do {
      let initialized = try await peer.request(
        ACP.Method.initialize,
        params: .object([
          "protocolVersion": .integer(ACP.protocolVersion),
          "clientInfo": .object([
            "name": .string("pmai"), "version": .string("1.0.0"),
          ]),
          "clientCapabilities": .object([
            "fs": .object([
              "readTextFile": .bool(configuration.readClientFiles), "writeTextFile": .bool(false),
            ]),
            "terminal": .bool(false),
          ]),
        ]),
        timeout: 30)
      supportsLoad = initialized.objectValue?["agentCapabilities"]?.objectValue?["loadSession"]?.boolValue == true
    } catch {
      await disconnect()
      throw ACPClientError.launchFailed(
        command: configuration.command,
        detail: transport.recentErrorOutput.isEmpty
          ? error.localizedDescription : transport.recentErrorOutput)
    }
    return peer
  }

  private func ensureSession(peer: JSONRPCPeer) async throws -> String {
    if let sessionID, sessionLoaded { return sessionID }
    let cwd = configuration.remoteWorkingDirectory
      ?? configuration.workingDirectory?.path ?? AgentExecutionScope.directory.path
    if let sessionID, supportsLoad {
      _ = try await peer.request(ACP.Method.sessionLoad, params: .object([
        "sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": .array([])
      ]), timeout: 60)
      sessionLoaded = true
      return sessionID
    }
    let result = try await peer.request(
      ACP.Method.sessionNew,
      params: .object(["cwd": .string(cwd), "mcpServers": .array([])]),
      timeout: 60)
    guard let id = result.objectValue?["sessionId"]?.stringValue, !id.isEmpty else {
      throw ACPClientError.noSession(configuration.command)
    }
    sessionID = id
    sessionLoaded = true
    return id
  }

  // MARK: - Agent-initiated traffic

  private func handleAgentNotification(method: String, params: JSONValue?) async {
    guard method == ACP.Method.sessionUpdate,
      params?.objectValue?["sessionId"]?.stringValue == sessionID,
      let sink = activeSink else { return }
    guard let update = params?.objectValue?["update"]?.objectValue,
      let kind = update["sessionUpdate"]?.stringValue.flatMap(ACP.Update.init)
    else { return }
    let text = ACP.ContentBlock.text(from: update["content"])
    switch kind {
    case .agentMessageChunk where !text.isEmpty:
      await sink(.textDelta(text))
    case .agentThoughtChunk where !text.isEmpty:
      await sink(.reasoningDelta(text))
    default:
      break
    }
  }

  private func handleAgentRequest(method: String, params: JSONValue?) async throws -> JSONValue {
    switch method {
    case ACP.Method.requestPermission:
      return permissionOutcome(params: params)
    case ACP.Method.readTextFile:
      guard configuration.readClientFiles else { throw JSONRPCError.methodNotFound(method) }
      return try readTextFile(params: params)
    default:
      throw JSONRPCError.methodNotFound(method)
    }
  }

  private func permissionOutcome(params: JSONValue?) -> JSONValue {
    let toolCall = params?.objectValue?["toolCall"]?.objectValue
    let kind = toolCall?["kind"]?.stringValue ?? ""
    let options = params?.objectValue?["options"]?.arrayValue ?? []
    guard let optionID = configuration.permission.optionID(from: options, kind: kind) else {
      return .object(["outcome": .object(["outcome": .string("cancelled")])])
    }
    return .object([
      "outcome": .object([
        "outcome": .string("selected"), "optionId": .string(optionID),
      ])
    ])
  }

  private func readTextFile(params: JSONValue?) throws -> JSONValue {
    guard let path = params?.objectValue?["path"]?.stringValue else {
      throw JSONRPCError.invalidParams("path is required")
    }
    let base =
      configuration.workingDirectory
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, relativeTo: base)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw JSONRPCError.internalError("cannot read \(path)")
    }
    return .object(["content": .string(text)])
  }
}

public enum ACPClientError: LocalizedError, Equatable, Sendable {
  case launchFailed(command: String, detail: String)
  case noSession(String)

  public var errorDescription: String? {
    switch self {
    case .launchFailed(let command, let detail):
      "The ACP agent '\(command)' did not start: \(detail)"
    case .noSession(let command):
      "The ACP agent '\(command)' did not open a session (it may need logging in with its own CLI first)."
    }
  }
}
