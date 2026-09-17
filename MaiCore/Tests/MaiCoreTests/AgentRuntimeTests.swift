import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MaiCore
@testable import MaiMCP
@testable import MaiOpenAI

@Test("Image attachment modes resize images and preserve their metadata")
func imageAttachmentResize() async throws {
  let original = try pngData(width: 200, height: 100)
  let part = try await ImageAttachmentImporter.content(
    data: original,
    mimeType: "image/png",
    filename: "fixture.png",
    mode: .tiny)

  guard case .image(let image) = part else {
    Issue.record("Expected resized image content")
    return
  }
  #expect(image.mimeType == "image/jpeg")
  #expect(image.name == "fixture.jpg")
  #expect(image.width == 100)
  #expect(image.height == 50)
  guard case .data(let resized) = image.source else {
    Issue.record("Expected inline resized image data")
    return
  }
  #expect(resized != original)
}

@Test("OCR image mode delegates to a separate provider and returns a Markdown file")
func imageAttachmentOCR() async throws {
  let part = try await ImageAttachmentImporter.content(
    data: Data([0x01, 0x02]),
    mimeType: "image/jpeg",
    filename: "receipt.jpg",
    mode: .ocr,
    ocrProvider: FixtureOCRProvider())

  guard case .file(let file) = part else {
    Issue.record("Expected OCR Markdown file content")
    return
  }
  #expect(file.name == "receipt.md")
  #expect(file.mimeType == "text/markdown")
  #expect(file.text == "# Recognized\n\nHello from OCR")

  await #expect(throws: ImageAttachmentImportError.ocrProviderRequired) {
    try await ImageAttachmentImporter.content(
      data: Data([0x01]),
      mimeType: "image/jpeg",
      filename: "missing.jpg",
      mode: .ocr)
  }
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

@Test("OpenAI-compatible tool results carry structured content only when they have no text")
func openAIStructuredContentOnlyWithoutText() async throws {
  let recorder = URLRequestRecorder()
  StubURLProtocol.install(forHost: "structured.example.test") { request in
    recorder.record(request, body: try requestBodyData(request))
    return try httpResponse(
      request,
      contentType: "application/json",
      body: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
  }
  defer { StubURLProtocol.reset(host: "structured.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://structured.example.test/v1"))),
    session: stubSession())
  let listing = ToolResult(
    callID: "c1",
    content: [.text("a.txt (3 bytes)")],
    structuredContent: .object(["entries": .array([.string("a.txt")])]))
  let bare = ToolResult(
    callID: "c2",
    content: [],
    structuredContent: .object(["ok": .bool(true)]))
  let read = ToolResult(
    callID: "c3",
    content: [.file(FileContent(name: "a.txt", mimeType: "text/plain", text: "hello"))],
    structuredContent: .object(["totalBytes": .integer(5)]))
  let call = AgentMessage(
    role: .assistant,
    content: [
      .toolCall(ToolCall(id: "c1", name: "files_list", arguments: .object([:]))),
      .toolCall(ToolCall(id: "c2", name: "probe", arguments: .object([:]))),
      .toolCall(ToolCall(id: "c3", name: "files_read", arguments: .object([:]))),
    ])
  _ = try await provider.complete(
    ProviderRequest(
      model: "test-model",
      messages: [
        .user("list"), call,
        AgentMessage(
          role: .tool, content: [.toolResult(listing), .toolResult(bare), .toolResult(read)]),
      ],
      stream: false)
  ) { _ in }

  let body = try jsonObject(try #require(recorder.body))
  let messages = try #require(body["messages"] as? [[String: Any]])
  let toolMessages = messages.filter { $0["role"] as? String == "tool" }
  #expect(toolMessages.count == 3)
  let texts = toolMessages.map { message -> String in
    if let text = message["content"] as? String { return text }
    let parts = message["content"] as? [[String: Any]] ?? []
    return parts.compactMap { $0["text"] as? String }.joined()
  }
  #expect(texts[0] == "a.txt (3 bytes)")
  #expect(texts[1] == "<structured_content>\n{\"ok\":true}\n</structured_content>")
  #expect(texts[2].contains("hello"))
  #expect(!texts[2].contains("structured_content"))
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
  #expect(ToolCallPreview.render(ToolCall(id: "5", name: "run_sh", arguments: .object(["script": .string("make -s && ./app")]))) == "→ run_sh \"make -s && ./app\"")
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

@Test("MCP registration enables all server tools and ignores stale tool references")
func mcpToolsAreEnabledAsAGroup() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(message: .assistant("enabled"), stopReason: .stop),
    ProviderResponse(message: .assistant("disabled"), stopReason: .stop),
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let catalog = try await runtime.register(mcp: FixtureMCPSource())

  #expect(Set(catalog.tools.map(\.name)) == ["r2mcp::analyze", "r2mcp::disassemble"])
  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("inspect")],
      toolNames: ["--::obsolete_tool"]))

  let removed = await runtime.unregisterMCP(serverID: "r2mcp")
  #expect(removed == ["r2mcp::analyze", "r2mcp::disassemble"])
  _ = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("inspect again")],
      toolNames: ["r2mcp::analyze"]))

  let requests = await provider.requests
  #expect(requests.count == 2)
  #expect(
    Set(requests[0].tools.map(\.name)) == ["r2mcp::analyze", "r2mcp::disassemble"])
  #expect(requests[1].tools.isEmpty)
}

@Test("OpenAI-compatible provider encodes multimodal native-tool requests")
func openAIChatCompletion() async throws {
  let recorder = URLRequestRecorder()
  StubURLProtocol.install(forHost: "completion.example.test") { request in
    recorder.record(request, body: try requestBodyData(request))
    return try httpResponse(
      request,
      contentType: "application/json",
      body: """
        {
          "choices": [{
            "message": {
              "content": null,
              "reasoning_content": "need weather",
              "tool_calls": [{
                "id": "call-1",
                "type": "function",
                "function": {"name": "weather_get", "arguments": "{\\"city\\":\\"Barcelona\\"}"}
              }]
            },
            "finish_reason": "tool_calls"
          }],
          "usage": {
            "prompt_tokens": 4,
            "completion_tokens": 3,
            "total_tokens": 7,
            "prompt_tokens_details": {"cached_tokens": 1},
            "completion_tokens_details": {"reasoning_tokens": 2}
          }
        }
        """)
  }
  defer { StubURLProtocol.reset(host: "completion.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://completion.example.test/v1/")),
      apiKey: "secret"),
    session: stubSession())
  #expect(provider.descriptor.capabilities.contains(.nativeToolCalling))
  #expect(provider.descriptor.capabilities.contains(.imageInput))
  let events = ProviderEventRecorder()
  let weather = ToolDefinition(
    name: "weather::get",
    providerName: "weather_get",
    description: "Get weather",
    inputSchema: objectSchema(required: ["city"]))

  let response = try await provider.complete(
    ProviderRequest(
      model: "test-model",
      messages: [
        AgentMessage(
          role: .user,
          content: [
            .text("weather?"),
            .image(
              ImageContent(
                source: .data(Data([0x89, 0x50])),
                mimeType: "image/png")),
          ])
      ],
      tools: [weather],
      responseFormat: .jsonSchema(
        name: "answer",
        schema: objectSchema(required: ["answer"]),
        strict: true),
      stream: false)
  ) { event in
    await events.append(event)
  }

  #expect(response.message.reasoning == "need weather")
  #expect(response.message.toolCalls.first?.name == "weather::get")
  #expect(response.message.toolCalls.first?.arguments == .object(["city": .string("Barcelona")]))
  #expect(response.stopReason == .toolCall)
  #expect(response.usage?.cachedTokens == 1)
  #expect(response.usage?.reasoningTokens == 2)

  let request = try #require(recorder.request)
  #expect(request.url?.absoluteString == "https://completion.example.test/v1/chat/completions")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  let body = try jsonObject(try #require(recorder.body))
  let messages = try #require(body["messages"] as? [[String: Any]])
  let parts = try #require(messages.first?["content"] as? [[String: Any]])
  #expect(parts.contains { $0["type"] as? String == "image_url" })
  let tools = try #require(body["tools"] as? [[String: Any]])
  let function = try #require(tools.first?["function"] as? [String: Any])
  #expect(function["name"] as? String == "weather_get")
  #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
}

@Test("OpenAI-compatible provider lists its model catalog")
func openAIModelCatalog() async throws {
  let recorder = URLRequestRecorder()
  StubURLProtocol.install(forHost: "models.example.test") { request in
    recorder.record(request, body: Data())
    return try httpResponse(
      request,
      contentType: "application/json",
      body: """
        {
          "object": "list",
          "data": [
            {"id":"model-z","owned_by":"vendor"},
            {
              "id":"model-a",
              "name":"Model A",
              "architecture":{"input_modalities":["text","image","audio"]}
            }
          ]
        }
        """)
  }
  defer { StubURLProtocol.reset(host: "models.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://models.example.test/v1/chat/completions")),
      apiKey: "secret",
      additionalHeaders: ["X-Workspace": "test"]),
    session: stubSession())
  let models = try await provider.availableModels()

  #expect(models.map(\.id) == ["model-a", "model-z"])
  #expect(models.first?.displayName == "Model A")
  #expect(models.first?.inputModalities == ["text", "image", "audio"])
  #expect(models.first?.capabilities.contains(.imageInput) == true)
  #expect(models.first?.capabilities.contains(.audioInput) == true)
  #expect(models.last?.ownedBy == "vendor")
  let request = try #require(recorder.request)
  #expect(request.httpMethod == "GET")
  #expect(request.url?.absoluteString == "https://models.example.test/v1/models")
  #expect(request.timeoutInterval == 15)
  #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  #expect(request.value(forHTTPHeaderField: "X-Workspace") == "test")
}

@Test("OpenAI-compatible provider fills {{session}} in configured headers per request")
func openAIConversationHeader() async throws {
  let recorder = URLRequestRecorder()
  StubURLProtocol.install(forHost: "session.example.test") { request in
    recorder.record(request, body: try requestBodyData(request))
    return try httpResponse(
      request,
      contentType: "application/json",
      body: #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
    )
  }
  defer { StubURLProtocol.reset(host: "session.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://session.example.test/v1")),
      additionalHeaders: ["x-opencode-session": "{{session}}", "X-Tenant": "acme"]),
    session: stubSession())

  _ = try await provider.complete(
    ProviderRequest(
      model: "test-model", messages: [.user("hi")], stream: false, sessionID: "chat-1"))
  var request = try #require(recorder.request)
  #expect(request.value(forHTTPHeaderField: "x-opencode-session") == "chat-1")
  #expect(request.value(forHTTPHeaderField: "X-Tenant") == "acme")

  // Requests made outside any chat share one id for the life of the provider.
  _ = try await provider.complete(
    ProviderRequest(model: "test-model", messages: [.user("hi")], stream: false))
  request = try #require(recorder.request)
  let standalone = try #require(request.value(forHTTPHeaderField: "x-opencode-session"))
  #expect(!standalone.isEmpty && standalone != "chat-1" && standalone != "{{session}}")
  _ = try await provider.complete(
    ProviderRequest(model: "test-model", messages: [.user("again")], stream: false))
  request = try #require(recorder.request)
  #expect(request.value(forHTTPHeaderField: "x-opencode-session") == standalone)
}

@Test("OpenAI-compatible provider lists voices and synthesizes speech")
func openAISpeech() async throws {
  let recorder = URLRequestRecorder()
  StubURLProtocol.install(forHost: "speech.example.test") { request in
    recorder.record(request, body: try requestBodyData(request))
    if request.url?.path.hasSuffix("/voices") == true {
      return try httpResponse(
        request,
        contentType: "application/json",
        body: #"{"data":["voice-z",{"id":"voice-a"},{"name":"voice-b"}]}"#)
    }
    return try httpResponse(request, contentType: "audio/wav", body: "RIFF")
  }
  defer { StubURLProtocol.reset(host: "speech.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://speech.example.test/v1/voices")),
      apiKey: "secret"),
    session: stubSession())
  #expect(try await provider.availableVoices() == ["voice-a", "voice-b", "voice-z"])
  #expect(recorder.request?.url?.absoluteString == "https://speech.example.test/v1/voices")

  let audio = try await provider.synthesizeSpeech(
    input: "hello", voice: "voice-a", responseFormat: "wav", model: "tts-model")
  #expect(audio == Data("RIFF".utf8))
  let request = try #require(recorder.request)
  let body = try jsonObject(try #require(recorder.body))
  #expect(request.url?.absoluteString == "https://speech.example.test/v1/audio/speech")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  #expect(request.value(forHTTPHeaderField: "Accept") == "audio/wav")
  #expect(body["input"] as? String == "hello")
  #expect(body["voice"] as? String == "voice-a")
  #expect(body["response_format"] as? String == "wav")
  #expect(body["model"] as? String == "tts-model")
}

@Test("Streaming requests accept providers that return one-shot JSON")
func openAIStreamingJSONFallback() async throws {
  StubURLProtocol.install(forHost: "buffered.example.test") { request in
    try httpResponse(
      request,
      contentType: "application/json",
      body: """
        {
          "choices": [{
            "message": {"content": "buffered response"},
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 2, "completion_tokens": 3}
        }
        """)
  }
  defer { StubURLProtocol.reset(host: "buffered.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://buffered.example.test/v1"))),
    session: stubSession())
  let response = try await provider.complete(
    ProviderRequest(
      model: "test-model",
      messages: [.user("hello")],
      stream: true))

  #expect(response.message.text == "buffered response")
  #expect(response.usage == TokenUsage(inputTokens: 2, outputTokens: 3))
  #expect(response.stopReason == .stop)
}

@Test("OpenAI-compatible provider accumulates streamed tool-call fragments")
func openAIStreamingToolCall() async throws {
  StubURLProtocol.install(forHost: "stream.example.test") { request in
    try httpResponse(
      request,
      contentType: "text/event-stream",
      body: """
        data: {"choices":[{"delta":{"reasoning_content":"checking "}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-2","function":{"name":"echo","arguments":"{\\"text\\":"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"hello\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":2,"total_tokens":4}}

        data: [DONE]

        """)
  }
  defer { StubURLProtocol.reset(host: "stream.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://stream.example.test/v1"))),
    session: stubSession())
  let response = try await provider.complete(
    ProviderRequest(
      model: "test-model",
      messages: [.user("echo hello")],
      tools: [ToolDefinition(name: "echo", description: "Echo")],
      stream: true))

  #expect(response.message.reasoning == "checking ")
  #expect(
    response.message.toolCalls == [
      ToolCall(id: "call-2", name: "echo", arguments: .object(["text": .string("hello")]))
    ])
  #expect(response.usage == TokenUsage(inputTokens: 2, outputTokens: 2, totalTokens: 4))
  #expect(response.stopReason == .toolCall)
}

@Test("Cancelling a streamed provider request cancels its URL session task")
func openAIStreamingCancellation() async throws {
  HangingURLProtocol.reset()
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [HangingURLProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: try #require(URL(string: "https://cancel.example.test/v1"))),
    session: session)
  let task = Task {
    try await provider.complete(
      ProviderRequest(model: "test-model", messages: [.user("wait")], stream: true))
  }

  for _ in 0..<100 where !HangingURLProtocol.didStart {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(HangingURLProtocol.didStart)
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("The cancelled provider request unexpectedly completed")
  } catch {
    let cocoaError = error as NSError
    #expect(error is CancellationError || cocoaError.code == NSURLErrorCancelled)
  }
  for _ in 0..<100 where !HangingURLProtocol.didStop {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(HangingURLProtocol.didStop)
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
  let runtime = AgentRuntime()
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
  #expect(result.transcript.contains { $0.role == .tool })
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
  #expect(report?.rewritten == 1)
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

@Test("Streamed usage is announced once, with the final figures, however often the server repeats it")
func openAIStreamingUsageOnce() async throws {
  StubURLProtocol.install(forHost: "usage.example.test") { request in
    try httpResponse(
      request,
      contentType: "text/event-stream",
      body: """
        data: {"choices":[{"delta":{"content":"a"}}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}

        data: {"choices":[{"delta":{"content":"b"}}],"usage":{"prompt_tokens":7,"completion_tokens":1,"total_tokens":8}}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9}}

        data: [DONE]

        """)
  }
  defer { StubURLProtocol.reset(host: "usage.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://usage.example.test/v1"))),
    session: stubSession())
  let seen = UsageEvents()
  let response = try await provider.complete(
    ProviderRequest(model: "test-model", messages: [.user("ab")], stream: true)
  ) { event in
    if case .usage(let usage) = event { await seen.append(usage) }
  }
  #expect(response.message.text == "ab")
  #expect(response.usage == TokenUsage(inputTokens: 7, outputTokens: 2, totalTokens: 9))
  #expect(await seen.all == [TokenUsage(inputTokens: 7, outputTokens: 2, totalTokens: 9)])
}

private actor UsageEvents {
  private(set) var all: [TokenUsage] = []
  func append(_ usage: TokenUsage) { all.append(usage) }
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

@Test("Subagents run with isolated transcripts and shared bounded lifecycle")
func subagentRun() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "spawn-1",
              name: AgentRuntime.subagentToolName,
              arguments: .object([
                "agent": .string("researcher"),
                "task": .string("Find the answer"),
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

@Test("Configuration loads providers, agents, secrets, and defaults")
func configurationLoading() async throws {
  let data = Data(
    """
    {
      "version": 1,
      "defaultAgent": "main",
      "providers": [{
        "id": "local",
        "kind": "openAICompatible",
        "baseURL": "http://127.0.0.1:8080/v1",
        "apiKeyEnvironment": "TEST_API_KEY"
      }],
      "agents": [{
        "id": "main",
        "provider": "local",
        "model": "model",
        "toolCallingStrategy": "json",
        "useToolProxy": true,
        "options": {"temperature": 0.2, "maxOutputTokens": 100},
        "subagentNames": ["helper"]
      }, {
        "id": "helper",
        "provider": "local",
        "model": "model"
      }],
      "approvals": {"confirm": "allow", "dangerous": "deny"}
    }
    """.utf8)
  let configuration = try JSONDecoder().decode(MaiConfiguration.self, from: data)
  try configuration.validate()
  #expect(configuration.defaultAgent == "main")
  #expect(configuration.approvals.confirm == .allow)
  #expect(configuration.agents[0].limits == AgentRunLimits())
  #expect(configuration.agents[0].limits.maxModelTurns == 60)
  #expect(configuration.agents[0].limits.maxToolCalls == 50)
  #expect(configuration.agents[0].limits.maxSubagents == 5)
  #expect(configuration.agents[0].limits.maxSubagentDepth == 5)
  #expect(configuration.agents[0].toolCallingStrategy == .json)
  #expect(configuration.agents[0].useToolProxy)
  #expect(configuration.agents[0].options.maxOutputTokens == 100)
  #expect(configuration.ui.toolResultForeground == "yellow")
  #expect(configuration.ui.toolResultLines == -1)
  let plugins = PluginRegistry()
  try await plugins.install(MaiOpenAIPlugin())
  let provider = try await plugins.makeProvider(
    from: configuration.providers[0],
    environment: ["TEST_API_KEY": "secret"])
  #expect(provider.descriptor.id == "local")
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

@Test("MCP client negotiates, catalogs, and preserves structured tool content")
func mcpClient() async throws {
  let recorder = MethodRecorder()
  StubURLProtocol.install(forHost: "mcp.example.test") { request in
    let body = try jsonObject(try requestBodyData(request))
    let method = try #require(body["method"] as? String)
    recorder.record(method)
    let id = body["id"] as? Int
    let payload: String
    switch method {
    case "initialize":
      payload = rpc(
        id: id,
        result: """
          {"protocolVersion":"2025-11-25","serverInfo":{"name":"Fixture"}}
          """)
    case "notifications/initialized":
      payload = ""
    case "tools/list":
      payload = rpc(
        id: id,
        result: """
          {"tools":[{"name":"lookup","description":"Lookup","inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]},"annotations":{"readOnlyHint":true}}]}
          """)
    case "resources/list":
      payload = rpc(
        id: id,
        result: """
          {"resources":[{"uri":"fixture://readme","name":"Readme","mimeType":"text/plain"}]}
          """)
    case "tools/call":
      payload = rpc(
        id: id,
        result: """
          {"content":[{"type":"text","text":"found"},{"type":"image","data":"AQI=","mimeType":"image/png"}],"structuredContent":{"count":1},"isError":false}
          """)
    default:
      payload = rpc(id: id, result: "{}")
    }
    return try httpResponse(
      request,
      contentType: "application/json",
      body: payload,
      headers: method == "initialize" ? ["Mcp-Session-Id": "session-1"] : [:])
  }
  defer { StubURLProtocol.reset(host: "mcp.example.test") }

  let client = MCPClient(
    configuration: MCPServerConfiguration(
      id: "fixture",
      url: try #require(URL(string: "https://mcp.example.test/mcp"))),
    session: stubSession())
  let catalog = try await client.connect()
  #expect(catalog.serverName == "Fixture")
  #expect(catalog.tools.first?.name == "fixture::lookup")
  #expect(catalog.resources.first?.uri == "fixture://readme")
  let agentTools = try await client.agentTools()
  #expect(agentTools.contains { $0.definition.name == "fixture::resources_read" })
  let tool = try #require(agentTools.first)
  let output = try await tool.call(
    arguments: .object(["q": .string("test")]),
    context: ToolExecutionContext(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
      modelTurn: 1))
  #expect(output.content.first == .text("found"))
  #expect(output.content.contains { if case .image = $0 { true } else { false } })
  #expect(output.structuredContent == .object(["count": .integer(1)]))
  #expect(recorder.methods.contains("notifications/initialized"))
  #expect(recorder.methods.contains("tools/call"))
}

private func objectSchema(required: [String]) -> JSONValue {
  .object([
    "type": .string("object"),
    "properties": .object(
      Dictionary(uniqueKeysWithValues: required.map { ($0, .object(["type": .string("string")])) })),
    "required": .array(required.map(JSONValue.string)),
  ])
}

private struct FixtureOCRProvider: OCRProvider {
  let descriptor = OCRProviderDescriptor(id: "fixture", displayName: "Fixture OCR")

  func recognize(_ request: OCRRequest) async throws -> OCRResult {
    #expect(request.filename == "receipt.jpg")
    #expect(request.mimeType == "image/jpeg")
    return OCRResult(markdown: "# Recognized\n\nHello from OCR")
  }
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

private func pngData(width: Int, height: Int) throws -> Data {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
  return data as Data
}

private func stubSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { throw stream.streamError ?? TestError.missingResponse }
    if count == 0 { break }
    result.append(contentsOf: buffer.prefix(count))
  }
  return result
}

private func httpResponse(
  _ request: URLRequest,
  status: Int = 200,
  contentType: String,
  body: String,
  headers: [String: String] = [:]
) throws -> (HTTPURLResponse, Data) {
  var allHeaders = headers
  allHeaders["Content-Type"] = contentType
  let url = try #require(request.url)
  let response = try #require(
    HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: allHeaders))
  return (response, Data(body.utf8))
}

private func rpc(id: Int?, result: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\(id ?? 0),\"result\":\(result)}"
}

private actor EventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

private actor ProviderEventRecorder {
  private(set) var events: [ProviderEvent] = []
  func append(_ event: ProviderEvent) { events.append(event) }
}

private actor ScriptedProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  private var responses: [ProviderResponse]
  /// Errors thrown instead of a response, by zero-based request index.
  private var failures: [Int: any Error]
  private(set) var requests: [ProviderRequest] = []

  init(
    responses: [ProviderResponse],
    capabilities: ProviderCapabilities = [.streaming, .nativeToolCalling, .imageInput],
    failures: [Int: any Error] = [:]
  ) {
    descriptor = ProviderDescriptor(
      id: "scripted",
      displayName: "Scripted",
      capabilities: capabilities)
    self.responses = responses
    self.failures = failures
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    if let failure = failures.removeValue(forKey: requests.count - 1) { throw failure }
    guard !responses.isEmpty else { throw TestError.missingResponse }
    let response = responses.removeFirst()
    if !response.message.reasoning.isEmpty {
      await emit(.reasoningDelta(response.message.reasoning))
    }
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}

private struct FixtureMCPSource: MCPToolSource {
  private var definitions: [ToolDefinition] {
    [
      ToolDefinition(name: "r2mcp::analyze", description: "Analyze a binary"),
      ToolDefinition(name: "r2mcp::disassemble", description: "Disassemble a function"),
    ]
  }

  func connect() async throws -> MCPServerCatalog {
    MCPServerCatalog(
      serverID: "r2mcp",
      serverName: "r2mcp",
      protocolVersion: "2025-03-26",
      tools: definitions,
      resources: [])
  }

  func agentTools() async throws -> [any AgentTool] {
    definitions.map { definition in
      ClosureTool(definition: definition) { _, _ in ToolOutput(text: "ok") }
        as any AgentTool
    }
  }

  func close() async {}
}

/// An orchestrator that delegates one file read, and the worker that performs
/// it. Both carry the file tool; only the orchestrator can start agents, and
/// that is how the fixture tells which side is answering.
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

private final class URLRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequest: URLRequest?
  private var storedBody: Data?
  var request: URLRequest? { lock.withLock { storedRequest } }
  var body: Data? { lock.withLock { storedBody } }
  func record(_ request: URLRequest, body: Data) {
    lock.withLock {
      storedRequest = request
      storedBody = body
    }
  }
}

private final class MethodRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedMethods: [String] = []
  var methods: [String] { lock.withLock { storedMethods } }
  func record(_ method: String) { lock.withLock { storedMethods.append(method) } }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

  static func install(forHost host: String, _ handler: @escaping Handler) {
    lock.withLock { handlers[host] = handler }
  }

  static func reset(host: String) { lock.withLock { handlers[host] = nil } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let host = try #require(request.url?.host)
      let handler = try Self.lock.withLock { try #require(Self.handlers[host]) }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var started = false
  nonisolated(unsafe) private static var stopped = false

  static var didStart: Bool { lock.withLock { started } }
  static var didStop: Bool { lock.withLock { stopped } }

  static func reset() {
    lock.withLock {
      started = false
      stopped = false
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.withLock { Self.started = true }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("data: ".utf8))
  }

  override func stopLoading() {
    Self.lock.withLock { Self.stopped = true }
  }
}

private enum TestError: Error { case missingResponse }

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

@Test(
  "Provider keeps native and inline reasoning in response order for streaming and buffered replies")
func openAIOrderedReasoning() async throws {
  StubURLProtocol.install(forHost: "ordered-reasoning.example.test") { request in
    let body = try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request))
    if body.objectValue?["stream"] == .bool(true) {
      return try httpResponse(
        request, contentType: "text/event-stream",
        body: """
          data: {"choices":[{"delta":{"reasoning_content":"first"}}]}

          data: {"choices":[{"delta":{"content":"answer<thi"}}]}

          data: {"choices":[{"delta":{"content":"nk>second</think>done"}}]}

          data: [DONE]

          """)
    }
    return try httpResponse(
      request, contentType: "application/json",
      body: """
        {"choices":[{"message":{"role":"assistant","reasoning_content":"first","content":"answer<think>second</think>done"},"finish_reason":"stop"}]}
        """)
  }
  defer { StubURLProtocol.reset(host: "ordered-reasoning.example.test") }
  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://ordered-reasoning.example.test/v1"))),
    session: stubSession())
  let expected: [ContentPart] = [
    .reasoning("first"), .text("answer"), .reasoning("second"), .text("done"),
  ]
  for stream in [false, true] {
    let events = OrderedReasoningEvents()
    let response = try await provider.complete(
      ProviderRequest(model: "test", messages: [.user("hi")], stream: stream)
    ) {
      await events.append($0)
    }
    #expect(response.message.content == expected)
    #expect(await events.text == ReasoningText.render(expected))
  }
}

private actor OrderedReasoningEvents {
  var output = ReasoningText()
  var text: String { output.rendered }
  func append(_ event: ProviderEvent) {
    switch event {
    case .textDelta(let text): output.append(.text(text))
    case .reasoningDelta(let text): output.append(.reasoning(text))
    default: break
    }
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
  #expect(await runtime.supervisor.processes().contains { $0.depth == 1 })
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
      $0.text == "Error: tool 'old-tool' is not available to this agent."
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
