import Foundation
import Testing

@testable import MaiCore

@Test("Tool context shrinks old output, keeps new evidence whole, and preserves history")
func toolResultContextLoop() async throws {
  let first = String(repeating: "FIRST FILE: parser code\n", count: 600) + "EXACT FIRST TAIL"
  let second = String(repeating: "SECOND FILE: regression code\n", count: 200) + "EXACT SECOND TAIL"
  let primary = ToolContextProvider(
    id: "primary",
    responses: [
      toolContextCall("one", path: "Parser.swift", prose: "Read the parser first."),
      toolContextCall("two", path: "Tests.swift", prose: "The parser needs a boundary fix."),
      toolContextCall("three", path: "verify", prose: "Check the regression."),
      .init(
        message: .assistant("Fixed and verified."), usage: .init(inputTokens: 10, outputTokens: 5)),
    ])
  let compact = ToolContextProvider(
    id: "compact",
    responses: [
      .init(
        message: .assistant(#"{"0":"Parser.swift: exact boundary fix evidence."}"#),
        usage: .init(inputTokens: 20, outputTokens: 5)),
      .init(
        message: .assistant(#"{"0":"Tests.swift: regression evidence."}"#),
        usage: .init(inputTokens: 20, outputTokens: 5)),
    ])
  let runtime = try await toolContextRuntime(primary, compact)
  await primary.observe(runtime.supervisor)
  let stats = ModelUsageStore()
  await runtime.configureUsageStats(stats)
  let attachment = ContentPart.image(
    ImageContent(source: .data(Data([1, 2, 3])), mimeType: "image/png"))
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "read", description: "Read evidence",
        annotations: .init(approval: .automatic))
    ) { arguments, _ in
      switch arguments.objectValue?["path"]?.stringValue {
      case "Parser.swift":
        ToolOutput(content: [
          .file(FileContent(name: "Parser.swift", mimeType: "text/plain", text: first)), attachment,
        ])
      case "Tests.swift":
        ToolOutput(content: [], structuredContent: .object(["code": .string(second)]))
      default:
        ToolOutput(text: "All checks passed.")
      }
    })
  let original: [AgentMessage] = [
    .system("Original system rule"), .developer("Keep the API stable"),
    .user("Fix the parser"), .assistant("Earlier design decision"),
    .user("Preserve the boundary condition exactly"),
  ]
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", model: "large", messages: original, toolNames: ["read"],
      retry: .none, autocompact: .init(tokens: 1), context: .tools))
  #expect(result.response.text == "Fixed and verified.")
  #expect(result.modelTurns == 4 && result.toolCalls == 3)
  #expect(result.usage?.totalTokens == 110)
  #expect(Array(result.transcript.prefix(original.count)) == original)
  let savedResults = result.transcript.flatMap(\.toolResults)
  #expect(savedResults[0].text == first)
  #expect(savedResults[1].structuredContent?.objectValue?["code"]?.stringValue == second)
  #expect(!result.transcript.contains { $0.text.contains("[Summary of earlier tool result]") })

  let requests = await primary.requests
  try #require(requests.count == 4)
  #expect(requests[1].messages.flatMap(\.toolResults)[0].text == first)
  let third = requests[2].messages.flatMap(\.toolResults)
  #expect(third[0].text.contains("exact boundary fix evidence"))
  #expect(third[0].content.contains(attachment))
  #expect(third[1] == savedResults[1])
  let fourth = requests[3].messages.flatMap(\.toolResults)
  #expect(fourth[0] == third[0])
  #expect(fourth[1].text.contains("regression evidence") && fourth[1].structuredContent == nil)
  #expect(fourth[2] == savedResults[2])
  #expect(requests.allSatisfy { request in original.allSatisfy { request.messages.contains($0) } })
  #expect(requests[3].messages.contains { $0.text == "The parser needs a boundary fix." })
  #expect(requests[3].messages.flatMap(\.toolCalls) == result.transcript.flatMap(\.toolCalls))
  let preparations = await compact.requests
  try #require(preparations.count == 2)
  #expect(preparations.allSatisfy { $0.model == "tiny" && $0.tools.isEmpty && !$0.stream })
  #expect(preparations[0].messages.last?.text.contains(first) == true)
  #expect(preparations[0].messages.last?.text.contains(second) == false)
  #expect(
    preparations[1].messages.last?.text.contains(JSONValue.string(second).compactJSONString) == true
  )
  #expect(preparations[1].messages.last?.text.contains(first) == false)
  #expect(await stats.totals().reduce(0) { $0 + $1.callCount } == 6)

  let sizes = await primary.contextSizes
  #expect(sizes == requests.map { AgentContextSize(messages: $0.messages) })
  #expect(sizes[1].estimatedTokens > sizes[0].estimatedTokens)
  #expect(sizes[2].estimatedTokens < sizes[1].estimatedTokens)
  #expect(sizes[3].estimatedTokens < sizes[2].estimatedTokens)
}

@Test("Tool context never summarizes loaded skill instructions", arguments: [false, true])
func toolResultContextSkills(proxied: Bool) {
  let call = ToolCall(
    id: "skill", name: proxied ? ToolProxy.callName : "skills_stamp",
    arguments: proxied
      ? .object(["name": .string("skills_stamp"), "arguments": .object([:])]) : .object([:]))
  let ordinary = ToolCall(id: "file", name: "files_read", arguments: .object([:]))
  let body = String(repeating: "Follow the exact skill steps.\n", count: 300)
  let messages: [AgentMessage] = [
    .user("Make a stamp"),
    AgentMessage(role: .assistant, content: [.toolCall(call), .toolCall(ordinary)]),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(.init(callID: call.id, text: body)),
        .toolResult(.init(callID: ordinary.id, text: body)),
      ]),
  ]
  var context = AgentToolResultContext(messages: messages)
  context.didRead(messages)
  let candidates = context.pending(in: messages)
  #expect(candidates.count == 1)
  #expect(candidates.first?.call?.name == "files_read")
  context.store(#"{"0":"Short file summary"}"#, for: candidates)
  #expect(context.messages(from: messages).flatMap(\.toolResults).first?.text == body)
}

@Test("Tool context batches consumed results and invalidates edited or retasked evidence")
func toolResultContextEdits() throws {
  let call = ToolCall(id: "one", name: "read", arguments: .object(["path": .string("a.swift")]))
  let large = String(repeating: "evidence ", count: 800)
  let result = ToolResult(callID: call.id, text: large)
  var messages: [AgentMessage] = [
    .user("Fix it"), AgentMessage(role: .assistant, content: [.toolCall(call)]),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(result), .toolResult(ToolResult(callID: "other", text: large)),
        .toolResult(ToolResult(callID: "error", text: large, isError: true)),
        .toolResult(ToolResult(callID: "small", text: "small")),
      ]),
  ]
  var context = AgentToolResultContext(messages: messages)
  #expect(context.pending(in: messages).isEmpty)  // Resume with unread output.
  context.didRead(messages)
  let candidates = context.pending(in: messages)
  #expect(candidates.count == 2)
  context.store(#"{"0":"First summary","1":"Second summary"}"#, for: candidates)
  #expect(context.pending(in: messages).isEmpty)
  let projected = context.messages(from: messages)
  #expect(projected[0] == messages[0] && projected[1] == messages[1])
  #expect(projected[2].toolResults[0].text.contains("First summary"))
  #expect(projected[2].toolResults[1].text.contains("Second summary"))
  #expect(projected[2].toolResults[2] == messages[2].toolResults[2])
  #expect(projected[2].toolResults[3] == messages[2].toolResults[3])

  messages[2].content[0] = .toolResult(ToolResult(callID: "one", text: large + "NEW EVIDENCE"))
  #expect(
    context.messages(from: messages)[2].content == [
      messages[2].content[0], projected[2].content[1], messages[2].content[2],
      messages[2].content[3],
    ])
  #expect(context.pending(in: messages).isEmpty)  // The edit has not been read yet.
  context.didRead(messages)
  #expect(context.pending(in: messages).count == 1)
  messages.append(.user("Inspect a different constraint"))
  #expect(context.pending(in: messages).count == 2)
  #expect(context.messages(from: messages) == messages)
  messages.remove(at: 2)
  #expect(context.pending(in: messages).isEmpty)
  #expect(context.messages(from: messages) == messages)
}

@Test(
  "Malformed, empty, partial and oversized tool summaries preserve original evidence",
  arguments: [
    "not JSON", "{}", #"{"0":" "}"#, #"{"0":123}"#,
    "{\"0\":\"" + String(repeating: "too long ", count: 1_000) + "\"}",
  ])
func toolResultContextInvalidSummary(response: String) {
  let messages: [AgentMessage] = [
    .user("Task"),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(ToolResult(callID: "read", text: String(repeating: "raw ", count: 1_500)))
      ]), .assistant("Already used this output"),
  ]
  var context = AgentToolResultContext(messages: messages)
  let candidates = context.pending(in: messages)
  #expect(candidates.count == 1)
  context.store(response, for: candidates)
  #expect(context.messages(from: messages) == messages)
  #expect(context.pending(in: messages).isEmpty)
}

@Test("Tool summarization respects token limits before another conversation call")
func toolResultContextTokenBudget() async throws {
  let primary = ToolContextProvider(id: "primary", responses: [])
  let compact = ToolContextProvider(
    id: "compact",
    responses: [
      .init(
        message: .assistant(#"{"0":"Evidence"}"#), usage: .init(inputTokens: 100, outputTokens: 10))
    ])
  let runtime = try await toolContextRuntime(primary, compact)
  let original: [AgentMessage] = [
    .user("Task"),
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(ToolResult(callID: "read", text: String(repeating: "raw ", count: 1_500)))
      ]), .assistant("Earlier answer"), .user("Continue"),
  ]
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", messages: original,
      limits: .init(maxTotalTokens: 100), retry: .none, context: .tools))
  #expect(result.interruption == .totalTokens(limit: 100))
  #expect(result.transcript == original && result.modelTurns == 0)
  #expect(result.usage?.totalTokens == 110)
  #expect(await primary.requests.isEmpty)
}

@Test("A failed tool summarizer keeps full evidence and lets the conversation finish")
func toolResultContextProviderFailure() async throws {
  let primary = ToolContextProvider(
    id: "primary",
    responses: [
      toolContextCall("one", path: "a.swift", prose: "Read a.swift"),
      toolContextCall("two", path: "b.swift", prose: "Read b.swift"),
      .init(message: .assistant("Done")),
    ])
  let compact = ToolContextProvider(id: "compact", responses: [])
  let runtime = try await toolContextRuntime(primary, compact)
  let evidence = String(repeating: "source evidence ", count: 500)
  try await runtime.register(
    tool: ClosureTool(
      definition: .init(name: "read", description: "Read", annotations: .init(approval: .automatic))
    ) { _, _ in ToolOutput(text: evidence) })
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", messages: [.user("Task")], toolNames: ["read"],
      retry: .none, context: .tools))
  #expect(result.response.text == "Done")
  #expect(result.transcript.flatMap(\.toolResults).allSatisfy { $0.text == evidence })
  let last = try #require(await primary.requests.last)
  #expect(last.messages.flatMap(\.toolResults).allSatisfy { $0.text == evidence })
  #expect(await compact.requests.count == 1)
}

@Test("Tools context configuration persists and live context counts include structured output")
func toolResultContextConfiguration() async throws {
  let configuration = MaiConfiguration(
    providers: [.init(id: "hello", kind: .hello)],
    agents: [
      .init(id: "main", instructions: "", provider: "hello", model: "hello", context: .tools)
    ])
  try configuration.validate()
  #expect(
    try JSONDecoder().decode(MaiConfiguration.self, from: configuration.encoded()) == configuration)
  let supervisor = AgentSupervisor()
  let pid = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "Task", depth: 0)
  let initial = [AgentMessage.user("Task")]
  await supervisor.note(pid, transcript: initial)
  let before = try #require(await supervisor.info(pid)?.contextSize)
  let messages =
    initial + [
      AgentMessage(
        role: .tool,
        content: [
          .toolResult(
            ToolResult(
              callID: "one", content: [],
              structuredContent: .object(["code": .string(String(repeating: "data ", count: 1_000))]
              )))
        ])
    ]
  await supervisor.note(pid, transcript: messages)
  let after = try #require(await supervisor.info(pid)?.contextSize)
  #expect(after.messageCount == 2 && after.estimatedTokens > before.estimatedTokens + 1_000)
  #expect(await supervisor.reopen(pid, runID: UUID(), task: "Next"))
  #expect(await supervisor.info(pid)?.contextSize == nil)
}

private func toolContextCall(_ id: String, path: String, prose: String) -> ProviderResponse {
  .init(
    message: AgentMessage(
      role: .assistant,
      content: [
        .text(prose),
        .toolCall(.init(id: id, name: "read", arguments: .object(["path": .string(path)]))),
      ]), usage: .init(inputTokens: 10, outputTokens: 5))
}

private func toolContextRuntime(_ primary: ToolContextProvider, _ compact: ToolContextProvider)
  async throws -> AgentRuntime
{
  let runtime = AgentRuntime()
  try await runtime.register(primary)
  try await runtime.register(compact)
  try await runtime.register(
    agent: .init(
      id: "summarizer", instructions: "Summarize accurately",
      provider: "compact", model: "tiny", retry: .none))
  await runtime.configureTaskAgents(.init(compact: "summarizer"))
  return runtime
}

private actor ToolContextProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  var responses: [ProviderResponse]
  private(set) var requests: [ProviderRequest] = []
  private(set) var contextSizes: [AgentContextSize] = []
  private var supervisor: AgentSupervisor?

  init(id: ProviderID, responses: [ProviderResponse]) {
    descriptor = .init(id: id, displayName: id.rawValue, capabilities: [.nativeToolCalling])
    self.responses = responses
  }

  func observe(_ supervisor: AgentSupervisor) { self.supervisor = supervisor }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    if let size = await supervisor?.processes().first?.contextSize { contextSizes.append(size) }
    guard !responses.isEmpty else { throw ToolContextFixtureError.unexpectedCall }
    return responses.removeFirst()
  }
}

private enum ToolContextFixtureError: Error { case unexpectedCall }
