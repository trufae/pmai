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

@Test("Scoped instructions discover nested files once and skip files already in context")
func scopedAgentsMarkdown() throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent("agents-context-\(UUID().uuidString)")
  let deep = root.appendingPathComponent("sub/deep", isDirectory: true)
  try files.createDirectory(at: deep, withIntermediateDirectories: true)
  try files.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
  defer { try? files.removeItem(at: root) }
  let rootFile = root.appendingPathComponent("AGENTS.md")
  let subFile = root.appendingPathComponent("sub/AGENTS.md")
  let deepFile = deep.appendingPathComponent("AGENTS.md")
  try "root rules".write(to: rootFile, atomically: true, encoding: .utf8)
  try "sub rules".write(to: subFile, atomically: true, encoding: .utf8)
  try "deep rules".write(to: deepFile, atomically: true, encoding: .utf8)

  var context = AgentInstructionsContext(directory: root)
  let rootSection = try #require(context.section(alreadyIn: []))
  #expect(rootSection.contains("root rules"))
  #expect(!rootSection.contains("sub rules"))
  let call = ToolCall(id: "read", name: "files_read", arguments: .object([
    "path": .string("sub/deep/source.swift")
  ]))
  let observed = context.observe(call, workingDirectory: root)
  let discovered = try #require(observed)
  #expect(discovered.contains("sub rules"))
  #expect(discovered.contains("deep rules"))
  #expect(!discovered.contains("root rules"))
  let repeated = context.observe(call, workingDirectory: root)
  #expect(repeated == nil)
  #expect(context.section(alreadyIn: [.system(rootSection)])?.contains("sub rules") == true)
  let complete = try #require(context.section(alreadyIn: []))
  #expect(context.section(alreadyIn: [.system(complete)]) == nil)

  try "changed root rules".write(to: rootFile, atomically: true, encoding: .utf8)
  #expect(context.section(alreadyIn: []) == complete)
  let outside = ToolCall(id: "outside", name: "files_read", arguments: .object([
    "path": .string("../unrelated/file.swift")
  ]))
  let ignored = context.observe(outside, workingDirectory: root)
  #expect(ignored == nil)

  var shellContext = AgentInstructionsContext(directory: root)
  let shell = ToolCall(id: "shell", name: "run_shell", arguments: .object([
    "script": .string("rg pattern sub/deep/source.swift")
  ]))
  let shellSection = shellContext.observe(shell, workingDirectory: root)
  #expect(shellSection?.contains("sub rules") == true)
  #expect(shellSection?.contains("deep rules") == true)
}

@Test("A nested write waits until its AGENTS.md reaches the next model turn")
func nestedAgentsMarkdownBeforeWrite() async throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent("agents-write-\(UUID().uuidString)")
  let sub = root.appendingPathComponent("sub", isDirectory: true)
  try files.createDirectory(at: sub, withIntermediateDirectories: true)
  try files.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
  defer { try? files.removeItem(at: root) }
  try "root rule".write(to: root.appendingPathComponent("AGENTS.md"),
    atomically: true, encoding: .utf8)
  try "sub rule".write(to: sub.appendingPathComponent("AGENTS.md"),
    atomically: true, encoding: .utf8)

  let provider = NestedInstructionsProvider()
  let writes = NestedWriteCounter()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(tool: NestedWriteTool(counter: writes))
  await runtime.configureProjectInstructionDirectory(root)
  let result = try await AgentExecutionScope.$current.withValue(
    AgentExecutionScope(sessionID: "nested-write", workingDirectory: root)
  ) {
    try await runtime.run(AgentRequest(
      provider: "nested-instructions", model: "fixture",
      messages: [.user("write the file")], toolNames: ["files_write"],
      toolGroupNames: [], limits: AgentRunLimits(maxModelTurns: 4, maxToolCalls: 4),
      sessionID: "nested-write"))
  }
  let requests = await provider.requests
  #expect(requests.count == 3)
  #expect(requests[0].messages.contains { $0.role == .system && $0.text.contains("root rule") })
  #expect(!requests[0].messages.contains { $0.role == .system && $0.text.contains("sub rule") })
  #expect(requests[1].messages.contains { $0.role == .system && $0.text.contains("sub rule") })
  let firstResult = try #require(result.transcript.flatMap(\.toolResults).first)
  #expect(firstResult.isError)
  #expect(!firstResult.text.contains("sub rule"))
  #expect(await writes.count == 1)
}

@Test("use.agentsmd defaults to off, and older configurations decode without it")
func useSettingsDecode() throws {
  let legacy = try JSONDecoder().decode(
    MaiConfiguration.self,
    from: Data(#"{"version":1,"providers":[{"id":"p","kind":"hello"}]}"#.utf8))
  #expect(legacy.use == ConfiguredUse())
  #expect(legacy.use.agentsmd == .off)

  let enabled = try JSONDecoder().decode(
    MaiConfiguration.self, from: Data(#"{"version":1,"use":{"agentsmd":"on"}}"#.utf8))
  #expect(enabled.use.agentsmd == .on)
  let roundTrip = try JSONDecoder().decode(MaiConfiguration.self, from: enabled.encoded())
  #expect(roundTrip.use.agentsmd == .on)
}

@Test(
  "use.agentsmd loads legacy booleans and current modes, and saves the mode as a string",
  arguments: [
    ("true", AgentsMDMode.on), ("false", .off),
    (#""on""#, .on), (#""off""#, .off), (#""ask""#, .ask),
    (#""maybe""#, .maybe), ("null", .off),
  ])
func useAgentsMarkdownModesDecode(value: String, expected: AgentsMDMode) throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("maicore-config-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: url) }
  try Data(#"{"version":1,"use":{"agentsmd":\#(value),"plan":false}}"#.utf8)
    .write(to: url)

  let configuration = try MaiConfiguration.load(from: url)
  #expect(configuration.use.agentsmd == expected)
  #expect(!configuration.use.plan)

  try configuration.save(to: url)
  #expect(try MaiConfiguration.load(from: url) == configuration)
  let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
  #expect(saved.objectValue?["use"]?.objectValue?["agentsmd"] == .string(expected.rawValue))
}

@Test("use.agentsmd rejects invalid settings", arguments: [#""invalid""#, "1", "[]", "{}"])
func useAgentsMarkdownRejectsInvalid(value: String) throws {
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      MaiConfiguration.self, from: Data(#"{"use":{"agentsmd":\#(value)}}"#.utf8))
  }
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

private actor NestedInstructionsProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "nested-instructions", displayName: "Nested instructions",
    capabilities: [.nativeToolCalling])
  private(set) var requests: [ProviderRequest] = []

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    guard requests.count <= 2 else { return ProviderResponse(message: .assistant("done")) }
    return ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(ToolCall(id: "write-\(requests.count)", name: "files_write",
        arguments: .object(["path": .string("sub/file.txt")]))),
    ]), stopReason: .toolCall)
  }
}

private actor NestedWriteCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private struct NestedWriteTool: AgentTool {
  let counter: NestedWriteCounter
  let definition = ToolDefinition(
    name: "files_write", description: "Test write",
    parameters: [ToolParameterDef(name: "path", type: "string",
      description: "Path", required: true)],
    annotations: ToolAnnotations(approval: .automatic))

  func approvalEnvironment(arguments: JSONValue) throws -> ToolApprovalEnvironment {
    .current
  }

  func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    await counter.increment()
    return ToolOutput(text: "wrote")
  }
}
