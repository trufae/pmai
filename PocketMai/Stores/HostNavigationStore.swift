import Foundation
import MaiACP
import Observation
import UIKit

/// Navigation owns host selection. Local chat state stays in AppStore and
/// remote state stays in the host repository, so switching never mixes them.
@MainActor @Observable
final class HostNavigationStore {
  let remotes = RemoteAgentStore.shared
  private(set) var selectedHostID: UUID?
  var selectedFolderID: String?
  var selectedConversationID: UUID?
  private(set) var loading = false
  private(set) var waitingApproval = false
  private(set) var error: String?
  private(set) var supportsDiscovery = true
  private var operation: Task<Void, Never>?
  private var client: ACPClient?
  private var generation = 0
  var activeChat: RemoteAgentChat?

  func manageConversation(_ conversation: RemoteAgentConversation, title: String?) async {
    guard let host = selectedHost else { return }
    stopDiscovery()
    error = nil
    let chat: RemoteAgentChat
    if let activeChat, activeChat.conversation.id == conversation.id,
      activeChat.bookmark.id == host.id
    {
      chat = activeChat
    } else {
      chat = RemoteAgentChat(bookmark: host, conversation: conversation)
    }
    do {
      try await chat.manage(title: title)
      if title == nil, selectedHostID == host.id, selectedConversationID == conversation.id {
        selectedConversationID = nil
      }
    } catch { self.error = error.localizedDescription }
  }

  var selectedHost: RemoteAgentBookmark? { remotes.host(selectedHostID) }
  var folders: [ACPWorkspaceFolder] {
    selectedHost.map { remotes.folders(for: $0) } ?? []
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
      stopDiscovery()
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

  func reconnect(_ id: UUID, isOffline: Bool) {
    stopDiscovery()
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
      error = "Turn off Airplane Mode in Settings to refresh this host."
      return
    }
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
        let client = ACPClient(
          configuration: .init(
            command: host.name,
            permission: .reject, remoteWorkingDirectory: host.cwd, readClientFiles: false,
            webSocketURL: host.url, bearerToken: token))
        self.client = client
        let snapshot = try await client.workspace()
        await client.disconnect()
        guard generation == attempt, !Task.isCancelled else { return }
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
      client = nil
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
    Task { await previous?.disconnect() }
    loading = false
    waitingApproval = false
  }
}
