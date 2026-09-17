import Foundation

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.init(rawValue: rawValue) }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { rawValue }

  public static let hello: ProviderID = "hello"
  public static let openAI: ProviderID = "openai"
}

public struct ProviderCapabilities: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt

  public init(rawValue: UInt) { self.rawValue = rawValue }

  public static let streaming = ProviderCapabilities(rawValue: 1 << 0)
  public static let nativeToolCalling = ProviderCapabilities(rawValue: 1 << 1)
  public static let imageInput = ProviderCapabilities(rawValue: 1 << 2)
  public static let reasoning = ProviderCapabilities(rawValue: 1 << 3)
  public static let structuredOutput = ProviderCapabilities(rawValue: 1 << 4)
  public static let audioInput = ProviderCapabilities(rawValue: 1 << 5)
  public static let fileInput = ProviderCapabilities(rawValue: 1 << 6)
}

public struct ProviderDescriptor: Codable, Equatable, Sendable {
  public var id: ProviderID
  public var displayName: String
  public var capabilities: ProviderCapabilities

  public init(
    id: ProviderID,
    displayName: String,
    capabilities: ProviderCapabilities = []
  ) {
    self.id = id
    self.displayName = displayName
    self.capabilities = capabilities
  }
}

public struct ModelDescriptor: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var ownedBy: String?
  public var capabilities: ProviderCapabilities
  /// Modalities explicitly declared by the model catalog. Nil means unknown.
  public var inputModalities: Set<String>?

  public init(
    id: String,
    displayName: String? = nil,
    ownedBy: String? = nil,
    capabilities: ProviderCapabilities = [],
    inputModalities: Set<String>? = nil
  ) {
    self.id = id
    self.displayName = displayName ?? id
    self.ownedBy = ownedBy
    self.capabilities = capabilities
    self.inputModalities = inputModalities
  }

  private enum CodingKeys: String, CodingKey {
    case id, displayName, ownedBy, capabilities, inputModalities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    self.init(
      id: id,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      ownedBy: try container.decodeIfPresent(String.self, forKey: .ownedBy),
      capabilities: try container.decodeIfPresent(
        ProviderCapabilities.self, forKey: .capabilities) ?? [],
      inputModalities: try container.decodeIfPresent(
        Set<String>.self, forKey: .inputModalities))
  }
}

public enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int)
  case number(Double)
  case bool(Bool)
  case null

  public init(json: Any) {
    guard
      let data = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      self = .null
      return
    }
    self = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value.")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public static func object(_ pairs: (String, JSONValue)...) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: pairs))
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    switch self {
    case .integer(let value): value
    case .number(let value): Int(exactly: value)
    default: nil
    }
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var numberValue: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .number(let value): value
    default: nil
    }
  }

  public var coercedStringValue: String {
    switch self {
    case .string(let value): value
    case .integer(let value): String(value)
    case .number(let value): String(value)
    case .bool(let value): value ? "true" : "false"
    case .object, .array: compactJSONString
    case .null: ""
    }
  }

  public var coercedNumberValue: Double? {
    numberValue
      ?? stringValue.flatMap {
        Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
      }
  }

  public var coercedBoolValue: Bool? {
    if let boolValue { return boolValue }
    if intValue == 0 { return false }
    if intValue == 1 { return true }
    switch stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "yes", "on": return true
    case "false", "0", "no", "off": return false
    default: return nil
    }
  }

  public var jsonObject: Any {
    switch self {
    case .object(let value): value.mapValues(\.jsonObject)
    case .array(let value): value.map(\.jsonObject)
    case .string(let value): value
    case .integer(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .null: NSNull()
    }
  }

  /// Keys are sorted so the same value renders the same way every time: a
  /// tool result that reaches the model through this text must not change
  /// between requests, or the server's prompt cache misses from that message on.
  public var compactJSONString: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else { return "null" }
    return string
  }
}

public enum AgentRole: String, Codable, Sendable {
  case system
  case developer
  case user
  case assistant
  case tool
}

public enum ImageDetail: String, Codable, Sendable {
  case automatic = "auto"
  case low
  case high
}

public enum BinarySource: Codable, Equatable, Sendable {
  case data(Data)
  case url(URL)
}

public struct ImageContent: Codable, Equatable, Sendable {
  public var source: BinarySource
  public var mimeType: String
  public var name: String?
  public var width: Int?
  public var height: Int?
  public var detail: ImageDetail

  public init(
    source: BinarySource,
    mimeType: String,
    name: String? = nil,
    width: Int? = nil,
    height: Int? = nil,
    detail: ImageDetail = .automatic
  ) {
    self.source = source
    self.mimeType = mimeType
    self.name = name
    self.width = width
    self.height = height
    self.detail = detail
  }
}

public struct FileContent: Codable, Equatable, Sendable {
  public var source: BinarySource?
  public var text: String?
  public var mimeType: String
  public var name: String

  public init(
    name: String,
    mimeType: String,
    source: BinarySource? = nil,
    text: String? = nil
  ) {
    self.source = source
    self.text = text
    self.mimeType = mimeType
    self.name = name
  }
}

public struct AudioContent: Codable, Equatable, Sendable {
  public var source: BinarySource
  public var mimeType: String
  public var name: String?

  public init(source: BinarySource, mimeType: String, name: String? = nil) {
    self.source = source
    self.mimeType = mimeType
    self.name = name
  }
}

public struct ResourceContent: Codable, Equatable, Sendable {
  public var uri: String
  public var name: String?
  public var mimeType: String?
  public var text: String?
  public var blob: Data?

  public init(
    uri: String,
    name: String? = nil,
    mimeType: String? = nil,
    text: String? = nil,
    blob: Data? = nil
  ) {
    self.uri = uri
    self.name = name
    self.mimeType = mimeType
    self.text = text
    self.blob = blob
  }
}

public struct ToolCall: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct ToolResult: Codable, Equatable, Sendable {
  public var callID: String
  public var content: [ContentPart]
  public var structuredContent: JSONValue?
  public var isError: Bool

  public init(
    callID: String,
    content: [ContentPart],
    structuredContent: JSONValue? = nil,
    isError: Bool = false
  ) {
    self.callID = callID
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
  }

  public init(callID: String, text: String, isError: Bool = false) {
    self.init(callID: callID, content: [.text(text)], isError: isError)
  }

  public var text: String {
    content.compactMap(\.textValue).joined(separator: "\n")
  }
}

public enum ContentPart: Codable, Equatable, Sendable {
  case text(String)
  case image(ImageContent)
  case file(FileContent)
  case audio(AudioContent)
  case resource(ResourceContent)
  case reasoning(String)
  case toolCall(ToolCall)
  case toolResult(ToolResult)

  public var textValue: String? {
    switch self {
    case .text(let value), .reasoning(let value): value
    case .file(let value): value.text
    case .resource(let value): value.text
    case .toolResult(let value): value.text
    case .image, .audio, .toolCall: nil
    }
  }
}

public struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var role: AgentRole
  public var content: [ContentPart]

  public init(
    id: String = UUID().uuidString,
    role: AgentRole,
    content: [ContentPart]
  ) {
    self.id = id
    self.role = role
    self.content = content
  }

  public init(id: String = UUID().uuidString, role: AgentRole, content: String) {
    self.init(id: id, role: role, content: [.text(content)])
  }

  public static func system(_ content: String) -> AgentMessage {
    AgentMessage(role: .system, content: content)
  }

  public static func developer(_ content: String) -> AgentMessage {
    AgentMessage(role: .developer, content: content)
  }

  public static func user(_ content: String) -> AgentMessage {
    AgentMessage(role: .user, content: content)
  }

  public static func assistant(_ content: String) -> AgentMessage {
    AgentMessage(role: .assistant, content: content)
  }

  public var text: String {
    content.compactMap { part -> String? in
      switch part {
      case .text(let value): value
      case .file(let value): value.text
      case .resource(let value): value.text
      default: nil
      }
    }.joined(separator: "\n")
  }

  public var reasoning: String {
    content.compactMap { part in
      guard case .reasoning(let value) = part else { return nil }
      return value
    }.joined()
  }

  public var imageInputCount: Int {
    content.reduce(0) { count, part in
      if case .image = part { count + 1 } else { count }
    }
  }

  public var toolCalls: [ToolCall] {
    content.compactMap { part in
      guard case .toolCall(let value) = part else { return nil }
      return value
    }
  }

  public var toolResults: [ToolResult] {
    content.compactMap { part in
      guard case .toolResult(let value) = part else { return nil }
      return value
    }
  }

  public mutating func appendText(_ text: String) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    if let index = content.firstIndex(where: { if case .text = $0 { true } else { false } }),
      case .text(let existing) = content[index]
    {
      content[index] = .text(existing.isEmpty ? value : "\(existing)\n\n\(value)")
    } else {
      content.insert(.text(value), at: 0)
    }
  }
}

public struct TokenUsage: Codable, Equatable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int
  public var cachedTokens: Int?
  public var reasoningTokens: Int?
  /// True when the numbers were estimated from text length because the
  /// provider reported no usage. Hosts show such counts with a `~`.
  public var isEstimated: Bool

  public init(
    inputTokens: Int,
    outputTokens: Int,
    totalTokens: Int? = nil,
    cachedTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    isEstimated: Bool = false
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens ?? inputTokens + outputTokens
    self.cachedTokens = cachedTokens
    self.reasoningTokens = reasoningTokens
    self.isEstimated = isEstimated
  }

  /// Usage guessed from text length, for a call whose provider reported none.
  public static func estimated(inputTokens: Int, outputTokens: Int) -> TokenUsage {
    TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens, isEstimated: true)
  }

  private enum CodingKeys: String, CodingKey {
    case inputTokens, outputTokens, totalTokens, cachedTokens, reasoningTokens, isEstimated
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
      outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
      totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens),
      cachedTokens: try container.decodeIfPresent(Int.self, forKey: .cachedTokens),
      reasoningTokens: try container.decodeIfPresent(Int.self, forKey: .reasoningTokens),
      isEstimated: try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false)
  }
}

public struct ToolCallDelta: Codable, Equatable, Sendable {
  public var index: Int
  public var id: String?
  public var name: String?
  public var argumentsFragment: String

  public init(index: Int, id: String? = nil, name: String? = nil, argumentsFragment: String = "") {
    self.index = index
    self.id = id
    self.name = name
    self.argumentsFragment = argumentsFragment
  }
}

public enum ProviderEvent: Codable, Equatable, Sendable {
  case textDelta(String)
  case reasoningDelta(String)
  case toolCallDelta(ToolCallDelta)
  /// The call's token usage, sent once per call when the provider reports
  /// it — after the last delta of a stream — so a host may add these up.
  case usage(TokenUsage)
}

public enum ProviderStopReason: String, Codable, Sendable {
  case stop
  case length
  case toolCall
  case contentFilter
  case cancelled
  case unknown
}

public enum ToolChoice: Codable, Equatable, Sendable {
  case automatic
  case none
  case required
  case tool(String)

  public init(from decoder: Decoder) throws {
    let value = try JSONValue(from: decoder)
    if let string = value.stringValue {
      switch string {
      case "auto", "automatic": self = .automatic
      case "none": self = .none
      case "required": self = .required
      default:
        throw DecodingError.dataCorrupted(
          .init(
            codingPath: decoder.codingPath, debugDescription: "Unknown tool choice '\(string)'."))
      }
      return
    }
    if let name = value.objectValue?["tool"]?.stringValue {
      self = .tool(name)
      return
    }
    throw DecodingError.dataCorrupted(
      .init(codingPath: decoder.codingPath, debugDescription: "Invalid tool choice."))
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .automatic: try JSONValue.string("auto").encode(to: encoder)
    case .none: try JSONValue.string("none").encode(to: encoder)
    case .required: try JSONValue.string("required").encode(to: encoder)
    case .tool(let name): try JSONValue.object(["tool": .string(name)]).encode(to: encoder)
    }
  }
}

public enum ToolCallingStrategy: String, Codable, Equatable, Sendable {
  case automatic
  case native
  case text
  case xml
  case json
}

public enum ResponseFormat: Codable, Equatable, Sendable {
  case text
  case jsonObject
  case jsonSchema(name: String, schema: JSONValue, strict: Bool)

  public init(from decoder: Decoder) throws {
    let value = try JSONValue(from: decoder)
    if let string = value.stringValue {
      switch string {
      case "text": self = .text
      case "json", "jsonObject": self = .jsonObject
      default:
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "Unknown response format."))
      }
      return
    }
    guard let object = value.objectValue,
      object["type"]?.stringValue == "jsonSchema",
      let name = object["name"]?.stringValue,
      let schema = object["schema"]
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid response format."))
    }
    self = .jsonSchema(name: name, schema: schema, strict: object["strict"]?.boolValue ?? true)
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .text:
      try JSONValue.string("text").encode(to: encoder)
    case .jsonObject:
      try JSONValue.string("jsonObject").encode(to: encoder)
    case .jsonSchema(let name, let schema, let strict):
      try JSONValue.object([
        "type": .string("jsonSchema"),
        "name": .string(name),
        "schema": schema,
        "strict": .bool(strict),
      ]).encode(to: encoder)
    }
  }
}

public struct GenerationOptions: Codable, Equatable, Sendable {
  public var temperature: Double?
  public var maxOutputTokens: Int?
  /// A `ReasoningEffort` name (`automatic`, `disabled`, `minimal` … `max`), which the runtime turns into a
  /// system prompt section and a provider into the fields its API family
  /// understands; or a provider's own value, sent as `reasoning_effort` as it
  /// is.
  public var reasoningEffort: String?
  /// Extra guidance for the system prompt that goes with the effort, as
  /// `/set effort LEVEL TEXT` sets it.
  public var reasoningGuidance: String?
  public var includeStreamUsage: Bool
  public var additional: [String: JSONValue]

  public init(
    temperature: Double? = nil,
    maxOutputTokens: Int? = nil,
    reasoningEffort: String? = nil,
    reasoningGuidance: String? = nil,
    includeStreamUsage: Bool = true,
    additional: [String: JSONValue] = [:]
  ) {
    self.temperature = temperature
    self.maxOutputTokens = maxOutputTokens
    self.reasoningEffort = reasoningEffort
    self.reasoningGuidance = reasoningGuidance
    self.includeStreamUsage = includeStreamUsage
    self.additional = additional
  }

  private enum CodingKeys: String, CodingKey {
    case temperature, maxOutputTokens, reasoningEffort, reasoningGuidance, includeStreamUsage
    case additional
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
      maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens),
      reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort),
      reasoningGuidance: try container.decodeIfPresent(String.self, forKey: .reasoningGuidance),
      includeStreamUsage: try container.decodeIfPresent(Bool.self, forKey: .includeStreamUsage)
        ?? true,
      additional: try container.decodeIfPresent(
        [String: JSONValue].self,
        forKey: .additional) ?? [:])
  }
}

public struct ProviderRequest: Codable, Sendable {
  public var model: String
  public var messages: [AgentMessage]
  public var tools: [ToolDefinition]
  public var toolChoice: ToolChoice
  public var responseFormat: ResponseFormat
  public var options: GenerationOptions
  public var stream: Bool
  /// The session of the chat this request belongs to (see `ChatSession`), for
  /// transports whose headers carry it (`{{session}}` in a configured
  /// header). Nil for a request outside any chat, such as a one-shot prompt.
  public var sessionID: String?

  public init(
    model: String,
    messages: [AgentMessage],
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic,
    responseFormat: ResponseFormat = .text,
    options: GenerationOptions = .init(),
    stream: Bool = true,
    sessionID: String? = nil
  ) {
    self.model = model
    self.messages = messages
    self.tools = tools
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
    self.options = options
    self.stream = stream
    self.sessionID = sessionID
  }
}

public struct ProviderResponse: Codable, Equatable, Sendable {
  public var message: AgentMessage
  public var usage: TokenUsage?
  public var stopReason: ProviderStopReason

  public init(
    message: AgentMessage,
    usage: TokenUsage? = nil,
    stopReason: ProviderStopReason = .unknown
  ) {
    self.message = message
    self.usage = usage
    self.stopReason = stopReason
  }

  public var reasoning: String { message.reasoning }
}

/// How much one run may do. Reaching a limit is not an error: the run stops
/// at its next turn boundary with `AgentResult.interruption` set and a
/// transcript a host can continue from, so a long task is paused, not lost.
public struct AgentRunLimits: Codable, Equatable, Sendable {
  public static let defaultMaxToolCalls = 50
  /// Text tool protocols use one model turn per call and still need a final reply.
  public static let defaultMaxModelTurns = defaultMaxToolCalls + 10

  public var maxModelTurns: Int
  public var maxToolCalls: Int
  /// Children that may run at once per parent process. Excess children wait
  /// in the `queued` state for a slot instead of being refused.
  public var maxSubagents: Int
  public var maxSubagentDepth: Int
  public var maxTotalTokens: Int?
  /// Wall-clock seconds the whole run, children included, may take. Nil
  /// leaves it open-ended.
  public var maxSeconds: Int?

  public init(
    maxModelTurns: Int = defaultMaxModelTurns,
    maxToolCalls: Int = defaultMaxToolCalls,
    maxSubagents: Int = 5,
    maxSubagentDepth: Int = 5,
    maxTotalTokens: Int? = nil,
    maxSeconds: Int? = nil
  ) {
    self.maxModelTurns = max(1, maxModelTurns)
    self.maxToolCalls = max(0, maxToolCalls)
    self.maxSubagents = max(0, maxSubagents)
    self.maxSubagentDepth = max(0, maxSubagentDepth)
    self.maxTotalTokens = maxTotalTokens.map { max(1, $0) }
    self.maxSeconds = maxSeconds.flatMap { $0 > 0 ? $0 : nil }
  }

  private enum CodingKeys: String, CodingKey {
    case maxModelTurns, maxToolCalls, maxSubagents, maxSubagentDepth, maxTotalTokens, maxSeconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      maxModelTurns: try container.decodeIfPresent(Int.self, forKey: .maxModelTurns)
        ?? Self.defaultMaxModelTurns,
      maxToolCalls: try container.decodeIfPresent(Int.self, forKey: .maxToolCalls)
        ?? Self.defaultMaxToolCalls,
      maxSubagents: try container.decodeIfPresent(Int.self, forKey: .maxSubagents) ?? 5,
      maxSubagentDepth: try container.decodeIfPresent(Int.self, forKey: .maxSubagentDepth) ?? 5,
      maxTotalTokens: try container.decodeIfPresent(Int.self, forKey: .maxTotalTokens),
      maxSeconds: try container.decodeIfPresent(Int.self, forKey: .maxSeconds))
  }
}

/// What to do when a model call fails for a reason that is not the run's own
/// doing — a dropped connection, a 5xx, a rate limit. The call is repeated
/// after `delaySeconds`, up to `attempts` more times, before the run fails.
public struct AgentRetryPolicy: Codable, Equatable, Sendable {
  public static let defaultAttempts = 2
  public static let defaultDelaySeconds = 5.0

  /// Extra tries after the first failure. Zero fails on the first error.
  public var attempts: Int
  public var delaySeconds: Double

  public init(attempts: Int = defaultAttempts, delaySeconds: Double = defaultDelaySeconds) {
    self.attempts = max(0, attempts)
    self.delaySeconds = max(0, delaySeconds)
  }

  /// Never retry, for callers that want the first error immediately.
  public static let none = AgentRetryPolicy(attempts: 0, delaySeconds: 0)

  private enum CodingKeys: String, CodingKey { case attempts, delaySeconds }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      attempts: try container.decodeIfPresent(Int.self, forKey: .attempts) ?? Self.defaultAttempts,
      delaySeconds: try container.decodeIfPresent(Double.self, forKey: .delaySeconds)
        ?? Self.defaultDelaySeconds)
  }
}

/// When the runtime folds the older part of a transcript into a summary on
/// its own, before a model turn, so a long task keeps fitting in the model's
/// context. Context windows differ per model and most providers do not say
/// how big theirs is, so the trigger is an absolute token count rather than
/// a percentage.
/// What a run optimises its conversation for. `cache` never touches a message
/// once sent, so a server's prompt cache covers every earlier turn; `size`
/// replaces the bodies of files read in earlier turns with a one-line
/// reference before each model call, at the price of invalidating the cache
/// from that message on.
public enum AgentContextMode: String, Codable, Equatable, Sendable {
  case cache
  case size
}

public struct AgentAutocompact: Codable, Equatable, Sendable {
  /// Estimated tokens in the conversation at which compaction runs. Zero
  /// turns it off.
  public var tokens: Int

  public init(tokens: Int = 64_000) {
    self.tokens = max(0, tokens)
  }

  public var isEnabled: Bool { tokens > 0 }

  private enum CodingKeys: String, CodingKey { case tokens }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(tokens: try container.decodeIfPresent(Int.self, forKey: .tokens) ?? 64_000)
  }
}

/// Why a run stopped before the model gave a final answer. The transcript in
/// the result ends at a turn boundary — a user message or the results of the
/// last tool calls — so running it again picks the task up where it paused.
public enum AgentRunInterruption: Equatable, Sendable {
  /// `limits.maxModelTurns` was reached.
  case modelTurns(limit: Int)
  /// `limits.maxTotalTokens` was reached.
  case totalTokens(limit: Int)
  /// `limits.maxSeconds` passed.
  case time(limitSeconds: Int)

  /// `model turn limit (50) reached`
  public var summary: String {
    switch self {
    case .modelTurns(let limit): "model turn limit (\(limit)) reached"
    case .totalTokens(let limit): "token budget (\(limit)) spent"
    case .time(let seconds): "time limit (\(ModelUsageFormat.duration(Double(seconds)))) reached"
    }
  }

  /// The `/set` key a person would raise to get further in one go.
  public var settingKey: String {
    switch self {
    case .modelTurns: "limits.maxModelTurns"
    case .totalTokens: "limits.maxTotalTokens"
    case .time: "limits.maxSeconds"
    }
  }

  /// A turn budget is a checkpoint: continuing costs nothing but another
  /// budget. Time and token caps are what a person set to stop the spend,
  /// so a host should not continue past them on its own.
  public var isCheckpoint: Bool {
    if case .modelTurns = self { return true }
    return false
  }
}

public struct AgentDefinition: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  /// What this agent is for, in one line. People read it when picking a setup;
  /// a delegating model reads it to choose an agent for a task, so write it as
  /// a capability ("reads code and finds definitions"), not as a label.
  public var description: String
  /// Disabled agents stay in the file but are hidden from pickers and are never
  /// offered as subagents, so a setup can be parked without deleting it.
  public var isEnabled: Bool
  public var instructions: String
  /// Name of the reusable system prompt that supplies `instructions`.
  public var systemPrompt: String?
  public var provider: ProviderID
  public var model: String
  public var toolNames: Set<String>
  public var toolGroupNames: Set<String>
  public var subagentNames: Set<String>
  public var stream: Bool
  public var limits: AgentRunLimits
  public var toolChoice: ToolChoice
  public var responseFormat: ResponseFormat
  public var options: GenerationOptions
  public var toolCallingStrategy: ToolCallingStrategy
  public var useToolProxy: Bool
  /// With the proxy on, the tools still offered natively; nil means
  /// `ToolProxy.defaultExposedNames`, an empty set hides them all.
  public var proxyExposedTools: Set<String>?
  /// Whether this agent runs its tools itself or delegates them to a child.
  public var toolDelegation: AgentToolDelegation
  /// How failed model calls are repeated before the run gives up.
  public var retry: AgentRetryPolicy
  /// When the runtime summarizes the older part of a conversation by itself.
  public var autocompact: AgentAutocompact
  /// Whether the run keeps every message as sent (cache) or prunes consumed
  /// file bodies before each call (size).
  public var context: AgentContextMode

  public init(
    id: String,
    displayName: String? = nil,
    description: String = "",
    isEnabled: Bool = true,
    instructions: String,
    systemPrompt: String? = nil,
    provider: ProviderID,
    model: String,
    toolNames: Set<String> = [],
    toolGroupNames: Set<String> = [],
    subagentNames: Set<String> = [],
    stream: Bool = true,
    limits: AgentRunLimits = .init(),
    toolChoice: ToolChoice = .automatic,
    responseFormat: ResponseFormat = .text,
    options: GenerationOptions = .init(),
    toolCallingStrategy: ToolCallingStrategy = .automatic,
    useToolProxy: Bool = false,
    proxyExposedTools: Set<String>? = nil,
    toolDelegation: AgentToolDelegation = .inline,
    retry: AgentRetryPolicy = .init(),
    autocompact: AgentAutocompact = .init(),
    context: AgentContextMode = .cache
  ) {
    self.id = id
    self.displayName = displayName ?? id
    self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    self.isEnabled = isEnabled
    self.instructions = instructions
    self.systemPrompt = systemPrompt
    self.provider = provider
    self.model = model
    self.toolNames = toolNames
    self.toolGroupNames = toolGroupNames
    self.subagentNames = subagentNames
    self.stream = stream
    self.limits = limits
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
    self.options = options
    self.toolCallingStrategy = toolCallingStrategy
    self.useToolProxy = useToolProxy
    self.proxyExposedTools = proxyExposedTools
    self.toolDelegation = toolDelegation
    self.retry = retry
    self.autocompact = autocompact
    self.context = context
  }

  private enum CodingKeys: String, CodingKey {
    case id, displayName, instructions, systemPrompt, provider, model, toolNames, toolGroupNames,
      subagentNames, stream, limits
    case toolChoice, responseFormat, options, toolCallingStrategy, useToolProxy, proxyExposedTools,
      toolDelegation
    case description
    case isEnabled = "enabled"
    case retry, autocompact, context
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    self.init(
      id: id,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
      isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
      instructions: try container.decodeIfPresent(String.self, forKey: .instructions) ?? "",
      systemPrompt: try container.decodeIfPresent(String.self, forKey: .systemPrompt),
      provider: try container.decode(ProviderID.self, forKey: .provider),
      model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
      toolNames: try container.decodeIfPresent(Set<String>.self, forKey: .toolNames) ?? [],
      toolGroupNames: try container.decodeIfPresent(Set<String>.self, forKey: .toolGroupNames)
        ?? [],
      subagentNames: try container.decodeIfPresent(Set<String>.self, forKey: .subagentNames) ?? [],
      stream: try container.decodeIfPresent(Bool.self, forKey: .stream) ?? true,
      limits: try container.decodeIfPresent(AgentRunLimits.self, forKey: .limits) ?? .init(),
      toolChoice: try container.decodeIfPresent(ToolChoice.self, forKey: .toolChoice) ?? .automatic,
      responseFormat: try container.decodeIfPresent(ResponseFormat.self, forKey: .responseFormat)
        ?? .text,
      options: try container.decodeIfPresent(GenerationOptions.self, forKey: .options) ?? .init(),
      toolCallingStrategy: try container.decodeIfPresent(
        ToolCallingStrategy.self,
        forKey: .toolCallingStrategy) ?? .automatic,
      useToolProxy: try container.decodeIfPresent(Bool.self, forKey: .useToolProxy) ?? false,
      proxyExposedTools: try container.decodeIfPresent(Set<String>.self, forKey: .proxyExposedTools),
      toolDelegation: try container.decodeIfPresent(
        AgentToolDelegation.self,
        forKey: .toolDelegation) ?? .inline,
      retry: try container.decodeIfPresent(AgentRetryPolicy.self, forKey: .retry) ?? .init(),
      autocompact: try container.decodeIfPresent(AgentAutocompact.self, forKey: .autocompact)
        ?? .init(),
      context: try container.decodeIfPresent(AgentContextMode.self, forKey: .context) ?? .cache)
  }
}

public struct AgentRequest: Sendable {
  /// Inbox entries held for a later run. New messages still steer this run.
  public var ignoredQueuedMessageIDs: Set<UUID> = []
  public var agentID: String
  public var provider: ProviderID
  public var model: String
  public var messages: [AgentMessage]
  public var toolNames: Set<String>
  /// Nil keeps source compatibility for callers that construct requests
  /// directly. Hosts set this from the agent profile so runtime-native tool
  /// groups can enforce the same permissions as registered tools.
  public var toolGroupNames: Set<String>?
  public var subagentNames: Set<String>
  public var toolChoice: ToolChoice
  public var responseFormat: ResponseFormat
  public var options: GenerationOptions
  public var limits: AgentRunLimits
  public var stream: Bool
  public var toolCallingStrategy: ToolCallingStrategy
  public var useToolProxy: Bool
  public var proxyExposedTools: Set<String>?
  public var toolDelegation: AgentToolDelegation
  public var retry: AgentRetryPolicy
  public var autocompact: AgentAutocompact
  public var context: AgentContextMode
  /// The session of the chat this run belongs to (see `ChatSession`). Every
  /// provider call the run makes, and every child it starts, carries it, so a
  /// header configured with `{{session}}` sends one value for the whole chat.
  public var sessionID: String?

  public init(
    agentID: String = "main",
    provider: ProviderID,
    model: String = "",
    messages: [AgentMessage],
    toolNames: Set<String> = [],
    toolGroupNames: Set<String>? = nil,
    subagentNames: Set<String> = [],
    toolChoice: ToolChoice = .automatic,
    responseFormat: ResponseFormat = .text,
    options: GenerationOptions = .init(),
    limits: AgentRunLimits = .init(),
    stream: Bool = true,
    toolCallingStrategy: ToolCallingStrategy = .automatic,
    useToolProxy: Bool = false,
    proxyExposedTools: Set<String>? = nil,
    toolDelegation: AgentToolDelegation = .inline,
    retry: AgentRetryPolicy = .init(),
    autocompact: AgentAutocompact = .init(),
    context: AgentContextMode = .cache,
    sessionID: String? = nil
  ) {
    self.agentID = agentID
    self.provider = provider
    self.model = model
    self.messages = messages
    self.toolNames = toolNames
    self.toolGroupNames = toolGroupNames
    self.subagentNames = subagentNames
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
    self.options = options
    self.limits = limits
    self.stream = stream
    self.toolCallingStrategy = toolCallingStrategy
    self.useToolProxy = useToolProxy
    self.proxyExposedTools = proxyExposedTools
    self.toolDelegation = toolDelegation
    self.retry = retry
    self.autocompact = autocompact
    self.context = context
    self.sessionID = sessionID
  }
}

public struct AgentResult: Equatable, Sendable {
  public var runID: UUID
  public var agentID: String
  public var provider: ProviderID
  public var response: AgentMessage
  public var transcript: [AgentMessage]
  public var usage: TokenUsage?
  public var stopReason: ProviderStopReason
  public var modelTurns: Int
  public var toolCalls: Int
  /// Set when a run limit stopped the run before the model answered. The
  /// transcript is complete up to that point and can be run again to go on.
  public var interruption: AgentRunInterruption?

  public init(
    runID: UUID,
    agentID: String,
    provider: ProviderID,
    response: AgentMessage,
    transcript: [AgentMessage],
    usage: TokenUsage?,
    stopReason: ProviderStopReason,
    modelTurns: Int,
    toolCalls: Int,
    interruption: AgentRunInterruption? = nil
  ) {
    self.runID = runID
    self.agentID = agentID
    self.provider = provider
    self.response = response
    self.transcript = transcript
    self.usage = usage
    self.stopReason = stopReason
    self.modelTurns = modelTurns
    self.toolCalls = toolCalls
    self.interruption = interruption
  }

  public var reasoning: String { response.reasoning }

  /// True when the model gave its final answer; false when a limit paused it.
  public var isComplete: Bool { interruption == nil }
}

public struct AgentEventContext: Codable, Equatable, Sendable {
  public var runID: UUID
  public var parentRunID: UUID?
  public var agentID: String
  public var depth: Int
  /// The supervisor's short identifier for this run, so hosts can tie an event
  /// to the row `/agents` shows. Nil for runs started outside a supervisor.
  public var pid: AgentPID?

  public init(
    runID: UUID,
    parentRunID: UUID?,
    agentID: String,
    depth: Int,
    pid: AgentPID? = nil
  ) {
    self.runID = runID
    self.parentRunID = parentRunID
    self.agentID = agentID
    self.depth = depth
    self.pid = pid
  }
}

public enum AgentEvent: Equatable, Sendable {
  case started(AgentEventContext, ProviderDescriptor)
  case modelStarted(AgentEventContext, turn: Int)
  case provider(AgentEventContext, ProviderEvent)
  case approvalRequested(AgentEventContext, ApprovalRequest)
  case approvalDecided(AgentEventContext, ApprovalDecision)
  case toolStarted(AgentEventContext, ToolCall)
  case toolFinished(AgentEventContext, ToolResult)
  case childStarted(AgentEventContext, child: AgentEventContext)
  /// A child was registered but every subagent slot is taken; it starts on
  /// its own, and reports `childStarted`, when a sibling ends.
  case childQueued(AgentEventContext, child: AgentEventContext)
  case childFinished(AgentEventContext, child: AgentResult)
  /// A message a person queued for this process was appended to its
  /// transcript, between two model turns of a run that was already going.
  case userMessage(AgentEventContext, AgentMessage)
  /// The process edited its own transcript with the context tools before a
  /// model turn; the report says what changed.
  case transcriptEdited(AgentEventContext, AgentTranscriptEditReport)
  /// A model call failed and will be repeated after `delaySeconds`; `attempt`
  /// counts from one up to `limit`.
  case retrying(AgentEventContext, attempt: Int, limit: Int, delaySeconds: Double, error: String)
  /// The conversation is estimated to hold this many tokens, which is past
  /// the agent's autocompact threshold, so a summary is being written. The
  /// outcome arrives as `transcriptEdited` or `compactionFailed`.
  case compactionStarted(AgentEventContext, estimatedTokens: Int)
  /// The summary could not be produced; the run goes on with the transcript
  /// it had.
  case compactionFailed(AgentEventContext, String)
  /// The run ended. `AgentResult.interruption` says whether it answered or a
  /// limit paused it.
  case finished(AgentEventContext, AgentResult)
}

public typealias ProviderEventHandler = @Sendable (ProviderEvent) async -> Void
public typealias AgentEventHandler = @Sendable (AgentEvent) async -> Void
