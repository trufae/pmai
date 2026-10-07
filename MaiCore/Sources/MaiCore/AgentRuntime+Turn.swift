import Foundation

extension AgentRuntime {
  struct ModelTurn: Sendable {
    let provider: any ChatProvider
    let request: ProviderRequest
    let retry: AgentRetryPolicy
    let definitions: [ToolDefinition]
    let selectingTools: Bool
    let deciding: Bool
    let textToolMode: ToolCallingMode?
    let toolBudgetExhausted: Bool

    var usesTextToolProtocol: Bool { textToolMode != nil && !toolBudgetExhausted }
  }

  func prepareTurn(
    concreteDefinitions: [ToolDefinition], definitions offeredDefinitions: [ToolDefinition],
    state: inout RunState
  ) async throws -> ModelTurn {
    let depth = state.context.depth
    var definitions = offeredDefinitions
    // Once the run's tool budget is spent the model gets no tools and is
    // told to answer, instead of the run failing with a limit error.
    let toolBudgetExhausted =
      !definitions.isEmpty
      && (state.toolCalls >= state.request.limits.maxToolCalls || state.repeatGuardTripped)
    // Resolve once at the call boundary, after compaction and queued input.
    // A task assignment changed during an await cannot mix one provider with
    // another agent's model or options.
    let routedDecision = state.pendingDecision
    state.pendingDecision = nil
    if let routedDecision {
      switch routedDecision {
      case .tool(let name): definitions = concreteDefinitions.filter { $0.name == name }
      default: definitions = []
      }
    }
    let selectingTools =
      routedDecision == nil && !state.usingPrimary && taskAgents.tool != nil
      && !concreteDefinitions.isEmpty
      && state.toolCalls < state.request.limits.maxToolCalls && !state.repeatGuardTripped
    if state.request.context == .tools {
      let candidates = state.toolContext.pending(in: state.transcript)
      if !candidates.isEmpty {
        await supervisor.note(state.pid, activity: "summarizing tool results")
        do {
          let summaries = try await compactText(
            prompt: AgentToolResultContext.prompt(for: candidates, in: state.transcript),
            state: &state)
          state.toolContext.store(summaries, for: candidates)
        } catch let error where error is CancellationError || error is RunDeadlineExceeded {
          throw error
        } catch {
          state.toolContext.store(nil, for: candidates)
          await state.emit(.compactionFailed(state.context, error.localizedDescription))
        }
      }
    }
    var inference = state.request
    inference.messages =
      state.contextMessages
    if selectingTools { inference = try taskRequest(.tool, from: inference) }
    guard let provider = providers[inference.provider] else {
      throw AgentRuntimeError.providerNotRegistered(inference.provider)
    }
    inference.model = resolvedModel(inference.model, for: provider)
    let deciding = provider.descriptor.capabilities.contains(.toolDecision)
    if deciding {
      guard selectingTools, state.request.useSystemOne else {
        throw AgentRuntimeError.systemOneConfiguration(
          "System One requires /set tool.systemone true and a /model-tool assignment; keep a chat provider as the primary model."
        )
      }
      definitions = concreteDefinitions
    } else if selectingTools, state.request.useSystemOne {
      throw AgentRuntimeError.systemOneConfiguration(
        "tool.systemone requires a System One provider in /model-tool.")
    }
    if state.request.useSystemOne, taskAgents.tool == nil, !concreteDefinitions.isEmpty {
      throw AgentRuntimeError.systemOneConfiguration(
        "Select a System One model with /model-tool PROVIDER::MODEL first.")
    }
    let supportsNativeTools =
      deciding || provider.descriptor.capabilities.contains(.nativeToolCalling)
    // A text-only primary can still finish after a native specialist. Give
    // it the text protocol if further work is needed at the handoff.
    if state.usingPrimary, inference.toolCallingStrategy == .native, !supportsNativeTools {
      inference.toolCallingStrategy = .automatic
    }
    if !toolBudgetExhausted, inference.toolCallingStrategy == .native, !definitions.isEmpty,
      !supportsNativeTools
    {
      throw AgentRuntimeError.nativeToolCallingUnavailable(inference.provider)
    }
    let textToolMode: ToolCallingMode? =
      switch deciding ? .native : inference.toolCallingStrategy {
      case .automatic: definitions.isEmpty || supportsNativeTools ? nil : .json
      case .native: nil
      case .text: definitions.isEmpty ? nil : .text
      case .xml: definitions.isEmpty ? nil : .xml
      case .json: definitions.isEmpty ? nil : .json
      }
    let usesTextToolProtocol = textToolMode != nil && !toolBudgetExhausted
    let promptContext = AgentPromptContext(
      messages: inference.messages, activeTaskID: state.activeTaskID)
    var providerMessages: [AgentMessage]
    if state.request.context == .smart {
      if let evidence = state.smartContext.pending(
        in: promptContext, activeTaskID: state.activeTaskID)
      {
        await supervisor.note(state.pid, activity: "preparing state.context")
        do {
          let brief = try await compactText(
            prompt: AgentSmartContext.prompt(
              for: evidence, in: promptContext, template: smartContextTemplate),
            state: &state)
          state.smartContext.store(brief, for: evidence)
        } catch let error where error is CancellationError || error is RunDeadlineExceeded {
          throw error
        } catch {
          await state.emit(.compactionFailed(state.context, error.localizedDescription))
        }
      }
      providerMessages = state.smartContext.messages(from: promptContext)
    } else {
      providerMessages = promptContext.messages()
    }
    if concreteDefinitions.contains(where: { MaiSkillTools.isSkillTool($0.name) }) {
      insertSystem(MaiSkillTools.promptSection, into: &providerMessages)
    }
    if let instructionsSection,
      !providerMessages.contains(where: {
        $0.role == .system && $0.text == instructionsSection
      })
    {
      insertSystem(instructionsSection, into: &providerMessages)
    }
    if let projectSection = projectInstructionSection(
      sessionID: state.request.sessionID, pid: state.pid, messages: providerMessages)
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
    if state.usingPrimary, !toolBudgetExhausted {
      insertSystem(
        "Use the tool results to answer the user's request. If the task is unfinished, use the available tools to complete it before answering.",
        into: &providerMessages)
    }
    if textToolMode != nil || toolBudgetExhausted {
      let prompt =
        toolBudgetExhausted
        ? (state.repeatGuardTripped ? Self.repeatedCallPrompt : Self.toolBudgetExhaustedPrompt)
        : textToolPrompt(definitions, mode: textToolMode ?? .text)
      insertSystem(prompt, into: &providerMessages)
    }
    let offersTools = !usesTextToolProtocol && !toolBudgetExhausted
    let providerRequest = ProviderRequest(
      model: inference.model,
      messages: providerMessages,
      tools: offersTools ? definitions : [],
      toolChoice: definitions.isEmpty || !offersTools ? .none : state.request.toolChoice,
      responseFormat: inference.responseFormat,
      options: inference.options,
      stream: usesTextToolProtocol ? false : inference.stream,
      sessionID: state.request.sessionID)
    return ModelTurn(
      provider: provider, request: providerRequest, retry: inference.retry,
      definitions: definitions, selectingTools: selectingTools, deciding: deciding,
      textToolMode: textToolMode, toolBudgetExhausted: toolBudgetExhausted)
  }

  private func textToolPrompt(
    _ definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> String {
    "Tools are available through a \(mode.displayName.uppercased()) fallback protocol.\n\n"
      + AgentTooling.promptDescription(
        for: AgentToolLoopPolicy.definitions(includingResponseTool: definitions), mode: mode)
  }
}
