import Foundation

extension AgentRuntime {
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
    state: inout RunState, inputLimit: Int? = nil, depth: Int = 0, outputLimit: Int? = nil
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
    let window =
      contextWindow(
        provider: inference.provider, model: inference.model, options: inference.options) ?? 32_768
    // Start small, but leave room to recover when reasoning or a dense
    // transcript needs more output. Explicit configured limits remain caps.
    let maximumOutput = min(
      max(1, inference.options.maxOutputTokens ?? 16_384), max(1, window / 4))
    inference.options.maxOutputTokens = min(
      max(1, outputLimit ?? inference.options.maxOutputTokens ?? 2_048), maximumOutput)
    let budget = min(
      inputLimit ?? Int.max, Self.inputTokenBudget(window: window, options: inference.options))
    var messages = inference.messages
    if let effort = ReasoningEffort.promptSection(for: inference.options) {
      insertSystem(effort, into: &messages)
    }
    let providerRequest = ProviderRequest(
      model: inference.model, messages: messages, tools: [], toolChoice: .none,
      responseFormat: .text, options: inference.options, stream: false,
      sessionID: state.request.sessionID)
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
        let text = MessageContentFilter.textWithoutReasoning(from: call.response.message.text)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowance = inference.options.maxOutputTokens ?? 2_048
        if (call.response.stopReason == .length || text.isEmpty), allowance < maximumOutput {
          // This is a changed request, not a blind transport retry. Recompute
          // the input budget too: more reply space may require smaller chunks.
          return try await compactText(
            source: source, render: render, state: &state, inputLimit: inputLimit,
            depth: depth + 1, outputLimit: min(maximumOutput, allowance * 2))
        }
        guard call.response.stopReason != .length else { throw SummaryError.truncated }
        guard !text.isEmpty else { throw SummaryError.empty }
        return text
      } catch is ProviderContextLimitError {
        // A conservative character estimate still cannot know every tokenizer.
        // Tighten the next request instead of resending the rejected payload.
        return try await compactText(
          source: source, render: render, state: &state,
          inputLimit: min(budget - 1, max(1, Self.contextTokens(providerRequest) / 2)),
          depth: depth + 1, outputLimit: outputLimit)
      }
    }
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
    let chunkBytes = Int(Double(source.utf8.count) * share)
    guard chunkBytes >= 256 else { throw SummaryError.instructionsTooLarge }
    let chunks = Self.summaryChunks(source, maxBytes: chunkBytes)
    guard chunks.count > 1 else { throw SummaryError.cannotReduce }
    var partials: [String] = []
    for chunk in chunks {
      partials.append(
        try await compactText(
          source: chunk, render: render, state: &state, inputLimit: budget, depth: depth + 1, outputLimit: outputLimit))
    }
    let combined = partials.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }
      .joined(separator: "\n\n")
    guard combined.utf8.count < source.utf8.count else { throw SummaryError.cannotReduce }
    return try await compactText(
      source: combined, render: render, state: &state, inputLimit: budget, depth: depth + 1, outputLimit: outputLimit)
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

  private enum SummaryError: LocalizedError {
    case empty, truncated, cannotReduce, instructionsTooLarge
    case budget(String)

    var errorDescription: String? {
      switch self {
      case .empty:
        "The model returned no summary text (possibly only reasoning); history was kept. Lower the compact model's reasoning effort, increase its output limit, or try another model."
      case .truncated:
        "The model's summary reached its output limit (which may include reasoning tokens); history was kept. Increase the compact model's output limit or lower its reasoning effort."
      case .cannotReduce:
        "Summarization did not reduce the context enough; history was kept. Try another compact model."
      case .instructionsTooLarge:
        "The summary instructions exceed the model's input budget. Shorten the compact prompt or use a larger compact model."
      case .budget(let reason): "Summarization stopped: \(reason). History was kept."
      }
    }
  }
}
