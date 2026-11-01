import MaiCore

/// Installs an ordinary, editable preset without inheriting the main agent's
/// write tools, MCP permissions, skills, or delegation settings.
public enum MaiPlanningAgent {
  @discardableResult
  public static func install(
    in configuration: inout MaiConfiguration, using fallback: AgentDefinition? = nil
  ) -> Bool {
    // A retained prompt also lets a user delete the preset without having it
    // recreated on every launch. Existing definitions and prompts are theirs.
    guard !configuration.agents.contains(where: { $0.id == "plan" }),
      configuration.prompts?.system["plan"] == nil,
      let source = configuration.agents.first(where: { $0.id == "main" })
        ?? fallback
        ?? configuration.agents.first(where: { $0.id == configuration.defaultAgent })
        ?? configuration.agents.first,
      !source.provider.rawValue.isEmpty
    else { return false }
    let reads = MaiFileWorkspaceTool.Operation.allCases.filter { !$0.changesFiles }.map(\.rawValue)
    let agent = AgentDefinition(
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
    let previousDefault = configuration.defaultAgent
    configuration.upsertAgent(agent)
    configuration.defaultAgent = previousDefault
    return true
  }
}
