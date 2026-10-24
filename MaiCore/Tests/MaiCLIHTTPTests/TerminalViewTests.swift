import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("View selectors resolve agents and tools without changing the conversation")
func terminalViewSelectors() throws {
  let processes = [
    AgentProcessInfo(pid: 1, runID: UUID(), agentID: "main"),
    AgentProcessInfo(
      pid: 2, parent: 1, runID: UUID(), agentID: "worker", displayName: "Review code", depth: 1),
  ]
  func source(_ input: String) throws -> TerminalViewSource? {
    try MaiCLI.viewSource(
      input, processes: processes, tools: ["files_read"], mainConversation: "chat:test"
    ).source
  }
  #expect(try source("off") == nil)
  #expect(try source("current") == .current)
  #expect(try source("main") == .conversation("chat:test"))
  #expect(try source("1") == .conversation("chat:test"))
  for name in ["worker", "Review code", "agent Review code", "2", "#2", "agent#2"] {
    #expect(try source(name) == .conversation("agent:2"))
  }
  #expect(try source("thinking") == .thinking)
  #expect(try source("diffs") == .diffs)
  #expect(try source("agents") == .conversations)
  #expect(try source("tools") == .tools(nil))
  for name in ["files_read", "tool files_read", "tools files_read"] {
    #expect(try source(name) == .tools("files_read"))
  }
  for name in ["", "missing", "tools missing", "thinking extra", "off extra", "agent"] {
    #expect(throws: (any Error).self) { try source(name) }
  }
  let duplicate = AgentProcessInfo(pid: 3, parent: 1, runID: UUID(), agentID: "worker", depth: 1)
  #expect(throws: (any Error).self) {
    try MaiCLI.viewSource(
      "worker", processes: processes + [duplicate], tools: [], mainConversation: "chat:test")
  }
}

@Test("View projections reveal full hidden thinking and tools without changing their source")
func terminalViewProjections() {
  var source = TerminalOutputBuffer()
  source.configureThinking(.status)
  source.configureTools(.lines(0))
  source.append("prompt\n")
  let thinking = source.appendThinking("thought one\nthought two")
  let tool = source.appendTool(
    call: ToolCall(id: "read", name: "files_read", arguments: .object([:])), result: nil)
  source.appendReply("answer")
  let original = source.visibleRows(width: 80, height: 50)
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .thinking)
  #expect(view.visibleRows(width: 80, height: 50) == ["thought one", "thought two"])
  view.updateView(from: source, selection: .tools(nil))
  #expect(view.visibleRows(width: 80, height: 50) == ["→ files_read"])
  source.appendThinking(" streamed", to: thinking)
  source.appendTool(
    call: nil, result: ToolResult(callID: "read", text: "result one\nresult two"), to: tool)
  view.updateView(from: source, selection: .tools("files_read"))
  let rows = view.visibleRows(width: 80, height: 50).joined(separator: "\n")
  #expect(rows.contains("result two"))
  #expect(!rows.contains("answer") && !rows.contains("thought"))
  view.updateView(from: source, selection: .tools("missing"))
  #expect(view.visibleRows(width: 80, height: 50).isEmpty)
  view.scroll(lines: -10, width: 80, height: 5)
  view.updateView(from: source, selection: .thinking)
  #expect(view.visibleRows(width: 80, height: 50).last == "thought two streamed")
  let after = source.visibleRows(width: 80, height: 50).joined(separator: "\n")
  #expect(!after.contains("thought") && !after.contains("result"))
  #expect(original.contains("answer"))
}

@Test("Diff views include successful applied changes and exclude errors, reads and no-ops")
func terminalViewDiffs() {
  var source = TerminalOutputBuffer()
  let diff = "Updated file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new"
  for (changed, error, text) in [
    (true, false, diff), (true, true, diff), (false, false, diff), (true, false, "no diff"),
  ] {
    source.appendTool(
      call: ToolCall(id: "edit", name: "files_patch", arguments: .object([:])),
      result: ToolResult(
        callID: "edit", content: [.text(text)],
        structuredContent: .object(["changed": .bool(changed)]), isError: error))
  }
  source.appendTool(call: nil, result: ToolResult(callID: "read", text: diff))
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .diffs)
  let rows = view.visibleRows(width: 80, height: 100)
  #expect(rows.filter { $0 == "  +new" }.count == 1)
  #expect(!rows.joined().contains("no diff"))
}

@Test("View scrolling stays independent across live updates, reflow and clearing")
func terminalViewScroll() {
  var source = TerminalOutputBuffer()
  source.append((0..<40).map { "row \($0)" }.joined(separator: "\n"))
  var view = TerminalOutputBuffer()
  view.updateView(from: source, selection: .all)
  view.scroll(lines: -15, width: 20, height: 4)
  let anchor = view.visibleRows(width: 20, height: 4)
  source.append("\nnew row")
  view.updateView(from: source, selection: .all)
  #expect(view.visibleRows(width: 20, height: 4) == anchor)
  #expect(source.visibleRows(width: 20, height: 4).last == "new row")
  #expect(view.visibleRows(width: 4, height: 4).first == "row ")
  source.clear()
  view.updateView(from: source, selection: .all)
  #expect(view.visibleRows(width: 20, height: 4) == [""])
  for available in 1...100 {
    let height = TerminalView.height(availableRows: available)
    #expect(height == 0 || height + 2 <= available)
  }
  #expect(TerminalView.height(availableRows: 22, preferredHeight: 6) == 6)
  #expect(TerminalView.height(availableRows: 3, preferredHeight: 6) == 1)
  #expect(TerminalView.height(availableRows: 2, preferredHeight: 6) == 0)
  #expect(TerminalView.height(availableRows: 22, preferredHeight: 0) == 1)
  #expect(TerminalView.height(availableRows: 22, preferredHeight: 100) == 20)
}
