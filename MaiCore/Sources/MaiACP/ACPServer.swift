import Foundation
import MaiCore

/// Exposes a MaiCore `AgentRuntime` to any ACP client (Zed, JetBrains, …) over
/// stdio. It is deliberately thin: `session/prompt` becomes one
/// `AgentRuntime.run`, provider deltas become `session/update` notifications,
/// and a tool that needs approval becomes a `session/request_permission` the
/// editor answers. All the agent logic stays in the runtime.
public actor ACPServer {
  private struct Session {
    var transcript: [AgentMessage]
    var workingDirectory: URL
    var task: Task<AgentResult, Error>?
  }

  private let runtime: AgentRuntime
  private let agent: AgentDefinition
  private let bridge: ACPPermissionBridge
  private var peer: JSONRPCPeer?
  private var sessions: [String: Session] = [:]
  private var nextSession = 0

  /// - Parameters:
  ///   - runtime: built with `bridge.approvalHandler` so tool approvals reach
  ///     the editor instead of being denied.
  ///   - agent: the definition each session runs.
  public init(runtime: AgentRuntime, agent: AgentDefinition, bridge: ACPPermissionBridge) {
    self.runtime = runtime
    self.agent = agent
    self.bridge = bridge
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
    bridge.connect(to: self)
    await peer.run()
  }

  // MARK: - Requests

  private func handle(method: String, params: JSONValue?) async throws -> JSONValue {
    switch method {
    case ACP.Method.initialize:
      return initializeResult()
    case ACP.Method.authenticate:
      return .object([:])
    case ACP.Method.sessionNew:
      return newSession(params: params)
    case ACP.Method.sessionPrompt:
      return try await runPrompt(params: params)
    default:
      throw JSONRPCError.methodNotFound(method)
    }
  }

  private func handleNotification(method: String, params: JSONValue?) async {
    guard method == ACP.Method.sessionCancel else { return }
    guard let id = params?.objectValue?["sessionId"]?.stringValue else { return }
    sessions[id]?.task?.cancel()
  }

  private func initializeResult() -> JSONValue {
    .object([
      "protocolVersion": .integer(ACP.protocolVersion),
      "agentInfo": .object([
        "name": .string(ACP.agentName), "version": .string("1.0.0"),
      ]),
      "agentCapabilities": .object([
        "loadSession": .bool(false),
        "promptCapabilities": .object([
          "image": .bool(false), "audio": .bool(false), "embeddedContext": .bool(true),
        ]),
      ]),
      "authMethods": .array([]),
    ])
  }

  private func newSession(params: JSONValue?) -> JSONValue {
    nextSession += 1
    let id = "pmai-\(Int(Date().timeIntervalSince1970))-\(nextSession)"
    let cwd = params?.objectValue?["cwd"]?.stringValue
    let workingDirectory =
      cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    sessions[id] = Session(
      transcript: AgentChat.initialHistory(for: agent), workingDirectory: workingDirectory)
    return .object(["sessionId": .string(id)])
  }

  private func runPrompt(params: JSONValue?) async throws -> JSONValue {
    guard let id = params?.objectValue?["sessionId"]?.stringValue, sessions[id] != nil else {
      throw JSONRPCError.invalidParams("unknown sessionId")
    }
    let text = ACP.promptText(params?.objectValue?["prompt"])
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw JSONRPCError.invalidParams("prompt is empty")
    }
    sessions[id]?.transcript.append(.user(text))

    let request = AgentRequest(
      agentID: agent.id,
      provider: agent.provider,
      model: agent.model,
      messages: sessions[id]!.transcript,
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
      toolDelegation: agent.toolDelegation,
      sessionID: id)

    let sessionID = id
    let task = Task { [weak self, runtime] in
      try await runtime.run(request) { [weak self] event in
        await self?.forward(event, session: sessionID)
      }
    }
    sessions[id]?.task = task

    do {
      let result = try await task.value
      sessions[id]?.transcript = result.transcript
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
      sessions[id]?.task = nil
      return .object(["stopReason": .string(ACP.StopReason.cancelled.rawValue)])
    } catch {
      sessions[id]?.task = nil
      // A run that never produced text should still tell the editor why.
      await update(session: id, kind: .agentMessageChunk, text: error.localizedDescription)
      return .object(["stopReason": .string(ACP.StopReason.refusal.rawValue)])
    }
  }

  // MARK: - Streaming out

  private func forward(_ event: AgentEvent, session id: String) async {
    // Child agents report through the same handler; the editor gets the served
    // agent's own stream, and children stay behind the tool result they become.
    switch event {
    case .provider(let context, .textDelta(let text)) where context.depth == 0 && !text.isEmpty:
      await update(session: id, kind: .agentMessageChunk, text: text)
    case .provider(let context, .reasoningDelta(let text))
    where context.depth == 0 && !text.isEmpty:
      await update(session: id, kind: .agentThoughtChunk, text: text)
    case .toolStarted(let context, let call) where context.depth == 0:
      await toolUpdate(session: id, name: call.name)
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

  private func toolUpdate(session id: String, name: String) async {
    try? peer?.notify(
      ACP.Method.sessionUpdate,
      params: .object([
        "sessionId": .string(id),
        "update": .object([
          "sessionUpdate": .string(ACP.Update.toolCall.rawValue),
          "title": .string(name),
          "status": .string("in_progress"),
        ]),
      ]))
  }

  // MARK: - Permission bridge

  /// Asks the editor to approve a tool call, mapping its answer to a decision.
  /// Called by `ACPPermissionBridge` on the runtime's approval path.
  func requestPermission(_ request: ApprovalRequest) async -> ApprovalDecision {
    guard let peer, let sessionID = sessions.keys.first else {
      return .deny(reason: "no ACP client is connected")
    }
    let toolCall: JSONValue = .object([
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
      outcome["optionId"]?.stringValue?.hasPrefix("allow") == true
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
    return await server.requestPermission(request)
  }

  private struct Handler: ApprovalHandler {
    let bridge: ACPPermissionBridge
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
      await bridge.decide(request)
    }
  }
}
