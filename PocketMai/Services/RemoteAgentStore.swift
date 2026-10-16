import Foundation
import MaiACP
import MaiCore
import Observation
import Security

struct RemoteAgentBookmark: Codable, Identifiable {
  var id = UUID()
  var name: String
  var url: URL
  var cwd: String
  var sessionID: String?
  var messages: [RemoteAgentMessage] = []
  var conversations: [RemoteAgentConversation]?
  var workspace: ACPWorkspaceSnapshot?
  var accentColor: String?
  var requiresApproval: Bool?
  var connectionProtocol: ACPRemoteProtocol?
  var revision: UUID?
  var backend: RemoteAgentBackend?
  var pinnedFolderPaths: [String]?

  func makeClient(
    token: String, cwd: String, sessionID: String? = nil,
    onUpdate: (@Sendable (JSONValue) async -> Void)? = nil,
    onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil,
    onDisconnect: (@Sendable () async -> Void)? = nil
  ) throws -> any RemoteSessionClient {
    if backend == .openCode {
      return OpenCodeClient(
        connection: try .init(name: name, url: url, token: token, cwd: cwd), sessionID: sessionID,
        onUpdate: onUpdate, onPermission: onPermission)
    }
    return ACPClient(
      configuration: .init(
        command: name, permission: .reject, remoteWorkingDirectory: cwd, readClientFiles: false,
        webSocketURL: url, bearerToken: token, sessionID: sessionID),
      onUpdate: onUpdate, onPermission: onPermission, onDisconnect: onDisconnect)
  }
}

struct RemoteAgentConversation: Codable, Identifiable {
  var id = UUID()
  var cwd: String
  var sessionID: String?
  var title = AgentChat.placeholderTitle
  var updatedAt = Date()
  var createdAt: Date? = Date()
  var messages: [RemoteAgentMessage] = []

  var presentation: Conversation {
    var result = Conversation()
    result.id = self.id
    result.title = self.title
    result.createdAt = self.createdAt ?? self.updatedAt
    result.updatedAt = self.updatedAt
    result.messages = messages.map { message in
      var text = message.text
      if message.role == "thought" { text = "<think>\n\(text)\n</think>" }
      if message.role == "tool" || message.role == "plan" {
        text = AgentTooling.makeRunBlock(
          toolName: message.role == "plan" ? "Plan" : "Remote",
          argumentsJSON: "{}",
          result: [message.status, text].compactMap { $0 }.joined(separator: "\n"))
      }
      return ChatMessage(
        id: message.id, role: ChatRole(rawValue: message.role) ?? .assistant, text: text,
        createdAt: message.createdAt ?? result.createdAt)
    }
    return result
  }
}

struct RemoteAgentMessage: Codable, Identifiable {
  var id = UUID()
  var role: String
  var text: String
  var toolID: String?
  var status: String?
  var createdAt: Date? = Date()
  var remoteID: String?
}

@MainActor @Observable
final class RemoteAgentStore {
  static let shared = RemoteAgentStore()
  private(set) var connections: [RemoteAgentBookmark] = []
  var error: String?
  private let file: URL
  private let keychainService = "io.github.trufae.mai.acp-gateway"

  init(file: URL? = nil) {
    let directory =
      file?.deletingLastPathComponent()
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RemoteAgents", isDirectory: true)
    self.file = file ?? directory.appendingPathComponent("connections.json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: self.file.path) {
        connections = try JSONDecoder().decode(
          [RemoteAgentBookmark].self, from: Data(contentsOf: self.file))
        migrateConnections()
      }
    } catch { self.error = error.localizedDescription }
  }

  @discardableResult
  func add(
    _ profile: ACPRemoteConnection, replacing hostID: UUID? = nil, accentColor: String? = nil
  ) throws -> UUID {
    try profile.validate()
    return try add(
      name: profile.name, url: profile.url, token: profile.token, cwd: profile.cwd,
      backend: .acp, requiresApproval: profile.requiresApproval,
      connectionProtocol: profile.connectionProtocol, replacing: hostID, accentColor: accentColor)
  }

  @discardableResult
  func add(
    _ profile: OpenCodeConnection, replacing hostID: UUID? = nil, accentColor: String? = nil
  ) throws -> UUID {
    let validated = try OpenCodeConnection(
      name: profile.name, url: profile.url, token: profile.token, cwd: profile.cwd)
    return try add(
      name: validated.name, url: validated.url, token: validated.token, cwd: validated.cwd,
      backend: .openCode, requiresApproval: false, connectionProtocol: nil,
      replacing: hostID, accentColor: accentColor)
  }

  private func add(
    name: String, url: URL, token: String, cwd: String, backend: RemoteAgentBackend,
    requiresApproval: Bool?, connectionProtocol: ACPRemoteProtocol?,
    replacing hostID: UUID?, accentColor: String?
  ) throws -> UUID {
    // Reimporting the same endpoint updates its token without losing the chat.
    let existing = connections.firstIndex {
      hostID != nil ? $0.id == hostID : $0.url == url
    }
    if let existing,
      connections.contains(where: { $0.url == url && $0.id != connections[existing].id })
    {
      throw JSONRPCError.invalidParams("A host with this gateway URL already exists.")
    }
    let id = existing.map { connections[$0].id } ?? UUID()
    let query = keychainQuery(id)
    let data = Data(token.utf8)
    let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
    if updated == errSecItemNotFound {
      var item = query
      item[kSecValueData] = data
      item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      try check(SecItemAdd(item as CFDictionary, nil))
    } else {
      try check(updated)
    }
    if let existing {
      connections[existing].name = name
      connections[existing].cwd = cwd
      connections[existing].url = url
      connections[existing].accentColor = accentColor
      connections[existing].requiresApproval = requiresApproval
      connections[existing].connectionProtocol = connectionProtocol
      connections[existing].backend = backend
      connections[existing].revision = UUID()
    } else {
      connections.append(
        RemoteAgentBookmark(
          id: id, name: name, url: url, cwd: cwd, accentColor: accentColor,
          requiresApproval: requiresApproval, connectionProtocol: connectionProtocol,
          backend: backend))
    }
    try save()
    return id
  }

  func token(for id: UUID) throws -> String {
    var query = keychainQuery(id)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    try check(SecItemCopyMatching(query as CFDictionary, &result))
    guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
      throw JSONRPCError.invalidParams("Reimport this connection's gateway token")
    }
    return token
  }

  func acceptPairing(_ id: UUID, token: String) throws {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    try check(
      SecItemUpdate(
        keychainQuery(id) as CFDictionary,
        [kSecValueData: Data(token.utf8)] as CFDictionary))
    connections[index].requiresApproval = false
    try save()
  }

  func update(_ hostID: UUID, conversation: RemoteAgentConversation) {
    guard let index = connections.firstIndex(where: { $0.id == hostID }) else { return }
    var chats = connections[index].conversations ?? []
    if let chatIndex = chats.firstIndex(where: { $0.id == conversation.id }) {
      chats[chatIndex] = conversation
    } else {
      chats.append(conversation)
    }
    connections[index].conversations = chats
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func updateWorkspace(_ hostID: UUID, snapshot: ACPWorkspaceSnapshot) {
    guard let index = connections.firstIndex(where: { $0.id == hostID }) else { return }
    connections[index].workspace = snapshot
    var chats = connections[index].conversations ?? []
    for session in snapshot.sessions {
      if let chatIndex = chats.firstIndex(where: { $0.sessionID == session.sessionID }) {
        if chats[chatIndex].messages.isEmpty
          || (session.updatedAt ?? .distantPast) >= chats[chatIndex].updatedAt
        {
          chats[chatIndex].title = session.title
          chats[chatIndex].updatedAt = session.updatedAt ?? chats[chatIndex].updatedAt
        }
      } else {
        chats.append(
          .init(
            id: UUID(uuidString: session.sessionID) ?? UUID(), cwd: session.cwd,
            sessionID: session.sessionID, title: session.title,
            updatedAt: session.updatedAt ?? .distantPast))
      }
    }
    connections[index].conversations = chats
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func deleteConversation(_ id: UUID, hostID: UUID) {
    guard let index = connections.firstIndex(where: { $0.id == hostID }) else { return }
    let sessionID = connections[index].conversations?.first { $0.id == id }?.sessionID
    connections[index].conversations?.removeAll { $0.id == id }
    connections[index].workspace?.sessions.removeAll { $0.sessionID == sessionID }
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func host(_ id: UUID?) -> RemoteAgentBookmark? {
    connections.first { $0.id == id }
  }

  func reconnect(_ id: UUID) {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    connections[index].revision = UUID()
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func rename(_ id: UUID, to name: String) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 200 else {
      throw JSONRPCError.invalidParams("Enter a host name of 1 to 200 characters.")
    }
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    connections[index].name = name
    try save()
  }

  func folders(for host: RemoteAgentBookmark) -> [ACPWorkspaceFolder] {
    var folders = host.workspace?.folders ?? []
    if host.workspace == nil {
      let paths = [host.cwd] + (host.conversations ?? []).map(\.cwd)
      for cwd in paths where !cwd.isEmpty && !folders.contains(where: { $0.cwd == cwd }) {
        folders.append(
          .init(cwd: cwd, name: AgentProject.defaultName(forWorkingDirectory: cwd) ?? cwd))
      }
    }
    let pins = host.pinnedFolderPaths ?? []
    return pins.compactMap { path in folders.first { $0.cwd == path } }
      + folders.filter { !pins.contains($0.cwd) }
  }

  func toggleFolderPin(hostID: UUID, cwd: String) {
    guard let index = connections.firstIndex(where: { $0.id == hostID }),
      folders(for: connections[index]).contains(where: { $0.cwd == cwd })
    else { return }
    var pins = connections[index].pinnedFolderPaths ?? []
    if pins.contains(cwd) { pins.removeAll { $0 == cwd } } else { pins.append(cwd) }
    connections[index].pinnedFolderPaths = pins.isEmpty ? nil : pins
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func conversations(for host: RemoteAgentBookmark) -> [RemoteAgentConversation] {
    (host.conversations ?? []).sorted { $0.updatedAt > $1.updatedAt }
  }

  @discardableResult
  func newConversation(hostID: UUID, cwd: String) -> RemoteAgentConversation {
    let conversation = RemoteAgentConversation(cwd: cwd)
    update(hostID, conversation: conversation)
    return conversation
  }

  private func migrateConnections() {
    var hosts: [RemoteAgentBookmark] = []
    for var connection in connections {
      if connection.conversations == nil {
        connection.conversations = []
        if connection.sessionID != nil || !connection.messages.isEmpty {
          connection.conversations = [
            .init(
              id: connection.id, cwd: connection.cwd,
              sessionID: connection.sessionID,
              title: connection.messages.first(where: { $0.role == "user" })
                .flatMap { AgentChat.derivedTitle(from: $0.text) } ?? AgentChat.placeholderTitle,
              messages: connection.messages)
          ]
        }
        connection.sessionID = nil
        connection.messages = []
      }
      if let index = hosts.firstIndex(where: { $0.url == connection.url }) {
        hosts[index].conversations =
          (hosts[index].conversations ?? []) + (connection.conversations ?? [])
        for path in connection.pinnedFolderPaths ?? []
        where hosts[index].pinnedFolderPaths?.contains(path) != true {
          hosts[index].pinnedFolderPaths = (hosts[index].pinnedFolderPaths ?? []) + [path]
        }
      } else {
        hosts.append(connection)
      }
    }
    connections = hosts
  }

  func remove(_ id: UUID) {
    SecItemDelete(keychainQuery(id) as CFDictionary)
    connections.removeAll { $0.id == id }
    do { try save() } catch { self.error = error.localizedDescription }
  }

  private func save() throws {
    try JSONEncoder().encode(connections).write(
      to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    // Device-local credentials and chats are not an iCloud settings export.
    var url = file
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  private func keychainQuery(_ id: UUID) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
      kSecAttrAccount: id.uuidString,
    ]
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw JSONRPCError.internalError(
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
    }
  }
}

struct RemoteAgentPermission: Identifiable {
  let id: UUID
  let title: String
  let details: String
  let options: [Option]
  struct Option: Identifiable {
    let id: String
    let name: String
    let kind: String
  }
}

@MainActor @Observable
final class RemoteAgentChat {
  let bookmark: RemoteAgentBookmark
  private(set) var conversation: RemoteAgentConversation
  var messages: [RemoteAgentMessage]
  var status = "Disconnected"
  var error: String?
  var busy = false
  var connected = false
  private(set) var configurationOptions: [RemoteSessionOption] = []
  private(set) var settingsLoading = false
  private(set) var settingsError: String?
  var permissions: [RemoteAgentPermission] = []
  private var sessionID: String?
  private var client: (any RemoteSessionClient)?
  private var operation: Task<Void, Never>?
  private var permissionReplies: [UUID: CheckedContinuation<String?, Never>] = [:]
  private var generation = 0
  private var deleted = false
  private var connectingHistory: [RemoteAgentMessage]?
  private let store: RemoteAgentStore
  private let isOffline: () -> Bool

  init(
    bookmark: RemoteAgentBookmark, conversation: RemoteAgentConversation,
    store: RemoteAgentStore = .shared, isOffline: @escaping () -> Bool = { false }
  ) {
    self.bookmark = bookmark
    self.conversation = conversation
    self.store = store
    self.isOffline = isOffline
    messages = conversation.messages
    sessionID = conversation.sessionID
    self.conversation.createdAt = conversation.createdAt ?? conversation.updatedAt
  }

  var presentation: Conversation {
    var snapshot = conversation
    snapshot.messages = messages
    return snapshot.presentation
  }

  var canManage: Bool {
    conversation.sessionID == nil
      || store.host(bookmark.id)?.workspace?.canManageSessions == true
  }

  func refreshConfiguration() async {
    guard connected, !settingsLoading, !isOffline(), let client else { return }
    settingsLoading = true
    settingsError = nil
    let attempt = generation
    defer { if generation == attempt { settingsLoading = false } }
    do {
      let options = try await client.configurationOptions()
      guard generation == attempt, connected, !Task.isCancelled else { return }
      configurationOptions = options
    } catch {
      if generation == attempt, !(error is CancellationError) {
        settingsError = error.localizedDescription
      }
    }
  }

  func setConfigurationOption(id: String, value: JSONValue) {
    guard connected, !busy, !settingsLoading, !isOffline(), let client else { return }
    busy = true
    settingsLoading = true
    settingsError = nil
    let attempt = generation
    operation = Task {
      do {
        let options = try await client.setConfigurationOption(id: id, value: value)
        guard generation == attempt else { return }
        configurationOptions = options
      } catch {
        if generation == attempt { settingsError = error.localizedDescription }
      }
      guard generation == attempt else { return }
      busy = false
      settingsLoading = false
      operation = nil
    }
  }

  func manage(title: String?) async throws {
    guard !busy, canManage else {
      throw JSONRPCError.invalidParams("Update the remote pmai to manage chats")
    }
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard title?.isEmpty != true else { return }
    busy = true
    defer { busy = false }
    let attempt = generation
    if let sessionID {
      guard !isOffline() else { throw InternetAccessError.offline }
      let temporary = client == nil
      let managementClient = try client ?? makeClient()
      if temporary { client = managementClient }
      do {
        try await managementClient.manageSession(sessionID, cwd: conversation.cwd, title: title)
        if temporary {
          if client === managementClient { client = nil }
          await managementClient.disconnect()
        }
      } catch {
        if temporary {
          if client === managementClient { client = nil }
          await managementClient.disconnect()
        }
        throw error
      }
      guard generation == attempt, !isOffline() else { throw CancellationError() }
    }
    if let title {
      conversation.title = title
      conversation.updatedAt = Date()
      persist()
    } else {
      deleted = true
      disconnect()
      store.deleteConversation(conversation.id, hostID: bookmark.id)
    }
  }

  private func makeClient() throws -> any RemoteSessionClient {
    guard !isOffline() else { throw InternetAccessError.offline }
    let generation = generation
    let token = try store.token(for: bookmark.id)
    return try bookmark.makeClient(
      token: token, cwd: conversation.cwd, sessionID: sessionID,
      onUpdate: { [weak self] update in await self?.receive(update, generation: generation) },
      onPermission: { [weak self] request in
        await self?.requestPermission(request, generation: generation)
      },
      onDisconnect: { [weak self] in
        await self?.connectionClosed(generation: generation)
      })
  }

  func connect() {
    guard !busy, !connected else { return }
    guard !isOffline() else {
      error = "Turn off Airplane Mode in Settings to connect to this host."
      return
    }
    busy = true
    error = nil
    status = "Connecting…"
    generation += 1
    let attempt = generation
    operation = Task { [self] in
      let previous = messages
      do {
        await client?.disconnect()
        guard generation == attempt, !Task.isCancelled else { return }
        let client = try makeClient()
        self.client = client
        connectingHistory = previous
        messages = []
        let id = try await client.connect()
        guard generation == attempt else { return }
        sessionID = id
        connected = await client.isConnected
        guard generation == attempt else { return }
        connectingHistory = nil
        status = connected ? "Connected" : "Disconnected"
        persist()
      } catch {
        guard generation == attempt else { return }
        messages = previous
        connectingHistory = nil
        self.error = error.localizedDescription
        connected = false
        status = "Disconnected"
        await client?.disconnect()
      }
      if generation == attempt {
        busy = false
        operation = nil
      }
    }
  }

  func send(_ text: String) {
    guard !isOffline(), connected, !busy, let client else { return }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    busy = true
    error = nil
    status = "Responding…"
    messages.append(RemoteAgentMessage(role: "user", text: text))
    conversation.updatedAt = Date()
    if AgentChat.isPlaceholderTitle(conversation.title) {
      conversation.title = AgentChat.derivedTitle(from: text) ?? conversation.title
    }
    persist()
    let attempt = generation
    operation = Task {
      do {
        let reason = try await client.prompt(text) { _ in }
        guard generation == attempt else { return }
        status = reason == .cancelled ? "Cancelled" : "Connected"
      } catch {
        guard generation == attempt else { return }
        self.error = error is CancellationError ? nil : error.localizedDescription
        status = "Disconnected — reconnect to restore the session"
        connected = false
      }
      guard generation == attempt else { return }
      cancelPermissions()
      busy = false
      operation = nil
      conversation.updatedAt = Date()
      persist()
    }
  }

  func disconnect() {
    generation += 1
    operation?.cancel()
    operation = nil
    cancelPermissions()
    let client = client
    self.client = nil
    Task { await client?.disconnect() }
    connected = false
    configurationOptions = []
    settingsLoading = false
    settingsError = nil
    busy = false
    status = "Disconnected"
    if let connectingHistory {
      messages = connectingHistory
      self.connectingHistory = nil
    }
    persist()
  }

  private func connectionClosed(generation: Int) {
    guard self.generation == generation else { return }
    connected = false
    status = "Disconnected"
    cancelPermissions()
  }

  func answer(_ id: UUID, optionID: String?) {
    permissions.removeAll { $0.id == id }
    permissionReplies.removeValue(forKey: id)?.resume(returning: optionID)
  }

  private func cancelPermissions() {
    for id in Array(permissionReplies.keys) { answer(id, optionID: nil) }
  }

  private func requestPermission(_ request: JSONValue, generation: Int) async -> String? {
    guard self.generation == generation, !Task.isCancelled else { return nil }
    let id = UUID()
    let tool = request.objectValue?["toolCall"]
    let options = (request.objectValue?["options"]?.arrayValue ?? []).compactMap {
      value -> RemoteAgentPermission.Option? in
      guard let object = value.objectValue, let id = object["optionId"]?.stringValue else {
        return nil
      }
      return .init(
        id: id, name: object["name"]?.stringValue ?? id, kind: object["kind"]?.stringValue ?? "")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let details = (try? tool.map { String(decoding: try encoder.encode($0), as: UTF8.self) }) ?? ""
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        permissionReplies[id] = continuation
        permissions.append(
          .init(
            id: id, title: tool?.objectValue?["title"]?.stringValue ?? "Tool permission",
            details: details, options: options))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.answer(id, optionID: nil) }
    }
  }

  private func receive(_ update: JSONValue, generation: Int) {
    guard self.generation == generation, let object = update.objectValue,
      let kind = object["sessionUpdate"]?.stringValue
    else { return }
    switch kind {
    case "config_option_update":
      configurationOptions = RemoteSessionOption.parse(object["configOptions"])
      return
    case "_pmai/message_snapshot":
      let previous = Dictionary(
        messages.compactMap { message in
          message.remoteID.map { ($0, message.id) }
        }, uniquingKeysWith: { first, _ in first })
      messages = (object["messages"]?.arrayValue ?? []).compactMap { value in
        guard let fields = value.objectValue, let remoteID = fields["remoteID"]?.stringValue,
          let role = fields["role"]?.stringValue, let text = fields["text"]?.stringValue
        else { return nil }
        return RemoteAgentMessage(
          id: previous[remoteID] ?? UUID(), role: role, text: text,
          toolID: fields["toolID"]?.stringValue, status: fields["status"]?.stringValue,
          createdAt: fields["created"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) },
          remoteID: remoteID)
      }
    case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
      let role =
        kind == "user_message_chunk"
        ? "user" : kind == "agent_message_chunk" ? "assistant" : "thought"
      let text = ACP.ContentBlock.text(from: object["content"])
      guard !text.isEmpty else { return }
      if let last = messages.indices.last, messages[last].role == role {
        messages[last].text += text
      } else {
        messages.append(RemoteAgentMessage(role: role, text: text))
      }
    case "tool_call", "tool_call_update":
      guard let id = object["toolCallId"]?.stringValue else { return }
      let title = object["title"]?.stringValue
      let content = ACP.ContentBlock.text(from: object["content"])
      if let index = messages.firstIndex(where: { $0.toolID == id }) {
        if !content.isEmpty { messages[index].text += "\n" + content }
        if let status = object["status"]?.stringValue { messages[index].status = status }
      } else {
        messages.append(
          RemoteAgentMessage(
            role: "tool",
            text: [title ?? "Tool", content].filter { !$0.isEmpty }.joined(separator: "\n"),
            toolID: id, status: object["status"]?.stringValue))
      }
    case "plan":
      let entries = object["entries"]?.arrayValue ?? []
      let text = entries.compactMap { $0.objectValue?["content"]?.stringValue }.joined(
        separator: "\n")
      if !text.isEmpty { messages.append(RemoteAgentMessage(role: "plan", text: text)) }
    default: break
    }
  }

  private func persist() {
    guard !deleted else { return }
    conversation.sessionID = sessionID
    conversation.messages = messages
    store.update(bookmark.id, conversation: conversation)
  }
}
