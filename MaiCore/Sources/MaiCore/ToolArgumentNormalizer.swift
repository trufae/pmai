import Foundation

/// Resolves tool names and normalizes arguments against the selected definition.
extension AgentTooling {
  public static func normalizeArguments(
    _ arguments: [String: AgentToolArgumentValue],
    for tool: ToolDefinition?
  ) -> [String: AgentToolArgumentValue] {
    let repaired =
      tool.flatMap {
        ToolSchemaValidator.repairArgumentKeys(.object(arguments), definition: $0).objectValue
      } ?? arguments
    // Do not let the legacy alias normalizer discard a failed repair and
    // silently choose one of two conflicting values in a proxied call.
    if let tool,
      repaired.keys.contains(where: { key in
        (key.isEmpty || key.contains("=")) && !tool.parameters.contains(where: { $0.name == key })
      })
    {
      return repaired
    }
    let normalized = normalizeValues(repaired, for: tool)
    guard let tool,
      tool.parameters.filter(\.required).count == 1,
      let requiredName = tool.parameters.first(where: \.required)?.name,
      normalized[requiredName] == nil,
      normalized.count == 1,
      let value = normalized.values.first
    else { return normalized }
    return [requiredName: value]
  }

  public static func normalizeArguments(_ arguments: [String: String], for tool: ToolDefinition?)
    -> [String: String]
  {
    normalizeArguments(arguments.mapValues { .string($0) }, for: tool)
      .mapValues(\.coercedStringValue)
  }

  /// Resolves provider aliases and coerces arguments according to the matching schema.
  public static func normalized(
    call: ParsedToolCall,
    tools: [ToolDefinition]
  ) -> ParsedToolCall {
    let resolver = AgentToolNameResolver(tools: tools)
    let canonicalName = resolver.canonicalName(for: call.name) ?? call.name
    let definition = definition(named: canonicalName, in: tools)
    return ParsedToolCall(
      name: canonicalName,
      arguments: [:],
      argumentValues: normalizeArguments(call.argumentValues, for: definition),
      rawBlock: call.rawBlock,
      toolCallID: call.toolCallID,
      apiName: call.apiName)
  }

  /// Normalizes a provider-facing call and returns it only when the host exposes that tool.
  public static func availableCall(
    _ call: ParsedToolCall,
    tools: [ToolDefinition]
  ) -> ParsedToolCall? {
    let call = normalized(call: call, tools: tools)
    return containsDefinition(named: call.name, in: tools) ? call : nil
  }

  public static func definition(
    named name: String,
    in tools: [ToolDefinition]
  ) -> ToolDefinition? {
    tools.first { $0.name == name }
  }

  public static func containsDefinition(
    named name: String,
    in tools: [ToolDefinition]
  ) -> Bool {
    definition(named: name, in: tools) != nil
  }

  /// Returns the host-facing validation message used before an approved call executes.
  public static func requiredArgumentsError(
    call: ParsedToolCall,
    tools: [ToolDefinition]
  ) -> String? {
    guard let definition = definition(named: call.name, in: tools) else { return nil }
    let missing = definition.parameters
      .filter(\.required)
      .filter { requiredArgumentIsMissing(call.argumentValues[$0.name]) }
      .map(\.name)
    guard !missing.isEmpty else { return nil }
    let names = missing.map { "'\($0)'" }.joined(separator: ", ")
    let noun = missing.count == 1 ? "argument" : "arguments"
    return "Error: missing required \(noun) \(names) for tool '\(call.name)'."
  }

  private static func requiredArgumentIsMissing(_ value: AgentToolArgumentValue?) -> Bool {
    guard let value else { return true }
    if case .string(let string) = value {
      return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return value == .null
  }

  public static func parameters(fromSchemaJSON schemaJSON: String) -> [ToolParameterDef] {
    guard let data = schemaJSON.data(using: .utf8),
      let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let properties = schema["properties"] as? [String: Any]
    else { return [] }
    let required = Set(schema["required"] as? [String] ?? [])
    return properties.keys.sorted().map { name in
      let property = properties[name] as? [String: Any] ?? [:]
      return ToolParameterDef(
        name: name,
        type: (property["type"] as? String) ?? "string",
        description: (property["description"] as? String) ?? "",
        required: required.contains(name))
    }
  }

  private static func normalizeValues(
    _ arguments: [String: AgentToolArgumentValue],
    for tool: ToolDefinition?
  ) -> [String: AgentToolArgumentValue] {
    guard let tool else {
      return arguments.filter { $0.value != .null }
    }
    let parameterByName = Dictionary(uniqueKeysWithValues: tool.parameters.map { ($0.name, $0) })
    var result: [String: AgentToolArgumentValue] = [:]
    var unknown: [String: AgentToolArgumentValue] = [:]
    for (name, value) in arguments {
      guard let parameter = parameterByName[name] else {
        if case .null = value { continue }
        unknown[name] = value
        continue
      }
      guard let normalized = normalizeValue(value, for: parameter) else {
        continue
      }
      if !parameter.required, isDefaultOptionalValue(normalized, for: parameter) {
        continue
      }
      result[name] = normalized
    }
    if result["query"] == nil,
      let queryParameter = parameterByName["query"],
      let q = unknown["q"],
      let normalized = normalizeValue(q, for: queryParameter)
    {
      result["query"] = normalized
    }
    if result["location"] == nil,
      let locationParameter = parameterByName["location"],
      let alias = firstLocationAlias(
        in: unknown,
        hasQueryParameter: parameterByName["query"] != nil),
      let normalized = normalizeValue(alias, for: locationParameter)
    {
      result["location"] = normalized
    }
    if result.isEmpty,
      tool.parameters.filter(\.required).count == 1,
      let required = tool.parameters.first(where: \.required),
      unknown.count == 1,
      let value = unknown.values.first,
      let normalized = normalizeValue(value, for: required)
    {
      result[required.name] = normalized
    }
    return result
  }

  private static func firstLocationAlias(
    in arguments: [String: AgentToolArgumentValue],
    hasQueryParameter: Bool
  ) -> AgentToolArgumentValue? {
    for name in ["city", "place", "where"] {
      if let value = arguments[name] { return value }
    }
    guard !hasQueryParameter else { return nil }
    return arguments["query"] ?? arguments["q"]
  }

  private static func normalizeValue(
    _ value: AgentToolArgumentValue,
    for parameter: ToolParameterDef
  ) -> AgentToolArgumentValue? {
    if case .null = value { return nil }
    switch parameter.type.lowercased() {
    case "integer", "int":
      if case .integer = value { return value }
      if let integer = value.stringValue.flatMap({
        Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
      })
        ?? value.coercedNumberValue.flatMap({ Int(exactly: $0) })
      {
        return .integer(integer)
      }
      return parameter.required ? value : nil
    case "number":
      if case .integer = value { return value }
      if let number = value.coercedNumberValue, number.isFinite {
        return Int(exactly: number).map(AgentToolArgumentValue.integer) ?? .number(number)
      }
      return parameter.required ? value : nil
    case "boolean", "bool":
      return value.coercedBoolValue.map(AgentToolArgumentValue.bool) ?? value
    case "string":
      if case .string = value { return value }
      return parameter.required ? .string(value.coercedStringValue) : nil
    default:
      return value
    }
  }

  private static func isDefaultOptionalValue(
    _ value: AgentToolArgumentValue,
    for parameter: ToolParameterDef
  ) -> Bool {
    switch value {
    case .string(let string):
      return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .bool(let bool):
      // False is only a default when the description says so: `wait` on
      // `agent_start` defaults to true, and dropping its false made every
      // start block.
      guard !bool else { return false }
      let description = parameter.description.lowercased()
      return description.contains("default: false") || description.contains("default false")
        || description.contains("defaults to false")
    case .integer(let int):
      let description = parameter.description.lowercased()
      return description.contains("default: \(int)") || description.contains("default \(int)")
    case .number(let double):
      let description = parameter.description.lowercased()
      return description.contains("default: \(double)") || description.contains("default \(double)")
    default:
      return false
    }
  }
}
