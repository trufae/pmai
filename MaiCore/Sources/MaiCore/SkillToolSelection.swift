import Foundation

/// A skill proposal and the enabled alternatives offered by the host. Selecting
/// another skill preserves the call ID, task arguments and proxy envelope.
public struct SkillToolSelection: Sendable {
  public let proposed: ParsedToolCall
  public let skills: [ToolDefinition]
  private let original: ParsedToolCall

  public init?(call: ParsedToolCall, definitions: [ToolDefinition]) {
    let resolved =
      call.name == ToolProxy.callName
      ? ToolProxy.resolveCall(arguments: call.argumentValues, definitions: definitions).call
      : AgentTooling.availableCall(call, tools: definitions)
    guard let resolved, MaiSkillTools.isSkillTool(resolved.name) else { return nil }
    original = call
    proposed = resolved
    skills = definitions.filter { MaiSkillTools.isSkillTool($0.name) }
  }

  public func selecting(_ name: String) -> ParsedToolCall? {
    guard skills.contains(where: { $0.name == name }) else { return nil }
    return ParsedToolCall(
      name: original.name == ToolProxy.callName ? ToolProxy.callName : name,
      arguments: [:],
      argumentValues: original.name == ToolProxy.callName
        ? ["name": .string(name), "arguments": .object(proposed.argumentValues)]
        : proposed.argumentValues,
      rawBlock: original.rawBlock,
      toolCallID: original.toolCallID)
  }
}
