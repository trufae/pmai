import Foundation
import MaiCore

/// The Agent Client Protocol (https://agentclientprotocol.com): JSON-RPC over
/// stdio between an editor (the client) and a coding agent. The method names,
/// update kinds, content blocks, and permission shapes here are shared by both
/// of MaiCore's sides of it, so a message the server emits is one the provider
/// knows how to read.
public enum ACP {
  public static let protocolVersion = 1
  public static let agentName = "pmai"

  public enum Method {
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionUpdate = "session/update"
    public static let requestPermission = "session/request_permission"
    public static let readTextFile = "fs/read_text_file"
    public static let writeTextFile = "fs/write_text_file"
  }

  /// The `sessionUpdate` discriminator inside a `session/update` notification.
  public enum Update: String, Sendable {
    case agentMessageChunk = "agent_message_chunk"
    case agentThoughtChunk = "agent_thought_chunk"
    case userMessageChunk = "user_message_chunk"
    case toolCall = "tool_call"
    case toolCallUpdate = "tool_call_update"
    case plan
  }

  public enum StopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled

    public init(_ providerStopReason: ProviderStopReason) {
      switch providerStopReason {
      case .stop: self = .endTurn
      case .length: self = .maxTokens
      case .contentFilter: self = .refusal
      case .cancelled: self = .cancelled
      case .toolCall, .unknown: self = .endTurn
      }
    }

    public var providerStopReason: ProviderStopReason {
      switch self {
      case .endTurn: .stop
      case .maxTokens: .length
      case .maxTurnRequests: .stop
      case .refusal: .contentFilter
      case .cancelled: .cancelled
      }
    }
  }

  /// One ACP content block. Only the kinds MaiCore produces or consumes are
  /// modeled; anything else round-trips as its text, so an unexpected block
  /// never drops silently.
  public enum ContentBlock: Sendable {
    case text(String)
    case resourceLink(name: String, uri: String)
    case resource(text: String)

    public var json: JSONValue {
      switch self {
      case .text(let text):
        .object(["type": .string("text"), "text": .string(text)])
      case .resourceLink(let name, let uri):
        .object([
          "type": .string("resource_link"), "name": .string(name), "uri": .string(uri),
        ])
      case .resource(let text):
        .object([
          "type": .string("resource"),
          "resource": .object(["text": .string(text)]),
        ])
      }
    }

    /// The text of one block, or the concatenation of an array of them. ACP
    /// carries content as either shape depending on the update kind.
    public static func text(from value: JSONValue?) -> String {
      guard let value else { return "" }
      if let array = value.arrayValue {
        return array.map { text(from: $0) }.joined()
      }
      guard let object = value.objectValue else { return "" }
      if object["type"]?.stringValue == "content" {
        return text(from: object["content"])
      }
      if let text = object["text"]?.stringValue { return text }
      if let resource = object["resource"]?.objectValue ?? object["contents"]?.objectValue {
        if let text = resource["text"]?.stringValue { return text }
        if let uri = resource["uri"]?.stringValue { return uri }
      }
      if let name = object["name"]?.stringValue, let uri = object["uri"]?.stringValue {
        return name.isEmpty ? uri : "\(name): \(uri)"
      }
      return object["uri"]?.stringValue ?? ""
    }
  }

  /// Flattens an ACP prompt array into the text a MaiCore run receives.
  public static func promptText(_ prompt: JSONValue?) -> String {
    guard let blocks = prompt?.arrayValue else { return prompt?.stringValue ?? "" }
    return blocks.map { ContentBlock.text(from: $0) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }
}

/// How MaiCore answers an agent's `session/request_permission`.
public enum ACPPermissionPolicy: String, Codable, Sendable {
  /// Approve every request.
  case allow
  /// Reject every request.
  case reject
  /// Approve read-only kinds (read, search, fetch, think); reject the rest.
  case auto

  public func approves(kind: String) -> Bool {
    switch self {
    case .allow: true
    case .reject: false
    case .auto: ["read", "search", "fetch", "think"].contains(kind)
    }
  }

  /// Picks the option id an agent offered that matches the verdict, preferring
  /// the "once" variant so an approval never silently becomes permanent.
  public func optionID(from options: [JSONValue], kind: String) -> String? {
    let approve = approves(kind: kind)
    let ids = options.compactMap { $0.objectValue?["optionId"]?.stringValue }
    let preferred = approve ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
    for candidate in preferred where ids.contains(candidate) { return candidate }
    // Fall back to the option whose declared kind matches the verdict.
    return options.first { option in
      let kind = option.objectValue?["kind"]?.stringValue ?? ""
      return approve ? kind.hasPrefix("allow") : kind.hasPrefix("reject")
    }?.objectValue?["optionId"]?.stringValue ?? ids.first
  }
}
