import Foundation

/// Coordinates format fallback without merging calls from different protocols.
public enum AgentTooling {
  public static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  public static func parseCalls(
    in text: String,
    tools: [ToolDefinition],
    mode: ToolCallingMode = .text
  ) -> [ParsedToolCall] {
    if mode == .text {
      let calls = TextToolCallParser.parseCalls(in: text, tools: tools)
      if !calls.isEmpty { return calls }
    }
    // XML envelopes take precedence over bare JSON, including in JSON mode.
    let xmlCalls = XMLToolCallParser.parseCalls(in: text, tools: tools)
    if !xmlCalls.isEmpty { return xmlCalls }
    let jsonCalls = JSONToolCallParser.parseCalls(in: text, tools: tools)
    if !jsonCalls.isEmpty { return jsonCalls }
    return mode == .text ? [] : TextToolCallParser.parseCalls(in: text, tools: tools)
  }

  public static func containsToolCallMarker(
    in text: String,
    mode: ToolCallingMode? = nil
  ) -> Bool {
    let modes = mode.map { [$0] } ?? [.text, .native]
    return modes.contains { mode in
      switch mode {
      case .text:
        return text.range(
          of: "(?m)^\\s*TOOL_CALL\\s*$",
          options: [.regularExpression, .caseInsensitive]) != nil
      case .xml, .native:
        let hasXMLMarker =
          text.range(
            of: "<\\s*/?\\s*tool_call\\b",
            options: [.regularExpression, .caseInsensitive]) != nil
        return hasXMLMarker
          || (mode == .native && JSONToolCallParser.containsToolCallMarker(in: text))
      case .json:
        return JSONToolCallParser.containsToolCallMarker(in: text)
      }
    }
  }

  public static func containsNonToolJSONToolLoopObject(
    in text: String,
    tools: [ToolDefinition]
  ) -> Bool {
    JSONToolCallParser.containsNonToolJSONToolLoopObject(in: text, tools: tools)
  }
}
