import Foundation
import MaiMarkdown

/// A plain-text transcript with speaker labels, readable markdown, and image names.
public enum TextExport {
  public static func text(for document: ExportDocument) -> String {
    let summary = document.summary
    var sections = [summary.title]
    sections.append(
      "Started \(summary.started) · Last updated \(summary.lastUpdated) · \(summary.messageCount)")
    for entry in document.exportedEntries {
      var parts = ["\(entry.role.displayName):"]
      for section in entry.reasoning {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append("Reasoning:\n\(plainText(trimmed))") }
      }
      let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty { parts.append(plainText(body)) }
      for image in entry.attachments {
        parts.append("Attached image: \(image.name)")
      }
      sections.append(parts.joined(separator: "\n\n"))
    }
    return sections.joined(separator: "\n\n") + "\n"
  }

  private static func plainText(_ markdown: String) -> String {
    MarkdownBlockParser.blocks(from: markdown).map { block in
      switch block {
      case .heading(_, let text), .paragraph(let text), .quote(let text):
        return inlineText(text)
      case .code(_, let code):
        return code
      case .rule:
        return "---"
      case .bullets(let items):
        return items.map { "• \(inlineText($0))" }.joined(separator: "\n")
      case .ordered(let items):
        return items.map { "\($0.label) \(inlineText($0.text))" }.joined(separator: "\n")
      case .tasks(let items):
        return items.map { "[\($0.checked ? "x" : " ")] \(inlineText($0.text))" }
          .joined(separator: "\n")
      case .table(let table):
        return ([table.headers] + table.rows).map { row in
          row.map(inlineText).joined(separator: "\t")
        }.joined(separator: "\n")
      case .footnotes(let notes):
        return notes.map { "[\($0.key)] \(inlineText($0.text))" }.joined(separator: "\n")
      }
    }.joined(separator: "\n\n")
  }

  private static func inlineText(_ text: String) -> String {
    MarkdownSpan.spans(
      for: MarkdownInlineParser.runs(from: text), role: .body, linkDestinations: true
    ).map(\.text).joined()
  }
}
