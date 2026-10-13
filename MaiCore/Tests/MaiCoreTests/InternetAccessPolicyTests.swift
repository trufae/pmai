import Foundation
import Testing

@testable import MaiCore
@testable import MaiTestSupport

private actor InternetToolCounter {
  var calls = 0
  func record() { calls += 1 }
}

@Test("Offline catalog restrictions override direct and proxy pins without changing saved choices")
func internetPolicyCatalog() throws {
  let tools = [
    ToolDefinition(name: "remote", description: "Remote"),
    ToolDefinition(name: "local", description: "Local"),
  ]
  let groups = ToolGroupDefinition.catalog(
    known: [
      ToolGroupDefinition(id: "service", toolNames: ["remote"], networkRequirement: .internet)
    ], tools: tools)
  let modes: [String: AgentToolMode] = ["remote": .direct, "local": .proxy]
  for policy in [InternetAccessPolicy(airplaneModeEnabled: true), .init(networkAvailable: false)] {
    let catalog = AgentToolCatalog(
      groups: groups, tools: tools, modes: modes, internetAccess: policy)
    #expect(catalog.modes["remote"] == .disabled)
    #expect(catalog.modes["local"] == .proxy)
    #expect(!catalog.visibleDefinitions.map(\.description).joined().contains("Remote"))
    #expect(modes["remote"] == .direct)
  }
  #expect(!InternetAccessPolicy().isOffline)
  #expect(
    try JSONDecoder().decode(ToolAnnotations.self, from: Data("{}".utf8)).requiresInternet == false)
  let configuration = MaiConfiguration(airplane: true)
  #expect(
    try JSONDecoder().decode(MaiConfiguration.self, from: JSONEncoder().encode(configuration))
      .airplane)
  #expect(try JSONDecoder().decode(MaiConfiguration.self, from: Data("{}".utf8)).airplane == false)
  let legacyGroup = try JSONDecoder().decode(
    ToolGroupDefinition.self,
    from: Data(#"{"id":"weather","toolNames":["weather"]}"#.utf8))
  #expect(legacyGroup.networkRequirement == .internet)
  #expect(ToolGroupDefinition.defaultNetworkRequirement(for: "webSearch") == .internet)
  #expect(ToolGroupDefinition.defaultNetworkRequirement(for: "files") == .offline)
  var policy = InternetAccessPolicy(networkAvailable: false)
  policy.toggleAirplaneMode()
  policy.networkAvailable = true
  #expect(policy.isOffline)
  policy.setAirplaneMode(false)
  #expect(!policy.isOffline)
}

@Test(
  "Airplane Mode rejects direct and proxy internet calls and restores them on exit",
  arguments: [false, true])
func airplaneToolExecution(proxy: Bool) async throws {
  let counter = InternetToolCounter()
  let remote = ClosureTool(
    definition: ToolDefinition(
      name: "remote", description: "Internet tool", annotations: .init(approval: .automatic))
  ) { _, _ in
    await counter.record()
    return ToolOutput(text: "remote ran")
  }
  let local = ClosureTool(
    definition: ToolDefinition(
      name: "local", description: "Local tool", annotations: .init(approval: .automatic))
  ) { _, _ in
    ToolOutput(text: "local ran")
  }
  let calls: [ContentPart] = [
    .toolCall(ToolCall(id: "remote-direct", name: "remote", arguments: .object([:]))),
    .toolCall(
      ToolCall(
        id: "remote-proxy", name: ToolProxy.callName,
        arguments: .object(["name": .string("remote"), "arguments": .object([:])]))),
    .toolCall(ToolCall(id: "local", name: "local", arguments: .object([:]))),
  ]
  let responses = [
    ProviderResponse(
      message: AgentMessage(role: .assistant, content: calls), stopReason: .toolCall),
    ProviderResponse(message: .assistant("done"), stopReason: .stop),
  ]
  let provider = ScriptedProvider(responses: responses + responses)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: remote)
  try await runtime.register(tool: local)
  await runtime.configureToolGroups([
    ToolGroupDefinition(id: "service", toolNames: ["remote"], networkRequirement: .internet)
  ])
  let request = AgentRequest(
    provider: "scripted", messages: [.user("work")],
    toolNames: ["remote", "local"], toolGroupNames: [], useToolProxy: proxy,
    toolPolicy: .init(tools: ["remote": proxy ? .proxy : .direct, "local": .direct]))
  await runtime.configureInternetAccess(.init(airplaneModeEnabled: true))
  let offline = try await runtime.run(request)
  let offered = try #require(await provider.requests.first)
  #expect(offered.tools.map(\.name) == ["local"])
  #expect(await counter.calls == 0)
  let results = offline.transcript.flatMap(\.toolResults)
  #expect(results.first { $0.callID == "remote-direct" }?.isError == true)
  #expect(results.first { $0.callID == "remote-proxy" }?.isError == true)
  #expect(results.first { $0.callID == "local" }?.text == "local ran")
  await runtime.configureInternetAccess(.init())
  _ = try await runtime.run(request)
  #expect(await counter.calls == (proxy ? 2 : 1))
}

@Test("Enabling airplane mode during approval revokes an already offered internet tool")
func airplaneDuringApproval() async throws {
  let counter = InternetToolCounter()
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(ToolCall(id: "remote", name: "remote", arguments: .object([:])))
        ]), stopReason: .toolCall),
    ProviderResponse(message: .assistant("done"), stopReason: .stop),
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(definition: ToolDefinition(name: "remote", description: "Internet")) { _, _ in
      await counter.record()
      return ToolOutput(text: "ran")
    })
  await runtime.configureToolGroups([
    ToolGroupDefinition(id: "service", toolNames: ["remote"], networkRequirement: .internet)
  ])
  let result = try await runtime.run(
    AgentRequest(provider: "scripted", messages: [.user("work")], toolNames: ["remote"])
  ) { event in
    if case .approvalRequested = event {
      await runtime.configureInternetAccess(.init(airplaneModeEnabled: true))
    }
  }
  #expect(await counter.calls == 0)
  #expect(result.transcript.flatMap(\.toolResults).last?.isError == true)
}
