import Foundation
import MaiCore

/// Adapts the mobile client's host-owned conversations to the CLI agent runtime.
/// Each local chat keeps its own remote session, including across CLI restarts.
public actor OpenCodeProvider: ChatProvider {
  public nonisolated let descriptor: ProviderDescriptor
  private let connection: OpenCodeConnection
  private let sessionFile: URL?
  private let onPermission: (@Sendable (JSONValue) async throws -> String?)?
  private var active: [String: OpenCodeClient] = [:]
  private var sessionIDs: [String: String] = [:]
  private var internetAccess = InternetAccessPolicy()

  public init(id: ProviderID, connection: OpenCodeConnection, sessionFile: URL? = nil,
    onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil
  ) {
    descriptor = .init(id: id, displayName: connection.name,
      capabilities: [.streaming, .reasoning, .nativeToolCalling, .managedToolLoop])
    self.connection = connection
    self.sessionFile = sessionFile
    self.onPermission = onPermission
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    // The host owns its selected model and agent, just as it owns its tool loop.
    [.init(id: descriptor.id.rawValue, displayName: descriptor.displayName)]
  }

  public func configureInternetAccess(_ policy: InternetAccessPolicy) async {
    internetAccess = policy
    if policy.isOffline {
      for client in active.values { await client.cancel(); await client.disconnect() }
    }
  }

  public func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler)
    async throws -> ProviderResponse
  {
    guard !internetAccess.isOffline else { throw InternetAccessError.offline }
    let key = AgentExecutionScope.directory.standardizedFileURL.path + "\u{0}"
      + (request.sessionID ?? AgentExecutionScope.current?.sessionID ?? "default")
    guard active[key] == nil else {
      throw JSONRPCError.invalidParams("An OpenCode prompt is already running for this conversation")
    }
    let sessions = try loadSessions()
    let output = OpenCodeProviderOutput()
    let client = OpenCodeClient(connection: connection, sessionID: sessions[key],
      onUpdate: { await output.update($0) }, onPermission: onPermission)
    active[key] = client
    defer { active[key] = nil }
    do {
      let id = try await client.connect()
      try saveSession(id, key: key)
      await output.begin(emit)
      let reason = try await client.prompt(ACPProvider.latestUserText(request.messages), emit: { _ in })
      await client.disconnect()
      return await ProviderResponse(message: output.message, usage: nil, stopReason: reason)
    } catch {
      await client.disconnect()
      throw error
    }
  }

  private func loadSessions() throws -> [String: String] {
    guard let sessionFile, FileManager.default.fileExists(atPath: sessionFile.path) else { return sessionIDs }
    return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: sessionFile))
  }

  private func saveSession(_ id: String, key: String) throws {
    sessionIDs[key] = id
    guard let sessionFile else { return }
    try ACPStateFiles.createDirectory(sessionFile.deletingLastPathComponent())
    let lock = try ACPFileLock(url: sessionFile.appendingPathExtension("lock"), wait: true)
    defer { withExtendedLifetime(lock) {} }
    var sessions = try loadSessions()
    sessions[key] = id
    try ACPStateFiles.write(sessions, to: sessionFile)
  }
}

/// OpenCode sends replacement snapshots. Emit only new parts from this turn,
/// while retaining the latest complete text as the authoritative response.
private actor OpenCodeProviderOutput {
  private var snapshot: [JSONValue] = []
  private var baseline: Set<String> = []
  private var previous: [String: JSONValue] = [:]
  private var emit: ProviderEventHandler?

  func begin(_ emit: @escaping ProviderEventHandler) {
    baseline = Set(snapshot.compactMap { $0.objectValue?["remoteID"]?.stringValue })
    self.emit = emit
  }

  func update(_ update: JSONValue) async {
    guard let fields = update.objectValue,
      fields["sessionUpdate"]?.stringValue == "_pmai/message_snapshot",
      let messages = fields["messages"]?.arrayValue else { return }
    snapshot = messages
    guard let emit else { return }
    for message in messages {
      guard let fields = message.objectValue, let id = fields["remoteID"]?.stringValue,
        !baseline.contains(id) else { continue }
      let old = previous[id]?.objectValue
      previous[id] = message
      let text = fields["text"]?.stringValue ?? ""
      switch fields["role"]?.stringValue {
      case "assistant", "thought":
        let before = old?["text"]?.stringValue ?? ""
        guard text.hasPrefix(before), text != before else { continue }
        let delta = String(text.dropFirst(before.count))
        await emit(fields["role"] == .string("thought") ? .reasoningDelta(delta) : .textDelta(delta))
      case "tool":
        let call = ToolCall(id: fields["toolID"]?.stringValue ?? id,
          name: fields["toolName"]?.stringValue ?? "OpenCode tool",
          arguments: fields["toolInput"] ?? .object([:]))
        if old == nil { await emit(.toolStarted(call)) }
        else if old?["toolInput"] != fields["toolInput"] { await emit(.toolUpdated(call)) }
        if let status = fields["status"]?.stringValue, ["completed", "failed"].contains(status),
          old?["status"] != fields["status"] {
          await emit(.toolFinished(.init(callID: call.id, text: text, isError: status == "failed")))
        }
      default: break
      }
    }
  }

  var message: AgentMessage {
    var content: [ContentPart] = []
    for message in snapshot {
      guard let fields = message.objectValue, let id = fields["remoteID"]?.stringValue,
        !baseline.contains(id), let text = fields["text"]?.stringValue, !text.isEmpty else { continue }
      if fields["role"] == .string("assistant") { content.append(.text(text)) }
      if fields["role"] == .string("thought") { content.append(.reasoning(text)) }
    }
    return .init(role: .assistant, content: content)
  }
}
