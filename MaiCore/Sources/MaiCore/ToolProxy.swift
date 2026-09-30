import Foundation

/// Reduces a large tool catalog to two stable tools. Hosts remain responsible
/// for executing the concrete call returned by `resolveCall`.
public enum ToolProxy {
  public static let listName = "list-tools"
  public static let callName = "call-tool"

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
  public static func definitions(
    for catalog: [ToolDefinition],
    exposing exposed: Set<String>? = nil
  ) -> [ToolDefinition] {
    let hidden = hiddenDefinitions(in: catalog, exposing: exposed)
    let visible = catalog.filter { !hidden.contains($0) }
    guard !hidden.isEmpty else { return visible }
    return visible + [listDefinition(for: hidden), callDefinition]
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
    "Tools not offered directly run through \(callName): {\"name\": TOOL, \"arguments\": {…}}; \(listName) describes their arguments."

  /// list-tools, describing what it reaches: each hidden tool's name and the
  /// start of its description, so the model knows what exists without paying
  /// for the schemas until it needs one.
  static func listDefinition(for hidden: [ToolDefinition]) -> ToolDefinition {
    var description =
      "Describe the arguments of the tools reachable through \(callName), by name or keyword."
    if !hidden.isEmpty {
      let shown = hidden.prefix(maximumDescribedTools).map { "\($0.name) (\(blurb($0.description)))" }
      description += " They are: " + shown.joined(separator: "; ")
      if hidden.count > shown.count { description += "; and \(hidden.count - shown.count) more" }
      description += "."
    }
    return ToolDefinition(
      name: listName,
      description: description,
      parameters: [
        ToolParameterDef(
          name: "keywords",
          type: "string",
          description: "Space-separated tool, capability, or argument keywords.",
          required: true)
      ],
      annotations: ToolAnnotations(
        readOnly: true, idempotent: true, openWorld: false, approval: .automatic))
  }

  static let callDefinition = ToolDefinition(
    name: callName,
    description:
      "Call one of the tools \(listName) describes, by exact name, with JSON arguments; they cannot be called directly. Use \(listName) first when the arguments are unknown.",
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
      return "No enabled tools\(suffix). Try broader keywords."
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
    var argumentValues = argumentObject(from: arguments["arguments"])
    // Some models put the name inside the arguments object instead of next
    // to it: {"arguments": {"name": T, "arguments": {...}}}.
    var requestedName =
      arguments["name"]?.stringValue ?? arguments["tool_name"]?.stringValue
      ?? arguments["tool"]?.stringValue ?? ""
    if requestedName.isEmpty,
      let inner = argumentValues["name"]?.stringValue ?? argumentValues["tool"]?.stringValue
    {
      requestedName = inner
    }
    let resolver = AgentToolNameResolver(tools: definitions)
    guard let canonicalName = resolver.canonicalName(for: requestedName) else {
      return (
        nil,
        "Error: unknown tool '\(requestedName)'. Call \(listName) first with relevant keywords."
      )
    }
    guard let definition = definitions.first(where: { $0.name == canonicalName }) else {
      return (nil, "Error: unknown tool '\(requestedName)'.")
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
    let normalized = AgentTooling.normalizeArguments(argumentValues, for: definition)
    return (
      ParsedToolCall(
        name: canonicalName,
        arguments: [:],
        argumentValues: normalized,
        rawBlock: ""),
      nil
    )
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
