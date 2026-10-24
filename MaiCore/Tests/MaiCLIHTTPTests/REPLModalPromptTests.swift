import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("Pinned approvals keep the tool, arguments and answer help together")
func pinnedApprovalQuestion() throws {
  let request = ApprovalRequest(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "worker", depth: 1, pid: 42),
    tool: ToolDefinition(name: "files_write", description: "Write a file", inputSchema: .object([:])),
    call: ToolCall(id: "write", name: "files_write", arguments: .object(["path": .string("file.txt")]))
  let id = UUID()
  let modal = REPLModalPrompt.approval(request, id: id, editing: false)
  let question = try #require(modal.question)
  #expect(question.contains("Agent#42"))
  #expect(question.contains("files_write"))
  #expect(question.contains("file.txt"))
  #expect(question.contains("y (yes)"))
  let edit = try #require(REPLModalPrompt.approval(request, id: id, editing: true).question)
  #expect(edit.contains("file.txt"))
  #expect(edit.contains("JSON object"))
}

@Test("Other decisions supply pinned questions without replacing chat chop")
func pinnedDecisionQuestions() throws {
  let request = AutocompactionRequest(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0), estimatedTokens: 1000, threshold: 900)
  let question = try #require(REPLModalPrompt.compaction(request, id: UUID()).question)
  #expect(question.contains("1000 tokens (threshold 900)"))
  #expect(question.contains("y summarize"))
  #expect(REPLModalPrompt.queue.question?.contains("queued messages") == true)
  #expect(REPLModalPrompt.chop(id: "message").question == nil)
}

@Test("Pinned questions wrap wide text, remove controls and bound their height")
func pinnedQuestionLayout() {
  let text = "Approve?\n檔案🙂file.txt"
  let rows = REPLModalPrompt.questionRows(text, width: 8, height: 10)
  #expect(rows.first == "Approve?")
  #expect(rows.dropFirst().joined() == "檔案🙂file.txt")
  #expect(rows.allSatisfy { TerminalScreen.displayWidth($0) <= 8 })
  let safe = REPLModalPrompt.questionRows("Question\u{1B}[2J\ranswer", width: 80, height: 10).joined()
  #expect(!safe.contains("\u{1B}") && !safe.contains("\r"))
  #expect(safe.contains("Question") && safe.contains("answer"))
  let long = "Approve this tool?\n" + String(repeating: "arguments ", count: 100)
  let clipped = REPLModalPrompt.questionRows(long, width: 30, height: 3)
  #expect(clipped.count == 3)
  #expect(clipped.first == "Approve this tool?")
  #expect(clipped.last == "… full details in chat")
  #expect(REPLModalPrompt.questionRows(long, width: 30, height: 1).first?.hasPrefix("Approve") == true)
  #expect(REPLModalPrompt.questionRows(long, width: 1, height: 2).allSatisfy {
    TerminalScreen.displayWidth($0) <= 1
  })
  #expect(REPLModalPrompt.questionRows(long, width: 30, height: 0).isEmpty)
}
