import Foundation
import MaiCore

/// Operations shared by the app's ACP and OpenCode remote hosts.
public protocol RemoteSessionClient: AnyObject, Sendable {
  var isConnected: Bool { get async }
  var supportsHistoryRewind: Bool { get }
  /// Some clients learn this capability during their connection handshake.
  func historyRewindSupported() async -> Bool
  func connect() async throws -> String
  func workspace() async throws -> ACPWorkspaceSnapshot?
  func manageSession(_ id: String, cwd: String, title: String?) async throws
  func configurationOptions() async throws -> [RemoteSessionOption]
  func setConfigurationOption(id: String, value: JSONValue) async throws -> [RemoteSessionOption]
  func prompt(_ text: String, emit: @escaping @Sendable (ProviderEvent) async -> Void)
    async throws -> ProviderStopReason
  /// Removes the selected message and everything after it. Nil clears the history.
  /// This changes conversation history only, without reverting workspace files.
  func rewind(to messageID: String?) async throws
  func inject(_ text: String) async throws
  func injectionSupported() async -> Bool
  func cancel() async
  func disconnect() async
}

extension RemoteSessionClient {
  public var supportsHistoryRewind: Bool { false }
  public func injectionSupported() async -> Bool { false }
  public func inject(_ text: String) async throws {
    throw JSONRPCError.invalidParams("Update the remote pmai to send messages during a response.")
  }
  public func cancel() async { await disconnect() }

  public func historyRewindSupported() async -> Bool { supportsHistoryRewind }

  public func rewind(to messageID: String?) async throws {
    throw JSONRPCError.invalidParams("This host does not support rewinding conversation history.")
  }
}

extension ACPClient: RemoteSessionClient {}
