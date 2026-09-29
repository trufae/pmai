import Foundation
import Testing

@testable import MaiCore

// Asynchronous tool calls: calls to a concurrent tool run side by side within
// one reply, a child started without waiting delivers its answer into the
// parent's inbox, a run holds for such children instead of ending, and the
// derived worker is a peer that can delegate until the depth limit.

@Test("Every agent tool is a concurrent call, and use.plan adds the plan-first sentence")
func agentToolsAreConcurrentAndPlanFirstIsOptional() throws {
  let plain = AgentProcessTools.definitions(offering: [], delegating: true)
  #expect(plain.allSatisfy { $0.annotations.concurrent })
  let start = try #require(plain.first { $0.name == AgentProcessTools.startToolName })
  #expect(start.description.contains("start them all in the same reply"))
  #expect(!start.description.contains("numbered plan"))

  let planning = AgentProcessTools.definitions(offering: [], delegating: true, planFirst: true)
  let planningStart = try #require(
    planning.first { $0.name == AgentProcessTools.startToolName })
  #expect(planningStart.description.contains("numbered plan"))
  #expect(planningStart.description.contains("a single question needs no plan"))
  // Only the start tool carries it; the others stay as they were.
  #expect(
    planning.filter { $0.name != AgentProcessTools.startToolName }
      == plain.filter { $0.name != AgentProcessTools.startToolName })
}

@Test("A tool annotation without concurrent decodes as sequential, and the flag round-trips")
func concurrentAnnotationDecodes() throws {
  let legacy = try JSONDecoder().decode(
    ToolAnnotations.self,
    from: Data(
      #"{"readOnly":true,"destructive":false,"idempotent":true,"openWorld":false,"approval":"automatic"}"#
        .utf8))
  #expect(!legacy.concurrent)
  #expect(legacy.readOnly && legacy.approval == .automatic)
  let bare = try JSONDecoder().decode(ToolAnnotations.self, from: Data("{}".utf8))
  #expect(bare == ToolAnnotations())
  let encoded = try JSONEncoder().encode(ToolAnnotations(concurrent: true))
  #expect(try JSONDecoder().decode(ToolAnnotations.self, from: encoded).concurrent)
}

@Test("use.plan is on unless set off, and older configurations decode without it")
func usePlanDefaultsOn() throws {
  let legacy = try JSONDecoder().decode(
    MaiConfiguration.self, from: Data(#"{"version":1,"use":{"agentsmd":"on"}}"#.utf8))
  #expect(legacy.use.plan)
  #expect(legacy.use.agentsmd == .on)
  let off = try JSONDecoder().decode(
    MaiConfiguration.self, from: Data(#"{"version":1,"use":{"plan":false}}"#.utf8))
  #expect(!off.use.plan)
  let roundTrip = try JSONDecoder().decode(MaiConfiguration.self, from: try off.encoded())
  #expect(!roundTrip.use.plan)
}

@Test("Two agent_start calls in one reply run side by side, and their results keep call order")
func siblingsStartedInOneReplyRunTogether() async throws {
  let barrier = Barrier()
  let provider = FixtureProvider { request in
    if agentName(of: request) != nil {
      // Each child holds until its sibling has also reached the model: with
      // one child run after the other, the first would wait alone and say so.
      await barrier.arrive()
      let together = await barrier.wait(for: 2)
      let task = request.messages.last { $0.role == .user }?.text ?? ""
      let which = task.contains("alpha") ? "alpha" : "beta"
      return ProviderResponse(
        message: .assistant("\(which) done \(together ? "together" : "alone")"),
        stopReason: .stop)
    }
    let results = request.messages.flatMap(\.toolResults)
    guard results.isEmpty else {
      return ProviderResponse(
        message: .assistant(results.map(\.text).joined(separator: " | ")), stopReason: .stop)
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(startCall(id: "start-alpha", task: "Do alpha")),
          .toolCall(startCall(id: "start-beta", task: "Do beta")),
        ]),
      stopReason: .toolCall)
  }
  let recorder = EventLog()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)

  let result = try await runtime.run(delegatingRequest(prompt: "fan out")) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "alpha done together | beta done together")
  #expect(result.transcript.flatMap(\.toolResults).map(\.callID) == ["start-alpha", "start-beta"])
  let events = await recorder.events
  let starts = events.indices.filter { if case .childStarted = events[$0] { true } else { false } }
  let finishes = events.indices.filter {
    if case .childFinished = events[$0] { true } else { false }
  }
  #expect(starts.count == 2 && finishes.count == 2)
  // Both children were running before either had finished.
  #expect(try #require(starts.last) < #require(finishes.first))
}

@Test("A child started without waiting delivers its answer, and the run holds for it")
func backgroundChildDeliversItsAnswer() async throws {
  let provider = FixtureProvider { request in
    if agentName(of: request) != nil {
      try await Task.sleep(for: .milliseconds(150))
      return ProviderResponse(message: .assistant("Background answer"), stopReason: .stop)
    }
    let users = request.messages.filter { $0.role == .user }
    if users.count > 1, let delivery = users.last {
      let last = delivery.text.split(separator: "\n").last.map(String.init) ?? ""
      return ProviderResponse(message: .assistant("Got: \(last)"), stopReason: .stop)
    }
    if request.messages.contains(where: { $0.role == .tool }) {
      // The model is done for now; the runtime must not be.
      return ProviderResponse(message: .assistant("Waiting for the child."), stopReason: .stop)
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(startCall(id: "start-1", task: "Think in the background", wait: false))
        ]),
      stopReason: .toolCall)
  }
  let recorder = EventLog()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)

  let result = try await runtime.run(delegatingRequest(prompt: "start something")) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Got: Background answer")
  // One tool call in all: the start. Nothing was polled or collected by hand.
  #expect(result.toolCalls == 1)
  let parentRequests = await provider.requests.filter { agentName(of: $0) == nil }
  #expect(parentRequests.count == 3)
  let last = try #require(parentRequests.last)
  let delivery = try #require(last.messages.last { $0.role == .user })
  #expect(delivery.text.hasPrefix("Agent #"))
  #expect(delivery.text.contains("(main.worker) finished. Its answer:\nBackground answer"))
  #expect(AgentProcessTools.deliveredChildPID(of: delivery) != nil)
  // The interim answer stays in the conversation before the delivery.
  let assistants = last.messages.filter { $0.role == .assistant }.map(\.text)
  #expect(assistants.contains("Waiting for the child."))
  // Hosts hear of the child's end as of a waited child, never as a person's message.
  let events = await recorder.events
  #expect(
    events.contains {
      if case .childFinished(_, let child) = $0 {
        child.response.text == "Background answer"
      } else {
        false
      }
    })
  #expect(!events.contains { if case .userMessage = $0 { true } else { false } })
  let child = try #require(
    await runtime.supervisor.processes().first { $0.agentID == "main.worker" })
  #expect(child.state == .completed)
  #expect(child.isCollected)
  #expect(child.queuedMessages == 0)
}

@Test("agent_result takes a background answer and the delivery is not repeated")
func collectingByHandDropsTheDelivery() async throws {
  let provider = FixtureProvider { request in
    if agentName(of: request) != nil {
      try await Task.sleep(for: .milliseconds(50))
      return ProviderResponse(message: .assistant("Background answer"), stopReason: .stop)
    }
    let results = request.messages.flatMap(\.toolResults)
    switch results.count {
    case 0:
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [.toolCall(startCall(id: "start-1", task: "Think", wait: false))]),
        stopReason: .toolCall)
    case 1:
      let pid =
        results[0].text.split(separator: "#").dropFirst().first?.prefix { $0.isNumber } ?? ""
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: "collect-1",
                name: AgentRuntime.agentResultToolName,
                arguments: .object(["pid": .string(String(pid))])))
          ]),
        stopReason: .toolCall)
    default:
      return ProviderResponse(
        message: .assistant("Collected: \(results[1].text)"), stopReason: .stop)
    }
  }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)

  let result = try await runtime.run(delegatingRequest(prompt: "start and collect")) { _ in }

  #expect(result.response.text == "Collected: Background answer")
  #expect(await provider.requests.filter { agentName(of: $0) == nil }.count == 3)
  #expect(!result.transcript.contains { AgentProcessTools.deliveredChildPID(of: $0) != nil })
}

@Test("Workers are peers until the depth limit, where the agent tools are withheld")
func workersArePeersUntilTheDepthLimit() async throws {
  let provider = FixtureProvider { request in
    let hasStart = request.tools.contains { $0.name == AgentRuntime.agentStartToolName }
    let results = request.messages.flatMap(\.toolResults)
    switch agentName(of: request) {
    case nil:
      if let first = results.first {
        return ProviderResponse(message: .assistant("root got \(first.text)"), stopReason: .stop)
      }
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant, content: [.toolCall(startCall(id: "outer", task: "Do the outer step"))]),
        stopReason: .toolCall)
    case "main.worker":
      guard hasStart else {
        return ProviderResponse(message: .assistant("worker lacks agent tools"), stopReason: .stop)
      }
      if let first = results.first {
        return ProviderResponse(message: .assistant("worker got \(first.text)"), stopReason: .stop)
      }
      return ProviderResponse(
        message: AgentMessage(
          role: .assistant, content: [.toolCall(startCall(id: "inner", task: "Do the inner step"))]),
        stopReason: .toolCall)
    case "main.worker.worker":
      return ProviderResponse(
        message: .assistant(hasStart ? "leaf has agent tools" : "leaf"), stopReason: .stop)
    case let other:
      return ProviderResponse(message: .assistant("unexpected \(other ?? "")"), stopReason: .stop)
    }
  }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)

  var request = delegatingRequest(prompt: "nest")
  request.limits = AgentRunLimits(
    maxModelTurns: 8, maxToolCalls: 4, maxSubagents: 2, maxSubagentDepth: 2)
  let result = try await runtime.run(request) { _ in }

  #expect(result.response.text == "root got worker got leaf")
  let depths = await runtime.supervisor.processes().map { ($0.agentID, $0.depth) }
  #expect(depths.contains { $0 == ("main.worker", 1) })
  #expect(depths.contains { $0 == ("main.worker.worker", 2) })
}

// MARK: - Fixtures

private func delegatingRequest(prompt: String) -> AgentRequest {
  AgentRequest(
    agentID: "main",
    provider: "fixture",
    model: "fixture",
    messages: [.user(prompt)],
    toolNames: AgentRuntime.agentToolNames,
    toolGroupNames: [AgentRuntime.agentToolGroup.id],
    limits: AgentRunLimits(maxModelTurns: 6, maxToolCalls: 4, maxSubagents: 2),
    toolDelegation: .subagent)
}

private func startCall(id: String, task: String, wait: Bool? = nil) -> ToolCall {
  var arguments: [String: JSONValue] = [
    "task": .string(task),
    "output": .string("One line."),
  ]
  if let wait { arguments["wait"] = .bool(wait) }
  return ToolCall(id: id, name: AgentRuntime.agentStartToolName, arguments: .object(arguments))
}

/// The agent a child request runs as, read from its brief; nil for the root.
private func agentName(of request: ProviderRequest) -> String? {
  for message in request.messages where message.role == .user {
    guard let range = message.text.range(of: "running as agent '") else { continue }
    let rest = message.text[range.upperBound...]
    return String(rest.prefix { $0 != "'" })
  }
  return nil
}

private actor FixtureProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "fixture", displayName: "Fixture", capabilities: [.nativeToolCalling])
  private(set) var requests: [ProviderRequest] = []
  private let script: @Sendable (ProviderRequest) async throws -> ProviderResponse

  init(script: @escaping @Sendable (ProviderRequest) async throws -> ProviderResponse) {
    self.script = script
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    return try await script(request)
  }
}

private actor EventLog {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

/// A meeting point: `wait` answers true once `count` callers have arrived,
/// false when the timeout passes first.
private actor Barrier {
  private var arrived = 0

  func arrive() { arrived += 1 }

  func wait(for count: Int, timeout: Duration = .seconds(3)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while arrived < count {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }
}

@Test("Two background children are taken in with one resume, once both have delivered")
func backgroundChildrenDeliverTogether() async throws {
  let provider = FixtureProvider { request in
    if let name = agentName(of: request) {
      let task = request.messages.last { $0.role == .user }?.text ?? ""
      try await Task.sleep(for: .milliseconds(task.contains("slow") ? 250 : 50))
      return ProviderResponse(message: .assistant("\(name) answered"), stopReason: .stop)
    }
    let deliveries = request.messages.filter { AgentProcessTools.deliveredChildPID(of: $0) != nil }
    if !deliveries.isEmpty {
      return ProviderResponse(
        message: .assistant("Got: \(deliveries.count) deliveries"), stopReason: .stop)
    }
    if request.messages.contains(where: { $0.role == .tool }) {
      return ProviderResponse(message: .assistant("Waiting for both."), stopReason: .stop)
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(startCall(id: "start-fast", task: "A fast thing", wait: false)),
          .toolCall(startCall(id: "start-slow", task: "A slow thing", wait: false)),
        ]),
      stopReason: .toolCall)
  }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)

  let result = try await runtime.run(delegatingRequest(prompt: "fan out and wait")) { _ in }

  // Start, "waiting", and one turn with both answers: never a turn per child.
  #expect(result.response.text == "Got: 2 deliveries")
  #expect(await provider.requests.filter { agentName(of: $0) == nil }.count == 3)
  let children = await runtime.supervisor.processes().filter { $0.agentID == "main.worker" }
  #expect(children.count == 2 && children.allSatisfy { $0.isCollected })
}

@Test("A call that changed something starts the identical-call count of the others over")
func writesResetTheRepeatGuard() async throws {
  let provider = FixtureProvider { request in
    let results = request.messages.flatMap(\.toolResults)
    // Four rounds of "run the tests" after "fix something": the fourth
    // identical test run must not be refused as a repeat.
    guard results.count < 8 else {
      return ProviderResponse(message: .assistant("All green."), stopReason: .stop)
    }
    let round = results.count / 2
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "fix-\(round)", name: "fix",
              arguments: .object(["change": .string("edit \(round)")]))),
          .toolCall(
            ToolCall(
              id: "test-\(round)", name: "test",
              arguments: .object(["command": .string("make test")]))),
        ]),
      stopReason: .toolCall)
  }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "fix", description: "Edit a file",
        inputSchema: .object(["type": .string("object")]),
        annotations: ToolAnnotations(readOnly: false, approval: .automatic))
    ) { _, _ in ToolOutput(text: "edited") })
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "test", description: "Run the tests",
        inputSchema: .object(["type": .string("object")]),
        annotations: ToolAnnotations(readOnly: true, approval: .automatic))
    ) { _, _ in ToolOutput(text: "1 failure") })

  let result = try await runtime.run(
    AgentRequest(
      agentID: "main",
      provider: "fixture",
      model: "fixture",
      messages: [.user("fix until green")],
      toolNames: ["fix", "test"],
      limits: AgentRunLimits(maxModelTurns: 8, maxToolCalls: 16))
  ) { _ in }

  #expect(result.response.text == "All green.")
  let results = result.transcript.flatMap(\.toolResults)
  #expect(results.count == 8)
  #expect(!results.contains { $0.isError })
}

@Test("A parent that narrows the child's tools without the agent family gets a leaf")
func narrowedWorkerIsALeaf() async throws {
  let provider = FixtureProvider { request in
    if agentName(of: request) != nil {
      return ProviderResponse(message: .assistant("leaf"), stopReason: .stop)
    }
    if let first = request.messages.flatMap(\.toolResults).first {
      return ProviderResponse(message: .assistant("root got \(first.text)"), stopReason: .stop)
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "narrow", name: AgentRuntime.agentStartToolName,
              arguments: .object([
                "task": .string("Read the file"),
                "output": .string("One line."),
                "tools": .array([.string("read_file")]),
              ])))
        ]),
      stopReason: .toolCall)
  }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "read_file", description: "Read a file",
        inputSchema: .object(["type": .string("object")]),
        annotations: ToolAnnotations(readOnly: true, approval: .automatic))
    ) { _, _ in ToolOutput(text: "contents") })

  var request = delegatingRequest(prompt: "narrow")
  request.toolNames = AgentRuntime.agentToolNames.union(["read_file"])
  let result = try await runtime.run(request) { _ in }

  #expect(result.response.text == "root got leaf")
  let worker = try #require(await provider.requests.first { agentName(of: $0) != nil })
  #expect(worker.tools.map(\.name) == ["read_file"])
}

@Test("An optional false boolean survives normalization unless false is its documented default")
func optionalFalseIsKeptUnlessItIsTheDefault() throws {
  let definitions = AgentProcessTools.definitions(offering: [], delegating: true)
  let start = ParsedToolCall(
    name: AgentProcessTools.startToolName,
    arguments: [:],
    argumentValues: ["task": .string("t"), "output": .string("o"), "wait": .bool(false)],
    rawBlock: "",
    toolCallID: "1",
    apiName: nil)
  // `wait` defaults to true, so its false is the whole point of the call.
  let normalizedStart = AgentTooling.normalized(call: start, tools: definitions)
  #expect(normalizedStart.argumentValues["wait"] == .bool(false))

  let quiet = ToolDefinition(
    name: "echo",
    description: "Echo",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "verbose": .object([
          "type": .string("boolean"),
          "description": .string("Print more. Default: false."),
        ])
      ]),
    ]))
  let echo = ParsedToolCall(
    name: "echo",
    arguments: [:],
    argumentValues: ["verbose": .bool(false)],
    rawBlock: "",
    toolCallID: "2",
    apiName: nil)
  #expect(AgentTooling.normalized(call: echo, tools: [quiet]).argumentValues["verbose"] == nil)
}

@Test("Every child spends a tool budget of its own, so a late child is not left without tools")
func childrenSpendTheirOwnToolBudgets() async throws {
  // The parent may make two tool calls in all, and each child makes two of
  // its own. Summed across the tree, as budgets once were, the first child's
  // second call would already have been refused and the second child could
  // not have been started at all.
  let provider = FixtureProvider { request in
    let results = request.messages.flatMap(\.toolResults)
    guard agentName(of: request) != nil else {
      switch results.count {
      case 0:
        return ProviderResponse(
          message: AgentMessage(
            role: .assistant, content: [.toolCall(startCall(id: "first", task: "Probe twice as A"))]),
          stopReason: .toolCall)
      case 1:
        return ProviderResponse(
          message: AgentMessage(
            role: .assistant, content: [.toolCall(startCall(id: "second", task: "Probe twice as B"))]),
          stopReason: .toolCall)
      default:
        return ProviderResponse(
          message: .assistant("root got " + results.map(\.text).joined(separator: ", ")),
          stopReason: .stop)
      }
    }
    let brief = request.messages.last { $0.role == .user }?.text ?? ""
    let name = brief.contains("as A") ? "A" : "B"
    guard results.count < 2 else {
      return ProviderResponse(
        message: .assistant("\(name) probed " + results.map(\.text).joined(separator: "+")),
        stopReason: .stop)
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "\(name)-\(results.count + 1)", name: "probe",
              arguments: .object(["n": .integer(results.count + 1)])))
        ]),
      stopReason: .toolCall)
  }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "probe",
        description: "Probe once",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(["n": .object(["type": .string("integer")])]),
        ]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: "p\(Int(arguments.objectValue?["n"]?.coercedNumberValue ?? 0))")
    })

  var request = delegatingRequest(prompt: "probe twice, twice")
  request.toolNames = AgentRuntime.agentToolNames.union(["probe"])
  request.limits = AgentRunLimits(
    maxModelTurns: 6, maxToolCalls: 2, maxSubagents: 1, maxSubagentDepth: 1)
  let result = try await runtime.run(request) { _ in }

  #expect(result.response.text == "root got A probed p1+p2, B probed p1+p2")
  #expect(result.toolCalls == 2, "the parent paid for its two starts and nothing else")
  let parentResults = result.transcript.flatMap(\.toolResults)
  #expect(parentResults.count == 2 && parentResults.allSatisfy { !$0.isError })
  let children = await runtime.supervisor.processes().filter { $0.depth == 1 }
  #expect(children.count == 2)
  #expect(children.allSatisfy { $0.state == .completed && $0.toolCalls == 2 })
  // Neither child was ever told its budget was spent.
  let probeResults = await provider.requests
    .filter { $0.tools.contains { $0.name == "probe" } }
    .flatMap { $0.messages.flatMap(\.toolResults) }
  #expect(!probeResults.isEmpty && probeResults.allSatisfy { !$0.isError })
}
