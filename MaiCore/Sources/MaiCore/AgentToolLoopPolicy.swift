import Foundation

/// A stable identity for a normalized tool call within one agent run.
public struct ToolCallKey: Hashable, Sendable {
  public let name: String
  public let argumentsJSON: String

  public init(name: String, argumentsJSON: String) {
    self.name = name
    self.argumentsJSON = argumentsJSON
  }

  public init(_ call: ParsedToolCall) {
    self.init(name: call.name, argumentsJSON: call.argsJSON)
  }

  public init(_ call: ToolCall) {
    self.init(name: call.name, argumentsJSON: call.arguments.compactJSONString)
  }
}

/// The provider-neutral result of inspecting one model response in a tool loop.
public enum AgentToolLoopDecision: Sendable {
  case final(String)
  case repair(String)
  case execute([ParsedToolCall])
}

/// Shared policy for parsing textual tool calls and deciding how an agent loop continues.
public enum AgentToolLoopPolicy {
  public static let responseToolName = "respond"

  public static let responseToolDefinition = ToolDefinition(
    name: responseToolName,
    description:
      "Optionally return the user-visible response in tool-call form when no more host tool runs are needed.",
    parameters: [
      ToolParameterDef(
        name: "action",
        type: "string",
        description: "One of final, ask_user, or no_solution.",
        required: true),
      ToolParameterDef(
        name: "content",
        type: "string",
        description: "The user-visible response text.",
        required: true),
    ],
    inputSchemaJSON: """
      {"type":"object","properties":{"action":{"type":"string","enum":["final","ask_user","no_solution"],"description":"One of final, ask_user, or no_solution."},"content":{"type":"string","description":"The user-visible response text."}},"required":["action","content"]}
      """)

  public static func definitions(includingResponseTool definitions: [ToolDefinition])
    -> [ToolDefinition]
  {
    definitions.isEmpty ? [] : definitions + [responseToolDefinition]
  }

  public static func repairFeedbackAfterToolResult(mode: ToolCallingMode) -> String {
    AgentTooling.makeRunBlock(
      toolName: "missing_tool_call",
      argumentsJSON: "{}",
      result: missingPostToolActionMessage(mode: mode)
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Inspects a model turn without executing host tools. Frontends can provide a filtered
  /// `actionableResponse` and `visibleText` while preserving `response` for display/history.
  public static func evaluate(
    response: String,
    actionableResponse: String? = nil,
    visibleText: String? = nil,
    tools: [ToolDefinition],
    mode: ToolCallingMode,
    hasToolResults: Bool = false,
    remainingToolCalls: Int
  ) -> AgentToolLoopDecision {
    guard !tools.isEmpty else { return .final(response) }
    let parseTools = definitions(includingResponseTool: tools)
    let actionable =
      actionableResponse ?? MessageContentFilter.removingReasoningSections(from: response)
    let calls = AgentTooling.parseCalls(in: actionable, tools: parseTools, mode: mode)

    guard !calls.isEmpty else {
      if AgentTooling.containsToolCallMarker(in: actionable, mode: mode) {
        return .repair(
          AgentTooling.malformedToolCallFeedback(
            from: actionable, mode: mode, tools: parseTools
          ).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      if AgentTooling.containsNonToolJSONToolLoopObject(in: actionable, tools: parseTools) {
        return .repair(
          AgentTooling.nonToolJSONToolLoopFeedback(
            from: actionable, mode: mode, tools: parseTools
          ).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      let visible = visibleText ?? MessageContentFilter.render(actionable).visibleText
      if hasToolResults,
        visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        remainingToolCalls > 0
      {
        return .repair(repairFeedbackAfterToolResult(mode: mode))
      }
      return .final(response)
    }

    let normalizedCalls = calls.map { AgentTooling.normalized(call: $0, tools: parseTools) }
    if normalizedCalls.contains(where: { $0.name == responseToolName }) {
      return responseDecision(calls: normalizedCalls, mode: mode)
    }
    // A repeated read may observe a file changed by an intervening write.
    // Let the runtime's bounded repeat guard handle loops in every protocol;
    // a previous tool result is never a substitute for the assistant's answer.
    return remainingToolCalls > 0 ? .execute(normalizedCalls) : .final(response)
  }

  private static func responseDecision(
    calls: [ParsedToolCall],
    mode: ToolCallingMode
  ) -> AgentToolLoopDecision {
    guard calls.count == 1, let call = calls.first else {
      return .repair(
        invalidResponseToolFeedback(
          mode: mode,
          message: "Error: respond must be the only tool call in this assistant turn."))
    }
    let action = call.argumentValues["action"]?.stringValue ?? ""
    guard ["final", "ask_user", "no_solution"].contains(normalizedAction(action)) else {
      return .repair(
        invalidResponseToolFeedback(
          mode: mode,
          message: "Error: respond action must be one of final, ask_user, or no_solution."))
    }
    let content = (call.argumentValues["content"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { return .repair(emptyResponseToolFeedback(mode: mode)) }
    return .final(content)
  }

  private static func normalizedAction(_ action: String) -> String {
    action.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")
  }

  private static func emptyResponseToolFeedback(mode: ToolCallingMode) -> String {
    AgentTooling.makeRunBlock(
      toolName: "invalid_respond",
      argumentsJSON: "{}",
      result:
        "Error: respond content is empty. Emit a host tool call if another host tool run is needed, or call respond with non-empty user-visible content."
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func invalidResponseToolFeedback(
    mode: ToolCallingMode,
    message: String
  ) -> String {
    AgentTooling.makeRunBlock(
      toolName: "invalid_respond",
      argumentsJSON: "{}",
      result: "\(message)\n\n\(missingPostToolActionMessage(mode: mode))"
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func missingPostToolActionMessage(mode: ToolCallingMode) -> String {
    if mode == .native {
      return
        "After a host tool result, call one provided native tool if another host tool run is needed, or give the final answer directly if the result is enough. Do not write prose that announces a future tool call."
    }
    return """
      After a host tool result, give the final answer directly if the result is enough.

      If another host tool run is needed, emit exactly one tool call in the configured \(mode.displayName) format. You may also call \(responseToolName) with final content:
      \(responseToolExample(mode: mode))
      """
  }

  private static func responseToolExample(mode: ToolCallingMode) -> String {
    AgentTooling.editableToolCallText(
      for: ParsedToolCall(
        name: responseToolName,
        arguments: [
          "action": "final",
          "content": "The user-visible answer goes here.",
        ],
        rawBlock: ""),
      mode: mode)
  }
}
