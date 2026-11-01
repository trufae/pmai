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
  var forwirohInvitation: String?
  var connectionProtocol: ACPRemoteProtocol?
  var revision: UUID?
  var backend: RemoteAgentBackend?
  var isPinned: Bool?
  var pinnedFolderPaths: [String]?
  var pinnedConversationIDs: [UUID]?

  func makeClient(
    token: String, cwd: String, sessionID: String? = nil, resumeID: String? = nil,
    httpConfiguration: URLSessionConfiguration = .ephemeral,
    onUpdate: (@Sendable (JSONValue) async -> Void)? = nil,
    onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil,
    onPermissionResponse: (@Sendable (JSONValue) async throws -> ACPPermissionResponse?)? = nil,
    onDisconnect: (@Sendable () async -> Void)? = nil
  ) throws -> any RemoteSessionClient {
    if backend == .openCode {
      if let onPermissionResponse {
        return OpenCodeClient(
          connection: try .init(name: name, url: url, token: token, cwd: cwd), sessionID: sessionID,
          configuration: httpConfiguration,
          onUpdate: onUpdate,
          onPermission: { request in try await onPermissionResponse(request)?.optionID })
      }
      return OpenCodeClient(
        connection: try .init(name: name, url: url, token: token, cwd: cwd), sessionID: sessionID,
        configuration: httpConfiguration,
        onUpdate: onUpdate, onPermission: onPermission)
    }
    return ACPClient(
      configuration: .init(
        command: name, permission: .reject, remoteWorkingDirectory: cwd, readClientFiles: false,
        webSocketURL: url, bearerToken: token, sessionID: sessionID, resumeID: resumeID),
      onUpdate: onUpdate, onPermission: onPermission,
      onPermissionResponse: onPermissionResponse, onDisconnect: onDisconnect)
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
        if let name = message.toolName {
          if text == name {
            text = ""
          } else if text.hasPrefix(name + "\n") {
            text = String(text.dropFirst(name.count + 1))
          }
        }
        let failed = message.status == "error" || message.status == "failed"
        text = AgentTooling.makeRunBlock(
          toolName: message.toolName ?? (message.role == "plan" ? "Plan" : "Remote"),
          argumentsJSON: message.toolInput?.compactJSONString ?? "",
          result: failed ? "Error: \(text)"
            : [message.status, text].compactMap { $0 }.joined(separator: "\n"))
      }
      return ChatMessage(
        id: message.id, role: ChatRole(rawValue: message.role) ?? .assistant, text: text,
        createdAt: message.createdAt ?? result.createdAt)
    }
    return result
  }
}

typealias RemoteAgentMessage = ACPConversationMessage

@MainActor @Observable
final class RemoteAgentStore {
  static let shared = RemoteAgentStore()
  private(set) var connections: [RemoteAgentBookmark] = []
  private(set) var failedHostIDs: Set<UUID> = []
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
      connectionProtocol: profile.connectionProtocol, replacing: hostID, accentColor: accentColor,
      forwirohInvitation: profile.forwirohInvitation)
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
    replacing hostID: UUID?, accentColor: String?, forwirohInvitation: String? = nil
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
      connections[existing].forwirohInvitation = forwirohInvitation
      connections[existing].connectionProtocol = connectionProtocol
      connections[existing].backend = backend
      connections[existing].revision = UUID()
    } else {
      connections.append(
        RemoteAgentBookmark(
          id: id, name: name, url: url, cwd: cwd, accentColor: accentColor,
          requiresApproval: requiresApproval, forwirohInvitation: forwirohInvitation,
          connectionProtocol: connectionProtocol,
          backend: backend))
    }
    setConnectionFailed(false, for: id)
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
    connections[index].forwirohInvitation = nil
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
    connections[index].pinnedConversationIDs?.removeAll { $0 == id }
    if connections[index].pinnedConversationIDs?.isEmpty == true {
      connections[index].pinnedConversationIDs = nil
    }
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func host(_ id: UUID?) -> RemoteAgentBookmark? {
    connections.first { $0.id == id }
  }

  func isHostPinned(_ id: UUID) -> Bool {
    host(id)?.isPinned == true
  }

  func toggleHostPin(_ id: UUID) {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    connections[index].isPinned = connections[index].isPinned == true ? nil : true
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func setConnectionFailed(_ failed: Bool, for id: UUID) {
    if failed {
      failedHostIDs.insert(id)
    } else {
      failedHostIDs.remove(id)
    }
  }

  func reconnect(_ id: UUID) {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    setConnectionFailed(false, for: id)
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
    var latest: [String: Date] = [:]
    func record(_ cwd: String, _ date: Date?) {
      guard let date, date > .distantPast else { return }
      latest[cwd] = max(latest[cwd] ?? date, date)
    }
    for session in host.workspace?.sessions ?? [] { record(session.cwd, session.updatedAt) }
    for chat in host.conversations ?? [] { record(chat.cwd, chat.updatedAt) }
    for index in folders.indices {
      folders[index].updatedAt = [folders[index].updatedAt, latest[folders[index].cwd]]
        .compactMap { $0 }.max()
    }
    return FolderPinning.ordered(folders, pins: host.pinnedFolderPaths ?? [], id: \.cwd)
  }

  func toggleFolderPin(hostID: UUID, cwd: String) {
    guard let index = connections.firstIndex(where: { $0.id == hostID }),
      folders(for: connections[index]).contains(where: { $0.cwd == cwd })
    else { return }
    var pins = connections[index].pinnedFolderPaths ?? []
    FolderPinning.toggle(cwd, in: &pins)
    connections[index].pinnedFolderPaths = pins.isEmpty ? nil : pins
    do { try save() } catch { self.error = error.localizedDescription }
  }

  func conversations(for host: RemoteAgentBookmark) -> [RemoteAgentConversation] {
    let pins = Set(host.pinnedConversationIDs ?? [])
    return (host.conversations ?? []).sorted {
      if pins.contains($0.id) != pins.contains($1.id) { return pins.contains($0.id) }
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  func toggleConversationPin(hostID: UUID, conversationID: UUID) {
    guard let index = connections.firstIndex(where: { $0.id == hostID }),
      connections[index].conversations?.contains(where: { $0.id == conversationID }) == true
    else { return }
    // Keep device-local pins outside chat snapshots so streaming updates cannot overwrite them.
    var pins = connections[index].pinnedConversationIDs ?? []
    if pins.contains(conversationID) {
      pins.removeAll { $0 == conversationID }
    } else {
      pins.append(conversationID)
    }
    connections[index].pinnedConversationIDs = pins.isEmpty ? nil : pins
    do { try save() } catch { self.error = error.localizedDescription }
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
        if connection.isPinned == true { hosts[index].isPinned = true }
        hosts[index].conversations =
          (hosts[index].conversations ?? []) + (connection.conversations ?? [])
        for path in connection.pinnedFolderPaths ?? []
        where hosts[index].pinnedFolderPaths?.contains(path) != true {
          hosts[index].pinnedFolderPaths = (hosts[index].pinnedFolderPaths ?? []) + [path]
        }
        for id in connection.pinnedConversationIDs ?? []
        where hosts[index].pinnedConversationIDs?.contains(id) != true {
          hosts[index].pinnedConversationIDs = (hosts[index].pinnedConversationIDs ?? []) + [id]
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
    failedHostIDs.remove(id)
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
  let kind: String
  let rawInput: JSONValue?
  let supportsEditing: Bool
  let supportsYolo: Bool
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
  private(set) var responding = false
  private(set) var injecting = false
  var unsentPrompt: String?
  private var supportsInjection = false
  private var reconnectTask: Task<Void, Never>?
  private var reconnectDelay = 1
  private var shouldReconnect = false
  private(set) var configurationOptions: [RemoteSessionOption] = []
  private(set) var settingsLoading = false
  private(set) var settingsError: String?
  private var configurationLoaded = false
  var permissions: [RemoteAgentPermission] = []
  private var sessionID: String?
  private var client: (any RemoteSessionClient)?
  private var operation: Task<Void, Never>?
  private var pendingPrompt: String?
  private var pendingInjection: String?
  private var permissionReplies: [UUID: CheckedContinuation<ACPPermissionResponse?, Never>] = [:]
  private var generation = 0
  private var historyRewindSupported = false
  private var deleted = false
  private var connectingHistory: [RemoteAgentMessage]?
  private var loadingMessages: [RemoteAgentMessage]?
  private let store: RemoteAgentStore
  private let isOffline: () -> Bool
  private let httpConfiguration: URLSessionConfiguration

  init(
    bookmark: RemoteAgentBookmark, conversation: RemoteAgentConversation,
    store: RemoteAgentStore = .shared, isOffline: @escaping () -> Bool = { false },
    httpConfiguration: URLSessionConfiguration = .ephemeral
  ) {
    self.bookmark = bookmark
    self.conversation = conversation
    self.store = store
    self.isOffline = isOffline
    self.httpConfiguration = httpConfiguration
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

  var canSend: Bool { connected && !busy && !isOffline() }

  /// A disconnected remote can reconnect when the person submits a draft.
  /// The actual prompt remains pending until that connection completes.
  var canSubmit: Bool {
    !isOffline() && store.host(bookmark.id)?.requiresApproval != true
      && (bookmark.backend != .openCode || !conversation.cwd.isEmpty)
      && (!busy || (connected && responding && supportsInjection && !injecting))
  }

  var remoteToolOptions: [RemoteSessionOption] {
    configurationOptions.filter {
      $0.id == "tools.enabled" || $0.id.hasPrefix("tools.tool.")
    }
  }

  var remoteToolsEnabled: Bool? {
    remoteToolOptions.first(where: { $0.id == "tools.enabled" })?.currentValue.boolValue
  }

  var enabledRemoteToolCount: Int {
    remoteToolOptions.filter { $0.id != "tools.enabled" }.reduce(into: 0) { count, option in
      if option.currentValue.boolValue == true { count += 1 }
    }
  }

  var supportsHistoryRewind: Bool { historyRewindSupported }

  func canResubmit(_ messageID: UUID) -> Bool {
    canSubmit && sourceMessage(messageID) != nil
  }

  func canRetry(_ messageID: UUID) -> Bool {
    canSend && supportsHistoryRewind
      && sourceMessage(messageID)?.remoteID != nil
  }

  func resubmit(_ messageID: UUID) {
    guard canResubmit(messageID), let message = sourceMessage(messageID) else { return }
    send(message.text)
  }

  func retry(_ messageID: UUID, restarting: Bool = false) {
    guard canRetry(messageID), let message = sourceMessage(messageID) else { return }
    submit(message.text, rewind: true, boundary: restarting ? nil : message.remoteID)
  }

  func canDelete(_ messageID: UUID) -> Bool {
    canSend && supportsHistoryRewind && messages.contains {
      $0.id == messageID && $0.remoteID != nil
    }
  }

  /// Removes this remote message and everything after it. The pmai host owns
  /// the transcript, so this never mutates PocketMai's unrelated local chats.
  func delete(_ messageID: UUID) {
    guard canDelete(messageID), let message = messages.first(where: { $0.id == messageID }),
      let remoteID = message.remoteID, let client
    else { return }
    busy = true
    error = nil
    status = "Deleting…"
    let attempt = generation
    operation = Task {
      do {
        try await client.rewind(to: remoteID)
        guard generation == attempt else { return }
        status = "Connected"
      } catch {
        guard generation == attempt else { return }
        self.error = error is CancellationError ? nil : error.localizedDescription
        status = "Connected"
      }
      guard generation == attempt else { return }
      busy = false
      operation = nil
      conversation.updatedAt = Date()
      persist()
    }
  }

  private func sourceMessage(_ id: UUID) -> RemoteAgentMessage? {
    messages.first {
      $0.id == id && $0.role == "user"
        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  func refreshConfiguration(force: Bool = false) async {
    guard force || !configurationLoaded else { return }
    guard connected, !settingsLoading, !isOffline(), let client else { return }
    settingsLoading = true
    settingsError = nil
    let attempt = generation
    defer { if generation == attempt { settingsLoading = false } }
    do {
      let options = try await client.configurationOptions()
      guard generation == attempt, connected, !Task.isCancelled else { return }
      configurationOptions = options
      configurationLoaded = true
    } catch {
      if generation == attempt, !(error is CancellationError) {
        settingsError = error.localizedDescription
      }
    }
  }

  func setConfigurationOption(id: String, value: JSONValue) {
    setConfigurationOptions([(id: id, value: value)])
  }

  /// Group selections update every option in order while keeping the picker busy.
  func setConfigurationOptions(_ updates: [(id: String, value: JSONValue)]) {
    guard !updates.isEmpty else { return }
    let reviewOnly = updates.allSatisfy { $0.id == "tools.review" }
    guard connected, (!busy || reviewOnly), !settingsLoading, !isOffline(), let client else { return }
    if !reviewOnly { busy = true }
    settingsLoading = true
    settingsError = nil
    let attempt = generation
    let task = Task {
      do {
        for update in updates {
          guard generation == attempt else { return }
          guard connected, !Task.isCancelled else { throw CancellationError() }
          let options = try await client.setConfigurationOption(id: update.id, value: update.value)
          guard generation == attempt else { return }
          configurationOptions = options
        }
      } catch {
        if generation == attempt, !(error is CancellationError) {
          settingsError = error.localizedDescription
        }
      }
      guard generation == attempt else { return }
      if !reviewOnly { busy = false; operation = nil }
      settingsLoading = false
    }
    if !reviewOnly { operation = task }
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
      token: token, cwd: conversation.cwd, sessionID: sessionID, resumeID: conversation.id.uuidString,
      httpConfiguration: httpConfiguration,
      onUpdate: { [weak self] update in await self?.receive(update, generation: generation) },
      onPermissionResponse: { [weak self] request in
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
    shouldReconnect = true
    reconnectTask?.cancel()
    reconnectTask = nil
    busy = true
    responding = false
    error = nil
    status = "Connecting…"
    historyRewindSupported = false
    configurationLoaded = false
    store.setConnectionFailed(false, for: bookmark.id)
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
        loadingMessages = bookmark.backend == .openCode ? previous : []
        let id = try await client.connect()
        guard generation == attempt else { return }
        sessionID = id
        connected = await client.isConnected
        guard generation == attempt else { return }
        historyRewindSupported = await client.historyRewindSupported()
        supportsInjection = await client.injectionSupported()
        guard generation == attempt, !Task.isCancelled else { return }
        messages = loadingMessages ?? previous
        loadingMessages = nil
        reconnectDelay = 1
        store.setConnectionFailed(!connected, for: bookmark.id)
        connectingHistory = nil
        status = connected ? (responding ? "Responding…" : "Connected") : "Disconnected"
        persist()
      } catch {
        guard generation == attempt else { return }
        messages = previous
        connectingHistory = nil
        loadingMessages = nil
        unsentPrompt = pendingPrompt
        pendingPrompt = nil
        historyRewindSupported = false
        self.error = error.localizedDescription
        connected = false
        if !RemoteConnectionRecovery.shouldRetry(error) { shouldReconnect = false }
        store.setConnectionFailed(!(error is CancellationError), for: bookmark.id)
        status = "Disconnected"
        await client?.disconnect()
      }
      if generation == attempt {
        busy = responding
        operation = nil
        if !connected { scheduleReconnect() }
        if connected, let pendingPrompt {
          self.pendingPrompt = nil
          send(pendingPrompt)
        }
      }
    }
  }

  @discardableResult
  func send(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, canSubmit else { return false }
    guard !connected else {
      if responding { inject(text) } else { submit(text) }
      return true
    }
    pendingPrompt = text
    connect()
    return true
  }

  private func inject(_ text: String) {
    guard let client, supportsInjection, !injecting else { return }
    injecting = true
    pendingInjection = text
    let attempt = generation
    Task {
      defer {
        if generation == attempt { injecting = false; pendingInjection = nil }
      }
      do {
        try await client.inject(text)
        guard generation == attempt else { return }
        persist()
      } catch {
        guard generation == attempt else { return }
        unsentPrompt = text
        self.error = error.localizedDescription
      }
    }
  }

  func cancel() {
    guard responding, connected, let client else { return }
    status = "Stopping…"
    Task { await client.cancel() }
  }

  private func scheduleReconnect() {
    guard shouldReconnect, !isOffline(), reconnectTask == nil else { return }
    status = "Reconnecting…"
    let delay = reconnectDelay
    reconnectDelay = min(30, reconnectDelay * 2)
    reconnectTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      reconnectTask = nil
      connect()
    }
  }

  private func submit(_ text: String, rewind: Bool = false, boundary: String? = nil) {
    guard canSend, let client else { return }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    busy = true
    error = nil
    responding = true
    status = rewind ? "Rewinding…" : "Responding…"
    if !rewind { appendPrompt(text) }
    let attempt = generation
    operation = Task {
      do {
        if rewind {
          try await client.rewind(to: boundary)
          guard generation == attempt else { return }
          try Task.checkCancellation()
          guard !isOffline(), connected else { throw CancellationError() }
          appendPrompt(text)
          status = "Responding…"
        }
        let reason = try await client.prompt(text) { _ in }
        guard generation == attempt else { return }
        status = reason == .cancelled ? "Cancelled" : "Connected"
      } catch {
        guard generation == attempt else { return }
        let stillConnected = await client.isConnected
        guard generation == attempt else { return }
        self.error = error is CancellationError ? nil : error.localizedDescription
        connected = error is OpenCodeClient.SessionFailure && stillConnected
        store.setConnectionFailed(!connected && !(error is CancellationError), for: bookmark.id)
        status = connected ? "Session failed" : "Reconnecting…"
      }
      guard generation == attempt else { return }
      cancelPermissions()
      responding = false
      busy = false
      operation = nil
      if !connected { scheduleReconnect() }
      conversation.updatedAt = Date()
      persist()
    }
  }

  private func appendPrompt(_ text: String) {
    messages.append(RemoteAgentMessage(role: "user", text: text))
    conversation.updatedAt = Date()
    if AgentChat.isPlaceholderTitle(conversation.title) {
      conversation.title = AgentChat.derivedTitle(from: text) ?? conversation.title
    }
    persist()
  }

  func disconnect() {
    shouldReconnect = false
    loadingMessages = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    generation += 1
    operation?.cancel()
    operation = nil
    pendingPrompt = nil
    cancelPermissions()
    let client = client
    self.client = nil
    Task { await client?.disconnect() }
    connected = false
    historyRewindSupported = false
    configurationOptions = []
    settingsLoading = false
    settingsError = nil
    busy = false
    responding = false
    injecting = false
    supportsInjection = false
    status = "Disconnected"
    if let connectingHistory {
      messages = connectingHistory
      self.connectingHistory = nil
    }
    persist()
  }

  private func connectionClosed(generation: Int) {
    guard self.generation == generation else { return }
    self.generation += 1
    loadingMessages = nil
    operation?.cancel()
    operation = nil
    client = nil
    if let pendingInjection {
      unsentPrompt = pendingInjection
      self.pendingInjection = nil
      error = "Connection lost while sending. Check the restored conversation before resending."
    }
    settingsLoading = false
    configurationLoaded = false
    if let pendingPrompt { unsentPrompt = pendingPrompt; self.pendingPrompt = nil }
    connected = false
    busy = false
    responding = false
    injecting = false
    historyRewindSupported = false
    if let connectingHistory {
      messages = connectingHistory
      self.connectingHistory = nil
    }
    store.setConnectionFailed(true, for: bookmark.id)
    cancelPermissions()
    persist()
    scheduleReconnect()
  }

  func answer(_ id: UUID, optionID: String?, rawInput: JSONValue? = nil) {
    permissions.removeAll { $0.id == id }
    permissionReplies.removeValue(forKey: id)?.resume(
      returning: optionID.map { ACPPermissionResponse(optionID: $0, rawInput: rawInput) })
  }

  private func cancelPermissions() {
    for id in Array(permissionReplies.keys) { answer(id, optionID: nil) }
  }

  private func requestPermission(_ request: JSONValue, generation: Int) async -> ACPPermissionResponse? {
    guard self.generation == generation, !Task.isCancelled else { return nil }
    let id = UUID()
    let tool = request.objectValue?["toolCall"]
    let pmai = request.objectValue?["_pmai"]?.objectValue
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
            details: details, kind: tool?.objectValue?["kind"]?.stringValue ?? "",
            rawInput: tool?.objectValue?["rawInput"],
            supportsEditing: pmai?["permissionEditing"]?.boolValue == true,
            supportsYolo: pmai?["yolo"]?.boolValue == true,
            options: options))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.answer(id, optionID: nil) }
    }
  }

  private func receive(_ update: JSONValue, generation: Int) {
    guard self.generation == generation, let object = update.objectValue,
      let kind = object["sessionUpdate"]?.stringValue
    else { return }
    if kind == "_pmai/session_state", let running = object["running"]?.boolValue {
      responding = running
      if !running { cancelPermissions(); persist() }
      busy = running || operation != nil
      status = running ? "Responding…" : "Connected"
    } else if kind == "config_option_update" {
      configurationOptions = RemoteSessionOption.parse(object["configOptions"])
    } else {
      if var loading = loadingMessages {
        ACPConversationTranscript.apply(update, to: &loading)
        loadingMessages = loading
      } else {
        ACPConversationTranscript.apply(update, to: &messages)
      }
    }
  }

  private func persist() {
    guard !deleted else { return }
    conversation.sessionID = sessionID
    conversation.messages = messages
    store.update(bookmark.id, conversation: conversation)
  }
}
