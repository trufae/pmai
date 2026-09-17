import Foundation

/// A listing entry read from a chat file without materializing its transcript.
public struct AgentChatSummary: ChatRecord, Decodable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var agentID: String
  public var provider: ProviderID
  public var model: String
  public var createdAt: Date
  public var updatedAt: Date
  public var isArchived: Bool
  /// Messages exchanged with the model, excluding configured instructions.
  public var messageCount: Int
  public var hasPendingContent: Bool

  public init(chat: AgentChat) {
    id = chat.id
    title = chat.title
    agentID = chat.primaryAgent.id
    provider = chat.primaryAgent.provider
    model = chat.primaryAgent.model
    createdAt = chat.createdAt
    updatedAt = chat.updatedAt
    isArchived = chat.isArchived
    messageCount = chat.conversationMessages.count
    hasPendingContent = !chat.pendingContent.isEmpty
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, primaryAgent, messages, pendingContent, createdAt, updatedAt, isArchived
  }

  private enum AgentKeys: String, CodingKey {
    case id, provider, model
  }

  private struct RoleOnly: Decodable {
    var role: AgentRole
  }

  private struct Ignored: Decodable {
    init(from decoder: Decoder) throws {}
  }

  /// Decodes the same layout as `AgentChat`, skipping message contents.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    let agent = try container.nestedContainer(keyedBy: AgentKeys.self, forKey: .primaryAgent)
    agentID = try agent.decode(String.self, forKey: .id)
    provider = try agent.decode(ProviderID.self, forKey: .provider)
    model = try agent.decode(String.self, forKey: .model)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    messageCount = try container.decode([RoleOnly].self, forKey: .messages)
      .filter { $0.role != .system }.count
    hasPendingContent =
      !(try container.decodeIfPresent([Ignored].self, forKey: .pendingContent) ?? []).isEmpty
  }

  public var displayTitle: String {
    AgentChat.isPlaceholderTitle(title)
      ? AgentChat.placeholderTitle : title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var hasConversation: Bool { messageCount > 0 }

  public var isDisposable: Bool {
    AgentChat.isDisposable(
      title: title,
      hasConversation: hasConversation,
      isBusy: false,
      isKept: isArchived)
  }

  private static func newestFirst(_ lhs: AgentChatSummary, _ rhs: AgentChatSummary) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return lhs.createdAt > rhs.createdAt
  }

  /// The sidebar order: active chats newest first, then archived ones.
  public static func precedes(_ lhs: AgentChatSummary, _ rhs: AgentChatSummary) -> Bool {
    if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
    return newestFirst(lhs, rhs)
  }
}

/// The file store for MaiCore's own chat shape: one `AgentChat` per file.
public typealias AgentChatStore = ChatFileStore<AgentChat>

extension ChatFileStore where Chat == AgentChat {
  /// Listing entries for every readable, non-disposable chat in sidebar order.
  public func loadSummaries(
    onFailure: ((ChatFileStoreError) -> Void)? = nil
  ) throws -> [AgentChatSummary] {
    try loadRecords(AgentChatSummary.self, onFailure: onFailure)
      .filter { !$0.isDisposable }
      .sorted(by: AgentChatSummary.precedes)
  }

  /// Loads every chat into a workspace that is already committed, so a later
  /// `commit` writes only what the host changes.
  public func loadWorkspace(
    selecting selectedChatID: UUID? = nil,
    onFailure: ((ChatFileStoreError) -> Void)? = nil
  ) throws -> AgentChatWorkspace {
    var workspace = AgentChatWorkspace(
      chats: try loadChats(onFailure: onFailure), selectedChatID: selectedChatID)
    workspace.markCommitted()
    return workspace
  }

  /// Writes the chats the workspace changed, deletes the ones it removed or
  /// that became disposable while in it, and clears its change tracking. The
  /// workspace is the source of truth here, unlike a plain `save`.
  public func commit(_ workspace: inout AgentChatWorkspace) throws {
    for id in workspace.removedChatIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      try delete(id: id)
    }
    for chat in workspace.chats where workspace.modifiedChatIDs.contains(chat.id) {
      if chat.isDisposable {
        try delete(id: chat.id)
      } else {
        try save(chat)
      }
    }
    workspace.markCommitted()
  }
}

/// The per-user root that outlives any one project: the index of every project
/// a host has opened, plus state shared across them.
///
/// Layout:
///
///     ~/.pmai/projects.json              index of known projects
///     ~/.pmai/history.json               editable input history
///     ~/.pmai/stats.json                 tokens/s and time in use per provider:model
///     <workdir>/.pmai/project.json       the project's own id, name, and tint
///     <workdir>/.pmai/settings.json      project-local CLI settings
///     <workdir>/.pmai/chats/<id>.json    one file per chat
///     <workdir>/.pmai/memory.md          the project's durable memory
///     <workdir>/.pmai/todo.md            the project's todo list
///     <workdir>/.pmai/skills/<name>/SKILL.md  the project's own skills
///     ~/.pmai/skills/<name>/SKILL.md     skills every project may use
///     ~/.pmai/projects/<id>/             the same files, for read-only directories
///
/// The root is `$PMAI_HOME` when set, else `$HOME/.pmai`.
public struct AgentHome: Sendable {
  public static let directoryName = ".pmai"
  public static let environmentVariable = "PMAI_HOME"
  public static let projectIndexFilename = "projects.json"
  public static let projectFilename = "project.json"
  public static let chatsDirectoryName = "chats"
  public static let historyFilename = "history.json"
  public static let usageStatsFilename = "stats.json"
  public static let skillsDirectoryName = "skills"

  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL
  }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> AgentHome {
    let userHome = userHomeDirectory(environment: environment, fallback: homeDirectory)
    if let override = environment[environmentVariable]?.trimmingCharacters(
      in: .whitespacesAndNewlines), !override.isEmpty
    {
      return AgentHome(
        rootURL: URL(
          fileURLWithPath: expandUserPath(
            override, environment: environment, fallback: homeDirectory),
          isDirectory: true))
    }
    return AgentHome(
      rootURL: userHome.appendingPathComponent(directoryName, isDirectory: true))
  }

  /// The shell's home is authoritative for command-line hosts such as Termux.
  /// Foundation's home remains the fallback for app hosts and sparse process
  /// environments.
  public static func userHomeDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fallback: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    guard
      let raw = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty, raw.hasPrefix("/")
    else { return fallback }
    return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
  }

  /// Expands `~` against the same home used by `resolve`, avoiding Foundation
  /// and the shell disagreeing about the current user's directory on Android.
  public static func expandUserPath(
    _ path: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fallback: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> String {
    let home = userHomeDirectory(environment: environment, fallback: fallback)
    if path == "~" { return home.path }
    if path.hasPrefix("~/") {
      return home.appendingPathComponent(String(path.dropFirst(2))).path
    }
    return NSString(string: path).expandingTildeInPath
  }

  public var projectIndexURL: URL {
    rootURL.appendingPathComponent(Self.projectIndexFilename)
  }

  public var historyURL: URL {
    rootURL.appendingPathComponent(Self.historyFilename)
  }

  /// The usage ledger every project shares: a model's speed does not depend
  /// on which directory it was asked from.
  public var usageStatsURL: URL {
    rootURL.appendingPathComponent(Self.usageStatsFilename)
  }

  /// Skills every project may use, one folder with a SKILL.md per skill.
  public var skillsDirectoryURL: URL {
    rootURL.appendingPathComponent(Self.skillsDirectoryName, isDirectory: true)
  }

  /// Storage for projects whose working directory cannot hold a `.pmai` folder.
  public var projectsDirectoryURL: URL {
    rootURL.appendingPathComponent("projects", isDirectory: true)
  }

  public func loadProjectIndex() throws -> AgentProjectIndex {
    guard FileManager.default.fileExists(atPath: projectIndexURL.path) else {
      return AgentProjectIndex()
    }
    return try AgentProjectIndex.load(from: projectIndexURL)
  }

  public func saveProjectIndex(_ index: AgentProjectIndex) throws {
    try index.save(to: projectIndexURL)
  }

  /// Where a project keeps its files: `.pmai` inside its working directory
  /// when that directory is writable or already holds one, else a directory
  /// named after the project id under the home.
  public func storageDirectory(for project: AgentProject) -> URL {
    if let workingDirectory = project.workingDirectoryURL {
      let local = workingDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
      if FileManager.default.fileExists(atPath: local.path)
        || FileManager.default.isWritableFile(atPath: workingDirectory.path)
      {
        return local
      }
    }
    return projectsDirectoryURL.appendingPathComponent(project.id.uuidString, isDirectory: true)
  }

  public func projectFileURL(for project: AgentProject) -> URL {
    storageDirectory(for: project).appendingPathComponent(Self.projectFilename)
  }

  /// The project's durable memory file, beside its chats.
  public func memoryURL(for project: AgentProject) -> URL {
    storageDirectory(for: project).appendingPathComponent(AgentMemory.filename)
  }

  /// The project's todo list, beside its chats.
  public func todoURL(for project: AgentProject) -> URL {
    storageDirectory(for: project).appendingPathComponent(AgentTodoList.filename)
  }

  /// The project's own skills, beside its chats; they shadow the home's.
  public func skillsURL(for project: AgentProject) -> URL {
    storageDirectory(for: project).appendingPathComponent(
      Self.skillsDirectoryName, isDirectory: true)
  }

  public func chatStore(for project: AgentProject) -> AgentChatStore {
    AgentChatStore(
      directoryURL: storageDirectory(for: project).appendingPathComponent(
        Self.chatsDirectoryName, isDirectory: true))
  }

  /// The project rooted at a directory, from its own `project.json` or from
  /// the index; nil when the directory was never opened.
  public func loadProject(atWorkingDirectory directory: URL) throws -> AgentProject? {
    let path = AgentProject.standardizedPath(directory.path)
    let localFile = directory.appendingPathComponent(Self.directoryName, isDirectory: true)
      .appendingPathComponent(Self.projectFilename)
    if FileManager.default.fileExists(atPath: localFile.path) {
      var project = try Self.decodeProject(at: localFile)
      project.workingDirectory = path
      return project
    }
    guard let indexed = try loadProjectIndex().project(atWorkingDirectory: path) else {
      return nil
    }
    let fallbackFile = projectFileURL(for: indexed)
    guard FileManager.default.fileExists(atPath: fallbackFile.path) else { return indexed }
    var project = try Self.decodeProject(at: fallbackFile)
    project.workingDirectory = path
    return project
  }

  /// Opens the project rooted at a directory, creating and registering it on
  /// first use, and records the visit in the index.
  @discardableResult
  public func openProject(atWorkingDirectory directory: URL, at date: Date = Date()) throws
    -> AgentProject
  {
    var project =
      try loadProject(atWorkingDirectory: directory)
      ?? AgentProject(workingDirectory: directory.path, createdAt: date)
    project.markOpened(at: date)
    try saveProject(project)
    return project
  }

  /// Writes the project's own file and refreshes its entry in the index.
  public func saveProject(_ project: AgentProject) throws {
    let url = projectFileURL(for: project)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try MaiJSONCoding.default.makeEncoder().encode(project).write(to: url, options: .atomic)
    var index = try loadProjectIndex()
    index.upsert(project)
    try saveProjectIndex(index)
  }

  /// Drops a project from the index. Its files stay where they are.
  @discardableResult
  public func forgetProject(id: UUID) throws -> AgentProject? {
    var index = try loadProjectIndex()
    guard let removed = index.remove(id: id) else { return nil }
    try saveProjectIndex(index)
    return removed
  }

  private static func decodeProject(at url: URL) throws -> AgentProject {
    try MaiJSONCoding.default.makeDecoder().decode(AgentProject.self, from: Data(contentsOf: url))
  }
}
