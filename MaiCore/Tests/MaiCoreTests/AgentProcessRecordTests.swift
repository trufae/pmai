import Foundation
import Testing

@testable import MaiCore

// What a chat keeps of the agents its runs started, and how a reopened chat
// gets them back: records taken from the supervisor, saved with the chat,
// restored under fresh pids, read through the same tools and commands as
// live processes, and purged along with the finished ones.

private let recordAgent = AgentDefinition(
  id: "local",
  instructions: "Be concise.",
  provider: "endpoint",
  model: "model-a")

/// Chat files keep millisecond precision, so round-trip checks use aligned dates.
private let recordEpoch = Date(timeIntervalSince1970: 1_700_000_000.5)

private func scratchDirectory(_ name: String) -> URL {
  FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("maicore-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func finished(_ text: String, agentID: String) -> AgentResult {
  AgentResult(
    runID: UUID(),
    agentID: agentID,
    provider: "endpoint",
    response: .assistant(text),
    transcript: [.user("brief"), .assistant(text)],
    usage: nil,
    stopReason: .stop,
    modelTurns: 1,
    toolCalls: 0)
}

private func record(
  pid: AgentPID,
  parent: AgentPID?,
  runID: UUID = UUID(),
  parentRunID: UUID? = nil,
  agentID: String,
  task: String,
  state: AgentProcessState,
  depth: Int,
  messages: [AgentMessage]
) -> AgentProcessRecord {
  AgentProcessRecord(
    process: AgentProcessInfo(
      pid: pid,
      parent: parent,
      runID: runID,
      agentID: agentID,
      task: task,
      state: state,
      depth: depth,
      startedAt: recordEpoch,
      updatedAt: recordEpoch + 1,
      finishedAt: state.isTerminal ? recordEpoch + 1 : nil,
      modelTurns: 2,
      toolCalls: 1),
    messages: messages,
    parentRunID: parentRunID)
}

@Test("A supervisor's subtree becomes records, parents before children, that merge by run id")
func recordsFromSupervisor() async throws {
  let supervisor = AgentSupervisor()
  let chat = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "chat", depth: 0)
  let child = await supervisor.register(
    runID: UUID(), parent: chat, agentID: "researcher", task: "find it", depth: 1)
  let grandchild = await supervisor.register(
    runID: UUID(), parent: child, agentID: "researcher.worker", task: "read it", depth: 2)
  await supervisor.note(
    child, state: .running, modelTurns: 2, toolCalls: 3,
    transcript: [.user("find it"), .assistant("found")])
  await supervisor.note(grandchild, state: .running, transcript: [.user("read it")])
  await supervisor.finish(
    grandchild, result: finished("read", agentID: "researcher.worker"), announce: false)
  let childInfo = try #require(await supervisor.info(child))

  let records = await supervisor.records(under: chat)
  #expect(records.map(\.agentID) == ["researcher", "researcher.worker"])
  #expect(records[0].parentRunID == nil, "a direct child hangs off the chat itself")
  #expect(records[1].parentRunID == childInfo.runID)
  #expect(records[0].state == .running)
  #expect(records[0].toolCalls == 3)
  #expect(records[0].messages.last?.text == "found")
  #expect(records[1].state == .completed)
  #expect(records[1].messages.last?.text == "read")
  #expect(await supervisor.records(under: child).map(\.agentID) == ["researcher.worker"])

  // A saved copy of a process the table still holds is replaced, a new one
  // is appended, and one the table has forgotten is kept as it was.
  var stale = records[0]
  stale.state = .starting
  stale.messages = []
  let forgotten = record(
    pid: 9, parent: chat, agentID: "old", task: "earlier", state: .completed, depth: 1,
    messages: [.assistant("old answer")])
  let merged = AgentProcessRecord.merging(saved: [stale, forgotten], current: records)
  #expect(merged.map(\.agentID) == ["researcher", "old", "researcher.worker"])
  #expect(merged[0].state == .running)
  #expect(merged[0].messages.last?.text == "found")
  #expect(merged[1].messages.last?.text == "old answer")
  #expect(AgentProcessRecord.merging(saved: [], current: records) == records)
  #expect(AgentProcessRecord.merging(saved: records, current: []) == records)
  #expect(AgentProcessRecord.merging(saved: records + records, current: []) == records)
}

@Test("Saved records restore under a chat with fresh pids, and the tools read them like live ones")
func restoreRecordsUnderChat() async throws {
  // As an earlier session left them: the worker had finished, its parent was
  // still running when the session ended.
  let parentRunID = UUID()
  let parent = record(
    pid: 7, parent: 1, runID: parentRunID, agentID: "researcher", task: "find the parser",
    state: .running, depth: 1, messages: [.user("find the parser"), .assistant("looking")])
  let worker = record(
    pid: 8, parent: 7, parentRunID: parentRunID, agentID: "researcher.worker",
    task: "read Parser.swift", state: .completed, depth: 2,
    messages: [.user("read Parser.swift"), .assistant("Parser.swift holds the parser.")])

  let supervisor = AgentSupervisor()
  let chat = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "chat", depth: 0)
  #expect(await supervisor.restore([parent, worker], under: AgentPID(99)).isEmpty)
  let pids = await supervisor.restore([parent, worker], under: chat)
  #expect(pids.count == 2)
  #expect(!pids.contains(7) && !pids.contains(8), "pids belong to this session")
  let tree = await supervisor.tree()
  let restoredParent = try #require(tree.info(pids[0]))
  let restoredWorker = try #require(tree.info(pids[1]))
  #expect(restoredParent.parent == chat)
  #expect(restoredWorker.parent == pids[0])
  #expect(restoredParent.depth == 1 && restoredWorker.depth == 2)
  #expect(restoredParent.task == "find the parser")
  #expect(restoredWorker.task == "read Parser.swift")
  #expect(tree.lines().contains { $0.contains("read Parser.swift") })
  #expect(restoredParent.runID == parentRunID)
  // A process that was running when it was saved is not running now.
  #expect(restoredParent.state == .cancelled)
  #expect(restoredParent.failure == AgentSupervisor.restoredWhileRunning)
  #expect(restoredParent.finishedAt != nil)
  #expect(restoredWorker.state == .completed)
  #expect(restoredWorker.failure == nil)
  #expect(restoredWorker.isCollected)
  #expect(await supervisor.liveProcesses().allSatisfy { $0.pid == chat })
  #expect(await supervisor.transcript(pids[1]).last?.text == "Parser.swift holds the parser.")
  #expect(tree.lines(from: chat).count == 3)

  // agent_status lists them under the chat and reads a transcript back.
  let status = await AgentProcessTools.status(
    arguments: ["tree": .bool(true)], callID: "s", caller: chat, supervisor: supervisor)
  #expect(status.structuredContent?.objectValue?["count"] == .integer(2))
  #expect(status.text.contains("find the parser"))
  let log = await AgentProcessTools.status(
    arguments: ["pid": .string(String(pids[1].rawValue)), "log": .bool(true)],
    callID: "l", caller: chat, supervisor: supervisor)
  #expect(log.text.contains("Parser.swift holds the parser."))
  // agent_result explains a restored process instead of waiting for it.
  let result = await AgentProcessTools.result(
    arguments: ["pid": .string(String(pids[1].rawValue))],
    callID: "r", caller: chat, supervisor: supervisor)
  #expect(result.isError)
  #expect(result.text.contains("earlier session"))
  #expect(result.text.contains("Parser.swift holds the parser."))
  let cancelled = await AgentProcessTools.result(
    arguments: ["pid": .string(String(pids[0].rawValue))],
    callID: "r2", caller: chat, supervisor: supervisor)
  #expect(cancelled.isError)
  #expect(cancelled.text.contains(AgentSupervisor.restoredWhileRunning))

  // Records taken again carry this session's pids and the same run ids, so a
  // save after a resume stays consistent with what was restored.
  let again = await supervisor.records(under: chat)
  #expect(again.map(\.runID) == [parent.runID, worker.runID])
  #expect(again.map(\.pid) == pids)
  #expect(again[1].parentRunID == parentRunID)
  #expect(again[0].state == .cancelled)

  // Clearing under the chat forgets them and keeps the chat's own process.
  let cleared = await supervisor.clearFinished(under: chat)
  #expect(Set(cleared) == Set(pids))
  #expect(await supervisor.info(chat) != nil)
  #expect(await supervisor.records(under: chat).isEmpty)
}

@Test("A chat file keeps its agents' records, and one written before them still loads")
func chatFileKeepsSubagents() throws {
  let store = AgentChatStore(directoryURL: scratchDirectory("subagents"))
  var chat = AgentChat(
    primaryAgent: recordAgent,
    messages: [.user("find the parser"), .assistant("found it")],
    createdAt: recordEpoch,
    updatedAt: recordEpoch)
  chat.refreshTitle(from: "find the parser")
  let saved = record(
    pid: 2, parent: 1, agentID: "researcher", task: "find the parser", state: .completed,
    depth: 1, messages: [.user("find the parser"), .assistant("Parser.swift")])
  chat.subagents = [saved]
  #expect(try store.save(chat))
  let reloaded = try #require(try store.loadChat(id: chat.id))
  #expect(reloaded.subagents == [saved])
  #expect(reloaded == chat)
  // The listing skips transcripts, the records' included.
  let summary = try #require(try store.loadSummaries().first)
  #expect(summary.messageCount == 2)
  // Clearing the conversation clears what its runs started.
  var cleared = reloaded
  cleared.resetTranscript()
  #expect(cleared.subagents.isEmpty)

  // A file from before records existed decodes with none.
  let data = try MaiJSONCoding.default.makeEncoder().encode(chat)
  var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  object["subagents"] = nil
  let older = try MaiJSONCoding.default.makeDecoder().decode(
    AgentChat.self, from: try JSONSerialization.data(withJSONObject: object))
  #expect(older.subagents.isEmpty)
  #expect(older.messages == chat.messages)

  // A record written without a run id, as the first debug exports were, is
  // given one and hangs off the chat.
  var legacy = try #require(
    try JSONSerialization.jsonObject(
      with: try MaiJSONCoding.default.makeEncoder().encode(saved)) as? [String: Any])
  legacy["runID"] = nil
  legacy["parentRunID"] = nil
  legacy["updatedAt"] = nil
  let decoded = try MaiJSONCoding.default.makeDecoder().decode(
    AgentProcessRecord.self, from: try JSONSerialization.data(withJSONObject: legacy))
  #expect(decoded.agentID == "researcher")
  #expect(decoded.parentRunID == nil)
  #expect(decoded.updatedAt == decoded.finishedAt)
  #expect(decoded.messages == saved.messages)
}

@Test("Restoring unordered or duplicate records preserves the tree and is idempotent")
func restoreUnorderedRecords() async throws {
  let parentID = UUID()
  let parent = record(
    pid: 7, parent: 1, runID: parentID, agentID: "parent", task: "work",
    state: .completed, depth: 1, messages: [.assistant("parent result")])
  let child = record(
    pid: 8, parent: 7, parentRunID: parentID, agentID: "child", task: "nested work",
    state: .paused, depth: 2, messages: [.user("child task")])
  let supervisor = AgentSupervisor()
  let chat = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "chat", depth: 0)
  let pids = await supervisor.restore([child, parent, child], under: chat)
  #expect(pids.count == 3)
  #expect(pids[0] == pids[2])
  #expect(await supervisor.info(pids[0])?.parent == pids[1])
  #expect(await supervisor.info(pids[0])?.depth == 2)
  #expect(await supervisor.info(pids[0])?.state == .cancelled)
  #expect(await supervisor.restore([child, parent], under: chat) == Array(pids.prefix(2)))
  #expect(await supervisor.records(under: chat).count == 2)

  var cyclicParent = parent
  cyclicParent.parentRunID = child.runID
  let other = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "other chat", depth: 0)
  let recovered = await supervisor.restore([cyclicParent, child], under: other)
  #expect(recovered.count == 2)
  #expect(await supervisor.tree().subtree(of: other).count == 3)
}
