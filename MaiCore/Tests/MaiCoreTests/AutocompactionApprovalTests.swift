import Foundation
import Testing

@testable import MaiCore
@testable import MaiVisual

private let compactionHistory: [AgentMessage] = [
  .system("Keep the system instructions."),
  .user(String(repeating: "Important old context. ", count: 200)),
  .assistant("Earlier answer"), .user("Finish the task."),
]

@Test("Autocompaction waits before any inference and uses model changes made at the prompt")
func compactionApprovalWaitsAndRefreshesModels() async throws {
  let approval = CompactionApprovalProbe()
  let provider = CompactionApprovalProvider(responses: [.assistant("final answer")])
  let summarizer = CompactionApprovalProvider(id: "summarizer", responses: [.assistant("summary")])
  let runtime = AgentRuntime(approvalHandler: approval)
  try await runtime.register(provider)
  try await runtime.register(summarizer)
  let request = AgentRequest(
    provider: provider.descriptor.id, model: "old", messages: compactionHistory,
    retry: .none, autocompact: .init(tokens: 1))
  let run = Task { try await runtime.run(request) }
  var iterator = approval.events.makeAsyncIterator()
  let pending = try #require(await iterator.next())
  let pid = try #require(pending.run.pid)
  #expect(await provider.requests.isEmpty)
  #expect(await summarizer.requests.isEmpty)
  #expect(await runtime.supervisor.transcript(pid) == compactionHistory)
  #expect(await runtime.supervisor.info(pid)?.state == .waitingForInput)
  var changed = request
  changed.model = "new"
  #expect(await runtime.reconfigure(pid, with: changed))
  try await runtime.register(agent: AgentDefinition(
    id: "compact", instructions: "", provider: "summarizer", model: "small"))
  await runtime.configureTaskAgents(.init(compact: "compact"))
  await approval.resolve(.compact)
  let result = try await run.value
  #expect(await provider.requests.first?.model == "new")
  #expect(await summarizer.requests.first?.model == "small")
  #expect(result.transcript.first == compactionHistory.first)
  #expect(result.transcript.contains(compactionHistory.last!))
  #expect(result.transcript.contains { $0.text.contains("summary") })
}

@Test("Skipping autocompaction preserves history across tool turns and asks again on the next run")
func compactionApprovalSkipLastsForRun() async throws {
  let approval = CompactionApprovalProbe(decision: .continueWithoutCompacting)
  let call = ToolCall(id: "echo-1", name: "echo", arguments: .object([:]))
  let provider = CompactionApprovalProvider(responses: [
    AgentMessage(role: .assistant, content: [.toolCall(call)]), .assistant("done"),
    .assistant("next answer"),
  ])
  let runtime = AgentRuntime(approvalHandler: approval)
  try await runtime.register(provider)
  try await runtime.register(tool: ClosureTool(
    definition: ToolDefinition(name: "echo", description: "Echo", annotations: .init(approval: .automatic))
  ) { _, _ in ToolOutput(text: "result") })
  let request = AgentRequest(
    provider: provider.descriptor.id, model: "main", messages: compactionHistory,
    toolNames: ["echo"], retry: .none, autocompact: .init(tokens: 1))
  let result = try await runtime.run(request)
  #expect(await approval.requests.count == 1)
  #expect(result.modelTurns == 2)
  #expect(Array(result.transcript.prefix(compactionHistory.count)) == compactionHistory)
  #expect(await provider.requests.count == 2)
  _ = try await runtime.run(request)
  #expect(await approval.requests.count == 2)
}

@Test("Stopping at autocompaction leaves history intact and makes no model call", arguments: [false, true])
func compactionApprovalCancellation(cancelTask: Bool) async throws {
  let approval = CompactionApprovalProbe()
  let provider = CompactionApprovalProvider(responses: [])
  let runtime = AgentRuntime(approvalHandler: approval)
  try await runtime.register(provider)
  let run = Task {
    try await runtime.run(AgentRequest(
      provider: provider.descriptor.id, model: "main", messages: compactionHistory,
      autocompact: .init(tokens: 1)))
  }
  var iterator = approval.events.makeAsyncIterator()
  let pending = try #require(await iterator.next())
  if cancelTask { run.cancel() } else { await approval.resolve(.cancelRun) }
  await #expect(throws: CancellationError.self) { try await run.value }
  #expect(await provider.requests.isEmpty)
  let pid = try #require(pending.run.pid)
  #expect(await runtime.supervisor.transcript(pid) == compactionHistory)
  #expect(await runtime.supervisor.info(pid)?.attention == nil)
}

@Test("Visual compaction prompts resolve and dismiss on cancellation")
@MainActor
func compactionVisualApprovals() async throws {
  let approvals = VisualApprovalHandler()
  let runtime = AgentRuntime(approvalHandler: approvals)
  let profile = AgentDefinition(id: "main", instructions: "", provider: .hello, model: "hello")
  let workspace = VisualWorkspace(
    launch: VisualLaunch(focusedConversation: VisualConversationSeed(
      title: "Test", profile: profile, messages: compactionHistory)),
    runtime: runtime, plugins: PluginRegistry(), approvals: approvals)
  await approvals.attachCompaction(
    presenter: { await workspace.presentCompaction($0) },
    dismiss: { await workspace.dismissCompaction($0) })
  let request = AutocompactionRequest(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0),
    estimatedTokens: 100, threshold: 10)
  let first = Task { try await approvals.decideCompaction(request) }
  while workspace.pendingCompaction == nil { await Task.yield() }
  #expect(workspace.pendingCompaction?.request == request)
  workspace.resolveCompaction(.continueWithoutCompacting)
  #expect(try await first.value == .continueWithoutCompacting)
  #expect(workspace.pendingCompaction == nil)

  let cancelled = Task { try await approvals.decideCompaction(request) }
  while workspace.pendingCompaction == nil { await Task.yield() }
  cancelled.cancel()
  await #expect(throws: CancellationError.self) { try await cancelled.value }
  #expect(workspace.pendingCompaction == nil)

  let detached = Task { try await approvals.decideCompaction(request) }
  while workspace.pendingCompaction == nil { await Task.yield() }
  await approvals.detach()
  await #expect(throws: CancellationError.self) { try await detached.value }
  #expect(workspace.pendingCompaction == nil)
}

private actor CompactionApprovalProbe: ApprovalHandler {
  nonisolated let events: AsyncStream<AutocompactionRequest>
  private let notifications: AsyncStream<AutocompactionRequest>.Continuation
  private let decisions: AsyncStream<AutocompactionDecision>
  private let replies: AsyncStream<AutocompactionDecision>.Continuation
  private let decision: AutocompactionDecision?
  var requests: [AutocompactionRequest] = []

  init(decision: AutocompactionDecision? = nil) {
    (events, notifications) = AsyncStream.makeStream()
    (decisions, replies) = AsyncStream.makeStream()
    self.decision = decision
  }

  func decide(_ request: ApprovalRequest) -> ApprovalDecision { .cancelRun }

  func decideCompaction(_ request: AutocompactionRequest) async throws -> AutocompactionDecision {
    requests.append(request)
    notifications.yield(request)
    if let decision { return decision }
    var iterator = decisions.makeAsyncIterator()
    let decision = await iterator.next()
    try Task.checkCancellation()
    return decision ?? .cancelRun
  }

  func resolve(_ decision: AutocompactionDecision) { replies.yield(decision) }
}

private actor CompactionApprovalProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  var requests: [ProviderRequest] = []
  private var responses: [AgentMessage]

  init(id: ProviderID = "fixture", responses: [AgentMessage]) {
    descriptor = ProviderDescriptor(id: id, displayName: id.rawValue, capabilities: [.nativeToolCalling])
    self.responses = responses
  }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw CancellationError() }
    return ProviderResponse(message: responses.removeFirst())
  }
}
