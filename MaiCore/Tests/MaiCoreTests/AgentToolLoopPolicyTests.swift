import Testing

@testable import MaiCore

private let weatherTool = ToolDefinition(
  name: "weather",
  description: "Look up weather.",
  parameters: [
    ToolParameterDef(name: "city", type: "string", description: "City", required: true)
  ])

@Test("Native repair recognizes rejected LFM envelopes without interpreting examples", arguments: [
  "<|tool_call_start|>[weather(city='Rome')]<|tool_call_end|>",
  "<think>choose a tool</think>\n<|tool_call_start|>[weather(city='Rome'",
  "<tool_call>{broken}</tool_call>",
])
func nativeEnvelopeRepair(text: String) throws {
  let feedback = try #require(AgentToolLoopPolicy.nativeToolCallRepairFeedback(response: text))
  #expect(feedback.contains("No tools from that response were executed"))
  #expect(feedback.contains("native tool call"))
  #expect(!feedback.contains("TOOL_CALL\n"))
  #expect(!feedback.contains("choose a tool"))
}

@Test("Native repair leaves ordinary answers and protocol examples alone", arguments: [
  "The token <|tool_call_start|> begins an LFM tool call.",
  "```python\n<|tool_call_start|>[weather(city='Rome')]<|tool_call_end|>\n```",
  #"{"name":"weather","arguments":{"city":"Rome"}}"#,
  "[weather(city='Rome')]",
  "<think><|tool_call_start|>[weather(city='Rome')]</think>Sunny.",
])
func nativeEnvelopeExamples(text: String) {
  #expect(AgentToolLoopPolicy.nativeToolCallRepairFeedback(response: text) == nil)
}

@Test("Text protocols repair LFM envelopes using the selected protocol", arguments: [
  ToolCallingMode.text, .json, .xml,
])
func lfmEnvelopeInTextProtocol(mode: ToolCallingMode) {
  let decision = AgentToolLoopPolicy.evaluate(
    response: "<|tool_call_start|>[weather(city='Rome')]<|tool_call_end|>",
    tools: [weatherTool], mode: mode, remainingToolCalls: 2)
  guard case .repair(let feedback) = decision else {
    Issue.record("Expected repair rather than a final answer")
    return
  }
  #expect(feedback.contains(mode.displayName))
}

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

@Test("Tool-loop policy normalizes calls without treating old results as final answers")
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
    hasToolResults: true,
    remainingToolCalls: 1)
  guard case .execute(let repeatedCalls) = repeated else {
    Issue.record("Expected a fresh execution")
    return
  }
  #expect(repeatedCalls.map(\.name) == ["weather"])
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

  let hiddenOnly = AgentToolLoopPolicy.evaluate(
    response: "<think>done</think>",
    actionableResponse: "",
    visibleText: "",
    tools: [weatherTool],
    mode: .json,
    hasToolResults: true,
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
