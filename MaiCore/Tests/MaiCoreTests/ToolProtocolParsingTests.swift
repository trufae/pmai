import Foundation
import Testing

@testable import MaiCore

private let writeDefinition = ToolDefinition(
  name: "files_write", description: "Write a file", parameters: [
    ToolParameterDef(name: "path", type: "string", description: "Path", required: true),
    ToolParameterDef(name: "content", type: "string", description: "Contents", required: true),
  ])

@Test("XML argument text preserves whitespace and embedded JSON", arguments: [
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
  let call = try #require(AgentTooling.parseCalls(in: block, tools: [writeDefinition], mode: .xml).first)
  #expect(call.name == "files_write")
  #expect(call.argumentValues == ["path": .string("file.txt"), "content": .string(content)])
}
