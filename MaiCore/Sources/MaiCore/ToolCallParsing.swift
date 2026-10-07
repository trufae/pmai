import Foundation

/// Shared string and JSON extraction for tool-call formats.
enum ToolCallParsing {
  static func jsonObject(from text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func stripMarkdownFence(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else { return trimmed }
    var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    lines.removeFirst()
    if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
      lines.removeLast()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func jsonObjects(in text: String) -> [String] {
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

  static func toolArguments(from object: [String: Any]) -> [String: Any] {
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

  static func containsJSONKey(in text: String, keys: [String]) -> Bool {
    keys.contains { key in
      text.range(
        of: #""\#(NSRegularExpression.escapedPattern(for: key))"\s*:"#,
        options: [.regularExpression]) != nil
    }
  }

  static func argumentsObject(from value: Any?) -> [String: Any] {
    if let object = value as? [String: Any] {
      return object
    }
    guard let string = value as? String, let data = string.data(using: .utf8) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
}
