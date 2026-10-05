import Foundation
import Testing

@testable import MaiCore

@Test("Injected instructions, skill bodies, and catalogs are separate from conversation evidence")
func promptContextSeparatesInstructions() {
  let skill = promptContextSkill()
  let prompt = skill.prompt(arguments: "literal $418  input.txt")
  let load = ToolCall(
    id: "load", name: skill.toolName,
    arguments: .object(["arguments": .string("literal $418  input.txt")]))
  let list = ToolCall(
    id: "list", name: ToolProxy.listName, arguments: .object(["keywords": .string("stamp")]))
  let catalog = "EXACT TOOL SCHEMA: {\"required\":[\"path\"],\"additionalProperties\":false}"
  let messages: [AgentMessage] = [
    .system("STATIC RULES"), .developer("DEVELOPER RULES"), .user(prompt),
    AgentMessage(role: .assistant, content: [.toolCall(load), .toolCall(list)]),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(
          .init(
            callID: load.id,
            text: MaiSkillTools.execute(
              skill: skill, arguments: ["arguments": .string("literal $418  input.txt")]
            ).text)),
        .toolResult(.init(callID: list.id, text: catalog)),
      ]),
  ]
  let context = AgentPromptContext(messages: messages)
  let summaryInput = AgentSmartContextPrompt.render(messages: messages)
  for excluded in [
    "STATIC RULES", "DEVELOPER RULES",
    skill.body.replacingOccurrences(of: "$ARGUMENTS", with: "literal $418  input.txt"), catalog,
  ] {
    #expect(!summaryInput.contains(excluded))
  }
  #expect(summaryInput.contains("literal $418  input.txt"))
  #expect(summaryInput.contains(load.id) && summaryInput.contains(list.id))
  let projected = context.messages(brief: "LOSSY BRIEF")
  #expect(projected.contains(messages[0]) && projected.contains(messages[1]))
  let full = projected.map(\.text).joined(separator: "\n")
  let exact = skill.body.replacingOccurrences(of: "$ARGUMENTS", with: "literal $418  input.txt")
  #expect(full.components(separatedBy: exact).count == 2)  // direct + redundant tool load share one body
  #expect(projected.filter { $0.text.contains(exact) }.map(\.role) == [.system])
  #expect(projected.filter { $0.text.contains(catalog) }.map(\.role) == [.system])
  #expect(
    projected.last(where: { $0.role == .user })?.text.contains("literal $418  input.txt") == true)
  #expect(projected.flatMap(\.toolCalls).map(\.id) == [load.id, list.id])
  #expect(projected.flatMap(\.toolResults).map(\.callID) == [load.id, list.id])
  #expect(messages[2].text == prompt && messages[4].toolResults[1].text == catalog)
  let later = AgentPromptContext(
    messages: messages + [.assistant("Done"), .user("Different task")])
  #expect(!later.instructions.contains { $0.text.contains(exact) || $0.text.contains(catalog) })
  #expect(!later.conversation.contains { $0.text.contains(exact) || $0.text.contains(catalog) })
}

@Test("Context edits and pruning protect every instruction role and active mixed exchanges")
func promptContextProtectsEdits() throws {
  let skill = promptContextSkill()
  let load = ToolCall(
    id: "load", name: ToolProxy.callName,
    arguments: .object(["name": .string(skill.toolName), "arguments": .object([:])]))
  let list = ToolCall(id: "list", name: ToolProxy.listName, arguments: .object([:]))
  let sibling = ToolCall(id: "read", name: "read", arguments: .object([:]))
  let messages: [AgentMessage] = [
    .user("Earlier task"), .system("SECOND SYSTEM"), .developer("DEVELOPER"),
    .user(skill.prompt(arguments: "input.txt")),
    AgentMessage(
      role: .assistant, content: [.toolCall(load), .toolCall(list), .toolCall(sibling)]),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(.init(callID: load.id, text: String(repeating: "SKILL STEP\n", count: 1000)))
      ]),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(
          .init(callID: list.id, text: String(repeating: "CATALOG SCHEMA\n", count: 1000)))
      ]),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(
          .init(callID: sibling.id, text: String(repeating: "SIBLING EVIDENCE\n", count: 1000)))
      ]),
    .assistant("Later step"),
  ]
  let protected = Array(messages[1...7])
  let ids = protected.map(\.id)
  for edit in [
    AgentTranscriptEdit.remove(messageIDs: ids), .compact(messageIDs: ids, summary: "lossy"),
  ] {
    let edited = AgentTranscriptEditor.apply([edit], to: messages)
    #expect(edited.messages == messages && edited.report.isEmpty)
  }
  let rewrites = ids.map { AgentTranscriptEdit.rewrite(messageID: $0, text: "lossy") }
  #expect(AgentTranscriptEditor.apply(rewrites, to: messages).messages == messages)
  let view = MaiContextTools.ContextView(messages: messages)
  for number in 2...8 { #expect(throws: (any Error).self) { try view.select(String(number)) } }
  var pruned = messages
  #expect(AgentContextPruning.pruneToolOutput(&pruned) == nil)
  #expect(pruned == messages)
  var tools = AgentToolResultContext(messages: messages)
  tools.didRead(messages)
  let candidates = tools.pending(in: messages)
  #expect(!candidates.contains { $0.result.callID == load.id || $0.result.callID == list.id })
  let compacted = AgentTranscriptEditor.compactingConversation(
    messages, summary: "Earlier task finished")
  #expect(protected.allSatisfy { compacted.contains($0) })
  #expect(compacted.contains { $0.role == .user && $0.text.contains("Earlier task finished") })
  #expect(!compacted.contains { $0.role == .system && $0.text.contains("Earlier task finished") })
}

@Test("Legacy system summaries remain reducible evidence and never become instructions")
func promptContextLegacySummaries() {
  let summary = AgentMessage.system("Conversation summary (compacted):\n\nLEGACY EVIDENCE")
  let original: [AgentMessage] = [
    .system("ACTUAL RULES"), summary, .developer("ACTUAL DEVELOPER"), .user("Continue"),
  ]
  let context = AgentPromptContext(messages: original)
  #expect(context.instructions == [original[0], original[2]])
  #expect(context.conversation[0].id == summary.id && context.conversation[0].role == .user)
  let rendered = AgentSmartContextPrompt.render(messages: original)
  #expect(rendered.contains("LEGACY EVIDENCE") && !rendered.contains("ACTUAL RULES"))
  #expect(AgentCompactionPrompt.transcript(of: original).contains("LEGACY EVIDENCE"))
  #expect(MaiContextTools.ContextView(messages: original).editable.contains(1))
  let rewritten = AgentTranscriptEditor.apply(
    [.rewrite(messageID: summary.id, text: "REWRITTEN EVIDENCE")], to: original)
  #expect(rewritten.messages[1].role == .user)
  #expect(!AgentPromptContext(messages: rewritten.messages).instructions.contains {
    $0.text == "REWRITTEN EVIDENCE"
  })
  let compacted = AgentTranscriptEditor.compactingConversation(original, summary: "NEW EVIDENCE")
  #expect(compacted.contains(original[0]) && compacted.contains(original[2]))
  #expect(!compacted.contains(summary))
}

private func promptContextSkill() -> AgentSkill {
  AgentSkill(
    name: "stamp", description: "Stamp a file", directoryURL: URL(fileURLWithPath: "/tmp/stamp"),
    body: "EXACT STEP for $ARGUMENTS.\nAnswer with REQUIRED FORMAT.")
}
