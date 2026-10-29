import Foundation
import Testing

@testable import MaiCore

@Test("Tool call display defaults, validation and persistence")
func toolCallDisplayConfiguration() throws {
  for (json, expected) in [
    ("{}", ToolCallDisplay.truncate),
    (#"{"toolcalls":"truncate"}"#, .truncate),
    (#"{"toolcalls":"first"}"#, .lines(1)),
    (#"{"toolcalls":5}"#, .lines(5)),
    (#"{"toolcalls":"3"}"#, .lines(3)),
    (#"{"toolcalls":0}"#, .truncate),
    (#"{"toolcalls":"unknown"}"#, .truncate),
  ] {
    let ui = try JSONDecoder().decode(ConfiguredTerminalUI.self, from: Data(json.utf8))
    #expect(ui.toolCalls == expected)
    #expect(try JSONDecoder().decode(ConfiguredTerminalUI.self, from: JSONEncoder().encode(ui)) == ui)
    #expect(ToolCallDisplay(setting: expected.description) == expected)
  }
  #expect(ToolCallDisplay(setting: "FIRST") == .lines(1))
  for invalid in ["0", "-1", "unknown", "1.5"] {
    #expect(ToolCallDisplay(setting: invalid) == nil)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ToolCallDisplay.self, from: JSONEncoder().encode(invalid))
    }
  }
}

@Test("Complete tool call source lines bypass both character limits and sanitize controls")
func toolCallDisplaySourceLines() {
  let first = "adb shell " + String(repeating: "com.example.package ", count: 30)
  let call = ToolCall(id: "shell", name: "run_shell", arguments: .object([
    "script": .string(first + "\n\n  heredoc body\nEOF"), "timeout_seconds": .number(540),
  ]))
  let compact = ToolCallPreview.render(call)
  #expect(compact.contains("…"))
  #expect(!compact.contains(first))
  #expect(ToolCallPreview.render(call, display: .lines(1))
    == "→ run_shell script=\"\(first)\" (+3 lines) timeout_seconds=540")
  #expect(ToolCallPreview.render(call, display: .lines(3))
    == "→ run_shell script=\"\(first)\n  \n    heredoc body\" (+1 lines) timeout_seconds=540")
  let full = ToolCallPreview.render(call, display: .lines(10))
  #expect(full.contains("\n  EOF\" timeout_seconds=540"))
  #expect(!full.contains("(+"))
  let unsafe = ToolCall(id: "unsafe", name: "run_shell", arguments: .object([
    "script": .string("cat\tfile\n\u{1B}[2Jbody\rtext"),
  ]))
  let safe = ToolCallPreview.render(unsafe, display: .lines(2))
  #expect(safe.contains("cat  file\n"))
  #expect(!safe.contains("\u{1B}") && !safe.contains("\r"))
}
