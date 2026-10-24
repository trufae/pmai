import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("80 agents share one UI wake-up and retain every completion")
func replSupervisorUpdateBurst() {
  let updates = REPLSupervisorUpdates()
  for pid in 1...80 {
    var info = AgentProcessInfo(pid: AgentPID(rawValue: pid), runID: UUID(), agentID: "worker", depth: 1)
    #expect(updates.insert(.started(info)) == (pid == 1))
    for _ in 0..<100 {
      #expect(!updates.insert(.changed(info)))
    }
    info.state = .cancelled
    #expect(!updates.insert(.finished(info)))
    // Collection and attention changes must not replace the completion.
    #expect(!updates.insert(.attention(info)))
    #expect(!updates.insert(.changed(info)))
  }
  let batch = updates.take()
  #expect(batch.finished.count == 80)
  #expect(batch.hasChildren && batch.needsAttention)
  #expect(batch.finished.values.allSatisfy { $0.state == .cancelled })
  #expect(updates.take().finished.isEmpty)
  let root = AgentProcessInfo(pid: 81, runID: UUID(), agentID: "main")
  #expect(updates.insert(.changed(root)))
  #expect(!updates.take().hasChildren)
}

@Test("Concurrent progress and drains cannot lose completion notices")
func replSupervisorConcurrentUpdates() async {
  let updates = REPLSupervisorUpdates()
  let drained = await withTaskGroup(of: [UUID: AgentProcessInfo].self) { group in
    for pid in 1...80 {
      group.addTask {
        let info = AgentProcessInfo(pid: AgentPID(rawValue: pid), runID: UUID(), agentID: "worker", depth: 1)
        _ = updates.insert(.started(info))
        for _ in 0..<100 { _ = updates.insert(.changed(info)) }
        _ = updates.insert(.finished(info))
        return updates.take().finished
      }
    }
    var finished: [UUID: AgentProcessInfo] = [:]
    for await batch in group { finished.merge(batch) { _, new in new } }
    finished.merge(updates.take().finished) { _, new in new }
    return finished
  }
  #expect(drained.count == 80)
}
