import Foundation

/// Forward- and backward-substitution rules for text that must reach the
/// model in a redacted form while the local transcript stays readable.
public struct ContentRedactor: Sendable, Equatable {
  public struct Rule: Sendable, Equatable {
    public let original: String
    public let replacement: String
    public init(original: String, replacement: String) {
      self.original = original
      self.replacement = replacement
    }
  }

  public let rules: [Rule]
  public let path: String?

  public init(rules: [Rule], path: String? = nil) {
    self.rules = rules
    self.path = path
  }

  /// Loads rules from a UTF-8 text file. Each non-empty, non-comment line is:
  ///   - "word=replacement" to substitute "word" with "replacement" in both
  ///     directions;
  ///   - "word" by itself to replace "word" with "<REDACT>".
  /// Lines beginning with '#' and blank lines are ignored.
  public init?(path: String?) {
    guard let path, !path.isEmpty, path.lowercased() != "off" else { return nil }
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    var rules: [Rule] = []
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      if let eq = trimmed.firstIndex(of: "=") {
        let original = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { continue }
        rules.append(Rule(original: original, replacement: replacement))
      } else {
        rules.append(Rule(original: trimmed, replacement: "<REDACT>"))
      }
    }
    self.init(rules: rules, path: path)
  }

  public var isEmpty: Bool { rules.isEmpty }

  public func redact(_ text: String) -> String {
    var result = text
    for rule in rules {
      result = result.replacingOccurrences(of: rule.original, with: rule.replacement)
    }
    return result
  }

  public func unredact(_ text: String) -> String {
    var result = text
    for rule in rules.reversed() {
      result = result.replacingOccurrences(of: rule.replacement, with: rule.original)
    }
    return result
  }

  public func redact(_ messages: [AgentMessage]) -> [AgentMessage] {
    messages.map { message in
      var content: [ContentPart] = []
      for part in message.content {
        switch part {
        case .text(let text):
          content.append(.text(redact(text)))
        case .reasoning(let text):
          content.append(.reasoning(redact(text)))
        case .file(var value):
          value.text = value.text.map(redact)
          content.append(.file(value))
        case .resource(var value):
          value.text = value.text.map(redact)
          content.append(.resource(value))
        case .toolResult(var value):
          let text = value.content.compactMap(\.textValue).joined(separator: "\n")
          if !text.isEmpty {
            value.content = [.text(redact(text))]
          }
          content.append(.toolResult(value))
        default:
          content.append(part)
        }
      }
      var updated = message
      updated.content = content
      return updated
    }
  }

  public func unredact(_ messages: [AgentMessage]) -> [AgentMessage] {
    messages.map { message in
      var content: [ContentPart] = []
      for part in message.content {
        switch part {
        case .text(let text):
          content.append(.text(unredact(text)))
        case .reasoning(let text):
          content.append(.reasoning(unredact(text)))
        case .file(var value):
          value.text = value.text.map(unredact)
          content.append(.file(value))
        case .resource(var value):
          value.text = value.text.map(unredact)
          content.append(.resource(value))
        case .toolResult(var value):
          let text = value.content.compactMap(\.textValue).joined(separator: "\n")
          if !text.isEmpty {
            value.content = [.text(unredact(text))]
          }
          content.append(.toolResult(value))
        default:
          content.append(part)
        }
      }
      var updated = message
      updated.content = content
      return updated
    }
  }
}
