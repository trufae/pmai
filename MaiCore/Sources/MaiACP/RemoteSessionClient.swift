import Foundation
import MaiCore

public struct RemotePromptRequest: Sendable {
  public var text: String
  public var command: String?
  public var skillID: String?

  public init(text: String, command: String? = nil, skillID: String? = nil) {
    self.text = text
    self.command = command
    self.skillID = skillID
  }

  public var draft: String {
    command.map { "/" + $0 + (text.isEmpty ? "" : " " + text) } ?? text
  }
}

/// Operations shared by the app's ACP and OpenCode remote hosts.
public protocol RemoteSessionClient: AnyObject, Sendable {
  var isConnected: Bool { get async }
  var supportsHistoryRewind: Bool { get }
  /// Some clients learn this capability during their connection handshake.
  func historyRewindSupported() async -> Bool
  func connect() async throws -> String
  /// Resume observing work already running on the host without resubmitting it.
  func resumeUpdates() async throws
  func workspace() async throws -> ACPWorkspaceSnapshot?
  func manageSession(_ id: String, cwd: String, title: String?) async throws
  func manageSession(_ id: String, cwd: String, action: ACPSessionAction, title: String?) async throws -> ACPSessionInfo?
  func moveSession(_ id: String, cwd: String, destinationCwd: String) async throws -> ACPSessionInfo?
  func configurationOptions() async throws -> [RemoteSessionOption]
  func promptCatalog() async throws -> PromptCatalog
  func setConfigurationOption(id: String, value: JSONValue) async throws -> [RemoteSessionOption]
  func prompt(_ text: String, emit: @escaping @Sendable (ProviderEvent) async -> Void)
    async throws -> ProviderStopReason
  func prompt(_ request: RemotePromptRequest, emit: @escaping @Sendable (ProviderEvent) async -> Void)
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
  public func moveSession(_ id: String, cwd: String, destinationCwd: String) async throws -> ACPSessionInfo? {
    throw JSONRPCError.invalidParams("This host does not support moving conversations")
  }

  public func manageSession(_ id: String, cwd: String, action: ACPSessionAction,
    title: String? = nil) async throws -> ACPSessionInfo? {
    guard action == .rename || action == .delete else {
      throw JSONRPCError.invalidParams("This host does not support this conversation action")
    }
    if action == .rename, title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
      throw JSONRPCError.invalidParams("Provide a nonempty title")
    }
    try await manageSession(id, cwd: cwd, title: action == .delete ? nil : title)
    return nil
  }

  public func resumeUpdates() async throws {}
  public func promptCatalog() async throws -> PromptCatalog { PromptCatalog(builtins: []) }
  public func prompt(_ request: RemotePromptRequest,
    emit: @escaping @Sendable (ProviderEvent) async -> Void) async throws -> ProviderStopReason {
    try await prompt(request.draft, emit: emit)
  }
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
