import Foundation
import Testing

@testable import MaiCore

@Test("AGENTS.md files are found from the working directory up to the repository root, root first")
func agentsMarkdownLocate() throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent(
    "agentsmd-\(UUID().uuidString)", isDirectory: true)
  let sub = root.appendingPathComponent("sub", isDirectory: true)
  let deep = sub.appendingPathComponent("deep", isDirectory: true)
  try files.createDirectory(at: deep, withIntermediateDirectories: true)
  defer { try? files.removeItem(at: root) }
  try "root rules".write(
    to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
  try "sub rules".write(
    to: sub.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

  // Outside a repository only the directory itself counts: a stray file
  // higher up the disk must not leak into unrelated work.
  #expect(AgentInstructionsFile.locate(from: deep).isEmpty)
  #expect(
    AgentInstructionsFile.locate(from: sub).map(\.path) == [
      sub.appendingPathComponent("AGENTS.md").standardizedFileURL.path
    ])

  try files.createDirectory(
    at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
  let found = AgentInstructionsFile.locate(from: deep)
  #expect(
    found.map { $0.deletingLastPathComponent().lastPathComponent } == [
      root.lastPathComponent, "sub",
    ])

  let section = try #require(AgentInstructionsFile.promptSection(files: found))
  let rootRange = try #require(section.range(of: "root rules"))
  let subRange = try #require(section.range(of: "sub rules"))
  #expect(rootRange.lowerBound < subRange.lowerBound)
  #expect(section.hasPrefix("<project_instructions>"))
  #expect(AgentInstructionsFile.promptSection(files: []) == nil)

  // An empty file adds nothing.
  try "".write(to: deep.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
  #expect(AgentInstructionsFile.promptSection(from: deep) == section)
}

@Test("Project instructions reach every run, child agents included, and go away when cleared")
func projectInstructionsReachRuns() async throws {
  let provider = InstructionsFixtureProvider()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  await runtime.configureProjectInstructions(
    "<project_instructions>Run make test before answering.</project_instructions>")

  _ = try await runtime.run(
    AgentRequest(
      agentID: "main",
      provider: "instructions-fixture",
      model: "fixture",
      messages: [.system("Be terse."), .user("check it")],
      toolNames: AgentRuntime.agentToolNames,
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      limits: AgentRunLimits(maxModelTurns: 4, maxToolCalls: 4, maxSubagents: 1),
      toolDelegation: .subagent))

  let requests = await provider.requests
  let parent = try #require(requests.first)
  #expect(parent.messages.map(\.role) == [.system, .system, .user])
  #expect(parent.messages[0].text == "Be terse.")
  #expect(parent.messages[1].text.contains("Run make test"))
  // The child works in the same tree, so it gets the same rules.
  let worker = try #require(
    requests.first { $0.messages.contains { $0.text.contains("running as agent '") } })
  #expect(worker.messages.contains { $0.role == .system && $0.text.contains("Run make test") })

  await runtime.configureProjectInstructions(nil)
  _ = try await runtime.run(
    AgentRequest(
      provider: "instructions-fixture",
      model: "fixture",
      messages: [.system("Be terse."), .user("done")]))
  #expect(await provider.requests.last?.messages.map(\.role) == [.system, .user])
}

@Test("use.agentsmd defaults to maybe, and older configurations decode without it")
func useSettingsDecode() throws {
  let legacy = try JSONDecoder().decode(
    MaiConfiguration.self,
    from: Data(#"{"version":1,"providers":[{"id":"p","kind":"hello"}]}"#.utf8))
  #expect(legacy.use == ConfiguredUse())
  #expect(legacy.use.agentsmd == .maybe)

  let enabled = try JSONDecoder().decode(
    MaiConfiguration.self, from: Data(#"{"version":1,"use":{"agentsmd":"on"}}"#.utf8))
  #expect(enabled.use.agentsmd == .on)
  let roundTrip = try JSONDecoder().decode(MaiConfiguration.self, from: enabled.encoded())
  #expect(roundTrip.use.agentsmd == .on)
}

/// Delegates once when it can, then answers.
private actor InstructionsFixtureProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "instructions-fixture",
    displayName: "Instructions fixture",
    capabilities: [.nativeToolCalling])
  private(set) var requests: [ProviderRequest] = []

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    let results = request.messages.flatMap(\.toolResults)
    guard results.isEmpty,
      let tool = request.tools.first(where: { $0.name == AgentRuntime.agentStartToolName })
    else {
      return ProviderResponse(message: .assistant("done"))
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "c1", name: tool.name,
              arguments: .object(["task": .string("check it"), "output": .string("a verdict")])))
        ]),
      stopReason: .toolCall)
  }
}
