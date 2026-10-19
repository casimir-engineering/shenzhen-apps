/* Reaching and following mentions offscreen (szfriends_gtk_conversation_probe.h), wave 6c: a bubble's mentions by
 * keyboard (focus marks the first, Tab and the arrows step, Return and Space act, Tab past the last leaves); a
 * stranger's card that shows a name literally and follows new snapshots; and the history's refusal words while a
 * link or a folder hovers over it. */

#include "szfriends_gtk_conversation_probe.h"

#include <glib/gstdio.h>
#include <string.h>
#include <unistd.h>

static SZFriendsGtkConversation *state_of(SZFGConv *conv) {
    return szfriends_gtk_conversation_page_state(szfg_conv_page(conv));
}

static GtkWidget *card_of(SZFGConv *conv) {
    GtkWidget *popover = state_of(conv)->popover;
    return popover ? gtk_popover_get_child(GTK_POPOVER(popover)) : NULL;
}

/* The bubble's own key controller, as GTK runs it for a key press. */
static gboolean press(GtkWidget *label, guint keyval, GdkModifierType state) {
    GListModel *controllers = gtk_widget_observe_controllers(label);
    gboolean handled = FALSE;
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_KEY(controller) &&
            gtk_event_controller_get_propagation_phase(controller) == GTK_PHASE_CAPTURE)
            g_signal_emit_by_name(controller, "key-pressed", keyval, 0, state, &handled);
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    return handled;
}

static gboolean marked_underlined(GtkWidget *label, guint start, guint end) {
    gboolean found = FALSE;
    GSList *all = pango_attr_list_get_attributes(gtk_label_get_attributes(GTK_LABEL(label)));
    for (GSList *a = all; a; a = a->next) {
        PangoAttribute *attribute = a->data;
        found |= attribute->klass->type == PANGO_ATTR_UNDERLINE && attribute->start_index == start &&
                 attribute->end_index == end;
    }
    g_slist_free_full(all, (GDestroyNotify)pango_attribute_destroy);
    return found;
}

typedef struct {
    GtkWidget *label;
    gssize segment;
} SZFGMarkWait;

static gboolean marked(gpointer data) {
    SZFGMarkWait *wait = data;
    return szfriends_gtk_message_focused_segment(wait->label) == wait->segment;
}

static gboolean top_is_mei(gpointer data) {
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(((SZFGConv *)data)->dropdown);
    return page && g_strcmp0(szfriends_gtk_page_get_argument(page), "c_mei") == 0;
}

static void test_keyboard_path(SZFGHarness *harness) {
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    GtkWidget *label = szfg_find_label(szfg_conv_root(conv), "@Lena and @Jonas");
    EXPECT(label && gtk_widget_get_focusable(label), "a bubble with mentions takes focus");
    if (!label) goto done;
    /* Focus arriving as Tab brings it: GTK selects the words, and the first mention is marked in their place. An
     * unshown window is never active, so GTK tells no controller about focus moving: the probe does, as it does
     * for keys. */
    EXPECT(gtk_widget_grab_focus(label), "the words take focus");
    GListModel *controllers = gtk_widget_observe_controllers(label);
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_FOCUS(controller)) g_signal_emit_by_name(controller, "enter");
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    SZFGMarkWait wait = {label, 0};
    EXPECT(szfg_pump_until(marked, &wait, 2000), "focus from the keyboard marks the first mention");
    int start = 0, end = 0;
    EXPECT(!gtk_label_get_selection_bounds(GTK_LABEL(label), &start, &end) &&
               marked_underlined(label, 0, strlen("@Lena")), "the mark shows instead of the whole-text selection");
    EXPECT(press(label, GDK_KEY_Tab, 0) && szfriends_gtk_message_focused_segment(label) == 2 &&
               marked_underlined(label, strlen("@Lena and "), strlen("@Lena and @Jonas")),
           "Tab steps to the next mention, past the words between");
    EXPECT(press(label, GDK_KEY_Return, 0) && card_of(conv) && szfg_find_label(card_of(conv), "Blocked"),
           "Return opens the marked mention's card, as a click does");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(press(label, GDK_KEY_ISO_Left_Tab, GDK_SHIFT_MASK) && szfriends_gtk_message_focused_segment(label) == 0,
           "Shift+Tab steps back");
    EXPECT(press(label, GDK_KEY_space, 0) && card_of(conv) && szfg_find_label(card_of(conv), "Wants to be friends"),
           "Space acts too");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(press(label, GDK_KEY_Left, 0) && szfriends_gtk_message_focused_segment(label) == 0 &&
               press(label, GDK_KEY_Right, 0) && szfriends_gtk_message_focused_segment(label) == 2 &&
               press(label, GDK_KEY_Right, 0) && szfriends_gtk_message_focused_segment(label) == 2,
           "the arrows step and stay inside the bubble");
    EXPECT(!press(label, GDK_KEY_Tab, 0) && szfriends_gtk_message_focused_segment(label) == -1 &&
               !marked_underlined(label, strlen("@Lena and "), strlen("@Lena and @Jonas")),
           "Tab past the last mention leaves the bubble as Tab always does, and the mark goes");
    GtkWidget *plain = szfg_find_label(szfg_conv_root(conv), "Or ask @Kenji");
    EXPECT(plain && !press(plain, GDK_KEY_Return, 0), "words with nothing to open keep their keys");
    GtkWidget *mei = szfg_find_label(szfg_conv_root(conv), "@Mei Lin has");
    if (mei) szfriends_gtk_message_focus_changed(mei, TRUE);
    EXPECT(mei && press(mei, GDK_KEY_KP_Enter, 0) && szfg_pump_until(top_is_mei, conv, 3000),
           "Enter on a friend's mention opens your conversation with them");
done:
    szfg_conv_close(conv);
}

/* ---- A stranger's card follows its person ---------------------------------------------------------------- */

typedef void (*SZFGEdit)(JsonObject *mention, JsonObject *card);

/* The mentions fixture as c_daniel, with mention `index` of item `item_id` edited by `edit`. */
static char *daniel_with(const char *item_id, guint index, SZFGEdit edit) {
    JsonObject *frame = szfg_fixture("snapshots/conversation-daniel-mentions.json");
    JsonObject *data = json_object_get_object_member(frame, "data");
    JsonArray *items = json_object_get_array_member(data, "items");
    for (guint i = 0; i < json_array_get_length(items); i++) {
        JsonObject *item = json_array_get_object_element(items, i);
        if (g_strcmp0(json_object_get_string_member_with_default(item, "item_id", ""), item_id) != 0) continue;
        JsonObject *mention = json_array_get_object_element(json_object_get_array_member(item, "mentions"), index);
        edit(mention, json_object_get_object_member(mention, "card"));
    }
    JsonNode *root = json_node_init_object(json_node_alloc(), data);
    char *json = json_to_string(root, FALSE);
    json_node_unref(root);
    json_object_unref(frame);
    return json;
}

static void hidden_space(JsonObject *mention, JsonObject *card) {
    (void)mention;
    json_object_set_string_member(card, "title", "Leo\xE2\x80\x8B\xE2\x80\x8BPark");
}

static void request_sent(JsonObject *mention, JsonObject *card) {
    hidden_space(mention, card);
    json_object_set_string_member(card, "status_label", "Request sent");
    json_object_set_array_member(card, "actions", json_array_new());
}

static void now_a_friend(JsonObject *mention, JsonObject *card) {
    (void)card;
    json_object_set_string_member(mention, "kind", "friend");
    json_object_set_string_member(mention, "conversation_id", "c_mei");
    json_object_set_null_member(mention, "card");
}

static void still_waiting(JsonObject *mention, JsonObject *card) {
    (void)mention;
    json_object_set_string_member(card, "status_label", "Still wants to be friends");
}

static void push(SZFGHarness *harness, const char *item_id, guint index, SZFGEdit edit) {
    char *json = daniel_with(item_id, index, edit);
    szfriends_fake_helper_set_view_data(harness->fake, "conversation", json);
    g_free(json);
}

typedef struct {
    SZFGConv *conv;
    const char *text;
} SZFGCardWait;

static gboolean card_says(gpointer data) {
    SZFGCardWait *wait = data;
    GtkWidget *card = card_of(wait->conv);
    GtkWidget *label = card ? szfg_find_label(card, wait->text) : NULL;
    return label && gtk_widget_get_visible(label);
}

static gboolean card_closed(gpointer data) {
    return card_of(data) == NULL;
}

static const SZFriendsGtkConversationItem *item_of(SZFGConv *conv, const char *item_id) {
    GListModel *model = szfriends_gtk_history_model(szfriends_gtk_conversation_page_history(szfg_conv_page(conv)));
    const SZFriendsGtkConversationItem *item = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(model) && !item; i++) {
        GObject *holder = g_list_model_get_item(model, i);
        const SZFriendsGtkConversationItem *candidate = szfriends_gtk_history_item(holder);
        if (candidate && strcmp(candidate->item_id, item_id) == 0) item = candidate;
        g_object_unref(holder);
    }
    return item;
}

static void click(SZFGConv *conv, const char *prefix, const char *item_id, gsize segment) {
    GtkWidget *label = szfg_find_label(szfg_conv_root(conv), prefix);
    const SZFriendsGtkConversationItem *item = item_of(conv, item_id);
    EXPECT(label && item && szfriends_gtk_message_activate(state_of(conv), item, segment, label) ==
                                SZFRIENDS_GTK_HIT_CARD, "the card of \"%s\" opens", prefix);
}

static void test_card_follows(SZFGHarness *harness) {
    push(harness, "m_d0a2", 0, hidden_space);
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    click(conv, "@Leo Park can review", "m_d0a2", 0);
    GtkWidget *card = card_of(conv), *popover = state_of(conv)->popover;
    GtkWidget *title = card ? gtk_widget_get_first_child(card) : NULL;
    EXPECT(title && strcmp(gtk_label_get_text(GTK_LABEL(title)), "Leo U+200B ×2 Park") == 0 &&
               !gtk_label_get_use_markup(GTK_LABEL(title)),
           "the name the sender wrote shows literally, its hidden characters as code points: \"%s\"",
           title ? gtk_label_get_text(GTK_LABEL(title)) : "");
    EXPECT(szfg_find_button(card, "Add") != NULL, "someone with nothing between you: Add");
    const SZFriendsGtkConversationItem *leo = item_of(conv, "m_d0a2");
    for (int dark = 0; leo && dark < 2; dark++) {
        szfg_set_dark(dark);
        GtkWidget *frame = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        /* Drawn inside the page, so the marks take the page's warning colour, then lifted out to render. */
        GtkWidget *copy = szfriends_gtk_mention_card_new(state_of(conv), leo, &leo->mentions[0]);
        gtk_widget_set_margin_top(copy, 10), gtk_widget_set_margin_bottom(copy, 10);
        gtk_widget_set_margin_start(copy, 10), gtk_widget_set_margin_end(copy, 10);
        gtk_box_append(GTK_BOX(frame), copy);
        szfg_conv_render_widget(frame, 284, dark ? "mention-card-literal-dark" : "mention-card-literal-light");
    }
    szfg_set_dark(FALSE);
    push(harness, "m_d0a2", 0, request_sent);
    SZFGCardWait wait = {conv, "Request sent"};
    EXPECT(szfg_pump_until(card_says, &wait, 3000) && state_of(conv)->popover == popover &&
               !szfg_find_button(card_of(conv), "Add"),
           "a new snapshot updates the open card in place: Request sent, and no Add");
    push(harness, "m_d0a2", 0, now_a_friend);
    EXPECT(szfg_pump_until(card_closed, conv, 3000), "once the mention names a friend, the card has nothing to say");

    click(conv, "@Lena and @Jonas", "m_d0a3", 0);
    GtkWidget *block = szfg_find_button(card_of(conv), "Block Lena");
    if (block) g_signal_emit_by_name(block, "clicked");
    EXPECT(block && szfriends_gtk_action_button_is_armed(block), "Block on Lena's card arms");
    push(harness, "m_d0a3", 0, still_waiting);
    wait = (SZFGCardWait){conv, "Still wants to be friends"};
    EXPECT(szfg_pump_until(card_says, &wait, 3000) && szfg_find_button(card_of(conv), "Block?") == block &&
               szfriends_gtk_action_button_is_armed(block),
           "a snapshot that changed something else keeps the armed Block? as it was");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    szfriends_gtk_dropdown_escape(conv->dropdown);
    szfg_conv_close(conv);
}

/* ---- The history's words while files hover --------------------------------------------------------------- */

static void test_drop_words(SZFGHarness *harness) {
    char *file = g_build_filename(harness->state, "Plan.pdf", NULL);
    char *link = g_build_filename(harness->state, "Plan link.pdf", NULL);
    char *folder = g_build_filename(harness->state, "Site visit", NULL);
    g_file_set_contents(file, "%PDF-1.4\n", -1, NULL);
    EXPECT(symlink(file, link) == 0 && g_mkdir(folder, 0700) == 0, "a link and a folder to drag");
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    SZFriendsGtkHistory *history = szfriends_gtk_conversation_page_history(szfg_conv_page(conv));
    GtkWidget *mark = NULL;
    for (GtkWidget *child = gtk_widget_get_first_child(szfriends_gtk_history_widget(history)); child;
         child = gtk_widget_get_next_sibling(child))
        if (gtk_widget_has_css_class(child, "szfriends-history-drop")) mark = child;
    struct {
        const char *path, *key, *what;
    } drags[] = {{link, "drop_not_a_file", "a link"}, {folder, "drop_folders_refused", "a folder"}};
    for (gsize i = 0; i < G_N_ELEMENTS(drags); i++) {
        GValue *value = szfg_files_value((const char *[]){drags[i].path, NULL});
        szfriends_gtk_history_drag_value(history, value);
        const char *words = szfriends_gtk_link_string(harness->link, drags[i].key);
        GtkWidget *said = mark ? gtk_widget_get_first_child(mark) : NULL;
        EXPECT(said && gtk_widget_get_visible(mark) && gtk_widget_has_css_class(mark, "szfriends-refuse") && *words &&
                   gtk_widget_get_visible(said) && strcmp(gtk_label_get_text(GTK_LABEL(said)), words) == 0,
               "%s over the history is refused in the helper's words: \"%s\"", drags[i].what,
               said ? gtk_label_get_text(GTK_LABEL(said)) : "");
        if (i == 0) szfg_conv_render(conv, "history-drop-link-light");
        EXPECT(!szfriends_gtk_history_drop(history, value) && !gtk_widget_get_visible(mark),
               "%s sends nothing, and the words go with the drag", drags[i].what);
        szfg_value_free(value);
    }
    szfg_conv_close(conv);
    g_unlink(link);
    g_unlink(file);
    g_rmdir(folder);
    g_free(link);
    g_free(file);
    g_free(folder);
}

void szfg_run_conversation_card_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conv-cards", NULL);
    test_keyboard_path(harness);
    test_card_follows(harness);
    test_drop_words(harness);
    szfg_harness_free(harness);
}
