import Foundation
import Testing

@testable import MaiCore
@testable import MaiOpenAI

// `/set effort` sets one level for every provider. The level becomes the fields
// each API family takes and a system prompt section, so a model with no
// reasoning control still hears how much care the task deserves.

@Test("Levels parse from the names people type and map to each API family's fields")
func effortMapsToProviderFields() {
  #expect(
    ReasoningEffort.names == [
      "automatic", "disabled", "minimal", "low", "medium", "high", "xhigh", "max",
    ])
  #expect(ReasoningEffort(name: "X-High") == .xhigh)
  #expect(ReasoningEffort(name: "maximum") == .max)
  #expect(ReasoningEffort(name: "h") == .high)
  #expect(ReasoningEffort(name: "minimal") == .minimal)

  let openAI = "https://api.openai.com/v1"
  #expect(
    ReasoningEffort.high.requestFields(model: "gpt-5", baseURL: openAI)
      == ["reasoning_effort": .string("high")])
  #expect(
    ReasoningEffort.max.requestFields(model: "gpt-5", baseURL: openAI)
      == ["reasoning_effort": .string("high")])
  #expect(
    ReasoningEffort.xhigh.requestFields(model: "gpt-5.2", baseURL: openAI)
      == ["reasoning_effort": .string("xhigh")])
  #expect(
    ReasoningEffort.max.requestFields(model: "gpt-5.1-codex-max", baseURL: openAI)
      == ["reasoning_effort": .string("xhigh")])
  #expect(ReasoningEffort.high.requestFields(model: "gpt-4o", baseURL: openAI).isEmpty)
  #expect(
    ReasoningEffort.low.requestFields(model: "o3-mini", baseURL: openAI)
      == ["reasoning_effort": .string("low")])

  #expect(
    ReasoningEffort.max.requestFields(model: "gpt-oss:20b", baseURL: "http://localhost:11434/v1")
      == ["think": .string("high"), "reasoning_effort": .string("high")])
  let qwenOnOllama = ReasoningEffort.low.requestFields(
    model: "qwen3:8b", provider: "ollama Thor", baseURL: "http://thor/v1")
  #expect(qwenOnOllama["think"] == .bool(true))
  #expect(qwenOnOllama["reasoning_effort"] == .string("low"))
  #expect(qwenOnOllama["chat_template_kwargs"] == .object(["enable_thinking": .bool(true)]))

  let dashscope = ReasoningEffort.medium.requestFields(
    model: "qwen3-max", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
  #expect(dashscope["enable_thinking"] == .bool(true))
  #expect(dashscope["thinking_budget"] == .integer(4096))

  let deepSeek = ReasoningEffort.high.requestFields(
    model: "deepseek-reasoner", baseURL: "https://api.deepseek.com/v1")
  #expect(deepSeek["thinking"] == .object(["type": .string("enabled")]))
  #expect(deepSeek["reasoning_effort"] == .string("high"))

  #expect(
    ReasoningEffort.xhigh.requestFields(
      model: "anthropic/claude", baseURL: "https://openrouter.ai/api/v1")["reasoning"]
      == .object([
        "effort": .string("xhigh"), "enabled": .bool(true), "exclude": .bool(false),
      ]))
  #expect(
    ReasoningEffort.xhigh.requestFields(model: "mistral", baseURL: "https://example.com/v1")
      == ["reasoning_effort": .string("high")])
}

@Test("The prompt section names the level, carries the guidance, and is absent when neither is set")
func effortPromptSection() {
  let section = ReasoningEffort.promptSection(effort: .max, guidance: "Check every edge case.")
  #expect(section?.hasPrefix("Reasoning effort: maximum. Take all the reasoning") == true)
  #expect(section?.hasSuffix("\n\nCheck every edge case.") == true)
  #expect(ReasoningEffort.promptSection(effort: nil, guidance: " ") == nil)
  #expect(
    ReasoningEffort.promptSection(
      for: GenerationOptions(reasoningEffort: "minimal", reasoningGuidance: "Be terse."))?
      .hasSuffix("Be terse.") == true)
  #expect(
    ReasoningEffort.promptSection(for: GenerationOptions(reasoningEffort: "low"))?
      .hasPrefix("Reasoning effort: low.") == true)
}

@Test("The OpenAI-compatible request carries the family's fields, and explicit extras win")
func openAIRequestCarriesEffort() throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(
      id: "thor", displayName: "Ollama on Thor", baseURL: URL(string: "http://thor:11434/v1")!))
  let mapped = try provider.makeURLRequest(
    ProviderRequest(
      model: "gpt-oss:20b", messages: [.user("hi")],
      options: GenerationOptions(reasoningEffort: "max"), stream: false),
    model: "gpt-oss:20b")
  let body = try JSONDecoder().decode(JSONValue.self, from: try #require(mapped.httpBody))
  #expect(body.objectValue?["think"] == .string("high"))
  #expect(body.objectValue?["reasoning_effort"] == .string("high"))

  let explicit = try provider.makeURLRequest(
    ProviderRequest(
      model: "gpt-oss:20b", messages: [.user("hi")],
      options: GenerationOptions(reasoningEffort: "max", additional: ["think": .string("low")]),
      stream: false),
    model: "gpt-oss:20b")
  let explicitBody = try JSONDecoder().decode(JSONValue.self, from: try #require(explicit.httpBody))
  #expect(explicitBody.objectValue?["think"] == .string("low"))

  let raw = try provider.makeURLRequest(
    ProviderRequest(
      model: "gpt-oss:20b", messages: [.user("hi")],
      options: GenerationOptions(reasoningEffort: "minimal"), stream: false),
    model: "gpt-oss:20b")
  let rawBody = try JSONDecoder().decode(JSONValue.self, from: try #require(raw.httpBody))
  #expect(rawBody.objectValue?["reasoning_effort"] == .string("low"))
  #expect(rawBody.objectValue?["think"] == .string("low"))
}

@Test("OpenAI-compatible requests put compacted system context first and join adjacent turns")
func openAIRequestNormalizesMessageOrder() throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: URL(string: "http://localhost:8000/v1")!))
  let request = try provider.makeURLRequest(
    ProviderRequest(
      model: "local-model",
      messages: [
        .system("Instructions"), .user("Earlier question"), .assistant("Earlier answer"),
        .system("Conversation summary (compacted): Earlier work"),
        .user("First queued message"), .user("Second queued message"),
        .assistant("First reply"), .assistant("Second reply"), .user("Next question"),
      ], stream: false),
    model: "local-model")
  let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
  let messages = try #require(body.objectValue?["messages"]?.arrayValue)
  #expect(messages.compactMap { $0.objectValue?["role"]?.stringValue } == [
    "system", "user", "assistant", "user", "assistant", "user",
  ])
  #expect(messages[0].objectValue?["content"] == .string(
    "Instructions\n\nConversation summary (compacted): Earlier work"))
  #expect(messages[3].objectValue?["content"] == .string(
    "First queued message\n\nSecond queued message"))
  #expect(messages[4].objectValue?["content"] == .string("First reply\n\nSecond reply"))
}

@Test("OpenAI-compatible requests keep native tool call and result boundaries")
func openAIRequestKeepsToolBoundaries() throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: URL(string: "http://localhost:8000/v1")!))
  let call = ToolCall(id: "call-1", name: "lookup", arguments: .object([:]))
  let request = try provider.makeURLRequest(
    ProviderRequest(
      model: "local-model",
      messages: [
        .user("Look it up"),
        AgentMessage(role: .assistant, content: [.toolCall(call)]),
        AgentMessage(role: .tool, content: [.toolResult(ToolResult(callID: "call-1", text: "Found"))]),
        .assistant("Here is the answer"),
      ], stream: false),
    model: "local-model")
  let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
  let messages = try #require(body.objectValue?["messages"]?.arrayValue)
  #expect(messages.compactMap { $0.objectValue?["role"]?.stringValue } == [
    "user", "assistant", "tool", "assistant",
  ])
  #expect(messages[1].objectValue?["tool_calls"]?.arrayValue?.count == 1)
  #expect(messages[2].objectValue?["tool_call_id"] == .string("call-1"))
}

@Test("A run at an effort level tells the model in the system prompt, after the instructions")
func runtimeInsertsEffortSection() async throws {
  let provider = EffortScriptedProvider()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let result = try await runtime.run(
    AgentRequest(
      provider: "effort-scripted",
      model: "fixture",
      messages: [.system("Be brief."), .user("Hi")],
      options: GenerationOptions(reasoningEffort: "high", reasoningGuidance: "Mind the edge cases.")
    )
  ) { _ in }
  #expect(result.response.text == "Hello.")
  let sent = try #require(await provider.requests.first)
  let systems = sent.messages.filter { $0.role == .system }.map(\.text)
  #expect(systems.first == "Be brief.")
  #expect(
    systems.contains {
      $0.hasPrefix("Reasoning effort: high.") && $0.hasSuffix("Mind the edge cases.")
    })
  #expect(sent.messages.last?.text == "Hi")
  #expect(sent.options.reasoningEffort == "high")
}

private actor EffortScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "effort-scripted", displayName: "Effort scripted", capabilities: [.streaming])
  private(set) var requests: [ProviderRequest] = []

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    return ProviderResponse(message: .assistant("Hello."), stopReason: .stop)
  }
}

@Test("Off is distinct from automatic and uses each provider's supported controls")
func effortOffAndAuto() throws {
  for family: ReasoningEffort.APIFamily in [
    .openAI, .openRouter, .deepSeek, .qwen, .ollama, .kimi, .kimiLocal, .minimax, .gemma,
    .gemini, .generic,
  ] {
    #expect(ReasoningEffort.automatic.requestFields(family: family, model: "qwen3").isEmpty)
  }
  #expect(
    ReasoningEffort.automatic.requestFields(family: .deepSeek, model: "deepseek-flash") == [
      "thinking": .object(["type": .string("disabled")])
    ])
  #expect(
    ReasoningEffort.automatic.requestFields(family: .deepSeek, model: "deepseek-v4-pro")
      .isEmpty)
  #expect(ReasoningEffort(name: "off") == .disabled)
  #expect(
    ReasoningEffort.disabled.requestFields(family: .qwen, model: "qwen3") == [
      "enable_thinking": .bool(false),
      "chat_template_kwargs": .object(["enable_thinking": .bool(false)]),
    ])
  #expect(
    ReasoningEffort.disabled.requestFields(family: .ollama, model: "qwen3")["think"] == .bool(false)
  )
  #expect(
    ReasoningEffort.disabled.requestFields(family: .deepSeek, model: "deepseek-chat") == [
      "thinking": .object(["type": .string("disabled")])
    ])
  #expect(
    ReasoningEffort.max.requestFields(family: .deepSeek, model: "deepseek-flash")[
      "reasoning_effort"] == .string("max"))
  #expect(
    ReasoningEffort.low.requestFields(family: .deepSeek, model: "deepseek-flash")[
      "reasoning_effort"] == .string("low"))
  for effort in [ReasoningEffort.medium, .high, .xhigh] {
    #expect(
      effort.requestFields(family: .deepSeek, model: "deepseek-flash")["reasoning_effort"]
        == .string("high"))
  }
  for model in ["gpt-5.1", "gpt-5.2", "gpt-5.4"] {
    #expect(
      ReasoningEffort.disabled.requestFields(family: .openAI, model: model)["reasoning_effort"]
        == .string("none"))
  }
  #expect(
    ReasoningEffort.disabled.requestFields(family: .openAI, model: "o3")["reasoning_effort"]
      == .string("low"))
  #expect(
    ReasoningEffort.disabled.requestFields(family: .openAI, model: "gpt-5")["reasoning_effort"]
      == .string("minimal"))
  #expect(
    ReasoningEffort.disabled.requestFields(family: .ollama, model: "gpt-oss")["think"]
      == .string("low"))
  #expect(ReasoningEffort.disabled.limitation(model: "gpt-oss") != nil)
  #expect(ReasoningEffort.disabled.limitation(model: "qwen3") == nil)
  #expect(ReasoningEffort.automatic.limitation(model: "deepseek-flash") != nil)
  let options = GenerationOptions(reasoningEffort: "off")
  let messages = ReasoningEffort.messages(
    [.system("Be useful."), .user("Hi")], options: options, model: "qwen3")
  #expect(messages.last?.text.hasSuffix("/no_think") == true)
  #expect(messages.first?.text == "Be useful.")
  let provider = OpenAICompatibleProvider(
    configuration: .init(
      id: "local", displayName: "local",
      baseURL: URL(string: "http://localhost:11434/v1")!))
  let request = try provider.makeURLRequest(
    ProviderRequest(
      model: "qwen3", messages: [.user("Hi")],
      options: options, stream: false), model: "qwen3")
  let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
  #expect(body.objectValue?["think"] == .bool(false))
  #expect(
    body.objectValue?["messages"]?.arrayValue?.last?.objectValue?["content"]?.stringValue?
      .hasSuffix("/no_think") == true)
}

@Test("DeepSeek Flash is non-thinking by default and explicit fields still win")
func deepSeekFlashAutomaticRequest() throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: URL(string: "https://api.deepseek.com/v1")!))

  func body(options: GenerationOptions = .init()) throws -> [String: JSONValue] {
    let request = try provider.makeURLRequest(
      ProviderRequest(
        model: "deepseek-flash", messages: [.user("Hi")], options: options, stream: false),
      model: "deepseek-flash")
    let data = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    return try #require(decoded.objectValue)
  }

  #expect(try body()["thinking"] == .object(["type": .string("disabled")]))
  let low = try body(options: GenerationOptions(reasoningEffort: "low"))
  #expect(low["thinking"] == .object(["type": .string("enabled")]))
  #expect(low["reasoning_effort"] == .string("low"))
  #expect(
    try body(options: GenerationOptions(additional: [
      "thinking": .object(["type": .string("enabled")])
    ]))["thinking"] == .object(["type": .string("enabled")]))
  let customEffort = try body(options: GenerationOptions(additional: [
    "reasoning_effort": .string("low")
  ]))
  #expect(customEffort["thinking"] == nil)
  #expect(customEffort["reasoning_effort"] == .string("low"))
}

@Test("DeepSeek reasoning history is sent only with tools")
func deepSeekReasoningHistoryFollowsTools() throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: URL(string: "https://api.deepseek.com/v1")!))
  let message = AgentMessage(
    role: .assistant,
    content: [.reasoning("old thought"), .text("answer")])

  func sentMessage(tools: [ToolDefinition]) throws -> [String: JSONValue] {
    let request = try provider.makeURLRequest(
      ProviderRequest(
        model: "deepseek-flash", messages: [message], tools: tools, stream: false),
      model: "deepseek-flash")
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    return try #require(body.objectValue?["messages"]?.arrayValue?.first?.objectValue)
  }

  #expect(try sentMessage(tools: [])["reasoning_content"] == nil)
  #expect(
    try sentMessage(tools: [ToolDefinition(name: "echo", description: "Echo")])[
      "reasoning_content"] == .string("old thought"))
  #expect(
    !ReasoningEffort.requiresReasoningHistory(
      model: "deepseek-flash", baseURL: "https://api.deepseek.com/v1", hasTools: false))
  #expect(
    ReasoningEffort.requiresReasoningHistory(
      model: "deepseek-flash", baseURL: "https://api.deepseek.com/v1", hasTools: true))
}

@Test("Thinking presentation survives old configurations and leaves generation independent")
func thinkingConfiguration() throws {
  let legacy = try JSONDecoder().decode(ConfiguredTerminalUI.self, from: Data("{}".utf8))
  #expect(legacy.thinking == .status)
  for mode in ThinkingDisplay.allCases {
    let ui = ConfiguredTerminalUI(thinking: mode)
    #expect(
      try JSONDecoder().decode(ConfiguredTerminalUI.self, from: JSONEncoder().encode(ui)) == ui)
  }
  #expect(
    try JSONDecoder().decode(ReasoningEffort.self, from: Data("\"disabled\"".utf8)) == .disabled)
}

@Test("Vendor controls distinguish Kimi versions, MiniMax, Gemma and Gemini")
func effortVendorMatrix() {
  let off = ReasoningEffort.disabled
  let high = ReasoningEffort.high
  #expect(
    off.requestFields(model: "kimi-k2.5", baseURL: "https://api.moonshot.ai/v1") == [
      "thinking": .object(["type": .string("disabled")])
    ])
  #expect(
    high.requestFields(model: "kimi-k2.6", baseURL: "https://api.kimi.ai/v1") == [
      "thinking": .object(["type": .string("enabled")])
    ])
  #expect(
    off.requestFields(model: "moonshotai/Kimi-K2.5", baseURL: "http://localhost:8000/v1") == [
      "chat_template_kwargs": .object(["thinking": .bool(false)])
    ])
  #expect(off.requestFields(family: .kimi, model: "kimi-k2.7-code").isEmpty)
  #expect(off.requestFields(family: .kimi, model: "kimi-k3")["reasoning_effort"] == .string("low"))
  #expect(
    ReasoningEffort.max.requestFields(family: .kimi, model: "kimi-k3")["reasoning_effort"]
      == .string("max"))
  #expect(off.requestFields(family: .minimax, model: "MiniMax-M2.5").isEmpty)
  #expect(
    off.requestFields(family: .minimax, model: "MiniMax-M3")["thinking"]
      == .object(["type": .string("disabled")]))
  #expect(
    high.requestFields(family: .minimax, model: "MiniMax-M3")["thinking"]
      == .object(["type": .string("adaptive")]))
  #expect(off.requestFields(family: .gemma, model: "gemma-3-4b-it").isEmpty)
  #expect(
    off.requestFields(family: .gemma, model: "google/gemma-4-31B-it")["chat_template_kwargs"]
      == .object(["enable_thinking": .bool(false)]))
  #expect(off.templateContext(model: "gemma-4-31b-it")?["enable_thinking"] as? Bool == false)
  #expect(off.templateContext(model: "Kimi-K2.5")?["thinking"] as? Bool == false)
  #expect(
    off.requestFields(family: .gemini, model: "gemini-2.5-flash")["reasoning_effort"]
      == .string("none"))
  #expect(
    off.requestFields(family: .gemini, model: "gemini-2.5-pro")["reasoning_effort"]
      == .string("low"))
  #expect(
    off.requestFields(family: .gemini, model: "gemini-3-flash")["reasoning_effort"]
      == .string("low"))
  for model in ["kimi-k3", "kimi-k2.7-code", "MiniMax-M2.5"] {
    #expect(off.limitation(model: model) != nil)
    #expect(ReasoningEffort.requiresReasoningHistory(model: model))
  }
  #expect(
    high.requestFields(model: "gemma4", baseURL: "http://localhost:11434/v1")["think"]
      == .bool(true))
  #expect(
    off.requestFields(model: "kimi-k2.5", baseURL: "https://openrouter.ai/api/v1")["reasoning"]
      != nil)
}

@Test("MiniMax continuation carries tagged reasoning while Kimi carries reasoning_content")
func reasoningContinuationBodies() throws {
  let message = AgentMessage(
    role: .assistant,
    content: [
      .reasoning("first"), .text("answer"), .reasoning("second"),
      .toolCall(ToolCall(id: "call", name: "echo", arguments: .object([:]))),
    ])
  for (host, model) in [("api.minimax.io", "MiniMax-M2.5"), ("api.moonshot.ai", "kimi-k2.6")] {
    let provider = OpenAICompatibleProvider(
      configuration: .init(baseURL: URL(string: "https://\(host)/v1")!))
    let request = try provider.makeURLRequest(
      ProviderRequest(model: model, messages: [message], stream: false), model: model)
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    let sent = try #require(body.objectValue?["messages"]?.arrayValue?.first?.objectValue)
    #expect(sent["tool_calls"]?.arrayValue?.count == 1)
    if host.contains("minimax") {
      #expect(sent["content"] == .string(ReasoningText.render(message.content)))
      #expect(sent["reasoning_content"] == nil)
    } else {
      #expect(sent["reasoning_content"] == .string(message.reasoning))
    }
  }
}
