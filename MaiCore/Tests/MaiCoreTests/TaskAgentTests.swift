import Foundation
import Testing

@testable import MaiCore

@Test("Task assignments persist, preserve model IDs, and clear when an agent is removed")
func taskAgentConfiguration() throws {
  let main = AgentDefinition(id: "main", instructions: "main", provider: "remote", model: "large")
  var configuration = MaiConfiguration(
    defaultAgent: "main",
    providers: [
      ConfiguredProvider(id: "remote", kind: .hello),
      ConfiguredProvider(id: "local", kind: .hello),
    ], agents: [main])
  try configuration.assignTask(.compact, selector: "local::org/small:latest", current: main)
  let compact = try #require(
    configuration.agents.first { $0.id == configuration.taskAgents.compact })
  #expect(compact.provider == "local")
  #expect(compact.model == "org/small:latest")
  #expect(compact.toolNames.isEmpty)
  try configuration.assignTask(.tool, selector: compact.id, current: main)
  let decoded = try JSONDecoder().decode(MaiConfiguration.self, from: configuration.encoded())
  #expect(decoded == configuration)
  try decoded.validate()
  configuration.removeAgent(compact.id)
  #expect(configuration.taskAgents == TaskAgentAssignments())
  try configuration.validate()
  try configuration.assignTask(.tool, selector: "small:7b", current: main)
  #expect(configuration.agents.last?.model == "small:7b")
  try configuration.assignTask(.tool, selector: nil, current: main)
  #expect(configuration.taskAgents.tool == nil)
  #expect(throws: MaiConfigurationError.unknownProvider("missing")) {
    try configuration.assignTask(.compact, selector: "missing::small", current: main)
  }
}

@Test("Model shorthand never rewrites an unrelated agent with a generated name")
func taskAgentShorthandCollision() throws {
  let main = AgentDefinition(
    id: "task-tool", instructions: "primary", provider: "local", model: "large")
  var configuration = MaiConfiguration(
    defaultAgent: main.id,
    providers: [ConfiguredProvider(id: "local", kind: .hello)], agents: [main])
  try configuration.assignTask(.tool, selector: "small", current: main)
  #expect(configuration.agents.first == main)
  #expect(configuration.taskAgents.tool == "task-tool-2")
  try configuration.assignTask(.tool, selector: "smaller", current: main)
  #expect(configuration.agents.count == 2)
  #expect(configuration.agents.last?.model == "smaller")
}

@Test("Task agent references are validated; older configurations inherit the current agent")
func taskAgentValidation() throws {
  let legacy = try JSONDecoder().decode(MaiConfiguration.self, from: Data("{}".utf8))
  #expect(legacy.taskAgents == TaskAgentAssignments())
  var configuration = legacy
  configuration.taskAgents.tool = "missing"
  #expect(throws: MaiConfigurationError.unknownAgent("missing")) { try configuration.validate() }
  configuration.providers = [ConfiguredProvider(id: "local", kind: .hello)]
  configuration.agents = [
    AgentDefinition(id: "missing", isEnabled: false, instructions: "", provider: "local", model: "")
  ]
  #expect(throws: MaiConfigurationError.disabledTaskAgent("missing")) {
    try configuration.validate()
  }
}

@Test(
  "Tool decisions use a specialist then the primary writes the final answer",
  arguments: [false, true])
func taskAgentToolRouting(textProtocol: Bool) async throws {
  let toolCall = ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("evidence")]))
  let first =
    textProtocol
    ? ProviderResponse(
      message: .assistant("{\"tool\":\"echo\",\"arguments\":{\"text\":\"evidence\"}}"))
    : ProviderResponse(message: AgentMessage(role: .assistant, content: [.toolCall(toolCall)]))
  let primary = TaskFixtureProvider(
    id: "primary", responses: [.init(message: .assistant("final answer"))])
  let specialist = TaskFixtureProvider(
    id: "local", responses: [first, .init(message: .assistant("private draft"))])
  let runtime = AgentRuntime()
  try await runtime.register(primary)
  try await runtime.register(specialist)
  try await runtime.register(tool: taskEchoTool())
  try await runtime.register(
    agent: AgentDefinition(
      id: "fast", instructions: "specialist instructions", provider: "local", model: "small",
      toolNames: ["forbidden"], options: GenerationOptions(reasoningEffort: "low"),
      toolCallingStrategy: textProtocol ? .json : .native))
  await runtime.configureTaskAgents(.init(tool: "fast"))
  let events = TaskFixtureEvents()
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", model: "large",
      messages: [.system("primary instructions"), .user("look it up")],
      toolNames: ["echo"], options: GenerationOptions(reasoningEffort: "high"), retry: .none,
      sessionID: "same-session")
  ) { event in await events.append(event) }
  #expect(result.response.text == "final answer")
  #expect(result.toolCalls == 1)
  #expect(result.modelTurns == 3)
  let localRequests = await specialist.requests
  #expect(localRequests.count == 2)
  #expect(localRequests.allSatisfy { $0.model == "small" && $0.options.reasoningEffort == "low" })
  #expect(localRequests.allSatisfy { $0.sessionID == "same-session" })
  #expect(!localRequests[0].tools.contains { $0.name == "forbidden" })
  #expect(localRequests[0].messages.contains { $0.text.contains("specialist instructions") })
  let mainRequest = try #require(await primary.requests.first)
  #expect(mainRequest.model == "large")
  #expect(mainRequest.options.reasoningEffort == "high")
  #expect(mainRequest.tools.isEmpty)
  #expect(mainRequest.messages.flatMap(\.toolResults).contains { $0.text.contains("evidence") })
  #expect(!mainRequest.messages.contains { $0.text.contains("private draft") })
  #expect(await events.text == "final answer")
}

@Test("Automatic compaction uses the assigned provider, model, prompt and effort")
func taskAgentAutomaticCompaction() async throws {
  let primary = TaskFixtureProvider(
    id: "primary", responses: [.init(message: .assistant("answer"))])
  let compact = TaskFixtureProvider(id: "local", responses: [.init(message: .assistant("summary"))])
  let runtime = AgentRuntime()
  try await runtime.register(primary)
  try await runtime.register(compact)
  try await runtime.register(
    agent: AgentDefinition(
      id: "summarizer", instructions: "keep all paths", provider: "local", model: "tiny",
      options: GenerationOptions(reasoningEffort: "disabled")))
  await runtime.configureTaskAgents(.init(compact: "summarizer"))
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", model: "large",
      messages: [
        .user(String(repeating: "old context ", count: 100)), .assistant("old answer"),
        .user("continue"),
      ],
      retry: .none, autocompact: .init(tokens: 1), sessionID: "chat-session"))
  #expect(result.response.text == "answer")
  let request = try #require(await compact.requests.first)
  #expect(request.model == "tiny")
  #expect(request.tools.isEmpty)
  #expect(request.options.reasoningEffort == "disabled")
  #expect(request.messages.contains { $0.text.contains("keep all paths") })
  #expect(request.sessionID == "chat-session")
  #expect(result.transcript.contains { $0.text.contains("summary") })
}

@Test("Compaction requests clear permissions and do not mutate the main profile")
func taskAgentManualCompaction() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(TaskFixtureProvider(id: "local", responses: []))
  try await runtime.register(
    agent: AgentDefinition(id: "compact", instructions: "", provider: "local", model: "tiny"))
  await runtime.configureTaskAgents(.init(compact: "compact"))
  let original = AgentRequest(
    provider: "primary", model: "large", messages: [.user("summarize")],
    toolNames: ["echo"], toolGroupNames: ["files"], subagentNames: ["worker"],
    autocompact: .init(tokens: 1))
  let request = try await runtime.taskRequest(.compact, from: original)
  #expect(request.provider == "local")
  #expect(request.toolNames.isEmpty && request.subagentNames.isEmpty)
  #expect(request.toolGroupNames == [])
  #expect(!request.autocompact.isEnabled)
  #expect(original.model == "large")
  await runtime.configureTaskAgents(.init())
  let fallback = try await runtime.taskRequest(.compact, from: original)
  #expect(fallback.provider == original.provider && fallback.model == original.model)
}

@Test("A primary without native tools can synthesize after a native specialist")
func taskAgentPrimaryNeedsNoNativeTools() async throws {
  let primary = TaskFixtureProvider(
    id: "primary", responses: [.init(message: .assistant("answer"))], nativeTools: false)
  let specialist = TaskFixtureProvider(
    id: "local", responses: [.init(message: .assistant("ready"))])
  let runtime = AgentRuntime()
  try await runtime.register(primary)
  try await runtime.register(specialist)
  try await runtime.register(tool: taskEchoTool())
  try await runtime.register(
    agent: AgentDefinition(
      id: "fast", instructions: "decide", provider: "local", model: "small",
      toolCallingStrategy: .native))
  await runtime.configureTaskAgents(.init(tool: "fast"))
  let result = try await runtime.run(
    AgentRequest(
      provider: "primary", model: "large", messages: [.user("answer")], toolNames: ["echo"],
      toolCallingStrategy: .native, retry: .none))
  #expect(result.response.text == "answer")
  #expect(await primary.requests.count == 1)
  #expect(await primary.requests.first?.tools.isEmpty == true)
}

private func taskEchoTool() -> ClosureTool {
  ClosureTool(
    definition: ToolDefinition(
      name: "echo", description: "Echo",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
      ]),
      annotations: ToolAnnotations(approval: .automatic))
  ) { arguments, _ in
    ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
  }
}

private actor TaskFixtureProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  var responses: [ProviderResponse]
  private(set) var requests: [ProviderRequest] = []
  init(id: ProviderID, responses: [ProviderResponse], nativeTools: Bool = true) {
    descriptor = ProviderDescriptor(
      id: id, displayName: id.rawValue, capabilities: nativeTools ? [.nativeToolCalling] : [])
    self.responses = responses
  }
  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    guard !responses.isEmpty else { throw TaskFixtureError.unexpectedCall }
    let response = responses.removeFirst()
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}
private enum TaskFixtureError: Error { case unexpectedCall }
private actor TaskFixtureEvents {
  var text = ""
  func append(_ event: AgentEvent) {
    if case .provider(_, .textDelta(let value)) = event { text += value }
  }
}
