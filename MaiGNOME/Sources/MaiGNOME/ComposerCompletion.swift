import CGNOME
import Foundation
import MaiCore

enum ComposerCommand: String, CaseIterable {
  case agent, help, model, provider, set, settings, sidebar, stop

  var summary: String {
    switch self {
    case .agent: "Choose the agent for this chat"
    case .help: "Show available composer commands"
    case .model: "Choose the model for this chat"
    case .provider: "Choose the provider for this chat"
    case .set: "Set a chat option"
    case .settings: "Open PocketMai Settings"
    case .sidebar: "Show or hide conversations"
    case .stop: "Interrupt the current reply"
    }
  }
}

final class ComposerCompletion {
  private struct Candidate: Equatable {
    let name: String
    let detail: String
  }

  private struct Word {
    let prefix: Character
    let start: Int
    let end: Int
    let fragment: String
    let atEnd: Bool
  }

  var onCaretChange: (() -> Void)?
  private let editor: Widget
  private let popup = gtk_popover_new()!
  private let rows = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
  private let scroll = gtk_scrolled_window_new()!
  private var candidates: [Candidate] = []
  private var selection = 0
  private var buttons: [Widget] = []
  private var prefix: Character?
  private var dismissed: String?
  private var choosing = false

  init(editor: Widget) {
    self.editor = editor
    gtk_popover_set_autohide(cast(popup, GtkPopover.self), 0)
    gtk_popover_set_position(cast(popup, GtkPopover.self), GTK_POS_TOP)
    gtk_widget_set_size_request(scroll, 320, -1)
    gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroll), 1)
    gtk_scrolled_window_set_max_content_height(OpaquePointer(scroll), 260)
    gtk_scrolled_window_set_child(OpaquePointer(scroll), rows)
    gtk_popover_set_child(cast(popup, GtkPopover.self), scroll)
    gtk_widget_set_parent(popup, editor)
    let focus = gtk_event_controller_focus_new()!
    signal(focus, "enter") { [weak self] in self?.onCaretChange?() }
    signal(focus, "leave") { [weak self] in self?.hide() }
    gtk_widget_add_controller(editor, focus)
    observeProperty(OpaquePointer(gtk_text_view_get_buffer(cast(editor, GtkTextView.self))!), "cursor-position") { [weak self] in
      self?.onCaretChange?()
    }
    captureKeyPress(editor) { [weak self] key in self?.keyPressed(key) ?? false }
  }

  func detach() {
    hide()
    gtk_widget_unparent(popup)
  }

  func update(_ catalog: PromptCatalog) {
    guard !choosing, gtk_widget_has_focus(editor) != 0 else { hide(); return }
    let text = editorText(editor)
    guard text != dismissed, let word = word(in: text) else { hide(); return }
    dismissed = nil
    var seen = Set<String>()
    let commands = ComposerCommand.allCases.map { Candidate(name: $0.rawValue, detail: $0.summary) }
    let entries = catalog.entries.compactMap { entry -> Candidate? in
      let normalized = PromptSlashCommand.normalized(entry.commandName)
      guard seen.insert(normalized).inserted, entry.kind != .system else { return nil }
      let kind = entry.invocation == nil ? entry.kind.label : "command"
      let detail = entry.summary.isEmpty ? kind : kind + " · " + entry.summary
      return Candidate(name: entry.commandName, detail: detail)
    }
    let ordered = word.prefix == "/" ? commands + entries : entries + commands
    seen.removeAll(keepingCapacity: true)
    let next = ordered.filter {
      let name = PromptSlashCommand.normalized($0.name)
      return seen.insert(name).inserted && name.hasPrefix(word.fragment)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    guard !next.isEmpty else { hide(); return }
    if candidates != next || prefix != word.prefix {
      candidates = next
      prefix = word.prefix
      selection = 0
      clear(rows)
      buttons = next.enumerated().map { index, candidate in
        let button = gtk_button_new()!
        let details = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let name = label(String(word.prefix) + candidate.name, wrap: false)
        let summary = label(candidate.detail, wrap: false)
        gtk_label_set_ellipsize(OpaquePointer(summary), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(summary, "dim-label")
        gtk_widget_add_css_class(summary, "caption")
        append(details, name)
        append(details, summary)
        gtk_button_set_child(cast(button, GtkButton.self), details)
        gtk_widget_add_css_class(button, "flat")
        gtk_widget_set_focusable(button, 0)
        signal(button, "clicked") { [weak self] in self?.choose(index) }
        append(rows, button)
        return button
      }
      markSelection()
    }
    var anchor = GdkRectangle(x: 0, y: 0, width: 1, height: 1)
    gtk_popover_set_pointing_to(cast(popup, GtkPopover.self), &anchor)
    gtk_popover_popup(cast(popup, GtkPopover.self))
  }

  private func hide() {
    candidates.removeAll(keepingCapacity: true)
    gtk_popover_popdown(cast(popup, GtkPopover.self))
  }

  private func word(in text: String) -> Word? {
    let buffer = gtk_text_view_get_buffer(cast(editor, GtkTextView.self))!
    guard gtk_text_buffer_get_has_selection(buffer) == 0 else { return nil }
    var cursor = GtkTextIter()
    gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer))
    let scalars = text.unicodeScalars
    guard let start = scalars.firstIndex(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
      let caret = scalars.index(scalars.startIndex, offsetBy: Int(gtk_text_iter_get_offset(&cursor)),
        limitedBy: scalars.endIndex)
    else { return nil }
    let prefix = Character(scalars[start])
    guard PromptSlashCommand.prefixes.contains(prefix) else { return nil }
    let name = scalars.index(after: start)
    let end = scalars[name...].firstIndex(where: CharacterSet.whitespacesAndNewlines.contains) ?? scalars.endIndex
    guard caret >= name, caret <= end else { return nil }
    return Word(prefix: prefix, start: scalars.distance(from: scalars.startIndex, to: start),
      end: scalars.distance(from: scalars.startIndex, to: end),
      fragment: PromptSlashCommand.normalized(String(scalars[name..<caret])), atEnd: end == scalars.endIndex)
  }

  private func choose(_ index: Int) {
    guard candidates.indices.contains(index), let word = word(in: editorText(editor)) else { hide(); return }
    let replacement = String(word.prefix) + candidates[index].name + (word.atEnd ? " " : "")
    choosing = true
    let buffer = gtk_text_view_get_buffer(cast(editor, GtkTextView.self))!
    var start = GtkTextIter()
    var end = GtkTextIter()
    gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(word.start))
    gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(word.end))
    gtk_text_buffer_begin_user_action(buffer)
    gtk_text_buffer_delete(buffer, &start, &end)
    gtk_text_buffer_insert(buffer, &start, replacement, -1)
    gtk_text_buffer_place_cursor(buffer, &start)
    gtk_text_buffer_end_user_action(buffer)
    dismissed = editorText(editor)
    choosing = false
    hide()
  }

  private func keyPressed(_ key: UInt32) -> Bool {
    guard !candidates.isEmpty else { return false }
    switch key {
    case UInt32(GDK_KEY_Up), UInt32(GDK_KEY_Down):
      let step = key == UInt32(GDK_KEY_Up) ? -1 : 1
      selection = (selection + candidates.count + step) % candidates.count
      markSelection()
      var bounds = graphene_rect_t()
      if gtk_widget_compute_bounds(buttons[selection], rows, &bounds) != 0 {
        gtk_adjustment_clamp_page(gtk_scrolled_window_get_vadjustment(OpaquePointer(scroll)),
          Double(bounds.origin.y), Double(bounds.origin.y + bounds.size.height))
      }
    case UInt32(GDK_KEY_Tab): choose(selection)
    case UInt32(GDK_KEY_Escape):
      dismissed = editorText(editor)
      hide()
    default: return false
    }
    return true
  }

  private func markSelection() {
    for (index, button) in buttons.enumerated() {
      if index == selection { gtk_widget_add_css_class(button, "accent") }
      else { gtk_widget_remove_css_class(button, "accent") }
    }
  }
}
