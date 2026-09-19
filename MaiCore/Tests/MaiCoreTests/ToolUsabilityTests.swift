import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

// What a model gets back when it uses a tool the way models tend to: with an
// absolute path it just saw, with the other tool's parameter name, or with
// the same call again after the directory changed.

@Test("File tools accept absolute paths inside the workspace and say where the workspace is")
func fileToolsAcceptAbsolutePathsInsideTheWorkspace() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "mai-usability-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
  try Data("int main(void) { return 0; }\n".utf8).write(
    to: root.appendingPathComponent("src/main.c"))
  defer { try? FileManager.default.removeItem(at: root) }
  // The temporary directory is a symlink on macOS; both spellings must work.
  let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(
      rootURL: root, followsProcessWorkingDirectory: false))

  let read = try await usabilityCall(
    usabilityTool(tools, .read),
    ["path": .string(resolvedRoot.appendingPathComponent("src/main.c").path)])
  #expect(!read.isError)
  #expect(read.text.contains("int main"))
  let unresolved = try await usabilityCall(
    usabilityTool(tools, .read), ["path": .string(root.appendingPathComponent("src/main.c").path)])
  #expect(!unresolved.isError)
  let list = try await usabilityCall(usabilityTool(tools, .list), ["path": .string(resolvedRoot.path)])
  #expect(!list.isError)
  #expect(list.text.contains("src/"))

  let outside = try await usabilityCall(usabilityTool(tools, .read), ["path": .string("/etc/hosts")])
  #expect(outside.isError)
  #expect(outside.text.contains("outside the configured workspace"))
  #expect(outside.text.contains("The workspace is \(root.path)"))
  let missing = try await usabilityCall(usabilityTool(tools, .read), ["path": .string("src/nope.c")])
  #expect(missing.isError)
  #expect(missing.text.contains("does not exist"))
  #expect(missing.text.contains("The workspace is \(root.path)"))
  let notFolder = try await usabilityCall(usabilityTool(tools, .list), ["path": .string("src/main.c")])
  #expect(notFolder.isError)
  #expect(notFolder.text.contains("not a folder; files_read reads a file"))
}

@Test("run_sh takes command and script as aliases of each other")
func runToolsAcceptAliases() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  let shell = try #require(tools.first { $0.definition.name == "run_sh" })

  let viaCommand = try await usabilityCall(shell, ["command": .string("printf via-command")])
  #expect(!viaCommand.isError)
  #expect(viaCommand.text == "via-command")
  let viaScript = try await usabilityCall(shell, ["script": .string("printf via-script")])
  #expect(!viaScript.isError)
  #expect(viaScript.text == "via-script")
  let viaCommands = try await usabilityCall(
    shell, ["commands": .array([.string("printf one"), .string("printf two")])])
  #expect(!viaCommands.isError)
  #expect(viaCommands.text == "onetwo")
  let empty = try await usabilityCall(shell, [:])
  #expect(empty.isError)
  #expect(empty.text.contains("script is required"))

  // The schema itself admits both spellings, so the runtime's validation
  // never rejects the call before the tool can read the alias.
  let schema = try #require(shell.definition.inputSchema.objectValue)
  #expect(schema["required"] == .array([]))
  let properties = try #require(schema["properties"]?.objectValue)
  #expect(properties["command"] != nil)
  #expect(properties["script"] != nil)
}

@Test("Schema errors name the fields the call had and the fields the tool takes")
func schemaErrorsNameFields() {
  let definition = ToolDefinition(
    name: "run_sh",
    description: "Run",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "script": .object(["type": .string("string")]),
        "cwd": .object(["type": .string("string")]),
      ]),
      "required": .array([.string("script")]),
      "additionalProperties": .bool(false),
    ]),
    annotations: ToolAnnotations(approval: .automatic))

  let missing = ToolSchemaValidator.validate(
    arguments: .object(["command": .string("ls")]), definition: definition)
  #expect(
    missing
      == "missing required field: script. Received: command. Accepted fields: cwd, script (required)")
  let unknown = ToolSchemaValidator.validate(
    arguments: .object(["script": .string("ls"), "cmd": .string("x")]), definition: definition)
  #expect(unknown == "unknown field: cmd. Received: cmd, script. Accepted fields: cwd, script (required)")
  let nothing = ToolSchemaValidator.validate(arguments: .object([:]), definition: definition)
  #expect(nothing?.contains("No fields were given") == true)
  #expect(ToolSchemaValidator.validate(arguments: .object(["script": .string("ls")]), definition: definition) == nil)
}

@Test("A call may repeat three times, and refused or invalid calls are still shown")
func repeatedCallsAreCappedAndShown() async throws {
  let same = JSONValue.object(["n": .string("a")])
  let calls =
    (1...5).map { ToolCall(id: "same-\($0)", name: "tick", arguments: same) }
    + [ToolCall(id: "bad", name: "tick", arguments: .object(["wrong": .string("x")]))]
  let provider = UsabilityScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(role: .assistant, content: calls.map(ContentPart.toolCall)),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("done"), stopReason: .stop),
  ])
  let executions = UsabilityCounter()
  let recorder = UsabilityEventRecorder()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "tick",
        description: "Tick",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(["n": .object(["type": .string("string")])]),
          "required": .array([.string("n")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { _, _ in
      await executions.increment()
      return ToolOutput(text: "tock")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "usability-scripted",
      model: "fixture",
      messages: [.user("tick a lot")],
      toolNames: ["tick"],
      limits: AgentRunLimits(maxModelTurns: 3, maxToolCalls: 10))
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "done")
  #expect(await executions.value == AgentRuntime.maximumIdenticalCalls)
  let results = result.transcript.flatMap(\.toolResults)
  #expect(results.count == 6)
  #expect(results.prefix(3).allSatisfy { !$0.isError && $0.text == "tock" })
  #expect(results[3].isError)
  #expect(results[3].text.contains("already run 3 times"))
  #expect(results[4].isError)
  #expect(results[5].isError)
  #expect(results[5].text.contains("missing required field: n"))
  #expect(results[5].text.contains("Received: wrong"))
  // Every call the model made was announced, including the two that were
  // refused and the one that never validated.
  let started = await recorder.events.filter {
    if case .toolStarted(_, let call) = $0 { return call.name == "tick" }
    return false
  }
  #expect(started.count == 6)
}

@Test("Native boolean spellings are normalized before validation without hiding bad arguments")
func nativeBooleanArguments() async throws {
  let values: [JSONValue] = [.string("true"), .string("false"), .integer(1), .integer(0),
                            .string("a.*b"), .array([]), .null]
  let calls = values.enumerated().map { index, value in
    ContentPart.toolCall(ToolCall(id: "bool-\(index)", name: "grep",
      arguments: .object(["query": .string("a.*b"), "regex": value])))
  }
  let runtime = AgentRuntime()
  try await runtime.register(UsabilityScriptedProvider(responses: [
    ProviderResponse(message: AgentMessage(role: .assistant, content: calls), stopReason: .toolCall),
    ProviderResponse(message: .assistant("done"), stopReason: .stop),
  ]))
  try await runtime.register(tool: ClosureTool(definition: ToolDefinition(
    name: "grep", description: "Search",
    parameters: [
      ToolParameterDef(name: "query", type: "string", description: "Text", required: true),
      ToolParameterDef(name: "regex", type: "boolean", description: "Use regex", required: false),
    ], annotations: ToolAnnotations(approval: .automatic)
  )) { arguments, _ in
    ToolOutput(text: arguments.objectValue?["regex"]?.compactJSONString ?? "missing")
  })
  let result = try await runtime.run(AgentRequest(
    provider: "usability-scripted", model: "fixture", messages: [.user("search")],
    toolNames: ["grep"], limits: AgentRunLimits(maxModelTurns: 2, maxToolCalls: 10)))
  let results = result.transcript.flatMap(\.toolResults)
  #expect(results.prefix(4).map(\.text) == ["true", "false", "true", "false"])
  #expect(results.dropFirst(4).count == 3)
  #expect(results.dropFirst(4).allSatisfy { $0.isError && $0.text.contains("regex must be boolean") })

  let definition = ToolDefinition(name: "nested", description: "Nested", inputSchema: .object([
    "type": .string("object"), "additionalProperties": .bool(false),
    "properties": .object(["flags": .object([
      "type": .string("array"), "items": .object(["type": .string("boolean")]),
    ])]),
  ]))
  let normalized = ToolSchemaValidator.coerceBooleans(
    .object(["flags": .array([.string("true"), .string("false")]), "unknown": .integer(1)]),
    schema: definition.inputSchema)
  #expect(normalized.objectValue?["flags"] == .array([.bool(true), .bool(false)]))
  #expect(ToolSchemaValidator.validate(arguments: normalized, definition: definition)?.contains("unknown field") == true)
}

// MARK: - Fixtures

private func usabilityTool(
  _ tools: [MaiFileWorkspaceTool],
  _ operation: MaiFileWorkspaceTool.Operation
) -> MaiFileWorkspaceTool {
  tools.first { $0.operation == operation }!
}

private func usabilityCall(
  _ tool: any AgentTool,
  _ arguments: [String: JSONValue]
) async throws -> ToolOutput {
  try await tool.call(
    arguments: .object(arguments),
    context: ToolExecutionContext(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "usability", depth: 0),
      modelTurn: 1))
}

private actor UsabilityScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "usability-scripted",
    displayName: "Usability scripted",
    capabilities: [.streaming, .nativeToolCalling])
  private var responses: [ProviderResponse]

  init(responses: [ProviderResponse]) {
    self.responses = responses
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    guard !responses.isEmpty else { throw UsabilityTestError.missingResponse }
    return responses.removeFirst()
  }
}

private actor UsabilityCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private actor UsabilityEventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

private enum UsabilityTestError: Error {
  case missingResponse
}
