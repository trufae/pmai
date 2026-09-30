import Foundation

/// Tasks borrow an agent's inference settings, never its tool permissions.
public enum AgentTask: String, CaseIterable, Codable, Sendable {
  case compact
  case tool
  case approval

  public var instructions: String {
    switch self {
    case .approval:
      SmartToolApproval.instructions
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
  public var approval: String?

  public init(compact: String? = nil, tool: String? = nil, approval: String? = nil) {
    self.compact = compact
    self.tool = tool
    self.approval = approval
  }

  public subscript(task: AgentTask) -> String? {
    get {
      switch task {
      case .compact: compact
      case .tool: tool
      case .approval: approval
      }
    }
    set {
      switch task {
      case .compact: compact = newValue
      case .tool: tool = newValue
      case .approval: approval = newValue
      }
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
    let stem = "task-\(task.rawValue)"
    var id = stem
    var suffix = 2
    while agents.contains(where: { $0.id == id }), taskAgents[task] != id || current.id == id {
      id = "\(stem)-\(suffix)"
      suffix += 1
    }
    // Reusing a shorthand keeps its independently edited effort and prompt.
    // An unrelated agent with the same name must never be overwritten.
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
    normalizeTaskPromptNames()
  }

  /// Generated task agents keep their IDs, but expose shorter prompt names.
  /// Only migrate their original prompt association; explicit choices survive.
  mutating func normalizeTaskPromptNames() {
    for task in [AgentTask.compact, .tool] {
      guard let id = taskAgents[task], let index = agents.firstIndex(where: { $0.id == id })
      else { continue }
      let stem = "task-\(task.rawValue)"
      guard id == stem || (id.hasPrefix(stem + "-") && Int(id.dropFirst(stem.count + 1)) != nil),
        agents[index].systemPrompt == nil || agents[index].systemPrompt == id
      else { continue }
      var configured = prompts ?? ConfiguredPrompts()
      let text = configured.system[id] ?? agents[index].instructions
      var name = task.rawValue
      var suffix = 2
      while configured.system[name] != nil
        || agents.contains(where: { ($0.systemPrompt ?? $0.id) == name })
      {
        name = "\(task.rawValue)-\(suffix)"
        suffix += 1
      }
      configured.system[name] = text
      agents[index].systemPrompt = name
      agents[index].instructions = text
      if !agents.contains(where: { ($0.systemPrompt ?? $0.id) == id }) {
        configured.system[id] = nil
      }
      prompts = configured
    }
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
