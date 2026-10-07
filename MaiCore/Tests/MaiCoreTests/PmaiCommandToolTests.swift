import Foundation
import Testing

@testable import MaiCore

private func arguments(_ values: [String: String]) -> JSONValue {
  .object(Dictionary(uniqueKeysWithValues: values.map { ($0.key, JSONValue.string($0.value)) }))
}

private func call(_ tool: any AgentTool, _ values: [String: String]) async throws -> ToolOutput {
  try await tool.call(
    arguments: arguments(values),
    context: ToolExecutionContext(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
      modelTurn: 0))
}

/// The error a call refuses with, for a test that checks the message as well
/// as the case.
private func failure(_ tool: any AgentTool, _ command: String) async throws -> any Error {
  do {
    _ = try await call(tool, ["command": command])
    throw PmaiCommandError.noRunner
  } catch {
    return error
  }
}

/// A refusal reaches the model as an error tool result, which the runtime
/// builds from the thrown error; this is that same text.
private func message(_ error: any Error) throws -> String {
  #expect(error is PmaiCommandError)
  return try #require((error as? LocalizedError)?.errorDescription)
}

/// A host of the test's own, so tests running in parallel do not take turns
/// installing runners on the process-wide one the CLI uses.
private func host(_ runner: PmaiCommandHost.Runner? = nil) async -> PmaiCommandHost {
  let host = PmaiCommandHost()
  await host.install(runner: runner)
  return host
}

/// Whether the policy lets the command through, so a test reads as the claim
/// it is making rather than as an expectation about which error is thrown.
private func allows(_ policy: PmaiCommandPolicy, _ command: String) -> Bool {
  (try? policy.evaluate(command)) != nil
}

private func refusedIs(_ policy: PmaiCommandPolicy, _ command: String, _ expected: PmaiCommandError)
  -> Bool
{
  do {
    _ = try policy.evaluate(command)
    return false
  } catch {
    return (error as? PmaiCommandError) == expected
  }
}

@Test("A command the policy allows runs and its output comes back")
func pmaiRunReturnsCommandOutput() async throws {
  let host = await host { line in "ran \(line)" }
  let output = try await call(
    MaiPmaiRunTool(policy: .init(), host: host), ["command": "/mcp list"])
  #expect(try output.text == "ran /mcp list")
  #expect(!output.isError)
}

@Test("A command that is not a slash command is refused")
func pmaiRunNeedsASlash() async throws {
  let host = await host { _ in "ran" }
  let tool = MaiPmaiRunTool(policy: .init(), host: host)
  await #expect(throws: PmaiCommandError.notACommand) {
    try await call(tool, ["command": "mcp list"])
  }
  let text = try message(try #require(try? await failure(tool, "mcp list")))
  #expect(text.contains("starts with a slash"))
}

@Test("Without a host runner the tool says so rather than pretending")
func pmaiRunWithoutHost() async throws {
  let tool = MaiPmaiRunTool(policy: .init(), host: await host())
  await #expect(throws: PmaiCommandError.noRunner) {
    try await call(tool, ["command": "/mcp list"])
  }
  let text = try message(try #require(try? await failure(tool, "/mcp list")))
  #expect(text.contains("does not run pmai commands"))
}

@Test("The blocked list refuses the commands that cannot work away from the prompt")
func pmaiRunBlocksSessionCommands() async throws {
  let tool = MaiPmaiRunTool(policy: .init(), host: await host { _ in "ran" })
  for command in ["/exit", "/quit", "/clear", "/visual", "/image", "/attach"] {
    await #expect(throws: PmaiCommandError.blocked(String(command.dropFirst()))) {
      try await call(tool, ["command": command + " rest"])
    }
  }
}

@Test("An empty blocked list allows every command")
func pmaiRunAllowEverything() async throws {
  let host = await host { line in "ran \(line)" }
  let output = try await call(
    MaiPmaiRunTool(policy: .init(blockedCommands: ""), host: host),
    ["command": "/export somewhere"])
  #expect(try output.text == "ran /export somewhere")
}

@Test("A blocked entry may be a regular expression")
func pmaiRunBlocksByPattern() async throws {
  let policy = PmaiCommandPolicy(blockedCommands: "/^\\/(export|import)/")
  for command in ["/export chat.md", "/import chat.md"] {
    #expect(!allows(policy, command))
  }
  #expect(allows(policy, "/stats"))
}

@Test("A blocklist entry matches the command name, not an argument")
func pmaiRunBlocksByNameOnly() async throws {
  let policy = PmaiCommandPolicy(blockedCommands: "model")
  #expect(refusedIs(policy, "/model gpt-5", .blocked("model")))
  #expect(allows(policy, "/set model.name gpt-5"))
}

@Test("A read-only policy allows only what its list names")
func pmaiRunReadOnly() async throws {
  let host = await host { line in "ran \(line)" }
  let policy = PmaiCommandPolicy(readOnly: true)
  for command in [
    "/set", "/mcp list", "/tools list", "/theme list", "/help", "/stats", "/jobs", "/job tree",
  ] {
    #expect(allows(policy, command))
  }
  #expect(refusedIs(policy, "/model gpt-5", .notReadOnly("model")))
  // The blocklist still wins over the allowlist.
  #expect(refusedIs(policy, "/exit", .blocked("exit")))
  let text = try message(
    try #require(try? await failure(MaiPmaiRunTool(policy: policy, host: host), "/model gpt-5")))
  #expect(text.contains("not read-only"))
}

@Test("A read-only allowlist of nothing refuses everything")
func pmaiRunReadOnlyEmptyAllowlist() async throws {
  let policy = PmaiCommandPolicy(readOnly: true, readOnlyCommands: "")
  #expect(refusedIs(policy, "/stats", .notReadOnly("stats")))
}

@Test("pmai_help asks the host for /help, with and without a topic")
func pmaiHelpUsesTheHost() async throws {
  let tool = MaiPmaiHelpTool(policy: .init(), host: await host { line in "help for \(line)" })
  #expect(try await call(tool, [:]).text == "help for /help")
  #expect(try await call(tool, ["topic": "mcp"]).text == "help for /help mcp")
  #expect(try await call(tool, ["topic": "  set  "]).text == "help for /help set")
}

@Test("pmai_help stays available when pmai_run is read-only")
func pmaiHelpSurvivesReadOnly() async throws {
  let host = await host { line in "help for \(line)" }
  let policy = PmaiCommandPolicy(readOnly: true)
  let output = try await call(MaiPmaiHelpTool(policy: policy, host: host), ["topic": "tools"])
  #expect(try output.text == "help for /help tools")
  // A read-only install with no help in its allowlist still refuses it, the
  // same as it refuses a command.
  let narrowed = PmaiCommandPolicy(readOnly: true, readOnlyCommands: "stats")
  await #expect(throws: PmaiCommandError.notReadOnly("help")) {
    try await call(MaiPmaiHelpTool(policy: narrowed, host: host), [:])
  }
}

@Test("The group is off until a person enables it, and its settings are declared")
func pmaiGroupIsOffByDefault() {
  let group = MaiPmaiCommands.group(policy: .init())
  #expect(group.id == "pmai")
  #expect(group.toolNames == ["pmai_run", "pmai_help"])
  // Nothing references the group, so no agent is offered the tools: a person's
  // /tools enable pmai is what puts them in an agent's allow-list.
  let agent = AgentDefinition(
    id: "main", instructions: "", provider: "hello", model: "",
    toolGroupNames: ["files", "web"])
  #expect(!agent.toolGroupNames.contains(group.id))
  let optionIDs = Set(group.options.map(\.id))
  #expect(optionIDs == ["blockedCommands", "readOnly", "readOnlyCommands"])
}

@Test("Running a command asks for approval; asking for help does not")
func pmaiApprovalRequirements() {
  #expect(MaiPmaiRunTool(policy: .init()).definition.annotations.approval == .confirm)
  #expect(MaiPmaiHelpTool(policy: .init()).definition.annotations.approval == .automatic)
  #expect(MaiPmaiRunTool(policy: .init()).definition.annotations.readOnly == false)
  #expect(MaiPmaiHelpTool(policy: .init()).definition.annotations.readOnly)
}

@Test("The tools describe what they do and what they take")
func pmaiToolDescriptions() {
  let run = MaiPmaiRunTool(policy: .init()).definition
  #expect(run.description.contains("/mcp"))
  #expect(run.description.contains("slash"))
  let schema = run.inputSchema.objectValue ?? [:]
  #expect((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue) == ["command"])

  let help = MaiPmaiHelpTool(policy: .init()).definition
  #expect(help.description.contains("/help"))
  #expect((help.inputSchema.objectValue?["required"]?.arrayValue ?? []).isEmpty)
}

@Test("A read-only pmai_run says what it may run, so the model does not have to find out")
func pmaiRunDescriptionStatesItsScope() {
  #expect(!MaiPmaiRunTool(policy: .init()).definition.description.contains("only reads"))
  let narrowed = MaiPmaiRunTool(
    policy: .init(readOnly: true, readOnlyCommands: "stats, tools")
  ).definition
  #expect(narrowed.description.contains("only reads"))
  #expect(narrowed.description.contains("stats, tools"))
}

@Test("The policy reads its settings from a group's options, then the environment")
func pmaiPolicySources() {
  let fromOptions = PmaiCommandPolicy(options: [
    "blockedCommands": .string("model"), "readOnly": .bool(true),
    "readOnlyCommands": .string("stats"),
  ])
  #expect(fromOptions.blockedCommands == "model")
  #expect(fromOptions.readOnly)
  #expect(fromOptions.readOnlyCommands == "stats")

  let fromEnvironment = PmaiCommandPolicy(
    options: [:],
    environment: [
      "PMAI_COMMANDS_BLOCKED": "clear", "PMAI_COMMANDS_READONLY": "1",
      "PMAI_COMMANDS_READONLY_COMMANDS": "help,stats",
    ])
  #expect(fromEnvironment.blockedCommands == "clear")
  #expect(fromEnvironment.readOnly)
  #expect(fromEnvironment.readOnlyCommands == "help,stats")
  #expect(refusedIs(fromEnvironment, "/model x", .notReadOnly("model")))
  #expect(allows(fromEnvironment, "/stats"))
  #expect(fromEnvironment.summary.contains("read-only"))

  let defaults = PmaiCommandPolicy(options: [:], environment: [:])
  #expect(defaults == .init())
}

// The tools are only worth anything if a model can reach them, so the rest of
// these drive a real run: one that offers the group, one that does not.

/// A provider that calls `pmai_run` on the first turn and answers with whatever
/// came back, so the run's own transcript shows the command's output.
private actor PmaiCommandProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "fixture", displayName: "Fixture", capabilities: [.nativeToolCalling])

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let results = request.messages.flatMap(\.toolResults)
    guard results.isEmpty else {
      return ProviderResponse(
        message: .assistant(results.map(\.text).joined(separator: " | ")), stopReason: .stop)
    }
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "run-1", name: MaiPmaiCommands.runToolName,
              arguments: .object(["command": .string("/theme list")])))
        ]),
      stopReason: .toolCall)
  }
}

@Test("An agent that is offered the group can run a command and reads its output")
func pmaiRunReachesTheModel() async throws {
  let host = await host { _ in "gruvbox\ncatppuccin" }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(PmaiCommandProvider())
  for tool in MaiPmaiCommands.makeTools(policy: .init(), host: host) {
    try await runtime.register(tool: tool)
  }
  let result = try await runtime.run(
    AgentRequest(
      agentID: "main", provider: "fixture", model: "fixture",
      messages: [.user("list the themes")],
      toolNames: MaiPmaiCommands.toolNames,
      toolGroupNames: [MaiPmaiCommands.group(policy: .init()).id])
  ) { _ in }

  #expect(result.response.text == "gruvbox\ncatppuccin")
  #expect(result.toolCalls == 1)
}

@Test("An agent that was not given the group never sees the tools")
func pmaiRunStaysOutOfTheWay() async throws {
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(PmaiCommandProvider())
  for tool in MaiPmaiCommands.makeTools(
    policy: .init(), host: await host { _ in "should not run" })
  {
    try await runtime.register(tool: tool)
  }
  let result = try await runtime.run(
    AgentRequest(
      agentID: "main", provider: "fixture", model: "fixture",
      messages: [.user("list the themes")],
      toolNames: ["current_time"])
  ) { _ in }

  // The provider asks for pmai_run regardless; with the group off the runtime
  // has no such tool for this agent, so the call is refused rather than quietly
  // run.
  #expect(result.toolCalls == 1)
  let refusal = try #require(result.transcript.flatMap(\.toolResults).first)
  #expect(refusal.isError)
  #expect(refusal.text != "should not run")
}

@Test("A list takes names, slashes, commas and newlines alike")
func pmaiPolicyListSeparators() {
  let policy = PmaiCommandPolicy(blockedCommands: "model, /clear\n\texit")
  for command in ["/model", "/model x", "/clear", "/exit"] {
    #expect(!allows(policy, command))
  }
  #expect(allows(policy, "/models"))
}
