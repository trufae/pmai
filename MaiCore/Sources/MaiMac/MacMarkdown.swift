import AppKit
import MaiMarkdown
import SwiftUI

/// The same block parser as CLI output and document exports, rendered natively.
struct MacMarkdown: View, @MainActor Equatable {
  let text: String
  var searchQuery = ""
  var role = "assistant"
  @State private var document: MacMarkdownDocument?
  private var typography = MacChatTypography()
  private var appearance = MacAppearance()

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text == rhs.text && lhs.searchQuery == rhs.searchQuery && lhs.role == rhs.role
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let document {
        ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
          render(block)
        }
      } else if !text.isEmpty {
        ProgressView().controlSize(.small)
      }
    }.font(typography.messageFont(for: role)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
        GeometryReader { geometry in
          MacMarkdownLinkCursor(rects: layouts.flatMap { anchored in
            let origin = geometry[anchored.origin]
            return anchored.layout.flatMap { line in
              line.compactMap { run -> CGRect? in
                guard run[MacMarkdownLink.self] != nil else { return nil }
                return run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
              }
            }
          })
        }.allowsHitTesting(false)
      }
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
    for run in attributed.runs where run.link != nil {
      attributed[run.range].underlineStyle = .single
    }
    attributed = MacSearchHighlight.apply(to: attributed, query: searchQuery)
    return attributed.runs.reduce(Text("")) { result, run in
      let part = Text(AttributedString(attributed[run.range]))
      let marked = run.link == nil ? part : part.customAttribute(MacMarkdownLink())
      return Text("\(result)\(marked)")
    }
  }

  @ViewBuilder private func render(_ block: MarkdownBlock) -> some View {
    switch block {
    case .paragraph(let text): inline(text)
    case .heading(let level, let text):
      inline(text).font(typography.messageFont(for: role, style: level == 1 ? .title1 : level == 2 ? .title2 : .headline)
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
        ScrollView(.horizontal) {
          Text(MacSearchHighlight.text(code, query: searchQuery))
            .font(typography.font(design: .monospaced)).fixedSize(horizontal: true, vertical: false)
        }
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
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        inline("[\(item.key)] \(item.text)").font(typography.messageFont(for: role, style: .caption1))
      }
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

private struct MacMarkdownLink: TextAttribute {}

/// Tracking areas follow SwiftUI's actual text layout, including wrapped links,
/// and override the selectable text's I-beam without intercepting clicks.
private struct MacMarkdownLinkCursor: NSViewRepresentable {
  var rects: [CGRect]

  func makeNSView(context: Context) -> CursorView { CursorView() }

  func updateNSView(_ view: CursorView, context: Context) {
    guard view.rects != rects else { return }
    view.rects = rects
    view.updateTrackingAreas()
  }

  final class CursorView: NSView {
    var rects: [CGRect] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas { removeTrackingArea(area) }
      for rect in rects {
        let visible = rect.intersection(visibleRect)
        if !visible.isEmpty {
          addTrackingArea(NSTrackingArea(rect: visible,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self, userInfo: nil))
        }
      }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
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
