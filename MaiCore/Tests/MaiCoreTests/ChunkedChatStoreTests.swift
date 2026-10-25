import Foundation
import Testing

@testable import MaiCore

private func chunkTestStore() throws -> AgentChatStore {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return AgentChatStore(directoryURL: directory)
}

private func chunkTestChat(count: Int) -> AgentChat {
  AgentChat(
    title: "Large chat", primaryAgent: AgentDefinition(id: "test", provider: "test", model: "test"),
    messages: (0..<count).map { .user("message \($0)") },
    createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 2000))
}

@Test("Chunked history opens at the tail and pages in either direction")
func chunkedHistoryPages() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  let chat = chunkTestChat(count: 129)
  try store.save(chat)
  let last = try #require(try store.loadChatPage(id: chat.id))
  #expect(last.historyWindow?.range == 65..<129)
  #expect(last.historyWindow?.totalCount == 129)
  #expect(last.messages == Array(chat.messages.suffix(64)))
  let previous = try #require(try store.loadChatPage(id: chat.id, before: 65))
  #expect(previous.historyWindow?.range == 1..<65)
  #expect(previous.messages == Array(chat.messages[1..<65]))
  let first = try #require(try store.loadChatPage(id: chat.id, before: 32))
  #expect(first.historyWindow?.hasEarlier == false)
  #expect(first.historyWindow?.hasLater == true)
  #expect(try store.loadChatPage(id: chat.id, limit: 0)?.messages.isEmpty == true)
  #expect(try store.loadSummaries().first?.messageCount == 129)
  #expect(try store.loadChat(id: chat.id) == chat)
}

@Test("Appending and editing reuse unaffected chunks without changing a captured snapshot")
func chunkedHistoryWrites() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  var chat = chunkTestChat(count: 130)
  try store.save(chat)
  let original = try #require(try ChatChunkManifest.read(at: store.fileURL(for: chat.id)))
  let captured = chat
  chat.messages.append(.assistant("new reply"))
  try store.save(captured)
  try store.save(chat)
  let appended = try #require(try ChatChunkManifest.read(at: store.fileURL(for: chat.id)))
  #expect(appended.chunks.count == 3)
  #expect(appended.chunks.prefix(2) == original.chunks.prefix(2))
  #expect(appended.chunks.last?.count == 3)
  #expect(try store.loadChat(id: chat.id)?.messages == chat.messages)
  chat.messages[70] = .user("edited")
  try store.save(chat)
  let edited = try #require(try ChatChunkManifest.read(at: store.fileURL(for: chat.id)))
  #expect(edited.chunks.first == appended.chunks.first)
  #expect(edited.chunks[1] != appended.chunks[1])
  #expect(try store.loadChat(id: chat.id)?.messages == chat.messages)
  let bytes = try Data(contentsOf: store.fileURL(for: chat.id))
  try store.save(chat)
  #expect(try Data(contentsOf: store.fileURL(for: chat.id)) == bytes)
}

@Test("Legacy migration scans escaped strings and children without changing portable JSON")
func chunkedLegacyRoundTrip() async throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  var chat = chunkTestChat(count: 65)
  // Cross the 64 KiB reader/inline boundary once, including escaped UTF-8.
  chat.messages[0] = .user(String(repeating: "😀 { [ \\\" quote\n", count: 4_096))
  let supervisor = AgentSupervisor()
  let parent = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "parent", task: "test", depth: 0)
  let child = await supervisor.register(
    runID: UUID(), parent: parent, agentID: "child", task: "test", depth: 1)
  let childMessages: [AgentMessage] = [.user("child input"), .assistant("child answer")]
  await supervisor.note(child, transcript: childMessages)
  await supervisor.complete(child)
  chat.subagents = await supervisor.records(under: parent)
  let raw = try MaiJSONCoding.default.makeEncoder().encode(chat)
  chat = try MaiJSONCoding.default.makeDecoder().decode(AgentChat.self, from: raw)
  try raw.write(to: store.fileURL(for: chat.id))
  let page = try #require(try store.loadChatPage(id: chat.id))
  #expect(page.messages == Array(chat.messages.suffix(64)))
  #expect(page.subagents.count == 1)
  #expect(page.subagents[0].messages.isEmpty)
  #expect(try page.subagents[0].historyReference?.loadMessages() == childMessages)
  #expect(try Data(contentsOf: store.fileURL(for: chat.id).appendingPathExtension("legacy")) == raw)
  let destination = store.directoryURL.appendingPathComponent("export.json")
  try store.exportChat(id: chat.id, to: destination)
  let exported = try MaiJSONCoding.default.makeDecoder().decode(
    AgentChat.self, from: Data(contentsOf: destination))
  #expect(Bool(exported == chat))
  var context = try #require(try store.loadChatHistory(id: chat.id))
  #expect(context.messages == chat.messages)
  #expect(context.subagents[0].messages.isEmpty)
  // The same directory can carry a different URL directory hint after a reload.
  let reference = try #require(context.subagents[0].historyReference)
  context.subagents[0].historyReference = try StoredAgentTranscript(
    directory: URL(fileURLWithPath: reference.directory.path, isDirectory: true),
    snapshot: reference.snapshot)
  let migrated = try #require(try ChatChunkManifest.read(at: store.fileURL(for: chat.id)))
  try store.save(context)
  let saved = try #require(try ChatChunkManifest.read(at: store.fileURL(for: chat.id)))
  #expect(saved.children[0].sameContents(as: migrated.children[0]))
  #expect(try store.loadChat(id: chat.id)?.subagents == chat.subagents)
}

@Test("A projection cannot overwrite or export the complete history")
func chunkedProjectionSafety() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  let chat = chunkTestChat(count: 65)
  try store.save(chat)
  var page = try #require(try store.loadChatPage(id: chat.id))
  page.messages.removeAll()
  #expect(throws: ChatHistoryError.self) { try store.save(page) }
  #expect(throws: ChatHistoryError.self) { try MaiJSONCoding.default.makeEncoder().encode(page) }
  #expect(try store.loadChat(id: chat.id) == chat)
}

@Test("Large values live outside bounded chunks and round-trip exactly")
func chunkedLargeValues() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  var chat = chunkTestChat(count: 65)
  // One byte above the inline limit is enough to exercise blob storage.
  chat.messages[64] = .assistant(String(repeating: "x", count: 64 * 1024 + 1))
  try store.save(chat)
  let manifest = try #require(try ChatChunkManifest.read(at: store.fileURL(for: chat.id)))
  let directory = try manifest.directory(relativeTo: store.fileURL(for: chat.id))
  for chunk in manifest.chunks {
    #expect(
      try Data(contentsOf: directory.appendingPathComponent(chunk.filename)).count < 256 * 1024)
  }
  #expect(manifest.chunks.flatMap { $0.blobs ?? [] }.count == 1)
  #expect(try store.loadChat(id: chat.id) == chat)
  let page = try #require(try store.loadChatPage(id: chat.id))
  #expect(page.messages.count == 64)
  #expect(page.messages == Array(chat.messages[page.historyWindow!.range]))
}

@Test("Missing cloud chunks preserve the manifest and previous committed data")
func chunkedIncompleteSnapshot() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  let chat = chunkTestChat(count: 65)
  try store.save(chat)
  let url = store.fileURL(for: chat.id)
  let bytes = try Data(contentsOf: url)
  let manifest = try #require(try ChatChunkManifest.read(at: url))
  let directory = try manifest.directory(relativeTo: url)
  try FileManager.default.removeItem(
    at: directory.appendingPathComponent(manifest.chunks.last!.filename))
  #expect(throws: (any Error).self) { try store.loadChat(id: chat.id) }
  #expect(throws: (any Error).self) { try store.loadChatPage(id: chat.id) }
  #expect(try Data(contentsOf: url) == bytes)
  #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test("Tool JSON can use reserved-looking keys without becoming a file reference")
func chunkedReservedKeys() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  var chat = chunkTestChat(count: 65)
  chat.messages[64].providerState = [
    "state": .object([
      "_pmaiBlob": .string("12345678-1234-1234-1234-123456789012.blob"),
      "_pmaiObject": .object(["nested": .string("literal")]),
    ])
  ]
  try store.save(chat)
  #expect(try store.loadChat(id: chat.id)?.messages == chat.messages)
}

@Test("Completed child snapshots survive chunk cleanup and lazy supervisor restoration")
func chunkedPinnedChildSnapshots() async throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  let supervisor = AgentSupervisor()
  let root = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "root", task: "test", depth: 0)
  let pid = await supervisor.register(
    runID: UUID(), parent: root, agentID: "child", task: "test", depth: 1)
  let messages: [AgentMessage] = [.user("old child"), .assistant("old answer")]
  await supervisor.note(pid, transcript: messages)
  await supervisor.complete(pid)
  var chat = chunkTestChat(count: 65)
  chat.subagents = await supervisor.records(under: root)
  try store.save(chat)
  let pinned = try #require(try store.loadChatPage(id: chat.id))
  for index in 0..<3 {
    chat.subagents[0].messages = [.user("new child \(index)")]
    try store.save(chat)
  }
  #expect(try pinned.subagents[0].historyReference?.loadMessages() == messages)
  let restored = AgentSupervisor()
  let parent = await restored.register(
    runID: UUID(), parent: nil, agentID: "root", task: "restore", depth: 0)
  let children = await restored.restore(pinned.subagents, under: parent)
  #expect(children.count == 1)
  #expect(try await restored.loadTranscript(children[0]) == messages)
}

@Test("Opening the tail does not require downloading older chunks")
func chunkedTailNeedsOnlyItsOwnFiles() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  let chat = chunkTestChat(count: 129)
  try store.save(chat)
  let url = store.fileURL(for: chat.id)
  let manifest = try #require(try ChatChunkManifest.read(at: url))
  let directory = try manifest.directory(relativeTo: url)
  try FileManager.default.removeItem(
    at: directory.appendingPathComponent(manifest.chunks[0].filename))
  let page = try #require(try store.loadChatPage(id: chat.id))
  #expect(page.messages == Array(chat.messages.suffix(64)))
  #expect(throws: (any Error).self) { try store.loadChatHistory(id: chat.id) }
}

@Test("Malformed chunk counts fail without indexing beyond the decoded array")
func chunkedMalformedCounts() throws {
  let store = try chunkTestStore()
  defer { try? FileManager.default.removeItem(at: store.directoryURL) }
  let chat = chunkTestChat(count: 128)
  try store.save(chat)
  let url = store.fileURL(for: chat.id)
  let manifest = try #require(try ChatChunkManifest.read(at: url))
  let directory = try manifest.directory(relativeTo: url)
  try Data("[]".utf8).write(to: directory.appendingPathComponent(manifest.chunks[1].filename))
  #expect(throws: (any Error).self) { try store.loadChatPage(id: chat.id, limit: 1) }
}

@Test("Page budgets select chunk boundaries without allocating large payloads")
func chunkedPageBudgetBoundaries() {
  var manifest = ChatChunkManifest(metadata: Data())
  manifest.chunks = [
    .init(filename: "older.json", count: 64, bytes: 32),
    .init(filename: "large.json", count: 64, bytes: 1024 * 1024),
    .init(filename: "tail.json", count: 1, bytes: 1),
  ]
  #expect(manifest.pageRange(before: nil, limit: 64) == 128..<129)
  // A single oversized message must remain reachable, rather than produce an empty page.
  manifest.chunks[1] = .init(filename: "large.json", count: 1, bytes: 1024 * 1024 + 1)
  #expect(manifest.pageRange(before: 65, limit: 64) == 64..<65)
}
