import Foundation
import Testing

@testable import MaiCore

@Test("A reply started before clearing or compacting does not reappear as an orphan turn")
func completedRunAfterClearingChat() {
  let system = AgentMessage.system("Instructions")
  let prompt = AgentMessage.user("Old question")
  let sent = [system, prompt]
  let result = sent + [.assistant("Old answer")]
  let cleared = [system]
  let compacted = [system, .system("Conversation summary (compacted): Earlier work")]
  #expect(
    AgentTranscriptEditor.mergeCompletedRun(current: cleared, sent: sent, result: result)
      == cleared)
  #expect(
    AgentTranscriptEditor.mergeCompletedRun(current: compacted, sent: sent, result: result)
      == compacted)

  let newPrompt = AgentMessage.user("New question")
  let restarted = [system, newPrompt]
  #expect(
    AgentTranscriptEditor.mergeCompletedRun(current: restarted, sent: sent, result: result)
      == restarted)
  let editedPrompt = AgentMessage(id: prompt.id, role: .user, content: "Edited question")
  #expect(
    AgentTranscriptEditor.mergeCompletedRun(
      current: [system, editedPrompt], sent: sent, result: result)
      == [system, editedPrompt, result[2]])
  #expect(AgentTranscriptEditor.mergeCompletedRun(current: sent, sent: sent, result: result) == result)
}

// The context tools let an agent shrink its own conversation: drop what no
// longer matters, rewrite a message, or fold a stretch into a summary. Edits
// are queued while the turn runs and applied before the next model call.

@Test("Removing either side of a tool exchange removes both, and the report counts characters")
func editorRemovesLinkedToolMessages() {
  let messages = contextFixture()
  let edit = AgentTranscriptEdit.remove(messageIDs: [messages[3].id])  // the tool result
  let applied = AgentTranscriptEditor.apply([edit], to: messages)
  #expect(applied.messages.map(\.id) == [messages[0].id, messages[1].id, messages[4].id, messages[5].id])
  #expect(applied.report.removed == 2)
  #expect(applied.report.charactersBefore > applied.report.charactersAfter)
  #expect(applied.report.summary.hasPrefix("removed 2 messages ("))

  let rewritten = AgentTranscriptEditor.apply(
    [.rewrite(messageID: messages[1].id, text: "Short instruction.")], to: messages)
  #expect(rewritten.messages[1].text == "Short instruction.")
  #expect(rewritten.report.rewritten == 1)

  let compacted = AgentTranscriptEditor.apply(
    [.compact(messageIDs: [messages[1].id, messages[2].id], summary: "The user wanted the file read; it was.")],
    to: messages)
  #expect(compacted.report.compacted == 3)  // the tool result goes with its call
  #expect(compacted.messages.count == 4)
  #expect(compacted.messages[1].role == .user)
  #expect(compacted.messages[1].text.contains("Summary of earlier parts of this conversation"))
  #expect(compacted.messages[1].text.hasSuffix("The user wanted the file read; it was."))
  #expect(compacted.messages[2].id == messages[4].id)
}

@Test("The context view numbers messages from one and keeps the system prompt, the latest prompt, and the current turn")
func contextViewProtectsWhatMustStay() throws {
  let view = MaiContextTools.ContextView(messages: contextFixture())
  #expect(view.listing.hasPrefix("Context: 6 messages"))
  #expect(view.listing.contains("#1 system"))
  #expect(view.listing.contains("[system prompt, kept]"))
  #expect(view.listing.contains("#3 assistant"))
  #expect(view.listing.contains("→ read_file {\"path\":\"a.c\"}"))
  #expect(view.listing.contains("#5 user"))
  #expect(view.listing.contains("[latest user prompt, kept]"))
  #expect(view.listing.contains("#6 assistant"))
  #expect(view.listing.contains("[turn in progress, kept]"))
  #expect(view.listing.contains("among the 3 editable messages"))

  #expect(try view.select("2") == [1])
  #expect(try view.select("#3") == [2])
  #expect(try view.select("2-4") == [1, 2, 3])
  #expect(try view.select("4, 2") == [1, 3])
  #expect(try view.select("all") == [1, 2, 3])  // not the system prompt, the latest user prompt, or the current turn
  #expect(try view.select("last") == [3])
  #expect(try view.select("last 2") == [2, 3])
  #expect(try view.select("last:10") == [1, 2, 3])
  #expect(throws: (any Error).self) { try view.select("1") }
  #expect(throws: (any Error).self) { try view.select("5") }
  #expect(throws: (any Error).self) { try view.select("6") }
  #expect(throws: (any Error).self) { try view.select("9") }
  #expect(throws: (any Error).self) { try view.select("x") }
  #expect(throws: (any Error).self) { try view.select("last x") }
}

@Test("Context edits queued by a tool are applied before the next model turn")
func contextEditsApplyBetweenTurns() async throws {
  let provider = ContextScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "c1", name: MaiContextTools.removeName,
              arguments: .object(["messages": .string("2")])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Done with a smaller context."), stopReason: .stop),
  ])
  let recorder = ContextEventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllContextApprovals())
  try await runtime.register(provider)
  for tool in MaiContextTools.makeTools(supervisor: runtime.supervisor) {
    try await runtime.register(tool: tool)
  }

  let result = try await runtime.run(
    AgentRequest(
      provider: "context-scripted",
      model: "fixture",
      messages: [
        .system("Be brief."),
        .user("Ignore this aside about the weather."),
        .user("Now: read the file."),
      ],
      toolNames: Set(MaiContextTools.toolNames))
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Done with a smaller context.")
  #expect(!result.transcript.contains { $0.text == "Ignore this aside about the weather." })
  #expect(result.transcript.first?.text == "Be brief.")
  let requests = await provider.requests
  #expect(requests.count == 2)
  #expect(requests[1].messages.contains { $0.text == "Now: read the file." })
  #expect(!requests[1].messages.contains { $0.text == "Ignore this aside about the weather." })
  let toolText = try #require(result.transcript.flatMap(\.toolResults).first?.text)
  #expect(toolText.hasPrefix("Before your next turn: removed 1 message ("))
  let reports = await recorder.events.compactMap { event -> AgentTranscriptEditReport? in
    if case .transcriptEdited(_, let report) = event { return report }
    return nil
  }
  #expect(reports.count == 1)
  #expect(reports.first?.removed == 1)
}

@Test("A compaction without a summary is written by the model before the next turn")
func contextCompactWithoutSummaryIsSummarizedByTheModel() async throws {
  let provider = ContextScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "c1", name: MaiContextTools.compactName,
              arguments: .object(["messages": .string("2"), "focus": .string("the weather")])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Earlier: the user talked about rain."), stopReason: .stop),
    ProviderResponse(message: .assistant("Done with a summary."), stopReason: .stop),
  ])
  let recorder = ContextEventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllContextApprovals())
  try await runtime.register(provider)
  for tool in MaiContextTools.makeTools(supervisor: runtime.supervisor) {
    try await runtime.register(tool: tool)
  }

  let result = try await runtime.run(
    AgentRequest(
      provider: "context-scripted",
      model: "fixture",
      messages: [
        .system("Be brief."),
        .user("It rained all week here."),
        .user("Now: read the file."),
      ],
      toolNames: Set(MaiContextTools.toolNames))
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Done with a summary.")
  let summary = try #require(
    result.transcript.first { $0.text.hasPrefix("Summary of earlier parts of this conversation") })
  #expect(summary.role == .user)
  #expect(summary.text.hasSuffix("Earlier: the user talked about rain."))
  #expect(!result.transcript.contains { $0.text == "It rained all week here." })
  let requests = await provider.requests
  #expect(requests.count == 3)
  let compaction = try #require(requests[1].messages.first?.text)
  #expect(compaction.contains("It rained all week here."))
  #expect(compaction.contains("the weather"))
  #expect(requests[1].tools.isEmpty)
  #expect(requests[2].messages.contains { $0.text.hasSuffix("Earlier: the user talked about rain.") })
  #expect(!requests[2].messages.contains { $0.text == "It rained all week here." })
  let toolText = try #require(result.transcript.flatMap(\.toolResults).first?.text)
  #expect(toolText.hasPrefix("Before your next turn: 1 message ("))
  #expect(toolText.contains("keeping: the weather"))
  let events = await recorder.events
  #expect(
    events.contains {
      if case .compactionStarted = $0 { return true }
      return false
    })
  let reports = events.compactMap { event -> AgentTranscriptEditReport? in
    if case .transcriptEdited(_, let report) = event { return report }
    return nil
  }
  #expect(reports.count == 1)
  #expect(reports.first?.compacted == 1)
}

// MARK: - Fixtures

/// system, user, assistant(tool call), tool(result), user, assistant(current turn)
private func contextFixture() -> [AgentMessage] {
  [
    .system("You are terse."),
    .user("Please read a.c but first let me tell you a long story about my weekend."),
    AgentMessage(
      role: .assistant,
      content: [.toolCall(ToolCall(id: "call-1", name: "read_file", arguments: .object(["path": .string("a.c")])))]),
    AgentMessage(role: .tool, content: [.toolResult(ToolResult(callID: "call-1", text: String(repeating: "x", count: 500)))]),
    .user("Now summarize it."),
    AgentMessage(
      role: .assistant,
      content: [.toolCall(ToolCall(id: "call-2", name: MaiContextTools.listName, arguments: .object([:])))]),
  ]
}

private actor ContextScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "context-scripted", displayName: "Context scripted",
    capabilities: [.streaming, .nativeToolCalling])
  private var responses: [ProviderResponse]
  private(set) var requests: [ProviderRequest] = []

  init(responses: [ProviderResponse]) { self.responses = responses }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw ContextTestError.missingResponse }
    return responses.removeFirst()
  }
}

private struct AllowAllContextApprovals: ApprovalHandler {
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .approve(arguments: request.call.arguments)
  }
}

private actor ContextEventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

private enum ContextTestError: Error { case missingResponse }
