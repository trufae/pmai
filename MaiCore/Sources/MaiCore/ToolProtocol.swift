import Foundation

/// Selects the wire format used when a model cannot call tools natively.
public enum ToolCallingMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case text
  case xml
  case json
  case native

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .text: "Text"
    case .xml: "XML"
    case .json: "JSON"
    case .native: "Native"
    }
  }

  public var summary: String {
    switch self {
    case .text:
      "Default. Uses a plain TOOL_CALL block with one argument per line. Most portable for small or local models."
    case .xml:
      "Uses <tool_call> XML blocks with one <arg> element per argument. More structured, but more fragile for small models."
    case .json:
      "Uses one JSON object with name and arguments. Compact and easy to parse when the model emits strict JSON."
    case .native:
      "Uses provider-native structured tools for compatible requests and a host-selected text fallback otherwise."
    }
  }

  public var textProtocolFallback: ToolCallingMode {
    self == .native ? .text : self
  }

  public func instructionAfterToolResults(_ hasToolResults: Bool) -> String {
    if hasToolResults {
      return
        "Continue from the latest host tool result. Either emit one more \(callReference) for a host tool if another host tool run is needed, or return the final answer."
    }
    return
      "Reply to the latest user message. If you need a tool, emit one \(callReference) and stop; otherwise answer directly."
  }

  private var callReference: String {
    switch self {
    case .text: "TOOL_CALL block"
    case .xml: "<tool_call> block"
    case .json: "tool-call JSON object"
    case .native: "TOOL_CALL block"
    }
  }
}

public typealias AgentToolArgumentValue = JSONValue

public struct ParsedToolCall: Identifiable, Sendable {
  public let id = UUID()
  public let name: String
  public let arguments: [String: String]
  public let argumentValues: [String: AgentToolArgumentValue]
  public let rawBlock: String
  public let argsJSON: String
  public let toolCallID: String?
  public let apiName: String?

  public init(
    name: String,
    arguments: [String: String],
    argumentValues: [String: AgentToolArgumentValue]? = nil,
    rawBlock: String,
    argsJSON: String? = nil,
    toolCallID: String? = nil,
    apiName: String? = nil
  ) {
    self.name = name
    let values = argumentValues ?? arguments.mapValues { AgentToolArgumentValue.string($0) }
    self.argumentValues = values
    self.arguments = values.mapValues(\.coercedStringValue)
    self.rawBlock = rawBlock
    self.argsJSON = argsJSON ?? AgentTooling.compactJSON(values)
    self.toolCallID = toolCallID
    self.apiName = apiName
  }
}

public struct AgentNativeToolCall: Sendable {
  public let id: String
  public let name: String
  public let arguments: [String: String]
  public let argumentValues: [String: AgentToolArgumentValue]
  public let rawArguments: String

  public var textBlock: String {
    let payload: [String: Any] = [
      "name": name,
      "arguments": argumentValues.mapValues(\.jsonObject),
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return
      "<tool_call id=\"\(AgentTooling.xmlEscapedAttribute(id))\" api_name=\"\(AgentTooling.xmlEscapedAttribute(name))\">\(json)</tool_call>"
  }
}

public struct AgentToolNameResolver: Sendable {
  private let canonicalByAlias: [String: String]
  private let canonicalByShortAlias: [String: String]
  private let apiByCanonical: [String: String]

  public init(tools: [ToolDefinition]) {
    var aliases: [String: String] = [:]
    var shortAliases: [String: String] = [:]
    var ambiguousShortAliases = Set<String>()
    var apiNames: [String: String] = [:]
    var usedAPI = Set<String>()

    for tool in tools {
      let preferredName = tool.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let api = Self.uniqueAPIName(
        for: preferredName.flatMap { $0.isEmpty ? nil : $0 } ?? tool.name,
        used: &usedAPI)
      apiNames[tool.name] = api
      var candidates = [
        tool.name,
        api,
        tool.name.replacingOccurrences(of: "::", with: "."),
        tool.name.replacingOccurrences(of: "::", with: "_"),
        tool.name.replacingOccurrences(of: "::", with: "__"),
      ]
      if let preferredName, !preferredName.isEmpty {
        candidates.append(preferredName)
      }
      for candidate in candidates {
        aliases[Self.key(candidate)] = tool.name
        let candidateShortKey = Self.shortKey(candidate)
        if let existing = shortAliases[candidateShortKey], existing != tool.name {
          ambiguousShortAliases.insert(candidateShortKey)
        } else {
          shortAliases[candidateShortKey] = tool.name
        }
      }
      let shortKey = Self.shortKey(tool.name)
      if let existing = shortAliases[shortKey], existing != tool.name {
        ambiguousShortAliases.insert(shortKey)
      } else {
        shortAliases[shortKey] = tool.name
      }
    }
    for key in ambiguousShortAliases {
      shortAliases.removeValue(forKey: key)
    }

    canonicalByAlias = aliases
    canonicalByShortAlias = shortAliases
    apiByCanonical = apiNames
  }

  public init(definitions: [ToolDefinition]) {
    self.init(tools: definitions)
  }

  public func canonicalName(for name: String) -> String? {
    if let known = canonicalByAlias[Self.key(name)] ?? canonicalByShortAlias[Self.shortKey(name)] {
      return known
    }
    // A model writing a call in its own syntax can hand the server a name with
    // the arguments glued on ("run_sh Optimize:", "files_read.arguments"). The
    // leading identifier is the tool it meant; failing it costs a whole turn.
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    guard !head.isEmpty, head.count < trimmed.count else { return nil }
    return canonicalByAlias[Self.key(String(head))]
  }

  public func apiName(for canonical: String) -> String {
    apiByCanonical[canonical] ?? Self.sanitizeAPIName(canonical)
  }

  public func providerName(for canonicalName: String) -> String {
    apiName(for: canonicalName)
  }

  private static func key(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private static func shortKey(_ name: String) -> String {
    let normalized = name.replacingOccurrences(of: "::", with: ".")
    guard let last = normalized.split(separator: ".").last else { return key(name) }
    return key(String(last))
  }

  private static func uniqueAPIName(for name: String, used: inout Set<String>) -> String {
    let base = sanitizeAPIName(name)
    var candidate = base
    var n = 2
    while used.contains(candidate) {
      let suffix = "_\(n)"
      candidate = String(base.prefix(max(1, 64 - suffix.count))) + suffix
      n += 1
    }
    used.insert(candidate)
    return candidate
  }

  private static func sanitizeAPIName(_ name: String) -> String {
    var out = ""
    var lastWasUnderscore = false
    for scalar in name.unicodeScalars {
      let isAllowed =
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
      if isAllowed {
        out.unicodeScalars.append(scalar)
        lastWasUnderscore = false
      } else if !lastWasUnderscore {
        out.append("_")
        lastWasUnderscore = true
      }
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    if out.isEmpty { out = "tool" }
    if out.first?.isNumber == true { out = "tool_\(out)" }
    if out.count > 64 {
      out = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }
    return out
  }
}

/// Provider-facing tool naming uses the same resolver as textual tool protocols.
public typealias ToolNameResolver = AgentToolNameResolver

public enum AgentTooling {
  public static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

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
    switch mode.textProtocolFallback {
    case .text:
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
    case .native:
      return promptInstructions(for: .text, tools: tools)
    }
  }

  public static func parseCalls(
    in text: String,
    tools: [ToolDefinition],
    mode: ToolCallingMode = .text
  ) -> [ParsedToolCall] {
    switch mode {
    case .text:
      let calls = parsePlainTextCalls(in: text, tools: tools)
      if !calls.isEmpty { return calls }
      let xmlCalls = parseXMLCalls(in: text, tools: tools)
      if !xmlCalls.isEmpty { return xmlCalls }
      return parseJSONCalls(in: text, tools: tools)
    case .xml:
      let calls = parseXMLCalls(in: text, tools: tools)
      if !calls.isEmpty { return calls }
      let textCalls = parsePlainTextCalls(in: text, tools: tools)
      return textCalls.isEmpty ? [] : textCalls
    case .json:
      let xmlCalls = parseXMLCalls(in: text, tools: tools)
      if !xmlCalls.isEmpty { return xmlCalls }
      let jsonCalls = parseJSONCalls(in: text, tools: tools)
      if !jsonCalls.isEmpty { return jsonCalls }
      let textCalls = parsePlainTextCalls(in: text, tools: tools)
      return textCalls.isEmpty ? [] : textCalls
    case .native:
      let xmlCalls = parseXMLCalls(in: text, tools: tools)
      if !xmlCalls.isEmpty { return xmlCalls }
      let jsonCalls = parseJSONCalls(in: text, tools: tools)
      if !jsonCalls.isEmpty { return jsonCalls }
      let textCalls = parsePlainTextCalls(in: text, tools: tools)
      return textCalls.isEmpty ? [] : textCalls
    }
  }

  private static func parseXMLCalls(in text: String, tools: [ToolDefinition]) -> [ParsedToolCall] {
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
    let openerCalls = parseMalformedXMLCallOpeners(in: text, tools: tools)
    if !openerCalls.isEmpty { return openerCalls }
    return parseJSONCalls(in: text, tools: tools)
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
      guard let name = firstNonEmpty(attrs["name"], attrs["tool"], attrs["function"]),
        let canonical = resolver.canonicalName(for: name),
        tools.contains(where: { $0.name == canonical })
      else { return nil }
      return parseToolCallPayload("", attributes: attributes, rawBlock: raw, tools: tools)
    }
  }

  private static func parsePlainTextCalls(
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

  public static func containsToolCallMarker(
    in text: String,
    mode: ToolCallingMode? = nil
  ) -> Bool {
    let modes = mode.map { [$0] } ?? [.text, .xml, .native]
    return modes.contains { mode in
      switch mode {
      case .text:
        return text.range(
          of: "(?m)^\\s*TOOL_CALL\\s*$",
          options: [.regularExpression, .caseInsensitive]) != nil
      case .xml:
        return text.range(
          of: "<\\s*/?\\s*tool_call\\b",
          options: [.regularExpression, .caseInsensitive]) != nil
      case .native:
        if text.range(
          of: "<\\s*/?\\s*tool_call\\b",
          options: [.regularExpression, .caseInsensitive]) != nil
        {
          return true
        }
        fallthrough
      case .json:
        let visible = MessageContentFilter.removingReasoningSections(
          from: stripMarkdownFence(from: text))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = jsonObjects(in: visible)
        for candidate in candidates {
          guard let object = jsonObject(from: candidate) else { continue }
          return strictToolCallObject(object) != nil || isNamelessToolCallObject(object)
        }
        return visible.contains("{")
          && containsJSONKey(in: visible, keys: ["name", "tool", "function"])
          && containsJSONKey(
            in: visible,
            keys: ["arguments", "args", "parameters", "params", "input"])
      }
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

  public static func containsNonToolJSONToolLoopObject(
    in text: String,
    tools: [ToolDefinition]
  ) -> Bool {
    let visible = stripMarkdownFence(
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
    return jsonObjects(in: visible).contains { rawBlock in
      guard let object = jsonObject(from: rawBlock),
        parseJSONCallObject(object, rawBlock: rawBlock, tools: tools) == nil
      else { return false }
      let keys = Set(object.keys.map { $0.lowercased() })
      return !keys.isDisjoint(with: toolLoopKeys)
    }
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

    switch mode.textProtocolFallback {
    case .text:
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
    case .native:
      return toolCallExample(for: .text, tool: tool, resolver: resolver)
    }
  }

  private static func exampleToolCandidates(
    matching text: String,
    tools: [ToolDefinition]
  ) -> [ToolDefinition] {
    guard let primary = exampleTool(matching: text, tools: tools) else { return [] }
    var result = [primary]
    let primaryHasRequiredArguments = primary.parameters.contains { $0.required }
    let secondary = tools.first { tool in
      guard tool.name != primary.name else { return false }
      let hasRequiredArguments = tool.parameters.contains { $0.required }
      return primaryHasRequiredArguments ? !hasRequiredArguments : hasRequiredArguments
    }
    if let secondary {
      result.append(secondary)
    }
    return result
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

  public static func normalizeArguments(
    _ arguments: [String: AgentToolArgumentValue],
    for tool: ToolDefinition?
  ) -> [String: AgentToolArgumentValue] {
    let normalized = normalizeValues(arguments, for: tool)
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

  public static func unavailableToolError(name: String) -> String {
    "Error: tool '\(name)' is not available. It may be unknown or disabled for this conversation."
  }

  private static func requiredArgumentIsMissing(_ value: AgentToolArgumentValue?) -> Bool {
    guard let value else { return true }
    if case .string(let string) = value {
      return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return value == .null
  }

  public static func parameters(fromSchemaJSON schemaJSON: String) -> [ToolParameterDef] {
    guard !schemaJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = schemaJSON.data(using: .utf8),
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

  public static func makeRunBlock(toolName: String, argumentsJSON: String, result: String) -> String {
    let body = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return "<tool_run>\n\(toolName) tool (\(argumentsJSON)):\n\(body)\n</tool_run>"
  }

  public static func makeRunBlock(call: ParsedToolCall, result: String) -> String {
    makeRunBlock(toolName: call.name, argumentsJSON: call.argsJSON, result: result)
  }

  public static func editableToolCallText(for call: ParsedToolCall, mode: ToolCallingMode) -> String {
    let raw = call.rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
    if !raw.isEmpty { return raw }

    switch mode {
    case .text:
      var lines = ["TOOL_CALL", "tool: \(call.name)"]
      for key in call.argumentValues.keys.sorted() {
        guard let value = call.argumentValues[key] else { continue }
        lines.append("\(key): \(value.coercedStringValue)")
      }
      lines.append("END_TOOL_CALL")
      return lines.joined(separator: "\n")
    case .xml, .native:
      return "<tool_call>\(toolCallObjectJSON(for: call))</tool_call>"
    case .json:
      return toolCallObjectJSON(for: call)
    }
  }

  public static func compactJSON(_ args: [String: String]) -> String {
    compactJSON(args.mapValues { .string($0) })
  }

  public static func compactJSON(_ args: [String: AgentToolArgumentValue]) -> String {
    guard !args.isEmpty,
      let data = try? JSONSerialization.data(
        withJSONObject: args.mapValues(\.jsonObject), options: [.sortedKeys]),
      let s = String(data: data, encoding: .utf8)
    else { return "{}" }
    return s
  }

  private static func jsonStringLiteral(_ value: String) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
      let array = String(data: data, encoding: .utf8),
      array.hasPrefix("["),
      array.hasSuffix("]")
    else { return "\"\"" }
    return String(array.dropFirst().dropLast())
  }

  private static func toolCallObjectJSON(for call: ParsedToolCall) -> String {
    toolCallObjectJSON(name: call.name, arguments: call.argumentValues)
  }

  private static func toolCallObjectJSON(
    name: String,
    arguments: [String: AgentToolArgumentValue]
  ) -> String {
    #"{"name":\#(jsonStringLiteral(name)),"arguments":\#(compactJSON(arguments))}"#
  }

  public static func argumentValues(_ args: [String: Any]) -> [String: AgentToolArgumentValue] {
    args.mapValues { AgentToolArgumentValue(json: $0) }
  }

  private static func normalizeValues(
    _ arguments: [String: AgentToolArgumentValue],
    for tool: ToolDefinition?
  ) -> [String: AgentToolArgumentValue] {
    guard let tool else {
      return arguments.filter { _, value in
        if case .null = value { return false }
        return true
      }
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
      return value.coercedBoolValue.map(AgentToolArgumentValue.bool)
        ?? (parameter.required ? value : nil)
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

  public static func nativeToolCalls(from acc: [Int: (id: String?, name: String?, args: String)])
    -> [AgentNativeToolCall]
  {
    acc.sorted(by: { $0.key < $1.key }).compactMap { _, e -> AgentNativeToolCall? in
      guard let name = e.name else { return nil }
      return makeNativeToolCall(id: e.id, name: name, rawArguments: e.args)
    }
  }

  public static func makeNativeToolCall(id: String?, name: String, rawArguments: String)
    -> AgentNativeToolCall
  {
    var args: [String: AgentToolArgumentValue] = [:]
    if !rawArguments.isEmpty,
      let data = rawArguments.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      args = argumentValues(parsed)
    }
    return AgentNativeToolCall(
      id: id ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
      name: name,
      arguments: args.mapValues(\.coercedStringValue),
      argumentValues: args,
      rawArguments: rawArguments.isEmpty ? "{}" : rawArguments)
  }

  private static func parseToolCallPayload(
    _ payload: String,
    attributes: String,
    rawBlock: String,
    tools: [ToolDefinition]
  ) -> ParsedToolCall? {
    let attrs = toolCallAttributes(from: attributes)
    let attrName = firstNonEmpty(attrs["name"], attrs["tool"], attrs["function"])
    let attrID = firstNonEmpty(attrs["id"], attrs["tool_call_id"])
    let attrAPIName = firstNonEmpty(attrs["api_name"], attrs["api"], attrs["native_name"])
    let attrArgs = firstNonEmpty(attrs["arguments"], attrs["args"], attrs["params"], attrs["input"])
    let normalizedPayload = stripMarkdownFence(from: payload)
    var candidates = [normalizedPayload]
    if let object = firstJSONObject(in: normalizedPayload), object != normalizedPayload {
      candidates.append(object)
    }
    if let attrArgs, !attrArgs.isEmpty {
      candidates.append(stripMarkdownFence(from: attrArgs))
    }

    for candidate in candidates {
      guard let object = jsonObject(from: candidate) else { continue }
      if let normalized = normalizeToolCallObject(object, tools: tools),
        let name = (normalized["name"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !name.isEmpty
      {
        let args = argumentValues(argumentsObject(from: normalized["arguments"]))
        return ParsedToolCall(
          name: name,
          arguments: [:],
          argumentValues: args,
          rawBlock: rawBlock,
          toolCallID: attrID,
          apiName: attrAPIName ?? name)
      }
      if let attrName {
        return ParsedToolCall(
          name: attrName,
          arguments: [:],
          argumentValues: argumentValues(object),
          rawBlock: rawBlock,
          toolCallID: attrID,
          apiName: attrAPIName ?? attrName)
      }
    }

    if let xmlCall = xmlToolCallPayload(
      normalizedPayload,
      attrName: attrName,
      attrID: attrID,
      attrAPIName: attrAPIName,
      rawBlock: rawBlock)
    {
      return xmlCall
    }

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
      argumentValues: argumentValues(xmlArguments(from: payload)),
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
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func xmlEscapedAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static func jsonObject(from text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func stripMarkdownFence(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else { return trimmed }
    var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
      lines.removeFirst()
    }
    if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
      lines.removeLast()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func firstJSONObject(in text: String) -> String? {
    jsonObjects(in: text).first
  }

  private static func jsonObjects(in text: String) -> [String] {
    var objects: [String] = []
    var start: String.Index?
    var depth = 0
    var inString = false
    var escaped = false

    for index in text.indices {
      let char = text[index]
      if start == nil {
        guard char == "{" else { continue }
        start = index
        depth = 1
        continue
      }

      if inString {
        if escaped {
          escaped = false
        } else if char == "\\" {
          escaped = true
        } else if char == "\"" {
          inString = false
        }
        continue
      }

      if char == "\"" {
        inString = true
      } else if char == "{" {
        depth += 1
      } else if char == "}" {
        depth -= 1
        if depth == 0, let objectStart = start {
          objects.append(
            String(text[objectStart...index]).trimmingCharacters(in: .whitespacesAndNewlines))
          start = nil
          inString = false
          escaped = false
        }
      }
    }
    return objects
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
  ) -> [String: Any]? {
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
        return ["name": nestedName, "arguments": toolArguments(from: nested)]
      }
      return ["name": name, "arguments": toolArguments(from: object)]
    }
    if let name = (object["tool"] as? String) ?? (object["function"] as? String) {
      return [
        "name": name,
        "arguments": toolArguments(from: object),
      ]
    }
    if let function = object["function"] as? [String: Any],
      let name = function["name"] as? String,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return ["name": name, "arguments": toolArguments(from: function)]
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

  private static func toolArguments(from object: [String: Any]) -> [String: Any] {
    for key in ["arguments", "args", "parameters", "params", "input"] {
      let args = argumentsObject(from: object[key])
      if !args.isEmpty { return args }
    }
    var args: [String: Any] = [:]
    var reserved = Set([
      "name", "tool", "function", "arguments", "args", "parameters", "params", "input",
    ])
    if (object["type"] as? String)?.lowercased() == "function" {
      reserved.formUnion(["id", "type"])
    }
    for (key, value) in object where !reserved.contains(key) {
      args[key] = value
    }
    return args
  }

  private static func parseJSONCall(in text: String, tools: [ToolDefinition]) -> ParsedToolCall? {
    parseJSONCalls(in: text, tools: tools).first
  }

  private static func parseJSONCalls(in text: String, tools: [ToolDefinition]) -> [ParsedToolCall] {
    let visible = stripMarkdownFence(
      from: MessageContentFilter.removingReasoningSections(from: text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    var calls: [ParsedToolCall] = []
    for rawBlock in jsonObjects(in: visible) {
      guard let object = jsonObject(from: rawBlock),
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
        argumentValues: argumentValues(normalized.arguments),
        rawBlock: rawBlock)
    }
    if let recovered = recoverJSONToolCall(object, tools: tools) {
      return ParsedToolCall(
        name: recovered.name,
        arguments: [:],
        argumentValues: argumentValues(recovered.arguments),
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
      return (name, toolArguments(from: arguments))
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

  private static func containsJSONKey(in text: String, keys: [String]) -> Bool {
    keys.contains { key in
      text.range(
        of: #""\#(NSRegularExpression.escapedPattern(for: key))"\s*:"#,
        options: [.regularExpression]) != nil
    }
  }

  private static func argumentsObject(from value: Any?) -> [String: Any] {
    if let object = value as? [String: Any] {
      return object
    }
    if let string = value as? String,
      let data = string.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return object
    }
    return [:]
  }
}
