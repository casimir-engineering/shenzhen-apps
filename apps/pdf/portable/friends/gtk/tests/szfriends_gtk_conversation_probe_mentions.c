/* Mentions and links in a conversation, offscreen (szfriends_gtk_conversation_probe.h): every mention kind drawn and
 * clicked through its label (a friend's opens their conversation, the reader's own does nothing, a stranger's shows
 * the card, whose Add sends add_from_mention with the card's own fields and whose Block arms first), and links that
 * open only through the menu that says where they go. */

#include "szfriends_gtk_conversation_probe.h"

#include "gtk/szfriends_gtk_row.h"

#include <string.h>

static const SZFriendsGtkConversationItem *item_of(SZFGConv *conv, const char *item_id) {
    GListModel *model = szfriends_gtk_history_model(szfriends_gtk_conversation_page_history(szfg_conv_page(conv)));
    for (guint i = 0; i < g_list_model_get_n_items(model); i++) {
        GObject *holder = g_list_model_get_item(model, i);
        const SZFriendsGtkConversationItem *item = szfriends_gtk_history_item(holder);
        g_object_unref(holder);
        if (item && strcmp(item->item_id, item_id) == 0) return item;
    }
    return NULL;
}

/* A click on a card's button as GTK delivers one: the press with its count, then GtkButton's clicked. */
static void press(GtkWidget *button, int n_press) {
    if (!button) return;
    GListModel *controllers = gtk_widget_observe_controllers(button);
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_GESTURE_CLICK(controller) &&
            gtk_event_controller_get_propagation_phase(controller) == GTK_PHASE_CAPTURE)
            g_signal_emit_by_name(controller, "pressed", n_press, 4.0, 4.0);
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    g_signal_emit_by_name(button, "clicked");
}

/* Where a segment starts inside its label, in the label's coordinates, a little inside the first character. */
static gboolean segment_point(GtkWidget *label, guint byte, double *x, double *y) {
    PangoRectangle position;
    int ox = 0, oy = 0;
    pango_layout_index_to_pos(gtk_label_get_layout(GTK_LABEL(label)), (int)byte, &position);
    gtk_label_get_layout_offsets(GTK_LABEL(label), &ox, &oy);
    *x = ox + PANGO_PIXELS(position.x) + 2;
    *y = oy + PANGO_PIXELS(position.y) + PANGO_PIXELS(position.height) / 2.0;
    return position.height > 0;
}

static SZFriendsGtkHitKind click(SZFGConv *conv, const char *prefix, const char *item_id, gsize segment) {
    GtkWidget *label = szfg_find_label(szfg_conv_root(conv), prefix);
    const SZFriendsGtkConversationItem *item = item_of(conv, item_id);
    EXPECT(label && item, "the bubble starting \"%s\" is drawn", prefix);
    if (!label || !item) return SZFRIENDS_GTK_HIT_NONE;
    return szfriends_gtk_message_activate(szfriends_gtk_conversation_page_state(szfg_conv_page(conv)), item, segment,
                                          label);
}

static GtkWidget *open_popover(SZFGConv *conv) {
    return szfriends_gtk_conversation_page_state(szfg_conv_page(conv))->popover;
}

typedef struct {
    GtkWidget *label;
    const char *text;
} SZFGLabelWait;

static gboolean label_says(gpointer data) {
    SZFGLabelWait *wait = data;
    return gtk_widget_get_visible(wait->label) && g_str_has_prefix(gtk_label_get_text(GTK_LABEL(wait->label)),
                                                                     wait->text);
}

static gboolean top_is(gpointer data) {
    SZFGConv *conv = data;
    SZFriendsGtkPage *page = szfg_conv_page(conv);
    return page && g_strcmp0(szfriends_gtk_page_get_argument(page), "c_mei") == 0;
}

static void test_clicks_on_words(SZFGHarness *harness) {
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    szfg_conv_render(conv, "conversation-daniel-mentions-light");
    GtkWidget *leo = szfg_find_label(szfg_conv_root(conv), "@Leo Park can review");
    double x = 0, y = 0;
    EXPECT(leo && segment_point(leo, 0, &x, &y) && szfriends_gtk_message_segment_at(leo, x, y) == 0,
           "a point on \"@Leo Park\" is the mention's segment");
    EXPECT(leo && segment_point(leo, 12, &x, &y) && szfriends_gtk_message_segment_at(leo, x, y) == 1,
           "a point on the words after it is the next segment");
    EXPECT(leo && szfriends_gtk_message_segment_at(leo, -50, -50) == -1, "outside the words: no segment");
    PangoAttrList *attributes = leo ? gtk_label_get_attributes(GTK_LABEL(leo)) : NULL;
    gboolean coloured = FALSE;
    GSList *all = attributes ? pango_attr_list_get_attributes(attributes) : NULL;
    for (GSList *a = all; a; a = a->next) {
        PangoAttribute *attribute = a->data;
        coloured |= attribute->klass->type == PANGO_ATTR_FOREGROUND && attribute->start_index == 0 &&
                    attribute->end_index == strlen("@Leo Park");
    }
    g_slist_free_full(all, (GDestroyNotify)pango_attribute_destroy);
    EXPECT(coloured, "the stranger's mention is drawn as a link, in the accent colour");

    guint popups = szfg_conv_records.popovers->len;
    EXPECT(click(conv, "@Leo Park can review", "m_d0a2", 2) == SZFRIENDS_GTK_HIT_NONE &&
               szfg_conv_records.popovers->len == popups && !open_popover(conv),
           "the reader's own mention does nothing");
    EXPECT(click(conv, "@Leo Park can review", "m_d0a2", 0) == SZFRIENDS_GTK_HIT_CARD && open_popover(conv) &&
               szfg_conv_records.popovers->len == popups + 1, "a stranger's mention shows their card");
    GtkWidget *card = open_popover(conv);
    EXPECT(szfg_find_label(card, "Leo Park") && szfg_find_label(card, "Friends ID bonfire‑otter"),
           "the card names the person as the sender wrote them, and their ID");
    guint before = szfg_fake_frames(harness, "add_from_mention", NULL, NULL);
    GtkWidget *add = szfg_find_button(card, "Add");
    if (add) g_signal_emit_by_name(add, "clicked");
    EXPECT(add && szfg_conv_wait_frames(harness, "add_from_mention", before), "Add sends add_from_mention");
    JsonObject *frame = szfg_fake_last_frame(harness, "add_from_mention");
    EXPECT(frame && strcmp(json_object_get_string_member(frame, "friends_id"), "bonfire-otter") == 0 &&
               strcmp(json_object_get_string_member(frame, "identity_key"),
                      "tN1JdICMMlIsgspydMWcnrWDAec9jXbspfRfygj7Q6o") == 0 &&
               strcmp(json_object_get_string_member(frame, "name"), "Leo Park") == 0,
           "with the card's own three fields, as they are");
    if (frame) json_object_unref(frame);
    /* The card's last line, under its buttons, is where it says what happens next (as AppKit's result line). */
    GtkWidget *box = gtk_popover_get_child(GTK_POPOVER(card));
    SZFGLabelWait said = {box ? gtk_widget_get_last_child(box) : NULL, "Request sent to Leo Park"};
    EXPECT(said.label && szfg_pump_until(label_says, &said, 3000), "the card then says what happens next");
    EXPECT(box && !gtk_widget_get_visible(gtk_widget_get_prev_sibling(said.label)), "and its Add is spent");

    /* A card closed before its reply arrives: the reply finds no card and changes nothing. */
    EXPECT(click(conv, "@Leo Park can review", "m_d0a2", 0) == SZFRIENDS_GTK_HIT_CARD, "Leo's card again");
    before = szfg_fake_frames(harness, "add_from_mention", NULL, NULL);
    add = szfg_find_button(open_popover(conv), "Add");
    if (add) g_signal_emit_by_name(add, "clicked");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(!open_popover(conv) && szfg_conv_wait_frames(harness, "add_from_mention", before),
           "Add went, and the card closed before its reply");
    szfg_pump_for(200);
    EXPECT(click(conv, "@Lena and @Jonas", "m_d0a3", 0) == SZFRIENDS_GTK_HIT_CARD, "Lena's card");
    card = open_popover(conv);
    GtkWidget *block = szfg_find_button(card, "Block Lena");
    EXPECT(szfg_find_button(card, "Accept") && szfg_find_button(card, "Decline") && block,
           "someone who asked: Accept, Decline and Block, as in the list");
    before = szfg_fake_frames(harness, "block", NULL, NULL);
    press(block, 1);
    EXPECT(block && szfriends_gtk_action_button_is_armed(block) &&
               g_strcmp0(gtk_button_get_label(GTK_BUTTON(block)), "Block?") == 0 && szfg_clock_live(4000) == 1,
           "Block arms first and says Block?, for the snapshot's 4 seconds");
    press(block, 2);
    szfg_pump_for(50);
    EXPECT(block && szfriends_gtk_action_button_is_armed(block) &&
               szfg_fake_frames(harness, "block", NULL, NULL) == before, "a double-click's second half sends nothing");
    gint64 double_click_ms = block ? szfriends_gtk_double_click_us(block) / 1000 : 400;
    szfg_clock_advance_ms(double_click_ms - 1);
    press(block, 1);
    szfg_pump_for(50);
    EXPECT(block && szfriends_gtk_action_button_is_armed(block) &&
               szfg_fake_frames(harness, "block", NULL, NULL) == before,
           "a single click within the double-click time of arming is half a double-click: still armed, nothing sent");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(open_popover(conv) && block && !szfriends_gtk_action_button_is_armed(block) &&
               szfriends_gtk_dropdown_is_open(conv->dropdown) && szfg_clock_live(4000) == 0,
           "Escape turns the pill back first, and its timer with it");
    press(block, 1);
    EXPECT(szfg_clock_fire(4000) && block && !szfriends_gtk_action_button_is_armed(block) &&
               g_strcmp0(gtk_button_get_label(GTK_BUTTON(block)), "Block Lena") == 0,
           "unconfirmed, the pill turns back by itself after arm.seconds");
    press(block, 1);
    szfg_clock_advance_ms(double_click_ms + 1); /* past the double-click time: a deliberate second click */
    press(block, 1);
    EXPECT(szfg_conv_wait_frames(harness, "block", before), "a separate second click blocks Lena");
    frame = szfg_fake_last_frame(harness, "block");
    EXPECT(frame && !g_strcmp0(json_object_get_string_member_with_default(frame, "conversation_id", NULL), "c_lena"),
           "and only Lena");
    if (frame) json_object_unref(frame);
    szfg_pump_for(50);
    if (open_popover(conv)) szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(!open_popover(conv) && szfriends_gtk_dropdown_is_open(conv->dropdown), "then the card is closed");
    EXPECT(click(conv, "@Lena and @Jonas", "m_d0a3", 2) == SZFRIENDS_GTK_HIT_CARD, "Jonas's card");
    card = open_popover(conv);
    EXPECT(szfg_find_label(card, "Blocked") && szfg_count_type(card, GTK_TYPE_BUTTON) == 0,
           "someone blocked: Blocked, and nothing to press");
    EXPECT(click(conv, "Or ask @Kenji", "m_d0a4", 0) == SZFRIENDS_GTK_HIT_NONE, "@Name as plain text");
    EXPECT(click(conv, "@Mei Lin has", "m_d0a1", 0) == SZFRIENDS_GTK_HIT_FRIEND, "a friend's mention");
    EXPECT(szfg_pump_until(top_is, conv, 3000), "opens your conversation with them");
    szfg_conv_close(conv);
}

static void render_cards(SZFGHarness *harness, const char *theme) {
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    char *name = g_strdup_printf("conversation-daniel-mentions-%s", theme);
    if (strcmp(theme, "dark") == 0) szfg_conv_render(conv, name);
    g_free(name);
    SZFriendsGtkConversation *state = szfriends_gtk_conversation_page_state(szfg_conv_page(conv));
    const char *items[] = {"m_d0a2", "m_d0a3", "m_d0a3"}, *names[] = {"leo-add", "lena-request", "jonas-blocked"};
    gsize mentions[] = {0, 0, 1};
    for (gsize i = 0; i < G_N_ELEMENTS(items); i++) {
        const SZFriendsGtkConversationItem *item = item_of(conv, items[i]);
        if (!item || item->n_mentions <= mentions[i]) continue;
        char *file = g_strdup_printf("mention-card-%s-%s", names[i], theme);
        /* With the room a popover gives its content around it. */
        GtkWidget *frame = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        GtkWidget *card = szfriends_gtk_mention_card_new(state, item, &item->mentions[mentions[i]]);
        gtk_widget_set_margin_top(card, 10), gtk_widget_set_margin_bottom(card, 10);
        gtk_widget_set_margin_start(card, 10), gtk_widget_set_margin_end(card, 10);
        gtk_box_append(GTK_BOX(frame), card);
        szfg_conv_render_widget(frame, 284, file);
        g_free(file);
    }
    szfg_conv_close(conv);
}

/* ---- Links ------------------------------------------------------------------------------------------------- */

static char *links_conversation(void) {
    JsonObject *frame = szfg_fixture("snapshots/conversation-daniel-mentions.json");
    JsonObject *data = json_object_get_object_member(frame, "data");
    json_object_set_string_member(data, "conversation_id", "c_links");
    GString *long_text = g_string_new(NULL);
    while (long_text->len < 6000) g_string_append(long_text, "The bracket moved four millimetres. ");
    char *items = g_strdup_printf(
        "[{\"kind\":\"message\",\"item_id\":\"m_l1\",\"direction\":\"in\",\"text\":\"See www.apple.com\","
        "\"text_format\":\"markdown\",\"segments\":[{\"text\":\"See \"},{\"text\":\"www.apple.com\",\"url\":"
        "\"https://appleid-verify.example.net/login\"},{\"text\":\", \"},{\"text\":\"write\",\"url\":"
        "\"mailto:mei@example.com\"},{\"text\":\" or \"},{\"text\":\"hosts\",\"url\":\"file:///etc/hosts\"}],"
        "\"time_label\":\"10:40\",\"status\":null,\"assistant_label\":null,\"actions\":[],\"highlighted\":false,"
        "\"accessibility_label\":\"Daniel Ortiz, 10:40\"},{\"kind\":\"message\",\"item_id\":\"m_l2\",\"direction\":"
        "\"in\",\"text\":\"%s\",\"text_format\":\"markdown\",\"segments\":[{\"text\":\"%s\"}],\"time_label\":null,"
        "\"status\":null,\"assistant_label\":null,\"actions\":[],\"highlighted\":false,\"accessibility_label\":"
        "\"Daniel Ortiz, 10:41\"}]", long_text->str, long_text->str);
    JsonNode *parsed = json_from_string(items, NULL);
    json_object_set_member(data, "items", parsed);
    JsonNode *root = json_node_init_object(json_node_alloc(), data);
    char *json = json_to_string(root, FALSE);
    json_node_unref(root);
    json_object_unref(frame);
    g_free(items);
    g_string_free(long_text, TRUE);
    return json;
}

static void test_links(SZFGHarness *harness) {
    char *data = links_conversation();
    szfriends_fake_helper_set_view_data(harness->fake, "conversation", data);
    g_free(data);
    SZFGConv *conv = szfg_conv_open(harness, "c_links");
    EXPECT(click(conv, "See www.apple.com", "m_l1", 5) == SZFRIENDS_GTK_HIT_NONE && !open_popover(conv),
           "a file: link in a friend's message never opens, and shows no menu");
    EXPECT(click(conv, "See www.apple.com", "m_l1", 1) == SZFRIENDS_GTK_HIT_WEB && open_popover(conv),
           "a web link shows the link menu");
    GtkWidget *menu = open_popover(conv);
    EXPECT(szfg_find_label(menu, "Goes to appleid-verify.example.net, not www.apple.com") &&
               szfg_find_label(menu, "https://appleid-verify.example.net/login"),
           "the warning first, then where the link goes");
    GtkWidget *open = szfg_find_button(menu, "Open in Browser");
    EXPECT(open && szfg_conv_records.opened->len == 0, "nothing opened yet");
    if (open) g_signal_emit_by_name(open, "clicked");
    EXPECT(szfg_conv_records.opened->len == 1 && strcmp(g_ptr_array_index(szfg_conv_records.opened, 0),
                                                        "https://appleid-verify.example.net/login") == 0,
           "only the menu's Open opens it");
    EXPECT(click(conv, "See www.apple.com", "m_l1", 3) == SZFRIENDS_GTK_HIT_EMAIL &&
               szfg_find_button(open_popover(conv), "New Email"), "an email link offers New Email");
    GtkWidget *rendered = szfriends_gtk_link_menu_new(szfriends_gtk_conversation_page_state(szfg_conv_page(conv)),
                                                      "https://appleid-verify.example.net/login", "www.apple.com");
    GtkWidget *child = g_object_ref(gtk_popover_get_child(GTK_POPOVER(rendered)));
    gtk_popover_set_child(GTK_POPOVER(rendered), NULL);
    szfg_conv_render_widget(child, 240, "link-menu-light");
    g_object_unref(child);
    g_object_ref_sink(rendered);
    g_object_unref(rendered);

    GtkWidget *long_label = szfg_find_label(szfg_conv_root(conv), "The bracket moved");
    GtkWidget *show_all = szfg_find_button(szfg_conv_root(conv), "Show all");
    gsize shown = long_label ? strlen(gtk_label_get_text(GTK_LABEL(long_label))) : 0;
    EXPECT(long_label && show_all && shown < 4200, "a long message shows its start and Show all (%zu)", shown);
    if (show_all) g_signal_emit_by_name(show_all, "clicked");
    EXPECT(long_label && strlen(gtk_label_get_text(GTK_LABEL(long_label))) > 6000 &&
               !gtk_widget_get_visible(show_all), "Show all shows the rest");
    szfg_conv_close(conv);
}

/* Mentions carry the accent as a Pango colour, which CSS cannot restyle: switching light and dark binds the rows
 * again, so their colours are resolved again. */
static void test_appearance_change(SZFGHarness *harness) {
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    GtkWidget *before = szfg_find_label(szfg_conv_root(conv), "@Leo Park can review");
    g_object_add_weak_pointer(G_OBJECT(before), (gpointer *)&before);
    szfg_set_dark(TRUE);
    szfg_conv_layout(conv);
    GtkWidget *after = szfg_find_label(szfg_conv_root(conv), "@Leo Park can review");
    EXPECT(after && after != before, "the bubble is drawn again for the new appearance");
    if (before) g_object_remove_weak_pointer(G_OBJECT(before), (gpointer *)&before);
    szfg_set_dark(FALSE);
    szfg_conv_close(conv);
}

void szfg_run_conversation_mention_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conv-mention", NULL);
    test_clicks_on_words(harness);
    test_links(harness);
    test_appearance_change(harness);
    render_cards(harness, "light");
    szfg_set_dark(TRUE);
    render_cards(harness, "dark");
    szfg_set_dark(FALSE);
    szfg_harness_free(harness);
}
