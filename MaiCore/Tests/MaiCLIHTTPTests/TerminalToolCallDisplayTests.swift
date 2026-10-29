import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("Tool call settings reflow retained previews in compact and result modes")
func terminalToolCallDisplayBuffer() {
  let first = "echo " + String(repeating: "abcdefghij", count: 30)
  let call = ToolCall(id: "shell", name: "run_shell", arguments: .object([
    "script": .string(first + "\nsecond\nthird\nEOF"),
  ]))
  var buffer = TerminalOutputBuffer()
  let block = buffer.appendTool(call: call, result: nil)
  buffer.appendTool(call: nil, result: .init(callID: call.id, text: "result"), to: block)
  buffer.append("answer")
  var filtered = TerminalOutputBuffer()
  for results in [ToolResultDisplay.lines(0), .all] {
    buffer.configureTools(results)
    for calls in [ToolCallDisplay.lines(1), .lines(3), .truncate, .lines(4)] {
      buffer.configureToolCalls(calls)
      for width in [40, 80] {
        let rows = buffer.visibleRows(width: width, height: 100)
        let text = rows.joined(separator: "\n")
        if calls == .truncate {
          #expect(!rows.joined().contains(first))
        } else {
          #expect(rows.joined().contains(first))
          #expect(text.contains("second") == (calls != .lines(1)))
          #expect(text.contains("EOF") == (calls == .lines(4)))
        }
        #expect(text.contains("result") == (results == .all))
        #expect(rows.last == "answer")
      }
      filtered.updateView(from: buffer, selection: .tools(nil))
      #expect(filtered.visibleRows(width: 80, height: 100).joined().contains(first)
        == (calls != .truncate))
    }
  }
}

@Test("Classic tool call previews honor complete source lines with and without results")
func terminalToolCallDisplayClassic() async {
  let first = "echo " + String(repeating: "abcdefghij", count: 30)
  let call = ToolCall(id: "shell", name: "run_shell", arguments: .object([
    "script": .string(first + "\nsecond\nthird"),
  ]))
  for results in [ToolResultDisplay.lines(0), .all] {
    let writer = TerminalWriter(capturesOutput: true)
    await writer.configureColors(.init(tools: results, toolCalls: .lines(2)))
    await writer.configureTools(results)
    let context = AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0)
    await writer.consume(.toolStarted(context, call))
    await writer.consume(.toolFinished(context, .init(callID: call.id, text: "output")))
    let text = await writer.drainCaptured()
    #expect(text.contains(first))
    #expect(text.contains("\n  second\" (+1 lines)"))
    #expect(!text.contains("third"))
    #expect(text.contains("output") == (results == .all))
  }
}
