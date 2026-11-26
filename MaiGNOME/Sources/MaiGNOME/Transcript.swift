import CGNOME
import Foundation
import MaiACP
import MaiCore
import MaiMarkdown

final class TranscriptView: @unchecked Sendable {
  let scroll = gtk_scrolled_window_new()!
  var onContextMenu: ((ACPConversationMessage, Widget, Double, Double) -> Void)?
  private let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16)!
  private let messages = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16)!
  private let welcome = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
  private let more = gtk_button_new_with_label("Show Earlier Messages")!
  private var rows: [UUID: Row] = [:]
  private var displayed: [ACPConversationMessage] = []
  private var limit = 80
  private var scrollTarget: ScrollTarget?

  private enum ScrollTarget {
    case bottom
    case preserve(value: Double, upper: Double)
  }

  init() {
    gtk_widget_set_vexpand(scroll, 1)
    gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    let clamp = adw_clamp_new()!
    adw_clamp_set_maximum_size(OpaquePointer(clamp), 840)
    adw_clamp_set_tightening_threshold(OpaquePointer(clamp), 600)
    adw_clamp_set_child(OpaquePointer(clamp), column)
    gtk_scrolled_window_set_child(OpaquePointer(scroll), clamp)
    margins(column, 24)

    gtk_widget_set_halign(more, GTK_ALIGN_CENTER)
    append(column, more)
    append(column, messages)
    let title = label("PocketMai")
    gtk_widget_add_css_class(title, "title-1")
    gtk_widget_set_halign(title, GTK_ALIGN_CENTER)
    let detail = label("Open a conversation or start a new chat in a project.")
    gtk_widget_add_css_class(detail, "dim-label")
    gtk_widget_set_halign(detail, GTK_ALIGN_CENTER)
    append(welcome, title)
    append(welcome, detail)
    margins(welcome, 32)
    append(column, welcome)
    gtk_widget_set_visible(more, 0)
    signal(more, "clicked") { [weak self] in
      guard let self else { return }
      self.limit += 80
      self.render(self.displayed, showWelcome: false, prepending: true)
    }
    signal(adjustment, "changed") { [weak self] in self?.adjustScroll() }
  }

  private var adjustment: UnsafeMutablePointer<GtkAdjustment> {
    gtk_scrolled_window_get_vadjustment(OpaquePointer(scroll))!
  }

  func reset() {
    limit = 80
    scrollTarget = .bottom
    render([], showWelcome: false)
  }

  func render(_ transcript: [ACPConversationMessage], showWelcome: Bool, prepending: Bool = false) {
    let adjustment = self.adjustment
    let top = gtk_adjustment_get_value(adjustment)
    let upper = gtk_adjustment_get_upper(adjustment)
    let page = gtk_adjustment_get_page_size(adjustment)
    if prepending {
      scrollTarget = .preserve(value: top, upper: upper)
    } else if upper - top - page < 60 {
      scrollTarget = .bottom
    }
    displayed = transcript
    var grouped: [[ACPConversationMessage]] = []
    for entry in transcript {
      if entry.role == "tool", let last = grouped.indices.last, grouped[last][0].role == "tool" {
        grouped[last].append(entry)
      } else {
        grouped.append([entry])
      }
    }
    let visible = grouped.suffix(limit)
    let visibleIDs = Set(visible.map { $0[0].id })
    for id in rows.keys.filter({ !visibleIDs.contains($0) }) {
      if let row = rows.removeValue(forKey: id) {
        gtk_box_remove(cast(messages, GtkBox.self), row.widget)
      }
    }
    var previous: Widget?
    for entries in visible {
      let entry = entries[0]
      let row: Row
      if let existing = rows[entry.id], existing.entries[0].role == entry.role {
        row = existing
        if row.entries != entries { row.update(entries) }
      } else {
        if let existing = rows[entry.id] { gtk_box_remove(cast(messages, GtkBox.self), existing.widget) }
        row = Row(entries)
        rows[entry.id] = row
        if entry.role == "user" || entry.role == "assistant" {
          contextClick(row.widget) { [weak self, weak row] x, y in
            guard let row else { return }
            self?.onContextMenu?(row.entries[0], row.widget, x, y)
          }
        }
        append(messages, row.widget)
      }
      if gtk_widget_get_prev_sibling(row.widget) != previous {
        gtk_box_reorder_child_after(cast(messages, GtkBox.self), row.widget, previous)
      }
      previous = row.widget
    }
    gtk_widget_set_visible(more, visible.count < grouped.count ? 1 : 0)
    gtk_widget_set_visible(welcome, showWelcome ? 1 : 0)
    // "changed" usually arrives during layout. Clear any pending scroll when a
    // text update changes no geometry, so a later resize cannot jump the view.
    onGTK(after: 80) { [weak self] in self?.adjustScroll() }
  }

  private func adjustScroll() {
    guard let target = scrollTarget else { return }
    scrollTarget = nil
    let adjustment = self.adjustment
    let upper = gtk_adjustment_get_upper(adjustment)
    switch target {
    case .bottom:
      gtk_adjustment_set_value(adjustment, upper - gtk_adjustment_get_page_size(adjustment))
    case .preserve(let value, let previousUpper):
      gtk_adjustment_set_value(adjustment, value + upper - previousUpper)
    }
  }

  private final class Row {
    let widget: Widget
    let body: Widget
    let title: Widget
    var entries: [ACPConversationMessage]

    init(_ entries: [ACPConversationMessage]) {
      self.entries = entries
      let role = entries[0].role
      let isActivity = ["tool", "thought", "plan"].contains(role)
      title = label("")
      if role == "tool" || role == "assistant" {
        body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
      } else {
        body = label("")
        gtk_label_set_selectable(OpaquePointer(body), 1)
      }
      if isActivity {
        widget = gtk_expander_new(nil)!
        gtk_expander_set_label_widget(OpaquePointer(widget), title)
        gtk_expander_set_child(OpaquePointer(widget), body)
        gtk_widget_add_css_class(title, "dim-label")
        margins(body, 8)
      } else {
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        gtk_widget_add_css_class(title, "heading")
        append(widget, title)
        append(widget, body)
        if role == "user" {
          gtk_widget_add_css_class(widget, "card")
          margins(title, 10)
          gtk_widget_set_margin_start(body, 10)
          gtk_widget_set_margin_end(body, 10)
          gtk_widget_set_margin_bottom(body, 10)
        }
      }
      update(entries)
      if role == "tool" {
        observeProperty(OpaquePointer(widget), "expanded") { [weak self] in self?.renderTools() }
      }
    }

    func update(_ entries: [ACPConversationMessage]) {
      self.entries = entries
      let entry = entries[0]
      switch entry.role {
      case "tool":
        var summary = [entries.count == 1 ? "1 tool call" : "\(entries.count) tool calls"]
        let running = entries.count { $0.status == "pending" || $0.status == "in_progress" }
        let failed = entries.count { $0.status == "failed" }
        if running > 0 { summary.append("\(running) active") }
        if failed > 0 { summary.append("\(failed) failed") }
        setLabel(title, summary.joined(separator: " · "))
        renderTools()
      case "thought":
        setLabel(title, "Reasoning")
        setLabel(body, entry.text)
      case "plan":
        setLabel(title, "Plan")
        setLabel(body, entry.text)
      case "user":
        setLabel(title, "You")
        setLabel(body, entry.text)
      case "assistant":
        setLabel(title, "Assistant")
        renderMarkdown(entry.text, in: body)
      default:
        setLabel(title, entry.role.capitalized)
        setLabel(body, entry.text)
      }
    }

    private func renderTools() {
      clear(body)
      guard gtk_expander_get_expanded(OpaquePointer(widget)) != 0 else { return }
      for tool in entries {
        let status = tool.status?.replacingOccurrences(of: "_", with: " ").capitalized
        let heading = label([tool.toolName ?? "Tool", status].compactMap { $0 }.joined(separator: " · "))
        gtk_widget_add_css_class(heading, "heading")
        append(body, heading)
        let output = [tool.toolInput.flatMap(jsonText), tool.text].compactMap { $0 }
          .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !output.isEmpty { append(body, consoleBlock(output)) }
      }
    }
  }
}

func jsonText(_ value: JSONValue) -> String? {
  guard value != .null else { return nil }
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
}

private func escape(_ text: String) -> String {
  text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\0", with: "")
}

private func inline(_ text: String) -> String {
  MarkdownInlineParser.runs(from: text).map { run in
    var text = escape(run.text)
    if run.style.contains(.bold) { text = "<b>\(text)</b>" }
    if run.style.contains(.italic) { text = "<i>\(text)</i>" }
    if run.style.contains(.code) { text = "<tt>\(text)</tt>" }
    if run.style.contains(.strikethrough) { text = "<s>\(text)</s>" }
    if run.style.contains(.link), let destination = run.destination,
      let scheme = URL(string: destination)?.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme)
    {
      text = "<a href=\"\(escape(destination))\">\(text)</a>"
    }
    return text
  }.joined()
}

private func consoleBlock(_ text: String) -> Widget {
  let output = label(text)
  gtk_widget_add_css_class(output, "console-block")
  gtk_widget_add_css_class(output, "monospace")
  gtk_label_set_selectable(OpaquePointer(output), 1)
  return output
}

private func renderMarkdown(_ text: String, in body: Widget) {
  clear(body)
  var prose: [String] = []
  func flushProse() {
    guard !prose.isEmpty else { return }
    let output = label("")
    gtk_label_set_selectable(OpaquePointer(output), 1)
    gtk_label_set_markup(OpaquePointer(output), prose.joined(separator: "\n\n"))
    append(body, output)
    prose.removeAll(keepingCapacity: true)
  }
  for block in MarkdownBlockParser.blocks(from: text) {
    if case .code(let language, let code) = block {
      flushProse()
      if !language.isEmpty {
        let title = label(language)
        gtk_widget_add_css_class(title, "dim-label")
        append(body, title)
      }
      append(body, consoleBlock(code))
    } else {
      prose.append(markdownMarkup(block))
    }
  }
  flushProse()
}

private func markdownMarkup(_ block: MarkdownBlock) -> String {
  switch block {
    case .heading(let level, let text):
      "<span weight=\"bold\" size=\"\(level <= 2 ? "large" : "medium")\">\(inline(text))</span>"
    case .paragraph(let text): inline(text)
    case .quote(let text): "<i>\(inline(text))</i>"
    case .rule: "────────"
    case .code(_, let code): escape(code)
    case .table(let table):
      ([table.headers] + table.rows).map { row in row.map(inline).joined(separator: "  │  ") }.joined(separator: "\n")
    case .bullets(let items): items.map { "•  " + inline($0) }.joined(separator: "\n")
    case .ordered(let items): items.map { escape($0.label) + "  " + inline($0.text) }.joined(separator: "\n")
    case .tasks(let items): items.map { ($0.checked ? "☑  " : "☐  ") + inline($0.text) }.joined(separator: "\n")
    case .footnotes(let items): items.map { escape($0.key) + "  " + inline($0.text) }.joined(separator: "\n")
  }
}
