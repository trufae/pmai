import Foundation

extension AgentRuntime {
  // The family itself lives in `AgentProcessTools`, shared with hosts that run
  // children through a loop of their own. What stays here is what only the
  // runtime knows: which definition a name resolves to, the derived worker,
  // the run budget, and the events a host follows.

  func startAgent(
    _ call: ToolCall,
    legacyName: String,
    request: AgentRequest,
    parent: AgentEventContext,
    depth: Int,
    launched: @escaping @Sendable () -> Void = {},
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    guard let start = AgentProcessTools.StartArguments(arguments: arguments, toolName: legacyName)
    else {
      return await fail(call, "the brief needs a non-empty 'task'.", parent: parent, emit: emit)
    }

    let definition: AgentDefinition
    let derived: DerivedRun?
    if let requestedAgent = start.agent {
      guard request.subagentNames.contains(requestedAgent), var named = agents[requestedAgent],
        named.isEnabled
      else {
        return await fail(
          call, "agent '\(requestedAgent)' is not available to this agent.",
          parent: parent, emit: emit)
      }
      named.toolNames = start.narrowed(named.toolNames)
      definition = named
      derived = nil
    } else if Self.canDeriveWorker(for: request) {
      // A parent that narrowed the child's tools and left the agent family
      // out said what the child may use: that child is a leaf and pays for
      // no agent schemas. Otherwise the worker is a peer.
      let delegates = start.tools.map { $0.contains(where: AgentProcessTools.isAgentTool) } ?? true
      definition = derivedWorker(
        for: request, toolNames: start.narrowed(request.toolNames), delegates: delegates)
      derived = parent.pid.map { DerivedRun(parent: $0, tools: start.tools, delegates: delegates) }
    } else {
      return await fail(
        call,
        "no agent was named. Available agents: "
          + request.subagentNames.sorted().joined(separator: ", ") + ".",
        parent: parent, emit: emit)
    }

    guard request.limits.maxSubagents > 0 else {
      return await fail(
        call, "this agent may not start children (limits.maxSubagents is 0).",
        parent: parent, emit: emit)
    }
    guard depth + 1 <= request.limits.maxSubagentDepth else {
      return await fail(
        call, "the subagent depth limit for this run is reached.",
        parent: parent, emit: emit)
    }

    let prompt = AgentDelegationPrompt.render(
      start.brief,
      agent: definition.id,
      workingDirectory: AgentExecutionScope.directory.path,
      template: delegationTemplate)
    // A child works in the session of the chat that started it, so a
    // per-session header carries the same value for the whole tree.
    var scopedChildRequest = self.request(
      for: definition, messages: [.user(prompt)], sessionID: request.sessionID)
    scopedChildRequest.restrictedToolNames = start.tools
    if start.agent == nil, let inherited = request.restrictedToolNames {
      scopedChildRequest.restrictedToolNames =
        start.tools.map { $0.intersection(inherited) } ?? inherited
    }
    let childRequest = scopedChildRequest
    // Limits belong to an agent, not to its whole delegation tree. A child
    // receives a fresh allowance from its own definition while its parent
    // retains control over how many children it may start and how deep they
    // may be.
    let childBudget = RunBudget(limits: childRequest.limits)
    let childRunID = UUID()
    let childDepth = depth + 1
    // A child past the concurrency limit is not refused: it is registered as
    // queued and starts on its own when a sibling ends, so the model can hand
    // out all the work it has and collect the answers as they come.
    let (childPID, admitted) = await AgentProcessTools.register(
      supervisor: supervisor,
      runID: childRunID,
      parent: parent.pid,
      agentID: definition.id,
      displayName: definition.displayName,
      task: start.headline,
      depth: childDepth,
      limit: request.limits.maxSubagents)
    // Registered, so the reply's next start may register after it.
    launched()
    let childContext = AgentEventContext(
      runID: childRunID,
      parentRunID: parent.runID,
      agentID: definition.id,
      depth: childDepth,
      pid: childPID)
    await emit(
      admitted
        ? .childStarted(parent, child: childContext) : .childQueued(parent, child: childContext))
    // Every child's events reach the host, background or not, tagged with the
    // child's own context and pid. How they are shown — prefixed, folded into
    // one line, or dropped — is the host's call, not the runtime's. The child
    // runs in a task of its own, so `agent_stop` kills a blocking child the
    // same way it kills a background one.
    var liveChildRequest = childRequest
    if start.agent != nil, let currentDefinition = agents[definition.id] {
      liveChildRequest.applyRuntimeSettings(from: currentDefinition)
    }
    liveRequests[childPID] = liveChildRequest
    if let derived { derivedRuns[childPID] = derived }
    runBudgets[childPID] = childBudget
    let task = Task {
      defer { self.clearLiveRequest(for: childPID) }
      return try await AgentProcessTools.run(
        childPID,
        supervisor: supervisor,
        dynamicLimit: {
          guard let parentPID = parent.pid else { return request.limits.maxSubagents }
          return await self.currentRequest(request, for: parentPID).limits.maxSubagents
        },
        admitted: admitted,
        background: !start.wait,
        queueInterruption: {
          await self.queuedInterruption(
            for: childPID, fallback: childRequest, budget: childBudget)
        },
        onAdmitted: { await emit(.childStarted(parent, child: childContext)) }
      ) {
        try await self.runInternal(
          childRequest,
          runID: childRunID,
          pid: childPID,
          parentRunID: parent.runID,
          depth: childDepth,
          budget: childBudget,
          derivedFrom: derived,
          registeredAgent: start.agent != nil,
          emit: emit)
      }
    }
    await supervisor.attach(task, to: childPID)
    let launched = AgentProcessTools.Launch(pid: childPID, task: task, queued: !admitted)

    guard start.wait else {
      let result = AgentProcessTools.startedResult(
        callID: call.id,
        pid: launched.pid,
        agentID: definition.id,
        queued: launched.queued,
        slots: request.limits.maxSubagents)
      await emit(.toolFinished(parent, result))
      return result
    }

    let result: ToolResult
    do {
      let child = try await AgentProcessTools.awaitChild(
        launched.task, pid: launched.pid, supervisor: supervisor)
      await emit(.childFinished(parent, child: child))
      result = AgentProcessTools.childResult(
        callID: call.id, pid: launched.pid, agentID: definition.id, result: child)
    } catch {
      result = AgentProcessTools.childFailure(
        callID: call.id, pid: launched.pid, agentID: definition.id, error: error)
    }
    await emit(.toolFinished(parent, result))
    return result
  }
}
