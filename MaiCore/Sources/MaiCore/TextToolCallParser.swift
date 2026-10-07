import Foundation

/// Decodes TOOL_CALL blocks while preserving multiline argument values.
enum TextToolCallParser {
  static func parseCalls(
    in text: String,
    tools: [ToolDefinition]
  ) -> [ParsedToolCall] {
    let pattern = "(?im)^\\s*TOOL_CALL\\s*$([\\s\\S]*?)(?:^\\s*END_TOOL_CALL\\s*$|\\z)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(
      in: text, options: [], range: NSRange(location: 0, length: nsText.length))

    return matches.compactMap { match in
      guard match.numberOfRanges == 2 else { return nil }
      let raw = nsText.substring(with: match.range(at: 0))
      let body = nsText.substring(with: match.range(at: 1))
      return parsePlainTextToolCallBlock(body, rawBlock: raw, tools: tools)
    }
  }

  private static func parsePlainTextToolCallBlock(
    _ body: String,
    rawBlock: String,
    tools: [ToolDefinition]
  ) -> ParsedToolCall? {
    let lines = body.components(separatedBy: .newlines)
    let nameKeys = Set(["tool", "name", "function"])
    let resolver = AgentToolNameResolver(tools: tools)
    let candidates = lines.enumerated().compactMap {
      index, line -> (index: Int, key: String, value: String)? in
      guard let pair = lineKeyValue(line), nameKeys.contains(pair.key.lowercased()) else {
        return nil
      }
      let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : (index, pair.key.lowercased(), value)
    }
    // Prefer an explicit tool:/function: line, then any line resolving to a
    // listed tool: a tool's own "name" argument (call-tool, webxdc_create)
    // must not be mistaken for the call's tool name.
    let toolNameLine =
      candidates.first { $0.key != "name" && resolver.canonicalName(for: $0.value) != nil }
      ?? candidates.first { resolver.canonicalName(for: $0.value) != nil }
      ?? candidates.first { $0.key != "name" }
      ?? candidates.first
    guard let toolNameLine else { return nil }
    let name = toolNameLine.value

    let canonical = resolver.canonicalName(for: name) ?? name
    let tool = tools.first { $0.name == canonical }
    let parameterNames = Set(tool?.parameters.map(\.name) ?? [])
    var arguments: [String: String] = [:]
    var currentKey: String?
    var currentValue: [String] = []

    func flush() {
      guard let currentKey else { return }
      arguments[currentKey] = currentValue.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    for (index, line) in lines.enumerated() {
      guard index != toolNameLine.index else { continue }
      guard let pair = lineKeyValue(line) else {
        if currentKey != nil { currentValue.append(line) }
        continue
      }
      let key = pair.key
      let isKnownArgument =
        nameKeys.contains(key.lowercased())
        ? parameterNames.contains(key)
        : parameterNames.isEmpty || parameterNames.contains(key)
      if isKnownArgument {
        flush()
        currentKey = key
        currentValue = [pair.value]
      } else if currentKey != nil {
        currentValue.append(line)
      }
    }
    flush()

    return ParsedToolCall(
      name: name,
      arguments: [:],
      argumentValues: arguments.mapValues { AgentToolArgumentValue.string($0) },
      rawBlock: rawBlock)
  }

  private static func lineKeyValue(_ line: String) -> (key: String, value: String)? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    else {
      return nil
    }
    let value = String(line[line.index(after: colon)...])
      .trimmingCharacters(in: .whitespaces)
    return (key, String(value))
  }
}
