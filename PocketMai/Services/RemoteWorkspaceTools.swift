import Foundation
import MaiACP

@MainActor
enum PocketMaiRemoteTools {
  static let shared = RemoteWorkspaceTools(onConnectionFailure: { id in
    guard let id = UUID(uuidString: id) else { return }
    await RemoteAgentStore.shared.setConnectionFailed(true, for: id)
  }) {
    await availableHosts()
  }

  private static func availableHosts() async -> [RemoteWorkspaceHost] {
    let store = RemoteAgentStore.shared
    var result: [RemoteWorkspaceHost] = []
    for host in store.connections where host.agentAccess == true {
      guard let token = try? await store.connectionToken(for: host.id),
        let current = store.host(host.id), current.agentAccess == true,
        current.revision == host.revision,
        let connection = try? current.connection(token: token, cwd: current.cwd)
      else { continue }
      result.append(RemoteWorkspaceHost(id: host.id.uuidString.lowercased(), connection: connection,
        isUnavailable: store.failedHostIDs.contains(host.id)))
    }
    return result
  }
}
