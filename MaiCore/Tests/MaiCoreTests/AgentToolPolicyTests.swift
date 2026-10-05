import Foundation
import Testing

@testable import MaiCore

private let githubPolicyGroup = ToolGroupDefinition(
  id: "github", sourceID: "standard", toolNames: ["github_pr", "github_issue", "github_ci_log"])

@Test("Hybrid and automatic exposure default on, with explicit legacy settings preserved")
func toolPolicyDefaultsAndPersistence() throws {
  let legacy = Data(#"{"id":"main","provider":"hello","toolNames":["files_read"]}"#.utf8)
  var agent = try JSONDecoder().decode(AgentDefinition.self, from: legacy)
  #expect(agent.useToolProxy)
  #expect(agent.toolPolicy.automatic)
  agent.useToolProxy = false
  agent.proxyExposedTools = []
  agent.toolPolicy = .init(automatic: false, groups: ["github": .proxy], tools: ["github_pr": .direct])
  let saved = try JSONDecoder().decode(AgentDefinition.self, from: JSONEncoder().encode(agent))
  #expect(saved == agent)
  #expect(!saved.useToolProxy)
  #expect(saved.proxyExposedTools == [])
  #expect(!AgentRequest(provider: "hello", messages: []).useToolProxy)
  #expect(try JSONDecoder().decode(AgentToolPolicy.self, from: Data(#"{"tools":{}}"#.utf8)).automatic)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(AgentToolPolicy.self, from: Data(#"{"tools":{"x":"typo"}}"#.utf8))
  }
}

@Test("Exact tool settings override a group and persist when its membership grows")
func toolPolicyMemberOverrides() {
  var agent = AgentDefinition(id: "main", provider: "hello", model: "", toolGroupNames: ["github"])
  agent.setToolGroupMode(.proxy, for: githubPolicyGroup)
  agent.setToolMode(.direct, for: "github_pr")
  agent.setToolMode(.disabled, for: "github_ci_log")
  var expanded = githubPolicyGroup
  expanded.toolNames.insert("github_new")
  let states = agent.toolModes(in: [expanded])
  #expect(states["github_pr"] == .direct)
  #expect(states["github_issue"] == .proxy)
  #expect(states["github_ci_log"] == .disabled)
  #expect(states["github_new"] == .proxy)
  agent.setToolGroupMode(.disabled, for: expanded)
  #expect(agent.toolMode(for: "github_pr", in: [expanded]) == .direct)
  #expect(agent.toolMode(for: "github_issue", in: [expanded]) == .disabled)
  agent.setToolMode(nil, for: "github_pr")
  #expect(agent.toolMode(for: "github_pr", in: [expanded]) == .disabled)
}

@Test("Native, skill, and MCP selectors address groups and individual members without collisions")
func toolPolicySelectors() {
  let mcp = ToolGroupDefinition(id: "github", sourceID: "mcp", toolNames: ["gh::search", "gh::read"])
  let skills = MaiSkillTools.group(toolNames: ["skills_review"])
  let groups = [githubPolicyGroup, mcp, skills]
  let names = Set(groups.flatMap(\.toolNames))
  #expect(AgentToolSelection.resolve("github", groups: groups, names: names) == .group(githubPolicyGroup))
  #expect(AgentToolSelection.resolve("github/pr", groups: groups, names: names) == .tool("github_pr"))
  #expect(AgentToolSelection.resolve("tool:github_issue", groups: groups, names: names) == .tool("github_issue"))
  #expect(AgentToolSelection.resolve("mcp/github", groups: groups, names: names) == .group(mcp))
  #expect(AgentToolSelection.resolve("mcp/github/search", groups: groups, names: names) == .tool("gh::search"))
  #expect(AgentToolSelection.resolve("gh::read", groups: groups, names: names) == .tool("gh::read"))
  #expect(AgentToolSelection.resolve("skills/review", groups: groups, names: names) == .tool("skills_review"))
  #expect(AgentToolSelection.resolve("github/missing", groups: groups, names: names) == nil)
  let policy = AgentToolPolicy(groups: ["github": .direct, "mcp": .disabled, "mcp/github": .proxy])
  #expect(policy.mode(for: "github_pr", in: groups, enabled: false, useToolProxy: true) == .direct)
  #expect(policy.mode(for: "gh::search", in: groups, enabled: true, useToolProxy: true) == .proxy)
}

@Test("Automatic exposure is bounded, adapts to recent use, and never overrides manual choices")
func automaticToolExposure() {
  var usage = AgentToolUsage()
  for name in ["github_pr", "github_issue", "github_ci_log", "github_new", "fifth", "disabled"] {
    for _ in 0..<5 { usage.record(name) }
  }
  var group = githubPolicyGroup
  group.toolNames.formUnion(["github_new", "fifth", "disabled", "unused"])
  var agent = AgentDefinition(id: "main", provider: "hello", model: "", toolGroupNames: ["github"])
  agent.toolPolicy.tools = ["github_pr": .proxy, "disabled": .disabled]
  let states = agent.toolModes(in: [group], usage: usage)
  #expect(states["github_pr"] == .proxy)
  #expect(states["disabled"] == .disabled)
  #expect(states.values.count(where: { $0 == .direct }) == 4)
  #expect(states["unused"] == .proxy)
  #expect(usage.count(for: group) == 30)
  agent.toolPolicy.automatic = false
  #expect(agent.toolMode(for: "github_issue", in: [group], usage: usage) == .proxy)
  agent.toolPolicy.automatic = true
  agent.proxyExposedTools = []
  #expect(agent.toolMode(for: "github_issue", in: [group], usage: usage) == .proxy)
  for _ in 0..<AgentToolUsage.recentWindow { usage.record("other_workflow") }
  agent.proxyExposedTools = nil
  #expect(agent.toolMode(for: "github_issue", in: [group], usage: usage) == .proxy)
  #expect(usage.counts["github_issue"] == 5)
  #expect(usage.recent.count == AgentToolUsage.recentWindow)
}

@Test("Separate usage stores preserve concurrent increments and reload lifetime counters")
func toolUsagePersistence() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("usage.json")
  let first = AgentToolUsageStore(url: url)
  let second = AgentToolUsageStore(url: url)
  await withTaskGroup(of: Void.self) { group in
    for store in [first, second] {
      group.addTask { for _ in 0..<10 { await store.record("github_pr") } }
    }
  }
  let reloaded = AgentToolUsageStore(url: url)
  #expect(await reloaded.usage.counts["github_pr"] == 20)
  #expect(await reloaded.usage.promotedTools(among: ["github_pr"]) == ["github_pr"])
  #expect(await first.lastPersistenceError == nil)
  #expect(await second.lastPersistenceError == nil)
}


@Test("A counter persistence failure retains in-memory learning without failing tool use")
func toolUsagePersistenceFailure() async throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("not a directory".utf8).write(to: file)
  let store = AgentToolUsageStore(url: file.appendingPathComponent("usage.json"))
  let usage = await store.record("github_pr")
  #expect(usage.counts["github_pr"] == 1)
  #expect(await store.lastPersistenceError != nil)
}
