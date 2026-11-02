import MaiCore

/// Installs ordinary, editable presets without inheriting the main agent's
/// write tools, MCP permissions, skills, or delegation settings.
public enum MaiAgentPresets {
  @discardableResult
  public static func install(
    in configuration: inout MaiConfiguration, using fallback: AgentDefinition? = nil
  ) -> [String] {
    guard let source = configuration.agents.first(where: { $0.id == "main" })
      ?? fallback
      ?? configuration.agents.first(where: { $0.id == configuration.defaultAgent })
      ?? configuration.agents.first,
      !source.provider.rawValue.isEmpty
    else { return [] }
    let reads = MaiFileWorkspaceTool.Operation.allCases.filter { !$0.changesFiles }.map(\.rawValue)
    let planner = AgentDefinition(
      id: "plan",
      description: "Explores options, resolves questions, and prepares a plan for an implementation agent.",
      instructions: SystemPrompt.planningInstructions,
      systemPrompt: "plan",
      provider: source.provider,
      model: source.model,
      toolNames: Set(reads + [MaiTodoTools.listName, MaiTodoTools.addName]),
      stream: source.stream,
      options: GenerationOptions(reasoningEffort: ReasoningEffort.medium.rawValue),
      toolPolicy: .init(groups: ["mcp": .disabled], localOnly: true))
    let bare = AgentDefinition(
      id: "bare",
      description: "Chats without tools or added system context, starting with an empty system prompt.",
      instructions: "",
      systemPrompt: "bare",
      systemContext: false,
      provider: source.provider,
      model: source.model,
      stream: source.stream,
      toolCallingStrategy: .off,
      useToolProxy: false,
      toolPolicy: .init(automatic: false, groups: ["mcp": .disabled], localOnly: true),
      autocompact: .init(tokens: 0))
    let previousDefault = configuration.defaultAgent
    var installed: [String] = []
    for agent in [planner, bare] {
      // Retained prompts prevent deleted presets from being recreated.
      guard !configuration.agents.contains(where: { $0.id == agent.id }),
        configuration.prompts?.system[agent.id] == nil
      else { continue }
      configuration.upsertAgent(agent)
      installed.append(agent.id)
    }
    configuration.defaultAgent = previousDefault
    return installed
  }
}
