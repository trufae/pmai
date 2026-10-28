import Foundation
import Testing

@testable import MaiCore

@Test("A slow supervisor subscriber retains every lifecycle event")
func supervisorLifecycleBurst() async {
  let supervisor = AgentSupervisor(finishedRetention: 1000)
  let stream = await supervisor.events()
  for _ in 0..<500 {
    let pid = await supervisor.register(runID: UUID(), parent: nil, agentID: "worker", depth: 0)
    await supervisor.complete(pid)
  }
  var iterator = stream.makeAsyncIterator()
  var started = Set<AgentPID>()
  var finished = Set<AgentPID>()
  for _ in 0..<1000 {
    switch await iterator.next() {
    case .started(let info): started.insert(info.pid)
    case .finished(let info): finished.insert(info.pid)
    default: Issue.record("Unexpected lifecycle event")
    }
  }
  #expect(started.count == 500)
  #expect(finished == started)
}

@Test("Process indexes follow mutations and bound malformed ancestry")
func processTreeIndexes() {
  let root = AgentProcessInfo(pid: 1, runID: UUID(), agentID: "main")
  var child = AgentProcessInfo(pid: 2, parent: 1, runID: UUID(), agentID: "worker", depth: 1)
  var tree = AgentProcessTree([child, root])
  #expect(tree.children(of: 1).map(\.pid) == [2])
  #expect(tree.info(runID: child.runID)?.pid == 2)
  child.parent = 2
  tree.processes[1] = child
  #expect(tree.children(of: 1).isEmpty)
  #expect(tree.subtree(of: 2).count == 1)
  #expect(!tree.isDescendant(2, of: 1))
}

@Test("Retention preserves unread and uncheckpointed jobs and their transcripts")
func supervisorRetentionProtectsJobs() async {
  let supervisor = AgentSupervisor(finishedRetention: 1)
  let root = await supervisor.register(runID: UUID(), parent: nil, agentID: "main", depth: 0)
  var children: [AgentPID] = []
  for index in 0..<40 {
    let pid = await supervisor.register(runID: UUID(), parent: root, agentID: "worker", depth: 1)
    await supervisor.note(pid, transcript: [.assistant("answer \(index)")])
    await supervisor.complete(pid)
    children.append(pid)
  }
  for (index, pid) in children.enumerated() {
    #expect(await supervisor.transcript(pid).last?.text == "answer \(index)")
    await supervisor.collect(pid)
  }
  await supervisor.prune()
  #expect(await supervisor.processes().count == 41)
  #expect(await supervisor.transcript(children[0]).last?.text == "answer 0")
  #expect(await supervisor.clearFinished() == children)
}

@Test("Pausing a queued child preserves its queue state without reserving a slot")
func supervisorPausedQueueSlots() async {
  let supervisor = AgentSupervisor()
  let root = await supervisor.register(runID: UUID(), parent: nil, agentID: "main", depth: 0)
  let first = await supervisor.register(runID: UUID(), parent: root, agentID: "worker", depth: 1)
  #expect(await supervisor.admit(first, limit: 1))
  let second = await supervisor.register(runID: UUID(), parent: root, agentID: "worker", depth: 1)
  #expect(!(await supervisor.admit(second, limit: 1)))
  await supervisor.pause(second)
  await supervisor.complete(first)
  #expect(!(await supervisor.admit(second, limit: 1)))
  #expect(await supervisor.info(second)?.state == .paused)
  let third = await supervisor.register(runID: UUID(), parent: root, agentID: "worker", depth: 1)
  #expect(await supervisor.admit(third, limit: 1))
  await supervisor.resume(second)
  #expect(await supervisor.info(second)?.state == .queued)
  #expect(!(await supervisor.admit(second, limit: 1)))
  await supervisor.complete(third)
  #expect(await supervisor.admit(second, limit: 1))
}

@Test("Change waiters do not lose early notifications and cancel without polling")
func agentChangeWaiters() async throws {
  let signal = AgentChangeSignal()
  let revision = signal.revision
  signal.notify()
  try await signal.wait(after: revision)
  let waiting = Task { try await signal.wait(after: signal.revision) }
  waiting.cancel()
  do { try await waiting.value; Issue.record("Cancelled waiter returned") }
  catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
  try await signal.wait(after: signal.revision, until: .now + .milliseconds(5))
}

@Test("A session concurrency limit applies across independent parents")
func supervisorSessionSlots() async {
  let supervisor = AgentSupervisor()
  await supervisor.configureConcurrencyLimit(1)
  let first = await supervisor.register(runID: UUID(), parent: nil, agentID: "main", depth: 0)
  let second = await supervisor.register(runID: UUID(), parent: nil, agentID: "main", depth: 0)
  let a = await supervisor.register(runID: UUID(), parent: first, agentID: "worker", depth: 1)
  #expect(await supervisor.admit(a, limit: 3))
  let b = await supervisor.register(runID: UUID(), parent: second, agentID: "worker", depth: 1)
  #expect(!(await supervisor.admit(b, limit: 3)))
  await supervisor.complete(a)
  #expect(await supervisor.admit(b, limit: 3))
}

@Test("Metadata lookup leaves transcript bodies separate from status revisions")
func agentConversationMetadata() async throws {
  let runtime = AgentRuntime()
  let root = await runtime.allocateProcess(agentID: "main")
  let request = AgentRequest(agentID: "worker", provider: "fixture", model: "test",
    messages: [.user("private transcript")])
  let child = try #require(await runtime.forkConversation(request, parent: root, title: "worker"))
  #expect(await runtime.conversationSettings(for: child)?.messages.isEmpty == true)
  #expect(await runtime.conversationSettings(for: child)?.model == "test")
  let revision = await runtime.supervisor.info(child)?.transcriptRevision
  await runtime.supervisor.note(child, activity: "status update")
  #expect(await runtime.supervisor.info(child)?.transcriptRevision == revision)
  #expect(await runtime.conversationRequest(for: child)?.messages == request.messages)
  await runtime.supervisor.note(child, transcript: [.assistant("new content")])
  #expect(await runtime.supervisor.info(child)?.transcriptRevision != revision)
}

@Test("Catalog snapshots observe registry, membership and live policy changes")
func agentCatalogSnapshots() async throws {
  let runtime = AgentRuntime()
  func tool(_ text: String) -> ClosureTool {
    ClosureTool(definition: ToolDefinition(name: "alpha", description: text)) { _, _ in
      ToolOutput(text: text)
    }
  }
  try await runtime.register(tool: tool("first"))
  var request = AgentRequest(provider: "fixture", messages: [], toolNames: ["alpha"])
  #expect(try await runtime.visibleDefinitions(for: request).first?.description == "first")
  _ = await runtime.availableToolGroups()
  try await runtime.register(tool: tool("replacement"), replacingExisting: true)
  #expect(try await runtime.visibleDefinitions(for: request).first?.description == "replacement")
  request.toolPolicy.tools["alpha"] = .disabled
  #expect(try await runtime.visibleDefinitions(for: request).isEmpty)
  await runtime.configureToolGroups([ToolGroupDefinition(id: "custom", toolNames: ["alpha"])])
  #expect(await runtime.availableToolGroups().contains { $0.id == "custom" })
  await runtime.unregister(toolNamed: "alpha")
  #expect(await runtime.availableTools().isEmpty)
}

@Test("Live transcript pages are bounded and explicit removal is observable")
func agentTranscriptPagingAndRemoval() async throws {
  let supervisor = AgentSupervisor()
  let pid = await supervisor.register(runID: UUID(), parent: nil, agentID: "main", depth: 0)
  await supervisor.note(pid, transcript: (0..<200).map { .user("message \($0)") })
  let page = try await supervisor.transcriptPage(pid)
  #expect(page.messages.count == 64)
  #expect(page.window?.range == 136..<200)
  let earlier = try await supervisor.transcriptPage(pid, before: 136)
  #expect(earlier.window?.range == 72..<136)
  let events = await supervisor.events()
  await supervisor.forget(pid)
  var iterator = events.makeAsyncIterator()
  #expect(await iterator.next() == .removed(pid))
}

@Test("Archive survives restart and terminal processes reject stale steering")
func agentArchiveAndActions() async throws {
  let supervisor = AgentSupervisor()
  let root = await supervisor.register(runID: UUID(), parent: nil, agentID: "main", depth: 0)
  let child = await supervisor.register(runID: UUID(), parent: root, agentID: "worker", depth: 1)
  await supervisor.perform(.pause, on: child)
  let paused = try #require(await supervisor.info(child))
  #expect(AgentProcessAction.resume.isAvailable(for: paused))
  #expect(!AgentProcessAction.pause.isAvailable(for: paused))
  await supervisor.perform(.resume, on: child)
  await supervisor.complete(child)
  #expect(await supervisor.postIfRunning(.user("too late"), to: child) == nil)
  #expect(await supervisor.archiveFinished(under: root) == [child])
  let records = await supervisor.records(under: root)
  let data = try JSONEncoder().encode(records)
  let decoded = try JSONDecoder().decode([AgentProcessRecord].self, from: data)
  let restored = AgentSupervisor()
  let restoredRoot = await restored.register(runID: UUID(), parent: nil, agentID: "main", depth: 0)
  let pids = await restored.restore(decoded, under: restoredRoot)
  #expect(await restored.info(pids[0])?.isArchived == true)
  #expect(await supervisor.info(child) != nil)
}
