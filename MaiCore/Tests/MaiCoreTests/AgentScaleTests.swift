import Foundation
import Testing

@testable import MaiCore

@Test("A slow supervisor subscriber retains every lifecycle event")
func supervisorLifecycleBurst() async {
  let supervisor = AgentSupervisor(finishedRetention: 100)
  let stream = await supervisor.events()
  for _ in 0..<80 {
    let pid = await supervisor.register(runID: UUID(), parent: nil, agentID: "worker", depth: 0)
    await supervisor.complete(pid)
  }
  var iterator = stream.makeAsyncIterator()
  var started = Set<AgentPID>()
  var finished = Set<AgentPID>()
  for _ in 0..<160 {
    switch await iterator.next() {
    case .started(let info): started.insert(info.pid)
    case .finished(let info): finished.insert(info.pid)
    default: Issue.record("Unexpected lifecycle event")
    }
  }
  #expect(started.count == 80)
  #expect(finished == started)
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
