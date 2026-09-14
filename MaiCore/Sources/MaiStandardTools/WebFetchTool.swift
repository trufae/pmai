import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct WebFetchedContent: Equatable, Sendable {
  public let title: String
  public let text: String

  public init(title: String, text: String) {
    self.title = title
    self.text = text
  }
}

public enum WebFetchContentCleaner {
  public static func clean(_ content: String, contentType: String?) -> WebFetchedContent {
    let mime = contentType?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let prefix = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256).lowercased()
    // An explicit text/JSON/XML type is authoritative: source code can contain HTML literals.
    let looksLikeHTML = mime == "text/html" || mime == "application/xhtml+xml"
      || (mime.isEmpty && (prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")))
    return looksLikeHTML
      ? cleanHTML(content) : WebFetchedContent(title: "", text: content)
  }

  private static func cleanHTML(_ html: String) -> WebFetchedContent {
    let title =
      firstMatch(in: html, pattern: #"<title\b[^>]*>([\s\S]*?)</title\s*>"#)
      .map { cleanText(stripTags($0)) } ?? ""

    var text = html
    text = replacingRegex(#"<!--[\s\S]*?-->"#, in: text, with: " ")
    text = replacingRegex(#"<!doctype[^>]*>"#, in: text, with: " ")

    for tag in [
      "head", "script", "style", "noscript", "svg", "canvas", "template", "iframe",
      "object", "embed", "form", "nav", "footer", "header", "aside",
    ] {
      text = replacingRegex(#"<\#(tag)\b[^>]*>[\s\S]*?</\#(tag)\s*>"#, in: text, with: "\n")
    }

    text = replacingRegex(
      #"</?(p|div|section|article|main|br|hr|li|tr|td|th|h[1-6]|blockquote)\b[^>]*>"#,
      in: text,
      with: "\n")
    text = stripTags(text)
    return WebFetchedContent(title: title, text: cleanText(text))
  }

  private static func stripTags(_ text: String) -> String {
    replacingRegex(#"<[^>]+>"#, in: text, with: " ")
  }

  private static func cleanText(_ text: String) -> String {
    let decoded = decodeHTMLEntities(text)
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let whitespace = CharacterSet.whitespaces.subtracting(CharacterSet(charactersIn: "\n"))
    var lines: [String] = []
    var previous = ""
    for rawLine in decoded.components(separatedBy: "\n") {
      let pieces = rawLine.components(separatedBy: whitespace).filter { !$0.isEmpty }
      let line = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, line != previous else { continue }
      lines.append(line)
      previous = line
    }
    return lines.joined(separator: "\n")
  }

  private static func decodeHTMLEntities(_ text: String) -> String {
    var result = text
    let named: [(String, String)] = [
      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
      ("&apos;", "'"), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "),
      ("&ensp;", " "), ("&emsp;", " "), ("&thinsp;", " "), ("&hellip;", "..."),
      ("&mdash;", "-"), ("&ndash;", "-"), ("&lsquo;", "'"), ("&rsquo;", "'"),
      ("&ldquo;", "\""), ("&rdquo;", "\""), ("&copy;", "(c)"), ("&reg;", "(R)"),
    ]
    for (entity, replacement) in named {
      result = result.replacingOccurrences(of: entity, with: replacement)
    }
    result = decodeNumericEntities(result, pattern: #"&#([0-9]+);"#, radix: 10)
    result = decodeNumericEntities(result, pattern: #"&#x([0-9A-Fa-f]+);"#, radix: 16)
    return result
  }

  private static func decodeNumericEntities(_ text: String, pattern: String, radix: Int) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let nsText = text as NSString
    var result = text
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    for match in matches.reversed() where match.numberOfRanges == 2 {
      let raw = nsText.substring(with: match.range(at: 1))
      guard
        let value = UInt32(raw, radix: radix),
        let scalar = UnicodeScalar(value)
      else { continue }
      let range = Range(match.range(at: 0), in: result)
      if let range {
        result.replaceSubrange(range, with: String(Character(scalar)))
      }
    }
    return result
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return nil }
    let nsText = text as NSString
    guard
      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
      match.numberOfRanges > 1
    else { return nil }
    return nsText.substring(with: match.range(at: 1))
  }

  private static func replacingRegex(_ pattern: String, in text: String, with replacement: String)
    -> String
  {
    guard
      let regex = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return text }
    let range = NSRange(location: 0, length: (text as NSString).length)
    return regex.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: replacement)
  }
}

public struct MaiWebFetchTool: AgentTool {
  public static let name = "web_fetch"
  public static let toolDefinition = ToolDefinition(
    name: name,
    description: "Fetch one HTTP or HTTPS URL and return cleaned page text.",
    parameters: [
      ToolParameterDef(
        name: "url", type: "string",
        description: "Full HTTP or HTTPS URL.",
        required: true)
    ])

  public let definition = Self.toolDefinition

  public init() {}

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    let arguments = arguments.objectValue ?? [:]
    let url =
      arguments["url"]?.coercedStringValue
      ?? arguments["uri"]?.coercedStringValue ?? ""
    let result = await MaiWebFetchService.fetchContext(urlString: url)
    return ToolOutput(text: result, isError: result.hasPrefix("Error:"))
  }
}

public enum MaiWebFetchService {
  private static let userAgent = "mai/1.0 (+https://github.com/trufae/mai)"
  private static let requestTimeout: TimeInterval = 10
  private static let maxDownloadedBytes = 2_000_000
  private static let maxReturnedCharacters = 16_000

  public static func fetchContext(urlString: String) async -> String {
    guard let url = normalizedURL(from: urlString) else {
      return "Error: provide a valid HTTP or HTTPS URL."
    }
    guard !hasCredentials(url) else {
      return "Error: URLs with embedded credentials are not supported."
    }

    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      "text/html, text/plain;q=0.9, application/xhtml+xml;q=0.9, application/json;q=0.5, */*;q=0.1",
      forHTTPHeaderField: "Accept")
    request.timeoutInterval = requestTimeout

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return "Error: fetch did not return an HTTP response."
      }
      guard (200..<300).contains(http.statusCode) else {
        return "Error: fetch returned HTTP \(http.statusCode)."
      }
      guard data.count <= maxDownloadedBytes else {
        return "Error: fetched content is too large (\(data.count) bytes)."
      }

      let contentType = http.value(forHTTPHeaderField: "Content-Type")
      guard isTextLike(contentType) else {
        return "Error: fetched content is not text or HTML."
      }
      guard
        let raw = decodedString(from: data),
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return "Error: fetched content could not be decoded as text."
      }

      let cleaned = WebFetchContentCleaner.clean(raw, contentType: contentType)
      guard !cleaned.text.isEmpty else {
        return "Error: no readable text was found at \(displayURL(http.url ?? url))."
      }

      let visibleURL = displayURL(http.url ?? url)
      let titleLine = cleaned.title.isEmpty ? nil : "Title: \(cleaned.title)"
      let text = limited(cleaned.text)
      return
        (["Web Fetch tool (url: \"\(visibleURL)\"):"]
        + [titleLine].compactMap { $0 } + ["", text])
        .joined(separator: "\n")
    } catch {
      return "Error: fetch failed for \(displayURL(url)): \(error.localizedDescription)"
    }
  }

  private static func normalizedURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard
      let components = URLComponents(string: candidate),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.host?.isEmpty == false,
      let url = components.url
    else {
      return nil
    }
    return url
  }

  private static func hasCredentials(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.user != nil || components.password != nil
  }

  private static func isTextLike(_ contentType: String?) -> Bool {
    guard let contentType = contentType?.lowercased(), !contentType.isEmpty else {
      return true
    }
    return contentType.contains("text/")
      || contentType.contains("html")
      || contentType.contains("xml")
      || contentType.contains("json")
  }

  private static func decodedString(from data: Data) -> String? {
    String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
      ?? String(data: data, encoding: .ascii)
  }

  private static func limited(_ text: String) -> String {
    guard text.count > maxReturnedCharacters else { return text }
    return String(text.prefix(maxReturnedCharacters))
      + "\n\n[Content truncated to \(maxReturnedCharacters) characters.]"
  }

  private static func displayURL(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.user = nil
    components.password = nil
    return components.string ?? url.absoluteString
  }
}
