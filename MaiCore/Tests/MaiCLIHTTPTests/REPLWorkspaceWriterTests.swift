import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("Queued progress checkpoints cannot overwrite a later foreground save")
func replWorkspaceWriteOrdering() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = AgentChatStore(directoryURL: directory)
  let writer = REPLWorkspaceWriter()
  var chat = AgentChat(title: "first", primaryAgent: .init(id: "main", provider: "hello", model: "test"))
  var workspace = AgentChatWorkspace(chats: [chat])
  let first = await writer.enqueue(workspace, store: store)
  chat.title = "latest"
  workspace.upsert(chat)
  let latest = await writer.enqueue(workspace, store: store)
  _ = try await first.value
  let committed = try await latest.value
  #expect(!committed.hasUncommittedChanges)
  #expect(try store.loadWorkspace().selectedChat?.title == "latest")
}
