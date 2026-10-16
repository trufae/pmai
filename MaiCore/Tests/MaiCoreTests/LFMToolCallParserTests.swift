import Testing

@testable import MaiCore

@Test("LFM call from the PocketMai export preserves the search query")
func lfmExportedWebSearch() throws {
  let text = "<|tool_call_start|>[web_search(query='author of rizen')]<|tool_call_end|>"
  let calls = AgentTooling.parseCalls(in: text, tools: [], mode: .text)
  let call = try #require(calls.first)
  #expect(calls.count == 1)
  #expect(call.name == "web_search")
  #expect(call.arguments == ["query": "author of rizen"])
  #expect(call.rawBlock == text)
}

@Test("LFM literals preserve types, escaping, nested proxy arguments and batches")
func lfmLiteralValues() throws {
  let calls = AgentTooling.parseCalls(in: #"""
    <|tool_call_start|>[call-tool(name='save', arguments={'text': 'Don\'t\\escape\n"quotes"', 'items': [True, False, None, -2, 1.5e2, {'emoji': '\uD83D\uDE00\U0001F600\x21'},],}), list-tools(keywords="a, b)"), ping()]<|tool_call_end|>
    """#, tools: [], mode: .native)
  #expect(calls.map(\.name) == ["call-tool", "list-tools", "ping"])
  let args = try #require(calls.first?.argumentValues["arguments"]?.objectValue)
  #expect(args["text"] == .string("Don't\\escape\n\"quotes\""))
  #expect(args["items"] == .array([
    .bool(true), .bool(false), .null, .integer(-2), .integer(150),
    .object(["emoji": .string("😀😀!")]),
  ]))
  #expect(calls[1].arguments["keywords"] == "a, b)")
  #expect(calls[2].argumentValues.isEmpty)
}

@Test("Malformed LFM batches never yield partial calls or fall through to embedded JSON", arguments: [
  "[ping(), save(text='unfinished)]",
  "[ping(), save(text='a', text='b')]",
  "[ping(), save(data={'key': 1, 'key': 2})]",
  "[ping(), save('positional')]",
  "[ping(), save(value=__import__('os').getcwd())]",
  "[ping(), save(value=1+2)]",
  "[ping(), save(value=NaN)]",
  "[ping(), save(value=1e999)]",
  "[ping(), save(text='bad\\q')]",
  "[ping(), save(text='\\uD800')]",
  "[ping(), save(text='\\UFFFFFFFF')]",
  "[ping(), save(text='unescaped\nnewline')]",
  #"[ping(), save(data={"name":"ping","arguments":{}})"#,
  "[ping()] trailing prose",
])
func lfmRejectsMalformedBatch(body: String) {
  let text = "<|tool_call_start|>\(body)<|tool_call_end|>"
  #expect(AgentTooling.parseCalls(in: text, tools: [], mode: .native).isEmpty)
}

@Test("LFM parser requires an explicit complete envelope", arguments: [
  "[ping()]",
  "<|tool_call_start|>[ping()]",
  "Example: <|tool_call_start|>[ping()]<|tool_call_end|>",
  "```python\n<|tool_call_start|>[ping()]<|tool_call_end|>\n```",
  "<|tool_call_start|>[ping()]<|tool_call_end|> More text",
])
func lfmRequiresEnvelope(text: String) {
  #expect(LFMToolCallParser.parseCalls(in: text).isEmpty)
}

@Test("LFM parser bounds nesting and never executes calls inside reasoning")
func lfmNestingAndReasoning() {
  let nested = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
  #expect(LFMToolCallParser.parseCalls(
    in: "<|tool_call_start|>[save(value=\(nested))]<|tool_call_end|>").isEmpty)
  let response = "<think><|tool_call_start|>[ping()]<|tool_call_end|></think>Done."
  let decision = AgentToolLoopPolicy.evaluate(
    response: response, tools: [ToolDefinition(name: "ping", description: "Ping")],
    mode: .native, remainingToolCalls: 1)
  guard case .final = decision else {
    Issue.record("Reasoning must not execute a tool")
    return
  }
}
