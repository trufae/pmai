import Foundation

/// Decodes XML envelopes, including their legacy JSON payloads and malformed openers.
enum XMLToolCallParser {
  static func parseCalls(in text: String, tools: [ToolDefinition]) -> [ParsedToolCall] {
    let pattern = "<tool_call\\b([^>]*)>([\\s\\S]*?)(?:</tool_call\\s*>|$)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(
      in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    var calls: [ParsedToolCall] = []
    for match in matches {
      guard match.numberOfRanges == 3 else { continue }
      let raw = nsText.substring(with: match.range(at: 0))
      let attributes = nsText.substring(with: match.range(at: 1))
      let payload = nsText.substring(with: match.range(at: 2))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let call = parseToolCallPayload(
        payload, attributes: attributes, rawBlock: raw, tools: tools)
      {
        calls.append(call)
      }
    }
    if !calls.isEmpty { return calls }
    return parseMalformedXMLCallOpeners(in: text, tools: tools)
  }

  private static func parseMalformedXMLCallOpeners(
    in text: String,
    tools: [ToolDefinition]
  ) -> [ParsedToolCall] {
    let pattern = "<\\s*tool_call\\b([^>\\n\\r]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(
      in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    let resolver = AgentToolNameResolver(tools: tools)
    return matches.compactMap { match in
      guard match.numberOfRanges == 2 else { return nil }
      let raw = nsText.substring(with: match.range(at: 0))
      let attributes = nsText.substring(with: match.range(at: 1))
      let attrs = toolCallAttributes(from: attributes)
      guard
        let name = AgentTooling.firstNonEmpty(attrs["name"], attrs["tool"], attrs["function"]),
        let canonical = resolver.canonicalName(for: name),
        tools.contains(where: { $0.name == canonical })
      else { return nil }
      return parseToolCallPayload("", attributes: attributes, rawBlock: raw, tools: tools)
    }
  }

  private static func parseToolCallPayload(
    _ payload: String,
    attributes: String,
    rawBlock: String,
    tools: [ToolDefinition]
  ) -> ParsedToolCall? {
    let attrs = toolCallAttributes(from: attributes)
    let attrName = AgentTooling.firstNonEmpty(attrs["name"], attrs["tool"], attrs["function"])
    let attrID = AgentTooling.firstNonEmpty(attrs["id"], attrs["tool_call_id"])
    let attrAPIName = AgentTooling.firstNonEmpty(
      attrs["api_name"], attrs["api"], attrs["native_name"],
    )
    let attrArgs = AgentTooling.firstNonEmpty(
      attrs["arguments"], attrs["args"], attrs["params"], attrs["input"],
    )
    let normalizedPayload = ToolCallParsing.stripMarkdownFence(from: payload)
    let xmlCall = xmlToolCallPayload(
      normalizedPayload, attrName: attrName, attrID: attrID,
      attrAPIName: attrAPIName, rawBlock: rawBlock)
    var candidates = [normalizedPayload]
    // JSON inside an XML argument is data, not a replacement call envelope.
    if xmlCall?.argumentValues.isEmpty != false,
      let object = ToolCallParsing.jsonObjects(in: normalizedPayload).first,
      object != normalizedPayload
    {
      candidates.append(object)
    }
    if let attrArgs, !attrArgs.isEmpty {
      candidates.append(ToolCallParsing.stripMarkdownFence(from: attrArgs))
    }

    for candidate in candidates {
      guard let object = ToolCallParsing.jsonObject(from: candidate) else { continue }
      if let normalized = normalizeToolCallObject(object, tools: tools) {
        let name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
          return ParsedToolCall(
            name: name,
            arguments: [:],
            argumentValues: AgentTooling.argumentValues(normalized.arguments),
            rawBlock: rawBlock,
            toolCallID: attrID,
            apiName: attrAPIName ?? name)
        }
      }
      if let attrName {
        return ParsedToolCall(
          name: attrName,
          arguments: [:],
          argumentValues: AgentTooling.argumentValues(object),
          rawBlock: rawBlock,
          toolCallID: attrID,
          apiName: attrAPIName ?? attrName)
      }
    }

    if let xmlCall { return xmlCall }

    if let attrName {
      return ParsedToolCall(
        name: attrName,
        arguments: [:],
        argumentValues: [:],
        rawBlock: rawBlock,
        toolCallID: attrID,
        apiName: attrAPIName ?? attrName)
    }
    return nil
  }

  private static func xmlToolCallPayload(
    _ payload: String,
    attrName: String?,
    attrID: String?,
    attrAPIName: String?,
    rawBlock: String
  ) -> ParsedToolCall? {
    let name =
      attrName
      ?? firstXMLValue(named: "name", in: payload)
      ?? firstXMLValue(named: "tool", in: payload)
      ?? firstXMLValue(named: "function", in: payload)
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }
    return ParsedToolCall(
      name: name,
      arguments: [:],
      argumentValues: AgentTooling.argumentValues(xmlArguments(from: payload)),
      rawBlock: rawBlock,
      toolCallID: attrID,
      apiName: attrAPIName ?? name)
  }

  private static func xmlArguments(from payload: String) -> [String: Any] {
    var arguments: [String: Any] = [:]
    let nsPayload = payload as NSString

    if let argRegex = try? NSRegularExpression(
      pattern: #"<\s*arg\s+name\s*=\s*("[^"]*"|'[^']*'|[^\s"'>/]+)\s*>([\s\S]*?)<\s*/\s*arg\s*>"#,
      options: [.caseInsensitive])
    {
      let matches = argRegex.matches(
        in: payload, options: [], range: NSRange(location: 0, length: nsPayload.length))
      for match in matches where match.numberOfRanges == 3 {
        var name = nsPayload.substring(with: match.range(at: 1))
        if name.count >= 2,
          (name.hasPrefix("\"") && name.hasSuffix("\""))
            || (name.hasPrefix("'") && name.hasSuffix("'"))
        {
          name.removeFirst()
          name.removeLast()
        }
        arguments[name] = xmlUnescaped(nsPayload.substring(with: match.range(at: 2)))
      }
    }

    if let tagRegex = try? NSRegularExpression(
      pattern: #"<\s*([A-Za-z_][A-Za-z0-9_-]*)\s*>([\s\S]*?)<\s*/\s*\1\s*>"#,
      options: [.caseInsensitive])
    {
      let matches = tagRegex.matches(
        in: payload, options: [], range: NSRange(location: 0, length: nsPayload.length))
      let reserved = Set(["name", "tool", "function", "arguments", "args", "params", "input"])
      for match in matches where match.numberOfRanges == 3 {
        let name = nsPayload.substring(with: match.range(at: 1))
        guard !reserved.contains(name.lowercased()), arguments[name] == nil else { continue }
        arguments[name] = xmlUnescaped(nsPayload.substring(with: match.range(at: 2)))
      }
    }

    return arguments
  }

  private static func firstXMLValue(named name: String, in payload: String) -> String? {
    guard
      let regex = try? NSRegularExpression(
        pattern: #"<\s*\#(name)\s*>([\s\S]*?)<\s*/\s*\#(name)\s*>"#,
        options: [.caseInsensitive])
    else {
      return nil
    }
    let nsPayload = payload as NSString
    guard
      let match = regex.firstMatch(
        in: payload, options: [], range: NSRange(location: 0, length: nsPayload.length)),
      match.numberOfRanges == 2
    else {
      return nil
    }
    return xmlUnescaped(nsPayload.substring(with: match.range(at: 1)))
  }

  private static func xmlUnescaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private static func toolCallAttributes(from text: String) -> [String: String] {
    let pattern = #"([A-Za-z_][A-Za-z0-9_:-]*)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>/]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var attrs: [String: String] = [:]
    for match in matches where match.numberOfRanges == 3 {
      let key = nsText.substring(with: match.range(at: 1)).lowercased()
      var value = nsText.substring(with: match.range(at: 2))
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value.removeFirst()
        value.removeLast()
      }
      attrs[key] = value
    }
    return attrs
  }

  private static func normalizeToolCallObject(
    _ object: [String: Any],
    tools: [ToolDefinition] = []
  ) -> (name: String, arguments: [String: Any])? {
    if let name = object["name"] as? String,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      // Only treat arguments.name as the tool name when the nested object is
      // itself a wrapped call (it carries its own arguments container) or the
      // outer name is a generic placeholder. A real tool call may legitimately
      // take a "name" argument (e.g. webxdc_create name=..., or the call-tool
      // proxy whose parameters are exactly name + arguments), and that must
      // stay an argument. When the outer name resolves to a listed tool, keep
      // it — unless the nested name resolves to the same tool (a double-wrap).
      if let nested = object["arguments"] as? [String: Any],
        let nestedName = nested["name"] as? String,
        shouldUnwrapNestedCall(
          outerName: name, nested: nested, nestedName: nestedName, tools: tools)
      {
        return (nestedName, ToolCallParsing.toolArguments(from: nested))
      }
      return (name, ToolCallParsing.toolArguments(from: object))
    }
    if let name = (object["tool"] as? String) ?? (object["function"] as? String) {
      return (name, ToolCallParsing.toolArguments(from: object))
    }
    if let function = object["function"] as? [String: Any],
      let name = function["name"] as? String,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return (name, ToolCallParsing.toolArguments(from: function))
    }
    return nil
  }

  private static func shouldUnwrapNestedCall(
    outerName: String,
    nested: [String: Any],
    nestedName: String,
    tools: [ToolDefinition]
  ) -> Bool {
    if isPlaceholderToolName(outerName) { return true }
    guard looksLikeWrappedCall(nested) else { return false }
    guard !tools.isEmpty else { return true }
    let resolver = AgentToolNameResolver(tools: tools)
    guard let outerCanonical = resolver.canonicalName(for: outerName) else { return true }
    return resolver.canonicalName(for: nestedName) == outerCanonical
  }

  private static func looksLikeWrappedCall(_ object: [String: Any]) -> Bool {
    ["arguments", "args", "parameters", "params", "input"].contains { key in
      object[key] is [String: Any] || object[key] is String
    }
  }

  private static func isPlaceholderToolName(_ name: String) -> Bool {
    switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "tool_call", "toolcall", "tool_use", "function_call", "call", "tool", "function":
      return true
    default:
      return false
    }
  }
}
