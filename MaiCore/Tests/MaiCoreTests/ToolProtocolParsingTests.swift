import Foundation
import Testing

@testable import MaiCore

private let writeDefinition = ToolDefinition(
  name: "files_write", description: "Write a file",
  parameters: [
    ToolParameterDef(name: "path", type: "string", description: "Path", required: true),
    ToolParameterDef(name: "content", type: "string", description: "Contents", required: true),
  ])

private let textWriteCall = """
  TOOL_CALL
  tool: files_write
  path: file.txt
  content: plain
  END_TOOL_CALL
  """
private let xmlWriteCall = """
  <tool_call name="files_write"><arg name="path">file.txt</arg><arg name="content">xml</arg></tool_call>
  """
private let jsonWriteCall =
  #"{"name":"files_write","arguments":{"path":"file.txt","content":"json"}}"#

@Test(
  "Every calling mode accepts standalone text, XML, and JSON calls",
  arguments: ToolCallingMode.allCases)
func protocolParserFallbacks(mode: ToolCallingMode) throws {
  for (input, content) in [
    (textWriteCall, "plain"), (xmlWriteCall, "xml"), (jsonWriteCall, "json"),
  ] {
    let calls = AgentTooling.parseCalls(in: input, tools: [writeDefinition], mode: mode)
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.name == "files_write")
    #expect(call.argumentValues == ["path": .string("file.txt"), "content": .string(content)])
  }
}

@Test(
  "Mixed protocol replies keep format precedence instead of combining calls",
  arguments: ToolCallingMode.allCases)
func protocolParserFormatPrecedence(mode: ToolCallingMode) throws {
  for (input, content) in [
    (
      [jsonWriteCall, xmlWriteCall, textWriteCall].joined(separator: "\n"),
      mode == .text ? "plain" : "xml"
    ),
    ([jsonWriteCall, textWriteCall].joined(separator: "\n"), mode == .text ? "plain" : "json"),
  ] {
    let calls = AgentTooling.parseCalls(in: input, tools: [writeDefinition], mode: mode)
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.argumentValues["content"] == .string(content))
  }
}

@Test("Native calls retain IDs and argument text through textual encoding")
func protocolParserNativeCallRoundTrip() throws {
  let native = AgentTooling.makeNativeToolCall(
    id: "call_42", name: "files_write",
    rawArguments: #"{"path":"file.txt","content":"  <tag> & \"quoted\"\n"}"#)
  let calls = AgentTooling.parseCalls(in: native.textBlock, tools: [writeDefinition], mode: .native)
  #expect(calls.count == 1)
  let call = try #require(calls.first)
  #expect(call.name == "files_write")
  #expect(call.toolCallID == "call_42")
  #expect(call.apiName == "files_write")
  #expect(
    call.argumentValues == [
      "path": .string("file.txt"), "content": .string("  <tag> & \"quoted\"\n"),
    ])
}

@Test(
  "XML argument text preserves whitespace and embedded JSON",
  arguments: [
    "  indented\n\ttext & <tag>  \n",
    #"{"name":"literal content","arguments":{"value":1}}"#,
    "prefix {\"value\":true} suffix",
  ])
func xmlArgumentPayloadPreserved(content: String) throws {
  let block = """
    <tool_call name="files_write"><arg name="path">file.txt</arg><arg name="content">\(AgentTooling.xmlEscapedAttribute(content))</arg></tool_call>
    """
  let calls = AgentTooling.parseCalls(in: block, tools: [writeDefinition], mode: .xml)
  #expect(calls.count == 1)
  let call = AgentTooling.normalized(call: try #require(calls.first), tools: [writeDefinition])
  #expect(call.name == "files_write")
  #expect(call.argumentValues == ["path": .string("file.txt"), "content": .string(content)])
}

@Test("XML arguments containing raw JSON are not promoted to tool calls")
func xmlRawJSONArgumentPreserved() throws {
  let content = #"{"name":"literal content","arguments":{"value":1}}"#
  let block = """
    <tool_call name="files_write"><arg name="path">file.txt</arg><arg name="content">\(content)</arg></tool_call>
    """
  let call = try #require(
    AgentTooling.parseCalls(in: block, tools: [writeDefinition], mode: .xml).first)
  #expect(call.name == "files_write")
  #expect(call.argumentValues == ["path": .string("file.txt"), "content": .string(content)])
}
