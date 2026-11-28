import Foundation

extension AgentRuntime {
  func summarizeToolResults(_ candidates: [AgentToolResultContext.Candidate], state: inout RunState) async throws {
    let task = AgentCompactionPrompt.transcript(of: state.workingMessages.filter { $0.role == .user })
    let sources = candidates.map(AgentToolResultContext.transcript)
    let numbered = sources.enumerated().map { "Result \($0.offset):\n\($0.element)" }.joined(separator: "\n\n")
    do {
      let response = try await compactText(source: numbered,
        render: { AgentToolResultContext.prompt(outputs: $0, task: task, batch: true) },
        state: &state, purpose: "tool-results")
      state.toolContext.store(response, for: candidates)
    } catch is SplitToolResults {
      // A byte split can detach a result from its number. Reduce each result
      // independently so even its continuation chunks have exactly one owner.
      for (candidate, source) in zip(candidates, sources) {
        do {
          let summary = try await compactText(source: source,
            render: { AgentToolResultContext.prompt(outputs: $0, task: task, batch: false) },
            state: &state, purpose: "tool-result")
          state.toolContext.store(summary, for: candidate)
        } catch let error where error is CancellationError || error is RunDeadlineExceeded || error is HurryRequested {
          throw error
        } catch {
          state.toolContext.store(nil, for: candidate)
          await state.emit(.compactionFailed(state.context, error.localizedDescription))
        }
      }
    } catch let error where error is CancellationError || error is RunDeadlineExceeded || error is HurryRequested {
      throw error
    } catch {
      state.toolContext.store(nil, for: candidates)
      await state.emit(.compactionFailed(state.context, error.localizedDescription))
    }
  }

  private struct SplitToolResults: Error {}

  /// Summarizes arbitrarily long text without placing the whole transcript in
  /// a model turn. Hosts replace their history only after this succeeds.
  public func summarize(
    _ source: String, request: AgentRequest,
    renderPrompt: @escaping @Sendable (String) -> String,
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> String {
    let runID = UUID()
    let pid = await supervisor.register(
      runID: runID, parent: nil, agentID: request.agentID,
      displayName: request.agentID, task: "summarizing", depth: 0)
    let context = AgentEventContext(
      runID: runID, parentRunID: nil, agentID: request.agentID, depth: 0, pid: pid)
    let budget = RunBudget(limits: request.limits)
    liveRequests[pid] = request
    runBudgets[pid] = budget
    defer { clearLiveRequest(for: pid) }
    var state = RunState(
      request, context: context, pid: pid, budget: budget, activeTaskID: nil, emit: emit)
    let redactor = contentRedactor(sessionID: request.sessionID ?? "process:\(pid.rawValue)")
    await supervisor.note(pid, state: .running, activity: "summarizing")
    do {
      let text = try await ContentRedactor.$current.withValue(redactor) {
        try await self.compactText(source: source, render: renderPrompt, state: &state)
      }
      let response = ProviderResponse(message: .assistant(text), stopReason: .stop)
      state.transcript.append(response.message)
      let result = await finishRun(state, response: response)
      await supervisor.finish(pid, result: result, announce: false)
      return text
    } catch {
      await supervisor.fail(
        pid, state: error is CancellationError ? .cancelled : .failed,
        message: error.localizedDescription, announce: false)
      throw error
    }
  }

  /// Split first, summarize every piece, then consolidate the summaries. Each
  /// piece gets the same template/focus and task-agent instructions. Nothing is
  /// removed from the durable transcript until every call has succeeded.
  func compactText(
    source: String, render: @escaping @Sendable (String) -> String,
    state: inout RunState, outputLimit: Int? = nil, purpose: String = "manual-summary",
    operationID: UUID? = nil, stopAfterRepeatedCutoffs: Bool = false
  ) async throws -> String {
    var consecutiveCutoffs: Int? = stopAfterRepeatedCutoffs ? 0 : nil
    if AgentDiagnosticScope.current == nil {
      return try await AgentDiagnosticScope.$current.withValue(
        .init(operationID: operationID ?? UUID(), purpose: purpose)
      ) {
        noteDiagnostic("compaction.started", context: state.context,
          sessionID: state.request.sessionID, value: .object([
            "sourceBytes": .integer(source.utf8.count),
            "activeTaskID": state.activeTaskID.map(JSONValue.string) ?? .null,
          ]))
        do {
          let text = try await compactText(source: source, render: render, state: &state,
            outputLimit: outputLimit, purpose: purpose, consecutiveCutoffs: &consecutiveCutoffs)
          noteDiagnostic("compaction.completed", context: state.context,
            sessionID: state.request.sessionID, value: .object([
              "summaryCharacters": .integer(text.count),
            ]))
          return text
        } catch is SplitToolResults {
          noteDiagnostic("compaction.split", context: state.context, sessionID: state.request.sessionID,
            value: .object(["reason": .string("tool-result-boundaries")]))
          throw SplitToolResults()
        } catch {
          noteDiagnostic(error is CancellationError ? "compaction.cancelled" : "compaction.failed",
            context: state.context, sessionID: state.request.sessionID,
            value: .object(["error": .string(error.localizedDescription)]))
          throw error
        }
      }
    }
    return try await compactText(source: source, render: render, state: &state,
      outputLimit: outputLimit, purpose: purpose, consecutiveCutoffs: &consecutiveCutoffs)
  }

  private func compactText(
    source: String, render: @escaping @Sendable (String) -> String,
    state: inout RunState, inputLimit: Int? = nil, depth: Int = 0, outputLimit: Int?,
    purpose: String, consecutiveCutoffs: inout Int?
  ) async throws -> String {
    try Task.checkCancellation()
    guard depth < 12 else { throw SummaryError.cannotReduce }
    if let interruption = await state.budget.exhausted() {
      switch interruption {
      case .modelTurns: break  // Durable compaction also runs at a conversation-turn checkpoint.
      default: throw SummaryError.budget(interruption.summary)
      }
    }
    var base = state.request
    base.messages = [.user(render(source))]
    var inference = try taskRequest(.compact, from: base)
    guard let provider = providers[inference.provider] else {
      throw AgentRuntimeError.providerNotRegistered(inference.provider)
    }
    inference.model = resolvedModel(inference.model, for: provider)
    if depth == 0 {
      await refreshDeploymentWindow(for: provider, model: inference.model, options: inference.options)
    }
    let window =
      contextWindow(
        provider: inference.provider, model: inference.model, options: inference.options) ?? 32_768
    // Start small, but leave room to recover when reasoning or a dense
    // transcript needs more output. Explicit configured limits remain caps.
    let maximumOutput = min(
      max(1, inference.options.maxOutputTokens ?? 16_384), max(1, window / 4))
    inference.options.maxOutputTokens = min(
      max(1, outputLimit ?? inference.options.maxOutputTokens ?? 2_048), maximumOutput)
    let allowance = inference.options.maxOutputTokens ?? 2_048
    let budget = min(
      inputLimit ?? Int.max, Self.inputTokenBudget(window: window, options: inference.options))
    var messages = inference.messages
    if let effort = ReasoningEffort.promptSection(for: inference.options) {
      insertSystem(effort, into: &messages)
    }
    let proseSummary = purpose != "tool-results"
    if proseSummary {
      insertSystem("Aim for a concise summary within \(min(1_024, max(1, allowance / 2))) tokens. Follow the requested focus and format. Preserve exact details relevant to that purpose.", into: &messages)
    }
    let providerRequest = ProviderRequest(
      model: inference.model, messages: messages, tools: [], toolChoice: .none,
      responseFormat: .text, options: inference.options, stream: false,
      sessionID: state.request.sessionID)
    noteDiagnostic("compaction.prepared", context: state.context, sessionID: state.request.sessionID,
      value: .object([
        "depth": .integer(depth), "sourceBytes": .integer(source.utf8.count),
        "inputBudget": .integer(budget), "window": .integer(window),
        "outputLimit": .integer(inference.options.maxOutputTokens ?? 0),
        "estimatedInputTokens": .integer(Self.contextTokens(providerRequest)),
      ]))
    var splitAfterCutoff = false
    if Self.contextTokens(providerRequest) <= budget {
      do {
        let call = try await complete(
          providerRequest, with: provider, retry: inference.retry, budget: state.budget,
          context: state.context, pid: state.pid, emit: state.emit
        ) { _ in }
        await recordModelCall(call, provider: inference.provider, request: providerRequest)
        let usage = call.usage(for: providerRequest)
        state.totalUsage = state.totalUsage.merging(usage)
        await supervisor.note(state.pid, usage: state.totalUsage.merging(await state.budget.approvalUsage))
        await state.budget.record(tokens: usage.totalTokens)
        if let previous = consecutiveCutoffs {
          let count = call.response.stopReason == .length ? previous + 1 : 0
          consecutiveCutoffs = count
          if count >= 2 { throw SummaryError.truncated }
        }
        let text = MessageContentFilter.textWithoutReasoning(from: call.response.message.text)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if call.response.stopReason != .length {
          try call.response.checkSummaryCompletion()
          if !text.isEmpty { return text }
        }
        // A long visible partial is evidence that the source will not fit in
        // one summary. Shorten the input instead of repeatedly paying for it.
        splitAfterCutoff = source.utf8.count >= 2_048
          && (allowance == maximumOutput || (text.utf8.count >= 512 && source.utf8.count / 16 >= allowance))
        if !splitAfterCutoff, allowance < maximumOutput {
          noteDiagnostic("compaction.outputRetry", context: state.context, sessionID: state.request.sessionID,
            value: .object(["reason": .string(text.isEmpty ? "empty-summary" : "output-limit"),
              "nextOutputLimit": .integer(min(maximumOutput, allowance * 2))]))
          // This is a changed request, not a blind transport retry. Recompute
          // the input budget too: more reply space may require smaller chunks.
          return try await compactText(
            source: source, render: render, state: &state, inputLimit: inputLimit,
            depth: depth + 1, outputLimit: min(maximumOutput, allowance * 2), purpose: purpose,
            consecutiveCutoffs: &consecutiveCutoffs)
        }
        if !splitAfterCutoff {
          throw call.response.stopReason == .length ? SummaryError.truncated : SummaryError.empty
        }
      } catch is ProviderContextLimitError {
        if consecutiveCutoffs != nil { consecutiveCutoffs = 0 }
        noteDiagnostic("compaction.overflowRetry", context: state.context, sessionID: state.request.sessionID,
          value: .object(["depth": .integer(depth)]))
        // A conservative character estimate still cannot know every tokenizer.
        // Tighten the next request instead of resending the rejected payload.
        return try await compactText(
          source: source, render: render, state: &state,
          inputLimit: min(budget - 1, max(1, Self.contextTokens(providerRequest) / 2)),
          depth: depth + 1, outputLimit: outputLimit, purpose: purpose,
          consecutiveCutoffs: &consecutiveCutoffs)
      }
    }
    if !proseSummary { throw SplitToolResults() }
    // Measure scaffolding separately so long custom prompts or task-agent
    // instructions cannot defeat the chunk limit.
    var empty = providerRequest
    empty.messages = messages.map { message in
      var copy = message
      if copy.id == base.messages[0].id { copy.content = [.text(render(""))] }
      return copy
    }
    let overhead = Self.contextTokens(empty)
    let available = max(0, budget - overhead)
    let evidenceTokens = max(1, Self.contextTokens(providerRequest) - overhead)
    // Measure expansion from JSON escaping and repeated template placeholders,
    // rather than assuming a fixed number of source characters per token.
    let share = min(0.8, Double(available) / Double(evidenceTokens) * 0.8)
    let inputChunkBytes = Int(Double(source.utf8.count) * share)
    let chunkBytes = splitAfterCutoff ? min(inputChunkBytes, source.utf8.count / 2) : inputChunkBytes
    guard chunkBytes >= 256 else { throw SummaryError.instructionsTooLarge }
    let chunks = Self.summaryChunks(source, maxBytes: chunkBytes)
    guard chunks.count > 1 else { throw SummaryError.cannotReduce }
    noteDiagnostic("compaction.split", context: state.context, sessionID: state.request.sessionID,
      value: .object(["depth": .integer(depth), "chunks": .integer(chunks.count),
        "chunkBytes": .integer(chunkBytes),
        "reason": .string(splitAfterCutoff ? "summary-output-limit" : "input-budget")]))
    var partials: [String] = []
    for chunk in chunks {
      partials.append(
        try await compactText(
          source: chunk, render: render, state: &state, inputLimit: budget, depth: depth + 1,
          outputLimit: outputLimit, purpose: purpose, consecutiveCutoffs: &consecutiveCutoffs))
    }
    let combined = partials.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }
      .joined(separator: "\n\n")
    guard combined.utf8.count < source.utf8.count else { throw SummaryError.cannotReduce }
    return try await compactText(
      source: combined, render: render, state: &state, inputLimit: budget, depth: depth + 1,
      outputLimit: outputLimit, purpose: purpose, consecutiveCutoffs: &consecutiveCutoffs)
  }

  /// Scalar boundaries preserve all text, including Unicode and a single
  /// message larger than the model window. No byte sequence is cut in half.
  static func summaryChunks(_ source: String, maxBytes: Int) -> [String] {
    var chunks: [String] = []
    var chunk = ""
    var bytes = 0
    for scalar in source.unicodeScalars {
      let size = scalar.utf8.count
      if bytes + size > maxBytes, !chunk.isEmpty {
        // Prefer a word boundary so paths, identifiers and sentences do not
        // get needlessly separated between independent summary requests.
        if let boundary = chunk.lastIndex(where: { $0.isWhitespace }),
          chunk[..<boundary].utf8.count >= maxBytes / 2
        {
          let end = chunk.index(after: boundary)
          chunks.append(String(chunk[..<end]))
          chunk = String(chunk[end...])
          bytes = chunk.utf8.count
        } else {
          chunks.append(chunk)
          chunk = ""
          bytes = 0
        }
      }
      chunk.unicodeScalars.append(scalar)
      bytes += size
    }
    if !chunk.isEmpty { chunks.append(chunk) }
    return chunks
  }
}

extension ProviderResponse {
  /// A partial reply may be displayed in chat, but must never replace saved history or notes.
  public func checkSummaryCompletion() throws {
    switch stopReason {
    case .cancelled: throw CancellationError()
    case .length: throw SummaryError.truncated
    case .contentFilter, .toolCall: throw SummaryError.incomplete(stopReason)
    case .stop, .unknown:
      if !message.toolCalls.isEmpty { throw SummaryError.incomplete(.toolCall) }
    }
  }
}

private enum SummaryError: LocalizedError {
  case empty, truncated, cannotReduce, instructionsTooLarge
  case incomplete(ProviderStopReason)
  case budget(String)

  var errorDescription: String? {
    switch self {
    case .empty:
      "The model returned no summary text (possibly only reasoning); history was kept. Lower the compact model's reasoning effort, increase its output limit, or try another model."
    case .truncated:
      "The model's summary reached its output limit (which may include reasoning tokens); history was kept. Increase the compact model's output limit or lower its reasoning effort."
    case .incomplete(let reason):
      "The provider stopped summarization (\(reason.rawValue)). History was kept."
    case .cannotReduce:
      "Summarization did not reduce the context enough; history was kept. Try another compact model."
    case .instructionsTooLarge:
      "The summary instructions exceed the model's input budget. Shorten the compact prompt or use a larger compact model."
    case .budget(let reason): "Summarization stopped: \(reason). History was kept."
    }
  }
}
