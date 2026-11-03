import Foundation

/// A shell-style path pattern: `*` and `?` stay inside one path component,
/// `**` crosses components, `[abc]` and `[!abc]` are character classes, and
/// `{a,b}` lists alternatives. A pattern without a slash is matched against
/// the file name, so `*.c` finds every C file at any depth; one with a slash
/// is matched against the whole relative path, so `src/*.c` finds only the
/// files directly in `src` and `src/**/*.c` the ones anywhere below it.
/// On Windows, backslashes also separate path components.
/// Matching is case-insensitive unless the pattern has an uppercase letter.
public struct MaiGlob: Sendable {
  public let pattern: String
  /// True when the pattern names a relative path rather than a file name.
  public let matchesPath: Bool
  private let expression: NSRegularExpression

  /// True when the text holds a metacharacter, so it is a pattern, not a name.
  public static func isPattern(_ text: String) -> Bool {
    text.contains { "*?[{".contains($0) }
  }

  /// `anchored` matches the pattern against the relative path even without
  /// a slash, for a pattern that came from a path such as `src/*.c`.
  public init?(_ pattern: String, anchored: Bool = false) {
    var trimmed = Self.normalizedSeparators(pattern).trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasPrefix("./") { trimmed = String(trimmed.dropFirst(2)) }
    while trimmed.hasPrefix("/") { trimmed = String(trimmed.dropFirst()) }
    guard !trimmed.isEmpty else { return nil }
    let options: NSRegularExpression.Options =
      trimmed.contains(where: \.isUppercase) ? [] : [.caseInsensitive]
    guard
      let expression = try? NSRegularExpression(
        pattern: Self.regularExpression(for: trimmed), options: options)
    else { return nil }
    self.pattern = trimmed
    self.matchesPath = anchored || trimmed.contains("/")
    self.expression = expression
  }

  /// Whether a path, relative to the directory the search started in, fits.
  public func matches(_ relativePath: String) -> Bool {
    var subject = Self.normalizedSeparators(relativePath)
    while subject.hasPrefix("./") { subject = String(subject.dropFirst(2)) }
    if !matchesPath, let slash = subject.lastIndex(of: "/") {
      subject = String(subject[subject.index(after: slash)...])
    }
    let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
    return expression.firstMatch(in: subject, range: range) != nil
  }

  /// Splits `src/lib/*.c` into the folder before the first patterned
  /// component and the pattern for what is under it; nil when the text has
  /// no metacharacter at all.
  public static func splitPath(_ text: String) -> (directory: String, pattern: String)? {
    guard isPattern(text) else { return nil }
    let components = normalizedSeparators(text).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard let first = components.firstIndex(where: isPattern) else { return nil }
    let directory = components[..<first].joined(separator: "/")
    let pattern = components[first...].joined(separator: "/")
    #if os(Windows)
    // C:/ is rooted on its drive; C: alone would be drive-relative.
    if first == 1, directory.count == 2, directory.hasSuffix(":") { return (directory + "/", pattern) }
    #endif
    return (directory, pattern)
  }

  private static func normalizedSeparators(_ path: String) -> String {
    #if os(Windows)
    path.replacingOccurrences(of: "\\", with: "/")
    #else
    path
    #endif
  }

  static func regularExpression(for pattern: String) -> String {
    let characters = Array(pattern)
    var regex = "^"
    var index = 0
    var braces = 0
    while index < characters.count {
      let character = characters[index]
      switch character {
      case "*":
        var stars = 1
        while index + stars < characters.count, characters[index + stars] == "*" { stars += 1 }
        let before = index > 0 ? characters[index - 1] : nil
        let after = index + stars < characters.count ? characters[index + stars] : nil
        if stars >= 2, after == "/", before == nil || before == "/" {
          // `**/` at the start or after a slash: zero or more whole folders.
          regex += "(?:.*/)?"
          index += stars + 1
          continue
        }
        regex += stars >= 2 ? ".*" : "[^/]*"
        index += stars
      case "?":
        regex += "[^/]"
        index += 1
      case "[":
        var start = index + 1
        if start < characters.count, characters[start] == "!" || characters[start] == "^" {
          start += 1
        }
        if start < characters.count, characters[start] == "]" { start += 1 }
        if let close = (start..<characters.count).first(where: { characters[$0] == "]" }) {
          var body = String(characters[(index + 1)..<close])
          if body.hasPrefix("!") { body = "^" + body.dropFirst() }
          body = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
          regex += "[\(body)]"
          index = close + 1
        } else {
          regex += "\\["
          index += 1
        }
      case "{":
        braces += 1
        regex += "(?:"
        index += 1
      case "}" where braces > 0:
        braces -= 1
        regex += ")"
        index += 1
      case "," where braces > 0:
        regex += "|"
        index += 1
      case "\\" where index + 1 < characters.count:
        regex += NSRegularExpression.escapedPattern(for: String(characters[index + 1]))
        index += 2
      default:
        regex += NSRegularExpression.escapedPattern(for: String(character))
        index += 1
      }
    }
    while braces > 0 {
      regex += ")"
      braces -= 1
    }
    return regex + "$"
  }
}
