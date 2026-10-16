import Foundation
import Testing

@testable import MaiCore

private let chatAgent = AgentDefinition(
  id: "local",
  instructions: "Be concise.",
  provider: "endpoint",
  model: "model-a")

@Test("Agent chats retain one primary agent and reset to its instructions")
func agentChatPrimaryAgent() {
  var chat = AgentChat(title: "Work", primaryAgent: chatAgent)
  #expect(chat.messages.count == 1)
  #expect(chat.messages.first?.role == .system)
  #expect(chat.messages.first?.text == "Be concise.")

  var replacement = chatAgent
  replacement.id = "reviewer"
  replacement.instructions = "Review carefully."
  chat.messages.append(.user("old context"))
  chat.assignPrimaryAgent(replacement)

  #expect(chat.primaryAgent.id == "reviewer")
  #expect(chat.messages.count == 1)
  #expect(chat.messages.first?.role == .system)
  #expect(chat.messages.first?.text == "Review carefully.")
}

@Test("Chats keep the session minted for them, and files from before sessions derive one")
func agentChatSession() throws {
  let chat = AgentChat(title: "Work", primaryAgent: chatAgent)
  #expect(!chat.sessionID.isEmpty)
  #expect(chat.sessionID != AgentChat(primaryAgent: chatAgent).sessionID)
  #expect(AgentChat(primaryAgent: chatAgent, sessionID: "kept").sessionID == "kept")

  let data = try JSONEncoder().encode(chat)
  #expect(try JSONDecoder().decode(AgentChat.self, from: data).sessionID == chat.sessionID)

  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "sessionID")
  let legacy = try JSONSerialization.data(withJSONObject: object)
  #expect(
    try JSONDecoder().decode(AgentChat.self, from: legacy).sessionID
      == ChatSession.legacyID(for: chat.id))
  #expect(ChatSession.legacyID(for: chat.id) == chat.id.uuidString.lowercased())
}

@Test("Chat workspaces switch, update, remove, and persist chats")
func agentChatWorkspaceRoundTrip() throws {
  // Files keep millisecond precision, so round-trip checks use aligned dates.
  let base = Date(timeIntervalSince1970: 1_700_000_000.25)
  let first = AgentChat(title: "First", primaryAgent: chatAgent, createdAt: base, updatedAt: base)
  let second = AgentChat(
    title: "Second", primaryAgent: chatAgent, createdAt: base + 1, updatedAt: base + 1)
  var workspace = AgentChatWorkspace(chats: [first, second], selectedChatID: first.id)

  let selected = workspace.selectChat(id: second.id)
  #expect(selected)
  #expect(workspace.selectedChat?.title == "Second")
  var changed = second
  changed.title = "Renamed"
  workspace.upsert(changed)
  #expect(workspace.selectedChat?.title == "Renamed")
  #expect(workspace.removeChat(id: second.id) == changed)
  #expect(workspace.selectedChatID == first.id)

  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("maicore-chats-\(UUID().uuidString)/chats.json")
  try workspace.save(to: url)
  #expect(try AgentChatWorkspace.load(from: url) == workspace)
}

@Test("Forks preserve structured history and settings with independent chat identities")
func agentChatFork() {
  let base = Date(timeIntervalSince1970: 1_700_000_000)
  let attachment = ContentPart.file(
    FileContent(name: "notes.txt", mimeType: "text/plain", text: "Saved notes"))
  var call = AgentMessage(role: .assistant, content: [
    .reasoning("Read the notes."),
    .toolCall(ToolCall(id: "read-1", name: "files_read", arguments: .object([:]))),
  ])
  call.providerState = ["opaque": .string("replay state")]
  let source = AgentChat(
    title: "Work", primaryAgent: chatAgent,
    messages: [
      .system("Compacted instructions"),
      AgentMessage(role: .user, content: [.text("Read this"), attachment]),
      call,
      AgentMessage(role: .tool, content: [.toolResult(ToolResult(callID: "read-1", text: "Read"))]),
    ],
    pendingContent: [attachment], createdAt: base, updatedAt: base + 1, isArchived: true,
    subagents: [AgentProcessRecord(
      process: AgentProcessInfo(
        pid: 2, parent: 1, runID: UUID(), agentID: "worker", state: .completed,
        depth: 1, startedAt: base, finishedAt: base + 1),
      messages: [.assistant("Worker findings")])],
    runtimeConfiguration: AgentChatConfiguration(configuration: MaiConfiguration(agents: [chatAgent])))
  var fork = source.forked(at: base + 2)
  #expect(fork.id != source.id)
  #expect(fork.sessionID != source.sessionID)
  #expect(fork.title == "Work (fork)")
  #expect(fork.createdAt == base + 2 && fork.updatedAt == base + 2)
  #expect(!fork.isArchived)
  #expect(fork.primaryAgent == source.primaryAgent)
  #expect(fork.messages == source.messages)
  #expect(fork.pendingContent == source.pendingContent)
  #expect(fork.subagents == source.subagents)
  #expect(fork.runtimeConfiguration == source.runtimeConfiguration)
  fork.messages[1].content = [.text("Changed in the fork")]
  fork.pendingContent.removeAll()
  fork.primaryAgent.model = "other-model"
  #expect(source.messages[1].content == [.text("Read this"), attachment])
  #expect(source.pendingContent == [attachment])
  #expect(source.primaryAgent == chatAgent)
  #expect(source.forked(title: " Alternative ").title == "Alternative")
  #expect(source.forked(title: " \n ").title == "Work (fork)")
  #expect(!AgentChat(primaryAgent: chatAgent).forked().isDisposable)
}

@Test("Chats saved before archiving existed decode as active")
func agentChatDecodesWithoutArchiveFlag() throws {
  let legacy = """
    {
      "version": 1,
      "chats": [{
        "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
        "title": "Legacy",
        "primaryAgent": \(String(decoding: try JSONEncoder().encode(chatAgent), as: UTF8.self)),
        "messages": [],
        "createdAt": 0,
        "updatedAt": 0
      }]
    }
    """
  let workspace = try JSONDecoder().decode(AgentChatWorkspace.self, from: Data(legacy.utf8))
  #expect(workspace.chats.count == 1)
  #expect(workspace.chats[0].isArchived == false)
  #expect(workspace.chats[0].pendingContent.isEmpty)
  #expect(workspace.selectedChatID == workspace.chats[0].id)
}

@Test("Placeholder chats are disposable until something happens to them")
func agentChatDisposable() {
  var chat = AgentChat(primaryAgent: chatAgent)
  #expect(chat.title == AgentChat.placeholderTitle)
  #expect(chat.isDisposable)
  #expect(!chat.hasConversation)

  var renamed = chat
  renamed.title = "Kept on purpose"
  #expect(!renamed.isDisposable)

  var attached = chat
  attached.pendingContent = [.text("queued")]
  #expect(attached.isDisposable, "queued attachments alone do not make a conversation")

  var archived = chat
  archived.setArchived(true)
  #expect(!archived.isDisposable)

  chat.messages.append(.user("hello"))
  #expect(chat.hasConversation)
  #expect(!chat.isDisposable)
  #expect(chat.conversationMessages.count == 1)
}

@Test("Placeholder titles come from the first message; chosen titles stay")
func agentChatDerivedTitle() {
  var chat = AgentChat(primaryAgent: chatAgent)
  chat.refreshTitle(
    from: "  Fix the\n  android   linker for ssl and crypto, then publish the build ")
  #expect(chat.title == "Fix the android linker for ssl and crypto, then")
  #expect(chat.title.count < AgentChat.derivedTitleLength)
  #expect(AgentChat.derivedTitle(from: String(repeating: "x", count: 60))?.count == 48)

  chat.refreshTitle(from: "second message")
  #expect(chat.title == "Fix the android linker for ssl and crypto, then")

  var named = AgentChat(title: "Release notes", primaryAgent: chatAgent)
  named.refreshTitle(from: "anything")
  #expect(named.title == "Release notes")

  var blank = AgentChat(title: "  ", primaryAgent: chatAgent)
  #expect(blank.hasPlaceholderTitle)
  blank.refreshTitle(from: "   \n ")
  #expect(blank.title == "  ")
  #expect(AgentChat.derivedTitle(from: "") == nil)
}

@Test("Workspaces list active chats newest first and archived chats last")
func agentChatWorkspaceOrdering() {
  let base = Date(timeIntervalSince1970: 1_000_000)
  let older = AgentChat(
    title: "Older", primaryAgent: chatAgent, messages: [.user("a")],
    createdAt: base, updatedAt: base)
  let newer = AgentChat(
    title: "Newer", primaryAgent: chatAgent, messages: [.user("b")],
    createdAt: base + 10, updatedAt: base + 100)
  let archived = AgentChat(
    title: "Archived", primaryAgent: chatAgent, messages: [.user("c")],
    createdAt: base + 20, updatedAt: base + 200, isArchived: true)
  let tie = AgentChat(
    title: "Tie", primaryAgent: chatAgent, messages: [.user("d")],
    createdAt: base + 5, updatedAt: base)
  let workspace = AgentChatWorkspace(chats: [older, archived, newer, tie])

  #expect(workspace.activeChats.map(\.title) == ["Newer", "Tie", "Older"])
  #expect(workspace.archivedChats.map(\.title) == ["Archived"])
  #expect(workspace.orderedChats.map(\.title) == ["Newer", "Tie", "Older", "Archived"])
  #expect(workspace.mostRecentActiveChat?.title == "Newer")
  #expect(workspace.mostRecentChat?.title == "Archived")
}

@Test("Starting a new chat keeps a single placeholder and drops the rest")
func agentChatWorkspaceStartNewChat() {
  var workspace = AgentChatWorkspace()
  let first = workspace.startNewChat(primaryAgent: chatAgent)
  #expect(workspace.selectedChatID == first.id)
  #expect(workspace.mostRecentActiveChat == nil)

  var used = first
  used.messages.append(.user("keep me"))
  workspace.upsert(used)
  let stray = workspace.startNewChat(primaryAgent: chatAgent)
  let second = workspace.startNewChat(primaryAgent: chatAgent)
  #expect(workspace.chats.map(\.id) == [first.id, second.id])
  #expect(!workspace.chats.contains { $0.id == stray.id })
  #expect(workspace.selectedChatID == second.id)

  let removed = workspace.removeDisposableChats(keeping: second.id)
  #expect(removed.isEmpty)
  #expect(workspace.removeDisposableChats().map(\.id) == [second.id])
  #expect(workspace.selectedChatID == first.id)
}

@Test("Archiving is reversible and bumps the update time")
func agentChatWorkspaceArchive() {
  let base = Date(timeIntervalSince1970: 1_000_000)
  let chat = AgentChat(
    title: "Work", primaryAgent: chatAgent, messages: [.user("a")],
    createdAt: base, updatedAt: base)
  var workspace = AgentChatWorkspace(chats: [chat])
  let archived = workspace.setArchived(true, id: chat.id, at: base + 5)
  #expect(archived)
  #expect(workspace.archivedChats.map(\.id) == [chat.id])
  #expect(workspace.activeChats.isEmpty)
  #expect(workspace.chats[0].updatedAt == base + 5)
  let repeated = workspace.setArchived(true, id: chat.id, at: base + 9)
  #expect(repeated)
  #expect(workspace.chats[0].updatedAt == base + 5)
  let restored = workspace.setArchived(false, id: chat.id, at: base + 10)
  #expect(restored)
  #expect(workspace.activeChats.map(\.id) == [chat.id])
  #expect(workspace.chats[0].updatedAt == base + 10)
  let missing = workspace.setArchived(true, id: UUID())
  #expect(!missing)
}

@Test("Chat dates group like the PocketMai sidebar")
func chatDatePresentationGroups() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
  calendar.firstWeekday = 2
  // Thursday 2026-09-10 12:00 UTC
  let now = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 12)))
  func group(_ seconds: TimeInterval) -> String {
    ChatDatePresentation.groupTitle(for: now + seconds, relativeTo: now, calendar: calendar)
  }
  #expect(group(-3_600) == "Today")
  #expect(group(-86_400) == "Yesterday")
  #expect(group(-3 * 86_400) == "This week")
  #expect(group(-5 * 86_400) == "Last week")
  #expect(group(-20 * 86_400) == "August 21")
  #expect(group(-400 * 86_400) == "August 6, 2025")

  #expect(ChatDatePresentation.timestamp(now, calendar: calendar) == "2026-09-10 12:00")
  #expect(
    ChatDatePresentation.compactTimestamp(now - 60, relativeTo: now, calendar: calendar)
      == "11:59")
  #expect(
    ChatDatePresentation.compactTimestamp(now - 86_400, relativeTo: now, calendar: calendar)
      == "2026-09-09 12:00")
}
