import Foundation

/// Builds protocol instructions, examples, and corrective feedback.
extension AgentTooling {
  public static func promptDescription(
    for definitions: [ToolDefinition],
    mode: ToolCallingMode = .text
  ) -> String {
    guard !definitions.isEmpty else { return "" }
    let resolver = AgentToolNameResolver(tools: definitions)
    let toolDescriptions = definitions.map { def -> String in
      let params: String
      if def.parameters.isEmpty {
        params = "no arguments"
      } else {
        let required = def.parameters.filter(\.required)
        let optional = def.parameters.filter { !$0.required }
        let requiredText =
          required.isEmpty
          ? "no required arguments"
          : required.map { p in
            "\(p.name) (\(p.type)): \(p.description)"
          }.joined(separator: "; ")
        let optionalText =
          optional.isEmpty
          ? ""
          : " Optional arguments, omit unless necessary: "
            + optional.map { p in
              "\(p.name) (\(p.type)): \(p.description)"
            }.joined(separator: "; ")
        params = requiredText + optionalText
      }
      let api = resolver.apiName(for: def.name)
      let name = api == def.name ? def.name : "\(def.name) (API/native alias: \(api))"
      return "- \(name): \(def.description) Arguments: \(params)."
    }.joined(separator: "\n")
    let toolCalling = promptInstructions(for: mode, tools: definitions)

    return """
      ## Available Tools

      \(toolDescriptions)

      ## Tool Calling

      \(toolCalling)

      After a `<tool_run>`, decide if the result is enough. If it is enough, give the final answer. If another missing fact remains, emit one more tool call in the next reply. You may call the same tool again with different arguments, but never repeat a tool call with identical arguments.
      """
  }

  private static func promptInstructions(
    for mode: ToolCallingMode,
    tools: [ToolDefinition] = []
  ) -> String {
    let examples = toolCallExamples(for: mode, text: "", tools: tools)
      .joined(separator: "\n\n")
    switch mode {
    case .text, .native:
      return """
        Use a tool whenever the user asks for current, external, searched, fetched, calculated, or tool-only information. Do not answer from memory when a listed tool can get the needed information.

        When a tool is needed, reply with exactly one plain text block and no other text. This limit is per assistant reply: after the host returns a result, you may emit one more tool call in the next reply if needed. Examples:
        \(examples)

        Use only listed tool names or aliases. Put one argument per line as `argument_name: value`. Include required arguments, omit unused optional arguments, use true/false for booleans, and stop after the block.
        """
    case .xml:
      return """
        Use a tool whenever the user asks for current, external, searched, fetched, calculated, or tool-only information. Do not answer from memory when a listed tool can get the needed information.

        When a tool is needed, reply with exactly one XML block and no other text. This limit is per assistant reply: after the host returns a result, you may emit one more tool call in the next reply if needed. Examples:
        \(examples)

        Use only listed tool names or aliases. Include required arguments, omit unused optional arguments, escape XML special characters, and stop after the block.
        """
    case .json:
      return """
        Use a tool whenever the user asks for current, external, searched, fetched, calculated, or tool-only information. Do not answer from memory when a listed tool can get the needed information.

        When a tool is needed, reply with exactly one JSON object and no other text. This limit is per assistant reply: after the host returns a result, you may emit one more tool call in the next reply if needed. Examples:
        \(examples)

        Use only listed tool names or aliases. Include required arguments, omit unused optional arguments, keep JSON valid, and stop after the JSON object.
        """
    }
  }

  public static func malformedToolCallFeedback(
    from text: String,
    mode: ToolCallingMode = .text,
    tools: [ToolDefinition] = []
  ) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.count > 500 ? String(trimmed.prefix(500)) + "..." : trimmed
    let example = toolCallExample(for: mode, text: text, tools: tools)
    return """
      <tool_run>
      invalid_tool_call tool ({}):
      Error: the assistant emitted a tool call marker, but the host could not parse an executable tool call.

      Received:
      \(preview)

      Emit exactly one valid tool call in the configured \(mode.displayName) format for the same intended tool call:
      \(example)
      </tool_run>
      """
  }

  public static func nonToolJSONToolLoopFeedback(
    from text: String,
    mode: ToolCallingMode = .text,
    tools: [ToolDefinition] = []
  ) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.count > 500 ? String(trimmed.prefix(500)) + "..." : trimmed
    let example = toolCallExample(for: mode, text: text, tools: tools)
    return """
      <tool_run>
      invalid_assistant_tool_loop_json tool ({}):
      Error: the assistant emitted status, planning, or result JSON instead of a tool call or final answer.

      Received:
      \(preview)

      JSON objects are only for executable tool calls in this chat. Do not emit status JSON like {"assistance":"..."} or pretend search result JSON like {"search_results":[...]}.
      Continue the tool loop. If no tool has run yet, or if more information is needed, emit exactly one valid tool call:
      \(example)

      If the available tool results are enough, write the final answer in normal text/Markdown, not JSON.
      </tool_run>
      """
  }

  private static func toolCallExample(
    for mode: ToolCallingMode,
    text: String,
    tools: [ToolDefinition]
  ) -> String {
    let resolver = AgentToolNameResolver(tools: tools)
    let tool = exampleTool(matching: text, tools: tools)
    return toolCallExample(for: mode, tool: tool, resolver: resolver)
  }

  private static func toolCallExamples(
    for mode: ToolCallingMode,
    text: String,
    tools: [ToolDefinition]
  ) -> [String] {
    let resolver = AgentToolNameResolver(tools: tools)
    let candidates = exampleToolCandidates(matching: text, tools: tools)
    guard !candidates.isEmpty else {
      return [toolCallExample(for: mode, tool: nil, resolver: resolver)]
    }
    return candidates.map { toolCallExample(for: mode, tool: $0, resolver: resolver) }
  }

  private static func toolCallExample(
    for mode: ToolCallingMode,
    tool: ToolDefinition?,
    resolver: AgentToolNameResolver
  ) -> String {
    let name = tool.map { resolver.apiName(for: $0.name) } ?? "tool_name"
    let arguments = tool.map { exampleArguments(for: $0) } ?? [:]

    switch mode {
    case .text, .native:
      var lines = ["TOOL_CALL", "tool: \(name)"]
      if let tool {
        for parameter in tool.parameters where parameter.required {
          let value = arguments[parameter.name]?.stringValue ?? "value"
          lines.append("\(parameter.name): \(value)")
        }
      }
      lines.append("END_TOOL_CALL")
      return lines.joined(separator: "\n")
    case .xml:
      guard let tool, !arguments.isEmpty else {
        return #"<tool_call name="\#(xmlEscapedAttribute(name))"></tool_call>"#
      }
      let body = tool.parameters
        .filter(\.required)
        .map { parameter in
          let value = arguments[parameter.name]?.stringValue ?? "value"
          return
            #"<arg name="\#(xmlEscapedAttribute(parameter.name))">\#(xmlEscapedAttribute(value))</arg>"#
        }
        .joined(separator: "\n")
      return """
        <tool_call name="\(xmlEscapedAttribute(name))">
        \(body)
        </tool_call>
        """
    case .json:
      return toolCallObjectJSON(name: name, arguments: arguments)
    }
  }

  private static func exampleToolCandidates(
    matching text: String,
    tools: [ToolDefinition]
  ) -> [ToolDefinition] {
    guard let primary = exampleTool(matching: text, tools: tools) else { return [] }
    let primaryHasRequiredArguments = primary.parameters.contains { $0.required }
    let secondary = tools.first { tool in
      guard tool.name != primary.name else { return false }
      let hasRequiredArguments = tool.parameters.contains { $0.required }
      return primaryHasRequiredArguments ? !hasRequiredArguments : hasRequiredArguments
    }
    return secondary.map { [primary, $0] } ?? [primary]
  }

  private static func exampleTool(
    matching text: String,
    tools: [ToolDefinition]
  ) -> ToolDefinition? {
    guard !tools.isEmpty else { return nil }
    let resolver = AgentToolNameResolver(tools: tools)
    let haystack = text.lowercased()
    if !haystack.isEmpty {
      for tool in tools {
        let candidates = [
          tool.name,
          resolver.apiName(for: tool.name),
          tool.name.replacingOccurrences(of: "::", with: "."),
          tool.name.replacingOccurrences(of: "::", with: "_"),
          tool.name.replacingOccurrences(of: "::", with: "__"),
        ]
        if candidates.contains(where: { candidate in
          !candidate.isEmpty && haystack.contains(candidate.lowercased())
        }) {
          return tool
        }
      }
    }
    return tools.first { tool in
      tool.parameters.allSatisfy { !$0.required }
    } ?? tools.first
  }

  private static func exampleArguments(
    for tool: ToolDefinition
  ) -> [String: AgentToolArgumentValue] {
    Dictionary(
      uniqueKeysWithValues: tool.parameters
        .filter(\.required)
        .map { ($0.name, exampleArgumentValue(for: $0)) })
  }

  private static func exampleArgumentValue(
    for parameter: ToolParameterDef
  ) -> AgentToolArgumentValue {
    switch parameter.type.lowercased() {
    case "bool", "boolean":
      return .bool(true)
    case "int", "integer":
      return .integer(1)
    case "number", "float", "double":
      return .number(1)
    case "array", "list":
      return .array([])
    case "object", "dictionary", "map":
      return .object([:])
    default:
      return .string("value")
    }
  }

  public static func unavailableToolError(name: String) -> String {
    "Error: tool '\(name)' is not available. It may be unknown or disabled for this conversation."
  }

  /// Suggest an enabled tool and its fields without guessing which call to execute.
  static func unavailableToolError(name: String, tools: [ToolDefinition]) -> String {
    let preview =
      name.prefix(120).replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t")
      + (name.count > 120 ? "…" : "")
    var message = "Error: tool '\(preview)' is not available to this agent."
    guard !tools.isEmpty else { return message }
    let resolver = AgentToolNameResolver(tools: tools)
    let requested = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let related = tools.filter { tool in
      [tool.name, resolver.apiName(for: tool.name)].contains { candidate in
        let candidate = candidate.lowercased()
        return requested.hasPrefix(candidate + "_") || requested.hasPrefix(candidate + "<")
      }
    }.sorted { $0.name.count > $1.name.count }
    message += " Retry with an exact tool name; keep reasoning and arguments out of the name."
    if related.isEmpty {
      message +=
        " Enabled tools: " + tools.prefix(8).map(\.name).joined(separator: ", ")
        + (tools.count > 8 ? ", …" : "") + "."
    } else {
      let hints = related.prefix(3).map { tool in
        let fields = tool.parameters.prefix(12).map {
          "\($0.name) (\($0.type)\($0.required ? ", required" : ""))"
        }.joined(separator: ", ")
        return "\(tool.name): \(fields.isEmpty ? "no arguments" : fields)"
      }
      message += " Related enabled tools and JSON fields: " + hints.joined(separator: "; ") + "."
    }
    return message
  }
}
