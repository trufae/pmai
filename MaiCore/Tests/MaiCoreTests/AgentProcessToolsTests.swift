import Foundation
import Testing

@testable import MaiCore

// The agent_* family as a host without AgentRuntime uses it: definitions,
// argument parsing, and a child run on a bare supervisor with a body the host
// supplies. Everything here is what PocketMai relies on.

private actor AdmissionRecorder {
  var announcements: [Bool] = []

  func record(_ admitted: Bool) {
    announcements.append(admitted)
  }
}

private actor DynamicLimit {
  var value: Int

  init(_ value: Int) {
    self.value = value
  }

  func set(_ value: Int) {
    self.value = value
  }
}

private func childResult(_ text: String, agentID: String = "worker") -> AgentResult {
  AgentResult(
    runID: UUID(),
    agentID: agentID,
    provider: "fixture",
    response: .assistant(text),
    transcript: [.user("brief"), .assistant(text)],
    usage: nil,
    stopReason: .stop,
    modelTurns: 1,
    toolCalls: 0)
}

@Test("The agent tools are the same four names AgentRuntime offers, and only those")
func processToolNames() {
  #expect(AgentProcessTools.toolNames == AgentRuntime.agentToolNames)
  #expect(AgentRuntime.agentStartToolName == AgentProcessTools.startToolName)
  #expect(AgentProcessTools.isAgentTool("spawn_agent"))
  #expect(AgentProcessTools.canonicalName("agent_launch") == AgentProcessTools.startToolName)
  #expect(AgentProcessTools.canonicalName("agent_status") == AgentProcessTools.statusToolName)
  #expect(!AgentProcessTools.isAgentTool("web_search"))
}

@Test("Definitions name the offered agents and say when a worker may be used instead")
func processToolDefinitions() throws {
  let named = AgentProcessTools.definitions(
    offering: [
      AgentProcessTools.OfferedAgent(id: "researcher", purpose: "finds things"),
      AgentProcessTools.OfferedAgent(id: "coder"),
    ],
    delegating: false)
  #expect(named.map(\.name) == [
    AgentProcessTools.startToolName, AgentProcessTools.statusToolName,
    AgentProcessTools.resultToolName, AgentProcessTools.stopToolName,
  ])
  let start = try #require(named.first)
  let agent = try #require(start.inputSchema.objectValue?["properties"]?.objectValue?["agent"])
  #expect(agent.objectValue?["enum"] == .array([.string("coder"), .string("researcher")]))
  let description = agent.objectValue?["description"]?.stringValue ?? ""
  #expect(description.contains("researcher — finds things"))
  #expect(!description.contains("general worker"))
  #expect(start.description.contains("Agents: coder, researcher"))
  #expect(start.parameters.filter(\.required).map(\.name) == ["output", "task"])

  let delegating = AgentProcessTools.definitions(offering: [], delegating: true)
  let worker = try #require(delegating.first)
  #expect(worker.inputSchema.objectValue?["properties"]?.objectValue?["agent"] == nil)
  #expect(worker.description.contains("with your tools"))
}

@Test("agent_start arguments parse the brief, the agent, and the wait flag")
func startArguments() throws {
  #expect(AgentProcessTools.StartArguments(arguments: [:]) == nil)
  #expect(AgentProcessTools.StartArguments(arguments: ["task": .string("  ")]) == nil)

  let full = try #require(
    AgentProcessTools.StartArguments(arguments: [
      "context": .string("Paths found."),
      "task": .string("Read it"),
      "output": .string("One line"),
      "agent": .string(" researcher "),
      "tools": .array([.string("read"), .string("missing")]),
      "wait": .bool(false),
    ]))
  #expect(full.brief == AgentTaskBrief(context: "Paths found.", task: "Read it", output: "One line"))
  #expect(full.agent == "researcher")
  #expect(full.wait == false)
  #expect(full.narrowed(["read", "write"]) == ["read"])
  // A request naming none of the tools keeps them all rather than none.
  #expect(full.narrowed(["write"]) == ["write"])

  let legacy = try #require(
    AgentProcessTools.StartArguments(
      arguments: ["prompt": .string("Find it")],
      toolName: AgentProcessTools.legacyLaunchToolName))
  #expect(legacy.brief.task == "Find it")
  #expect(legacy.agent == nil)
  #expect(legacy.wait == false)
  let spawn = try #require(
    AgentProcessTools.StartArguments(
      arguments: ["task": .string("Find it")],
      toolName: AgentProcessTools.legacySpawnToolName))
  #expect(spawn.wait == true)
}

@Test("A host runs a child on a bare supervisor and reads it back through status and result")
func hostRunsChild() async throws {
  let supervisor = AgentSupervisor()
  let parent = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "chat", depth: 0)

  let launched = await AgentProcessTools.launch(
    supervisor: supervisor,
    parent: parent,
    agentID: "worker",
    displayName: "main worker",
    task: "Read it",
    depth: 1,
    limit: 2,
    background: true
  ) { pid in
    await supervisor.note(pid, state: .running, modelTurns: 1, activity: "thinking")
    try await Task.sleep(for: .milliseconds(50))
    return childResult("Done reading")
  }
  #expect(!launched.queued)
  let started = AgentProcessTools.startedResult(
    callID: "c1", pid: launched.pid, agentID: "worker", queued: false, slots: 2)
  #expect(started.text.hasPrefix("Started worker as \(launched.pid)."))
  #expect(started.structuredContent?.objectValue?["status"] == .string("running"))

  // The child is listed under its parent, and only under its parent.
  let listed = await AgentProcessTools.status(
    arguments: [:], callID: "c2", caller: parent, supervisor: supervisor)
  #expect(listed.structuredContent?.objectValue?["count"] == .integer(1))
  #expect(listed.text.contains("worker"))
  let stranger = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "other", task: "", depth: 0)
  let notYours = await AgentProcessTools.result(
    arguments: ["pid": .string(String(launched.pid.rawValue))],
    callID: "c3", caller: stranger, supervisor: supervisor)
  #expect(notYours.isError)
  #expect(notYours.text.contains("not one of yours"))

  let collected = await AgentProcessTools.result(
    arguments: ["pid": .string(String(launched.pid.rawValue))],
    callID: "c4", caller: parent, supervisor: supervisor)
  #expect(!collected.isError)
  #expect(collected.text == "Done reading")
  #expect(collected.structuredContent?.objectValue?["status"] == .string("completed"))
  let info = try #require(await supervisor.info(launched.pid))
  #expect(info.state == .completed)
  #expect(info.isCollected)

  for count: JSONValue in [.bool(true), .integer(Int.max), .number(1e100)] {
    let log = await AgentProcessTools.status(
      arguments: ["pid": .string("#\(launched.pid.rawValue)"), "log": count],
      callID: "c5", caller: parent, supervisor: supervisor)
    #expect(log.text.contains("[2] assistant: Done reading"))
  }
}

@Test("A child past the limit waits for a slot, and agent_stop ends a waiting child")
func queuedChildAndStop() async throws {
  let supervisor = AgentSupervisor()
  let parent = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "chat", depth: 0)
  let recorder = AdmissionRecorder()

  let first = await AgentProcessTools.launch(
    supervisor: supervisor, parent: parent, agentID: "worker", task: "one",
    depth: 1, limit: 1, background: true
  ) { _ in
    // Holds its slot until it is stopped; the sleep throws on cancellation.
    try await Task.sleep(for: .seconds(30))
    return childResult("first")
  }
  let second = await AgentProcessTools.launch(
    supervisor: supervisor, parent: parent, agentID: "worker", task: "two",
    depth: 1, limit: 1, background: true,
    announce: { _, admitted in await recorder.record(admitted) }
  ) { _ in
    childResult("second")
  }
  #expect(!first.queued)
  #expect(second.queued)
  #expect(await recorder.announcements == [false])
  #expect(await supervisor.info(second.pid)?.state == .queued)
  let queuedText = AgentProcessTools.startedResult(
    callID: "c1", pid: second.pid, agentID: "worker", queued: true, slots: 1)
  #expect(queuedText.text.hasPrefix("Queued worker as \(second.pid): all 1 subagent slot is busy"))

  // Stopping the running child frees its slot; the queued one starts by itself.
  let stopped = await AgentProcessTools.stop(
    arguments: ["pid": .string(String(first.pid.rawValue)), "reason": .string("done")],
    callID: "c2", caller: parent, supervisor: supervisor, stoppedBy: "main")
  #expect(stopped.text == "Stopped \(first.pid).")
  #expect(await supervisor.info(first.pid)?.state == .cancelled)
  #expect(await supervisor.info(first.pid)?.failure == "done")
  let result = try await second.task.value
  #expect(result.response.text == "second")
  #expect(await supervisor.info(second.pid)?.state == .completed)
  #expect(await recorder.announcements == [false, true])

  // A stopped child answers agent_result with its error, not a hang.
  let refused = await AgentProcessTools.result(
    arguments: ["pid": .string(String(first.pid.rawValue))],
    callID: "c3", caller: parent, supervisor: supervisor)
  #expect(refused.isError)
  #expect(refused.text.contains("is not available: done"))
}

@Test("Recursive instances have separate child slots and keep sibling queue order across turns")
func recursiveAgentSlots() async throws {
  let supervisor = AgentSupervisor()
  let root = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "worker", depth: 0)
  let child = await AgentProcessTools.register(
    supervisor: supervisor, parent: root, agentID: "worker", task: "child",
    depth: 1, limit: 1)
  let sibling = await AgentProcessTools.register(
    supervisor: supervisor, parent: root, agentID: "worker", task: "sibling",
    depth: 1, limit: 1)
  let grandchild = await AgentProcessTools.register(
    supervisor: supervisor, parent: child.pid, agentID: "worker", task: "grandchild",
    depth: 2, limit: 1)
  #expect(child.admitted && !sibling.admitted)
  #expect(grandchild.admitted)

  // An older queued uncle must not block a child's own queue either.
  let next = await AgentProcessTools.register(
    supervisor: supervisor, parent: child.pid, agentID: "worker", task: "next",
    depth: 2, limit: 1)
  let last = await AgentProcessTools.register(
    supervisor: supervisor, parent: child.pid, agentID: "worker", task: "last",
    depth: 2, limit: 1)
  #expect(!next.admitted && !last.admitted)
  await supervisor.stop(grandchild.pid)
  #expect(await supervisor.admit(last.pid, limit: 1) == false)
  #expect(await supervisor.admit(next.pid, limit: 1))

  #expect(await supervisor.reopen(root, runID: UUID(), task: "next turn"))
  #expect(await supervisor.admit(sibling.pid, limit: 1) == false)
  await supervisor.stop(child.pid)
  #expect(await supervisor.admit(sibling.pid, limit: 1))
}

@Test("A queued child starts as soon as its dynamic limit is raised")
func queuedChildStartsWhenDynamicLimitIsRaised() async throws {
  let supervisor = AgentSupervisor()
  let parent = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "chat", depth: 0)
  let first = await AgentProcessTools.register(
    supervisor: supervisor, parent: parent, agentID: "worker", task: "one",
    depth: 1, limit: 1)
  let second = await AgentProcessTools.register(
    supervisor: supervisor, parent: parent, agentID: "worker", task: "two",
    depth: 1, limit: 1)
  #expect(first.admitted)
  #expect(!second.admitted)

  let limit = DynamicLimit(1)
  let task = Task {
    try await AgentProcessTools.run(
      second.pid,
      supervisor: supervisor,
      dynamicLimit: { await limit.value },
      admitted: second.admitted,
      background: false
    ) {
      childResult("second")
    }
  }
  await supervisor.attach(task, to: second.pid)
  let watchdog = Task {
    try? await Task.sleep(for: .seconds(2))
    task.cancel()
  }

  try await Task.sleep(for: .milliseconds(150))
  #expect(await supervisor.info(second.pid)?.state == .queued)
  await limit.set(2)
  let result = try await task.value
  watchdog.cancel()

  #expect(result.response.text == "second")
  #expect(await supervisor.info(second.pid)?.state == .completed)
  await supervisor.stop(first.pid)
}

@Test("A host-driven process is completed between turns and reopened for the next")
func completeAndReopen() async throws {
  let supervisor = AgentSupervisor()
  let pid = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "first turn", depth: 0)
  await supervisor.note(pid, state: .running, modelTurns: 2, activity: "thinking")
  await supervisor.complete(pid)
  let idle = try #require(await supervisor.info(pid))
  #expect(idle.state == .completed)
  #expect(idle.finishedAt != nil)
  #expect(idle.activity.isEmpty)

  #expect(await supervisor.reopen(pid, runID: UUID(), task: "second turn"))
  let reopened = try #require(await supervisor.info(pid))
  #expect(reopened.state == .running)
  #expect(reopened.task == "second turn")
  #expect(reopened.finishedAt == nil)
  #expect(reopened.modelTurns == 0)
  // Completing twice is harmless, and a terminal process stays as it is.
  await supervisor.stop(pid)
  await supervisor.complete(pid)
  #expect(await supervisor.info(pid)?.state == .cancelled)
}
