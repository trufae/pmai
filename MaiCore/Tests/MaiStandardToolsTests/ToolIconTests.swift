import MaiCore
import MaiStandardTools
import Testing

@Test("Every built-in tool has a distinct single emoji; dynamic families have stable fallbacks")
func toolIcons() async throws {
  let groups = try await MaiStandardToolFactory().toolGroups(context: .init(id: "tools"))
  let names = Set(groups.flatMap(\.toolNames)).union(AgentProcessTools.toolNames)
    .union(MaiContextTools.toolNames).union(MaiMemoryTools.toolNames)
    .union(MaiTodoTools.toolNames).union([ToolProxy.listName, ToolProxy.callName])
  let icons = names.map { ToolIcon.emoji(for: $0) }
  #expect(icons.allSatisfy { $0.count == 1 && $0 != "🔧" })
  #expect(Set(icons).count == names.count)
  #expect(ToolIcon.emoji(for: "spawn_agent") == ToolIcon.emoji(for: "agent_start"))
  #expect(ToolIcon.emoji(for: "skills_review") == "🎓")
  #expect(ToolIcon.emoji(for: "server::search") == "🔌")
  #expect(ToolIcon.emoji(for: "plugin_custom") == "🔧")
}
