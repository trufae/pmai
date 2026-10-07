import Foundation

/// Encodes tool calls and results for textual and provider-native protocols.
extension AgentTooling {
  public static func makeRunBlock(toolName: String, argumentsJSON: String, result: String) -> String
  {
    let body = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return "<tool_run>\n\(toolName) tool (\(argumentsJSON)):\n\(body)\n</tool_run>"
  }

  public static func makeRunBlock(call: ParsedToolCall, result: String) -> String {
    makeRunBlock(toolName: call.name, argumentsJSON: call.argsJSON, result: result)
  }

  public static func editableToolCallText(for call: ParsedToolCall, mode: ToolCallingMode) -> String
  {
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
      return
        "<tool_call>\(toolCallObjectJSON(name: call.name, arguments: call.argumentValues))</tool_call>"
    case .json:
      return toolCallObjectJSON(name: call.name, arguments: call.argumentValues)
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

  static func toolCallObjectJSON(
    name: String,
    arguments: [String: AgentToolArgumentValue]
  ) -> String {
    #"{"name":\#(jsonStringLiteral(name)),"arguments":\#(compactJSON(arguments))}"#
  }

  public static func argumentValues(_ args: [String: Any]) -> [String: AgentToolArgumentValue] {
    args.mapValues { AgentToolArgumentValue(json: $0) }
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

  public static func xmlEscapedAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

extension AgentNativeToolCall {
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
