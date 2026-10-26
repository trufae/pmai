import Foundation
import Testing
@testable import MaiCore
@testable import MaiTestSupport

@Test("Progress snapshots keep continuation settings without reading stored transcripts")
func conversationSnapshotSettings() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let runtime = AgentRuntime()
  let parent = await runtime.allocateProcess(agentID: "main")
  var request = AgentRequest(
    agentID: "worker", provider: "scripted", model: "saved-model",
    messages: [.user("Saved worker history")], toolNames: ["files_read"], useToolProxy: false)
  request.restrictedToolNames = ["files_read"]
  _ = try #require(await runtime.forkConversation(request, parent: parent, title: "Worker"))
  let chat = AgentChat(
    primaryAgent: .init(id: "main", provider: "scripted", model: "fixture"),
    messages: (0..<65).map { .user("Message \($0)") },
    subagents: await runtime.conversationRecords(under: parent))
  let store = AgentChatStore(directoryURL: directory)
  try store.save(chat)
  let page = try #require(try store.loadChatPage(id: chat.id, limit: 0))
  let reference = try #require(page.subagents.first?.historyReference)
  let restored = AgentRuntime()
  let restoredParent = await restored.allocateProcess(agentID: "main")
  let children = await restored.restoreConversations(page.subagents, under: restoredParent)
  let child = try #require(children.first)

  // Settings snapshots must not depend on transcript I/O succeeding. Actual
  // continuation still requires the body, and fails when its chunks disappear.
  try FileManager.default.removeItem(at: reference.directory)
  #expect(await restored.conversationRequest(for: child) == nil)
  let records = await restored.conversationRecords(under: restoredParent)
  let settings = try #require(records.first?.conversationRequest)
  #expect(settings.model == "saved-model")
  #expect(settings.restrictedToolNames == ["files_read"])
  #expect(settings.messages.isEmpty)
  #expect(records.first?.historyReference == reference)
}

@Test("Conversation forks keep lineage, independent transcripts and restricted settings across resume")
func conversationForksAndResume() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("First answer"), stopReason: .stop),
    ProviderResponse(message: .assistant("Follow-up answer"), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let parent = await runtime.allocateProcess(agentID: "main")
  await runtime.supervisor.complete(parent)
  var request = AgentRequest(
    agentID: "derived.worker", provider: "scripted", model: "fixture",
    messages: [.system("Shared instructions"), .user("Shared history")],
    toolNames: ["files_read"], toolGroupNames: [], useToolProxy: false)
  request.restrictedToolNames = ["files_read"]
  let child = try #require(await runtime.forkConversation(request, parent: parent, title: "First branch"))
  let sibling = try #require(await runtime.forkConversation(request, parent: parent, title: "Second branch"))
  let before = await runtime.conversationRecords(under: parent)
  request.messages.append(.user("Only first branch"))
  let result = try await runtime.run(request, process: child)
  #expect(await runtime.supervisor.info(child)?.parent == parent)
  #expect(await runtime.supervisor.info(child)?.depth == 1)
  #expect(await runtime.supervisor.transcript(sibling).map(\.text) == ["Shared instructions", "Shared history"])
  #expect(result.transcript.last?.text == "First answer")

  let records = AgentProcessRecord.merging(saved: before, current: await runtime.conversationRecords(under: parent))
  #expect(records.count == 2)
  #expect(records[0].id == before[0].id)
  #expect(records[0].runID != before[0].runID)
  let data = try JSONEncoder().encode(records)
  let saved = try JSONDecoder().decode([AgentProcessRecord].self, from: data)
  let resumed = AgentRuntime()
  try await resumed.register(provider)
  let resumedParent = await resumed.allocateProcess(agentID: "main")
  let restored = await resumed.restoreConversations(saved, under: resumedParent)
  let pid = try #require(restored.first)
  var continuation = try #require(await resumed.conversationRequest(for: pid))
  #expect(continuation.restrictedToolNames == ["files_read"])
  #expect(continuation.model == "fixture")
  #expect(continuation.messages.last?.text == "First answer")
  continuation.messages.append(.user("Continue restored branch"))
  _ = try await resumed.run(continuation, process: pid)
  #expect(await resumed.supervisor.info(pid)?.parent == resumedParent)
  #expect(await resumed.supervisor.info(pid)?.depth == 1)
  let updated = AgentProcessRecord.merging(saved: saved, current: await resumed.conversationRecords(under: resumedParent))
  #expect(updated.count == 2)
  #expect(updated[0].id == records[0].id)
  #expect(updated[0].messages.last?.text == "Follow-up answer")
  #expect(updated.allSatisfy { $0.conversationRequest?.messages.isEmpty == true })
}
