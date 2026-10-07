import Foundation

extension AgentRuntime {
  func interpretResponse(
    _ call: ProviderCall, turn: ModelTurn, state: inout RunState
  ) async throws -> ProviderResponse? {
    var providerResponse = call.response
    try Task.checkCancellation()
    if state.request.context == .tools { state.toolContext.didRead(state.transcript) }
    await recordModelCall(
      call, provider: turn.provider.descriptor.id, request: turn.request,
      userMessages: state.modelTurns == 1 ? state.request.messages : nil)
    let usage = call.usage(for: turn.request.messages)
    state.totalUsage = state.totalUsage.merging(usage)
    // Reduced context usage does not describe the full saved transcript.
    state.lastUsage =
      state.request.context == .smart || state.request.context == .tools || turn.deciding
      ? nil : providerResponse.usage
    state.lastUsageMessageCount = state.transcript.count + 1
    await supervisor.note(state.pid, usage: state.totalUsage)
    await state.budget.record(tokens: usage.totalTokens)

    if turn.deciding {
      guard let decision = providerResponse.toolDecision else {
        throw AgentRuntimeError.systemOneConfiguration("System One returned no tool decision.")
      }
      switch decision {
      case .none: break
      case .tool(let name) where turn.definitions.contains(where: { $0.name == name }): break
      default:
        throw AgentRuntimeError.systemOneConfiguration("System One returned an unavailable tool.")
      }
      state.pendingDecision = decision
      return nil
    }

    // A server such as Ollama parses the model's own function-call syntax
    // into native tool calls even when the request offered no tools. Those
    // calls are as good as a text block and run below; reading only the text
    // would mistake the turn for one without a call and repeat the repair
    // feedback until the turn limit.
    // The text protocols offer a `respond` pseudo-tool; a server may hand it
    // back as a native call. It is the final answer, not a host tool.
    if turn.textToolMode != nil, providerResponse.message.toolCalls.count == 1,
      let respond = providerResponse.message.toolCalls.first,
      respond.name == AgentToolLoopPolicy.responseToolName
    {
      let content = respond.arguments.objectValue?["content"]?.coercedStringValue ?? ""
      providerResponse.message = .assistant(content)
      providerResponse.stopReason = .stop
      if !content.isEmpty && !turn.selectingTools {
        await state.emit(.provider(state.context, .textDelta(content)))
      }
    }
    if let textToolMode = turn.textToolMode, !turn.toolBudgetExhausted,
      providerResponse.message.toolCalls.isEmpty
    {
      let decision = AgentToolLoopPolicy.evaluate(
        response: providerResponse.message.text,
        tools: turn.definitions,
        mode: textToolMode,
        hasToolResults: state.toolCalls > 0,
        remainingToolCalls: state.request.limits.maxToolCalls - state.toolCalls)
      switch decision {
      case .final(let text):
        if text != providerResponse.message.text {
          providerResponse.message = replacingText(in: providerResponse.message, with: text)
        }
        if !text.isEmpty && !turn.selectingTools {
          await state.emit(.provider(state.context, .textDelta(text)))
        }
      case .repair(let feedback):
        state.recordRepair(feedback)
        await supervisor.note(state.pid, transcript: state.transcript)
        return nil
      case .execute(let parsedCalls):
        let calls = parsedCalls.map(toolCall)
        providerResponse.message.content =
          providerResponse.message.content.filter {
            if case .reasoning = $0 { return true }
            return false
          } + calls.map(ContentPart.toolCall)
        providerResponse.stopReason = .toolCall
        for (index, call) in calls.enumerated() {
          await state.emit(
            .provider(
              state.context,
              .toolCallDelta(
                ToolCallDelta(
                  index: index,
                  id: call.id,
                  name: call.name,
                  argumentsFragment: call.arguments.compactJSONString))))
        }
      }
    }
    state.consecutiveRepairs = 0
    if turn.selectingTools && providerResponse.message.toolCalls.isEmpty {
      // The specialist's stop decision hands the tool results to the primary
      // model. Its draft is not promoted to a user-visible final answer.
      state.usingPrimary = true
      return nil
    }
    state.transcript.append(providerResponse.message)
    await supervisor.note(
      state.pid, transcript: state.transcript,
      contextSize: AgentContextSize(messages: state.contextMessages))
    return providerResponse
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
