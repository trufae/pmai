import Foundation
import MaiACP
import Observation
import UIKit

enum RemoteFolderSortOrder: String, CaseIterable, Identifiable {
  case updated
  case name

  var id: String { rawValue }
  var title: String { self == .updated ? "Last Updated" : "Name" }
}

enum HostConnectionState: String {
  case connected = "Connected"
  case failed = "Connection broken"
  case disconnected = "Not connected"
}

/// Navigation owns host selection. Local chat state stays in AppStore and
/// remote state stays in the host repository, so switching never mixes them.
@MainActor @Observable
final class HostNavigationStore {
  let remotes: RemoteAgentStore
  private(set) var selectedHostID: UUID?
  private var selectedHostRevision: UUID?
  var selectedFolderID: String? {
    didSet { preferences?.set(selectedFolderID, forKey: "remote.selectedFolder") }
  }
  var selectedConversationID: UUID? {
    didSet { preferences?.set(selectedConversationID?.uuidString, forKey: "remote.selectedConversation") }
  }
  private var draftConversation: RemoteAgentConversation?
  private(set) var loading = false
  private(set) var waitingApproval = false
  private(set) var error: String?
  private(set) var supportsDiscovery = true
  private var operation: Task<Void, Never>?
  private var client: (any RemoteSessionClient)?
  private var generation = 0
  private(set) var connectedHostID: UUID?
  var activeChat: RemoteAgentChat?
  private var managementChat: RemoteAgentChat?
  private let preferences: UserDefaults?
  private let httpConfiguration: URLSessionConfiguration
  private var reconnectTask: Task<Void, Never>?
  private var reconnectDelay = 1
  private var suspended = false

  init(
    remotes: RemoteAgentStore = .shared, preferences: UserDefaults? = nil,
    httpConfiguration: URLSessionConfiguration = .ephemeral
  ) {
    self.remotes = remotes
    self.preferences = preferences
    self.httpConfiguration = httpConfiguration
    if let saved = preferences?.string(forKey: "remote.selectedHost"),
      let id = UUID(uuidString: saved), let host = remotes.host(id)
    {
      selectedHostID = id
      selectedHostRevision = host.revision
      selectedFolderID = preferences?.string(forKey: "remote.selectedFolder") ?? host.cwd
      if let saved = preferences?.string(forKey: "remote.selectedConversation"),
        let chat = host.conversations?.first(where: { $0.id.uuidString == saved })
      {
        selectedConversationID = chat.id
        selectedFolderID = chat.cwd
      }
      if selectedConversationID == nil { newConversation() }
    }
  }

  func isConnected(_ id: UUID) -> Bool {
    connectedHostID == id || (activeChat?.bookmark.id == id && activeChat?.connected == true)
  }

  func connectionState(_ id: UUID, isOffline: Bool) -> HostConnectionState {
    guard !isOffline else { return .disconnected }
    if isConnected(id) { return .connected }
    return remotes.failedHostIDs.contains(id) ? .failed : .disconnected
  }

  func disconnect(_ id: UUID) {
    if activeChat?.bookmark.id == id {
      activeChat?.disconnect()
      activeChat = nil
    }
    if selectedHostID == id { selectHost(nil, isOffline: false) }
    remotes.setConnectionFailed(false, for: id)
  }

  func suspendConnections() {
    suspended = true
    stopDiscovery()
    activeChat?.disconnect()
    managementChat?.disconnect()
  }

  func resumeConnections(isOffline: Bool) {
    guard !isOffline else { return }
    suspended = false
    if let id = selectedHostID, !isConnected(id), !loading { refresh(isOffline: false) }
    if let activeChat, activeChat.conversation.id == selectedConversationID,
      activeChat.conversation.sessionID != nil || !activeChat.messages.isEmpty
    {
      activeChat.connect()
    }
  }

  func manageConversation(
    _ conversation: RemoteAgentConversation, title: String?, isOffline: @escaping () -> Bool
  ) async {
    guard let host = selectedHost else { return }
    guard !isOffline() || conversation.sessionID == nil else {
      error = "Turn off Airplane Mode in Settings to manage remote conversations."
      return
    }
    stopDiscovery()
    error = nil
    let chat: RemoteAgentChat
    if let activeChat, activeChat.conversation.id == conversation.id,
      activeChat.bookmark.id == host.id
    {
      chat = activeChat
    } else {
      chat = RemoteAgentChat(
        bookmark: host, conversation: conversation, store: remotes, isOffline: isOffline)
    }
    managementChat = chat
    defer {
      if managementChat === chat { managementChat = nil }
      if !suspended { resumeConnections(isOffline: isOffline()) }
    }
    do {
      try await chat.manage(title: title)
      if title == nil, selectedHostID == host.id, selectedConversationID == conversation.id {
        newConversation()
      }
    } catch is CancellationError {
    } catch { self.error = error.localizedDescription }
  }

  var selectedHost: RemoteAgentBookmark? { remotes.host(selectedHostID) }
  var folders: [ACPWorkspaceFolder] {
    selectedHost.map { remotes.folders(for: $0) } ?? []
  }

  func folders(matching query: String, sortedBy order: RemoteFolderSortOrder)
    -> [ACPWorkspaceFolder]
  {
    let matching = folders.filter { SidebarSearch.matches(query, in: [$0.name]) }
    let pinned = matching.filter { isFolderPinned($0.cwd) }
    let unpinned = matching.filter { !isFolderPinned($0.cwd) }.sorted { left, right in
      if order == .updated, left.updatedAt != right.updatedAt {
        return (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast)
      }
      let comparison = left.name.localizedStandardCompare(right.name)
      return comparison == .orderedSame ? left.cwd < right.cwd : comparison == .orderedAscending
    }
    return pinned + unpinned
  }
  var conversations: [RemoteAgentConversation] {
    guard let host = selectedHost else { return [] }
    return remotes.conversations(for: host).filter { $0.cwd == selectedFolderID }
  }
  var selectedConversation: RemoteAgentConversation? {
    guard let host = selectedHost else { return nil }
    return host.conversations?.first { $0.id == selectedConversationID }
      ?? (draftConversation?.id == selectedConversationID ? draftConversation : nil)
  }

  func selectHost(_ id: UUID?, isOffline: Bool) {
    let host = remotes.host(id)
    guard selectedHostID != id || selectedHostRevision != host?.revision else {
      resumeConnections(isOffline: isOffline)
      return
    }
    suspendConnections()
    activeChat = nil
    selectedHostRevision = host?.revision
    if selectedHostID != id {
      selectedHostID = id
      preferences?.set(id?.uuidString, forKey: "remote.selectedHost")
      selectedFolderID = host?.cwd
      draftConversation = nil
      selectedConversationID = nil
      if host != nil { newConversation() }
      error = nil
    }
    if id != nil { refresh(isOffline: isOffline) }
  }

  func selectFolder(_ cwd: String, preservingDraft: Bool = false) {
    selectedFolderID = cwd
    if preservingDraft, let draftConversation, draftConversation.id == selectedConversationID {
      self.draftConversation?.cwd = cwd
    } else {
      newConversation()
    }
  }

  func selectConversation(_ id: UUID) {
    guard let chat = selectedHost?.conversations?.first(where: { $0.id == id }) else { return }
    selectedFolderID = chat.cwd
    selectedConversationID = chat.id
  }

  var recentConversations: [RemoteAgentConversation] {
    Array((selectedHost?.conversations ?? [])
      .filter { $0.id != selectedConversationID && ($0.sessionID != nil || !$0.messages.isEmpty) }
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(ConversationSummary.recentCacheLimit).reversed())
  }

  func isFolderPinned(_ cwd: String) -> Bool {
    selectedHost?.pinnedFolderPaths?.contains(cwd) == true
  }

  func isHostPinned(_ id: UUID) -> Bool {
    remotes.isHostPinned(id)
  }

  func toggleHostPin(_ id: UUID) {
    remotes.toggleHostPin(id)
  }

  func toggleFolderPin(_ cwd: String) {
    guard let selectedHostID else { return }
    remotes.toggleFolderPin(hostID: selectedHostID, cwd: cwd)
  }

  func isConversationPinned(_ id: UUID) -> Bool {
    selectedHost?.pinnedConversationIDs?.contains(id) == true
  }

  func toggleConversationPin(_ id: UUID) {
    guard let selectedHostID else { return }
    remotes.toggleConversationPin(hostID: selectedHostID, conversationID: id)
  }

  func reconnect(_ id: UUID, isOffline: Bool) {
    guard !isOffline else { return }
    remotes.reconnect(id)
    selectHost(id, isOffline: isOffline)
  }

  @discardableResult
  func newConversation() -> RemoteAgentConversation? {
    guard let host = selectedHost else { return nil }
    let chat = RemoteAgentConversation(cwd: selectedFolderID ?? host.cwd)
    draftConversation = chat
    selectedConversationID = chat.id
    return chat
  }

  func refresh(isOffline: Bool) {
    guard let host = selectedHost, !loading else { return }
    guard !isOffline else {
      suspendConnections()
      error = "Turn off Airplane Mode in Settings to refresh this host."
      return
    }
    stopDiscovery()
    suspended = false
    loading = true
    error = nil
    remotes.setConnectionFailed(false, for: host.id)
    generation += 1
    let attempt = generation
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        var token = try remotes.token(for: host.id)
        if host.requiresApproval == true {
          waitingApproval = true
          let pairingClient = ACPClient(
            configuration: .init(
              command: host.name,
              webSocketURL: host.url, bearerToken: token,
              forwirohInvitation: host.forwirohInvitation))
          self.client = pairingClient
          token = try await pairingClient.requestPairing(
            clientID: host.id.uuidString.lowercased(),
            name: UIDevice.current.name + " · PocketMai")
          guard generation == attempt, !Task.isCancelled else { return }
          try remotes.acceptPairing(host.id, token: token)
          waitingApproval = false
        }
        let client = try host.makeClient(
          token: token, cwd: host.cwd,
          httpConfiguration: httpConfiguration,
          onDisconnect: { [weak self] in await self?.connectionClosed(attempt: attempt) })
        self.client = client
        let snapshot = try await client.workspace()
        guard generation == attempt, !Task.isCancelled else { return }
        let connected = await client.isConnected
        guard generation == attempt, !Task.isCancelled else { return }
        connectedHostID = connected ? host.id : nil
        reconnectDelay = 1
        remotes.setConnectionFailed(!connected, for: host.id)
        supportsDiscovery = snapshot != nil
        if let snapshot { remotes.updateWorkspace(host.id, snapshot: snapshot, inBackground: true) }
        if selectedConversation?.sessionID == nil,
          selectedConversation?.messages.isEmpty != false,
          !folders.contains(where: { $0.cwd == selectedFolderID }),
          let cwd = folders.first?.cwd, cwd != selectedFolderID
        {
          selectFolder(cwd, preservingDraft: true)
        }
      } catch {
        guard generation == attempt else { return }
        self.error = error.localizedDescription
        remotes.setConnectionFailed(!(error is CancellationError), for: host.id)
        let previous = client
        client = nil
        await previous?.disconnect()
        guard generation == attempt else { return }
        loading = false
        if RemoteConnectionRecovery.shouldRetry(error) { scheduleReconnect() }
      }
      guard generation == attempt else { return }
      operation = nil
      loading = false
      waitingApproval = false
    }
  }

  func stopDiscovery() {
    reconnectTask?.cancel()
    reconnectTask = nil
    generation += 1
    operation?.cancel()
    operation = nil
    let previous = client
    client = nil
    connectedHostID = nil
    Task { await previous?.disconnect() }
    loading = false
    waitingApproval = false
  }

  private func connectionClosed(attempt: Int) {
    guard generation == attempt, client != nil else { return }
    if let selectedHostID { remotes.setConnectionFailed(true, for: selectedHostID) }
    connectedHostID = nil
    error = "Connection lost. Reconnecting…"
    // Invalidate callbacks before closing the failed client.
    stopDiscovery()
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    guard !suspended, selectedHostID != nil, reconnectTask == nil else { return }
    let delay = reconnectDelay
    reconnectDelay = min(30, reconnectDelay * 2)
    reconnectTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self, !Task.isCancelled, !suspended else { return }
      reconnectTask = nil
      refresh(isOffline: false)
    }
  }
}
