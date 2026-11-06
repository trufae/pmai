import Foundation
import MaiCore

struct REPLSession: Sendable {
  var id: UUID
  /// The session the chat presents to providers; see `ChatSession`.
  var sessionID: String
  var title: String
  var profile: SessionProfile
  var history: AgentTranscript {
    didSet {
      if !isKnownUniquelyReferenced(&historyChanges) { historyChanges = historyChanges.copy() }
      historyChanges.changed(
        from: zip(oldValue.messages, history.messages).prefix { $0 == $1 }.count)
    }
  }
  var historyChanges = ChatHistoryChanges()
  var historyWindow: ChatHistoryWindow? = nil
  /// The whole history's size, measured before it was swapped for a page,
  /// so the status line keeps describing the chat rather than the page.
  var historyContextSize: AgentContextSize? = nil
  var fileAccessLog: FileAccessLog
  var pendingContent: [ContentPart]
  var createdAt: Date
  var updatedAt: Date
  var isArchived: Bool
  var isPinned: Bool
  /// The agents this chat's runs started, with their transcripts, as saved
  /// with the chat. The REPL brings them up to date from the supervisor as
  /// runs end and puts them back in the process table when the chat is
  /// reopened, so `/jobs tree` and `/jobs log` outlive the session.
  var subagents: [AgentProcessRecord]
  var commands: [AgentCommandRecord]
  var runtimeConfiguration: AgentChatConfiguration?
  var redactor: ContentRedactor?

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
    fileAccessLog = FileAccessLog()
    self.pendingContent = pendingContent
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    isArchived = false
    isPinned = false
    subagents = []
    commands = []
    redactor = nil
  }

  init(chat: AgentChat) {
    id = chat.id
    sessionID = chat.sessionID
    title = chat.title
    profile = SessionProfile(definition: chat.primaryAgent)
    history = AgentTranscript(messages: chat.messages)
    historyWindow = chat.historyWindow
    historyChanges = chat.historyChanges
    fileAccessLog = FileAccessLog(paths: chat.accessedFiles)
    pendingContent = chat.pendingContent
    createdAt = chat.createdAt
    updatedAt = chat.updatedAt
    isArchived = chat.isArchived
    isPinned = chat.isPinned
    subagents = chat.subagents
    commands = chat.commands
    runtimeConfiguration = chat.runtimeConfiguration
    redactor = nil
  }

  var chat: AgentChat {
    var result = AgentChat(
      id: id,
      title: title,
      primaryAgent: profile.agentDefinition,
      messages: history.messages,
      pendingContent: pendingContent,
      accessedFiles: fileAccessLog.snapshot(),
      createdAt: createdAt,
      updatedAt: updatedAt,
      isArchived: isArchived,
      isPinned: isPinned,
      sessionID: sessionID,
      subagents: redactor?.unredact(subagents) ?? subagents,
      commands: commands,
      runtimeConfiguration: runtimeConfiguration,
      historyWindow: historyWindow)
    result.historyChanges = historyChanges
    return result
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
    fileAccessLog = FileAccessLog()
    touch()
  }

  mutating func touch() {
    updatedAt = Date()
  }

  private static func initialHistory(for profile: SessionProfile) -> [AgentMessage] {
    let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
  }
}
