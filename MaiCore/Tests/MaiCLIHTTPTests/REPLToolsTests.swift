import Foundation
import MaiCore
import MaiMarkdown
import Testing

@testable import MaiCLI

@Test("Tool completion includes disabled runtime, plugin and MCP groups")
func replToolsCompleteCatalog() {
  let groups = [
    AgentRuntime.agentToolGroup,
    MaiMemoryTools.group,
    ToolGroupDefinition(id: "custom", sourceID: "plugin", displayName: "Custom", toolNames: ["custom_read"]),
    ToolGroupDefinition(id: "custom", sourceID: "mcp", displayName: "Remote", toolNames: ["remote_read"]),
  ]
  let completions = Set(MaiCLI.completionCandidates(
    workspace: .init(), configuration: nil, availableProviders: [], toolGroups: groups,
    themesDirectory: FileManager.default.temporaryDirectory))
  #expect(completions.contains("/tools list"))
  #expect(completions.contains("/tools full"))
  for selector in ["agents", "chats", "custom", "mcp/custom"] {
    for action in ["show", "enable", "disable", "direct", "proxy", "hide", "inherit"] {
      #expect(completions.contains("/tools \(action) \(selector)"))
    }
  }
  #expect(completions.contains("/tools enable tool:agent_start"))
  #expect(completions.contains("/tools enable tool:custom_read"))
  #expect(completions.contains("/tools enable tool:remote_read"))
}

@Test("Default CLI assistants enable agents and preserve explicit disabling")
func replToolsDefaultAgents() {
  let profile = SessionProfile(provider: "hello", model: "", instructions: "", stream: false)
  #expect(profile.toolGroupNames.contains(AgentRuntime.agentToolGroup.id))
  #expect(profile.agentDefinition.toolMode(for: AgentRuntime.agentStartToolName,
    in: [AgentRuntime.agentToolGroup]) != .disabled)
  var definition = profile.agentDefinition
  definition.setToolGroupMode(.disabled, for: AgentRuntime.agentToolGroup)
  #expect(SessionProfile(definition: definition).agentDefinition.toolMode(
    for: AgentRuntime.agentStartToolName, in: [AgentRuntime.agentToolGroup]) == .disabled)
}

@Test("Tool status badges distinguish availability and mixed groups without ANSI in captured output")
func replToolsStatusBadges() async {
  let terminal = TerminalWriter(capturesOutput: true)
  #expect(await terminal.toolModeBadge(.direct) == "[● direct]")
  #expect(await terminal.toolModeBadge(.proxy) == "[● proxy]")
  #expect(await terminal.toolModeBadge(.hidden) == "[◐ hidden]")
  #expect(await terminal.toolModeBadge(.disabled) == "[○ disabled]")
  func summary(_ first: AgentToolMode, _ second: AgentToolMode) -> AgentToolModeSummary {
    .init(names: ["one", "two"], modes: ["one": first, "two": second])
  }
  #expect(await terminal.toolGroupBadge(summary(.direct, .proxy)) == "[● enabled]")
  #expect(await terminal.toolGroupBadge(summary(.hidden, .hidden)) == "[◐ hidden]")
  #expect(await terminal.toolGroupBadge(summary(.direct, .disabled)) == "[◐ mixed]")
  #expect(await terminal.toolGroupBadge(summary(.disabled, .disabled)) == "[○ disabled]")
}

@Test("Tool summary tables count modes and usage and preserve qualified catalog labels")
func replToolsTable() async {
  let groups = [
    ToolGroupDefinition(id: "files", displayName: "Files", toolNames: ["read", "write"]),
    ToolGroupDefinition(id: "remote", sourceID: "mcp", displayName: "A | **B**", toolNames: ["remote::a"]),
  ]
  let modes: [String: AgentToolMode] = ["read": .direct, "write": .hidden]
  var usage = AgentToolUsage()
  usage.record("read")
  usage.record("read")
  let table = MaiCLI.toolGroupsTable(groups, modes: modes, usage: usage)
  #expect(table.rows[0] == ["**files**", "● enabled", "1", "0", "1", "0", "2", "Files"])
  #expect(table.rows[1][0] == "**mcp/remote**")
  #expect(table.rows[1][1...6] == ["○ disabled", "0", "0", "0", "1", "0"])

  let terminal = TerminalWriter(capturesOutput: true)
  await terminal.table(table)
  let output = await terminal.drainCaptured()
  #expect(!output.contains("\u{1B}") && !output.contains("**files"))
  #expect(output.contains("A | **B**"))
  #expect(output.split(separator: "\n").count == groups.count + 1)
  let details = MaiCLI.toolDetailsTable(groups[0], modes: modes, usage: usage)
  #expect(details.rows.map { $0[1] } == ["direct", "hidden"])
  #expect(details.rows.map { $0[2] } == ["2", "0"])

  var buffer = TerminalOutputBuffer()
  let block = buffer.appendReply(table.markdown)
  buffer.finishReply(block)
  buffer.configureMarkdown(MarkdownTerminalRenderer(options: .init(tableBorders: false)))
  let compact = buffer.visibleRows(width: 130, height: 50).joined(separator: "\n")
  #expect(!compact.contains("┌"))
  #expect(compact.contains("mcp/remote") && compact.contains("A | **B**"))
  buffer.configureMarkdown(MarkdownTerminalRenderer(options: .init(tableBorders: true)))
  #expect(buffer.visibleRows(width: 130, height: 50).joined().contains("┌"))
  buffer.configureMarkdown(MarkdownTerminalRenderer(options: .init(tableBorders: false)))
  #expect(buffer.visibleRows(width: 130, height: 50).joined(separator: "\n") == compact)
  let narrow = buffer.visibleRows(width: 60, height: 50)
  #expect(narrow.count > groups.count + 1)
}
