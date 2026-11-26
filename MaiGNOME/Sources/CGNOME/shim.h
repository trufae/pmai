#pragma once
#include <adwaita.h>

static inline GApplicationFlags mai_instance_flags(gboolean independent) {
  return independent ? G_APPLICATION_NON_UNIQUE : G_APPLICATION_DEFAULT_FLAGS;
}

static inline GtkWidget *mai_window(AdwApplication *app) {
  return adw_application_window_new(GTK_APPLICATION(app));
}

static inline GtkWidget *mai_split(GtkWidget *window, GtkWidget *sidebar, GtkWidget *content) {
  GtkWidget *split = adw_overlay_split_view_new();
  adw_overlay_split_view_set_sidebar(ADW_OVERLAY_SPLIT_VIEW(split), sidebar);
  adw_overlay_split_view_set_content(ADW_OVERLAY_SPLIT_VIEW(split), content);
  AdwBreakpoint *breakpoint = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 660sp"));
  adw_breakpoint_add_setters(breakpoint, split, "collapsed", TRUE, NULL);
  adw_application_window_add_breakpoint(ADW_APPLICATION_WINDOW(window), breakpoint);
  GtkWidget *content_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_vexpand(split, TRUE);
  gtk_box_append(GTK_BOX(content_box), split);
  adw_application_window_set_content(ADW_APPLICATION_WINDOW(window), content_box);
  return split;
}

static inline void mai_bind_sidebar_toggle(GtkWidget *split, GtkWidget *button) {
  g_object_bind_property(split, "show-sidebar", button, "active",
    G_BINDING_BIDIRECTIONAL | G_BINDING_SYNC_CREATE);
}

static inline void mai_update_transcript_theme(AdwStyleManager *manager, GParamSpec *property,
    GtkWidget *window) {
  if (adw_style_manager_get_dark(manager))
    gtk_widget_add_css_class(window, "dark-transcript");
  else
    gtk_widget_remove_css_class(window, "dark-transcript");
}

static inline void mai_style_transcript(GtkWidget *window) {
  GtkCssProvider *provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(provider,
    ".console-block { background: #ededed; color: #232323; border-radius: 6px; padding: 8px 10px; }"
    ".dark-transcript .console-block { background: #000; color: #f6f5f4; }", -1);
  gtk_style_context_add_provider_for_display(gtk_widget_get_display(window),
    GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(provider);
  AdwStyleManager *manager = adw_style_manager_get_for_display(gtk_widget_get_display(window));
  mai_update_transcript_theme(manager, NULL, window);
  g_signal_connect_object(manager, "notify::dark", G_CALLBACK(mai_update_transcript_theme), window, 0);
}

static inline gulong mai_signal(gpointer object, const char *name, GCallback callback,
    gpointer data, GClosureNotify destroy) {
  return g_signal_connect_data(object, name, callback, data, destroy, 0);
}

static inline gboolean mai_send_key_pressed(GtkEventControllerKey *controller, guint key,
    guint keycode, GdkModifierType modifiers, GtkWidget *button) {
  if ((key != GDK_KEY_Return && key != GDK_KEY_KP_Enter && key != GDK_KEY_ISO_Enter) ||
      (modifiers & gtk_accelerator_get_default_mod_mask())) {
    return FALSE;
  }
  GtkEventController *events = GTK_EVENT_CONTROLLER(controller);
  GtkWidget *editor = gtk_event_controller_get_widget(events);
  GdkEvent *event = gtk_event_controller_get_current_event(events);
  if (event && gtk_text_view_im_context_filter_keypress(GTK_TEXT_VIEW(editor), event)) {
    return TRUE;
  }
  if (gtk_widget_is_sensitive(button)) {
    gtk_widget_activate(button);
  }
  return TRUE;
}

static inline void mai_bind_send_key(GtkWidget *editor, GtkWidget *button) {
  GtkEventController *controller = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);
  g_signal_connect_object(controller, "key-pressed", G_CALLBACK(mai_send_key_pressed), button, 0);
  gtk_widget_add_controller(editor, controller);
}

static inline GtkNativeDialog *mai_file_chooser(GtkWidget *window, gboolean folder, const char *path) {
  GtkFileChooserNative *dialog = gtk_file_chooser_native_new(folder ? "Open Project Folder" : "Attach File",
    GTK_WINDOW(window), folder ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN,
    folder ? "Open" : "Attach", "Cancel");
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog), TRUE);
  if (path) {
    GFile *directory = g_file_new_for_path(path);
    gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog), directory, NULL);
    g_object_unref(directory);
  }
  return GTK_NATIVE_DIALOG(dialog);
}

static inline char *mai_chooser_path(gpointer dialog) {
  GFile *file = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(dialog));
  if (!file) return NULL;
  char *path = g_file_get_path(file);
  g_object_unref(file);
  return path;
}
