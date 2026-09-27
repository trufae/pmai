import Foundation

/// Tasks borrow an agent's inference settings, never its tool permissions.
public enum AgentTask: String, CaseIterable, Codable, Sendable {
  case compact
  case tool

  public var instructions: String {
    switch self {
    case .compact:
      "Summarize the conversation accurately, preserving the facts needed to continue the task."
    case .tool:
      "Choose and call the available tools needed for the user's task. When the results are sufficient, stop calling tools; the conversation's primary agent will write the final answer."
    }
  }
}

/// Installation-wide assignments. Nil means the agent running the conversation.
/// References use the host's agent IDs (names in pmai, UUIDs in PocketMai).
public struct TaskAgentAssignments: Codable, Equatable, Sendable {
  public var compact: String?
  public var tool: String?

  public init(compact: String? = nil, tool: String? = nil) {
    self.compact = compact
    self.tool = tool
  }

  public subscript(task: AgentTask) -> String? {
    get { task == .compact ? compact : tool }
    set {
      if task == .compact { compact = newValue } else { tool = newValue }
    }
  }

  public mutating func removeReferences(to id: String) {
    for task in AgentTask.allCases where self[task] == id { self[task] = nil }
  }
}

extension MaiConfiguration {
  /// Agent ID, provider::model, or a model on the current provider. The explicit
  /// separator leaves slashes and colons in model IDs (Ollama/Hugging Face) intact.
  public mutating func assignTask(
    _ task: AgentTask, selector: String?, current: AgentDefinition
  ) throws {
    guard let selector, !["", "-", "default"].contains(selector) else {
      taskAgents[task] = nil
      return
    }
    if let agent = agents.first(where: { $0.id == selector }) {
      guard agent.isEnabled else { throw MaiConfigurationError.disabledTaskAgent(selector) }
      taskAgents[task] = agent.id
      return
    }
    let selection = try modelSelection(selector, currentProvider: current.provider)
    let id = "task-\(task.rawValue)"
    // Reusing a shorthand keeps its independently edited effort and prompt.
    var agent =
      agents.first(where: { $0.id == id })
      ?? AgentDefinition(
        id: id, instructions: task.instructions, provider: selection.provider,
        model: selection.model)
    agent.provider = selection.provider
    agent.model = selection.model
    agent.isEnabled = true
    upsertAgent(agent)
    taskAgents[task] = id
  }

  public func modelSelection(_ selector: String, currentProvider: ProviderID) throws
    -> (provider: ProviderID, model: String)
  {
    let parts = selector.components(separatedBy: "::")
    let provider = parts.count == 1 ? currentProvider : ProviderID(parts[0])
    let model = parts.count == 1 ? selector : parts.dropFirst().joined(separator: "::")
    guard providers.contains(where: { $0.id == provider.rawValue }) else {
      throw MaiConfigurationError.unknownProvider(provider.rawValue)
    }
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MaiConfigurationError.emptyIdentifier("model")
    }
    return (provider, model)
  }
}
