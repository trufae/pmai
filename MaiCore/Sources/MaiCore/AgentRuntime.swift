import Foundation

/// UI-independent orchestration for providers, tools, approvals, MCP tools,
/// and bounded child-agent runs. Hosts own presentation and persistence and
/// observe work through `AgentEvent` values and the shared `AgentSupervisor`.
public actor AgentRuntime {
  // Support extensions share this actor-isolated state. Internal access
  // avoids forwarding accessors; none of it is part of the public API.
  var providers: [ProviderID: any ChatProvider] = [:]
  var tools: [String: any AgentTool] = [:]
  var agents: [String: AgentDefinition] = [:]
  /// The operational part of every request currently running. Transcripts
  /// stay local to their run; hosts may replace these settings between model
  /// and tool calls without cancelling the work already in flight.
  var liveRequests: [AgentPID: AgentRequest] = [:]
  var derivedRuns: [AgentPID: DerivedRun] = [:]
  var runBudgets: [AgentPID: RunBudget] = [:]
  /// Covers the tiny interval after a host starts a task but before the run
  /// has installed its request in this actor.
  var pendingReconfigurations: [AgentPID: AgentRequest] = [:]
  var registeredMCPs: [String: RegisteredMCP] = [:]
  var configuredToolGroups: [ToolGroupDefinition] = []
  let approvalHandler: any ApprovalHandler
  /// Overrides for the delegation brief and the derived worker's instructions.
  /// Nil keeps the built-in text, so MaiCore works without configuration.
  var delegationTemplate: String?
  var workerInstructions: String?
  var plansBeforeDelegating = false
  /// The compaction prompt autocompact renders; nil keeps the built-in one.
  var compactionTemplate: String?
  var smartContextTemplate: String?
  var taskAgents = TaskAgentAssignments()
  /// Durable notes added to the system prompt of top-level runs. A child agent
  /// grepping a file does not need the user's standing preferences, so this
  /// never reaches one.
  var memorySection: String?
  var instructionsSection: String?
  var instructionsDirectory: URL?
  var instructionContexts: [String: AgentInstructionsContext] = [:]
  var toolUsageStore: AgentToolUsageStore?
  var toolUsage = AgentToolUsage()
  /// Where completed provider calls' tokens and timing are folded in.
  /// Nil disables usage recording.
  var usageStats: ModelUsageStore?
  var debugLog: AgentDebugLog?

  /// The process table every run reports into. Hosts read it for `/agents`,
  /// follow its events for notifications, and stop subtrees through it.
  public nonisolated let supervisor: AgentSupervisor

  public init(
    approvalHandler: any ApprovalHandler = DenyInteractiveApprovals(),
    supervisor: AgentSupervisor = AgentSupervisor()
  ) {
    self.approvalHandler = approvalHandler
    self.supervisor = supervisor
  }

  public func run(
    agentID: String,
    messages: [AgentMessage],
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    guard let definition = agents[agentID] else {
      throw AgentRuntimeError.agentNotRegistered(agentID)
    }
    let request = request(for: definition, messages: messages)
    return try await run(request, emit: emit)
  }

  /// Registers an idle top-level process for a conversation before any turn
  /// runs, so a host can queue messages for it and pass its pid to `run`.
  public func allocateProcess(agentID: String, task: String = "") async -> AgentPID {
    await supervisor.register(
      runID: UUID(),
      parent: nil,
      agentID: agentID,
      displayName: agentID,
      task: task,
      depth: 0)
  }

  /// Runs one turn. Pass the pid an earlier turn returned as `process` to keep
  /// a conversation's identity — and the background children it started —
  /// across turns; a stale or omitted pid starts a fresh process.
  @discardableResult
  public func run(
    _ request: AgentRequest,
    process: AgentPID? = nil,
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    let budget = RunBudget(limits: request.limits)
    let runID = UUID()
    let task = AgentProcessInfo.oneLine(
      request.messages.last { $0.role == .user }?.text ?? "", limit: 60)
    var resumed: AgentPID?
    if let existing = process, await supervisor.reopen(existing, runID: runID, task: task) {
      resumed = existing
    }
    let pid: AgentPID
    if let resumed {
      pid = resumed
    } else {
      pid = await supervisor.register(
        runID: runID,
        parent: nil,
        agentID: request.agentID,
        displayName: request.agentID,
        task: task,
        depth: 0)
    }
    do {
      let result = try await runInternal(
        request,
        runID: runID,
        pid: pid,
        parentRunID: nil,
        depth: 0,
        budget: budget,
        emit: emit)
      await supervisor.finish(pid, result: result, announce: false)
      return result
    } catch is CancellationError {
      await supervisor.fail(pid, state: .cancelled, message: "Cancelled", announce: false)
      await debugLog?.record("run.cancelled", value: runID)
      throw CancellationError()
    } catch {
      await supervisor.fail(
        pid, state: .failed, message: error.localizedDescription, announce: false)
      await debugLog?.record("run.error", value: "\(runID): \(error.localizedDescription)")
      throw error
    }
  }

  /// Where a paused run waits. A person pauses through the supervisor while
  /// the run is inside a model call or a tool; it gets here at the next
  /// boundary and stays until it is resumed or stopped.
  private func holdWhilePaused(_ pid: AgentPID) async throws {
    guard await supervisor.isPaused(pid) else { return }
    // "thinking" or a tool name would describe work that is not happening.
    await supervisor.note(pid, activity: "")
    while await supervisor.isPaused(pid) {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  func runInternal(
    _ initialRequest: AgentRequest,
    runID: UUID,
    pid: AgentPID,
    parentRunID: UUID?,
    depth: Int,
    budget: RunBudget,
    derivedFrom: DerivedRun? = nil,
    registeredAgent: Bool = false,
    emit downstream: @escaping AgentEventHandler
  ) async throws -> AgentResult {
    let emit: AgentEventHandler = { event in
      if depth == 0 { await self.recordDebugEvent(event) }
      await downstream(event)
    }
    try Task.checkCancellation()
    if liveRequests[pid] == nil {
      var installed = initialRequest
      if registeredAgent, let definition = agents[initialRequest.agentID] {
        installed.applyRuntimeSettings(from: definition)
      }
      if let pending = pendingReconfigurations.removeValue(forKey: pid) {
        installed.applyRuntimeSettings(from: pending)
      }
      liveRequests[pid] = installed
    }
    if let derivedFrom { derivedRuns[pid] = derivedFrom }
    runBudgets[pid] = budget
    defer {
      clearLiveRequest(for: pid)
    }
    var request = currentRequest(initialRequest, for: pid)
    guard let initialProvider = providers[request.provider] else {
      throw AgentRuntimeError.providerNotRegistered(request.provider)
    }

    let context = AgentEventContext(
      runID: runID,
      parentRunID: parentRunID,
      agentID: request.agentID,
      depth: depth,
      pid: pid)
    var transcript = request.messages
    let activeTaskID = await supervisor.beginActiveTask(in: transcript, for: pid)
    var toolContext = AgentToolResultContext(messages: request.context == .tools ? transcript : [])
    var smartContext = AgentSmartContext()
    var totalUsage: TokenUsage?
    /// What the provider counted on the last call, for the autocompact
    /// estimate. Cleared when a summary changes the transcript's shape.
    var lastUsage: TokenUsage?
    var lastUsageMessageCount = 0
    var skipAutocompaction = false
    var localModelTurns = 0
    var localToolCalls = 0
    // Once the specialist hands off, the primary owns the rest of this reply,
    // including any tool work the specialist left unfinished.
    var pendingDecision: ToolChoice?
    var usingPrimary = false
    var repeatedCalls: [ToolCallKey: Int] = [:]
    /// Set once a call came back a fourth time with the same arguments, or the
    /// model needed three consecutive protocol repairs. The next turn
    /// is offered no tools and asked to answer: a model that keeps repeating a
    /// refused call, or keeps saying nothing, otherwise does so until the turn
    /// limit.
    var repeatGuardTripped = false
    var consecutiveRepairs = 0

    /// A limit met at a turn boundary pauses the run instead of failing it.
    /// The transcript ends in a user message or in tool results, so running
    /// it again picks the task up exactly where it stopped.
    func pause(_ interruption: AgentRunInterruption) async -> AgentResult {
      // Only what this run said counts as its reply; an older assistant
      // message would be printed twice by a host that streams.
      let response =
        transcript.dropFirst(request.messages.count).last { $0.role == .assistant }
        ?? .assistant("")
      let result = AgentResult(
        runID: context.runID,
        agentID: request.agentID,
        provider: request.provider,
        response: response,
        transcript: transcript,
        usage: totalUsage.merging(await budget.approvalUsage(for: pid)),
        stopReason: .unknown,
        modelTurns: localModelTurns + (await budget.approvalTurns(for: pid)),
        toolCalls: localToolCalls,
        interruption: interruption)
      await emit(.finished(context, result))
      return result
    }

    await emit(.started(context, initialProvider.descriptor))
    await supervisor.note(pid, state: .running, transcript: transcript)
    while true {
      try Task.checkCancellation()
      try await holdWhilePaused(pid)
      request = currentRequest(request, for: pid)
      await budget.update(limits: request.limits)
      // Edits the agent asked for with the context tools land first, so the
      // next turn already runs on the smaller conversation. A compaction the
      // agent left for the runtime to write is summarized here, the way
      // autocompact does it.
      let edits = await supervisor.drainTranscriptEdits(pid)
      if !edits.isEmpty {
        var resolved: [AgentTranscriptEdit] = []
        for edit in edits {
          guard case .summarize(let ids, let focus) = edit else {
            resolved.append(edit)
            continue
          }
          let present = Set(transcript.map(\.id))
          let selection = ids.filter { present.contains($0) }
          guard !selection.isEmpty else { continue }
          await emit(
            .compactionStarted(
              context,
              estimatedTokens: AgentAutocompaction.estimatedTokens(
                of: transcript, lastUsage: lastUsage, lastUsageMessageCount: lastUsageMessageCount))
          )
          await supervisor.note(pid, activity: "compacting")
          do {
            let text = try await summaryText(
              of: selection, in: transcript, focus: Self.requestedFocus(focus),
              request: request, budget: budget, context: context, pid: pid,
              totalUsage: &totalUsage, emit: emit)
            resolved.append(.compact(messageIDs: selection, summary: text))
          } catch is RunDeadlineExceeded {
            return await pause(await budget.timeInterruption)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            await emit(.compactionFailed(context, error.localizedDescription))
          }
        }
        let applied = AgentTranscriptEditor.apply(
          resolved, to: transcript, activeTaskID: activeTaskID)
        if !applied.report.isEmpty {
          transcript = applied.messages
          lastUsage = nil
          await emit(.transcriptEdited(context, applied.report))
          await supervisor.note(pid, transcript: transcript)
        }
      }
      // In size mode the bodies of files read for earlier user prompts make
      // way for a reference before every call; cache mode leaves conversation
      // evidence whole. Instruction separation affects only the provider view.
      if request.context == .size,
        let report = AgentContextPruning.prune(&transcript, activeTaskID: activeTaskID)
      {
        lastUsage = nil
        await emit(.transcriptEdited(context, report))
        await supervisor.note(pid, transcript: transcript)
      }
      // Anything a person queued for this process since the last turn joins
      // the conversation here, after the tool results the model is about to
      // read, so a running agent can be steered without stopping it.
      let injected = await supervisor.drainInbox(pid, excluding: request.ignoredQueuedMessageIDs)
      if !injected.isEmpty {
        pendingDecision = nil
        usingPrimary = false
        for message in injected {
          transcript.append(message)
          // A child started without waiting reports here too: its answer
          // counts as taken, and hosts hear of it as of a waited child.
          if let child = AgentProcessTools.deliveredChildPID(of: message) {
            await supervisor.collect(child)
            if let result = await supervisor.result(child) {
              await emit(.childFinished(context, child: result))
            }
          } else {
            await emit(.userMessage(context, message))
          }
        }
        await supervisor.note(pid, transcript: transcript)
      }
      // A conversation past the agent's autocompact threshold is folded here,
      // before the limits are checked, so a run that pauses next hands its
      // host the smaller transcript too. Tools mode reduces only the model's
      // view of tool output, leaving the conversation itself intact.
      if request.autocompact.isEnabled && !skipAutocompaction && request.context != .tools {
        let estimate = AgentAutocompaction.estimatedTokens(
          of: transcript, lastUsage: lastUsage, lastUsageMessageCount: lastUsageMessageCount)
        if estimate >= request.autocompact.tokens,
          let selection = AgentAutocompaction.selection(
            in: transcript, preservingRecentTokens: request.autocompact.recentTokenBudget,
            activeTaskID: activeTaskID)
        {
          var prunedTranscript = transcript
          let pruning = AgentContextPruning.pruneToolOutput(
            &prunedTranscript, activeTaskID: activeTaskID)
          await supervisor.raise(.input("Context reduction needs a decision."), for: pid)
          let decision: AutocompactionDecision
          do {
            decision = try await approvalHandler.decideCompaction(
              AutocompactionRequest(
                run: context, estimatedTokens: estimate, threshold: request.autocompact.tokens,
                pruning: pruning))
            try Task.checkCancellation()
          } catch {
            await supervisor.clearAttention(for: pid)
            throw error
          }
          await supervisor.clearAttention(for: pid)
          switch decision {
          case .cancelRun:
            throw CancellationError()
          case .continueWithoutCompacting:
            skipAutocompaction = true
            continue
          case .pruneToolOutput:
            guard let pruning else {
              // A host should not offer this action without a preview. Do
              // not spin at the prompt if a custom handler still chooses it.
              skipAutocompaction = true
              continue
            }
            transcript = prunedTranscript
            lastUsage = nil
            await emit(.transcriptEdited(context, pruning))
            await supervisor.note(pid, transcript: transcript)
            // If still above the threshold, offer summarization or keeping
            // the context; the pruning preview will now be empty.
            continue
          case .compact:
            break
          }
          // The person may have changed the model or task assignment while waiting.
          request = currentRequest(request, for: pid)
          if !request.autocompact.isEnabled { continue }
          await emit(.compactionStarted(context, estimatedTokens: estimate))
          await supervisor.note(pid, activity: "compacting")
          do {
            let text = try await summaryText(
              of: selection, in: transcript, focus: AgentCompactionPrompt.automaticFocus,
              request: request, budget: budget, context: context, pid: pid,
              totalUsage: &totalUsage, emit: emit)
            let applied = AgentTranscriptEditor.apply(
              [.compact(messageIDs: selection, summary: text)], to: transcript,
              activeTaskID: activeTaskID)
            transcript = applied.messages
            lastUsage = nil
            await emit(.transcriptEdited(context, applied.report))
            await supervisor.note(pid, transcript: transcript)
          } catch is RunDeadlineExceeded {
            return await pause(await budget.timeInterruption)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            // The run goes on with what it has; the next boundary tries again
            // once the conversation has grown.
            await emit(.compactionFailed(context, error.localizedDescription))
          }
        }
      }
      request = currentRequest(request, for: pid)
      await budget.update(limits: request.limits)
      let concreteDefinitions = try visibleDefinitions(for: request, depth: depth)
      var definitions =
        ToolProxy.definitions(
          for: concreteDefinitions,
          exposing: exposedTools(in: concreteDefinitions, request: request))
      if localModelTurns >= request.limits.maxModelTurns {
        return await pause(.modelTurns(limit: request.limits.maxModelTurns))
      }
      if let interruption = await budget.exhausted() {
        return await pause(interruption)
      }

      // Once the run's tool budget is spent the model gets no tools and is
      // told to answer, instead of the run failing with a limit error.
      let toolBudgetExhausted =
        !definitions.isEmpty
        && (localToolCalls >= request.limits.maxToolCalls || repeatGuardTripped)
      // Resolve once at the call boundary, after compaction and queued input.
      // A task assignment changed during an await cannot mix one provider with
      // another agent's model or options.
      let routedDecision = pendingDecision
      pendingDecision = nil
      if let routedDecision {
        switch routedDecision {
        case .tool(let name): definitions = concreteDefinitions.filter { $0.name == name }
        default: definitions = []
        }
      }
      let selectingTools =
        routedDecision == nil && !usingPrimary && taskAgents.tool != nil
        && !concreteDefinitions.isEmpty
        && localToolCalls < request.limits.maxToolCalls && !repeatGuardTripped
      if request.context == .tools {
        let candidates = toolContext.pending(in: transcript)
        if !candidates.isEmpty {
          await supervisor.note(pid, activity: "summarizing tool results")
          do {
            let summaries = try await compactText(
              prompt: AgentToolResultContext.prompt(for: candidates, in: transcript),
              request: request, budget: budget, context: context, pid: pid,
              totalUsage: &totalUsage, emit: emit)
            toolContext.store(summaries, for: candidates)
          } catch is RunDeadlineExceeded {
            return await pause(await budget.timeInterruption)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            toolContext.store(nil, for: candidates)
            await emit(.compactionFailed(context, error.localizedDescription))
          }
        }
      }
      var inference = request
      inference.messages =
        request.context == .tools ? toolContext.messages(from: transcript) : transcript
      if selectingTools { inference = try taskRequest(.tool, from: inference) }
      guard let provider = providers[inference.provider] else {
        throw AgentRuntimeError.providerNotRegistered(inference.provider)
      }
      inference.model = resolvedModel(inference.model, for: provider)
      let deciding = provider.descriptor.capabilities.contains(.toolDecision)
      if deciding {
        guard selectingTools, request.useSystemOne else {
          throw AgentRuntimeError.systemOneConfiguration(
            "System One requires /set tool.systemone true and a /model-tool assignment; keep a chat provider as the primary model."
          )
        }
        definitions = concreteDefinitions
      } else if selectingTools, request.useSystemOne {
        throw AgentRuntimeError.systemOneConfiguration(
          "tool.systemone requires a System One provider in /model-tool.")
      }
      if request.useSystemOne, taskAgents.tool == nil, !concreteDefinitions.isEmpty {
        throw AgentRuntimeError.systemOneConfiguration(
          "Select a System One model with /model-tool PROVIDER::MODEL first.")
      }
      let supportsNativeTools =
        deciding || provider.descriptor.capabilities.contains(.nativeToolCalling)
      // A text-only primary can still finish after a native specialist. Give
      // it the text protocol if further work is needed at the handoff.
      if usingPrimary, inference.toolCallingStrategy == .native, !supportsNativeTools {
        inference.toolCallingStrategy = .automatic
      }
      if !toolBudgetExhausted, inference.toolCallingStrategy == .native, !definitions.isEmpty,
        !supportsNativeTools
      {
        throw AgentRuntimeError.nativeToolCallingUnavailable(inference.provider)
      }
      let textToolMode: ToolCallingMode?
      switch deciding ? .native : inference.toolCallingStrategy {
      case .automatic:
        textToolMode = definitions.isEmpty || supportsNativeTools ? nil : .json
      case .native:
        textToolMode = nil
      case .text:
        textToolMode = definitions.isEmpty ? nil : .text
      case .xml:
        textToolMode = definitions.isEmpty ? nil : .xml
      case .json:
        textToolMode = definitions.isEmpty ? nil : .json
      }
      let usesTextToolProtocol = textToolMode != nil && !toolBudgetExhausted
      let promptContext = AgentPromptContext(
        messages: inference.messages, activeTaskID: activeTaskID)
      var providerMessages: [AgentMessage]
      if request.context == .smart {
        if let evidence = smartContext.pending(in: promptContext, activeTaskID: activeTaskID) {
          await supervisor.note(pid, activity: "preparing context")
          do {
            let brief = try await compactText(
              prompt: AgentSmartContext.prompt(
                for: evidence, in: promptContext, template: smartContextTemplate),
              request: request, budget: budget, context: context, pid: pid,
              totalUsage: &totalUsage, emit: emit)
            smartContext.store(brief, for: evidence)
          } catch is RunDeadlineExceeded {
            return await pause(await budget.timeInterruption)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            await emit(.compactionFailed(context, error.localizedDescription))
          }
        }
        providerMessages = smartContext.messages(from: promptContext)
      } else {
        providerMessages = promptContext.messages()
      }
      if concreteDefinitions.contains(where: { MaiSkillTools.isSkillTool($0.name) }) {
        insertSystem(MaiSkillTools.promptSection, into: &providerMessages)
      }
      if let instructionsSection {
        if !providerMessages.contains(where: {
          $0.role == .system && $0.text == instructionsSection
        }) {
          insertSystem(instructionsSection, into: &providerMessages)
        }
      }
      if let projectSection = projectInstructionSection(
        sessionID: request.sessionID, pid: pid, messages: providerMessages)
      {
        insertSystem(projectSection, into: &providerMessages)
      }
      if let memorySection, depth == 0 {
        insertSystem(memorySection, into: &providerMessages)
      }
      if depth == 0 {
        let soulPath = AgentHome.expandUserPath("~/.pmai/SOUL.md")
        if let soul = try? String(contentsOfFile: soulPath, encoding: .utf8).trimmingCharacters(
          in: .whitespacesAndNewlines), !soul.isEmpty
        {
          insertSystem(soul, into: &providerMessages)
        }
      }
      // The effort level and its guidance reach the model in words as well as
      // in the provider's own field, for the models that have none.
      if let effortSection = ReasoningEffort.promptSection(for: inference.options) {
        insertSystem(effortSection, into: &providerMessages)
      }
      if case .tool(let name) = routedDecision {
        insertSystem(
          "The decision model selected \(name). Fill its arguments from the conversation and call it if appropriate. Do not invent missing values.",
          into: &providerMessages)
      }
      if usingPrimary, !toolBudgetExhausted {
        insertSystem(
          "Use the tool results to answer the user's request. If the task is unfinished, use the available tools to complete it before answering.",
          into: &providerMessages)
      }
      if textToolMode != nil || toolBudgetExhausted {
        let prompt =
          toolBudgetExhausted
          ? (repeatGuardTripped ? Self.repeatedCallPrompt : Self.toolBudgetExhaustedPrompt)
          : textToolPrompt(definitions, mode: textToolMode ?? .text)
        insertSystem(prompt, into: &providerMessages)
      }
      // Context preparation spends tokens too. Check the budget again before
      // starting the conversation call, and count only conversation turns.
      if let interruption = await budget.claimModelTurn() {
        return await pause(interruption)
      }
      localModelTurns += 1
      await emit(.modelStarted(context, turn: localModelTurns))
      await supervisor.note(
        pid, modelTurns: localModelTurns, activity: "thinking",
        contextSize: AgentContextSize(messages: providerMessages))
      let offersTools = !usesTextToolProtocol && !toolBudgetExhausted
      let providerRequest = ProviderRequest(
        model: inference.model,
        messages: providerMessages,
        tools: offersTools ? definitions : [],
        toolChoice: definitions.isEmpty || !offersTools ? .none : request.toolChoice,
        responseFormat: inference.responseFormat,
        options: inference.options,
        stream: usesTextToolProtocol ? false : inference.stream,
        sessionID: request.sessionID)
      let call: ProviderCall
      let repairsEmptyReply = localToolCalls > 0 && localModelTurns < request.limits.maxModelTurns
      do {
        call = try await complete(
          providerRequest, with: provider, retry: inference.retry, budget: budget,
          context: context, pid: pid, retriesEmptyReply: !repairsEmptyReply, emit: emit
        ) { event in
          if selectingTools {
            switch event {
            case .textDelta, .reasoningDelta: return
            default: break
            }
          }
          if usesTextToolProtocol, case .textDelta = event { return }
          await emit(.provider(context, event))
        }
      } catch is RunDeadlineExceeded {
        // Time ran out inside the call. The reply is lost, but the transcript
        // is whole, so the pause is as clean as one at the top of the loop.
        return await pause(await budget.timeInterruption)
      } catch let error as any ProviderToolCallError
        where error.toolCallRepairMessage != nil && !definitions.isEmpty && !toolBudgetExhausted
      {
        consecutiveRepairs += 1
        if consecutiveRepairs >= Self.maximumRepairAttempts { repeatGuardTripped = true }
        transcript.append(.assistant(error.toolCallRepairMessage!))
        await supervisor.note(pid, transcript: transcript)
        continue
      } catch is ProviderEmptyResponseError where repairsEmptyReply {
        // A model that answers a tool result with nothing at all is told what
        // is expected of it, as after a malformed call; retrying the same
        // request twice and then failing the whole run threw the work away.
        consecutiveRepairs += 1
        if consecutiveRepairs >= Self.maximumRepairAttempts { repeatGuardTripped = true }
        var feedback = AgentToolLoopPolicy.repairFeedbackAfterToolResult(
          mode: textToolMode ?? .native)
        if request.usesToolProxy { feedback += "\n" + ToolProxy.repairHint }
        transcript.append(.assistant(feedback))
        await supervisor.note(pid, transcript: transcript)
        continue
      }
      var providerResponse = call.response
      try Task.checkCancellation()
      if request.context == .tools { toolContext.didRead(transcript) }
      await recordModelCall(
        call, provider: provider.descriptor.id, request: providerRequest,
        userMessages: localModelTurns == 1 ? request.messages : nil)
      let usage = call.usage(for: providerMessages)
      totalUsage = totalUsage.merging(usage)
      // Reduced context usage does not describe the full saved transcript.
      lastUsage =
        request.context == .smart || request.context == .tools || deciding
        ? nil : providerResponse.usage
      lastUsageMessageCount = transcript.count + 1
      await supervisor.note(pid, usage: totalUsage)
      await budget.record(tokens: usage.totalTokens)

      if deciding {
        guard let decision = providerResponse.toolDecision else {
          throw AgentRuntimeError.systemOneConfiguration("System One returned no tool decision.")
        }
        switch decision {
        case .none: break
        case .tool(let name) where concreteDefinitions.contains(where: { $0.name == name }): break
        default:
          throw AgentRuntimeError.systemOneConfiguration("System One returned an unavailable tool.")
        }
        pendingDecision = decision
        continue
      }

      // A server such as Ollama parses the model's own function-call syntax
      // into native tool calls even when the request offered no tools. Those
      // calls are as good as a text block and run below; reading only the text
      // would mistake the turn for one without a call and repeat the repair
      // feedback until the turn limit.
      // The text protocols offer a `respond` pseudo-tool; a server may hand it
      // back as a native call. It is the final answer, not a host tool.
      if textToolMode != nil, providerResponse.message.toolCalls.count == 1,
        let respond = providerResponse.message.toolCalls.first,
        respond.name == AgentToolLoopPolicy.responseToolName
      {
        let content = respond.arguments.objectValue?["content"]?.coercedStringValue ?? ""
        providerResponse.message = .assistant(content)
        providerResponse.stopReason = .stop
        if !content.isEmpty && !selectingTools {
          await emit(.provider(context, .textDelta(content)))
        }
      }
      if let textToolMode, !toolBudgetExhausted, providerResponse.message.toolCalls.isEmpty {
        let decision = AgentToolLoopPolicy.evaluate(
          response: providerResponse.message.text,
          tools: definitions,
          mode: textToolMode,
          hasToolResults: localToolCalls > 0,
          remainingToolCalls: request.limits.maxToolCalls - localToolCalls)
        switch decision {
        case .final(let text):
          if text != providerResponse.message.text {
            providerResponse.message = replacingText(in: providerResponse.message, with: text)
          }
          if !text.isEmpty && !selectingTools { await emit(.provider(context, .textDelta(text))) }
        case .repair(let feedback):
          consecutiveRepairs += 1
          if consecutiveRepairs >= Self.maximumRepairAttempts { repeatGuardTripped = true }
          providerResponse.message = .assistant(feedback)
          transcript.append(providerResponse.message)
          await supervisor.note(pid, transcript: transcript)
          continue
        case .execute(let parsedCalls):
          let calls = parsedCalls.map(toolCall)
          var content = providerResponse.message.content.filter {
            if case .reasoning = $0 { return true }
            return false
          }
          content.append(contentsOf: calls.map(ContentPart.toolCall))
          providerResponse.message.content = content
          providerResponse.stopReason = .toolCall
          for (index, call) in calls.enumerated() {
            await emit(
              .provider(
                context,
                .toolCallDelta(
                  ToolCallDelta(
                    index: index,
                    id: call.id,
                    name: call.name,
                    argumentsFragment: call.arguments.compactJSONString))))
          }
        }
      }
      consecutiveRepairs = 0
      if selectingTools && providerResponse.message.toolCalls.isEmpty {
        // The specialist's stop decision hands the tool results to the primary
        // model. Its draft is not promoted to a user-visible final answer.
        usingPrimary = true
        continue
      }
      transcript.append(providerResponse.message)
      await supervisor.note(
        pid, transcript: transcript,
        contextSize: AgentContextSize(
          messages: request.context == .tools ? toolContext.messages(from: transcript) : transcript)
      )

      let calls = providerResponse.message.toolCalls.filter { !$0.name.isEmpty }
      if calls.isEmpty {
        // A message that arrived while the model was answering is not left
        // behind for a run that is about to end, and neither are children
        // started without waiting: the run holds until every one of them has
        // delivered, then goes round once more so the answer takes them all
        // into account. A run out of turns ends anyway and leaves the
        // messages queued for its host.
        if localModelTurns < request.limits.maxModelTurns,
          await budget.exhausted() == nil,
          try await AgentProcessTools.awaitChildren(
            of: pid, supervisor: supervisor, excluding: request.ignoredQueuedMessageIDs)
        {
          continue
        }
        let result = AgentResult(
          runID: context.runID,
          agentID: request.agentID,
          provider: request.provider,
          response: providerResponse.message,
          transcript: transcript,
          usage: totalUsage.merging(await budget.approvalUsage(for: pid)),
          stopReason: providerResponse.stopReason,
          modelTurns: localModelTurns + (await budget.approvalTurns(for: pid)),
          toolCalls: localToolCalls)
        await emit(.finished(context, result))
        return result
      }

      // The reply's calls run in order, except that a call to a concurrent
      // tool — the agent family, or any tool that says so — is started and
      // left running while the calls after it start, so children started in
      // one reply work side by side and a blocking start never holds back
      // the rest. The results join the transcript in call order once the
      // last of them is in.
      let modelTurn = localModelTurns
      let usedTokens = AgentAutocompaction.estimatedTokens(
        of: request.context == .tools ? toolContext.messages(from: transcript) : transcript,
        lastUsage: lastUsage, lastUsageMessageCount: lastUsageMessageCount)
      var results = [ToolResult?](repeating: nil, count: calls.count)
      var definitionsByCall = [[ToolDefinition]](repeating: [], count: calls.count)
      try await withThrowingTaskGroup(of: (Int, ToolResult).self) { group in
        for (index, call) in calls.enumerated() {
          try Task.checkCancellation()
          try await holdWhilePaused(pid)
          // A prior sequential tool may have taken minutes. Refresh again for
          // every call so commands typed while it ran affect the next one.
          request = currentRequest(request, for: pid)
          await budget.update(limits: request.limits)
          let callRequest = request
          let suggestedOutputBytes = ToolExecutionContext.suggestedOutputBytes(
            contextTokens: callRequest.autocompact.tokens, usedTokens: usedTokens,
            toolCalls: calls.count)
          let callDefinitions = try visibleDefinitions(for: callRequest, depth: depth)
          definitionsByCall[index] = callDefinitions
          if await budget.deadlinePassed {
            // Out of time between two calls: the rest are answered rather
            // than run, so the transcript stays sendable and the pause at
            // the top of the loop is clean.
            await emit(.toolStarted(context, call))
            let result = ToolResult(
              callID: call.id,
              text:
                "Error: the run's time limit was reached before this call ran; it was not executed.",
              isError: true)
            await emit(.toolFinished(context, result))
            results[index] = result
            continue
          }
          guard localToolCalls < callRequest.limits.maxToolCalls, await budget.claimToolCall()
          else {
            let result = ToolResult(
              callID: call.id,
              text:
                "Error: the tool call budget for this run (\(callRequest.limits.maxToolCalls)) is exhausted; this call was not executed. Answer with the information already gathered.",
              isError: true)
            await emit(.toolFinished(context, result))
            results[index] = result
            continue
          }
          localToolCalls += 1
          await supervisor.note(pid, toolCalls: localToolCalls, activity: call.name)
          // Repeating a call is often right — the directory changed, a file
          // was written, a child is being polled — so only a call that keeps
          // coming back with the same arguments is stopped, and never one of
          // the agent tools, which exist to be polled.
          let key = ToolCallKey(call)
          let repeats = repeatedCalls[key, default: 0]
          let pollable = AgentProcessTools.reservedToolNames.contains(
            AgentProcessTools.canonicalName(call.name))
          guard pollable || repeats < Self.maximumIdenticalCalls else {
            repeatGuardTripped = true
            await emit(.toolStarted(context, call))
            let result = ToolResult(
              callID: call.id,
              text:
                "Error: this exact call has already run \(repeats) times with the same arguments; change them, or answer with what you have.",
              isError: true)
            await emit(.toolFinished(context, result))
            results[index] = result
            continue
          }
          repeatedCalls[key] = repeats + 1
          if Self.runsConcurrently(call, in: callDefinitions) {
            let gate = LaunchGate()
            group.addTask {
              defer { gate.open() }
              return (
                index,
                try await self.execute(
                  call,
                  definitions: callDefinitions,
                  request: callRequest,
                  context: context,
                  modelTurn: modelTurn,
                  suggestedOutputBytes: suggestedOutputBytes,
                  depth: depth,
                  budget: budget,
                  launched: { gate.open() },
                  emit: emit)
              )
            }
            // The next call starts once this one is under way, so children
            // started together get their pids, and their slots, in call order.
            await gate.wait()
          } else {
            results[index] = try await execute(
              call,
              definitions: callDefinitions,
              request: callRequest,
              context: context,
              modelTurn: modelTurn,
              suggestedOutputBytes: suggestedOutputBytes,
              depth: depth,
              budget: budget,
              emit: emit)
          }
        }
        for try await (index, result) in group {
          results[index] = result
        }
      }
      for (index, call) in calls.enumerated() {
        guard let result = results[index] else { continue }
        transcript.append(AgentMessage(role: .tool, content: [.toolResult(result)]))
        // A call that changed something makes repeating an earlier call
        // reasonable again — the tests run after each fix are the common
        // case — so every other call's identical-call count starts over.
        if !result.isError, Self.changesState(call, in: definitionsByCall[index]) {
          let own = ToolCallKey(call)
          repeatedCalls = repeatedCalls.filter { $0.key == own }
        }
      }
      await supervisor.note(
        pid, transcript: transcript,
        contextSize: AgentContextSize(
          messages: request.context == .tools ? toolContext.messages(from: transcript) : transcript)
      )
    }
  }

  /// Whether `call` names a tool whose calls run alongside the rest of the
  /// reply instead of after the call before them.
  private static func runsConcurrently(
    _ call: ToolCall,
    in definitions: [ToolDefinition]
  ) -> Bool {
    let name = AgentProcessTools.canonicalName(call.name)
    return definitions.contains { $0.name == name && $0.annotations.concurrent }
  }

  /// Whether `call` names a tool that may change what a later call sees: not
  /// read-only, and not one of the agent tools.
  private static func changesState(_ call: ToolCall, in definitions: [ToolDefinition]) -> Bool {
    let name = AgentProcessTools.canonicalName(call.name)
    guard !AgentProcessTools.reservedToolNames.contains(name) else { return false }
    return definitions.contains { $0.name == name && !$0.annotations.readOnly }
  }

  /// A one-shot signal a concurrent call gives once it is under way — a
  /// child registered, a tool called — so the reply's next call can start.
  /// `wait` returns at once when the signal was already given, and the call's
  /// end gives it too, so an early error never holds the reply up.
  private final class LaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
      lock.lock()
      opened = true
      let resumed = waiters
      waiters = []
      lock.unlock()
      for waiter in resumed { waiter.resume() }
    }

    func wait() async {
      await withCheckedContinuation { continuation in
        lock.lock()
        if opened {
          lock.unlock()
          continuation.resume()
        } else {
          waiters.append(continuation)
          lock.unlock()
        }
      }
    }
  }

  static let toolBudgetExhaustedPrompt =
    "The tool call budget for this run is exhausted and no tools are available anymore. Do not call tools; give the final answer using the information already gathered."
  static let repeatedCallPrompt =
    "The last turns made no progress: tool calls repeated or could not be parsed, or no reply was produced. No tools are available anymore. Do not call tools; give the final answer using the information already gathered, and say what could not be done."
  /// Consecutive empty or malformed replies before tools are withdrawn.
  static let maximumRepairAttempts = 3

  /// How often one call may run with exactly the same arguments in one run
  /// before it is refused as a loop.
  static let maximumIdenticalCalls = 3

  /// The user messages a turn was started with: everything after the last
  /// assistant reply.
  static func trailingUserMessages(in messages: [AgentMessage]) -> [AgentMessage] {
    var trailing: [AgentMessage] = []
    for message in messages.reversed() {
      if message.role == .assistant { break }
      if message.role == .user { trailing.append(message) }
    }
    return trailing
  }

  private func textToolPrompt(
    _ definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> String {
    "Tools are available through a \(mode.displayName.uppercased()) fallback protocol.\n\n"
      + AgentTooling.promptDescription(
        for: AgentToolLoopPolicy.definitions(includingResponseTool: definitions), mode: mode)
  }

  private func toolCall(_ call: ParsedToolCall) -> ToolCall {
    return ToolCall(
      id: call.toolCallID ?? "text_\(UUID().uuidString)",
      name: call.name,
      arguments: .object(call.argumentValues))
  }

  private func replacingText(in message: AgentMessage, with text: String) -> AgentMessage {
    var message = message
    message.content.removeAll {
      if case .text = $0 { return true }
      if case .toolCall = $0 { return true }
      return false
    }
    if !text.isEmpty { message.content.append(.text(text)) }
    return message
  }
}
