import Foundation

/// Decodes JSON calls and recovers only unambiguous schema-matching envelopes.
enum JSONToolCallParser {
  static func containsToolCallMarker(in text: String) -> Bool {
    let visible = MessageContentFilter.removingReasoningSections(
      from: ToolCallParsing.stripMarkdownFence(from: text)
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = ToolCallParsing.jsonObjects(in: visible)
    for candidate in candidates {
      guard let object = ToolCallParsing.jsonObject(from: candidate) else { continue }
      return strictToolCallObject(object) != nil || isNamelessToolCallObject(object)
    }
    return visible.contains("{")
      && ToolCallParsing.containsJSONKey(in: visible, keys: ["name", "tool", "function"])
      && ToolCallParsing.containsJSONKey(
        in: visible,
        keys: ["arguments", "args", "parameters", "params", "input"])
  }

  static func containsNonToolJSONToolLoopObject(
    in text: String,
    tools: [ToolDefinition]
  ) -> Bool {
    let visible = ToolCallParsing.stripMarkdownFence(
      from: MessageContentFilter.removingReasoningSections(from: text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let statusKeys = Set([
      "assistance", "assistant", "status", "progress", "message", "note", "thought",
    ])
    let toolLoopKeys = statusKeys.union([
      "search_results", "search_queries", "planned_searches", "research_plan",
    ])
    return ToolCallParsing.jsonObjects(in: visible).contains { rawBlock in
      guard let object = ToolCallParsing.jsonObject(from: rawBlock),
        parseJSONCallObject(object, rawBlock: rawBlock, tools: tools) == nil
      else { return false }
      let keys = Set(object.keys.map { $0.lowercased() })
      return !keys.isDisjoint(with: toolLoopKeys)
    }
  }

  static func parseCalls(in text: String, tools: [ToolDefinition]) -> [ParsedToolCall] {
    let visible = ToolCallParsing.stripMarkdownFence(
      from: MessageContentFilter.removingReasoningSections(from: text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    var calls: [ParsedToolCall] = []
    for rawBlock in ToolCallParsing.jsonObjects(in: visible) {
      guard let object = ToolCallParsing.jsonObject(from: rawBlock),
        let call = parseJSONCallObject(object, rawBlock: rawBlock, tools: tools)
      else { continue }
      calls.append(call)
    }
    return calls
  }

  private static func parseJSONCallObject(
    _ object: [String: Any],
    rawBlock: String,
    tools: [ToolDefinition]
  ) -> ParsedToolCall? {
    if let normalized = strictToolCallObject(object) {
      return ParsedToolCall(
        name: normalized.name,
        arguments: [:],
        argumentValues: AgentTooling.argumentValues(normalized.arguments),
        rawBlock: rawBlock)
    }
    if let recovered = recoverJSONToolCall(object, tools: tools) {
      return ParsedToolCall(
        name: recovered.name,
        arguments: [:],
        argumentValues: AgentTooling.argumentValues(recovered.arguments),
        rawBlock: rawBlock)
    }
    return nil
  }

  private static func recoverJSONToolCall(_ object: [String: Any], tools: [ToolDefinition])
    -> (name: String, arguments: [String: Any])?
  {
    guard !tools.isEmpty else { return nil }
    let resolver = AgentToolNameResolver(tools: tools)
    if let name = nonEmptyString(object["name"])
      ?? nonEmptyString(object["tool"])
      ?? nonEmptyString(object["function"]),
      let canonical = resolver.canonicalName(for: name),
      let tool = tools.first(where: { $0.name == canonical }),
      tool.parameters.filter(\.required).isEmpty
    {
      return (name, [:])
    }

    guard let arguments = explicitArgumentsObject(from: object),
      isNamelessToolCallObject(object)
    else { return nil }
    let candidates = tools.filter { toolCanAccept(arguments: arguments, tool: $0) }
    guard candidates.count == 1, let tool = candidates.first else { return nil }
    return (tool.name, arguments)
  }

  private static func strictToolCallObject(_ object: [String: Any])
    -> (name: String, arguments: [String: Any])?
  {
    if let function = object["function"] as? [String: Any],
      let name = nonEmptyString(function["name"]),
      let arguments = explicitArgumentsObject(from: function)
        ?? explicitArgumentsObject(from: object)
    {
      return (name, arguments)
    }
    if let name = nonEmptyString(object["name"])
      ?? nonEmptyString(object["tool"])
      ?? nonEmptyString(object["function"]),
      let arguments = explicitArgumentsObject(from: object)
    {
      return (name, arguments)
    }
    if let arguments = explicitArgumentsObject(from: object),
      let name = nonEmptyString(arguments["name"])
        ?? nonEmptyString(arguments["tool"])
        ?? nonEmptyString(arguments["function"])
    {
      return (name, ToolCallParsing.toolArguments(from: arguments))
    }
    return nil
  }

  private static func isNamelessToolCallObject(_ object: [String: Any]) -> Bool {
    guard explicitArgumentsObject(from: object) != nil else { return false }
    return nonEmptyString(object["name"]) == nil
      && nonEmptyString(object["tool"]) == nil
      && nonEmptyString(object["function"]) == nil
  }

  private static func toolCanAccept(arguments: [String: Any], tool: ToolDefinition) -> Bool {
    let parameterNames = Set(tool.parameters.map(\.name))
    guard arguments.keys.allSatisfy({ parameterNames.contains($0) }) else { return false }
    return tool.parameters.filter(\.required).allSatisfy { parameter in
      argumentIsPresent(arguments[parameter.name])
    }
  }

  private static func argumentIsPresent(_ value: Any?) -> Bool {
    switch value {
    case nil:
      return false
    case let string as String:
      return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case is NSNull:
      return false
    default:
      return true
    }
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func explicitArgumentsObject(from object: [String: Any]) -> [String: Any]? {
    for key in ["arguments", "args", "parameters", "params", "input"]
    where object.keys.contains(key) {
      if let argumentObject = object[key] as? [String: Any] {
        return argumentObject
      }
      if let string = object[key] as? String,
        let data = string.data(using: .utf8),
        let argumentObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        return argumentObject
      }
    }
    return nil
  }
}
