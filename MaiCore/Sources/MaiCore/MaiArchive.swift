import Foundation

/// The portable parts of a Mai installation. Each section is optional so a
/// host can export only what the person selected without inventing empty
/// values that an importer might mistake for "clear this section".
public enum MaiArchiveSection: String, Codable, CaseIterable, Hashable, Sendable {
  case providers
  case prompts
  case mcpServers
  case agents
  case chats
  case skills
}

/// Configuration shared by PocketMai and pmai. Host-only preferences such as
/// appearance and terminal colours deliberately stay out of the interchange
/// format; importing an archive must not make one host look like the other.
public struct MaiArchiveSettings: Codable, Equatable, Sendable {
  public var providers: [ConfiguredProvider]?
  public var prompts: ConfiguredPrompts?
  public var mcpServers: [ConfiguredMCPServer]?
  public var agents: [AgentDefinition]?
  public var defaultAgent: String?
  public var taskAgents: TaskAgentAssignments?

  public init(
    providers: [ConfiguredProvider]? = nil,
    prompts: ConfiguredPrompts? = nil,
    mcpServers: [ConfiguredMCPServer]? = nil,
    agents: [AgentDefinition]? = nil,
    defaultAgent: String? = nil,
    taskAgents: TaskAgentAssignments? = nil
  ) {
    self.providers = providers
    self.prompts = prompts
    self.mcpServers = mcpServers
    self.agents = agents
    self.defaultAgent = defaultAgent
    self.taskAgents = taskAgents
  }

  public init(configuration: MaiConfiguration) {
    self.init(
      providers: configuration.providers,
      prompts: configuration.prompts,
      mcpServers: configuration.mcpServers,
      agents: configuration.agents,
      defaultAgent: configuration.defaultAgent,
      taskAgents: configuration.taskAgents)
  }

  public var isEmpty: Bool {
    providers == nil && prompts == nil && mcpServers == nil && agents == nil
  }

  public var sections: Set<MaiArchiveSection> {
    var result: Set<MaiArchiveSection> = []
    if providers != nil { result.insert(.providers) }
    if prompts != nil { result.insert(.prompts) }
    if mcpServers != nil { result.insert(.mcpServers) }
    if agents != nil { result.insert(.agents) }
    return result
  }
}

/// One regular file inside a portable skill directory. JSON's standard Data
/// representation keeps binary helpers and reference assets intact.
public struct MaiArchiveSkillFile: Codable, Equatable, Sendable {
  public var path: String
  public var data: Data
  public var executable: Bool

  public init(path: String, data: Data, executable: Bool = false) {
    self.path = path
    self.data = data
    self.executable = executable
  }
}

/// A complete skill folder, including files referenced by SKILL.md.
public struct MaiArchiveSkill: Codable, Equatable, Sendable {
  public var name: String
  public var files: [MaiArchiveSkillFile]

  public init(name: String, files: [MaiArchiveSkillFile]) {
    self.name = name
    self.files = files
  }

  /// Captures regular files only. Symlinks are skipped so an archive never
  /// reaches outside the skill directory when it is made or restored.
  public init(skill: AgentSkill, fileManager: FileManager = .default) throws {
    let directory = skill.directoryURL.standardizedFileURL
    try Self.validateComponent(directory.lastPathComponent, kind: "skill name")
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles])
    else {
      throw MaiArchiveError.unreadableSkill(skill.name)
    }
    var captured: [MaiArchiveSkillFile] = []
    while let file = enumerator.nextObject() as? URL {
      let values = try file.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true else { continue }
      let relative = try Self.relativePath(of: file.standardizedFileURL, under: directory)
      let permissions =
        try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions]
        as? NSNumber
      captured.append(
        MaiArchiveSkillFile(
          path: relative,
          data: try Data(contentsOf: file),
          executable: ((permissions?.intValue ?? 0) & 0o111) != 0))
    }
    name = directory.lastPathComponent
    files = captured.sorted { $0.path < $1.path }
  }

  /// Adds or updates this skill under `root`. Files not present in the archive
  /// are left alone, which makes import non-destructive while still syncing
  /// every file the archive carries.
  public func install(in root: URL, fileManager: FileManager = .default) throws {
    try validate()
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = try Self.prepareDirectories([name], under: root, fileManager: fileManager)
    for file in files {
      let components = try Self.pathComponents(file.path)
      let parent = try Self.prepareDirectories(
        Array(components.dropLast()), under: destination, fileManager: fileManager)
      let target = parent.appendingPathComponent(components.last!)
      guard (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) == nil else {
        throw MaiArchiveError.invalidSkillPath(file.path)
      }
      try file.data.write(to: target, options: .atomic)
      if file.executable {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
      }
    }
  }

  private static func prepareDirectories(
    _ components: [String],
    under root: URL,
    fileManager: FileManager
  ) throws -> URL {
    var directory = root
    for component in components {
      directory.appendPathComponent(component, isDirectory: true)
      guard (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
        throw MaiArchiveError.invalidSkillPath(components.joined(separator: "/"))
      }
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
          throw MaiArchiveError.invalidSkillPath(components.joined(separator: "/"))
        }
      } else {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
      }
    }
    return directory
  }

  /// Checks names and relative paths before an importer writes any files.
  public func validate() throws {
    try Self.validateComponent(name, kind: "skill name")
    guard !files.isEmpty else { throw MaiArchiveError.emptySkill(name) }
    var seen: Set<String> = []
    for file in files {
      let components = try Self.pathComponents(file.path)
      let normalized = components.joined(separator: "/")
      guard seen.insert(normalized).inserted else {
        throw MaiArchiveError.duplicateSkillPath(name, normalized)
      }
    }
  }

  private static func relativePath(of file: URL, under directory: URL) throws -> String {
    let root = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    guard file.path.hasPrefix(root) else { throw MaiArchiveError.invalidSkillPath(file.path) }
    let relative = String(file.path.dropFirst(root.count))
    _ = try pathComponents(relative)
    return relative
  }

  private static func pathComponents(_ path: String) throws -> [String] {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
      throw MaiArchiveError.invalidSkillPath(path)
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty else { throw MaiArchiveError.invalidSkillPath(path) }
    for component in components {
      try validateComponent(component, kind: "skill path")
    }
    return components
  }

  private static func validateComponent(_ value: String, kind: String) throws {
    guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
      !value.contains("\\"), !value.contains("\0")
    else {
      throw kind == "skill name"
        ? MaiArchiveError.invalidSkillName(value) : MaiArchiveError.invalidSkillPath(value)
    }
  }
}

/// A versioned JSON archive understood by every Mai host. PocketMai embeds
/// this value in its older backup envelope so old app versions keep working;
/// pmai writes it directly and the decoder accepts both layouts.
public struct MaiArchive: Codable, Equatable, Sendable {
  public static let format = "mai.archive"
  public static let currentVersion = 1
  public static let fileExtension = "pocketmai.json"

  public var format: String
  public var version: Int
  public var generator: String
  public var exportedAt: Date
  public var settings: MaiArchiveSettings?
  public var chats: [AgentChat]?
  public var skills: [MaiArchiveSkill]?

  public init(
    generator: String,
    exportedAt: Date = Date(),
    settings: MaiArchiveSettings? = nil,
    chats: [AgentChat]? = nil,
    skills: [MaiArchiveSkill]? = nil
  ) {
    format = Self.format
    version = Self.currentVersion
    self.generator = generator
    self.exportedAt = exportedAt
    self.settings = settings?.isEmpty == true ? nil : settings
    self.chats = chats
    self.skills = skills
  }

  public var sections: Set<MaiArchiveSection> {
    var result = settings?.sections ?? []
    if chats != nil { result.insert(.chats) }
    if skills != nil { result.insert(.skills) }
    return result
  }

  public var isEmpty: Bool { sections.isEmpty }

  public func encoded() throws -> Data {
    try validate()
    return try MaiJSONCoding.default.makeEncoder().encode(self)
  }

  /// Reads a standalone archive or the `portable` member of a legacy
  /// PocketMai backup. Keeping this compatibility rule in MaiCore avoids each
  /// host growing its own format sniffer.
  public static func decode(from data: Data) throws -> MaiArchive {
    let decoder = MaiJSONCoding.default.makeDecoder()
    if let archive = try? decoder.decode(MaiArchive.self, from: data),
      archive.format == format
    {
      try archive.validate()
      return archive
    }
    if let wrapped = try? decoder.decode(EmbeddedArchive.self, from: data),
      let archive = wrapped.portable, archive.format == format
    {
      try archive.validate()
      return archive
    }
    if let legacy = try? decoder.decode(PocketMaiConversationEnvelope.self, from: data),
      legacy.format == PocketMaiConversationEnvelope.format
    {
      return legacy.archive
    }
    throw MaiArchiveError.invalidFormat
  }

  public func validate() throws {
    guard format == Self.format else { throw MaiArchiveError.invalidFormat }
    guard version == Self.currentVersion else {
      throw MaiArchiveError.unsupportedVersion(version)
    }
    guard !isEmpty else { throw MaiArchiveError.emptyArchive }
    try skills?.forEach { try $0.validate() }
  }

  private struct EmbeddedArchive: Decodable {
    var portable: MaiArchive?
  }
}

public struct MaiArchiveMergeSummary: Equatable, Sendable {
  public var providers = 0
  public var prompts = 0
  public var mcpServers = 0
  public var agents = 0

  public init() {}
}

extension MaiConfiguration {
  /// Upserts portable settings by their stable identifier. Sections absent
  /// from the archive are untouched; prompt dictionaries merge by name.
  @discardableResult
  public mutating func mergeArchiveSettings(_ imported: MaiArchiveSettings) throws
    -> MaiArchiveMergeSummary
  {
    var result = MaiArchiveMergeSummary()
    if let values = imported.providers {
      Self.archiveUpsert(values, into: &providers, id: \ConfiguredProvider.id)
      result.providers = values.count
    }
    if let values = imported.mcpServers {
      Self.archiveUpsert(values, into: &mcpServers, id: \ConfiguredMCPServer.id)
      result.mcpServers = values.count
    }
    if let values = imported.agents {
      Self.archiveUpsert(values, into: &agents, id: \AgentDefinition.id)
      result.agents = values.count
    }
    if let values = imported.prompts {
      var destination = prompts ?? ConfiguredPrompts()
      destination.system.merge(values.system) { _, imported in imported }
      destination.user.merge(values.user) { _, imported in imported }
      if let value = values.compact { destination.compact = value }
      if let value = values.recap { destination.recap = value }
      if let value = values.delegation { destination.delegation = value }
      if let value = values.worker { destination.worker = value }
      if let value = values.memory { destination.memory = value }
      prompts = destination
      for index in agents.indices {
        if let name = agents[index].systemPrompt, let text = destination.system[name] {
          agents[index].instructions = text
        }
      }
      result.prompts =
        values.system.count + values.user.count
        + [values.compact, values.recap, values.delegation, values.worker, values.memory].compactMap { $0 }.count
    }
    if let selected = imported.defaultAgent, agents.contains(where: { $0.id == selected }) {
      defaultAgent = selected
    }
    if let assignments = imported.taskAgents { taskAgents = assignments }
    try validate()
    return result
  }

  private static func archiveUpsert<Value, ID: Hashable>(
    _ imported: [Value],
    into destination: inout [Value],
    id: KeyPath<Value, ID>
  ) {
    var indexes = Dictionary(
      uniqueKeysWithValues: destination.indices.map { (destination[$0][keyPath: id], $0) })
    for value in imported {
      let key = value[keyPath: id]
      if let index = indexes[key] {
        destination[index] = value
      } else {
        indexes[key] = destination.count
        destination.append(value)
      }
    }
  }
}

/// The conversation envelope PocketMai shipped before `MaiArchive`. It stays
/// private: decoding old files is part of the archive contract, while new
/// hosts only need to understand the canonical models above.
private struct PocketMaiConversationEnvelope: Decodable {
  static let format = "pocketmai.conversation"

  var format: String
  var pocketMaiVersion: String
  var exportedAt: Date
  var conversation: PocketMaiConversation
  var conversations: [PocketMaiConversation]?

  var archive: MaiArchive {
    MaiArchive(
      generator: "PocketMai \(pocketMaiVersion)",
      exportedAt: exportedAt,
      chats: (conversations ?? [conversation]).map(\.agentChat))
  }
}

private struct PocketMaiConversation: Decodable {
  var id: UUID
  var title: String
  var messages: [PocketMaiMessage]
  var createdAt: Date
  var updatedAt: Date
  var provider: String
  var modelID: String
  var endpointID: UUID?
  var toolsEnabled: Bool?
  var enabledTools: [String]?
  var usesStreaming: Bool?
  var reasoningLevel: String?
  var folderID: String?
  var isArchived: Bool?
  var sessionID: String?
  var subagents: [AgentProcessRecord]?

  var agentChat: AgentChat {
    let providerID =
      provider == "openAICompatible"
      ? ProviderID(endpointID?.uuidString.lowercased() ?? "openai") : ProviderID(provider)
    let agent = AgentDefinition(
      id: "pocketmai",
      displayName: "PocketMai",
      instructions: "",
      provider: providerID,
      model: modelID,
      toolNames: toolsEnabled == false ? [] : Set(enabledTools ?? []),
      stream: usesStreaming ?? true,
      options: GenerationOptions(reasoningEffort: reasoningEffort))
    return AgentChat(
      id: id,
      title: title,
      primaryAgent: agent,
      messages: messages.map(\.agentMessage),
      createdAt: createdAt,
      updatedAt: updatedAt,
      isArchived: folderID == "archived" || isArchived == true,
      sessionID: sessionID ?? ChatSession.legacyID(for: id),
      subagents: subagents ?? [])
  }

  private var reasoningEffort: String? {
    switch reasoningLevel {
    case "disabled": "none"
    case "minimal", "low", "medium", "high", "xhigh", "max": reasoningLevel
    default: nil
    }
  }
}

private struct PocketMaiMessage: Decodable {
  var id: UUID
  var role: String
  var text: String
  var attachments: [PocketMaiAttachment]?

  var agentMessage: AgentMessage {
    let agentRole: AgentRole =
      switch role {
      case "user": .user
      case "system": .system
      case "tool": .tool
      default: .assistant
      }
    var content: [ContentPart] = text.isEmpty ? [] : [.text(text)]
    content.append(contentsOf: (attachments ?? []).compactMap(\.contentPart))
    return AgentMessage(id: id.uuidString.lowercased(), role: agentRole, content: content)
  }
}

private struct PocketMaiAttachment: Decodable {
  var kind: String
  var filename: String
  var mimeType: String
  var text: String?
  var dataBase64: String?
  var width: Int?
  var height: Int?

  var contentPart: ContentPart? {
    switch kind {
    case "textFile":
      .file(FileContent(name: filename, mimeType: mimeType, text: text ?? ""))
    case "image":
      dataBase64.flatMap { Data(base64Encoded: $0) }.map {
        .image(
          ImageContent(
            source: .data($0), mimeType: mimeType, name: filename, width: width, height: height))
      }
    default:
      nil
    }
  }
}

public enum MaiArchiveError: LocalizedError, Sendable {
  case invalidFormat
  case unsupportedVersion(Int)
  case emptyArchive
  case unreadableSkill(String)
  case invalidSkillName(String)
  case invalidSkillPath(String)
  case duplicateSkillPath(String, String)
  case emptySkill(String)

  public var errorDescription: String? {
    switch self {
    case .invalidFormat: "The file is not a Mai archive."
    case .unsupportedVersion(let version): "Mai archive version \(version) is not supported."
    case .emptyArchive: "The Mai archive contains no portable sections."
    case .unreadableSkill(let name): "Could not read skill '\(name)'."
    case .invalidSkillName(let name): "Invalid skill name '\(name)'."
    case .invalidSkillPath(let path): "Invalid path '\(path)' in a skill archive."
    case .duplicateSkillPath(let name, let path):
      "Skill '\(name)' contains the path '\(path)' more than once."
    case .emptySkill(let name): "Skill '\(name)' contains no files."
    }
  }
}
