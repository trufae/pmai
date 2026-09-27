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
