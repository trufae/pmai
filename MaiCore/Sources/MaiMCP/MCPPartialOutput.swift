import Foundation
import MaiCore

/// Retain bounded, complete notification messages, never unfinished JSON frames.
struct MCPPartialOutput: Sendable {
  private static let maximumBytes = 64 * 1_024
  private var data = Data()
  private var truncated = false

  mutating func record(method: String, params: [String: JSONValue]) {
    let text: String
    switch method {
    case "notifications/progress":
      guard let message = params["message"]?.stringValue, !message.isEmpty else { return }
      text = "[progress] \(message)"
    case "notifications/message":
      guard let value = params["data"] else { return }
      text = "[server log] \(value.stringValue ?? value.compactJSONString)"
    default:
      return
    }
    let bytes = Data((text + "\n").utf8)
    let remaining = Self.maximumBytes - data.count
    data.append(bytes.prefix(remaining))
    truncated = truncated || bytes.count > remaining
  }

  func preserving(_ error: Error) -> Error {
    guard !data.isEmpty, !(error is CancellationError) else { return error }
    let text =
      String(decoding: data, as: UTF8.self)
      + (truncated ? "\n[partial output truncated at 64 KiB]" : "")
    return MCPPartialOutputError(underlying: error, text: text)
  }
}

struct MCPPartialOutputError: LocalizedError {
  let underlying: Error
  let text: String

  var errorDescription: String? {
    "[Incomplete MCP output received before failure; progress and logs may contain partial data]\n"
      + text + "\nError: \(underlying.localizedDescription)"
  }

  var toolOutput: ToolOutput {
    ToolOutput(
      content: [.text(errorDescription ?? text)],
      structuredContent: .object(["partial": .bool(true)]),
      isError: true)
  }
}
