import Foundation
import Testing

@testable import MaiCore

private let storeAgent = AgentDefinition(
  id: "local",
  instructions: "Be concise.",
  provider: "endpoint",
  model: "model-a")

/// Chat files keep millisecond precision, so round-trip checks use aligned dates.
private let storeEpoch = Date(timeIntervalSince1970: 1_700_000_000.5)

private func scratchDirectory(_ name: String) -> URL {
  FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("maicore-\(name)-\(UUID().uuidString)", isDirectory: true)
}

@Test("Pinned placeholders persist in full chats, summaries, and paged metadata")
func pinnedChatPersistence() throws {
  let directory = scratchDirectory("pinned")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = AgentChatStore(directoryURL: directory)
  let chat = AgentChat(
    primaryAgent: storeAgent, createdAt: storeEpoch, updatedAt: storeEpoch, isPinned: true)
  #expect(!chat.isDisposable)
  #expect(try store.save(chat))
  #expect(try store.loadChat(id: chat.id)?.isPinned == true)
  #expect(try store.loadSummaries().first?.isPinned == true)
  #expect(try store.loadWorkspace(paged: true).selectedChat?.isPinned == true)
  #expect(!chat.forked().isPinned)

  var object = try #require(JSONSerialization.jsonObject(
    with: MaiJSONCoding.default.makeEncoder().encode(chat)) as? [String: Any])
  object.removeValue(forKey: "isPinned")
  let legacy = try JSONSerialization.data(withJSONObject: object)
  #expect(try MaiJSONCoding.default.makeDecoder().decode(AgentChat.self, from: legacy).isPinned == false)
  #expect(try MaiJSONCoding.default.makeDecoder().decode(AgentChatSummary.self, from: legacy).isPinned == false)
}

@Test("The disposable rule is shared: untouched placeholders only")
func sharedDisposableRule() {
  #expect(AgentChat.isDisposable(
    title: "New chat", hasConversation: false, isBusy: false, isKept: false))
  #expect(AgentChat.isDisposable(
    title: "  ", hasConversation: false, isBusy: false, isKept: false))
  #expect(!AgentChat.isDisposable(
    title: "Named", hasConversation: false, isBusy: false, isKept: false))
  #expect(!AgentChat.isDisposable(
    title: "New chat", hasConversation: true, isBusy: false, isKept: false))
  #expect(!AgentChat.isDisposable(
    title: "New chat", hasConversation: false, isBusy: true, isKept: false))
  #expect(!AgentChat.isDisposable(
    title: "New chat", hasConversation: false, isBusy: false, isKept: true))
  #expect(AgentChat.isPlaceholderTitle(" New chat "))
  #expect(!AgentChat.isPlaceholderTitle("new chat"))
}

@Test("Chat stores never write disposable chats and drop their stale files")
func chatStoreSkipsDisposableChats() throws {
  let store = AgentChatStore(directoryURL: scratchDirectory("store"))
  let placeholder = AgentChat(primaryAgent: storeAgent, createdAt: storeEpoch, updatedAt: storeEpoch)
  #expect(try store.save(placeholder) == false)
  #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: placeholder.id).path))
  #expect(try store.chatIDs().isEmpty)

  var used = placeholder
  used.messages.append(.user("hello"))
  used.refreshTitle(from: "hello")
  #expect(try store.save(used))
  #expect(try store.chatIDs() == [used.id])
  #expect(try store.loadChat(id: used.id) == used)

  // Clearing the transcript makes it disposable again: saving refuses, but the
  // existing file is left alone until a host deletes it on purpose.
  var cleared = used
  cleared.resetTranscript()
  cleared.touch(at: storeEpoch + 2)
  cleared.title = AgentChat.placeholderTitle
  #expect(try store.save(cleared) == false)
  #expect(try store.chatIDs() == [used.id])
  #expect(try store.loadChat(id: used.id) == used)
  #expect(try store.save(cleared, evenIfDisposable: true))
  #expect(try store.loadChat(id: used.id) == cleared)
  #expect(try store.delete(id: used.id))
  #expect(try store.chatIDs().isEmpty)
  #expect(try store.loadChat(id: used.id) == nil)
  #expect(try store.delete(id: used.id) == false)
}

@Test("Committing a workspace deletes the file of a chat that became disposable")
func chatStoreCommitDropsDisposable() throws {
  let store = AgentChatStore(directoryURL: scratchDirectory("commit-disposable"))
  var workspace = AgentChatWorkspace()
  var chat = workspace.startNewChat(primaryAgent: storeAgent)
  chat.messages.append(.user("kept for a while"))
  chat.refreshTitle(from: "kept for a while")
  workspace.upsert(chat)
  try store.commit(&workspace)
  #expect(try store.chatIDs() == [chat.id])

  chat.resetTranscript()
  chat.title = AgentChat.placeholderTitle
  workspace.upsert(chat)
  try store.commit(&workspace)
  #expect(try store.chatIDs().isEmpty)
  #expect(workspace.chats.count == 1, "the placeholder stays in memory")
}

@Test("Committing a workspace writes changed chats and deletes removed ones")
func chatStoreCommitTracksChanges() throws {
  let store = AgentChatStore(directoryURL: scratchDirectory("commit"))
  var workspace = AgentChatWorkspace()
  let first = workspace.startNewChat(primaryAgent: storeAgent, at: storeEpoch)
  try store.commit(&workspace)
  #expect(try store.chatIDs().isEmpty, "a fresh placeholder has no file")
  #expect(!workspace.hasUncommittedChanges)

  var chat = first
  chat.messages.append(.user("first message"))
  chat.refreshTitle(from: "first message")
  workspace.upsert(chat, selecting: true)
  #expect(workspace.modifiedChatIDs == [chat.id])
  try store.commit(&workspace)
  #expect(try store.chatIDs() == [chat.id])

  let second = workspace.startNewChat(primaryAgent: storeAgent, at: storeEpoch + 1)
  var named = second
  named.title = "Kept"
  workspace.upsert(named)
  try store.commit(&workspace)
  #expect(Set(try store.chatIDs()) == [chat.id, named.id])

  workspace.removeChat(id: chat.id)
  #expect(workspace.removedChatIDs == [chat.id])
  try store.commit(&workspace)
  #expect(try store.chatIDs() == [named.id])
  #expect(!workspace.hasUncommittedChanges)

  let reloaded = try store.loadWorkspace()
  #expect(reloaded.chats == [named])
  #expect(!reloaded.hasUncommittedChanges)
  #expect(reloaded.selectedChatID == named.id)
}

@Test("Summaries list chats in sidebar order without their transcripts")
func chatStoreSummaries() throws {
  let store = AgentChatStore(directoryURL: scratchDirectory("summaries"))
  let base = Date(timeIntervalSince1970: 1_000_000)
  let older = AgentChat(
    title: "Older", primaryAgent: storeAgent, messages: [.system("x"), .user("a")],
    createdAt: base, updatedAt: base)
  let newer = AgentChat(
    title: "Newer", primaryAgent: storeAgent, messages: [.user("b"), .assistant("c")],
    createdAt: base + 10, updatedAt: base + 100)
  let archived = AgentChat(
    title: "Archived", primaryAgent: storeAgent, messages: [.user("d")],
    createdAt: base + 20, updatedAt: base + 200, isArchived: true)
  let queued = AgentChat(
    primaryAgent: storeAgent, pendingContent: [.text("attachment")],
    createdAt: base + 30, updatedAt: base + 300)
  for chat in [older, newer, archived, queued, AgentChat(primaryAgent: storeAgent)] {
    try store.save(chat)
  }
  try Data("not json".utf8).write(to: store.fileURL(for: UUID()))

  var failures: [URL] = []
  let summaries = try store.loadSummaries { failures.append($0.url) }
  #expect(failures.count == 1)
  #expect(try store.chatIDs().count == 4, "the two placeholders were never written")
  #expect(summaries.map(\.title) == ["Newer", "Older", "Archived"])
  #expect(summaries.map(\.messageCount) == [2, 1, 1])
  #expect(summaries[0].agentID == "local")
  #expect(summaries[0].provider == "endpoint")
  #expect(summaries[0].model == "model-a")
  #expect(summaries[0].displayTitle == "Newer")
  #expect(summaries.allSatisfy { !$0.isDisposable && !$0.hasPendingContent })
  #expect(try store.loadChats().count == 3)
  #expect(try store.loadChat(id: queued.id) == nil)
}

@Test("Stores follow PocketMai's file conventions: ISO dates, quarantine, restore")
func chatStoreConventions() throws {
  let store = AgentChatStore(directoryURL: scratchDirectory("conventions"))
  let chat = AgentChat(
    title: "Dated", primaryAgent: storeAgent, messages: [.user("hi")],
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
  try store.save(chat)
  let text = String(decoding: try Data(contentsOf: store.fileURL(for: chat.id)), as: UTF8.self)
  #expect(text.contains("\"createdAt\" : \"2023-11-14T22:13:20.000Z\""))
  #expect(try store.loadChat(id: chat.id) == chat)

  // Numeric dates written by earlier MaiCore builds, and plain ISO dates as
  // PocketMai writes them, still decode.
  let numeric = text.replacingOccurrences(
    of: "\"2023-11-14T22:13:20.000Z\"", with: "\(chat.createdAt.timeIntervalSinceReferenceDate)")
  try Data(numeric.utf8).write(to: store.fileURL(for: chat.id))
  #expect(try store.loadChat(id: chat.id)?.createdAt == chat.createdAt)
  let plain = text.replacingOccurrences(of: "\"2023-11-14T22:13:20.000Z\"", with: "\"2023-11-14T22:13:20Z\"")
  try Data(plain.utf8).write(to: store.fileURL(for: chat.id))
  #expect(try store.loadChat(id: chat.id)?.createdAt == chat.createdAt)
  try Data(text.utf8).write(to: store.fileURL(for: chat.id))

  // A file that is not a chat is quarantined beside the live ones, bytes intact.
  let badID = UUID()
  let bad = Data("{\"validJSON\":true}".utf8)
  try bad.write(to: store.fileURL(for: badID))
  var reported: [ChatFileStoreError] = []
  #expect(try store.loadChats { reported.append($0) }.count == 1)
  guard case .undecodable(let badURL, _)? = reported.first else {
    Issue.record("expected an undecodable report")
    return
  }
  let quarantined = try #require(store.quarantine(fileAt: badURL))
  #expect(quarantined.lastPathComponent == "\(badID.uuidString).json.corrupt")
  #expect(try Data(contentsOf: quarantined) == bad)
  #expect(store.quarantinedFileURLs().map(\.lastPathComponent) == [quarantined.lastPathComponent])
  #expect(try store.chatIDs() == [chat.id])
  #expect(store.quarantine(fileAt: badURL) == nil, "nothing left to move")
  try bad.write(to: store.fileURL(for: badID))
  #expect(
    store.quarantine(fileAt: badURL)?.lastPathComponent == "\(badID.uuidString)-2.json.corrupt")

  // A quarantined file that decodes again goes back among the live chats.
  let recoverable = store.fileURL(for: chat.id).appendingPathExtension("corrupt")
  try store.delete(id: chat.id)
  try Data(text.utf8).write(to: recoverable)
  #expect(try store.restoreQuarantinedFile(at: recoverable) == chat)
  #expect(try store.chatIDs() == [chat.id])
  try Data(text.utf8).write(to: recoverable)
  #expect(throws: ChatFileStoreError.self) { try store.restoreQuarantinedFile(at: recoverable) }
}

@Test("Newest-wins merging keeps one record per id in first-seen order")
func newestRecordWins() {
  let base = Date(timeIntervalSince1970: 3_000_000)
  let id = UUID()
  let stale = AgentChat(
    id: id, title: "Stale", primaryAgent: storeAgent, createdAt: base, updatedAt: base)
  let fresh = AgentChat(
    id: id, title: "Fresh", primaryAgent: storeAgent, createdAt: base, updatedAt: base + 5)
  let other = AgentChat(title: "Other", primaryAgent: storeAgent, createdAt: base, updatedAt: base)
  let merged = AgentChat.newest(of: [stale, other, fresh])
  #expect(merged.map(\.title) == ["Fresh", "Other"])
  #expect(AgentChat.precedes(fresh, other))
}

@Test("Legacy single-file workspaces import into a store")
func legacyWorkspaceImport() throws {
  let root = scratchDirectory("legacy")
  let legacyURL = root.appendingPathComponent("chats.json")
  let chat = AgentChat(title: "Kept", primaryAgent: storeAgent, messages: [.user("hi")])
  try AgentChatWorkspace(chats: [chat, AgentChat(primaryAgent: storeAgent)]).save(to: legacyURL)

  var imported = try AgentChatWorkspace.load(from: legacyURL)
  #expect(imported.modifiedChatIDs.count == 2)
  let store = AgentChatStore(directoryURL: root.appendingPathComponent("chats"))
  try store.commit(&imported)
  #expect(try store.chatIDs() == [chat.id])
}

@Test("Project tints accept presets and hex values, including PocketMai's spelling")
func projectTints() throws {
  #expect(AgentProjectTint(rawValue: " Blue ")?.rawValue == "blue")
  #expect(AgentProjectTint(rawValue: "blue")?.hex == "#007AFF")
  #expect(AgentProjectTint(rawValue: "#abc")?.rawValue == "#AABBCC")
  #expect(AgentProjectTint(rawValue: "custom:#ff8800")?.rawValue == "#FF8800")
  let rgb = AgentProjectTint(rawValue: "ff8800")!.rgb
  #expect(rgb.red == 255 && rgb.green == 136 && rgb.blue == 0)
  #expect(AgentProjectTint(rawValue: "plaid") == nil)
  #expect(AgentProjectTint(rawValue: "#12345") == nil)
  #expect(AgentProjectTint(rawValue: "mint")?.displayName == "Mint")

  let encoded = try JSONEncoder().encode([
    AgentProjectTint(rawValue: "teal")!, AgentProjectTint(rawValue: "#ff8800")!,
  ])
  #expect(String(decoding: encoded, as: UTF8.self) == "[\"teal\",\"custom:#FF8800\"]")
  #expect(
    try JSONDecoder().decode([AgentProjectTint].self, from: encoded).map(\.rawValue)
      == ["teal", "#FF8800"])
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(AgentProjectTint.self, from: Data("\"nope\"".utf8))
  }
}

@Test("Projects are named after their directory until renamed")
func projectNaming() {
  let project = AgentProject(workingDirectory: "/opt/demo/pocketmai/")
  #expect(project.workingDirectory == "/opt/demo/pocketmai")
  #expect(project.displayName == "pocketmai")
  #expect(!project.hasCustomName)
  var renamed = project
  renamed.rename(to: "  Pocket  ")
  #expect(renamed.displayName == "Pocket")
  #expect(AgentProject(workingDirectory: "/").displayName == "/")
  #expect(AgentProject().displayName == AgentProject.placeholderName)
  #expect(AgentProject.standardizedPath("/opt/./demo/../demo") == "/opt/demo")
}

@Test("Project indexes dedupe by id and directory and list recent first")
func projectIndexOrdering() throws {
  let base = Date(timeIntervalSince1970: 2_000_000)
  let a = AgentProject(name: "A", workingDirectory: "/opt/a", createdAt: base, lastOpenedAt: base)
  let b = AgentProject(
    name: "B", workingDirectory: "/opt/b", createdAt: base, lastOpenedAt: base + 50)
  var index = AgentProjectIndex(projects: [a, b])
  #expect(index.orderedProjects.map(\.name) == ["B", "A"])

  var moved = a
  moved.workingDirectory = "/opt/b"
  moved.markOpened(at: base + 100)
  index.upsert(moved)
  #expect(index.projects.count == 1, "the entry that claimed /opt/b is replaced")
  #expect(index.project(atWorkingDirectory: "/opt/b/")?.id == a.id)
  #expect(index.project(atWorkingDirectory: "/opt/a") == nil)

  let url = scratchDirectory("index").appendingPathComponent("projects.json")
  try index.save(to: url)
  #expect(try AgentProjectIndex.load(from: url) == index)
  #expect(index.remove(id: a.id) == moved)
  #expect(index.projects.isEmpty)
}

@Test("Homes open projects in place and keep the index outside them")
func homeOpensProjects() throws {
  let root = scratchDirectory("home")
  let home = AgentHome(rootURL: root.appendingPathComponent(".pmai", isDirectory: true))
  let workdir = root.appendingPathComponent("work/repo", isDirectory: true)
  try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)

  let opened = try home.openProject(atWorkingDirectory: workdir, at: Date(timeIntervalSince1970: 5))
  #expect(opened.displayName == "repo")
  #expect(opened.workingDirectory == AgentProject.standardizedPath(workdir.path))
  #expect(home.storageDirectory(for: opened).path == workdir.appendingPathComponent(".pmai").path)
  #expect(FileManager.default.fileExists(atPath: home.projectFileURL(for: opened).path))
  #expect(try home.loadProjectIndex().projects.map(\.id) == [opened.id])

  var renamed = opened
  renamed.rename(to: "Repo")
  renamed.tint = AgentProjectTint(rawValue: "mint")
  try home.saveProject(renamed)
  let reopened = try home.openProject(atWorkingDirectory: workdir, at: Date(timeIntervalSince1970: 9))
  #expect(reopened.id == opened.id)
  #expect(reopened.name == "Repo")
  #expect(reopened.tint?.rawValue == "mint")
  #expect(reopened.lastOpenedAt == Date(timeIntervalSince1970: 9))
  #expect(try home.loadProjectIndex().projects.first?.name == "Repo")

  let store = home.chatStore(for: reopened)
  #expect(store.directoryURL.path == workdir.appendingPathComponent(".pmai/chats").path)
  var workspace = try store.loadWorkspace()
  var chat = workspace.startNewChat(primaryAgent: storeAgent)
  chat.messages.append(.user("hi"))
  workspace.upsert(chat)
  try store.commit(&workspace)
  #expect(try home.chatStore(for: reopened).loadSummaries().map(\.id) == [chat.id])

  #expect(try home.forgetProject(id: opened.id)?.id == opened.id)
  #expect(try home.loadProjectIndex().projects.isEmpty)
  #expect(try home.loadProject(atWorkingDirectory: workdir)?.id == opened.id, "the project file survives")
  #expect(try home.forgetProject(id: UUID()) == nil)
}

@Test("Homes fall back to their own directory for read-only working directories")
func homeFallbackStorage() throws {
  let root = scratchDirectory("home-ro")
  let home = AgentHome(rootURL: root.appendingPathComponent(".pmai", isDirectory: true))
  let workdir = root.appendingPathComponent("readonly", isDirectory: true)
  try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workdir.path)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workdir.path)
  }
  guard !FileManager.default.isWritableFile(atPath: workdir.path) else { return }

  let opened = try home.openProject(atWorkingDirectory: workdir)
  let expected = home.projectsDirectoryURL.appendingPathComponent(opened.id.uuidString)
  #expect(home.storageDirectory(for: opened).path == expected.path)
  #expect(FileManager.default.fileExists(atPath: home.projectFileURL(for: opened).path))
  #expect(try home.loadProject(atWorkingDirectory: workdir)?.id == opened.id)
  #expect(try home.openProject(atWorkingDirectory: workdir).id == opened.id)
}

@Test("Home resolution honors PMAI_HOME")
func homeResolution() {
  let fallback = URL(fileURLWithPath: "/Users/example", isDirectory: true)
  #expect(
    AgentHome.resolve(environment: [:], homeDirectory: fallback).rootURL.path
      == "/Users/example/.pmai")
  #expect(
    AgentHome.resolve(environment: ["PMAI_HOME": "/var/state/pmai"], homeDirectory: fallback)
      .rootURL.path == "/var/state/pmai")
  #expect(
    AgentHome.resolve(environment: ["PMAI_HOME": "  "], homeDirectory: fallback).rootURL.path
      == "/Users/example/.pmai")
  #expect(
    AgentHome.resolve(
      environment: ["HOME": "/data/data/com.termux/files/home"], homeDirectory: fallback
    )
    .rootURL.path == "/data/data/com.termux/files/home/.pmai")
  #expect(
    AgentHome.resolve(
      environment: [
        "HOME": "/data/data/com.termux/files/home",
        "PMAI_HOME": "~/.local/state/pmai",
      ],
      homeDirectory: fallback
    ).rootURL.path == "/data/data/com.termux/files/home/.local/state/pmai")
}

@Test("User paths expand against the shell HOME")
func userPathResolution() {
  let fallback = URL(fileURLWithPath: "/Users/example", isDirectory: true)
  let environment = ["HOME": "/data/data/com.termux/files/home"]
  #expect(
    AgentHome.userHomeDirectory(environment: environment, fallback: fallback).path
      == "/data/data/com.termux/files/home")
  #expect(
    AgentHome.expandUserPath("~", environment: environment, fallback: fallback)
      == "/data/data/com.termux/files/home")
  #expect(
    AgentHome.expandUserPath(
      "~/.config/pmai/config.json", environment: environment, fallback: fallback)
      == "/data/data/com.termux/files/home/.config/pmai/config.json")
  #expect(
    AgentHome.expandUserPath("relative/file", environment: environment, fallback: fallback)
      == "relative/file")
}
