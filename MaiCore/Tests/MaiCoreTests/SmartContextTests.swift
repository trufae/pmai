import Foundation
import Testing

@testable import MaiCore

@Test(
  "Smart context is rebuilt from the full transcript after every tool turn",
  arguments: [false, true])
func smartContextToolTurns(textProtocol: Bool) async throws {
  let call = ToolCall(id: "read-1", name: "read", arguments: .object([:]))
  let evidence = String(repeating: "irrelevant log\n", count: 500) + "RELEVANT TAIL: line 900 fails"
  let primary = SmartContextProvider(
    id: "primary",
    responses: [
      .init(
        message: textProtocol
          ? .assistant(#"{"tool":"read","arguments":{}}"#)
          : AgentMessage(role: .assistant, content: [.toolCall(call)]),
        usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
      .init(message: .assistant("Fixed."), usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
    ])
  let compact = SmartContextProvider(
    id: "compact",
    responses: [
      .init(
        message: .assistant("First working brief"),
        usage: TokenUsage(inputTokens: 20, outputTokens: 5)),
      .init(
        message: .assistant("Second working brief"),
        usage: TokenUsage(inputTokens: 20, outputTokens: 5)),
    ])
  let runtime = try await smartRuntime(primary, compact)
  await runtime.configureSmartContext(prompt: "SMART TEMPLATE\n{{transcript}}")
  await runtime.configureCompaction(prompt: "DURABLE TEMPLATE\n{{transcript}}")
  let stats = ModelUsageStore()
  await runtime.configureUsageStats(stats)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "read", description: "Read evidence",
        annotations: ToolAnnotations(approval: .automatic))
    ) { _, _ in
      ToolOutput(
        content: [.text(evidence)], structuredContent: .object(["status": .string("tail-status")]))
    })
  let original: [AgentMessage] = [
    .system("Keep all safety constraints"), .developer("Developer rule"),
    .user("Fix the failing test"), .assistant("Earlier finding"), .user("Keep the API stable"),
  ]
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", model: "frontier", messages: original, toolNames: ["read"],
      limits: AgentRunLimits(maxModelTurns: 2), toolCallingStrategy: textProtocol ? .json : .native,
      retry: .none, autocompact: .init(tokens: 0), context: .smart, sessionID: "same-session"))
  #expect(result.response.text == "Fixed.")
  #expect(result.modelTurns == 2 && result.toolCalls == 1)
  #expect(result.usage?.totalTokens == 80)
  #expect(Array(result.transcript.prefix(original.count)) == original)
  #expect(result.transcript.flatMap(\.toolResults).first?.text == evidence)
  #expect(!result.transcript.contains { $0.text.contains("working brief") })
  let requests = await primary.requests
  try #require(requests.count == 2)
  #expect(
    requests.map { $0.messages.filter { $0.role == .user }.map(\.text) }
      == [["First working brief", "Keep the API stable"], ["Second working brief", "Keep the API stable"]])
  #expect(
    requests.allSatisfy { request in
      request.messages.filter { $0.role != .system && $0.role != .developer }.count == 2
        && request.messages.contains(original[1])
        && request.messages.contains { $0.role == .system && $0.text.contains(original[0].text) }
        && request.model == "frontier" && request.sessionID == "same-session"
    })
  #expect(requests.allSatisfy { $0.tools.isEmpty == textProtocol })
  let preparations = await compact.requests
  try #require(preparations.count == 2)
  #expect(preparations.allSatisfy { $0.model == "tiny" && $0.tools.isEmpty && !$0.stream })
  let next = preparations[1].messages.map(\.text).joined(separator: "\n")
  #expect(next.contains("SMART TEMPLATE") && !next.contains("DURABLE TEMPLATE"))
  #expect(next.contains(evidence) && next.contains("tail-status"))
  #expect(next.contains("Earlier finding") && next.contains("Keep the API stable"))
  #expect(next.contains("tool call") && next.contains("tool result"))
  #expect(!next.contains("First working brief"))
  #expect(!next.contains("Keep all safety constraints") && !next.contains("Developer rule"))
  #expect(!next.contains("Tools are available through") && !next.contains("parameter schema"))
  #expect(await stats.totals().count == 2)
}

@Test("Smart context still compacts the full growing transcript")
func smartContextAutocompaction() async throws {
  let call = ToolCall(id: "one", name: "read", arguments: .object([:]))
  let second = ToolCall(id: "two", name: "read", arguments: .object(["next": .bool(true)]))
  let primary = SmartContextProvider(
    id: "primary",
    responses: [
      .init(
        message: AgentMessage(role: .assistant, content: [.toolCall(call)]),
        usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
      .init(
        message: AgentMessage(role: .assistant, content: [.toolCall(second)]),
        usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
      .init(message: .assistant("Done")),
    ])
  let compact = SmartContextProvider(
    id: "compact",
    responses: [
      .init(message: .assistant("brief one")),
      .init(message: .assistant("brief two")),
      .init(message: .assistant("durable summary")),
      .init(message: .assistant("brief three")),
    ])
  let runtime = try await smartRuntime(primary, compact)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "read", description: "Read",
        annotations: ToolAnnotations(approval: .automatic))
    ) { _, _ in ToolOutput(text: String(repeating: "important context ", count: 500)) })
  let original = [AgentMessage.user("Finish the task, preserving this exact constraint.")]
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", messages: original, toolNames: ["read"], retry: .none,
      autocompact: .init(tokens: 500), context: .smart))
  let preparations = await compact.requests
  try #require(preparations.count == 4)
  #expect(preparations[2].messages.last?.text.contains("Compact the transcript") == true)
  #expect(preparations[3].messages.last?.text.contains("durable summary") == true)
  #expect(result.transcript.contains { $0.text.contains("durable summary") })
  #expect(result.transcript.contains(original[0]))
  #expect(!result.transcript.contains { $0.text == "brief one" || $0.text == "brief two" })
}

@Test("Smart preparation respects token limits before calling the primary")
func smartContextTokenBudget() async throws {
  let primary = SmartContextProvider(id: "primary", responses: [])
  let compact = SmartContextProvider(
    id: "compact",
    responses: [
      .init(message: .assistant("brief"), usage: TokenUsage(inputTokens: 100, outputTokens: 10))
    ])
  let runtime = try await smartRuntime(primary, compact)
  let original = [AgentMessage.user("Do the work")]
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", messages: original, limits: AgentRunLimits(maxTotalTokens: 100),
      retry: .none, context: .smart))
  #expect(result.interruption == .totalTokens(limit: 100))
  #expect(result.transcript == original)
  #expect(result.modelTurns == 0)
  #expect(result.usage?.totalTokens == 110)
  #expect(await primary.requests.isEmpty)
}

@Test(
  "An empty or failed smart preparation never sends full history to the primary",
  arguments: [false, true])
func smartContextFailure(empty: Bool) async throws {
  let primary = SmartContextProvider(id: "primary", responses: [])
  let compact = SmartContextProvider(
    id: "compact", responses: empty ? [.init(message: .assistant("  "))] : [])
  let runtime = try await smartRuntime(primary, compact)
  await #expect(throws: (any Error).self) {
    try await runtime.run(
      AgentRequest(
        provider: "primary", messages: [.user("Work")],
        retry: .none, context: .smart))
  }
  #expect(await primary.requests.isEmpty)
  #expect(await compact.requests.count == 1)
  let process = try #require(await runtime.supervisor.processes().first)
  #expect(await runtime.supervisor.transcript(process.pid).map(\.text) == ["Work"])
}

@Test("Smart context preserves binary evidence and excludes hidden reasoning")
func smartContextAttachments() {
  let attachment = ContentPart.image(
    ImageContent(source: .url(URL(string: "https://example.org/image.png")!), mimeType: "image/png")
  )
  let original: [AgentMessage] = [
    .system("Rules"), .user("Inspect image"),
    AgentMessage(
      role: .tool, content: [.toolResult(ToolResult(callID: "image", content: [attachment]))]),
    AgentMessage(
      role: .assistant, content: [.reasoning("private reasoning"), .text("Visible finding")]),
  ]
  let prompt = AgentSmartContextPrompt.render(messages: original)
  #expect(!prompt.contains("private reasoning"))
  #expect(prompt.contains("Visible finding") && prompt.contains("[image image/png]"))
  let messages = AgentSmartContextPrompt.messages(brief: "Inspect the attachment", from: original)
  #expect(messages.count == 3 && messages[0] == original[0])
  #expect(messages[1].content == [.text("Inspect the attachment"), attachment])
  #expect(messages[2] == original[1])
}

@Test("Smart mode and its independent prompt persist and validate")
func smartContextConfiguration() async throws {
  let agent = AgentDefinition(
    id: "main", instructions: "", provider: "hello", model: "hello", context: .smart)
  let config = MaiConfiguration(
    providers: [.init(id: "hello", kind: .hello)], agents: [agent],
    prompts: .init(compact: "Compact {{transcript}}", smart: "Smart {{transcript}}"))
  try config.validate()
  let decoded = try JSONDecoder().decode(MaiConfiguration.self, from: config.encoded())
  #expect(decoded == config)
  var invalid = config
  invalid.prompts?.smart = "Missing evidence"
  #expect(throws: MaiConfigurationError.self) { try invalid.validate() }
  let runtime = AgentRuntime()
  let auxiliary = try await runtime.taskRequest(
    .compact,
    from: AgentRequest(
      provider: "hello", messages: [], context: .smart))
  #expect(auxiliary.context == .cache)
}

@Test(
  "Smart context forwards invoked skill instructions verbatim after later tools",
  arguments: [false, true], [false, true])
func smartContextSkills(textProtocol: Bool, proxied: Bool) async throws {
  let skill = AgentSkill(
    name: "stamp", description: "Make a stamp",
    directoryURL: URL(fileURLWithPath: "/tmp/skills/stamp"),
    body: String(repeating: "Keep every exact step.\n", count: 250) + "Answer exactly STAMP SAVED.")
  let details: JSONValue = .object(["arguments": .string("input.txt")])
  let load = ToolCall(
    id: "load", name: proxied ? ToolProxy.callName : skill.toolName,
    arguments: proxied ? .object(["name": .string(skill.toolName), "arguments": details]) : details)
  let read = ToolCall(id: "read", name: "read", arguments: .object([:]))
  let primary = SmartContextProvider(
    id: "primary",
    responses: [load, read].map { call in
      ProviderResponse(
        message: textProtocol
          ? .assistant(
            "{\"tool\":\"\(call.name)\",\"arguments\":\(call.arguments.compactJSONString)}")
          : AgentMessage(role: .assistant, content: [.toolCall(call)]))
    } + [.init(message: .assistant("STAMP SAVED"))])
  let compact = SmartContextProvider(
    id: "compact",
    responses: (0..<3).map { _ in
      .init(message: .assistant("Make a stamp; the brief omits all skill steps."))
    })
  let runtime = try await smartRuntime(primary, compact)
  try await runtime.register(tool: MaiSkillTools.makeTool(for: skill) { .init(skills: [skill]) })
  try await runtime.register(
    tool: ClosureTool(
      definition: .init(
        name: "read", description: "Read", annotations: .init(approval: .automatic))
    ) { _, _ in
      ToolOutput(text: "payload")
    })
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", messages: [.user("Produce a checked stamp")],
      toolNames: [skill.toolName, "read"], toolCallingStrategy: textProtocol ? .json : .native,
      useToolProxy: proxied,
      retry: .none, autocompact: .init(tokens: 0), context: .smart))
  #expect(result.toolCalls == 2)
  let requests = await primary.requests
  try #require(requests.count == 3)
  #expect(
    requests.dropFirst().allSatisfy { request in
      request.messages.contains { $0.text.contains(skill.prompt(arguments: "input.txt")) }
    })
  #expect(!requests[0].messages.contains { $0.text.contains(skill.body) })
  #expect(result.transcript.flatMap(\.toolResults).first?.text.contains(skill.body) == true)
  #expect(requests.dropFirst().allSatisfy { request in
    let bodies = request.messages.filter { $0.text.contains(skill.body) }
    return bodies.count == 1 && bodies.first?.role == .system
  })
  let preparations = await compact.requests
  #expect(preparations.allSatisfy { request in
    let input = request.messages.map(\.text).joined(separator: "\n")
    return !input.contains(skill.body) && !input.contains(MaiSkillTools.promptSection)
      && !input.contains("Tools are available through")
  })
  #expect(preparations[1].messages.last?.text.contains("input.txt") == true)
}

@Test("Smart context keeps an explicit skill prompt and its arguments verbatim")
func smartContextSkillPrompt() {
  let skill = AgentSkill(
    name: "stamp", description: "Make a stamp",
    directoryURL: URL(fileURLWithPath: "/tmp/skills/stamp"), body: "Answer exactly STAMP SAVED.")
  let prompt = skill.prompt(arguments: "Use the literal value $418 and preserve all spacing.")
  let messages = AgentSmartContextPrompt.messages(brief: "A lossy brief", from: [.user(prompt)])
  #expect(messages.contains { $0.text.contains(prompt) })
  #expect(messages.contains { $0.text.contains("A lossy brief") })
  #expect(messages.filter { $0.text.contains(skill.body) }.map(\.role) == [.system])
  #expect(messages.last?.text.contains("Use the literal value $418 and preserve all spacing.") == true)
  let rendered = AgentSmartContextPrompt.render(messages: [.user(prompt)])
  #expect(!rendered.contains(skill.body))
  #expect(rendered.contains("Use the literal value $418 and preserve all spacing."))
  let ordinary = AgentSmartContextPrompt.messages(
    brief: "Next task", from: [.user(prompt), .assistant("Done"), .user("Unrelated task")])
  #expect(!ordinary.contains { $0.text.contains(prompt) })
}

@Test(
  "Automatic compaction retains current skill exchanges, including sibling tool results",
  arguments: [false, true])
func smartContextSkillCompaction(proxied: Bool) throws {
  let skill = ToolCall(
    id: "skill", name: proxied ? ToolProxy.callName : "skills_stamp",
    arguments: proxied
      ? .object(["name": .string("skills_stamp"), "arguments": .object([:])]) : .object([:]))
  let sibling = ToolCall(id: "sibling", name: "read", arguments: .object([:]))
  let load = AgentMessage(role: .assistant, content: [.toolCall(skill), .toolCall(sibling)])
  let skillResult = AgentMessage(
    role: .tool,
    content: [
      .toolResult(
        .init(
          callID: skill.id,
          text: String(repeating: "EXACT SKILL STEP\n", count: 300)))
    ])
  let siblingResult = AgentMessage(
    role: .tool, content: [.toolResult(.init(callID: sibling.id, text: "payload"))])
  var messages = [AgentMessage.user("Make a stamp"), load, skillResult, siblingResult]
  for index in 0..<5 {
    let call = ToolCall(id: "read-\(index)", name: "read", arguments: .object([:]))
    messages.append(AgentMessage(role: .assistant, content: [.toolCall(call)]))
    messages.append(
      AgentMessage(
        role: .tool,
        content: [
          .toolResult(
            .init(
              callID: call.id,
              text: String(repeating: "Other large evidence\n", count: 400)))
        ]))
  }
  let ids = try #require(AgentAutocompaction.selection(in: messages, preservingRecentTokens: 0))
  #expect(
    !ids.contains(load.id) && !ids.contains(skillResult.id) && !ids.contains(siblingResult.id))
  let applied = AgentTranscriptEditor.apply(
    [.compact(messageIDs: ids, summary: "Lossy summary")], to: messages)
  #expect([load, skillResult, siblingResult].allSatisfy { applied.messages.contains($0) })
  #expect(
    AgentSmartContextPrompt.messages(brief: "Brief", from: applied.messages)
      .contains { $0.text.contains(skillResult.toolResults[0].text) })
  #expect(AgentSmartContextPrompt.messages(brief: "Empty", from: []).last?.text == "Empty")
  let error = AgentMessage(
    role: .tool, content: [.toolResult(.init(callID: skill.id, text: "Unavailable", isError: true))]
  )
  #expect(AgentSkillContext.instructions(in: [.user("Work"), load, error]) == nil)
}

private func smartRuntime(_ primary: SmartContextProvider, _ compact: SmartContextProvider)
  async throws -> AgentRuntime
{
  let runtime = AgentRuntime()
  try await runtime.register(primary)
  try await runtime.register(compact)
  try await runtime.register(
    agent: AgentDefinition(
      id: "summarizer", instructions: "Summarize accurately", provider: "compact", model: "tiny",
      retry: .none))
  await runtime.configureTaskAgents(.init(compact: "summarizer"))
  return runtime
}

private actor SmartContextProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  var responses: [ProviderResponse]
  private(set) var requests: [ProviderRequest] = []

  init(id: ProviderID, responses: [ProviderResponse]) {
    descriptor = ProviderDescriptor(
      id: id, displayName: id.rawValue, capabilities: [.nativeToolCalling])
    self.responses = responses
  }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    guard !responses.isEmpty else { throw SmartFixtureError.unexpectedCall }
    return responses.removeFirst()
  }
}

private enum SmartFixtureError: Error { case unexpectedCall }
