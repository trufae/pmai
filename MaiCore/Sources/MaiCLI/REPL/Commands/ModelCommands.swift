import Foundation
import MaiCore
import MaiStandardTools

extension MaiCLI {
  static func handleModelCommand(
    _ argument: String, session: inout REPLSession, runtime: AgentRuntime,
    configuration: inout MaiConfiguration?, configurationPath: String?, terminal: TerminalWriter
  ) async {
    var words = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    let chatOnly = words.first == "-chat"
    if chatOnly { words.removeFirst() }
    guard let first = words.first else {
      let selection = session.profile.provider.rawValue.isEmpty
        ? "no model selected" : "\(session.profile.provider)::\(session.profile.model)"
      var plain = ["Chat: \(selection)"]
      var rows = [["Chat", selection, session.profile.agentDefinition.id,
                   session.profile.options.reasoningEffort ?? "auto"]]
      for task in AgentTask.allCases {
        let id = configuration?.taskAgents[task]
        let agent = configuration?.agents.first { $0.id == id }
        let detail = agent.map {
          "\($0.id) — \($0.provider)::\($0.model), effort \($0.options.reasoningEffort ?? "auto")"
        }
        plain.append("\(task.rawValue): \(detail ?? "current agent")")
        let title = switch task {
        case .compact: "Compaction"
        case .tool: "Tool decisions"
        case .approval: "Smart approval"
        case .btw: "Side questions"
        case .voiceover: "Voiceover"
        case .voice: "Voice conversation"
        }
        rows.append([
          title,
          agent.map { "\($0.provider)::\($0.model)" } ?? selection,
          agent?.id ?? "current agent",
          agent.map { $0.options.reasoningEffort ?? "auto" }
            ?? session.profile.options.reasoningEffort ?? "auto",
        ])
      }
      let table = (["| Task | Model | Agent | Effort |", "| --- | --- | --- | --- |"]
        + rows.map { "| " + $0.map(markdownTableCell).joined(separator: " | ") + " |" })
        .joined(separator: "\n")
      await terminal.markdown(
        "## Current models\n\n" + table,
        plainText: plain.joined(separator: "\n"))
      await terminal.markdown(modelHelp)
      return
    }
    guard var draft = configuration, let configurationPath else { return }
    do {
      var chatDefinition: AgentDefinition?
      let message: String
      if !chatOnly, ["-compact", "-tool", "-approval", "-aproval", "-btw", "-voice"].contains(first) {
        guard words.count <= 2 else {
          await terminal.line("Usage: /model \(first) [AGENT|PROVIDER::MODEL|MODEL]")
          return
        }
        let task: AgentTask = switch first {
        case "-compact": .compact
        case "-tool": .tool
        case "-btw": .btw
        case "-voice": .voice
        default: .approval
        }
        try draft.assignTask(
          task, selector: words.count == 2 ? words[1] : nil,
          current: session.profile.agentDefinition)
        message = "\(task.rawValue): \(draft.taskAgents[task] ?? "current agent") (saved)"
      } else {
        guard words.count == 1, !first.hasPrefix("-") else {
          await terminal.markdown(modelHelp)
          return
        }
        let selection = try draft.modelSelection(first, currentProvider: session.profile.provider)
        var definition = session.profile.agentDefinition
        definition.provider = selection.provider
        definition.model = selection.model
        draft.upsertAgent(definition)
        draft.defaultAgent = definition.id
        MaiAgentPresets.install(in: &draft, using: definition)
        if !chatOnly {
          for task in AgentTask.allCases {
            try draft.assignTask(
              task, selector: "\(selection.provider)::\(selection.model)", current: definition)
          }
        }
        chatDefinition = definition
        let scope = chatOnly ? "agent \(definition.id)" : "chat and all tasks"
        message = "Model: \(selection.provider)::\(selection.model) (saved for \(scope)) · default for new chats"
      }
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      for agent in draft.agents
      where configuration?.agents.first(where: { $0.id == agent.id }) != agent {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      await runtime.configureTaskAgents(draft.taskAgents)
      configuration = draft
      if let chatDefinition {
        try applyDefinition(chatDefinition, to: &session)
      }
      await terminal.line(message)
    } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
  }

  // MARK: Effort

  /// `/set effort` shows the reasoning level and guidance of the current
  /// agent; `/set effort LEVEL [TEXT]` sets them and `/set effort auto` clears
  /// them. The level
  /// reaches the provider as the field its API family takes and, with the
  /// guidance, the system prompt; both persist on the agent like /set does.
  static func handleEffortCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let first = fields.first?.lowercased() else {
      await terminal.line(effortDescription(session.profile.options))
      return
    }
    let guidance = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if ["auto", "automatic", "default", "clear"].contains(first) {
      session.profile.options.reasoningEffort = nil
      session.profile.options.reasoningGuidance = nil
    } else if let effort = ReasoningEffort(name: first) {
      session.profile.options.reasoningEffort = effort.rawValue
      session.profile.options.reasoningGuidance = guidance.isEmpty ? nil : guidance
    } else {
      await terminal.line(effortHelp)
      return
    }
    session.touch()
    let summary = effortDescription(session.profile.options)
    let endpoint = configuration?.providers.first { $0.id == session.profile.provider.rawValue }
    let effort =
      session.profile.options.reasoningEffort.flatMap(ReasoningEffort.init(name:))
      ?? .automatic
    if let note = effort.limitation(
      model: session.profile.model,
      provider: session.profile.provider.rawValue,
      baseURL: endpoint?.baseURL?.absoluteString ?? "")
    {
      await terminal.line(note)
    }
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("Set \(summary) for this chat.")
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line("Set \(summary) for agent '\(session.profile.agentID)'.")
    }
  }

  /// `effort = high — Check every edge case.`, or `effort = off`.
  static func effortDescription(_ options: GenerationOptions) -> String {
    let level = options.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let guidance = options.reasoningGuidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var text = "effort = \(level.isEmpty ? "auto" : level)"
    if !guidance.isEmpty { text += " — \(guidance)" }
    return text
  }
}
