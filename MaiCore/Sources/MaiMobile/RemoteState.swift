import Foundation
import MaiACP
import MaiCore
import MaiStandardTools
import Observation

private struct RemoteBookmark: Codable, Identifiable {
  var id = UUID().uuidString
  var profile: RemoteHostConnection
  var pinned = false
  var folders: [ACPWorkspaceFolder] = []
  var sessions: [RemoteConversation] = []
}

private struct RemoteConversation: Codable, Identifiable {
  var id = UUID().uuidString
  var sessionID: String?
  var cwd: String
  var title = "New chat"
  var updatedAt = Date()
  var messages: [RemoteMessage] = []
}

private typealias RemoteMessage = ACPConversationMessage

/// Host → workspace → conversation mirrors iOS navigation. ACP owns all
/// transport, Forwiroh pairing, streaming and session protocol behavior.
@MainActor @Observable final class RemoteState {
  private var bookmarks: [RemoteBookmark]
  var selectedHostID = ""
  var selectedFolder = ""
  var conversationID = ""
  var connected = false
  var busy = false
  var status = ""
  var error = ""
  let workspace: RemoteWorkspaceState
  private var options: [RemoteSessionOption] = []
  private var canRewind = false
  private var messages: [RemoteMessage] = []
  private var permission: JSONValue?
  private var permissionReply: CheckedContinuation<String?, Never>?
  private let directory: URL
  private let clientName: String
  private var client: (any RemoteSessionClient)?
  private var operation: Task<Void, Never>?
  private var preparation: Task<Void, Error>?
  private var generation = 0

  init(directory: URL, clientName: String = "PocketMai") throws {
    workspace = RemoteWorkspaceState(directory: directory)
    self.directory = directory
    self.clientName = clientName
    let file = directory.appendingPathComponent("bookmarks.json")
    bookmarks = FileManager.default.fileExists(atPath: file.path)
      ? try JSONDecoder().decode([RemoteBookmark].self, from: Data(contentsOf: file)) : []
  }

  func configure(identity: Data?) {
    preparation = Task {
      guard let identity, identity.count == 32 else { throw CocoaError(.coderInvalidValue) }
      try await ForwirohRemote.shared.configure(
        directory: directory.appendingPathComponent("forwiroh"), identity: identity)
    }
  }

  private var index: Int? { bookmarks.firstIndex { $0.id == selectedHostID } }

  func pair(_ invitation: String, name: String) {
    guard !busy else { return }
    disconnect()
    run {
      var profile: RemoteHostConnection
      if let link = try? OpenCodePairingLink.parse(invitation) {
        profile = .init(try await link.redeem())
      } else { profile = .init(try ACPRemoteConnection.parse(invitation)) }
      if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { profile.name = name }
      if profile.requiresApproval == true {
        self.status = "Approve this device, then chat access, on the remote host."
        let client = self.makeACPClient(try ACPRemoteConnection.parse(invitation), generation: self.generation)
        self.client = client
        profile.token = try await client.requestPairing(
          clientID: UUID().uuidString, name: self.clientName)
        profile.requiresApproval = false
        await client.disconnect()
      }
      try Task.checkCancellation()
      if let found = self.bookmarks.firstIndex(where: { $0.profile.url == profile.url }) {
        self.bookmarks[found].profile = profile
        self.selectedHostID = self.bookmarks[found].id
      } else {
        let host = RemoteBookmark(profile: profile)
        self.bookmarks.append(host)
        self.selectedHostID = host.id
      }
      self.selectedFolder = profile.cwd
      try self.persist()
      try await self.discover()
    }
  }

  func selectHost(_ id: String) {
    disconnect()
    selectedHostID = id
    conversationID = ""
    messages = []
    guard let index else { return }
    selectedFolder = bookmarks[index].profile.cwd
    run { try await self.discover() }
  }

  private func discover() async throws {
    guard let index else { return }
    let profile = bookmarks[index].profile
    let client = try makeClient(profile, generation: generation)
    self.client = client
    status = "Connecting to \(profile.name)…"
    let workspace = try await client.workspace()
    try Task.checkCancellation()
    if let workspace {
      bookmarks[index].folders = workspace.folders
      if selectedFolder.isEmpty { selectedFolder = workspace.folders.first?.cwd ?? "" }
      for session in workspace.sessions {
        if let existing = bookmarks[index].sessions.firstIndex(where: { $0.sessionID == session.sessionID }) {
          bookmarks[index].sessions[existing].title = session.title
        } else {
          bookmarks[index].sessions.append(RemoteConversation(
            sessionID: session.sessionID, cwd: session.cwd, title: session.title,
            updatedAt: session.updatedAt ?? .distantPast))
        }
      }
    }
    connected = true
    status = "Connected"
    try persist()
  }

  func open(_ id: String, cwd: String) {
    guard !busy, let index else { return }
    disconnect()
    if id.isEmpty {
      let conversation = RemoteConversation(cwd: cwd.isEmpty ? selectedFolder : cwd)
      bookmarks[index].sessions.append(conversation)
      conversationID = conversation.id
    } else { conversationID = id }
    guard let session = bookmarks[index].sessions.first(where: { $0.id == conversationID }) else { return }
    messages = session.messages
    selectedFolder = session.cwd
    run {
      let attempt = self.generation
      let client = try self.makeClient(self.bookmarks[index].profile,
        cwd: session.cwd, session: session.sessionID, updates: true, generation: attempt)
      self.client = client
      self.status = "Opening chat…"
      let sessionID = try await client.connect()
      try Task.checkCancellation()
      if let current = self.bookmarks[index].sessions.firstIndex(where: { $0.id == self.conversationID }) {
        self.bookmarks[index].sessions[current].sessionID = sessionID
      }
      self.connected = true
      self.canRewind = await client.historyRewindSupported()
      self.options = try await client.configurationOptions()
      self.status = "Connected"
      try self.persistConversation()
    }
  }

  func send(_ text: String) {
    guard !busy, connected, !conversationID.isEmpty, let client,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    messages.append(RemoteMessage(role: "user", text: text))
    if let index, let c = bookmarks[index].sessions.firstIndex(where: { $0.id == conversationID }),
      bookmarks[index].sessions[c].title == "New chat" {
      bookmarks[index].sessions[c].title = String(text.prefix(80))
    }
    run {
      self.status = "Replying…"
      try self.persistConversation()
      _ = try await client.prompt(text) { _ in }
      try Task.checkCancellation()
      self.status = "Connected"
      try self.persistConversation()
    }
  }

  func stop() { operation?.cancel(); answer(nil) }

  func retryMessage(_ id: String, restarting: Bool = false) {
    guard let message = messages.first(where: { $0.id.uuidString == id }),
      message.role == "user" else { return }
    changeMessage(id, text: message.text, restarting: restarting)
  }

  func changeMessage(_ id: String, text: String?, restarting: Bool = false) {
    guard !busy, connected, canRewind, let client,
      let position = messages.firstIndex(where: { $0.id.uuidString == id }),
      let remoteID = messages[position].remoteID,
      text == nil || messages[position].role == "user" else { return }
    let prefix = restarting ? [] : Array(messages.prefix(position))
    run {
      try await client.rewind(to: restarting ? nil : remoteID)
      try Task.checkCancellation()
      self.messages = prefix
      if let text {
        self.messages.append(RemoteMessage(role: "user", text: text))
        _ = try await client.prompt(text) { _ in }
      }
      try self.persistConversation()
    }
  }

  func setOption(_ id: String, value: String) {
    guard !busy, let client else { return }
    run {
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
      _ = try await client.setConfigurationOption(id: id, value: value)
      self.options = try await client.configurationOptions()
    }
  }

  func prepareWorkspace() throws {
    guard let index, !selectedFolder.isEmpty else {
      throw WorkspaceFileError("Choose a remote project first.")
    }
    workspace.configure(hostID: selectedHostID, profile: bookmarks[index].profile, cwd: selectedFolder, preparation: preparation)
  }

  func browse(_ path: String) {
    do { try prepareWorkspace(); workspace.browse(path) }
    catch { workspace.error = error.localizedDescription }
  }

  func selectFolder(_ cwd: String) {
    guard selectedFolder != cwd else { return }
    workspace.close()
    selectedFolder = cwd
  }

  func disconnect() {
    workspace.close()
    generation += 1
    operation?.cancel()
    operation = nil
    answer(nil)
    let old = client
    client = nil
    busy = false
    connected = false
    options = []
    canRewind = false
    status = "Disconnected"
    Task { await old?.disconnect() }
  }

  func editHost(_ id: String, name: String?, remove: Bool = false, pin: Bool = false) throws {
    guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
    if remove {
      if selectedHostID == id { disconnect(); selectedHostID = ""; conversationID = ""; messages = [] }
      bookmarks.remove(at: i)
    } else if pin { bookmarks[i].pinned.toggle() }
    else if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      bookmarks[i].profile.name = name
    }
    try persist()
  }

  func answer(_ option: String?) {
    permission = nil
    let reply = permissionReply
    permissionReply = nil
    reply?.resume(returning: option)
  }

  private func ask(_ request: JSONValue, generation attempt: Int) async -> String? {
    guard generation == attempt, !Task.isCancelled, permissionReply == nil else { return nil }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume(returning: nil); return }
        permission = request
        permissionReply = continuation
      }
    } onCancel: { Task { @MainActor [weak self] in self?.answer(nil) } }
  }

  private func makeClient(_ profile: RemoteHostConnection, cwd: String? = nil,
    session: String? = nil, updates: Bool = false, generation attempt: Int = 0) throws -> any RemoteSessionClient {
    let onUpdate: (@Sendable (JSONValue) async -> Void)?
    if updates { onUpdate = { [weak self] update in await self?.receive(update, generation: attempt) } }
    else { onUpdate = nil }
    return try profile.makeSession(cwd: cwd, sessionID: session, onUpdate: onUpdate,
      onPermission: { [weak self] request in await self?.ask(request, generation: attempt) },
      onDisconnect: { [weak self] in await self?.connectionClosed(generation: attempt) })
  }

  private func makeACPClient(_ profile: ACPRemoteConnection, generation attempt: Int) -> ACPClient {
    ACPClient(configuration: .init(command: profile.name, permission: .reject,
      remoteWorkingDirectory: profile.cwd, readClientFiles: false, webSocketURL: profile.url,
      bearerToken: profile.token, forwirohInvitation: profile.forwirohInvitation),
      onDisconnect: { [weak self] in await self?.connectionClosed(generation: attempt) })
  }

  private func connectionClosed(generation attempt: Int) {
    guard generation == attempt else { return }
    connected = false
    status = "Disconnected"
    answer(nil)
  }

  private func receive(_ value: JSONValue, generation attempt: Int) {
    guard generation == attempt, let fields = value.objectValue,
      let kind = fields["sessionUpdate"]?.stringValue else { return }
    if kind == "config_option_update" {
      options = RemoteSessionOption.parse(fields["configOptions"])
    } else {
      ACPConversationTranscript.apply(value, to: &messages)
    }
  }

  private func run(_ body: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    error = ""
    let attempt = generation
    operation = Task {
      do {
        try await preparation?.value
        try Task.checkCancellation()
        try await body()
      } catch {
        guard generation == attempt else { return }
        self.error = error is CancellationError ? "" : error.localizedDescription
        connected = false
        status = error is CancellationError ? "Stopped" : "Connection failed"
        await client?.disconnect()
        do { try persistConversation() } catch { self.error = error.localizedDescription }
      }
      guard generation == attempt else { return }
      answer(nil)
      busy = false
      operation = nil
    }
  }

  private func persistConversation() throws {
    if let index, let c = bookmarks[index].sessions.firstIndex(where: { $0.id == conversationID }) {
      bookmarks[index].sessions[c].messages = messages
      bookmarks[index].sessions[c].updatedAt = Date()
    }
    try persist()
  }

  private func persist() throws {
    try ACPStateFiles.write(bookmarks, to: directory.appendingPathComponent("bookmarks.json"))
  }

  var snapshot: [String: Any] {
    let selected = index.map { bookmarks[$0] }
    var folders = selected?.folders ?? []
    for cwd in (selected?.sessions.map(\.cwd) ?? []) + [selected?.profile.cwd ?? ""] where !cwd.isEmpty {
      if !folders.contains(where: { $0.cwd == cwd }) {
        folders.append(.init(cwd: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent))
      }
    }
    let permissionObject = permission.flatMap { try? JSONEncoder().encode($0) }
      .flatMap { try? JSONSerialization.jsonObject(with: $0) }
    let optionsObject = (try? JSONEncoder().encode(options.map(\.json)))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
    return workspace.snapshot.merging([
      "selectedHostID": selectedHostID, "selectedFolder": selectedFolder,
      "conversationID": conversationID, "connected": connected, "busy": busy,
      "canRewind": canRewind,
      "status": status, "error": error, "permission": permissionObject ?? NSNull(),
      "options": optionsObject,
      "hosts": bookmarks.sorted { $0.pinned && !$1.pinned }.map {
        ["id": $0.id, "name": $0.profile.name, "address": $0.profile.url.absoluteString,
          "pinned": $0.pinned, "connected": $0.id == selectedHostID && connected] as [String: Any]
      },
      "folders": folders.map { ["cwd": $0.cwd, "name": $0.name] },
      "sessions": (selected?.sessions ?? []).sorted { $0.updatedAt > $1.updatedAt }.map {
        ["id": $0.id, "title": $0.title, "cwd": $0.cwd, "updatedAt": $0.updatedAt.timeIntervalSince1970] as [String: Any]
      },
      "messages": messages.map { ["id": $0.id.uuidString, "role": $0.role, "text": $0.text, "status": $0.status ?? "", "remoteID": $0.remoteID ?? ""] },
    ]) { _, value in value }
  }
}
