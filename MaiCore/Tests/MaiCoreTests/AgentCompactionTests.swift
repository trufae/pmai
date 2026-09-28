import Foundation
import Testing

@testable import MaiCore

@Test("Compaction includes attachment bodies once and bounds files and resources")
func compactionBoundsAttachments() {
  let messages = [
    AgentMessage(
      role: .user,
      content: [
        .text("Compare these sources."),
        .file(
          FileContent(
            name: "large.txt", mimeType: "text/plain",
            text: "FILE-START" + String(repeating: "f", count: 80_000) + "FILE-END")),
        .resource(
          ResourceContent(
            uri: "source://large", name: "Large source",
            text: "RESOURCE-START" + String(repeating: "r", count: 80_000) + "RESOURCE-END")),
      ])
  ]

  let transcript = AgentCompactionPrompt.transcript(of: messages)
  #expect(transcript.contains("Compare these sources."))
  #expect(transcript.contains("[file large.txt] FILE-START"))
  #expect(transcript.contains("[resource source://large] RESOURCE-START"))
  #expect(transcript.components(separatedBy: "FILE-START").count == 2)
  #expect(transcript.components(separatedBy: "RESOURCE-START").count == 2)
  #expect(!transcript.contains("FILE-END"))
  #expect(!transcript.contains("RESOURCE-END"))
  #expect(transcript.count < 8_300)
}

@Test("Compaction keeps prose and tool exchanges while bounding only attachment and result bodies")
func compactionPreservesProseAndTools() {
  let prose = String(repeating: "Keep this requirement. ", count: 20)
  let messages: [AgentMessage] = [
    .system("Persistent system instructions"),
    .developer("Persistent developer instructions"),
    AgentMessage(
      role: .user,
      content: [
        .text(prose),
        .file(FileContent(name: "short.txt", mimeType: "text/plain", text: "short body")),
        .resource(ResourceContent(uri: "source://binary")),
      ]),
    AgentMessage(
      role: .assistant,
      content: [
        .text("<think>private reasoning</think>Read the source."),
        .reasoning("more private reasoning"),
        .toolCall(
          ToolCall(
            id: "read", name: "files_read", arguments: .object(["path": .string("source.swift")]))),
      ]),
    AgentMessage(
      role: .tool,
      content: [.toolResult(ToolResult(callID: "read", text: String(repeating: "t", count: 100)))]),
  ]

  let transcript = AgentCompactionPrompt.transcript(of: messages, resultLimit: 40)
  #expect(transcript.contains(prose.trimmingCharacters(in: .whitespacesAndNewlines)))
  #expect(transcript.components(separatedBy: "short body").count == 2)
  #expect(transcript.contains("[resource source://binary]"))
  #expect(transcript.contains("Assistant:\nRead the source."))
  #expect(transcript.contains(#"[tool call files_read {"path":"source.swift"}]"#))
  #expect(transcript.contains("[tool result] " + String(repeating: "t", count: 40)))
  #expect(transcript.contains("60 characters omitted"))
  #expect(!transcript.contains("Persistent"))
  #expect(!transcript.contains("private reasoning"))
}

@Test("Pruning includes old plain-text file reads and keeps their recovery arguments")
func pruningIncludesPlainTextFileReads() throws {
  let body = String(repeating: "line of source\n", count: 800)
  let metadata: JSONValue = .object(["revision": .string("abc"), "startLine": .integer(12)])
  let range: JSONValue = .object([
    "path": .string("src/file.cpp"), "start_line": .integer(12), "end_line": .integer(811),
  ])
  let function: JSONValue = .object(["path": .string("src/file.cpp"), "name": .string("main")])
  func exchange(_ id: String, _ name: String, _ arguments: JSONValue) -> [AgentMessage] {
    [
      AgentMessage(role: .assistant, content: [.toolCall(ToolCall(id: id, name: name, arguments: arguments))]),
      AgentMessage(role: .tool, content: [.toolResult(ToolResult(
        callID: id, content: [.text(body)], structuredContent: metadata))]),
    ]
  }
  var messages: [AgentMessage] = [.user("Inspect the code.")]
  messages += exchange("range", "files_read_range", range)
  messages += exchange("function", "files_get_function", function)
  messages += exchange("proxy", ToolProxy.callName, .object([
    "name": .string("files_read_range"), "arguments": range,
  ]))
  messages += [.assistant("Inspected."), .user("Next task.")]
  messages += exchange("current", "files_read_range", range)
  let before = AgentTranscriptEditor.characterCount(of: messages)
  let report = try #require(AgentContextPruning.prune(&messages))
  #expect(report.pruned == 3)
  #expect(report.rewritten == 0)
  #expect(!report.isEmpty)
  #expect(report.summary.hasPrefix("pruned 3 old read results ("))
  #expect(report.charactersBefore == before)
  #expect(report.charactersAfter == AgentTranscriptEditor.characterCount(of: messages))
  #expect(report.charactersAfter < before / 3)
  let results = messages.flatMap(\.toolResults)
  for result in results.prefix(3) {
    #expect(result.text.contains("Earlier file read removed"))
    #expect(result.structuredContent == metadata)
  }
  #expect(results[0].text.contains("files_read_range with \(range.compactJSONString)"))
  #expect(results[1].text.contains("files_get_function with \(function.compactJSONString)"))
  #expect(results[2].text == results[0].text)
  #expect(results[3].text == body)
  #expect(messages.flatMap(\.toolCalls).map(\.id) == ["range", "function", "proxy", "current"])
  #expect(AgentContextPruning.prune(&messages) == nil)
}

@Test("Pruning does not mistake errors, edits or shell output for file reads")
func pruningPreservesOtherTextResults() {
  let body = String(repeating: "important output\n", count: 100)
  var messages: [AgentMessage] = [.user("First task.")]
  for (id, name, text, error) in [
    ("shell", "run_sh", body, false),
    ("edit", "files_patch", body, false),
    ("error", "files_read_range", body, true),
    ("short", "files_get_function", "short body", false),
  ] {
    messages.append(AgentMessage(role: .assistant, content: [.toolCall(ToolCall(
      id: id, name: name, arguments: .object(["path": .string("source.cpp")])))]))
    messages.append(AgentMessage(role: .tool, content: [.toolResult(ToolResult(
      callID: id, text: text, isError: error))]))
  }
  messages.append(.user("Next task."))
  let original = messages
  #expect(AgentContextPruning.prune(&messages) == nil)
  #expect(messages == original)
}
