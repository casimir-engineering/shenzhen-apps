/* Transfers, the request card, the header and search offscreen (szfriends_gtk_conversation_probe.h): previews drawn
 * from the helper's cache with a missing one falling back to the type's icon, Accept and Decline on an offer, Cancel
 * and Try again on queued and failed messages, Show in Shenzhen Files through the host, Show earlier messages, a
 * pending request's card in place of the history, the name that opens details, and search that jumps to a message. */

#include "szfriends_gtk_conversation_probe.h"

#include <string.h>

static guint loaded_previews(GtkWidget *root) {
    guint count = szfriends_gtk_preview_is_loaded(root);
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        count += loaded_previews(child);
    return count;
}

static GtkWidget *find_preview(GtkWidget *root) {
    if (szfriends_gtk_is_preview(root)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_preview(child);
        if (found) return found;
    }
    return NULL;
}

static gboolean has_preview(GtkWidget *root) {
    return find_preview(root) != NULL;
}

/* The type's icon: the theme's image, or the kind label on a page shape where the theme has no document icons. */
static gboolean has_type_icon(GtkWidget *root) {
    if (GTK_IS_IMAGE(root) || gtk_widget_has_css_class(root, "szfriends-file-glyph")) return TRUE;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        if (has_type_icon(child)) return TRUE;
    return FALSE;
}

typedef struct {
    SZFGConv *conv;
    guint count;
} SZFGPreviewWait;

static gboolean previews_loaded(gpointer data) {
    SZFGPreviewWait *wait = data;
    return loaded_previews(szfg_conv_root(wait->conv)) >= wait->count;
}

static void press(SZFGConv *conv, const char *label) {
    GtkWidget *button = szfg_find_button(szfg_conv_root(conv), label);
    EXPECT(button && gtk_widget_get_sensitive(button), "a %s button to press", label);
    if (button) g_signal_emit_by_name(button, "clicked");
}

static void expect_sent(SZFGHarness *harness, SZFGConv *conv, const char *label, const char *type, const char *key,
                        const char *value) {
    guint before = szfg_fake_frames(harness, type, key, value), all = szfg_fake_frames(harness, type, NULL, NULL);
    press(conv, label);
    EXPECT(szfg_conv_wait_frames(harness, type, all) && szfg_fake_frames(harness, type, key, value) == before + 1,
           "%s sends %s with %s %s", label, type, key, value);
}

static void open_rendered(SZFGHarness *harness, const char *id, guint previews, const char *name) {
    SZFGConv *conv = szfg_conv_open(harness, id);
    SZFGPreviewWait wait = {conv, previews};
    EXPECT(szfg_pump_until(previews_loaded, &wait, 3000), "%s: %u previews drawn", id, previews);
    szfg_conv_layout(conv);
    szfg_conv_render(conv, name);
    szfg_conv_close(conv);
}

static void test_previews_and_actions(SZFGHarness *harness) {
    char *kenji = szfg_conv_data_with_previews(harness, "conversation-kenji-offer.json", NULL);
    char *mei = szfg_conv_data_with_previews(harness, "conversation-mei.json", "t_3e8b5d10");
    szfriends_fake_helper_set_view_data(harness->fake, "conversation", kenji);
    szfriends_fake_helper_set_view_data(harness->fake, "conversation", mei);
    g_free(kenji);
    g_free(mei);
    SZFGConv *conv = szfg_conv_open(harness, "c_kenji");
    SZFGPreviewWait wait = {conv, 1};
    EXPECT(szfg_pump_until(previews_loaded, &wait, 3000), "the sender's preview of an offer shows before accepting");
    szfg_conv_layout(conv);
    GtkWidget *preview = find_preview(szfg_conv_root(conv));
    EXPECT(preview && gtk_widget_get_width(preview) == 45 && gtk_widget_get_height(preview) == 64,
           "a 136 x 192 preview keeps the 45 x 64 box laid out from the snapshot before it loaded, as AppKit (%d x %d)",
           preview ? gtk_widget_get_width(preview) : -1, preview ? gtk_widget_get_height(preview) : -1);
    EXPECT(szfg_find_label(szfg_conv_root(conv), "Over Bluetooth, about 6 min"), "with the route note");
    guint earlier = szfg_fake_frames(harness, "load_earlier", NULL, NULL);
    press(conv, "Show earlier messages");
    EXPECT(szfg_conv_wait_frames(harness, "load_earlier", earlier), "Show earlier messages asks for 200 more");
    expect_sent(harness, conv, "Accept", "accept_offer", "transfer_id", "t_kenji_site");
    szfg_conv_close(conv);

    conv = szfg_conv_open(harness, "c_mei");
    wait = (SZFGPreviewWait){conv, 1};
    EXPECT(szfg_pump_until(previews_loaded, &wait, 3000), "a delivered file's preview shows");
    szfg_pump_for(100);
    szfg_conv_layout(conv);
    GtkWidget *list = szfriends_gtk_history_list_view(szfriends_gtk_conversation_page_history(szfg_conv_page(conv)));
    GtkAdjustment *scroll = gtk_scrollable_get_vadjustment(GTK_SCROLLABLE(list));
    EXPECT(gtk_adjustment_get_upper(scroll) > gtk_adjustment_get_page_size(scroll) &&
               gtk_adjustment_get_value(scroll) + gtk_adjustment_get_page_size(scroll) >=
                   gtk_adjustment_get_upper(scroll) - 4,
           "a history taller than the view opens at its newest message (%.0f + %.0f of %.0f)",
           gtk_adjustment_get_value(scroll), gtk_adjustment_get_page_size(scroll), gtk_adjustment_get_upper(scroll));
    GtkWidget *words = szfg_find_label(szfg_conv_root(conv), "Thanks. Here is my markup");
    GtkWidget *bubble = words ? gtk_widget_get_parent(words) : NULL;
    graphene_rect_t box = GRAPHENE_RECT_INIT(0, 0, 0, 0);
    gboolean placed = bubble && gtk_widget_compute_bounds(bubble, bubble, &box); /* border box, padding included */
    EXPECT(placed && box.size.width >= 270 && box.size.width <= 280,
           "a bubble keeps to chat width, 280 px, as AppKit's (%.0f)", box.size.width);
    GtkWidget *receiving = szfg_find_label(szfg_conv_root(conv), "Bracket drawing rev B.pdf");
    GtkWidget *card = receiving ? gtk_widget_get_ancestor(receiving, GTK_TYPE_BOX) : NULL;
    while (card && !gtk_widget_has_css_class(card, "szfriends-transfer-card")) card = gtk_widget_get_parent(card);
    EXPECT(card && !has_preview(card) && has_type_icon(card) &&
               szfg_count_type(card, GTK_TYPE_PROGRESS_BAR) == 1,
           "a preview the cache no longer has shows the type's icon, and the transfer its progress");
    expect_sent(harness, conv, "Cancel", "cancel_transfer", "transfer_id", "t_3e8b5d10");
    GtkWidget *title = szfriends_gtk_conversation_page_part(szfg_conv_page(conv), "title");
    EXPECT(GTK_IS_BUTTON(title), "the name opens details when they are available");
    if (GTK_IS_BUTTON(title)) g_signal_emit_by_name(title, "clicked");
    SZFriendsGtkPage *top = szfg_conv_page(conv);
    EXPECT(top && szfriends_gtk_page_get_kind(top) == SZFRIENDS_GTK_PAGE_DETAILS, "a click on the name opens details");
    szfriends_gtk_dropdown_go_back(conv->dropdown);
    szfg_pump_for(100);
    GtkWidget *search = szfriends_gtk_conversation_page_part(szfg_conv_page(conv), "search");
    guint searches = szfg_fake_frames(harness, "search_messages", "conversation_id", "c_mei");
    gtk_editable_set_text(GTK_EDITABLE(search), "pages");
    EXPECT(szfg_conv_wait_frames(harness, "search_messages", searches) &&
               szfg_fake_frames(harness, "search_messages", "conversation_id", "c_mei") == searches + 1,
           "search asks the helper about this conversation only");
    szfg_pump_for(100);
    GtkWidget *results = szfriends_gtk_conversation_page_part(szfg_conv_page(conv), "results");
    EXPECT(results && szfg_find_label(results, "Can you check pages 3–5"), "the excerpts show");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(!szfriends_gtk_conversation_page_part(szfg_conv_page(conv), "results") &&
               szfriends_gtk_dropdown_is_open(conv->dropdown), "Escape closes the results first");
    gtk_editable_set_text(GTK_EDITABLE(search), "pages 3");
    szfg_pump_for(400);
    results = szfriends_gtk_conversation_page_part(szfg_conv_page(conv), "results");
    guint opens = szfg_fake_frames(harness, "open_conversation", "message_id", "m_a4109f52");
    guint all_opens = szfg_fake_frames(harness, "open_conversation", NULL, NULL);
    GtkWidget *hit = results ? gtk_widget_get_first_child(results) : NULL;
    if (hit) g_signal_emit_by_name(hit, "clicked");
    EXPECT(szfg_conv_wait_frames(harness, "open_conversation", all_opens) &&
               szfg_fake_frames(harness, "open_conversation", "message_id", "m_a4109f52") == opens + 1,
           "choosing one opens the conversation at that exact message");
    szfg_conv_close(conv);
}

static void test_messages_and_files(SZFGHarness *harness) {
    SZFGConv *conv = szfg_conv_open(harness, "c_priya");
    guint cancels = szfg_count_buttons(szfg_conv_root(conv), "Cancel");
    EXPECT(cancels == 3, "Cancel on both queued messages and the queued file (%u)", cancels);
    EXPECT(szfg_find_label(szfg_conv_root(conv), "Messages and files send when Priya is nearby"),
           "the composer's note says when they go");
    expect_sent(harness, conv, "Try again", "retry_item", "item_id", "m_9b31c7e5");
    expect_sent(harness, conv, "Cancel", "cancel_message", "message_id", "m_c4d27a19");
    szfg_conv_close(conv);

    /* A received file: Show in Shenzhen Files goes through the host, never the helper. */
    JsonObject *frame = szfg_fixture("snapshots/conversation-mei.json");
    JsonObject *data = json_object_get_object_member(frame, "data");
    json_object_set_string_member(data, "conversation_id", "c_received");
    JsonObject *item = json_array_get_object_element(json_object_get_array_member(data, "items"), 3);
    json_object_set_string_member(item, "state", "received");
    json_object_set_string_member(item, "status_label", "Received");
    json_object_set_null_member(item, "progress");
    json_object_set_null_member(item, "thumbnail");
    json_object_set_member(item, "actions", json_from_string(
        "[{\"action\":\"show_file\",\"label\":\"Show in Shenzhen Files\",\"style\":\"link\",\"path\":"
        "\"/Users/raph/Library/Application Support/Shenzhen Friends/received/Bracket drawing rev B.pdf\"}]", NULL));
    JsonNode *root = json_node_init_object(json_node_alloc(), data);
    char *json = json_to_string(root, FALSE);
    szfriends_fake_helper_set_view_data(harness->fake, "conversation", json);
    g_free(json);
    json_node_unref(root);
    json_object_unref(frame);
    conv = szfg_conv_open(harness, "c_received");
    guint revealed = szfg_conv_records.revealed->len;
    press(conv, "Show in Shenzhen Files");
    EXPECT(szfg_conv_records.revealed->len == revealed + 1 &&
               g_str_has_suffix(g_ptr_array_index(szfg_conv_records.revealed, revealed), "rev B.pdf"),
           "Show in Shenzhen Files reveals the received file through the host");
    szfg_conv_close(conv);
}

static void test_request(SZFGHarness *harness) {
    SZFGConv *conv = szfg_conv_open(harness, "c_lena");
    SZFriendsGtkPage *page = szfg_conv_page(conv);
    GtkWidget *stack = szfriends_gtk_conversation_page_part(page, "stack");
    EXPECT(g_strcmp0(gtk_stack_get_visible_child_name(GTK_STACK(stack)), "request") == 0 &&
               !gtk_widget_get_visible(szfriends_gtk_conversation_page_part(page, "composer")),
           "a pending request replaces the history and the composer");
    EXPECT(!GTK_IS_BUTTON(szfriends_gtk_conversation_page_part(page, "title")),
           "without details the name is not a button");
    GtkWidget *card = szfriends_gtk_conversation_page_part(page, "request");
    EXPECT(szfg_find_label(card, "418 270") && szfg_find_label(card, "Before you accept"),
           "the comparison code both screens show, and what to check");
    GtkWidget *block = szfg_find_button(card, "Block Lena");
    if (block) g_signal_emit_by_name(block, "clicked");
    EXPECT(block && szfriends_gtk_action_button_is_armed(block), "Block arms first");
    szfriends_gtk_dropdown_escape(conv->dropdown);
    EXPECT(block && !szfriends_gtk_action_button_is_armed(block) && szfriends_gtk_dropdown_is_open(conv->dropdown),
           "Escape turns it back before closing anything");
    expect_sent(harness, conv, "Accept", "accept_request", "conversation_id", "c_lena");
    szfg_conv_close(conv);
}

static void render_all(SZFGHarness *harness, const char *theme) {
    char *name;
#define RENDER(id, previews, label)                                                                              \
    name = g_strdup_printf("conversation-%s-%s", label, theme);                                                \
    open_rendered(harness, id, previews, name);                                                                \
    g_free(name)
    RENDER("c_mei", 1, "mei");
    RENDER("c_kenji", 1, "kenji-offer");
    RENDER("c_priya", 0, "priya-queued");
    RENDER("c_lena", 0, "lena-request");
#undef RENDER
}

void szfg_run_conversation_transfer_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conv-transfer", NULL);
    test_previews_and_actions(harness);
    test_messages_and_files(harness);
    test_request(harness);
    render_all(harness, "light");
    szfg_set_dark(TRUE);
    render_all(harness, "dark");
    szfg_set_dark(FALSE);
    szfg_harness_free(harness);
}
