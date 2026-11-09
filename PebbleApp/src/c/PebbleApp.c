#include <pebble.h>

#define PRESET_LIMIT 8
#define DICTATION_SIZE 1024
#define REPLY_SIZE 1801

static Window *s_window, *s_reply_window;
static BitmapLayer *s_logo_layer;
static GBitmap *s_logo;
static MenuLayer *s_menu;
static TextLayer *s_title, *s_status, *s_reply;
static ScrollLayer *s_scroll;
static DictationSession *s_dictation;
static AppTimer *s_wait;
static bool s_transport, s_listening, s_ready;
static char s_status_text[80] = "Connecting…";
static char s_reply_text[REPLY_SIZE];
static struct {
  char id[37];
  char name[73];
} s_presets[PRESET_LIMIT];
static uint16_t s_preset_count;

static void set_status(const char *text) {
  snprintf(s_status_text, sizeof(s_status_text), "%s", text);
  text_layer_set_text(s_status, s_status_text);
}

static void stop_wait(void) {
  if (s_wait) {
    app_timer_cancel(s_wait);
    s_wait = NULL;
  }
}

static void timed_out(void *context) {
  s_wait = NULL;
  set_status("Open PocketMai on phone");
}

static void send_action(const char *action, const char *value) {
  if (!s_transport || s_wait) return;
  DictionaryIterator *out;
  if (app_message_outbox_begin(&out) != APP_MSG_OK ||
      dict_write_cstring(out, MESSAGE_KEY_Action, action) != DICT_OK ||
      (value && dict_write_cstring(out, MESSAGE_KEY_Value, value) != DICT_OK) ||
      app_message_outbox_send() != APP_MSG_OK) {
    set_status("Could not reach phone");
    return;
  }
  set_status("Contacting phone…");
  s_wait = app_timer_register(9000, timed_out, NULL);
}

static void dictation_result(DictationSession *session, DictationSessionStatus status,
                             char *transcription, void *context) {
  s_listening = false;
  if (status == DictationSessionStatusSuccess && transcription && *transcription) {
    send_action("voice", transcription);
  } else if (status == DictationSessionStatusFailureTranscriptionRejected) {
    set_status("Dictation canceled");
  } else {
    set_status("Dictation unavailable");
  }
}

static void start_dictation(void) {
  if (!s_dictation) {
    s_dictation = dictation_session_create(DICTATION_SIZE, dictation_result, NULL);
  }
  if (!s_dictation || dictation_session_start(s_dictation) != DictationSessionStatusSuccess) {
    set_status("Dictation unavailable");
    return;
  }
  s_listening = true;
  set_status("Listening…");
}

static const char *const s_actions[] = {
  "Talk to the Agent", "New Watch Chat", "Refresh Prompts", "Pair Phone",
};

static uint16_t row_count(MenuLayer *menu, uint16_t section, void *context) {
  return ARRAY_LENGTH(s_actions) + s_preset_count;
}

static int16_t row_height(MenuLayer *menu, MenuIndex *index, void *context) {
  return 34;
}

static void draw_row(GContext *ctx, const Layer *layer, MenuIndex *index, void *context) {
  const uint16_t row = index->row;
  const char *title = row < ARRAY_LENGTH(s_actions) ? s_actions[row]
    : s_presets[row - ARRAY_LENGTH(s_actions)].name;
  menu_cell_basic_draw(ctx, layer, title, NULL, NULL);
}

static void select_row(MenuLayer *menu, MenuIndex *index, void *context) {
  if (!s_transport || s_listening || s_wait) return;
  if (!s_ready && (index->row < 2 || index->row >= ARRAY_LENGTH(s_actions))) {
    set_status("Pair or refresh phone");
    return;
  }
  switch (index->row) {
  case 0: start_dictation(); break;
  case 1: send_action("new", NULL); break;
  case 2: send_action("menu", NULL); break;
  case 3: send_action("pair", NULL); break;
  default: send_action("preset", s_presets[index->row - ARRAY_LENGTH(s_actions)].id); break;
  }
}

static void load_presets(const char *list) {
  s_preset_count = 0;
  while (*list && s_preset_count < PRESET_LIMIT) {
    const char *end = strchr(list, '\n');
    if (!end) end = list + strlen(list);
    const char *tab = memchr(list, '\t', end - list);
    if (tab && tab - list == 36 && end - tab > 1 && end - tab <= 73) {
      memcpy(s_presets[s_preset_count].id, list, 36);
      s_presets[s_preset_count].id[36] = '\0';
      memcpy(s_presets[s_preset_count].name, tab + 1, end - tab - 1);
      s_presets[s_preset_count].name[end - tab - 1] = '\0';
      s_preset_count++;
    }
    list = *end ? end + 1 : end;
  }
  MenuIndex selection = menu_layer_get_selected_index(s_menu);
  if (selection.row >= row_count(s_menu, 0, NULL)) {
    menu_layer_set_selected_index(s_menu, MenuIndex(0, 2), MenuRowAlignCenter, false);
  }
  menu_layer_reload_data(s_menu);
}

static const char *message_string(DictionaryIterator *message, uint32_t key) {
  Tuple *value = dict_find(message, key);
  return value && value->type == TUPLE_CSTRING ? value->value->cstring : NULL;
}

static void show_reply(const char *reply) {
  snprintf(s_reply_text, sizeof(s_reply_text), "%s", reply);
  text_layer_set_text(s_reply, s_reply_text);
  const GRect screen = layer_get_bounds(window_get_root_layer(s_reply_window));
  const int16_t width = screen.size.w - 20;
  const GSize size = graphics_text_layout_get_content_size(s_reply_text,
    fonts_get_system_font(FONT_KEY_GOTHIC_24), GRect(0, 0, width, 6000),
    GTextOverflowModeWordWrap, GTextAlignmentLeft);
  text_layer_set_size(s_reply, GSize(width, size.h + 6));
  scroll_layer_set_content_size(s_scroll, GSize(screen.size.w, size.h + 22));
  scroll_layer_set_content_offset(s_scroll, GPointZero, false);
  if (!window_stack_contains_window(s_reply_window)) window_stack_push(s_reply_window, true);
}

static void receive(DictionaryIterator *message, void *context) {
  stop_wait();
  const char *status = message_string(message, MESSAGE_KEY_Status);
  if (status) set_status(status);
  const char *presets = message_string(message, MESSAGE_KEY_Presets);
  if (presets) {
    s_ready = status && (strcmp(status, "Ready") == 0 || strcmp(status, "Agent is working") == 0);
    load_presets(presets);
  }
  const char *reply = message_string(message, MESSAGE_KEY_Reply);
  if (reply && *reply) show_reply(reply);
}

static void inbox_dropped(AppMessageResult result, void *context) {
  stop_wait();
  set_status("Refresh to check reply");
}

static void outbox_failed(DictionaryIterator *message, AppMessageResult result, void *context) {
  stop_wait();
  set_status("Could not reach phone");
}

static void init(void) {
  s_window = window_create();
  Layer *root = window_get_root_layer(s_window);
  const GRect screen = layer_get_bounds(root);
  s_logo = gbitmap_create_with_resource(RESOURCE_ID_POCKETMAI_LOGO);
  s_logo_layer = bitmap_layer_create(GRect(7, 4, 40, 40));
  bitmap_layer_set_bitmap(s_logo_layer, s_logo);
  layer_add_child(root, bitmap_layer_get_layer(s_logo_layer));
  s_title = text_layer_create(GRect(53, 4, screen.size.w - 58, 40));
  text_layer_set_font(s_title, fonts_get_system_font(FONT_KEY_GOTHIC_28_BOLD));
  text_layer_set_text(s_title, "PocketMai");
  layer_add_child(root, text_layer_get_layer(s_title));

  s_menu = menu_layer_create(GRect(0, 48, screen.size.w, screen.size.h - 73));
  menu_layer_set_callbacks(s_menu, NULL, (MenuLayerCallbacks){
    .get_num_rows = row_count, .get_cell_height = row_height,
    .draw_row = draw_row, .select_click = select_row,
  });
  menu_layer_set_highlight_colors(s_menu, GColorOxfordBlue, GColorWhite);
  menu_layer_set_click_config_onto_window(s_menu, s_window);
  layer_add_child(root, menu_layer_get_layer(s_menu));
  s_status = text_layer_create(GRect(4, screen.size.h - 24, screen.size.w - 8, 24));
  text_layer_set_font(s_status, fonts_get_system_font(FONT_KEY_GOTHIC_18_BOLD));
  text_layer_set_text_alignment(s_status, GTextAlignmentCenter);
  layer_add_child(root, text_layer_get_layer(s_status));
  set_status("Connecting…");

  s_reply_window = window_create();
  Layer *reply_root = window_get_root_layer(s_reply_window);
  s_scroll = scroll_layer_create(layer_get_bounds(reply_root));
  scroll_layer_set_click_config_onto_window(s_scroll, s_reply_window);
  s_reply = text_layer_create(GRect(10, 8, screen.size.w - 20, screen.size.h));
  text_layer_set_font(s_reply, fonts_get_system_font(FONT_KEY_GOTHIC_24));
  text_layer_set_overflow_mode(s_reply, GTextOverflowModeWordWrap);
  scroll_layer_add_child(s_scroll, text_layer_get_layer(s_reply));
  layer_add_child(reply_root, scroll_layer_get_layer(s_scroll));

  app_message_register_inbox_received(receive);
  app_message_register_inbox_dropped(inbox_dropped);
  app_message_register_outbox_failed(outbox_failed);
  s_transport = app_message_open(2200, DICTATION_SIZE + 64) == APP_MSG_OK;
  if (s_transport) s_wait = app_timer_register(9000, timed_out, NULL);
  else set_status("Messaging unavailable");
  window_stack_push(s_window, true);
}

static void deinit(void) {
  stop_wait();
  app_message_deregister_callbacks();
  if (s_dictation) dictation_session_destroy(s_dictation);
  text_layer_destroy(s_reply);
  scroll_layer_destroy(s_scroll);
  window_destroy(s_reply_window);
  menu_layer_destroy(s_menu);
  text_layer_destroy(s_status);
  text_layer_destroy(s_title);
  bitmap_layer_destroy(s_logo_layer);
  gbitmap_destroy(s_logo);
  window_destroy(s_window);
}

int main(void) {
  init();
  app_event_loop();
  deinit();
}
