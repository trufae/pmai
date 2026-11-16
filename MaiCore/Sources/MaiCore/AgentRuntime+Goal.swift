import Foundation

extension AgentRuntime {
  static let goalReviewName = "goal_review"
  static let goalReviewDefinition = ToolDefinition(
    name: goalReviewName,
    description: "Record your review of the current goal. Call by itself after inspecting results. Continue with a concrete next step, complete with verification evidence, or blocked with the external input needed.",
    parameters: [
      ToolParameterDef(name: "status", type: "string", description: "continue, complete, or blocked", required: true),
      ToolParameterDef(name: "summary", type: "string", description: "Review outcome; when complete, the final answer with any requested deliverable or artifact links", required: true),
      ToolParameterDef(name: "evidence", type: "string", description: "Observed results, checks and relevant locations supporting the decision", required: true),
      ToolParameterDef(name: "next", type: "string", description: "Concrete next action or missing external input; empty only when complete", required: true),
    ],
    annotations: ToolAnnotations(readOnly: false, destructive: false, idempotent: false,
      openWorld: false, approval: .automatic))

  public func validateGoal(_ request: AgentRequest) throws {
    guard let goal = request.goal, goal.isActive else { return }
    let reason: String?
    if goal.objective.isEmpty {
      reason = "A goal needs a non-empty objective."
    } else if !toolsEnabled || request.toolCallingStrategy == .off || request.toolChoice != .automatic {
      reason = "Goals require tools enabled and automatic tool choice."
    } else if providers[request.provider]?.descriptor.capabilities.contains(.managedToolLoop) == true {
      reason = "Goals require a chat provider whose tools pmai runs. This provider manages its own tool loop."
    } else {
      reason = nil
    }
    if let reason { throw AgentToolError.invalidArguments(tool: "/goal", reason: reason) }
  }

  /// Reviews are runtime control messages, kept separate from concurrent work.
  /// A mixed batch is rejected in full so a decision cannot race a file write.
  func reviewGoal(_ calls: [ToolCall], state: inout RunState) async throws -> Bool {
    guard state.goal?.isActive == true else { return false }
    let reviews = calls.map { call -> ToolCall in
      if state.request.usesToolProxy, call.name == ToolProxy.callName,
        let target = ToolProxy.resolveCall(arguments: call.arguments.objectValue ?? [:],
          definitions: [Self.goalReviewDefinition]).call {
        return ToolCall(id: call.id, name: target.name, arguments: .object(target.argumentValues))
      }
      return call
    }
    guard reviews.contains(where: { $0.name == Self.goalReviewName }) else { return false }
    for var call in reviews {
      try Task.checkCancellation()
      if let redactor = ContentRedactor.current { call.arguments = redactor.unredact(call.arguments) }
      await state.emit(.toolStarted(state.context, call))
      let hasBudget = await budgetAllowsGoalReview(state)
      if hasBudget { state.toolCalls += 1 }
      var error: String?
      let args = call.arguments.objectValue ?? [:]
      let status = args["status"]?.stringValue ?? ""
      let summary = (args["summary"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let evidence = (args["evidence"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let next = (args["next"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if reviews.count != 1 {
        error = "Call goal_review alone, after collecting and inspecting all work. This batch was not executed."
      } else if !toolsEnabled || state.request.toolCallingStrategy == .off {
        error = "Tools are disabled."
      } else if !hasBudget {
        error = "The run's tool or time budget is exhausted."
      } else if let invalid = ToolSchemaValidator.validate(arguments: call.arguments, definition: Self.goalReviewDefinition) {
        error = invalid
      } else if !["continue", "complete", "blocked"].contains(status) || summary.isEmpty || evidence.isEmpty
        || (status != "complete" && next.isEmpty) {
        error = "Provide status (continue, complete, blocked), a non-empty summary and evidence, and a next action unless complete."
      } else if await supervisor.tree().subtree(of: state.pid).contains(where: { $0.pid != state.pid && !$0.state.isTerminal }) {
        error = "Collect or stop outstanding children before reviewing the goal."
      } else if await supervisor.queuedMessages(for: state.pid).contains(where: {
        !state.request.ignoredQueuedMessageIDs.contains($0.id)
      }) {
        error = "New input is waiting. Incorporate it before reviewing the goal."
      }
      let result: ToolResult
      if let error {
        result = ToolResult(callID: call.id, text: "Error: \(error)", isError: true)
      } else if var goal = state.goal {
        goal.iterations += 1
        state.goalReviews += 1
        goal.summary = summary
        goal.evidence = evidence
        goal.nextStep = next
        goal.status = status == "complete" ? .complete : status == "blocked" ? .blocked : .active
        if goal.isActive, state.goalReviews >= max(1, min(100, goal.maxIterations)) {
          goal.status = .paused
          goal.summary += "\nGoal review limit reached; /goal resume grants another review allowance."
        }
        state.goal = goal
        state.goalNeedsReview = false
        liveRequests[state.pid]?.goal = goal
        result = ToolResult(callID: call.id, text: goal.report)
      } else {
        return false
      }
      state.transcript.append(AgentMessage(role: .tool, content: [.toolResult(result)]))
      await state.emit(.toolFinished(state.context, result))
    }
    await supervisor.note(state.pid, toolCalls: state.toolCalls, transcript: state.transcript)
    return true
  }

  private func budgetAllowsGoalReview(_ state: RunState) async -> Bool {
    guard !(await state.budget.deadlinePassed) else { return false }
    return await state.budget.allowsToolCall(used: state.toolCalls)
  }
}
