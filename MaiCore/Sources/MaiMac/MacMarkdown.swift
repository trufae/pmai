import AppKit
import MaiMarkdown
import SwiftUI

/// The same block parser as CLI output and document exports, rendered natively.
struct MacMarkdown: View, @MainActor Equatable {
  let text: String
  @State private var document: MacMarkdownDocument?
  private var typography = MacChatTypography()
  private var appearance = MacAppearance()

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let document {
        ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
          render(block)
        }
      } else if !text.isEmpty {
        ProgressView().controlSize(.small)
      }
    }.font(typography.font()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      .task(id: text) {
        guard document?.source != text else { return }
        guard let prepared = try? await MacMarkdownParser.shared.parse(text), !Task.isCancelled else { return }
        document = prepared
      }
  }

  private func inline(_ text: String) -> Text {
    var attributed = document?.inlineText[text] ?? AttributedString(text)
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

private actor MacMarkdownParser {
  static let shared = MacMarkdownParser()

  func parse(_ text: String) throws -> MacMarkdownDocument {
    // Serialize work so rapid stream updates cannot launch overlapping parses.
    // Cancelled snapshots are discarded before parsing starts.
    try MacMarkdownDocument(source: text)
  }
}

/// Width-independent parsing is retained by each bubble. Resizing only lays out
/// prepared text; neither block parsing nor inline Markdown runs on the UI thread.
struct MacMarkdownDocument: Sendable {
  let source: String
  let blocks: [MarkdownBlock]
  let inlineText: [String: AttributedString]

  init(source: String) throws {
    try Task.checkCancellation()
    self.source = source
    blocks = MarkdownBlockParser.blocks(from: source)
    var inlineText: [String: AttributedString] = [:]
    for block in blocks {
      try Task.checkCancellation()
      let strings: [String]
      switch block {
      case .paragraph(let text), .heading(_, let text), .quote(let text): strings = [text]
      case .bullets(let items): strings = items
      case .ordered(let items): strings = items.map(\.text)
      case .tasks(let items): strings = items.map(\.text)
      case .footnotes(let items): strings = items.map { "[\($0.key)] \($0.text)" }
      case .table(let table): strings = table.headers + table.rows.flatMap { $0 }
      case .rule, .code: strings = []
      }
      for text in strings where inlineText[text] == nil {
        try Task.checkCancellation()
        inlineText[text] = (try? AttributedString(markdown: text,
          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
      }
    }
    self.inlineText = inlineText
  }
}
