import Foundation

extension AgentRuntime {
  /// Install rules before inference starts. Reloads are atomic: an unreadable
  /// file or invalid regex leaves the previous policy and rules active.
  public func configureRedaction(
    _ mode: RedactionMode, file: URL? = nil,
    onWarning: (@Sendable (Int) async -> Void)? = nil
  ) throws {
    let url =
      file ?? redactionFile ?? AgentHome.resolve().rootURL.appendingPathComponent("redact.txt")
    let rules: [ContentRedactor.Rule]
    if mode == .off {
      rules = redactionRules
    } else {
      rules = try ContentRedactor.parse(String(contentsOf: url, encoding: .utf8))
    }
    redactionFile = url
    redactionRules = rules
    redactionMode = mode
    if let onWarning { redactionWarning = onWarning }
    for redactor in redactionSessions.values { redactor.update(rules: rules) }
  }

  /// Shared only by one chat and its children; token tables are never persisted.
  public func contentRedactor(sessionID: String) -> ContentRedactor {
    if let existing = redactionSessions[sessionID] { return existing }
    let redactor = ContentRedactor(rules: redactionRules)
    redactionSessions[sessionID] = redactor
    return redactor
  }

  public func redactionRulesURL() -> URL {
    redactionFile ?? AgentHome.resolve().rootURL.appendingPathComponent("redact.txt")
  }
}
