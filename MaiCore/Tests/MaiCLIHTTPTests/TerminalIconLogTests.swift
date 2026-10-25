import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("Icon rows keep call order, update live, wrap whole emojis and retain full results")
func terminalIconRows() {
  for grouped in [false, true] {
    var buffer = TerminalOutputBuffer()
    buffer.configureToolGroups(grouped)
    buffer.configureTools(.icons)
    buffer.append("prompt\n")
    let read = buffer.appendTool(
      call: .init(id: "read", name: "files_read", arguments: .object([:])), result: nil)
    #expect(buffer.visibleRows(width: 80, height: 40) == ["prompt", "📖", ""])
    let patch = buffer.appendTool(
      call: .init(id: "patch", name: "files_patch", arguments: .object([:])), result: nil)
    buffer.appendTool(
      call: nil, result: .init(callID: "patch", text: "patch failed", isError: true), to: patch)
    buffer.appendTool(call: nil, result: .init(callID: "read", text: "full result"), to: read)
    buffer.appendReply("answer")
    #expect(buffer.visibleRows(width: 80, height: 40) == ["prompt", "📖🩹", "answer", ""])
    let toggled = buffer.toggleToolGroup(row: 1)
    #expect(!toggled)
    #expect(buffer.visibleRows(width: 2, height: 40).contains("🩹"))
    var filtered = TerminalOutputBuffer()
    filtered.updateView(from: buffer, selection: .tools("files_patch"))
    #expect(filtered.visibleRows(width: 80, height: 40) == ["🩹"])
    buffer.configureTools(.all)
    buffer.configureToolGroups(false)
    let expanded = buffer.visibleRows(width: 80, height: 40).joined(separator: "\n")
    #expect(expanded.contains("full result") && expanded.contains("patch failed"))
  }
}

@Test("Iconlog includes each call once across replies and ignores results and preview limits")
func terminalIconLog() {
  var buffer = TerminalOutputBuffer()
  let read = buffer.appendTool(
    call: .init(id: "read", name: "files_read", arguments: .object([:])), result: nil)
  buffer.appendReply("answer")
  buffer.appendTool(
    call: .init(id: "shell", name: "run_shell", arguments: .object([:])), result: nil)
  var view = TerminalOutputBuffer()
  for display in [ToolResultDisplay.all, .lines(0), .icons] {
    buffer.configureTools(display)
    view.updateView(from: buffer, selection: .iconlog)
    #expect(view.visibleRows(width: 80, height: 40) == ["📖💻"])
  }
  buffer.appendTool(call: nil, result: .init(callID: "read", text: "result"), to: read)
  view.updateView(from: buffer, selection: .iconlog)
  #expect(view.visibleRows(width: 2, height: 40) == ["📖", "💻"])
  buffer.configureExcluding(.iconlog)
  #expect(!buffer.visibleRows(width: 80, height: 40).joined().contains("📖"))
  buffer.configureExcluding(nil)
  buffer.configureTools(.all)
  #expect(buffer.visibleRows(width: 80, height: 40).joined().contains("result"))
  view.updateView(from: TerminalOutputBuffer(), selection: .iconlog)
  #expect(!view.visibleRows(width: 80, height: 40).joined().contains("📖"))
}

@Test("Classic icon output prints one glyph per call and closes its row before other output")
func terminalWriterIcons() async {
  let writer = TerminalWriter(capturesOutput: true)
  await writer.configureTools(.icons)
  let context = AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0)
  for (id, name) in [("read", "files_read"), ("patch", "files_patch")] {
    await writer.consume(.toolStarted(context, .init(id: id, name: name, arguments: .object([:]))))
    await writer.consume(.toolFinished(context, .init(callID: id, text: "hidden result")))
  }
  await writer.line("answer")
  #expect(await writer.drainCaptured() == "📖🩹\nanswer\n")
  await writer.consume(
    .toolStarted(context, .init(id: "read2", name: "files_read", arguments: .object([:]))))
  await writer.configureTools(.all)
  await writer.consume(.toolFinished(context, .init(callID: "read2", text: "hidden after switch")))
  await writer.line("done")
  #expect(await writer.drainCaptured() == "📖\ndone\n")
}
