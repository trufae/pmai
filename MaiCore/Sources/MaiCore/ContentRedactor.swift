import Foundation

public enum RedactionMode: String, Codable, CaseIterable, Sendable {
  case off, on, warn
}

/// A conversation's in-memory replacement table. Originals never enter the
/// placeholders, and only placeholders issued by this instance can be restored.
public final class ContentRedactor: @unchecked Sendable {
  @TaskLocal static var current: ContentRedactor?

  public struct Rule: Sendable {
    public let pattern: String
    public let label: String
    fileprivate let expression: NSRegularExpression

    public init(pattern: String, label: String = "REDACTED") throws {
      self.pattern = pattern
      self.label = label
      let regex =
        pattern.hasPrefix("/")
        ? String(pattern.dropFirst()) : NSRegularExpression.escapedPattern(for: pattern)
      expression = try NSRegularExpression(pattern: regex, options: [.caseInsensitive])
    }
  }

  public struct InvalidRule: LocalizedError {
    public let line: Int
    public var errorDescription: String? { "Invalid redaction rule on line \(line)." }
  }

  /// Literals are case insensitive substrings. `/pattern/` (or `/pattern`)
  /// uses ICU regex syntax. An optional `=label` names the opaque placeholder.
  public static func parse(_ text: String) throws -> [Rule] {
    try text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
      let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
      var pattern = line
      var label = "REDACTED"
      if line.hasPrefix("/") {
        // A closing delimiter is optional. Equals signs inside a regex,
        // including lookarounds, are not replacement separators.
        var escaped = false
        var closing: String.Index?
        for i in line.indices.dropFirst() {
          if escaped {
            escaped = false
            continue
          }
          if line[i] == "\\" {
            escaped = true
            continue
          }
          if line[i] == "/" { closing = i }
        }
        if let closing {
          let suffix = line[line.index(after: closing)...].trimmingCharacters(in: .whitespaces)
          if suffix.isEmpty || suffix.hasPrefix("=") {
            pattern = String(line[..<closing])
            if suffix.hasPrefix("=") { label = String(suffix.dropFirst()) }
          }
        }
      } else if let equal = line.firstIndex(of: "=") {
        pattern = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
        label = String(line[line.index(after: equal)...])
      }
      guard !pattern.isEmpty, pattern != "/" else { throw InvalidRule(line: index + 1) }
      do {
        return try Rule(pattern: pattern, label: label.trimmingCharacters(in: .whitespaces))
      } catch { throw InvalidRule(line: index + 1) }
    }
  }

  private let lock = NSLock()
  private var rules: [Rule]
  private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
  private var originals: [String: String] = [:]
  private var placeholders: [String: String] = [:]
  private var numberTokens: [String: String] = [:]
  private var numbers: [String: JSONValue] = [:]

  public init(rules: [Rule]) { self.rules = rules }

  func update(rules: [Rule]) { lock.withLock { self.rules = rules } }

  public func redact(_ text: String) -> String {
    var count = 0
    return redact(text, count: &count)
  }

  private func redact(_ text: String, count: inout Int) -> String {
    lock.withLock {
      let source = text as NSString
      let entire = NSRange(location: 0, length: source.length)
      let protected = originals.keys.flatMap { token -> [NSRange] in
        var ranges: [NSRange] = []
        var remaining = entire
        while remaining.length > 0 {
          let range = source.range(of: token, range: remaining)
          if range.location == NSNotFound { break }
          ranges.append(range)
          remaining = NSRange(
            location: NSMaxRange(range), length: source.length - NSMaxRange(range))
        }
        return ranges
      }
      var gaps: [NSRange] = []
      var cursor = 0
      for range in protected.sorted(by: { $0.location < $1.location }) {
        if range.location > cursor {
          gaps.append(NSRange(location: cursor, length: range.location - cursor))
        }
        cursor = max(cursor, NSMaxRange(range))
      }
      if cursor < source.length {
        gaps.append(NSRange(location: cursor, length: source.length - cursor))
      }
      var matches: [(NSRange, String)] = []
      for rule in rules {
        for match in rule.expression.matches(in: text, range: entire)
        where match.range.length > 0 {
          // A broad regex can cross an existing token and a fresh secret.
          // Keep the token intact while still hiding the rest of that match.
          for gap in gaps {
            let range = NSIntersectionRange(gap, match.range)
            if range.length > 0 { matches.append((range, rule.label)) }
          }
        }
      }
      matches.sort {
        $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location
      }
      // Merge overlaps so a shorter rule cannot expose the tail of a secret.
      var spans: [(NSRange, String)] = []
      for match in matches {
        if let last = spans.last, NSIntersectionRange(last.0, match.0).length > 0 {
          spans[spans.count - 1].0 = NSUnionRange(last.0, match.0)
        } else {
          spans.append(match)
        }
      }
      var result = ""
      var offset = 0
      for (range, label) in spans {
        result += source.substring(with: NSRange(location: offset, length: range.location - offset))
        let original = source.substring(with: range)
        let token: String
        if let existing = placeholders[original] {
          token = existing
        } else {
          let safeLabel = String(
            label.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(24))
          token =
            "__PMAI_\(safeLabel.isEmpty ? "REDACTED" : safeLabel)_\(nonce)_\(originals.count)__"
          originals[token] = original
          placeholders[original] = token
        }
        result += token
        offset = NSMaxRange(range)
      }
      result += source.substring(from: offset)
      count += spans.count
      return result
    }
  }

  public func unredact(_ text: String) -> String {
    lock.withLock {
      // One pass: a secret containing another placeholder stays literal.
      let source = text as NSString
      let ranges = originals.flatMap { token, original -> [(NSRange, String)] in
        var matches: [(NSRange, String)] = []
        var search = NSRange(location: 0, length: source.length)
        while search.length > 0 {
          let range = source.range(of: token, range: search)
          if range.location == NSNotFound { break }
          matches.append((range, original))
          search = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
        }
        return matches
      }.sorted { $0.0.location < $1.0.location }
      let result = NSMutableString(string: text)
      for (range, original) in ranges.reversed() {
        result.replaceCharacters(in: range, with: original)
      }
      return result as String
    }
  }

  fileprivate func pendingTokenLength(in text: String) -> Int {
    lock.withLock {
      if originals.keys.contains(where: { text.hasSuffix($0) }) { return 0 }
      let limit = min(text.count, originals.keys.map(\.count).max() ?? 0)
      guard limit > 0 else { return 0 }
      for length in stride(from: limit, through: 1, by: -1) {
        let suffix = text.suffix(length)
        if originals.keys.contains(where: { $0.hasPrefix(suffix) }) { return length }
      }
      return 0
    }
  }

  private func map(_ value: JSONValue, using transform: (String) -> String, restoring: Bool = false)
    -> JSONValue
  {
    switch value {
    case .string(let text):
      if restoring, let number = lock.withLock({ numbers[text] }) { return number }
      return .string(transform(text))
    case .array(let values):
      return .array(values.map { map($0, using: transform, restoring: restoring) })
    case .object(let fields):
      return .object(
        Dictionary(
          fields.map {
            (transform($0.key), map($0.value, using: transform, restoring: restoring))
          }, uniquingKeysWith: { first, _ in first }))
    case .integer, .number:
      let text = value.compactJSONString
      guard !restoring, transform(text) != text else { return value }
      return lock.withLock {
        if let token = numberTokens[text] { return .string(token) }
        let token = "__PMAI_NUMBER_\(nonce)_\(originals.count)__"
        numberTokens[text] = token
        numbers[token] = value
        originals[token] = text
        return .string(token)
      }
    default: return value
    }
  }

  public func unredact(_ value: JSONValue) -> JSONValue {
    map(value, using: unredact, restoring: true)
  }

  private func map(
    _ messages: [AgentMessage], using transform: (String) -> String, restoring: Bool = false
  ) -> [AgentMessage] {
    messages.map { message in
      var message = message
      message.content = message.content.map { map($0, using: transform, restoring: restoring) }
      message.providerState = message.providerState?.mapValues {
        mapProviderState($0, using: transform)
      }
      return message
    }
  }

  private func map(_ part: ContentPart, using transform: (String) -> String, restoring: Bool)
    -> ContentPart
  {
    switch part {
    case .text(let text): return .text(transform(text))
    case .reasoning(let text): return .reasoning(transform(text))
    case .file(var file):
      file.name = transform(file.name)
      file.source = file.source.map { mapSource($0, using: transform) }
      let filtered = file.text.map(transform)
      if filtered != file.text { file.source = nil }
      file.text = filtered
      return .file(file)
    case .resource(var resource):
      resource.uri = transform(resource.uri)
      resource.name = resource.name.map(transform)
      let filtered = resource.text.map(transform)
      if filtered != resource.text { resource.blob = nil }
      resource.text = filtered
      return .resource(resource)
    case .toolCall(var call):
      call.arguments = map(call.arguments, using: transform, restoring: restoring)
      return .toolCall(call)
    case .toolResult(var result):
      result.content = result.content.map { map($0, using: transform, restoring: restoring) }
      result.structuredContent = result.structuredContent.map {
        map($0, using: transform, restoring: restoring)
      }
      return .toolResult(result)
    case .image(var image):
      image.name = image.name.map(transform)
      image.source = mapSource(image.source, using: transform)
      return .image(image)
    case .audio(var audio):
      audio.name = audio.name.map(transform)
      audio.source = mapSource(audio.source, using: transform)
      return .audio(audio)
    }
  }

  private func mapSource(_ source: BinarySource, using transform: (String) -> String)
    -> BinarySource
  {
    guard case .url(let url) = source else { return source }
    return .url(URL(string: transform(url.absoluteString)) ?? url)
  }

  public func unredact(_ messages: [AgentMessage]) -> [AgentMessage] {
    map(messages, using: unredact, restoring: true)
  }

  public func unredact(_ records: [AgentProcessRecord]) -> [AgentProcessRecord] {
    records.map { record in
      var record = record
      record.task = unredact(record.task)
      record.failure = record.failure.map(unredact)
      record.messages = unredact(record.messages)
      return record
    }
  }

  func redact(_ request: ProviderRequest) -> (request: ProviderRequest, count: Int) {
    var count = 0
    func text(_ value: String) -> String { redact(value, count: &count) }
    var request = request
    request.options.reasoningGuidance = request.options.reasoningGuidance.map(text)
    request.options.additional = request.options.additional.mapValues { map($0, using: text) }
    if case .jsonSchema(let name, let schema, let strict) = request.responseFormat {
      request.responseFormat = .jsonSchema(
        name: name, schema: mapSchema(schema, using: text), strict: strict)
    }
    request.tools = request.tools.map { tool in
      var tool = tool
      tool.description = text(tool.description)
      // Preserve schema keys (type, properties, etc.) and tool identifiers.
      tool.inputSchema = mapSchema(tool.inputSchema, using: text)
      return tool
    }
    if var review = request.approvalReview {
      let originalState = review.state.compactJSONString
      review.description = text(review.description)
      review.arguments = map(review.arguments, using: text)
      review.task = text(review.task)
      review.environment.workingDirectory = text(review.environment.workingDirectory)
      review.environment.allowedPaths = review.environment.allowedPaths.map(text)
      review.environment.sandbox = text(review.environment.sandbox)
      request.approvalReview = review
      // The chat reviewer receives the same state as serialized text. Rebuild
      // it after filtering the values so JSON escapes cannot hide a match.
      request.messages = request.messages.map { message in
        var message = message
        message.content = message.content.map {
          if case .text(let value) = $0, value == originalState {
            return .text(review.state.compactJSONString)
          }
          return $0
        }
        return message
      }
    }
    request.messages = map(request.messages, using: text)
    return (request, count)
  }

  private func mapSchema(_ value: JSONValue, using transform: (String) -> String) -> JSONValue {
    guard let fields = value.objectValue else { return value }
    var result = fields
    for (key, value) in fields {
      if ["description", "title", "default", "examples", "enum", "const"].contains(key) {
        result[key] = map(value, using: transform)
      } else if key == "properties" || key == "$defs" {
        result[key] = .object(
          (value.objectValue ?? [:]).mapValues { mapSchema($0, using: transform) })
      } else if let values = value.arrayValue {
        result[key] = .array(values.map { mapSchema($0, using: transform) })
      } else {
        result[key] = mapSchema(value, using: transform)
      }
    }
    return .object(result)
  }

  private func mapProviderState(_ value: JSONValue, using transform: (String) -> String)
    -> JSONValue
  {
    switch value {
    case .object(let fields):
      var result = fields
      for (key, value) in fields
      where !["encrypted_content", "signature", "id", "type"].contains(key) {
        result[key] = mapProviderState(value, using: transform)
      }
      return .object(result)
    case .array(let values): return .array(values.map { mapProviderState($0, using: transform) })
    case .string(let text): return .string(transform(text))
    default: return value
    }
  }
}

/// Streaming display restores complete tokens, even when a provider splits
/// one across deltas. Tool-call deltas and the actual response stay untouched.
actor RedactionStream {
  let redactor: ContentRedactor
  private var text = ""
  private var reasoning = ""
  init(_ redactor: ContentRedactor) { self.redactor = redactor }

  func feed(_ event: ProviderEvent) -> ProviderEvent? {
    switch event {
    case .textDelta(let value): return take(value, from: &text).map(ProviderEvent.textDelta)
    case .reasoningDelta(let value):
      return take(value, from: &reasoning).map(ProviderEvent.reasoningDelta)
    default: return event
    }
  }

  private func take(_ value: String, from buffer: inout String) -> String? {
    buffer += value
    let pending = redactor.pendingTokenLength(in: buffer)
    let visible = String(buffer.dropLast(pending))
    buffer = String(buffer.suffix(pending))
    return visible.isEmpty ? nil : redactor.unredact(visible)
  }

  func finish() -> [ProviderEvent] {
    var events: [ProviderEvent] = []
    if !reasoning.isEmpty { events.append(.reasoningDelta(redactor.unredact(reasoning))) }
    if !text.isEmpty { events.append(.textDelta(redactor.unredact(text))) }
    reasoning = ""
    text = ""
    return events
  }
}
