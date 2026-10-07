import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import MaiCore
@testable import MaiOpenAI

@testable import MaiTestSupport

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

@Test("Anthropic model catalog sends its API version and follows cursor pages")
func anthropicModelCatalog() async throws {
  let first = URLRequestRecorder()
  let second = URLRequestRecorder()
  StubURLProtocol.install(forHost: "api.anthropic.com") { request in
    let afterID = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "after_id" })?.value
    if afterID == nil {
      first.record(request, body: Data())
      return try httpResponse(
        request, contentType: "application/json",
        body: """
          {"data":[{"id":"claude-z","display_name":"Claude Z"}],
           "has_more":true,"last_id":"claude-z"}
          """)
    }
    second.record(request, body: Data())
    return try httpResponse(
      request, contentType: "application/json",
      body: """
        {"data":[{"id":"claude-a","capabilities":{"image_input":{"supported":true}}}],
         "has_more":false,"last_id":"claude-a"}
        """)
  }
  defer { StubURLProtocol.reset(host: "api.anthropic.com") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://api.anthropic.com/v1")),
      apiKey: "secret"), session: stubSession())
  let models = try await provider.availableModels()

  #expect(models.map(\.id) == ["claude-a", "claude-z"])
  #expect(models.first?.capabilities.contains(.imageInput) == true)
  #expect(models.first?.inputModalities == ["text", "image"])
  for request in [try #require(first.request), try #require(second.request)] {
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
  }
  #expect(second.request?.url?.absoluteString == "https://api.anthropic.com/v1/models?after_id=claude-z")
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

@Test("OpenAI-compatible provider tolerates repeated full-argument chunks from MiniMax-M3")
func openAIStreamingToolCallResendsArguments() async throws {
  // MiniMax-M3 streaming repeats the full tool-call JSON in each chunk instead
  // of emitting OpenAI-style argument fragments. Concatenating those chunks
  // produces invalid JSON, so the provider must pick the longest valid chunk
  // and ignore the shorter prefixes that would invalidate it.
  StubURLProtocol.install(forHost: "stream.minimax.example.test") { request in
    try httpResponse(
      request,
      contentType: "text/event-stream",
      body: """
        data: {"choices":[{"delta":{"reasoning_content":"planning "}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-2","function":{"name":"echo","arguments":"{\\"text\\": \\"hello\\"}"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"text\\": \\"hello\\"}"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"text\\": \\"hello\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":2,"total_tokens":4}}

        data: [DONE]

        """)
  }
  defer { StubURLProtocol.reset(host: "stream.minimax.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      id: .openAI,
      displayName: "minimax",
      baseURL: try #require(URL(string: "https://stream.minimax.example.test/v1"))),
    session: stubSession())
  let response = try await provider.complete(
    ProviderRequest(
      model: "MiniMax-M3",
      messages: [.user("echo hello")],
      tools: [ToolDefinition(name: "echo", description: "Echo")],
      stream: true))

  #expect(response.message.reasoning == "planning ")
  #expect(
    response.message.toolCalls == [
      ToolCall(id: "call-2", name: "echo", arguments: .object(["text": .string("hello")]))
    ])
  #expect(response.stopReason == .toolCall)
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

@Test("Tool argument decoding preserves newlines and literal backslashes", arguments: [false, true])
func openAIToolArgumentEscapes(stream: Bool) async throws {
  let host = "escapes-\(stream).example.test"
  // One JSON escape means a newline; two mean a literal backslash followed by n.
  let rawArguments = #"{"find":"one\ntwo","replace":"one\\ntwo","quote":"\"","escapedQuote":"\\\""}"#
  StubURLProtocol.install(forHost: host) { request in
    func payload(_ fragment: String) -> String {
      let call: JSONValue = .object([
        "index": .integer(0), "id": .string("patch"), "type": .string("function"),
        "function": .object(["name": .string("files_patch"), "arguments": .string(fragment)]),
      ])
      return JSONValue.object([
        "choices": .array([.object([
          stream ? "delta" : "message": .object(["tool_calls": .array([call])]),
        ])]),
      ]).compactJSONString
    }
    // Split inside the first escape sequence to exercise stream accumulation too.
    let split = rawArguments.index(after: rawArguments.firstIndex(of: "\\")!)
    let body = stream
      ? "data: \(payload(String(rawArguments[..<split])))\n\ndata: \(payload(String(rawArguments[split...])))\n\ndata: [DONE]\n\n"
      : payload(rawArguments)
    return try httpResponse(
      request, contentType: stream ? "text/event-stream" : "application/json", body: body)
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: try #require(URL(string: "https://\(host)/v1"))),
    session: stubSession())
  let response = try await provider.complete(ProviderRequest(
    model: "test-model", messages: [.user("patch")],
    tools: [ToolDefinition(name: "files_patch", description: "Patch")], stream: stream))
  let arguments = try #require(response.message.toolCalls.first?.arguments.objectValue)
  #expect(arguments["find"] == .string("one\ntwo"))
  #expect(arguments["replace"] == .string(#"one\ntwo"#))
  #expect(arguments["quote"] == .string("\""))
  #expect(arguments["escapedQuote"] == .string("\\\""))
}

@Test("Native streaming preserves object-shaped fragments inside arguments", arguments: [
  [#"{"text":"before "#, "{}", #" after"}"#],
  [#"{"payload":["#, #"{"nested":true}"#, "]}"],
  [#"{"payload":"#, #"{"payload":true}"#, "}"],
])
func openAIStreamingNestedObjectFragments(fragments: [String]) async throws {
  let host = "nested-fragments-\(UUID().uuidString).example.test"
  StubURLProtocol.install(forHost: host) { request in
    let chunks = fragments.map { fragment in
      let function: JSONValue = .object([
        "name": .string("echo"), "arguments": .string(fragment),
      ])
      let payload: JSONValue = .object(["choices": .array([.object([
        "delta": .object(["tool_calls": .array([.object([
          "index": .integer(0), "id": .string("nested"), "function": function,
        ])])]),
      ])])])
      return "data: \(payload.compactJSONString)\n\n"
    }.joined()
    return try httpResponse(request, contentType: "text/event-stream", body: chunks + "data: [DONE]\n\n")
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: try #require(URL(string: "https://\(host)/v1"))),
    session: stubSession())
  let response = try await provider.complete(ProviderRequest(
    model: "fixture", messages: [.user("echo")],
    tools: [ToolDefinition(name: "echo", description: "Echo")], stream: true))
  let expected = try JSONDecoder().decode(JSONValue.self, from: Data(fragments.joined().utf8))
  #expect(response.message.toolCalls == [ToolCall(id: "nested", name: "echo", arguments: expected)])
}

@Test("Native streaming associates unindexed chunks by call ID or array position", arguments: [false, true])
func openAIStreamingUnindexedCalls(reordered: Bool) async throws {
  let host = "unindexed-\(reordered).example.test"
  StubURLProtocol.install(forHost: host) { request in
    func payload(_ calls: [[String: JSONValue]]) -> String {
      let value: JSONValue = .object(["choices": .array([.object([
        "delta": .object(["tool_calls": .array(calls.map(JSONValue.object))]),
      ])])])
      return "data: \(value.compactJSONString)\n\n"
    }
    let first = (0..<2).map { index -> [String: JSONValue] in
      ["id": .string("call-\(index)"), "function": .object([
        "name": .string("echo"), "arguments": .string(#"{"text":"#),
      ])]
    }
    let last = (reordered ? [1, 0] : [0, 1]).map { index -> [String: JSONValue] in
      var call: [String: JSONValue] = ["function": .object([
        "arguments": .string("\"value-\(index)\"}"),
      ])]
      if reordered { call["id"] = .string("call-\(index)") }
      return call
    }
    return try httpResponse(request, contentType: "text/event-stream",
      body: payload(first) + payload(last) + "data: [DONE]\n\n")
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: try #require(URL(string: "https://\(host)/v1"))),
    session: stubSession())
  let response = try await provider.complete(ProviderRequest(
    model: "fixture", messages: [.user("echo")],
    tools: [ToolDefinition(name: "echo", description: "Echo")], stream: true))
  #expect(response.message.toolCalls == (0..<2).map {
    ToolCall(id: "call-\($0)", name: "echo", arguments: .object(["text": .string("value-\($0)")]))
  })
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

@Test("Malformed native arguments receive feedback without blind retries", arguments: [false, true])
func malformedNativeArgumentsAreRepaired(stream: Bool) async throws {
  let host = stream ? "repair-stream.example.test" : "repair-json.example.test"
  StubURLProtocol.install(forHost: host) { request in
    let body = try jsonObject(try requestBodyData(request))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let repaired = messages.contains { ($0["content"] as? String)?.contains("Tool call rejected") == true }
    if repaired {
      return try httpResponse(request, contentType: "application/json", body:
        #"{"choices":[{"message":{"content":"Corrected."},"finish_reason":"stop"}]}"#)
    }
    if stream {
      return try httpResponse(request, contentType: "text/event-stream", body: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"bad","function":{"name":"echo","arguments":"{"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """)
    }
    return try httpResponse(request, contentType: "application/json", body:
      #"{"choices":[{"message":{"tool_calls":[{"id":"bad","function":{"name":"echo","arguments":"{"}}]},"finish_reason":"tool_calls"}]}"#)
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = OpenAICompatibleProvider(configuration: .init(
    baseURL: try #require(URL(string: "https://\(host)/v1"))), session: stubSession())
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(
    definition: ToolDefinition(name: "echo", description: "Echo")
  ) { _, _ in
    Issue.record("Invalid arguments must never execute")
    return ToolOutput(text: "unexpected")
  })
  let result = try await runtime.run(AgentRequest(
    provider: provider.descriptor.id, model: "fixture", messages: [.user("echo")],
    toolNames: ["echo"], stream: stream, retry: .none))
  #expect(result.modelTurns == 2)
  #expect(result.toolCalls == 0)
  #expect(result.response.text == "Corrected.")
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

private actor ProviderEventRecorder {
  private(set) var events: [ProviderEvent] = []
  func append(_ event: ProviderEvent) { events.append(event) }
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

@Test("System One sends choices and validates decisions without fabricating arguments")
func systemOneDecisionTransport() async throws {
  StubURLProtocol.install(forHost: "systemone.example.test") { request in
    #expect(request.url?.path == "/v1/systemone")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(request.value(forHTTPHeaderField: "X-Session") == "decision-chat")
    let data = try requestBodyData(request)
    let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
    #expect(root?["model"] == .string("tev1:0.8b"))
    #expect(root?["messages"] == nil)
    #expect(
      root?["questions"]?.objectValue?["tool"]?.objectValue?["criteria"]?.objectValue?.count == 2)
    return try httpResponse(
      request, contentType: "application/json",
      body:
        #"{"answers":{"tool":{"choice":"tool_0","confidence":0.9}},"usage":{"input_tokens":12,"output_tokens":1}}"#
    )
  }
  defer { StubURLProtocol.reset(host: "systemone.example.test") }
  let provider = SystemOneProvider(
    configuration: .init(
      baseURL: URL(string: "https://systemone.example.test/v1/systemone")!, apiKey: "secret",
      additionalHeaders: ["X-Session": "{{session}}"]), session: stubSession())
  let response = try await provider.complete(
    .init(
      model: "tev1:0.8b", messages: [.user("read a file")],
      tools: [ToolDefinition(name: "read", description: "Read a file", parameters: [])],
      sessionID: "decision-chat"))
  #expect(response.toolDecision == .tool("read"))
  #expect(response.message.toolCalls.isEmpty)
  #expect(response.usage?.totalTokens == 13)
}

@Test("System One catalog uses decision capabilities, including renamed local models")
func systemOneCatalog() async throws {
  StubURLProtocol.install(forHost: "decision-models.example.test") { request in
    let body: String
    if request.url?.path == "/api/tags" {
      body = #"{"models":[{"name":"gpt-oss:20b"},{"name":"my-router"}]}"#
    } else {
      #expect(request.url?.path == "/api/show")
      let data = try requestBodyData(request)
      let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
      body =
        root?["model"] == .string("my-router")
        ? #"{"capabilities":["completion","decision"],"details":{"format":"gguf"}}"#
        : #"{"capabilities":["completion","tools"],"details":{"format":"gguf"}}"#
    }
    return try httpResponse(request, contentType: "application/json", body: body)
  }
  defer { StubURLProtocol.reset(host: "decision-models.example.test") }
  let provider = SystemOneProvider(
    configuration: .init(
      baseURL: URL(string: "https://decision-models.example.test/v1")!), session: stubSession())
  #expect(try await provider.availableModels().map(\.id) == ["my-router"])
}

@Test("System One rejects unknown choices and preserves endpoint errors")
func systemOneInvalidResponse() async throws {
  StubURLProtocol.install(forHost: "bad-decision.example.test") { request in
    try httpResponse(
      request, contentType: "application/json",
      body: #"{"answers":{"tool":{"choice":"nonexistent"}}}"#)
  }
  defer { StubURLProtocol.reset(host: "bad-decision.example.test") }
  let provider = SystemOneProvider(
    configuration: .init(
      baseURL: URL(string: "https://bad-decision.example.test")!), session: stubSession())
  await #expect(throws: OpenAICompatibleProviderError.self) {
    try await provider.complete(
      .init(
        model: "tev1", messages: [.user("hello")],
        tools: [ToolDefinition(name: "read", description: "read", parameters: [])]))
  }
}

@Test("System One bounds large catalogs and keeps the latest request after many tool results")
func systemOneLargeCatalog() async throws {
  StubURLProtocol.install(forHost: "large-decision.example.test") { request in
    let data = try requestBodyData(request)
    let root = try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    #expect(root["state"]?.stringValue?.contains("original task") == true)
    let criteria = try #require(
      root["questions"]?.objectValue?["tool"]?.objectValue?["criteria"]?.objectValue)
    #expect((2...24).contains(criteria.count))
    // Keep the final tool even though it lies beyond the first batch.
    let choice =
      criteria.first { $0.value.stringValue?.hasPrefix("tool46:") == true }?.key ?? "none"
    return try httpResponse(
      request, contentType: "application/json",
      body: #"{"answers":{"tool":{"choice":""# + choice + #""}}}"#)
  }
  defer { StubURLProtocol.reset(host: "large-decision.example.test") }
  let provider = SystemOneProvider(
    configuration: .init(
      baseURL: URL(string: "https://large-decision.example.test")!), session: stubSession())
  let response = try await provider.complete(
    .init(
      model: "tev1",
      messages: [.user("original task")]
        + (0..<12).map { .assistant("result \($0)") },
      tools: (0..<47).map {
        ToolDefinition(name: "tool\($0)", description: "A tool", parameters: [])
      }))
  #expect(response.toolDecision == .tool("tool46"))
  #expect(response.usage?.isEstimated == true)
}

@Test(
  "System One approval uses a harm question and blocks uncertainty", arguments: [0.05, 0.5, 0.99])
func systemOneApprovalHarm(probability: Double) async throws {
  let host = "harm-\(probability).example.test"
  StubURLProtocol.install(forHost: host) { request in
    let body = try #require(
      try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request)).objectValue)
    #expect(request.url?.path == "/v1/systemone")
    #expect(body["questions"]?.objectValue?["harm"]?.objectValue?["type"] == .string("noul"))
    #expect(body["state"]?.objectValue?["arguments"]?.objectValue?["script"] == .string("rm -rf ~"))
    return try httpResponse(
      request, contentType: "application/json",
      body: "{\"answers\":{\"harm\":{\"noul\":\(probability)}}}")
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = SystemOneProvider(
    configuration: .init(baseURL: URL(string: "https://\(host)")!), session: stubSession())
  let arguments: JSONValue = .object(["script": .string("rm -rf ~")])
  let review = ToolApprovalReview(
    tool: .init(name: "run_shell", description: "shell"), arguments: arguments,
    task: "list files",
    environment: .init(
      workingDirectory: "/workspace", allowedPaths: ["/workspace"], sandbox: "test"))
  let response = try await provider.complete(
    SmartToolApproval.request(review: review, model: "nimble"))
  let decision = SmartToolApproval.decision(response, arguments: arguments)
  if probability < 0.5 {
    #expect(decision == .approve(arguments: arguments))
  } else if case .deny = decision {
  } else {
    Issue.record("Harmful or uncertain tool approved")
  }
}

@Test("Malformed System One harm responses fail closed")
func systemOneApprovalInvalid() async throws {
  StubURLProtocol.install(forHost: "bad-harm.example.test") { request in
    try httpResponse(
      request, contentType: "application/json", body: #"{"answers":{"harm":{"noul":2}}}"#)
  }
  defer { StubURLProtocol.reset(host: "bad-harm.example.test") }
  let provider = SystemOneProvider(
    configuration: .init(baseURL: URL(string: "https://bad-harm.example.test")!),
    session: stubSession())
  let review = ToolApprovalReview(
    tool: .init(name: "run_shell", description: "shell"), arguments: .object([:]),
    task: "test", environment: .current)
  await #expect(throws: OpenAICompatibleProviderError.self) {
    try await provider.complete(SmartToolApproval.request(review: review, model: "tev1"))
  }
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
  #expect(configuration.approvals.mode == .ask)
  #expect(configuration.agents[0].limits == AgentRunLimits())
  #expect(configuration.agents[0].limits.maxModelTurns == 60)
  #expect(configuration.agents[0].limits.maxToolCalls == 50)
  #expect(configuration.agents[0].limits.maxSubagents == 5)
  #expect(configuration.agents[0].limits.maxSubagentDepth == 5)
  #expect(configuration.agents[0].toolCallingStrategy == .json)
  #expect(configuration.agents[0].useToolProxy)
  #expect(configuration.agents[0].options.maxOutputTokens == 100)
  #expect(configuration.ui.toolResultForeground == "yellow")
  #expect(configuration.ui.toolResultLines == .all)
  let plugins = PluginRegistry()
  try await plugins.install(MaiOpenAIPlugin())
  let provider = try await plugins.makeProvider(
    from: configuration.providers[0],
    environment: ["TEST_API_KEY": "secret"])
  #expect(provider.descriptor.id == "local")
}
