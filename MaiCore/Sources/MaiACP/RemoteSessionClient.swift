import Foundation
import MaiCore

/// Operations shared by the app's ACP and OpenCode remote hosts.
public protocol RemoteSessionClient: AnyObject, Sendable {
  var isConnected: Bool { get async }
  func connect() async throws -> String
  func workspace() async throws -> ACPWorkspaceSnapshot?
  func manageSession(_ id: String, cwd: String, title: String?) async throws
  func prompt(_ text: String, emit: @escaping @Sendable (ProviderEvent) async -> Void)
    async throws -> ProviderStopReason
  func disconnect() async
}

extension ACPClient: RemoteSessionClient {}
