import Foundation
import MaiCore
import MaiMarkdown

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  /// A renderer for replies on this terminal, or nil to print them verbatim.
  /// Output that is not a terminal stays verbatim unless rendering is forced.
  static func markdownRenderer(
    enabled: Bool,
    forced: Bool,
    environment: [String: String]
  ) -> MarkdownTerminalRenderer? {
    guard enabled, forced || isatty(STDOUT_FILENO) != 0 else { return nil }
    let detected = MarkdownTerminalEnvironment.detect(environment)
    return MarkdownTerminalRenderer(
      theme: detected.theme,
      options: MarkdownLayoutOptions(
        width: TerminalLineEditor.terminalColumns(), unicode: detected.unicode),
      widthProvider: { TerminalLineEditor.terminalColumns() })
  }

  /// The agent, estimated context, and provider/model a chat runs on. The
  /// context sits immediately before the model so it stays easy to compare.
  static func promptIdentity(
    _ session: REPLSession, contextSize: AgentContextSize? = nil, includeContext: Bool = true
  ) -> String {
    let profile = session.profile
    let model = profile.model.isEmpty
      ? (profile.provider.rawValue.isEmpty ? "no model selected" : profile.provider.rawValue)
      : "\(profile.provider.rawValue)::\(profile.model)"
    let context = includeContext ? " · \(promptContextStatus(session, contextSize: contextSize))" : ""
    let effort = visibleUITitle(profile.options.reasoningEffort ?? "auto")
    return "[\(profile.agentID)]\(context) · \(model) [\(effort.isEmpty ? "auto" : effort)]"
  }

  /// The final component of the working directory, with a useful root label.
  static func currentDirectoryName() -> String {
    let path = FileManager.default.currentDirectoryPath
    if path == "/" { return path }
    let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    return name.isEmpty ? path : name
  }

  /// Removes terminal controls from text before showing it.
  static func visibleUITitle(_ title: String) -> String {
    String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// How long a turn took, as `5s`, `1m4s`, or `2h3m4s`.
  static func elapsedDescription(since start: ContinuousClock.Instant) -> String {
    let parts = (ContinuousClock.now - start).components
    let total = Int(parts.seconds) + (parts.attoseconds >= 500_000_000_000_000_000 ? 1 : 0)
    guard total >= 1 else { return "<1s" }
    let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
    if hours > 0 { return "\(hours)h\(minutes)m\(seconds)s" }
    if minutes > 0 { return "\(minutes)m\(seconds)s" }
    return "\(seconds)s"
  }

  /// A fast, deliberately approximate context indicator. Providers tokenize
  /// differently and do not all expose their context-window size, so showing
  /// an estimate is more honest than implying an exact percentage.
  private static func promptContextStatus(
    _ session: REPLSession, contextSize: AgentContextSize? = nil
  ) -> String {
    if let size = contextSize ?? session.historyContextSize {
      return "\(ModelUsageFormat.count(size.estimatedTokens))/\(size.messageCount)"
    }
    let size = AgentContextSize(messages: session.history.messages)
    // A chat opened on its latest page has not been measured as a whole:
    // its message count is known, its tokens are at least the page's.
    guard let window = session.historyWindow, window.totalCount > size.messageCount else {
      return "\(ModelUsageFormat.count(size.estimatedTokens))/\(size.messageCount)"
    }
    return "\(ModelUsageFormat.count(size.estimatedTokens))+/\(window.totalCount)"
  }

  static func markdownTableCell(_ text: String) -> String {
    let punctuation = "\\`*_{}[]<>()#+-.!|~$&"
    return text.map { character in
      if character.isNewline { return " " }
      return punctuation.contains(character) ? "\\" + String(character) : String(character)
    }.joined()
  }
}
