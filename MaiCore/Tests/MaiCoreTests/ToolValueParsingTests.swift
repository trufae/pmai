import Foundation
import Testing

@testable import MaiCore

@Test("Integer access rejects out-of-range and nonintegral doubles")
func integerAccessBounds() throws {
  for number in [Double.infinity, -.infinity, .nan, 1e100, -1e100, Double(Int.max), 1.5] {
    #expect(JSONValue.number(number).intValue == nil)
  }
  #expect(JSONValue.number(Double(Int.min)).intValue == Int.min)
  #expect(JSONValue.integer(Int.max).intValue == Int.max)
  #expect(JSONValue.number(42).intValue == 42)
  #expect(JSONValue.number(-42).intValue == -42)
  let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("1e100".utf8))
  #expect(decoded.intValue == nil)
}

// Keep all ten app regression inputs, without rebuilding the app or repeating
// parser setup and assertions. A tool's name parameter is distinct from its name.
private let textCases: [(String, String, [String: JSONValue])] = [
  ("TOOL_CALL\ntool: call_tool\nname: read_wiki_structure\narguments: {\"repoName\":\"trufae/mai\"}\nEND_TOOL_CALL",
   ToolProxy.callName, ["name": .string("read_wiki_structure"), "arguments": .string(#"{"repoName":"trufae/mai"}"#)]),
  ("TOOL_CALL\nname: read_wiki_structure\ntool: call_tool\narguments: {\"repoName\":\"trufae/mai\"}\nEND_TOOL_CALL",
   ToolProxy.callName, ["name": .string("read_wiki_structure"), "arguments": .string(#"{"repoName":"trufae/mai"}"#)]),
  ("TOOL_CALL\ntool: webxdc_create\nname: myapp\nEND_TOOL_CALL",
   "webxdc_create", ["name": .string("myapp")]),
  ("TOOL_CALL\nname: search\nquery: radare2\nEND_TOOL_CALL", "search", ["query": .string("radare2")]),
  ("TOOL_CALL\ntool: search\nname: junk\nquery: radare2\nEND_TOOL_CALL", "search", ["query": .string("radare2")]),
]

private let nativeCases: [(String, String, [String: JSONValue])] = [
  (#"<tool_call id="call_00_ckST6CkbeQRTWCb7OUZh2132" api_name="call_tool">{"arguments":{"arguments":{"repoName":"trufae\/mai"},"name":"read_wiki_structure"},"name":"call_tool"}</tool_call>"#,
   ToolProxy.callName, ["name": .string("read_wiki_structure"), "arguments": .object(["repoName": .string("trufae/mai")])]),
  (#"<tool_call>{"name":"tool_call","arguments":{"name":"search","arguments":{"query":"radare2"}}}</tool_call>"#,
   "search", ["query": .string("radare2")]),
  (#"<tool_call>{"name":"invoke","arguments":{"name":"search","arguments":{"query":"radare2"}}}</tool_call>"#,
   "search", ["query": .string("radare2")]),
  (#"<tool_call>{"name":"search","arguments":{"name":"search","arguments":{"query":"radare2"}}}</tool_call>"#,
   "search", ["query": .string("radare2")]),
  (#"<tool_call>{"name":"webxdc_create","arguments":{"name":"myapp"}}</tool_call>"#,
   "webxdc_create", ["name": .string("myapp")]),
]

@Test("Text calls preserve declared name arguments and discard undeclared names", arguments: textCases)
func textNameArguments(fixture: (String, String, [String: JSONValue])) throws {
  try checkCall(fixture, mode: .text)
}

@Test("Native proxy envelopes survive parsing while scaffolding wrappers unwrap", arguments: nativeCases)
func nativeProxyEnvelopes(fixture: (String, String, [String: JSONValue])) throws {
  try checkCall(fixture, mode: .native)
}

private func checkCall(_ fixture: (String, String, [String: JSONValue]), mode: ToolCallingMode) throws {
  let (block, name, arguments) = fixture
  let tools = ToolProxy.definitions + [
    ToolDefinition(name: "search", description: "Search", parameters: [
      ToolParameterDef(name: "query", type: "string", description: "Query", required: true)
    ]),
    ToolDefinition(name: "webxdc_create", description: "Create", parameters: [
      ToolParameterDef(name: "name", type: "string", description: "Name", required: true)
    ]),
  ]
  let calls = AgentTooling.parseCalls(in: block, tools: tools, mode: mode)
  #expect(calls.count == 1)
  let call = try #require(calls.first)
  if name != ToolProxy.callName {
    #expect(call.name == name)
    #expect(call.argumentValues == arguments)
  }
  let normalized = AgentTooling.normalized(call: call, tools: tools)
  #expect(normalized.name == name)
  #expect(AgentTooling.containsDefinition(named: name, in: tools))
  #expect(normalized.argumentValues == arguments)
}

@Test("Native proxy self-calls preserve the envelope and report the recursion")
func nativeProxyRejectsRecursion() throws {
  let response = #"<tool_call id="proxy" api_name="call_tool">{"arguments":{"arguments":{"path":"README.md"},"name":"call_tool"},"name":"call-tool"}</tool_call>"#
  let calls = AgentTooling.parseCalls(in: response, tools: ToolProxy.definitions, mode: .native)
  let call = try #require(calls.first)
  #expect(call.toolCallID == "proxy")
  let resolved = ToolProxy.resolveCall(arguments: call.argumentValues, definitions: [])
  #expect(resolved.call == nil)
  #expect(resolved.error?.contains("cannot call itself") == true)
}

// The PR-review export wrapped every native call_tool invocation in another
// call_tool envelope, so even fetching the supplied URL failed as recursion.
@Test("Exported native proxy wrappers reach the intended tool and preserve skill arguments",
  arguments: [
    (#"{"name":"call_tool","arguments":{"name":"web_fetch","arguments":{"url":"https://github.com/radareorg/radare2/pull/27412"}}}"#,
     "web_fetch", ["url": JSONValue.string("https://github.com/radareorg/radare2/pull/27412")]),
    (#"{"name":"call_tool","arguments":{"name":"web_search","arguments":{"query":"radare2 pull request 27412 bug fix"}}}"#,
     "web_search", ["query": JSONValue.string("radare2 pull request 27412 bug fix")]),
    (#"{"name":"call_tool","arguments":{"name":"skills_PrReview","arguments":{"arguments":"https://github.com/radareorg/radare2/pull/27412"}}}"#,
     "skills_PrReview", ["arguments": JSONValue.string("https://github.com/radareorg/radare2/pull/27412")]),
    (#"{"name":"call_tool","arguments":{"name":"list_tools","arguments":{}}}"#,
     ToolProxy.listName, [:]),
  ])
func exportedNativeProxyWrapper(fixture: (String, String, [String: JSONValue])) throws {
  let (arguments, name, expected) = fixture
  let parameter = expected.keys.first.map {
    ToolParameterDef(name: $0, type: "string", description: "Input", required: name == "web_search")
  }
  let definitions = [ToolDefinition(name: name, description: "Fixture", parameters: parameter.map { [$0] } ?? [])]
  let block = "<tool_call id=\"exported\" api_name=\"call_tool\">{\"name\":\"call-tool\",\"arguments\":\(arguments)}</tool_call>"
  let parsed = try #require(AgentTooling.parseCalls(in: block, tools: ToolProxy.definitions, mode: .native).first)
  let normalized = AgentTooling.normalized(call: parsed, tools: ToolProxy.definitions)
  #expect(normalized.toolCallID == "exported")
  #expect(normalized.argumentValues["name"] != .string("call_tool"))
  #expect(ToolProxy.requestedToolName(in: parsed.argumentValues) == (name == ToolProxy.listName ? "list_tools" : name))
  for call in [parsed, normalized] {
    let resolved = ToolProxy.resolveCall(arguments: call.argumentValues, definitions: definitions)
    #expect(resolved.error == nil)
    #expect(resolved.call?.name == name)
    #expect(resolved.call?.argumentValues == expected)
  }
}

@Test("A wrapped proxy cannot make an unavailable tool callable")
func wrappedUnavailableProxyTool() {
  let result = ToolProxy.resolveCall(arguments: [
    "name": .string("call_tool"),
    "arguments": .object(["name": .string("r2mcp_pr_review"), "arguments": .object(["pr": .integer(27412)])]),
  ], definitions: [])
  #expect(result.call == nil)
  #expect(result.error?.contains("unknown tool 'r2mcp_pr_review'") == true)
}
