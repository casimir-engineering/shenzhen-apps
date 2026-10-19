/* The composer offscreen (szfriends_gtk_conversation_probe.h): `@` opens the friends who may be mentioned from a
 * second list subscription filtered as the person types, a chip goes out as U+FFFC with its friend in `mentions`,
 * Return sends and Shift+Return or an input method's Return does not, `#` attaches the host's items, drops on the
 * composer become chips and drops on the history are sent at once, the draft survives leaving the page, and a helper
 * without `mentions` gets no `@`. */

#include "szfriends_gtk_conversation_probe.h"

#include <glib/gstdio.h>
#include <string.h>

static SZFriendsGtkComposerView *composer_of(SZFGConv *conv) {
    return szfriends_gtk_conversation_page_state(szfg_conv_page(conv))->composer;
}

static GtkTextBuffer *buffer_of(SZFGConv *conv) {
    return gtk_text_view_get_buffer(GTK_TEXT_VIEW(szfriends_gtk_composer_get_text_view(composer_of(conv))));
}

static void type(SZFGConv *conv, const char *text) {
    /* One character at a time, as typing inserts them. */
    for (const char *p = text; *p; p = g_utf8_next_char(p))
        gtk_text_buffer_insert_at_cursor(buffer_of(conv), p, (int)(g_utf8_next_char(p) - p));
}

static gboolean picker_shows_rows(gpointer data) {
    GtkWidget *picker = szfriends_gtk_composer_get_picker(composer_of(data));
    return picker && szfriends_gtk_picker_row_count(picker) > 0;
}

/* The text view's own key handler, as GTK runs it for a key press. */
static gboolean press_return(SZFGConv *conv, GdkModifierType state) {
    GtkWidget *view = szfriends_gtk_composer_get_text_view(composer_of(conv));
    GListModel *controllers = gtk_widget_observe_controllers(view);
    gboolean handled = FALSE;
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_KEY(controller) &&
            gtk_event_controller_get_propagation_phase(controller) == GTK_PHASE_CAPTURE)
            g_signal_emit_by_name(controller, "key-pressed", GDK_KEY_Return, 36, state, &handled);
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    return handled;
}

static char *mentionable_list(void) {
    JsonObject *frame = szfg_fixture("snapshots/list.json");
    JsonObject *data = json_object_get_object_member(frame, "data");
    JsonArray *rows = json_object_get_array_member(data, "rows");
    /* Friends with a Friends ID may be mentioned; a request or someone blocked may not. */
    for (guint i = 0; i < json_array_get_length(rows); i++) {
        JsonObject *row = json_array_get_object_element(rows, i);
        const char *id = json_object_get_string_member(row, "conversation_id");
        gboolean friend = !strcmp(id, "c_mei") || !strcmp(id, "c_kenji") || !strcmp(id, "c_priya");
        json_object_set_boolean_member(row, "mentionable", friend);
    }
    JsonNode *root = json_node_init_object(json_node_alloc(), data);
    char *json = json_to_string(root, FALSE);
    json_node_unref(root);
    json_object_unref(frame);
    return json;
}

static void test_mentioning_and_sending(SZFGHarness *harness) {
    char *list = mentionable_list();
    szfriends_fake_helper_set_view_data(harness->fake, "list", list);
    g_free(list);
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    SZFriendsGtkComposerView *composer = composer_of(conv);
    guint lists = szfg_fake_frames(harness, "subscribe", "view", "list");
    type(conv, "Ask @");
    EXPECT(szfg_pump_until(picker_shows_rows, conv, 3000), "@ opens the friends who may be mentioned");
    GtkWidget *picker = szfriends_gtk_composer_get_picker(composer);
    EXPECT(szfg_fake_frames(harness, "subscribe", "view", "list") == lists + 1, "from a second list subscription");
    EXPECT(picker && szfriends_gtk_picker_row_count(picker) == 3, "only the rows whose mentionable is true (%u)",
           picker ? szfriends_gtk_picker_row_count(picker) : 0);
    EXPECT(szfg_find_label(picker, "Daniel can click the name"), "with the composer's mention_note under them");
    guint filters = szfg_fake_frames(harness, "set_filter", NULL, NULL);
    GtkWidget *entry = picker ? gtk_widget_get_first_child(picker) : NULL;
    if (GTK_IS_EDITABLE(entry)) gtk_editable_set_text(GTK_EDITABLE(entry), "pri");
    EXPECT(szfg_conv_wait_frames(harness, "set_filter", filters), "typing filters that subscription");
    JsonObject *frame = szfg_fake_last_frame(harness, "set_filter");
    EXPECT(frame && strcmp(json_object_get_string_member(frame, "query"), "pri") == 0, "with what was typed");
    if (frame) json_object_unref(frame);
    szfg_conv_layout(conv);
    szfg_conv_render(conv, "composer-mention-picker-light");
    szfriends_gtk_picker_key(picker, GDK_KEY_Down);
    szfriends_gtk_picker_key(picker, GDK_KEY_Down);
    szfriends_gtk_picker_key(picker, GDK_KEY_Return); /* the third: Priya, in the list's order */
    EXPECT(!szfriends_gtk_composer_get_picker(composer) && szfriends_gtk_composer_mention_count(composer) == 1,
           "choosing one closes the picker and puts a chip in the text");
    guint unsubscribed = szfg_fake_frames(harness, "unsubscribe", NULL, NULL);
    EXPECT(unsubscribed > 0, "the picker's subscription goes with it");
    type(conv, "about it");
    guint sends = szfg_fake_frames(harness, "send_message", NULL, NULL);
    EXPECT(!press_return(conv, GDK_SHIFT_MASK), "Shift+Return is the text view's: a new line");
    g_signal_emit_by_name(szfriends_gtk_composer_get_text_view(composer), "preedit-changed", "ni");
    EXPECT(!press_return(conv, 0), "Return while an input method composes is the input method's");
    g_signal_emit_by_name(szfriends_gtk_composer_get_text_view(composer), "preedit-changed", "");
    szfg_pump_for(50);
    EXPECT(szfg_fake_frames(harness, "send_message", NULL, NULL) == sends, "neither sends");
    EXPECT(press_return(conv, 0) && szfg_conv_wait_frames(harness, "send_message", sends), "Return sends");
    frame = szfg_fake_last_frame(harness, "send_message");
    JsonArray *mentions = frame ? json_object_get_array_member(frame, "mentions") : NULL;
    EXPECT(frame && strcmp(json_object_get_string_member(frame, "text"), "Ask \xEF\xBF\xBC about it") == 0 &&
               mentions && json_array_get_length(mentions) == 1 &&
               strcmp(json_object_get_string_member(json_array_get_object_element(mentions, 0), "conversation_id"),
                      "c_priya") == 0,
           "the chip goes out as U+FFFC with its friend in mentions: %s",
           frame ? json_object_get_string_member(frame, "text") : "(none)");
    if (frame) json_object_unref(frame);
    szfg_pump_for(200);
    EXPECT(gtk_text_buffer_get_char_count(buffer_of(conv)) == 0, "the reply clears the composer");
    szfg_conv_close(conv);
}

static void test_attaching_and_drafts(SZFGHarness *harness, const char *file, const char *folder) {
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    SZFriendsGtkComposerView *composer = composer_of(conv);
    type(conv, "Plan #");
    EXPECT(szfg_pump_until(picker_shows_rows, conv, 3000), "# opens the host's items");
    GtkWidget *picker = szfriends_gtk_composer_get_picker(composer);
    EXPECT(picker && szfriends_gtk_picker_row_count(picker) == 3, "all of them for nothing typed");
    GtkWidget *entry = gtk_widget_get_first_child(picker);
    gtk_editable_set_text(GTK_EDITABLE(entry), "pricing");
    szfg_pump_for(300);
    EXPECT(szfriends_gtk_picker_row_count(picker) == 1, "what is typed narrows them");
    EXPECT(szfg_find_label(picker, "Attaching sends nothing yet"), "the picker says attaching sends nothing");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(!szfriends_gtk_composer_get_picker(composer) && szfriends_gtk_dropdown_is_open(conv->dropdown),
           "Escape closes the picker, and only the picker");
    type(conv, "#");
    EXPECT(szfg_pump_until(picker_shows_rows, conv, 3000), "# opens it again");
    picker = szfriends_gtk_composer_get_picker(composer);
    gtk_editable_set_text(GTK_EDITABLE(gtk_widget_get_first_child(picker)), "pricing");
    szfg_pump_for(300);
    szfriends_gtk_picker_key(picker, GDK_KEY_Return);
    GtkWidget *chips = szfriends_gtk_composer_get_chips(composer);
    EXPECT(!szfriends_gtk_composer_get_picker(composer) && szfg_count_type(chips, GTK_TYPE_BUTTON) == 1,
           "choosing one adds a chip");
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer_of(conv), &start, &end);
    char *text = gtk_text_buffer_get_text(buffer_of(conv), &start, &end, FALSE);
    EXPECT(strcmp(text, "Plan #") == 0, "and the # typed to open the picker goes: \"%s\"", text);
    g_free(text);

    GValue *files = szfg_files_value((const char *[]){file, NULL});
    GValue *folders = szfg_files_value((const char *[]){folder, NULL});
    szfriends_gtk_composer_drag_value(composer, folders);
    GtkWidget *error = szfriends_gtk_composer_get_error_label(composer);
    EXPECT(gtk_widget_get_visible(error) && strcmp(gtk_label_get_text(GTK_LABEL(error)),
                                                   "Folders can’t be sent yet") == 0,
           "a folder over the composer is refused in the helper's words");
    EXPECT(!szfriends_gtk_composer_drop(composer, folders) && szfg_count_type(chips, GTK_TYPE_BUTTON) == 1,
           "and dropping it adds nothing");
    EXPECT(!gtk_widget_get_visible(error), "the refusal goes with the drag");
    szfriends_gtk_composer_drag_value(composer, files);
    EXPECT(szfriends_gtk_composer_drop(composer, files) && szfg_count_type(chips, GTK_TYPE_BUTTON) == 2,
           "a file dropped on the composer becomes a chip, sent with the next Send");
    SZFriendsGtkHistory *history = szfriends_gtk_conversation_page_history(szfg_conv_page(conv));
    guint offers = szfg_fake_frames(harness, "send_files", NULL, NULL);
    szfriends_gtk_history_drag_value(history, files);
    EXPECT(szfriends_gtk_history_drop(history, files) && szfg_conv_wait_frames(harness, "send_files", offers),
           "a file dropped on the history is sent at once");
    JsonObject *frame = szfg_fake_last_frame(harness, "send_files");
    JsonArray *sent = frame ? json_object_get_array_member(frame, "files") : NULL;
    EXPECT(frame && strcmp(json_object_get_string_member(frame, "conversation_id"), "c_daniel") == 0 && sent &&
               strcmp(json_object_get_string_member(json_array_get_object_element(sent, 0), "path"), file) == 0,
           "to this conversation, one offer per file");
    if (frame) json_object_unref(frame);
    EXPECT(!szfriends_gtk_history_drop(history, folders), "a folder dropped on the history sends nothing");
    szfg_value_free(files);
    szfg_value_free(folders);
    type(conv, "@");
    EXPECT(szfg_pump_until(picker_shows_rows, conv, 3000), "the @ picker");
    szfriends_gtk_picker_key(szfriends_gtk_composer_get_picker(composer), GDK_KEY_Return);
    type(conv, "has it");
    szfg_conv_layout(conv);
    szfg_conv_render(conv, "composer-chips-light");

    /* Leaving the page and coming back: the words, the chip and the attachments are where they were. */
    szfriends_gtk_dropdown_go_back(conv->dropdown);
    szfriends_gtk_dropdown_open_conversation(conv->dropdown, "c_daniel", NULL);
    szfg_pump_for(200);
    composer = composer_of(conv);
    gtk_text_buffer_get_bounds(buffer_of(conv), &start, &end);
    text = gtk_text_buffer_get_slice(buffer_of(conv), &start, &end, TRUE);
    EXPECT(composer && strcmp(text, "Plan #\xEF\xBF\xBC has it") == 0 &&
               szfriends_gtk_composer_mention_count(composer) == 1 &&
               szfg_count_type(szfriends_gtk_composer_get_chips(composer), GTK_TYPE_BUTTON) == 2,
           "the draft comes back with its chips: \"%s\"", text);
    g_free(text);
    szfg_conv_close(conv);
}

/* A helper that predates mentions and messages.cancel: no `@`, and no Cancel on queued messages. */
static void test_older_helper(void) {
    SZFGHarness *harness = szfg_conv_harness("conv-old", "[\"nearby.network\",\"nearby.bluetooth\"]");
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    guint lists = szfg_fake_frames(harness, "subscribe", "view", "list");
    type(conv, "Ask @");
    szfg_pump_for(150);
    EXPECT(!szfriends_gtk_composer_get_picker(composer_of(conv)) &&
               szfg_fake_frames(harness, "subscribe", "view", "list") == lists,
           "no @ picker: an older helper would send each U+FFFC as it is");
    szfg_conv_close(conv);
    conv = szfg_conv_open(harness, "c_priya");
    guint cancels = szfg_count_buttons(szfg_conv_root(conv), "Cancel");
    EXPECT(cancels == 1 && szfg_find_label(szfg_conv_root(conv), "Sends when Priya is nearby"),
           "the queued file keeps its Cancel; the queued messages offer none (%u)", cancels);
    szfg_conv_close(conv);
    szfg_harness_free(harness);
}

void szfg_run_conversation_composer_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conv-composer", NULL);
    char *file = g_build_filename(harness->state, "Site photos.pdf", NULL);
    char *folder = g_build_filename(harness->state, "Site visit", NULL);
    g_file_set_contents(file, "%PDF-1.4\n", -1, NULL);
    g_mkdir(folder, 0700);
    test_mentioning_and_sending(harness);
    test_attaching_and_drafts(harness, file, folder);
    g_free(file);
    g_free(folder);
    szfg_harness_free(harness);
    test_older_helper();
}
