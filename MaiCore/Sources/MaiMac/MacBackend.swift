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
  var boxes: [ProjectBox] = []
  private var boxSessions: [UUID: [ACPSessionInfo]] = [:]
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
      let manager = ProjectBoxes(home: home, environment: MacCLI.environment)
      boxes = try manager.list()
      var local = try await AgentHomeACPWorkspace(home: home).snapshot()
      var failure: Error?
      for box in boxes where box.enabled {
        local.sessions.removeAll { $0.cwd == box.project || $0.cwd.hasPrefix(box.project + "/") }
        do {
          if try await manager.isRunning(box) {
            let cwd = URL(fileURLWithPath: box.project)
            let launch = try manager.launchCommand(box, arguments: ["--acp"], cwd: cwd)
            let client = ACPClient(configuration: .init(command: launch.command,
              arguments: launch.arguments, environment: MacCLI.environment,
              workingDirectory: cwd, remoteWorkingDirectory: box.project, readClientFiles: false))
            do {
              let guest = try await client.workspace() ?? .init()
              boxSessions[box.id] = guest.sessions.filter { $0.cwd == box.project || $0.cwd.hasPrefix(box.project + "/") }
            } catch { await client.disconnect(); throw error }
            await client.disconnect()
          }
        } catch { failure = error }
        local.sessions += boxSessions[box.id] ?? []
      }
      // Cross-boundary moves cannot be handled by a single ACP worker.
      if boxes.contains(where: \.enabled) { local.canMoveSessions = false }
      snapshots[nil] = local
      if let failure { throw failure }
    }
  }

  func close() async {
    await servers.close()
    for conversation in conversations { conversation.stop() }
    for conversation in conversations { await conversation.close() }
  }
}
