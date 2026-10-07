import Foundation

extension AgentRuntime {
  /// A nameless worker inherits its parent's live settings. Named agents keep
  /// their own definition, including when that definition is edited mid-run.
  struct DerivedRun: Sendable {
    var parent: AgentPID
    var tools: Set<String>?
    var delegates: Bool
  }

  public func register(
    agent: AgentDefinition,
    replacingExisting: Bool = false
  ) async throws {
    let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw AgentRuntimeError.invalidAgentID }
    guard replacingExisting || agents[id] == nil else {
      throw AgentRuntimeError.agentAlreadyRegistered(id)
    }
    agents[id] = agent
    // A named agent already running reads its edited definition at its next
    // safe boundary. Derived workers are refreshed from their live parent.
    for pid in Array(liveRequests.keys) {
      guard var request = liveRequests[pid], request.agentID == id else { continue }
      request.applyRuntimeSettings(from: agent)
      liveRequests[pid] = request
      await runBudgets[pid]?.update(limits: request.limits)
    }
    await refreshDerivedBudgets()
  }

  /// Every registered definition, disabled ones included, so a host can list
  /// and re-enable them. Pass false to see only what can actually be run.
  public func availableAgents(includingDisabled: Bool = true) -> [AgentDefinition] {
    agents.values
      .filter { includingDisabled || $0.isEnabled }
      .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }

  /// Forgets a definition, so it is no longer offered or startable. A run
  /// already using it carries on with the copy it was given.
  public func unregister(agentID: String) {
    agents[agentID] = nil
  }

  /// Replaces the operational settings of a running process. The provider or
  /// tool call already in flight is allowed to finish; the next call observes
  /// the new provider, model, tools, generation options, limits and policies.
  /// The run's messages and session identity are deliberately left alone.
  @discardableResult
  public func reconfigure(_ process: AgentPID, with request: AgentRequest) async -> Bool {
    guard let info = await supervisor.info(process), !info.state.isTerminal
    else { return false }
    if var current = liveRequests[process] {
      current.applyRuntimeSettings(from: request)
      liveRequests[process] = current
      await runBudgets[process]?.update(limits: current.limits)
      await refreshDerivedBudgets()
    } else {
      pendingReconfigurations[process] = request
    }
    return true
  }

  /// Installs the durable memory every top-level run should see, already
  /// wrapped in its envelope by `AgentMemory.promptSection`. Nil removes it.
  public func configureMemory(_ section: String?) {
    memorySection = section?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Installs the project's AGENTS.md text, already wrapped by
  /// `AgentInstructionsFile.promptSection`. Runs at every depth see it: a
  /// child working in the same tree needs the same rules. Nil removes it.
  public func configureProjectInstructions(_ section: String?) {
    instructionsSection =
      section?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Enables scoped AGENTS.md discovery for a workspace. Reconfiguring the
  /// same directory keeps the per-conversation cache intact.
  public func configureProjectInstructionDirectory(_ directory: URL?) {
    let selected = directory?.standardizedFileURL.resolvingSymlinksInPath()
    guard selected != instructionsDirectory else { return }
    instructionsDirectory = selected
    instructionContexts.removeAll()
  }

  /// Installs host-configured delegation text. Empty or nil values restore the
  /// built-in template and worker instructions.
  public func configureDelegation(prompt: String?, workerInstructions: String?) {
    delegationTemplate = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
    self.workerInstructions =
      workerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Whether `agent_start` asks the model to open a request of several steps
  /// with a numbered plan before its first delegation (`use.plan`). Off until
  /// a host says otherwise.
  public func configurePlanning(_ enabled: Bool) {
    plansBeforeDelegating = enabled
  }

  /// Installs the template autocompact summarizes with, the same one a host
  /// uses for `/chat compact`. Empty or nil restores `AgentCompactionPrompt`.
  public func configureCompaction(prompt: String?) {
    compactionTemplate = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Installs the disposable working-context prompt used by `context: smart`.
  public func configureSmartContext(prompt: String?) {
    smartContextTemplate = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  public func configureTaskAgents(_ assignments: TaskAgentAssignments) {
    taskAgents = assignments
  }

  /// Resolve inference settings only. The caller keeps its tool permissions,
  /// approvals, budgets, and session identity; task assignments never recurse.
  public func taskRequest(_ task: AgentTask, from original: AgentRequest) throws -> AgentRequest {
    var request = original
    if let id = taskAgents[task] {
      guard let agent = agents[id] else { throw MaiConfigurationError.unknownAgent(id) }
      guard agent.isEnabled else { throw MaiConfigurationError.disabledTaskAgent(id) }
      request.provider = agent.provider
      request.model = agent.model
      request.options = agent.options
      request.responseFormat = agent.responseFormat
      request.retry = agent.retry
      request.stream = agent.stream
      request.toolCallingStrategy = agent.toolCallingStrategy
      if !agent.instructions.isEmpty {
        insertSystem(agent.instructions, into: &request.messages)
      }
    }
    if task == .compact {
      request.agentID = "\(original.agentID).compact"
      request.toolNames = []
      request.toolPolicy = .init()
      request.toolGroupNames = []
      request.subagentNames = []
      request.toolChoice = .none
      request.responseFormat = .text
      request.stream = false
      request.autocompact = .init(tokens: 0)
      request.context = .cache
      request.useToolProxy = false
    }
    return request
  }

  /// Returns the newest settings for one run. Derived workers are rebuilt
  /// from their parent so a `/set`, `/model`, or `/tools` change propagates
  /// through the active tree without flattening named agents' own profiles.
  func currentRequest(_ fallback: AgentRequest, for pid: AgentPID) -> AgentRequest {
    var current = liveRequests[pid] ?? fallback
    if let derived = derivedRuns[pid], let parentFallback = liveRequests[derived.parent] {
      let parent = currentRequest(parentFallback, for: derived.parent)
      let narrowedTools: Set<String>
      if let wanted = derived.tools {
        let allowed = parent.toolNames.intersection(wanted)
        narrowedTools = allowed.isEmpty ? parent.toolNames : allowed
      } else {
        narrowedTools = parent.toolNames
      }
      let definition = derivedWorker(
        for: parent,
        toolNames: narrowedTools,
        delegates: derived.delegates)
      current.applyRuntimeSettings(from: definition)
      current.restrictedToolNames = derived.tools
      if let inherited = parent.restrictedToolNames {
        current.restrictedToolNames = derived.tools.map { $0.intersection(inherited) } ?? inherited
      }
    }
    liveRequests[pid] = current
    return current
  }

  private func refreshDerivedBudgets() async {
    for pid in Array(derivedRuns.keys) {
      guard let fallback = liveRequests[pid] else { continue }
      let inherited = currentRequest(fallback, for: pid)
      await runBudgets[pid]?.update(limits: inherited.limits)
    }
  }

  func queuedInterruption(
    for pid: AgentPID, fallback: AgentRequest, budget: RunBudget
  ) async -> AgentRunInterruption? {
    let request = currentRequest(fallback, for: pid)
    await budget.update(limits: request.limits)
    return await budget.exhausted()
  }

  func clearLiveRequest(for pid: AgentPID) {
    liveRequests[pid] = nil
    derivedRuns[pid] = nil
    runBudgets[pid] = nil
    pendingReconfigurations[pid] = nil
  }

  /// The agent MaiCore invents when a delegating agent does not name a child:
  /// same provider and model, the parent's tools, and the parent's delegation
  /// and subagents, so it is a peer that hands work down in turn until the
  /// depth limit hides the agent tools. Without it, switching delegation on
  /// would leave an agent with no way to do anything.
  func derivedWorker(
    for request: AgentRequest,
    toolNames: Set<String>,
    delegates: Bool = true
  ) -> AgentDefinition {
    AgentDefinition(
      id: "\(request.agentID).worker",
      displayName: "\(request.agentID) worker",
      instructions: workerInstructions ?? AgentDelegationPrompt.workerInstructions,
      provider: request.provider,
      model: request.model,
      toolNames: delegates ? toolNames.union(Self.agentToolNames) : toolNames,
      toolGroupNames: delegates
        ? (request.toolGroupNames ?? [])
        : (request.toolGroupNames ?? []).subtracting([Self.agentToolGroup.id]),
      subagentNames: delegates ? request.subagentNames : [],
      stream: request.stream,
      limits: request.limits,
      options: request.options,
      toolCallingStrategy: request.toolCallingStrategy,
      useToolProxy: request.useToolProxy,
      useSystemOne: request.useSystemOne,
      proxyExposedTools: request.proxyExposedTools,
      toolPolicy: request.toolPolicy,
      toolDelegation: delegates ? request.toolDelegation : .inline,
      retry: request.retry,
      autocompact: request.autocompact,
      context: request.context)
  }

  func request(
    for definition: AgentDefinition,
    messages: [AgentMessage],
    sessionID: String? = nil
  ) -> AgentRequest {
    var transcript = messages
    let instructions = definition.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !instructions.isEmpty {
      transcript.insert(.system(instructions), at: 0)
    }
    var request = AgentRequest(
      agentID: definition.id,
      provider: definition.provider,
      messages: transcript,
      sessionID: sessionID)
    request.applyRuntimeSettings(from: definition)
    return request
  }
}

extension AgentRequest {
  /// Copies only values that may change while a run is in progress. The
  /// transcript, queued-message exclusions, process identity and chat session
  /// belong to the run itself and are never replaced by reconfiguration.
  mutating func applyRuntimeSettings(from other: AgentRequest) {
    provider = other.provider
    model = other.model
    toolNames = other.toolNames
    toolGroupNames = other.toolGroupNames
    subagentNames = other.subagentNames
    toolChoice = other.toolChoice
    responseFormat = other.responseFormat
    options = other.options
    limits = other.limits
    stream = other.stream
    toolCallingStrategy = other.toolCallingStrategy
    useToolProxy = other.useToolProxy
    useSystemOne = other.useSystemOne
    proxyExposedTools = other.proxyExposedTools
    toolPolicy = other.toolPolicy
    toolDelegation = other.toolDelegation
    retry = other.retry
    autocompact = other.autocompact
    context = other.context
  }

  mutating func applyRuntimeSettings(from definition: AgentDefinition) {
    provider = definition.provider
    model = definition.model
    toolNames = definition.toolNames
    toolGroupNames = definition.toolGroupNames
    subagentNames = definition.subagentNames
    toolChoice = definition.toolChoice
    responseFormat = definition.responseFormat
    options = definition.options
    limits = definition.limits
    stream = definition.stream
    toolCallingStrategy = definition.toolCallingStrategy
    useToolProxy = definition.useToolProxy
    useSystemOne = definition.useSystemOne
    proxyExposedTools = definition.proxyExposedTools
    toolPolicy = definition.toolPolicy
    toolDelegation = definition.toolDelegation
    retry = definition.retry
    autocompact = definition.autocompact
    context = definition.context
  }
}

extension String {
  fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
