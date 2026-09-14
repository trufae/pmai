import Foundation

/// Converts an HTML or XHTML document into Markdown using the same parser as
/// EPUB chapters. The original source remains available through
/// `DocumentAttachmentImporter` when conversion is not wanted.
public enum HTMLImporter {
  private static let unsafeElementPattern = #"<(script|style|template)\b[^>]*>[\s\S]*?</\1\s*>"#
  private static let voidElementPattern = #"<(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)(\b[^<>]*?)(?<!/)>"#

  public enum ImportError: LocalizedError, Equatable, Sendable {
    case emptyDocument

    public var errorDescription: String? {
      switch self {
      case .emptyDocument: "The HTML document does not contain any text."
      }
    }
  }

  public static func markdown(from url: URL) throws -> String {
    try markdown(from: Data(contentsOf: url))
  }

  public static func markdown(from data: Data) throws -> String {
    let prepared = prepared(data)
    let markdown = HTMLToMarkdownParser().parse(prepared)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !markdown.isEmpty else { throw ImportError.emptyDocument }
    return markdown
  }

  /// HTML permits void elements without a closing slash and arbitrary script
  /// contents; XMLParser does not. Normalize those two common differences so
  /// ordinary browser HTML follows the same portable parser as XHTML/EPUB.
  private static func prepared(_ data: Data) -> Data {
    let html = (String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? String(decoding: data, as: UTF8.self))
      .replacingOccurrences(
        of: #"<!doctype[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
      .replacingOccurrences(
        of: unsafeElementPattern, with: "", options: [.regularExpression, .caseInsensitive])
      .replacingOccurrences(
        of: voidElementPattern, with: #"<$1$2/>"#,
        options: [.regularExpression, .caseInsensitive])
    return Data(html.utf8)
  }
}
