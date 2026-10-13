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
    public var webSocketURL: URL?
    public var bearerToken: String?
    public var sessionID: String?

    public init(
      command: String,
      arguments: [String] = [],
      environment: [String: String]? = nil,
      workingDirectory: URL? = nil,
      permission: ACPPermissionPolicy = .auto,
      promptTimeout: TimeInterval = 600,
      remoteWorkingDirectory: String? = nil,
      readClientFiles: Bool = true,
      webSocketURL: URL? = nil,
      bearerToken: String? = nil,
      sessionID: String? = nil
    ) {
      self.command = command
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory
      self.permission = permission
      self.promptTimeout = promptTimeout
      self.remoteWorkingDirectory = remoteWorkingDirectory
      self.readClientFiles = readClientFiles
      self.webSocketURL = webSocketURL
      self.bearerToken = bearerToken
      self.sessionID = sessionID
    }
  }

  private let configuration: Configuration
  private var transport: (any JSONRPCTransport)?
  private let onUpdate: (@Sendable (JSONValue) async -> Void)?
  private let onPermission: (@Sendable (JSONValue) async throws -> String?)?
  private var peer: JSONRPCPeer?
  private var sessionID: String?
  private var sessionLoaded = false
  private var supportsLoad = false
  private var supportsList = false
  private var busy = false
  /// The delta sink for the prompt in flight; only one prompt runs at a time.
  private var activeSink: (@Sendable (ProviderEvent) async -> Void)?

  public init(
    configuration: Configuration,
    onUpdate: (@Sendable (JSONValue) async -> Void)? = nil,
    onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil
  ) {
    self.configuration = configuration
    self.sessionID = configuration.sessionID
    self.onUpdate = onUpdate
    self.onPermission = onPermission
  }

  /// Connects and creates or restores a session; history arrives through onUpdate.
  public func connect() async throws -> String {
    guard !busy else { throw JSONRPCError.invalidParams("An ACP operation is already running") }
    busy = true
    defer { busy = false }
    return try await ensureSession(peer: connectedPeer())
  }

  public var currentSessionID: String? { sessionID }

  /// Redeems a server's pairing invitation. Invitations cannot initialize ACP
  /// or access files/chats; the server operator must approve this request.
  public func requestPairing(clientID: String, name: String) async throws -> String {
    guard !busy, let url = configuration.webSocketURL else {
      throw JSONRPCError.invalidParams("Pairing requires an idle WebSocket client")
    }
    busy = true
    defer { busy = false }
    await disconnect()
    let transport = try WebSocketJSONRPCTransport(url: url, bearerToken: configuration.bearerToken)
    let peer = JSONRPCPeer(transport: transport)
    self.transport = transport
    self.peer = peer
    await peer.start()
    do {
      let result = try await peer.request(
        "_pmai/pair",
        params: .object([
          "clientID": .string(clientID), "name": .string(name),
        ]), timeout: 0)
      guard let token = result.objectValue?["token"]?.stringValue, !token.isEmpty else {
        throw JSONRPCError.invalidParams("The server did not approve pairing")
      }
      await disconnect()
      return token
    } catch {
      await disconnect()
      throw error
    }
  }

  /// Discovers host work without creating a conversation. Nil means the agent
  /// predates session discovery; callers can still use its configured workspace.
  public func workspace() async throws -> ACPWorkspaceSnapshot? {
    guard !busy else { throw JSONRPCError.invalidParams("An ACP operation is already running") }
    busy = true
    defer { busy = false }
    let peer = try await connectedPeer()
    guard supportsList else { return nil }
    var snapshot = ACPWorkspaceSnapshot()
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      var params: [String: JSONValue] = [:]
      if let cursor { params["cursor"] = .string(cursor) }
      let result = try await peer.request(
        ACP.Method.sessionList, params: .object(params), timeout: 60)
      guard let fields = result.objectValue, let sessions = fields["sessions"]?.arrayValue else {
        throw JSONRPCError.invalidParams("Invalid session/list response")
      }
      for value in sessions {
        guard let entry = value.objectValue,
          let id = entry["sessionId"]?.stringValue, !id.isEmpty,
          let cwd = entry["cwd"]?.stringValue, cwd.hasPrefix("/")
        else { continue }
        let date = entry["updatedAt"]?.stringValue.flatMap {
          (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0))
            ?? (try? Date.ISO8601FormatStyle().parse($0))
        }
        if !snapshot.sessions.contains(where: { $0.sessionID == id }) {
          snapshot.sessions.append(
            .init(
              sessionID: id, cwd: cwd,
              title: entry["title"]?.stringValue ?? AgentChat.placeholderTitle, updatedAt: date))
        }
      }
      let folders = fields["_meta"]?.objectValue?["pmai"]?.objectValue?["folders"]?.arrayValue ?? []
      for value in folders {
        guard let entry = value.objectValue, let cwd = entry["cwd"]?.stringValue,
          cwd.hasPrefix("/"), !snapshot.folders.contains(where: { $0.cwd == cwd })
        else { continue }
        snapshot.folders.append(
          .init(
            cwd: cwd,
            name: entry["name"]?.stringValue ?? cwd, icon: entry["icon"]?.stringValue,
            tint: entry["tint"]?.stringValue))
      }
      cursor = fields["nextCursor"]?.stringValue
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw JSONRPCError.invalidParams("The agent repeated a session list cursor")
      }
    } while cursor != nil
    for session in snapshot.sessions
    where !snapshot.folders.contains(where: { $0.cwd == session.cwd }) {
      snapshot.folders.append(
        .init(
          cwd: session.cwd,
          name: AgentProject.defaultName(forWorkingDirectory: session.cwd) ?? session.cwd))
    }
    return snapshot
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

  public func disconnect() async {
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
    let transport: any JSONRPCTransport
    if let url = configuration.webSocketURL {
      transport = try WebSocketJSONRPCTransport(url: url, bearerToken: configuration.bearerToken)
    } else {
      #if os(macOS) || os(Linux) || os(Windows) || os(Android)
        transport = try StdioJSONRPCTransport.spawn(
          command: configuration.command,
          arguments: configuration.arguments,
          environment: configuration.environment,
          workingDirectory: configuration.workingDirectory)
      #else
        throw JSONRPCError.invalidParams("This platform requires an ACP WebSocket URL")
      #endif
    }
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
      supportsLoad =
        initialized.objectValue?["agentCapabilities"]?.objectValue?["loadSession"]?.boolValue
        == true
      supportsList =
        initialized.objectValue?["agentCapabilities"]?.objectValue?["sessionCapabilities"]?
        .objectValue?["list"]?.objectValue != nil
      guard initialized.objectValue?["protocolVersion"]?.intValue == ACP.protocolVersion else {
        throw JSONRPCError.invalidParams("The agent returned an unsupported ACP protocol version")
      }
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
    let cwd =
      configuration.remoteWorkingDirectory
      ?? configuration.workingDirectory?.path ?? AgentExecutionScope.directory.path
    if let sessionID, supportsLoad {
      _ = try await peer.request(
        ACP.Method.sessionLoad,
        params: .object([
          "sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": .array([]),
        ]), timeout: 60)
      sessionLoaded = true
      return sessionID
    }
    if sessionID != nil {
      throw JSONRPCError.invalidParams(
        "This agent cannot restore sessions. Start a new chat to continue.")
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
      params?.objectValue?["sessionId"]?.stringValue == sessionID
    else { return }
    if let update = params?.objectValue?["update"] { await onUpdate?(update) }
    guard let sink = activeSink else { return }
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
      guard params?.objectValue?["sessionId"]?.stringValue == sessionID else {
        throw JSONRPCError.invalidParams("Permission requested for an unknown session")
      }
      if let onPermission, let params {
        let optionID = try await onPermission(params)
        let options = params.objectValue?["options"]?.arrayValue ?? []
        guard let optionID,
          options.contains(where: { $0.objectValue?["optionId"]?.stringValue == optionID })
        else {
          return .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        return .object([
          "outcome": .object([
            "outcome": .string("selected"), "optionId": .string(optionID),
          ])
        ])
      }
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
