import Foundation
import MaiMarkdown

#if os(iOS)
  import SwiftUI
#else
  import SwiftUICore
#endif

/// Renders a markdown reply with the shared MaiMarkdown parser.
///
/// The portable Text holds one plain string, so a paragraph cannot mix styles.
/// Blocks get their own layout; inline markers are removed, a paragraph whose
/// text is entirely bold or italic takes that style, and its links follow it
/// as tappable rows.
struct MarkdownText: View {
  private let blocks: [MarkdownBlock]

  init(_ markdown: String) { blocks = MarkdownBlockParser.blocks(from: markdown) }

  private static let subtle = Color(red: 0.5, green: 0.5, blue: 0.55, opacity: 0.12)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        Self.view(for: block)
      }
    }
  }

  // AnyView keeps the per-block switch out of the builder: the portable
  // evaluator only flattens conditionals inside containers.
  private static func view(for block: MarkdownBlock) -> AnyView {
    switch block {
    case .heading(let level, let text):
      return AnyView(inline(text, size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
    case .paragraph(let text):
      return AnyView(inline(text))
    case .quote(let text):
      return AnyView(
        inline(text)
          .opacity(0.85)
          .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(subtle)
          .cornerRadius(8))
    case .rule:
      return AnyView(Divider())
    case .code(let language, let code):
      return AnyView(codeBlock(language: language, code: code))
    case .table(let table):
      return AnyView(tableView(table))
    case .bullets(let items):
      return AnyView(list(items.map { ("•", $0) }))
    case .ordered(let items):
      return AnyView(list(items.map { ($0.label, $0.text) }))
    case .tasks(let items):
      return AnyView(list(items.map { ($0.checked ? "✓" : "○", $0.text) }))
    case .footnotes(let notes):
      return AnyView(
        VStack(alignment: .leading, spacing: 4) {
          Divider()
          ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
            Text("[\(note.key)] " + MarkdownInlineParser.plainText(note.text))
              .font(.caption)
              .opacity(0.7)
          }
        })
    }
  }

  private static func headingSize(_ level: Int) -> Double {
    switch level {
    case 1: 24
    case 2: 21
    case 3: 18
    default: 16
    }
  }

  /// One block of inline markdown: its plain text, then any links it holds.
  private static func inline(
    _ source: String, size: Double = 16, weight: Font.Weight? = nil
  ) -> some View {
    let runs = MarkdownInlineParser.runs(from: source)
    let text = runs.map(\.text).joined()
    let styles = runs.filter { !$0.text.allSatisfy(\.isWhitespace) }.map(\.style)
    let bold = !styles.isEmpty && styles.allSatisfy { $0.contains(.bold) }
    let italic = !styles.isEmpty && styles.allSatisfy { $0.contains(.italic) }
    let font = Font.system(size: size, weight: bold ? .bold : weight)
    let links = links(in: runs)
    return VStack(alignment: .leading, spacing: 4) {
      if italic {
        Text(text).font(font).italic()
      } else {
        Text(text).font(font)
      }
      ForEach(Array(links.enumerated()), id: \.offset) { _, link in
        Link(destination: link.url) {
          Text("↗ " + link.title).font(.callout)
        }
      }
    }
  }

  /// Markdown links, then bare web addresses written in plain text.
  private static func links(in runs: [MarkdownInlineRun]) -> [(title: String, url: URL)] {
    var links: [(title: String, url: URL)] = []
    func add(_ title: String, _ address: String) {
      guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
        ["http", "https", "mailto"].contains(scheme),
        !links.contains(where: { $0.url == url })
      else { return }
      links.append((title.isEmpty ? address : title, url))
    }
    for run in runs {
      if run.style.contains(.link), !run.style.contains(.image), let destination = run.destination {
        add(run.text, destination)
      } else if !run.style.contains(.code) {
        for match in run.text.matches(of: #/https?://[^\s<>()\[\]]+/#) {
          var address = String(match.output)
          while let last = address.last, ".,;:!?'\"".contains(last) { address.removeLast() }
          add(address, address)
        }
      }
    }
    return links
  }

  private static func list(_ items: [(marker: String, text: String)]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .top, spacing: 8) {
          Text(item.marker).font(.system(size: 16)).opacity(0.8)
          inline(item.text)
        }
      }
    }
  }

  private static func codeBlock(language: String, code: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if !language.isEmpty { Text(language).font(.caption).opacity(0.7) }
      // Code keeps its line breaks and scrolls sideways rather than wrapping.
      ScrollView(.horizontal) {
        Text(code).font(.system(size: 14))
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(subtle)
    .cornerRadius(8)
  }

  /// Columns are stacks, so each one is as wide as its widest cell.
  private static func tableView(_ table: MarkdownTable) -> some View {
    let columns = table.headers.indices.map { column in
      (
        header: MarkdownInlineParser.plainText(table.headers[column]),
        cells: table.rows.map {
          column < $0.count ? MarkdownInlineParser.plainText($0[column]) : ""
        }
      )
    }
    return ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: 20) {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
          VStack(alignment: .leading, spacing: 8) {
            Text(column.header).font(.system(size: 15, weight: .semibold))
            ForEach(Array(column.cells.enumerated()), id: \.offset) { _, cell in
              Text(cell).font(.system(size: 15))
            }
          }
        }
      }.padding(12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(subtle)
    .cornerRadius(8)
  }
}
