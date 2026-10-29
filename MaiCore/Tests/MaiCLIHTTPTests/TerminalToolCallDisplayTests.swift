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
    await writer.configureColors(.init(tools: results, toolCalls: .truncate))
    await writer.consume(.toolFinished(context, .init(callID: call.id, text: "output")))
    let text = await writer.drainCaptured()
    #expect(text.contains(first))
    #expect(text.contains("\n  second\" (+1 lines)"))
    #expect(!text.contains("third"))
    #expect(text.contains("output") == (results == .all))
  }
}

@Test("Late ACP arguments appear in retained and classic tool previews")
func terminalToolCallUpdates() async {
  let context = AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0)
  let initial = ToolCall(id: "remote", name: "Bash", arguments: .object([:]))
  let complete = ToolCall(id: initial.id, name: initial.name, arguments: .object([
    "command": .string("ls /workspace"),
  ]))
  for display in [ToolResultDisplay.all, .lines(0)] {
    var buffer = TerminalOutputBuffer()
    buffer.configureTools(display)
    let block = buffer.appendTool(call: initial, result: nil)
    buffer.appendTool(call: complete, result: nil, to: block)
    buffer.appendTool(call: nil, result: .init(callID: initial.id, text: "files"), to: block)
    let rows = buffer.visibleRows(width: 120, height: 20).joined(separator: "\n")
    #expect(rows.contains("ls /workspace"))

    let writer = TerminalWriter(capturesOutput: true)
    await writer.configureTools(display)
    await writer.consume(.toolStarted(context, initial))
    await writer.consume(.toolUpdated(context, complete))
    await writer.consume(.toolFinished(context, .init(callID: initial.id, text: "files")))
    #expect(await writer.drainCaptured().contains("ls /workspace"))
  }
}

@Test("Truncated tool calls use current columns and recover their source after resizing")
func terminalToolCallDisplayResize() {
  let script = "echo " + String(repeating: "abcdefghij", count: 30)
  let call = ToolCall(id: "shell", name: "run_shell", arguments: .object([
    "script": .string(script + "\nsecond"), "timeout_seconds": .number(30),
  ]))
  let full = "agent#2 → run_shell script=\"\(script)\" (+1 lines) timeout_seconds=30"
  for results in [ToolResultDisplay.lines(0), .all] {
    for completed in [false, true] {
      var buffer = TerminalOutputBuffer()
      buffer.configureTools(results)
      buffer.appendTool(call: call,
        result: completed ? .init(callID: call.id, text: "result") : nil, prefix: "agent#2 ")
      buffer.append("answer")
      var filtered = TerminalOutputBuffer()
      filtered.updateView(from: buffer, selection: .tools(nil))
      // Grow beyond both former limits, then shrink and grow again.
      for width in [40, 100, 200, 500, 80, 500] {
        let rows = buffer.visibleRows(width: width, height: 100)
        let toolRows = rows.filter { $0.hasPrefix("agent#2 ") }
        if results == .lines(0) && !completed {
          #expect(toolRows.isEmpty)
          continue
        }
        let heading = results == .lines(0)
          ? full.replacingOccurrences(of: "→", with: "✔") : full
        let expected = width < heading.count ? String(heading.prefix(width - 1)) + "…" : heading
        #expect(toolRows.first == expected)
        #expect(toolRows.count == (completed && results == .all ? 2 : 1))
        #expect(rows.last == "answer")
        #expect(filtered.visibleRows(width: width, height: 100).first == expected)
      }
    }
  }
}

@Test("Tool call clipping counts terminal cells, prefixes and styling")
func terminalToolCallDisplayCells() {
  let value = String(repeating: "界e\u{301}🐱", count: 70)
  let call = ToolCall(id: "wide", name: "files_read", arguments: .object(["path": .string(value)]))
  var buffer = TerminalOutputBuffer()
  buffer.configureTools(.all)
  buffer.configureColors(.init(toolCallBackground: "blue"))
  buffer.appendTool(call: call, result: nil, prefix: "agent#2 ")
  let fullWidth = TerminalLineEditor.displayWidth(of: "agent#2 → files_read " + value)
  for width in [1, 2, 18, 40, 80, 200, 500, 20] {
    let rows = buffer.visibleRows(width: width, height: 100).filter {
      !$0.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "",
        options: .regularExpression).trimmingCharacters(in: .whitespaces).isEmpty
    }
    #expect(rows.count == 1)
    let text = rows[0].replacingOccurrences(
      of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    #expect(TerminalLineEditor.displayWidth(of: text) == width)
    #expect(text.trimmingCharacters(in: .whitespaces).hasSuffix("…") == (width < fullWidth))
  }
}

@Test("Captured tool calls retain long arguments without a terminal column limit")
func terminalToolCallDisplayCapture() async {
  let script = "echo " + String(repeating: "abcdefghij", count: 30)
  let call = ToolCall(id: "shell", name: "run_shell", arguments: .object(["script": .string(script)]))
  for results in [ToolResultDisplay.lines(0), .all] {
    let writer = TerminalWriter(capturesOutput: true)
    await writer.configureTools(results)
    let context = AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0)
    await writer.consume(.toolStarted(context, call))
    await writer.consume(.toolFinished(context, .init(callID: call.id, text: "output")))
    #expect(await writer.drainCaptured().contains(script))
  }
}
