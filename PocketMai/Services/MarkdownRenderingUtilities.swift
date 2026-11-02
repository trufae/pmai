import Foundation

enum MarkdownInlineCodeSpan {
  static func span(in chars: [Character], at index: Int) -> (code: String, end: Int)? {
    guard index < chars.count, chars[index] == "`", !isEscaped(chars, at: index) else {
      return nil
    }

    let opening = backtickRun(in: chars, at: index)
    var cursor = opening.end
    while cursor < chars.count {
      guard chars[cursor] == "`", !isEscaped(chars, at: cursor) else {
        cursor += 1
        continue
      }

      let closing = backtickRun(in: chars, at: cursor)
      if closing.length >= opening.length {
        return (String(chars[opening.end..<cursor]), closing.end)
      }
      cursor = closing.end
    }
    return nil
  }

  private static func backtickRun(in chars: [Character], at index: Int) -> (
    length: Int, end: Int
  ) {
    var cursor = index
    while cursor < chars.count, chars[cursor] == "`" {
      cursor += 1
    }
    return (cursor - index, cursor)
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return slashCount % 2 == 1
  }
}

enum MarkdownWebURL {
  static func url(from raw: String) -> URL? {
    guard let string = normalizedString(from: raw) else { return nil }
    return URL(string: string)
  }

  static func normalizedString(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else {
      return nil
    }
    return trimmed
  }
}

enum MarkdownImageURL {
  static func svgSource(code: String, language: String) -> String? {
    let language = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard language == "svg"
      || (["xml", "html", ""].contains(language)
        && code.range(of: "<svg(?:\\s|>)", options: [.regularExpression, .caseInsensitive]) != nil)
    else { return nil }
    return "data:image/svg+xml;base64," + Data(code.utf8).base64EncodedString()
  }

  static func url(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("data:image/"), trimmed.contains(",") {
      return URL(string: trimmed)
    }
    return MarkdownWebURL.url(from: trimmed)
  }

  static func embeddedData(from url: URL) throws -> Data? {
    guard url.scheme?.lowercased() == "data" else { return nil }
    let source = url.absoluteString
    guard let comma = source.firstIndex(of: ","),
      source.lowercased().hasPrefix("data:image/"),
      let payload = String(source[source.index(after: comma)...]).removingPercentEncoding
    else {
      throw URLError(.cannotDecodeContentData)
    }
    let metadata = source[..<comma].lowercased().split(separator: ";")
    if metadata.contains("base64") {
      guard let data = Data(base64Encoded: payload) else {
        throw URLError(.cannotDecodeContentData)
      }
      return data
    }
    return Data(payload.utf8)
  }
}
