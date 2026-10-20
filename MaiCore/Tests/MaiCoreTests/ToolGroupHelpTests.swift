import Foundation
import Testing

@testable import MaiCore

// `/tools show GROUP` describes a group by its
// purpose and every tool's schema; a group nobody described gets a summary of
// its tools instead of a list of their names.

@Test("A tool's help names its traits, then its description and parameters, required first")
func toolHelpListsParameters() {
  let tool = ToolDefinition(
    name: "files_read",
    description: "Read a text file.\nPDF and DOCX are converted to Markdown.",
    parameters: [
      ToolParameterDef(
        name: "offset", type: "integer", description: "Byte offset. Default: 0.", required: false),
      ToolParameterDef(name: "path", type: "string", description: "File to read.", required: true),
    ],
    annotations: ToolAnnotations(readOnly: true, approval: .automatic))
  #expect(
    ToolGroupHelp.lines(for: tool) == [
      "files_read  [read-only, no approval]",
      "  Read a text file.",
      "  PDF and DOCX are converted to Markdown.",
      "  path (string, required): File to read.",
      "  offset (integer, optional): Byte offset. Default: 0.",
    ])
  let bare = ToolDefinition(
    name: "todo_list", description: "List the items.", parameters: [],
    annotations: ToolAnnotations(destructive: true))
  #expect(
    ToolGroupHelp.lines(for: bare) == [
      "todo_list  [destructive, asks approval]",
      "  List the items.",
      "  Parameters: none.",
    ])
}

@Test("A group's help starts with its purpose and covers every tool, noting ones not registered")
func groupHelpCoversEveryTool() {
  let group = ToolGroupDefinition(
    id: "chats", displayName: "Chats", description: "Use other chats.",
    toolNames: ["chats_list", "chats_read"])
  let tools = [
    ToolDefinition(
      name: "chats_list", description: "List chats.", parameters: [],
      annotations: ToolAnnotations(readOnly: true, approval: .automatic))
  ]
  let lines = ToolGroupHelp.lines(for: group, tools: tools)
  #expect(lines.first == "Use other chats.")
  #expect(lines.contains("chats_list  [read-only, no approval]"))
  #expect(lines.contains("chats_read  [not registered]"))
}

@Test("A group inferred from tool names is described by their first sentences")
func inferredGroupSummarizesItsTools() {
  let tools = [
    ToolDefinition(
      name: "chats_read", description: "Read the transcript of one other chat.", parameters: []),
    ToolDefinition(
      name: "chats_list", description: "List other chats, 1-50 of them. Newest first.",
      parameters: []),
  ]
  let groups = ToolGroupDefinition.inferred(from: tools)
  #expect(groups.map(\.id) == ["chats"])
  #expect(
    groups[0].description
      == "chats_list: List other chats, 1-50 of them. chats_read: Read the transcript of one other chat."
  )
  #expect(
    ToolGroupHelp.firstSentence(of: "Maximum number of chats, 1-50. Default: 20.")
      == "Maximum number of chats, 1-50.")
  #expect(ToolGroupHelp.firstSentence(of: "No period here") == "No period here")
}

@Test("Built-in groups cover the registered runtime tools; the catalog infers the rest")
func builtInGroupsAndCatalog() {
  let tools = [
    ToolDefinition(name: MaiMemoryTools.listName, description: "List.", parameters: []),
    ToolDefinition(name: MaiContextTools.listName, description: "List.", parameters: []),
    ToolDefinition(name: MaiContextTools.removeName, description: "Remove.", parameters: []),
    ToolDefinition(
      name: MaiSkillTools.toolName(for: "review"), description: "Review.", parameters: []),
    ToolDefinition(name: "custom_thing", description: "Do a thing.", parameters: []),
  ]
  let builtIn = AgentRuntime.builtInToolGroups(for: tools)
  #expect(builtIn.map(\.id) == ["agents", "chats", "context", "skills"])
  #expect(
    builtIn.first { $0.id == "context" }?.toolNames
      == [MaiContextTools.listName, MaiContextTools.removeName])
  #expect(
    builtIn.first { $0.id == "skills" }?.toolNames == [MaiSkillTools.toolName(for: "review")])
  #expect(builtIn.allSatisfy { !$0.description.isEmpty })
  let catalog = ToolGroupDefinition.catalog(known: builtIn, tools: tools)
  #expect(catalog.map(\.id) == ["agents", "chats", "context", "custom", "skills"])
  #expect(catalog.first { $0.id == "custom" }?.sourceID == "runtime")
  #expect(catalog.first { $0.id == "custom" }?.description == "Do a thing.")
}
