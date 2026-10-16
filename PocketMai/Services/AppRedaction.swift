import Foundation
import MaiCore

/// Privacy rules are shared by every agent. Replacement tables live only for a
/// turn and its children; local transcripts retain their original text.
struct RedactionSettings: Codable, Equatable, Sendable {
  var enabled = false
  var rules = ""
}

enum AppRedaction {
  static func context(settings: AppSettings) throws -> ContentRedactor? {
    let rules =
      settings.redaction.enabled ? try ContentRedactor.parse(settings.redaction.rules) : []
    if let current = ContentRedactor.current {
      current.update(rules: rules)
      return current
    }
    return settings.redaction.enabled ? ContentRedactor(rules: rules) : nil
  }

  static func request(_ request: ProviderRequest, settings: AppSettings) throws -> ProviderRequest {
    guard let redactor = try context(settings: settings) else { return request }
    var request = request
    if settings.redaction.enabled, !settings.redaction.rules.isEmpty {
      request.messages.insert(.system(ContentRedactor.placeholderInstructions), at: 0)
    }
    return redactor.redact(request).request
  }

  static func display(_ text: String, complete: Bool = true) -> String {
    ContentRedactor.current?.displayText(text, complete: complete) ?? text
  }
}
