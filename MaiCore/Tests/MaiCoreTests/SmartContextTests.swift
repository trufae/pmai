import Foundation
import Testing

@testable import MaiCore

@Test(
  "Small smart tasks keep full evidence without any context-generation calls",
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
  #expect(result.usage?.totalTokens == 30)
  #expect(Array(result.transcript.prefix(original.count)) == original)
  #expect(result.transcript.flatMap(\.toolResults).first?.text == evidence)
  #expect(!result.transcript.contains { $0.text.contains("working brief") })
  let requests = await primary.requests
  try #require(requests.count == 2)
  #expect(
    requests.map { $0.messages.filter { $0.role == .user }.map(\.text) }
      == Array(repeating: ["Fix the failing test", "Keep the API stable"], count: 2))
  #expect(
    requests.allSatisfy { request in
      request.messages.contains(original[1])
        && request.messages.contains { $0.role == .system && $0.text.contains(original[0].text) }
        && request.model == "frontier" && request.sessionID == "same-session"
    })
  #expect(requests.allSatisfy { $0.tools.isEmpty == textProtocol })
  let preparations = await compact.requests
  #expect(preparations.isEmpty)
  #expect(requests[1].messages.flatMap(\.toolResults).first?.text == evidence)
  #expect(requests[1].messages.flatMap(\.toolResults).first?.structuredContent == .object(["status": .string("tail-status")]))
  #expect(await stats.totals().count == 1)
}

@Test("Large working context keeps new source code and tool pairs verbatim",
  arguments: [AgentContextMode.smart, .adaptive])
func smartContextLargeHistory(mode: AgentContextMode) async throws {
  let call = ToolCall(id: "read", name: "read", arguments: .object([:]))
  let evidence = "EXACT CODE: if (!v) return false;"
  let primary = SmartContextProvider(id: "primary", responses: [
    .init(message: AgentMessage(role: .assistant, content: [.toolCall(call)])),
    .init(message: .assistant("Concrete finding")),
  ])
  let compact = SmartContextProvider(id: "compact", responses: [
    .init(message: .assistant("Earlier evidence brief"), usage: .estimated(inputTokens: 20, outputTokens: 5)),
  ])
  let runtime = try await smartRuntime(primary, compact)
  await runtime.configureSmartContext(prompt: "SMART TEMPLATE\n{{transcript}}")
  try await runtime.register(tool: ClosureTool(definition: .init(
    name: "read", description: "Read code", annotations: .init(approval: .automatic))) { _, _ in
    ToolOutput(text: evidence)
  })
  let original: [AgentMessage] = [
    .system("STATIC RULE"), .developer("DEVELOPER RULE"),
    .user("Earlier goal"), .assistant(String(repeating: "Earlier evidence.\n", count: 5_600)),
    .user("Find bugs; do not edit files"),
  ]
  let result = try await runtime.run(AgentRequest(
    provider: "primary", model: "frontier", messages: original, toolNames: ["read"],
    retry: .none, autocompact: .init(tokens: 0), context: mode, sessionID: "large-history"))
  #expect(result.response.text == "Concrete finding")
  #expect(Array(result.transcript.prefix(original.count)) == original)
  let preparations = await compact.requests
  try #require(preparations.count == 1)
  #expect(preparations[0].model == "tiny" && preparations[0].tools.isEmpty && !preparations[0].stream)
  let prompt = preparations[0].messages.map(\.text).joined(separator: "\n")
  #expect(prompt.contains("SMART TEMPLATE") && prompt.contains(original[3].text))
  #expect(prompt.contains(original[4].text) && !prompt.contains(evidence))
  #expect(!prompt.contains("STATIC RULE") && !prompt.contains("DEVELOPER RULE"))
  let requests = await primary.requests
  try #require(requests.count == 2)
  #expect(requests.allSatisfy { $0.messages.contains(original[4]) })
  if mode == .smart {
    #expect(requests.allSatisfy { $0.messages.contains(original[2]) })
  }
  #expect(requests.allSatisfy { $0.messages.contains { $0.text.contains("Earlier evidence brief") } })
  #expect(!requests[0].messages.contains(original[3]))
  #expect(requests[1].messages.flatMap(\.toolCalls) == [call])
  #expect(requests[1].messages.flatMap(\.toolResults).first?.text == evidence)
  let diagnostics = runtime.diagnosticHistory.records(sessionID: "large-history")
  #expect(diagnostics.filter { $0.kind == "model.request" }.count == 3)
  let summary = try #require(diagnostics.first { $0.kind == "model.response" && $0.purpose == "working-context" })
  #expect(summary.value.objectValue?["summary"] == .string("Earlier evidence brief"))
  #expect(summary.value.objectValue?["usageEstimated"] == .bool(true))
  let reduction = try #require(diagnostics.first { $0.kind == "context.reduction" })
  #expect(reduction.operationID == summary.operationID)
  #expect(reduction.value.objectValue?["outcome"] == .string("applied"))
  #expect(diagnostics.contains { $0.kind == "compaction.completed" && $0.operationID == summary.operationID })
}

@Test("Adaptive keeps medium histories intact when the context window is unknown")
func adaptiveDefersCompactionDuringToolWork() async throws {
  let call = ToolCall(id: "read", name: "read", arguments: .object([:]))
  let primary = SmartContextProvider(id: "primary", responses: [
    .init(message: AgentMessage(role: .assistant, content: [.toolCall(call)])),
    .init(message: .assistant("done")),
  ])
  let compact = SmartContextProvider(id: "compact", responses: [])
  let runtime = try await smartRuntime(primary, compact)
  try await runtime.register(tool: ClosureTool(definition: .init(
    name: "read", description: "Read code", annotations: .init(approval: .automatic))) { _, _ in
      ToolOutput(text: "fresh tool result")
    })
  let oldEvidence = AgentMessage.assistant(String(repeating: "evidence ", count: 7_000))
  let result = try await runtime.run(AgentRequest(
    provider: "primary", model: "frontier",
    messages: [.user("Earlier task"), oldEvidence, .user("Continue")], toolNames: ["read"],
    retry: .none))
  #expect(result.response.text == "done")
  #expect(await compact.requests.isEmpty)
  let requests = await primary.requests
  #expect(requests.count == 2)
  #expect(requests.allSatisfy { $0.messages.contains(oldEvidence) })
}

@Test("Working context reuses a weak brief or failed attempt across small tool results",
  arguments: [AgentContextMode.smart, .adaptive], [false, true])
func smartContextWaitsForMoreEvidence(mode: AgentContextMode, failed: Bool) async throws {
  let calls = ["first", "second", "third"].map { id in
    ToolCall(id: id, name: "read", arguments: .object(["file": .string(id)]))
  }
  let primary = SmartContextProvider(id: "primary", responses: calls.map { call in
    .init(message: AgentMessage(role: .assistant, content: [.toolCall(call)]))
  } + [.init(message: .assistant("done"))])
  let compact = SmartContextProvider(id: "compact", responses: failed ? [] : [
    .init(message: .assistant("Saved earlier findings")),
  ])
  let runtime = try await smartRuntime(primary, compact)
  try await runtime.register(tool: ClosureTool(definition: .init(
    // Schemas alone can exceed the unknown-window trigger. A new small result
    // must not cause another summary that cannot reduce this fixed overhead.
    name: "read", description: String(repeating: "schema ", count: 15_000),
    annotations: .init(approval: .automatic))) { args, _ in
      ToolOutput(text: "Exact result: " + (args.objectValue?["file"]?.stringValue ?? ""))
    })
  let oldEvidence = AgentMessage.assistant(String(repeating: "evidence ", count: 4_500))
  // Fill the recent tail so a small next result moves only a small older
  // exchange into the selection. Otherwise the unchanged-selection guard
  // alone would conceal the repeated-summary regression.
  let smallExchanges = (0..<2).flatMap { index -> [AgentMessage] in
    let call = ToolCall(id: "earlier-\(index)", name: "read", arguments: .object([:]))
    return [AgentMessage(role: .assistant, content: [.toolCall(call)]),
      AgentMessage(role: .tool, content: [.toolResult(.init(callID: call.id,
        text: String(repeating: "x", count: 122)))])]
  }
  let tailCharacters = mode == .smart ? 16_000 : 32_000
  let original = [AgentMessage.user("Earlier task"), oldEvidence, .user("Continue")]
    + smallExchanges + [.assistant(String(repeating: "r", count: tailCharacters - 256))]
  let result = try await runtime.run(AgentRequest(
    provider: "primary", model: "frontier",
    messages: original, toolNames: ["read"],
    retry: .none, context: mode, sessionID: "summary-attempt"))
  #expect(result.response.text == "done")
  #expect(result.toolCalls == 3)
  #expect(await compact.requests.count == 1)
  let requests = await primary.requests
  try #require(requests.count == 4)
  for (index, id) in ["first", "second", "third"].enumerated() {
    #expect(requests[index + 1].messages.flatMap(\.toolResults).contains { $0.text == "Exact result: " + id })
  }
  #expect(Array(result.transcript.prefix(original.count)) == original)
  let diagnostics = runtime.diagnosticHistory.records(sessionID: "summary-attempt")
  #expect(diagnostics.contains { $0.kind == "compaction.failed" } == failed)
  #expect(diagnostics.contains { $0.kind == "model.error" && $0.purpose == "working-context" } == failed)
  #expect(diagnostics.contains { $0.kind == "context.decision"
    && $0.value.objectValue?["reason"] == .string("waiting-for-new-evidence") })
}

@Test("Unknown-window pressure discovers a larger catalog window before summarizing",
  arguments: [AgentContextMode.smart, .adaptive])
func smartContextDiscoversWindow(mode: AgentContextMode) async throws {
  let primary = SmartContextProvider(id: "primary", responses: [.init(message: .assistant("done"))],
    models: [.init(id: "frontier", contextWindow: 131_072)])
  let compact = SmartContextProvider(id: "compact", responses: [])
  let runtime = try await smartRuntime(primary, compact)
  let messages = [AgentMessage.user("Earlier task"),
    .assistant(String(repeating: "evidence ", count: 12_000)), .user("Continue")]
  let result = try await runtime.run(AgentRequest(
    provider: "primary", model: "frontier", messages: messages, retry: .none, context: mode))
  #expect(result.response.text == "done")
  #expect(await compact.requests.isEmpty)
  #expect(await primary.requests.first?.messages.contains(messages[1]) == true)
}

@Test("Two truncated working summaries fall back only when the original request fits",
  arguments: [false, true])
func smartContextRepeatedSummaryCutoffs(requiresReduction: Bool) async throws {
  let primary = SmartContextProvider(id: "primary", responses: [.init(message: .assistant("done"))])
  let cutoff = ProviderResponse(message: .assistant(String(repeating: "partial ", count: 80)),
    stopReason: .length)
  let summary = ProviderResponse(message: .assistant("Usable summary"), stopReason: .stop)
  let compact = SmartContextProvider(id: "compact", responses: [cutoff, cutoff] + Array(repeating: summary, count: 12))
  let runtime = try await smartRuntime(primary, compact)
  let oldEvidence = AgentMessage.assistant(String(repeating: "evidence ", count: 4_600))
  let original = [AgentMessage.user("Earlier task"), oldEvidence, .user("Continue")]
  let result = try await runtime.run(AgentRequest(
    provider: "primary", model: "frontier", messages: original,
    options: .init(maxOutputTokens: 768, contextWindowTokens: requiresReduction ? 12_000 : 16_000),
    retry: .none, autocompact: .init(tokens: 0), context: .adaptive))
  #expect(result.response.text == "done")
  #expect(Array(result.transcript.prefix(original.count)) == original)
  let acting = try #require(await primary.requests.first)
  #expect(acting.messages.contains(oldEvidence) == !requiresReduction)
  if requiresReduction {
    #expect(await compact.requests.count > 2)
    #expect(acting.messages.contains { $0.text.contains("Usable summary") })
  } else {
    #expect(await compact.requests.count == 2)
  }
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
      .init(message: .assistant("durable summary")),
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
  try #require(preparations.count == 1)
  #expect(preparations[0].messages.last?.text.contains("Compact the transcript") == true)
  #expect(result.transcript.contains { $0.text.contains("durable summary") })
  #expect(result.transcript.contains(original[0]))
  #expect(!result.transcript.contains { $0.text == "brief one" || $0.text == "brief two" })
}

@Test("A large newest tool result reaches the acting model without summarization")
func smartContextLargeNewestResult() async throws {
  let call = ToolCall(id: "read", name: "read", arguments: .object([:]))
  let evidence = String(repeating: "source code\n", count: 8_000) + "EXACT TAIL"
  let primary = SmartContextProvider(id: "primary", responses: [
    .init(message: AgentMessage(role: .assistant, content: [.toolCall(call)])),
    .init(message: .assistant("Reviewed")),
  ])
  let compact = SmartContextProvider(id: "compact", responses: [])
  let runtime = try await smartRuntime(primary, compact)
  try await runtime.register(tool: ClosureTool(definition: .init(
    name: "read", description: "Read", annotations: .init(approval: .automatic))) { _, _ in
    ToolOutput(text: evidence)
  })
  _ = try await runtime.run(AgentRequest(
    provider: "primary", messages: [.user("Review source")], toolNames: ["read"],
    retry: .none, autocompact: .init(tokens: 0), context: .smart))
  #expect(await compact.requests.isEmpty)
  #expect(await primary.requests.last?.messages.flatMap(\.toolResults).first?.text == evidence)
}

@Test("Queued corrections invalidate a cached smart brief and retain exact task and tool evidence")
func smartContextQueuedCorrection() async throws {
  let call = ToolCall(id: "read", name: "read", arguments: .object([:]))
  let primary = SmartContextProvider(id: "primary", responses: [
    .init(message: AgentMessage(role: .assistant, content: [.toolCall(call)])),
    .init(message: .assistant("Corrected answer")),
  ])
  let compact = SmartContextProvider(id: "compact", responses: [
    .init(message: .assistant("Stale brief")), .init(message: .assistant("Corrected brief")),
  ])
  let runtime = try await smartRuntime(primary, compact)
  let supervisor = runtime.supervisor
  let correction = AgentMessage.user("Focus on memory safety instead")
  try await runtime.register(tool: ClosureTool(definition: .init(
    name: "read", description: "Read", annotations: .init(approval: .automatic))) { _, context in
    await supervisor.post(correction, to: try #require(context.run.pid))
    return ToolOutput(text: "Exact new code")
  })
  let task = AgentMessage.user("Review the requested code")
  _ = try await runtime.run(AgentRequest(
    provider: "primary", messages: [.user("Old task"), .assistant(String(repeating: "old ", count: 20_000)), task],
    toolNames: ["read"], retry: .none, autocompact: .init(tokens: 0), context: .smart))
  #expect(await compact.requests.count == 2)
  let next = try #require(await primary.requests.last)
  #expect(next.messages.contains(task) && next.messages.contains(correction))
  #expect(!next.messages.contains { $0.text.contains("Stale brief") })
  #expect(next.messages.contains { $0.text.contains("Corrected brief") })
  #expect(next.messages.flatMap(\.toolResults).first?.text == "Exact new code")
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
  let original = [AgentMessage.user("Earlier goal"), .assistant(String(repeating: "old ", count: 20_000)), .user("Do the work")]
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
  "An empty or failed smart preparation keeps evidence and still answers",
  arguments: [false, true])
func smartContextFailure(empty: Bool) async throws {
  let call = ToolCall(id: "read", name: "read", arguments: .object([:]))
  let primary = SmartContextProvider(id: "primary", responses: [
    .init(message: AgentMessage(role: .assistant, content: [.toolCall(call)])),
    .init(message: .assistant("Done")),
  ])
  let compact = SmartContextProvider(
    id: "compact", responses: empty ? [.init(message: .assistant("  "))] : [])
  let runtime = try await smartRuntime(primary, compact)
  try await runtime.register(tool: ClosureTool(definition: .init(
    name: "read", description: "Read", annotations: .init(approval: .automatic))) { _, _ in
    ToolOutput(text: "new evidence")
  })
  let original = [AgentMessage.user("Earlier goal"), .assistant(String(repeating: "old ", count: 20_000)), .user("Work")]
  let result = try await runtime.run(AgentRequest(
    provider: "primary", messages: original, toolNames: ["read"],
    retry: .none, autocompact: .init(tokens: 0), context: .smart))
  #expect(result.response.text == "Done")
  #expect(await primary.requests.count == 2)
  #expect(await primary.requests.allSatisfy { $0.messages.contains(original[1]) })
  #expect(Array(result.transcript.prefix(original.count)) == original)
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

@Test("Context defaults to adaptive; explicit smart mode and its prompt persist and validate")
func smartContextConfiguration() async throws {
  #expect(AgentDefinition(id: "main", instructions: "", provider: "hello", model: "hello").context == .adaptive)
  #expect(AgentRequest(provider: "hello", messages: []).context == .adaptive)
  let legacy = Data(#"{"id":"main","provider":"hello"}"#.utf8)
  #expect(try JSONDecoder().decode(AgentDefinition.self, from: legacy).context == .adaptive)
  let explicit = Data(#"{"id":"main","provider":"hello","context":"cache"}"#.utf8)
  #expect(try JSONDecoder().decode(AgentDefinition.self, from: explicit).context == .cache)
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
  "Every context and protocol forwards direct and proxied skill instructions after later tools",
  arguments: [AgentContextMode.cache, .size, .smart, .tools, .adaptive].flatMap { context in
    [ToolCallingStrategy.native, .json, .xml, .text].flatMap { strategy in
      [false, true].map { (context, strategy, $0) }
    }
  })
func smartContextSkills(fixture: (AgentContextMode, ToolCallingStrategy, Bool)) async throws {
  let (context, strategy, proxied) = fixture
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
      let arguments = call.arguments.objectValue ?? [:]
      let fields = arguments.sorted { $0.key < $1.key }.map { key, value in
        (key, value.stringValue ?? value.compactJSONString)
      }
      let message: AgentMessage
      switch strategy {
      case .off, .native, .automatic:
        message = AgentMessage(role: .assistant, content: [.toolCall(call)])
      case .json:
        message = .assistant(
          "{\"tool\":\"\(call.name)\",\"arguments\":\(call.arguments.compactJSONString)}")
      case .xml:
        message = .assistant(
          "<tool_call name=\"\(call.name)\">"
            + fields.map { "<arg name=\"\($0.0)\">\(AgentTooling.xmlEscapedAttribute($0.1))</arg>" }.joined()
            + "</tool_call>")
      case .text:
        message = .assistant("TOOL_CALL\ntool: \(call.name)\n"
          + fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\nEND_TOOL_CALL")
      }
      return ProviderResponse(message: message)
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
      toolNames: [skill.toolName, "read"], toolCallingStrategy: strategy,
      useToolProxy: proxied,
      retry: .none, autocompact: .init(tokens: 0), context: context))
  #expect(result.response.text == "STAMP SAVED")
  #expect(result.toolCalls == 2)
  let requests = await primary.requests
  try #require(requests.count == 3)
  #expect(
    requests.dropFirst().allSatisfy { request in
      request.messages.contains { $0.text.contains(skill.prompt(arguments: "input.txt")) }
    })
  #expect(!requests[0].messages.contains { $0.text.contains(skill.body) })
  #expect(requests.allSatisfy { request in
    request.messages.contains { $0.role == .user && $0.text.contains("Produce a checked stamp") }
  })
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
  #expect(preparations.isEmpty)
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
      options: .init(contextWindowTokens: 128_000),
      retry: .none))
  await runtime.configureTaskAgents(.init(compact: "summarizer"))
  return runtime
}

private actor SmartContextProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  var responses: [ProviderResponse]
  let models: [ModelDescriptor]
  private(set) var requests: [ProviderRequest] = []

  init(id: ProviderID, responses: [ProviderResponse], models: [ModelDescriptor] = []) {
    descriptor = ProviderDescriptor(
      id: id, displayName: id.rawValue, capabilities: [.nativeToolCalling])
    self.responses = responses
    self.models = models
  }

  func availableModels() async throws -> [ModelDescriptor] { models }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    guard !responses.isEmpty else { throw SmartFixtureError.unexpectedCall }
    return responses.removeFirst()
  }
}

private enum SmartFixtureError: Error { case unexpectedCall }
