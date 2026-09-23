import Foundation
import MaiCore

@MainActor
enum AssistantToolLoop {
  struct ToolRunDetail: Sendable {
    let name: String
    let argumentsJSON: String
    let result: String
    let isError: Bool
  }

  struct IsolatedResult: Sendable {
    let text: String
    let toolRuns: [ToolRunDetail]
    /// How many times the model was asked, for a child agent's process row.
    let modelTurns: Int
    /// The conversation as it ended, so a child agent's transcript can be kept.
    let conversation: Conversation
  }

  private struct RequestState {
    let definitions: [ToolDefinition]
    let nativeTools: [ToolDefinition]?
    let activeMode: ToolCallingMode
    let context: String
    let toolPrompt: String

    var usesTextProtocol: Bool { nativeTools == nil }
  }

  private struct RunOutput {
    let text: String
    let nativeMessages: [AgentMessage]
    let completedRuns: [(key: ToolCallKey, result: String)]
    let parsedCalls: [ParsedToolCall]
    let results: [CallResult]
  }

  private struct CallResult {
    let call: ParsedToolCall
    let result: String
  }

  private enum RunHost {
    case live(assistantID: UUID, baselineText: String, conversationID: UUID)
    case isolated(
      conversation: Conversation,
      settings: AppSettings,
      mcpTools: [UUID: [MCPToolDescriptor]],
      mcpResources: [UUID: [MCPResourceDescriptor]],
      mcpStatuses: [UUID: EndpointConnectionState],
      process: AgentPID?)
  }

  private struct SkippedModelResponse: Error {
    let partialText: String
  }

  private struct State {
    var assistantText = ""
    var nativeContinuationMessages: [AgentMessage] = []
    var completedToolRuns: [ToolCallKey: String] = [:]
    var provisionalText = ""
    var debugRoundIndex = 0
    var toolCallCount = 0
    var repairTurnCount = 0

    mutating func append(_ turnText: String) -> String {
      assistantText = assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
      return assistantText
    }

    var displayText: String {
      [assistantText, provisionalText]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    func displayText(appending turnText: String) -> String {
      [displayText, turnText.trimmingCharacters(in: .whitespacesAndNewlines)]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    mutating func setProvisionalText(_ text: String?) {
      provisionalText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    mutating func clearProvisionalText() {
      provisionalText = ""
    }

    mutating func applyNativeContinuation(
      _ messages: [AgentMessage],
      conversation: Conversation,
      requestState: RequestState
    ) {
      if Self.shouldUseNativeContinuation(conversation: conversation, requestState: requestState),
        !messages.isEmpty
      {
        nativeContinuationMessages.append(contentsOf: messages)
      } else {
        nativeContinuationMessages.removeAll()
      }
    }

    func nativeContinuation(
      conversation: Conversation,
      requestState: RequestState
    ) -> [AgentMessage] {
      Self.shouldUseNativeContinuation(conversation: conversation, requestState: requestState)
        ? nativeContinuationMessages : []
    }

    private static func shouldUseNativeContinuation(
      conversation: Conversation,
      requestState: RequestState
    ) -> Bool {
      requestState.activeMode == .native
        && conversation.provider == .openAICompatible
        && requestState.nativeTools != nil
    }
  }

  private enum Outcome {
    case final(String)
    case retry(String, provisionalText: String?)
    case toolRun(RunOutput)
  }

  static func run(
    conversationID: UUID,
    assistantID: UUID,
    baseContext: String,
    store: AppStore
  ) async throws {
    var activeAssistantID = assistantID
    var state = State()
    var didFinish = false
    let maxToolCalls = maxToolCallsPerTurn(store: store)
    let maxRepairTurns = maxRepairTurnsPerTurn(store: store)

    store.clearToolCallingDebugIterations(
      conversationID: conversationID,
      assistantMessageID: activeAssistantID)

    if let conversation = store.conversation(withID: conversationID) {
      await store.refreshEnabledMCPServers(for: conversation)
    }

    while state.toolCallCount < maxToolCalls && state.repairTurnCount < maxRepairTurns {
      try Task.checkCancellation()
      guard let conversation = store.conversation(withID: conversationID) else { return }
      let host = RunHost.live(
        assistantID: activeAssistantID,
        baselineText: state.displayText,
        conversationID: conversationID)
      let requestState = makeRequestState(
        conversation: conversation,
        baseContext: baseContext,
        host: host,
        store: store)
      let promptMessages = debugPromptMessages(
        conversation: conversation,
        requestState: requestState,
        state: state,
        assistantID: activeAssistantID,
        store: store)
      store.activityPhaseChanged(conversationID: conversationID, phase: .thinking)
      let response: String
      do {
        response = try await requestModelResponse(
          conversation: conversation,
          requestState: requestState,
          state: state,
          assistantID: activeAssistantID,
          host: host,
          store: store)
      } catch let skipped as SkippedModelResponse {
        state.clearProvisionalText()
        let partial = skipped.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let skippedTurn =
          partial.isEmpty
          ? "[model response skipped by user after timeout]"
          : "\(partial)\n\n[model response skipped by user after timeout]"
        store.setAssistantMessage(
          id: activeAssistantID,
          text: state.append(skippedTurn),
          role: .assistant)
        store.saveConversations()
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
          continue
        }
        if !requestState.definitions.isEmpty {
          state.nativeContinuationMessages.removeAll()
          continue
        }
        store.assistantResponseCompleted()
        didFinish = true
        return
      }

      let outcome = try await outcome(
        response: response,
        requestState: requestState,
        host: host,
        store: store,
        completedToolRuns: state.completedToolRuns,
        remainingToolCalls: maxToolCalls - state.toolCallCount)

      switch outcome {
      case .final(let turnText):
        if shouldRetryHiddenOnlyFinal(turnText, state: state, maxRepairTurns: maxRepairTurns) {
          state.debugRoundIndex += 1
          state.repairTurnCount += 1
          appendDebugIteration(
            outcome: "retry",
            response: response,
            promptMessages: promptMessages,
            requestState: requestState,
            conversation: conversation,
            assistantID: activeAssistantID,
            roundIndex: state.debugRoundIndex,
            store: store)
          state.setProvisionalText(provisionalDisplayText(from: turnText))
          let canonicalText = state.append(
            AgentToolLoopPolicy.repairFeedbackAfterToolResult(mode: requestState.activeMode))
          store.setAssistantMessage(id: activeAssistantID, text: canonicalText, role: .assistant)
          if !state.provisionalText.isEmpty {
            store.setAssistantMessage(
              id: activeAssistantID,
              text: state.displayText,
              role: .assistant,
              touch: false,
              streaming: true)
          }
          store.saveConversations()
          state.nativeContinuationMessages.removeAll()
          if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
            in: conversationID)
          {
            activeAssistantID = nextAssistantID
            state = State()
            store.clearToolCallingDebugIterations(
              conversationID: conversationID,
              assistantMessageID: activeAssistantID)
          }
          continue
        }
        state.clearProvisionalText()
        store.setAssistantMessage(
          id: activeAssistantID,
          text: state.append(turnText),
          role: .assistant)
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
          continue
        }
        // A child started without waiting reports into the chat's inbox; the
        // turn holds for it instead of ending with the work unfinished, and
        // its answer joins the chat as a message the model answers next.
        if let nextAssistantID = try await store.awaitAgentDeliveriesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
          continue
        }
        store.assistantResponseCompleted()
        didFinish = true
        return
      case .retry(let feedback, let provisionalText):
        state.debugRoundIndex += 1
        state.repairTurnCount += 1
        appendDebugIteration(
          outcome: "retry",
          response: response,
          promptMessages: promptMessages,
          requestState: requestState,
          conversation: conversation,
          assistantID: activeAssistantID,
          roundIndex: state.debugRoundIndex,
          store: store)
        state.setProvisionalText(provisionalText)
        let canonicalText = state.append(feedback)
        store.setAssistantMessage(id: activeAssistantID, text: canonicalText, role: .assistant)
        if !state.provisionalText.isEmpty {
          store.setAssistantMessage(
            id: activeAssistantID,
            text: state.displayText,
            role: .assistant,
            touch: false,
            streaming: true)
        }
        store.saveConversations()
        state.nativeContinuationMessages.removeAll()
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
        }
      case .toolRun(let output):
        state.debugRoundIndex += 1
        appendDebugIteration(
          outcome: "toolRun",
          response: response,
          promptMessages: promptMessages,
          requestState: requestState,
          conversation: conversation,
          assistantID: activeAssistantID,
          roundIndex: state.debugRoundIndex,
          store: store,
          parsedCalls: output.parsedCalls,
          results: output.results)
        store.setAssistantMessage(
          id: activeAssistantID, text: state.append(output.text), role: .assistant)
        if !state.provisionalText.isEmpty {
          store.setAssistantMessage(
            id: activeAssistantID,
            text: state.displayText,
            role: .assistant,
            touch: false,
            streaming: true)
        }
        store.saveConversations()
        for completedRun in output.completedRuns where isSuccessfulToolResult(completedRun.result) {
          state.completedToolRuns[completedRun.key] = completedRun.result
        }
        state.toolCallCount += output.results.count
        state.applyNativeContinuation(
          output.nativeMessages,
          conversation: conversation,
          requestState: requestState)
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
        }
      }
    }

    if !didFinish {
      let suffix =
        "\n\nTool loop stopped after \(state.toolCallCount) of \(maxToolCalls) allowed tool call\(maxToolCalls == 1 ? "" : "s") and \(state.repairTurnCount) repair turn\(state.repairTurnCount == 1 ? "" : "s") before the model produced a final answer."
      let text =
        state.displayText.isEmpty
        ? suffix.trimmingCharacters(in: .whitespacesAndNewlines) : state.displayText + suffix
      store.setAssistantMessage(
        id: activeAssistantID,
        text: text,
        role: .assistant)
      if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
        in: conversationID)
      {
        try await run(
          conversationID: conversationID,
          assistantID: nextAssistantID,
          baseContext: baseContext,
          store: store)
      }
    }
  }

  /// Runs a conversation the store does not own to its final answer. With a
  /// `process`, the run is a child agent: it reports each turn and tool to
  /// the supervisor, waits while paused, and reads the messages a person
  /// queued for it before its next model turn.
  static func runIsolated(
    conversation initialConversation: Conversation,
    settings: AppSettings,
    baseContext: String,
    store: AppStore,
    process: AgentPID? = nil
  ) async throws -> IsolatedResult {
    var conversation = initialConversation
    var assistantID = UUID()
    conversation.messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))

    var state = State()
    var toolRuns: [ToolRunDetail] = []
    var modelTurns = 0
    let maxToolCalls = maxToolCallsPerTurn(settings: settings)
    let maxRepairTurns = maxRepairTurnsPerTurn(settings: settings)

    await store.refreshEnabledMCPServers(for: conversation, settings: settings)

    while state.toolCallCount < maxToolCalls && state.repairTurnCount < maxRepairTurns {
      try Task.checkCancellation()
      // A run started without a process gets one the first time it uses an
      // agent tool, registered under its conversation; from then on its
      // children report into that process's inbox.
      let process = process ?? store.agentProcessIDs[conversation.id]
      if let process {
        try await holdWhilePaused(process, store: store)
        // Messages queued for this child join its conversation before the
        // next model turn, the way pmai's inbox works: the answer so far is
        // kept and a fresh assistant turn follows them.
        let injected = await store.agentSupervisor.drainInbox(process).filter { $0.role == .user }
        if !injected.isEmpty {
          // A child started without waiting reports here too; its answer
          // counts as taken once it is read.
          for message in injected {
            if let child = AgentProcessTools.deliveredChildPID(of: message) {
              await store.agentSupervisor.collect(child)
            }
          }
          conversation.messages.append(
            contentsOf: injected.map { ChatMessage(role: .user, text: $0.text) })
          assistantID = UUID()
          conversation.messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
          state = State()
        }
      }
      modelTurns += 1
      if let process {
        await store.agentSupervisor.note(
          process,
          state: .running,
          modelTurns: modelTurns,
          toolCalls: toolRuns.count,
          activity: "thinking",
          transcript: SubagentRunner.transcript(of: conversation))
      }
      let host = RunHost.isolated(
        conversation: conversation,
        settings: settings,
        mcpTools: store.mcpTools,
        mcpResources: store.mcpResources,
        mcpStatuses: store.mcpStatuses,
        process: process)
      let requestState = makeRequestState(
        conversation: conversation,
        baseContext: baseContext,
        host: host,
        store: store)
      let response = try await requestModelResponse(
        conversation: conversation,
        requestState: requestState,
        state: state,
        assistantID: assistantID,
        host: host,
        store: store)

      let outcome = try await outcome(
        response: response,
        requestState: requestState,
        host: host,
        store: store,
        completedToolRuns: state.completedToolRuns,
        remainingToolCalls: maxToolCalls - state.toolCallCount)

      switch outcome {
      case .final(let turnText):
        if shouldRetryHiddenOnlyFinal(turnText, state: state, maxRepairTurns: maxRepairTurns) {
          state.debugRoundIndex += 1
          state.repairTurnCount += 1
          let text = state.append(
            AgentToolLoopPolicy.repairFeedbackAfterToolResult(mode: requestState.activeMode))
          updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
          state.nativeContinuationMessages.removeAll()
          continue
        }
        state.clearProvisionalText()
        let text = state.append(turnText)
        updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
        // A child started without waiting reports into this process's inbox;
        // the run holds for it and goes round once more, where the drain at
        // the top of the loop reads its answer under a fresh assistant turn.
        if let process,
          try await AgentProcessTools.awaitChildren(of: process, supervisor: store.agentSupervisor)
        {
          state = State()
          continue
        }
        return IsolatedResult(
          text: userVisibleResponseText(from: text),
          toolRuns: toolRuns,
          modelTurns: modelTurns,
          conversation: conversation)
      case .retry(let feedback, _):
        state.debugRoundIndex += 1
        state.repairTurnCount += 1
        let text = state.append(feedback)
        updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
        state.nativeContinuationMessages.removeAll()
      case .toolRun(let output):
        state.debugRoundIndex += 1
        let text = state.append(output.text)
        updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
        toolRuns.append(
          contentsOf: output.results.map {
            ToolRunDetail(
              name: $0.call.name,
              argumentsJSON: $0.call.argsJSON,
              result: $0.result,
              isError: isToolResultError($0.result))
          })
        for completedRun in output.completedRuns where isSuccessfulToolResult(completedRun.result) {
          state.completedToolRuns[completedRun.key] = completedRun.result
        }
        state.toolCallCount += output.results.count
        state.applyNativeContinuation(
          output.nativeMessages,
          conversation: conversation,
          requestState: requestState)
      }
    }

    let suffix =
      "\n\nTool loop stopped after \(state.toolCallCount) of \(maxToolCalls) allowed tool call\(maxToolCalls == 1 ? "" : "s") and \(state.repairTurnCount) repair turn\(state.repairTurnCount == 1 ? "" : "s") before the model produced a final answer."
    let text = state.assistantText + suffix
    updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
    return IsolatedResult(
      text: userVisibleResponseText(from: text),
      toolRuns: toolRuns,
      modelTurns: modelTurns,
      conversation: conversation)
  }

  /// Where a paused child waits: a person pauses it through the supervisor
  /// while it is inside a model call or a tool, and it holds here at the
  /// next turn boundary until it is resumed or stopped.
  private static func holdWhilePaused(_ process: AgentPID, store: AppStore) async throws {
    guard await store.agentSupervisor.isPaused(process) else { return }
    await store.agentSupervisor.note(process, activity: "")
    while await store.agentSupervisor.isPaused(process) {
      try await Task.sleep(for: .milliseconds(200))
    }
  }

  private static func requestModelResponse(
    conversation: Conversation,
    requestState: RequestState,
    state: State,
    assistantID: UUID,
    host: RunHost,
    store: AppStore
  ) async throws -> String {
    // In the synthesis round (after a tool has run), suppress the tail reminder that says
    // "emit exactly one valid tool call and stop" — small models echo the tool result instead
    // of answering when they see that instruction a second time.
    let tailToolPrompt: String = {
      guard requestState.usesTextProtocol else { return "" }
      return state.completedToolRuns.isEmpty ? requestState.toolPrompt : ""
    }()
    let userInputTokens: Int?
    if case .live = host, state.toolCallCount == 0, state.repairTurnCount == 0 {
      userInputTokens = userInputTokenEstimate(in: conversation, before: assistantID)
    } else {
      userInputTokens = nil
    }
    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: settings(for: host, store: store),
      context: requestState.context,
      assistantMessageID: assistantID,
      userInputTokens: userInputTokens,
      nativeTools: requestState.nativeTools,
      nativeContinuationMessages: state.nativeContinuation(
        conversation: conversation,
        requestState: requestState),
      hasToolCalling: !requestState.definitions.isEmpty,
      toolPrompt: conversation.provider == .apple ? requestState.toolPrompt : tailToolPrompt,
      toolPromptInContext: conversation.provider != .apple
        && requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty
    )
    var latestStreamedResponse = ""
    let response: String
    do {
      response = try await ChatProviderRouter.complete(
        request: request,
        timeoutHandler: timeoutHandler(store: store)
      ) { [weak store] streamed in
        latestStreamedResponse = streamed
        guard case .live = host else { return }
        let turnText =
          requestState.definitions.isEmpty
          ? AppStore.strippedSpuriousToolCallText(streamed) : streamed
        store?.receiveStreamingAssistantText(
          state.displayText(appending: turnText),
          for: assistantID,
          vibrate: request.conversation.usesStreaming)
      }
    } catch is LongRunningOperationSkipped {
      let partial =
        requestState.definitions.isEmpty
        ? AppStore.strippedSpuriousToolCallText(latestStreamedResponse)
        : latestStreamedResponse
      switch host {
      case .live:
        throw SkippedModelResponse(partialText: partial)
      case .isolated:
        return partial.isEmpty
          ? "[model response skipped by user after timeout]"
          : "\(partial)\n\n[model response skipped by user after timeout]"
      }
    }
    try Task.checkCancellation()
    if case .live = host,
      let stats = UsageStatsStore.shared.pendingStats(for: assistantID)
    {
      store.attachGenerationStats(stats, toMessage: assistantID)
    }
    return requestState.definitions.isEmpty
      ? AppStore.strippedSpuriousToolCallText(response)
      : response
  }

  private static func timeoutHandler(store: AppStore) -> LongRunningOperationTimeoutHandler {
    { [weak store] context in
      guard let store else { return .interrupt }
      return await store.requestLongRunningOperationDecision(context)
    }
  }

  /// Counts only the user messages that started this assistant turn, excluding
  /// prior context, tool output, and the generated system prompt.
  private static func userInputTokenEstimate(
    in conversation: Conversation, before assistantID: UUID
  )
    -> Int?
  {
    guard let assistantIndex = conversation.messages.firstIndex(where: { $0.id == assistantID })
    else {
      return nil
    }
    let turnMessages = conversation.messages[..<assistantIndex]
      .reversed()
      .prefix { $0.role != .assistant }
      .filter { $0.role == .user }
    let characters = turnMessages.reduce(0) { total, message in
      total + MessageContentFilter.promptSafeText(from: message.text).count
    }
    guard characters > 0 else { return nil }
    return GenerationStats.estimatedTokenCount(forCharacterCount: characters)
  }

  private static func outcome(
    response: String,
    requestState: RequestState,
    host: RunHost,
    store: AppStore,
    completedToolRuns: [ToolCallKey: String],
    remainingToolCalls: Int
  ) async throws -> Outcome {
    guard !requestState.definitions.isEmpty else { return .final(response) }

    let currentDefinitions = currentVisibleDefinitions(for: host, store: store)
    let hostDefinitions =
      currentDefinitions.isEmpty ? requestState.definitions : currentDefinitions
    let parseDefinitions = AgentToolLoopPolicy.definitions(includingResponseTool: hostDefinitions)
    let decision = AgentToolLoopPolicy.evaluate(
      response: response,
      tools: hostDefinitions,
      mode: requestState.activeMode,
      completedToolRuns: completedToolRuns,
      remainingToolCalls: remainingToolCalls)
    let calls: [ParsedToolCall]
    switch decision {
    case .final(let text): return .final(text)
    case .repair(let feedback): return .retry(feedback, provisionalText: nil)
    case .execute(let parsedCalls): calls = parsedCalls
    }

    let output = try await runToolCalls(
      response: response,
      calls: calls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions,
      mode: requestState.activeMode,
      host: host,
      store: store)
    return .toolRun(output)
  }

  private static func runToolCalls(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    host: RunHost,
    store: AppStore
  ) async throws -> RunOutput {
    if case .live(let assistantID, let baselineText, _) = host {
      publishPendingToolRuns(
        response: response,
        calls: calls,
        remainingToolCalls: remainingToolCalls,
        parseDefinitions: parseDefinitions,
        assistantID: assistantID,
        baselineText: baselineText,
        store: store)
    }

    // The reply's calls are prepared — normalized, approved, validated — in
    // order. A call to a concurrent tool, the agent family above all, is then
    // started and left running while the calls after it go on, so children
    // started in one reply work side by side; the others run one at a time
    // in between. The results join the transcript in call order once the
    // last of them is in.
    var assistantContent = response
    var results = [CallResult?](repeating: nil, count: calls.count)
    // Calls past the cap: dropped, and taken out of the transcript.
    var dropped = Set<Int>()
    var launched = 0

    func publishProgress() {
      guard case .live(let assistantID, let baselineText, _) = host else { return }
      let assembled = assembleRunBlocks(
        response: response, calls: calls, results: results, dropped: dropped)
      let pending = calls.indices
        .filter { results[$0] == nil && !dropped.contains($0) }
        .map { calls[$0] }
      publishToolRunProgress(
        transcriptText: assembled.text,
        appendedRunBlocks: assembled.appended,
        pendingCalls: pending,
        remainingToolCalls: max(0, remainingToolCalls - launched),
        parseDefinitions: parseDefinitions,
        assistantID: assistantID,
        baselineText: baselineText,
        store: store)
    }

    try await withThrowingTaskGroup(of: (Int, CallResult).self) { group in
      for (index, call) in calls.enumerated() {
        try Task.checkCancellation()
        // Feedback queued after this provider response takes precedence over
        // tool calls that have not started yet. Already-running tools finish,
        // then the loop injects the feedback before asking the model again.
        if case .live(_, _, let conversationID) = host,
          store.hasQueuedUserMessages(in: conversationID)
        {
          break
        }
        replaceFirstOccurrence(of: call.rawBlock, in: &assistantContent, with: "")
        guard launched < remainingToolCalls else {
          dropped.insert(index)
          continue
        }
        launched += 1
        switch try await prepareToolCall(
          call,
          parseDefinitions: parseDefinitions,
          mode: mode,
          host: host,
          store: store)
        {
        case .answered(let result):
          results[index] = result
        case .ready(let ready) where ready.concurrent:
          group.addTask {
            (index, try await executeToolCall(ready, store: store))
          }
        case .ready(let ready):
          results[index] = try await executeToolCall(ready, store: store)
        }
        publishProgress()
      }
      for try await (index, result) in group {
        results[index] = result
        publishProgress()
      }
    }

    let assembled = assembleRunBlocks(
      response: response, calls: calls, results: results, dropped: dropped)
    let ordered = results.compactMap { $0 }
    let completedRuns = ordered.map { (key: ToolCallKey($0.call), result: $0.result) }
    let text =
      ([assembled.text.trimmingCharacters(in: .whitespacesAndNewlines)] + assembled.appended)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
    let echoReasoningContent: Bool
    switch host {
    case .live(_, _, let conversationID):
      echoReasoningContent = shouldEchoReasoningContent(
        conversationID: conversationID,
        store: store)
    case .isolated(let conversation, let settings, _, _, _, _):
      echoReasoningContent = shouldEchoReasoningContent(
        conversation: conversation,
        settings: settings)
    }
    return RunOutput(
      text: text,
      nativeMessages: nativeMessages(
        assistantContent: assistantContent,
        results: ordered,
        definitions: parseDefinitions,
        mode: mode,
        echoReasoningContent: echoReasoningContent),
      completedRuns: completedRuns,
      parsedCalls: calls,
      results: ordered)
  }

  /// The reply with each finished call's block replaced by its run block, in
  /// call order; blocks the text does not carry (native calls) are returned
  /// separately to be appended. A dropped call leaves no trace; a call still
  /// running, or one that never started, keeps its block as it was.
  private static func assembleRunBlocks(
    response: String,
    calls: [ParsedToolCall],
    results: [CallResult?],
    dropped: Set<Int>
  ) -> (text: String, appended: [String]) {
    var text = response
    var appended: [String] = []
    for (index, call) in calls.enumerated() {
      if dropped.contains(index) {
        replaceFirstOccurrence(of: call.rawBlock, in: &text, with: "")
        continue
      }
      guard let result = results[index] else { continue }
      let runBlock = AgentTooling.makeRunBlock(call: result.call, result: result.result)
      if !replaceFirstOccurrence(of: call.rawBlock, in: &text, with: runBlock) {
        appended.append(runBlock)
      }
    }
    return (text, appended)
  }

  private static func publishPendingToolRuns(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    assistantID: UUID,
    baselineText: String,
    store: AppStore
  ) {
    let text = pendingToolRunText(
      response: response,
      calls: calls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    store.setAssistantMessage(
      id: assistantID,
      text: combinedAssistantText(baseline: baselineText, turnText: text),
      role: .assistant,
      touch: false)
    store.saveConversations()
  }

  private static func publishToolRunProgress(
    transcriptText: String,
    appendedRunBlocks: [String],
    pendingCalls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    assistantID: UUID,
    baselineText: String,
    store: AppStore
  ) {
    let pendingText = pendingToolRunText(
      response: transcriptText,
      calls: pendingCalls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions)
    let turnText = ([pendingText] + appendedRunBlocks)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    store.setAssistantMessage(
      id: assistantID,
      text: combinedAssistantText(baseline: baselineText, turnText: turnText),
      role: .assistant,
      touch: false)
    store.saveConversations()
  }

  private static func pendingToolRunText(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition]
  ) -> String {
    var transcriptText = response
    var appendedRunBlocks: [String] = []
    var pendingCount = 0
    for call in calls {
      guard pendingCount < remainingToolCalls else {
        replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: "")
        continue
      }
      let normalizedCall = AgentTooling.normalized(call: call, tools: parseDefinitions)
      let runBlock = AgentTooling.makeRunBlock(
        call: normalizedCall,
        result: "Waiting for host tool result.")
      if !replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: runBlock) {
        appendedRunBlocks.append(runBlock)
      }
      pendingCount += 1
    }
    return
      ([transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)]
      + appendedRunBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
  }

  /// A call the host has approved and is about to run: what to run, whether
  /// it may run alongside the other calls of its reply, and the timeout to
  /// hold it to.
  private struct ReadyToolCall: Sendable {
    let call: ParsedToolCall
    let concurrent: Bool
    let context: LongRunningOperationContext
    let execute: @Sendable () async -> String
  }

  private enum PreparedToolCall {
    /// The call is answered without running: unavailable, refused, or invalid.
    case answered(CallResult)
    case ready(ReadyToolCall)
  }

  /// Everything that happens to a call before it runs, in call order for the
  /// whole reply: the name is resolved against the tools the model may use,
  /// the person approves it, the arguments are checked.
  private static func prepareToolCall(
    _ call: ParsedToolCall,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    host: RunHost,
    store: AppStore
  ) async throws -> PreparedToolCall {
    let currentDefinitions = currentVisibleDefinitions(for: host, store: store)
    let fallbackCall = AgentTooling.normalized(call: call, tools: parseDefinitions)
    guard let normalizedCall = AgentTooling.availableCall(call, tools: currentDefinitions) else {
      return .answered(
        CallResult(
          call: fallbackCall,
          result: AgentTooling.unavailableToolError(name: fallbackCall.name)))
    }

    let approvedCall: ParsedToolCall
    let shouldExecute: Bool
    let approval: ToolCallApprovalDecision
    switch host {
    case .live(_, _, let conversationID):
      approval = await store.requestToolCallApproval(
        call: normalizedCall,
        definitions: currentDefinitions,
        mode: mode,
        conversationID: conversationID)
    case .isolated(let conversation, _, _, _, _, _):
      approval = await store.requestToolCallApproval(
        call: normalizedCall,
        definitions: currentDefinitions,
        mode: mode,
        conversationTitle: conversation.displayTitle)
    }
    switch approval {
    case .approved(let call):
      approvedCall = call
      shouldExecute = true
    case .cancelled:
      approvedCall = normalizedCall
      shouldExecute = false
    case .interrupted:
      throw CancellationError()
    }

    try Task.checkCancellation()
    guard shouldExecute else {
      return .answered(
        CallResult(call: approvedCall, result: "Error: tool call cancelled by user."))
    }
    if case .live(_, _, let conversationID) = host,
      store.hasQueuedUserMessages(in: conversationID)
    {
      return .answered(
        CallResult(
          call: approvedCall,
          result: "Error: tool call skipped because the user queued new instructions."))
    }

    let executionDefinitions = currentVisibleDefinitions(for: host, store: store)
    guard let executableCall = AgentTooling.availableCall(approvedCall, tools: executionDefinitions)
    else {
      let unavailableCall = AgentTooling.normalized(
        call: approvedCall,
        tools: currentDefinitions)
      return .answered(
        CallResult(
          call: unavailableCall,
          result: AgentTooling.unavailableToolError(name: unavailableCall.name)))
    }
    if let validationError = AgentTooling.requiredArgumentsError(
      call: executableCall,
      tools: executionDefinitions)
    {
      return .answered(CallResult(call: executableCall, result: validationError))
    }

    let context: LongRunningOperationContext
    switch host {
    case .live(let assistantID, _, let conversationID):
      store.activityPhaseChanged(
        conversationID: conversationID,
        phase: .runningTool,
        detail: executableCall.name)
      context = LongRunningOperationContext(
        kind: .toolCall,
        conversationID: conversationID,
        assistantMessageID: assistantID,
        operationName: executableCall.name,
        conversationTitle: store.conversation(withID: conversationID)?.displayTitle,
        timeoutInterval: store.settings.mcpRequestTimeoutInterval)
    case .isolated(let conversation, let settings, _, _, _, let process):
      if let process {
        await store.agentSupervisor.note(process, activity: executableCall.name)
      }
      context = LongRunningOperationContext(
        kind: .toolCall,
        conversationID: conversation.id,
        assistantMessageID: nil,
        operationName: executableCall.name,
        conversationTitle: conversation.displayTitle,
        timeoutInterval: settings.mcpRequestTimeoutInterval)
    }
    let execute: @Sendable () async -> String = {
      switch host {
      case .live(_, _, let conversationID):
        await ToolAgentRegistry.execute(
          call: executableCall,
          conversationID: conversationID,
          store: store)
      case .isolated(let conversation, let settings, _, _, _, _):
        await ToolAgentRegistry.execute(
          call: executableCall,
          conversation: conversation,
          settings: settings,
          store: store)
      }
    }
    // An asynchronous tool call — one whose definition says it runs
    // alongside the rest of the reply — is what lets several children start
    // at once; a legacy spelling of agent_start counts as the tool it names.
    let canonicalName = AgentProcessTools.canonicalName(executableCall.name)
    let concurrent = executionDefinitions.contains {
      $0.name == canonicalName && $0.annotations.concurrent
    }
    return .ready(
      ReadyToolCall(
        call: executableCall, concurrent: concurrent, context: context, execute: execute))
  }

  private static func executeToolCall(
    _ ready: ReadyToolCall,
    store: AppStore
  ) async throws -> CallResult {
    // A child agent runs for as long as its own model calls take, each under
    // the same timeout prompt as this one; asking again about the parent's
    // wait for it would only double the questions.
    if SubagentTool.isAgentTool(ready.call.name) {
      return CallResult(call: ready.call, result: await ready.execute())
    }
    do {
      let result = try await InteractiveOperationTimeout.run(
        seconds: ready.context.timeoutInterval,
        context: ready.context,
        onTimeout: timeoutHandler(store: store),
        operation: ready.execute)
      return CallResult(call: ready.call, result: result)
    } catch is LongRunningOperationSkipped {
      return CallResult(
        call: ready.call,
        result: "Error: tool call skipped by user after timeout.")
    }
  }

  private static func currentVisibleDefinitions(
    for host: RunHost,
    store: AppStore
  ) -> [ToolDefinition] {
    switch host {
    case .live(_, _, let conversationID):
      return currentVisibleDefinitions(conversationID: conversationID, store: store)
    case .isolated(
      let conversation, let settings, let mcpTools, let mcpResources, let mcpStatuses, _):
      return currentVisibleDefinitions(
        conversation: conversation,
        settings: settings,
        mcpTools: mcpTools,
        mcpResources: mcpResources,
        mcpStatuses: mcpStatuses)
    }
  }

  private static func settings(for host: RunHost, store: AppStore) -> AppSettings {
    switch host {
    case .live:
      return store.settings
    case .isolated(_, let settings, _, _, _, _):
      return settings
    }
  }

  private static func makeRequestState(
    conversation: Conversation,
    baseContext: String,
    host: RunHost,
    store: AppStore
  ) -> RequestState {
    let settings = settings(for: host, store: store)
    let visibleDefinitions = currentVisibleDefinitions(for: host, store: store)
    let loopDefinitions = AgentToolLoopPolicy.definitions(includingResponseTool: visibleDefinitions)
    let nativeTools = nativeToolsIfNeeded(
      conversation: conversation,
      settings: settings,
      definitions: loopDefinitions)
    let activeMode =
      nativeTools == nil
      ? settings.toolCallingMode.textProtocolFallback(for: conversation.provider)
      : .native
    let toolPrompt =
      nativeTools == nil
      ? AgentTooling.promptDescription(for: loopDefinitions, mode: activeMode)
      : nativeToolLoopPrompt()
    let requestContext = [baseContext, conversation.provider == .apple ? "" : toolPrompt]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    return RequestState(
      definitions: visibleDefinitions,
      nativeTools: nativeTools,
      activeMode: activeMode,
      context: requestContext,
      toolPrompt: toolPrompt)
  }

  private static func nativeToolLoopPrompt() -> String {
    """
    When tools are available, use the provided native tools. After a host tool result, call another host tool if another host tool run is needed. If the result is enough, give the final answer directly. Do not describe a future tool call in prose.
    """
  }

  private static func nativeToolsIfNeeded(
    conversation: Conversation,
    settings: AppSettings,
    definitions: [ToolDefinition]
  ) -> [ToolDefinition]? {
    guard
      settings.toolCallingMode == .native,
      conversation.provider.supportsNativeToolCalling,
      !definitions.isEmpty
    else {
      return nil
    }

    let resolver = AgentToolNameResolver(tools: definitions)
    return definitions.map { definition in
      var native = definition
      let apiName = resolver.apiName(for: definition.name)
      native.providerName = apiName
      if apiName != definition.name {
        native.description += " Original tool name: \(definition.name)."
      }
      return native
    }
  }

  private static func nativeMessages(
    assistantContent: String,
    results: [CallResult],
    definitions: [ToolDefinition],
    mode: ToolCallingMode,
    echoReasoningContent: Bool
  ) -> [AgentMessage] {
    guard mode == .native, !results.isEmpty else { return [] }
    let resolver = AgentToolNameResolver(tools: definitions)
    let toolCalls = results.compactMap { item -> ToolCall? in
      guard let id = item.call.toolCallID else { return nil }
      let canonical = resolver.canonicalName(for: item.call.name) ?? item.call.name
      return ToolCall(id: id, name: canonical, arguments: .object(item.call.argumentValues))
    }
    guard toolCalls.count == results.count else { return [] }

    let content = MessageContentFilter.conversationContextText(from: assistantContent)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var assistantParts: [ContentPart] = [.text(content)]
    if let reasoning = PromptComposer.reasoningContent(
      from: assistantContent,
      echoReasoningContent: echoReasoningContent)
    {
      assistantParts.append(.reasoning(reasoning))
    }
    assistantParts.append(contentsOf: toolCalls.map(ContentPart.toolCall))
    let assistant = AgentMessage(role: .assistant, content: assistantParts)
    let toolMessages = results.compactMap { item -> AgentMessage? in
      guard let id = item.call.toolCallID else { return nil }
      return AgentMessage(
        role: .tool,
        content: [.toolResult(ToolResult(callID: id, text: item.result))])
    }
    return [assistant] + toolMessages
  }

  private static func appendDebugIteration(
    outcome: String,
    response: String,
    promptMessages: [ConversationDebugPromptMessage],
    requestState: RequestState,
    conversation: Conversation,
    assistantID: UUID,
    roundIndex: Int,
    store: AppStore,
    parsedCalls: [ParsedToolCall] = [],
    results: [CallResult] = []
  ) {
    let firstCall = results.first?.call ?? parsedCalls.first
    let firstResult = results.first?.result ?? "Error: invalid tool call response."
    let resultText =
      results.isEmpty
      ? firstResult
      : results.map { "\($0.call.name) tool (\($0.call.argsJSON)):\n\($0.result)" }
        .joined(separator: "\n\n")
    let parsedDebugCalls = parsedCalls.map {
      ConversationDebugParsedToolCall(
        name: $0.name,
        argumentsJSON: $0.argsJSON,
        rawBlock: $0.rawBlock)
    }
    let iteration = ConversationDebugToolIteration(
      assistantMessageID: assistantID,
      assistantMessageIndex: conversation.messages.firstIndex(where: { $0.id == assistantID })
        ?? -1,
      roundIndex: roundIndex,
      source: "runtime",
      createdAt: Date(),
      provider: conversation.provider.rawValue,
      model: debugModelName(for: conversation, store: store),
      selectedMode: store.settings.toolCallingMode.rawValue,
      effectiveMode: requestState.activeMode.rawValue,
      maxToolCallsPerTurn: maxToolCallsPerTurn(store: store),
      maxRepairTurnsPerTurn: maxRepairTurnsPerTurn(store: store),
      yoloModeEnabled: store.settings.yoloModeEnabled,
      useToolProxy: store.settings.useToolProxy,
      nativeToolCallingUnavailableReason: nativeToolCallingUnavailableReason(
        conversation: conversation,
        settings: store.settings,
        hasTools: !requestState.definitions.isEmpty),
      requestContext: requestState.context,
      toolPrompt: requestState.toolPrompt,
      nativeToolNames: requestState.nativeTools?.map { $0.providerName ?? $0.name } ?? [],
      visibleToolDefinitions: requestState.definitions.map(debugDefinition),
      promptMessages: promptMessages,
      rawModelResponse: response,
      parsedToolCalls: parsedDebugCalls,
      outcome: outcome,
      toolName: firstCall?.name ?? "invalid_tool_call",
      argumentsJSON: firstCall?.argsJSON ?? "{}",
      result: resultText,
      isError: firstResult.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .hasPrefix("error:"),
      rawBlock: response)
    store.appendToolCallingDebugIteration(iteration, conversationID: conversation.id)
  }

  private static func debugPromptMessages(
    conversation: Conversation,
    requestState: RequestState,
    state: State,
    assistantID: UUID,
    store: AppStore
  ) -> [ConversationDebugPromptMessage] {
    let tailToolPrompt: String = {
      guard requestState.usesTextProtocol else { return "" }
      return state.completedToolRuns.isEmpty ? requestState.toolPrompt : ""
    }()
    if conversation.provider == .apple {
      let request = ChatCompletionRequest(
        conversation: conversation, settings: store.settings, context: requestState.context,
        assistantMessageID: assistantID, hasToolCalling: !requestState.definitions.isEmpty,
        toolPrompt: requestState.toolPrompt)
      return PromptComposer.appleInput(request: request).messages.map(debugPromptMessage)
    }
    if conversation.provider == .openAICompatible,
      let endpoint = OpenAICompatibleProvider.selectedEndpoint(
        for: conversation,
        settings: store.settings)
    {
      let model = conversation.modelID.isEmpty ? endpoint.defaultModel : conversation.modelID
      return PromptComposer.openAIMessages(
        conversation: conversation,
        settings: store.settings,
        context: requestState.context,
        model: model,
        endpoint: endpoint,
        excludingMessageID: state.nativeContinuationMessages.isEmpty ? nil : assistantID,
        nativeContinuationMessages: state.nativeContinuation(
          conversation: conversation,
          requestState: requestState),
        hasTools: requestState.nativeTools?.isEmpty == false,
        toolPrompt: tailToolPrompt,
        toolPromptInContext: requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty
      ).map(debugPromptMessage)
    }

    let baseSystem = PromptComposer.systemPrompt(
      settings: store.settings,
      conversation: conversation)
    let systemContent =
      requestState.context.isEmpty
      ? baseSystem
      : "\(baseSystem)\n\n## Context\n\(requestState.context)"
    var messages = [ConversationDebugPromptMessage(role: "system", content: systemContent)]
    let limited = PromptComposer.contextMessages(
      from: conversation,
      settings: store.settings,
      limit: store.settings.contextWindowMode.messageLimit)
    messages.append(
      contentsOf: limited.flatMap { message in
        PromptComposer.contextTranscriptEntries(from: message, settings: store.settings).map {
          ConversationDebugPromptMessage(
            role: debugRole(displayName: $0.displayName),
            content: $0.content)
        }
      })
    if let reminder = PromptComposer.toolCallingReminder(
      toolPrompt: tailToolPrompt,
      includeToolPrompt: !(requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty))
    {
      messages.append(ConversationDebugPromptMessage(role: "user", content: reminder))
    }
    return messages
  }

  private static func debugPromptMessage(
    from message: AgentMessage
  ) -> ConversationDebugPromptMessage {
    let toolCallsJSON: String?
    if !message.toolCalls.isEmpty,
      let data = try? JSONEncoder().encode(message.toolCalls),
      let json = String(data: data, encoding: .utf8)
    {
      toolCallsJSON = json
    } else {
      toolCallsJSON = nil
    }
    return ConversationDebugPromptMessage(
      role: message.role.rawValue,
      content: message.text,
      reasoningContent: message.reasoning.isEmpty ? nil : message.reasoning,
      toolCallsJSON: toolCallsJSON,
      toolCallID: message.toolResults.first?.callID)
  }

  private static func debugRole(displayName: String) -> String {
    switch displayName {
    case ChatRole.system.displayName:
      return "system"
    case ChatRole.assistant.displayName:
      return "assistant"
    default:
      return "user"
    }
  }

  private static func currentVisibleDefinitions(
    conversationID: UUID,
    store: AppStore
  ) -> [ToolDefinition] {
    guard let conversation = store.conversation(withID: conversationID) else { return [] }
    return ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools,
      mcpResources: store.mcpResources,
      mcpStatuses: store.mcpStatuses)
  }

  private static func currentVisibleDefinitions(
    conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]],
    mcpStatuses: [UUID: EndpointConnectionState]
  ) -> [ToolDefinition] {
    ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
  }

  private static func shouldRetryHiddenOnlyFinal(
    _ response: String,
    state: State,
    maxRepairTurns: Int
  ) -> Bool {
    state.toolCallCount > 0
      && state.repairTurnCount < maxRepairTurns
      && !hasVisibleText(response)
  }

  private static func provisionalDisplayText(from response: String) -> String? {
    let rendered = MessageContentFilter.render(response)
    let visible = rendered.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !visible.isEmpty else { return nil }
    return response.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func hasVisibleText(_ response: String) -> Bool {
    !MessageContentFilter.render(response).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  private static func debugModelName(for conversation: Conversation, store: AppStore) -> String {
    if conversation.provider == .openAICompatible,
      conversation.modelID.isEmpty,
      let endpoint = OpenAICompatibleProvider.selectedEndpoint(
        for: conversation,
        settings: store.settings)
    {
      return endpoint.defaultModel
    }
    return conversation.modelID
  }

  private static func maxToolCallsPerTurn(store: AppStore) -> Int {
    maxToolCallsPerTurn(settings: store.settings)
  }

  private static func maxToolCallsPerTurn(settings: AppSettings) -> Int {
    AppSettings.clampedMaxToolCallsPerTurn(settings.maxToolCallsPerTurn)
  }

  private static func maxRepairTurnsPerTurn(store: AppStore) -> Int {
    maxRepairTurnsPerTurn(settings: store.settings)
  }

  private static func maxRepairTurnsPerTurn(settings: AppSettings) -> Int {
    min(4, maxToolCallsPerTurn(settings: settings) + 1)
  }

  private static func nativeToolCallingUnavailableReason(
    conversation: Conversation,
    settings: AppSettings,
    hasTools: Bool
  ) -> String? {
    guard settings.toolCallingMode == .native, hasTools else { return nil }
    guard !conversation.provider.supportsNativeToolCalling else { return nil }
    return
      "\(conversation.provider.displayName) uses pmai’s tool executor; using \(settings.toolCallingMode.textProtocolFallback(for: conversation.provider).displayName) text fallback."
  }

  private static func debugDefinition(
    _ definition: ToolDefinition
  ) -> ConversationDebugToolDefinition {
    ConversationDebugToolDefinition(
      name: definition.name,
      description: definition.description,
      parameters: definition.parameters.map {
        ConversationDebugToolParameter(
          name: $0.name,
          type: $0.type,
          description: $0.description,
          required: $0.required)
      },
      inputSchemaJSON: definition.inputSchemaJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty ? nil : definition.inputSchemaJSON)
  }

  private static func isSuccessfulToolResult(_ result: String) -> Bool {
    !isToolResultError(result)
  }

  private static func isToolResultError(_ result: String) -> Bool {
    let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized.hasPrefix("error:") || normalized.hasPrefix("error calling ")
  }

  private static func shouldEchoReasoningContent(
    conversationID: UUID,
    store: AppStore
  ) -> Bool {
    guard let conversation = store.conversation(withID: conversationID) else {
      return false
    }
    return OpenAICompatibleProvider.shouldEchoReasoningContent(
      conversation: conversation,
      settings: store.settings)
  }

  private static func shouldEchoReasoningContent(
    conversation: Conversation,
    settings: AppSettings
  ) -> Bool {
    OpenAICompatibleProvider.shouldEchoReasoningContent(
      conversation: conversation,
      settings: settings)
  }

  private static func updateLocalAssistantMessage(
    id: UUID,
    text: String,
    conversation: inout Conversation
  ) {
    guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else {
      return
    }
    conversation.messages[index].text = text
  }

  private static func userVisibleResponseText(from text: String) -> String {
    let visible = MessageContentFilter.render(text).visibleText
    return visible.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : visible
  }

  private static func combinedAssistantText(baseline: String, turnText: String) -> String {
    baseline.isEmpty ? turnText : "\(baseline)\n\n\(turnText)"
  }

  @discardableResult
  private static func replaceFirstOccurrence(
    of target: String,
    in text: inout String,
    with replacement: String
  ) -> Bool {
    guard !target.isEmpty, let range = text.range(of: target) else {
      return false
    }
    text.replaceSubrange(range, with: replacement)
    return true
  }
}
