import Foundation

/// Reduces a large tool catalog to two stable tools. Hosts remain responsible
/// for executing the concrete call returned by `resolveCall`.
public enum ToolProxy {
  public static let listName = "list-tools"
  public static let callName = "call-tool"
  private static let listAPIName = "list_tools"
  private static let callAPIName = "call_tool"
  private static let proxyNames = AgentToolNameResolver(tools: definitions)

  /// How many matches `listTools` describes with their arguments; the rest
  /// are named in one line each, so a broad search costs a screen, not the
  /// whole catalog.
  public static let detailedMatches = 6

  /// Tools most coding work touches every few turns. With the proxy on, an
  /// agent offers these natively unless its definition names another set; the
  /// rest stay behind list-tools and call-tool. A model calling the common
  /// tools by their own schema makes far fewer mistakes than one wrapping
  /// every call in an envelope, and the six schemas cost about 1k tokens.
  public static let defaultExposedNames: Set<String> = [
    "files_read", "files_grep", "files_patch", "files_write", "files_list", "run_shell",
  ]

  /// Tools shown at most in the list-tools description before "and N more".
  static let maximumDescribedTools = 40

  /// The definitions a proxied run offers: the exposed tools as they are,
  /// then list-tools and call-tool for the rest. `exposed` nil means
  /// `defaultExposedNames`; an empty set is the pure proxy.
  /// Hidden names stay callable through call-tool but never appear in discovery.
  public static func definitions(
    for catalog: [ToolDefinition],
    exposing exposed: Set<String>? = nil,
    hiding hiddenNames: Set<String> = []
  ) -> [ToolDefinition] {
    let listed = catalog.filter { !hiddenNames.contains($0.name) }
    let proxied = hiddenDefinitions(in: listed, exposing: exposed)
    let proxiedNames = Set(proxied.map(\.name))
    let visible = listed.filter { !proxiedNames.contains($0.name) }
    guard !proxied.isEmpty || catalog.contains(where: { hiddenNames.contains($0.name) }) else {
      return visible
    }
    return visible + [listDefinition(for: proxied), callDefinition]
  }

  /// The proxy tools without a catalog to describe.
  public static var definitions: [ToolDefinition] { [listDefinition(for: []), callDefinition] }

  /// The tools of `catalog` that sit behind the proxy.
  public static func hiddenDefinitions(
    in catalog: [ToolDefinition],
    exposing exposed: Set<String>?
  ) -> [ToolDefinition] {
    let names = exposed ?? defaultExposedNames
    return catalog.filter { !names.contains($0.name) }
  }

  /// Appended to repair feedback in a proxied run: a model that calls a hidden
  /// tool by its own name gets nothing back from the server, and needs to be
  /// told the way in.
  public static let repairHint =
    "Tools not offered directly run through \(callAPIName): {\"name\": TOOL, \"arguments\": {…}}; call \(listAPIName) directly to see their arguments."

  /// list-tools, describing what it reaches: each hidden tool's name and the
  /// start of its description, so the model knows what exists without paying
  /// for the schemas until it needs one.
  static func listDefinition(for hidden: [ToolDefinition]) -> ToolDefinition {
    var description =
      "Call this function directly to discover tools and their arguments."
    description += " Search for a tool's name or capability, then use \(callAPIName) with its arguments to perform the task."
    if !hidden.isEmpty {
      let shown = hidden.prefix(maximumDescribedTools).map { "\($0.name) (\(blurb($0.description)))" }
      description += " They are: " + shown.joined(separator: "; ")
      if hidden.count > shown.count { description += "; and \(hidden.count - shown.count) more" }
      description += "."
    }
    var definition = ToolDefinition(
      name: listName,
      description: description,
      parameters: [
        ToolParameterDef(
          name: "keywords",
          type: "string",
          description: "Space-separated tool names or capabilities. Omit to browse tools. Put the user's search query in the discovered tool's arguments.",
          required: false)
      ],
      annotations: ToolAnnotations(
        readOnly: true, idempotent: true, openWorld: false, approval: .automatic))
    // Pythonic native parsers cannot represent a hyphenated function name.
    definition.providerName = listAPIName
    return definition
  }

  static let callDefinition: ToolDefinition = {
    var definition = ToolDefinition(
      name: callName,
      description:
        "Run a concrete tool by exact name with JSON arguments. Set name to the target tool, never \(callAPIName), and arguments to that tool's parameter object; do not wrap them in another name/arguments envelope. Call \(listAPIName) only when you need to discover a tool or its arguments. Some tools are callable by known name without appearing in discovery.",
      parameters: [
        ToolParameterDef(
          name: "name",
          type: "string",
          description: "Exact tool name.",
          required: true),
        ToolParameterDef(
          name: "arguments",
          type: "object",
          description: "JSON object with arguments for the selected tool. Use {} when none.",
          required: true),
      ],
      annotations: ToolAnnotations(approval: .automatic))
    definition.providerName = callAPIName
    return definition
  }()

  /// The first clause of a description, cut to a few words.
  static func blurb(_ description: String) -> String {
    let clause =
      description.split(whereSeparator: { $0 == "." || $0 == ";" || $0 == ":" }).first.map(String.init)
      ?? description
    let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 48 else { return trimmed }
    return String(trimmed.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
  }

  public static func listTools(
    arguments: [String: AgentToolArgumentValue],
    definitions: [ToolDefinition]
  ) -> String {
    let keywords =
      arguments["keywords"]?.stringValue ?? arguments["query"]?.stringValue
      ?? arguments["filter"]?.stringValue ?? ""
    let terms = keywords.lowercased().split { $0.isWhitespace || $0 == "," }.map(String.init)
    // A term found in the name outweighs one found somewhere in the text, so
    // "read" ranks files_read above every tool whose description mentions reading.
    let matches = definitions.compactMap { definition -> (ToolDefinition, Int)? in
      guard !terms.isEmpty else { return (definition, 0) }
      let name = definition.name.lowercased()
      let searchable = searchableText(for: definition)
      let score = terms.count(where: name.contains) * 2 + terms.count(where: searchable.contains)
      return score > 0 ? (definition, score) : nil
    }.sorted {
      $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 > $1.1
    }

    guard !matches.isEmpty else {
      let suffix =
        keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "" : " matching '\(keywords)'"
      guard !definitions.isEmpty else { return "No enabled tools\(suffix)." }
      // Models sometimes search discovery with the user's topic instead of
      // a capability. Show a bounded catalog so they can progress to a call.
      let available = definitions.sorted { $0.name < $1.name }.prefix(detailedMatches)
      var lines = [
        "No tool names or capabilities match '\(keywords)'. Available tool schemas:",
      ] + available.map { summary(for: $0) }
      if definitions.count > available.count {
        lines.append("\(definitions.count - available.count) more tools available; search by tool name or capability.")
      }
      lines.append("Use \(callAPIName) with one of these tool names and its arguments to perform the task.")
      return lines.joined(separator: "\n")
    }
    var lines = matches.prefix(detailedMatches).map { summary(for: $0.0) }
    let rest = matches.dropFirst(detailedMatches)
    if !rest.isEmpty {
      lines.append("Also matching, named only: " + rest.map(\.0.name).joined(separator: ", ") + ".")
      lines.append("Search again with a tool's name to see its arguments.")
    }
    return lines.joined(separator: "\n")
  }

  public static func resolveCall(
    arguments: [String: AgentToolArgumentValue],
    definitions: [ToolDefinition]
  ) -> (call: ParsedToolCall?, error: String?) {
    let arguments = normalizedArguments(arguments)
    var argumentValues = argumentObject(from: arguments["arguments"])
    // Some models put the name inside the arguments object instead of next
    // to it: {"arguments": {"name": T, "arguments": {...}}}.
    let requestedName = requestedToolName(in: arguments)
    let proxyName = proxyNames.canonicalName(for: requestedName)
    if proxyName == callName {
      return (nil, "Error: \(callAPIName) cannot call itself. Pass the concrete tool's name, or call \(listAPIName) directly for discovery.")
    }
    let resolver = AgentToolNameResolver(tools: definitions)
    let definition = proxyName == listName ? listDefinition(for: [])
      : resolver.canonicalName(for: requestedName).flatMap { name in
        definitions.first { $0.name == name }
      }
    guard let definition else {
      return (nil, "Error: unknown tool '\(requestedName)'. Call \(listAPIName) directly with relevant keywords.")
    }
    // Some models wrap the call twice: {"name": T, "arguments": {"name": T,
    // "arguments": {...}}}. The inner object is what they meant, unless the
    // tool really takes an argument called "arguments".
    let envelopeKeys: Set<String> = ["name", "tool", "tool_name", "arguments"]
    if let inner = argumentValues["arguments"],
      Set(argumentValues.keys).isSubset(of: envelopeKeys),
      !definition.parameters.contains(where: { $0.name == "arguments" })
    {
      argumentValues = argumentObject(from: inner)
    }
    if definition.name == listName, argumentValues["keywords"] == nil {
      argumentValues["keywords"] = argumentValues["query"] ?? argumentValues["filter"]
    }
    let normalized = AgentTooling.normalizeArguments(argumentValues, for: definition)
    return (
      ParsedToolCall(
        name: definition.name,
        arguments: [:],
        argumentValues: normalized,
        rawBlock: ""),
      nil
    )
  }

  /// Also used when identifying a concrete call in a saved proxy exchange.
  public static func requestedToolName(in arguments: [String: AgentToolArgumentValue]) -> String {
    let arguments = normalizedArguments(arguments)
    let outer =
      arguments["name"]?.stringValue ?? arguments["tool_name"]?.stringValue
      ?? arguments["tool"]?.stringValue ?? ""
    guard outer.isEmpty else { return outer }
    let inner = argumentObject(from: arguments["arguments"])
    return inner["name"]?.stringValue ?? inner["tool"]?.stringValue ?? ""
  }

  /// A native call already names call_tool. Some models repeat that envelope
  /// inside its parameters. Peel only complete proxy envelopes, stopping at
  /// the concrete tool so a skill's real `arguments` parameter stays intact.
  static func normalizedArguments(
    _ arguments: [String: AgentToolArgumentValue]
  ) -> [String: AgentToolArgumentValue] {
    var result = arguments
    let nameKeys = ["name", "tool_name", "tool"]
    let envelopeKeys = Set(nameKeys + ["arguments"])
    for _ in 0..<8 {
      let names = nameKeys.compactMap { result[$0]?.stringValue }
      guard Set(result.keys).isSubset(of: envelopeKeys),
        nameKeys.filter({ result[$0] != nil }).count == names.count,
        names.isEmpty || names.allSatisfy({ proxyNames.canonicalName(for: $0) == callName })
      else { break }
      let nested = argumentObject(from: result["arguments"])
      guard Set(nested.keys).isSubset(of: envelopeKeys),
        nameKeys.filter({ nested[$0] != nil }).count == 1,
        nameKeys.contains(where: { nested[$0]?.stringValue?.isEmpty == false }),
        nested["arguments"]?.objectValue != nil
          || nested["arguments"]?.stringValue.flatMap({
            ToolCallParsing.jsonObject(from: $0)
          }) != nil
      else { break }
      result = nested
    }
    return result
  }

  private static func searchableText(for definition: ToolDefinition) -> String {
    ([definition.name, definition.description]
      + definition.parameters.flatMap { [$0.name, $0.type, $0.description] })
      .joined(separator: " ")
      .lowercased()
  }

  private static func summary(for definition: ToolDefinition) -> String {
    let arguments =
      definition.parameters.isEmpty
      ? "no arguments"
      : definition.parameters.map { parameter in
        let required = parameter.required ? "required" : "optional"
        let detail = parameter.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(parameter.name) (\(parameter.type), \(required))"
          + (detail.isEmpty ? "" : " - \(detail)")
      }.joined(separator: "; ")
    return "- \(definition.name): \(definition.description) Arguments: \(arguments)."
  }

  private static func argumentObject(
    from value: AgentToolArgumentValue?
  ) -> [String: AgentToolArgumentValue] {
    if let object = value?.objectValue { return object }
    guard let string = value?.stringValue,
      let data = string.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return [:] }
    return decoded.objectValue ?? [:]
  }
}
