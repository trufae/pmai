import Foundation
import MaiCore
import MaiStandardTools

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
    public var forwirohInvitation: String?
    public var mcpServers: [JSONValue] = []
    public var forwardTools = true

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
      sessionID: String? = nil,
      forwirohInvitation: String? = nil
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
      self.forwirohInvitation = forwirohInvitation
    }
  }

  private let configuration: Configuration
  private var transport: (any JSONRPCTransport)?
  private var forwirohTunnel: ForwirohRemote.Tunnel?
  private let onUpdate: (@Sendable (JSONValue) async -> Void)?
  private let onPermission: (@Sendable (JSONValue) async throws -> String?)?
  private let onPermissionResponse: (@Sendable (JSONValue) async throws -> ACPPermissionResponse?)?
  private let onDisconnect: (@Sendable () async -> Void)?
  private var reader: Task<Void, Never>?
  private var peer: JSONRPCPeer?
  private var sessionID: String?
  private var sessionLoaded = false
  private var sessionOptions: [RemoteSessionOption] = []
  private var legacyModes = false
  private var legacyModels: [ModelDescriptor] = []
  private var currentModel: String?
  private var toolCalls: [String: ToolCall] = [:]
  private var supportsLoad = false
  private var supportsList = false
  private var supportsFiles = false
  private var supportsPermissionEditing = false
  private var supportsYolo = false
  private var supportsHistoryRewind = false
  private var busy = false
  private var internetAccess = InternetAccessPolicy()
  /// The delta sink for the prompt in flight; only one prompt runs at a time.
  private var activeSink: (@Sendable (ProviderEvent) async -> Void)?

  public init(
    configuration: Configuration,
    onUpdate: (@Sendable (JSONValue) async -> Void)? = nil,
    onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil,
    onPermissionResponse: (@Sendable (JSONValue) async throws -> ACPPermissionResponse?)? = nil,
    onDisconnect: (@Sendable () async -> Void)? = nil
  ) {
    self.configuration = configuration
    self.sessionID = configuration.sessionID
    self.onUpdate = onUpdate
    self.onPermission = onPermission
    self.onPermissionResponse = onPermissionResponse
    self.onDisconnect = onDisconnect
  }

  /// Connects and creates or restores a session; history arrives through onUpdate.
  public func connect() async throws -> String {
    guard !busy else { throw JSONRPCError.invalidParams("An ACP operation is already running") }
    busy = true
    defer { busy = false }
    return try await ensureSession(peer: connectedPeer())
  }

  public var currentSessionID: String? { sessionID }

  public func historyRewindSupported() async -> Bool { supportsHistoryRewind }

  public func configurationOptions() async throws -> [RemoteSessionOption] {
    if !sessionLoaded { _ = try await connect() }
    return sessionOptions
  }

  public func setConfigurationOption(id: String, value: JSONValue) async throws
    -> [RemoteSessionOption]
  {
    guard !busy, sessionLoaded, let sessionID, let peer,
      let option = sessionOptions.first(where: { $0.id == id }), option.accepts(value)
    else {
      throw JSONRPCError.invalidParams(
        "Connect to an idle session and choose an available setting.")
    }
    busy = true
    defer { busy = false }
    if legacyModes {
      _ = try await peer.request(
        "session/set_mode",
        params: .object([
          "sessionId": .string(sessionID), "modeId": value,
        ]), timeout: 30)
      if let index = sessionOptions.firstIndex(where: { $0.id == id }) {
        sessionOptions[index].currentValue = value
      }
    } else {
      var params: [String: JSONValue] = [
        "sessionId": .string(sessionID), "configId": .string(id), "value": value,
      ]
      if option.isBoolean { params["type"] = .string("boolean") }
      let result = try await peer.request(
        ACP.Method.sessionSetConfigOption, params: .object(params), timeout: 30)
      guard let options = result.objectValue?["configOptions"], options.arrayValue != nil else {
        throw JSONRPCError.invalidParams("The agent returned no session settings.")
      }
      sessionOptions = RemoteSessionOption.parse(options)
    }
    return sessionOptions
  }

  public func rewind(to messageID: String?) async throws {
    guard !busy, sessionLoaded, supportsHistoryRewind, let sessionID, let peer else {
      throw JSONRPCError.invalidParams(
        "Connect to an idle pmai session before changing its conversation history.")
    }
    busy = true
    defer { busy = false }
    var params: [String: JSONValue] = ["sessionId": .string(sessionID)]
    params["messageId"] = messageID.map(JSONValue.string) ?? .null
    _ = try await peer.request(ACP.Method.sessionRewind, params: .object(params), timeout: 60)
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    let options = try await configurationOptions()
    if let model = options.first(where: { $0.category == "model" || $0.id == "model" }) {
      return model.choices.map { ModelDescriptor(id: $0.id, displayName: $0.name) }
    }
    return legacyModels
  }

  public func selectModel(_ id: String) async throws {
    let options = try await configurationOptions()
    if let option = options.first(where: { $0.category == "model" || $0.id == "model" }) {
      if option.currentValue != .string(id) {
        _ = try await setConfigurationOption(id: option.id, value: .string(id))
      }
    } else if !legacyModels.isEmpty {
      guard legacyModels.contains(where: { $0.id == id }), !busy, let peer, let sessionID else {
        throw JSONRPCError.invalidParams("Unknown ACP model '\(id)'")
      }
      if currentModel == id { return }
      busy = true
      defer { busy = false }
      _ = try await peer.request(
        "session/set_model",
        params: .object([
          "sessionId": .string(sessionID), "modelId": .string(id),
        ]), timeout: 30)
      currentModel = id
    } else {
      throw JSONRPCError.invalidParams("This ACP agent does not expose model selection")
    }
  }

  private func readSessionOptions(_ result: JSONValue) {
    if let models = result.objectValue?["models"]?.objectValue {
      currentModel = models["currentModelId"]?.stringValue
      legacyModels = (models["availableModels"]?.arrayValue ?? []).compactMap {
        guard let id = $0.objectValue?["modelId"]?.stringValue else { return nil }
        return ModelDescriptor(id: id, displayName: $0.objectValue?["name"]?.stringValue)
      }
    }
    legacyModes = result.objectValue?["configOptions"] == nil
    sessionOptions = RemoteSessionOption.parse(result.objectValue?["configOptions"])
    if legacyModes, let modes = result.objectValue?["modes"]?.objectValue,
      let current = modes["currentModeId"]?.stringValue
    {
      sessionOptions = [
        .init(
          id: "mode", name: "Mode", category: "mode", currentValue: .string(current),
          choices: (modes["availableModes"]?.arrayValue ?? []).compactMap {
            guard let id = $0.objectValue?["id"]?.stringValue else { return nil }
            return .init(id, $0.objectValue?["name"]?.stringValue ?? id)
          })
      ]
    }
  }
  public var isConnected: Bool { peer != nil && transport?.isRunning == true }

  public func configureInternetAccess(_ policy: InternetAccessPolicy) async {
    internetAccess = policy
    if policy.isOffline, configuration.webSocketURL != nil { await disconnect() }
  }

  /// Accesses host files without creating a chat or running an agent prompt.
  public func files(cwd: String, request: WorkspaceFileRequest) async throws
    -> WorkspaceFileResponse
  {
    guard !busy else { throw JSONRPCError.invalidParams("An ACP operation is already running") }
    busy = true
    defer { busy = false }
    let peer = try await connectedPeer()
    guard supportsFiles else {
      throw JSONRPCError.invalidParams("Update the remote pmai host to browse and transfer files.")
    }
    let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    let result = try await peer.request(
      ACP.Method.workspaceFiles,
      params: .object(["cwd": .string(cwd), "request": body]), timeout: 120)
    return try JSONDecoder().decode(WorkspaceFileResponse.self, from: JSONEncoder().encode(result))
  }

  /// Runs one enabled host tool without opening an ACP chat session. The
  /// caller chooses `cwd`; the server validates it against its served roots.
  public func runTool(cwd: String, call: ToolCall) async throws -> ToolResult {
    guard !busy else { throw JSONRPCError.invalidParams("An ACP operation is already running") }
    busy = true
    defer { busy = false }
    let peer = try await connectedPeer()
    let result = try await peer.request(
      ACP.Method.sessionRunTool,
      params: .object([
        "cwd": .string(cwd),
        "tool": .object(["name": .string(call.name), "arguments": call.arguments]),
      ]), timeout: MaiRunConfiguration.maximumTimeout + 10)
    return try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
  }

  /// A title renames a durable session; nil deletes it without creating a new session.
  public func manageSession(_ id: String, cwd: String, title: String?) async throws {
    guard !busy else { throw JSONRPCError.invalidParams("Session is busy") }
    busy = true
    defer { busy = false }
    _ = try await connectedPeer().request(
      ACP.Method.sessionManage,
      params: .object([
        "sessionId": .string(id), "cwd": .string(cwd),
        "title": title.map(JSONValue.string) ?? .null,
      ]), timeout: 60)
  }

  /// Redeems a server's pairing invitation. Invitations cannot initialize ACP
  /// or access files/chats; the server operator must approve this request.
  public func requestPairing(clientID: String, name: String) async throws -> String {
    guard !busy, let url = configuration.webSocketURL else {
      throw JSONRPCError.invalidParams("Pairing requires an idle WebSocket client")
    }
    busy = true
    defer { busy = false }
    await disconnect()
    try Task.checkCancellation()
    guard !internetAccess.isOffline else { throw InternetAccessError.offline }
    let transport = try await remoteTransport(url: url, pairing: true)
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
      if !(error is CancellationError), !transport.recentErrorOutput.isEmpty {
        throw ACPClientError.launchFailed(
          command: configuration.command, detail: transport.recentErrorOutput)
      }
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
      snapshot.canManageSessions =
        fields["_meta"]?.objectValue?["pmai"]?
        .objectValue?["canManageSessions"]?.boolValue
      for value in sessions {
        guard let entry = value.objectValue,
          let id = entry["sessionId"]?.stringValue, !id.isEmpty,
          let cwd = entry["cwd"]?.stringValue, cwd.hasPrefix("/")
        else { continue }
        let date = Self.parseDate(entry["updatedAt"])
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
            tint: entry["tint"]?.stringValue, updatedAt: Self.parseDate(entry["updatedAt"])))
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

  private static func parseDate(_ value: JSONValue?) -> Date? {
    value?.stringValue.flatMap {
      (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0))
        ?? (try? Date.ISO8601FormatStyle().parse($0))
    }
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
    toolCalls.removeAll()
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
      // The runtime retries ordinary transport failures. A prompt may already
      // have executed tools, so this error must require explicit user action.
      await disconnect()
      throw ProviderPolicyError(code: "acp_prompt_failed", message: error.localizedDescription)
    }
  }

  public func close() async {
    await disconnect()
    sessionID = nil
  }

  public func disconnect() async {
    let previous = peer
    let transport = transport
    peer = nil
    self.transport = nil
    reader?.cancel()
    reader = nil
    sessionLoaded = false
    supportsPermissionEditing = false
    supportsYolo = false
    supportsHistoryRewind = false
    let tunnel = forwirohTunnel
    forwirohTunnel = nil
    transport?.close()
    await previous?.close()
    await tunnel?.close()
  }

  private func connectionClosed(_ peer: JSONRPCPeer) async {
    guard self.peer === peer else { return }
    self.peer = nil
    transport?.close()
    transport = nil
    reader = nil
    sessionLoaded = false
    let tunnel = forwirohTunnel
    forwirohTunnel = nil
    await tunnel?.close()
    await onDisconnect?()
  }

  private func remoteTransport(url: URL, pairing: Bool = false) async throws
    -> any JSONRPCTransport
  {
    if url.scheme != "forwiroh" {
      return try WebSocketJSONRPCTransport(url: url, bearerToken: configuration.bearerToken)
    }
    if pairing {
      try await ForwirohRemote.shared.pair(url: url, invitation: configuration.forwirohInvitation)
    }
    let tunnel = try await ForwirohRemote.shared.connect(url: url)
    do {
      try Task.checkCancellation()
      let transport = try ForwirohWebSocketTransport(
        url: tunnel.url, bearerToken: configuration.bearerToken)
      forwirohTunnel = tunnel
      return transport
    } catch {
      await tunnel.close()
      throw error
    }
  }

  // MARK: - Connection

  private func connectedPeer() async throws -> JSONRPCPeer {
    try Task.checkCancellation()
    if let peer, transport?.isRunning == true { return peer }
    await disconnect()
    try Task.checkCancellation()
    guard configuration.webSocketURL == nil || !internetAccess.isOffline else {
      throw InternetAccessError.offline
    }
    let transport: any JSONRPCTransport
    if let url = configuration.webSocketURL {
      transport = try await remoteTransport(url: url)
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
    self.transport = transport
    self.peer = peer
    reader = Task { [weak self] in
      await peer.run()
      await self?.connectionClosed(peer)
    }
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
            "session": .object(["configOptions": .object(["boolean": .object([:])])]),
          ]),
        ]),
        timeout: 30)
      supportsLoad =
        initialized.objectValue?["agentCapabilities"]?.objectValue?["loadSession"]?.boolValue
        == true
      supportsList =
        initialized.objectValue?["agentCapabilities"]?.objectValue?["sessionCapabilities"]?
        .objectValue?["list"]?.objectValue != nil
      let pmaiCapabilities = initialized.objectValue?["agentCapabilities"]?.objectValue?["_meta"]?
        .objectValue?["pmai"]?.objectValue
      supportsFiles = pmaiCapabilities?["workspaceFiles"]?.intValue == 1
      supportsPermissionEditing = pmaiCapabilities?["permissionEditing"]?.intValue == 1
      supportsYolo = pmaiCapabilities?["yolo"]?.intValue == 1
      supportsHistoryRewind = pmaiCapabilities?["historyRewind"]?.intValue == 1
      if configuration.mcpServers.contains(where: { $0.objectValue?["type"]?.stringValue == "http" }
      ),
        initialized.objectValue?["agentCapabilities"]?.objectValue?["mcpCapabilities"]?
          .objectValue?["http"]?.boolValue != true
      {
        throw JSONRPCError.invalidParams(
          "This ACP agent does not support HTTP MCP servers; update its adapter to use pmai tools")
      }
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
      let result = try await peer.request(
        ACP.Method.sessionLoad,
        params: .object([
          "sessionId": .string(sessionID), "cwd": .string(cwd),
          "mcpServers": .array(configuration.mcpServers),
        ]), timeout: 60)
      readSessionOptions(result)
      sessionLoaded = true
      return sessionID
    }
    if sessionID != nil {
      throw JSONRPCError.invalidParams(
        "This agent cannot restore sessions. Start a new chat to continue.")
    }
    let result = try await peer.request(
      ACP.Method.sessionNew,
      params: .object(["cwd": .string(cwd), "mcpServers": .array(configuration.mcpServers)]),
      timeout: 60)
    guard let id = result.objectValue?["sessionId"]?.stringValue, !id.isEmpty else {
      throw ACPClientError.noSession(configuration.command)
    }
    sessionID = id
    readSessionOptions(result)
    sessionLoaded = true
    return id
  }

  // MARK: - Agent-initiated traffic

  private func handleAgentNotification(method: String, params: JSONValue?) async {
    guard method == ACP.Method.sessionUpdate,
      params?.objectValue?["sessionId"]?.stringValue == sessionID
    else { return }
    if let update = params?.objectValue?["update"] {
      if update.objectValue?["sessionUpdate"]?.stringValue == "config_option_update" {
        readSessionOptions(update)
      } else if legacyModes,
        update.objectValue?["sessionUpdate"]?.stringValue == "current_mode_update",
        let mode = update.objectValue?["currentModeId"]?.stringValue,
        !sessionOptions.isEmpty
      {
        sessionOptions[0].currentValue = .string(mode)
        await onUpdate?(
          .object([
            "sessionUpdate": .string("config_option_update"),
            "configOptions": .array(sessionOptions.map(\.json)),
          ]))
      }
      await onUpdate?(update)
    }
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
    case .toolCall, .toolCallUpdate:
      guard let id = update["toolCallId"]?.stringValue else { return }
      if toolCalls[id] == nil {
        let call = ToolCall(
          id: id, name: update["title"]?.stringValue ?? "ACP tool",
          arguments: update["rawInput"] ?? .object([:]))
        toolCalls[id] = call
        await sink(.toolStarted(call))
      }
      if let status = update["status"]?.stringValue, ["completed", "failed"].contains(status) {
        await sink(
          .toolFinished(
            ToolResult(
              callID: id,
              text: ACP.ContentBlock.text(from: update["content"]), isError: status == "failed")))
      }
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
      if let onPermissionResponse, let params {
        var request = params
        if supportsPermissionEditing || supportsYolo, var object = request.objectValue {
          object["_pmai"] = .object([
            "permissionEditing": .bool(supportsPermissionEditing),
            "yolo": .bool(supportsYolo),
          ])
          request = .object(object)
        }
        let response = try await onPermissionResponse(request)
        let optionID = response?.optionID
        let options = params.objectValue?["options"]?.arrayValue ?? []
        guard let optionID,
          options.contains(where: { $0.objectValue?["optionId"]?.stringValue == optionID })
        else {
          return .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        var outcome: [String: JSONValue] = [
          "outcome": .string("selected"), "optionId": .string(optionID),
        ]
        if supportsPermissionEditing, let rawInput = response?.rawInput {
          outcome["rawInput"] = rawInput
        }
        return .object([
          "outcome": .object(outcome)
        ])
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
