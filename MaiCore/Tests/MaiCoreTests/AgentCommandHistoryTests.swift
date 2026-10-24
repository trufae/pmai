import Foundation
import Testing

@testable import MaiCore

private func commandScope(_ history: AgentCommandHistory, depth: Int = 0) -> AgentCommandScope {
  AgentCommandScope(
    history: history, sessionID: "chat",
    run: .init(
      runID: UUID(), parentRunID: nil, agentID: depth == 0 ? "main" : "worker",
      depth: depth, pid: AgentPID(depth + 1)), callID: UUID().uuidString, tool: "run_shell")
}

@Test("ps filters running, past, and nested agent commands and validates all flags")
func psOptions() throws {
  let history = AgentCommandHistory()
  let main = commandScope(history).started(
    pid: 100, command: "main", arguments: [], cwd: "/", stop: { true })
  let child = commandScope(history, depth: 2).started(
    pid: 101, command: "child", arguments: [], cwd: "/", stop: { true })
  #expect(
    history.records(sessionID: "chat").filter(try AgentPSOptions("").includes).map(\.id) == [main])
  #expect(history.records(sessionID: "chat").filter(try AgentPSOptions("-a").includes).count == 2)
  history.finished(child, exitCode: 3, state: .exited)
  #expect(history.records(sessionID: "chat").filter(try AgentPSOptions("-p").includes).isEmpty)
  #expect(
    history.records(sessionID: "chat").filter(try AgentPSOptions("-ap").includes).map(\.id) == [
      child
    ])
  #expect(try AgentPSOptions("-a -p") == AgentPSOptions("-pa"))
  #expect(try AgentPSOptions("-k 100").killPID == 100)
  for argument in [
    "-k", "-k 0", "-k -1", "-k +1", "-k 2147483648", "-k 1 extra", "-z", "100", "-a -k 100",
  ] {
    #expect(throws: (any Error).self) { try AgentPSOptions(argument) }
  }
  #expect(try PmaiCommandPolicy(readOnly: true).evaluate("/ps -ap") == "/ps -ap")
  #expect(throws: PmaiCommandError.notReadOnly("ps")) {
    try PmaiCommandPolicy(readOnly: true).evaluate("/ps -k 100")
  }
}

@Test("Command history survives chat coding and restore never revives a saved PID")
func commandHistoryPersistence() throws {
  let history = AgentCommandHistory()
  let scope = commandScope(history)
  let done = scope.started(
    pid: 123, command: "printf ok", arguments: ["a b"], cwd: "/tmp", stop: { true })
  history.finished(done, exitCode: 0, state: .exited)
  _ = scope.started(pid: 124, command: "sleep 30", arguments: [], cwd: "/tmp", stop: { true })
  let chat = AgentChat(
    primaryAgent: .init(id: "main", provider: "hello", model: "test"),
    commands: history.records(sessionID: "chat"))
  let data = try JSONEncoder().encode(chat)
  let decoded = try JSONDecoder().decode(AgentChat.self, from: data)
  #expect(decoded.commands == chat.commands)
  let restored = AgentCommandHistory()
  restored.restore(decoded.commands)
  restored.restore(decoded.commands)
  let records = restored.records(sessionID: "chat")
  #expect(records.count == 2)
  #expect(records.first { $0.id == done }?.state == .exited)
  #expect(records.first { $0.pid == 124 }?.state == .interrupted)
  #expect(!restored.kill(pid: 123, sessionID: "chat"))
  #expect(!restored.kill(pid: 124, sessionID: "chat"))
  #expect(!history.kill(pid: 124, sessionID: "another-chat"))
  // Rotating the provider session keeps the chat's older command history.
  #expect(restored.records(sessionID: "new-session", saved: records) == records)
  #expect(history.kill(pid: 124, sessionID: "new-session", saved: chat.commands))
  let fork = chat.forked()
  history.restore(fork.commands)
  #expect(fork.commands.allSatisfy { $0.sessionID == fork.sessionID })
  #expect(Set(fork.commands.map(\.id)).isDisjoint(with: Set(chat.commands.map(\.id))))
  #expect(fork.commands.first { $0.pid == 124 }?.state == .interrupted)
  #expect(!history.kill(pid: 124, sessionID: fork.sessionID, saved: fork.commands))
  #expect(history.records(sessionID: "chat").count == 2)
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "commands")
  let legacy = try JSONSerialization.data(withJSONObject: object)
  #expect(try JSONDecoder().decode(AgentChat.self, from: legacy).commands.isEmpty)
}

@Test("Old chats recover native and proxied run history without inventing PIDs or times")
func commandHistoryLegacy() throws {
  let result = ToolResult(
    callID: "native", content: [.text("ok")],
    structuredContent: .object([
      "exitCode": .integer(0), "durationMs": .integer(1250), "cwd": .string("/tmp"),
    ]))
  let proxyResult = ToolResult(
    callID: "proxy", content: [.text("failed")],
    structuredContent: .object([
      "exitCode": .integer(9), "durationMs": .integer(1000), "timedOut": .bool(true),
    ]), isError: true)
  var chat = AgentChat(
    primaryAgent: .init(id: "main", provider: "hello", model: "test"),
    messages: [
      .init(
        role: .assistant,
        content: [
          .toolCall(
            .init(
              id: "native", name: "run_shell",
              arguments: .object([
                "command": .string("printf ok")
              ])))
        ]),
      .init(role: .tool, content: [.toolResult(result)]),
      .init(
        role: .assistant,
        content: [
          .toolCall(
            .init(
              id: "proxy", name: "call-tool",
              arguments: .object([
                "name": .string("run_shell"),
                "arguments": .object(["args": .array([.string("sleep"), .string("30")])]),
              ])))
        ]),
      .init(role: .tool, content: [.toolResult(proxyResult)]),
      .init(
        role: .assistant,
        content: [
          .toolCall(
            .init(
              id: "denied", name: "run_shell",
              arguments: .object([
                "script": .string("do not execute")
              ])))
        ]),
      .init(
        role: .tool, content: [.toolResult(.init(callID: "denied", text: "denied", isError: true))]),
    ])
  let childRun = UUID()
  chat.subagents = [
    .init(
      process: .init(
        pid: 4, parent: 3, runID: childRun, agentID: "nested", state: .completed, depth: 2),
      messages: chat.messages)
  ]
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
  object.removeValue(forKey: "commands")
  let recovered = try JSONDecoder().decode(
    AgentChat.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(recovered.commands.count == 4)
  #expect(recovered.commands[0].command == "printf ok")
  #expect(recovered.commands[0].duration() == 1.25)
  #expect(recovered.commands[0].pid == nil)
  #expect(recovered.commands[0].startedAt == nil)
  #expect(recovered.commands[0].cwd == "/tmp")
  #expect(recovered.commands[1].command == "sleep")
  #expect(recovered.commands[1].arguments == ["30"])
  #expect(recovered.commands[1].state == .timedOut)
  #expect(recovered.commands[1].duration() == 1)
  #expect(recovered.commands[1].exitCode == 9)
  #expect(recovered.commands[2].run.agentID == "nested")
  #expect(recovered.commands[2].run.depth == 2)
  #expect(recovered.commands[2].run.runID == childRun)
  #expect(try AgentPSOptions("-p").includes(recovered.commands[2]) == false)
  #expect(try AgentPSOptions("-ap").includes(recovered.commands[2]))
  let data = try JSONEncoder().encode(recovered)
  #expect(try JSONDecoder().decode(AgentChat.self, from: data).commands == recovered.commands)
  let reusedID = [1, 2].flatMap { exit in
    [
      AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            .init(
              id: "reused", name: "run_shell",
              arguments: .object(["command": .string("exit \(exit)")])))
        ]),
      AgentMessage(
        role: .tool,
        content: [
          .toolResult(
            .init(
              callID: "reused", content: [],
              structuredContent: .object(["exitCode": .integer(exit)])))
        ]),
    ]
  }
  let repeated = AgentCommandRecord.recovering(
    messages: reusedID, sessionID: "chat",
    run: .init(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0))
  #expect(repeated.map(\.exitCode) == [1, 2])
}
