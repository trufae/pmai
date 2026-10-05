import Foundation
import MaiCore

/// Exposes a MaiCore `AgentRuntime` to any ACP client (Zed, JetBrains, …) over
/// stdio. It is deliberately thin: `session/prompt` becomes one
/// `AgentRuntime.run`, provider deltas become `session/update` notifications,
/// and a tool that needs approval becomes a `session/request_permission` the
/// editor answers. All the agent logic stays in the runtime.
public actor ACPServer {
  private struct SavedSession: Codable {
    var id: String
    var agentID: String
    var workingDirectory: URL
    var transcript: [AgentMessage]
    var promptInFlight: Bool?
  }

  private struct Session {
    var saved: SavedSession
    var task: Task<AgentResult, Error>?
    var lease: ACPFileLock?
    var processes: [AgentPID] = []
  }

  private let runtime: AgentRuntime
  private let agent: AgentDefinition
  private let bridge: ACPPermissionBridge
  private var peer: JSONRPCPeer?
  private var sessions: [String: Session] = [:]
  private let sessionDirectory: URL?
  private let workspaceRoot: URL?
  private let authorize: @Sendable () throws -> Void
  private let extensionHandler: @Sendable (String, JSONValue?) throws -> JSONValue?
  private var connected = false
  private var initialized = false
  private var connectedAt = Date()

  /// - Parameters:
  ///   - runtime: built with `bridge.approvalHandler` so tool approvals reach
  ///     the editor instead of being denied.
  ///   - agent: the definition each session runs.
  public init(
    runtime: AgentRuntime, agent: AgentDefinition, bridge: ACPPermissionBridge,
    sessionDirectory: URL? = nil, workspaceRoot: URL? = nil,
    authorize: @escaping @Sendable () throws -> Void = {},
    extensionHandler: @escaping @Sendable (String, JSONValue?) throws -> JSONValue? = { _, _ in nil }
  ) {
    self.runtime = runtime
    self.agent = agent
    self.bridge = bridge
    self.sessionDirectory = sessionDirectory
    self.workspaceRoot = workspaceRoot?.resolvingSymlinksInPath().standardizedFileURL
    self.authorize = authorize
    self.extensionHandler = extensionHandler
  }

  /// Serves the client on the given transport (usually this process's stdio)
  /// until it disconnects.
  public func serve(on transport: any JSONRPCTransport) async {
    let peer = JSONRPCPeer(
      transport: transport,
      onRequest: { [weak self] method, params in
        guard let self else { throw JSONRPCError.internalError("server is gone") }
        return try await self.handle(method: method, params: params)
      },
      onNotification: { [weak self] method, params in
        await self?.handleNotification(method: method, params: params)
      })
    self.peer = peer
    connected = true
    connectedAt = Date()
    bridge.connect(to: self)
    // Revocation also closes idle connections and cancels in-flight work.
    let monitor = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        await self?.checkAuthorization()
      }
    }
    await peer.run()
    connected = false
    monitor.cancel()
    for session in sessions.values {
      for pid in session.processes { await runtime.supervisor.stop(pid, reason: "ACP disconnected") }
    }
    let tasks = sessions.values.compactMap(\.task)
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
    sessions.removeAll()
    self.peer = nil
  }

  // MARK: - Requests

  private func handle(method: String, params: JSONValue?) async throws -> JSONValue {
    guard connected else { throw JSONRPCTransportError.closed }
    if let result = try extensionHandler(method, params) { return result }
    try authorize()
    if method == ACP.Method.initialize {
      guard params?.objectValue?["protocolVersion"]?.intValue == ACP.protocolVersion else {
        throw JSONRPCError.invalidParams("Unsupported ACP protocol version.")
      }
      initialized = true
      return initializeResult()
    }
    guard initialized else { throw JSONRPCError.invalidParams("initialize is required") }
    switch method {
    case ACP.Method.authenticate:
      return .object([:])
    case ACP.Method.sessionNew:
      return try newSession(params: params)
    case ACP.Method.sessionLoad:
      return try await loadSession(params: params)
    case "ping":
      return .object([:])
    case ACP.Method.sessionPrompt:
      return try await runPrompt(params: params)
    default:
      throw JSONRPCError.methodNotFound(method)
    }
  }

  private func handleNotification(method: String, params: JSONValue?) async {
    guard connected, (try? authorize()) != nil, method == ACP.Method.sessionCancel else { return }
    guard let id = params?.objectValue?["sessionId"]?.stringValue else { return }
    sessions[id]?.task?.cancel()
    for pid in sessions[id]?.processes ?? [] { await runtime.supervisor.stop(pid, reason: "ACP cancelled") }
  }

  private func initializeResult() -> JSONValue {
    .object([
      "protocolVersion": .integer(ACP.protocolVersion),
      "agentInfo": .object([
        "name": .string(ACP.agentName), "version": .string("1.0.0"),
      ]),
      "agentCapabilities": .object([
        "loadSession": .bool(sessionDirectory != nil),
        "promptCapabilities": .object([
          "image": .bool(false), "audio": .bool(false), "embeddedContext": .bool(true),
        ]),
      ]),
      "authMethods": .array([]),
    ])
  }

  private func checkAuthorization() async {
    // A fresh, not-yet-paired connection must be able to redeem its invite.
    guard initialized else {
      if Date().timeIntervalSince(connectedAt) > 30 { await peer?.close() }
      return
    }
    do { try authorize() } catch { await peer?.close() }
  }

  private func directory(params: JSONValue?) throws -> URL {
    guard let path = params?.objectValue?["cwd"]?.stringValue, path.hasPrefix("/") else {
      throw JSONRPCError.invalidParams("cwd must be an absolute directory on the worker")
    }
    let url = URL(fileURLWithPath: path, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
      throw JSONRPCError.invalidParams("cwd does not exist on the worker")
    }
    if let root = workspaceRoot, url != root,
      !url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") {
      throw JSONRPCError.invalidParams("cwd is outside the served workspace")
    }
    // Do not silently accept client-supplied executables that were never installed.
    if let servers = params?.objectValue?["mcpServers"]?.arrayValue, !servers.isEmpty {
      throw JSONRPCError.invalidParams("Configure MCP servers in the worker's pmai config.")
    }
    return url
  }

  private func lease(_ id: String) throws -> ACPFileLock? {
    guard let sessionDirectory else { return nil }
    try ACPStateFiles.createDirectory(sessionDirectory)
    return try ACPFileLock(url: sessionDirectory.appendingPathComponent(id + ".lock"))
  }

  private func save(_ session: SavedSession) throws {
    guard let sessionDirectory else { return }
    try ACPStateFiles.write(session, to: sessionDirectory.appendingPathComponent(session.id + ".json"))
  }

  private func newSession(params: JSONValue?) throws -> JSONValue {
    let cwd = try directory(params: params)
    let id = UUID().uuidString.lowercased()
    let saved = SavedSession(
      id: id, agentID: agent.id, workingDirectory: cwd,
      transcript: AgentChat.initialHistory(for: agent))
    let lock = try lease(id)
    try save(saved)
    sessions[id] = Session(saved: saved, lease: lock)
    return .object(["sessionId": .string(id)])
  }

  private func loadSession(params: JSONValue?) async throws -> JSONValue {
    guard let sessionDirectory,
      let id = params?.objectValue?["sessionId"]?.stringValue,
      let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
      throw JSONRPCError.invalidParams("Unknown sessionId")
    }
    let cwd = try directory(params: params)
    guard sessions[id]?.task == nil else {
      throw JSONRPCError.invalidParams("Session is busy")
    }
    if sessions[id] == nil {
      let lock = try lease(id)
      let url = sessionDirectory.appendingPathComponent(id + ".json")
      guard let data = try? Data(contentsOf: url),
        var saved = try? JSONDecoder().decode(SavedSession.self, from: data),
        saved.id == id, saved.agentID == agent.id, saved.workingDirectory == cwd else {
        throw JSONRPCError.invalidParams("Session does not belong to this agent and workspace")
      }
      if saved.promptInFlight == true {
        saved.transcript.append(.assistant(Self.interruptedPromptNotice))
        saved.promptInFlight = false
        try save(saved)
      }
      sessions[id] = Session(saved: saved, lease: lock)
    }
    guard let session = sessions[id], session.saved.workingDirectory == cwd else {
      throw JSONRPCError.invalidParams("Session working directory differs")
    }
    for message in session.saved.transcript {
      switch message.role {
      case .user:
        await update(session: id, kind: .userMessageChunk, text: message.text)
      case .assistant:
        if !message.text.isEmpty { await update(session: id, kind: .agentMessageChunk, text: message.text) }
        for call in message.toolCalls { await toolUpdate(session: id, call: call) }
      case .tool:
        for result in message.toolResults { await toolFinished(session: id, result: result) }
      default: break
      }
    }
    return .object([:])
  }

  private func runPrompt(params: JSONValue?) async throws -> JSONValue {
    guard let id = params?.objectValue?["sessionId"]?.stringValue, sessions[id] != nil else {
      throw JSONRPCError.invalidParams("unknown sessionId")
    }
    guard sessions[id]?.task == nil else {
      throw JSONRPCError.invalidParams("A prompt is already running in this session")
    }
    let text = ACP.promptText(params?.objectValue?["prompt"])
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw JSONRPCError.invalidParams("prompt is empty")
    }
    sessions[id]?.saved.transcript.append(.user(text))
    sessions[id]?.saved.promptInFlight = true
    try save(sessions[id]!.saved)

    let request = AgentRequest(
      agentID: agent.id,
      provider: agent.provider,
      model: agent.model,
      messages: sessions[id]!.saved.transcript,
      toolNames: agent.toolNames,
      toolGroupNames: agent.toolGroupNames,
      subagentNames: agent.subagentNames,
      toolChoice: agent.toolChoice,
      responseFormat: agent.responseFormat,
      options: agent.options,
      limits: agent.limits,
      stream: true,
      toolCallingStrategy: agent.toolCallingStrategy,
      useToolProxy: agent.useToolProxy,
      proxyExposedTools: agent.proxyExposedTools,
      toolPolicy: agent.toolPolicy,
      toolDelegation: agent.toolDelegation,
      retry: agent.retry, autocompact: agent.autocompact, context: agent.context,
      sessionID: id)

    let sessionID = id
    let scope = AgentExecutionScope(sessionID: id, workingDirectory: sessions[id]!.saved.workingDirectory)
    let task = Task { [weak self, runtime] in
      try await AgentExecutionScope.$current.withValue(scope) {
        try await runtime.run(request) { [weak self] event in
          await self?.forward(event, session: sessionID)
        }
      }
    }
    sessions[id]?.task = task

    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: { task.cancel() }
      sessions[id]?.saved.transcript = result.transcript
      sessions[id]?.saved.promptInFlight = false
      if let saved = sessions[id]?.saved { try save(saved) }
      sessions[id]?.task = nil
      // A limit pauses the run with its transcript kept, so the next prompt
      // carries on; the editor is told which limit it was.
      if let interruption = result.interruption {
        await update(
          session: id, kind: .agentMessageChunk,
          text: "Stopped: \(interruption.summary). Send another prompt to continue.")
        let stopReason: ACP.StopReason =
          switch interruption {
          case .modelTurns: .maxTurnRequests
          case .totalTokens: .maxTokens
          case .time: .endTurn
          }
        return .object(["stopReason": .string(stopReason.rawValue)])
      }
      return .object(["stopReason": .string(ACP.StopReason(result.stopReason).rawValue)])
    } catch is CancellationError {
      try? finishInterruptedPrompt(id)
      sessions[id]?.task = nil
      return .object(["stopReason": .string(ACP.StopReason.cancelled.rawValue)])
    } catch {
      try? finishInterruptedPrompt(id)
      sessions[id]?.task = nil
      // A run that never produced text should still tell the editor why.
      await update(session: id, kind: .agentMessageChunk, text: error.localizedDescription)
      return .object(["stopReason": .string(ACP.StopReason.refusal.rawValue)])
    }
  }

  private static let interruptedPromptNotice =
    "The previous prompt was interrupted. Some tools may already have run and partial output may be missing. Verify the current state before repeating actions."

  private func finishInterruptedPrompt(_ id: String) throws {
    sessions[id]?.saved.transcript.append(.assistant(Self.interruptedPromptNotice))
    sessions[id]?.saved.promptInFlight = false
    if let saved = sessions[id]?.saved { try save(saved) }
  }

  // MARK: - Streaming out

  private func forward(_ event: AgentEvent, session id: String) async {
    // Child agents report through the same handler; the editor gets the served
    // agent's own stream, and children stay behind the tool result they become.
    switch event {
    case .started(let context, _) where context.depth == 0:
      if let pid = context.pid { sessions[id]?.processes.append(pid) }
    case .provider(let context, .textDelta(let text)) where context.depth == 0 && !text.isEmpty:
      await update(session: id, kind: .agentMessageChunk, text: text)
    case .provider(let context, .reasoningDelta(let text))
    where context.depth == 0 && !text.isEmpty:
      await update(session: id, kind: .agentThoughtChunk, text: text)
    case .toolStarted(let context, let call) where context.depth == 0:
      await toolUpdate(session: id, call: call)
    case .toolFinished(let context, let result) where context.depth == 0:
      await toolFinished(session: id, result: result)
    default:
      break
    }
  }

  private func update(session id: String, kind: ACP.Update, text: String) async {
    try? peer?.notify(
      ACP.Method.sessionUpdate,
      params: .object([
        "sessionId": .string(id),
        "update": .object([
          "sessionUpdate": .string(kind.rawValue),
          "content": ACP.ContentBlock.text(text).json,
        ]),
      ]))
  }

  private func toolUpdate(session id: String, call: ToolCall) async {
    try? peer?.notify(
      ACP.Method.sessionUpdate,
      params: .object([
        "sessionId": .string(id),
        "update": .object([
          "sessionUpdate": .string(ACP.Update.toolCall.rawValue),
          "toolCallId": .string(call.id),
          "title": .string(call.name),
          "rawInput": call.arguments,
          "status": .string("in_progress"),
        ]),
      ]))
  }

  private func toolFinished(session id: String, result: ToolResult) async {
    try? peer?.notify(ACP.Method.sessionUpdate, params: .object([
      "sessionId": .string(id), "update": .object([
        "sessionUpdate": .string(ACP.Update.toolCallUpdate.rawValue),
        "toolCallId": .string(result.callID),
        "status": .string(result.isError ? "failed" : "completed"),
        "content": .array([.object([
          "type": .string("content"), "content": ACP.ContentBlock.text(result.text).json
        ])]),
      ]),
    ]))
  }

  // MARK: - Permission bridge

  /// Asks the editor to approve a tool call, mapping its answer to a decision.
  /// Called by `ACPPermissionBridge` on the runtime's approval path.
  func requestPermission(_ request: ApprovalRequest, sessionID: String?) async -> ApprovalDecision {
    guard let peer, let sessionID, sessions[sessionID]?.task != nil, connected else {
      return .deny(reason: "no ACP client is connected")
    }
    do { try authorize() } catch { return .deny(reason: "Peer authorization was revoked") }
    let toolCall: JSONValue = .object([
      "toolCallId": .string(request.call.id),
      "rawInput": request.call.arguments,
      "status": .string("pending"),
      "title": .string(request.tool.annotations.title ?? request.tool.name),
      "kind": .string(request.tool.annotations.readOnly ? "read" : "edit"),
    ])
    let options: JSONValue = .array([
      .object([
        "optionId": .string("allow_once"), "name": .string("Allow"), "kind": .string("allow_once"),
      ]),
      .object([
        "optionId": .string("reject_once"), "name": .string("Reject"),
        "kind": .string("reject_once"),
      ]),
    ])
    let params: JSONValue = .object([
      "sessionId": .string(sessionID), "toolCall": toolCall, "options": options,
    ])
    guard
      let outcome = try? await peer.request(
        ACP.Method.requestPermission, params: params, timeout: 0
      )
      .objectValue?["outcome"]?.objectValue
    else {
      return .deny(reason: "the editor did not answer the permission request")
    }
    if outcome["outcome"]?.stringValue == "selected",
      outcome["optionId"]?.stringValue == "allow_once"
    {
      return .approve(arguments: request.call.arguments)
    }
    return .deny(reason: "the editor rejected the tool call")
  }
}

/// Breaks the cycle between the runtime (which needs an approval handler at
/// construction) and the server (which needs the runtime). The runtime is built
/// with `approvalHandler`; the server calls `connect` once it exists.
public final class ACPPermissionBridge: @unchecked Sendable {
  private let lock = NSLock()
  private weak var server: ACPServer?

  public init() {}

  public var approvalHandler: any ApprovalHandler { Handler(bridge: self) }

  func connect(to server: ACPServer) { lock.withLock { self.server = server } }

  fileprivate func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
    guard let server = lock.withLock({ server }) else {
      return .deny(reason: "no ACP server is connected")
    }
    return await server.requestPermission(request, sessionID: AgentExecutionScope.current?.sessionID)
  }

  private struct Handler: ApprovalHandler {
    let bridge: ACPPermissionBridge
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
      await bridge.decide(request)
    }
  }
}
