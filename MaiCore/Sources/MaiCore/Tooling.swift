import Foundation

public enum ToolApprovalRequirement: String, Codable, Equatable, Sendable {
  case automatic
  case confirm
  case dangerous
}

public struct ToolAnnotations: Codable, Equatable, Sendable {
  public var title: String?
  public var readOnly: Bool
  public var destructive: Bool
  public var idempotent: Bool
  public var openWorld: Bool
  /// An asynchronous tool call: the run starts it and goes on to the next
  /// call of the same reply instead of waiting for it, so every concurrent
  /// call a reply makes runs at once — `agent_start` above all, so several
  /// children started in one reply work side by side. Results still join the
  /// transcript in call order. A tool that writes what a later call reads
  /// stays sequential, which is the default.
  public var concurrent: Bool
  public var approval: ToolApprovalRequirement

  public init(
    title: String? = nil,
    readOnly: Bool = false,
    destructive: Bool = false,
    idempotent: Bool = false,
    openWorld: Bool = true,
    concurrent: Bool = false,
    approval: ToolApprovalRequirement = .confirm
  ) {
    self.title = title
    self.readOnly = readOnly
    self.destructive = destructive
    self.idempotent = idempotent
    self.openWorld = openWorld
    self.concurrent = concurrent
    self.approval = approval
  }

  private enum CodingKeys: String, CodingKey {
    case title, readOnly, destructive, idempotent, openWorld, concurrent, approval
  }

  /// Every key is optional on the way in, so annotations written before
  /// `concurrent` existed — plugin manifests, saved tool catalogs — decode.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      title: try container.decodeIfPresent(String.self, forKey: .title),
      readOnly: try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false,
      destructive: try container.decodeIfPresent(Bool.self, forKey: .destructive) ?? false,
      idempotent: try container.decodeIfPresent(Bool.self, forKey: .idempotent) ?? false,
      openWorld: try container.decodeIfPresent(Bool.self, forKey: .openWorld) ?? true,
      concurrent: try container.decodeIfPresent(Bool.self, forKey: .concurrent) ?? false,
      approval: try container.decodeIfPresent(ToolApprovalRequirement.self, forKey: .approval)
        ?? .confirm)
  }
}

/// A compact, presentation-friendly view of one object-schema property.
///
/// Hosts that already have a full JSON Schema should use `ToolDefinition.inputSchema`.
/// This type exists for tools, configuration files, and UIs that define the common
/// flat object-schema shape.
public struct ToolParameterDef: Codable, Equatable, Sendable {
  public var name: String
  public var type: String
  public var description: String
  public var required: Bool

  public init(name: String, type: String, description: String, required: Bool) {
    self.name = name
    self.type = type
    self.description = description
    self.required = required
  }
}

public struct ToolDefinition: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var providerName: String?
  public var description: String
  public var inputSchema: JSONValue
  public var annotations: ToolAnnotations

  public var id: String { name }

  public init(
    name: String,
    providerName: String? = nil,
    description: String,
    inputSchema: JSONValue = .object(["type": .string("object")]),
    annotations: ToolAnnotations = .init()
  ) {
    self.name = name
    self.providerName = providerName
    self.description = description
    self.inputSchema = inputSchema
    self.annotations = annotations
  }

  /// Convenience initializer for hosts that describe tools as a flat parameter list.
  /// A non-empty raw schema takes precedence and preserves nested JSON Schema features.
  public init(
    name: String,
    description: String,
    parameters: [ToolParameterDef],
    inputSchemaJSON: String = "",
    annotations: ToolAnnotations = .init()
  ) {
    let rawSchema = inputSchemaJSON.data(using: .utf8).flatMap {
      try? JSONDecoder().decode(JSONValue.self, from: $0)
    }
    let schema = rawSchema?.objectValue == nil ? Self.schema(for: parameters) : rawSchema
    self.init(
      name: name,
      description: description,
      inputSchema: schema ?? .object([:]),
      annotations: annotations)
  }

  /// The flat properties exposed by this tool's object schema.
  public var parameters: [ToolParameterDef] {
    guard let schema = inputSchema.objectValue,
      let properties = schema["properties"]?.objectValue
    else { return [] }
    let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    return properties.keys.sorted().map { name in
      let property = properties[name]?.objectValue ?? [:]
      return ToolParameterDef(
        name: name,
        type: property["type"]?.stringValue ?? "string",
        description: property["description"]?.stringValue ?? "",
        required: required.contains(name))
    }
  }

  /// A compact JSON representation for APIs that accept raw JSON Schema strings.
  public var inputSchemaJSON: String { inputSchema.compactJSONString }

  private static func schema(for parameters: [ToolParameterDef]) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(
        Dictionary(
          uniqueKeysWithValues: parameters.map { parameter in
            (
              parameter.name,
              .object([
                "type": .string(parameter.type),
                "description": .string(parameter.description),
              ])
            )
          })),
      "required": .array(parameters.filter(\.required).map { .string($0.name) }),
    ])
  }
}

public struct ToolExecutionContext: Codable, Equatable, Sendable {
  public var run: AgentEventContext
  public var modelTurn: Int
  /// Suggested default for paged tools. Explicit page sizes still take precedence.
  public var suggestedOutputBytes: Int?

  public init(run: AgentEventContext, modelTurn: Int, suggestedOutputBytes: Int? = nil) {
    self.run = run
    self.modelTurn = modelTurn
    self.suggestedOutputBytes = suggestedOutputBytes
  }

  /// Share half the remaining compaction budget across this turn's tools.
  /// This is a sizing hint, not a tokenizer or a provider context-window guarantee.
  public static func suggestedOutputBytes(contextTokens: Int, usedTokens: Int, toolCalls: Int) -> Int? {
    guard contextTokens > 0 else { return nil }
    let remaining = max(0, contextTokens - max(0, usedTokens))
    let share = remaining / max(1, toolCalls) / 2
    return max(1024, min(8000, share) * 4)
  }
}

public protocol AgentTool: Sendable {
  var definition: ToolDefinition { get }

  func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput
}

public struct ToolOutput: Codable, Equatable, Sendable {
  public var content: [ContentPart]
  public var structuredContent: JSONValue?
  public var isError: Bool

  public init(
    content: [ContentPart],
    structuredContent: JSONValue? = nil,
    isError: Bool = false
  ) {
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
  }

  public init(text: String, isError: Bool = false) {
    self.init(content: [.text(text)], isError: isError)
  }

  public var text: String {
    content.compactMap(\.textValue).joined(separator: "\n")
  }
}

/// One line for a tool call as a person reads it: the tool name, then the
/// arguments with the path-like ones first, long values cut and multi-line
/// values folded to their first line. `→ files_patch shapes.py find="def
/// area…" replace="def area…"` says what happened; the JSON did not.
package enum ToolCallPreview {
  /// Arguments shown first, and shown bare when they are the only one.
  static let leadingKeys = ["path", "name", "query", "command", "script", "keywords", "task"]
  static let maximumValueLength = 60

  package static func render(_ call: ToolCall, maxLength: Int = 160) -> String {
    let arguments = call.arguments.objectValue ?? [:]
    var line = "→ \(call.name)"
    guard !arguments.isEmpty else { return line }
    let ordered = arguments.keys.sorted { a, b in
      let ia = leadingKeys.firstIndex(of: a) ?? leadingKeys.count
      let ib = leadingKeys.firstIndex(of: b) ?? leadingKeys.count
      return ia == ib ? a < b : ia < ib
    }
    let parts = ordered.map { key -> String in
      let value = summary(of: arguments[key] ?? .null)
      let bare = arguments.count == 1 && leadingKeys.contains(key)
      return bare ? value : "\(key)=\(value)"
    }
    line += " " + parts.joined(separator: " ")
    return ToolResultPreview.safeLine(line, maximumLength: max(1, maxLength))
  }

  static func summary(of value: JSONValue) -> String {
    guard case .string(let text) = value else { return value.compactJSONString }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var first = String(lines.first ?? "")
    if first.count > maximumValueLength {
      first = String(first.prefix(maximumValueLength)) + "…"
    }
    let quoted = first.isEmpty || first.contains(" ") || first.contains("=")
    var shown = quoted ? "\"\(first)\"" : first
    if lines.count > 1 { shown += " (+\(lines.count - 1) lines)" }
    return shown
  }
}

/// The result as the person wants to read it: the text itself, first line
/// after `←`, the rest indented, cut at `maxLines`. No heading line, because
/// the result is the point; `← done` only when nothing is to be shown.
package enum ToolResultPreview {
  package static func render(
    _ result: ToolResult,
    maxLines: Int,
    maxLineLength: Int = .max
  ) -> String {
    let compactHeading = result.isError ? "← error" : "← done"
    guard maxLines != 0 else { return compactHeading }
    var text = result.text
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let structured = result.structuredContent
    {
      text = structured.compactJSONString
    }
    text = text.trimmingCharacters(in: .newlines)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return result.isError ? compactHeading : "← (no output)"
    }
    let lines = text.components(separatedBy: .newlines)
    let shownCount = maxLines < 0 ? lines.count : min(lines.count, maxLines)
    var output: [String] = []
    for (index, line) in lines.prefix(shownCount).enumerated() {
      let safe = safeLine(line, maximumLength: max(1, maxLineLength))
      output.append(index == 0 ? "← \(safe)" : "  \(safe)")
    }
    if lines.count > shownCount {
      let remaining = lines.count - shownCount
      output.append("  … \(remaining) more line\(remaining == 1 ? "" : "s")")
    }
    return output.joined(separator: "\n")
  }

  static func safeLine(_ line: String, maximumLength: Int) -> String {
    let sanitized = line.unicodeScalars.map { scalar -> String in
      if scalar.value == 9 { return "  " }
      return CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }.joined()
    guard sanitized.count > maximumLength else { return sanitized }
    return String(sanitized.prefix(maximumLength)) + "…"
  }
}

public struct ClosureTool: AgentTool {
  public let definition: ToolDefinition
  private let operation: @Sendable (JSONValue, ToolExecutionContext) async throws -> ToolOutput

  public init(
    definition: ToolDefinition,
    operation: @escaping @Sendable (JSONValue, ToolExecutionContext) async throws -> ToolOutput
  ) {
    self.definition = definition
    self.operation = operation
  }

  public func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    try await operation(arguments, context)
  }
}

public struct ApprovalRequest: Equatable, Sendable {
  public var run: AgentEventContext
  public var tool: ToolDefinition
  public var call: ToolCall

  public init(run: AgentEventContext, tool: ToolDefinition, call: ToolCall) {
    self.run = run
    self.tool = tool
    self.call = call
  }
}

public enum ApprovalDecision: Equatable, Sendable {
  case approve(arguments: JSONValue)
  case deny(reason: String)
  case cancelRun
}

public protocol ApprovalHandler: Sendable {
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision
}

public struct DenyInteractiveApprovals: ApprovalHandler {
  public init() {}

  public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .deny(reason: "No approval handler is configured for '\(request.tool.name)'.")
  }
}

public struct AllowAllApprovals: ApprovalHandler {
  public init() {}

  public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .approve(arguments: request.call.arguments)
  }
}

public enum AgentToolError: LocalizedError, Equatable, Sendable {
  case invalidName
  case duplicateName(String)
  case unavailable(String)
  case invalidArguments(tool: String, reason: String)
  case executionFailed(tool: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .invalidName:
      "Tool names cannot be empty."
    case .duplicateName(let name):
      "Tool '\(name)' is already registered."
    case .unavailable(let name):
      "Tool '\(name)' is not registered."
    case .invalidArguments(let tool, let reason):
      "Invalid arguments for '\(tool)': \(reason)"
    case .executionFailed(let tool, let reason):
      "Tool '\(tool)' failed: \(reason)"
    }
  }
}

enum ToolSchemaValidator {
  /// Coerce unambiguous boolean spellings without dropping invalid or unknown fields.
  static func coerceBooleans(_ value: JSONValue, schema: JSONValue) -> JSONValue {
    guard let schema = schema.objectValue else { return value }
    if schema["type"]?.stringValue == "boolean", let bool = value.coercedBoolValue {
      return .bool(bool)
    }
    if let object = value.objectValue, let properties = schema["properties"]?.objectValue {
      return .object(object.reduce(into: [:]) { result, entry in
        result[entry.key] = properties[entry.key].map {
          coerceBooleans(entry.value, schema: $0)
        } ?? entry.value
      })
    }
    if let array = value.arrayValue, let items = schema["items"] {
      return .array(array.map { coerceBooleans($0, schema: items) })
    }
    return value
  }

  static func validate(arguments: JSONValue, definition: ToolDefinition) -> String? {
    guard arguments.objectValue != nil else { return "arguments must be a JSON object" }
    return validate(arguments, schema: definition.inputSchema, path: "arguments")
  }

  private static func validate(_ value: JSONValue, schema: JSONValue, path: String) -> String? {
    guard let schema = schema.objectValue else { return nil }
    if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
      return "\(path) must be one of the schema's allowed values"
    }
    if let expected = schema["type"]?.stringValue, !matches(value, type: expected) {
      return "\(path) must be \(expected)"
    }
    if let object = value.objectValue {
      let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let properties = schema["properties"]?.objectValue ?? [:]
      // Naming what arrived and what the tool takes lets a model fix the
      // call on its next try instead of guessing at field names.
      let accepted = properties.keys.sorted().map { required.contains($0) ? "\($0) (required)" : $0 }
      let received = object.keys.sorted()
      let shape =
        path == "arguments"
        ? (received.isEmpty ? ". No fields were given" : ". Received: \(received.joined(separator: ", "))")
          + (accepted.isEmpty ? "" : ". Accepted fields: \(accepted.joined(separator: ", "))")
        : ""
      let missing = required.filter { object[$0] == nil }
      if !missing.isEmpty {
        return
          "missing required field\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", "))"
          + shape
      }
      if schema["additionalProperties"]?.boolValue == false {
        let unknown = object.keys.filter { properties[$0] == nil }.sorted()
        if !unknown.isEmpty {
          return
            "unknown field\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", "))"
            + shape
        }
      }
      for (name, propertySchema) in properties {
        if let property = object[name],
          let error = validate(property, schema: propertySchema, path: "\(path).\(name)")
        {
          return error
        }
      }
    }
    if let array = value.arrayValue, let itemSchema = schema["items"] {
      for (index, item) in array.enumerated() {
        if let error = validate(item, schema: itemSchema, path: "\(path)[\(index)]") {
          return error
        }
      }
    }
    return nil
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("object", .object), ("array", .array), ("string", .string),
      ("integer", .integer), ("number", .integer), ("number", .number),
      ("boolean", .bool), ("null", .null):
      true
    default:
      false
    }
  }
}
