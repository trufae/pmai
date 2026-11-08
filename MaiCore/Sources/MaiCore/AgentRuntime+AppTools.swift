import Foundation

extension AgentRuntime {
  public func appToolDefinitions(for request: AgentRequest) throws -> [ToolDefinition] {
    guard request.toolChoice != .none, request.limits.maxToolCalls > 0 else { return [] }
    let groups = availableToolGroups()
    return try visibleDefinitions(for: request).filter { definition in
      guard internetAccess.allows(definition, in: groups) else { return false }
      if case .tool(let name) = request.toolChoice { return definition.name == name }
      return true
    }
  }

  /// App requests use the same approval and argument validation path as model calls.
  public func callAppTool(
    _ call: ToolCall, request: AgentRequest, emit: @escaping AgentEventHandler
  ) async throws -> ToolResult {
    let definitions = try appToolDefinitions(for: request)
    guard definitions.contains(where: { $0.name == call.name }) else {
      return ToolResult(callID: call.id, text: "Tool unavailable: \(call.name)", isError: true)
    }
    let runID = UUID()
    let pid = await supervisor.register(runID: runID, parent: nil, agentID: request.agentID,
      displayName: "CLI XDC", task: call.name, depth: 0)
    let context = AgentEventContext(runID: runID, parentRunID: nil, agentID: request.agentID,
      depth: 0, pid: pid)
    let budget = RunBudget(limits: request.limits)
    do {
      let result = try await ContentRedactor.$current.withValue(
        contentRedactor(sessionID: request.sessionID ?? runID.uuidString)
      ) {
        try await execute(call, definitions: definitions, request: request,
          execution: ToolExecutionContext(run: context, modelTurn: 0), budget: budget, emit: emit)
      }
      await supervisor.complete(pid)
      return result
    } catch {
      await supervisor.complete(pid)
      throw error
    }
  }
}
