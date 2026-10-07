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
  func summaryText(
    of selection: [String],
    in transcript: [AgentMessage],
    focus: String,
    request: AgentRequest,
    budget: RunBudget,
    context: AgentEventContext,
    pid: AgentPID,
    totalUsage: inout TokenUsage?,
    emit: @escaping AgentEventHandler
  ) async throws -> String {
    let selected = Set(selection)
    let latestUserID = transcript.last(where: { $0.role == .user })?.id
    let prompt = AgentCompactionPrompt.render(
      transcript: AgentCompactionPrompt.transcript(
        of: transcript.filter { selected.contains($0.id) || $0.id == latestUserID }),
      focus: focus,
      template: compactionTemplate)
    return try await compactText(
      prompt: prompt, request: request, budget: budget, context: context,
      pid: pid, totalUsage: &totalUsage, emit: emit)
  }

  /// Shared inference plumbing; durable compaction and smart context have
  /// separate prompts and only durable compaction edits the transcript.
  func compactText(
    prompt: String,
    request: AgentRequest,
    budget: RunBudget,
    context: AgentEventContext,
    pid: AgentPID,
    totalUsage: inout TokenUsage?,
    emit: @escaping AgentEventHandler
  ) async throws -> String {
    var base = request
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
      sessionID: request.sessionID)
    let call = try await complete(
      providerRequest,
      with: provider, retry: inference.retry, budget: budget, context: context, pid: pid,
      emit: emit
    ) { _ in }
    await recordModelCall(call, provider: provider.descriptor.id, request: providerRequest)
    let usage = call.usage(for: messages)
    totalUsage = totalUsage.merging(usage)
    await supervisor.note(pid, usage: totalUsage)
    await budget.record(tokens: usage.totalTokens)
    let text = MessageContentFilter.textWithoutReasoning(from: call.response.message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CompactionError.emptySummary }
    return text
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
