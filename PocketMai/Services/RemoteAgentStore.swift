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
}

struct RemoteAgentMessage: Codable, Identifiable {
  var id = UUID()
  var role: String
  var text: String
  var toolID: String?
  var status: String?
}

@MainActor @Observable
final class RemoteAgentStore {
  static let shared = RemoteAgentStore()
  private(set) var connections: [RemoteAgentBookmark] = []
  var error: String?
  private let file: URL
  private let keychainService = "io.github.trufae.mai.acp-gateway"

  private init() {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RemoteAgents", isDirectory: true)
    file = directory.appendingPathComponent("connections.json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: file.path) {
        connections = try JSONDecoder().decode(
          [RemoteAgentBookmark].self, from: Data(contentsOf: file))
      }
    } catch { self.error = error.localizedDescription }
  }

  @discardableResult
  func add(_ profile: ACPRemoteConnection) throws -> UUID {
    try profile.validate()
    // Reimporting the same endpoint updates its token without losing the chat.
    let existing = connections.firstIndex { $0.url == profile.url && $0.cwd == profile.cwd }
    let id = existing.map { connections[$0].id } ?? UUID()
    let query = keychainQuery(id)
    let data = Data(profile.token.utf8)
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
      connections[existing].name = profile.name
    } else {
      connections.append(
        RemoteAgentBookmark(id: id, name: profile.name, url: profile.url, cwd: profile.cwd))
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

  func update(_ id: UUID, sessionID: String?, messages: [RemoteAgentMessage]) {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    connections[index].sessionID = sessionID
    connections[index].messages = messages
    do { try save() } catch { self.error = error.localizedDescription }
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
  var messages: [RemoteAgentMessage]
  var status = "Disconnected"
  var error: String?
  var busy = false
  var connected = false
  var permissions: [RemoteAgentPermission] = []
  private var sessionID: String?
  private var client: ACPClient?
  private var operation: Task<Void, Never>?
  private var permissionReplies: [UUID: CheckedContinuation<String?, Never>] = [:]
  private var generation = 0

  init(bookmark: RemoteAgentBookmark) {
    self.bookmark = bookmark
    messages = bookmark.messages
    sessionID = bookmark.sessionID
  }

  func connect() {
    guard !busy else { return }
    busy = true
    error = nil
    status = "Connecting…"
    generation += 1
    let attempt = generation
    operation = Task {
      let previous = messages
      do {
        await client?.disconnect()
        let token = try RemoteAgentStore.shared.token(for: bookmark.id)
        let client = ACPClient(
          configuration: .init(
            command: bookmark.name, permission: .reject,
            remoteWorkingDirectory: bookmark.cwd, readClientFiles: false,
            webSocketURL: bookmark.url, bearerToken: token, sessionID: sessionID),
          onUpdate: { [weak self] update in await self?.receive(update, generation: attempt) },
          onPermission: { [weak self] request in
            await self?.requestPermission(request, generation: attempt)
          })
        self.client = client
        messages = []
        let id = try await client.connect()
        guard generation == attempt else { return }
        sessionID = id
        connected = true
        status = "Connected"
        persist()
      } catch {
        guard generation == attempt else { return }
        messages = previous
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
    guard connected, !busy, let client else { return }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    busy = true
    error = nil
    status = "Responding…"
    messages.append(RemoteAgentMessage(role: "user", text: text))
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
    busy = false
    status = "Disconnected"
    persist()
  }

  func newChat() {
    disconnect()
    sessionID = nil
    messages = []
    persist()
    connect()
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
    RemoteAgentStore.shared.update(bookmark.id, sessionID: sessionID, messages: messages)
  }
}
