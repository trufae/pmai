import Foundation
import MaiACP

@MainActor
enum PocketMaiRemoteTools {
  static let shared = RemoteWorkspaceTools {
    try await MainActor.run {
      try RemoteAgentStore.shared.connections.filter { $0.agentAccess == true }.map { host in
        RemoteWorkspaceHost(id: host.id.uuidString.lowercased(),
          connection: try host.connection(token: RemoteAgentStore.shared.token(for: host.id), cwd: host.cwd))
      }
    }
  }
}
