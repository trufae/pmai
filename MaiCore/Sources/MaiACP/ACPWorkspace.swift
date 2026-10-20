import Foundation
import MaiCore

/// Host navigation data, independent of the agent runtime and of any UI.
public struct ACPWorkspaceFolder: Codable, Identifiable, Equatable, Sendable {
  public var id: String { cwd }
  public var cwd: String
  public var name: String
  public var icon: String?
  public var tint: String?
  public var updatedAt: Date?

  public init(
    cwd: String, name: String, icon: String? = nil, tint: String? = nil, updatedAt: Date? = nil
  ) {
    self.cwd = cwd
    self.name = name
    self.icon = icon
    self.tint = tint
    self.updatedAt = updatedAt
  }

  var json: JSONValue {
    var fields: [String: JSONValue] = ["cwd": .string(cwd), "name": .string(name)]
    if let icon { fields["icon"] = .string(icon) }
    if let tint { fields["tint"] = .string(tint) }
    if let updatedAt { fields["updatedAt"] = .string(updatedAt.ISO8601Format()) }
    return .object(fields)
  }
}

public struct ACPSessionInfo: Codable, Identifiable, Equatable, Sendable {
  public var id: String { sessionID }
  public var sessionID: String
  public var cwd: String
  public var title: String
  public var updatedAt: Date?

  public init(sessionID: String, cwd: String, title: String, updatedAt: Date? = nil) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.title = title
    self.updatedAt = updatedAt
  }

  var json: JSONValue {
    var fields: [String: JSONValue] = [
      "sessionId": .string(sessionID), "cwd": .string(cwd), "title": .string(title),
    ]
    if let updatedAt {
      fields["updatedAt"] = .string(updatedAt.ISO8601Format())
    }
    return .object(fields)
  }
}

public struct ACPWorkspaceSnapshot: Codable, Equatable, Sendable {
  public var folders: [ACPWorkspaceFolder]
  public var sessions: [ACPSessionInfo]
  public var canManageSessions: Bool?

  public init(folders: [ACPWorkspaceFolder] = [], sessions: [ACPSessionInfo] = []) {
    self.folders = folders
    self.sessions = sessions
  }
}

/// A durable conversation supplied by the host, rather than owned by ACP.
public struct ACPWorkspaceConversation: Sendable {
  public var info: ACPSessionInfo
  public var agent: AgentDefinition
  public var transcript: [AgentMessage]
  public var createdAt: Date
  public var providerSessionID: String?

  public init(
    info: ACPSessionInfo, agent: AgentDefinition, transcript: [AgentMessage], createdAt: Date,
    providerSessionID: String? = nil
  ) {
    self.info = info
    self.agent = agent
    self.transcript = transcript
    self.createdAt = createdAt
    self.providerSessionID = providerSessionID
  }
}

/// Each host adapts its local persistence here. ACP handles transport and
/// sessions; the repository handles folders and chats; AgentRuntime runs agents.
public protocol ACPWorkspaceRepository: Sendable {
  func snapshot() async throws -> ACPWorkspaceSnapshot
  func load(sessionID: String, cwd: String) async throws -> ACPWorkspaceConversation?
  func save(_ conversation: ACPWorkspaceConversation) async throws
  func delete(sessionID: String, cwd: String) async throws
}

extension ACPWorkspaceRepository {
  public func delete(sessionID: String, cwd: String) async throws {
    throw JSONRPCError.methodNotFound(ACP.Method.sessionManage)
  }
}

/// Exposes the same projects and chats used by the CLI, including chats created
/// before a remote client connected. Workspace authorization remains in ACPServer.
public struct AgentHomeACPWorkspace: ACPWorkspaceRepository {
  public let home: AgentHome

  public init(home: AgentHome) { self.home = home }

  public func delete(sessionID: String, cwd: String) async throws {
    guard let id = UUID(uuidString: sessionID),
      let project = try home.loadProject(atWorkingDirectory: URL(fileURLWithPath: cwd))
    else { throw JSONRPCError.invalidParams("Unknown conversation") }
    _ = try home.chatStore(for: project).delete(id: id)
  }

  public func snapshot() async throws -> ACPWorkspaceSnapshot {
    let projects = try home.loadProjectIndex().orderedProjects.filter {
      !$0.workingDirectory.isEmpty && $0.workingDirectoryExists
    }
    var folders: [ACPWorkspaceFolder] = []
    var sessions: [ACPSessionInfo] = []
    for project in projects {
      let summaries = try home.chatStore(for: project).loadSummaries()
      folders.append(
        .init(
          cwd: project.workingDirectory, name: project.displayName,
          icon: project.icon, tint: project.tint?.storageIdentifier,
          updatedAt: max(project.createdAt, summaries.map(\.updatedAt).max() ?? project.createdAt)))
      sessions += summaries.map {
        ACPSessionInfo(
          sessionID: $0.id.uuidString.lowercased(), cwd: project.workingDirectory,
          title: $0.displayTitle, updatedAt: $0.updatedAt)
      }
    }
    return .init(folders: folders, sessions: sessions)
  }

  public func load(sessionID: String, cwd: String) async throws -> ACPWorkspaceConversation? {
    guard let id = UUID(uuidString: sessionID),
      let project = try home.loadProject(atWorkingDirectory: URL(fileURLWithPath: cwd)),
      home.chatStore(for: project).fileExists(for: id)
    else { return nil }
    guard let chat = try home.chatStore(for: project).loadChat(id: id) else { return nil }
    return .init(
      info: .init(
        sessionID: sessionID, cwd: cwd, title: chat.displayTitle,
        updatedAt: chat.updatedAt), agent: chat.primaryAgent, transcript: chat.messages,
      createdAt: chat.createdAt, providerSessionID: chat.sessionID)
  }

  public func save(_ conversation: ACPWorkspaceConversation) async throws {
    guard let id = UUID(uuidString: conversation.info.sessionID) else {
      throw JSONRPCError.invalidParams("Invalid conversation id")
    }
    let project = try home.openProject(
      atWorkingDirectory: URL(fileURLWithPath: conversation.info.cwd))
    let store = home.chatStore(for: project)
    var chat =
      try store.loadChat(id: id)
      ?? AgentChat(
        id: id, primaryAgent: conversation.agent, createdAt: conversation.createdAt,
        sessionID: conversation.providerSessionID ?? conversation.info.sessionID)
    // ACP session settings belong to the chat. Without this assignment an
    // existing pmai chat retains the provider and model it had before the
    // remote client changed them, then restores those stale values on reconnect.
    chat.primaryAgent = conversation.agent
    chat.messages = conversation.transcript
    chat.title = conversation.info.title
    chat.updatedAt = conversation.info.updatedAt ?? Date()
    try store.save(chat)
  }
}
