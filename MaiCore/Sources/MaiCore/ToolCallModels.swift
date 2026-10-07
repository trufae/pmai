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
}
