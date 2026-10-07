import Foundation

extension AgentRuntime {
  private func instructionContextKey(sessionID: String?, pid: AgentPID) -> String {
    sessionID ?? "process:\(pid.rawValue)"
  }

  func projectInstructionSection(
    sessionID: String?, pid: AgentPID, messages: [AgentMessage]
  ) -> String? {
    guard let instructionsDirectory else { return nil }
    let key = instructionContextKey(sessionID: sessionID, pid: pid)
    if instructionContexts[key] == nil {
      instructionContexts[key] = AgentInstructionsContext(directory: instructionsDirectory)
    }
    return instructionContexts[key]?.section(alreadyIn: messages)
  }

  func observeProjectInstructions(
    _ call: ToolCall, request: AgentRequest,
    context: AgentEventContext
  ) -> Bool {
    guard let instructionsDirectory, let pid = context.pid else { return false }
    let key = instructionContextKey(sessionID: request.sessionID, pid: pid)
    var instructions =
      instructionContexts[key]
      ?? AgentInstructionsContext(directory: instructionsDirectory)
    let discovered = instructions.observe(call, workingDirectory: AgentExecutionScope.directory)
    instructionContexts[key] = instructions
    return discovered != nil
  }

  /// The focus of a summary an agent asked for with `context_compact`: the
  /// run is mid-task, as with autocompact, plus whatever the agent said must
  /// survive.
  static func requestedFocus(_ focus: String) -> String {
    let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return AgentCompactionPrompt.automaticFocus }
    return AgentCompactionPrompt.automaticFocus
      + "\nThe assistant asked that the summary keep, above all: " + trimmed
  }

  /// Asks the model for a summary of `selection`, accounts for the call, and
  /// returns the text, for autocompact and for a compaction the agent left to
  /// the runtime. An empty answer is an error: the run goes on uncompacted.
  func summaryText(of selection: [String], focus: String, state: inout RunState) async throws
    -> String
  {
    let selected = Set(selection)
    let transcript = state.transcript
    let latestUserID = transcript.last(where: { $0.role == .user })?.id
    let prompt = AgentCompactionPrompt.render(
      transcript: AgentCompactionPrompt.transcript(
        of: transcript.filter { selected.contains($0.id) || $0.id == latestUserID }),
      focus: focus,
      template: compactionTemplate)
    return try await compactText(prompt: prompt, state: &state)
  }

  /// Shared inference plumbing; durable compaction and smart context have
  /// separate prompts and only durable compaction edits the transcript.
  func compactText(prompt: String, state: inout RunState) async throws -> String {
    var base = state.request
    base.messages = [.user(prompt)]
    var inference = try taskRequest(.compact, from: base)
    guard let provider = providers[inference.provider] else {
      throw AgentRuntimeError.providerNotRegistered(inference.provider)
    }
    inference.model = resolvedModel(inference.model, for: provider)
    var messages = inference.messages
    if let effort = ReasoningEffort.promptSection(for: inference.options) {
      insertSystem(effort, into: &messages)
    }
    let providerRequest = ProviderRequest(
      model: inference.model,
      messages: messages,
      tools: [],
      toolChoice: .none,
      responseFormat: .text,
      options: inference.options,
      stream: false,
      sessionID: state.request.sessionID)
    let call = try await complete(
      providerRequest,
      with: provider, retry: inference.retry, budget: state.budget,
      context: state.context, pid: state.pid, emit: state.emit
    ) { _ in }
    await recordModelCall(call, provider: provider.descriptor.id, request: providerRequest)
    let usage = call.usage(for: messages)
    state.totalUsage = state.totalUsage.merging(usage)
    await supervisor.note(state.pid, usage: state.totalUsage)
    await state.budget.record(tokens: usage.totalTokens)
    let text = MessageContentFilter.textWithoutReasoning(from: call.response.message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CompactionError.emptySummary }
    return text
  }

  func applyPendingInput(to state: inout RunState) async throws {
    // Edits the agent asked for with the context tools land first, so the
    // next turn already runs on the smaller conversation. A compaction the
    // agent left for the runtime to write is summarized here, the way
    // autocompact does it.
    let edits = await supervisor.drainTranscriptEdits(state.pid)
    if !edits.isEmpty {
      var resolved: [AgentTranscriptEdit] = []
      let present = Set(state.transcript.map(\.id))
      for edit in edits {
        guard case .summarize(let ids, let focus) = edit else {
          resolved.append(edit)
          continue
        }
        let selection = ids.filter { present.contains($0) }
        guard !selection.isEmpty else { continue }
        await state.emit(.compactionStarted(state.context, estimatedTokens: state.estimatedTokens))
        await supervisor.note(state.pid, activity: "compacting")
        do {
          let text = try await summaryText(
            of: selection, focus: Self.requestedFocus(focus),
            state: &state)
          resolved.append(.compact(messageIDs: selection, summary: text))
        } catch let error where error is CancellationError || error is RunDeadlineExceeded {
          throw error
        } catch {
          await state.emit(.compactionFailed(state.context, error.localizedDescription))
        }
      }
      let applied = AgentTranscriptEditor.apply(
        resolved, to: state.transcript, activeTaskID: state.activeTaskID)
      if !applied.report.isEmpty {
        state.transcript = applied.messages
        state.lastUsage = nil
        await state.emit(.transcriptEdited(state.context, applied.report))
        await supervisor.note(state.pid, transcript: state.transcript)
      }
    }
    // In size mode the bodies of files read for earlier user prompts make
    // way for a reference before every call; cache mode leaves conversation
    // evidence whole. Instruction separation affects only the provider view.
    if state.request.context == .size,
      let report = AgentContextPruning.prune(&state.transcript, activeTaskID: state.activeTaskID)
    {
      state.lastUsage = nil
      await state.emit(.transcriptEdited(state.context, report))
      await supervisor.note(state.pid, transcript: state.transcript)
    }
    // Anything a person queued for this process since the last turn joins
    // the conversation here, after the tool results the model is about to
    // read, so a running agent can be steered without stopping it.
    let injected = await supervisor.drainInbox(
      state.pid, excluding: state.request.ignoredQueuedMessageIDs)
    if !injected.isEmpty {
      state.pendingDecision = nil
      state.usingPrimary = false
      for message in injected {
        state.transcript.append(message)
        // A child started without waiting reports here too: its answer
        // counts as taken, and hosts hear of it as of a waited child.
        if let child = AgentProcessTools.deliveredChildPID(of: message) {
          await supervisor.collect(child)
          if let result = await supervisor.result(child) {
            await state.emit(.childFinished(state.context, child: result))
          }
        } else {
          await state.emit(.userMessage(state.context, message))
        }
      }
      await supervisor.note(state.pid, transcript: state.transcript)
    }
  }

  /// Returns true when a decision requires another loop boundary.
  func autocompact(_ state: inout RunState) async throws -> Bool {
    // A conversation past the agent's autocompact threshold is folded here,
    // before the limits are checked, so a run that pauses next hands its
    // host the smaller transcript too. Tools mode reduces only the model's
    // view of tool output, leaving the conversation itself intact.
    if state.request.autocompact.isEnabled && !state.skipAutocompaction
      && state.request.context != .tools
    {
      let estimate = state.estimatedTokens
      if estimate >= state.request.autocompact.tokens,
        let selection = AgentAutocompaction.selection(
          in: state.transcript, preservingRecentTokens: state.request.autocompact.recentTokenBudget,
          activeTaskID: state.activeTaskID)
      {
        var prunedTranscript = state.transcript
        let pruning = AgentContextPruning.pruneToolOutput(
          &prunedTranscript, activeTaskID: state.activeTaskID)
        await supervisor.raise(.input("Context reduction needs a decision."), for: state.pid)
        let decision: AutocompactionDecision
        do {
          decision = try await approvalHandler.decideCompaction(
            AutocompactionRequest(
              run: state.context, estimatedTokens: estimate,
              threshold: state.request.autocompact.tokens,
              pruning: pruning))
          try Task.checkCancellation()
        } catch {
          await supervisor.clearAttention(for: state.pid)
          throw error
        }
        await supervisor.clearAttention(for: state.pid)
        switch decision {
        case .cancelRun:
          throw CancellationError()
        case .continueWithoutCompacting:
          state.skipAutocompaction = true
          return true
        case .pruneToolOutput:
          guard let pruning else {
            // A host should not offer this action without a preview. Do
            // not spin at the prompt if a custom handler still chooses it.
            state.skipAutocompaction = true
            return true
          }
          state.transcript = prunedTranscript
          state.lastUsage = nil
          await state.emit(.transcriptEdited(state.context, pruning))
          await supervisor.note(state.pid, transcript: state.transcript)
          // If still above the threshold, offer summarization or keeping
          // the context; the pruning preview will now be empty.
          return true
        case .compact:
          break
        }
        // The person may have changed the model or task assignment while waiting.
        state.request = currentRequest(state.request, for: state.pid)
        if !state.request.autocompact.isEnabled { return true }
        await state.emit(.compactionStarted(state.context, estimatedTokens: estimate))
        await supervisor.note(state.pid, activity: "compacting")
        do {
          let text = try await summaryText(
            of: selection, focus: AgentCompactionPrompt.automaticFocus,
            state: &state)
          let applied = AgentTranscriptEditor.apply(
            [.compact(messageIDs: selection, summary: text)], to: state.transcript,
            activeTaskID: state.activeTaskID)
          state.transcript = applied.messages
          state.lastUsage = nil
          await state.emit(.transcriptEdited(state.context, applied.report))
          await supervisor.note(state.pid, transcript: state.transcript)
        } catch let error where error is CancellationError || error is RunDeadlineExceeded {
          throw error
        } catch {
          // The run goes on with what it has; the next boundary tries again
          // once the conversation has grown.
          await state.emit(.compactionFailed(state.context, error.localizedDescription))
        }
      }
    }
    return false
  }

  private enum CompactionError: LocalizedError {
    case emptySummary

    var errorDescription: String? {
      switch self {
      case .emptySummary: "the model returned an empty summary"
      }
    }
  }

  /// Adds a system message after configured instructions and before the
  /// conversation, so run-scoped context never enters the stored transcript.
  func insertSystem(_ prompt: String, into messages: inout [AgentMessage]) {
    let index =
      messages.firstIndex { $0.role != .system && $0.role != .developer }
      ?? messages.endIndex
    messages.insert(.system(prompt), at: index)
  }
}
