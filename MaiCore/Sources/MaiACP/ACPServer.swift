import Foundation
import MaiCore
import MaiStandardTools

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
    var title: String?
    var createdAt: Date?
    var updatedAt: Date?
    var definition: AgentDefinition?
    /// Keeps the chat's tool selection intact while tools are temporarily off.
    var toolsEnabled: Bool?
    var providerSessionID: String?
    var indexed: Bool?
  }

  private struct Session {
    var saved: SavedSession
    var task: Task<AgentResult, Error>?
    var lease: ACPFileLock?
    var processes: [AgentPID] = []
    var busy = false
  }

  private let runtime: AgentRuntime
  private let agent: AgentDefinition
  private let bridge: ACPPermissionBridge
  private var peer: JSONRPCPeer?
  private var sessions: [String: Session] = [:]
  private var yoloSessionIDs = Set<String>()
  private var loadingSessions = Set<String>()
  private var modelCatalogs: [ProviderID: [ModelDescriptor]] = [:]
  private var fileSystems: [String: MaiWorkspaceFiles] = [:]
  private let sessionDirectory: URL?
  private let workspaceRoots: [URL]?
  private let workspace: (any ACPWorkspaceRepository)?
  private let fileConfiguration: MaiFileWorkspaceConfiguration?
  private let authorize: @Sendable () throws -> Void
  private let extensionHandler: @Sendable (String, JSONValue?) throws -> JSONValue?
  private var connected = false
  private var initialized = false
  private var connectedAt = Date()

  private static let toolsEnabledOptionID = "tools.enabled"
  private static let toolOptionPrefix = "tools.tool."

  /// - Parameters:
  ///   - runtime: built with `bridge.approvalHandler` so tool approvals reach
  ///     the editor instead of being denied.
  ///   - agent: the definition each session runs.
  public init(
    runtime: AgentRuntime, agent: AgentDefinition, bridge: ACPPermissionBridge,
    sessionDirectory: URL? = nil, workspaceRoot: URL? = nil, workspaceRoots: [URL]? = nil,
    workspace: (any ACPWorkspaceRepository)? = nil,
    fileConfiguration: MaiFileWorkspaceConfiguration? = nil,
    authorize: @escaping @Sendable () throws -> Void = {},
    extensionHandler: @escaping @Sendable (String, JSONValue?) throws -> JSONValue? = { _, _ in nil
    }
  ) {
    self.runtime = runtime
    self.agent = agent
    self.bridge = bridge
    self.sessionDirectory = sessionDirectory
    self.workspaceRoots = (workspaceRoots ?? workspaceRoot.map { [$0] })?.map {
      $0.resolvingSymlinksInPath().standardizedFileURL
    }
    self.workspace = workspace
    self.fileConfiguration = fileConfiguration
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
      for pid in session.processes {
        await runtime.supervisor.stop(pid, reason: "ACP disconnected")
      }
    }
    let tasks = sessions.values.compactMap(\.task)
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
    sessions.removeAll()
    yoloSessionIDs.removeAll()
    for fileSystem in fileSystems.values { await fileSystem.close() }
    fileSystems.removeAll()
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
      return try await newSession(params: params)
    case ACP.Method.sessionLoad:
      return try await loadSession(params: params)
    case ACP.Method.sessionList:
      return try await listSessions(params: params)
    case ACP.Method.sessionManage:
      return try await manageSession(params: params)
    case ACP.Method.sessionRewind:
      return try await rewindSession(params: params)
    case ACP.Method.sessionRunTool:
      return try await runTool(params: params)
    case ACP.Method.workspaceFiles:
      return try await workspaceFiles(params: params)
    case "ping":
      return .object([:])
    case ACP.Method.sessionPrompt:
      return try await runPrompt(params: params)
    case ACP.Method.sessionSetConfigOption:
      return try await setConfigurationOption(params: params)
    default:
      throw JSONRPCError.methodNotFound(method)
    }
  }

  private func handleNotification(method: String, params: JSONValue?) async {
    guard connected, (try? authorize()) != nil, method == ACP.Method.sessionCancel else { return }
    guard let id = params?.objectValue?["sessionId"]?.stringValue else { return }
    sessions[id]?.task?.cancel()
    for pid in sessions[id]?.processes ?? [] {
      await runtime.supervisor.stop(pid, reason: "ACP cancelled")
    }
  }

  private func initializeResult() -> JSONValue {
    .object([
      "protocolVersion": .integer(ACP.protocolVersion),
      "agentInfo": .object([
        "name": .string(ACP.agentName), "version": .string("1.0.0"),
      ]),
      "agentCapabilities": .object([
        "_meta": .object(["pmai": .object([
          "workspaceFiles": .integer(1), "permissionEditing": .integer(1), "yolo": .integer(1),
          "historyRewind": .integer(1),
        ])]),
        "loadSession": .bool(sessionDirectory != nil || workspace != nil),
        "sessionCapabilities": .object(
          sessionDirectory != nil || workspace != nil ? ["list": .object([:])] : [:]),
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
      isDirectory.boolValue
    else {
      throw JSONRPCError.invalidParams("cwd does not exist on the worker")
    }
    if !canAccess(url) {
      throw JSONRPCError.invalidParams("cwd is outside the served workspace")
    }
    // Do not silently accept client-supplied executables that were never installed.
    if let servers = params?.objectValue?["mcpServers"]?.arrayValue, !servers.isEmpty {
      throw JSONRPCError.invalidParams("Configure MCP servers in the worker's pmai config.")
    }
    return url
  }

  private func canAccess(_ url: URL) -> Bool {
    guard let roots = workspaceRoots else { return true }
    return roots.contains { root in
      url == root || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }
  }

  private func workspaceFiles(params: JSONValue?) async throws -> JSONValue {
    let cwd = try directory(params: params)
    guard let body = params?.objectValue?["request"] else {
      throw JSONRPCError.invalidParams("A filesystem request is required")
    }
    let request = try JSONDecoder().decode(
      WorkspaceFileRequest.self, from: JSONEncoder().encode(body))
    let files: MaiWorkspaceFiles
    if let existing = fileSystems[cwd.path] {
      files = existing
    } else {
      guard fileSystems.count < 16 else {
        throw JSONRPCError.invalidParams("Too many open workspaces")
      }
      var configuration = fileConfiguration ?? .init(rootURL: cwd)
      configuration.rootURL = cwd
      configuration.followsProcessWorkingDirectory = false
      configuration.additionalAllowedURLs = []
      files = MaiWorkspaceFiles(configuration: configuration)
      fileSystems[cwd.path] = files
    }
    let response = try await files.request(request)
    return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
  }

  /// Executes the terminal's one explicit `run_shell` call. It deliberately
  /// does not create a session or add terminal history to a conversation.
  private func runTool(params: JSONValue?) async throws -> JSONValue {
    let cwd = try directory(params: params)
    guard let tool = params?.objectValue?["tool"]?.objectValue,
      tool["name"]?.stringValue == MaiRunTool.name,
      var arguments = tool["arguments"]?.objectValue
    else {
      throw JSONRPCError.invalidParams("Only an enabled run_shell tool call is supported.")
    }
    // The client selects a served project, rather than getting to replace the
    // run tool's starting directory inside its argument object.
    arguments["cwd"] = .string(cwd.path)
    let call = ToolCall(
      id: UUID().uuidString.lowercased(), name: MaiRunTool.name, arguments: .object(arguments))
    let scope = AgentExecutionScope(sessionID: "terminal:\(call.id)", workingDirectory: cwd)
    let result = try await AgentExecutionScope.$current.withValue(scope) {
      try await runtime.runTool(call, for: agent)
    }
    return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
  }

  private func listSessions(params: JSONValue?) async throws -> JSONValue {
    guard sessionDirectory != nil || workspace != nil else {
      throw JSONRPCError.methodNotFound(ACP.Method.sessionList)
    }
    let filter = params?.objectValue?["cwd"] == nil ? nil : try directory(params: params)
    func included(_ path: String) -> Bool {
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      return canAccess(url) && (filter == nil || url == filter)
    }
    var snapshot = try await workspace?.snapshot() ?? ACPWorkspaceSnapshot()
    // Filter before returning any metadata, including names of empty projects.
    snapshot.folders = snapshot.folders.filter { included($0.cwd) }
    for root in workspaceRoots ?? [] where included(root.path) {
      let hasProject = snapshot.folders.contains {
        let path = URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().standardizedFileURL.path
        return path == root.path
          || path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
      }
      var isDirectory: ObjCBool = false
      if !hasProject, FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        snapshot.folders.append(
          .init(
            cwd: root.path,
            name: AgentProject.defaultName(forWorkingDirectory: root.path) ?? root.path))
      }
    }
    var byID = Dictionary(
      snapshot.sessions.filter { included($0.cwd) }
        .map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
    if let sessionDirectory,
      let files = try? FileManager.default.contentsOfDirectory(
        at: sessionDirectory, includingPropertiesForKeys: nil)
    {
      for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
          let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
          let uuid = UUID(uuidString: saved.id), uuid.uuidString.lowercased() == saved.id,
          file.lastPathComponent == saved.id + ".json",
          saved.agentID == agent.id, included(saved.workingDirectory.path)
        else { continue }
        if workspace != nil {
          if saved.indexed == true {
            // Forgetting a project must not resurrect it from an ACP checkpoint.
            guard snapshot.folders.contains(where: { $0.cwd == saved.workingDirectory.path }) else {
              continue
            }
          } else if let migrationLease = try? lease(saved.id) {
            // Adopt pre-index sessions once without touching another client's
            // live transcript. Original session IDs and history are retained.
            if try await workspace?.load(sessionID: saved.id, cwd: saved.workingDirectory.path) != nil {
              var checkpoint = saved
              checkpoint.indexed = true
              try ACPStateFiles.write(checkpoint, to: file)
              guard snapshot.folders.contains(where: { $0.cwd == saved.workingDirectory.path }) else { continue }
            } else {
              try await save(saved)
            }
            withExtendedLifetime(migrationLease) {}
          }
        }
        let title =
          saved.title ?? saved.transcript.first(where: { $0.role == .user })
          .flatMap { AgentChat.derivedTitle(from: $0.text) } ?? AgentChat.placeholderTitle
        let info = ACPSessionInfo(
          sessionID: saved.id, cwd: saved.workingDirectory.path,
          title: title, updatedAt: saved.updatedAt)
        if byID[saved.id] == nil { byID[saved.id] = info }
      }
    }
    let infos = byID.values.sorted {
      if $0.updatedAt != $1.updatedAt {
        return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
      }
      return $0.sessionID < $1.sessionID
    }
    for info in infos where !snapshot.folders.contains(where: { $0.cwd == info.cwd }) {
      snapshot.folders.append(
        .init(
          cwd: info.cwd,
          name: AgentProject.defaultName(forWorkingDirectory: info.cwd) ?? info.cwd))
    }
    return .object([
      "sessions": .array(infos.map(\.json)),
      "_meta": .object([
        "pmai": .object([
          "folders": .array(snapshot.folders.map(\.json)), "canManageSessions": .bool(true),
        ])
      ])
    ])
  }

  private func lease(_ id: String) throws -> ACPFileLock? {
    guard let sessionDirectory else { return nil }
    try ACPStateFiles.createDirectory(sessionDirectory)
    return try ACPFileLock(url: sessionDirectory.appendingPathComponent(id + ".lock"))
  }

  private func save(_ session: SavedSession) async throws {
    var checkpoint = session
    checkpoint.title = session.title ?? session.transcript.first(where: { $0.role == .user })
      .flatMap { AgentChat.derivedTitle(from: $0.text) } ?? AgentChat.placeholderTitle
    if let workspace {
      try await workspace.save(
        .init(
          info: .init(
            sessionID: session.id, cwd: session.workingDirectory.path,
            title: checkpoint.title ?? AgentChat.placeholderTitle, updatedAt: session.updatedAt),
          agent: session.definition ?? agent, transcript: session.transcript,
          createdAt: session.createdAt ?? Date(),
          providerSessionID: session.providerSessionID ?? session.id))
      checkpoint.indexed = true
    }
    if let sessionDirectory {
      try ACPStateFiles.write(
        checkpoint, to: sessionDirectory.appendingPathComponent(session.id + ".json"))
    }
  }

  private func newSession(params: JSONValue?) async throws -> JSONValue {
    let cwd = try directory(params: params)
    let id = UUID().uuidString.lowercased()
    let saved = SavedSession(
      id: id, agentID: agent.id, workingDirectory: cwd,
      transcript: AgentChat.initialHistory(for: agent), title: AgentChat.placeholderTitle,
      createdAt: Date(), updatedAt: Date())
    let lock = try lease(id)
    try await save(saved)
    guard connected else { throw JSONRPCTransportError.closed }
    sessions[id] = Session(saved: saved, lease: lock)
    let options = await configurationOptions(for: agent)
    await messageSnapshot(session: id)
    return .object(["sessionId": .string(id), "configOptions": .array(options.map(\.json))])
  }

  private func manageSession(params: JSONValue?) async throws -> JSONValue {
    guard let title = params?.objectValue?["title"],
      title == .null
        || title.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else { throw JSONRPCError.invalidParams("Provide a nonempty title, or null to delete") }
    let id = params?.objectValue?["sessionId"]?.stringValue ?? ""
    let wasLoaded = sessions[id] != nil
    _ = try await loadSession(params: params, replay: false)
    sessions[id]?.busy = true
    defer {
      if wasLoaded { sessions[id]?.busy = false } else { sessions.removeValue(forKey: id) }
    }
    guard var saved = sessions[id]?.saved else {
      throw JSONRPCError.invalidParams("Unknown session")
    }
    if title == .null {
      if let file = sessionDirectory?.appendingPathComponent(id + ".json"),
        FileManager.default.fileExists(atPath: file.path)
      {
        try FileManager.default.removeItem(at: file)
      }
      try await workspace?.delete(sessionID: id, cwd: saved.workingDirectory.path)
      sessions.removeValue(forKey: id)
    } else {
      saved.title = title.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      saved.updatedAt = Date()
      try await save(saved)
      sessions[id]?.saved = saved
    }
    return .object([:])
  }

  private func loadSession(params: JSONValue?, replay: Bool = true) async throws -> JSONValue {
    guard let id = params?.objectValue?["sessionId"]?.stringValue,
      let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id
    else {
      throw JSONRPCError.invalidParams("Unknown sessionId")
    }
    let cwd = try directory(params: params)
    guard sessions[id]?.busy != true, loadingSessions.insert(id).inserted else {
      throw JSONRPCError.invalidParams("Session is busy")
    }
    defer { loadingSessions.remove(id) }
    if sessions[id] == nil {
      let lock = try lease(id)
      let file = sessionDirectory?.appendingPathComponent(id + ".json")
      let checkpoint = file.flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }
      var restored: SavedSession?
      if let conversation = try await workspace?.load(sessionID: id, cwd: cwd.path) {
        restored = SavedSession(
          id: id, agentID: agent.id, workingDirectory: cwd,
          transcript: conversation.transcript, promptInFlight: checkpoint?.promptInFlight,
          title: conversation.info.title, createdAt: conversation.createdAt,
          updatedAt: conversation.info.updatedAt, definition: conversation.agent,
          providerSessionID: conversation.providerSessionID)
      } else {
        restored = checkpoint
      }
      guard var saved = restored, saved.id == id, saved.agentID == agent.id,
        saved.workingDirectory == cwd
      else {
        throw JSONRPCError.invalidParams("Session does not belong to this agent and workspace")
      }
      saved.title = saved.title ?? saved.transcript.first(where: { $0.role == .user })
        .flatMap { AgentChat.derivedTitle(from: $0.text) }
      if saved.promptInFlight == true {
        saved.transcript.append(.assistant(Self.interruptedPromptNotice))
        saved.promptInFlight = false
        try await save(saved)
      }
      guard connected else { throw JSONRPCTransportError.closed }
      sessions[id] = Session(saved: saved, lease: lock)
    }
    guard let session = sessions[id], session.saved.workingDirectory == cwd else {
      throw JSONRPCError.invalidParams("Session working directory differs")
    }
    if !replay { return .object([:]) }
    for message in session.saved.transcript {
      switch message.role {
      case .user:
        await update(session: id, kind: .userMessageChunk, text: message.text)
      case .assistant:
        if !message.text.isEmpty {
          await update(session: id, kind: .agentMessageChunk, text: message.text)
        }
        for call in message.toolCalls { await toolUpdate(session: id, call: call) }
      case .tool:
        for result in message.toolResults { await toolFinished(session: id, result: result) }
      default: break
      }
    }
    await messageSnapshot(session: id)
    let options = await configurationOptions(
      for: session.saved.definition ?? agent, toolsEnabled: session.saved.toolsEnabled ?? true)
    return .object(["configOptions": .array(options.map(\.json))])
  }

  /// Removes the selected transcript entry and all later entries, leaving the
  /// agent's configured system/developer context and workspace unchanged.
  private func rewindSession(params: JSONValue?) async throws -> JSONValue {
    guard let fields = params?.objectValue, let id = fields["sessionId"]?.stringValue,
      var saved = sessions[id]?.saved
    else { throw JSONRPCError.invalidParams("Unknown session") }
    guard sessions[id]?.busy != true, !loadingSessions.contains(id) else {
      throw JSONRPCError.invalidParams("A prompt is already running in this session")
    }
    let boundary = fields["messageId"]?.stringValue
    let end: Int
    if let boundary {
      guard let index = saved.transcript.firstIndex(where: { $0.id == boundary }) else {
        throw JSONRPCError.invalidParams("This message is no longer in the conversation")
      }
      end = index
    } else {
      // A reset starts from the agent's initial instructions, not a blank
      // transcript, matching local PocketMai's "Reset Chat From Here" action.
      end = saved.transcript.prefix {
        $0.role == .system || $0.role == .developer
      }.count
    }
    saved.transcript = Array(saved.transcript.prefix(end))
    saved.promptInFlight = false
    saved.updatedAt = Date()
    sessions[id]?.saved = saved
    try await save(saved)
    await messageSnapshot(session: id)
    return .object([:])
  }

  private func configurationOptions(
    for definition: AgentDefinition, toolsEnabled: Bool = true
  ) async -> [RemoteSessionOption] {
    let providers = await runtime.availableProviders()
    let displayNameCounts = Dictionary(grouping: providers, by: \.displayName).mapValues(\.count)
    var providerChoices = providers.map { provider in
      let name = provider.displayName
      // Several configured connections commonly share the factory's generic
      // label (for example, "OpenAI-compatible"). Include the configured ID
      // in that case so remote clients can tell those connections apart.
      let label = displayNameCounts[name, default: 0] > 1
        ? "\(provider.id.rawValue) · \(name)"
        : name
      return RemoteSessionOption.Choice(provider.id.rawValue, label)
    }
    if !providerChoices.contains(where: { $0.id == definition.provider.rawValue }) {
      providerChoices.append(.init(definition.provider.rawValue, definition.provider.rawValue))
    }
    if modelCatalogs[definition.provider] == nil,
      let models = try? await runtime.availableModels(provider: definition.provider)
    {
      modelCatalogs[definition.provider] = models
    }
    var models = (modelCatalogs[definition.provider] ?? []).map {
      RemoteSessionOption.Choice($0.id, $0.displayName)
    }
    for model in [
      providers.first(where: { $0.id == definition.provider })?.defaultModel, definition.model,
    ].compactMap({ $0 })
    where !models.contains(where: { $0.id == model }) {
      models.append(.init(model, model.isEmpty ? "Provider default" : model))
    }
    let effort = definition.options.reasoningEffort ?? ReasoningEffort.automatic.rawValue
    var efforts = ReasoningEffort.allCases.map {
      RemoteSessionOption.Choice($0.rawValue, $0.displayName)
    }
    if !efforts.contains(where: { $0.id == effort }) { efforts.append(.init(effort, effort)) }
    let definitions = await runtime.availableTools()
    let groups = await runtime.availableToolGroups()
    let modes = definition.toolModes(in: groups, usage: await runtime.toolUsageSnapshot())
    var groupNamesByTool: [String: String] = [:]
    for group in groups.sorted(by: { $0.catalogID < $1.catalogID }) {
      for name in group.toolNames where groupNamesByTool[name] == nil {
        groupNamesByTool[name] = group.displayName
      }
    }
    let toolOptions = definitions.map { tool in
      return RemoteSessionOption(
        id: Self.toolOptionPrefix + tool.name, name: tool.name,
        category: "tools/\(groupNamesByTool[tool.name] ?? "Other")",
        description: tool.description,
        currentValue: .bool(toolsEnabled && modes[tool.name, default: .disabled] != .disabled))
    }
    return [
      .init(
        id: "provider", name: "Provider", category: "_provider",
        currentValue: .string(definition.provider.rawValue), choices: providerChoices),
      .init(
        id: "model", name: "Model", category: "model", currentValue: .string(definition.model),
        choices: models),
      .init(
        id: "reasoning", name: "Reasoning", category: "thought_level",
        currentValue: .string(effort), choices: efforts),
      .init(
        id: Self.toolsEnabledOptionID, name: "Enable Tools", category: "tools",
        currentValue: .bool(toolsEnabled)),
    ] + toolOptions
  }

  private func setConfigurationOption(params: JSONValue?) async throws -> JSONValue {
    guard let fields = params?.objectValue, let id = fields["sessionId"]?.stringValue,
      let key = fields["configId"]?.stringValue, let value = fields["value"],
      var saved = sessions[id]?.saved
    else { throw JSONRPCError.invalidParams("Unknown session or setting") }
    guard sessions[id]?.busy != true, !loadingSessions.contains(id) else {
      throw JSONRPCError.invalidParams("Session is busy")
    }
    sessions[id]?.busy = true
    defer { sessions[id]?.busy = false }
    var definition = saved.definition ?? agent
    let toolsEnabled = saved.toolsEnabled ?? true
    let available = await configurationOptions(for: definition, toolsEnabled: toolsEnabled)
    guard available.first(where: { $0.id == key })?.accepts(value) == true else {
      throw JSONRPCError.invalidParams("Choose an available setting")
    }
    switch key {
    case "provider":
      guard let value = value.stringValue else {
        throw JSONRPCError.invalidParams("Choose an available setting")
      }
      if definition.provider.rawValue != value {
        guard
          let provider = await runtime.availableProviders().first(where: { $0.id.rawValue == value }
          )
        else {
          throw JSONRPCError.invalidParams("Provider is unavailable")
        }
        definition.provider = provider.id
        if modelCatalogs[provider.id] == nil {
          modelCatalogs[provider.id] = try? await runtime.availableModels(provider: provider.id)
        }
        definition.model = provider.defaultModel ?? modelCatalogs[provider.id]?.first?.id ?? ""
      }
    case "model":
      guard let value = value.stringValue else {
        throw JSONRPCError.invalidParams("Choose an available setting")
      }
      definition.model = value
    case "reasoning":
      guard let value = value.stringValue else {
        throw JSONRPCError.invalidParams("Choose an available setting")
      }
      definition.options.reasoningEffort = value == "automatic" ? nil : value
    case Self.toolsEnabledOptionID:
      guard let enabled = value.boolValue else {
        throw JSONRPCError.invalidParams("Choose an available setting")
      }
      saved.toolsEnabled = enabled
    case let key where key.hasPrefix(Self.toolOptionPrefix):
      guard let enabled = value.boolValue else {
        throw JSONRPCError.invalidParams("Choose an available setting")
      }
      let name = String(key.dropFirst(Self.toolOptionPrefix.count))
      guard (await runtime.availableTools()).contains(where: { $0.name == name }) else {
        throw JSONRPCError.invalidParams("Choose an available tool")
      }
      definition.setToolMode(enabled ? .direct : .disabled, for: name)
    default: throw JSONRPCError.invalidParams("Unknown setting")
    }
    let options = await configurationOptions(
      for: definition, toolsEnabled: saved.toolsEnabled ?? true)
    guard connected, sessions[id] != nil else { throw JSONRPCTransportError.closed }
    saved.definition = definition
    saved.updatedAt = Date()
    try await save(saved)
    sessions[id]?.saved = saved
    let json = JSONValue.array(options.map(\.json))
    try peer?.notify(
      ACP.Method.sessionUpdate,
      params: .object([
        "sessionId": .string(id),
        "update": .object([
          "sessionUpdate": .string("config_option_update"), "configOptions": json,
        ]),
      ]))
    return .object(["configOptions": json])
  }

  private func runPrompt(params: JSONValue?) async throws -> JSONValue {
    guard let id = params?.objectValue?["sessionId"]?.stringValue, sessions[id] != nil else {
      throw JSONRPCError.invalidParams("unknown sessionId")
    }
    guard sessions[id]?.busy != true, !loadingSessions.contains(id) else {
      throw JSONRPCError.invalidParams("A prompt is already running in this session")
    }
    let text = ACP.promptText(params?.objectValue?["prompt"])
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw JSONRPCError.invalidParams("prompt is empty")
    }
    sessions[id]?.busy = true
    defer { sessions[id]?.busy = false }
    sessions[id]?.saved.transcript.append(.user(text))
    if AgentChat.isPlaceholderTitle(sessions[id]?.saved.title ?? AgentChat.placeholderTitle) {
      sessions[id]?.saved.title = AgentChat.derivedTitle(from: text)
    }
    sessions[id]?.saved.updatedAt = Date()
    sessions[id]?.saved.promptInFlight = true
    try await save(sessions[id]!.saved)
    guard connected, sessions[id] != nil else { throw JSONRPCTransportError.closed }

    let agent = sessions[id]?.saved.definition ?? self.agent
    var toolPolicy = agent.toolPolicy
    if sessions[id]?.saved.toolsEnabled == false {
      for group in await runtime.availableToolGroups() {
        toolPolicy.setGroupMode(.disabled, for: group)
      }
      for tool in await runtime.availableTools() {
        toolPolicy.tools[tool.name] = .disabled
      }
    }
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
      toolPolicy: toolPolicy,
      toolDelegation: agent.toolDelegation,
      retry: agent.retry, autocompact: agent.autocompact, context: agent.context,
      sessionID: sessions[id]?.saved.providerSessionID ?? id)

    let sessionID = id
    let scope = AgentExecutionScope(
      sessionID: id, workingDirectory: sessions[id]!.saved.workingDirectory)
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
      } onCancel: {
        task.cancel()
      }
      sessions[id]?.saved.transcript = result.transcript
      sessions[id]?.saved.promptInFlight = false
      sessions[id]?.saved.updatedAt = Date()
      if let saved = sessions[id]?.saved { try await save(saved) }
      sessions[id]?.task = nil
      await messageSnapshot(session: id)
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
          case .time, .toolCalls: .endTurn
          }
        return .object(["stopReason": .string(stopReason.rawValue)])
      }
      return .object(["stopReason": .string(ACP.StopReason(result.stopReason).rawValue)])
    } catch is CancellationError {
      try? await finishInterruptedPrompt(id)
      sessions[id]?.task = nil
      await messageSnapshot(session: id)
      return .object(["stopReason": .string(ACP.StopReason.cancelled.rawValue)])
    } catch {
      try? await finishInterruptedPrompt(id)
      sessions[id]?.task = nil
      await messageSnapshot(session: id)
      // A run that never produced text should still tell the editor why.
      await update(session: id, kind: .agentMessageChunk, text: error.localizedDescription)
      return .object(["stopReason": .string(ACP.StopReason.refusal.rawValue)])
    }
  }

  private static let interruptedPromptNotice =
    "The previous prompt was interrupted. Some tools may already have run and partial output may be missing. Verify the current state before repeating actions."

  private func finishInterruptedPrompt(_ id: String) async throws {
    sessions[id]?.saved.transcript.append(.assistant(Self.interruptedPromptNotice))
    sessions[id]?.saved.promptInFlight = false
    sessions[id]?.saved.updatedAt = Date()
    if let saved = sessions[id]?.saved { try await save(saved) }
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

  /// PocketMai consumes this extension to replace optimistic streaming rows
  /// with durable transcript entries. Standard ACP clients simply ignore it.
  private func messageSnapshot(session id: String) async {
    guard let transcript = sessions[id]?.saved.transcript else { return }
    let messages = transcript.compactMap { message -> JSONValue? in
      guard message.role == .user || message.role == .assistant || message.role == .tool else {
        return nil
      }
      let text: String
      switch message.role {
      case .tool:
        text = message.toolResults.map(\.text).joined(separator: "\n")
      default:
        text = message.text
      }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return .object([
        "remoteID": .string(message.id), "role": .string(message.role.rawValue),
        "text": .string(text),
      ])
    }
    try? peer?.notify(
      ACP.Method.sessionUpdate,
      params: .object([
        "sessionId": .string(id),
        "update": .object([
          "sessionUpdate": .string("_pmai/message_snapshot"), "messages": .array(messages),
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
    try? peer?.notify(
      ACP.Method.sessionUpdate,
      params: .object([
        "sessionId": .string(id),
        "update": .object([
          "sessionUpdate": .string(ACP.Update.toolCallUpdate.rawValue),
          "toolCallId": .string(result.callID),
          "status": .string(result.isError ? "failed" : "completed"),
          "content": .array([
            .object([
              "type": .string("content"), "content": ACP.ContentBlock.text(result.text).json,
            ])
          ]),
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
    if yoloSessionIDs.contains(sessionID) {
      return .approve(arguments: request.call.arguments)
    }
    let toolCall: JSONValue = .object([
      "toolCallId": .string(request.call.id),
      "rawInput": request.call.arguments,
      "status": .string("pending"),
      "title": .string(request.tool.annotations.title ?? request.tool.name),
      "kind": .string(request.tool.annotations.readOnly ? "read" : "edit"),
    ])
    let options: JSONValue = .array([
      .object([
        "optionId": .string("allow_once"), "name": .string("Allow once"),
        "kind": .string("allow_once"),
      ]),
      .object([
        "optionId": .string("allow_always"), "name": .string("Enable YOLO mode"),
        "kind": .string("allow_always"),
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
    guard outcome["outcome"]?.stringValue == "selected" else {
      return .deny(reason: "the editor rejected the tool call")
    }
    let arguments = outcome["rawInput"] ?? request.call.arguments
    switch outcome["optionId"]?.stringValue {
    case "allow_once":
      return .approve(arguments: arguments)
    case "allow_always":
      yoloSessionIDs.insert(sessionID)
      return .approve(arguments: arguments)
    default:
      return .deny(reason: "the editor rejected the tool call")
    }
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
    return await server.requestPermission(
      request, sessionID: AgentExecutionScope.current?.sessionID)
  }

  private struct Handler: ApprovalHandler {
    let bridge: ACPPermissionBridge
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
      await bridge.decide(request)
    }
  }
}
