import Testing

@testable import MaiCore

private let weatherTool = ToolDefinition(
  name: "weather",
  description: "Look up weather.",
  parameters: [
    ToolParameterDef(name: "city", type: "string", description: "City", required: true)
  ])

@Test("Tool-loop policy exposes and resolves the final response tool")
func toolLoopResponseTool() {
  let definitions = AgentToolLoopPolicy.definitions(includingResponseTool: [weatherTool])
  #expect(definitions.map(\.name) == ["weather", "respond"])

  let decision = AgentToolLoopPolicy.evaluate(
    response: #"{"name":"respond","arguments":{"action":"ask-user","content":"Which city?"}}"#,
    tools: [weatherTool],
    mode: .json,
    remainingToolCalls: 2)
  guard case .final(let text) = decision else {
    Issue.record("Expected a final response")
    return
  }
  #expect(text == "Which city?")
}

@Test("Tool-loop policy normalizes executable calls and reuses completed results")
func toolLoopExecutionAndDeduplication() {
  var aliasedTool = weatherTool
  aliasedTool.providerName = "get_weather"
  let response = #"{"name":"get_weather","arguments":{"city":"Rome"}}"#
  let first = AgentToolLoopPolicy.evaluate(
    response: response,
    tools: [aliasedTool],
    mode: .json,
    remainingToolCalls: 2)
  guard case .execute(let calls) = first, let call = calls.first else {
    Issue.record("Expected an executable call")
    return
  }
  #expect(call.name == "weather")
  #expect(call.arguments["city"] == "Rome")

  let repeated = AgentToolLoopPolicy.evaluate(
    response: response,
    tools: [aliasedTool],
    mode: .json,
    completedToolRuns: [ToolCallKey(call): "22 C"],
    remainingToolCalls: 1)
  guard case .final(let text) = repeated else {
    Issue.record("Expected the completed result")
    return
  }
  #expect(text == "22 C")
}

@Test("Tool-loop policy repairs malformed and missing post-tool actions")
func toolLoopRepairDecisions() {
  let malformed = AgentToolLoopPolicy.evaluate(
    response: #"{"name":"weather","arguments":{"city":"Rome"}"#,
    tools: [weatherTool],
    mode: .json,
    remainingToolCalls: 2)
  guard case .repair(let malformedFeedback) = malformed else {
    Issue.record("Expected malformed-call feedback")
    return
  }
  #expect(malformedFeedback.contains("Error:"))

  let completedCall = ParsedToolCall(
    name: "weather",
    arguments: ["city": "Rome"],
    rawBlock: "")
  let hiddenOnly = AgentToolLoopPolicy.evaluate(
    response: "<think>done</think>",
    actionableResponse: "",
    visibleText: "",
    tools: [weatherTool],
    mode: .json,
    completedToolRuns: [ToolCallKey(completedCall): "22 C"],
    remainingToolCalls: 1)
  guard case .repair(let missingActionFeedback) = hiddenOnly else {
    Issue.record("Expected missing-action feedback")
    return
  }
  #expect(missingActionFeedback.contains("missing_tool_call"))
}

@Test("Tool names with arguments glued on resolve to their leading identifier")
func resolverAcceptsGluedNames() {
  let resolver = AgentToolNameResolver(tools: [
    ToolDefinition(name: "run_shell", description: "Run"),
    ToolDefinition(name: "files_read", description: "Read"),
  ])
  #expect(resolver.canonicalName(for: "run_shell Optimize:") == "run_shell")
  #expect(resolver.canonicalName(for: "files_read.arguments") == "files_read")
  #expect(resolver.canonicalName(for: "run_shell") == "run_shell")
  #expect(resolver.canonicalName(for: "weather") == nil)
  #expect(resolver.canonicalName(for: "weather now") == nil)
}
