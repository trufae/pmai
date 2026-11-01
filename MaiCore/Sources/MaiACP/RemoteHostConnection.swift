import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Credentials and backend selection shared by native and command-line clients.
/// Missing backend fields preserve existing ACP bookmarks.
public struct RemoteHostConnection: Codable, Sendable {
  public var name: String
  public var url: URL
  public var token: String
  public var cwd: String
  public var backend: RemoteAgentBackend?
  public var requiresApproval: Bool?
  public var forwirohInvitation: String?
  public var connectionProtocol: ACPRemoteProtocol?

  public init(_ profile: ACPRemoteConnection) {
    name = profile.name
    url = profile.url
    token = profile.token
    cwd = profile.cwd
    backend = .acp
    requiresApproval = profile.requiresApproval
    forwirohInvitation = profile.forwirohInvitation
    connectionProtocol = profile.connectionProtocol
  }

  public init(_ profile: OpenCodeConnection) {
    name = profile.name
    url = profile.url
    token = profile.token
    cwd = profile.cwd
    backend = .openCode
  }

  private func acpConfiguration(cwd: String, sessionID: String?, resumeID: String? = nil) throws -> ACPClient.Configuration {
    var profile = try ACPRemoteConnection(
      name: name, url: url, token: token, cwd: cwd,
      connectionProtocol: connectionProtocol ?? (url.scheme == "forwiroh" ? .forwiroh : nil))
    profile.forwirohInvitation = forwirohInvitation
    try profile.validate()
    return .init(command: name, permission: .reject, remoteWorkingDirectory: cwd,
      readClientFiles: false, webSocketURL: url, bearerToken: token,
      sessionID: sessionID, forwirohInvitation: forwirohInvitation, resumeID: resumeID)
  }

  public func makeSession(cwd: String? = nil, sessionID: String? = nil, resumeID: String? = nil,
    configuration: URLSessionConfiguration = .ephemeral,
    onUpdate: (@Sendable (JSONValue) async -> Void)? = nil,
    onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil,
    onPermissionResponse: (@Sendable (JSONValue) async throws -> ACPPermissionResponse?)? = nil,
    onDisconnect: (@Sendable () async -> Void)? = nil
  ) throws -> any RemoteSessionClient {
    if backend == .openCode {
      let permission: (@Sendable (JSONValue) async throws -> String?)?
      if let onPermissionResponse {
        permission = { request in try await onPermissionResponse(request)?.optionID }
      } else { permission = onPermission }
      return OpenCodeClient(
        connection: try .init(name: name, url: url, token: token, cwd: cwd ?? self.cwd),
        sessionID: sessionID, configuration: configuration,
        onUpdate: onUpdate, onPermission: permission, onDisconnect: onDisconnect)
    }
    return ACPClient(configuration: try acpConfiguration(cwd: cwd ?? self.cwd, sessionID: sessionID, resumeID: resumeID),
      onUpdate: onUpdate, onPermission: onPermission,
      onPermissionResponse: onPermissionResponse, onDisconnect: onDisconnect)
  }

  /// Workspace connections have their own lifetime, independent of chat prompts.
  public func workspace(cwd: String? = nil, configuration: URLSessionConfiguration = .ephemeral)
    throws -> WorkspaceConnection
  {
    guard requiresApproval != true else {
      throw JSONRPCError.invalidParams("Approve this device on the remote host first.")
    }
    let cwd = cwd ?? self.cwd
    if backend == .openCode {
      return .openCode(try OpenCodeWorkspace(
        connection: .init(name: name, url: url, token: token, cwd: cwd), configuration: configuration))
    }
    return .remote(ACPClient(configuration: try acpConfiguration(cwd: cwd, sessionID: nil)), cwd: cwd)
  }
}
