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

/// Navigation owns host selection. Local chat state stays in AppStore and
/// remote state stays in the host repository, so switching never mixes them.
@MainActor @Observable
final class HostNavigationStore {
  let remotes: RemoteAgentStore
  private(set) var selectedHostID: UUID?
  var selectedFolderID: String?
  var selectedConversationID: UUID?
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

  init(remotes: RemoteAgentStore = .shared) {
    self.remotes = remotes
  }

  func isConnected(_ id: UUID) -> Bool {
    connectedHostID == id || (activeChat?.bookmark.id == id && activeChat?.connected == true)
  }

  func disconnect(_ id: UUID) {
    if activeChat?.bookmark.id == id {
      activeChat?.disconnect()
      activeChat = nil
    }
    if selectedHostID == id { selectHost(nil, isOffline: false) }
  }

  func suspendConnections() {
    stopDiscovery()
    activeChat?.disconnect()
    managementChat?.disconnect()
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
    defer { if managementChat === chat { managementChat = nil } }
    do {
      try await chat.manage(title: title)
      if title == nil, selectedHostID == host.id, selectedConversationID == conversation.id {
        selectedConversationID = nil
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
    return remotes.conversations(for: host).first { $0.id == selectedConversationID }
  }

  func selectHost(_ id: UUID?, isOffline: Bool) {
    if selectedHostID != id {
      suspendConnections()
      activeChat = nil
      selectedHostID = id
      selectedFolderID = remotes.host(id)?.cwd
      selectedConversationID = nil
      error = nil
    }
    if id != nil { refresh(isOffline: isOffline) }
  }

  func selectFolder(_ cwd: String) {
    selectedFolderID = cwd
    selectedConversationID = nil
  }

  func isFolderPinned(_ cwd: String) -> Bool {
    selectedHost?.pinnedFolderPaths?.contains(cwd) == true
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
    suspendConnections()
    remotes.reconnect(id)
    selectHost(id, isOffline: isOffline)
  }

  @discardableResult
  func newConversation() -> RemoteAgentConversation? {
    guard let hostID = selectedHostID, let cwd = selectedFolderID else { return nil }
    let chat = remotes.newConversation(hostID: hostID, cwd: cwd)
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
    loading = true
    error = nil
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
              webSocketURL: host.url, bearerToken: token))
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
          onDisconnect: { [weak self] in await self?.connectionClosed(attempt: attempt) })
        self.client = client
        let snapshot = try await client.workspace()
        guard generation == attempt, !Task.isCancelled else { return }
        let connected = await client.isConnected
        guard generation == attempt, !Task.isCancelled else { return }
        connectedHostID = connected ? host.id : nil
        supportsDiscovery = snapshot != nil
        if let snapshot { remotes.updateWorkspace(host.id, snapshot: snapshot) }
        if !folders.contains(where: { $0.cwd == selectedFolderID }) {
          selectedFolderID = folders.first?.cwd
        }
      } catch {
        guard generation == attempt else { return }
        self.error = error.localizedDescription
        await client?.disconnect()
      }
      guard generation == attempt else { return }
      operation = nil
      loading = false
      waitingApproval = false
    }
  }

  func stopDiscovery() {
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
    guard generation == attempt else { return }
    connectedHostID = nil
    if !loading { error = "Disconnected from this host. Reconnect to continue." }
  }
}
