import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("PS rows show OS PID, agent identity, elapsed time, exit and escaped full commands")
func psCommandRows() throws {
  let history = AgentCommandHistory()
  let scope = AgentCommandScope(
    history: history, sessionID: "chat",
    run: .init(
      runID: UUID(), parentRunID: nil, agentID: "worker", depth: 1, pid: 7),
    callID: "call", tool: "run_shell")
  let id = scope.started(
    pid: 123, command: "printf a\nprintf b\t\u{1b}[31m", arguments: ["a b"], cwd: "/tmp",
    stop: { true })
  let started = try #require(history.records(sessionID: "chat").first?.startedAt)
  history.finished(id, exitCode: 3, state: .exited, at: started + 2.5)
  let rows = MaiCLI.psLines(history.records(sessionID: "chat"), at: started + 100)
  #expect(rows.count == 2)
  #expect(rows[1].hasPrefix("123\tworker\t#7\texited\t3\t2.500s\t"))
  #expect(rows[1].contains("printf a\\nprintf b\\t[31m"))
  #expect(rows[1].contains(#"args=["a b"]"#))
  #expect(!rows[1].contains("\u{1b}"))
  let agent = AgentDefinition(id: "main", provider: "hello", model: "test")
  let chat = AgentChat(primaryAgent: agent, commands: history.records(sessionID: "chat"))
  #expect(REPLSession(chat: chat).chat.commands == chat.commands)
  let interrupted = AgentCommandHistory()
  let running = scope.started(
    pid: 124, command: "sleep 30", arguments: [], cwd: "/tmp", stop: { true })
  interrupted.restore(history.records(sessionID: "chat"))
  let record = try #require(interrupted.records(sessionID: "chat").first { $0.id == running })
  #expect(MaiCLI.psLines([record])[1].contains("interrupted\t—\tunknown"))
}

@Test("PS command routing lists live commands, rejects invalid kills, and uses owned handles")
func psCommandRouting() async throws {
  let runtime = AgentRuntime()
  let chat = AgentChat(primaryAgent: .init(id: "main", provider: "hello", model: "test"))
  let session = REPLSession(chat: chat)
  let terminal = TerminalWriter(capturesOutput: true)
  let scope = AgentCommandScope(
    history: runtime.commandHistory, sessionID: session.sessionID,
    run: .init(runID: UUID(), parentRunID: nil, agentID: "worker", depth: 1, pid: 3),
    callID: "run", tool: "run_shell")
  let id = scope.started(pid: 123, command: "sleep 30", arguments: [], cwd: "/tmp", stop: { true })
  await MaiCLI.handlePSCommand("", session: session, runtime: runtime, terminal: terminal)
  #expect(await terminal.drainCaptured().contains("No matching commands"))
  await MaiCLI.handlePSCommand("-a", session: session, runtime: runtime, terminal: terminal)
  #expect(await terminal.drainCaptured().contains("123\tworker\t—\trunning"))
  let root = await runtime.allocateProcess(agentID: "main")
  let worker = await runtime.supervisor.register(
    runID: scope.run.runID, parent: root, agentID: "worker", displayName: "worker", task: "test", depth: 1)
  await MaiCLI.handlePSCommand(
    "-a", session: session, runtime: runtime, chatProcess: root, terminal: terminal)
  #expect(await terminal.drainCaptured().contains("123\tworker\t\(worker)\trunning"))
  await MaiCLI.handlePSCommand("-k -1", session: session, runtime: runtime, terminal: terminal)
  #expect(await terminal.drainCaptured().contains(AgentPSOptions.usage))
  await MaiCLI.handlePSCommand("-k 123", session: session, runtime: runtime, terminal: terminal)
  #expect(await terminal.drainCaptured().contains("Killed process 123 and its process group"))
  runtime.commandHistory.finished(id, exitCode: 9, state: .killed)
  await MaiCLI.handlePSCommand("-ap", session: session, runtime: runtime, terminal: terminal)
  #expect(await terminal.drainCaptured().contains("123\tworker\t—\tkilled\t9"))
  await MaiCLI.handlePSCommand("-k 123", session: session, runtime: runtime, terminal: terminal)
  #expect(await terminal.drainCaptured().contains("No live process 123 owned by this chat"))
}
