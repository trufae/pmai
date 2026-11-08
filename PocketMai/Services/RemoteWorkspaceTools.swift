import Foundation
import MaiACP

@MainActor
enum PocketMaiRemoteTools {
  static let shared = RemoteWorkspaceTools(onConnectionFailure: { id in
    guard let id = UUID(uuidString: id) else { return }
    await RemoteAgentStore.shared.setConnectionFailed(true, for: id)
  }) {
    await MainActor.run {
      let store = RemoteAgentStore.shared
      return store.connections.compactMap { host in
        guard host.agentAccess == true,
          let connection = try? host.connection(token: store.token(for: host.id), cwd: host.cwd)
        else { return nil }
        return RemoteWorkspaceHost(id: host.id.uuidString.lowercased(), connection: connection,
          isUnavailable: store.failedHostIDs.contains(host.id))
      }
    }
  }
}
