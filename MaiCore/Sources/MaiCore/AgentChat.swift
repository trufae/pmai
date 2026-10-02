import Foundation

/// The session a chat presents to backends that meter or route by session,
/// such as OpenCode Zen through its `x-opencode-session` header. A chat is
/// given one when it is created, keeps it in its file, and can be given a
/// fresh one at any time without losing anything else; every provider call
/// the chat makes, including those of the child agents it starts, carries it
/// wherever a configured header says `{{session}}`.
public enum ChatSession {
  /// A fresh session id for a new chat.
  public static func newID() -> String {
    UUID().uuidString.lowercased()
  }

  /// The session of a chat saved before sessions existed: derived from the
  /// chat id, so every load agrees on it without rewriting the file.
  public static func legacyID(for chatID: UUID) -> String {
    chatID.uuidString.lowercased()
  }
}

/// A durable chat transcript associated with one primary agent definition.
/// Hosts can snapshot the inference setup so changes to installation defaults
/// do not change the models or endpoints of a resumed chat.
public struct AgentChat: StoredChat, Equatable {
  /// Title given to a chat that has not received its first message yet. A chat
  /// keeping this title with no conversation is disposable, like the placeholder
  /// PocketMai creates on launch.
  public static let placeholderTitle = "New chat"
  /// Maximum length of a title derived from the first user message.
  public static let derivedTitleLength = 48

  public var id: UUID
  public var title: String
  public var primaryAgent: AgentDefinition
  public var messages: [AgentMessage]
  public var pendingContent: [ContentPart]
  public var createdAt: Date
  public var updatedAt: Date
  /// Archived chats are kept for reference but listed apart from active ones.
  public var isArchived: Bool
  /// The session this chat presents to providers; see `ChatSession`.
  public var sessionID: String
  /// The agents this chat's runs started, parents before children, each
  /// with its own transcript: what `/agents tree` and `/agents log` show
  /// once the chat is resumed, and what the debug export carries. Hosts
  /// bring these up to date from the supervisor as runs end.
  public var subagents: [AgentProcessRecord]
  public var runtimeConfiguration: AgentChatConfiguration?

  public init(
    id: UUID = UUID(),
    title: String = AgentChat.placeholderTitle,
    primaryAgent: AgentDefinition,
    messages: [AgentMessage]? = nil,
    pendingContent: [ContentPart] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    isArchived: Bool = false,
    sessionID: String? = nil,
    subagents: [AgentProcessRecord] = [],
    runtimeConfiguration: AgentChatConfiguration? = nil
  ) {
    self.id = id
    self.title = title
    self.primaryAgent = primaryAgent
    self.messages = messages ?? Self.initialHistory(for: primaryAgent)
    self.pendingContent = pendingContent
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.isArchived = isArchived
    self.sessionID = sessionID ?? ChatSession.newID()
    self.subagents = subagents
    self.runtimeConfiguration = runtimeConfiguration
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, primaryAgent, messages, pendingContent, createdAt, updatedAt, isArchived
    case sessionID, subagents, runtimeConfiguration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    sessionID =
      try container.decodeIfPresent(String.self, forKey: .sessionID)
      ?? ChatSession.legacyID(for: id)
    title = try container.decode(String.self, forKey: .title)
    primaryAgent = try container.decode(AgentDefinition.self, forKey: .primaryAgent)
    messages = try container.decode([AgentMessage].self, forKey: .messages)
    pendingContent =
      try container.decodeIfPresent([ContentPart].self, forKey: .pendingContent) ?? []
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    subagents =
      try container.decodeIfPresent([AgentProcessRecord].self, forKey: .subagents) ?? []
    runtimeConfiguration = try container.decodeIfPresent(
      AgentChatConfiguration.self, forKey: .runtimeConfiguration)
  }

  /// The title shown to people; empty titles fall back to the placeholder.
  public var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Self.placeholderTitle : trimmed
  }

  /// True while the chat still carries the placeholder title.
  public var hasPlaceholderTitle: Bool {
    Self.isPlaceholderTitle(title)
  }

  /// Messages exchanged with the model, excluding configured instructions.
  public var conversationMessages: [AgentMessage] {
    messages.filter { $0.role != .system }
  }

  public var hasConversation: Bool {
    messages.contains { $0.role != .system }
  }

  /// An untouched placeholder: nothing was said, and nobody renamed or
  /// archived it. Queued attachments do not count; a chat that never received
  /// a message is dropped instead of piling up as an empty entry.
  public var isDisposable: Bool {
    Self.isDisposable(
      title: title,
      hasConversation: hasConversation,
      isBusy: false,
      isKept: isArchived)
  }

  /// The rule every host applies before listing or persisting a chat: an
  /// empty chat is never worth keeping unless someone deliberately marked it.
  /// `isKept` covers chats set aside on purpose, such as archived or pinned
  /// ones; `isBusy` covers a reply still being produced. Hosts layer their own
  /// transient input on top, as PocketMai does with unsent drafts. PocketMai
  /// and pmai share this so an empty chat left behind on either platform
  /// disappears the same way.
  public static func isDisposable(
    title: String,
    hasConversation: Bool,
    isBusy: Bool,
    isKept: Bool
  ) -> Bool {
    !hasConversation && !isBusy && !isKept && isPlaceholderTitle(title)
  }

  /// Blank titles and the placeholder itself count as "never named".
  public static func isPlaceholderTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == placeholderTitle
  }

  public mutating func assignPrimaryAgent(
    _ agent: AgentDefinition,
    resettingTranscript: Bool = true
  ) {
    primaryAgent = agent
    if resettingTranscript {
      messages = Self.initialHistory(for: agent)
      subagents.removeAll()
    }
    pendingContent.removeAll()
    touch()
  }

  /// A cleared conversation keeps nothing of its runs: the agents they
  /// started go with the messages.
  public mutating func resetTranscript() {
    messages = Self.initialHistory(for: primaryAgent)
    subagents.removeAll()
    pendingContent.removeAll()
    touch()
  }

  public mutating func touch(at date: Date = Date()) {
    updatedAt = date
  }

  /// Names a placeholder chat after its first message, as PocketMai does.
  /// Titles chosen by people are never replaced.
  public mutating func refreshTitle(from text: String) {
    guard hasPlaceholderTitle, let derived = Self.derivedTitle(from: text) else { return }
    title = derived
  }

  public mutating func setArchived(_ archived: Bool, at date: Date = Date()) {
    guard isArchived != archived else { return }
    isArchived = archived
    touch(at: date)
  }

  public static func derivedTitle(from text: String) -> String? {
    let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !compact.isEmpty else { return nil }
    return String(compact.prefix(derivedTitleLength)).trimmingCharacters(in: .whitespaces)
  }

  public static func initialHistory(for agent: AgentDefinition) -> [AgentMessage] {
    let instructions = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
  }
}

/// A persistable collection of independent chats and the chat selected by a host.
///
/// The workspace remembers which chats changed or disappeared since it was
/// last committed, so an `AgentChatStore` writes and deletes only those files.
public struct AgentChatWorkspace: Codable, Equatable, Sendable {
  public var version: Int
  public private(set) var selectedChatID: UUID?
  public private(set) var chats: [AgentChat]
  /// Chats added or changed since the last commit.
  public private(set) var modifiedChatIDs: Set<UUID>
  /// Chats removed since the last commit whose files should go away.
  public private(set) var removedChatIDs: Set<UUID>

  /// A freshly built workspace treats every chat as new, so committing it to
  /// a store writes them all; stores mark what they load as committed.
  public init(
    version: Int = 1,
    chats: [AgentChat] = [],
    selectedChatID: UUID? = nil
  ) {
    self.version = version
    self.chats = chats
    self.selectedChatID =
      selectedChatID.flatMap { id in
        chats.contains(where: { $0.id == id }) ? id : nil
      } ?? chats.first?.id
    modifiedChatIDs = Set(chats.map(\.id))
    removedChatIDs = []
  }

  private enum CodingKeys: String, CodingKey {
    case version, selectedChatID, chats
  }

  /// Decoding goes through the memberwise initializer so a missing or dangling
  /// selection falls back to the first chat, as it does for hosts.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
      chats: try container.decodeIfPresent([AgentChat].self, forKey: .chats) ?? [],
      selectedChatID: try container.decodeIfPresent(UUID.self, forKey: .selectedChatID))
  }

  /// Change tracking is bookkeeping, not content: two workspaces holding the
  /// same chats and selection are equal however they got there.
  public static func == (lhs: AgentChatWorkspace, rhs: AgentChatWorkspace) -> Bool {
    lhs.version == rhs.version && lhs.selectedChatID == rhs.selectedChatID
      && lhs.chats == rhs.chats
  }

  public var selectedChat: AgentChat? {
    guard let selectedChatID else { return nil }
    return chats.first { $0.id == selectedChatID }
  }

  /// Chats in the order a sidebar shows them: active chats newest first,
  /// then archived chats newest first. Listing indexes refer to this order.
  public var orderedChats: [AgentChat] {
    activeChats + archivedChats
  }

  public var activeChats: [AgentChat] {
    chats.filter { !$0.isArchived }.sorted(by: Self.precedes)
  }

  public var archivedChats: [AgentChat] {
    chats.filter(\.isArchived).sorted(by: Self.precedes)
  }

  /// The chat to continue when a host prefers resuming over starting fresh.
  public var mostRecentActiveChat: AgentChat? {
    activeChats.first { $0.hasConversation }
  }

  /// The newest saved conversation, including archived chats.
  public var mostRecentChat: AgentChat? {
    chats.filter(\.hasConversation).sorted(by: Self.precedes).first
  }

  public var hasUncommittedChanges: Bool {
    !modifiedChatIDs.isEmpty || !removedChatIDs.isEmpty
  }

  /// Forgets the recorded changes once a store has written them.
  public mutating func markCommitted() {
    modifiedChatIDs.removeAll()
    removedChatIDs.removeAll()
  }

  @discardableResult
  public mutating func selectChat(id: UUID) -> Bool {
    guard chats.contains(where: { $0.id == id }) else { return false }
    selectedChatID = id
    return true
  }

  public mutating func upsert(_ chat: AgentChat, selecting: Bool = false) {
    if let index = chats.firstIndex(where: { $0.id == chat.id }) {
      if chats[index] != chat {
        chats[index] = chat
        modifiedChatIDs.insert(chat.id)
      }
    } else {
      chats.append(chat)
      modifiedChatIDs.insert(chat.id)
    }
    removedChatIDs.remove(chat.id)
    if selecting || selectedChatID == nil { selectedChatID = chat.id }
  }

  @discardableResult
  public mutating func removeChat(id: UUID) -> AgentChat? {
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return nil }
    let removed = chats.remove(at: index)
    modifiedChatIDs.remove(id)
    removedChatIDs.insert(id)
    if selectedChatID == id {
      selectedChatID = chats.isEmpty ? nil : chats[min(index, chats.count - 1)].id
    }
    return removed
  }

  /// Creates and selects a fresh placeholder chat, dropping every other
  /// placeholder so only one empty chat exists at a time.
  @discardableResult
  public mutating func startNewChat(
    primaryAgent: AgentDefinition,
    title: String? = nil,
    at date: Date = Date()
  ) -> AgentChat {
    let chat = AgentChat(
      title: title ?? AgentChat.placeholderTitle,
      primaryAgent: primaryAgent,
      createdAt: date,
      updatedAt: date)
    removeDisposableChats()
    upsert(chat, selecting: true)
    return chat
  }

  /// Removes untouched placeholder chats, optionally sparing one of them.
  @discardableResult
  public mutating func removeDisposableChats(keeping keptID: UUID? = nil) -> [AgentChat] {
    let disposable = chats.filter { $0.isDisposable && $0.id != keptID }
    for chat in disposable { removeChat(id: chat.id) }
    return disposable
  }

  @discardableResult
  public mutating func setArchived(_ archived: Bool, id: UUID, at date: Date = Date()) -> Bool {
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return false }
    guard chats[index].isArchived != archived else { return true }
    chats[index].setArchived(archived, at: date)
    modifiedChatIDs.insert(id)
    return true
  }

  public static func precedes(_ lhs: AgentChat, _ rhs: AgentChat) -> Bool {
    AgentChat.precedes(lhs, rhs)
  }

  /// Reads a single-file workspace, the layout pmai used before per-project
  /// chat directories. Every chat counts as modified so a store can adopt it.
  public static func load(from url: URL) throws -> AgentChatWorkspace {
    try MaiJSONCoding.default.makeDecoder().decode(
      AgentChatWorkspace.self, from: Data(contentsOf: url))
  }

  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try MaiJSONCoding.default.makeEncoder().encode(self).write(to: url, options: .atomic)
  }
}
