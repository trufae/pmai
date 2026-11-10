import AppKit
import MaiMarkdown
import SwiftUI

/// The same block parser as CLI output and document exports, rendered natively.
struct MacMarkdown: View {
  let text: String
  private var typography = MacChatTypography()
  private var appearance = MacAppearance()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(MarkdownBlockParser.blocks(from: text).enumerated()), id: \.offset) { _, block in
        render(block)
      }
    }.font(typography.font()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func inline(_ text: String) -> Text {
    var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    for run in attributed.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
      attributed[run.range].foregroundColor = appearance.accentColor
    }
    return Text(attributed)
  }

  @ViewBuilder private func render(_ block: MarkdownBlock) -> some View {
    switch block {
    case .paragraph(let text): inline(text)
    case .heading(let level, let text):
      inline(text).font(typography.font(level == 1 ? .title1 : level == 2 ? .title2 : .headline)
        .weight(level <= 2 ? .regular : .semibold))
    case .quote(let text):
      inline(text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.leading, 16).padding(.trailing, 12)
        .background(appearance.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2).fill(appearance.accentColor.opacity(0.7))
            .frame(width: 3).padding(.vertical, 8)
        }
    case .rule: Divider()
    case .code(let language, let code):
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(language.isEmpty ? "Code" : language).font(typography.font(.caption1)).foregroundStyle(.secondary)
          Spacer()
          Button("Copy", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
          }.buttonStyle(.borderless).font(typography.font(.caption1))
        }
        ScrollView(.horizontal) { Text(code).font(typography.font(design: .monospaced)).fixedSize(horizontal: true, vertical: false) }
      }.padding(14).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    case .bullets(let items):
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .top) { Text("•"); inline(item) } }
    case .ordered(let items):
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .top) { Text(item.label); inline(item.text) } }
    case .tasks(let items):
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .top) { Image(systemName: item.checked ? "checkmark.square" : "square"); inline(item.text) }
      }
    case .footnotes(let items):
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in inline("[\(item.key)] \(item.text)").font(typography.font(.caption1)) }
    case .table(let table):
      ScrollView(.horizontal) {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
          GridRow { ForEach(Array(table.headers.enumerated()), id: \.offset) { _, cell in
            inline(cell).bold().foregroundStyle(appearance.accentColor)
          } }
          Divider()
          ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
            GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in inline(cell) } }
          }
        }.padding(12)
      }.background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}
