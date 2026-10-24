import Foundation
import MaiCore
import MaiStandardTools
import Testing

private func trackedRun(
  _ command: String, history: AgentCommandHistory, timeout: Double = 60
) async throws -> ToolOutput {
  let context = ToolExecutionContext(
    run: .init(
      runID: UUID(), parentRunID: nil, agentID: "worker", depth: 2, pid: 7), modelTurn: 1)
  let scope = AgentCommandScope(
    history: history, sessionID: "chat", run: context.run, callID: "call", tool: "run_shell")
  return try await AgentCommandScope.$current.withValue(scope) {
    try await MaiRunTool(configuration: .init()).call(
      arguments: .object([
        "command": .string(command), "timeout_seconds": .number(timeout),
      ]), context: context)
  }
}

@Test("Run process history captures actual PID, command, agent, timing, and exit")
func runProcessHistoryExit() async throws {
  let history = AgentCommandHistory()
  let output = try await trackedRun("printf tracked; exit 3", history: history)
  let record = try #require(history.records(sessionID: "chat").first)
  let pid = try #require(record.pid)
  #expect(pid > 0)
  #expect(output.structuredContent?.objectValue?["pid"] == .integer(Int(pid)))
  #expect(record.command == "printf tracked; exit 3")
  #expect(record.run.agentID == "worker")
  #expect(record.run.pid == 7)
  #expect(record.run.depth == 2)
  #expect(record.callID == "call")
  #expect(record.state == .exited)
  #expect(record.exitCode == 3)
  #expect(record.endedAt != nil)
  #expect(record.duration() >= 0)
  #expect(!history.kill(pid: pid, sessionID: "chat"))
}

@Test("A tracked live command can be killed only from its owning chat")
func runProcessHistoryKill() async throws {
  let history = AgentCommandHistory()
  let task = Task { try await trackedRun("sleep 30 & wait", history: history) }
  defer { task.cancel() }
  let deadline = ContinuousClock.now + .seconds(5)
  while history.records(sessionID: "chat").isEmpty, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  let record = try #require(history.records(sessionID: "chat").first)
  let pid = try #require(record.pid)
  #expect(record.state == .running)
  #expect(!history.kill(pid: pid, sessionID: "another-chat"))
  #expect(history.kill(pid: pid, sessionID: "chat"))
  let output = try await task.value
  #expect(output.isError)
  let finished = try #require(history.records(sessionID: "chat").first)
  #expect(finished.state == .killed)
  #expect(finished.endedAt != nil)
  #expect(finished.duration() < 10)
  #expect(!history.kill(pid: pid, sessionID: "chat"))
}

@Test("Timeouts are retained as command history")
func runProcessHistoryTimeout() async throws {
  let history = AgentCommandHistory()
  _ = try await trackedRun("sleep 30", history: history, timeout: 1)
  let record = try #require(history.records(sessionID: "chat").first)
  #expect(record.state == .timedOut)
  #expect(record.exitCode != 0)
  #expect(record.duration() >= 0.9)
}

@Test("Cancellation retains the command even though the tool throws")
func runProcessHistoryCancellation() async throws {
  let history = AgentCommandHistory()
  let task = Task { try await trackedRun("sleep 30", history: history) }
  defer { task.cancel() }
  let deadline = ContinuousClock.now + .seconds(5)
  while history.records(sessionID: "chat").isEmpty, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(!history.records(sessionID: "chat").isEmpty)
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(history.records(sessionID: "chat").first?.state == .cancelled)
}
