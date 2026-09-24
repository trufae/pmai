import Foundation
import MaiACP
import MaiCore
import MaiDocuments
import MaiMCP
import MaiMarkdown
import MaiOpenAI
import MaiPluginHost
import MaiStandardTools
import MaiVisionOCR

#if PMAI_HAS_VISUAL
  import MaiVisual
#endif

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

@_silgen_name("system")
private func posixSystem(_ command: UnsafePointer<CChar>) -> CInt

/// Swift discovers argv from the initial process stack on ELF targets. The
/// Play Store build of Termux preserves argv[0], inserts the executable at
/// argv[1], and starts Android's linker. Bionic skips the preserved argv[0]
/// before calling C main, but Swift still finds it on the initial stack.
private func platformCommandLineArguments(environment: [String: String]) -> [String] {
  var arguments = CommandLine.arguments
  #if canImport(Android)
    guard arguments.count >= 2 else { return arguments }

    if environment["TERMUX_EXEC__PROC_SELF_EXE"] != nil {
      arguments.removeFirst()
    } else {
      // Also support invoking the Android linker explicitly, outside the
      // termux-exec wrapper.
      let first = URL(fileURLWithPath: arguments[0]).lastPathComponent
      if first == "linker" || first == "linker64" {
        arguments.removeFirst()
      }
    }
  #endif
  return arguments
}

private struct CLIOptions {
  var configPath: String?
  /// Root holding the project index and shared state; nil follows PMAI_HOME or ~/.pmai.
  var homePath: String?
  /// Directory holding this project's chat files; nil uses .pmai/chats in the project.
  var statePath: String?
  var historyPath: String?
  var agentOverride: String?
  var providerOverride: ProviderID?
  var modelOverride: String?
  var baseURLOverride: URL?
  var apiKeyOverride: String?
  var systemOverride: String?
  var maxToolCalls: Int?
  var maxModelTurns: Int?
  var maxSubagents: Int?
  var stream = true
  /// Permit all tool calls without prompting for this process.
  var yolo = false
  /// Reopen the most recently updated chat instead of starting a fresh one.
  var resume = false
  /// A chat list index, UUID prefix, or title to reopen.
  var resumeSelector: String?
  /// Render replies as markdown; nil follows the configuration and the tty.
  var markdown: Bool?
  var imagePaths: [String] = []
  /// Attach what arrives on standard input as a text file, for one-liners
  /// such as `git diff | pmai --stdin "review this"`.
  var readStdin = false
  var pluginPaths: [String] = []
  var initialPrompt: String?
  var printConfig = false
  var update = false
  /// List every known project and exit.
  var listProjects = false
  /// List this project's saved chats and exit.
  var listChats = false
  /// Serve one protocol on stdio instead of the REPL.
  var serve: ServeMode?

  init(arguments: [String], environment: [String: String]) throws {
    configPath = environment["PMAI_CONFIG"]
    statePath = environment["PMAI_STATE"]
    historyPath = environment["PMAI_HISTORY"]
    var positional: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--config":
        configPath = try Self.value(after: argument, in: arguments, index: &index)
      case "--state":
        statePath = try Self.value(after: argument, in: arguments, index: &index)
      case "--history":
        historyPath = try Self.value(after: argument, in: arguments, index: &index)
      case "--home":
        homePath = try Self.value(after: argument, in: arguments, index: &index)
      case "--projects":
        listProjects = true
      case "-l", "--list":
        listChats = true
      case "--agent":
        agentOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--provider":
        providerOverride = ProviderID(try Self.value(after: argument, in: arguments, index: &index))
      case "--model":
        modelOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--base-url":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        guard let url = URL(string: value) else { throw CLIError.invalidURL(value) }
        baseURLOverride = url
      case "--api-key":
        apiKeyOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--system":
        systemOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--max-tool-calls":
        maxToolCalls = try Self.count(after: argument, in: arguments, index: &index)
      case "--max-turns", "--max-model-turns":
        maxModelTurns = try Self.count(after: argument, in: arguments, index: &index)
      case "--max-subagents":
        maxSubagents = try Self.count(after: argument, in: arguments, index: &index)
      case "--image":
        imagePaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--stdin":
        readStdin = true
      case "--plugin":
        pluginPaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--no-stream":
        stream = false
      case "-y", "--yolo":
        yolo = true
      case "-r", "--resume", "--continue":
        resume = true
        if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
          index += 1
          resumeSelector = arguments[index]
        }
      case "--markdown":
        markdown = true
      case "--no-markdown":
        markdown = false
      case "--print-config":
        printConfig = true
      case "-U", "--update":
        update = true
      case "--acp":
        serve = .acp
      case "--mcp":
        serve = .mcp
      default:
        guard !argument.hasPrefix("-") else { throw CLIError.unknownOption(argument) }
        positional.append(argument)
      }
      index += 1
    }
    if !positional.isEmpty { initialPrompt = positional.joined(separator: " ") }
    if readStdin, serve != nil { throw CLIError.stdinServesProtocol }
  }

  private static func value(
    after option: String,
    in arguments: [String],
    index: inout Int
  ) throws -> String {
    index += 1
    guard index < arguments.count else { throw CLIError.missingValue(option) }
    return arguments[index]
  }

  private static func count(
    after option: String,
    in arguments: [String],
    index: inout Int
  ) throws -> Int {
    let raw = try value(after: option, in: arguments, index: &index)
    guard let count = Int(raw), count >= 0 else { throw CLIError.invalidCount(option, raw) }
    return count
  }

  /// Applies command-line run limits on top of a configured agent.
  func applyLimitOverrides(to limits: inout AgentRunLimits) {
    if let maxToolCalls { limits.maxToolCalls = max(0, maxToolCalls) }
    if let maxModelTurns { limits.maxModelTurns = max(1, maxModelTurns) }
    if let maxSubagents { limits.maxSubagents = max(0, maxSubagents) }
  }
}

/// A protocol pmai speaks over stdio instead of running its REPL.
enum ServeMode: String, Sendable {
  case acp
  case mcp
}

private enum CLIError: LocalizedError {
  case invalidURL(String)
  case missingValue(String)
  case unknownOption(String)
  case unknownChat(String)
  case invalidCount(String, String)
  case configNotFound(String)
  case noProvider
  case noProject
  case invalidImage(String)
  case isDirectory(String)
  case missingFolder(String)
  case stdinServesProtocol
  case stdinWithoutTerminal
  case apiKeySourcesConflict

  var errorDescription: String? {
    switch self {
    case .noProject: "No project is open."
    case .stdinServesProtocol:
      "--stdin cannot be combined with --acp or --mcp: they own standard input."
    case .apiKeySourcesConflict: "Set PMAI_API_KEY or PMAI_API_KEY_FILE, not both."
    case .stdinWithoutTerminal:
      "--stdin was read, but there is no terminal for the REPL; give the message on the command line."
    case .invalidURL(let value): "Invalid URL: \(value)"
    case .missingValue(let option): "Missing value after \(option)."
    case .unknownOption(let option): "Unknown option: \(option)"
    case .unknownChat(let selector): "No chat matches '\(selector)'. Run pmai -l to list chats."
    case .invalidCount(let option, let value):
      "\(option) expects a non-negative integer, got '\(value)'."
    case .configNotFound(let path): "Configuration file not found: \(path)"
    case .noProvider: "No provider is configured."
    case .invalidImage(let path): "Unable to load image: \(path)"
    case .isDirectory(let path): "\(path) is a folder; give a file name."
    case .missingFolder(let path): "The folder \(path) does not exist; create it first."
    }
  }
}

private enum MCPCommandError: LocalizedError {
  case missingID
  case invalidID(String)
  case duplicateID(String)
  case missingCommand
  case missingOptionValue(String)
  case invalidOption(String)
  case invalidEnvironment
  case invalidTimeout
  case invalidApproval
  case unterminatedQuote
  case danglingEscape

  var errorDescription: String? {
    switch self {
    case .missingID: "Could not infer an MCP name from the command. Use --name ID."
    case .invalidID(let id):
      "Invalid MCP name '\(id)'. Start with a letter or number; "
        + "then use letters, numbers, '.', '_', or '-'."
    case .duplicateID(let id): "An MCP server named '\(id)' is already configured."
    case .missingCommand: "The stdio MCP command is missing."
    case .missingOptionValue(let option): "Missing value after \(option)."
    case .invalidOption(let option): "Unknown MCP option '\(option)'."
    case .invalidEnvironment: "--env expects KEY=VALUE."
    case .invalidTimeout: "--timeout expects a positive number of seconds."
    case .invalidApproval: "--approval expects automatic, confirm, or dangerous."
    case .unterminatedQuote: "The command contains an unterminated quote."
    case .danglingEscape: "The command ends with an incomplete escape."
    }
  }
}

private struct RuntimeSetup {
  var catalogs: [MCPServerCatalog]
  var implicitProviders: [ConfiguredProvider] = []
  var providerBaseURLs: [String: URL] = [:]
}

private func environmentValue(
  _ names: [String],
  in environment: [String: String]
) -> String? {
  names.lazy.compactMap { environment[$0] }.first { !$0.isEmpty }
}

/// Unlike the other ad-hoc settings, an explicitly exported empty API key is
/// meaningful: it suppresses lower-priority aliases and configured secrets.
/// `PMAI_API_KEY_FILE` names a file holding the key instead, so the secret
/// itself never sits in the environment; it excludes `PMAI_API_KEY`.
private func environmentAPIKey(in environment: [String: String]) throws -> String? {
  let keyFile =
    environment["PMAI_API_KEY_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if !keyFile.isEmpty {
    guard environment["PMAI_API_KEY"] == nil else { throw CLIError.apiKeySourcesConflict }
    return try ConfiguredProvider.apiKey(fromFile: keyFile)
  }
  for name in ["PMAI_API_KEY", "MAI_API_KEY", "OPENAI_API_KEY"] {
    if let value = environment[name] { return value }
  }
  return nil
}

private func environmentName(
  _ names: [String],
  in environment: [String: String]
) -> String? {
  names.first { environment[$0].map { !$0.isEmpty } ?? false }
}

/// What `/visual` needs beyond the REPL session itself.
private final class ProviderBaseURLStore: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [String: URL]

  init(_ urls: [String: URL]) {
    self.urls = urls
  }

  func url(for providerID: String) -> URL? {
    lock.withLock { urls[providerID] }
  }

  func set(_ url: URL, for providerID: String) {
    lock.withLock { urls[providerID] = url }
  }

  func snapshot() -> [String: URL] {
    lock.withLock { urls }
  }
}

private struct VisualBridge: Sendable {
  var approvalHandler: TerminalApprovalHandler
  var configurationPath: String?
  var implicitProviders: [ConfiguredProvider]
  var providerBaseURLs: ProviderBaseURLStore
  var memory: MemoryState
  var todo: TodoState
  var skills: SkillState
  /// Tokens/s and time in use per provider:model, shared with the runtime.
  var usageStats: ModelUsageStore
}

/// Where the current project's todo list lives. The `todo_*` tools are
/// registered before the project is opened, so they resolve the file through
/// this box on every call; the file itself is the only copy, read fresh each
/// time so edits made in an editor are seen at once.
private final class TodoState: @unchecked Sendable {
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

/// Where skills are read from: the project's `.pmai/skills`, then the
/// `skills` folder under the home. The `skills_*` tools are registered before
/// the project is opened, so until then the start directory stands in for
/// it; every listing and call reads the SKILL.md files afresh.
private final class SkillState: @unchecked Sendable {
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
private final class MemoryState: @unchecked Sendable {
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

struct SessionProfile: Sendable {
  var agentID: String
  var displayName: String
  /// Carried through so writing the chat's agent back to the configuration
  /// never erases the setup's purpose or its enabled state.
  var description: String
  var isEnabled: Bool
  var provider: ProviderID
  var model: String
  var instructions: String
  var systemPrompt: String?
  var toolNames: Set<String>
  var toolGroupNames: Set<String>
  var subagentNames: Set<String>
  var stream: Bool
  var limits: AgentRunLimits
  var toolChoice: ToolChoice
  var responseFormat: ResponseFormat
  var options: GenerationOptions
  var toolCallingStrategy: ToolCallingStrategy
  var useToolProxy: Bool
  var proxyExposedTools: Set<String>?
  var toolDelegation: AgentToolDelegation
  var retry: AgentRetryPolicy
  var autocompact: AgentAutocompact
  var context: AgentContextMode

  init(definition: AgentDefinition) {
    agentID = definition.id
    displayName = definition.displayName
    description = definition.description
    isEnabled = definition.isEnabled
    provider = definition.provider
    model = definition.model
    instructions = definition.instructions
    systemPrompt = definition.systemPrompt
    toolNames = definition.toolNames
    toolGroupNames = definition.toolGroupNames
    subagentNames = definition.subagentNames
    stream = definition.stream
    limits = definition.limits
    toolChoice = definition.toolChoice
    responseFormat = definition.responseFormat
    options = definition.options
    toolCallingStrategy = definition.toolCallingStrategy
    useToolProxy = definition.useToolProxy
    proxyExposedTools = definition.proxyExposedTools
    toolDelegation = definition.toolDelegation
    retry = definition.retry
    autocompact = definition.autocompact
    context = definition.context
  }

  init(provider: ProviderID, model: String, instructions: String, stream: Bool) {
    agentID = "main"
    displayName = "main"
    description = ""
    isEnabled = true
    self.provider = provider
    self.model = model
    self.instructions = instructions
    systemPrompt = nil
    toolNames = Set(
      [
        MaiCurrentTimeTool.name,
        MaiCalculatorTool.name,
        MaiWeatherTool.name,
        MaiWebSearchTool.name,
        MaiWebFetchTool.name,
        MaiMastodonTool.name,
      ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames
        + MaiTodoTools.toolNames + MaiContextTools.toolNames)
    toolGroupNames = [
      "datetime", "calc", "files", "run", "weather", "web", "mastodon", "github", "todo",
      "context", MaiSkillTools.groupID,
    ]
    subagentNames = []
    self.stream = stream
    limits = .init()
    toolChoice = .automatic
    responseFormat = .text
    options = .init()
    toolCallingStrategy = .automatic
    useToolProxy = false
    proxyExposedTools = nil
    toolDelegation = .inline
    retry = .init()
    autocompact = .init()
    context = .cache
  }

  var agentDefinition: AgentDefinition {
    AgentDefinition(
      id: agentID,
      displayName: displayName,
      description: description,
      isEnabled: isEnabled,
      instructions: instructions,
      systemPrompt: systemPrompt,
      provider: provider,
      model: model,
      toolNames: toolNames,
      toolGroupNames: toolGroupNames,
      subagentNames: subagentNames,
      stream: stream,
      limits: limits,
      toolChoice: toolChoice,
      responseFormat: responseFormat,
      options: options,
      toolCallingStrategy: toolCallingStrategy,
      useToolProxy: useToolProxy,
      proxyExposedTools: proxyExposedTools,
      toolDelegation: toolDelegation,
      retry: retry,
      autocompact: autocompact,
      context: context)
  }
}

struct REPLSession: Sendable {
  var id: UUID
  /// The session the chat presents to providers; see `ChatSession`.
  var sessionID: String
  var title: String
  var profile: SessionProfile
  var history: AgentTranscript
  var pendingContent: [ContentPart]
  var createdAt: Date
  var updatedAt: Date
  var isArchived: Bool
  /// The agents this chat's runs started, with their transcripts, as saved
  /// with the chat. The REPL brings them up to date from the supervisor as
  /// runs end and puts them back in the process table when the chat is
  /// reopened, so `/agents tree` and `/agents log` outlive the session.
  var subagents: [AgentProcessRecord]
  #if PMAI_HAS_VISUAL
    /// Conversations and panes left behind by the last `/visual` session.
    var visualSnapshot: VisualWorkspaceSnapshot?
  #endif

  init(
    id: UUID = UUID(),
    title: String? = nil,
    profile: SessionProfile,
    pendingContent: [ContentPart] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    sessionID: String? = nil
  ) {
    self.id = id
    self.sessionID = sessionID ?? ChatSession.newID()
    self.title = title ?? profile.agentID
    self.profile = profile
    history = AgentTranscript(messages: Self.initialHistory(for: profile))
    self.pendingContent = pendingContent
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    isArchived = false
    subagents = []
  }

  init(chat: AgentChat) {
    id = chat.id
    sessionID = chat.sessionID
    title = chat.title
    profile = SessionProfile(definition: chat.primaryAgent)
    history = AgentTranscript(messages: chat.messages)
    pendingContent = chat.pendingContent
    createdAt = chat.createdAt
    updatedAt = chat.updatedAt
    isArchived = chat.isArchived
    subagents = chat.subagents
  }

  var chat: AgentChat {
    AgentChat(
      id: id,
      title: title,
      primaryAgent: profile.agentDefinition,
      messages: history.messages,
      pendingContent: pendingContent,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isArchived: isArchived,
      sessionID: sessionID,
      subagents: subagents)
  }

  /// Names a placeholder chat after its first message; chosen titles stay.
  mutating func refreshTitle(from text: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty || trimmed == AgentChat.placeholderTitle,
      let derived = AgentChat.derivedTitle(from: text)
    else { return }
    title = derived
  }

  /// A cleared conversation keeps nothing of its runs: the agents they
  /// started go with the messages.
  mutating func reset(profile: SessionProfile? = nil) {
    if let profile { self.profile = profile }
    history.replaceAll(with: Self.initialHistory(for: self.profile))
    pendingContent.removeAll()
    subagents.removeAll()
    touch()
  }

  mutating func touch() {
    updatedAt = Date()
  }

  #if PMAI_HAS_VISUAL
    func visualSeed() -> VisualConversationSeed {
      VisualConversationSeed(
        id: id,
        title: title,
        profile: profile.agentDefinition,
        messages: history.messages,
        pendingContent: pendingContent,
        sessionID: sessionID)
    }

    mutating func adopt(_ conversation: VisualConversationSeed) {
      id = conversation.id
      sessionID = conversation.sessionID
      title = conversation.title
      profile = SessionProfile(definition: conversation.profile)
      history.replaceAll(with: conversation.messages)
      pendingContent = conversation.pendingContent
      touch()
    }
  #endif

  private static func initialHistory(for profile: SessionProfile) -> [AgentMessage] {
    let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
  }
}

private final class TerminalInterruptHandler: @unchecked Sendable {
  #if !os(Windows)
    private let source: DispatchSourceSignal
  #endif
  private let lock = NSLock()
  private var nextID: UInt = 0
  private var active: (REPLInterruptID, @Sendable () -> Void, reports: Bool)?
  private var interrupted: Set<REPLInterruptID> = []
  private let notify: @Sendable (REPLInterruptID?, Bool) -> Void

  init(notify: @escaping @Sendable (REPLInterruptID?, Bool) -> Void) {
    self.notify = notify
    #if os(Windows)
      WindowsConsole.watchInterrupts { [weak self] in self?.requestInterrupt() }
    #else
      signal(SIGINT, SIG_IGN)
      source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      source.setEventHandler { [weak self] in self?.requestInterrupt() }
      source.resume()
    #endif
  }

  deinit {
    #if os(Windows)
      WindowsConsole.watchInterrupts(nil)
    #else
      source.cancel()
      signal(SIGINT, SIG_DFL)
    #endif
  }

  @discardableResult
  func activate(
    reports: Bool = true,
    cancellation: @escaping @Sendable () -> Void
  ) -> REPLInterruptID {
    lock.withLock {
      nextID &+= 1
      let registration = REPLInterruptID(rawValue: nextID)
      active = (registration, cancellation, reports)
      return registration
    }
  }

  /// Removes only the operation that registered this token. This prevents a
  /// late completion from disabling Ctrl+C for the job that replaced it.
  @discardableResult
  func deactivate(_ registration: REPLInterruptID) -> Bool {
    lock.withLock {
      if active?.0 == registration { active = nil }
      return interrupted.remove(registration) != nil
    }
  }

  func suspend(_ registration: REPLInterruptID) {
    lock.withLock {
      if active?.0 == registration { active = nil }
    }
  }

  func restore(
    _ registration: REPLInterruptID,
    cancellation: @escaping @Sendable () -> Void
  ) {
    lock.withLock { active = (registration, cancellation, true) }
  }

  func requestInterrupt(endedInput: Bool = false) {
    let (action, registration, reports) = lock.withLock {
      let operation = active
      if let registration = operation?.0 { interrupted.insert(registration) }
      return (operation?.1, operation?.0, operation?.reports ?? true)
    }
    action?()
    if reports { notify(registration, endedInput) }
  }
}

private actor TerminalApprovalHandler: ApprovalHandler {
  typealias Prompter = @Sendable (ApprovalRequest) async throws -> ApprovalDecision

  private struct ProjectSettings: Codable {
    var yolo: Bool?
  }

  private let configuration: ConfiguredApprovals
  private let projectSettingsURL: URL
  private var projectSettings: ProjectSettings
  private var delegate: (any ApprovalHandler)?
  private var yoloEnabled: Bool
  /// Asks through the REPL's own prompt while the persistent screen owns the
  /// terminal, so a question from a child agent never fights the line editor
  /// for stdin.
  private var prompter: Prompter?

  init(
    configuration: ConfiguredApprovals, projectSettingsURL: URL, yoloEnabled: Bool = false
  ) throws {
    self.configuration = configuration
    self.projectSettingsURL = projectSettingsURL
    let projectSettings =
      FileManager.default.fileExists(atPath: projectSettingsURL.path)
      ? try MaiJSONCoding.default.makeDecoder().decode(
        ProjectSettings.self, from: Data(contentsOf: projectSettingsURL))
      : ProjectSettings()
    self.projectSettings = projectSettings
    self.yoloEnabled = yoloEnabled || (projectSettings.yolo ?? configuration.yolo)
  }

  /// Routes `ask` decisions elsewhere while another surface owns the terminal.
  func setDelegate(_ handler: (any ApprovalHandler)?) {
    delegate = handler
  }

  func setYOLOEnabled(_ enabled: Bool) {
    yoloEnabled = enabled
  }

  func saveYOLOEnabled(_ enabled: Bool) throws {
    yoloEnabled = enabled
    projectSettings.yolo = enabled
    try MaiJSONCoding.default.makeEncoder().encode(projectSettings)
      .write(to: projectSettingsURL, options: .atomic)
  }

  func isYOLOEnabled() -> Bool {
    yoloEnabled
  }

  func setPrompter(_ prompter: Prompter?) {
    self.prompter = prompter
  }

  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    if yoloEnabled {
      return .approve(arguments: request.call.arguments)
    }
    let mode =
      request.tool.annotations.approval == .dangerous
      ? configuration.dangerous : configuration.confirm
    switch mode {
    case .allow:
      return .approve(arguments: request.call.arguments)
    case .deny:
      return .deny(reason: "Denied by configuration.")
    case .ask:
      if let delegate { return try await delegate.decide(request) }
      if let prompter { return try await prompter(request) }
      guard isatty(STDIN_FILENO) != 0 else {
        return .deny(reason: "Interactive approval requires a terminal.")
      }
      FileHandle.standardError.write(
        Data(
          "Approve \(request.tool.annotations.approval.rawValue) tool '\(request.tool.name)'?\nArguments: \(request.call.arguments.compactJSONString)\n"
            .utf8))
      let editor = TerminalLineEditor()
      editor.configure(
        ui: ConfiguredTerminalUI(backgroundLine: "", promptForeground: "yellow"))
      guard
        let answer = editor.readLine(
          prompt: "[y]es/[a]lways/[n]o/[e]dit/[c]ancel run: ", completions: [])?
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      else { return .deny(reason: "No approval response.") }
      if editor.wasInterrupted { throw CancellationError() }
      switch answer {
      case "y", "yes":
        return .approve(arguments: request.call.arguments)
      case "a", "always":
        yoloEnabled = true
        return .approve(arguments: request.call.arguments)
      case "e", "edit":
        FileHandle.standardError.write(Data("Replacement JSON arguments: ".utf8))
        guard let raw = readLine(), let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          value.objectValue != nil
        else { return .deny(reason: "Edited arguments were not a JSON object.") }
        return .approve(arguments: value)
      case "c", "cancel":
        return .cancelRun
      default:
        return .deny(reason: "Denied by user.")
      }
    }
  }
}

@main
struct MaiCLI {
  private static let version = "1.8.0"

  static func main() async {
    let environment = ProcessInfo.processInfo.environment
    let commandLineArguments = platformCommandLineArguments(environment: environment)
    if commandLineArguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
      printUsage()
      return
    }
    if commandLineArguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
      print(version)
      return
    }

    do {
      let options = try CLIOptions(
        arguments: Array(commandLineArguments.dropFirst()),
        environment: environment)
      if options.update {
        try updateCLI(executable: commandLineArguments[0], environment: environment)
        return
      }
      if options.printConfig {
        FileHandle.standardOutput.write(try sampleConfiguration().encoded())
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
      }
      if options.listProjects {
        let home = resolvedHome(options: options, environment: environment)
        print(projectListing(try home.loadProjectIndex(), currentID: nil, now: Date()))
        return
      }
      if options.listChats {
        let home = resolvedHome(options: options, environment: environment)
        let project = try home.openProject(
          atWorkingDirectory: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        let store = resolvedChatStore(
          options: options, home: home, project: project, environment: environment)
        let workspace = try store.loadWorkspace { error in
          FileHandle.standardError.write(
            Data("warning: skipped a chat file. \(error.localizedDescription)\n".utf8))
        }
        print(chatListing(workspace, scope: .all, selectedID: nil))
        return
      }

      let loaded = try loadConfiguration(options: options, environment: environment)
      let configurationPath = loaded?.path ?? defaultConfigurationPath(environment: environment)
      var configuration = loaded?.configuration
      if var existing = configuration {
        var changed = existing.associateSystemPrompts()
        if !existing.toolSources.contains(where: {
          $0.kind == MaiStandardToolsPlugin.factoryKind
        }) {
          existing.toolSources.append(
            ConfiguredToolSource(
              id: "standard-tools",
              kind: MaiStandardToolsPlugin.factoryKind))
          changed = true
        }
        if changed { try existing.save(to: URL(fileURLWithPath: configurationPath)) }
        configuration = existing
      }
      let home = resolvedHome(options: options, environment: environment)
      let project = try home.openProject(
        atWorkingDirectory: URL(
          fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
      let approvalHandler = try TerminalApprovalHandler(
        configuration: configuration?.approvals ?? .init(),
        projectSettingsURL: home.storageDirectory(for: project).appendingPathComponent(
          "settings.json"),
        yoloEnabled: options.yolo)
      let runtime = AgentRuntime(approvalHandler: approvalHandler)
      let plugins = PluginRegistry()
      try await plugins.install(MaiCoreBuiltinsPlugin(), origin: "built-in")
      try await plugins.install(MaiMCPPlugin(), origin: "built-in")
      try await plugins.install(MaiOpenAIPlugin(), origin: "built-in")
      try await plugins.install(MaiACPPlugin(), origin: "built-in")
      do {
        try await plugins.install(MaiVisionOCRPlugin(), origin: "built-in")
      } catch {
        // OCR is optional: a platform without a usable backend must not stop
        // the CLI from starting.
        FileHandle.standardError.write(
          Data("warning: OCR plugin unavailable: \(error.localizedDescription)\n".utf8))
      }
      try await plugins.install(MaiStandardToolsPlugin(), origin: "built-in")
      let nativePluginHost = NativePluginHost()
      try await loadNativePlugins(
        options: options,
        loadedConfigurationPath: loaded?.path,
        configuration: configuration,
        environment: environment,
        host: nativePluginHost,
        registry: plugins)
      let memoryState = MemoryState(
        home: resolvedHome(options: options, environment: environment))
      let todoState = TodoState(
        home: resolvedHome(options: options, environment: environment))
      let skillState = SkillState(
        home: resolvedHome(options: options, environment: environment))
      try await registerTools(
        in: runtime,
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      try await registerMemoryTools(in: runtime, state: memoryState)
      try await registerTodoTools(in: runtime, state: todoState)
      for tool in MaiContextTools.makeTools(supervisor: runtime.supervisor) {
        try await runtime.register(tool: tool)
      }
      try await registerSkillTools(in: runtime, state: skillState)
      try await synchronizeToolGroupSelections(
        configuration: &configuration,
        configurationPath: configurationPath,
        plugins: plugins,
        runtime: runtime,
        environment: environment)
      let ocrProvider = await configuredOCRProvider(
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      let setup = try await configureRuntime(
        runtime,
        plugins: plugins,
        configuration: configuration,
        options: options,
        environment: environment)
      var profile = try selectedProfile(
        configuration: configuration,
        options: options,
        environment: environment)
      if configuration == nil {
        var created = MaiConfiguration(
          defaultAgent: profile.agentID,
          providers: setup.implicitProviders,
          toolSources: [
            ConfiguredToolSource(
              id: "standard-tools",
              kind: MaiStandardToolsPlugin.factoryKind)
          ],
          agents: [profile.agentDefinition])
        created.associateSystemPrompts()
        try created.save(to: URL(fileURLWithPath: configurationPath))
        configuration = created
        profile = try selectedProfile(
          configuration: created,
          options: options,
          environment: environment)
      }
      let usageStats = ModelUsageStore(url: home.usageStatsURL)
      await runtime.configureUsageStats(usageStats)
      memoryState.adopt(project: project, settings: configuration?.memory ?? .init())
      todoState.focus(project: project)
      skillState.focus(project: project)
      await runtime.configureMemory(memoryState.promptSection)
      await runtime.configureProjectInstructions(projectInstructionsSection(configuration))
      await runtime.configurePlanning(configuration?.use.plan ?? true)
      let store = resolvedChatStore(
        options: options, home: home, project: project, environment: environment)
      importLegacyChats(into: store, project: project, options: options, environment: environment)
      let providerOverride =
        options.providerOverride
        ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: environment).map {
          ProviderID($0)
        }
      let modelOverride =
        options.modelOverride
        ?? environmentValue(["PMAI_MODEL", "MAI_MODEL", "OPENAI_MODEL"], in: environment)
      var workspace = try loadChatWorkspace(
        from: store,
        initialProfile: profile,
        configuredAgents: configuration?.agents ?? [],
        providerOverride: providerOverride,
        modelOverride: modelOverride,
        options: options)
      var session = REPLSession(chat: workspace.selectedChat!)
      session.pendingContent.append(contentsOf: try options.imagePaths.map(imageContent))
      if options.readStdin {
        session.pendingContent.append(
          try stdinAttachment(reopeningTerminal: options.initialPrompt == nil))
      }
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      let terminal = TerminalWriter()
      await terminal.configureMarkdown(
        markdownRenderer(
          enabled: options.markdown ?? configuration?.ui.markdown ?? true,
          forced: options.markdown == true,
          environment: environment))
      await terminal.configureThinking(configuration?.ui.thinking ?? .status)
      await terminal.configureToolResultLines(
        configuration?.ui.toolResultLines ?? ConfiguredTerminalUI().toolResultLines)
      await terminal.configureToolResultColor(
        configuration?.ui.toolResultForeground ?? ConfiguredTerminalUI().toolResultForeground)
      await terminal.configureSubagentOutput(
        configuration?.ui.subagentOutput ?? ConfiguredTerminalUI().subagentOutput)
      await terminal.configurePromptColor(
        configuration?.ui.promptForeground ?? ConfiguredTerminalUI().promptForeground)
      configureEditor(configuration?.ui.editor ?? "")

      if let mode = options.serve {
        await runServer(
          mode,
          runtime: runtime,
          approvalHandler: approvalHandler,
          agent: profile.agentDefinition)
        return
      }
      if loaded == nil {
        await terminal.line("Created \(configurationPath)", to: .standardError)
      }
      if let prompt = options.initialPrompt {
        var oneShotProcess: AgentPID?
        let succeeded = await submit(
          prompt,
          session: &session,
          runtime: runtime,
          process: &oneShotProcess,
          terminal: terminal)
        if let process = oneShotProcess {
          session.subagents = AgentProcessRecord.merging(
            saved: session.subagents,
            current: await runtime.supervisor.records(under: process))
        }
        workspace.upsert(session.chat, selecting: true)
        try store.commit(&workspace)
        if !succeeded { exit(1) }
        return
      }
      await runREPL(
        workspace: &workspace,
        store: store,
        home: home,
        project: project,
        historyURL: resolvedHistoryURL(options: options, home: home, environment: environment),
        runtime: runtime,
        plugins: plugins,
        ocrProvider: ocrProvider,
        configuration: configuration,
        catalogs: setup.catalogs,
        visual: VisualBridge(
          approvalHandler: approvalHandler,
          configurationPath: configurationPath,
          implicitProviders: setup.implicitProviders,
          providerBaseURLs: ProviderBaseURLStore(setup.providerBaseURLs),
          memory: memoryState,
          todo: todoState,
          skills: skillState,
          usageStats: usageStats),
        terminal: terminal)
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(2)
    }
  }

  private static func loadNativePlugins(
    options: CLIOptions,
    loadedConfigurationPath: String?,
    configuration: MaiConfiguration?,
    environment: [String: String],
    host: NativePluginHost,
    registry: PluginRegistry
  ) async throws {
    let currentDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true)
    let configDirectory =
      loadedConfigurationPath.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent()
      } ?? currentDirectory
    let configured =
      configuration?.plugins.filter(\.enabled).map {
        (entry: $0, baseURL: configDirectory)
      } ?? []
    let commandLine = options.pluginPaths.map {
      (entry: ConfiguredPlugin(path: $0), baseURL: currentDirectory)
    }

    for item in configured + commandLine {
      let expanded = AgentHome.expandUserPath(item.entry.path, environment: environment)
      let url = URL(fileURLWithPath: expanded, relativeTo: item.baseURL).standardizedFileURL
      do {
        _ = try await host.loadPlugin(at: url, into: registry)
      } catch {
        if item.entry.required { throw error }
        FileHandle.standardError.write(
          Data(
            "warning: optional plugin '\(url.path)' was not loaded: \(error.localizedDescription)\n"
              .utf8))
      }
    }
  }

  private static func registerTools(
    in runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    environment: [String: String]
  ) async throws {
    let sources = configuration?.toolSources ?? []
    let configuredStandardTools = sources.filter {
      $0.kind == MaiStandardToolsPlugin.factoryKind
    }
    if configuredStandardTools.isEmpty {
      let tools = try await plugins.makeTools(
        kind: MaiStandardToolsPlugin.factoryKind,
        context: PluginFactoryContext(id: "standard-tools", environment: environment))
      for tool in tools { try await runtime.register(tool: tool) }
    } else {
      for source in configuredStandardTools where source.enabled {
        let tools = try await plugins.makeTools(
          kind: source.kind,
          context: source.context(environment: environment))
        for tool in tools { try await runtime.register(tool: tool) }
      }
    }

    for source in sources
    where source.enabled && source.kind != MaiStandardToolsPlugin.factoryKind {
      let tools = try await plugins.makeTools(
        kind: source.kind,
        context: source.context(environment: environment))
      for tool in tools { try await runtime.register(tool: tool) }
    }
  }

  /// Tool and group names that changed; agent records saved under the old
  /// name are moved to the new one the next time the configuration is read.
  private static let renamedToolNames = ["calculator": MaiCalculatorTool.name]

  /// Tool names remain in the agent record for provider/runtime portability;
  /// group names let a host expand newly added plugin tools without requiring
  /// users to toggle an already enabled group off and on again.
  private static func synchronizeToolGroupSelections(
    configuration: inout MaiConfiguration?,
    configurationPath: String,
    plugins: PluginRegistry,
    runtime: AgentRuntime,
    environment: [String: String]
  ) async throws {
    guard var draft = configuration else { return }
    var toolsByGroup: [String: Set<String>] = [
      AgentRuntime.agentToolGroup.id: AgentRuntime.agentToolGroup.toolNames
    ]
    for source in draft.toolSources where source.enabled {
      for group in try await plugins.toolGroups(
        kind: source.kind,
        context: source.context(environment: environment))
      {
        toolsByGroup[group.id, default: []].formUnion(group.toolNames)
      }
    }
    // Tools pmai registers itself — todo, chats — belong to no plugin, so
    // their groups are inferred the way /tools lists them; otherwise a group
    // named in the configuration would show as enabled yet offer nothing.
    let grouped = Set(toolsByGroup.values.flatMap { $0 })
    let hostTools = await runtime.availableTools().filter { !grouped.contains($0.name) }
    for group in ToolGroupDefinition.inferred(from: hostTools) {
      toolsByGroup[group.id, default: []].formUnion(group.toolNames)
    }
    var changed = false
    for index in draft.agents.indices {
      let previous = draft.agents[index].toolNames
      let previousGroups = draft.agents[index].toolGroupNames
      for (old, new) in renamedToolNames {
        if draft.agents[index].toolNames.remove(old) != nil {
          draft.agents[index].toolNames.insert(new)
        }
        if draft.agents[index].toolGroupNames.remove(old) != nil {
          draft.agents[index].toolGroupNames.insert(new)
        }
      }
      for groupName in draft.agents[index].toolGroupNames {
        draft.agents[index].toolNames.formUnion(toolsByGroup[groupName] ?? [])
      }
      changed =
        changed || previous != draft.agents[index].toolNames
        || previousGroups != draft.agents[index].toolGroupNames
    }
    guard changed else { return }
    try draft.save(to: URL(fileURLWithPath: configurationPath))
    configuration = draft
  }

  /// Picks the configured OCR backend, falling back to whatever this platform
  /// can offer (Apple Vision, then a local tesseract binary). OCR never blocks
  /// startup: when nothing is usable the returned provider explains why the
  /// first time OCR is requested.
  private static func configuredOCRProvider(
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    environment: [String: String]
  ) async -> any OCRProvider {
    var failures: [String] = []
    if let configured = configuration?.ocrProviders.first(where: \.enabled) {
      do {
        return try await plugins.makeOCRProvider(
          kind: configured.kind,
          context: configured.context(environment: environment))
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    var fallbackKinds = [MaiVisionOCRPlugin.preferredFactoryKind]
    for kind in ["vision", TesseractOCRProvider.factoryKind] where !fallbackKinds.contains(kind) {
      fallbackKinds.append(kind)
    }
    for kind in fallbackKinds {
      do {
        return try await plugins.makeOCRProvider(
          kind: kind,
          context: PluginFactoryContext(id: kind, environment: environment))
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    return UnavailableOCRProvider(
      reason: failures.isEmpty
        ? "no OCR provider is registered on this platform."
        : failures.joined(separator: " "))
  }

  /// Exposes the shared `chats_*` tools over this session's reachable chats.
  /// They are registered before configured agents are filtered against the
  /// known tool names, so an agent may list them like any other tool.
  private static func registerMemoryTools(
    in runtime: AgentRuntime,
    state: MemoryState
  ) async throws {
    for definition in MaiMemoryTools.definitions {
      let name = definition.name
      try await runtime.register(
        tool: ClosureTool(definition: definition) { arguments, _ in
          guard state.readsOtherChats else {
            return ToolOutput(
              text:
                "Error: reading other chats is disabled. Enable it with /memory scope project or /memory scope all.",
              isError: true)
          }
          return ToolOutput(
            text: MaiMemoryTools.execute(
              name: name,
              arguments: arguments.objectValue ?? [:],
              chats: state.reachableChats()))
        })
    }
  }

  /// Exposes the shared `todo_*` tools over the current project's list file.
  /// Like the memory tools they are registered before agents are filtered
  /// against the known tool names, so an agent may list them like any other.
  private static func registerTodoTools(
    in runtime: AgentRuntime,
    state: TodoState
  ) async throws {
    for tool in MaiTodoTools.makeTools(url: { state.url }) {
      try await runtime.register(tool: tool)
    }
  }

  /// Runs pmai as a stdio server instead of the REPL: ACP for editors, MCP for
  /// tool callers. Both speak JSON-RPC over stdin/stdout, so no output may go
  /// there but the protocol itself; diagnostics go to stderr.
  private static func runServer(
    _ mode: ServeMode,
    runtime: AgentRuntime,
    approvalHandler: TerminalApprovalHandler,
    agent: AgentDefinition
  ) async {
    let transport = StdioJSONRPCTransport.standardIO()
    switch mode {
    case .acp:
      // Tool approvals belong to the editor, not to a terminal nobody is at.
      let bridge = ACPPermissionBridge()
      await approvalHandler.setDelegate(bridge.approvalHandler)
      let server = ACPServer(runtime: runtime, agent: agent, bridge: bridge)
      FileHandle.standardError.write(
        Data("pmai ACP agent ready (\(agent.id)); waiting for a client on stdio.\n".utf8))
      await server.serve(on: transport)
    case .mcp:
      let server = MCPAgentServer(runtime: runtime, agent: agent)
      FileHandle.standardError.write(
        Data("pmai MCP server ready (\(agent.id)); waiting for a client on stdio.\n".utf8))
      await server.serve(on: transport)
    }
  }

  private static func configureRuntime(
    _ runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) async throws -> RuntimeSetup {
    let providerOverride =
      options.providerOverride
      ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: environment).map {
        ProviderID($0)
      }
    let rawBaseURL =
      options.baseURLOverride?.absoluteString
      ?? environmentValue(
        ["PMAI_BASE_URL", "MAI_BASE_URL", "OPENAI_BASE_URL"], in: environment)
    let baseURLOverride: URL?
    if let rawBaseURL {
      guard let url = URL(string: rawBaseURL) else { throw CLIError.invalidURL(rawBaseURL) }
      baseURLOverride = url
    } else {
      baseURLOverride = nil
    }
    let apiKeyOverride =
      try options.apiKeyOverride ?? environmentAPIKey(in: environment)

    if let configuration {
      let selectedAgentID =
        options.agentOverride ?? configuration.defaultAgent
        ?? configuration.agents.first?.id
      let selectedProviderID = selectedAgentID.flatMap { selectedAgentID in
        configuration.agents.first { $0.id == selectedAgentID }?.provider.rawValue
      }
      let targetProviderID =
        providerOverride?.rawValue ?? selectedProviderID
        ?? ProviderID.openAI.rawValue
      var providerBaseURLs: [String: URL] = [:]
      for configuredProvider in configuration.providers {
        var provider = configuredProvider
        if provider.id == targetProviderID {
          if let baseURLOverride { provider.baseURL = baseURLOverride }
          if let apiKeyOverride {
            provider.apiKey = apiKeyOverride
            provider.apiKeyEnvironment = nil
            provider.apiKeyFile = nil
          }
        }
        providerBaseURLs[provider.id] = provider.baseURL
        try await runtime.register(
          plugins.makeProvider(from: provider, environment: environment))
      }
      var catalogs: [MCPServerCatalog] = []
      for server in configuration.mcpServers where server.enabled {
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: environment)
        catalogs.append(try await runtime.register(mcp: source))
      }
      await runtime.configureDelegation(
        prompt: configuration.prompts?.delegation,
        workerInstructions: configuration.prompts?.worker)
      await runtime.configureCompaction(prompt: configuration.prompts?.compact)
      let knownTools = Set(await runtime.availableTools().map(\.name))
      for var agent in configuration.agents {
        agent.toolNames.formIntersection(knownTools)
        try await runtime.register(agent: agent)
      }
      return RuntimeSetup(catalogs: catalogs, providerBaseURLs: providerBaseURLs)
    }

    let hello = ConfiguredProvider(id: "hello", kind: .hello)
    try await runtime.register(plugins.makeProvider(from: hello, environment: environment))
    let baseURL = baseURLOverride ?? URL(string: "http://127.0.0.1:11434/v1")!
    let openAI = ConfiguredProvider(
      id: ProviderID.openAI.rawValue,
      kind: .openAICompatible,
      baseURL: baseURL,
      apiKey: apiKeyOverride)
    try await runtime.register(plugins.makeProvider(from: openAI, environment: environment))
    // The visual workspace drafts a configuration from these implicit providers.
    // It references the API key through its environment variable instead of
    // copying the secret into a file.
    var draft = openAI
    draft.apiKey = nil
    draft.apiKeyEnvironment = environmentName(
      ["PMAI_API_KEY", "MAI_API_KEY", "OPENAI_API_KEY"], in: environment)
    draft.apiKeyFile = environment["PMAI_API_KEY_FILE"].flatMap {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
    }
    return RuntimeSetup(
      catalogs: [],
      implicitProviders: [hello, draft],
      providerBaseURLs: [openAI.id: baseURL])
  }

  private static func selectedProfile(
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) throws -> SessionProfile {
    let providerOverride =
      options.providerOverride
      ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: environment).map {
        ProviderID($0)
      }
    let modelOverride =
      options.modelOverride
      ?? environmentValue(["PMAI_MODEL", "MAI_MODEL", "OPENAI_MODEL"], in: environment)
    if let configuration, !configuration.agents.isEmpty {
      let selectedID =
        options.agentOverride ?? configuration.defaultAgent
        ?? configuration.agents.first?.id
      guard let definition = configuration.agents.first(where: { $0.id == selectedID }) else {
        throw MaiConfigurationError.unknownAgent(selectedID ?? "")
      }
      var profile = SessionProfile(definition: definition)
      if let providerOverride { profile.provider = providerOverride }
      if let modelOverride { profile.model = modelOverride }
      if let system = options.systemOverride {
        profile.instructions = system
        profile.systemPrompt = nil
      }
      profile.stream = options.stream && profile.stream
      options.applyLimitOverrides(to: &profile.limits)
      return profile
    }
    var profile = SessionProfile(
      provider: providerOverride ?? .openAI,
      model: modelOverride ?? "gpt-oss:20b",
      instructions: options.systemOverride ?? "You are a helpful, concise assistant.",
      stream: options.stream)
    options.applyLimitOverrides(to: &profile.limits)
    return profile
  }

  /// A renderer for replies on this terminal, or nil to print them verbatim.
  /// Output that is not a terminal stays verbatim unless rendering is forced.
  private static func markdownRenderer(
    enabled: Bool,
    forced: Bool,
    environment: [String: String]
  ) -> MarkdownTerminalRenderer? {
    guard enabled, forced || isatty(STDOUT_FILENO) != 0 else { return nil }
    let detected = MarkdownTerminalEnvironment.detect(environment)
    return MarkdownTerminalRenderer(
      theme: detected.theme,
      options: MarkdownLayoutOptions(
        width: TerminalLineEditor.terminalColumns(), unicode: detected.unicode),
      widthProvider: { TerminalLineEditor.terminalColumns() })
  }

  /// What outlives one event of the loop: the turn in flight, who typed text
  /// goes to, and the tool calls waiting for an answer.
  private enum REPLTurnKind {
    case chat
    case btw
  }

  /// One run in flight. A chat turn also remembers which chat it belongs to
  /// and what that chat held when it was sent, so its reply finds its way
  /// back even after the person edited the chat or moved to another one.
  private struct REPLTurn {
    let task: Task<AgentResult, any Error>
    let interrupt: REPLInterruptID
    let started: ContinuousClock.Instant
    let pid: AgentPID
    let kind: REPLTurnKind
    let chatID: UUID?
    let sent: [AgentMessage]
  }

  private struct REPLLoop {
    var activeTurn: REPLTurn?
    var foregroundCommand: String?
    var focus: REPLMessageTarget = .main
    var approvals: [(request: ApprovalRequest, reply: REPLApprovalReply)] = []
    var editingApproval: (request: ApprovalRequest, reply: REPLApprovalReply)?
    var pendingQueueMessage: String?
    /// True while the input thread waits for the loop before reading again.
    var readerParked = true
    var exiting = false

    mutating func beginExit() {
      exiting = true
      activeTurn?.task.cancel()
      cancelApprovals { _ in true }
    }

    mutating func cancelApprovals(matching matches: (ApprovalRequest) -> Bool) {
      approvals.removeAll { waiting in
        guard matches(waiting.request) else { return false }
        waiting.reply.fail(CancellationError())
        return true
      }
      if let waiting = editingApproval, matches(waiting.request) {
        waiting.reply.fail(CancellationError())
        editingApproval = nil
      }
    }
  }

  /// What a command may change under a running turn, taken before it runs
  /// so the person can be told how the change and the run meet.
  private struct REPLCommandSnapshot {
    let chatID: UUID
    let title: String
    let messages: [AgentMessage]
    let agent: AgentDefinition
    let directory: String

    init(session: REPLSession) {
      chatID = session.id
      title = session.title
      messages = session.history.messages
      agent = session.profile.agentDefinition
      directory = FileManager.default.currentDirectoryPath
    }
  }

  /// The value state a slash command may change. Commands run on a child task
  /// so Ctrl+C can cancel them while the event loop remains the sole owner of
  /// the live REPL state.
  private struct REPLCommandResult: Sendable {
    var session: REPLSession
    var configuration: MaiConfiguration?
    var catalogs: [MCPServerCatalog]
    var exits: Bool
  }

  /// What a chat holds once a run that started from `sent` comes back with
  /// `result`. Usually nothing touched the chat meanwhile and the run's
  /// transcript is the chat. When the person edited it during the run —
  /// cleared it, undid a message, compacted it — their edits stay and what
  /// the run added goes after them.
  static func mergedTranscript(
    current: [AgentMessage], sent: [AgentMessage], result: [AgentMessage]
  ) -> [AgentMessage] {
    guard current != sent else { return result }
    let shared = zip(sent, result).prefix { $0.0 == $0.1 }.count
    return current + result.dropFirst(shared)
  }

  /// The REPL is one loop over one stream of events. Typed lines arrive from
  /// a thread of their own, so the prompt stays on screen while a turn runs;
  /// a turn ending, a tool asking for approval, and a change in the process
  /// table arrive on the same stream. On a terminal the prompt lives on two
  /// reserved rows under the output (`TerminalScreen`); piped input keeps the
  /// one-line-at-a-time behaviour, where a turn finishes before the next line
  /// is read.
  private static func runREPL(
    workspace: inout AgentChatWorkspace,
    store: AgentChatStore,
    home: AgentHome,
    project: AgentProject,
    historyURL: URL,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: MaiConfiguration?,
    catalogs: [MCPServerCatalog],
    visual: VisualBridge,
    terminal: TerminalWriter
  ) async {
    var configuration = configuration
    var catalogs = catalogs
    var project = project
    var session = REPLSession(chat: workspace.selectedChat!)
    let editor = TerminalLineEditor(historyURL: historyURL)
    var announcedAttention: Set<AgentPID> = []
    // One process per chat, not per turn: a background agent started three
    // turns ago is still the current run's child, so it stays collectable,
    // and a message typed while a turn runs has a pid to wait in.
    var chatProcessIDs: [UUID: AgentPID] = [:]
    // Chats whose saved agents were put back in the process table this
    // session: once is enough, and clearing the table must not bring them
    // back.
    var restoredChatIDs: Set<UUID> = []
    await terminal.line("pmai — MaiCore agent REPL")
    await terminal.line(
      "Project: \(project.displayName) · \(abbreviatedPath(project.workingDirectory)) · /project shows more"
    )
    await terminal.line(
      "Type /help for commands. \(promptIdentity(session)) · \(session.title)")
    let earlier = workspace.chats.filter { $0.id != session.id && $0.hasConversation }
    if !earlier.isEmpty {
      await terminal.line(
        "\(earlier.count) earlier chat\(earlier.count == 1 ? "" : "s") in this project: /chat list shows them, /chat use N switches."
      )
    }

    let (events, continuation) = AsyncStream<REPLEvent>.makeStream()
    let interruptHandler = TerminalInterruptHandler {
      continuation.yield(.interrupt($0, endedInput: $1))
    }
    let reader = REPLInputReader(
      editor: editor,
      continuation: continuation,
      interrupt: { interruptHandler.requestInterrupt(endedInput: true) })
    let screen = TerminalScreen()
    if let screen {
      screen.configure(ui: tintedUI(configuration?.ui ?? .init(), project: project))
      screen.activate()
      TerminalScreen.install(screen)
      editor.install(surface: screen)
      await terminal.attach(screen: screen)
      await visual.approvalHandler.setPrompter { request in
        // Stream iteration wakes when the waiting agent's task is cancelled.
        let (decisions, pending) = AsyncThrowingStream<ApprovalDecision, any Error>.makeStream()
        let reply = REPLApprovalReply(pending)
        defer { continuation.yield(.approvalFinished(reply)) }
        if case .terminated = continuation.yield(.approval(request, reply)) {
          throw CancellationError()
        }
        var iterator = decisions.makeAsyncIterator()
        guard let decision = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return decision
      }
    }
    let supervisorFeed = Task {
      for await change in await runtime.supervisor.events() {
        continuation.yield(.supervisor(change))
      }
    }
    var loop = REPLLoop()
    var activityWasInterrupted = false

    func refreshTerminalSettings() async {
      let ui = tintedUI(configuration?.ui ?? .init(), project: project)
      editor.configure(ui: ui)
      screen?.configure(ui: ui)
      await terminal.configureThinking(ui.thinking)
      await terminal.configureToolResultLines(ui.toolResultLines)
      await terminal.configureToolResultColor(ui.toolResultForeground)
      await terminal.configureSubagentOutput(ui.subagentOutput)
      await terminal.configurePromptColor(ui.promptForeground)
      await terminal.configureTerminalTitle(ui.title)
      configureEditor(ui.editor)
      visual.memory.focus(project: project, chatID: session.id)
      visual.todo.focus(project: project)
      await runtime.configureMemory(visual.memory.promptSection)
      await runtime.configureProjectInstructions(Self.projectInstructionsSection(configuration))
      await runtime.configurePlanning(configuration?.use.plan ?? true)
    }

    func statusLine() async -> (text: String, animating: Bool) {
      var facts: [String] = []
      let liveProcesses = await runtime.supervisor.liveProcesses()
      let running = loop.foregroundCommand != nil || (!activityWasInterrupted && !liveProcesses.isEmpty)
      let activityMarker = running ? "●" : "○"
      if let turn = loop.activeTurn {
        let activity = await runtime.supervisor.info(turn.pid)?.activity ?? ""
        let prefix = turn.kind == .btw ? "btw " : ""
        facts.append(
          prefix + (activity.isEmpty || activity == "thinking" ? "thinking" : "running \(activity)")
        )
      }
      if let command = loop.foregroundCommand { facts.append("running \(command)") }
      let children = liveProcesses.filter { $0.depth > 0 }
      if !children.isEmpty {
        let paused = children.filter { $0.state == .paused }.count
        let queued = children.filter { $0.state == .queued }.count
        var notes: [String] = []
        if paused > 0 { notes.append("\(paused) paused") }
        if queued > 0 { notes.append("\(queued) queued") }
        facts.append(
          "\(children.count) agent\(children.count == 1 ? "" : "s")"
            + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"))
      }
      let queued = await runtime.supervisor.queuedMessages().count
      if queued > 0 { facts.append("\(queued) queued") }
      if configuration?.ui.broadcast == true {
        facts.append("→ all active")
      } else if case .agent(let pid) = loop.focus {
        facts.append("→ agent#\(pid.rawValue)")
      }
      if let editing = loop.editingApproval {
        facts.append("json for \(editing.request.tool.name)?")
      } else if let waiting = loop.approvals.first {
        let who = waiting.request.run.pid.map { "agent#\($0.rawValue) " } ?? ""
        facts.append("approve? \(who)\(waiting.request.tool.name) [y/a/n/e/c]")
      }
      let detail = facts.isEmpty ? "" : " · " + facts.joined(separator: " · ")
      // The chat title goes last so a narrow terminal truncates it, not the status.
      return (
        "\(activityMarker) \(currentDirectoryName()) · \(project.displayName) \(promptIdentity(session))\(detail) · \(session.title)",
        running)
    }

    func promptText() -> String {
      let prompt: String
      if loop.pendingQueueMessage != nil {
        prompt = "queue [submit/ignore/clear]> "
      } else if loop.editingApproval != nil {
        prompt = "json> "
      } else if let waiting = loop.approvals.first {
        let who = waiting.request.run.pid.map { "#\($0.rawValue) " } ?? ""
        prompt = "approve \(who)\(waiting.request.tool.name)? [y/a/n/e/c] "
      } else if configuration?.ui.broadcast == true {
        prompt = "pmai@*> "
      } else if case .agent(let pid) = loop.focus {
        // The prompt names the process a line goes to: a focused child, or the
        // chat's own once it has run, so its pid is at hand for /agents commands.
        prompt = "pmai#\(pid.rawValue)> "
      } else if let pid = chatProcessIDs[session.id] {
        prompt = "pmai#\(pid.rawValue)> "
      } else {
        prompt = "pmai> "
      }
      let title = visibleUITitle(configuration?.ui.title ?? "")
      return title.isEmpty ? prompt : "[\(title)] \(prompt)"
    }

    func refreshStatus() async {
      guard let screen else { return }
      let status = await statusLine()
      screen.setStatus(status.text, animating: status.animating)
    }

    /// Lets the input thread read the next line. Settings that the editor
    /// reads are refreshed here, while the thread is parked and cannot race.
    func releaseReader(workspace: AgentChatWorkspace) async {
      guard loop.readerParked, !loop.exiting else { return }
      await refreshTerminalSettings()
      if screen == nil {
        // Announcing while the classic editor owns the row would corrupt it,
        // so on a plain terminal this happens between prompts.
        await announceAgentAttention(
          runtime: runtime, announced: &announcedAttention, terminal: terminal)
      }
      let status = await statusLine()
      screen?.setStatus(status.text, animating: status.animating)
      loop.readerParked = false
      reader.resume(
        with: REPLInputReader.Prompt(
          text: promptText(),
          completions: completionCandidates(
            workspace: workspace, configuration: configuration,
            skills: visual.skills.catalog.skills),
          separator: screen == nil ? status.text : nil))
    }

    /// On a plain terminal a turn owns the screen, so the next line waits for
    /// it; on the persistent screen the prompt is always open.
    func releaseIfIdle(workspace: AgentChatWorkspace) async {
      if screen != nil || loop.activeTurn == nil {
        await releaseReader(workspace: workspace)
      }
    }

    func mainProcess() async -> AgentPID {
      if let pid = chatProcessIDs[session.id] { return pid }
      let pid = await runtime.allocateProcess(agentID: session.profile.agentID, task: session.title)
      chatProcessIDs[session.id] = pid
      return pid
    }

    /// Brings every chat's saved agents up to date with the process table:
    /// what runs under a chat's process, live or finished, replaces its
    /// saved copy, and what the table has since forgotten stays as saved.
    /// Called wherever the workspace is about to be written.
    func recordSubagents() async {
      for (chatID, pid) in chatProcessIDs {
        let current = await runtime.supervisor.records(under: pid)
        if chatID == session.id {
          session.subagents = AgentProcessRecord.merging(
            saved: session.subagents, current: current)
        } else if var chat = workspace.chats.first(where: { $0.id == chatID }) {
          chat.subagents = AgentProcessRecord.merging(saved: chat.subagents, current: current)
          workspace.upsert(chat)
        }
      }
    }

    /// Puts the agents saved with the chat at the prompt back in the process
    /// table, once per chat and session, so `/agents tree` and `/agents log`
    /// show what earlier runs started before the chat's next turn.
    func restoreSavedSubagents() async {
      guard restoredChatIDs.insert(session.id).inserted, !session.subagents.isEmpty else {
        return
      }
      let pid = await mainProcess()
      let restored = await runtime.supervisor.restore(session.subagents, under: pid)
      // Idle between turns, like a chat that has already run: listed as done,
      // cleared with the rest, and reopened by its next turn.
      await runtime.supervisor.complete(pid)
      guard !restored.isEmpty else { return }
      await terminal.line(
        "\(restored.count) agent\(restored.count == 1 ? "" : "s") from earlier runs of this chat: /agents tree lists them, /agents log PID reads one, /agents clear drops them."
      )
    }

    /// Drops the agents saved with the chat at the prompt that the process
    /// table no longer holds, after `/agents clear`. Answers how many went.
    func dropForgottenSubagents() async -> Int {
      let known = Set(await runtime.supervisor.processes().map(\.runID))
      let before = session.subagents.count
      session.subagents.removeAll { !known.contains($0.runID) }
      return before - session.subagents.count
    }

    func beginTurn(_ request: AgentRequest, process pid: AgentPID, kind: REPLTurnKind) async {
      await terminal.resetResponse()
      let task = Task {
        try await runtime.run(request, process: pid) { event in
          await terminal.consume(event)
        }
      }
      let interrupt = interruptHandler.activate { task.cancel() }
      activityWasInterrupted = false
      loop.activeTurn = REPLTurn(
        task: task, interrupt: interrupt, started: ContinuousClock.now, pid: pid, kind: kind,
        chatID: kind == .chat ? session.id : nil, sent: request.messages)
      Task {
        let outcome: Result<AgentResult, any Error>
        do {
          outcome = .success(try await task.value)
        } catch {
          outcome = .failure(error)
        }
        continuation.yield(.turnFinished(outcome))
      }
      await refreshStatus()
    }

    /// Starts one turn with whatever is queued for the chat followed by the
    /// texts just typed. The turn runs in its own task; the loop hears about
    /// its end as an event.
    func startTurn(_ texts: [String], ignoringQueue: Bool = false) async {
      let pid = await mainProcess()
      let held = ignoringQueue
        ? Set(await runtime.supervisor.queuedMessages(for: pid).map(\.id)) : []
      var messages = await runtime.supervisor.drainInbox(pid, excluding: held)
      messages.append(contentsOf: texts.map { AgentMessage.user($0) })
      guard !messages.isEmpty else { return }
      if !session.pendingContent.isEmpty {
        messages[0].content.append(contentsOf: session.pendingContent)
        session.pendingContent.removeAll()
      }
      for message in messages { session.history.append(message) }
      session.refreshTitle(from: messages[0].text)
      var request = chatRequest()
      request.ignoredQueuedMessageIDs = held
      await beginTurn(request, process: pid, kind: .chat)
    }

    /// The chat's next run: its whole history under the current profile.
    func chatRequest() -> AgentRequest {
      let profile = session.profile
      return AgentRequest(
        agentID: profile.agentID,
        provider: profile.provider,
        model: profile.model,
        messages: session.history.messages,
        toolNames: profile.toolNames,
        toolGroupNames: profile.toolGroupNames,
        subagentNames: profile.subagentNames,
        toolChoice: profile.toolChoice,
        responseFormat: profile.responseFormat,
        options: profile.options,
        limits: profile.limits,
        stream: profile.stream,
        toolCallingStrategy: profile.toolCallingStrategy,
        useToolProxy: profile.useToolProxy,
        proxyExposedTools: profile.proxyExposedTools,
        toolDelegation: profile.toolDelegation,
        retry: profile.retry,
        autocompact: profile.autocompact,
        context: profile.context,
        sessionID: session.sessionID)
    }

    /// Picks a paused or interrupted task up where it stopped: the history is
    /// run again with a fresh budget and nothing new said, so the model sees
    /// its last tool results and carries on. Queued messages go with it, the
    /// way they would with a typed one.
    @discardableResult
    func continueTurn() async -> Bool {
      let pid = await mainProcess()
      if await runtime.supervisor.hasQueuedMessages(pid) {
        await startTurn([])
        return true
      }
      guard let last = session.history.messages.last, last.role != .system else {
        await terminal.line("Nothing to continue yet: this chat has no messages.")
        return false
      }
      if last.role == .assistant, last.toolCalls.isEmpty {
        await terminal.line(
          "Nothing to continue: the last reply was complete. Type a message instead.")
        return false
      }
      await beginTurn(chatRequest(), process: pid, kind: .chat)
      return true
    }

    /// Folds what an interrupted run had already added into the chat, with
    /// any tool call it never answered marked as such, so the next turn — a
    /// typed one or /continue — starts from there instead of from before the
    /// run. Returns how many messages were kept.
    func keepPartialTranscript(of turn: REPLTurn, reason: String) async -> Int {
      guard let chatID = turn.chatID, let current = currentMessages(of: chatID) else { return 0 }
      let partial = await runtime.supervisor.transcript(turn.pid)
      guard !partial.isEmpty, partial != current else { return 0 }
      let kept = max(0, partial.count - turn.sent.count)
      settle(
        AgentTranscriptEditor.answeringUnansweredToolCalls(in: partial, reason: reason), from: turn)
      return kept
    }

    /// The messages a chat holds right now: the session's for the chat at the
    /// prompt, the workspace copy for any other. Nil once the chat is closed.
    func currentMessages(of chatID: UUID) -> [AgentMessage]? {
      if chatID == session.id { return session.history.messages }
      return workspace.chats.first { $0.id == chatID }?.messages
    }

    /// Folds a run's transcript into the chat it started from. That is
    /// usually the chat at the prompt, but the person may have moved to
    /// another chat or edited this one while the run was going; the reply
    /// still lands where the run began, after any edits made there meanwhile.
    /// Answers false when that chat was closed in the meantime.
    @discardableResult
    func settle(_ transcript: [AgentMessage], from turn: REPLTurn) -> Bool {
      guard let chatID = turn.chatID, let current = currentMessages(of: chatID) else {
        return false
      }
      let merged = Self.mergedTranscript(current: current, sent: turn.sent, result: transcript)
      if chatID == session.id {
        session.history.replaceAll(with: merged)
      } else if var chat = workspace.chats.first(where: { $0.id == chatID }) {
        chat.messages = merged
        chat.touch()
        workspace.upsert(chat)
      }
      return true
    }

    /// Runs a command with the running turn's Ctrl+C set aside, so a program
    /// the command hands the tty to — an editor, a shell — keeps its own
    /// Ctrl+C instead of ending the run.
    func withTurnInterruptSetAside(_ body: () async -> Void) async {
      let turn = loop.activeTurn
      if let turn { interruptHandler.suspend(turn.interrupt) }
      let shield = interruptHandler.activate(reports: false) {}
      await body()
      _ = interruptHandler.deactivate(shield)
      if let turn { interruptHandler.restore(turn.interrupt) { turn.task.cancel() } }
    }

    /// Gives Ctrl+C to one non-interactive command, then restores a turn that
    /// may still be streaming behind it. Its value state is applied by the
    /// event loop only after the command ends.
    func runForeground<Value: Sendable>(
      _ name: String,
      resumeInput: Bool = true,
      operation: @escaping @Sendable () async -> Value
    ) async -> (value: Value, interrupted: Bool) {
      let turn = loop.activeTurn
      if let turn { interruptHandler.suspend(turn.interrupt) }
      let task = Task { await operation() }
      let interrupt = interruptHandler.activate { task.cancel() }
      loop.foregroundCommand = name
      if screen != nil && resumeInput { await releaseReader(workspace: workspace) }
      let value = await task.value
      let interrupted = interruptHandler.deactivate(interrupt)
      loop.foregroundCommand = nil
      if let turn { interruptHandler.restore(turn.interrupt) { turn.task.cancel() } }
      return (value, interrupted)
    }

    /// After a command ran under a turn: says how what it changed meets the
    /// run. Chat edits are merged when its reply lands; operational settings
    /// are pushed into the live request and observed at its next safe boundary.
    func noteTurnEffects(since before: REPLCommandSnapshot) async {
      guard let turn = loop.activeTurn else { return }
      if session.id != before.chatID {
        guard turn.chatID == before.chatID else { return }
        if workspace.chats.contains(where: { $0.id == before.chatID }) {
          await terminal.note(
            "The turn running in '\(before.title)' finishes there; its reply lands in that chat.")
        } else {
          await terminal.note(
            "The turn running in '\(before.title)' goes on without its chat; /agents log \(turn.pid.rawValue) will show its reply, Ctrl+C cancels it."
          )
        }
        return
      }
      if session.history.messages != before.messages, turn.chatID == session.id {
        await terminal.note(
          "A turn is running; what it adds goes after this edit when it finishes.")
      }
      if FileManager.default.currentDirectoryPath != before.directory {
        await terminal.note("A turn is running; its tools now work in the new directory.")
      }
      if session.profile.agentDefinition != before.agent, turn.chatID == session.id,
        await runtime.reconfigure(turn.pid, with: chatRequest())
      {
        await terminal.note(
          "Updated the running agent; the operation already in flight finishes, and the next model or tool call uses these settings."
        )
      }
    }

    /// Runs a one-off prompt with the active profile and no conversation
    /// messages. It is a real turn so streaming, tools, approvals, and Ctrl+C
    /// work normally, but its transcript never replaces the chat's.
    func startBTW(_ text: String) async {
      guard let request = btwRequest(text, profile: session.profile) else {
        await terminal.line("Usage: /btw PROMPT")
        return
      }
      let pid = await runtime.allocateProcess(
        agentID: session.profile.agentID, task: "btw: \(text)")
      await beginTurn(request, process: pid, kind: .btw)
    }

    /// Sends typed text where it belongs: to the chat as a new turn when it
    /// is idle, or into an inbox the running agent reads at its next turn.
    func deliver(_ text: String, to target: REPLMessageTarget) async {
      switch target {
      case .main:
        guard loop.activeTurn != nil else {
          let pid = await mainProcess()
          let count = await runtime.supervisor.queuedMessages(for: pid).count
          if count > 0 {
            loop.pendingQueueMessage = text
            await terminal.line(
              "\(count) queued message(s). Submit them before this message, ignore them for this turn, or clear them? [submit/ignore/clear]")
          } else {
            await startTurn([text])
          }
          return
        }
        let pid = await mainProcess()
        await runtime.supervisor.post(.user(text), to: pid)
        let waiting = await runtime.supervisor.queuedMessages(for: pid).count
        await terminal.note(
          "queued (\(waiting) waiting): it joins the conversation at the next model turn · /queue")
      case .agent(let pid):
        guard let info = await runtime.supervisor.info(pid) else {
          await terminal.note("No agent #\(pid.rawValue). /agents tree lists the running ones.")
          return
        }
        if pid == chatProcessIDs[session.id] {
          await deliver(text, to: .main)
          return
        }
        // A top-level pid from another chat owns a different inbox, even
        // when that chat is idle. Never redirect it to the focused chat.
        guard info.depth == 0 || !info.state.isTerminal else {
          await terminal.note(
            "agent#\(pid.rawValue) (\(info.agentID)) has finished; /agents log \(pid.rawValue) shows what it did."
          )
          if loop.focus == .agent(pid) { loop.focus = .main }
          return
        }
        await runtime.supervisor.post(.user(text), to: pid)
        let waiting = await runtime.supervisor.queuedMessages(for: pid).count
        let when =
          await runtime.supervisor.isPaused(pid)
          ? "it is paused, so /agents continue \(pid.rawValue) delivers it"
          : "delivered at its next model turn"
        await terminal.note(
          "queued for agent#\(pid.rawValue) (\(info.agentID)) (\(waiting) waiting): \(when)"
        )
      }
      await refreshStatus()
    }

    func deliver(_ text: String, to addresses: [REPLMessageAddress]) async {
      do {
        let main = await mainProcess()
        let recipients = try await messageRecipients(
          addresses, main: main, supervisor: runtime.supervisor)
        for info in recipients where info.pid != main {
          await deliver(text, to: .agent(info.pid))
        }
        if recipients.contains(where: { $0.pid == main }) {
          await deliver(text, to: .main)
        }
      } catch {
        await terminal.note(error.localizedDescription)
      }
    }

    /// Treats a typed line as the answer to the approval at the head of the
    /// queue when it reads as one; anything else stays an ordinary line and
    /// the question keeps waiting.
    func answerApproval(_ text: String) async -> Bool {
      if let editing = loop.editingApproval {
        // Settings and inspection remain available while an edit prompt is
        // open; only an ordinary line is interpreted as replacement JSON.
        if text.hasPrefix("/") { return false }
        loop.editingApproval = nil
        if let data = text.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          value.objectValue != nil
        {
          editing.reply.resume(with: .approve(arguments: value))
          await terminal.note("approved \(editing.request.tool.name) with the edited arguments")
        } else {
          editing.reply.resume(with: .deny(reason: "Edited arguments were not a JSON object."))
          await terminal.note(
            "denied \(editing.request.tool.name): the arguments were not a JSON object")
        }
        return true
      }
      guard let waiting = loop.approvals.first else { return false }
      let tool = waiting.request.tool.name
      switch text.lowercased() {
      case "y", "yes":
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool)")
      case "a", "always":
        await visual.approvalHandler.setYOLOEnabled(true)
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool); YOLO mode is on for this session")
      case "n", "no":
        waiting.reply.resume(with: .deny(reason: "Denied by user."))
        await terminal.note("denied \(tool)")
      case "e", "edit":
        loop.approvals.removeFirst()
        loop.editingApproval = waiting
        await terminal.note("Type the replacement JSON arguments for \(tool):")
        return true
      case "c", "cancel":
        waiting.reply.resume(with: .cancelRun)
        await terminal.note("cancelling the run that asked for \(tool)")
      default:
        return false
      }
      loop.approvals.removeFirst()
      return true
    }

    /// Turning YOLO on while calls already wait for approval releases them as
    /// well as future calls. Otherwise the setting is live but the run still
    /// appears blocked on decisions made under the old value.
    func releasePendingApprovalsIfYOLO() async {
      guard await visual.approvalHandler.isYOLOEnabled() else { return }
      if let editing = loop.editingApproval {
        editing.reply.resume(with: .approve(arguments: editing.request.call.arguments))
        loop.editingApproval = nil
      }
      let pending = loop.approvals
      loop.approvals.removeAll()
      for approval in pending {
        approval.reply.resume(with: .approve(arguments: approval.request.call.arguments))
      }
      if !pending.isEmpty {
        await terminal.note(
          "approved \(pending.count) waiting tool call\(pending.count == 1 ? "" : "s"); YOLO mode is on")
      }
    }

    func handleFocus(_ argument: String) async {
      let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        if configuration?.ui.broadcast == true {
          await terminal.line(
            "Messages go to every active agent. /set ui.broadcast off restores the focus.")
          return
        }
        switch loop.focus {
        case .main:
          await terminal.line(
            "Messages go to this chat. /agents focus PID sends them to a running agent.")
        case .agent(let pid):
          await terminal.line(
            "Messages go to agent#\(pid.rawValue). /agents focus main returns to the chat.")
        }
        return
      }
      guard let target = focusTarget(trimmed) else {
        await terminal.line("Usage: /agents focus <PID|main>")
        return
      }
      switch target {
      case .main:
        loop.focus = .main
        await terminal.line(
          configuration?.ui.broadcast == true
            ? "Focus saved: main. Broadcast is on; @main TEXT addresses this chat."
            : "Messages go to this chat again.")
      case .agent(let pid):
        guard let info = await runtime.supervisor.info(pid) else {
          await terminal.line("No agent #\(pid.rawValue). /agents tree lists the running ones.")
          return
        }
        guard info.depth > 0, !info.state.isTerminal else {
          await terminal.line(
            info.depth == 0
              ? "agent#\(pid.rawValue) is this chat; /agents focus main is the same thing."
              : "agent#\(pid.rawValue) (\(info.agentID)) has finished; pick a running one from /agents tree."
          )
          return
        }
        loop.focus = .agent(pid)
        await terminal.line(
          configuration?.ui.broadcast == true
            ? "Focus saved: agent#\(pid.rawValue). Broadcast is on; @\(pid.rawValue) TEXT addresses this agent."
            : "Messages go to agent#\(pid.rawValue) (\(info.agentID)) until /agents focus main; @main TEXT still reaches the chat."
        )
      }
    }

    await restoreSavedSubagents()
    reader.start()
    await releaseReader(workspace: workspace)

    events: for await event in events {
      switch event {
      case .line(let raw, let heredoc):
        loop.readerParked = true
        let typed = heredoc ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `$NAME [TEXT]` is the short form of `/prompts NAME [TEXT]`.
        let text =
          !heredoc && typed.hasPrefix("$")
          ? ("/prompts " + typed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
          : typed
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          await releaseIfIdle(workspace: workspace)
          continue
        }
        if !heredoc, text == "/stop" {
          // Use the same event as Ctrl+C, including pending queue decisions.
          interruptHandler.requestInterrupt()
          continue
        }
        if let pending = loop.pendingQueueMessage {
          switch text.lowercased() {
          case "submit", "s":
            loop.pendingQueueMessage = nil
            await startTurn([pending])
          case "ignore", "i":
            loop.pendingQueueMessage = nil
            await startTurn([pending], ignoringQueue: true)
          case "clear", "c":
            loop.pendingQueueMessage = nil
            let pid = await mainProcess()
            await runtime.supervisor.clearQueuedMessages(for: pid)
            await startTurn([pending])
          default:
            await terminal.line("Choose submit, ignore, or clear. Ctrl+C or /stop cancels this new message and keeps the queue.")
          }
          await releaseIfIdle(workspace: workspace)
          continue
        }
        if !heredoc, await answerApproval(text) {
          await refreshStatus()
          await releaseIfIdle(workspace: workspace)
          continue
        }
        if !heredoc {
          do {
            if let addressed = try addressedMessage(text) {
              await deliver(addressed.body, to: addressed.targets)
              await releaseIfIdle(workspace: workspace)
              continue
            }
          } catch {
            await terminal.note(error.localizedDescription)
            await releaseIfIdle(workspace: workspace)
            continue
          }
        }
        if !heredoc, text.hasPrefix("!") {
          if loop.activeTurn != nil {
            await terminal.note("A turn is running; what it prints waits until the command ends.")
          }
          await withTurnInterruptSetAside {
            await runShellCommand(String(text.dropFirst()), terminal: terminal)
          }
          await releaseIfIdle(workspace: workspace)
          continue
        }
        if !heredoc, text.hasPrefix("/") {
          let command = text.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
          let name = String(command[0])
          let argument =
            command.count > 1
            ? command[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
          if name == "/queue" {
            let main = await mainProcess()
            await handleQueueCommand(
              argument,
              defaultAddress: configuration?.ui.broadcast == true ? .active : .target(loop.focus),
              main: main, runtime: runtime, terminal: terminal)
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/agents" || name == "/agent",
            argument == "focus" || argument.hasPrefix("focus ")
          {
            await handleFocus(String(argument.dropFirst("focus".count)))
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/agents" || name == "/agent", argument.lowercased() == "clear" {
            let cleared = Set(await runtime.supervisor.clearFinished())
            // A chat whose idle process went with them gets a fresh one at
            // its next turn; nothing it said is lost, the session has it.
            chatProcessIDs = chatProcessIDs.filter { !cleared.contains($0.value) }
            // Clearing is also how the agents saved with this chat are
            // purged: what stays in its file is what the table still holds.
            let dropped = await dropForgottenSubagents()
            if dropped > 0 {
              workspace.upsert(session.chat, selecting: true)
              await saveWorkspace(&workspace, store: store, terminal: terminal)
            }
            let summary =
              switch (cleared.count, dropped) {
              case (0, 0): "No finished agents to clear."
              case (let count, 0):
                "Cleared \(count) finished agent\(count == 1 ? "" : "s"); /agents tree lists what still runs."
              case (0, let dropped):
                "Dropped \(dropped) agent\(dropped == 1 ? "" : "s") saved with this chat."
              case (let count, let dropped):
                "Cleared \(count) finished agent\(count == 1 ? "" : "s") and dropped \(dropped) saved with this chat; /agents tree lists what still runs."
              }
            await terminal.line(summary)
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/exit" || name == "/quit" {
            loop.beginExit()
            if loop.activeTurn != nil { continue }
            break events
          }
          if name == "/continue" {
            if loop.activeTurn != nil {
              await terminal.note("A turn is already running; Ctrl+C cancels it.")
            } else {
              await continueTurn()
            }
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/prompts" {
            let before = REPLCommandSnapshot(session: session)
            var outcome = PromptsCommandOutcome.handled
            await withTurnInterruptSetAside {
              outcome = await handlePromptsCommand(
                argument,
                session: session,
                configuration: &configuration,
                configurationPath: visual.configurationPath,
                skills: visual.skills.catalog,
                terminal: terminal)
            }
            switch outcome {
            case .handled:
              break
            case .send(let message, let title):
              session.refreshTitle(from: title)
              await deliver(message, to: loop.focus)
            case .selectSystemPrompt(let promptName, let message):
              await selectSystemPrompt(
                promptName,
                session: &session,
                runtime: runtime,
                configuration: &configuration,
                configurationPath: visual.configurationPath,
                terminal: terminal)
              session.touch()
              workspace.upsert(session.chat, selecting: true)
              await saveWorkspace(&workspace, store: store, terminal: terminal)
              await noteTurnEffects(since: before)
              if let message { await deliver(message, to: loop.focus) }
            }
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/skills" || name == "/skill", let request = skillPromptRequest(argument) {
            if request.name.isEmpty {
              await terminal.line("Usage: /skills prompt NAME [TEXT]   (/skills lists the names)")
            } else if let skill = visual.skills.catalog.skill(named: request.name) {
              session.refreshTitle(from: "\(skill.name) \(request.arguments)")
              await deliver(skill.prompt(arguments: request.arguments), to: loop.focus)
            } else {
              await terminal.line("Unknown skill '\(request.name)'. /skills lists them.")
            }
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/edit", argument.lowercased() == "input" {
            // The editor takes the terminal, as it does for /reply.
            var message: String?
            await withTurnInterruptSetAside {
              message = await composeInput(terminal: terminal)
            }
            if let message { await deliver(message, to: loop.focus) }
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/reply" {
            // The editor takes the terminal, so a running turn keeps its
            // Ctrl+C rather than ending on the one meant for the editor.
            var message: String?
            await withTurnInterruptSetAside {
              message = await composeReply(argument, session: session, terminal: terminal)
            }
            if let message { await deliver(message, to: loop.focus) }
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/btw" {
            if loop.activeTurn != nil {
              await terminal.note(
                "/btw waits for the running turn; Ctrl+C cancels it. Messages typed now are queued."
              )
            } else {
              await startBTW(argument)
            }
            await releaseIfIdle(workspace: workspace)
            continue
          }
          #if PMAI_HAS_VISUAL
            if name == "/visual", loop.activeTurn != nil {
              await terminal.note(
                "Visual mode takes the whole screen, so it waits for the running turn; Ctrl+C cancels it."
              )
              await releaseIfIdle(workspace: workspace)
              continue
            }
          #endif
          // Every other command runs now. What it changes and the running
          // turn meet as noteTurnEffects describes, with a note, not a wait.
          let before = REPLCommandSnapshot(session: session)
          if name == "/project" {
            await handleProjectCommand(
              argument,
              project: &project,
              home: home,
              store: store,
              terminal: terminal)
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/chat" {
            await recordSubagents()
            workspace.upsert(session.chat, selecting: true)
            await handleWorkspaceChatCommand(
              argument,
              session: &session,
              workspace: &workspace,
              runtime: runtime,
              configuration: configuration,
              chatProcess: chatProcessIDs[session.id],
              terminal: terminal)
            await restoreSavedSubagents()
            workspace.upsert(session.chat, selecting: true)
            await saveWorkspace(&workspace, store: store, terminal: terminal)
            await noteTurnEffects(since: before)
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/import" {
            await recordSubagents()
            workspace.upsert(session.chat, selecting: true)
            await withTurnInterruptSetAside {
              await handleImportCommand(
                argument,
                session: &session,
                workspace: &workspace,
                runtime: runtime,
                plugins: plugins,
                configuration: &configuration,
                catalogs: &catalogs,
                visual: visual,
                selectImportedChat: loop.activeTurn == nil,
                terminal: terminal)
            }
            await restoreSavedSubagents()
            workspace.upsert(session.chat, selecting: true)
            await saveWorkspace(&workspace, store: store, terminal: terminal)
            await noteTurnEffects(since: before)
            await releaseIfIdle(workspace: workspace)
            continue
          }
          await recordSubagents()
          #if PMAI_HAS_VISUAL
            if text == "/visual" {
              workspace.upsert(session.chat, selecting: true)
              session.visualSnapshot = visualSnapshot(for: workspace)
            }
          #endif
          var exits = false
          var commandWasInterrupted = false
          let editsInTerminal =
            ["/edit", "/attach", "/visual"].contains(name)
            || argument.split(whereSeparator: \Character.isWhitespace).first?.lowercased() == "edit"
          if editsInTerminal {
            await withTurnInterruptSetAside {
              exits = await handleCommand(
                text,
                session: &session,
                runtime: runtime,
                plugins: plugins,
                ocrProvider: ocrProvider,
                configuration: &configuration,
                catalogs: &catalogs,
                visual: visual,
                chatProcess: chatProcessIDs[session.id],
                editor: editor,
                terminal: terminal)
            }
          } else {
            let commandSession = session
            let commandConfiguration = configuration
            let commandCatalogs = catalogs
            let commandChatProcess = chatProcessIDs[session.id]
            let changesRouting = name == "/set"
              && argument.split(whereSeparator: \.isWhitespace).first?.lowercased() == "ui.broadcast"
            let command = await runForeground(name, resumeInput: !changesRouting) {
              await runCommand(
                text,
                session: commandSession,
                runtime: runtime,
                plugins: plugins,
                ocrProvider: ocrProvider,
                configuration: commandConfiguration,
                catalogs: commandCatalogs,
                visual: visual,
                chatProcess: commandChatProcess,
                terminal: terminal)
            }
            commandWasInterrupted = command.interrupted
            session = command.value.session
            configuration = command.value.configuration
            catalogs = command.value.catalogs
            exits = command.value.exits
            if commandWasInterrupted { await terminal.note("cancelled \(name)") }
          }
          if exits {
            loop.exiting = true
            break events
          }
          await releasePendingApprovalsIfYOLO()
          #if PMAI_HAS_VISUAL
            if text == "/visual", let snapshot = session.visualSnapshot {
              workspace = chatWorkspace(from: snapshot, focusedID: session.id, previous: workspace)
              session = REPLSession(chat: workspace.selectedChat!)
            } else {
              session.touch()
              workspace.upsert(session.chat, selecting: true)
            }
          #else
            session.touch()
            workspace.upsert(session.chat, selecting: true)
          #endif
          await saveWorkspace(&workspace, store: store, terminal: terminal)
          await restoreSavedSubagents()
          await noteTurnEffects(since: before)
          await refreshStatus()
          // A cancellation has an ordered interrupt event waiting behind this
          // command; that event releases exactly one prompt. Signalling here as
          // well would leave an extra semaphore permit and start two readers.
          if !commandWasInterrupted { await releaseIfIdle(workspace: workspace) }
          continue
        }
        if configuration?.ui.broadcast == true {
          await deliver(text, to: [.active])
        } else {
          await deliver(text, to: loop.focus)
        }
        await releaseIfIdle(workspace: workspace)

      case .interrupt(let cancelledOperation, let endedInput):
        if endedInput { loop.readerParked = true }
        // Reflect Ctrl+C immediately, rather than waiting for a provider or
        // tool cancellation to make its way through the supervisor.
        activityWasInterrupted = cancelledOperation == loop.activeTurn?.interrupt
        if loop.pendingQueueMessage != nil {
          loop.pendingQueueMessage = nil
          await terminal.note("New message cancelled; the queue is unchanged.")
        } else if cancelledOperation != nil {
          // The input or signal path already cancelled exactly the operation
          // that was active when Ctrl+C arrived. Do not let a delayed event
          // cancel whatever became active afterwards.
        } else if let waiting = loop.approvals.first {
          loop.approvals.removeFirst()
          waiting.reply.fail(CancellationError())
        } else if loop.editingApproval != nil {
          loop.editingApproval?.reply.resume(with: .deny(reason: "Edit cancelled."))
          loop.editingApproval = nil
        } else if screen != nil {
          await terminal.note("Nothing to cancel. /exit or Ctrl+D quits.")
        }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .endOfFile:
        loop.readerParked = true
        loop.beginExit()
        if loop.activeTurn != nil { continue }
        break events

      case .turnFinished(let outcome):
        let turn = loop.activeTurn
        let wasInterrupted = turn.map { interruptHandler.deactivate($0.interrupt) } ?? false
        loop.activeTurn = nil
        var succeeded = false
        var paused: AgentRunInterruption?
        var kept = 0
        var settled = true
        switch outcome {
        case .success(let result):
          if let turn, turn.chatID != nil {
            settled = settle(result.transcript, from: turn)
          }
          succeeded = true
          paused = result.interruption
        case .failure(let error):
          let cancelled = error is CancellationError || wasInterrupted
          if cancelled {
            if let turn {
              let stopped = Set(await runtime.supervisor.stop(turn.pid, reason: "Cancelled"))
              loop.cancelApprovals { $0.run.pid.map(stopped.contains) ?? false }
            }
            await terminal.recoverAfterCancellation()
          } else {
            await terminal.recoverAfterError(error.localizedDescription)
          }
          // What the run did before it broke off is not thrown away: the
          // supervisor has its transcript, and /continue picks it up.
          if let turn, turn.chatID != nil {
            kept = await keepPartialTranscript(
              of: turn, reason: cancelled ? "the run was cancelled" : "the run failed")
          }
        }
        // The run's own chat is usually the one at the prompt; `elsewhere`
        // names it when the person moved to another chat during the run.
        let atPrompt = turn?.chatID == session.id
        var elsewhere: String?
        if let turn, let chatID = turn.chatID, !atPrompt {
          elsewhere = workspace.chats.first { $0.id == chatID }?.displayTitle
        }
        if let turn {
          let prefix = turn.kind == .btw ? "btw " : ""
          var took = "\(prefix)took \(elapsedDescription(since: turn.started))"
          if let elsewhere {
            took += " · saved in '\(elsewhere)'"
          } else if !settled {
            took += " · its chat was closed; /agents log \(turn.pid.rawValue) shows the reply"
          }
          if let paused {
            await terminal.note("⏸ \(took) · \(paused.summary)", color: "yellow")
          } else {
            await terminal.note(
              succeeded ? "✓ \(took)" : "✗ \(took)", color: succeeded ? "cyan" : "red")
          }
        }
        if let turn, turn.chatID != nil {
          // The agents the run started, and earlier ones still going, are
          // saved with their chat as they stand now.
          await recordSubagents()
          if atPrompt {
            session.touch()
            workspace.upsert(session.chat, selecting: true)
          }
          await saveWorkspace(&workspace, store: store, terminal: terminal)
        }
        if loop.exiting { break events }
        if let turn {
          let waiting: Int
          if let pid = chatProcessIDs[session.id] {
            waiting = await runtime.supervisor.queuedMessages(for: pid).count
          } else {
            waiting = 0
          }
          // Entries deliberately ignored, or arriving after the last model
          // turn, stay queued until the person chooses to submit them.
          if waiting > 0 {
            await terminal.note(
              "\(waiting) queued message\(waiting == 1 ? "" : "s") still waiting: /queue shows them; /continue submits them; a new message asks what to do."
            )
          } else if let paused, atPrompt {
            // A spent turn budget is a checkpoint, and with yolo on the person
            // asked not to be consulted; time and token caps are theirs to lift.
            if paused.isCheckpoint, await visual.approvalHandler.isYOLOEnabled() {
              await terminal.note(
                "continuing: yolo is on, so a spent turn budget does not stop the task (/set yolo off to be asked)",
                color: "yellow")
              await continueTurn()
            } else {
              await terminal.note(
                "/continue picks the task up where it stopped · /set \(paused.settingKey) N goes further in one go"
              )
            }
          } else if kept > 0, atPrompt {
            await terminal.note(
              "kept \(kept) message\(kept == 1 ? "" : "s") from the interrupted run · /continue resumes it"
            )
          }
          if let elsewhere {
            let left = await runtime.supervisor.queuedMessages(for: turn.pid).count
            if left > 0 {
              await terminal.note(
                "\(left) queued message\(left == 1 ? "" : "s") wait in '\(elsewhere)'; /continue there submits them; a new message asks what to do."
              )
            } else if paused != nil || kept > 0 {
              await terminal.note(
                "/continue in '\(elsewhere)' picks that task up where it stopped.")
            }
          }
        }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .approval(let request, let reply):
        if loop.exiting {
          reply.fail(CancellationError())
        } else if await visual.approvalHandler.isYOLOEnabled() {
          reply.resume(with: .approve(arguments: request.call.arguments))
        } else {
          loop.approvals.append((request, reply))
          await terminal.approvalRequest(request)
        }
        await refreshStatus()

      case .approvalFinished(let reply):
        loop.approvals.removeAll { $0.reply === reply }
        if loop.editingApproval?.reply === reply { loop.editingApproval = nil }
        await refreshStatus()

      case .supervisor(let change):
        switch change {
        case .finished(let info) where info.depth > 0:
          await terminal.processEnded(info)
          if loop.focus == .agent(info.pid) {
            loop.focus = .main
            await terminal.note(
              "agent#\(info.pid.rawValue) has ended; messages go to this chat again.")
          }
        case .attention where screen != nil:
          await announceAgentAttention(
            runtime: runtime, announced: &announcedAttention, terminal: terminal,
            skippingApprovals: true)
        default:
          break
        }
        await refreshStatus()
      }
    }

    loop.beginExit()
    reader.stop()
    supervisorFeed.cancel()
    continuation.finish()
    await visual.approvalHandler.setPrompter(nil)
    await recordSubagents()
    workspace.upsert(session.chat, selecting: true)
    await saveWorkspace(&workspace, store: store, terminal: terminal, closing: true)
    await terminal.attach(screen: nil)
    editor.install(surface: nil)
    TerminalScreen.install(nil)
    screen?.deactivate()
  }

  /// `!ls`, `!git diff`, `!vim notes.md`: runs a line in the system shell with
  /// the terminal handed over, so interactive programs work and their output
  /// is neither captured nor sent to the model.
  private static func runShellCommand(_ command: String, terminal: TerminalWriter) async {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: !COMMAND")
      return
    }
    var waitStatus: CInt = -1
    let launch = { waitStatus = trimmed.withCString(posixSystem) }
    if let screen = TerminalScreen.current {
      screen.suspendTerminal(launch)
    } else {
      launch()
    }
    guard waitStatus != -1 else {
      await terminal.line(
        "error: Could not run '\(trimmed)': \(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription)",
        to: .standardError)
      return
    }
    // The wait status packs a signal in the low bits and an exit code above.
    let signalNumber = waitStatus & 0x7f
    if signalNumber != 0 {
      await terminal.note("killed by signal \(signalNumber)")
    } else if (waitStatus >> 8) & 0xff != 0 {
      await terminal.note("exit status \((waitStatus >> 8) & 0xff)")
    }
  }

  /// Reports background agents that are waiting on somebody, once each. A
  /// process that stops asking and asks again is announced again.
  private static func announceAgentAttention(
    runtime: AgentRuntime,
    announced: inout Set<AgentPID>,
    terminal: TerminalWriter,
    skippingApprovals: Bool = false
  ) async {
    // On the persistent screen an approval is already a question at the
    // prompt, so only the other kinds of attention need a line here.
    let waiting = await runtime.supervisor.processesNeedingAttention().filter { process in
      guard skippingApprovals, case .approval = process.attention else { return true }
      return false
    }
    let pids = Set(waiting.map(\.pid))
    announced.formIntersection(pids)
    for process in waiting where !announced.contains(process.pid) {
      announced.insert(process.pid)
      let verb =
        switch process.attention {
        case .approval: "needs approval"
        case .input: "is waiting for you"
        case .error: "stopped"
        case .finished: "finished"
        case nil: "changed"
        }
      await terminal.line(
        "agent \(process.pid) (\(process.agentID)) \(verb): "
          + "\(process.attention?.summary ?? "")  ·  /agents log \(process.pid.rawValue)")
    }
  }

  private static func submit(
    _ text: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    process: inout AgentPID?,
    terminal: TerminalWriter
  ) async -> Bool {
    var content: [ContentPart] = [.text(text)]
    content.append(contentsOf: session.pendingContent)
    session.pendingContent.removeAll()
    session.history.append(AgentMessage(role: .user, content: content))
    session.refreshTitle(from: text)
    await terminal.resetResponse()
    do {
      let profile = session.profile
      let request = AgentRequest(
        agentID: profile.agentID,
        provider: profile.provider,
        model: profile.model,
        messages: session.history.messages,
        toolNames: profile.toolNames,
        toolGroupNames: profile.toolGroupNames,
        subagentNames: profile.subagentNames,
        toolChoice: profile.toolChoice,
        responseFormat: profile.responseFormat,
        options: profile.options,
        limits: profile.limits,
        stream: profile.stream,
        toolCallingStrategy: profile.toolCallingStrategy,
        useToolProxy: profile.useToolProxy,
        proxyExposedTools: profile.proxyExposedTools,
        toolDelegation: profile.toolDelegation,
        retry: profile.retry,
        autocompact: profile.autocompact,
        context: profile.context,
        sessionID: session.sessionID)
      let existingProcess = process
      let result = try await runtime.run(request, process: existingProcess) { event in
        await terminal.consume(event)
      }
      process = await runtime.supervisor.tree().processes.first { $0.runID == result.runID }?.pid
      session.history.replaceAll(with: result.transcript)
      if let interruption = result.interruption {
        await terminal.note(
          "⏸ \(interruption.summary) · send another message to continue, or raise \(interruption.settingKey)",
          color: "yellow")
      }
      return true
    } catch {
      if error is CancellationError {
        await terminal.recoverAfterCancellation()
        return false
      }
      await terminal.recoverAfterError(error.localizedDescription)
      return false
    }
  }

  /// Builds the throwaway context used by `/btw`: the active agent's system
  /// prompt plus this one question, with none of the chat's transcript or
  /// pending attachments.
  private static func btwRequest(_ text: String, profile: SessionProfile) -> AgentRequest? {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return nil }
    var messages = AgentChat.initialHistory(for: profile.agentDefinition)
    messages.append(.user(prompt))
    return AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: messages,
      toolNames: profile.toolNames,
      toolGroupNames: profile.toolGroupNames,
      subagentNames: profile.subagentNames,
      toolChoice: profile.toolChoice,
      responseFormat: profile.responseFormat,
      options: profile.options,
      limits: profile.limits,
      stream: profile.stream,
      toolCallingStrategy: profile.toolCallingStrategy,
      useToolProxy: profile.useToolProxy,
      proxyExposedTools: profile.proxyExposedTools,
      toolDelegation: profile.toolDelegation,
      retry: profile.retry,
      autocompact: profile.autocompact,
      context: profile.context)
  }

  /// Visual mode runs commands in their own task already, so it can await the
  /// isolated turn directly. The REPL starts the same request in its event loop
  /// to keep approvals and Ctrl+C responsive.
  private static func handleBTWCommand(
    _ text: String,
    session: REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    guard let request = btwRequest(text, profile: session.profile) else {
      await terminal.line("Usage: /btw PROMPT")
      return
    }
    await terminal.resetResponse()
    do {
      _ = try await runtime.run(request) { event in
        await terminal.consume(event)
      }
    } catch is CancellationError {
      await terminal.recoverAfterCancellation()
    } catch {
      await terminal.recoverAfterError(error.localizedDescription)
    }
  }

  /// The agent, estimated context, and model a chat runs on. The context is
  /// deliberately immediately before the model so it stays easy to compare.
  private static func promptIdentity(_ session: REPLSession) -> String {
    let profile = session.profile
    let model = profile.model.isEmpty ? profile.provider.rawValue : profile.model
    return "[\(profile.agentID)] · \(promptContextStatus(session)) · \(model)"
  }

  /// The final component of the working directory, with a useful root label.
  private static func currentDirectoryName() -> String {
    let path = FileManager.default.currentDirectoryPath
    if path == "/" { return path }
    let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    return name.isEmpty ? path : name
  }

  /// Removes terminal controls from the configured label before showing it.
  private static func visibleUITitle(_ title: String) -> String {
    String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// How long a turn took, as `5s`, `1m4s`, or `2h3m4s`.
  private static func elapsedDescription(since start: ContinuousClock.Instant) -> String {
    let parts = (ContinuousClock.now - start).components
    let total = Int(parts.seconds) + (parts.attoseconds >= 500_000_000_000_000_000 ? 1 : 0)
    guard total >= 1 else { return "<1s" }
    let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
    if hours > 0 { return "\(hours)h\(minutes)m\(seconds)s" }
    if minutes > 0 { return "\(minutes)m\(seconds)s" }
    return "\(seconds)s"
  }

  /// A fast, deliberately approximate context indicator. Providers tokenize
  /// differently and do not all expose their context-window size, so showing
  /// an estimate is more honest than implying an exact percentage.
  private static func promptContextStatus(_ session: REPLSession) -> String {
    let characters = session.history.messages.reduce(0) { total, message in
      total + message.content.reduce(0) { $0 + renderFullContent($1).utf8.count }
    }
    let estimatedTokens = (characters + 2) / 3
    let messageLabel = "\(session.history.count) msg"
    return "\(messageLabel) \(ModelUsageFormat.tokens(estimatedTokens, estimated: true))"
  }

  private static func changeWorkingDirectory(_ argument: String, terminal: TerminalWriter) async {
    let path = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      await terminal.line("Usage: /cd PATH")
      return
    }
    let expanded = NSString(string: path).expandingTildeInPath
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let target = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      await terminal.line("error: Not a directory: \(target.path)", to: .standardError)
      return
    }
    guard FileManager.default.changeCurrentDirectoryPath(target.path) else {
      await terminal.line("error: Could not change directory to \(target.path)", to: .standardError)
      return
    }
    await terminal.line(FileManager.default.currentDirectoryPath)
  }

  /// Runs the large command switch against copies. The event loop applies the
  /// returned values once the task ends, keeping mutable REPL state in one
  /// place while letting Ctrl+C cancel network and other cooperative waits.
  private static func runCommand(
    _ input: String,
    session: REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: MaiConfiguration?,
    catalogs: [MCPServerCatalog],
    visual: VisualBridge,
    chatProcess: AgentPID?,
    terminal: TerminalWriter
  ) async -> REPLCommandResult {
    var session = session
    var configuration = configuration
    var catalogs = catalogs
    let exits = await handleCommand(
      input,
      session: &session,
      runtime: runtime,
      plugins: plugins,
      ocrProvider: ocrProvider,
      configuration: &configuration,
      catalogs: &catalogs,
      visual: visual,
      chatProcess: chatProcess,
      terminal: terminal)
    return REPLCommandResult(
      session: session, configuration: configuration, catalogs: catalogs, exits: exits)
  }

  private static func handleCommand(
    _ input: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    visual: VisualBridge,
    chatProcess: AgentPID? = nil,
    editor: TerminalLineEditor? = nil,
    terminal: TerminalWriter
  ) async -> Bool {
    let parts = input.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
    let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

    switch parts[0] {
    case "/exit", "/quit":
      return true
    case "/version":
      await terminal.line(version)
    case "/help":
      switch argument.lowercased() {
      case "":
        await terminal.line(replHelp)
      case "set", "/set":
        await terminal.line(setHelp)
      case "memory", "/memory":
        await terminal.line(memoryHelp)
      case "todo", "/todo":
        await terminal.line(todoHelp)
      case "prompt", "prompts", "/prompt", "/prompts":
        await terminal.line(promptHelp)
      case "agents", "agent", "/agents", "/agent":
        await terminal.line(agentsHelp)
      case "mcp", "/mcp":
        await terminal.line(mcpCommandHelp)
      case "chat", "/chat":
        await terminal.line(chatHelp)
      case "edit", "/edit":
        await terminal.line(editHelp)
      case "tools", "/tools":
        await terminal.line(toolHelp)
      case "queue", "/queue":
        await terminal.line(queueHelp)
      case "export", "/export":
        await terminal.line(exportHelp)
      case "import", "/import":
        await terminal.line(importHelp)
      case "reply", "/reply":
        await terminal.line(replyHelp)
      case "copy", "/copy":
        await terminal.line(copyHelp)
      case "stats", "/stats":
        await terminal.line(statsHelp)
      case "skills", "skill", "/skills", "/skill":
        await terminal.line(skillsHelp)
      default:
        await terminal.line(
          "Unknown help topic '\(argument)'. Try /help, or /help set, memory, todo, prompts, agents, mcp, chat, edit, tools, skills, queue, export, import, copy, or stats."
        )
      }
    case "/cwd", "/pwd":
      await terminal.line(FileManager.default.currentDirectoryPath)
    case "/cd":
      await changeWorkingDirectory(argument, terminal: terminal)
    case "/nothink":
      await handleEffortCommand(
        "off", session: &session, runtime: runtime, configuration: &configuration,
        configurationPath: visual.configurationPath, terminal: terminal)
    case "/set":
      await handleSetCommand(
        argument,
        session: &session,
        runtime: runtime,
        approvalHandler: visual.approvalHandler,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/providers":
      for provider in await runtime.availableProviders() {
        let selected = provider.id == session.profile.provider ? "*" : " "
        let baseURL =
          (visual.providerBaseURLs.url(for: provider.id.rawValue)
          ?? configuration?.providers.first { $0.id == provider.id.rawValue }?.baseURL)
          .map { " — \($0.absoluteString)" } ?? ""
        await terminal.line("\(selected) \(provider.id) — \(provider.displayName)\(baseURL)")
      }
    case "/plugins":
      for plugin in await plugins.installedPlugins() {
        let capabilities = plugin.manifest.capabilities.map(\.rawValue).sorted().joined(
          separator: ", ")
        let origin = plugin.origin.map { " — \($0)" } ?? ""
        await terminal.line(
          "\(plugin.manifest.id) \(plugin.manifest.version) [\(capabilities)]\(origin)")
      }
    case "/models":
      let providerID = argument.isEmpty ? session.profile.provider : ProviderID(argument)
      do {
        let models = try await runtime.availableModels(provider: providerID)
        if models.isEmpty {
          await terminal.line("Provider '\(providerID)' returned no models.")
        }
        for model in models {
          let selected =
            providerID == session.profile.provider && model.id == session.profile.model
            ? "*" : " "
          let owner = model.ownedBy.map { " — \($0)" } ?? ""
          let label =
            model.displayName == model.id ? model.id : "\(model.id) (\(model.displayName))"
          await terminal.line("\(selected) \(label)\(owner)")
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "/btw":
      await handleBTWCommand(argument, session: session, runtime: runtime, terminal: terminal)
    case "/todo":
      await handleTodoCommand(argument, todo: visual.todo, terminal: terminal)
    case "/skills", "/skill":
      await handleSkillsCommand(
        argument,
        session: &session,
        runtime: runtime,
        skills: visual.skills,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/memory":
      await handleMemoryCommand(
        argument,
        session: session,
        runtime: runtime,
        memory: visual.memory,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/prompts":
      // The REPL loop answers /prompts before it gets here, so a prompt can
      // be sent; from anywhere else the catalog is listed and kept.
      switch await handlePromptsCommand(
        argument,
        session: session,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        skills: visual.skills.catalog,
        terminal: terminal)
      {
      case .handled:
        break
      case .send, .selectSystemPrompt:
        await terminal.line("Use $NAME [TEXT] or /prompts NAME [TEXT] at the chat prompt.")
      }
    case "/prompt":
      await handlePromptCommand(
        argument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        skills: visual.skills.catalog,
        terminal: terminal)
    case "/chat":
      await handleChatCommand(
        argument,
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        chatProcess: chatProcess,
        terminal: terminal)
    case "/edit":
      await handleEditCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        memory: visual.memory,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs,
        terminal: terminal)
    case "/provider":
      await handleProviderCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs,
        terminal: terminal)
    case "/baseurl":
      await handleBaseURLCommand(
        argument,
        currentProvider: session.profile.provider,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs,
        terminal: terminal)
    case "/model":
      if argument.isEmpty {
        await terminal.line(
          session.profile.model.isEmpty ? "No model selected." : "Model: \(session.profile.model)")
      } else {
        session.profile.model = argument
        let saved = await persistAgentProfile(
          session: session,
          configuration: &configuration,
          configurationPath: visual.configurationPath,
          runtime: runtime,
          terminal: terminal)
        if saved {
          await terminal.line("Model: \(argument) (saved for agent \(session.profile.agentID))")
        }
      }
    case "/agents":
      await handleAgentsCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs,
        terminal: terminal)
    case "/agent":
      await handleAgentCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs.snapshot(),
        terminal: terminal)
    case "/tools":
      await handleToolsCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/mcp":
      await handleMCPCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        catalogs: &catalogs,
        terminal: terminal)
    case "/mcps":
      await handleMCPCommand(
        "list",
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        catalogs: &catalogs,
        terminal: terminal)
    case "/image":
      let imageArguments = argument.split(
        maxSplits: 1, whereSeparator: \Character.isWhitespace
      ).map(String.init)
      guard imageArguments.count == 2,
        let mode = ImageAttachmentMode(rawValue: imageArguments[0].lowercased())
      else {
        await terminal.line("Usage: /image <tiny|small|medium|big|full|ocr> PATH")
        return false
      }
      do {
        let path = imageArguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        session.pendingContent.append(
          try await imageContent(path: path, mode: mode, ocrProvider: ocrProvider))
        if mode == .ocr {
          let markdownName = (path as NSString).lastPathComponent
          await terminal.line(
            "OCR text queued as \((markdownName as NSString).deletingPathExtension).md")
        } else {
          await terminal.line("Image queued at \(mode.rawValue) size: \(path)")
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "/attach":
      await attachDocument(
        argument,
        session: &session,
        ocrProvider: ocrProvider,
        editor: editor,
        terminal: terminal)
    case "/copy":
      await copyToClipboard(argument, session: session, terminal: terminal)
    case "/export":
      await handleExportCommand(
        argument,
        session: session,
        runtime: runtime,
        process: chatProcess,
        configuration: configuration,
        skills: visual.skills.catalog,
        terminal: terminal)
    case "/import":
      await terminal.line("Use /import PATH at the interactive chat prompt.")
    case "/stats":
      await handleStatsCommand(argument, store: visual.usageStats, terminal: terminal)
    #if PMAI_HAS_VISUAL
      case "/visual":
        await runVisualMode(
          session: &session,
          runtime: runtime,
          plugins: plugins,
          ocrProvider: ocrProvider,
          configuration: &configuration,
          catalogs: &catalogs,
          visual: visual,
          terminal: terminal)
    #endif
    case "/clear":
      session.reset()
      // The agents the cleared runs started leave the table with them, so
      // the next save does not bring them back; running ones stay.
      if let chatProcess { await runtime.supervisor.clearFinished(under: chatProcess) }
      await terminal.line("Conversation cleared.")
    case "/queue":
      await terminal.line("The message queue lives at the terminal prompt.\n" + queueHelp)
    case "/reply":
      await terminal.line(
        "Use /reply at the chat prompt; it opens the last reply quoted in $EDITOR.")
    case "/stop":
      await terminal.line("Use /stop at the chat prompt to interrupt the running turn and keep its queue.")
    case "/continue":
      await terminal.line(
        "Use /continue at the chat prompt; in visual mode, send \"continue\" as a message.")
    default:
      await terminal.line("Unknown command. Type /help.")
    }
    return false
  }

  private static func handleMCPCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    catalogs: inout [MCPServerCatalog],
    terminal: TerminalWriter
  ) async {
    let pieces = argument.split(
      maxSplits: 1, whereSeparator: \Character.isWhitespace
    ).map(String.init)
    let action = pieces.first?.lowercased() ?? "list"
    switch action {
    case "", "list":
      let configured = configuration?.mcpServers ?? []
      let connected = Dictionary(uniqueKeysWithValues: catalogs.map { ($0.serverID, $0) })
      if configured.isEmpty, catalogs.isEmpty {
        await terminal.line("No configured MCP servers.")
        return
      }
      for server in configured {
        let transport =
          server.kind == "stdio"
          ? server.command ?? "stdio" : server.url?.absoluteString ?? server.kind
        let state: String
        if !server.enabled {
          state = "disabled"
        } else if let catalog = connected[server.id] {
          state =
            "connected — \(catalog.tools.count) tools, \(catalog.resources.count) resources, MCP \(catalog.protocolVersion)"
        } else {
          state = "not connected"
        }
        await terminal.line("\(server.id) — \(transport) [\(state)]")
      }
      let configuredIDs = Set(configured.map(\.id))
      for catalog in catalogs where !configuredIDs.contains(catalog.serverID) {
        await terminal.line(
          "\(catalog.serverID) — \(catalog.tools.count) tools, \(catalog.resources.count) resources, MCP \(catalog.protocolVersion) [connected]"
        )
      }

    case "add":
      guard let rawAddArguments = pieces.dropFirst().first else {
        await terminal.line(mcpCommandHelp)
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let server = try parseStdioMCPAddArguments(rawAddArguments)
        guard !draft.mcpServers.contains(where: { $0.id == server.id }) else {
          throw MCPCommandError.duplicateID(server.id)
        }
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: ProcessInfo.processInfo.environment)
        let toolsBefore = Set(await runtime.availableTools().map(\.name))
        let catalog = try await runtime.register(mcp: source)
        let addedTools = Set(await runtime.availableTools().map(\.name)).subtracting(toolsBefore)

        draft.mcpServers.append(server)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        catalogs.append(catalog)
        await terminal.line(
          "Added and connected stdio MCP '\(server.id)'; enabled all \(addedTools.count) tools for every agent."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "enable":
      guard pieces.count == 2 else {
        await terminal.line(mcpCommandHelp)
        return
      }
      let id = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard var draft = configuration, let configurationPath,
        let serverIndex = draft.mcpServers.firstIndex(where: { $0.id == id })
      else {
        await terminal.line("error: MCP server '\(id)' is not configured.", to: .standardError)
        return
      }
      if catalogs.contains(where: { $0.serverID == id }) {
        await terminal.line("MCP server '\(id)' is already enabled and connected.")
        return
      }
      do {
        var server = draft.mcpServers[serverIndex]
        server.enabled = true
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: ProcessInfo.processInfo.environment)
        let toolsBefore = Set(await runtime.availableTools().map(\.name))
        let catalog = try await runtime.register(mcp: source)
        let addedTools = Set(await runtime.availableTools().map(\.name)).subtracting(toolsBefore)
        draft.mcpServers[serverIndex] = server
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        catalogs.append(catalog)
        await terminal.line(
          "Enabled and connected MCP '\(id)'; enabled all \(addedTools.count) tools for every agent."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "disable":
      guard pieces.count == 2 else {
        await terminal.line(mcpCommandHelp)
        return
      }
      let id = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard var draft = configuration, let configurationPath,
        let serverIndex = draft.mcpServers.firstIndex(where: { $0.id == id })
      else {
        await terminal.line("error: MCP server '\(id)' is not configured.", to: .standardError)
        return
      }
      if !draft.mcpServers[serverIndex].enabled {
        await terminal.line("MCP server '\(id)' is already disabled.")
        return
      }
      let namespace = mcpNamespace(for: draft.mcpServers[serverIndex])
      let registeredTools = Set(await runtime.availableTools().map(\.name))
      let removedTools = registeredTools.filter { $0.hasPrefix("\(namespace)::") }
      draft.mcpServers[serverIndex].enabled = false
      for index in draft.agents.indices {
        draft.agents[index].toolNames.subtract(removedTools)
      }
      var profile = session.profile
      profile.toolNames.subtract(removedTools)
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        _ = await runtime.unregisterMCP(serverID: id)
        for agent in draft.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        session.profile = profile
        configuration = draft
        catalogs.removeAll { $0.serverID == id }
        await terminal.line("Disabled MCP '\(id)' and removed \(removedTools.count) live tools.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      await terminal.line(mcpCommandHelp)
    }
  }

  private static func mcpNamespace(for server: ConfiguredMCPServer) -> String {
    let prefix = server.toolNamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.flatMap { $0.isEmpty ? nil : $0 } ?? server.id
  }

  private static func parseStdioMCPAddArguments(_ arguments: String) throws
    -> ConfiguredMCPServer
  {
    let words = try shellWords(arguments)
    guard !words.isEmpty else { throw MCPCommandError.missingCommand }
    var environment: [String: String] = [:]
    var workingDirectory: String?
    var timeout: TimeInterval?
    var prefix: String?
    var approval = ToolApprovalRequirement.confirm
    var id: String?
    let separatorIndex = words.firstIndex(of: "--")
    let optionWords: ArraySlice<String>
    let commandWords: ArraySlice<String>
    if let separatorIndex {
      var optionsStart = words.startIndex
      if optionsStart < separatorIndex, !words[optionsStart].hasPrefix("-") {
        id = words[optionsStart]
        optionsStart += 1
      }
      optionWords = words[optionsStart..<separatorIndex]
      commandWords = words[words.index(after: separatorIndex)...]
    } else {
      optionWords = []
      commandWords = words[...]
    }

    var index = optionWords.startIndex
    while index < optionWords.endIndex {
      switch optionWords[index] {
      case "--name":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--name")
        }
        id = optionWords[index]
        index += 1
      case "--env":
        index += 1
        guard index < optionWords.endIndex,
          let separator = optionWords[index].firstIndex(of: "="),
          separator != optionWords[index].startIndex
        else { throw MCPCommandError.invalidEnvironment }
        environment[String(optionWords[index][..<separator])] = String(
          optionWords[index][optionWords[index].index(after: separator)...])
        index += 1
      case "--cwd":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--cwd")
        }
        workingDirectory = optionWords[index]
        index += 1
      case "--timeout":
        index += 1
        guard index < optionWords.endIndex,
          let value = TimeInterval(optionWords[index]), value > 0
        else {
          throw MCPCommandError.invalidTimeout
        }
        timeout = value
        index += 1
      case "--prefix":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--prefix")
        }
        prefix = optionWords[index]
        index += 1
      case "--approval":
        index += 1
        guard index < optionWords.endIndex,
          let value = ToolApprovalRequirement(rawValue: optionWords[index].lowercased())
        else { throw MCPCommandError.invalidApproval }
        approval = value
        index += 1
      default:
        throw MCPCommandError.invalidOption(optionWords[index])
      }
    }
    guard let command = commandWords.first, !command.isEmpty else {
      throw MCPCommandError.missingCommand
    }
    let inferredID = URL(fileURLWithPath: command).lastPathComponent
    let resolvedID = id ?? inferredID
    guard !resolvedID.isEmpty else { throw MCPCommandError.missingID }
    guard isValidMCPID(resolvedID) else { throw MCPCommandError.invalidID(resolvedID) }
    return ConfiguredMCPServer(
      id: resolvedID,
      kind: "stdio",
      command: command,
      args: Array(commandWords.dropFirst()),
      env: environment,
      cwd: workingDirectory,
      timeout: timeout,
      toolNamePrefix: prefix,
      defaultApproval: approval)
  }

  private static func isValidMCPID(_ id: String) -> Bool {
    guard id != ".", id != "..",
      id.first.map({ $0.isLetter || $0.isNumber }) == true
    else {
      return false
    }
    return id.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
  }

  private static func resolvedSystemPromptName(
    _ requested: String,
    configuration: MaiConfiguration?
  ) -> String? {
    let names = configuration?.prompts?.system.keys ?? [String: String]().keys
    if names.contains(requested) { return requested }
    let matches = names.filter { $0.caseInsensitiveCompare(requested) == .orderedSame }
    return matches.count == 1 ? matches[0] : nil
  }

  /// `/todo` in full: the same list the `todo_*` tools drive, for the person
  /// at the keyboard. Every action reads the file afresh, so the list an
  /// agent just changed is what gets shown or edited.
  private static func handleTodoCommand(
    _ argument: String,
    todo: TodoState,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    var list = todo.current

    switch action {
    case "", "show", "list":
      await terminal.line(list.listing)

    case "add":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo add TEXT")
        return
      }
      await terminal.line(
        MaiTodoTools.execute(
          name: MaiTodoTools.addName, arguments: ["title": .string(rest)], list: &list))
      await storeTodo(list, in: todo, terminal: terminal)

    case "done", "check":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo done NUMBER|TEXT")
        return
      }
      await terminal.line(
        MaiTodoTools.execute(
          name: MaiTodoTools.doneName, arguments: ["task": .string(rest)], list: &list))
      await storeTodo(list, in: todo, terminal: terminal)

    case "remove", "rm", "delete", "del":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo remove NUMBER|TEXT")
        return
      }
      guard let index = list.index(matching: rest) else {
        await terminal.line(
          list.isEmpty ? "The todo list is empty." : "No todo matched '\(rest)'.\n\(list.listing)")
        return
      }
      guard let removed = list.remove(at: index) else { return }
      await terminal.line("Removed: \(removed.title)\n\(list.listing)")
      await storeTodo(list, in: todo, terminal: terminal)

    case "sweep":
      let removed = list.removeCompleted()
      guard removed > 0 else {
        await terminal.line("No completed todo items.")
        return
      }
      await terminal.line("Removed \(removed) completed todo item\(removed == 1 ? "" : "s").")
      await storeTodo(list, in: todo, terminal: terminal)

    case "edit":
      guard
        let edited = await editTemporaryText(
          list.markdown, suffix: AgentTodoList.filename, terminal: terminal)
      else { return }
      await storeTodo(AgentTodoList(markdown: edited), in: todo, terminal: terminal)

    case "clear":
      await storeTodo(AgentTodoList(), in: todo, terminal: terminal)

    case "path":
      await terminal.line(todo.url?.path ?? AgentTodoList.filename)

    default:
      await terminal.line(todoHelp)
    }
  }

  private static func storeTodo(
    _ list: AgentTodoList,
    in todo: TodoState,
    terminal: TerminalWriter
  ) async {
    do {
      try todo.save(list)
      await terminal.line(
        list.isEmpty
          ? "Todo list cleared."
          : "Todo list saved to \(todo.url?.path ?? AgentTodoList.filename) (\(list.pendingCount) pending, \(list.doneCount) done)."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/memory` in full: read it, edit it, extend it from what was said, and
  /// decide how far the chat tools may look.
  private static func handleMemoryCommand(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let settings = memory.configuration

    switch action {
    case "", "show":
      let current = memory.current
      let state = settings.enabled ? "on" : "off"
      await terminal.line(
        "Memory: \(state) · scope \(settings.scope.rawValue) · \(current.lineCount) line\(current.lineCount == 1 ? "" : "s")"
      )
      await terminal.line(current.isEmpty ? "(empty)" : current.text)

    case "edit":
      guard
        let edited = await editTemporaryText(
          memory.current.text, suffix: "memory.md", terminal: terminal)
      else { return }
      await store(
        AgentMemory(text: edited), in: memory, runtime: runtime, terminal: terminal)

    case "set", "replace":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /memory set TEXT")
        return
      }
      await store(AgentMemory(text: rest), in: memory, runtime: runtime, terminal: terminal)

    case "add", "append":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /memory add TEXT")
        return
      }
      var updated = memory.current
      updated.append(rest)
      await store(updated, in: memory, runtime: runtime, terminal: terminal)

    case "clear", "forget":
      await store(AgentMemory(), in: memory, runtime: runtime, terminal: terminal)

    case "reload":
      memory.reload()
      await runtime.configureMemory(memory.promptSection)
      await terminal.line("Reloaded \(memory.url?.path ?? AgentMemory.filename).")

    case "learn":
      await learnMemory(
        rest,
        session: session,
        runtime: runtime,
        memory: memory,
        promptTemplate: configuration?.prompts?.memory,
        terminal: terminal)

    case "scope":
      guard !rest.isEmpty else {
        await terminal.line("Memory scope: \(settings.scope.rawValue)")
        return
      }
      guard let scope = MemoryScope(rawValue: rest.lowercased()) else {
        await terminal.line("Usage: /memory scope <none|project|all>")
        return
      }
      await persistMemorySettings(
        ConfiguredMemory(enabled: settings.enabled, scope: scope),
        memory: memory,
        configuration: &configuration,
        configurationPath: configurationPath,
        note:
          "The chat tools now read \(scope == .none ? "nothing" : scope.displayName.lowercased()).",
        terminal: terminal)

    case "on", "off":
      await persistMemorySettings(
        ConfiguredMemory(enabled: action == "on", scope: settings.scope),
        memory: memory,
        configuration: &configuration,
        configurationPath: configurationPath,
        note:
          action == "on"
          ? "Memory is added to the system prompt again."
          : "Memory is kept but no longer sent to the model.",
        terminal: terminal)
      await runtime.configureMemory(memory.promptSection)

    default:
      await terminal.line(memoryHelp)
    }
  }

  private static func store(
    _ updated: AgentMemory,
    in memory: MemoryState,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    do {
      try memory.save(updated)
      await runtime.configureMemory(memory.promptSection)
      await terminal.line(
        updated.isEmpty
          ? "Memory cleared."
          : "Memory saved to \(memory.url?.path ?? AgentMemory.filename) (\(updated.lineCount) line\(updated.lineCount == 1 ? "" : "s"))."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func persistMemorySettings(
    _ settings: ConfiguredMemory,
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    note: String,
    terminal: TerminalWriter
  ) async {
    memory.apply(settings)
    guard var draft = configuration, let configurationPath else {
      await terminal.line("\(note) (not saved: no writable configuration is active.)")
      return
    }
    draft.memory = settings
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line(note)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Folds conversations into the notes. The model is given what is already
  /// known and returns the merged set, so learning never silently forgets.
  private static func learnMemory(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    memory: MemoryState,
    promptTemplate: String?,
    terminal: TerminalWriter
  ) async {
    var focus = argument
    var everyChat = false
    for flag in ["--all", "-a"] where focus == flag || focus.hasPrefix(flag + " ") {
      everyChat = true
      focus = String(focus.dropFirst(flag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let chats =
      everyChat ? memory.projectChats() : [MemoryChat(session.chat, scope: session.title)]
    let transcript = AgentMemoryPrompt.transcript(of: chats)
    guard !transcript.isEmpty else {
      await terminal.line(
        everyChat ? "No conversations in this project yet." : "Nothing said in this chat yet.")
      return
    }
    if let template = promptTemplate,
      let missing = AgentMemoryPrompt.missingPlaceholder(in: template)
    {
      await terminal.line(
        "error: The memory prompt must contain \(missing). Edit it with /edit memory-prompt.",
        to: .standardError)
      return
    }

    let existing = memory.current
    let profile = session.profile
    let request = AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: [
        .user(
          AgentMemoryPrompt.render(
            existing: existing,
            transcript: transcript,
            focus: focus,
            template: promptTemplate))
      ],
      toolChoice: .none,
      options: profile.options,
      limits: profile.limits,
      stream: false,
      sessionID: session.sessionID)
    await terminal.line(
      "Learning from \(everyChat ? "\(chats.count) chat\(chats.count == 1 ? "" : "s")" : "this chat")…"
    )
    do {
      let result = try await runtime.run(request) { _ in }
      let learned = MessageContentFilter.promptSafeText(from: result.response.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !learned.isEmpty else {
        await terminal.line("Nothing durable to remember; memory is unchanged.")
        return
      }
      await store(AgentMemory(text: learned), in: memory, runtime: runtime, terminal: terminal)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/prompts`: every prompt a name can run here, by kind, then the
  /// templates that are not run by name.
  private static func showPrompts(
    session: REPLSession,
    configuration: MaiConfiguration?,
    skills: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async {
    let catalog =
      configuration?.promptCatalog(skills: skills.skills) ?? PromptCatalog(skills: skills.skills)
    let width = max(10, catalog.entries.map { $0.commandName.count }.max() ?? 0)
    func row(_ marker: String, _ name: String, _ detail: String) -> String {
      "\(marker) \(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(detail)"
    }
    var lines = [
      "System prompts — an agent's instructions (/prompt manages them; $NAME switches this agent to one):"
    ]
    let system = catalog.entries(of: .system)
    for entry in system {
      let selected = session.profile.systemPrompt == entry.name ? "*" : " "
      let agents = configuration?.agentsUsingSystemPrompt(entry.name) ?? []
      lines.append(
        row(
          selected, entry.commandName,
          agents.isEmpty ? "unused" : "agents: \(agents.joined(separator: ", "))"))
    }
    if system.isEmpty { lines.append("  None; /prompt add NAME TEXT creates one.") }
    lines.append(
      "User prompts — messages sent by name (prompts.user; /prompts add NAME TEXT, /edit user NAME):"
    )
    let user = catalog.entries(of: .user)
    for entry in user { lines.append(row(" ", entry.commandName, entry.summary)) }
    if user.isEmpty { lines.append("  None yet.") }
    let userCommands = Set(user.map { PromptSlashCommand.normalized($0.commandName) })
    lines.append("Builtin prompts — MaiCore's; a user prompt of the same name replaces one:")
    for entry in catalog.entries(of: .builtin) {
      let replaced = userCommands.contains(PromptSlashCommand.normalized(entry.commandName))
      lines.append(
        row(" ", entry.commandName, replaced ? "replaced by the user prompt above" : entry.summary))
    }
    lines.append("Skills — /skills; $NAME sends one whether or not this agent may call it:")
    let skillEntries = catalog.entries(of: .skill)
    for entry in skillEntries { lines.append(row(" ", entry.commandName, entry.summary)) }
    if skillEntries.isEmpty { lines.append("  None found; /skills path lists the folders read.") }
    let templates: [(String, String?)] = [
      ("compact", configuration?.prompts?.compact),
      ("delegation", configuration?.prompts?.delegation),
      ("worker", configuration?.prompts?.worker),
      ("memory", configuration?.prompts?.memory),
    ]
    lines.append(
      "Templates — not sent by name; /edit compact, /edit delegation, /edit worker, /edit memory-prompt:"
    )
    for (name, text) in templates {
      let custom = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      lines.append(row(" ", name, custom ? "custom" : "built-in"))
    }
    lines.append(
      "$NAME [TEXT] sends a prompt with TEXT after it (/prompts NAME [TEXT] is the long form); /prompts show NAME prints one."
    )
    await terminal.line(lines.joined(separator: "\n"))
  }

  /// What the REPL loop does after `/prompts`: nothing more, send a
  /// message, or switch the agent to a system prompt and then send one.
  private enum PromptsCommandOutcome {
    case handled
    case send(String, title: String)
    case selectSystemPrompt(String, then: String?)
  }

  /// `/prompts` — and `$`, its short form — in full: the catalog listed, one
  /// prompt shown, user prompts kept from one line, and a name with words
  /// after it sent as a message. A system prompt is not a message: the agent
  /// is switched to it, and the words after the name are sent as they are.
  private static func handlePromptsCommand(
    _ argument: String,
    session: REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    skills: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async -> PromptsCommandOutcome {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let catalog =
      configuration?.promptCatalog(skills: skills.skills) ?? PromptCatalog(skills: skills.skills)

    switch action.lowercased() {
    case "", "list", "ls":
      await showPrompts(
        session: session, configuration: configuration, skills: skills, terminal: terminal)

    case "help":
      await terminal.line(promptHelp)

    case "show", "cat":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompts show NAME")
        return .handled
      }
      guard let entry = catalog.entry(named: rest) else {
        await terminal.line("Unknown prompt '\(rest)'. /prompts lists them.")
        return .handled
      }
      let heading: String
      let text: String
      switch entry.kind {
      case .system:
        let users = configuration?.agentsUsingSystemPrompt(entry.name) ?? []
        heading =
          "System prompt '\(entry.name)' — \(users.isEmpty ? "unused" : "agents: \(users.joined(separator: ", "))"); $\(entry.commandName) [TEXT] switches this agent to it."
        text = entry.text
      case .skill:
        heading = "Skill '\(entry.name)' — \(entry.summary); $\(entry.commandName) [TEXT] sends:"
        text = entry.message(arguments: "") ?? entry.text
      case .user, .builtin:
        let label = entry.kind.label.prefix(1).uppercased() + entry.kind.label.dropFirst()
        heading = "\(label) '\(entry.name)'; $\(entry.commandName) [TEXT] sends:"
        text = entry.text
      }
      await terminal.line(heading)
      await terminal.line(text.isEmpty ? "(empty)" : text)

    case "add", "set", "new", "create":
      let parts = rest.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
      guard parts.count == 2 else {
        await terminal.line("Usage: /prompts \(action) NAME TEXT")
        return .handled
      }
      await storeUserPrompt(
        named: parts[0],
        text: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "edit":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompts edit NAME   (/edit user NAME is the same)")
        return .handled
      }
      await editUserPrompt(
        named: rest,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "remove", "rm", "delete", "del":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompts rm NAME")
        return .handled
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return .handled
      }
      guard let name = draft.userPromptName(matching: rest) else {
        let hint =
          catalog.entry(named: rest).map {
            switch $0.kind {
            case .system: " '\(rest)' is a system prompt: /prompt rm drops one."
            case .builtin:
              " '\(rest)' is a builtin prompt, which stays; a user prompt of that name replaces it."
            case .skill: " '\(rest)' is a skill: remove its folder (/skills path)."
            case .user: ""
            }
          } ?? ""
        await terminal.line("Unknown user prompt '\(rest)'. /prompts lists them.\(hint)")
        return .handled
      }
      draft.removeUserPrompt(name)
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        let command = PromptSlashCommand.commandName(for: name)
        let uncovered = UserPrompt.builtins.contains {
          PromptSlashCommand.normalized($0.commandName) == PromptSlashCommand.normalized(command)
        }
        await terminal.line(
          "Removed user prompt '\(name)'."
            + (uncovered ? " The builtin prompt of that name is back." : ""))
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      guard let entry = catalog.entry(named: action) else {
        await terminal.line(
          "Unknown prompt '\(action)'. /prompts lists them; a message that starts with $ can be sent inside <<EOF."
        )
        return .handled
      }
      switch entry.kind {
      case .system:
        return .selectSystemPrompt(entry.name, then: rest.isEmpty ? nil : rest)
      case .user, .builtin, .skill:
        return .send(entry.message(arguments: rest) ?? rest, title: "\(entry.name) \(rest)")
      }
    }
    return .handled
  }

  @discardableResult
  private static func storeUserPrompt(
    named name: String,
    text: String,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async -> Bool {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      await terminal.line("A user prompt needs a name.")
      return false
    }
    let created = draft.setUserPrompt(trimmedName, text: text)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      let command = PromptSlashCommand.commandName(for: trimmedName)
      let replaces = UserPrompt.builtins.contains {
        PromptSlashCommand.normalized($0.commandName) == PromptSlashCommand.normalized(command)
      }
      await terminal.line(
        "\(created ? "Created" : "Saved") user prompt '\(trimmedName)': $\(command) [TEXT] sends it"
          + (replaces ? " instead of the builtin prompt of that name." : "."))
      return true
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return false
    }
  }

  /// Opens a user prompt in the editor; a new one named like a builtin
  /// prompt starts from the builtin's text, which is how one is adjusted.
  private static func editUserPrompt(
    named requested: String,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /edit user NAME")
      return
    }
    let name = configuration?.userPromptName(matching: trimmed) ?? trimmed
    let command = PromptSlashCommand.normalized(PromptSlashCommand.commandName(for: name))
    let previous =
      configuration?.prompts?.user[name]
      ?? UserPrompt.builtins.first { PromptSlashCommand.normalized($0.commandName) == command }?
      .text ?? ""
    guard
      let edited = await editTemporaryText(previous, suffix: "user-prompt.md", terminal: terminal)
    else { return }
    await storeUserPrompt(
      named: name,
      text: edited.trimmingCharacters(in: .whitespacesAndNewlines),
      configuration: &configuration,
      configurationPath: configurationPath,
      terminal: terminal)
  }

  /// `/prompt` in full: named system prompts are created, edited, dropped,
  /// and pointed at from one line each; the bare name still selects one for
  /// the current agent.
  private static func handlePromptCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    skills: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

    switch action {
    case "":
      let name = session.profile.systemPrompt ?? "inline"
      await terminal.line("System prompt for agent '\(session.profile.agentID)': \(name)")
      await terminal.line(
        session.profile.instructions.isEmpty ? "(empty)" : session.profile.instructions)

    case "list", "ls":
      await showPrompts(
        session: session, configuration: configuration, skills: skills, terminal: terminal)

    case "show", "cat":
      let requested = rest.isEmpty ? session.profile.systemPrompt ?? "" : rest
      guard let name = resolvedSystemPromptName(requested, configuration: configuration),
        let text = configuration?.prompts?.system[name]
      else {
        await terminal.line("Unknown system prompt '\(requested)'. /prompts lists them.")
        return
      }
      let users = configuration?.agentsUsingSystemPrompt(name) ?? []
      await terminal.line(
        "System prompt '\(name)' — \(users.isEmpty ? "unused" : "agents: \(users.joined(separator: ", "))")"
      )
      await terminal.line(text.isEmpty ? "(empty)" : text)

    case "add", "set", "new", "create":
      let parts = rest.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
      guard parts.count == 2 else {
        await terminal.line("Usage: /prompt \(action) NAME TEXT")
        return
      }
      await storeSystemPrompt(
        named: parts[0],
        text: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "edit":
      await editSystemPrompt(
        named: rest.isEmpty ? session.profile.systemPrompt ?? session.profile.agentID : rest,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "remove", "rm", "delete", "del":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompt rm NAME")
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      guard let name = resolvedSystemPromptName(rest, configuration: draft) else {
        await terminal.line("Unknown system prompt '\(rest)'. /prompts lists them.")
        return
      }
      let users = draft.agentsUsingSystemPrompt(name)
      guard users.isEmpty else {
        await terminal.line(
          "System prompt '\(name)' is used by \(users.joined(separator: ", ")). Point them elsewhere first: /agent prompt ID OTHER."
        )
        return
      }
      draft.removeSystemPrompt(name)
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line("Removed system prompt '\(name)'.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "use", "select":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompt use NAME")
        return
      }
      await selectSystemPrompt(
        rest,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "help":
      await terminal.line(promptHelp)

    default:
      // `/prompt NAME` keeps selecting a prompt for the current agent.
      await selectSystemPrompt(
        argument.trimmingCharacters(in: .whitespacesAndNewlines),
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    }
  }

  /// Points the current agent at a named prompt and saves the association.
  private static func selectSystemPrompt(
    _ requested: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard
      let name = resolvedSystemPromptName(requested, configuration: configuration),
      let instructions = configuration?.prompts?.system[name]
    else {
      await terminal.line(
        "Unknown system prompt '\(requested)'. /prompts lists them; /prompt add NAME TEXT creates one."
      )
      return
    }
    let previous = session.profile.instructions
    do {
      try applySystemInstructions(instructions, replacing: previous, session: &session)
      session.profile.systemPrompt = name
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line(
        "Agent '\(session.profile.agentID)' now uses system prompt '\(name)'.")
    }
  }

  /// Writes one named system prompt and refreshes every agent that uses it,
  /// in the file, in the live runtime, and in this chat when it is one of
  /// them. Answers false, having said why, when nothing was saved.
  @discardableResult
  private static func storeSystemPrompt(
    named name: String,
    text: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async -> Bool {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      await terminal.line("A system prompt needs a name.")
      return false
    }
    let created = draft.prompts?.system[name] == nil
    let refreshed = draft.setSystemPrompt(name, text: text)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      for agent in draft.agents where refreshed.contains(agent.id) {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      if session.profile.systemPrompt == name {
        try applySystemInstructions(
          text, replacing: session.profile.instructions, session: &session)
      }
      let usage =
        refreshed.isEmpty
        ? "no agent uses it yet; /agent prompt ID \(name) or /agent add picks it"
        : "used by \(refreshed.joined(separator: ", "))"
      await terminal.line("\(created ? "Created" : "Saved") system prompt '\(name)' (\(usage)).")
      return true
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return false
    }
  }

  private static func applySystemInstructions(
    _ instructions: String,
    replacing previous: String,
    session: inout REPLSession
  ) throws {
    session.profile.instructions = instructions
    if let index = session.history.messages.firstIndex(where: {
      $0.role == .system && $0.text == previous
    }) {
      if instructions.isEmpty {
        _ = try session.history.removeMessage(at: index)
      } else {
        try session.history.editMessage(at: index, text: instructions)
      }
    } else if !instructions.isEmpty {
      session.history.replaceAll(with: [.system(instructions)] + session.history.messages)
    }
    session.touch()
  }

  private static func editSystemPrompt(
    named requested: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /prompt edit [NAME]")
      return
    }
    let name = resolvedSystemPromptName(trimmed, configuration: configuration) ?? trimmed
    let previous = configuration?.prompts?.system[name] ?? ""
    guard
      let edited = await editTemporaryText(
        previous, suffix: "system-prompt.md", terminal: terminal)
    else { return }
    await storeSystemPrompt(
      named: name,
      text: edited.trimmingCharacters(in: .whitespacesAndNewlines),
      session: &session,
      runtime: runtime,
      configuration: &configuration,
      configurationPath: configurationPath,
      terminal: terminal)
  }

  private static func shellWords(_ input: String) throws -> [String] {
    enum Quote { case single, double }
    var words: [String] = []
    var word = ""
    var quote: Quote?
    var escaped = false
    var started = false
    for character in input {
      if escaped {
        word.append(character)
        escaped = false
        started = true
        continue
      }
      if character == "\\", quote != .single {
        escaped = true
        started = true
        continue
      }
      if character == "'", quote != .double {
        quote = quote == .single ? nil : .single
        started = true
        continue
      }
      if character == "\"", quote != .single {
        quote = quote == .double ? nil : .double
        started = true
        continue
      }
      if character.isWhitespace, quote == nil {
        if started {
          words.append(word)
          word = ""
          started = false
        }
        continue
      }
      word.append(character)
      started = true
    }
    guard quote == nil else { throw MCPCommandError.unterminatedQuote }
    guard !escaped else { throw MCPCommandError.danglingEscape }
    if started { words.append(word) }
    return words
  }

  /// Opens a text value from the active REPL session in the user's terminal
  /// editor. Transcript and configuration edits deliberately go through the
  /// same core types used by the iOS app and the persistent chat workspace.
  private static func handleEditCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let target = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      await terminal.line(editHelp)
      return
    }
    let fields = target.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields[0].lowercased()
    let actionArgument = fields.count == 2 ? fields[1] : ""

    switch action {
    case "system":
      await editSystemPrompt(
        named: actionArgument.isEmpty
          ? session.profile.systemPrompt ?? session.profile.agentID : actionArgument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "user", "userprompt":
      guard !actionArgument.isEmpty else {
        await terminal.line("Usage: /edit user NAME")
        return
      }
      await editUserPrompt(
        named: actionArgument,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "prompt":
      // Without a name, the current agent's system prompt. With one, the
      // prompt of that name, whichever kind it is; a system prompt and a
      // user prompt are different things, so a new one is created with
      // /edit system NAME or /edit user NAME.
      guard !actionArgument.isEmpty else {
        await editSystemPrompt(
          named: session.profile.systemPrompt ?? session.profile.agentID,
          session: &session,
          runtime: runtime,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
        return
      }
      let wanted = PromptSlashCommand.normalized(actionArgument)
      if let name = resolvedSystemPromptName(actionArgument, configuration: configuration) {
        await editSystemPrompt(
          named: name,
          session: &session,
          runtime: runtime,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
      } else if let name = configuration?.userPromptName(matching: actionArgument) {
        await editUserPrompt(
          named: name,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
      } else if UserPrompt.builtins.contains(where: {
        PromptSlashCommand.normalized($0.commandName) == wanted
      }) {
        await editUserPrompt(
          named: actionArgument,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
      } else {
        await terminal.line(
          "No prompt named '\(actionArgument)'. /edit system NAME creates a system prompt, /edit user NAME a user prompt; /prompts lists both."
        )
      }

    case "agent":
      await editAgentDefinition(
        named: actionArgument.isEmpty ? session.profile.agentID : actionArgument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "provider":
      await editConfiguredProvider(
        named: actionArgument.isEmpty ? session.profile.provider.rawValue : actionArgument,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)

    case "input":
      // The chat prompt intercepts this one, because the message it writes is
      // sent from there; here it can only say where it works.
      await terminal.line(
        "Use /edit input at the chat prompt; it opens an empty file and sends what you write in it."
      )

    case "compact":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let previous = draft.prompts?.compact ?? defaultCompactPrompt
      guard
        let edited = await editTemporaryText(
          previous, suffix: "compact-prompt.md", terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      guard candidate.isEmpty || candidate.contains("{{transcript}}") else {
        await terminal.line(
          "error: The compact prompt must contain {{transcript}}; no changes were saved.",
          to: .standardError)
        return
      }
      let customPrompt =
        candidate.isEmpty || candidate == defaultCompactPrompt ? nil : candidate
      var prompts = draft.prompts ?? ConfiguredPrompts()
      prompts.compact = customPrompt
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        await runtime.configureCompaction(prompt: customPrompt)
        configuration = draft
        await terminal.line(
          customPrompt == nil
            ? "Compact prompt restored to the built-in default."
            : "Compact prompt saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "memory":
      guard
        let edited = await editTemporaryText(
          memory.current.text, suffix: "memory.md", terminal: terminal)
      else { return }
      await store(AgentMemory(text: edited), in: memory, runtime: runtime, terminal: terminal)

    case "memory-prompt", "learn":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      var prompts = draft.prompts ?? ConfiguredPrompts()
      guard
        let edited = await editTemporaryText(
          prompts.memory ?? AgentMemoryPrompt.template,
          suffix: "memory-prompt.md",
          terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      if let missing = AgentMemoryPrompt.missingPlaceholder(in: candidate) {
        await terminal.line(
          "error: The memory prompt must contain \(missing); no changes were saved.",
          to: .standardError)
        return
      }
      prompts.memory =
        candidate.isEmpty || candidate == AgentMemoryPrompt.template ? nil : candidate
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line(
          prompts.memory == nil
            ? "The memory prompt was restored to the built-in default."
            : "The memory prompt was saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "delegation", "worker":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      var prompts = draft.prompts ?? ConfiguredPrompts()
      let isBrief = action == "delegation"
      let builtIn =
        isBrief ? AgentDelegationPrompt.template : AgentDelegationPrompt.workerInstructions
      let previous = (isBrief ? prompts.delegation : prompts.worker) ?? builtIn
      guard
        let edited = await editTemporaryText(
          previous, suffix: "\(action)-prompt.md", terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      if isBrief, let missing = AgentDelegationPrompt.missingPlaceholder(in: candidate) {
        await terminal.line(
          "error: The delegation prompt must contain \(missing); no changes were saved.",
          to: .standardError)
        return
      }
      let custom = candidate.isEmpty || candidate == builtIn ? nil : candidate
      if isBrief { prompts.delegation = custom } else { prompts.worker = custom }
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        await runtime.configureDelegation(
          prompt: prompts.delegation, workerInstructions: prompts.worker)
        configuration = draft
        await terminal.line(
          custom == nil
            ? "The \(action) prompt was restored to the built-in default."
            : "The \(action) prompt was saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "config":
      guard let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let url = URL(fileURLWithPath: configurationPath)
      guard await launchEditor(at: url, terminal: terminal) else { return }
      do {
        var editedConfiguration = try MaiConfiguration.load(from: url)
        if editedConfiguration.associateSystemPrompts() {
          try editedConfiguration.save(to: url)
        }
        for agent in editedConfiguration.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        await runtime.configureDelegation(
          prompt: editedConfiguration.prompts?.delegation,
          workerInstructions: editedConfiguration.prompts?.worker)
        await runtime.configureCompaction(prompt: editedConfiguration.prompts?.compact)
        if let agent = editedConfiguration.agents.first(where: {
          $0.id == session.profile.agentID
        }) {
          session.profile.limits = agent.limits
          session.profile.toolCallingStrategy = agent.toolCallingStrategy
          session.profile.toolDelegation = agent.toolDelegation
          session.profile.retry = agent.retry
          session.profile.autocompact = agent.autocompact
          session.profile.systemPrompt = agent.systemPrompt
          try applySystemInstructions(
            agent.instructions,
            replacing: session.profile.instructions,
            session: &session)
        }
        configuration = editedConfiguration
        await terminal.line(
          "Configuration saved. Agent limits and tool-calling strategy were applied; "
            + "restart pmai to apply provider, plugin, tool, or MCP changes.")
      } catch {
        await terminal.line(
          "error: The edited configuration was not loaded: \(error.localizedDescription)",
          to: .standardError)
      }

    case "mcps", "mcp":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft.mcpServers)
        guard let edited = await editTemporaryData(data, suffix: "mcps.json", terminal: terminal)
        else {
          return
        }
        draft.mcpServers = try JSONDecoder().decode([ConfiguredMCPServer].self, from: edited)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line("MCP configuration saved. Restart pmai to reconnect MCP servers.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      if let name = resolvedSystemPromptName(target, configuration: configuration) {
        await editSystemPrompt(
          named: name,
          session: &session,
          runtime: runtime,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
        return
      }
      if let name = configuration?.userPromptName(matching: target) {
        await editUserPrompt(
          named: name,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
        return
      }
      guard let index = editableMessageIndex(target, in: session.history) else {
        await terminal.line("Unknown edit target '\(target)'.\n\n\(editHelp)")
        return
      }
      let message = session.history[index]
      guard
        let edited = await editTemporaryText(message.text, suffix: "message.md", terminal: terminal)
      else { return }
      do {
        try session.history.editMessage(at: index, text: edited)
        await terminal.line("Edited message \(index + 1) (id: \(message.id)).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    }
  }

  private static func editableMessageIndex(_ target: String, in transcript: AgentTranscript) -> Int?
  {
    if let index = chatIndex(target, count: transcript.count) { return index }
    return transcript.index(ofMessageID: target)
  }

  private static func editTemporaryText(
    _ text: String, suffix: String, terminal: TerminalWriter
  ) async -> String? {
    guard let data = text.data(using: .utf8),
      let edited = await editTemporaryData(data, suffix: suffix, terminal: terminal)
    else { return nil }
    guard let result = String(data: edited, encoding: .utf8) else {
      await terminal.line("error: Editor output must be UTF-8 text.", to: .standardError)
      return nil
    }
    return result
  }

  private static func editTemporaryData(
    _ data: Data, suffix: String, terminal: TerminalWriter
  ) async -> Data? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pmai-edit-\(UUID().uuidString)-\(suffix)")
    do {
      try data.write(to: url, options: .atomic)
      defer { try? FileManager.default.removeItem(at: url) }
      guard await launchEditor(at: url, terminal: terminal) else { return nil }
      return try Data(contentsOf: url)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return nil
    }
  }

  /// The editor every `/edit` hands the terminal to: `/set ui.editor` when it
  /// is set, then `$EDITOR`, `$VISUAL`, and vim as the last resort.
  private static let editorLock = NSLock()
  nonisolated(unsafe) private static var configuredEditor = ""

  static func configureEditor(_ command: String) {
    editorLock.withLock {
      configuredEditor = command.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  static func resolvedEditor(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    let configured = editorLock.withLock { configuredEditor }
    for candidate in [configured, environment["EDITOR"] ?? "", environment["VISUAL"] ?? ""] {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return "vim"
  }

  private static func launchEditor(at url: URL, terminal: TerminalWriter) async -> Bool {
    let command = resolvedEditor()
    let shellCommand = "\(command) \(shellQuote(url.path))"
    var waitStatus: CInt = -1
    let launch = { waitStatus = shellCommand.withCString(posixSystem) }
    if let screen = TerminalScreen.current {
      screen.suspendTerminal(launch)
    } else {
      launch()
    }
    guard waitStatus != -1 else {
      await terminal.line(
        "error: Could not launch editor '\(command)': \(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription)",
        to: .standardError)
      return false
    }
    let exitStatus = waitStatus & 0x7f == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
    guard exitStatus == 0 else {
      await terminal.line(
        "error: Editor exited with status \(exitStatus).", to: .standardError)
      return false
    }
    return true
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  private static func handleProviderCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard !fields.isEmpty else {
      let configured = configuration?.providers.first {
        $0.id == session.profile.provider.rawValue
      }
      let baseURL =
        providerBaseURLs.url(for: session.profile.provider.rawValue)?.absoluteString
        ?? configured?.baseURL?.absoluteString ?? "-"
      await terminal.line("Current provider: \(session.profile.provider) — \(baseURL)")
      if let configured {
        let names = (Array(configured.headers.keys) + Array(configured.headerEnvironment.keys))
          .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if !names.isEmpty {
          await terminal.line("Headers: \(names.joined(separator: ", "))")
        }
      }
      await terminal.line(
        "Use /baseurl URL to change its endpoint, or /edit provider to edit it as JSON.")
      return
    }

    if ["baseurl", "url"].contains(fields[0].lowercased()) {
      await handleBaseURLCommand(
        fields.dropFirst().joined(separator: " "),
        currentProvider: session.profile.provider,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)
      return
    }

    let selectedID = fields[0].lowercased() == "use" && fields.count == 2 ? fields[1] : fields[0]
    let id = ProviderID(selectedID)
    guard await runtime.availableProviders().contains(where: { $0.id == id }) else {
      await terminal.line("Unknown provider '\(selectedID)'. Use /providers.")
      return
    }
    session.profile.provider = id
    let saved = await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    if saved {
      await terminal.line("Provider: \(id) (saved for agent \(session.profile.agentID))")
    }
  }

  private static func handleBaseURLCommand(
    _ argument: String,
    currentProvider: ProviderID,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard !fields.isEmpty else {
      let configuredURL = configuration?.providers.first {
        $0.id == currentProvider.rawValue
      }?.baseURL
      let effectiveURL = providerBaseURLs.url(for: currentProvider.rawValue) ?? configuredURL
      var detail = effectiveURL?.absoluteString ?? "-"
      if let effectiveURL, let configuredURL, effectiveURL != configuredURL {
        detail += " (runtime override; configured: \(configuredURL.absoluteString))"
      }
      await terminal.line("Base URL for '\(currentProvider)': \(detail)")
      await terminal.line("Usage: /baseurl URL")
      return
    }

    guard fields.count == 1 else {
      await terminal.line("Usage: /baseurl URL")
      return
    }
    let providerID = currentProvider
    let rawURL = fields[0]
    guard let baseURL = URL(string: rawURL),
      ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
      baseURL.host != nil
    else {
      await terminal.line("Invalid provider URL '\(rawURL)'; use an http:// or https:// URL.")
      return
    }
    guard var draft = configuration,
      let index = draft.providers.firstIndex(where: { $0.id == providerID.rawValue })
    else {
      await terminal.line("Unknown configured provider '\(providerID)'. Use /providers.")
      return
    }
    guard let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.providers[index].baseURL = baseURL
    do {
      let provider = try await plugins.makeProvider(
        from: draft.providers[index],
        environment: ProcessInfo.processInfo.environment)
      try await runtime.register(provider, replacingExisting: true)
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      providerBaseURLs.set(baseURL, for: providerID.rawValue)
      await terminal.line("Provider '\(providerID)' base URL set to \(baseURL.absoluteString).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/agents` covers both halves of the model: the definitions people switch
  /// between, and the processes started from them.
  private static func handleAgentsCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""

    switch action {
    case "", "list":
      await listAgentDefinitions(
        session: session,
        runtime: runtime,
        configuration: configuration,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)
      if action.isEmpty {
        let lines = await agentTreeLines(runtime: runtime)
        if !lines.isEmpty {
          await terminal.line("")
          await terminal.line(lines.joined(separator: "\n"))
        }
      }

    case "enable", "disable":
      guard fields.count >= 2 else {
        await terminal.line("Usage: /agents \(action) ID")
        return
      }
      await setAgentEnabled(
        fields[1],
        enabled: action == "enable",
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "describe":
      guard fields.count >= 2 else {
        await terminal.line("Usage: /agents describe ID [TEXT]")
        return
      }
      await describeAgent(
        fields[1],
        text: fields.count > 2 ? fields[2] : nil,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "use", "show", "add", "new", "create", "acp", "tools", "model", "prompt", "provider",
      "remove", "rm", "delete", "del":
      await handleAgentCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        providerBaseURLs: providerBaseURLs.snapshot(),
        terminal: terminal)

    default:
      if await !handleProcessCommand(argument, runtime: runtime, terminal: terminal) {
        await terminal.line(agentsHelp)
      }
    }
  }

  /// The `/agents` subcommands that act on a running process rather than on
  /// a definition; `/agent` accepts them too, and they stay usable while a
  /// turn runs. `focus` is not here because it lives in the REPL loop's state.
  private static let processActions: Set<String> = [
    "tree", "ps", "log", "kill", "stop", "pause", "suspend", "continue", "cont", "resume",
    "clear",
  ]

  static func isProcessCommand(_ argument: String) -> Bool {
    let action = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).first
    return action.map { processActions.contains($0.lowercased()) } ?? false
  }

  /// Runs one process subcommand. Answers false when the argument is not one,
  /// so the caller can fall back to its own handling.
  private static func handleProcessCommand(
    _ argument: String,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async -> Bool {
    let fields = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    guard processActions.contains(action) else { return false }

    switch action {
    case "tree", "ps":
      let lines = await agentTreeLines(runtime: runtime)
      await terminal.line(lines.isEmpty ? "No agents are running." : lines.joined(separator: "\n"))

    case "clear":
      // The REPL loop handles this itself so its chat pids follow; this is
      // the path from visual mode, which holds no pids.
      let cleared = await runtime.supervisor.clearFinished()
      await terminal.line(
        cleared.isEmpty
          ? "No finished agents to clear."
          : "Cleared \(cleared.count) finished agent\(cleared.count == 1 ? "" : "s").")

    case "log":
      guard fields.count >= 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /agents log PID")
        return true
      }
      let messages = await runtime.supervisor.transcript(pid)
      guard !messages.isEmpty else {
        let known = await runtime.supervisor.info(pid) != nil
        await terminal.line(
          known ? "\(pid) has not produced a transcript yet." : "No agent \(pid).")
        return true
      }
      var lines: [String] = []
      for (index, message) in messages.enumerated() {
        lines.append("## [\(index + 1)] \(message.role.rawValue.capitalized)")
        lines.append(message.content.map { renderFullContent($0) }.joined(separator: "\n"))
      }
      await terminal.line(lines.joined(separator: "\n"))

    case "kill":
      guard fields.count >= 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /agents kill PID [REASON]")
        return true
      }
      guard await runtime.supervisor.info(pid) != nil else {
        await terminal.line("No agent \(pid).")
        return true
      }
      let reason = fields.count > 2 ? fields[2] : "Stopped from the REPL"
      let stopped = await runtime.supervisor.stop(pid, reason: reason)
      await terminal.line(
        "Stopped \(stopped.map(\.description).joined(separator: ", ")).")

    case "stop", "pause", "suspend":
      guard fields.count == 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /agents stop PID")
        return true
      }
      guard let info = await runtime.supervisor.info(pid) else {
        await terminal.line("No agent \(pid).")
        return true
      }
      guard info.depth > 0 else {
        await terminal.line("\(pid) is this chat; Ctrl+C cancels its turn.")
        return true
      }
      guard !info.state.isTerminal else {
        await terminal.line(
          "\(pid) (\(info.agentID)) has finished; /agents log \(pid.rawValue) shows what it did.")
        return true
      }
      let held = await runtime.supervisor.pause(pid)
      guard !held.isEmpty else {
        await terminal.line(
          "\(pid) (\(info.agentID)) is already paused; /agents continue \(pid.rawValue) lets it go on."
        )
        return true
      }
      await terminal.line(
        "Paused \(held.map(\.description).joined(separator: ", ")): it finishes the step it is in, then waits. Messages queued meanwhile are read when /agents continue \(pid.rawValue) lets it go on."
      )

    case "continue", "cont", "resume":
      guard fields.count == 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /agents continue PID")
        return true
      }
      guard let info = await runtime.supervisor.info(pid) else {
        await terminal.line("No agent \(pid).")
        return true
      }
      let released = await runtime.supervisor.resume(pid)
      guard !released.isEmpty else {
        await terminal.line(
          info.state.isTerminal
            ? "\(pid) (\(info.agentID)) has finished; /agents log \(pid.rawValue) shows what it did."
            : "\(pid) (\(info.agentID)) is not paused.")
        return true
      }
      await terminal.line("Continued \(released.map(\.description).joined(separator: ", ")).")

    default:
      return false
    }
    return true
  }

  private static func listAgentDefinitions(
    session: REPLSession,
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let agents: [AgentDefinition]
    if let configured = configuration?.agents {
      agents = configured
    } else {
      agents = await runtime.availableAgents()
    }
    guard !agents.isEmpty else {
      await terminal.line("No configured agents.")
      return
    }
    for agent in agents {
      let isCurrent = agent.id == session.profile.agentID
      let displayed = isCurrent ? session.profile.agentDefinition : agent
      let baseURL =
        providerBaseURLs.url(for: displayed.provider.rawValue)?.absoluteString
        ?? configuration?.providers.first { $0.id == displayed.provider.rawValue }?.baseURL?
        .absoluteString ?? "-"
      let marker = isCurrent ? "*" : (displayed.isEnabled ? " " : "-")
      var line =
        "\(marker) \(displayed.id) — \(displayed.displayName) [\(displayed.provider) \(baseURL) \(displayed.model)]"
      if displayed.toolDelegation.delegatesTools { line += " delegating" }
      if !displayed.isEnabled { line += " (disabled)" }
      await terminal.line(line)
      if !displayed.description.isEmpty {
        await terminal.line("    \(displayed.description)")
      }
    }
  }

  private static func agentTreeLines(runtime: AgentRuntime) async -> [String] {
    let tree = await runtime.supervisor.tree()
    guard !tree.isEmpty else { return [] }
    return ["Running agents:"] + tree.lines() + [agentTreeTotal(tree)]
  }

  /// One row summing what the whole tree has spent so far. Tokens are every
  /// model call's input and output added up, the way a provider bills them,
  /// formatted like the rows above it.
  static func agentTreeTotal(_ tree: AgentProcessTree) -> String {
    let turns = tree.processes.reduce(0) { $0 + $1.modelTurns }
    let tools = tree.processes.reduce(0) { $0 + $1.toolCalls }
    let tokens = tree.processes.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }
    let estimated = tree.processes.contains { $0.usage?.isEstimated == true }
    return
      "Total: \(turns) turn\(turns == 1 ? "" : "s"), \(tools) tool\(tools == 1 ? "" : "s"), \(ModelUsageFormat.tokens(tokens, estimated: estimated))"
  }

  private static func setAgentEnabled(
    _ id: String,
    enabled: Bool,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == id })
    else {
      await terminal.line("Unknown agent '\(id)', or no writable configuration is active.")
      return
    }
    guard enabled || draft.agents[index].id != session.profile.agentID else {
      await terminal.line(
        "Agent '\(id)' is the one this chat uses. Switch with /agent use ID before disabling it.")
      return
    }
    draft.agents[index].isEnabled = enabled
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: draft.agents[index], replacingExisting: true)
      configuration = draft
      await terminal.line("Agent '\(id)' \(enabled ? "enabled" : "disabled").")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func describeAgent(
    _ id: String,
    text: String?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == id })
    else {
      await terminal.line("Unknown agent '\(id)', or no writable configuration is active.")
      return
    }
    guard let text else {
      let existing = draft.agents[index].description
      await terminal.line(existing.isEmpty ? "Agent '\(id)' has no description." : existing)
      return
    }
    draft.agents[index].description = text.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: draft.agents[index], replacingExisting: true)
      if session.profile.agentID == id { session.touch() }
      configuration = draft
      await terminal.line("Described agent '\(id)'.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/agent acp` registers an external ACP agent as a provider-backed agent,
  /// so it is selectable and spawnable like any other. `list` shows the builtin
  /// catalog and what is installed; `add NAME [COMMAND ARGS...]` persists one,
  /// defaulting the command from the catalog when only a known name is given.
  private static func handleAgentACPCommand(
    _ fields: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let sub = fields.first?.lowercased() ?? "list"
    switch sub {
    case "list", "":
      for agent in ACPCatalog.agents {
        let mark = agent.isInstalled ? "\u{2705}" : "\u{274C}"
        let configured = configuration?.providers.contains { $0.id == agent.id } == true
        await terminal.line(
          "\(mark) \(agent.id) — \(agent.summary)\(configured ? " [configured]" : "")")
      }
      await terminal.line(
        "Add one with /agent acp add NAME [COMMAND ARG ...]; a known name needs no command.")

    case "add":
      let rest = Array(fields.dropFirst())
      guard let name = rest.first else {
        await terminal.line("Usage: /agent acp add NAME [COMMAND ARG ...]")
        return
      }
      let provider: ConfiguredProvider
      if rest.count >= 2 {
        var options: [String: JSONValue] = ["command": .string(rest[1])]
        let args = Array(rest.dropFirst(2))
        if !args.isEmpty { options["args"] = .array(args.map(JSONValue.string)) }
        provider = ConfiguredProvider(
          id: name, kind: ACPConfiguredProviderFactory.providerKind, displayName: name,
          options: options)
      } else if let catalog = ACPCatalog.agent(name) {
        provider = catalog.configuredProvider()
        if !catalog.isInstalled, let install = catalog.install {
          await terminal.line("note: '\(name)' is not installed. Install it with: \(install)")
        }
      } else {
        await terminal.line(
          "Unknown ACP agent '\(name)'. Give a command, or use a catalog name (/agent acp list).")
        return
      }
      await registerACPAgent(
        provider,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    default:
      await terminal.line("Usage: /agent acp [list|add NAME [COMMAND ARG ...]]")
    }
  }

  /// Persists an ACP provider and a same-named agent, registers both live, and
  /// selects the agent for the current chat — the same shape `/agent add` uses.
  private static func registerACPAgent(
    _ provider: ConfiguredProvider,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    if let index = draft.providers.firstIndex(where: { $0.id == provider.id }) {
      draft.providers[index] = provider
    } else {
      draft.providers.append(provider)
    }
    let definition = AgentDefinition(
      id: provider.id,
      displayName: provider.displayName ?? provider.id,
      description: ACPCatalog.agent(provider.id)?.summary ?? "External ACP agent.",
      instructions: "",
      provider: ProviderID(provider.id),
      model: provider.id)
    if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
      draft.agents[index] = definition
    } else {
      draft.agents.append(definition)
    }
    do {
      let built = try await plugins.makeProvider(
        from: provider, environment: ProcessInfo.processInfo.environment)
      try await runtime.register(built, replacingExisting: true)
      try await runtime.register(agent: definition, replacingExisting: true)
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      session.reset(profile: SessionProfile(definition: definition))
      await terminal.line(
        "ACP agent '\(provider.id)' registered and selected for this chat. It runs like any other agent."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/agent` in full: switch the chat's agent, or create and maintain saved
  /// definitions with one line each. Process subcommands are accepted too.
  private static func handleAgentCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: [String: URL],
    terminal: TerminalWriter
  ) async {
    let words = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard let action = words.first?.lowercased() else {
      await showAgent(
        session.profile.agentID,
        session: session,
        configuration: configuration,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)
      await terminal.line(
        "Usage: /agent [use] ID · /agent add NAME MODEL GROUPS PROMPT · /help agents")
      return
    }

    if await handleProcessCommand(argument, runtime: runtime, terminal: terminal) {
      return
    }

    if action == "acp" {
      let fields = argument.split(maxSplits: 5, whereSeparator: \Character.isWhitespace).map(
        String.init)
      await handleAgentACPCommand(
        Array(fields.dropFirst()),
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }

    switch action {
    case "add", "new", "create":
      await addAgent(
        Array(words.dropFirst()),
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "show":
      await showAgent(
        words.count > 1 ? words[1] : session.profile.agentID,
        session: session,
        configuration: configuration,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)

    case "tools":
      guard words.count == 3 else {
        await terminal.line(
          "Usage: /agent tools ID GROUPS   (a,b,c replaces; +a,-b adjusts; - clears)")
        return
      }
      guard
        let selection = await resolveToolGroupSpec(
          words[2], runtime: runtime, plugins: plugins, configuration: configuration,
          terminal: terminal)
      else { return }
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, _ in
        selection.apply(to: &definition)
        return nil
      }
      if let saved {
        let groups = saved.toolGroupNames.sorted()
        await terminal.line(
          "Agent '\(saved.id)' tool groups: \(groups.isEmpty ? "none" : groups.joined(separator: ", ")) (\(saved.toolNames.count) tools)."
        )
      }

    case "model":
      guard words.count == 3 else {
        await terminal.line("Usage: /agent model ID MODEL   (- keeps the provider's default)")
        return
      }
      let model = words[2] == "-" ? "" : words[2]
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, _ in
        definition.model = model
        return nil
      }
      if let saved {
        await terminal.line(
          "Agent '\(saved.id)' model: \(saved.model.isEmpty ? "-" : saved.model).")
      }

    case "provider":
      guard words.count == 3 else {
        await terminal.line("Usage: /agent provider ID PROVIDER")
        return
      }
      let providerID = ProviderID(words[2])
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, draft in
        guard draft.providers.contains(where: { $0.id == providerID.rawValue }) else {
          return
            "Unknown provider '\(providerID)'. /providers lists them; /agent add NAME MODEL GROUPS PROMPT PROVIDER BASE_URL registers a new endpoint."
        }
        definition.provider = providerID
        return nil
      }
      if let saved { await terminal.line("Agent '\(saved.id)' provider: \(saved.provider).") }

    case "prompt":
      guard words.count == 3 else {
        await terminal.line("Usage: /agent prompt ID PROMPT")
        return
      }
      let requested = words[2]
      let saved = await updateAgent(
        words[1],
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal
      ) { definition, draft in
        guard let name = resolvedSystemPromptName(requested, configuration: draft),
          let text = draft.prompts?.system[name]
        else {
          return
            "Unknown system prompt '\(requested)'. /prompts lists them; /prompt add NAME TEXT creates one."
        }
        definition.systemPrompt = name
        definition.instructions = text
        return nil
      }
      if let saved {
        await terminal.line(
          "Agent '\(saved.id)' uses system prompt '\(saved.systemPrompt ?? "-")'.")
      }

    case "remove", "rm", "delete", "del":
      guard words.count == 2 else {
        await terminal.line("Usage: /agent remove ID")
        return
      }
      await removeAgent(
        words[1],
        session: session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "use":
      guard words.count == 2 else {
        await terminal.line("Usage: /agent use ID")
        return
      }
      await selectAgent(
        words[1], session: &session, configuration: configuration, terminal: terminal)

    default:
      await selectAgent(
        words[0], session: &session, configuration: configuration, terminal: terminal)
    }
  }

  /// Makes a saved definition this chat's agent, starting the conversation over.
  private static func selectAgent(
    _ id: String,
    session: inout REPLSession,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    guard let definition = configuration?.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. Use /agents.")
      return
    }
    session.reset(profile: SessionProfile(definition: definition))
    await terminal.line(
      "Agent: \(id). It is now the primary agent for chat '\(session.title)'; conversation cleared."
    )
  }

  /// `/agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]`: one line
  /// saves a definition out of things that already exist — a provider, a
  /// named system prompt, tool groups — and a base URL registers a new
  /// OpenAI-compatible provider on the way. Saving does not switch the chat.
  private static func addAgent(
    _ words: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let usage = """
      Usage: /agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]
        MODEL     a model name, or - for the provider's default
        GROUPS    tool groups as a,b,c (see /tools), or - for none
        PROMPT    a named system prompt (see /prompts; /prompt add NAME TEXT creates one)
        PROVIDER  defaults to this chat's provider; with BASE_URL a new OpenAI-compatible one
      """
    guard (4...6).contains(words.count) else {
      await terminal.line(usage)
      return
    }
    guard let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    var draft = configuration ?? MaiConfiguration()
    let name = words[0]
    let model = words[1] == "-" ? "" : words[1]
    let providerID = words.count >= 5 ? ProviderID(words[4]) : session.profile.provider

    var providerChanged = false
    if words.count == 6 {
      guard let baseURL = URL(string: words[5]),
        ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
        baseURL.host != nil
      else {
        await terminal.line("BASE_URL must be an http(s) URL.\n\(usage)")
        return
      }
      if let index = draft.providers.firstIndex(where: { $0.id == providerID.rawValue }) {
        if let configuredURL = draft.providers[index].baseURL, configuredURL != baseURL {
          await terminal.line(
            "Provider '\(providerID)' already uses \(configuredURL.absoluteString). Use a unique provider ID for \(baseURL.absoluteString).",
            to: .standardError)
          return
        }
        if draft.providers[index].baseURL == nil {
          draft.providers[index].baseURL = baseURL
          providerChanged = true
        }
      } else {
        draft.providers.append(
          ConfiguredProvider(
            id: providerID.rawValue,
            kind: .openAICompatible,
            baseURL: baseURL,
            apiKeyEnvironment: apiKeyEnvironmentName(for: providerID.rawValue)))
        providerChanged = true
      }
    } else if !draft.providers.contains(where: { $0.id == providerID.rawValue }) {
      await terminal.line(
        "Unknown provider '\(providerID)'. /providers lists the configured ones; add BASE_URL to register a new OpenAI-compatible endpoint."
      )
      return
    }

    guard let promptName = resolvedSystemPromptName(words[3], configuration: draft),
      let instructions = draft.prompts?.system[promptName]
    else {
      let known = draft.prompts?.system.keys.sorted() ?? []
      await terminal.line(
        "Unknown system prompt '\(words[3])'. Create it first: /prompt add \(words[3]) TEXT, or /prompt edit \(words[3])."
          + (known.isEmpty ? "" : " Known: \(known.joined(separator: ", ")).")
      )
      return
    }
    guard
      let selection = await resolveToolGroupSpec(
        words[2], runtime: runtime, plugins: plugins, configuration: draft, terminal: terminal)
    else { return }

    let isNew = !draft.agents.contains { $0.id == name }
    var definition =
      draft.agents.first { $0.id == name }
      ?? AgentDefinition(id: name, instructions: instructions, provider: providerID, model: model)
    definition.provider = providerID
    definition.model = model
    definition.systemPrompt = promptName
    definition.instructions = instructions
    definition.toolGroupNames = []
    definition.toolNames = []
    selection.apply(to: &definition)
    let changed = draft.upsertAgent(definition)

    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      if providerChanged,
        let provider = draft.providers.first(where: { $0.id == providerID.rawValue })
      {
        try await runtime.register(
          plugins.makeProvider(from: provider, environment: ProcessInfo.processInfo.environment),
          replacingExisting: true)
      }
      for agent in draft.agents where changed.contains(agent.id) {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      configuration = draft
      if session.profile.agentID == name {
        try applyDefinition(definition, to: &session)
      }
      let groups = definition.toolGroupNames.sorted()
      let summary =
        "\(providerID)\(model.isEmpty ? "" : " \(model)"), "
        + (groups.isEmpty ? "no tool groups" : "tool groups \(groups.joined(separator: ", "))")
        + ", system prompt '\(promptName)'"
      let hint =
        session.profile.agentID == name ? "" : " /agent use \(name) switches this chat to it."
      await terminal.line("\(isNew ? "Added" : "Updated") agent '\(name)': \(summary).\(hint)")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// What `a,b,c`, `+a,-b`, or `-` asks for, resolved against the tool
  /// group catalog.
  private struct ToolGroupSelection {
    var replaces: Bool
    var added: [ToolGroupDefinition] = []
    var removed: [ToolGroupDefinition] = []

    func apply(to definition: inout AgentDefinition) {
      if replaces {
        definition.toolGroupNames = Set(added.map(\.id))
        definition.toolNames = added.reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
        return
      }
      for group in removed {
        definition.toolGroupNames.remove(group.id)
        definition.toolNames.subtract(group.toolNames)
      }
      for group in added {
        definition.toolGroupNames.insert(group.id)
        definition.toolNames.formUnion(group.toolNames)
      }
    }
  }

  /// Parses a tool group spec, saying which name was not found.
  private static func resolveToolGroupSpec(
    _ spec: String,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async -> ToolGroupSelection? {
    let catalog: [ToolGroupDefinition]
    do {
      catalog = try await toolGroupCatalog(
        runtime: runtime, plugins: plugins, configuration: configuration)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return nil
    }
    if spec == "-" || spec.lowercased() == "none" { return ToolGroupSelection(replaces: true) }
    let entries = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let relative = !entries.isEmpty && entries.allSatisfy { $0.hasPrefix("+") || $0.hasPrefix("-") }
    var selection = ToolGroupSelection(replaces: !relative)
    for entry in entries {
      let name = relative ? String(entry.dropFirst()) : entry
      guard let group = resolveToolGroup(name, in: catalog) else {
        await terminal.line(
          "Unknown tool group '\(name)'. Available: \(catalog.map(\.id).sorted().joined(separator: ", "))."
        )
        return nil
      }
      if relative, entry.hasPrefix("-") {
        selection.removed.append(group)
      } else {
        selection.added.append(group)
      }
    }
    return selection
  }

  /// Applies one change to a saved definition, writes it back, and keeps the
  /// current chat in step when it is the agent edited — without clearing
  /// the conversation. `change` answers a message to refuse the edit.
  private static func updateAgent(
    _ id: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter,
    change: (inout AgentDefinition, MaiConfiguration) -> String?
  ) async -> AgentDefinition? {
    guard let draft = configuration, configurationPath != nil else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return nil
    }
    guard var definition = draft.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. /agents lists the saved ones.")
      return nil
    }
    if let refusal = change(&definition, draft) {
      await terminal.line(refusal)
      return nil
    }
    guard
      await persistAgentDefinition(
        definition,
        configuration: &configuration,
        configurationPath: configurationPath,
        runtime: runtime,
        terminal: terminal)
    else { return nil }
    if session.profile.agentID == id {
      do {
        try applyDefinition(definition, to: &session)
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    }
    return definition
  }

  /// Brings the current chat in step with a definition just saved, without
  /// clearing the conversation: the system message is rewritten in place.
  private static func applyDefinition(
    _ definition: AgentDefinition,
    to session: inout REPLSession
  ) throws {
    let previous = session.profile.instructions
    session.profile = SessionProfile(definition: definition)
    try applySystemInstructions(definition.instructions, replacing: previous, session: &session)
  }

  private static func removeAgent(
    _ id: String,
    session: REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    guard let removed = draft.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. /agents lists the saved ones.")
      return
    }
    guard id != session.profile.agentID else {
      await terminal.line("Agent '\(id)' is this chat's agent; switch with /agent use OTHER first.")
      return
    }
    let parents = draft.agents.filter { $0.subagentNames.contains(id) }.map(\.id)
    let previousDefault = draft.defaultAgent
    draft.removeAgent(id)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      await runtime.unregister(agentID: id)
      configuration = draft
      var notes = ["Removed agent '\(id)'."]
      if !parents.isEmpty {
        notes.append("It is no longer a subagent of \(parents.joined(separator: ", ")).")
      }
      if let current = draft.defaultAgent, current != previousDefault {
        notes.append("The default agent is now '\(current)'.")
      }
      if let prompt = removed.systemPrompt, draft.agentsUsingSystemPrompt(prompt).isEmpty,
        draft.prompts?.system[prompt] != nil
      {
        notes.append("Its system prompt '\(prompt)' is now unused; /prompt rm \(prompt) drops it.")
      }
      await terminal.line(notes.joined(separator: " "))
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Opens one saved definition as JSON. `instructions` is the text of the
  /// prompt named in `systemPrompt`: changing the text changes that prompt
  /// for every agent using it; naming another existing prompt without
  /// touching the text switches to that prompt.
  private static func editAgentDefinition(
    named id: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard let draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    guard let current = draft.agents.first(where: { $0.id == id }) else {
      await terminal.line("Unknown agent '\(id)'. /agents lists the saved ones.")
      return
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(current)
      guard
        let edited = await editTemporaryData(data, suffix: "agent-\(id).json", terminal: terminal)
      else { return }
      var definition = try JSONDecoder().decode(AgentDefinition.self, from: edited)
      guard definition.id == id else {
        await terminal.line("Keep the id '\(id)'; /agent add creates another agent.")
        return
      }
      if let name = definition.systemPrompt, name != current.systemPrompt,
        definition.instructions == current.instructions,
        let text = draft.prompts?.system[name]
      {
        definition.instructions = text
      }
      guard
        await persistAgentDefinition(
          definition,
          configuration: &configuration,
          configurationPath: configurationPath,
          runtime: runtime,
          terminal: terminal)
      else { return }
      if session.profile.agentID == id {
        try applyDefinition(definition, to: &session)
      }
      await terminal.line("Agent '\(id)' saved to \(configurationPath).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Opens one configured provider as JSON, the way `/edit agent` opens an
  /// agent, and rebuilds it in the live runtime once the file is saved, so a
  /// new header or base URL takes effect without a restart.
  private static func editConfiguredProvider(
    named id: String,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    guard let index = draft.providers.firstIndex(where: { $0.id == id }) else {
      await terminal.line("Unknown configured provider '\(id)'. /providers lists them.")
      return
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(draft.providers[index])
      guard
        let edited = await editTemporaryData(
          data, suffix: "provider-\(id).json", terminal: terminal)
      else { return }
      let provider = try JSONDecoder().decode(ConfiguredProvider.self, from: edited)
      guard provider.id == id else {
        await terminal.line("Keep the id '\(id)'; /edit config adds providers.")
        return
      }
      let built = try await plugins.makeProvider(
        from: provider, environment: ProcessInfo.processInfo.environment)
      try await runtime.register(built, replacingExisting: true)
      draft.providers[index] = provider
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      if let baseURL = provider.baseURL {
        providerBaseURLs.set(baseURL, for: id)
      }
      await terminal.line("Provider '\(id)' saved to \(configurationPath) and reloaded.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func showAgent(
    _ id: String,
    session: REPLSession,
    configuration: MaiConfiguration?,
    providerBaseURLs: [String: URL],
    terminal: TerminalWriter
  ) async {
    let definition =
      session.profile.agentID == id
      ? session.profile.agentDefinition : configuration?.agents.first(where: { $0.id == id })
    guard let definition else {
      await terminal.line("Unknown agent '\(id)'. Use /agents.")
      return
    }
    let baseURL =
      providerBaseURLs[definition.provider.rawValue]
      ?? configuration?.providers.first { $0.id == definition.provider.rawValue }?.baseURL
    let groups = definition.toolGroupNames.sorted()
    let subagents = definition.subagentNames.sorted()
    let parked = definition.isEnabled ? "" : " [disabled]"
    await terminal.line("Agent: \(definition.id) (\(definition.displayName))\(parked)")
    if !definition.description.isEmpty {
      await terminal.line("Description: \(definition.description)")
    }
    await terminal.line("Provider: \(definition.provider)")
    await terminal.line("Base URL: \(baseURL?.absoluteString ?? "-")")
    await terminal.line("Model: \(definition.model.isEmpty ? "-" : definition.model)")
    await terminal.line(
      "Tool groups: \(groups.isEmpty ? "-" : groups.joined(separator: ", ")) (\(definition.toolNames.count) tools)"
    )
    await terminal.line("Subagents: \(subagents.isEmpty ? "-" : subagents.joined(separator: ", "))")
    await terminal.line(
      "Delegation: \(definition.toolDelegation.rawValue) · limits \(definition.limits.maxModelTurns) turns, \(definition.limits.maxToolCalls) tools, \(definition.limits.maxSubagents) subagents"
    )
    await terminal.line("Tool calling: \(definition.toolCallingStrategy.rawValue)")
    await terminal.line("System prompt: \(definition.systemPrompt ?? "inline")")
    await terminal.line(
      "Instructions: \(definition.instructions.isEmpty ? "-" : definition.instructions)")
  }

  @discardableResult
  private static func persistAgentProfile(
    session: REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async -> Bool {
    await persistAgentDefinition(
      session.profile.agentDefinition,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
  }

  /// Writes one definition to the configuration and the live runtime, along
  /// with every agent sharing its named prompt. Answers false, having said
  /// why, when nothing could be saved.
  @discardableResult
  private static func persistAgentDefinition(
    _ definition: AgentDefinition,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async -> Bool {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    let changed = draft.upsertAgent(definition)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      for agent in draft.agents where changed.contains(agent.id) {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      configuration = draft
      return true
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return false
    }
  }

  private static func apiKeyEnvironmentName(for providerID: String) -> String {
    if providerID.lowercased() == "openai" { return "OPENAI_API_KEY" }
    let stem = providerID.uppercased().map { character in
      character.isLetter || character.isNumber ? character : "_"
    }
    return String(stem) + "_API_KEY"
  }

  private static func handleToolsCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 3, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? "list"
    let groups: [ToolGroupDefinition]
    do {
      groups = try await toolGroupCatalog(
        runtime: runtime,
        plugins: plugins,
        configuration: configuration)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }

    if action == "list" || fields.isEmpty {
      if session.profile.useToolProxy {
        await terminal.line(
          "Tool proxy \(toolProxySetting(session.profile)): models see \(session.profile.proxyExposedTools?.isEmpty == true ? "only" : "the common tools plus") list-tools and call-tool."
        )
      }
      for group in groups {
        let enabled = isToolGroupEnabled(group, profile: session.profile) ? "*" : " "
        await terminal.line(
          "\(enabled) \(group.id) — \(group.displayName) [\(group.toolNames.count) tool\(group.toolNames.count == 1 ? "" : "s")]"
        )
      }
      await terminal.line(
        "Use /tools show GROUP to see what a group is for, each tool with its parameters, and its settings."
      )
      return
    }

    guard fields.count >= 2, let group = resolveToolGroup(fields[1], in: groups) else {
      await terminal.line(toolHelp)
      return
    }
    switch action {
    case "enable", "on":
      session.profile.toolGroupNames.insert(group.id)
      session.profile.toolNames.formUnion(group.toolNames)
      if await persistAgentProfile(
        session: session,
        configuration: &configuration,
        configurationPath: configurationPath,
        runtime: runtime,
        terminal: terminal)
      {
        await terminal.line(
          "Enabled tool group '\(group.id)' for agent \(session.profile.agentID).")
      }
    case "disable", "off":
      session.profile.toolGroupNames.remove(group.id)
      session.profile.toolNames.subtract(group.toolNames)
      if await persistAgentProfile(
        session: session,
        configuration: &configuration,
        configurationPath: configurationPath,
        runtime: runtime,
        terminal: terminal)
      {
        await terminal.line(
          "Disabled tool group '\(group.id)' for agent \(session.profile.agentID).")
      }
    case "show":
      let count = group.toolNames.count
      let enabled = isToolGroupEnabled(group, profile: session.profile)
      // Names in the bold cyan of headings, traits yellow, parameter names
      // green with their type dim, so the eye can jump from tool to tool and
      // the descriptions read as prose in between.
      let colors = await terminal.paintsOutput
      func paint(_ text: String, _ code: String?) -> String {
        guard colors, let code else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
      }
      await terminal.line(
        paint(group.displayName, "1;36") + " " + paint("(\(group.catalogID))", "2")
          + ": \(count) tool\(count == 1 ? "" : "s"), "
          + paint(enabled ? "enabled" : "disabled", enabled ? "32" : "31")
          + " for agent \(session.profile.agentID)")
      // The agent family is synthesized per run rather than registered, so
      // its help comes from the definitions the model would see.
      var tools = await runtime.availableTools()
      if group.id == AgentRuntime.agentToolGroup.id {
        tools += AgentProcessTools.definitions(
          offering: [], delegating: true, planFirst: configuration?.use.plan ?? true)
      }
      let helpLines = ToolGroupHelp.lines(for: group, tools: tools) { text, style in
        switch style {
        case .group: return paint(text, "36")
        case .tool: return paint(text, "1;36")
        case .trait: return paint(text, "33")
        case .description, .parameterDetail: return text
        case .parameter: return paint(text, "32")
        case .parameterType, .note: return paint(text, "2")
        case .missing: return paint(text, "31")
        }
      }
      for line in helpLines {
        await terminal.line(line)
      }
      guard !group.options.isEmpty else { return }
      let options = configuredOptions(for: group, configuration: configuration)
      await terminal.line("")
      await terminal.line(
        paint("Settings", "1;36")
          + paint(", changed with /tools set \(group.id) OPTION VALUE:", "2"))
      for option in group.options {
        let value = options[option.id] ?? option.defaultValue
        var line =
          "  " + paint(option.id, "32") + " = "
          + paint(displayedOption(value, kind: option.kind), "1")
          + "  " + paint("\(option.label).", "2")
        if let help = option.help?.trimmingCharacters(in: .whitespacesAndNewlines), !help.isEmpty {
          line += " " + paint(help, "2")
        }
        await terminal.line(line)
      }
    case "set", "config":
      guard fields.count == 4,
        let option = group.options.first(where: { $0.id == fields[2] }),
        let value = parseToolOption(fields[3], definition: option)
      else {
        await terminal.line("Usage: /tools set GROUP OPTION VALUE")
        return
      }
      await reconfigureToolGroup(
        group,
        option: option.id,
        value: value,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    case "unset":
      guard fields.count == 3,
        group.options.contains(where: { $0.id == fields[2] })
      else {
        await terminal.line("Usage: /tools unset GROUP OPTION")
        return
      }
      await reconfigureToolGroup(
        group,
        option: fields[2],
        value: nil,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    default:
      await terminal.line(toolHelp)
    }
  }

  // MARK: Effort

  /// `/set effort` shows the reasoning level and guidance of the current
  /// agent; `/set effort LEVEL [TEXT]` sets them and `/set effort auto` clears
  /// them. The level
  /// reaches the provider as the field its API family takes and, with the
  /// guidance, the system prompt; both persist on the agent like /set does.
  private static func handleEffortCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let first = fields.first?.lowercased() else {
      await terminal.line(effortDescription(session.profile.options))
      return
    }
    let guidance = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if ["auto", "automatic", "default", "clear"].contains(first) {
      session.profile.options.reasoningEffort = nil
      session.profile.options.reasoningGuidance = nil
    } else if let effort = ReasoningEffort(name: first) {
      session.profile.options.reasoningEffort = effort.rawValue
      session.profile.options.reasoningGuidance = guidance.isEmpty ? nil : guidance
    } else {
      await terminal.line(effortHelp)
      return
    }
    session.touch()
    let summary = effortDescription(session.profile.options)
    let endpoint = configuration?.providers.first { $0.id == session.profile.provider.rawValue }
    let effort = session.profile.options.reasoningEffort.flatMap(ReasoningEffort.init(name:))
      ?? .automatic
    if let note = effort.limitation(
        model: session.profile.model,
        provider: session.profile.provider.rawValue,
        baseURL: endpoint?.baseURL?.absoluteString ?? "")
    {
      await terminal.line(note)
    }
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("Set \(summary) for this chat.")
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line("Set \(summary) for agent '\(session.profile.agentID)'.")
    }
  }

  /// `effort = high — Check every edge case.`, or `effort = off`.
  private static func effortDescription(_ options: GenerationOptions) -> String {
    let level = options.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let guidance = options.reasoningGuidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var text = "effort = \(level.isEmpty ? "auto" : level)"
    if !guidance.isEmpty { text += " — \(guidance)" }
    return text
  }

  // MARK: Skills

  /// Registers a `skills_*` tool for every skill the state can see. Called
  /// at startup, before agents are filtered against the known tool names.
  private static func registerSkillTools(
    in runtime: AgentRuntime,
    state: SkillState
  ) async throws {
    for tool in MaiSkillTools.makeTools(catalog: { state.catalog }) {
      try await runtime.register(tool: tool, replacingExisting: true)
    }
  }

  /// Brings the runtime's skill tools in line with the folders on disk: new
  /// skills are registered, edited ones re-described, removed ones dropped.
  @discardableResult
  private static func synchronizeSkillTools(
    runtime: AgentRuntime,
    state: SkillState
  ) async -> (catalog: AgentSkillCatalog, added: [String], removed: [String]) {
    let catalog = state.catalog
    let wanted = catalog.modelInvocable
    let wantedNames = Set(wanted.map(\.toolName))
    let registered = Set(
      await runtime.availableTools().map(\.name).filter(MaiSkillTools.isSkillTool))
    var removed: [String] = []
    for name in registered.subtracting(wantedNames).sorted() {
      await runtime.unregister(toolNamed: name)
      removed.append(name)
    }
    var added: [String] = []
    for skill in wanted {
      let tool = MaiSkillTools.makeTool(for: skill) { state.catalog }
      guard (try? await runtime.register(tool: tool, replacingExisting: true)) != nil else {
        continue
      }
      if !registered.contains(skill.toolName) { added.append(skill.name) }
    }
    return (catalog, added, removed)
  }

  private static func isSkillEnabled(_ skill: AgentSkill, profile: SessionProfile) -> Bool {
    profile.toolNames.contains(skill.toolName)
      || profile.toolGroupNames.contains(MaiSkillTools.groupID)
  }

  /// The name and extra text of a `/skills prompt NAME [TEXT]` line; nil for
  /// any other /skills action.
  private static func skillPromptRequest(_ argument: String)
    -> (name: String, arguments: String)?
  {
    let pieces = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = pieces.first?.lowercased(), ["prompt", "send", "use"].contains(action)
    else { return nil }
    let name = pieces.count > 1 ? pieces[1] : ""
    let arguments =
      pieces.count > 2 ? pieces[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return (name, arguments)
  }

  private static func resolveSkill(
    _ selector: String,
    in catalog: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async -> AgentSkill? {
    guard !selector.isEmpty else {
      await terminal.line("Usage: /skills show|enable|disable|prompt NAME   (/skills lists them)")
      return nil
    }
    guard let skill = catalog.skill(named: selector) else {
      await terminal.line("Unknown skill '\(selector)'. /skills lists them.")
      return nil
    }
    return skill
  }

  private static func handleSkillsCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    skills: SkillState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? "list"
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let synced = await synchronizeSkillTools(runtime: runtime, state: skills)
    let catalog = synced.catalog
    let agentID = session.profile.agentID

    switch action {
    case "", "list", "ls":
      guard !catalog.isEmpty else {
        let places = skills.directories.map { abbreviatedPath($0.path, width: 60) }
        await terminal.line(
          "No skills. A skill is a folder with a SKILL.md under \(places.joined(separator: " or ")); /help skills explains."
        )
        return
      }
      for skill in catalog.skills {
        let mark =
          skill.isModelInvocable && isSkillEnabled(skill, profile: session.profile) ? "*" : " "
        var note = skill.rootURL.path == skills.userDirectory.path ? "user" : "project"
        if !skill.isModelInvocable { note += ", prompt only" }
        await terminal.line("\(mark) \(skill.name) — \(skill.description) [\(note)]")
      }
      await terminal.line(
        "* marks the skills agent \(agentID) may call. /skills enable NAME offers one; /skills prompt NAME [TEXT] sends one now."
      )

    case "show", "cat":
      guard let skill = await resolveSkill(rest, in: catalog, terminal: terminal) else { return }
      let state =
        !skill.isModelInvocable
        ? "not offered to the model"
        : isSkillEnabled(skill, profile: session.profile)
          ? "enabled for \(agentID)" : "disabled for \(agentID)"
      await terminal.line("\(skill.name): \(skill.description)")
      await terminal.line("File: \(skill.fileURL.path)")
      await terminal.line("Tool: \(skill.toolName) (\(state))")
      await terminal.line("")
      await terminal.line(skill.body)

    case "enable", "on", "disable", "off":
      let enabling = action == "enable" || action == "on"
      if rest.lowercased() == "all" {
        let names = catalog.modelInvocable.map(\.toolName)
        if enabling {
          session.profile.toolGroupNames.insert(MaiSkillTools.groupID)
          session.profile.toolNames.formUnion(names)
        } else {
          session.profile.toolGroupNames.remove(MaiSkillTools.groupID)
          session.profile.toolNames = session.profile.toolNames.filter {
            !MaiSkillTools.isSkillTool($0)
          }
        }
        guard
          await persistAgentProfile(
            session: session, configuration: &configuration,
            configurationPath: configurationPath, runtime: runtime, terminal: terminal)
        else { return }
        await terminal.line(
          enabling
            ? "Enabled all \(names.count) skill\(names.count == 1 ? "" : "s") for agent \(agentID); skills added later are offered too."
            : "Disabled every skill for agent \(agentID); /skills prompt NAME still sends one.")
        return
      }
      guard let skill = await resolveSkill(rest, in: catalog, terminal: terminal) else { return }
      guard skill.isModelInvocable else {
        await terminal.line(
          "Skill '\(skill.name)' says disable-model-invocation, so the model never calls it; /skills prompt \(skill.name) sends it."
        )
        return
      }
      if enabling {
        session.profile.toolNames.insert(skill.toolName)
      } else {
        session.profile.toolNames.remove(skill.toolName)
        // The group means "every skill, present and future"; one dropped
        // out of it has to be listed by name from now on.
        session.profile.toolGroupNames.remove(MaiSkillTools.groupID)
      }
      guard
        await persistAgentProfile(
          session: session, configuration: &configuration,
          configurationPath: configurationPath, runtime: runtime, terminal: terminal)
      else { return }
      await terminal.line(
        enabling
          ? "Enabled skill '\(skill.name)' for agent \(agentID): the model may call \(skill.toolName)."
          : "Disabled skill '\(skill.name)' for agent \(agentID); /skills prompt \(skill.name) still sends it."
      )

    case "prompt", "send", "use":
      await terminal.line(
        "Use /skills prompt NAME [TEXT] at the chat prompt; /skills show NAME prints what it sends."
      )

    case "path", "paths", "dirs", "dir":
      for directory in skills.directories {
        var isDirectory: ObjCBool = false
        let exists =
          FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
          && isDirectory.boolValue
        let count = AgentSkillCatalog.load(directory: directory).count
        await terminal.line(
          "\(directory.path)  \(exists ? "\(count) skill\(count == 1 ? "" : "s")" : "(missing)")")
      }

    case "reload", "sync", "rescan":
      var parts: [String] = []
      if !synced.added.isEmpty { parts.append("added \(synced.added.joined(separator: ", "))") }
      if !synced.removed.isEmpty {
        parts.append("removed \(synced.removed.joined(separator: ", "))")
      }
      await terminal.line(
        "\(catalog.skills.count) skill\(catalog.skills.count == 1 ? "" : "s")"
          + (parts.isEmpty ? ", unchanged." : ": " + parts.joined(separator: "; ") + "."))

    default:
      await terminal.line(skillsHelp)
    }
  }

  private static func toolGroupCatalog(
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?
  ) async throws -> [ToolGroupDefinition] {
    let tools = await runtime.availableTools()
    var groups = AgentRuntime.builtInToolGroups(for: tools)
    for source in configuration?.toolSources.filter(\.enabled) ?? [] {
      groups.append(
        contentsOf: try await plugins.toolGroups(
          kind: source.kind,
          context: source.context(environment: ProcessInfo.processInfo.environment)))
    }
    return ToolGroupDefinition.catalog(known: groups, tools: tools)
  }

  private static func resolveToolGroup(
    _ selector: String,
    in groups: [ToolGroupDefinition]
  ) -> ToolGroupDefinition? {
    let matches = groups.filter {
      $0.id.caseInsensitiveCompare(selector) == .orderedSame
        || $0.catalogID.caseInsensitiveCompare(selector) == .orderedSame
    }
    return matches.count == 1 ? matches[0] : nil
  }

  private static func isToolGroupEnabled(
    _ group: ToolGroupDefinition,
    profile: SessionProfile
  ) -> Bool {
    profile.toolGroupNames.contains(group.id) || group.toolNames.isSubset(of: profile.toolNames)
  }

  private static func configuredOptions(
    for group: ToolGroupDefinition,
    configuration: MaiConfiguration?
  ) -> [String: JSONValue] {
    let source = configuration?.toolSources.first { $0.id == group.sourceID }
    return Dictionary(
      uniqueKeysWithValues: group.options.compactMap { option in
        source?.options[option.id].map { (option.id, $0) }
          ?? option.defaultValue.map { (option.id, $0) }
      })
  }

  private static func displayedOption(
    _ value: JSONValue?,
    kind: ToolGroupOptionKind
  ) -> String {
    guard let value else { return "-" }
    if kind == .secret { return value.stringValue?.isEmpty == false ? "(configured)" : "-" }
    if let string = value.stringValue { return string }
    if let integer = value.intValue { return String(integer) }
    if let number = value.numberValue { return String(number) }
    if let boolean = value.boolValue { return String(boolean) }
    return value.compactJSONString
  }

  private static func parseToolOption(
    _ rawValue: String,
    definition: ToolGroupOptionDefinition
  ) -> JSONValue? {
    switch definition.kind {
    case .text, .secret:
      return .string(rawValue)
    case .boolean:
      return booleanSetting(rawValue).map(JSONValue.bool)
    case .number:
      return Double(rawValue).map(JSONValue.number)
    case .choice:
      guard definition.choices.contains(rawValue) else { return nil }
      return .string(rawValue)
    }
  }

  private static func reconfigureToolGroup(
    _ group: ToolGroupDefinition,
    option: String,
    value: JSONValue?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let sourceIndex = draft.toolSources.firstIndex(where: { $0.id == group.sourceID })
    else {
      await terminal.line("This runtime-only group has no persistent settings.")
      return
    }
    if let value {
      draft.toolSources[sourceIndex].options[option] = value
    } else {
      draft.toolSources[sourceIndex].options.removeValue(forKey: option)
    }
    let source = draft.toolSources[sourceIndex]
    do {
      let context = source.context(environment: ProcessInfo.processInfo.environment)
      let tools = try await plugins.makeTools(kind: source.kind, context: context)
      let groups = try await plugins.toolGroups(kind: source.kind, context: context)
      let replacement = groups.first(where: { $0.id == group.id })
      for index in draft.agents.indices
      where draft.agents[index].toolGroupNames.contains(group.id)
        || group.toolNames.isSubset(of: draft.agents[index].toolNames)
      {
        draft.agents[index].toolGroupNames.insert(group.id)
        draft.agents[index].toolNames.subtract(group.toolNames)
        if let replacement {
          draft.agents[index].toolNames.formUnion(replacement.toolNames)
        }
      }
      if isToolGroupEnabled(group, profile: session.profile),
        let replacement
      {
        session.profile.toolGroupNames.insert(group.id)
        session.profile.toolNames.subtract(group.toolNames)
        session.profile.toolNames.formUnion(replacement.toolNames)
      }
      let definition = session.profile.agentDefinition
      if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
        draft.agents[index] = definition
      } else {
        draft.agents.append(definition)
      }
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      for tool in tools {
        try await runtime.register(tool: tool, replacingExisting: true)
      }
      for agent in draft.agents {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      configuration = draft
      await terminal.line("Saved \(group.id).\(option).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func handleSetCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    approvalHandler: TerminalApprovalHandler,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let parts = argument.replacingOccurrences(of: "=", with: " ")
      .split(whereSeparator: \Character.isWhitespace)
      .map(String.init)
    guard !parts.isEmpty else {
      let enabled = await approvalHandler.isYOLOEnabled()
      await terminal.line("yolo = \(enabled ? "on" : "off")")
      await listLimitSettings(session.profile.limits, terminal: terminal)
      await listRecoverySettings(session.profile, terminal: terminal)
      await listToolSettings(session.profile, terminal: terminal)
      await terminal.line("delegation = \(session.profile.toolDelegation.rawValue)")
      await terminal.line(effortDescription(session.profile.options))
      await listUISettings(configuration?.ui ?? .init(), terminal: terminal)
      await listUseSettings(configuration?.use ?? .init(), terminal: terminal)
      return
    }
    let key = parts[0].lowercased()
    let displayedKey = key == "ui.toolresultlines" ? "ui.toolResultLines" : key
    if key == "effort" {
      await handleEffortCommand(
        parts.dropFirst().joined(separator: " "),
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "ui" || key == "ui." {
      await listUISettings(configuration?.ui ?? .init(), terminal: terminal)
      return
    }
    if key == "use" || key == "use." {
      await listUseSettings(configuration?.use ?? .init(), terminal: terminal)
      return
    }
    if key == "use.agentsmd" {
      await setAgentsMarkdown(
        parts: parts,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "use.plan" {
      await setPlanning(
        parts: parts,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "limits" || key == "limits." {
      await listLimitSettings(session.profile.limits, terminal: terminal)
      return
    }
    if let limitKey = limitSettingKeys[key] {
      await setLimit(
        limitKey,
        parts: parts,
        session: &session,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if let recoveryKey = recoverySettingKeys[key] {
      await setRecoverySetting(
        recoveryKey,
        parts: parts,
        session: &session,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if delegationSettingKeys.contains(key) {
      await setToolDelegation(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "tool" || key == "tool." || key == "tools" || key == "tools." {
      await listToolSettings(session.profile, terminal: terminal)
      return
    }
    if toolCallingStrategyKeys.contains(key) {
      await setToolCallingStrategy(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if toolProxyKeys.contains(key) {
      await setToolProxy(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if contextModeKeys.contains(key) {
      await setContextMode(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "yolo" {
      await setYOLO(
        parts: parts,
        approvalHandler: approvalHandler,
        terminal: terminal)
      return
    }

    let colorKeys = [
      "ui.bgline", "ui.fgcolor", "ui.bgcolor", "ui.fgprompt", "ui.bgprompt",
      "ui.fgtoolresult",
    ]
    let booleanKeys = ["ui.bold", "ui.markdown", "ui.broadcast"]
    let countKeys = ["ui.toolresultlines"]
    let levelKeys = ["ui.subagents", "ui.thinking"]
    let textKeys = ["ui.title", "ui.editor"]
    guard
      colorKeys.contains(key) || booleanKeys.contains(key) || countKeys.contains(key)
        || levelKeys.contains(key) || textKeys.contains(key)
    else {
      await terminal.line(
        "Unknown setting '\(parts[0])'. Available settings: effort, yolo, delegation, tool.calling, tool.proxy, limits.maxToolCalls, limits.maxModelTurns, limits.maxSubagents, limits.maxSubagentDepth, limits.maxTotalTokens, limits.maxSeconds, retry.attempts, retry.delay, ctx.compact, ctx.strategy, ui.title, ui.editor, ui.bgline, ui.fgcolor, ui.bgcolor, ui.fgprompt, ui.bgprompt, ui.fgtoolresult, ui.bold, ui.markdown, ui.toolResultLines, ui.subagents, ui.broadcast, use.agentsmd, use.plan"
      )
      return
    }
    var ui = configuration?.ui ?? .init()
    guard parts.count > 1 else {
      await terminal.line("\(displayedKey) = \(uiSetting(key, in: ui))")
      return
    }
    guard parts.count == 2 || textKeys.contains(key) else {
      await terminal.line("Usage: /set \(key) VALUE")
      return
    }
    if textKeys.contains(key) {
      let text = parts.dropFirst().joined(separator: " ")
      // "none" empties the setting: the title goes away, and the editor falls
      // back to $EDITOR again.
      let value = ["none", "off"].contains(text.lowercased()) ? "" : text
      if key == "ui.editor" {
        ui.editor = value
      } else {
        ui.title = value
      }
    } else if countKeys.contains(key) {
      let value: Int
      if parts[1].lowercased() == "all" {
        value = -1
      } else if let count = Int(parts[1]), count >= 0 {
        value = count
      } else {
        await terminal.line("Usage: /set ui.toolResultLines <all|N>")
        return
      }
      ui.toolResultLines = value
      await terminal.configureToolResultLines(value)
    } else if key == "ui.thinking" {
      guard let mode = ThinkingDisplay(rawValue: parts[1].lowercased()) else {
        await terminal.line("Usage: /set ui.thinking <status|line|three|five|full>")
        return
      }
      ui.thinking = mode
      await terminal.configureThinking(mode)
    } else if levelKeys.contains(key) {
      guard let level = SubagentOutputLevel(rawValue: parts[1].lowercased()) else {
        await terminal.line(
          "Usage: /set ui.subagents <\(SubagentOutputLevel.allCases.map(\.rawValue).joined(separator: "|"))>"
        )
        return
      }
      ui.subagentOutput = level
      await terminal.configureSubagentOutput(level)
    } else if booleanKeys.contains(key) {
      guard let enabled = booleanSetting(parts[1]) else {
        await terminal.line("Usage: /set \(key) <on|off>")
        return
      }
      if key == "ui.bold" {
        ui.bold = enabled
      } else if key == "ui.broadcast" {
        ui.broadcast = enabled
      } else {
        ui.markdown = enabled
        await terminal.configureMarkdown(
          markdownRenderer(
            enabled: enabled, forced: false, environment: ProcessInfo.processInfo.environment))
      }
    } else {
      guard let color = TerminalLineEditor.normalizedColor(parts[1]) else {
        await terminal.line(
          "Unknown color '\(parts[1])'. Use a named ANSI color, rgb:RGB, or none.")
        return
      }
      switch key {
      case "ui.bgline": ui.backgroundLine = color
      case "ui.fgcolor": ui.foreground = color
      case "ui.bgcolor": ui.background = color
      case "ui.fgprompt": ui.promptForeground = color
      case "ui.bgprompt": ui.promptBackground = color
      case "ui.fgtoolresult":
        ui.toolResultForeground = color
        await terminal.configureToolResultColor(color)
      default: break
      }
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.ui = ui
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      if key == "ui.title" { await terminal.configureTerminalTitle(ui.title) }
      if key == "ui.editor" { configureEditor(ui.editor) }
      await terminal.line("Set \(displayedKey) = \(uiSetting(key, in: ui)).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Lowercased `/set` keys mapped to their canonical spelling.
  private static let limitSettingKeys = [
    "limits.maxtoolcalls": "limits.maxToolCalls",
    "limits.maxmodelturns": "limits.maxModelTurns",
    "limits.maxsubagents": "limits.maxSubagents",
    "limits.maxsubagentdepth": "limits.maxSubagentDepth",
    "limits.maxtotaltokens": "limits.maxTotalTokens",
    "limits.maxtokens": "limits.maxTotalTokens",
    "limits.maxseconds": "limits.maxSeconds",
    "limits.maxtime": "limits.maxSeconds",
  ]

  /// Lowercased `/set` keys for retry and context-compaction policies.
  private static let recoverySettingKeys = [
    "retry.attempts": "retry.attempts",
    "retry.count": "retry.attempts",
    "retries": "retry.attempts",
    "retry.delay": "retry.delay",
    "retry.delayseconds": "retry.delay",
    "ctx.compact": "ctx.compact",
  ]

  private static let delegationSettingKeys: Set<String> = [
    "delegation", "tools.delegation", "tooldelegation", "subagents",
  ]

  private static let toolCallingStrategyKeys: Set<String> = [
    "tool.calling", "tools.calling", "toolcalling", "toolcallingstrategy",
  ]

  private static let toolProxyKeys: Set<String> = [
    "tool.proxy", "tools.proxy", "toolproxy", "usetoolproxy",
  ]

  private static let contextModeKeys: Set<String> = ["ctx.strategy"]

  private static func listToolSettings(_ profile: SessionProfile, terminal: TerminalWriter) async {
    await terminal.line("tool.calling = \(profile.toolCallingStrategy.rawValue)")
    await terminal.line("tool.proxy = \(toolProxySetting(profile))")
  }

  /// `/set yolo [on|off]`: permits every tool call without asking. The choice
  /// is saved in the opened project's .pmai/settings.json for later runs.
  private static func setYOLO(
    parts: [String],
    approvalHandler: TerminalApprovalHandler,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      let enabled = await approvalHandler.isYOLOEnabled()
      await terminal.line("yolo = \(enabled ? "on" : "off")")
      return
    }
    guard parts.count == 2, let enabled = booleanSetting(parts[1]) else {
      await terminal.line("Usage: /set yolo <on|off>")
      return
    }
    let effect =
      enabled
      ? "YOLO mode enabled; all tool calls are permitted"
      : "YOLO mode disabled; configured approval rules restored"
    do {
      try await approvalHandler.saveYOLOEnabled(enabled)
      await terminal.line("\(effect), and saved for later runs in this project.")
    } catch {
      await terminal.line(
        "\(effect) for this session; could not save the project settings: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  /// `/set tool.proxy [on|off]`: shows or changes whether models see only the
  /// shared list-tools and call-tool pair instead of the agent's tools.
  private static func setToolProxy(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("tool.proxy = \(toolProxySetting(session.profile))")
      return
    }
    // on (or hybrid) keeps the common tools native and proxies the rest;
    // all hides every tool behind list-tools and call-tool.
    let value: String
    switch parts.count == 2 ? parts[1].lowercased() : "" {
    case "all":
      session.profile.useToolProxy = true
      session.profile.proxyExposedTools = []
      value = "all"
    case "hybrid":
      session.profile.useToolProxy = true
      session.profile.proxyExposedTools = nil
      value = "on"
    case let word:
      guard let enabled = booleanSetting(word) else {
        await terminal.line("Usage: /set tool.proxy <on|all|off>")
        return
      }
      session.profile.useToolProxy = enabled
      if enabled { session.profile.proxyExposedTools = nil }
      value = enabled ? "on" : "off"
    }
    session.touch()
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("Set tool.proxy = \(value) for this chat.")
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line("Set tool.proxy = \(value) for agent '\(session.profile.agentID)'.")
    }
  }

  /// `/set ctx.strategy <cache|size>`: cache never changes a sent message, size
  /// replaces consumed file bodies with references before each model call.
  private static func setContextMode(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("ctx.strategy = \(session.profile.context.rawValue)")
      return
    }
    guard parts.count == 2, let mode = AgentContextMode(rawValue: parts[1].lowercased()) else {
      await terminal.line("Usage: /set ctx.strategy <cache|size>")
      return
    }
    session.profile.context = mode
    session.touch()
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("Set ctx.strategy = \(mode.rawValue) for this chat.")
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line(
        "Set ctx.strategy = \(mode.rawValue) for agent '\(session.profile.agentID)'.")
    }
  }

  private static func setToolCallingStrategy(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("tool.calling = \(session.profile.toolCallingStrategy.rawValue)")
      return
    }
    let rawValue = parts[1].lowercased()
    let strategy =
      rawValue == "auto" ? ToolCallingStrategy.automatic : ToolCallingStrategy(rawValue: rawValue)
    guard parts.count == 2, let strategy else {
      await terminal.line(
        "Usage: /set tool.calling <automatic|native|text|xml|json>")
      return
    }
    session.profile.toolCallingStrategy = strategy
    session.touch()
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line("Set tool.calling = \(strategy.rawValue) for this chat.")
      return
    }
    draft.agents[index].toolCallingStrategy = strategy
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: session.profile.agentDefinition, replacingExisting: true)
      configuration = draft
      await terminal.line(
        "Set tool.calling = \(strategy.rawValue) for agent '\(session.profile.agentID)'.")
    } catch {
      await terminal.line(
        "Set tool.calling = \(strategy.rawValue) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  private static let limitSettingOrder = [
    "limits.maxToolCalls", "limits.maxModelTurns", "limits.maxSubagents",
    "limits.maxSubagentDepth", "limits.maxTotalTokens", "limits.maxSeconds",
  ]

  private static func listLimitSettings(_ limits: AgentRunLimits, terminal: TerminalWriter) async {
    for key in limitSettingOrder {
      await terminal.line("\(key) = \(limitValue(key, in: limits))")
    }
  }

  private static func limitValue(_ key: String, in limits: AgentRunLimits) -> String {
    switch key {
    case "limits.maxToolCalls": String(limits.maxToolCalls)
    case "limits.maxSubagents": String(limits.maxSubagents)
    case "limits.maxSubagentDepth": String(limits.maxSubagentDepth)
    case "limits.maxTotalTokens": limits.maxTotalTokens.map(String.init) ?? "off"
    case "limits.maxSeconds":
      limits.maxSeconds.map { ModelUsageFormat.duration(Double($0)) } ?? "off"
    default: String(limits.maxModelTurns)
    }
  }

  private static func listRecoverySettings(_ profile: SessionProfile, terminal: TerminalWriter)
    async
  {
    await terminal.line("retry.attempts = \(profile.retry.attempts)")
    await terminal.line("retry.delay = \(durationSetting(profile.retry.delaySeconds))")
    await terminal.line("ctx.compact = \(autocompactSetting(profile.autocompact))")
    await terminal.line("ctx.strategy = \(profile.context.rawValue)")
  }

  private static func durationSetting(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? "\(Int(seconds))s" : "\(seconds)s"
  }

  /// `off`, `on` (the common tools native, the rest proxied) or `all`.
  private static func toolProxySetting(_ profile: SessionProfile) -> String {
    guard profile.useToolProxy else { return "off" }
    return profile.proxyExposedTools?.isEmpty == true ? "all" : "on"
  }

  private static func autocompactSetting(_ autocompact: AgentAutocompact) -> String {
    autocompact.isEnabled ? "\(autocompact.tokens) tokens" : "off"
  }

  /// `90`, `90s`, `10m`, `1h`, `1h30m`: a duration in seconds, or nil.
  static func parseDurationSeconds(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if let plain = Int(text) { return plain > 0 ? plain : nil }
    var total = 0
    var digits = ""
    var units = 0
    for character in text {
      if character.isNumber {
        digits.append(character)
        continue
      }
      guard let value = Int(digits) else { return nil }
      switch character {
      case "h": total += value * 3600
      case "m": total += value * 60
      case "s": total += value
      default: return nil
      }
      digits = ""
      units += 1
    }
    guard units > 0, digits.isEmpty, total > 0 else { return nil }
    return total
  }

  /// `120000`, `120k`, `1.5m`: a token count, or nil.
  static func parseTokenCount(_ raw: String) -> Int? {
    var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    text.removeAll { $0 == "_" || $0 == "," }
    if let plain = Int(text) { return plain >= 0 ? plain : nil }
    let multiplier: Double
    if text.hasSuffix("k") {
      multiplier = 1_000
    } else if text.hasSuffix("m") {
      multiplier = 1_000_000
    } else {
      return nil
    }
    guard let value = Double(text.dropLast()), value >= 0 else { return nil }
    return Int((value * multiplier).rounded())
  }

  /// Lets the current agent hand tool work to a child, or not. Turning
  /// delegation on with no subagent budget would silently do nothing, so it
  /// raises the budget too.
  private static func setToolDelegation(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("delegation = \(session.profile.toolDelegation.rawValue)")
      return
    }
    let raw = parts[1].lowercased()
    let mode: AgentToolDelegation? =
      switch raw {
      case "off", "none", "self", "inline": .inline
      case "on", "child", "subagent", "subagents": .subagent
      default: nil
      }
    guard parts.count == 2, let mode else {
      await terminal.line("Usage: /set delegation <off|subagent>")
      return
    }
    session.profile.toolDelegation = mode
    var raised = false
    if mode == .subagent, session.profile.limits.maxSubagents < 1 {
      session.profile.limits.maxSubagents = 1
      raised = true
    }
    session.touch()
    var notes = [
      mode == .subagent
        ? "This agent keeps its tools and can also hand work to a child that has them; only the child's answer lands here."
        : "This agent runs every tool call itself."
    ]
    if raised { notes.append("Raised limits.maxSubagents to 1.") }
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line(
        (["Set delegation = \(mode.rawValue) for this chat."] + notes).joined(separator: " "))
      return
    }
    draft.agents[index].toolDelegation = mode
    draft.agents[index].limits = session.profile.limits
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: session.profile.agentDefinition, replacingExisting: true)
      configuration = draft
      await terminal.line(
        (["Set delegation = \(mode.rawValue) for agent '\(session.profile.agentID)'."] + notes)
          .joined(separator: " "))
    } catch {
      await terminal.line(
        "Set delegation = \(mode.rawValue) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  /// Changes one run limit for the current chat and, when the chat uses a
  /// configured agent, persists it into that agent's definition. The token
  /// and time caps take `off`; time takes `10m` and `1h` as well as seconds.
  private static func setLimit(
    _ key: String,
    parts: [String],
    session: inout REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    var limits = session.profile.limits
    guard parts.count > 1 else {
      await terminal.line("\(key) = \(limitValue(key, in: limits))")
      return
    }
    let raw = parts.count == 2 ? parts[1].lowercased() : ""
    let cleared = ["off", "none", "unlimited", "0"].contains(raw)
    switch key {
    case "limits.maxSeconds":
      if cleared {
        limits.maxSeconds = nil
      } else if let seconds = parseDurationSeconds(raw) {
        limits.maxSeconds = seconds
      } else {
        await terminal.line(
          "Usage: /set limits.maxSeconds <off|N|Nm|Nh>  (wall-clock time per run)")
        return
      }
    case "limits.maxTotalTokens":
      if cleared {
        limits.maxTotalTokens = nil
      } else if let tokens = parseTokenCount(raw), tokens > 0 {
        limits.maxTotalTokens = tokens
      } else {
        await terminal.line("Usage: /set limits.maxTotalTokens <off|N|Nk>  (tokens per run)")
        return
      }
    default:
      guard let value = Int(raw), value >= 0 else {
        await terminal.line("Usage: /set \(key) N  (a non-negative integer)")
        return
      }
      switch key {
      case "limits.maxToolCalls": limits.maxToolCalls = value
      case "limits.maxSubagents": limits.maxSubagents = value
      case "limits.maxSubagentDepth": limits.maxSubagentDepth = value
      default: limits.maxModelTurns = max(1, value)
      }
    }
    session.profile.limits = limits
    session.touch()
    let applied = limitValue(key, in: limits)
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line("Set \(key) = \(applied) for this chat.")
      return
    }
    draft.agents[index].limits = limits
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line("Set \(key) = \(applied) for agent '\(session.profile.agentID)'.")
    } catch {
      await terminal.line(
        "Set \(key) = \(applied) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  /// `retry.attempts`, `retry.delay`, and `ctx.compact`: what a run does when
  /// a model call fails, and when it summarizes its own conversation. Saved
  /// on the chat's agent like the limits.
  private static func setRecoverySetting(
    _ key: String,
    parts: [String],
    session: inout REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    var retry = session.profile.retry
    var autocompact = session.profile.autocompact
    func current() -> String {
      switch key {
      case "retry.attempts": String(retry.attempts)
      case "retry.delay": durationSetting(retry.delaySeconds)
      default: autocompactSetting(autocompact)
      }
    }
    guard parts.count > 1 else {
      await terminal.line("\(key) = \(current())")
      return
    }
    let raw = parts.count == 2 ? parts[1].lowercased() : ""
    switch key {
    case "retry.attempts":
      guard let value = Int(raw), value >= 0 else {
        await terminal.line("Usage: /set retry.attempts N  (0 fails on the first error)")
        return
      }
      retry.attempts = value
    case "retry.delay":
      if let seconds = Double(raw), seconds >= 0 {
        retry.delaySeconds = seconds
      } else if let seconds = parseDurationSeconds(raw) {
        retry.delaySeconds = Double(seconds)
      } else {
        await terminal.line("Usage: /set retry.delay SECONDS  (the wait before each retry)")
        return
      }
    default:
      if ["off", "none", "0"].contains(raw) {
        autocompact.tokens = 0
      } else if let tokens = parseTokenCount(raw), tokens > 0 {
        autocompact.tokens = tokens
      } else {
        await terminal.line(
          "Usage: /set ctx.compact <off|N|Nk>  (summarize the chat once it holds about N tokens)")
        return
      }
    }
    session.profile.retry = retry
    session.profile.autocompact = autocompact
    session.touch()
    var notes: [String] = []
    if key == "ctx.compact", autocompact.isEnabled {
      notes.append(
        "Older exchanges are summarized before a model turn once the conversation is estimated at \(autocompact.tokens) tokens; the newest exchange is kept verbatim."
      )
    }
    let applied = current()
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line(
        (["Set \(key) = \(applied) for this chat."] + notes).joined(separator: " "))
      return
    }
    draft.agents[index].retry = retry
    draft.agents[index].autocompact = autocompact
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line(
        (["Set \(key) = \(applied) for agent '\(session.profile.agentID)'."] + notes)
          .joined(separator: " "))
    } catch {
      await terminal.line(
        "Set \(key) = \(applied) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  private static func listUseSettings(_ use: ConfiguredUse, terminal: TerminalWriter) async {
    await terminal.line("use.agentsmd = \(use.agentsmd ? "on" : "off")")
    await terminal.line("use.plan = \(use.plan ? "on" : "off")")
  }

  /// `/set use.plan [on|off]`: shows or changes whether an agent that can
  /// start children is asked to open a multi-step request with a plan before
  /// its first `agent_start`.
  private static func setPlanning(
    parts: [String],
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let enabled = configuration?.use.plan ?? true
    guard parts.count > 1 else {
      await terminal.line("use.plan = \(enabled ? "on" : "off")")
      return
    }
    guard parts.count == 2, let wanted = booleanSetting(parts[1]) else {
      await terminal.line("Usage: /set use.plan <on|off>")
      return
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.use.plan = wanted
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    await runtime.configurePlanning(wanted)
    await terminal.line(
      "Set use.plan = \(wanted ? "on" : "off"). "
        + (wanted
          ? "An agent with children opens a request of several steps with a numbered plan."
          : "Agents delegate without planning first."))
  }

  /// `/set use.agentsmd [on|off]`: shows or changes whether the working
  /// tree's AGENTS.md files go into every run's system prompt, and says which
  /// files that means from here.
  private static func setAgentsMarkdown(
    parts: [String],
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let located = AgentInstructionsFile.locate(from: directory)
    let enabled = configuration?.use.agentsmd ?? false
    guard parts.count > 1 else {
      await terminal.line(
        "use.agentsmd = \(enabled ? "on" : "off") · \(agentsMarkdownSummary(located, directory: directory))"
      )
      return
    }
    guard parts.count == 2, let wanted = booleanSetting(parts[1]) else {
      await terminal.line("Usage: /set use.agentsmd <on|off>")
      return
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.use.agentsmd = wanted
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    await runtime.configureProjectInstructions(
      wanted ? AgentInstructionsFile.promptSection(files: located) : nil)
    await terminal.line(
      "Set use.agentsmd = \(wanted ? "on" : "off"). \(agentsMarkdownSummary(located, directory: directory))"
    )
  }

  /// Which AGENTS.md files apply from `directory`, as one line, each path
  /// relative to it: `AGENTS.md`, `../AGENTS.md`, and so on up the tree.
  private static func agentsMarkdownSummary(_ files: [URL], directory: URL) -> String {
    guard !files.isEmpty else {
      return "No AGENTS.md from \(directory.path) up to the repository root."
    }
    let base = directory.standardizedFileURL.pathComponents
    let names = files.map { file -> String in
      let target = file.standardizedFileURL.pathComponents
      let shared = zip(base, target).prefix { $0 == $1 }.count
      let ups = Array(repeating: "..", count: base.count - shared)
      return (ups + target.dropFirst(shared)).joined(separator: "/")
    }
    return "AGENTS.md from here up to the repository root: \(names.joined(separator: ", "))."
  }

  /// The AGENTS.md block for the working directory, when `use.agentsmd` is on.
  private static func projectInstructionsSection(_ configuration: MaiConfiguration?) -> String? {
    guard configuration?.use.agentsmd == true else { return nil }
    return AgentInstructionsFile.promptSection(
      from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
  }

  private static func listUISettings(_ ui: ConfiguredTerminalUI, terminal: TerminalWriter) async {
    for key in [
      "ui.title", "ui.editor", "ui.bgline", "ui.fgcolor", "ui.bgcolor", "ui.fgprompt",
      "ui.bgprompt", "ui.bold",
      "ui.fgtoolresult", "ui.markdown", "ui.toolResultLines", "ui.subagents", "ui.thinking",
      "ui.broadcast",
    ] {
      await terminal.line("\(key) = \(uiSetting(key, in: ui))")
    }
  }

  private static func uiSetting(_ key: String, in ui: ConfiguredTerminalUI) -> String {
    let value: String
    switch key.lowercased() {
    case "ui.title": value = visibleUITitle(ui.title)
    // Unset is worth showing as what it resolves to, since that is the editor
    // that actually opens.
    case "ui.editor":
      return ui.editor.isEmpty ? "\(resolvedEditor()) (from the environment)" : ui.editor
    case "ui.bgline": value = ui.backgroundLine
    case "ui.fgcolor": value = ui.foreground
    case "ui.bgcolor": value = ui.background
    case "ui.fgprompt": value = ui.promptForeground
    case "ui.bgprompt": value = ui.promptBackground
    case "ui.fgtoolresult": value = ui.toolResultForeground
    case "ui.bold": return ui.bold ? "on" : "off"
    case "ui.markdown": return ui.markdown ? "on" : "off"
    case "ui.toolresultlines": return ui.toolResultLines < 0 ? "all" : String(ui.toolResultLines)
    case "ui.thinking": return ui.thinking.rawValue
    case "ui.subagents": return ui.subagentOutput.rawValue
    case "ui.broadcast": return ui.broadcast ? "on" : "off"
    default: return "-"
    }
    return value.isEmpty ? "none" : value
  }

  private static func booleanSetting(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "1", "true", "yes", "on": true
    case "0", "false", "no", "off": false
    default: nil
    }
  }

  /// `/export FORMAT [PATH]` writes this chat as a document, or writes a
  /// portable archive containing the active configuration, visible skills,
  /// and current chat. MaiCore owns the archive format used by both hosts.
  private static func handleExportCommand(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    process: AgentPID?,
    configuration: MaiConfiguration?,
    skills: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let first = fields.first else {
      await terminal.line(exportHelp)
      return
    }
    var chat = session.chat
    // The agents of this chat's runs as they stand: what the process table
    // holds now, live or finished, over what was saved with the chat.
    if chat.hasConversation, let process {
      chat.subagents = AgentProcessRecord.merging(
        saved: chat.subagents, current: await runtime.supervisor.records(under: process))
    }
    if ["archive", "pack", "portable"].contains(first.lowercased()) {
      do {
        let archive = MaiArchive(
          generator: "pmai",
          settings: configuration.map { MaiArchiveSettings(configuration: $0) },
          chats: chat.hasConversation ? [chat] : nil,
          skills: try skills.skills.map { try MaiArchiveSkill(skill: $0) })
        let filename =
          chat.hasConversation
          ? archiveFilename(for: chat) : "Mai-Archive.\(MaiArchive.fileExtension)"
        let target = exportTarget(
          fields.count > 1 ? fields[1] : nil, defaultFilename: filename)
        let data = try archive.encoded()
        try data.write(to: target, options: .atomic)
        await terminal.line(
          "Exported Mai archive (\(AgentProcessInfo.compactCount(data.count)) bytes) to \(target.path)"
        )
      } catch {
        await terminal.line(
          "error: Could not export: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    guard let format = ChatExportFormat(argument: first) else {
      await terminal.line(exportHelp)
      return
    }
    guard chat.hasConversation else {
      await terminal.line("Nothing to export yet: this chat has no messages.")
      return
    }
    var debug: ChatExportDebug?
    if format == .debug {
      let profile = session.profile
      let tools = await runtime.availableTools().filter { profile.toolNames.contains($0.name) }
      let provider = await runtime.availableProviders().first { $0.id == profile.provider }
      debug = ChatExportDebug(
        provider: profile.provider.rawValue,
        providerDisplayName: provider?.displayName,
        toolDefinitions: tools,
        settings: [
          "workingDirectory": FileManager.default.currentDirectoryPath,
          "toolCallingStrategy": profile.toolCallingStrategy.rawValue,
          "toolDelegation": profile.toolDelegation.rawValue,
          "useToolProxy": profile.useToolProxy ? "true" : "false",
          "proxyExposedTools": profile.proxyExposedTools.map { $0.sorted().joined(separator: ", ") }
            ?? "default",
          "subagentNames": profile.subagentNames.sorted().joined(separator: ", "),
          "limits.maxToolCalls": String(profile.limits.maxToolCalls),
          "limits.maxModelTurns": String(profile.limits.maxModelTurns),
          "limits.maxSubagents": String(profile.limits.maxSubagents),
          "limits.maxSubagentDepth": String(profile.limits.maxSubagentDepth),
          "limits.maxTotalTokens": limitValue("limits.maxTotalTokens", in: profile.limits),
          "limits.maxSeconds": limitValue("limits.maxSeconds", in: profile.limits),
          "retry.attempts": String(profile.retry.attempts),
          "retry.delay": durationSetting(profile.retry.delaySeconds),
          "ctx.compact": autocompactSetting(profile.autocompact),
          "ctx.strategy": profile.context.rawValue,
        ],
        subagents: chat.subagents)
    }
    let target = exportTarget(
      fields.count > 1 ? fields[1] : nil,
      defaultFilename: ChatExport.filename(for: chat, format: format))
    do {
      let data = try ChatExport.data(for: chat, format: format, generator: "pmai", debug: debug)
      try data.write(to: target, options: .atomic)
      await terminal.line(
        "Exported \(format.displayName) (\(AgentProcessInfo.compactCount(data.count)) bytes) to \(target.path)"
      )
    } catch {
      await terminal.line(
        "error: Could not export: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func exportTarget(_ path: String?, defaultFilename: String) -> URL {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    guard let path else { return current.appendingPathComponent(defaultFilename) }
    let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let expanded = NSString(string: raw).expandingTildeInPath
    var target = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
    if raw.hasSuffix("/") || (exists && isDirectory.boolValue) {
      try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      target.appendPathComponent(defaultFilename)
    }
    return target
  }

  private static func archiveFilename(for chat: AgentChat) -> String {
    let json = ChatExport.filename(for: chat, format: .json)
    return String(json.dropLast(".json".count)) + "." + MaiArchive.fileExtension
  }

  /// Imports a Mai archive (standalone or embedded in a PocketMai backup).
  /// Older pmai JSON chat exports remain valid inputs as a convenience.
  private static func handleImportCommand(
    _ argument: String,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    visual: VisualBridge,
    selectImportedChat: Bool,
    terminal: TerminalWriter
  ) async {
    guard !argument.isEmpty else {
      await terminal.line(importHelp)
      return
    }
    let expanded = NSString(string: argument).expandingTildeInPath
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let url = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    do {
      let archive = try importArchive(from: Data(contentsOf: url))
      let summary = try await applyImportedArchive(
        archive,
        session: &session,
        workspace: &workspace,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        catalogs: &catalogs,
        visual: visual,
        selectImportedChat: selectImportedChat,
        terminal: terminal)
      await terminal.line("Imported \(summary.joined(separator: ", ")) from \(url.path).")
      if !selectImportedChat, archive.chats?.isEmpty == false {
        await terminal.line("The current turn kept its chat; /chat list shows the imported chats.")
      }
    } catch {
      await terminal.line(
        "error: Could not import: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func importArchive(from data: Data) throws -> MaiArchive {
    do {
      return try MaiArchive.decode(from: data)
    } catch let archiveError {
      let decoder = MaiJSONCoding.default.makeDecoder()
      guard let envelope = try? decoder.decode(ChatExportEnvelope.self, from: data),
        envelope.format == ChatExportEnvelope.format,
        envelope.version == 1
      else { throw archiveError }
      return MaiArchive(
        generator: envelope.generator, exportedAt: envelope.exportedAt, chats: [envelope.chat])
    }
  }

  private static func applyImportedArchive(
    _ archive: MaiArchive,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    visual: VisualBridge,
    selectImportedChat: Bool,
    terminal: TerminalWriter
  ) async throws -> [String] {
    var summary: [String] = []
    var importedConfiguration = configuration
    if let settings = archive.settings {
      guard let path = visual.configurationPath else {
        throw ArchiveImportError.configurationUnavailable
      }
      var draft = configuration ?? MaiConfiguration()
      let merged = try draft.mergeArchiveSettings(settings)
      try draft.save(to: URL(fileURLWithPath: path))
      importedConfiguration = draft
      configuration = draft
      summary.append(contentsOf: archiveSettingsSummary(merged))
    }

    if let skills = archive.skills {
      for skill in skills { try skill.install(in: visual.skills.userDirectory) }
      _ = await synchronizeSkillTools(runtime: runtime, state: visual.skills)
      summary.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
    }

    if let settings = archive.settings, let draft = importedConfiguration {
      await reloadImportedSettings(
        settings,
        configuration: draft,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        catalogs: &catalogs,
        providerBaseURLs: visual.providerBaseURLs,
        terminal: terminal)
    }

    if let chats = archive.chats {
      var existingIDs = Set(workspace.chats.map(\.id))
      var firstImported: AgentChat?
      for var chat in chats {
        if existingIDs.contains(chat.id) {
          chat.id = UUID()
          chat.sessionID = ChatSession.newID()
        }
        while !existingIDs.insert(chat.id).inserted { chat.id = UUID() }
        workspace.upsert(chat)
        if firstImported == nil { firstImported = chat }
      }
      if selectImportedChat, let firstImported {
        workspace.selectChat(id: firstImported.id)
        session = REPLSession(chat: firstImported)
      }
      summary.append("\(chats.count) chat\(chats.count == 1 ? "" : "s")")
    }
    return summary.isEmpty ? ["nothing"] : summary
  }

  private static func archiveSettingsSummary(_ summary: MaiArchiveMergeSummary) -> [String] {
    [
      (summary.providers, "provider"),
      (summary.prompts, "prompt"),
      (summary.mcpServers, "MCP server"),
      (summary.agents, "agent"),
    ].compactMap { item in
      let (count, name) = item
      return count == 0 ? nil : "\(count) \(name)\(count == 1 ? "" : "s")"
    }
  }

  private static func reloadImportedSettings(
    _ imported: MaiArchiveSettings,
    configuration: MaiConfiguration,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    catalogs: inout [MCPServerCatalog],
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let environment = ProcessInfo.processInfo.environment
    for requested in imported.providers ?? [] {
      guard let provider = configuration.providers.first(where: { $0.id == requested.id }) else {
        continue
      }
      do {
        try await runtime.register(
          plugins.makeProvider(from: provider, environment: environment), replacingExisting: true)
        if let url = provider.baseURL { providerBaseURLs.set(url, for: provider.id) }
      } catch {
        await terminal.line(
          "warning: Provider '\(provider.id)' was saved but could not be loaded: \(error.localizedDescription)",
          to: .standardError)
      }
    }

    for requested in imported.mcpServers ?? [] {
      guard let server = configuration.mcpServers.first(where: { $0.id == requested.id }) else {
        continue
      }
      _ = await runtime.unregisterMCP(serverID: server.id)
      catalogs.removeAll { $0.serverID == server.id }
      guard server.enabled else { continue }
      do {
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind, configuration: server, environment: environment)
        catalogs.append(try await runtime.register(mcp: source))
      } catch {
        await terminal.line(
          "warning: MCP server '\(server.id)' was saved but could not connect: \(error.localizedDescription)",
          to: .standardError)
      }
    }

    await runtime.configureDelegation(
      prompt: configuration.prompts?.delegation,
      workerInstructions: configuration.prompts?.worker)
    await runtime.configureCompaction(prompt: configuration.prompts?.compact)
    let knownTools = Set(await runtime.availableTools().map(\.name))
    for requested in imported.agents ?? [] {
      guard var agent = configuration.agents.first(where: { $0.id == requested.id }) else {
        continue
      }
      agent.toolNames.formIntersection(knownTools)
      do {
        try await runtime.register(agent: agent, replacingExisting: true)
      } catch {
        await terminal.line(
          "warning: Agent '\(agent.id)' was saved but could not be loaded: \(error.localizedDescription)",
          to: .standardError)
      }
    }
    if let agent = configuration.agents.first(where: { $0.id == session.profile.agentID }) {
      try? applyDefinition(agent, to: &session)
    }
  }

  private enum ArchiveImportError: LocalizedError {
    case configurationUnavailable

    var errorDescription: String? {
      "No writable configuration is active; chats and skills were not imported."
    }
  }

  /// `/stats`: the usage ledger the runtime fills after every model call,
  /// printed as one colored bar per provider:model for the combined ranking,
  /// speed, time in use, and efficiency. `/stats METRIC` shows one ranking; `/stats show TARGET`
  /// every fact recorded about a model or a provider.
  private static func handleStatsCommand(
    _ argument: String,
    store: ModelUsageStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let target = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
    func printReport(_ metrics: [ModelUsageReport.Metric]) async {
      let report = ModelUsageReport(await store.ledger)
      let colors = await terminal.paintsOutput
      // Headings in the cyan of `✓ took`, label and bar in the provider's
      // palette color, the number bold, the rest dim.
      let lines = report.lines(width: TerminalLineEditor.terminalColumns(), metrics: metrics) {
        text, style in
        guard colors else { return text }
        let code: String
        switch style {
        case .heading: code = "1;36"
        case .headline: code = "36"
        case .label(let color), .bar(let color):
          guard let colorCode = TerminalLineEditor.foregroundColorCode(color.hex) else {
            return text
          }
          code = colorCode
        case .value: code = "1"
        case .detail, .note: code = "2"
        }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
      }
      await terminal.line(lines.joined(separator: "\n"))
      if let error = await store.lastPersistenceError {
        await terminal.line(
          "warning: statistics could not be saved: \(error)", to: .standardError)
      }
    }
    if let metric = ModelUsageReport.Metric.named(action) {
      await printReport([metric])
      return
    }
    switch action {
    case "", "list":
      await printReport(ModelUsageReport.Metric.displayCases)
    case "show":
      guard !target.isEmpty else {
        await printReport(ModelUsageReport.Metric.displayCases)
        return
      }
      let rows = await store.ledger.totals(matching: target)
      guard !rows.isEmpty else {
        await terminal.line(noStatisticsMessage(for: target))
        return
      }
      await terminal.line(
        rows.map { row in
          ([row.title] + row.detailLines.map { "  " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n"))
    case "reset", "clear":
      await store.reset()
      await terminal.line("Usage statistics reset.")
    case "rm", "remove", "delete", "forget":
      guard !target.isEmpty else {
        await terminal.line("Usage: /stats rm PROVIDER[:MODEL]")
        return
      }
      switch await store.remove(matching: target) {
      case 0: await terminal.line(noStatisticsMessage(for: target))
      case 1: await terminal.line("Removed the statistics of '\(target)'.")
      case let count:
        await terminal.line(
          "Removed the statistics of \(count) models of provider '\(target)'.")
      }
    case "path":
      await terminal.line(
        await store.location?.path ?? "Statistics are kept in memory for this session only.")
    case "help":
      await terminal.line(statsHelp)
    default:
      await terminal.line("Unknown /stats action '\(action)'.\n" + statsHelp)
    }
  }

  private static func noStatisticsMessage(for target: String) -> String {
    "No statistics for '\(target)'. /stats lists the provider:model pairs."
  }

  private static let statsHelp = """
    Statistics commands:
      /stats                 Rank every provider:model by combined ranking, tokens/s, time in use, and efficiency
      /stats METRIC          One ranking: ranking, speed, time, or efficiency
      /stats show PROVIDER[:MODEL]  Every fact recorded about one model or a whole provider
      /stats rm PROVIDER[:MODEL]  Drop the statistics of one model or a whole provider
      /stats reset           Forget every statistic
      /stats path            Print the file the statistics are saved in
    The runtime records tokens (from the provider's usage, or estimated from text
    length and marked ~) and the wall-clock time of every model call, in the REPL,
    one-shot runs, and the visual workspace alike. Speed is visible output tokens
    over the streaming window; time in use adds the wait for the first token;
    efficiency is total tokens / (seconds in use × requests).
    """

  private static let exportHelp = """
    Export this chat as a document, or make a portable Mai archive:

      /export archive [PATH]    Providers, prompts, MCPs, agents, visible skills,
                                and this chat (.pocketmai.json)
      /export markdown [PATH]   A Markdown transcript (.md)
      /export json [PATH]       The chat as stored, in a JSON envelope (.json)
      /export debug [PATH]      The JSON plus the tools, settings, and every child agent's
                                transcript from this chat's runs
      /export html [PATH]       A self-contained HTML document
      /export epub [PATH]       An EPUB book, one chapter per message
      /export docx [PATH]       A Word document

    PATH may be a file or a folder; without it the file is named after the
    chat title and written to the current directory.

    Archives can contain credentials already stored literally in the
    configuration. Environment-variable and key-file references stay as references.
    """

  private static let importHelp = """
    Import a portable Mai archive into this project:

      /import PATH              Merge providers, prompts, MCPs, and agents; install
                                skills for the current user; add chats to this project

    Standalone .pocketmai.json archives and archives embedded by PocketMai are
    accepted. Existing settings are replaced only when their stable IDs or prompt
    names match; existing chats are never overwritten. Older pmai JSON chat exports
    are accepted too.
    """

  private static let replyHelp = """
    Answer the last assistant reply with it quoted above the answer:

      /reply                 Quote the last reply and open $EDITOR on it
      /reply WIDTH           Wrap the quote at WIDTH columns instead of the screen width

    Every quoted line is wrapped and prefixed with "> ", with a blank line left
    under it for the answer. Saving and leaving the editor sends the whole text
    as an ordinary message; leaving the quote untouched sends nothing.
    """

  private static let copyHelp = """
    Copy conversation text to the clipboard, or into a file:

      /copy                  The last assistant reply, without its reasoning
      /copy N                The last N messages, oldest first, labelled by role
      /copy PATH             The last reply, written to the file PATH
      /copy N PATH           The last N messages, written to the file PATH

    Tool calls, tool results, images, and other attachments are summarized on
    their own lines; system instructions are never copied. PATH may start with
    ~ and is resolved from the current directory; an existing file is replaced,
    and a folder is refused.
    """

  /// `/reply` answers the last assistant message the way the reply action in
  /// the iOS app does: its text is quoted at the terminal width, `$EDITOR` opens on
  /// the quote with room underneath, and what the editor leaves is sent as if
  /// it had been typed at the prompt. An optional argument overrides the width.
  private static func composeReply(
    _ argument: String,
    session: REPLSession,
    terminal: TerminalWriter
  ) async -> String? {
    let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    // Leave the terminal's final column unused to avoid an automatic wrap.
    // MarkdownQuote reserves two more columns for the `> ` marker, leaving
    // the quoted text itself the requested screen-width-minus-three columns.
    var width = max(3, TerminalLineEditor.terminalColumns() - 1)
    if !trimmed.isEmpty {
      guard let columns = Int(trimmed), columns > 2 else {
        await terminal.line(
          "Usage: /reply [WIDTH]   (the quote wraps to the screen width by default)"
        )
        return nil
      }
      width = columns
    }
    let reply: String
    do {
      reply = try TranscriptCopy.text(
        for: .lastAssistantReply, in: session.history.messages
      ).text
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return nil
    }
    let quoted = MarkdownQuote.quote(reply, lineWidth: width)
    return await composeMessage(
      from: quoted + "\n\n",
      suffix: "reply.md",
      unchanged: "Reply cancelled: nothing was written under the quote.",
      terminal: terminal)
  }

  /// `/edit input` writes the next message in the editor instead of at the
  /// prompt, which is the room `/reply` gives without a quote to answer.
  private static func composeInput(terminal: TerminalWriter) async -> String? {
    await composeMessage(
      from: "",
      suffix: "input.md",
      unchanged: "Nothing to send: the editor left the file empty.",
      terminal: terminal)
  }

  /// Opens the editor on a draft message and returns what it left, for the
  /// caller to send as if it had been typed at the prompt. A file that comes
  /// back empty, or exactly as it went in, sends nothing.
  private static func composeMessage(
    from draft: String,
    suffix: String,
    unchanged note: String,
    terminal: TerminalWriter
  ) async -> String? {
    guard let edited = await editTemporaryText(draft, suffix: suffix, terminal: terminal)
    else { return nil }
    let message = edited.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, message != draft.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      await terminal.line(note)
      return nil
    }
    return message
  }

  /// `/copy [N] [PATH]`: the last reply or the last N messages, on the system
  /// clipboard or, when PATH is given, in that file.
  private static func copyToClipboard(
    _ argument: String,
    session: REPLSession,
    terminal: TerminalWriter
  ) async {
    if argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "help" {
      await terminal.line(copyHelp)
      return
    }
    do {
      let command = try TranscriptCopy.command(parsing: argument)
      let result = try TranscriptCopy.text(for: command.selection, in: session.history.messages)
      let count = result.messages.count
      let subject =
        command.selection == .lastAssistantReply
        ? "the last reply" : "\(count) message\(count == 1 ? "" : "s")"
      let destination: String
      if let path = command.path {
        destination = try writeCopiedText(result.text, to: path).path
      } else {
        try SystemClipboard.write(result.text)
        destination = "the clipboard"
      }
      await terminal.line(
        "Copied \(subject) (\(result.text.count) characters) to \(destination).")
    } catch let error as TranscriptCopyError {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      if case .invalidCount = error { await terminal.line("Usage: /copy [N] [PATH] (/help copy)") }
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Writes `/copy` output to a file: `~` expands, a relative path resolves
  /// against the working directory, an existing file is replaced, and a folder
  /// is refused rather than inventing a name inside it. Text files end with a
  /// newline even though clipboard text does not.
  private static func writeCopiedText(_ text: String, to path: String) throws -> URL {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let expanded = NSString(string: path).expandingTildeInPath
    let target = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
    if path.hasSuffix("/") || (exists && isDirectory.boolValue) {
      throw CLIError.isDirectory(target.path)
    }
    let parent = target.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw CLIError.missingFolder(parent.path) }
    let contents = text.hasSuffix("\n") ? text : text + "\n"
    try contents.write(to: target, atomically: true, encoding: .utf8)
    return target
  }

  /// `/attach PATH` converts a document to text the model can read and queues it
  /// for the next message; `/attach clear` drops everything queued so far.
  private static func attachDocument(
    _ argument: String,
    session: inout REPLSession,
    ocrProvider: any OCRProvider,
    editor: TerminalLineEditor?,
    terminal: TerminalWriter
  ) async {
    var trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /attach [source|markdown|copy] PATH | /attach clear")
      await terminal.line(
        "Word, EPUB and PDF files become Markdown, JSON becomes an outline, arbitrary text/source files attach as they are, and images attach at medium size. HTML asks whether to attach its source, convert it to Markdown, or copy it into the working directory."
      )
      return
    }
    if trimmed.lowercased() == "clear" {
      let count = session.pendingContent.count
      session.pendingContent.removeAll()
      await terminal.line(
        count == 0
          ? "No pending attachments."
          : "Dropped \(count) pending attachment\(count == 1 ? "" : "s").")
      return
    }
    var htmlChoice: String?
    if trimmed.first != "\"" && trimmed.first != "'" {
      let fields = trimmed.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
        String.init)
      if fields.count == 2,
        ["source", "markdown", "copy"].contains(fields[0].lowercased())
      {
        htmlChoice = fields[0].lowercased()
        trimmed = fields[1]
      }
    }
    if trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'",
      trimmed.last == first
    {
      trimmed = String(trimmed.dropFirst().dropLast())
    }
    let path = NSString(string: trimmed).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    do {
      let data = try DocumentAttachmentImporter.data(at: url)
      let kind = DocumentAttachmentImporter.kind(for: data, filename: url.lastPathComponent)
      if kind == .image {
        session.pendingContent.append(
          try await imageContent(path: path, mode: .medium, ocrProvider: ocrProvider))
        await terminal.line(
          "Image queued at medium size: \(url.lastPathComponent). Use /image for other sizes or OCR."
        )
        return
      }
      if htmlChoice != nil, kind != .html {
        await terminal.line(
          "error: source, markdown, and copy choices apply only to HTML files.",
          to: .standardError)
        return
      }
      if kind == .html, htmlChoice == nil {
        guard isatty(STDIN_FILENO) != 0, let editor else {
          await terminal.line(
            "HTML needs a choice: /attach source \(trimmed), /attach markdown \(trimmed), or /attach copy \(trimmed).",
            to: .standardError)
          return
        }
        await terminal.line("Import \(url.lastPathComponent) as HTML source, Markdown, or a working-directory file?")
        let answer = editor.readLine(
          prompt: "html [source/markdown/copy/cancel]> ",
          completions: ["source", "markdown", "copy", "cancel"],
          rememberInput: false)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !editor.wasInterrupted, let answer, !["cancel", "c", ""].contains(answer) else {
          await terminal.line("HTML import cancelled.")
          return
        }
        switch answer {
        case "source", "s", "1": htmlChoice = "source"
        case "markdown", "md", "m", "2": htmlChoice = "markdown"
        case "copy", "file", "3": htmlChoice = "copy"
        default:
          await terminal.line("HTML import cancelled: unknown choice '\(answer)'.")
          return
        }
      }
      if htmlChoice == "copy" {
        let destination = try DocumentAttachmentImporter.copy(
          data: data,
          filename: url.lastPathComponent,
          into: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true),
          sourceURL: url)
        await terminal.line("Copied HTML to \(destination.path).")
        return
      }
      let attachment = try DocumentAttachmentImporter.attachment(
        data: data,
        filename: url.lastPathComponent,
        htmlMode: htmlChoice == "markdown" ? .markdown : .source)
      session.pendingContent.append(attachment.content)
      var message = "Attached \(attachment.name) (\(attachment.characterCount) characters"
      if let note = attachment.note { message += ", \(note)" }
      message += "); it is sent with the next message."
      await terminal.line(message)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  #if PMAI_HAS_VISUAL
    /// Hands the terminal to the SwiftTUI workspace and adopts its focused
    /// conversation, registrations, and configuration draft when it returns.
    private static func runVisualMode(
      session: inout REPLSession,
      runtime: AgentRuntime,
      plugins: PluginRegistry,
      ocrProvider: any OCRProvider,
      configuration: inout MaiConfiguration?,
      catalogs: inout [MCPServerCatalog],
      visual: VisualBridge,
      terminal: TerminalWriter
    ) async {
      guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
        await terminal.line("Visual mode needs an interactive terminal.", to: .standardError)
        return
      }
      let screen = TerminalScreen.current
      screen?.deactivate()
      defer { screen?.resume() }
      let launch = VisualLaunch(
        focusedConversation: session.visualSeed(),
        snapshot: session.visualSnapshot,
        configuration: configuration ?? MaiConfiguration(providers: visual.implicitProviders),
        configurationPath: visual.configurationPath,
        catalogs: catalogs,
        environment: ProcessInfo.processInfo.environment,
        commandHandler: { request in
          await runVisualCommand(
            request,
            runtime: runtime,
            plugins: plugins,
            ocrProvider: ocrProvider,
            visual: visual)
        })
      let approvals = VisualApprovalHandler {
        await visual.approvalHandler.setYOLOEnabled(true)
      }
      await visual.approvalHandler.setDelegate(approvals)
      do {
        let outcome = try await VisualMode.run(
          launch,
          runtime: runtime,
          plugins: plugins,
          approvals: approvals)
        await visual.approvalHandler.setDelegate(nil)
        session.adopt(outcome.focusedConversation)
        session.visualSnapshot = outcome.snapshot
        catalogs = outcome.catalogs
        if outcome.configurationChanged || configuration != nil {
          configuration = outcome.configuration
        }
        await terminal.line(outcome.summary)
      } catch {
        await visual.approvalHandler.setDelegate(nil)
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    }

    /// Runs a slash command typed into a visual pane exactly as the REPL would,
    /// on a session built from that pane's conversation, and returns what it
    /// printed together with the conversation it left behind.
    private static func runVisualCommand(
      _ request: VisualCommandRequest,
      runtime: AgentRuntime,
      plugins: PluginRegistry,
      ocrProvider: any OCRProvider,
      visual: VisualBridge
    ) async -> VisualCommandOutcome {
      let command =
        request.input.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).first.map(
          String.init) ?? request.input
      switch command {
      case "/visual":
        return VisualCommandOutcome(
          output: "Already in visual mode. /exit or Ctrl+C returns to the REPL.",
          conversation: request.conversation)
      case "/exit", "/quit":
        return VisualCommandOutcome(
          output: "Leaving visual mode.",
          conversation: request.conversation,
          leavesVisualMode: true)
      default:
        break
      }

      var session = REPLSession(
        profile: SessionProfile(definition: request.conversation.profile),
        pendingContent: request.conversation.pendingContent)
      session.history.replaceAll(with: request.conversation.messages)
      var configuration: MaiConfiguration? = request.configuration
      var catalogs = request.catalogs
      let terminal = TerminalWriter(capturesOutput: true)
      _ = await handleCommand(
        request.input,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        ocrProvider: ocrProvider,
        configuration: &configuration,
        catalogs: &catalogs,
        visual: visual,
        terminal: terminal)
      var output = await terminal.drainCaptured()
      if request.input.trimmingCharacters(in: .whitespacesAndNewlines) == "/help" {
        output +=
          "\nIn visual mode, /exit returns to the REPL and the output above closes with Esc."
      }
      if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "Done." }
      var conversation = request.conversation
      conversation.profile = session.profile.agentDefinition
      conversation.messages = session.history.messages
      conversation.pendingContent = session.pendingContent
      return VisualCommandOutcome(output: output, conversation: conversation)
    }
  #endif

  private static func handleWorkspaceChatCommand(
    _ argument: String,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    chatProcess: AgentPID? = nil,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = parts.first?.lowercased(), !action.isEmpty else {
      await terminal.line(chatHelp)
      return
    }
    let rest = String(argument.dropFirst(action.count)).trimmingCharacters(
      in: .whitespacesAndNewlines)

    switch action {
    case "list", "chats", "ls":
      guard let scope = ChatListScope(rest) else {
        await terminal.line("Usage: /chat list [active|archived|all]")
        return
      }
      await terminal.line(chatListing(workspace, scope: scope, selectedID: session.id))
    case "new":
      var profile = session.profile
      var title = rest
      var explicitAgent = false
      if title.hasPrefix("--agent ") {
        let values = title.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
          String.init)
        guard values.count >= 2,
          let agent = configuration?.agents.first(where: { $0.id == values[1] })
        else {
          await terminal.line("Usage: /chat new [--agent ID] [TITLE]")
          return
        }
        profile = SessionProfile(definition: agent)
        title = values.count == 3 ? values[2] : ""
        explicitAgent = true
      }
      if title.isEmpty, !explicitAgent, session.chat.isDisposable {
        await terminal.line("Already in a new chat.")
        return
      }
      let chat = workspace.startNewChat(
        primaryAgent: profile.agentDefinition,
        title: title.isEmpty ? nil : title)
      session = REPLSession(chat: chat)
      await terminal.line("Started chat '\(chat.displayTitle)' with agent \(profile.agentID).")
    case "use", "switch", "open":
      guard !rest.isEmpty, let chat = resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat use INDEX|ID|TITLE")
        return
      }
      guard chat.id != session.id else {
        await terminal.line("Already in '\(chat.displayTitle)'.")
        return
      }
      await switchSession(
        to: chat, session: &session, workspace: &workspace, configuration: configuration,
        terminal: terminal)
    case "next", "previous", "prev":
      let ordered = workspace.orderedChats
      guard ordered.count > 1,
        let current = ordered.firstIndex(where: { $0.id == session.id })
      else {
        await terminal.line("There is only one chat.")
        return
      }
      let offset = action == "next" ? 1 : -1
      let chat = ordered[(current + offset + ordered.count) % ordered.count]
      await switchSession(
        to: chat, session: &session, workspace: &workspace, configuration: configuration,
        terminal: terminal)
    case "info", "show":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat info [INDEX|ID|TITLE]")
        return
      }
      await terminal.line(chatInfo(chat, workspace: workspace, selectedID: session.id))
    case "session":
      switch rest.lowercased() {
      case "":
        await terminal.line("Session: \(session.sessionID)")
      case "new":
        // A fresh session for the same chat: a backend that meters by session
        // sees a new one from the next message on, and nothing else changes.
        session.sessionID = ChatSession.newID()
        session.touch()
        workspace.upsert(session.chat, selecting: true)
        await terminal.line("Session: \(session.sessionID) (new)")
      default:
        await terminal.line("Usage: /chat session [new]")
      }
    case "rename":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /chat rename TITLE")
        return
      }
      session.title = rest
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      await terminal.line("Chat renamed to '\(rest)'.")
    case "archive":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat archive [INDEX|ID|TITLE]")
        return
      }
      guard !chat.isArchived else {
        await terminal.line("'\(chat.displayTitle)' is already archived.")
        return
      }
      guard !chat.isDisposable else {
        await terminal.line("'\(chat.displayTitle)' is empty; there is nothing to archive.")
        return
      }
      guard chat.id == session.id else {
        workspace.setArchived(true, id: chat.id)
        await terminal.line("Archived '\(chat.displayTitle)'.")
        return
      }
      session.isArchived = true
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      session = REPLSession(
        chat: workspace.startNewChat(primaryAgent: session.profile.agentDefinition))
      await terminal.line("Archived '\(chat.displayTitle)' and started a new chat.")
    case "unarchive", "restore":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat unarchive INDEX|ID|TITLE")
        return
      }
      guard chat.isArchived else {
        await terminal.line("'\(chat.displayTitle)' is not archived.")
        return
      }
      if chat.id == session.id {
        session.isArchived = false
        session.touch()
        workspace.upsert(session.chat, selecting: true)
      } else {
        workspace.setArchived(false, id: chat.id)
      }
      await terminal.line("Restored '\(chat.displayTitle)' to the active chats.")
    case "close", "delete":
      guard parts.count == 2, parts[1].lowercased() == "confirm" else {
        await terminal.line("Closing a chat is permanent. Confirm with: /chat close confirm")
        return
      }
      let closed = session.chat
      _ = workspace.removeChat(id: closed.id)
      if let next = workspace.activeChats.first ?? workspace.orderedChats.first {
        _ = workspace.selectChat(id: next.id)
        session = REPLSession(
          chat: chatApplyingConfiguredAgentSettings(next, configuration: configuration))
        await terminal.line("Closed '\(closed.displayTitle)'; switched to '\(session.title)'.")
      } else {
        session = REPLSession(
          chat: workspace.startNewChat(primaryAgent: session.profile.agentDefinition))
        await terminal.line("Closed '\(closed.displayTitle)'; started a new chat.")
      }
    case "messages":
      await handleChatCommand(
        "list",
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        chatProcess: chatProcess,
        terminal: terminal)
    case "log", "edit", "remove", "rm", "undo", "trim", "compact", "clear", "help":
      await handleChatCommand(
        argument,
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        chatProcess: chatProcess,
        terminal: terminal)
    default:
      await terminal.line("Unknown /chat action '\(action)'.\n\n\(chatHelp)")
    }
  }

  private static func switchSession(
    to chat: AgentChat,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    _ = workspace.selectChat(id: chat.id)
    session = REPLSession(
      chat: chatApplyingConfiguredAgentSettings(chat, configuration: configuration))
    let status = chat.isArchived ? ", archived" : ""
    await terminal.line(
      "Switched to '\(chat.displayTitle)' (agent \(chat.primaryAgent.id)\(status)).")
  }

  private enum ChatListScope {
    case active, archived, all

    init?(_ raw: String) {
      switch raw.lowercased() {
      case "", "all": self = .all
      case "active", "open": self = .active
      case "archived", "archive", "old": self = .archived
      default: return nil
      }
    }
  }

  /// Chats grouped the way the PocketMai sidebar groups them: active chats
  /// under Today / Yesterday / This week / Last week / date headers, newest
  /// first, then the archived ones. Indexes match `/chat use N`.
  private static func handleProjectCommand(
    _ argument: String,
    project: inout AgentProject,
    home: AgentHome,
    store: AgentChatStore,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = parts.first?.lowercased() ?? "info"
    let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

    switch action {
    case "info", "show":
      await terminal.line(projectInfo(project, home: home, store: store))
    case "list", "ls", "projects":
      do {
        await terminal.line(
          projectListing(try home.loadProjectIndex(), currentID: project.id, now: Date()))
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "name", "rename":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /project name NAME")
        return
      }
      project.rename(to: rest)
      await saveProject(
        project, home: home, terminal: terminal,
        success: "Project renamed to '\(project.displayName)'.")
    case "tint", "color", "colour":
      let presets = AgentProjectTint.presetNames.joined(separator: ", ")
      guard !rest.isEmpty else {
        await terminal.line(
          "Tint: \(project.tint?.rawValue ?? "none"). Presets: \(presets); or #RRGGBB; none clears it."
        )
        return
      }
      if ["none", "off", "default", "-"].contains(rest.lowercased()) {
        project.tint = nil
        await saveProject(project, home: home, terminal: terminal, success: "Project tint cleared.")
        return
      }
      guard let tint = AgentProjectTint(rawValue: rest) else {
        await terminal.line("Unknown tint '\(rest)'. Use one of \(presets), or #RRGGBB.")
        return
      }
      project.tint = tint
      await saveProject(
        project, home: home, terminal: terminal, success: "Project tint set to \(tint.rawValue).")
    case "forget":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /project forget INDEX|PATH|NAME")
        return
      }
      do {
        let index = try home.loadProjectIndex()
        guard let target = resolveProject(rest, in: index) else {
          await terminal.line("No project matches '\(rest)'. /project list shows them.")
          return
        }
        guard target.id != project.id else {
          await terminal.line("'\(target.displayName)' is the open project; it stays listed.")
          return
        }
        _ = try home.forgetProject(id: target.id)
        await terminal.line(
          "Forgot '\(target.displayName)'. Its files in \(target.workingDirectory) were left alone."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "help":
      await terminal.line(projectHelp)
    default:
      await terminal.line("Unknown /project action '\(action)'.\n\n\(projectHelp)")
    }
  }

  private static func saveProject(
    _ project: AgentProject,
    home: AgentHome,
    terminal: TerminalWriter,
    success: String
  ) async {
    do {
      try home.saveProject(project)
      await terminal.line(success)
    } catch {
      await terminal.line(
        "warning: the project was not saved: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func resolveProject(_ selector: String, in index: AgentProjectIndex)
    -> AgentProject?
  {
    let ordered = index.orderedProjects
    if let number = Int(selector), number >= 1, number <= ordered.count {
      return ordered[number - 1]
    }
    let path = AgentProject.standardizedPath(selector)
    if let match = index.project(atWorkingDirectory: path) { return match }
    let lowered = selector.lowercased()
    if let match = ordered.first(where: { $0.id.uuidString.lowercased().hasPrefix(lowered) }) {
      return match
    }
    return ordered.first { $0.displayName.lowercased() == lowered }
  }

  private static func projectInfo(
    _ project: AgentProject,
    home: AgentHome,
    store: AgentChatStore
  ) -> String {
    let summaries = (try? store.loadSummaries()) ?? []
    let archived = summaries.filter(\.isArchived).count
    let nameNote =
      project.hasCustomName ? "" : " (from the directory; /project name NAME renames it)"
    return [
      "Name:      \(project.displayName)\(nameNote)",
      "Directory: \(project.workingDirectory)",
      "Tint:      \(project.tint?.rawValue ?? "none")",
      "Chats:     \(summaries.count - archived) active, \(archived) archived",
      "Storage:   \(store.directoryURL.path)",
      "Index:     \(home.projectIndexURL.path)",
      "ID:        \(project.id.uuidString)",
      "Created:   \(ChatDatePresentation.timestamp(project.createdAt))",
      "Opened:    \(ChatDatePresentation.timestamp(project.lastOpenedAt))",
    ].joined(separator: "\n")
  }

  private static func projectListing(
    _ index: AgentProjectIndex,
    currentID: UUID?,
    now: Date
  ) -> String {
    let projects = index.orderedProjects
    guard !projects.isEmpty else {
      return "No projects yet. pmai registers the directory it is started in."
    }
    var lines = ["Projects, most recently opened first:"]
    for (offset, project) in projects.enumerated() {
      let marker = project.id == currentID ? "*" : " "
      let number = offset < 9 ? " \(offset + 1)" : "\(offset + 1)"
      var notes: [String] = []
      if let tint = project.tint { notes.append(tint.rawValue) }
      if !project.workingDirectoryExists { notes.append("missing") }
      lines.append(
        [
          "\(marker) \(number)", padded(project.displayName, width: 24),
          padded(abbreviatedPath(project.workingDirectory), width: 44),
          padded(notes.joined(separator: ", "), width: 12),
          ChatDatePresentation.compactTimestamp(project.lastOpenedAt, relativeTo: now),
        ].joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
  }

  /// Shortens a path the way shells print it: `~` for home, and the head
  /// elided when it is still too long, keeping the tail people recognize.
  private static func abbreviatedPath(_ path: String, width: Int = 44) -> String {
    var shown = path
    let home = AgentHome.userHomeDirectory().path
    if shown == home {
      shown = "~"
    } else if shown.hasPrefix(home + "/") {
      shown = "~" + shown.dropFirst(home.count)
    }
    guard shown.count > width else { return shown }
    return "…" + shown.suffix(width - 1)
  }

  private static func chatListing(
    _ workspace: AgentChatWorkspace,
    scope: ChatListScope,
    selectedID: UUID?,
    now: Date = Date()
  ) -> String {
    let ordered = workspace.orderedChats
    var lines: [String] = []
    func append(_ chats: [AgentChat], header: (AgentChat) -> String) {
      var previous: String?
      for chat in chats {
        let title = header(chat)
        if title != previous {
          lines.append(title)
          previous = title
        }
        let index = (ordered.firstIndex { $0.id == chat.id } ?? 0) + 1
        lines.append(chatRow(chat, index: index, selected: chat.id == selectedID, now: now))
      }
    }
    if scope != .archived {
      let active = workspace.activeChats
      if active.isEmpty { lines.append("No active chats.") }
      append(active) { ChatDatePresentation.groupTitle(for: $0.updatedAt, relativeTo: now) }
    }
    if scope != .active {
      let archived = workspace.archivedChats
      if archived.isEmpty, scope == .archived { lines.append("No archived chats.") }
      append(archived) { _ in "Archived" }
    }
    return lines.joined(separator: "\n")
  }

  private static func chatRow(_ chat: AgentChat, index: Int, selected: Bool, now: Date) -> String {
    let marker = selected ? "*" : " "
    let number = index < 10 ? " \(index)" : "\(index)"
    let count = chat.conversationMessages.count
    let size = count == 0 ? "empty" : "\(count) msg"
    return [
      "\(marker) \(number)", String(chat.id.uuidString.prefix(8)),
      padded(chat.displayTitle, width: 40), padded(chat.primaryAgent.id, width: 10),
      padded(size, width: 8),
      ChatDatePresentation.compactTimestamp(chat.updatedAt, relativeTo: now),
    ].joined(separator: "  ")
  }

  private static func chatInfo(
    _ chat: AgentChat,
    workspace: AgentChatWorkspace,
    selectedID: UUID?
  ) -> String {
    let index = (workspace.orderedChats.firstIndex { $0.id == chat.id } ?? 0) + 1
    let count = chat.conversationMessages.count
    var status = chat.isArchived ? "archived" : "active"
    if chat.id == selectedID { status += ", current" }
    var lines = [
      "Title:    \(chat.displayTitle)",
      "Index:    \(index)",
      "ID:       \(chat.id.uuidString)",
      "Session:  \(chat.sessionID)",
      "Agent:    \(chat.primaryAgent.id) (\(chat.primaryAgent.provider) / \(chat.primaryAgent.model))",
      "Messages: \(count) conversation, \(chat.messages.count) total",
      "Started:  \(ChatDatePresentation.timestamp(chat.createdAt))",
      "Updated:  \(ChatDatePresentation.timestamp(chat.updatedAt)) (\(ChatDatePresentation.groupTitle(for: chat.updatedAt)))",
      "Status:   \(status)",
    ]
    if !chat.pendingContent.isEmpty {
      lines.append("Pending:  \(chat.pendingContent.count) attachment(s) queued")
    }
    if !chat.subagents.isEmpty {
      let running = chat.subagents.filter { !$0.state.isTerminal }.count
      lines.append(
        "Agents:   \(chat.subagents.count) started by its runs"
          + (running > 0 ? ", \(running) still running when last saved" : "")
          + " (/agents tree lists them)")
    }
    return lines.joined(separator: "\n")
  }

  private static func padded(_ text: String, width: Int) -> String {
    let count = text.count
    guard count <= width else { return String(text.prefix(width - 3)) + "..." }
    return text + String(repeating: " ", count: width - count)
  }

  private static func resolveChat(
    _ selector: String,
    in workspace: AgentChatWorkspace
  ) -> AgentChat? {
    let ordered = workspace.orderedChats
    if let index = Int(selector), ordered.indices.contains(index - 1) {
      return ordered[index - 1]
    }
    if let id = UUID(uuidString: selector) {
      return ordered.first { $0.id == id }
    }
    let idMatches = ordered.filter {
      $0.id.uuidString.lowercased().hasPrefix(selector.lowercased())
    }
    if idMatches.count == 1 { return idMatches[0] }
    let titleMatches = ordered.filter {
      $0.displayTitle.caseInsensitiveCompare(selector) == .orderedSame
    }
    return titleMatches.count == 1 ? titleMatches[0] : nil
  }

  private static func handleChatCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    compactPrompt: String?,
    chatProcess: AgentPID? = nil,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = parts.first?.lowercased(), !action.isEmpty else {
      await terminal.line(chatHelp)
      return
    }
    let actionArgument = String(argument.dropFirst(parts[0].count))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    switch action {
    case "list":
      await terminal.line(conversationLog(session: session, full: false))
    case "log":
      let renderer = await terminal.markdownRenderer
      await terminal.line(
        conversationLog(session: session, full: true) { text in
          guard let renderer else { return text }
          var rendered = renderer.render(text)
          while rendered.hasSuffix("\n") { rendered.removeLast() }
          return rendered
        })
    case "edit":
      guard parts.count == 3, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /chat edit INDEX TEXT")
        return
      }
      do {
        try session.history.editMessage(at: index, text: parts[2])
        await terminal.line("Edited message \(index + 1).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "remove", "delete", "rm":
      guard parts.count >= 2, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /chat remove INDEX")
        return
      }
      await removeChatMessage(at: index, session: &session, terminal: terminal)
    case "undo":
      let index: Int?
      if parts.count >= 2 {
        index = chatIndex(parts[1], count: session.history.count)
      } else {
        index = session.history.messages.lastIndex(where: { $0.role != .system })
      }
      guard let index else {
        await terminal.line(
          session.history.isEmpty ? "No messages to undo." : "No conversation messages to undo.")
        return
      }
      await removeChatMessage(at: index, session: &session, terminal: terminal)
    case "trim":
      guard parts.count >= 2, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /chat trim INDEX")
        return
      }
      do {
        let removed = try session.history.trim(through: index)
        if removed.isEmpty {
          await terminal.line("Nothing follows message \(index + 1).")
        } else {
          await terminal.line(
            "Trimmed \(removed.count) message\(removed.count == 1 ? "" : "s"); kept through message \(session.history.count)."
          )
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "compact":
      await compactChat(
        focus: actionArgument,
        promptTemplate: compactPrompt,
        session: &session,
        runtime: runtime,
        terminal: terminal)
    case "clear":
      session.reset()
      if let chatProcess { await runtime.supervisor.clearFinished(under: chatProcess) }
      await terminal.line("Conversation cleared.")
    case "help":
      await terminal.line(chatHelp)
    default:
      await terminal.line("Unknown /chat action '\(action)'.\n\n\(chatHelp)")
    }
  }

  private static func removeChatMessage(
    at index: Int,
    session: inout REPLSession,
    terminal: TerminalWriter
  ) async {
    do {
      let removed = try session.history.removeMessage(at: index)
      let suffix = removed.count == 1 ? "" : " (including linked tool messages)"
      await terminal.line(
        "Removed \(removed.count) message\(removed.count == 1 ? "" : "s")\(suffix).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static let defaultCompactPrompt = AgentCompactionPrompt.template

  /// Ask the selected model for durable context using the configured prompt
  /// template, then replace the transcript while retaining system instructions.
  private static func compactChat(
    focus: String,
    promptTemplate: String?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    let spoken = session.history.messages.filter {
      ($0.role == .user || $0.role == .assistant)
        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard spoken.count >= 2 else {
      await terminal.line("Nothing to compact yet.")
      return
    }
    let configuredTemplate = promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard configuredTemplate.isEmpty || configuredTemplate.contains("{{transcript}}") else {
      await terminal.line(
        "error: The compact prompt must contain {{transcript}}. Edit it with /edit compact.",
        to: .standardError)
      return
    }
    // The same prompt and transcript rendering autocompact uses, so a summary
    // reads the same whether a person or the runtime asked for it.
    let prompt = AgentCompactionPrompt.render(
      transcript: AgentCompactionPrompt.transcript(of: session.history.messages),
      focus: focus,
      template: configuredTemplate)
    let profile = session.profile
    let request = AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: [.user(prompt)],
      toolNames: [],
      subagentNames: [],
      toolChoice: .none,
      responseFormat: .text,
      options: profile.options,
      limits: profile.limits,
      stream: false,
      toolCallingStrategy: .automatic,
      useToolProxy: false,
      retry: profile.retry,
      sessionID: session.sessionID)
    await terminal.line("Compacting conversation…")
    do {
      let result = try await runtime.run(request) { _ in }
      let summary =
        result.transcript.last(where: { $0.role == .assistant })?.text
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !summary.isEmpty else {
        await terminal.line("error: Compact returned an empty summary.", to: .standardError)
        return
      }
      var compacted: [AgentMessage] = []
      if !profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        compacted.append(.system(profile.instructions))
      }
      compacted.append(.system("Conversation summary (compacted):\n\n\(summary)"))
      session.history.replaceAll(with: compacted)
      session.pendingContent.removeAll()
      session.touch()
      await terminal.line("Conversation compacted into a summary.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func chatIndex(_ raw: String, count: Int) -> Int? {
    guard let value = Int(raw), value != 0 else { return nil }
    let index = value > 0 ? value - 1 : count + value
    return (0..<count).contains(index) ? index : nil
  }

  private static func conversationLog(
    session: REPLSession,
    full: Bool,
    renderText: (String) -> String = { $0 }
  ) -> String {
    guard !session.history.isEmpty else { return "No conversation messages yet." }
    var lines = [full ? "# Full conversation log" : "Conversation log:"]
    if !full { lines.append("-----------------") }
    for (index, message) in session.history.messages.enumerated() {
      let role = message.role.rawValue.capitalized
      if full {
        lines.append("\n## [\(index + 1)] \(role) (id: \(message.id))")
        lines.append(
          message.content.map { renderFullContent($0, renderText: renderText) }
            .joined(separator: "\n"))
        lines.append("--------------------")
      } else {
        lines.append("[\(index + 1)] \(role): \(messagePreview(message))")
      }
    }
    lines.append("\nTotal messages: \(session.history.count)")
    if !session.pendingContent.isEmpty {
      lines.append(
        "Pending for next message: \(session.pendingContent.map(renderCompactContent).joined(separator: ", "))"
      )
    }
    return lines.joined(separator: "\n")
  }

  private static func messagePreview(_ message: AgentMessage) -> String {
    let rendered = message.content.map(renderCompactContent).joined(separator: " ")
      .replacingOccurrences(of: "\n", with: " ")
    guard rendered.count > 120 else { return rendered }
    return String(rendered.prefix(117)) + "..."
  }

  private static func renderCompactContent(_ part: ContentPart) -> String {
    switch part {
    case .text(let text):
      text
    case .image(let image):
      "[image \(image.name ?? image.mimeType)]"
    case .file(let file):
      "[file \(file.name)]"
    case .audio(let audio):
      "[audio \(audio.name ?? audio.mimeType)]"
    case .resource(let resource):
      "[resource \(resource.name ?? resource.uri)]"
    case .reasoning(let reasoning):
      "[reasoning] \(reasoning)"
    case .toolCall(let call):
      "[tool call \(call.name) \(call.arguments.compactJSONString)]"
    case .toolResult(let result):
      "[tool result \(result.callID)\(result.isError ? " error" : "")] \(result.text)"
    }
  }

  private static func renderFullContent(
    _ part: ContentPart,
    renderText: (String) -> String = { $0 }
  ) -> String {
    switch part {
    case .text(let text):
      return renderText(text)
    case .image(let image):
      return
        "[image name=\(image.name ?? "-") mime=\(image.mimeType) source=\(binarySourceSummary(image.source))]"
    case .file(let file):
      return
        "[file name=\(file.name) mime=\(file.mimeType)\(file.source.map { " source=\(binarySourceSummary($0))" } ?? "")]\(file.text.map { "\n\($0)" } ?? "")"
    case .audio(let audio):
      return
        "[audio name=\(audio.name ?? "-") mime=\(audio.mimeType) source=\(binarySourceSummary(audio.source))]"
    case .resource(let resource):
      return
        "[resource name=\(resource.name ?? "-") uri=\(resource.uri) mime=\(resource.mimeType ?? "-")]\(resource.text.map { "\n\($0)" } ?? "")"
    case .reasoning(let reasoning):
      return "[reasoning]\n\(reasoning)"
    case .toolCall(let call):
      return "[tool call name=\(call.name) id=\(call.id)]\n\(call.arguments.compactJSONString)"
    case .toolResult(let result):
      var value = "[tool result call=\(result.callID) status=\(result.isError ? "error" : "ok")]"
      if !result.content.isEmpty {
        value += "\n" + result.content.map { renderFullContent($0) }.joined(separator: "\n")
      }
      if let structured = result.structuredContent {
        value += "\n[structured content]\n\(structured.compactJSONString)"
      }
      return value
    }
  }

  private static func binarySourceSummary(_ source: BinarySource) -> String {
    switch source {
    case .data(let data): "inline:\(data.count)-bytes"
    case .url(let url): url.absoluteString
    }
  }

  private static func defaultConfigurationPath(environment: [String: String]) -> String {
    AgentHome.expandUserPath("~/.config/pmai/config.json", environment: environment)
  }

  /// Where pmai kept chats and history before projects existed.
  private static let legacyStateDirectory = "~/.config/pmai"

  private static func resolvedHome(options: CLIOptions, environment: [String: String])
    -> AgentHome
  {
    if let path = options.homePath {
      return AgentHome(
        rootURL: URL(
          fileURLWithPath: AgentHome.expandUserPath(path, environment: environment),
          isDirectory: true))
    }
    return AgentHome.resolve(environment: environment)
  }

  /// Pre-project state is adopted only into the default home: a relocated
  /// home is a deliberate fresh setup, and scratch runs must not touch the
  /// files under the real home directory.
  private static func usesDefaultHome(options: CLIOptions, environment: [String: String])
    -> Bool
  {
    options.homePath == nil
      && (environment[AgentHome.environmentVariable] ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
  }

  private static func resolvedChatStore(
    options: CLIOptions,
    home: AgentHome,
    project: AgentProject,
    environment: [String: String]
  ) -> AgentChatStore {
    if let path = options.statePath {
      return AgentChatStore(
        directoryURL: URL(
          fileURLWithPath: AgentHome.expandUserPath(path, environment: environment),
          isDirectory: true))
    }
    return home.chatStore(for: project)
  }

  /// The shared input history, copied once from its pre-project location.
  private static func resolvedHistoryURL(
    options: CLIOptions,
    home: AgentHome,
    environment: [String: String]
  ) -> URL {
    if let path = options.historyPath {
      return URL(fileURLWithPath: AgentHome.expandUserPath(path, environment: environment))
    }
    let url = home.historyURL
    let legacy = URL(
      fileURLWithPath: AgentHome.expandUserPath(
        "\(legacyStateDirectory)/history.json", environment: environment))
    if usesDefaultHome(options: options, environment: environment),
      !FileManager.default.fileExists(atPath: url.path),
      FileManager.default.fileExists(atPath: legacy.path)
    {
      try? FileManager.default.createDirectory(at: home.rootURL, withIntermediateDirectories: true)
      try? FileManager.default.copyItem(at: legacy, to: url)
    }
    return url
  }

  /// Adopts the single-file workspace pmai kept before projects existed into
  /// the first project started afterwards, then sets the file aside so it is
  /// imported only once.
  private static func importLegacyChats(
    into store: AgentChatStore,
    project: AgentProject,
    options: CLIOptions,
    environment: [String: String]
  ) {
    guard options.statePath == nil, usesDefaultHome(options: options, environment: environment)
    else { return }
    let legacy = URL(
      fileURLWithPath: AgentHome.expandUserPath(
        "\(legacyStateDirectory)/chats.json", environment: environment))
    guard FileManager.default.fileExists(atPath: legacy.path) else { return }
    do {
      var workspace = try AgentChatWorkspace.load(from: legacy)
      let count = workspace.chats.filter { !$0.isDisposable }.count
      try store.commit(&workspace)
      let imported = legacy.appendingPathExtension("imported")
      try? FileManager.default.removeItem(at: imported)
      try FileManager.default.moveItem(at: legacy, to: imported)
      FileHandle.standardError.write(
        Data(
          "Imported \(count) earlier chat\(count == 1 ? "" : "s") from \(legacy.path) into project '\(project.displayName)'.\n"
            .utf8))
    } catch {
      FileHandle.standardError.write(
        Data(
          "warning: earlier chats in \(legacy.path) were not imported: \(error.localizedDescription)\n"
            .utf8))
    }
  }

  /// A project tint colors the prompt so the terminal shows which project is open.
  private static func tintedUI(_ ui: ConfiguredTerminalUI, project: AgentProject)
    -> ConfiguredTerminalUI
  {
    guard let tint = project.tint else { return ui }
    var tinted = ui
    tinted.promptForeground = tint.hex
    return tinted
  }

  private static func loadChatWorkspace(
    from store: AgentChatStore,
    initialProfile: SessionProfile,
    configuredAgents: [AgentDefinition],
    providerOverride: ProviderID?,
    modelOverride: String?,
    options: CLIOptions
  ) throws -> AgentChatWorkspace {
    var workspace = try store.loadWorkspace { error in
      FileHandle.standardError.write(
        Data("warning: skipped a chat file. \(error.localizedDescription)\n".utf8))
    }
    synchronizeConfiguredAgentSettings(in: &workspace, agents: configuredAgents)
    let overridesLimits =
      options.maxToolCalls != nil || options.maxModelTurns != nil
      || options.maxSubagents != nil
    if providerOverride != nil || modelOverride != nil || overridesLimits {
      for var chat in workspace.chats {
        if let providerOverride { chat.primaryAgent.provider = providerOverride }
        if let modelOverride { chat.primaryAgent.model = modelOverride }
        options.applyLimitOverrides(to: &chat.primaryAgent.limits)
        workspace.upsert(chat)
      }
    }
    // Like the PocketMai app, every launch opens a fresh chat and keeps the
    // earlier ones one `/chat use` away; `--resume` reopens a saved chat instead.
    if options.resume {
      if let selector = options.resumeSelector {
        guard let chat = resolveChat(selector, in: workspace) else {
          throw CLIError.unknownChat(selector)
        }
        workspace.selectChat(id: chat.id)
        return workspace
      }
      if let recent = workspace.mostRecentChat {
        workspace.selectChat(id: recent.id)
        return workspace
      }
    }
    workspace.startNewChat(primaryAgent: initialProfile.agentDefinition)
    return workspace
  }

  /// Chat files retain an agent snapshot for portability, but reusable agent
  /// controls are configured in pmai.json. Refreshing them prevents an old
  /// chat from masking or overwriting newer `/edit config` and `/set` values.
  private static func synchronizeConfiguredAgentSettings(
    in workspace: inout AgentChatWorkspace,
    agents: [AgentDefinition]
  ) {
    let configuredByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
    for var chat in workspace.chats {
      guard let configured = configuredByID[chat.primaryAgent.id] else { continue }
      applyConfiguredAgentSettings(configured, to: &chat)
      workspace.upsert(chat)
    }
  }

  private static func applyConfiguredAgentSettings(
    _ configured: AgentDefinition,
    to chat: inout AgentChat
  ) {
    let previousInstructions = chat.primaryAgent.instructions
    chat.primaryAgent.limits = configured.limits
    chat.primaryAgent.toolCallingStrategy = configured.toolCallingStrategy
    chat.primaryAgent.instructions = configured.instructions
    chat.primaryAgent.systemPrompt = configured.systemPrompt
    // The chat keeps a copy of its agent, and every tool change made from the
    // REPL is saved into the configuration, so the configuration is the truth:
    // a chat opened after a group was enabled must see the new tools too.
    chat.primaryAgent.toolNames = configured.toolNames
    chat.primaryAgent.toolGroupNames = configured.toolGroupNames
    chat.primaryAgent.subagentNames = configured.subagentNames
    chat.primaryAgent.toolDelegation = configured.toolDelegation
    chat.primaryAgent.useToolProxy = configured.useToolProxy
    chat.primaryAgent.proxyExposedTools = configured.proxyExposedTools
    chat.primaryAgent.context = configured.context
    guard previousInstructions != configured.instructions else { return }
    var transcript = AgentTranscript(messages: chat.messages)
    if let index = transcript.messages.firstIndex(where: {
      $0.role == .system && $0.text == previousInstructions
    }) {
      if configured.instructions.isEmpty {
        _ = try? transcript.removeMessage(at: index)
      } else {
        _ = try? transcript.editMessage(at: index, text: configured.instructions)
      }
    } else if !configured.instructions.isEmpty {
      transcript.replaceAll(with: [.system(configured.instructions)] + transcript.messages)
    }
    chat.messages = transcript.messages
  }

  private static func chatApplyingConfiguredAgentSettings(
    _ chat: AgentChat,
    configuration: MaiConfiguration?
  ) -> AgentChat {
    guard
      let configured = configuration?.agents.first(where: { $0.id == chat.primaryAgent.id })
    else { return chat }
    var chat = chat
    applyConfiguredAgentSettings(configured, to: &chat)
    return chat
  }

  /// Commits the workspace to the project's chat store. The selected
  /// placeholder stays in memory while the REPL runs and is dropped when it
  /// closes; the store never writes a placeholder, so an empty chat leaves no
  /// file behind however the process ends.
  private static func saveWorkspace(
    _ workspace: inout AgentChatWorkspace,
    store: AgentChatStore,
    terminal: TerminalWriter,
    closing: Bool = false
  ) async {
    workspace.removeDisposableChats(keeping: closing ? nil : workspace.selectedChatID)
    do {
      try store.commit(&workspace)
    } catch {
      await terminal.line(
        "warning: chats were not saved: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  #if PMAI_HAS_VISUAL
    private static func visualSnapshot(for workspace: AgentChatWorkspace) -> VisualWorkspaceSnapshot
    {
      let conversations = workspace.chats.map { chat in
        VisualConversationSeed(
          id: chat.id,
          title: chat.title,
          profile: chat.primaryAgent,
          messages: chat.messages,
          pendingContent: chat.pendingContent,
          sessionID: chat.sessionID)
      }
      return VisualWorkspaceSnapshot(
        conversations: conversations,
        layout: PaneLayout(conversation: workspace.selectedChatID ?? conversations[0].id))
    }

    private static func chatWorkspace(
      from snapshot: VisualWorkspaceSnapshot,
      focusedID: UUID,
      previous: AgentChatWorkspace
    ) -> AgentChatWorkspace {
      let previousByID = Dictionary(uniqueKeysWithValues: previous.chats.map { ($0.id, $0) })
      let chats = snapshot.conversations.map { conversation in
        let old = previousByID[conversation.id]
        let untouched =
          old.map {
            $0.title == conversation.title && $0.primaryAgent == conversation.profile
              && $0.messages == conversation.messages
              && $0.pendingContent == conversation.pendingContent
          } ?? false
        return AgentChat(
          id: conversation.id,
          title: conversation.title,
          primaryAgent: conversation.profile,
          messages: conversation.messages,
          pendingContent: conversation.pendingContent,
          createdAt: old?.createdAt ?? Date(),
          updatedAt: untouched ? old!.updatedAt : Date(),
          isArchived: old?.isArchived ?? false,
          sessionID: conversation.sessionID,
          subagents: old?.subagents ?? [])
      }
      return AgentChatWorkspace(chats: chats, selectedChatID: focusedID)
    }
  #endif

  private static func completionCandidates(
    workspace: AgentChatWorkspace,
    configuration: MaiConfiguration?,
    skills: [AgentSkill] = []
  ) -> [String] {
    var values = [
      "/help", "/help set", "/exit", "/quit", "/set yolo on", "/set yolo off",
      "/set ui.", "/set effort", "/set effort off", "/set effort auto", "/nothink",
      "/set ui.thinking status", "/set ui.thinking line", "/set ui.thinking three",
      "/set ui.thinking five", "/set ui.thinking full",
      "/btw ",
      "/help memory", "/help agents", "/help chat", "/help edit", "/help tools",
      "/agent acp list", "/agent acp add ", "/agents acp list",
      "/memory", "/memory edit", "/memory learn", "/memory learn --all", "/memory add ",
      "/memory clear", "/memory on", "/memory off", "/memory scope none",
      "/memory scope project", "/memory scope all", "/edit memory", "/edit memory-prompt",
      "/help todo", "/todo", "/todo add ", "/todo done ", "/todo edit", "/todo sweep",
      "/todo clear", "/todo path",
      "/set limits.", "/set limits.maxToolCalls ", "/set limits.maxModelTurns ",
      "/set limits.maxSubagents ", "/set limits.maxSeconds ", "/set limits.maxTotalTokens ",
      "/set retry.attempts ", "/set retry.delay ", "/set ctx.strategy ", "/set ctx.compact ",
      "/set ctx.compact off",
      "/continue", "/stop",
      "/set tool.", "/set tool.calling automatic", "/set tool.calling native",
      "/set tool.calling text", "/set tool.calling xml", "/set tool.calling json",
      "/set tool.proxy on", "/set tool.proxy off",
      "/set ui.title ", "/set ui.title none", "/set ui.editor ", "/set ui.editor none",
      "/set ui.bgline rgb:024", "/set ui.bgline none",
      "/set ui.fgprompt yellow",
      "/set ui.fgcolor none", "/set ui.bgcolor none", "/set ui.bgprompt none",
      "/set ui.fgtoolresult yellow", "/set use.", "/set use.agentsmd on", "/set use.agentsmd off",
      "/set use.plan on", "/set use.plan off",
      "/set ui.bold on", "/set ui.bold off", "/set ui.markdown on", "/set ui.markdown off",
      "/set ui.broadcast on", "/set ui.broadcast off",
      "/set ui.toolResultLines all", "/set ui.toolResultLines ",
      "/cwd", "/pwd", "/cd ", "/plugins",
      "/providers", "/models ", "/provider ", "/baseurl ", "/model ", "/prompts", "/prompt",
      "/prompt list", "/prompt show ", "/prompt add ", "/prompt set ", "/prompt edit ",
      "/prompt rm ", "/prompt use ", "/help prompts", "/prompts list", "/prompts show ",
      "/prompts add ", "/prompts edit ", "/prompts rm ", "/edit user ", "/edit system ",
      "/agents", "/agents tree", "/agents clear", "/agents log ", "/agents kill ", "/agents focus ",
      "/agents focus main", "/queue", "/queue push ", "/queue pop", "/queue drop",
      "/help queue", "/help export", "/help import", "/export archive ", "/import ",
      "/export markdown ", "/export html ", "/export json ", "/export debug ",
      "/stats", "/stats ranking", "/stats speed", "/stats time", "/stats efficiency",
      "/stats show ",
      "/stats reset", "/stats rm ", "/stats path", "/help stats",
      "/export epub ", "/export docx ", "/set ui.subagents all", "/set ui.subagents tools",
      "/set ui.subagents stats", "/set ui.subagents none",
      "/agent use ",
      "/agent show ", "/agent add ", "/agent tools ", "/agent model ", "/agent prompt ",
      "/agent provider ", "/agent remove ", "/edit agent", "/tools",
      "/skills", "/skills list", "/skills show ", "/skills enable ", "/skills disable ",
      "/skills enable all", "/skills disable all", "/skills prompt ", "/skills path",
      "/skills reload", "/help skills",
      "/mcp list",
      "/mcp add ", "/mcp enable ", "/mcp disable ",
      "/edit prompt", "/edit compact", "/edit config", "/edit mcps", "/edit provider",
      "/edit input",
      "/chat compact ",
      "/image tiny ", "/image small ", "/image medium ", "/image big ", "/image full ",
      "/image ocr ", "/attach ", "/attach source ", "/attach markdown ", "/attach copy ",
      "/attach clear", "/copy", "/help copy", "/reply", "/help reply",
      "/clear", "/chat list",
      "/chat list active", "/chat list archived", "/chat list all", "/chat new ",
      "/chat use ", "/chat next", "/chat previous", "/chat info", "/chat session",
      "/chat session new", "/chat rename ",
      "/chat archive", "/chat unarchive ", "/chat close confirm", "/chat messages",
      "/chat log", "/chat edit ", "/chat remove ", "/chat undo", "/chat trim ",
      "/chat clear", "/project", "/project info", "/project list", "/project name ",
      "/project tint ", "/project tint none", "/project forget ",
    ]
    for tint in AgentProjectTint.presetNames {
      values.append("/project tint \(tint)")
    }
    #if PMAI_HAS_VISUAL
      values.append("/visual")
    #endif
    for (index, chat) in workspace.orderedChats.enumerated() {
      values.append("/chat use \(index + 1)")
      values.append("/chat use \(chat.id.uuidString.prefix(8))")
      values.append("/chat use \(chat.displayTitle)")
      values.append("/chat info \(index + 1)")
      values.append(chat.isArchived ? "/chat unarchive \(index + 1)" : "/chat archive \(index + 1)")
    }
    for agent in configuration?.agents ?? [] {
      values.append("/agent use \(agent.id)")
      values.append("/agent show \(agent.id)")
      values.append("/chat new --agent \(agent.id) ")
    }
    for name in configuration?.prompts?.system.keys.sorted() ?? [] {
      values.append("/prompt \(name)")
      values.append("/edit prompt \(name)")
      values.append("/edit \(name)")
    }
    for provider in configuration?.providers ?? [] {
      values.append("/provider \(provider.id)")
      values.append("/models \(provider.id)")
      values.append("/edit provider \(provider.id)")
    }
    for skill in skills {
      values.append("/skills show \(skill.name)")
      values.append("/skills prompt \(skill.name) ")
      if skill.isModelInvocable {
        values.append("/skills enable \(skill.name)")
        values.append("/skills disable \(skill.name)")
      }
    }
    let catalog = configuration?.promptCatalog(skills: skills) ?? PromptCatalog(skills: skills)
    for entry in catalog.entries {
      values.append("$\(entry.commandName) ")
      values.append("/prompts \(entry.commandName) ")
      values.append("/prompts show \(entry.commandName)")
    }
    for name in (configuration?.prompts?.user ?? [:]).keys.sorted() {
      values.append("/prompts edit \(name)")
      values.append("/prompts rm \(name)")
      values.append("/edit user \(name)")
    }
    var groupNames = Set(workspace.chats.flatMap(\.primaryAgent.toolGroupNames))
    if skills.contains(where: \.isModelInvocable) { groupNames.insert(MaiSkillTools.groupID) }
    if configuration?.toolSources.contains(where: {
      $0.enabled && $0.kind == MaiStandardToolsPlugin.factoryKind
    }) == true {
      groupNames.formUnion(
        [
          "datetime", "calc", "files", "run", "weather", "web", "mastodon", "github",
          "todo", "context",
        ])
    }
    for level in ReasoningEffort.names {
      values.append("/set effort \(level)")
    }
    for group in groupNames {
      values.append("/tools show \(group)")
      values.append("/tools enable \(group)")
      values.append("/tools disable \(group)")
      values.append("/tools set \(group) ")
    }
    return Array(Set(values))
  }

  private static func loadConfiguration(
    options: CLIOptions,
    environment: [String: String]
  ) throws -> (configuration: MaiConfiguration, path: String)? {
    if let explicit = options.configPath {
      let expanded = AgentHome.expandUserPath(explicit, environment: environment)
      guard FileManager.default.fileExists(atPath: expanded) else {
        throw CLIError.configNotFound(expanded)
      }
      return (try MaiConfiguration.load(from: URL(fileURLWithPath: expanded)), expanded)
    }
    let candidates = [
      FileManager.default.currentDirectoryPath + "/pmai.json",
      defaultConfigurationPath(environment: environment),
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
      return (try MaiConfiguration.load(from: URL(fileURLWithPath: path)), path)
    }
    return nil
  }

  /// Reads standard input to its end and attaches it as a text file, the way
  /// `/attach` does with a file on disk. With a message on the command line
  /// the run is one-shot; without one the REPL follows, so the terminal takes
  /// over as standard input, which needs one to exist.
  private static func stdinAttachment(reopeningTerminal: Bool) throws -> ContentPart {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let attachment = try DocumentAttachmentImporter.attachment(data: data, filename: "stdin.txt")
    if reopeningTerminal {
      #if os(Windows)
        guard WindowsConsole.reopenStandardInputOnConsole() else {
          throw CLIError.stdinWithoutTerminal
        }
      #else
        let tty = open("/dev/tty", O_RDONLY)
        guard tty >= 0 else { throw CLIError.stdinWithoutTerminal }
        defer { close(tty) }
        guard dup2(tty, STDIN_FILENO) >= 0 else { throw CLIError.stdinWithoutTerminal }
      #endif
    }
    return attachment.content
  }

  private static func imageContent(path: String) throws -> ContentPart {
    let loaded = try loadImage(path: path)
    return .image(
      ImageContent(
        source: .data(loaded.data),
        mimeType: loaded.mimeType,
        name: loaded.url.lastPathComponent))
  }

  private static func imageContent(
    path: String,
    mode: ImageAttachmentMode,
    ocrProvider: any OCRProvider
  ) async throws -> ContentPart {
    let loaded = try loadImage(path: path)
    return try await ImageAttachmentImporter.content(
      data: loaded.data,
      mimeType: loaded.mimeType,
      filename: loaded.url.lastPathComponent,
      mode: mode,
      ocrProvider: mode == .ocr ? ocrProvider : nil)
  }

  private static func loadImage(path: String) throws -> (data: Data, url: URL, mimeType: String) {
    let expanded = NSString(string: path).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
      throw CLIError.invalidImage(path)
    }
    let mimeType: String
    switch url.pathExtension.lowercased() {
    case "png": mimeType = "image/png"
    case "gif": mimeType = "image/gif"
    case "webp": mimeType = "image/webp"
    case "heic", "heif": mimeType = "image/heic"
    default: mimeType = "image/jpeg"
    }
    return (data, url, mimeType)
  }

  private static func sampleConfiguration() -> MaiConfiguration {
    MaiConfiguration(
      defaultAgent: "hello",
      plugins: [
        ConfiguredPlugin(path: "./plugins/example.dylib", enabled: false)
      ],
      providers: [
        ConfiguredProvider(id: "hello", kind: .hello),
        ConfiguredProvider(
          id: "openai",
          kind: .openAICompatible,
          baseURL: URL(string: "https://api.openai.com/v1"),
          apiKeyEnvironment: "OPENAI_API_KEY"),
      ],
      toolSources: [
        ConfiguredToolSource(
          id: "standard-tools",
          kind: MaiStandardToolsPlugin.factoryKind,
          options: [
            "webSearchProvider": .string(MaiWebSearchProvider.exa.rawValue),
            "weatherLocation": .string(""),
            "mastodonInstance": .string("mastodon.social"),
            "mastodonAPIKeyEnvironment": .string("MASTODON_API_KEY"),
            "mastodonWriteEnabled": .bool(false),
          ]),
        ConfiguredToolSource(id: "example-tools", kind: "example", enabled: false),
      ],
      ocrProviders: [
        ConfiguredOCRProvider(
          id: MaiVisionOCRPlugin.preferredFactoryKind,
          kind: MaiVisionOCRPlugin.preferredFactoryKind)
      ],
      mcpServers: [
        ConfiguredMCPServer(
          id: "remote",
          enabled: false,
          displayName: "Example MCP",
          url: URL(string: "https://your-mcp.example/mcp")!,
          bearerTokenEnvironment: "MCP_API_KEY",
          toolNamePrefix: "remote",
          defaultApproval: .confirm),
        ConfiguredMCPServer(
          id: "local",
          kind: "stdio",
          enabled: false,
          displayName: "Example local MCP",
          command: "your-mcp-server",
          args: ["--stdio"],
          cwd: ".",
          toolNamePrefix: "local",
          defaultApproval: .confirm),
      ],
      agents: [
        AgentDefinition(
          id: "hello",
          description: "Offline smoke test; no tools and no network.",
          instructions: "Exercise the offline MaiCore provider.",
          systemPrompt: "hello",
          provider: "hello",
          model: ""),
        AgentDefinition(
          id: "main",
          description: "General assistant with the full tool set.",
          instructions: "You are a helpful assistant. Use tools when needed.",
          systemPrompt: "main",
          provider: "openai",
          model: "your-model",
          toolNames: Set(
            [
              MaiCalculatorTool.name,
              MaiCurrentTimeTool.name,
              MaiWeatherTool.name,
              MaiWebSearchTool.name,
              MaiWebFetchTool.name,
              MaiMastodonTool.name,
            ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames
              + MaiTodoTools.toolNames + MaiContextTools.toolNames),
          toolGroupNames: [
            "datetime", "calc", "files", "run", "weather", "web", "mastodon",
            "github", "todo", "context",
          ],
          subagentNames: ["researcher"],
          limits: AgentRunLimits(),
          useToolProxy: true),
        AgentDefinition(
          id: "researcher",
          description: "Investigates one question and answers in a few lines.",
          instructions: "Investigate the delegated task and return a concise result.",
          systemPrompt: "researcher",
          provider: "openai",
          model: "your-model",
          toolNames: [MaiCurrentTimeTool.name],
          toolGroupNames: ["datetime"]),
      ],
      prompts: ConfiguredPrompts(
        delegation: AgentDelegationPrompt.template,
        worker: AgentDelegationPrompt.workerInstructions,
        memory: AgentMemoryPrompt.template,
        system: [
          "hello": "Exercise the offline MaiCore provider.",
          "main": "You are a helpful assistant. Use tools when needed.",
          "researcher": "Investigate the delegated task and return a concise result.",
        ]),
      memory: ConfiguredMemory(),
      approvals: ConfiguredApprovals(confirm: .ask, dangerous: .ask))
  }

  private static let visualHelp: String = {
    #if PMAI_HAS_VISUAL
      "/visual                Open the terminal workspace: split chats, providers, MCPs, tools\n"
    #else
      ""
    #endif
  }()

  private static let replHelp = """
    /agent                 Select or edit this chat's agent; /help agent lists commands
    /agents                Manage agent definitions and running agents; /help agents lists commands
    /attach [MODE] PATH    Attach a document/source file; HTML asks for source, markdown, or copy
    /attach clear          Drop the attachments queued for the next message
    /baseurl URL           Change the current provider endpoint
    /btw PROMPT            Ask in a fresh context without changing this chat
    /cd PATH               Change the current working directory
    /chat                  List, switch, archive, rename, or edit this project's chats
    /clear                 Clear conversation history
    /continue              Resume a stopped or interrupted task, including queued messages
    /copy [N] [PATH]       Copy the last reply, or N messages, to the clipboard or a file
    /cwd                   Print the current working directory
    /edit TARGET           Edit a prompt, agent, config, MCP list, or message in $EDITOR
    /edit input            Write the next message in $EDITOR instead of at the prompt
    /exit                  Exit the REPL
    /export FORMAT [PATH]  Save a portable archive, or this chat as markdown, html, json, debug, epub, or docx
    /help [COMMAND]        Show commands or help for one command
    /image MODE PATH       Attach at tiny/small/medium/big/full size, or OCR to Markdown
    /import PATH           Merge a PocketMai/pmai archive into settings, skills, and chats
    /mcp                   Manage MCP servers; /help mcp lists commands
    /memory                Show, edit, learn, or scope this project's durable memory
    /model NAME            Select a model
    /models [PROVIDER]     List models from the current or named provider
    /nothink               Disable reasoning where the model supports it
    /plugins               List statically and dynamically loaded plugins
    /project               Show, list, rename, or tint the project (the start directory)
    /prompt                Manage named system prompts; /help prompt lists commands
    /prompts               List every prompt and skill; $NAME [TEXT] sends one (/help prompt)
    /provider ID           Select a provider
    /providers             List registered providers
    /queue                 List, push, pop, or drop messages waiting for an agent
    /reply [WIDTH]         Answer the last reply in $EDITOR with it quoted above (/help reply)
    /set [SETTING VALUE]   Show or change settings; /help set lists them
    /skills                List, enable, disable, or send skills (/help skills)
    /stats                 Combined ranking, tokens/s, time in use, and efficiency per provider:model, as bars
    /stop                  Interrupt the current turn and keep its queue; /continue resumes it
    /todo                  Show, add to, tick off, or edit this project's todo list
    /tools                 List logical tool groups for the current agent
    /version               Print the pmai version
    \(visualHelp)
    Input: Shift+Enter adds a line (Alt+Enter or Ctrl+J where the terminal sends Enter for it)
           A paste keeps its lines · Enter sends the whole text
           <<WORD starts a multiline message ending at WORD alone
           $NAME [TEXT] sends a prompt or skill by name; /prompts lists them
           !COMMAND runs a line in the system shell (interactive programs work)
           Up/Down or Ctrl+P/N move between lines, then history · Ctrl+R reverse search
           Ctrl+A/E or Home/End beginning/end of the line
           Ctrl+B/F move left/right like the arrow keys
           Ctrl+L clear the screen, keeping the input
           Ctrl+W delete word · Ctrl+C or /stop interrupt the run · Ctrl+Z suspend
           The prompt stays open while a turn runs: a message typed then is queued and
           joins the conversation at the next model turn. @2,3 TEXT or @2 @3 TEXT reaches several agents.
           @* TEXT reaches every active agent, including the main chat when it is running.
           Commands run right away too; a setting changed then reaches the next turn.
           Child agents print in blocks prefixed agent#PID; /set ui.subagents picks how much.
    """

  private static let effortHelp = """
    Reasoning effort:
      /set effort                Show the current agent's reasoning effort and guidance
      /set effort LEVEL          Set it: off, minimal, low, medium, high, xhigh, or max. The provider gets the
                                 field its API takes (reasoning_effort, think, enable_thinking,
                                 thinking…) and the system prompt says how much care to take
      /set effort LEVEL TEXT     The level plus TEXT, added to the system prompt as guidance
      /set effort auto           Use pmai's automatic policy, with no guidance; DeepSeek Flash
                                 defaults to off because its provider default is high
      /set effort off            Disable thinking where supported (also /nothink)

    Examples:
      /set effort high
      /set effort max Check every edge case and verify the result before answering
      /set effort low Keep answers to one paragraph
    """

  private static let setHelp = """
    Settings commands:
      /set                         List current settings and their values
      /set effort [LEVEL] [TEXT]   Show or set reasoning effort and optional guidance
      /set yolo BOOL               Permit all tool calls without asking (on/off); saved for this project
      /set tool.                   List the tool calling settings
      /set tool.calling MODE       Use automatic/native tools, or text/XML/JSON emulation
      /set tool.proxy BOOL         Show models only the shared list-tools and call-tool pair (on/off)
      /set delegation MODE         off: runs every tool itself; subagent: may also hand work to a child
      /set limits.                 List the tool, turn, and subagent limits
      /set limits.maxToolCalls N   Tool calls allowed per run
      /set limits.maxModelTurns N  Model turns allowed per run
      /set limits.maxSubagents N   Child agents allowed at once (0 disables delegation)
      /set limits.maxSubagentDepth N  Maximum depth of the agent tree
      /set limits.maxTotalTokens <off|N|Nk>  Tokens a run may spend before it pauses
      /set limits.maxSeconds <off|N|Nm|Nh>   Wall-clock time a run may take before it pauses
      /set retry.attempts N        Times a failed model call is repeated (default 2)
      /set retry.delay SECONDS     Wait before each retry (default 5)
      /set ctx.compact <off|N|Nk>  Summarize older exchanges once the chat holds ~N tokens
      /set ctx.strategy <cache|size>  Keep prompt-cache history intact, or compact old file reads
      /set ui.                     List terminal UI settings
      /set ui.title TEXT           Set the prompt label and terminal/tab title (`none` clears it)
      /set ui.editor COMMAND       Editor /edit opens (`none` falls back to $EDITOR, $VISUAL, vim)
      /set ui.bgline COLOR         Set the input-line background
      /set ui.fgcolor COLOR        Set the input foreground
      /set ui.bgcolor COLOR        Set the input background
      /set ui.fgprompt COLOR       Set the prompt foreground
      /set ui.bgprompt COLOR       Set the prompt background
      /set ui.fgtoolresult COLOR   Set successful tool-result output color
      /set ui.bold BOOL            Render input in bold (on/off)
      /set ui.markdown BOOL        Render replies as styled markdown (on/off)
      /set ui.toolResultLines <all|N>  Show all or the first N result lines (0 hides them)
      /set ui.thinking MODE        Thinking display: status, line, three, five, or full
      /set ui.subagents LEVEL      What child agents print: all, tools, stats, or none
      /set ui.broadcast BOOL       Default unaddressed messages to @* (on/off; default off)
      /set use.agentsmd BOOL       Put the working tree's AGENTS.md files — this directory up to
                                   the repository root — into every run's system prompt (on/off)
      /set use.plan BOOL           Ask an agent that can start children to open a request of
                                   several steps with a numbered plan before delegating (on/off)

    YOLO is saved in the opened project's .pmai/settings.json; -y enables it for
    one run only. Projects without a saved choice use approvals.yolo from the
    active configuration. Agent and UI settings use the active configuration.
    COLOR accepts a named ANSI color, rgb:RGB, or none.
    """

  private static let chatHelp = """
    Persistent chat management commands:
      /chat list [active|archived|all]  List chats by day, newest first; archived last
      /chat new [TITLE]             Start a fresh chat using the current agent
      /chat new --agent ID [TITLE]  Start a fresh chat using a configured agent
      /chat use INDEX|ID|TITLE      Switch to a chat by list index, ID prefix, or title
      /chat next|previous           Cycle through chats
      /chat info [INDEX|ID|TITLE]   Show a chat's agent, session, size, and timestamps
      /chat session [new]           Show the session id providers see, or start a fresh one
      /chat rename TITLE            Rename the active chat
      /chat archive [INDEX|ID|TITLE]  Archive a chat; archiving the active one starts fresh
      /chat unarchive INDEX|ID|TITLE  Return an archived chat to the active list
      /chat close confirm           Permanently close the active chat
      /chat messages                Display a compact indexed message list
      /chat log           Display the full structured conversation
      /chat edit INDEX TEXT  Replace a message's text; preserve attachments
      /chat remove INDEX  Remove a message
      /chat undo [INDEX]  Remove the last conversation message or selected message
      /chat trim INDEX    Keep through the selected message; remove newer messages
      /chat compact [FOCUS]  Summarize the chat, prioritizing what FOCUS says to preserve
      /chat clear         Clear the conversation and restore configured instructions

    Message indexes are 1-based. Negative indexes count back from the end;
    -1 selects the last message, -2 the second-to-last, and so on.
    Removing a tool call or result also removes its linked tool transaction.
    pmai opens a fresh chat on every launch and names it after the first
    message; chats that never received a message are never written. Start
    Start with -l to list saved chats, then -r INDEX|ID|TITLE to reopen one;
    -r without a selector reopens the most recently updated chat. Chats
    belong to the project rooted at the start directory; /project shows it.
    A chat is saved with the agents its runs started and their transcripts:
    reopening it lists them under /agents tree, /agents log PID reads one,
    /chat info counts them, and /agents clear drops them from the chat.
    """

  private static let projectHelp = """
    Project commands (a project is the directory pmai was started in):
      /project [info]          Show the project's name, tint, directory, and chat counts
      /project list            List every project pmai has been started in, recent first
      /project name NAME       Rename the project; the directory name is the default
      /project tint COLOR      Color the prompt: a preset such as mint, or #RRGGBB; none clears it
      /project forget INDEX|PATH|NAME  Drop another project from the list; its files stay

    Chats live in .pmai/chats inside the project directory; the list of
    projects lives in ~/.pmai/projects.json (or under $PMAI_HOME). /cd changes
    where tools run, not which project the chats belong to.
    """

  private static let mcpCommandHelp = """
    MCP commands:
      /mcp list
      /mcp enable ID
      /mcp disable ID
      /mcp add COMMAND [ARG ...]
      /mcp add [--name ID] [--env KEY=VALUE] [--cwd PATH] [--timeout SECONDS]
               [--prefix PREFIX] [--approval MODE] -- COMMAND [ARG ...]

    MODE is automatic, confirm, or dangerous. Quotes and backslash escapes are
    supported. Without --name, the command's basename becomes the server name.
    The server is connected immediately, saved in the normal mcpServers
    configuration, and all of its tools are enabled for every agent.

    Examples:
      /mcp add r2mcp
      /mcp add --name weather -- npx -y weather-mcp
    """

  private static let editHelp = """
    /edit prompt [NAME]      Edit the prompt called NAME, system or user (current agent's when omitted)
    /edit system [NAME]      Edit/create a named system prompt (current when omitted)
    /edit user NAME          Edit/create a user prompt; a builtin's name starts from its text
    /edit NAME               Edit an existing system or user prompt
    /edit agent [ID]         Edit a saved agent as JSON (current when omitted)
    /edit provider [ID]      Edit a configured provider as JSON (current when omitted)
    /edit compact            Edit the global chat-compaction prompt template
    /edit memory             Edit this project's durable memory notes
    /edit memory-prompt      Edit the template /memory learn uses
    /edit delegation         Edit the brief template child agents receive
    /edit worker             Edit the instructions of the derived worker agent
    /edit config             Edit the active configuration file
    /edit mcps               Edit the configured MCP server list as JSON
    /edit N|MESSAGE_ID       Edit conversation message N or its full message ID
    /edit input              Write the next message in the editor and send it

    The compact and memory templates must contain {{transcript}}; {{focus}} and
    {{memory}} are optional. The delegation template must contain {{task}};
    {{context}}, {{output}}, {{agent}}, and {{cwd}} are optional.
    Clearing it restores the built-in default. Uses /set ui.editor when it is
    set, then $EDITOR, then $VISUAL, then vim. Agent limits and tool-calling
    strategy apply immediately, and an edited provider is rebuilt in place;
    other provider, plugin, tool, and MCP changes made through /edit config
    require a restart.

    A provider's "headers" is an object of names to values or an array of
    "Name: value" strings, sent with every request. A value may contain
    {{session}}, which becomes the session id of the chat a request belongs
    to (/chat session shows it; OpenCode Zen needs it in x-opencode-session).
    """

  private static let memoryHelp = """
    Durable notes about you, kept per project in .pmai/memory.md and added to
    the system prompt of this chat — never of the subagents it starts.

      /memory                    Show the notes and how they are configured
      /memory edit               Edit them in $EDITOR (same as /edit memory)
      /memory learn [FOCUS]      Fold this chat into the notes, keeping what is known
      /memory learn --all [FOCUS]  Fold every chat in this project into them
      /memory add TEXT           Append one note
      /memory set TEXT           Replace every note
      /memory clear              Forget everything
      /memory reload             Re-read the file after editing it elsewhere
      /memory on|off             Whether the notes reach the model
      /memory scope MODE         Chats the chats_* tools may read

    MODE is none, project, or all; all crosses working directories. The tools
    are chats_list, chats_search, chats_read, and chats_read_document; enable
    them for an agent with /tools enable chats. Edit the learning prompt with
    /edit memory-prompt.
    """

  private static let todoHelp = """
    The project's todo list, kept in .pmai/todo.md as a Markdown task list the
    agent plans with and ticks off through the todo_list, todo_add, and
    todo_done tools. It survives across chats, and editing the file by hand
    is fine: every command and tool call reads it afresh.

      /todo                      Show the list, numbered
      /todo add TEXT             Append one pending item
      /todo done NUMBER|TEXT     Mark an item done by number or title fragment
      /todo remove NUMBER|TEXT   Drop an item by number or title fragment
      /todo sweep                Remove every completed item
      /todo edit                 Edit the list in $EDITOR
      /todo clear                Remove every item
      /todo path                 Print where the file lives

    Enable the tools for an agent with /tools enable todo.
    """

  private static let skillsHelp = """
    Skills are folders holding a SKILL.md whose front matter gives a name and
    a description and whose body is the instructions to follow: the layout
    other coding agents use, so their skills work here unchanged. pmai reads
    the project's .pmai/skills and ~/.pmai/skills (or $PMAI_HOME/skills); a
    project skill shadows a home one of the same name. Each skill is also a
    skills_NAME tool the model may call to get the instructions, once it is
    enabled for the agent.

      /skills                    List skills; * marks the ones the agent may call
      /skills show NAME          Print a skill's file, tool state, and instructions
      /skills enable NAME|all    Offer a skill (or every skill) to the current agent
      /skills disable NAME|all   Stop offering it; /skills prompt still works
      /skills prompt NAME [TEXT] Send the instructions, then TEXT, as your next message
      /skills path               Print the directories scanned
      /skills reload             Rescan the directories (every /skills command does)

    /tools enable skills is the same as /skills enable all and also picks up
    skills added later. A skill whose front matter says
    disable-model-invocation: true is never a tool. Where the body says
    $ARGUMENTS the TEXT goes there; otherwise it follows the instructions.
    """

  private static let promptHelp = """
    Prompts. A system prompt is an agent's instructions: every agent takes
    them from one prompt in the catalog (prompts.system in the configuration),
    referenced by name in its systemPrompt field; several agents may share
    one, and editing the prompt updates all of them. A user prompt is a
    message sent by name (prompts.user), and MaiCore ships builtin ones —
    goal, newapp, tldr, followup — that a user prompt of the same name
    replaces. Skills (/skills) are sent by name the same way, whether or not
    the agent may call them as tools.

      /prompts                   List every prompt and skill by kind
      $NAME [TEXT]               Send prompt or skill NAME with TEXT after it: TEXT goes
                                 where $ARGUMENTS stands, or after the text. For a
                                 system prompt, switch this agent to it, then send TEXT.
                                 /prompts NAME [TEXT] is the long form.
      /prompts show NAME         Print what NAME is or sends
      /prompts add NAME TEXT     Create a user prompt from one line (set replaces it)
      /prompts edit NAME         Edit or create a user prompt in $EDITOR (/edit user NAME too)
      /prompts rm NAME           Drop a user prompt (a builtin it replaced shows again)

      /prompt                    Show the current agent's system prompt
      /prompt show NAME          Print one system prompt
      /prompt add NAME TEXT      Create a system prompt from one line (set replaces it)
      /prompt edit [NAME]        Edit or create one in $EDITOR (current when omitted; /edit system NAME too)
      /prompt rm NAME            Drop an unused system prompt
      /prompt use NAME           Point the current agent at a system prompt (/prompt NAME too)
      /agent prompt ID NAME      Point another saved agent at a system prompt
      /edit prompt NAME          Edit NAME, whichever kind of prompt it is

    Register an agent around a prompt in two lines:
      /prompt add reviewer You review diffs and list only real defects.
      /agent add reviewer - files,run reviewer

    Keep a message you send often as a user prompt:
      /prompts add commit Write a commit message for the staged changes: $ARGUMENTS
      $commit one line, imperative mood

    The other templates — compact, delegation, worker, memory — are edited
    with /edit compact, /edit delegation, /edit worker, and /edit memory-prompt.
    """

  private static let agentsHelp = """
    Agent commands. A definition is a saved setup — provider, model, system
    prompt, tools, and limits — that you switch between; a process is one run
    started from a definition, addressed by its pid.

      /agents                    List definitions, then the running process tree
      /agents list               Definitions only
      /agents tree               The running process tree only
      /agents clear              Forget finished processes, and drop the ones saved with this chat
      /agents use ID             Switch this chat to a definition
      /agents show [ID]          Show one definition in full
      /agents describe ID TEXT   Set the one-line purpose a model reads to pick it
      /agents enable|disable ID  Park a definition without deleting it
      /agents acp [list]         List external ACP agents and what is installed
      /agents acp add NAME [CMD ARG ...]  Register an ACP agent as a usable agent

    Saving and changing definitions, one line each (/agent and /agents both work):

      /agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]
                                 GROUPS is a,b,c (see /tools) or -; PROMPT names a system
                                 prompt (see /prompts); PROVIDER defaults to this chat's, and
                                 with BASE_URL registers a new OpenAI-compatible endpoint
      /agent tools ID GROUPS     Replace its tool groups (a,b,c), adjust them (+a,-b), or clear (-)
      /agent model ID MODEL      Change its model (- for the provider default)
      /agent prompt ID PROMPT    Point it at another named system prompt
      /agent provider ID PROVIDER  Move it to a configured provider
      /agent remove ID           Drop it; subagent lists and the default agent are updated
      /edit agent [ID]           Edit a definition as JSON in $EDITOR (current when omitted)

    A definition's tools are its own, whatever its depth in the tree: give a
    subagent its groups the same way. Named prompts are managed with /prompt.
      /agents log PID            Print a running, finished, or saved agent's own transcript
      /agents stop PID           Pause an agent and everything it started at their next step
      /agents continue PID       Let a paused agent go on; queued messages reach it then
      /agents kill PID [REASON]  End an agent and everything it started
      /agents focus PID|main     Send what you type to one running agent, or back to the chat

    While agents run, what you type is queued for them and read at their next
    model turn: /queue lists it, @PID TEXT addresses one agent once, and
    @2,3 TEXT or @2 @3 TEXT sends the same message to several; @* TEXT reaches
    every active process, including the running main chat and paused agents.
    Idle chats and finished agents are skipped. /set ui.broadcast on makes
    unaddressed messages use @*; off restores the focus. Agent output prints
    in blocks prefixed agent#PID; /set ui.subagents picks how much.

    An agent always has the tools its definition allows, at any depth of the
    tree. /set delegation subagent also lets it hand bulky work to a child with
    the same tools, so only the answer lands here. /set limits.maxSubagents and
    /set limits.maxSubagentDepth bound the tree.
    """

  private static let toolHelp = """
    Tool group commands:
      /tools list                    List logical tool groups
      /tools show GROUP              What the group is for, each tool with its parameters, and its settings
      /tools enable|disable GROUP    Change the current agent's allowed groups
      /tools set GROUP OPTION VALUE  Configure a tool group and reload its tools
      /tools unset GROUP OPTION      Restore an option's default

    Examples:
      /tools enable github
      /tools set mastodon mastodonInstance mastodon.social
      /tools set mastodon mastodonAPIKeyEnvironment MASTODON_API_KEY
      /tools set mastodon mastodonWriteEnabled on
    """

  private static func updateCLI(executable: String, environment: [String: String]) throws {
    #if os(Windows)
      throw NSError(
        domain: "pmai", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Automatic updates support macOS, Linux, and Android."
        ])
    #else
      let candidates =
        executable.contains("/")
        ? [executable]
        : (environment["PATH"] ?? "").components(separatedBy: ":").map {
          URL(fileURLWithPath: $0.isEmpty ? "." : $0).appendingPathComponent(executable).path
        }
      guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
      else { throw CocoaError(.fileNoSuchFile) }
      let directory =
        environment["PMAI_INSTALL_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().path
      let command = """
        installer=$(curl -fsSL https://raw.githubusercontent.com/trufae/pmai/main/www/install.sh) &&
        PMAI_INSTALL_DIR=\(shellQuote(directory)) sh -c "$installer"
        """
      let status = command.withCString(posixSystem)
      guard status != -1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      exit(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    #endif
  }

  private static func printUsage() {
    print(
      """
      pmai — the Pocket Mai command-line agent

      Usage:
        pmai [options] [message]

      Options:
        --acp               serve pmai as an ACP agent on stdio (for IDEs)
        --agent ID          select a configured agent
        --api-key KEY       prefer an environment variable or config reference
        --base-url URL      ad-hoc OpenAI-compatible endpoint
        --config PATH       load plugins, providers, tools, MCPs, agents, and approvals
        -h, --help          show this help
        --history PATH      persist editable input history (or PMAI_HISTORY)
        --home DIR          keep the project index and shared state in DIR (or PMAI_HOME)
        --image PATH        attach an image (repeatable)
        -l, --list          list saved chats in this project and exit
        --markdown          render replies as markdown even when piped
        --max-subagents N   children an agent may run at once (default 5)
        --max-tool-calls N  tool calls allowed per agent run (default 50)
        --max-turns N       model turns allowed per agent run (default 60)
        --mcp               serve pmai as an MCP server on stdio (one prompt tool)
        --model NAME        override the selected model
        --no-markdown       print replies verbatim
        --no-stream         disable response streaming
        --plugin PATH       load a native .dylib plugin (repeatable)
        --print-config      print a complete example configuration
        --projects          list every project pmai has been started in, then exit
        --provider ID       override the selected provider
        -r, --resume [CHAT] reopen CHAT (list index, ID, or title), or the latest chat,
                            with the agents its runs started
        --state DIR         keep this project's chats in DIR, not ./.pmai/chats (or PMAI_STATE)
        --stdin             attach standard input as a text file (git diff | pmai --stdin "review it")
        --system TEXT       override agent instructions
        -U, --update        check for updates and install the latest release
        -v, --version       print the pmai version
        -y, --yolo          permit all tool calls without prompting for this run
                            (/set yolo on saves the choice for this project)

      Config discovery:
        --config, PMAI_CONFIG, ./pmai.json, ~/.config/pmai/config.json

      Ad-hoc provider (overrides the selected agent's):
        PMAI_PROVIDER, PMAI_MODEL, PMAI_BASE_URL, and PMAI_API_KEY, or
        PMAI_API_KEY_FILE naming a file that holds the key, so the secret
        never sits in the environment

      Persistent REPL state:
        Chats belong to the project rooted at the current directory and are
        kept one file per chat in ./.pmai/chats; ~/.pmai/projects.json lists
        every project and ~/.pmai/history.json holds the input history.

      Without a config file, the offline hello and OpenAI-compatible providers
      are registered as before.
      """)
  }
}
