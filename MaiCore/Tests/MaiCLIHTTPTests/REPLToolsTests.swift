import Foundation
import MaiCore
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
