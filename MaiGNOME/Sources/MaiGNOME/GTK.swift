import CGNOME
import Foundation

typealias Widget = UnsafeMutablePointer<GtkWidget>

func cast<T>(_ widget: Widget, _: T.Type) -> UnsafeMutablePointer<T> {
  UnsafeMutableRawPointer(widget).assumingMemoryBound(to: T.self)
}

func append(_ box: Widget, _ child: Widget) {
  gtk_box_append(cast(box, GtkBox.self), child)
}

func clear(_ box: Widget) {
  while let child = gtk_widget_get_first_child(box) {
    gtk_box_remove(cast(box, GtkBox.self), child)
  }
}

func margins(_ widget: Widget, _ value: Int32) {
  gtk_widget_set_margin_top(widget, value)
  gtk_widget_set_margin_bottom(widget, value)
  gtk_widget_set_margin_start(widget, value)
  gtk_widget_set_margin_end(widget, value)
}

func label(_ text: String, wrap: Bool = true) -> Widget {
  let widget = gtk_label_new(text)!
  let label = OpaquePointer(widget)
  gtk_label_set_xalign(label, 0)
  gtk_label_set_wrap(label, wrap ? 1 : 0)
  gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR)
  return widget
}

func setLabel(_ widget: Widget, _ text: String) {
  gtk_label_set_text(OpaquePointer(widget), text)
}

func iconButton(_ icon: String, _ title: String) -> Widget {
  let widget = gtk_button_new_from_icon_name(icon)!
  gtk_widget_set_tooltip_text(widget, title)
  return widget
}

private final class Callback {
  let run: () -> Void
  init(_ run: @escaping () -> Void) { self.run = run }
}

private final class FileCallback {
  let run: (URL) -> Void
  init(_ run: @escaping (URL) -> Void) { self.run = run }
}

/// GTK owns the UI thread. Swift tasks enqueue work on GLib's main context.
func onGTK(after milliseconds: UInt32 = 0, _ run: @escaping @Sendable () -> Void) {
  let data = Unmanaged.passRetained(Callback(run)).toOpaque()
  let callback: GSourceFunc = { data in
    if let data { Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run() }
    return 0
  }
  let destroy: GDestroyNotify = { data in
    if let data { Unmanaged<Callback>.fromOpaque(data).release() }
  }
  if milliseconds == 0 {
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, callback, data, destroy)
  } else {
    g_timeout_add_full(G_PRIORITY_DEFAULT, milliseconds, callback, data, destroy)
  }
}

func signal(_ object: OpaquePointer, _ name: String, _ run: @escaping () -> Void) {
  let data = Unmanaged.passRetained(Callback(run)).toOpaque()
  let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    if let data { Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run() }
  }
  mai_signal(UnsafeMutableRawPointer(object), name, unsafeBitCast(callback, to: GCallback.self), data) { data, _ in
    if let data { Unmanaged<Callback>.fromOpaque(data).release() }
  }
}

func signal<T>(_ object: UnsafeMutablePointer<T>, _ name: String, _ run: @escaping () -> Void) {
  signal(OpaquePointer(object), name, run)
}

func observeProperty(_ object: OpaquePointer, _ name: String, _ run: @escaping () -> Void) {
  let data = Unmanaged.passRetained(Callback(run)).toOpaque()
  let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
    _, _, data in
    if let data { Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run() }
  }
  mai_signal(UnsafeMutableRawPointer(object), "notify::" + name, unsafeBitCast(callback, to: GCallback.self), data) { data, _ in
    if let data { Unmanaged<Callback>.fromOpaque(data).release() }
  }
}

func captureKeyPress(_ widget: Widget, _ run: @escaping (UInt32) -> Bool) {
  let controller = gtk_event_controller_key_new()!
  gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
  let data = Unmanaged.passRetained(KeyCallback(run)).toOpaque()
  let callback: @convention(c) (OpaquePointer?, UInt32, UInt32, GdkModifierType, UnsafeMutableRawPointer?) -> Int32 = {
    _, key, _, modifiers, data in
    guard let data, (modifiers.rawValue & gtk_accelerator_get_default_mod_mask().rawValue) == 0 else { return 0 }
    return Unmanaged<KeyCallback>.fromOpaque(data).takeUnretainedValue().run(key) ? 1 : 0
  }
  mai_signal(UnsafeMutableRawPointer(controller), "key-pressed", unsafeBitCast(callback, to: GCallback.self), data) { data, _ in
    if let data { Unmanaged<KeyCallback>.fromOpaque(data).release() }
  }
  gtk_widget_add_controller(widget, controller)
}

private final class KeyCallback {
  let run: (UInt32) -> Bool
  init(_ run: @escaping (UInt32) -> Bool) { self.run = run }
}

private func dismissOnEscape(_ widget: Widget, dismiss: @escaping () -> Void) {
  captureKeyPress(widget) { key in
    guard key == UInt32(GDK_KEY_Escape) else { return false }
    dismiss()
    return true
  }
}

func dismissPopoverOnEscape(_ popover: Widget) {
  dismissOnEscape(popover) { gtk_popover_popdown(cast(popover, GtkPopover.self)) }
}

func contextClick(_ widget: Widget, _ run: @escaping (Double, Double) -> Void) {
  let gesture = gtk_gesture_click_new()!
  gtk_gesture_single_set_button(gesture, UInt32(GDK_BUTTON_SECONDARY))
  gtk_event_controller_set_propagation_phase(gesture, GTK_PHASE_CAPTURE)
  let data = Unmanaged.passRetained(ContextClick(run)).toOpaque()
  let callback: @convention(c) (OpaquePointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = {
    gesture, _, x, y, data in
    guard let data else { return }
    gtk_gesture_set_state(gesture, GTK_EVENT_SEQUENCE_CLAIMED)
    Unmanaged<ContextClick>.fromOpaque(data).takeUnretainedValue().run(x, y)
  }
  mai_signal(UnsafeMutableRawPointer(gesture), "pressed", unsafeBitCast(callback, to: GCallback.self), data) { data, _ in
    if let data { Unmanaged<ContextClick>.fromOpaque(data).release() }
  }
  gtk_widget_add_controller(widget, gesture)
}

private final class ContextClick {
  let run: (Double, Double) -> Void
  init(_ run: @escaping (Double, Double) -> Void) { self.run = run }
}

final class ContextMenu {
  struct Action {
    let title: String
    var destructive = false
    var enabled = true
    let run: () -> Void
  }

  private let parent: Widget
  private let popup = gtk_popover_new()!
  private let items = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!

  init(parent: Widget) {
    self.parent = parent
    margins(items, 4)
    gtk_popover_set_has_arrow(cast(popup, GtkPopover.self), 0)
    gtk_popover_set_child(cast(popup, GtkPopover.self), items)
    dismissPopoverOnEscape(popup)
    gtk_widget_set_parent(popup, parent)
  }

  func detach() {
    gtk_popover_popdown(cast(popup, GtkPopover.self))
    gtk_widget_unparent(popup)
  }

  func show(from widget: Widget, x: Double, y: Double, actions: [Action]) {
    guard !actions.isEmpty else { return }
    var source = graphene_point_t(x: Float(x), y: Float(y))
    var point = graphene_point_t()
    guard gtk_widget_compute_point(widget, parent, &source, &point) != 0 else { return }
    clear(items)
    for action in actions {
      let button = gtk_button_new()!
      let caption = label(action.title, wrap: false)
      gtk_button_set_child(cast(button, GtkButton.self), caption)
      gtk_widget_add_css_class(button, "flat")
      if action.destructive { gtk_widget_add_css_class(button, "destructive-action") }
      gtk_widget_set_sensitive(button, action.enabled ? 1 : 0)
      signal(button, "clicked") { [weak self] in
        guard let self else { return }
        gtk_popover_popdown(cast(self.popup, GtkPopover.self))
        action.run()
      }
      append(items, button)
    }
    var rect = GdkRectangle(x: Int32(point.x), y: Int32(point.y), width: 1, height: 1)
    gtk_popover_set_pointing_to(cast(popup, GtkPopover.self), &rect)
    gtk_popover_popup(cast(popup, GtkPopover.self))
  }
}

func closeRequest(_ window: Widget, closeOnEscape: Bool = false, _ run: @escaping () -> Void) {
  let data = Unmanaged.passRetained(Callback(run)).toOpaque()
  let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32 = { _, data in
    if let data { Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run() }
    return 1
  }
  mai_signal(window, "close-request", unsafeBitCast(callback, to: GCallback.self), data) { data, _ in
    if let data { Unmanaged<Callback>.fromOpaque(data).release() }
  }
  if closeOnEscape {
    dismissOnEscape(window) { gtk_window_close(cast(window, GtkWindow.self)) }
  }
}

func chooseFile(window: Widget, folder: Bool, directory: String?, action: @escaping (URL) -> Void) {
  guard let dialog = mai_file_chooser(window, folder ? 1 : 0, directory) else { return }
  let data = Unmanaged.passRetained(FileCallback(action)).toOpaque()
  let callback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void = {
    dialog, response, data in
    guard let dialog, let data else { return }
    let action = Unmanaged<FileCallback>.fromOpaque(data).takeUnretainedValue()
    if response == GTK_RESPONSE_ACCEPT.rawValue, let path = mai_chooser_path(dialog) {
      action.run(URL(fileURLWithPath: String(cString: path)))
      g_free(path)
    }
    gtk_native_dialog_destroy(dialog.assumingMemoryBound(to: GtkNativeDialog.self))
    g_object_unref(dialog)
  }
  mai_signal(dialog, "response", unsafeBitCast(callback, to: GCallback.self), data) { data, _ in
    if let data { Unmanaged<FileCallback>.fromOpaque(data).release() }
  }
  gtk_native_dialog_show(dialog)
}

func editorText(_ view: Widget) -> String {
  let buffer = gtk_text_view_get_buffer(cast(view, GtkTextView.self))
  var start = GtkTextIter()
  var end = GtkTextIter()
  gtk_text_buffer_get_bounds(buffer, &start, &end)
  guard let value = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
  defer { g_free(value) }
  return String(cString: value)
}

func setEditorText(_ view: Widget, _ value: String) {
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(view, GtkTextView.self)), value, -1)
}
