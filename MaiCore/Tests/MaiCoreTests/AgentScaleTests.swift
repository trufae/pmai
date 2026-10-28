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
