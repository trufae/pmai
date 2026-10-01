import Foundation
import Testing

@testable import MaiCore

@Test("Context estimates add new tool output to measured provider usage")
func compactionCountsAppendedOutput() {
  let original: [AgentMessage] = [.user("go"), .assistant("working")]
  let output = AgentMessage(role: .tool, content: [.toolResult(
    ToolResult(callID: "read", text: String(repeating: "x", count: 8_000)))])
  let usage = TokenUsage(inputTokens: 10_000, outputTokens: 100)
  #expect(AgentAutocompaction.estimatedTokens(
    of: original + [output], lastUsage: usage, lastUsageMessageCount: original.count) == 12_100)
  #expect(AgentAutocompaction.estimatedTokens(
    of: original, lastUsage: usage, lastUsageMessageCount: original.count) == 10_100)
  #expect(AgentAutocompaction.estimatedTokens(
    of: [output], lastUsage: nil, lastUsageMessageCount: original.count) == 2_000)
}

@Test("Compaction keeps a recent tail, the user request, and complete tool transactions")
func compactionRetainsRecentExchanges() throws {
  let user = AgentMessage.user("Implement the change; do not modify the public API.")
  func exchange(_ id: String, count: Int) -> [AgentMessage] {
    [AgentMessage(role: .assistant, content: [.toolCall(ToolCall(
      id: id, name: "read", arguments: .object([:])))]),
     AgentMessage(role: .tool, content: [.toolResult(ToolResult(
       callID: id, text: String(repeating: "x", count: count)))])]
  }
  let old = exchange("old", count: 10_000)
  let recent = exchange("recent", count: 400) + exchange("newest", count: 400)
  let messages = [AgentMessage.system("instructions"), user] + old + recent
  let selection = try #require(AgentAutocompaction.selection(in: messages, preservingRecentTokens: 300))
  #expect(selection == old.map(\.id))
  let compacted = AgentTranscriptEditor.apply([.compact(messageIDs: selection, summary: "old findings")], to: messages).messages
  #expect(compacted.last(where: { $0.role == .user }) == user)
  #expect(Array(compacted.suffix(recent.count)) == recent)
  #expect(compacted.first == messages.first)
  // The next compaction must still protect the real request, not the summary.
  let next = try #require(AgentAutocompaction.selection(
    in: compacted + exchange("later", count: 200), preservingRecentTokens: 0))
  #expect(!next.contains(user.id))
  #expect(next.contains(compacted[1].id))
  #expect(AgentAutocompaction.selection(in: messages, preservingRecentTokens: 100_000) == nil)
}

@Test("Compaction tail budgets decode compatibly and allow explicit overrides")
func compactionTailConfiguration() throws {
  let defaults = try JSONDecoder().decode(AgentAutocompact.self, from: Data(#"{"tokens":16000}"#.utf8))
  #expect(defaults.recentTokenBudget == 4_000)
  #expect(AgentAutocompact().recentTokenBudget == 8_000)
  let explicit = AgentAutocompact(tokens: 16_000, preserveRecentTokens: 0)
  #expect(try JSONDecoder().decode(AgentAutocompact.self, from: JSONEncoder().encode(explicit)) == explicit)
}

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
    ("shell", "run_shell", body, false),
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

@Test("Explicit pruning shortens old tool output and preserves the latest exchange and errors")
func aggressivePruningKeepsConversationAndLatestExchange() throws {
  let body = "START" + String(repeating: "search result\n", count: 1_000) + "END"
  let metadata: JSONValue = .object(["exitCode": .integer(0)])
  func exchange(_ id: String, _ content: [ContentPart], error: Bool = false) -> [AgentMessage] {
    [
      AgentMessage(role: .assistant, content: [
        .text("Keep this conclusion."), .toolCall(ToolCall(
          id: id, name: "web_search", arguments: .object(["query": .string("important search")]))),
      ]),
      AgentMessage(role: .tool, content: [.toolResult(ToolResult(
        callID: id, content: content, structuredContent: metadata, isError: error))]),
    ]
  }
  var messages: [AgentMessage] = [.system("Instructions"), .user("Keep my request.")]
  messages += exchange("search", [.text(body)])
  messages += exchange("attachments", [
    .file(FileContent(name: "source.c", mimeType: "text/plain", text: body)),
    .resource(ResourceContent(uri: "source://web", text: body)),
  ])
  messages += exchange("error", [.text(body)], error: true)
  messages += exchange("latest", [.text(body)])
  let original = messages
  var cheap = messages
  #expect(AgentContextPruning.prune(&cheap) == nil)
  let report = try #require(AgentContextPruning.pruneToolOutput(&messages))
  #expect(report.trimmedToolResults == 2)
  #expect(!report.isEmpty)
  #expect(report.summary.hasPrefix("pruned 2 old tool outputs"))
  #expect(report.charactersBefore - report.charactersAfter > 30_000)
  #expect(messages.filter { $0.role != .tool } == original.filter { $0.role != .tool })
  let results = messages.flatMap(\.toolResults)
  #expect(results[0].text.hasPrefix("START"))
  #expect(results[0].text.hasSuffix("END"))
  #expect(results[0].text.contains("pruned by user choice"))
  #expect(results[0].text.count < 1_400)
  #expect(results.allSatisfy { $0.structuredContent == metadata })
  #expect(results[2].text == body)
  #expect(results[3].text == body)
  #expect(AgentContextPruning.pruneToolOutput(&messages) == nil)
}
