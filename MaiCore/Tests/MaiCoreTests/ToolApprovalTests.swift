import Foundation
import MaiStandardTools
import Testing

@testable import MaiCore

private struct ModeHandler: ApprovalHandler {
  let mode: ToolApprovalMode
  var edit: JSONValue? = nil
  func toolApprovalMode() async -> ToolApprovalMode? { mode }
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    #expect(mode == .ask)
    return .approve(arguments: edit ?? request.call.arguments)
  }
}

private actor ApprovalProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  var responses: [ProviderResponse]
  let unavailable: Bool
  private(set) var requests: [ProviderRequest] = []
  init(id: ProviderID, responses: [ProviderResponse], unavailable: Bool = false) {
    self.descriptor = .init(
      id: id, displayName: id.rawValue,
      capabilities: unavailable ? [.toolDecision] : [.nativeToolCalling])
    self.responses = responses
    self.unavailable = unavailable
  }
  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    if unavailable { throw ToolApprovalUnavailable("Unsupported decision model") }
    guard !responses.isEmpty else {
      throw AgentToolError.executionFailed(tool: "fixture", reason: "Unexpected inference")
    }
    return responses.removeFirst()
  }
}

private actor ApprovalCalls {
  var values: [JSONValue] = []
  func append(_ value: JSONValue) { values.append(value) }
}

private func approvalCall(
  _ name: String = "candidate", arguments: JSONValue = .object(["text": .string("original")])
) -> ProviderResponse {
  .init(
    message: AgentMessage(
      role: .assistant, content: [.toolCall(.init(id: "c1", name: name, arguments: arguments))]))
}
private func verdict(_ value: String) -> ProviderResponse {
  .init(message: .assistant(value))
}
private func candidate(_ calls: ApprovalCalls) -> ClosureTool {
  ClosureTool(
    definition: .init(
      name: "candidate", description: "Echo supplied text",
      parameters: [.init(name: "text", type: "string", description: "text", required: true)],
      annotations: .init(approval: .automatic))
  ) { arguments, _ in
    await calls.append(arguments)
    return ToolOutput(text: "done")
  }
}

@Test("ask reviews automatic tools and validates edited arguments; yolo bypasses review")
func approvalModesRunAutomaticTools() async throws {
  for mode in [ToolApprovalMode.ask, .yolo] {
    let calls = ApprovalCalls()
    let edited: JSONValue = .object(["text": .string("edited")])
    let runtime = AgentRuntime(approvalHandler: ModeHandler(mode: mode, edit: edited))
    try await runtime.register(
      ApprovalProvider(
        id: "main", responses: [approvalCall(), .init(message: .assistant("answer"))]))
    try await runtime.register(tool: candidate(calls))
    _ = try await runtime.run(
      .init(provider: "main", messages: [.user("echo")], toolNames: ["candidate"], retry: .none))
    #expect(await calls.values == [mode == .ask ? edited : .object(["text": .string("original")])])
  }
}

@Test(
  "smart approves only a strict allow verdict and preserves original arguments",
  arguments: [
    #"{"decision":"allow","reason":"within scope","arguments":{"text":"tampered"}}"#,
    #"{"decision":"block","reason":"harmful"}"#, "yes", "ALLOW", #"{"decision":"allow"}"#,
  ])
func smartApprovalVerdicts(answer: String) async throws {
  let calls = ApprovalCalls()
  let runtime = AgentRuntime(approvalHandler: ModeHandler(mode: .smart))
  let primary = ApprovalProvider(
    id: "main", responses: [approvalCall(), .init(message: .assistant("answer"))])
  let reviewer = ApprovalProvider(id: "review", responses: [verdict(answer)])
  try await runtime.register(primary)
  try await runtime.register(reviewer)
  try await runtime.register(tool: candidate(calls))
  try await runtime.register(
    agent: .init(id: "reviewer", instructions: "", provider: "review", model: "small"))
  await runtime.configureTaskAgents(.init(approval: "reviewer"))
  let result = try await runtime.run(
    .init(
      provider: "main", model: "large", messages: [.user("echo original")],
      toolNames: ["candidate"], retry: .none, sessionID: "approval-session"))
  let allowed = answer.contains("within scope")
  #expect(await calls.values.count == (allowed ? 1 : 0))
  if allowed { #expect(await calls.values.first == .object(["text": .string("original")])) }
  let review = try #require(await reviewer.requests.first)
  #expect(review.tools.isEmpty && review.toolChoice == .none && !review.stream)
  #expect(review.sessionID == "approval-session")
  #expect(review.approvalReview?.task == "echo original")
  #expect(review.approvalReview?.arguments == .object(["text": .string("original")]))
  #expect(review.approvalReview?.environment.allowedPaths.isEmpty == false)
  #expect(result.modelTurns == 3)
}

@Test("smart falls back from unavailable System One to the primary chat model")
func smartApprovalFallback() async throws {
  let calls = ApprovalCalls()
  let runtime = AgentRuntime(approvalHandler: ModeHandler(mode: .smart))
  let primary = ApprovalProvider(
    id: "main",
    responses: [
      approvalCall(),
      verdict(#"{"decision":"block","reason":"outside task scope"}"#),
      .init(message: .assistant("blocked")),
    ])
  let reviewer = ApprovalProvider(id: "decision", responses: [], unavailable: true)
  try await runtime.register(primary)
  try await runtime.register(reviewer)
  try await runtime.register(tool: candidate(calls))
  try await runtime.register(
    agent: .init(id: "reviewer", instructions: "", provider: "decision", model: "missing"))
  await runtime.configureTaskAgents(.init(approval: "reviewer"))
  let result = try await runtime.run(
    .init(
      provider: "main", model: "chat", messages: [.user("echo")],
      toolNames: ["candidate"], retry: .none))
  #expect(await calls.values.isEmpty)
  #expect(await reviewer.requests.count == 1)
  #expect(await primary.requests.filter { $0.approvalReview != nil }.count == 1)
  #expect(
    result.transcript.flatMap(\.toolResults).first?.text.contains("outside task scope") == true)
}

@Test(
  "smart without an assigned reviewer uses the current model; budget exhaustion blocks execution")
func smartApprovalDefaultAndBudget() async throws {
  for limit in [1, 4] {
    let calls = ApprovalCalls()
    let runtime = AgentRuntime(approvalHandler: ModeHandler(mode: .smart))
    let primary = ApprovalProvider(
      id: "main",
      responses: [
        approvalCall(),
        verdict(#"{"decision":"allow","reason":"safe"}"#), .init(message: .assistant("done")),
      ])
    try await runtime.register(primary)
    try await runtime.register(tool: candidate(calls))
    _ = try await runtime.run(
      .init(
        provider: "main", model: "chat", messages: [.user("echo")],
        toolNames: ["candidate"], limits: .init(maxModelTurns: limit), retry: .none))
    #expect(await calls.values.count == (limit == 1 ? 0 : 1))
  }
}

@Test("approval task assignments round trip and are cleared on removal")
func approvalAssignmentPersistence() throws {
  let main = AgentDefinition(id: "main", instructions: "", provider: "local", model: "chat")
  var configuration = MaiConfiguration(
    providers: [.init(id: "local", kind: .systemOne)], agents: [main])
  try configuration.assignTask(.approval, selector: "local::tev1", current: main)
  let decoded = try JSONDecoder().decode(MaiConfiguration.self, from: configuration.encoded())
  #expect(decoded.taskAgents.approval == "task-approval")
  configuration.removeAgent("task-approval")
  #expect(configuration.taskAgents.approval == nil)
}

@Test("smart reviews the resolved target of a proxy call")
func smartApprovalProxy() async throws {
  let calls = ApprovalCalls()
  let primary = ApprovalProvider(
    id: "main",
    responses: [
      approvalCall(
        ToolProxy.callName,
        arguments: .object([
          "name": .string("candidate"),
          "arguments": .object(["text": .string("original")]),
        ])),
      verdict(#"{"decision":"block","reason":"denied by reviewer"}"#),
      .init(message: .assistant("done")),
    ])
  let runtime = AgentRuntime(approvalHandler: ModeHandler(mode: .smart))
  try await runtime.register(primary)
  try await runtime.register(tool: candidate(calls))
  _ = try await runtime.run(
    .init(
      provider: "main", messages: [.user("echo")],
      toolNames: ["candidate"], useToolProxy: true, proxyExposedTools: [], retry: .none))
  #expect(await calls.values.isEmpty)
  #expect(
    await primary.requests.first(where: { $0.approvalReview != nil })?.approvalReview?.tool
      == "candidate")
}

@Test("ask rejects edits that no longer satisfy the tool schema")
func askInvalidEditedArguments() async throws {
  let calls = ApprovalCalls()
  let runtime = AgentRuntime(approvalHandler: ModeHandler(mode: .ask, edit: .object([:])))
  try await runtime.register(
    ApprovalProvider(id: "main", responses: [approvalCall(), .init(message: .assistant("done"))]))
  try await runtime.register(tool: candidate(calls))
  let result = try await runtime.run(
    .init(provider: "main", messages: [.user("echo")], toolNames: ["candidate"], retry: .none))
  #expect(await calls.values.isEmpty)
  #expect(
    result.transcript.flatMap(\.toolResults).first?.text.contains("approved arguments are invalid")
      == true)
}

@Test("smart reviews proxy catalog calls before listing tools")
func smartApprovalProxyCatalog() async throws {
  let calls = ApprovalCalls()
  let primary = ApprovalProvider(
    id: "main",
    responses: [
      approvalCall(ToolProxy.listName, arguments: .object(["keywords": .string("candidate")])),
      verdict(#"{"decision":"block","reason":"catalog access blocked"}"#),
      .init(message: .assistant("done")),
    ])
  let runtime = AgentRuntime(approvalHandler: ModeHandler(mode: .smart))
  try await runtime.register(primary)
  try await runtime.register(tool: candidate(calls))
  let result = try await runtime.run(
    .init(
      provider: "main", messages: [.user("list tools")],
      toolNames: ["candidate"], useToolProxy: true, proxyExposedTools: [], retry: .none))
  #expect(
    await primary.requests.first(where: { $0.approvalReview != nil })?.approvalReview?.tool
      == ToolProxy.listName)
  #expect(
    result.transcript.flatMap(\.toolResults).first?.text.contains("catalog access blocked") == true)
}
