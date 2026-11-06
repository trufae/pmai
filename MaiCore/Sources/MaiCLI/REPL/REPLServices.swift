import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Provider endpoints shared by the REPL and hosted pmai commands.
final class ProviderBaseURLStore: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [String: URL]

  init(_ urls: [String: URL]) {
    self.urls = urls
  }

  func url(for providerID: String) -> URL? {
    lock.withLock { urls[providerID] }
  }

  func set(_ url: URL?, for providerID: String) {
    lock.withLock { urls[providerID] = url }
  }

  func replace(_ urls: [String: URL]) {
    lock.withLock { self.urls = urls }
  }

  func snapshot() -> [String: URL] {
    lock.withLock { urls }
  }
}

struct REPLServices: Sendable {
  var approvalHandler: TerminalApprovalHandler
  var promptFileAccess: PromptFileAccess
  var configurationPath: String?
  var remoteTerminalSettingsURL: URL
  var providerBaseURLs: ProviderBaseURLStore
  var memory: MemoryState
  var todo: TodoState
  var skills: SkillState
  var themesDirectory: URL
  /// Tokens/s and time in use per provider:model, shared with the runtime.
  var usageStats: ModelUsageStore
  let modelCatalog = REPLModelCatalog()
  let voiceCatalog = REPLVoiceCatalog()
}

/// Where the current project's todo list lives. The `todo_*` tools are
/// registered before the project is opened, so they resolve the file through
/// this box on every call; the file itself is the only copy, read fresh each
/// time so edits made in an editor are seen at once.
final class TodoState: @unchecked Sendable {
  private let lock = NSLock()
  private let home: AgentHome
  private var project: AgentProject?

  init(home: AgentHome) {
    self.home = home
  }

  func focus(project: AgentProject) {
    lock.withLock { self.project = project }
  }

  var url: URL? {
    lock.withLock { project.map { home.todoURL(for: $0) } }
  }

  var current: AgentTodoList {
    url.flatMap { try? AgentTodoList.load(from: $0) } ?? AgentTodoList()
  }

  func save(_ list: AgentTodoList) throws {
    guard let url else { throw CLIError.noProject }
    try list.save(to: url)
  }
}

/// Where skills are read from: the project's storage `skills` folder, then the
/// `skills` folder under the home. The `skills_*` tools are registered before
/// the project is opened, so until then the start directory stands in for
/// it; every listing and call reads the SKILL.md files afresh.
final class SkillState: @unchecked Sendable {
  private let lock = NSLock()
  private let home: AgentHome
  private var project: AgentProject?

  init(home: AgentHome) {
    self.home = home
  }

  func focus(project: AgentProject) {
    lock.withLock { self.project = project }
  }

  /// The project's directory first, so its skills shadow the home's.
  var directories: [URL] {
    let local =
      lock.withLock { project.map { home.skillsURL(for: $0) } }
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent(AgentHome.directoryName, isDirectory: true)
      .appendingPathComponent(AgentHome.skillsDirectoryName, isDirectory: true)
    return [local, userDirectory]
  }

  var userDirectory: URL { home.skillsDirectoryURL }

  var catalog: AgentSkillCatalog { AgentSkillCatalog.load(directories: directories) }
}

/// Everything the memory feature needs that outlives one command: where the
/// notes are stored, which chats the `chats_*` tools may reach, and how far.
/// The REPL keeps it current; commands and tools read it.
///
/// The project arrives after the runtime is built, so the tools are registered
/// against this box rather than against a project they cannot see yet.
final class MemoryState: @unchecked Sendable {
  private let lock = NSLock()
  private let home: AgentHome
  private var project: AgentProject?
  private var currentChatID: UUID?
  private var memory = AgentMemory()
  private var settings = ConfiguredMemory()

  init(home: AgentHome) {
    self.home = home
  }

  /// Adopts the project whose memory this is, loading its notes from disk.
  func adopt(project: AgentProject, settings: ConfiguredMemory) {
    lock.withLock {
      self.project = project
      self.settings = settings
      memory = (try? AgentMemory.load(from: home.memoryURL(for: project))) ?? AgentMemory()
    }
  }

  func focus(project: AgentProject, chatID: UUID?) {
    lock.withLock {
      self.project = project
      currentChatID = chatID
    }
  }

  func apply(_ settings: ConfiguredMemory) {
    lock.withLock { self.settings = settings }
  }

  var current: AgentMemory { lock.withLock { memory } }
  var configuration: ConfiguredMemory { lock.withLock { settings } }
  var readsOtherChats: Bool { lock.withLock { settings.scope != .none } }

  var url: URL? {
    lock.withLock { project.map { home.memoryURL(for: $0) } }
  }

  /// What the runtime should inject, or nil when memory is off or empty.
  var promptSection: String? {
    lock.withLock { settings.enabled ? memory.promptSection : nil }
  }

  func save(_ updated: AgentMemory) throws {
    let url = lock.withLock { () -> URL? in
      memory = updated
      return project.map { home.memoryURL(for: $0) }
    }
    guard let url else { throw CLIError.noProvider }
    try updated.save(to: url)
  }

  func reload() {
    lock.withLock {
      guard let project else { return }
      memory = (try? AgentMemory.load(from: home.memoryURL(for: project))) ?? AgentMemory()
    }
  }

  /// Every chat in the current project, newest first, for `/memory learn --all`.
  func projectChats() -> [MemoryChat] {
    guard let project = lock.withLock({ project }) else { return [] }
    return chats(of: project)
  }

  /// The chats the tools may read: never the one asking, and only this
  /// project unless the scope opens every working directory.
  func reachableChats() -> [MemoryChat] {
    let (project, currentChatID, scope) = lock.withLock {
      (self.project, self.currentChatID, settings.scope)
    }
    guard scope != .none, let project else { return [] }
    var reachable = chats(of: project)
    if scope == .all, let index = try? home.loadProjectIndex() {
      for other in index.orderedProjects where other.id != project.id {
        reachable += chats(of: other)
      }
    }
    return reachable.filter { $0.id != currentChatID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private func chats(of project: AgentProject) -> [MemoryChat] {
    let chats = (try? home.chatStore(for: project).loadChats()) ?? []
    return chats.filter(\.hasConversation)
      .map { MemoryChat($0, scope: project.displayName) }
      .sorted { $0.updatedAt > $1.updatedAt }
  }
}
