import Foundation
import MaiACP
import MaiCore
import Observation

/// Connections and transcripts belong to the app, independently of its windows.
@MainActor @Observable
final class MacBackend {
  let home: AgentHome
  let servers: MacServerStore
  var hosts: [ACPRemoteHost] = []
  var conversations: [MacConversation] = []
  var snapshots: [UUID?: ACPWorkspaceSnapshot] = [:]
  weak var activeWorkspace: MacWorkspace?
  private var preparation: Task<Void, Error>?

  init() {
    let home = AgentHome.resolve()
    self.home = home
    servers = MacServerStore(home: home)
  }

  var hostStore: ACPRemoteHostStore { .init(directory: home.rootURL.appendingPathComponent("remotes")) }

  func prepare() async throws {
    if preparation == nil {
      preparation = Task {
        try await ForwirohRemote.shared.configure(
          directory: home.rootURL.appendingPathComponent("forwiroh-client"), name: "pmai for Mac")
      }
    }
    try await preparation?.value
  }

  func refresh(hostID: UUID?) async throws {
    hosts = try hostStore.hosts()
    if let hostID {
      guard let host = hosts.first(where: { $0.id == hostID }) else {
        snapshots[hostID] = nil
        return
      }
      let client = try hostStore.connection(for: host).makeSession()
      do { snapshots[hostID] = try await client.workspace() ?? .init() }
      catch { await client.disconnect(); throw error }
      await client.disconnect()
    } else {
      snapshots[nil] = try await AgentHomeACPWorkspace(home: home).snapshot()
    }
  }

  func close() async {
    await servers.close()
    for conversation in conversations { conversation.stop() }
    for conversation in conversations { await conversation.close() }
  }
}
