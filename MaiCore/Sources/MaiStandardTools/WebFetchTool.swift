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
    description: "Fetch a URL, or search/read a cached source_id without downloading it again. HTML becomes readable text; source code and other text stay intact. For large extraction tasks, fetch with max_bytes 0 and pass the source_id, question and expected summary to agent_start when available.",
    parameters: [
      ToolParameterDef(name: "url", type: "string", description: "HTTP or HTTPS URL to fetch. Supply either url or source_id.", required: false),
      ToolParameterDef(name: "source_id", type: "string", description: "Cached source returned by an earlier fetch; shared with child agents. An expired source must be fetched again by URL.", required: false),
      ToolParameterDef(name: "offset", type: "integer", description: "UTF-8 byte offset in the source, starting at 0. Use nextOffset to continue.", required: false),
      ToolParameterDef(name: "max_bytes", type: "integer", description: "Page size: 4-256000 bytes, or 0 for metadata only. Default: up to 16000, reduced when context is tight.", required: false),
      ToolParameterDef(name: "query", type: "string", description: "Find literal text, case-insensitively, at or after offset and return a page around the first match. Searches the entire remaining source.", required: false),
    ],
    annotations: ToolAnnotations(readOnly: true, idempotent: true, openWorld: true, approval: .confirm))

  public let definition = Self.toolDefinition
  private let service: MaiWebFetchService

  public init(service: MaiWebFetchService = .shared) { self.service = service }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    var values = arguments.objectValue ?? [:]
    if values["max_bytes"] == nil, let limit = context.suggestedOutputBytes {
      values["max_bytes"] = .integer(min(16_000, max(4, limit)))
    }
    return try await service.fetch(arguments: values)
  }
}

/// The cache keeps complete sources out of transcripts. IDs name immutable snapshots,
/// including across child agents; eviction is explicit rather than silently mixing pages.
public actor MaiWebFetchService {
  public static let shared = MaiWebFetchService()
  private static let maximumPageBytes = 256_000
  private let configuration: URLSessionConfiguration
  private let maximumDownloadedBytes: Int
  private let maximumCacheBytes: Int
  private let maximumCacheEntries: Int
  private struct Source {
    let url: String
    let content: WebFetchedContent
    let bytes: Int
  }
  private var sources: [String: Source] = [:]
  private var recent: [String] = []
  private var cachedBytes = 0

  public init(
    configuration: URLSessionConfiguration = .ephemeral,
    maximumDownloadedBytes: Int = 16_000_000,
    maximumCacheBytes: Int = 32_000_000,
    maximumCacheEntries: Int = 16
  ) {
    let sessionConfiguration = configuration.copy() as! URLSessionConfiguration
    sessionConfiguration.timeoutIntervalForResource = 60
    self.configuration = sessionConfiguration
    self.maximumDownloadedBytes = max(1, maximumDownloadedBytes)
    self.maximumCacheBytes = max(1, maximumCacheBytes)
    self.maximumCacheEntries = max(1, maximumCacheEntries)
  }

  /// Compatibility entry point for hosts which only consume rendered text.
  public static func fetchContext(urlString: String) async -> String {
    do {
      return try await shared.fetch(arguments: ["url": .string(urlString)]).text
    } catch {
      return "Error: fetch failed: \(error.localizedDescription)"
    }
  }

  public func fetch(arguments: [String: JSONValue]) async throws -> ToolOutput {
    try Task.checkCancellation()
    let offset = arguments["offset"]?.intValue ?? 0
    let limit = arguments["max_bytes"]?.intValue ?? 16_000
    guard offset >= 0, limit == 0 || (4...Self.maximumPageBytes).contains(limit) else {
      return ToolOutput(text: "Error: offset must be non-negative; max_bytes must be 0 or 4-256000.", isError: true)
    }
    let query = arguments["query"]?.coercedStringValue ?? ""
    let rawURL = arguments["url"]?.coercedStringValue ?? arguments["uri"]?.coercedStringValue
    let sourceID: String
    let source: Source
    if let id = arguments["source_id"]?.stringValue {
      guard rawURL == nil else {
        return ToolOutput(text: "Error: supply either url or source_id, not both.", isError: true)
      }
      guard let cached = sources[id] else {
        return ToolOutput(text: "Error: source_id has expired or is unknown; fetch the original URL again.", isError: true)
      }
      sourceID = id
      source = cached
    } else {
      guard let url = Self.normalizedURL(from: rawURL ?? "") else {
        return ToolOutput(text: "Error: provide a valid HTTP or HTTPS URL.", isError: true)
      }
      guard url.user == nil, url.password == nil else {
        return ToolOutput(text: "Error: URLs with embedded credentials are not supported.", isError: true)
      }
      var request = URLRequest(url: url)
      request.timeoutInterval = 30
      request.setValue("pmai/1.0 (+https://github.com/trufae/pmai)", forHTTPHeaderField: "User-Agent")
      request.setValue("text/html, text/plain;q=0.9, application/json;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
      do {
        let (data, http) = try await WebFetchDownload(limit: maximumDownloadedBytes)
          .fetch(request, configuration: configuration)
        guard (200..<300).contains(http.statusCode) else {
          return ToolOutput(text: "Error: fetch returned HTTP \(http.statusCode).", isError: true)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard Self.isTextLike(contentType), !data.contains(0),
          let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
          return ToolOutput(text: "Error: fetched content is not readable text or HTML.", isError: true)
        }
        let cleaned = WebFetchContentCleaner.clean(raw, contentType: contentType)
        guard !cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return ToolOutput(text: "Error: no readable text was found at \(url.absoluteString).", isError: true)
        }
        source = Source(url: (http.url ?? url).absoluteString, content: cleaned, bytes: cleaned.text.utf8.count)
        guard source.bytes <= maximumCacheBytes else {
          return ToolOutput(text: "Error: decoded source exceeds the \(maximumCacheBytes)-byte cache limit.", isError: true)
        }
        try Task.checkCancellation()
        while cachedBytes > maximumCacheBytes - source.bytes || sources.count >= maximumCacheEntries {
          let oldest = recent.removeFirst()
          cachedBytes -= sources.removeValue(forKey: oldest)!.bytes
        }
        sourceID = UUID().uuidString
        sources[sourceID] = source
        cachedBytes += source.bytes
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        return ToolOutput(text: "Error: fetch failed: \(error.localizedDescription)", isError: true)
      }
    }
    recent.removeAll { $0 == sourceID }
    recent.append(sourceID)
    guard offset <= source.bytes else {
      return ToolOutput(text: "Error: offset \(offset) is past the source's \(source.bytes) bytes.", isError: true)
    }
    let bytes = source.content.text.utf8
    var start = offset
    var index = bytes.index(bytes.startIndex, offsetBy: start)
    // Offsets may be supplied by hand. Never begin or end inside a UTF-8 scalar.
    while index < bytes.endIndex, bytes[index] & 0xC0 == 0x80 {
      bytes.formIndex(after: &index)
      start += 1
    }
    var matchOffset: Int?
    if !query.isEmpty, limit > 0 {
      let from = index
      if let match = source.content.text.range(of: query, options: .caseInsensitive, range: from..<source.content.text.endIndex) {
        matchOffset = bytes.distance(from: bytes.startIndex, to: match.lowerBound)
        start = max(start, matchOffset! - min(1000, limit / 4))
        index = bytes.index(bytes.startIndex, offsetBy: start)
        while index < bytes.endIndex, bytes[index] & 0xC0 == 0x80 {
          bytes.formIndex(after: &index)
          start += 1
        }
      } else {
        start = source.bytes
        index = bytes.endIndex
      }
    }
    var end = min(source.bytes, start + min(limit, source.bytes - start))
    var last = bytes.index(bytes.startIndex, offsetBy: end)
    while last > index, last < bytes.endIndex, bytes[last] & 0xC0 == 0x80 {
      bytes.formIndex(before: &last)
      end -= 1
    }
    let text = String(decoding: bytes[index..<last], as: UTF8.self)
    var header = "Web Fetch tool (url: \"\(source.url)\"):\nsource_id: \(sourceID)\nBytes \(start)-\(end) of \(source.bytes); nextOffset: \(end)."
    let title = String(source.content.title.prefix(512))
    if !title.isEmpty { header += "\nTitle: \(title)" }
    if limit == 0 {
      header += "\nMetadata only. Read this source_id with query or a positive max_bytes, or pass it to a child agent for extraction."
    } else if !query.isEmpty, matchOffset == nil {
      header += "\nNo matches at or after offset \(offset)."
    } else if end < source.bytes {
      header += "\nMore content is available: call web_fetch with this source_id and offset \(end), or narrow it with query."
    }
    return ToolOutput(
      content: [.text(header), .resource(ResourceContent(uri: source.url, name: title, mimeType: "text/plain", text: text))],
      structuredContent: .object([
        "tool": .string(MaiWebFetchTool.name), "source_id": .string(sourceID), "url": .string(source.url),
        "totalBytes": .integer(source.bytes), "offset": .integer(start),
        "nextOffset": .integer(end), "truncated": .bool(end < source.bytes),
        "matchOffset": matchOffset.map(JSONValue.integer) ?? .null,
      ]))
  }

  private static func normalizedURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
    return url
  }

  private static func isTextLike(_ contentType: String?) -> Bool {
    let mime = contentType?.lowercased() ?? ""
    return mime.isEmpty || mime.hasPrefix("text/") || mime.contains("html")
      || mime.contains("xml") || mime.contains("json")
  }
}
