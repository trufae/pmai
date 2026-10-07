import Foundation
import Testing

@testable import MaiCore

@testable import MaiTestSupport

@Test("Provider default model fills an empty model but keeps explicit selections")
func providerDefaultModelInference() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(message: .assistant("Default"), stopReason: .stop),
      ProviderResponse(message: .assistant("Explicit"), stopReason: .stop),
    ], defaultModel: "provider-default")
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  _ = try await runtime.run(AgentRequest(
    provider: "scripted", model: "", messages: [.user("Use default")]))
  _ = try await runtime.run(AgentRequest(
    provider: "scripted", model: "chosen", messages: [.user("Use chosen")]))
  #expect(await provider.requests.map(\.model) == ["provider-default", "chosen"])
}

@Test("Registered skills are only visible and callable when enabled for the agent", arguments: [false, true])
func skillToolAvailability(enabled: Bool) async throws {
  let skill = AgentSkill(
    name: "review", description: "Review code.",
    directoryURL: URL(fileURLWithPath: "/skills/review"), body: "Read AGENTS.md first.")
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(role: .assistant, content: [
        .toolCall(ToolCall(id: "skill", name: skill.toolName, arguments: .object([:])))
      ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("Done"), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: MaiSkillTools.makeTool(for: skill) {
    AgentSkillCatalog(skills: [skill])
  })
  let result = try await runtime.run(AgentRequest(
    provider: "scripted", model: "fixture", messages: [.user("Review the project")],
    toolNames: enabled ? [skill.toolName] : [], toolGroupNames: []))
  let request = try #require(await provider.requests.first)
  #expect(request.tools.contains { $0.name == skill.toolName } == enabled)
  #expect(!request.messages.contains { $0.text.contains(skill.directoryURL.path) })
  let output = try #require(result.transcript.flatMap(\.toolResults).first)
  #expect(output.isError == !enabled)
  #expect(output.text.contains(skill.body) == enabled)
  if !enabled { #expect(output.text.contains("not available to this agent")) }
}

@Test("Structured messages preserve multimodal and tool content")
func structuredMessageRoundTrip() throws {
  var message = AgentMessage(
    id: "message-1",
    role: .user,
    content: [
      .text("inspect"),
      .image(
        ImageContent(
          source: .data(Data([0x01, 0x02])),
          mimeType: "image/png",
          name: "sample.png")),
      .file(FileContent(name: "notes.txt", mimeType: "text/plain", text: "notes")),
      .toolResult(ToolResult(callID: "call-1", text: "done")),
    ])
  message.appendText("more context")

  let data = try JSONEncoder().encode(message)
  #expect(try JSONDecoder().decode(AgentMessage.self, from: data) == message)
  #expect(message.text == "inspect\n\nmore context\nnotes")
  #expect(message.imageInputCount == 1)
}

@Test("Tool proxy searches and resolves the shared catalog")
func toolProxyResolution() throws {
  let definitions = [
    ToolDefinition(
      name: "weather",
      description: "Look up a forecast.",
      parameters: [
        ToolParameterDef(name: "city", type: "string", description: "City name.", required: true)
      ])
  ]
  let listing = ToolProxy.listTools(
    arguments: ["keywords": .string("forecast")], definitions: definitions)
  #expect(listing.contains("weather"))

  let resolved = ToolProxy.resolveCall(
    arguments: ["name": .string("weather"), "arguments": .object(["city": .string("Rome")])],
    definitions: definitions)
  #expect(resolved.error == nil)
  #expect(resolved.call?.name == "weather")
  #expect(resolved.call?.argumentValues["city"] == .string("Rome"))
}

@Test("JSON values render with sorted keys so a repeated message is byte-identical")
func compactJSONSortsKeys() {
  let value = JSONValue.object([
    "workspace": .string("w"), "entries": .array([.integer(1)]), "path": .string("."),
  ])
  #expect(value.compactJSONString == #"{"entries":[1],"path":".","workspace":"w"}"#)
}

@Test("Tool proxy names its catalog and caps a broad listing")
func toolProxyCatalogAndCap() {
  let catalog = (1...9).map { index in
    ToolDefinition(
      name: "files_op\(index)",
      description: "Work with files, operation \(index).",
      parameters: [
        ToolParameterDef(name: "path", type: "string", description: "A file path.", required: true)
      ])
  }
  let definitions = ToolProxy.definitions(for: catalog)
  #expect(definitions.map(\.name) == [ToolProxy.listName, ToolProxy.callName])
  #expect(
    definitions[0].description.contains(
      "files_op1 (Work with files, operation 1); files_op2 (Work with files, operation 2)"))
  #expect(ToolProxy.definitions.first?.description.contains("They are:") == false)

  // Hybrid: the common tools stay native, the rest sit behind the two proxy tools.
  let hybridCatalog = [
    ToolDefinition(name: "files_read", description: "Read a text file. PDF and DOCX are converted."),
    ToolDefinition(name: "weather", description: "Look up a forecast; needs a city."),
  ]
  let hybrid = ToolProxy.definitions(for: hybridCatalog)
  #expect(hybrid.map(\.name) == ["files_read", ToolProxy.listName, ToolProxy.callName])
  #expect(hybrid[1].description.contains("weather (Look up a forecast)"))
  #expect(!hybrid[1].description.contains("files_read"))
  #expect(
    ToolProxy.definitions(for: hybridCatalog, exposing: []).map(\.name)
      == [ToolProxy.listName, ToolProxy.callName])
  #expect(
    ToolProxy.definitions(for: hybridCatalog, exposing: ["files_read", "weather"]).map(\.name)
      == ["files_read", "weather"])

  let listing = ToolProxy.listTools(arguments: ["keywords": .string("files")], definitions: catalog)
  let detailed = listing.components(separatedBy: "\n").filter { $0.hasPrefix("- files_op") }
  #expect(detailed.count == ToolProxy.detailedMatches)
  #expect(listing.contains("named only: files_op7, files_op8, files_op9."))

  // A term in the name ranks above the same term in a description.
  let mixed = [
    ToolDefinition(name: "web_fetch", description: "Read a page."),
    ToolDefinition(name: "files_read", description: "Fetch nothing; read a file."),
  ]
  let ranked = ToolProxy.listTools(arguments: ["keywords": .string("read")], definitions: mixed)
  #expect(ranked.hasPrefix("- files_read"))
}

@Test("Tool proxy unwraps a call envelope nested inside the arguments")
func toolProxyNestedEnvelope() {
  let definitions = [
    ToolDefinition(
      name: "files_read", description: "Read.",
      parameters: [
        ToolParameterDef(name: "path", type: "string", description: "Path.", required: true)
      ])
  ]
  let resolved = ToolProxy.resolveCall(
    arguments: [
      "name": .string("files_read"),
      "arguments": .object([
        "name": .string("files_read"), "arguments": .object(["path": .string("cli.py")]),
      ]),
    ],
    definitions: definitions)
  #expect(resolved.error == nil)
  #expect(resolved.call?.argumentValues["path"] == .string("cli.py"))

  // The name only inside the arguments object, nothing beside it.
  let inside = ToolProxy.resolveCall(
    arguments: [
      "arguments": .object([
        "name": .string("files_read"), "arguments": .object(["path": .string("b.py")]),
      ])
    ],
    definitions: definitions)
  #expect(inside.error == nil)
  #expect(inside.call?.name == "files_read")
  #expect(inside.call?.argumentValues["path"] == .string("b.py"))
}

@Test("A call repeated past the identical-call guard withdraws the tools and forces an answer")
func repeatedCallWithdrawsTools() async throws {
  let same = ProviderResponse(
    message: AgentMessage(
      role: .assistant,
      content: [.toolCall(ToolCall(id: "c", name: "probe", arguments: .object([:])))]),
    stopReason: .toolCall)
  let provider = ScriptedProvider(
    responses: Array(repeating: same, count: 5)
      + [ProviderResponse(message: .assistant("Stuck; here is what I have."), stopReason: .stop)])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "probe", description: "Probe")) { _, _ in
      ToolOutput(text: "Error: nope", isError: true)
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("probe until it works")],
      toolNames: ["probe"]))

  #expect(result.response.text == "Stuck; here is what I have.")
  let requests = await provider.requests
  #expect(requests.count == 6)
  // The fourth identical call trips the guard; the fifth turn is offered no tools.
  #expect(!requests[3].tools.isEmpty)
  #expect(requests[4].tools.isEmpty)
  #expect(requests[4].messages.contains { $0.text.contains("made no progress") })
  #expect(result.transcript.contains { $0.toolResults.contains { $0.text.contains("already run 3 times") } })
}

@Test("A run's session id reaches every provider request it makes")
func sessionIDReachesProviderRequests() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("done"), stopReason: .stop)
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)

  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted", model: "fixture", messages: [.user("hi")], sessionID: "chat-1"))

  let requests = await provider.requests
  #expect(requests.map(\.sessionID) == ["chat-1"])
}

@Test("Tool result previews show the text first, bound lines and length, and strip control characters")
func toolResultPreview() {
  let result = ToolResult(
    callID: "preview",
    text: "first line\nsecond\u{1B}[31m line\nthird line\nfourth line")

  #expect(
    ToolResultPreview.render(result, maxLines: 2, maxLineLength: 12)
      == "← first line\n  second [31m …\n  … 2 more lines")
  #expect(ToolResultPreview.render(result, maxLines: 0) == "← done")
  let longLine = String(repeating: "x", count: 300)
  #expect(
    ToolResultPreview.render(
      ToolResult(callID: "complete", text: "one\ntwo\n\(longLine)"), maxLines: -1)
      == "← one\n  two\n  \(longLine)")
  #expect(
    ToolResultPreview.render(
      ToolResult(
        callID: "structured",
        content: [],
        structuredContent: .object(["ok": .bool(true)]),
        isError: true),
      maxLines: 1)
      == "← {\"ok\":true}")
  #expect(ToolResultPreview.render(ToolResult(callID: "e", text: "", isError: true), maxLines: 3) == "← error")
  #expect(ToolResultPreview.render(ToolResult(callID: "n", text: "  \n"), maxLines: 3) == "← (no output)")
}

@Test("Tool call previews name the tool and fold the arguments into one readable line")
func toolCallPreview() {
  #expect(
    ToolCallPreview.render(ToolCall(id: "1", name: "files_read", arguments: .object(["path": .string("cli.py")])))
      == "→ files_read cli.py")
  #expect(ToolCallPreview.render(ToolCall(id: "2", name: "files_list", arguments: .object([:]))) == "→ files_list")
  let patch = ToolCall(
    id: "3", name: "files_patch",
    arguments: .object([
      "replace": .string("return 0.5 * base * height"),
      "path": .string("shapes.py"),
      "find": .string("def area_of_triangle(base, height):\n    return base * height"),
    ]))
  #expect(
    ToolCallPreview.render(patch)
      == "→ files_patch path=shapes.py find=\"def area_of_triangle(base, height):\" (+1 lines) replace=\"return 0.5 * base * height\"")
  let long = ToolCall(
    id: "4", name: "files_write",
    arguments: .object(["path": .string("a.py"), "content": .string(String(repeating: "x", count: 200) + "\ny")]))
  let rendered = ToolCallPreview.render(long)
  #expect(rendered == "→ files_write path=a.py content=" + String(repeating: "x", count: 60) + "… (+1 lines)")
  #expect(ToolCallPreview.render(ToolCall(id: "5", name: "run_shell", arguments: .object(["script": .string("make -s && ./app")]))) == "→ run_shell \"make -s && ./app\"")
  #expect(ToolCallPreview.render(patch, maxLength: 20) == "→ files_patch path=s…")
}

@Test("Transcripts edit rich messages and preserve valid tool transactions")
func transcriptEditing() throws {
  let messages = [
    AgentMessage(id: "system", role: .system, content: "Rules"),
    AgentMessage(
      id: "user",
      role: .user,
      content: [
        .text("original"),
        .image(ImageContent(source: .data(Data([0x01])), mimeType: "image/png")),
      ]),
    AgentMessage(
      id: "calls",
      role: .assistant,
      content: [
        .toolCall(ToolCall(id: "call-a", name: "a", arguments: .object([:]))),
        .toolCall(ToolCall(id: "call-b", name: "b", arguments: .object([:]))),
      ]),
    AgentMessage(
      id: "result-a",
      role: .tool,
      content: [.toolResult(ToolResult(callID: "call-a", text: "A"))]),
    AgentMessage(
      id: "result-b",
      role: .tool,
      content: [.toolResult(ToolResult(callID: "call-b", text: "B"))]),
    AgentMessage(id: "answer", role: .assistant, content: "Done"),
  ]
  var transcript = AgentTranscript(messages: messages)

  let previous = try transcript.editMessage(id: "user", text: "revised")
  #expect(previous.text == "original")
  #expect(transcript[1].text == "revised")
  #expect(transcript[1].content.contains { if case .image = $0 { true } else { false } })

  try transcript.editMessage(id: "result-a", text: "Edited tool result")
  #expect(transcript[3].toolResults.first?.text == "Edited tool result")

  let removed = try transcript.removeMessage(id: "result-a")
  #expect(Set(removed.map(\.id)) == ["calls", "result-a", "result-b"])
  #expect(transcript.messages.map(\.id) == ["system", "user", "answer"])

  let trimmed = try transcript.trim(throughMessageID: "user")
  #expect(trimmed.map(\.id) == ["answer"])
  #expect(transcript.messages.map(\.id) == ["system", "user"])
}

@Test("Trimming through an incomplete tool call removes the entire transaction")
func transcriptTrimToolBoundary() throws {
  var transcript = AgentTranscript(messages: [
    .user("question"),
    AgentMessage(
      id: "calls",
      role: .assistant,
      content: [.toolCall(ToolCall(id: "call", name: "lookup", arguments: .object([:])))]),
    AgentMessage(
      role: .tool,
      content: [.toolResult(ToolResult(callID: "call", text: "result"))]),
    .assistant("answer"),
  ])

  let removed = try transcript.trim(through: 1)
  #expect(removed.map(\.id).contains("calls"))
  #expect(transcript.messages.map(\.role) == [.user])
}

@Test("A registered provider runs through MaiCore and emits lifecycle events")
func registeredProviderRun() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let recorder = EventRecorder()

  let result = try await runtime.run(
    AgentRequest(provider: .hello, messages: [.user("world")])
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Hello from MaiCore: world")
  #expect(result.stopReason == .stop)
  #expect(result.transcript.count == 2)
  let events = await recorder.events
  #expect(events.count == 4)
  guard case .started(let context, let descriptor) = events[0] else {
    Issue.record("Expected started event")
    return
  }
  #expect(descriptor == HelloProvider().descriptor)
  #expect(events[1] == .modelStarted(context, turn: 1))
  #expect(events[2] == .provider(context, .textDelta("Hello from MaiCore: world")))
  #expect(events[3] == .finished(context, result))
}

@Test("Provider registration rejects duplicates and permits explicit replacement")
func providerRegistration() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  await #expect(throws: AgentRuntimeError.providerAlreadyRegistered(.hello)) {
    try await runtime.register(HelloProvider(prefix: "Replacement"))
  }
  try await runtime.register(
    HelloProvider(prefix: "Replacement"),
    replacingExisting: true)
  let result = try await runtime.run(
    AgentRequest(provider: .hello, messages: [.user("works")]))
  #expect(result.response.text == "Replacement: works")
}

@Test("Agent runtime validates, approves, executes, and continues after a tool call")
func toolLoop() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "call-1",
              name: "uppercase",
              arguments: .object(["text": .string("hello")])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("The result is HELLO."), stopReason: .stop),
  ])
  let approval = QueueApprovalHandler(decisions: [
    .approve(arguments: .object(["text": .string("changed")]))
  ])
  let observedArguments = JSONValueRecorder()
  let runtime = AgentRuntime(approvalHandler: approval)
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "uppercase",
        description: "Uppercase text",
        inputSchema: objectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .confirm))
    ) { arguments, _ in
      await observedArguments.record(arguments)
      return ToolOutput(text: arguments.objectValue?["text"]?.stringValue?.uppercased() ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("uppercase hello")],
      toolNames: ["uppercase"]))

  #expect(result.response.text == "The result is HELLO.")
  #expect(result.modelTurns == 2)
  #expect(result.toolCalls == 1)
  #expect(await observedArguments.value == .object(["text": .string("changed")]))
  #expect(result.transcript.flatMap(\.toolResults).first?.text == "CHANGED")
}

@Test("Denied approvals become tool results without executing the tool")
func deniedApproval() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [.toolCall(ToolCall(id: "c", name: "sensitive", arguments: .object([:])))]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Denied."), stopReason: .stop),
  ])
  let runtime = AgentRuntime(
    approvalHandler: QueueApprovalHandler(decisions: [.deny(reason: "test policy")]))
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "sensitive",
        description: "Sensitive",
        annotations: ToolAnnotations(approval: .dangerous))
    ) { _, _ in
      Issue.record("Denied tool must not execute")
      return ToolOutput(text: "unexpected")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("do it")],
      toolNames: ["sensitive"]))
  let toolResult = try #require(result.transcript.flatMap(\.toolResults).first)
  #expect(toolResult.isError)
  #expect(toolResult.text.contains("test policy"))
}

@Test("Agent runtime resolves proxied calls before approval and execution")
func proxiedToolLoop() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "proxy-1",
              name: ToolProxy.callName,
              arguments: .object([
                "name": .string("uppercase"),
                "arguments": .object(["text": .string("hello")]),
              ])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Proxied result received."), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "uppercase",
        description: "Uppercase text",
        inputSchema: objectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: arguments.objectValue?["text"]?.stringValue?.uppercased() ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("uppercase hello")],
      toolNames: ["uppercase"],
      useToolProxy: true))

  #expect(result.transcript.flatMap(\.toolResults).first?.text == "HELLO")
  let offered = await provider.requests.first?.tools ?? []
  #expect(offered.map(\.name) == [ToolProxy.listName, ToolProxy.callName])
  #expect(offered.first?.description.contains("They are: uppercase") == true)
}

@Test("Tool result events carry importance from the resolved definition", arguments: [false, true])
func toolResultImportanceThroughRuntime(proxied: Bool) async throws {
  let arguments: JSONValue = proxied
    ? .object(["name": .string("edit"), "arguments": .object([:])]) : .object([:])
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(role: .assistant, content: [
        .toolCall(ToolCall(
          id: "edit-1", name: proxied ? ToolProxy.callName : "edit", arguments: arguments))
      ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("Done."), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(
    definition: ToolDefinition(
      name: "edit", description: "Edit a file",
      annotations: ToolAnnotations(approval: .automatic, resultImportance: .important))
  ) { _, _ in ToolOutput(text: "header\ncontext\n-old\n+new") })
  let events = EventRecorder()
  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted", model: "fixture", messages: [.user("Edit the file")],
      toolNames: ["edit"], useToolProxy: proxied),
    emit: { await events.append($0) })
  #expect(result.transcript.flatMap(\.toolResults).first?.importance == .important)
  let eventResult = try #require(await events.events.compactMap { event -> ToolResult? in
    guard case .toolFinished(_, let result) = event else { return nil }
    return result
  }.first)
  #expect(eventResult.importance == .important)
  #expect(ToolResultPreview.render(eventResult, display: .relevant).hasSuffix("  +new"))
  let followup = try #require(await provider.requests.last)
  #expect(followup.messages.flatMap(\.toolResults).first?.text == "header\ncontext\n-old\n+new")
}

@Test("Providers without native tools use the JSON fallback without leaking protocol text")
func textToolFallback() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: .assistant("{\"tool\":\"echo\",\"arguments\":{\"text\":\"fallback\"}}"),
        stopReason: .stop),
      ProviderResponse(message: .assistant("Fallback complete."), stopReason: .stop),
    ],
    capabilities: [.streaming])
  let events = EventRecorder()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "echo",
        description: "Echo",
        inputSchema: objectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("use echo")],
      toolNames: ["echo"],
      toolCallingStrategy: .automatic)
  ) { event in
    await events.append(event)
  }

  #expect(result.response.text == "Fallback complete.")
  #expect(result.transcript.flatMap(\.toolResults).first?.text == "fallback")
  let requests = await provider.requests
  #expect(requests.first?.tools.isEmpty == true)
  #expect(requests.first?.stream == false)
  #expect(requests.first?.messages.contains { $0.text.contains("JSON fallback protocol") } == true)
  let leakedProtocol = await events.events.contains { event in
    if case .provider(_, .textDelta(let text)) = event { return text.contains("\"tool\"") }
    return false
  }
  #expect(!leakedProtocol)
}

@Test("Text, XML, and JSON strategies force the emulated tool loop")
func forcedTextToolStrategies() async throws {
  let cases: [(ToolCallingStrategy, String, String)] = [
    (
      .text,
      """
      TOOL_CALL
      tool: echo
      text: text
      END_TOOL_CALL
      """,
      "text"
    ),
    (.xml, #"<tool_call name="echo"><arg name="text">xml</arg></tool_call>"#, "xml"),
    (.json, #"{"name":"echo","arguments":{"text":"json"}}"#, "json"),
  ]

  for (strategy, call, expected) in cases {
    let provider = ScriptedProvider(
      responses: [
        ProviderResponse(message: .assistant(call), stopReason: .stop),
        ProviderResponse(message: .assistant("Finished \(expected)."), stopReason: .stop),
      ],
      capabilities: [.streaming, .nativeToolCalling])
    let runtime = AgentRuntime()
    try await runtime.register(provider)
    try await runtime.register(
      tool: ClosureTool(
        definition: ToolDefinition(
          name: "echo",
          description: "Echo",
          inputSchema: objectSchema(required: ["text"]),
          annotations: ToolAnnotations(approval: .automatic))
      ) { arguments, _ in
        ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
      })

    let result = try await runtime.run(
      AgentRequest(
        provider: "scripted",
        model: "fixture",
        messages: [.user("use echo")],
        toolNames: ["echo"],
        toolCallingStrategy: strategy))

    #expect(result.response.text == "Finished \(expected).")
    #expect(result.transcript.flatMap(\.toolResults).first?.text == expected)
    let requests = await provider.requests
    #expect(requests.first?.tools.isEmpty == true)
    #expect(
      requests.first?.messages.contains {
        $0.text.contains("\(strategy.rawValue.uppercased()) fallback protocol")
      } == true)
  }
}

@Test("Text fallback executes every tool call emitted in one model turn")
func multipleTextToolCalls() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: .assistant(
          """
          {"name":"echo","arguments":{"text":"one"}}
          {"name":"echo","arguments":{"text":"two"}}
          """),
        stopReason: .stop),
      ProviderResponse(message: .assistant("Both calls completed."), stopReason: .stop),
    ],
    capabilities: [.streaming])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "echo",
        description: "Echo",
        inputSchema: objectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("echo twice")],
      toolNames: ["echo"],
      toolCallingStrategy: .json))

  #expect(result.response.text == "Both calls completed.")
  #expect(result.toolCalls == 2)
  #expect(result.transcript.flatMap(\.toolResults).map(\.text) == ["one", "two"])
}

@Test("Text fallback can read again after a write and still produce a final answer")
func textToolReadAfterWrite() async throws {
  let read = ProviderResponse(message: .assistant(#"{"name":"read","arguments":{}}"#))
  let provider = ScriptedProvider(responses: [
    read,
    ProviderResponse(message: .assistant(#"{"name":"write","arguments":{}}"#)),
    read,
    ProviderResponse(message: .assistant("Verified the change."), stopReason: .stop),
  ])
  actor FileState {
    var text = "before"
    func write() { text = "after" }
  }
  let file = FileState()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(definition: ToolDefinition(
    name: "read", description: "Read", annotations: ToolAnnotations(readOnly: true, approval: .automatic)
  )) { _, _ in ToolOutput(text: await file.text) })
  try await runtime.register(tool: ClosureTool(definition: ToolDefinition(
    name: "write", description: "Write", annotations: ToolAnnotations(approval: .automatic)
  )) { _, _ in
    await file.write()
    return ToolOutput(text: "written")
  })
  let result = try await runtime.run(AgentRequest(
    provider: "scripted", model: "fixture", messages: [.user("edit and verify")],
    toolNames: ["read", "write"], toolCallingStrategy: .json))
  #expect(result.response.text == "Verified the change.")
  #expect(result.toolCalls == 3)
  #expect(result.transcript.flatMap(\.toolResults).map(\.text) == ["before", "written", "after"])
}

@Test("Text fallback repairs malformed turns and resolves respond without host execution")
func textToolRepairAndRespond() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: .assistant(#"{"name":"echo","arguments":{"text":"unfinished"}"#),
        stopReason: .stop),
      ProviderResponse(
        message: .assistant(
          #"{"name":"respond","arguments":{"action":"final","content":"Recovered."}}"#),
        stopReason: .stop),
    ],
    capabilities: [.streaming])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(name: "echo", description: "Echo")
    ) { _, _ in
      Issue.record("Repair and respond turns must not execute a host tool")
      return ToolOutput(text: "unexpected")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("recover")],
      toolNames: ["echo"],
      toolCallingStrategy: .json))

  #expect(result.response.text == "Recovered.")
  #expect(result.modelTurns == 2)
  #expect(result.toolCalls == 0)
  #expect(result.transcript.contains { $0.text.contains("Error:") })
  #expect(await provider.requests.first?.messages.contains { $0.text.contains("respond") } == true)
}

@Test("Repeated malformed text calls reach a bounded final turn")
func malformedTextCallsAreBounded() async throws {
  let malformed = ProviderResponse(message: .assistant(#"{"name":"echo","arguments":{"text":"unfinished"}"#))
  let provider = ScriptedProvider(responses: Array(repeating: malformed, count: 3) + [
    ProviderResponse(message: .assistant("Unable to call the tool."), stopReason: .stop)
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(
    definition: ToolDefinition(name: "echo", description: "Echo")
  ) { _, _ in
    Issue.record("Malformed calls must not execute")
    return ToolOutput(text: "unexpected")
  })
  let result = try await runtime.run(AgentRequest(
    provider: "scripted", model: "fixture", messages: [.user("echo")],
    toolNames: ["echo"], toolCallingStrategy: .json))
  #expect(result.modelTurns == 4)
  #expect(result.toolCalls == 0)
  #expect(result.response.text == "Unable to call the tool.")
  #expect(await provider.requests.last?.messages.contains { $0.text.contains("No tools are available") } == true)
}

@Test("Text fallback runs native tool calls a server parsed out of the model's own syntax")
func textToolAcceptsNativeCalls() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(id: "srv-1", name: "echo", arguments: .object(["text": .string("hi")])))
          ]),
        stopReason: .toolCall),
      ProviderResponse(message: .assistant("Echoed: hi"), stopReason: .stop),
    ],
    capabilities: [.streaming])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "echo", description: "Echo",
        parameters: [ToolParameterDef(name: "text", type: "string", description: "Text", required: true)])
    ) { arguments, _ in
      ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("echo hi")],
      toolNames: ["echo"],
      toolCallingStrategy: .text))

  #expect(result.response.text == "Echoed: hi")
  #expect(result.modelTurns == 2)
  #expect(result.toolCalls == 1)
  #expect(!result.transcript.contains { $0.text.contains("missing_tool_call") })
}

@Test("An empty reply after a tool result becomes repair feedback instead of retries and failure")
func emptyReplyAfterToolResultIsRepaired() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [.toolCall(ToolCall(id: "c1", name: "probe", arguments: .object([:])))]),
        stopReason: .toolCall),
      ProviderResponse(message: .assistant("Probed."), stopReason: .stop),
    ],
    failures: [1: EmptyReplyFailure()])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "probe", description: "Probe")) { _, _ in
      ToolOutput(text: "42")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("probe")],
      toolNames: ["probe"],
      retry: AgentRetryPolicy(attempts: 2, delaySeconds: 0)))

  #expect(result.response.text == "Probed.")
  #expect(result.toolCalls == 1)
  // Turn one called the tool, turn two said nothing and was fed back, turn three answered.
  #expect(result.modelTurns == 3)
  #expect(result.transcript.contains { $0.text.contains("missing_tool_call") })
  #expect(await provider.requests.count == 3)
}

@Test("Three empty replies in a row withdraw the tools and force an answer")
func repeatedEmptyRepliesWithdrawTools() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [.toolCall(ToolCall(id: "c1", name: "probe", arguments: .object([:])))]),
        stopReason: .toolCall),
      ProviderResponse(message: .assistant("Nothing more I can do."), stopReason: .stop),
    ],
    failures: [1: EmptyReplyFailure(), 2: EmptyReplyFailure(), 3: EmptyReplyFailure()])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "probe", description: "Probe")) { _, _ in
      ToolOutput(text: "42")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("probe")],
      toolNames: ["probe"],
      retry: AgentRetryPolicy(attempts: 2, delaySeconds: 0)))

  #expect(result.response.text == "Nothing more I can do.")
  let requests = await provider.requests
  #expect(requests.count == 5)
  #expect(!requests[3].tools.isEmpty)
  #expect(requests[4].tools.isEmpty)
  #expect(requests[4].messages.contains { $0.text.contains("made no progress") })
}

private struct EmptyReplyFailure: ProviderEmptyResponseError {}

@Test("The run loop resolves a glued tool name the provider could not map")
func runLoopResolvesGluedNames() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(id: "g1", name: "probe Optimize:", arguments: .object([:])))
          ]),
        stopReason: .toolCall),
      ProviderResponse(message: .assistant("Probed."), stopReason: .stop),
    ],
    capabilities: [.streaming])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "probe", description: "Probe")) { _, _ in
      ToolOutput(text: "42")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted", model: "fixture", messages: [.user("probe")],
      toolNames: ["probe"], toolCallingStrategy: .json))

  #expect(result.response.text == "Probed.")
  #expect(result.toolCalls == 1)
  let output = try #require(result.transcript.flatMap(\.toolResults).first)
  #expect(!output.isError)
  #expect(output.text == "42")
}

@Test("A native respond call in a text protocol is the final answer, not a host tool")
func nativeRespondCallIsFinal() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: "r1", name: AgentToolLoopPolicy.responseToolName,
                arguments: .object(["action": .string("final"), "content": .string("Done.")])))
          ]),
        stopReason: .toolCall)
    ],
    capabilities: [.streaming])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "probe", description: "Probe")) { _, _ in
      Issue.record("respond must not run a host tool")
      return ToolOutput(text: "unexpected")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted", model: "fixture", messages: [.user("finish")],
      toolNames: ["probe"], toolCallingStrategy: .json))

  #expect(result.response.text == "Done.")
  #expect(result.modelTurns == 1)
  #expect(result.toolCalls == 0)
}

@Test("Size mode prunes file bodies read for earlier prompts and keeps the current prompt's; cache mode keeps all")
func sizeModePrunesEarlierPromptsFileBodies() async throws {
  let body = String(repeating: "line of source code\n", count: 40)
  func fileResult(_ id: String, _ name: String) -> AgentMessage {
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(
          ToolResult(
            callID: id,
            content: [.file(FileContent(name: name, mimeType: "text/plain", text: body))],
            structuredContent: .object(["path": .string(name)])))
      ])
  }
  func readCall(_ id: String, _ name: String) -> AgentMessage {
    AgentMessage(
      role: .assistant,
      content: [
        .toolCall(ToolCall(id: id, name: "readfile", arguments: .object(["path": .string(name)])))
      ])
  }
  // An earlier prompt read a.py and was answered; the new prompt reads b.py.
  let history: [AgentMessage] = [
    .user("describe a.py"), readCall("r1", "a.py"), fileResult("r1", "a.py"),
    .assistant("a.py defines main."), .user("now look at b.py"),
  ]
  func run(_ mode: AgentContextMode) async throws -> (AgentResult, [ProviderRequest]) {
    let provider = ScriptedProvider(responses: [
      ProviderResponse(message: readCall("r2", "b.py"), stopReason: .toolCall),
      ProviderResponse(message: .assistant("Done."), stopReason: .stop),
    ])
    let runtime = AgentRuntime()
    try await runtime.register(provider)
    try await runtime.register(
      tool: ClosureTool(
        definition: ToolDefinition(
          name: "readfile", description: "Read",
          parameters: [ToolParameterDef(name: "path", type: "string", description: "Path", required: true)],
          annotations: ToolAnnotations(readOnly: true, approval: .automatic))
      ) { arguments, _ in
        let path = arguments.objectValue?["path"]?.stringValue ?? "?"
        return ToolOutput(
          content: [.file(FileContent(name: path, mimeType: "text/plain", text: body))],
          structuredContent: .object(["path": .string(path)]))
      })
    let result = try await runtime.run(
      AgentRequest(
        provider: "scripted", model: "fixture", messages: history,
        toolNames: ["readfile"], context: mode))
    return (result, await provider.requests)
  }

  let (sized, sizedRequests) = try await run(.size)
  #expect(sized.response.text == "Done.")
  let results = sizedRequests[1].messages.filter { $0.role == .tool }.flatMap(\.toolResults)
  #expect(results.count == 2)
  #expect(results[0].text.contains("[a.py: 41 lines, \(body.count) characters, read earlier and removed"))
  #expect(results[1].text == body)

  let (cached, cachedRequests) = try await run(.cache)
  #expect(cached.response.text == "Done.")
  #expect(cachedRequests[1].messages.filter { $0.role == .tool }.flatMap(\.toolResults).allSatisfy { $0.text == body })
}

@Test("Pruning leaves short bodies and the prompt in progress alone")
func pruningKeepsSmallAndCurrent() {
  func toolMessage(_ id: String, _ text: String) -> AgentMessage {
    AgentMessage(
      role: .tool,
      content: [
        .toolResult(
          ToolResult(callID: id, content: [.file(FileContent(name: "\(id).txt", mimeType: "text/plain", text: text))]))
      ])
  }
  let long = String(repeating: "x", count: 500)
  var messages = [
    AgentMessage.user("first"), toolMessage("1", "short"), toolMessage("2", long),
    .assistant("done"), .user("second"), toolMessage("3", long),
  ]
  let report = AgentContextPruning.prune(&messages)
  #expect(report?.pruned == 1)
  #expect(messages[1].toolResults[0].text == "short")
  #expect(messages[2].toolResults[0].text.hasPrefix("[2.txt: 1 lines, 500 characters"))
  #expect(messages[5].toolResults[0].text == long)
  #expect(AgentContextPruning.prune(&messages) == nil)
}

@Test("A call without reported usage is estimated, marked as such, and still counts against the budget")
func estimatedUsage() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("twelve characters"), usage: nil, stopReason: .stop),
    ProviderResponse(message: .assistant("never asked"), usage: nil, stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("say something twelve characters long please")],
      limits: AgentRunLimits(maxTotalTokens: 5)))
  let usage = try #require(result.usage)
  #expect(usage.isEstimated)
  #expect(usage.inputTokens > 0)
  #expect(usage.outputTokens > 0)
  #expect(usage.totalTokens == usage.inputTokens + usage.outputTokens)
  // The estimate spent the budget, so no second call was made.
  #expect(await provider.requests.count == 1)
  #expect(result.response.text == "twelve characters")

  let info = AgentProcessInfo(pid: 1, runID: UUID(), agentID: "main", usage: usage)
  #expect(info.summaryLine.contains("~\(ModelUsageFormat.count(usage.totalTokens)) tok"))
  let reported = AgentProcessInfo(
    pid: 2, runID: UUID(), agentID: "main", usage: TokenUsage(inputTokens: 1_000, outputTokens: 240))
  #expect(reported.summaryLine.contains(" 1.2k tok"))
  #expect(!reported.summaryLine.contains("~"))
}

@Test("A token budget spent by the final answer still delivers that answer")
func tokenBudget() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: .assistant("too expensive"),
      usage: TokenUsage(inputTokens: 4, outputTokens: 2),
      stopReason: .stop)
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  // The budget stops the next model call; an answer already paid for is
  // never thrown away.
  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("hello")],
      limits: AgentRunLimits(maxTotalTokens: 5)))
  #expect(result.response.text == "too expensive")
  #expect(result.isComplete)
  #expect(result.usage?.totalTokens == 6)
}

@Test(
  "Subagents keep job titles separate from their isolated task briefs",
  arguments: [AgentRuntime.agentStartToolName, AgentRuntime.subagentToolName])
func subagentRun(toolName: String) async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "spawn-1",
              name: toolName,
              arguments: .object([
                "agent": .string("researcher"),
                "title": .string("Research the answer"),
                "task": .string("Find the answer"),
                "output": .string("One concise answer"),
              ])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Child result"), stopReason: .stop),
    ProviderResponse(message: .assistant("Parent used Child result"), stopReason: .stop),
  ])
  let recorder = EventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      instructions: "Research carefully.",
      provider: "scripted",
      model: "fixture"))

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("delegate")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(
        maxModelTurns: 4,
        maxToolCalls: 2,
        maxSubagents: 1,
        maxSubagentDepth: 1))
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Parent used Child result")
  #expect(result.transcript.flatMap(\.toolResults).first?.text == "Child result")
  let events = await recorder.events
  #expect(events.contains { if case .childStarted = $0 { true } else { false } })
  #expect(events.contains { if case .childFinished = $0 { true } else { false } })
  let requests = await provider.requests
  #expect(requests.count == 3)
  #expect(requests[1].messages.first?.text == "Research carefully.")
  let brief = try #require(requests[1].messages.last?.text)
  #expect(brief.contains("Find the answer"))
  #expect(brief.contains("## Task"))
  #expect(!brief.contains("{{task}}"))
  #expect(!brief.contains("Research the answer"))
  let tree = await runtime.supervisor.tree()
  let child = try #require(tree.processes.first { $0.depth == 1 })
  #expect(child.task == "Research the answer")
  #expect(child.state == .completed)
  #expect(child.summaryLine.contains("Research the answer"))
  let pid = try #require(child.parent)
  #expect(await runtime.supervisor.records(under: pid).first?.task == "Research the answer")
}

@Test("A background child reports to the turn that started it, and later turns still own it")
func launchedSubagentRun() async throws {
  let provider = LaunchedSubagentProvider()
  let recorder = EventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      instructions: "Research carefully.",
      provider: "launched-subagent",
      model: "fixture"))

  let launch = try await runtime.run(
    AgentRequest(
      provider: "launched-subagent",
      model: "fixture",
      messages: [.user("delegate asynchronously")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(
        maxModelTurns: 4,
        maxToolCalls: 2,
        maxSubagents: 1,
        maxSubagentDepth: 1))
  ) { event in
    await recorder.append(event)
  }

  let launchResult = try #require(launch.transcript.flatMap(\.toolResults).first)
  let id = try #require(launchResult.structuredContent?.objectValue?["pid"]?.stringValue)
  // The host keeps one process per conversation, so later turns still own the
  // child this turn started in the background.
  let orchestrator = try #require(
    await runtime.supervisor.tree().processes.first { $0.runID == launch.runID }?.pid)
  #expect(launchResult.structuredContent?.objectValue?["status"] == .string("running"))
  // The model answered as soon as the child was started; the run held for
  // the child, took its answer as a message, and asked the model once more.
  #expect(launch.transcript.contains { $0.role == .assistant && $0.text == "Launched \(id)" })
  #expect(launch.response.text == "Delivered: Background result")
  let child = try #require(AgentPID(text: id))
  #expect(await runtime.supervisor.info(child)?.state == .completed)
  #expect(await runtime.supervisor.info(child)?.isCollected == true)

  let rejected = try await runtime.run(
    AgentRequest(
      provider: "launched-subagent",
      model: "fixture",
      messages: [.user("launch again")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(
        maxModelTurns: 4,
        maxToolCalls: 2,
        maxSubagents: 1,
        maxSubagentDepth: 1)),
    process: orchestrator)
  // The first child ended with its turn, so the only slot is free again and
  // the second child runs at once, and reports to its own turn the same way.
  let secondResult = try #require(rejected.transcript.flatMap(\.toolResults).first)
  #expect(!secondResult.isError)
  #expect(secondResult.text.hasPrefix("Started researcher as"))
  #expect(secondResult.structuredContent?.objectValue?["status"] == .string("running"))
  #expect(rejected.response.text == "Delivered: Background result")

  try await Task.sleep(for: .milliseconds(120))
  let collected = try await runtime.run(
    AgentRequest(
      provider: "launched-subagent",
      model: "fixture",
      messages: [.user("collect \(id)")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(
        maxModelTurns: 5,
        maxToolCalls: 3,
        maxSubagents: 1,
        maxSubagentDepth: 1)),
    process: orchestrator
  ) { event in
    await recorder.append(event)
  }

  #expect(collected.response.text == "Parent received: Background result")
  let toolResults = collected.transcript.flatMap(\.toolResults)
  #expect(toolResults.count == 2)
  let status = try #require(
    toolResults[0].structuredContent?.objectValue?["agents"]?.arrayValue?.first?.objectValue)
  #expect(status["pid"] == .string(id))
  #expect(status["status"] == .string("completed"))
  #expect(toolResults[1].text == "Background result")
  #expect(toolResults[1].structuredContent?.objectValue?["status"] == .string("completed"))
  let events = await recorder.events
  #expect(events.contains { if case .childStarted = $0 { true } else { false } })
  let requests = await provider.requests
  let offeredNames = Set(requests.first?.tools.map(\.name) ?? [])
  #expect(offeredNames.contains(AgentRuntime.agentStartToolName))
  #expect(offeredNames.contains(AgentRuntime.agentStatusToolName))
  #expect(offeredNames.contains(AgentRuntime.agentResultToolName))
  #expect(offeredNames.contains(AgentRuntime.agentStopToolName))
  // The retired names still run, but spending prompt on six near-identical
  // tools only confuses a model, so they are not offered.
  #expect(!offeredNames.contains(AgentRuntime.subagentToolName))
  #expect(!offeredNames.contains(AgentRuntime.agentLaunchToolName))
  #expect(
    requests.first { $0.messages.first?.text == "Research carefully." }?.messages.last?.text
      .contains("Find this in the background") == true)
}

@Test("Agent tools have one permission group")
func agentToolGroup() {
  #expect(AgentRuntime.agentToolGroup.id == "agents")
  #expect(AgentRuntime.agentToolGroup.sourceID == "runtime")
  #expect(
    AgentRuntime.agentToolGroup.toolNames == [
      AgentRuntime.agentStartToolName,
      AgentRuntime.agentStatusToolName,
      AgentRuntime.agentResultToolName,
      AgentRuntime.agentStopToolName,
    ])
  #expect(!AgentRuntime.agentToolGroup.toolNames.contains(AgentRuntime.subagentToolName))
  #expect(!AgentRuntime.agentToolGroup.toolNames.contains(AgentRuntime.agentLaunchToolName))
}

@Test("The agents tool group controls subagent access per profile")
func agentToolGroupPermission() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("No delegation"), stopReason: .stop)
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      instructions: "Research.",
      provider: "scripted",
      model: "fixture"))

  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("Do not delegate")],
      toolNames: [],
      toolGroupNames: [],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(maxSubagents: 1)))

  let names = Set(try #require(await provider.requests.first).tools.map(\.name))
  #expect(AgentRuntime.agentToolNames.isDisjoint(with: names))
}

@Test("Subagents use the default concurrency limit")
func subagentsUseDefaultConcurrencyLimit() async throws {
  #expect(AgentRunLimits().maxSubagents == 5)
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("No delegation"), stopReason: .stop)
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      instructions: "Research.",
      provider: "scripted",
      model: "fixture"))

  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("Do not delegate")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher"]))

  let names = Set(try #require(await provider.requests.first).tools.map(\.name))
  #expect(AgentRuntime.agentToolNames.isSubset(of: names))
}

@Test("A delegating agent still calls its own tools itself when it wants to")
func toolDelegationKeepsTheAgentsOwnTools() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "read-1", name: "read_file",
              arguments: .object(["path": .string("Parser.swift")])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Read it myself."), stopReason: .stop),
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "read_file",
        description: "Read a file",
        inputSchema: objectSchema(required: ["path"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: "contents of \(arguments.objectValue?["path"]?.stringValue ?? "-")")
    })

  let result = try await runtime.run(
    AgentRequest(
      agentID: "main",
      provider: "scripted",
      model: "fixture",
      messages: [.user("what is in Parser.swift?")],
      toolNames: ["read_file"],
      toolGroupNames: [],
      limits: AgentRunLimits(maxModelTurns: 4, maxToolCalls: 4, maxSubagents: 2),
      toolDelegation: .subagent))

  #expect(result.response.text == "Read it myself.")
  #expect(result.toolCalls == 1)
  #expect(result.transcript.flatMap(\.toolResults).map(\.text) == ["contents of Parser.swift"])
  // The call ran here: no child was started for it.
  #expect(await runtime.supervisor.processes().count == 1)
}

@Test("Delegation lets an agent hand tool work to a child that has the same tools")
func toolDelegationRunsToolsInAChild() async throws {
  let provider = DelegatingProvider()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "read_file",
        description: "Read a file",
        inputSchema: objectSchema(required: ["path"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: "contents of \(arguments.objectValue?["path"]?.stringValue ?? "-")")
    })

  let result = try await runtime.run(
    AgentRequest(
      agentID: "main",
      provider: "delegating",
      model: "fixture",
      messages: [.user("what is in Parser.swift?")],
      toolNames: AgentRuntime.agentToolNames.union(["read_file"]),
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      // The parent spends one tool call to delegate and two model turns; the
      // worker gets its own two model turns and one tool call.
      limits: AgentRunLimits(maxModelTurns: 2, maxToolCalls: 1, maxSubagents: 2),
      toolDelegation: .subagent,
      sessionID: "chat-1"))

  #expect(result.response.text == "Parser.swift holds the parser.")
  let requests = await provider.requests
  // The child works for the same chat, so a per-conversation header matches.
  #expect(requests.count > 1 && requests.allSatisfy { $0.sessionID == "chat-1" })
  // The orchestrator keeps its own tools and is offered the agent family besides.
  let parentTools = Set(requests[0].tools.map(\.name))
  #expect(
    parentTools == [
      "read_file",
      AgentRuntime.agentStartToolName, AgentRuntime.agentStatusToolName,
      AgentRuntime.agentResultToolName, AgentRuntime.agentStopToolName,
    ])
  // The derived worker gets the same tool and, as a peer of its parent, the
  // agent family too: it may hand work down in turn until the depth limit.
  let workerRequest = try #require(
    requests.first { $0.messages.first?.text.contains("focused worker agent") == true })
  #expect(
    Set(workerRequest.tools.map(\.name))
      == Set(["read_file"]).union(AgentRuntime.agentToolNames))
  #expect(workerRequest.messages.last?.text.contains("Read Parser.swift") == true)
  // Only one call and one answer reach the orchestrator: no file contents.
  let parentResults = result.transcript.flatMap(\.toolResults)
  #expect(parentResults.count == 1)
  #expect(parentResults[0].text == "Parser.swift holds the parser.")
  #expect(!result.transcript.contains { $0.text.contains("contents of Parser.swift") })
}

@Test("Delegation without a subagent budget leaves the agent's own tools in place")
func toolDelegationNeedsASubagentBudget() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("No tools needed"), stopReason: .stop)
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(name: "read_file", description: "Read a file")
    ) { _, _ in ToolOutput(text: "-") })

  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("hello")],
      toolNames: ["read_file"],
      limits: AgentRunLimits(maxSubagents: 0),
      toolDelegation: .subagent))

  let names = Set(try #require(await provider.requests.first).tools.map(\.name))
  #expect(names == Set(["read_file"]).union(AgentRuntime.agentToolNames.subtracting([AgentRuntime.agentStartToolName])))
}

@Test("Disabled agents are never offered as subagents")
func disabledAgentsAreNotOffered() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("Done"), stopReason: .stop)
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      description: "Finds things in the repository",
      instructions: "Research.",
      provider: "scripted",
      model: "fixture"))
  try await runtime.register(
    agent: AgentDefinition(
      id: "parked",
      isEnabled: false,
      instructions: "Parked.",
      provider: "scripted",
      model: "fixture"))

  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("delegate")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher", "parked"],
      limits: AgentRunLimits(maxSubagents: 1)))

  let start = try #require(
    await provider.requests.first?.tools.first { $0.name == AgentRuntime.agentStartToolName })
  let agentProperty = try #require(
    start.inputSchema.objectValue?["properties"]?.objectValue?["agent"]?.objectValue)
  #expect(agentProperty["enum"] == .array([.string("researcher")]))
  // The description a model reads to pick an agent comes from the definition.
  #expect(
    agentProperty["description"]?.stringValue?.contains(
      "researcher — Finds things in the repository") == true)
  #expect(await runtime.availableAgents().count == 2)
  #expect(await runtime.availableAgents(includingDisabled: false).map(\.id) == ["researcher"])
}

@Test("The supervisor tracks the tree, surfaces attention, and stops a subtree")
func agentSupervisorTree() async throws {
  let supervisor = AgentSupervisor()
  let root = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "top", depth: 0)
  let child = await supervisor.register(
    runID: UUID(), parent: root, agentID: "coder", task: "write it", depth: 1)
  let grandchild = await supervisor.register(
    runID: UUID(), parent: child, agentID: "worker", task: "grep", depth: 2)

  var tree = await supervisor.tree()
  #expect(tree.roots.map(\.pid) == [root])
  #expect(tree.subtree(of: child).map(\.pid) == [child, grandchild])
  #expect(tree.isDescendant(grandchild, of: root))
  #expect(!tree.isDescendant(root, of: child))
  #expect(tree.liveChildren(ofAgent: "main").map(\.pid) == [child])
  #expect(tree.lines().count == 3)
  #expect(tree.lines()[1].hasPrefix("└── #2 coder"))

  let approval = ApprovalRequest(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "worker", depth: 2),
    tool: ToolDefinition(name: "write_file", description: "Write"),
    call: ToolCall(id: "call-1", name: "write_file", arguments: .object([:])))
  await supervisor.raise(.approval(approval), for: grandchild)
  #expect(await supervisor.info(grandchild)?.state == .waitingForApproval)
  #expect(await supervisor.processesNeedingAttention().map(\.pid) == [grandchild])
  await supervisor.clearAttention(for: grandchild)
  #expect(await supervisor.processesNeedingAttention().isEmpty)

  // Stopping a node takes everything under it; a half-stopped tree would leak
  // work nobody is waiting for.
  let stopped = await supervisor.stop(child, reason: "no longer needed")
  #expect(stopped == [child, grandchild])
  tree = await supervisor.tree()
  #expect(tree.info(child)?.state == .cancelled)
  #expect(tree.info(grandchild)?.state == .cancelled)
  #expect(tree.info(root)?.state == .starting)
}

@Test("Clearing forgets finished processes whose subtree is done and nothing is queued for")
func agentSupervisorClearFinished() async throws {
  let supervisor = AgentSupervisor()
  let root = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "top", depth: 0)
  let child = await supervisor.register(
    runID: UUID(), parent: root, agentID: "coder", task: "write it", depth: 1)
  let sibling = await supervisor.register(
    runID: UUID(), parent: root, agentID: "coder", task: "test it", depth: 1)

  // Nothing has finished yet, so nothing goes.
  #expect(await supervisor.clearFinished().isEmpty)

  _ = await supervisor.stop(child, reason: "done")
  _ = await supervisor.stop(sibling, reason: "done")
  await supervisor.post(.user("one more thing"), to: sibling)
  // A finished child goes; one somebody queued a message for stays, and so
  // does the root, which is still running.
  #expect(await supervisor.clearFinished() == [child])
  #expect(await supervisor.tree().processes.map(\.pid) == [root, sibling])

  _ = await supervisor.clearQueuedMessages(for: sibling)
  _ = await supervisor.stop(root, reason: "done")
  #expect(await supervisor.clearFinished() == [root, sibling])
  #expect(await supervisor.tree().isEmpty)
}

@Test("Pausing holds a subtree, keeps a waiting process visible, and ends with the process")
func agentSupervisorPauseAndResume() async throws {
  let supervisor = AgentSupervisor()
  let root = await supervisor.register(
    runID: UUID(), parent: nil, agentID: "main", task: "top", depth: 0)
  let child = await supervisor.register(
    runID: UUID(), parent: root, agentID: "coder", task: "write it", depth: 1)
  let grandchild = await supervisor.register(
    runID: UUID(), parent: child, agentID: "worker", task: "grep", depth: 2)
  let finished = await supervisor.register(
    runID: UUID(), parent: root, agentID: "coder", task: "done already", depth: 1)
  await supervisor.fail(finished, state: .failed, message: "gave up", announce: false)
  await supervisor.note(child, state: .running, activity: "thinking")

  // Holding a node takes everything under it, and nothing beside it.
  #expect(await supervisor.pause(child) == [child, grandchild])
  #expect(await supervisor.isPaused(child))
  #expect(await supervisor.isPaused(grandchild))
  #expect(await supervisor.info(child)?.state == .paused)
  #expect(await supervisor.info(grandchild)?.state == .paused)
  #expect(await supervisor.info(root)?.state == .starting)
  #expect(await supervisor.pause(child).isEmpty)
  #expect(await supervisor.pause(finished).isEmpty)

  // The run reports progress until it reaches its next step; that does not
  // lift the hold.
  await supervisor.note(child, state: .running, activity: "read_file")
  #expect(await supervisor.info(child)?.state == .paused)
  #expect(await supervisor.info(child)?.activity == "read_file")

  // A question the run asks meanwhile shows, and the hold shows again once
  // it is answered.
  let approval = ApprovalRequest(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "worker", depth: 2),
    tool: ToolDefinition(name: "write_file", description: "Write"),
    call: ToolCall(id: "call-1", name: "write_file", arguments: .object([:])))
  await supervisor.raise(.approval(approval), for: grandchild)
  #expect(await supervisor.info(grandchild)?.state == .waitingForApproval)
  await supervisor.clearAttention(for: grandchild)
  #expect(await supervisor.info(grandchild)?.state == .paused)

  // Letting the parent go releases the subtree.
  #expect(await supervisor.resume(child) == [child, grandchild])
  #expect(await supervisor.info(child)?.state == .running)
  #expect(await supervisor.info(grandchild)?.state == .running)
  #expect(await supervisor.isPaused(grandchild) == false)
  #expect(await supervisor.resume(child).isEmpty)

  // Killing a held process ends the hold with it.
  #expect(await supervisor.pause(grandchild) == [grandchild])
  #expect(await supervisor.stop(grandchild, reason: "gone") == [grandchild])
  #expect(await supervisor.isPaused(grandchild) == false)
  #expect(await supervisor.info(grandchild)?.state == .cancelled)
  #expect(await supervisor.info(child)?.state == .running)
}

@Test("Pids parse the way people and models write them")
func agentPIDParsing() {
  #expect(AgentPID(text: "4") == AgentPID(4))
  #expect(AgentPID(text: " #4 ") == AgentPID(4))
  #expect(AgentPID(text: "pid 4") == AgentPID(4))
  #expect(AgentPID(4).description == "#4")
  #expect(AgentPID(text: "0") == nil)
  #expect(AgentPID(text: "worker") == nil)
}

@Test("A brief renders through the delegation template, custom or built-in")
func delegationPromptRendering() throws {
  let brief = AgentTaskBrief(
    context: "The parser lives in Sources/Parser.",
    task: "Find every call site of parseHeader.",
    output: "One path:line per line, no prose.")
  let rendered = AgentDelegationPrompt.render(
    brief, agent: "researcher", workingDirectory: "/tmp/work")
  #expect(rendered.contains("The parser lives in Sources/Parser."))
  #expect(rendered.contains("Find every call site of parseHeader."))
  #expect(rendered.contains("One path:line per line, no prose."))
  #expect(rendered.contains("researcher"))
  #expect(rendered.contains("/tmp/work"))

  // An empty context reads as a statement, not as an oversight to ask about.
  let bare = AgentDelegationPrompt.render(
    AgentTaskBrief(task: "Say hi"), agent: "worker", workingDirectory: "")
  #expect(bare.contains(AgentDelegationPrompt.emptyContext))
  #expect(bare.contains(AgentDelegationPrompt.emptyOutput))

  #expect(
    AgentDelegationPrompt.render(
      brief, agent: "x", workingDirectory: "/", template: "Do: {{task}}")
      == "Do: Find every call site of parseHeader.")
  #expect(AgentDelegationPrompt.missingPlaceholder(in: "Do: {{task}}") == nil)
  #expect(AgentDelegationPrompt.missingPlaceholder(in: "Do something") == "{{task}}")
  #expect(AgentDelegationPrompt.missingPlaceholder(in: "  ") == nil)
  #expect(AgentTaskBrief(arguments: ["task": .string("  ")]) == nil)
}

@Test("A delegation template without {{task}} is refused by the configuration")
func delegationPromptValidation() throws {
  var configuration = MaiConfiguration(
    providers: [ConfiguredProvider(id: "p", kind: .hello)],
    prompts: ConfiguredPrompts(delegation: "Just do it"))
  #expect(
    throws: MaiConfigurationError.missingPromptPlaceholder(
      prompt: "delegation", placeholder: "{{task}}")
  ) {
    try configuration.validate()
  }
  configuration.prompts = ConfiguredPrompts(delegation: "Do {{task}}", worker: "Be brief")
  try configuration.validate()
  let decoded = try JSONDecoder().decode(
    MaiConfiguration.self, from: try configuration.encoded())
  #expect(decoded.prompts?.delegation == "Do {{task}}")
  #expect(decoded.prompts?.worker == "Be brief")
}

@Test("An explicitly empty provider environment secret suppresses its fallback key")
func emptyProviderEnvironmentSecret() throws {
  let provider = ConfiguredProvider(
    id: "remote",
    kind: .openAICompatible,
    apiKey: "configured-fallback",
    apiKeyEnvironment: "TEST_API_KEY")

  #expect(try provider.resolvedAPIKey(environment: [:]) == "configured-fallback")
  #expect(
    try provider.resolvedAPIKey(environment: ["TEST_API_KEY": "shell-secret"]) == "shell-secret")
  #expect(
    try provider.resolvedAPIKey(environment: ["TEST_API_KEY": ""]) == nil)
}

@Test("Configuration accepts host-defined provider kinds and factories")
func customProviderFactory() async throws {
  let data = Data(
    """
    {
      "id": "fixture-provider",
      "kind": "fixture",
      "options": {"prefix": "Configured extension"}
    }
    """.utf8)
  let configured = try JSONDecoder().decode(ConfiguredProvider.self, from: data)
  #expect(configured.kind == ConfiguredProviderKind("fixture"))
  #expect(configured.options["prefix"] == .string("Configured extension"))

  let plugins = PluginRegistry()
  try await plugins.install(FixtureProviderPlugin())
  let provider = try await plugins.makeProvider(from: configured, environment: [:])
  let response = try await provider.complete(
    ProviderRequest(model: "fixture", messages: [.user("works")], stream: false))

  #expect(provider.descriptor.id == "fixture-provider")
  #expect(response.message.text == "Configured extension: works")
}

private struct FixtureConfiguredProviderFactory: ConfiguredProviderFactory {
  let kind = ConfiguredProviderKind("fixture")

  func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    HelloProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? "Fixture",
      prefix: configuration.options["prefix"]?.stringValue ?? "Fixture")
  }
}

private struct FixtureProviderPlugin: MaiPlugin {
  let manifest = PluginManifest(
    id: "fixture-provider-plugin",
    displayName: "Fixture provider",
    version: "1.0.0",
    capabilities: [.chatProvider])

  func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      providerFactory: FixtureConfiguredProviderFactory(),
      from: manifest.id)
  }
}

private actor EventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

private actor DelegatingProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "delegating",
    displayName: "Delegating fixture",
    capabilities: [.nativeToolCalling])
  private(set) var requests: [ProviderRequest] = []

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    let results = request.messages.flatMap(\.toolResults)
    // The worker is a peer with the agent tools of its own; its instructions
    // are what tell it apart.
    let isWorker = request.messages.first?.text.contains("focused worker agent") == true
    if isWorker {
      guard results.isEmpty else {
        return ProviderResponse(
          message: .assistant("Parser.swift holds the parser."), stopReason: .stop)
      }
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: "read-1",
                name: "read_file",
                arguments: .object(["path": .string("Parser.swift")])))
          ]),
        stopReason: .toolCall)
    }
    guard results.isEmpty else {
      return ProviderResponse(message: .assistant(results[0].text), stopReason: .stop)
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "start-1",
              name: AgentRuntime.agentStartToolName,
              arguments: .object([
                "context": .string("The user asked about Parser.swift."),
                "task": .string("Read Parser.swift and say what it holds."),
                "output": .string("One sentence."),
              ])))
        ]),
      stopReason: .toolCall)
  }
}

private actor LaunchedSubagentProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "launched-subagent",
    displayName: "Launched subagent fixture",
    capabilities: [.nativeToolCalling])
  private(set) var requests: [ProviderRequest] = []

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    if request.messages.first?.text == "Research carefully." {
      try await Task.sleep(for: .milliseconds(100))
      return ProviderResponse(message: .assistant("Background result"), stopReason: .stop)
    }

    let results = request.messages.flatMap(\.toolResults)
    // A background child's answer arrives as the newest user message.
    if let delivery = request.messages.last(where: { $0.role == .user }),
      AgentProcessTools.deliveredChildPID(of: delivery) != nil
    {
      return ProviderResponse(
        message: .assistant("Delivered: \(delivery.text.split(separator: "\n").last ?? "")"),
        stopReason: .stop)
    }
    let command = request.messages.last { $0.role == .user }?.text ?? ""
    if ["delegate asynchronously", "launch again"].contains(command), results.isEmpty {
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: "launch-1",
                name: AgentRuntime.agentLaunchToolName,
                arguments: .object([
                  "agent": .string("researcher"),
                  "prompt": .string("Find this in the background"),
                ])))
          ]),
        stopReason: .toolCall)
    }
    if command == "delegate asynchronously" {
      let id = try #require(results[0].structuredContent?.objectValue?["pid"]?.stringValue)
      return ProviderResponse(message: .assistant("Launched \(id)"), stopReason: .stop)
    }
    if command == "launch again" {
      return ProviderResponse(
        message: .assistant("Second launch: \(results[0].text)"),
        stopReason: .stop)
    }
    let id = String(command.dropFirst("collect ".count))
    if results.isEmpty {
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: "status-1",
                name: AgentRuntime.agentStatusToolName,
                arguments: .object(["pid": .string(id)])))
          ]),
        stopReason: .toolCall)
    }
    if results.count == 1 {
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: "result-1",
                name: AgentRuntime.agentResultToolName,
                arguments: .object(["pid": .string(id)])))
          ]),
        stopReason: .toolCall)
    }
    return ProviderResponse(
      message: .assistant("Parent received: \(results.last?.text ?? "")"),
      stopReason: .stop)
  }
}

private actor QueueApprovalHandler: ApprovalHandler {
  private var decisions: [ApprovalDecision]
  init(decisions: [ApprovalDecision]) { self.decisions = decisions }

  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    guard !decisions.isEmpty else { return .deny(reason: "No test decision") }
    return decisions.removeFirst()
  }
}

private actor JSONValueRecorder {
  private(set) var value: JSONValue?
  func record(_ value: JSONValue) { self.value = value }
}

@Test("Exhausted tool call budgets become tool errors and the model is asked to answer")
func toolCallBudgetExhaustion() async throws {
  func upper(_ id: String, _ text: String) -> ContentPart {
    .toolCall(ToolCall(id: id, name: "uppercase", arguments: .object(["text": .string(text)])))
  }
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(role: .assistant, content: [upper("c1", "one"), upper("c2", "two")]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("ONE is all I got."), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "uppercase",
        description: "Uppercase text",
        inputSchema: objectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: arguments.objectValue?["text"]?.stringValue?.uppercased() ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("uppercase both")],
      toolNames: ["uppercase"],
      limits: AgentRunLimits(maxToolCalls: 1)))

  #expect(result.response.text == "ONE is all I got.")
  #expect(result.toolCalls == 1)
  let toolResults = result.transcript.flatMap(\.toolResults)
  #expect(toolResults.count == 2)
  #expect(toolResults[0].text == "ONE")
  #expect(toolResults[1].isError)
  #expect(toolResults[1].text.contains("budget"))
  let requests = await provider.requests
  #expect(requests.count == 2)
  #expect(requests[0].tools.count == 1)
  #expect(requests[1].tools.isEmpty)
  #expect(requests[1].messages.contains { $0.text == AgentRuntime.toolBudgetExhaustedPrompt })
}

@Test("agent_status reads a child's transcript by pid, and a name passed as a pid is explained")
func agentStatusLogReadsChildTranscript() async throws {
  let provider = ChildLogProvider()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      instructions: "Research carefully.",
      provider: "child-log",
      model: "fixture"))

  let result = try await runtime.run(
    AgentRequest(
      provider: "child-log",
      model: "fixture",
      messages: [.user("find the parser")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(
        maxModelTurns: 6,
        maxToolCalls: 4,
        maxSubagents: 1,
        maxSubagentDepth: 1)))

  let results = result.transcript.flatMap(\.toolResults)
  #expect(results.count == 3)
  #expect(!results[0].isError)
  let pid = try #require(results[0].structuredContent?.objectValue?["pid"]?.stringValue)

  let log = results[1]
  #expect(!log.isError)
  #expect(log.text.hasPrefix("#\(pid) researcher"))
  #expect(log.text.contains("Transcript of #\(pid)"))
  #expect(log.text.contains("Child answer: the parser is in Parser.swift."))
  let transcript = try #require(log.structuredContent?.objectValue?["transcript"]?.arrayValue)
  #expect(!transcript.isEmpty && transcript.count <= 3)
  #expect(transcript.last?.objectValue?["role"] == .string("assistant"))

  let named = results[2]
  #expect(named.isError)
  #expect(named.text.contains("'researcher' is not a pid"))
  #expect(named.text.contains("#2 main.worker"))
  #expect(result.response.text == "done")
}

private actor ChildLogProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "child-log",
    displayName: "Child log fixture",
    capabilities: [.nativeToolCalling])

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let isWorker = !request.tools.contains { $0.name == AgentRuntime.agentStartToolName }
    if isWorker {
      return ProviderResponse(
        message: .assistant("Child answer: the parser is in Parser.swift."), stopReason: .stop)
    }
    let results = request.messages.flatMap(\.toolResults)
    switch results.count {
    case 0:
      return call(
        "start-1", AgentRuntime.agentStartToolName,
        [
          "agent": .string("researcher"),
          "context": .string("The user wants the parser."),
          "task": .string("Find the parser."),
          "output": .string("One line."),
        ])
    case 1:
      let pid = results[0].structuredContent?.objectValue?["pid"]?.stringValue ?? "0"
      return call(
        "status-1", AgentRuntime.agentStatusToolName,
        ["pid": .string(pid), "log": .integer(3)])
    case 2:
      return call("status-2", AgentRuntime.agentStatusToolName, ["pid": .string("researcher")])
    default:
      return ProviderResponse(message: .assistant("done"), stopReason: .stop)
    }
  }

  private func call(_ id: String, _ name: String, _ arguments: [String: JSONValue])
    -> ProviderResponse
  {
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [.toolCall(ToolCall(id: id, name: name, arguments: .object(arguments)))]),
      stopReason: .toolCall)
  }
}

@Test("Enabling agents permits a worker in inline mode without configured subagents")
func enabledAgentGroupStartsWorker() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: "start", name: "agent_start", arguments: .object([
        "task": .string("Compute"), "output": .string("One line")
      ])))
    ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("Child answer"), stopReason: .stop),
    ProviderResponse(message: .assistant("Parent answer"), stopReason: .stop),
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  let result = try await runtime.run(AgentRequest(
    provider: "scripted", model: "fixture", messages: [.user("delegate")],
    toolGroupNames: [AgentRuntime.agentToolGroup.id]))
  #expect(result.transcript.flatMap(\.toolResults).map(\.text) == ["Child answer"])
  let child = try #require(await runtime.supervisor.processes().first { $0.depth == 1 })
  #expect(child.task == "Compute")
  #expect(child.summaryLine.contains("Compute"))
}

@Test("A child budget of zero keeps management tools and explains why start is refused")
func enabledAgentGroupExplainsLimits() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: "start", name: "agent_start", arguments: .object([
        "task": .string("Compute"), "output": .string("One line")
      ])))
    ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("Done"), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let result = try await runtime.run(AgentRequest(
    provider: "scripted", model: "fixture", messages: [.user("delegate")],
    toolGroupNames: [AgentRuntime.agentToolGroup.id], limits: AgentRunLimits(maxSubagents: 0)))
  let names = Set(try #require(await provider.requests.first).tools.map(\.name))
  #expect(!names.contains(AgentRuntime.agentStartToolName))
  #expect(names.contains(AgentRuntime.agentStatusToolName))
  #expect(result.transcript.flatMap(\.toolResults).first?.text.contains("limits.maxSubagents is 0") == true)
  #expect(await runtime.supervisor.processes().count == 1)
}

@Test("Queued live settings update provider, model, effort, tools and raised limits")
func queuedRunningAgentReconfiguresWithoutRestarting() async throws {
  let oldProvider = LiveSettingsProvider(
    id: "live-old",
    responses: [ProviderResponse(
      message: AgentMessage(role: .assistant, content: [
        .toolCall(ToolCall(id: "old", name: "old-tool", arguments: .object([:])))
      ]),
      stopReason: .toolCall)],
    blockedRequest: 1)
  let newProvider = LiveSettingsProvider(
    id: "live-new",
    responses: [ProviderResponse(message: .assistant("new settings"), stopReason: .stop)])
  let runtime = AgentRuntime()
  try await runtime.register(oldProvider)
  try await runtime.register(newProvider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "old-tool", description: "Old")) { _, _ in
      ToolOutput(text: "must not run")
    })
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "new-tool", description: "New")) { _, _ in
      ToolOutput(text: "new")
    })

  let pid = await runtime.allocateProcess(agentID: "main")
  let initial = AgentRequest(
    provider: "live-old",
    model: "old-model",
    messages: [.user("work")],
    toolNames: ["old-tool"],
    limits: AgentRunLimits(maxModelTurns: 1))
  let task = Task { try await runtime.run(initial, process: pid) }
  #expect(await oldProvider.waitForRequests(1))

  var updated = initial
  updated.provider = "live-new"
  updated.model = "new-model"
  updated.toolNames = ["new-tool"]
  updated.options.reasoningEffort = ReasoningEffort.low.rawValue
  updated.limits.maxModelTurns = 3
  #expect(await runtime.reconfigure(pid, with: updated))
  await oldProvider.releaseBlockedRequest()

  let result = try await task.value
  #expect(result.response.text == "new settings")
  #expect(
    result.transcript.flatMap(\.toolResults).contains {
      $0.isError && $0.text.hasPrefix("Error: tool 'old-tool' is not available to this agent.")
    })
  let request = try #require(await newProvider.requests.first)
  #expect(request.model == "new-model")
  #expect(request.options.reasoningEffort == ReasoningEffort.low.rawValue)
  #expect(request.tools.map(\.name) == ["new-tool"])
}

@Test("Queued retry delay adopts live settings without waiting for the old delay")
func queuedRetryDelayReconfiguresWithoutRestarting() async throws {
  let provider = LiveSettingsProvider(
    id: "live-retry",
    responses: [ProviderResponse(message: .assistant("retried"), stopReason: .stop)],
    failures: 1)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let pid = await runtime.allocateProcess(agentID: "main")
  let initial = AgentRequest(
    provider: "live-retry",
    model: "fixture",
    messages: [.user("retry")],
    retry: AgentRetryPolicy(attempts: 1, delaySeconds: 30))
  let task = Task { try await runtime.run(initial, process: pid) }
  let watchdog = Task {
    try? await Task.sleep(for: .seconds(2))
    task.cancel()
  }
  #expect(await provider.waitForRequests(1))

  var updated = initial
  updated.retry.delaySeconds = 0
  #expect(await runtime.reconfigure(pid, with: updated))

  let result = try await task.value
  watchdog.cancel()
  #expect(result.response.text == "retried")
  #expect(await provider.requests.count == 2)
}

@Test("agentToolGroup derived workers adopt live parent settings without restarting")
func agentToolGroupDerivedSubagentReconfiguresWithParent() async throws {
  let provider = LiveTreeProvider()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "old-tool", description: "Old")) { _, _ in
      ToolOutput(text: "must not run")
    })
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "new-tool", description: "New")) { _, _ in
      ToolOutput(text: "new")
    })

  let pid = await runtime.allocateProcess(agentID: "main")
  let initial = AgentRequest(
    provider: "live-tree",
    model: "old-model",
    messages: [.user("delegate")],
    toolNames: AgentRuntime.agentToolNames.union(["old-tool"]),
    toolGroupNames: [AgentRuntime.agentToolGroup.id],
    toolDelegation: .subagent)
  let task = Task { try await runtime.run(initial, process: pid) }
  #expect(await provider.waitForFirstChildRequest())

  var updated = initial
  updated.model = "new-model"
  updated.toolNames = AgentRuntime.agentToolNames.union(["new-tool"])
  updated.options.reasoningEffort = ReasoningEffort.high.rawValue
  #expect(await runtime.reconfigure(pid, with: updated))
  await provider.releaseBlockedRequest()

  let result = try await task.value
  #expect(result.response.text == "parent done")
  let childRequests = await provider.childRequests
  let parentRequests = await provider.parentRequests
  #expect(childRequests.count == 2)
  #expect(parentRequests.count == 2)
  let refreshedChild = try #require(childRequests.last)
  let refreshedParent = try #require(parentRequests.last)
  #expect(refreshedChild.model == "new-model")
  #expect(refreshedChild.options.reasoningEffort == ReasoningEffort.high.rawValue)
  #expect(Set(refreshedChild.tools.map(\.name)).contains("new-tool"))
  #expect(!Set(refreshedChild.tools.map(\.name)).contains("old-tool"))
  #expect(refreshedParent.model == "new-model")
}

private actor LiveTreeProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "live-tree",
    displayName: "Live tree",
    capabilities: [.streaming, .nativeToolCalling])
  private var firstChildReleased = false
  private(set) var childRequests: [ProviderRequest] = []
  private(set) var parentRequests: [ProviderRequest] = []

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let isChild = request.messages.contains {
      $0.role == .user && $0.text.contains("## Task") && $0.text.contains("inspect")
    }
    if isChild {
      childRequests.append(request)
      if childRequests.count == 1 {
        while !firstChildReleased { try await Task.sleep(for: .milliseconds(5)) }
        return ProviderResponse(
          message: AgentMessage(role: .assistant, content: [
            .toolCall(ToolCall(id: "old", name: "old-tool", arguments: .object([:])))
          ]),
          stopReason: .toolCall)
      }
      await emit(.textDelta("child done"))
      return ProviderResponse(message: .assistant("child done"), stopReason: .stop)
    }

    parentRequests.append(request)
    if parentRequests.count == 1 {
      return ProviderResponse(
        message: AgentMessage(role: .assistant, content: [
          .toolCall(ToolCall(
            id: "start", name: AgentRuntime.agentStartToolName,
            arguments: .object([
              "task": .string("inspect"),
              "output": .string("a short summary"),
            ]))),
        ]),
        stopReason: .toolCall)
    }
    await emit(.textDelta("parent done"))
    return ProviderResponse(message: .assistant("parent done"), stopReason: .stop)
  }

  func waitForFirstChildRequest() async -> Bool {
    for _ in 0..<1_000 {
      if !childRequests.isEmpty { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  func releaseBlockedRequest() {
    firstChildReleased = true
  }
}

private actor LiveSettingsProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  private var responses: [ProviderResponse]
  private let blockedRequest: Int?
  private var failures: Int
  private var blockedRequestReleased = false
  private(set) var requests: [ProviderRequest] = []

  init(
    id: ProviderID,
    responses: [ProviderResponse],
    blockedRequest: Int? = nil,
    failures: Int = 0
  ) {
    descriptor = ProviderDescriptor(
      id: id, displayName: id.rawValue, capabilities: [.streaming, .nativeToolCalling])
    self.responses = responses
    self.blockedRequest = blockedRequest
    self.failures = failures
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    if failures > 0 {
      failures -= 1
      throw TestError.missingResponse
    }
    if let blockedRequest, requests.count == blockedRequest {
      while !blockedRequestReleased { try await Task.sleep(for: .milliseconds(5)) }
    }
    guard !responses.isEmpty else { throw TestError.missingResponse }
    let response = responses.removeFirst()
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }

  func waitForRequests(_ count: Int) async -> Bool {
    for _ in 0..<1_000 {
      if requests.count >= count { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  func releaseBlockedRequest() { blockedRequestReleased = true }
}

@Test("Mixed exposure enforces disabled tools through direct names and proxy envelopes")
func mixedToolPolicyExecution() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: "list", name: ToolProxy.listName,
        arguments: .object(["keywords": .string("github")]))),
      .toolCall(ToolCall(id: "blocked-direct", name: "github_ci_log", arguments: .object([:]))),
      .toolCall(ToolCall(id: "blocked-proxy", name: ToolProxy.callName,
        arguments: .object(["name": .string("github_ci_log"), "arguments": .object([:])]))),
      .toolCall(ToolCall(id: "pr", name: "github_pr", arguments: .object([:]))),
      .toolCall(ToolCall(id: "issue", name: ToolProxy.callName,
        arguments: .object(["name": .string("github_issue"), "arguments": .object([:])]))),
    ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("done"), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  for name in ["github_pr", "github_issue", "github_ci_log"] {
    try await runtime.register(tool: ClosureTool(definition: ToolDefinition(
      name: name, description: name, annotations: ToolAnnotations(approval: .automatic))) { _, _ in
        #expect(name != "github_ci_log")
        return ToolOutput(text: name + " ran")
      })
  }
  let result = try await runtime.run(AgentRequest(
    provider: "scripted", messages: [.user("review")], toolGroupNames: ["github"],
    useToolProxy: false,
    toolPolicy: .init(groups: ["github": .proxy],
                      tools: ["github_pr": .direct, "github_ci_log": .disabled])))
  let request = try #require(await provider.requests.first)
  #expect(Set(request.tools.map(\.name)) == ["github_pr", ToolProxy.listName, ToolProxy.callName])
  #expect(!request.tools.map(\.description).joined().contains("github_ci_log"))
  let outputs = result.transcript.flatMap(\.toolResults)
  #expect(outputs.first { $0.callID == "blocked-direct" }?.isError == true)
  #expect(outputs.first { $0.callID == "blocked-proxy" }?.isError == true)
  #expect(outputs.first { $0.callID == "list" }?.text.contains("github_ci_log") == false)
  #expect(outputs.first { $0.callID == "issue" }?.text == "github_issue ran")
  let usage = await runtime.toolUsageSnapshot()
  #expect(usage.counts == ["github_pr": 1, "github_issue": 1])
}

@Test("Proxy calls accumulate under the real tool and promote it on later model turns")
func learnedToolExposureRuntime() async throws {
  var replies: [ProviderResponse] = []
  for index in 0..<3 {
    replies.append(ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: "call-\(index)", name: ToolProxy.callName,
        arguments: .object(["name": .string("github_pr"), "arguments": .object([:])]))),
    ]), stopReason: .toolCall))
    replies.append(ProviderResponse(message: .assistant("done"), stopReason: .stop))
  }
  replies.append(ProviderResponse(message: .assistant("manual proxy"), stopReason: .stop))
  let provider = ScriptedProvider(responses: replies)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(definition: ToolDefinition(
    name: "github_pr", description: "Read a PR", annotations: ToolAnnotations(approval: .automatic)))
    { _, _ in ToolOutput(text: "PR") })
  var request = AgentRequest(
    provider: "scripted", messages: [.user("read")], toolNames: ["github_pr"], useToolProxy: true)
  for _ in 0..<3 { _ = try await runtime.run(request) }
  let requests = await provider.requests
  #expect(requests.first?.tools.map(\.name) == [ToolProxy.listName, ToolProxy.callName])
  #expect(requests.last?.tools.map(\.name) == ["github_pr"])
  #expect(await runtime.toolUsageSnapshot().counts["github_pr"] == 3)
  request.toolPolicy.tools["github_pr"] = .proxy
  _ = try await runtime.run(request)
  #expect(await provider.requests.last?.tools.map(\.name) == [ToolProxy.listName, ToolProxy.callName])
}
