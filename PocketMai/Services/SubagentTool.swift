import Foundation
import MaiCore

/// The `agent_*` tools in PocketMai. An agent whose profile may spawn
/// subagents sees them; a child is an isolated tool loop run in a Swift task
/// of its own, tracked by the app's `AgentSupervisor` the way pmai tracks its
/// processes, so the chat can list, steer, pause, and stop it. The tool
/// family itself — schemas, argument parsing, pids, results — comes from
/// MaiCore's `AgentProcessTools`; what lives here is how a child conversation
/// is put together from the app's agents and settings.
@MainActor
enum SubagentTool {
  /// Children one agent may have running at once; the rest wait their turn.
  static let maxConcurrentChildren = 3
  /// How deep the tree may go: a child's child may not start children.
  static let maxDepth = 2

  static var toolNames: Set<String> { AgentProcessTools.toolNames }

  static func isAgentTool(_ name: String) -> Bool {
    AgentProcessTools.isAgentTool(name)
  }

  /// The tools the conversation's agent sees, or nothing when it may not
  /// start children. A named agent is every other profile; leaving the name
  /// out runs a worker with the caller's own model and tools.
  static func definitions(for conversation: Conversation, settings: AppSettings) -> [ToolDefinition] {
    guard conversation.toolsEnabled, settings.selectedAgent.canSpawnSubagents else { return [] }
    return AgentProcessTools.definitions(
      offering: offeredAgents(settings: settings),
      delegating: true,
      planFirst: settings.plansBeforeDelegating)
  }

  /// The settings a child at `depth` runs with: the caller's own, or another
  /// profile's once selected. A child is a peer of its parent and may start
  /// children of its own, except at the leaf depth, where it could not start
  /// anything: there the agent tools are withheld, so it does not pay for
  /// their schemas on every call.
  static func childSettings(from settings: AppSettings, agentID: UUID, depth: Int) -> AppSettings {
    var child = settings
    if child.selectedAgentID != agentID { child.selectAgent(agentID) }
    if depth >= maxDepth, let index = child.agents.firstIndex(where: { $0.id == agentID }) {
      child.agents[index].canSpawnSubagents = false
    }
    return child
  }

  /// Every agent other than the caller's, by name. The first of two agents
  /// sharing a name is the one the name reaches.
  static func offeredAgents(settings: AppSettings) -> [AgentProcessTools.OfferedAgent] {
    let caller = settings.selectedAgent
    var seen: Set<String> = [caller.name]
    return settings.agents.compactMap { agent in
      guard agent.id != caller.id, seen.insert(agent.name).inserted else { return nil }
      return AgentProcessTools.OfferedAgent(id: agent.name, purpose: agent.description)
    }
  }

  static func execute(
    call: ParsedToolCall,
    conversation: Conversation,
    settings: AppSettings,
    store: AppStore
  ) async -> String {
    let arguments = call.argumentValues
    let callID = call.toolCallID ?? "text_\(UUID().uuidString)"
    let supervisor = store.agentSupervisor
    let caller = await store.agentProcessID(
      for: conversation, agentName: settings.selectedAgent.name)
    let result: ToolResult
    switch AgentProcessTools.canonicalName(call.name) {
    case AgentProcessTools.startToolName:
      result = await start(
        arguments,
        toolName: call.name,
        callID: callID,
        caller: caller,
        conversation: conversation,
        settings: settings,
        store: store)
    case AgentProcessTools.statusToolName:
      result = await AgentProcessTools.status(
        arguments: arguments, callID: callID, caller: caller, supervisor: supervisor)
    case AgentProcessTools.resultToolName:
      result = await AgentProcessTools.result(
        arguments: arguments, callID: callID, caller: caller, supervisor: supervisor)
    case AgentProcessTools.stopToolName:
      result = await AgentProcessTools.stop(
        arguments: arguments,
        callID: callID,
        caller: caller,
        supervisor: supervisor,
        stoppedBy: settings.selectedAgent.name)
    default:
      result = AgentProcessTools.failure(callID: callID, "unknown agent tool '\(call.name)'.")
    }
    return result.text
  }

  // MARK: - agent_start

  /// Who a child is started from: the caller's own settings, or another
  /// agent's profile.
  private enum Target {
    case worker
    case profile(AgentProfile)
  }

  private static func start(
    _ arguments: [String: JSONValue],
    toolName: String,
    callID: String,
    caller: AgentPID,
    conversation: Conversation,
    settings: AppSettings,
    store: AppStore
  ) async -> ToolResult {
    guard let start = AgentProcessTools.StartArguments(arguments: arguments, toolName: toolName)
    else {
      return AgentProcessTools.failure(callID: callID, "the brief needs a non-empty 'task'.")
    }
    let parent = settings.selectedAgent
    let target: Target
    if let name = start.agent {
      guard
        let profile = settings.agents.first(where: {
          $0.id != parent.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        })
      else {
        return AgentProcessTools.failure(
          callID: callID, "agent '\(name)' is not available to this agent.")
      }
      target = .profile(profile)
    } else {
      target = .worker
    }
    let depth = (await store.agentSupervisor.info(caller)?.depth ?? 0) + 1
    guard depth <= maxDepth else {
      return AgentProcessTools.failure(
        callID: callID, "the subagent depth limit for this run is reached.")
    }

    let agentID: String
    let displayName: String
    let childSettings: AppSettings
    let baseContext: String
    var child = Conversation()
    switch target {
    case .worker:
      agentID = "\(parent.name).worker"
      displayName = "\(parent.name) worker"
      childSettings = Self.childSettings(from: settings, agentID: parent.id, depth: depth)
      baseContext = AgentDelegationPrompt.workerInstructions
      child.provider = conversation.provider
      child.modelID = conversation.modelID
      child.endpointID = conversation.endpointID
      child.systemPromptID = conversation.systemPromptID
      child.toolsEnabled = conversation.toolsEnabled
      child.enabledTools = conversation.enabledTools
      child.enabledMCPServers = conversation.enabledMCPServers
      child.enabledMCPTools = conversation.enabledMCPTools
      child.disabledMCPTools = conversation.disabledMCPTools
      child.reasoningLevel = conversation.reasoningLevel
      child.usesStreaming = conversation.usesStreaming
      child.contextWindowMode = conversation.contextWindowMode
      child.mlxMaxKVSize = conversation.mlxMaxKVSize
    case .profile(let profile):
      agentID = profile.name
      displayName = profile.name
      let selected = Self.childSettings(from: settings, agentID: profile.id, depth: depth)
      childSettings = selected
      baseContext = ""
      let provider = selected.defaultProviderConfiguration
      child.provider = provider.provider
      child.modelID = provider.modelID
      child.endpointID = provider.endpointID
      child.systemPromptID = selected.defaultSystemPromptID
      child.toolsEnabled = true
      child.enabledTools = selected.defaultEnabledTools
      child.enabledMCPServers = selected.defaultEnabledMCPServers
      child.enabledMCPTools = selected.defaultEnabledMCPTools
      child.reasoningLevel = selected.defaultReasoningLevel
      child.usesStreaming = selected.streamByDefault
    }
    child.folderID = conversation.folderID
    child.workingFolder = conversation.workingFolder
    child.languageOverrideIdentifier = conversation.languageOverrideIdentifier
    // The child works in the session of the chat that started the tree, so a
    // per-session provider header carries one value for all of them.
    child.sessionID = conversation.sessionID
    child.showThinking = false
    child.isPinned = false

    let workspace =
      child.toolsEnabled && !child.enabledTools.isDisjoint(with: [.files, .vdb])
      ? FileWorkspaceTool.workspaceName(for: child, settings: childSettings) : ""
    let prompt = AgentDelegationPrompt.render(
      start.brief, agent: agentID, workingDirectory: workspace)
    child.messages = [ChatMessage(role: .user, text: prompt)]

    if let preflight = ChatProviderRouter.preflightMessage(
      conversation: child, settings: childSettings)
    {
      return AgentProcessTools.failure(callID: callID, "agent '\(agentID)' cannot run: \(preflight)")
    }

    // A child past the concurrency limit is not refused: it is registered as
    // queued and starts on its own when a sibling ends.
    let supervisor = store.agentSupervisor
    let runID = UUID()
    let (pid, admitted) = await AgentProcessTools.register(
      supervisor: supervisor,
      runID: runID,
      parent: caller,
      agentID: agentID,
      displayName: displayName,
      task: start.brief.headline,
      depth: depth,
      limit: maxConcurrentChildren)
    child.title = "\(displayName) \(pid)"
    store.registerAgentProcess(pid, for: child.id)
    let childConversation = child
    let task = Task { @MainActor in
      defer { store.forgetAgentProcess(for: childConversation.id) }
      return try await AgentProcessTools.run(
        pid,
        supervisor: supervisor,
        limit: maxConcurrentChildren,
        admitted: admitted,
        background: !start.wait
      ) {
        try await SubagentRunner.run(
          conversation: childConversation,
          settings: childSettings,
          baseContext: baseContext,
          runID: runID,
          agentID: agentID,
          process: pid,
          store: store)
      }
    }
    await supervisor.attach(task, to: pid)

    guard start.wait else {
      return AgentProcessTools.startedResult(
        callID: callID,
        pid: pid,
        agentID: agentID,
        queued: !admitted,
        slots: maxConcurrentChildren)
    }
    do {
      let result = try await AgentProcessTools.awaitChild(task, pid: pid, supervisor: supervisor)
      return AgentProcessTools.childResult(
        callID: callID, pid: pid, agentID: agentID, result: result)
    } catch {
      return AgentProcessTools.childFailure(
        callID: callID, pid: pid, agentID: agentID, error: error)
    }
  }
}

/// Runs one child conversation through the isolated tool loop and turns
/// what came back into the `AgentResult` the supervisor keeps.
@MainActor
enum SubagentRunner {
  static func run(
    conversation: Conversation,
    settings: AppSettings,
    baseContext: String,
    runID: UUID,
    agentID: String,
    process: AgentPID,
    store: AppStore
  ) async throws -> AgentResult {
    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation,
      settings: settings,
      baseContext: baseContext,
      store: store,
      process: process)
    return AgentResult(
      runID: runID,
      agentID: agentID,
      provider: ProviderID(conversation.provider.rawValue),
      response: .assistant(result.text),
      transcript: transcript(of: result.conversation),
      usage: nil,
      stopReason: .stop,
      modelTurns: result.modelTurns,
      toolCalls: result.toolRuns.count)
  }

  /// The child's conversation as the supervisor lists it, so `agent_status`
  /// with `log` and the chat's process sheet can read it.
  static func transcript(of conversation: Conversation) -> [AgentMessage] {
    conversation.messages.compactMap { message in
      let text = message.text
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      switch message.role {
      case .user: return .user(text)
      case .assistant, .error: return .assistant(text)
      case .system: return .system(text)
      case .tool: return AgentMessage(role: .tool, content: [.text(text)])
      }
    }
  }
}
