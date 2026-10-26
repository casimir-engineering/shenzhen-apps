/* The end of a conversation offscreen (szfriends_gtk_conversation_probe.h): Mei's messages arriving below a history
 * scrolled up leave it where it is and are counted on a pill ("New message ↓", "3 new messages ↓"); the pill scrolls to
 * the first of them and goes; sending from the top takes the history to its end. Rendered light and dark. */

#include "szfriends_gtk_conversation_probe.h"

#include <string.h>

/* A copy of its own (json_node_copy shares the object it holds). */
static JsonNode *deep_copy(JsonNode *node) {
    char *json = json_to_string(node, FALSE);
    JsonNode *copy = json_from_string(json, NULL);
    g_free(json);
    return copy;
}

/* conversation-mei with `older` messages from Mei before its own items, and `extra` (a JSON array's items) after. */
static char *follow_data(SZFGHarness *harness, int older, const char *extra) {
    char *base = szfg_conv_data_with_previews(harness, "conversation-mei.json", NULL);
    JsonNode *root = json_from_string(base, NULL);
    g_free(base);
    JsonArray *items = json_object_get_array_member(json_node_get_object(root), "items");
    JsonArray *next = json_array_new();
    json_array_add_element(next, json_node_copy(json_array_get_element(items, 0)));
    for (int i = 0; i < older; i++) { /* copies of Mei's "Thanks. Here is my markup…" */
        JsonNode *node = deep_copy(json_array_get_element(items, 3));
        JsonObject *item = json_node_get_object(node);
        char *id = g_strdup_printf("m_old_%d", i);
        char *text = g_strdup_printf("Older message %d, long enough to wrap onto a second line here.", i);
        json_object_set_string_member(item, "item_id", id);
        json_object_set_string_member(item, "text", text);
        JsonArray *segments = json_array_new();
        JsonObject *segment = json_object_new();
        json_object_set_string_member(segment, "text", text);
        json_array_add_object_element(segments, segment);
        json_object_set_array_member(item, "segments", segments);
        json_array_add_element(next, node);
        g_free(id);
        g_free(text);
    }
    for (guint i = 1; i < json_array_get_length(items); i++)
        json_array_add_element(next, json_node_copy(json_array_get_element(items, i)));
    JsonNode *added = extra ? json_from_string(extra, NULL) : NULL;
    for (guint i = 0; added && i < json_array_get_length(json_node_get_array(added)); i++) {
        JsonNode *node = deep_copy(json_array_get_element(items, 3));
        JsonObject *item = json_node_get_object(node), *spec = json_array_get_object_element(json_node_get_array(added), i);
        const char *text = json_object_get_string_member(spec, "text");
        json_object_set_string_member(item, "item_id", json_object_get_string_member(spec, "id"));
        json_object_set_string_member(item, "direction", json_object_get_string_member(spec, "direction"));
        json_object_set_string_member(item, "text", text);
        JsonArray *segments = json_array_new();
        JsonObject *segment = json_object_new();
        json_object_set_string_member(segment, "text", text);
        json_array_add_object_element(segments, segment);
        json_object_set_array_member(item, "segments", segments);
        json_array_add_element(next, node);
    }
    if (added) json_node_unref(added);
    json_object_set_array_member(json_node_get_object(root), "items", next);
    char *json = json_to_string(root, FALSE);
    json_node_unref(root);
    return json;
}

typedef struct {
    SZFGConv *conv;
    guint count;
} SZFGFollowWait;

static SZFriendsGtkHistory *history_of(SZFGConv *conv) {
    return szfriends_gtk_conversation_page_history(szfg_conv_page(conv));
}

static gboolean has_items(gpointer data) {
    SZFGFollowWait *wait = data;
    return g_list_model_get_n_items(szfriends_gtk_history_model(history_of(wait->conv))) >= wait->count;
}

static GtkAdjustment *adjustment_of(SZFGConv *conv) {
    GtkWidget *scroller = gtk_widget_get_ancestor(szfriends_gtk_history_list_view(history_of(conv)),
                                                  GTK_TYPE_SCROLLED_WINDOW);
    return gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroller));
}

static gboolean at_end(SZFGConv *conv) {
    GtkAdjustment *a = adjustment_of(conv);
    return gtk_adjustment_get_value(a) + gtk_adjustment_get_page_size(a) >= gtk_adjustment_get_upper(a) - 4;
}

static void serve(SZFGConv *conv, SZFGHarness *harness, int older, const char *extra, guint count) {
    char *data = follow_data(harness, older, extra);
    EXPECT(szfriends_fake_helper_set_view_data(harness->fake, "conversation", data) == SZFRIENDS_OK, "served");
    g_free(data);
    SZFGFollowWait wait = {conv, count};
    EXPECT(szfg_pump_until(has_items, &wait, 3000), "the history shows %u items", count);
    szfg_conv_layout(conv);
}

static void test_follow(SZFGHarness *harness, gboolean dark) {
    szfg_set_dark(dark);
    char *data = follow_data(harness, 24, NULL);
    szfriends_fake_helper_set_view_data(harness->fake, "conversation", data);
    g_free(data);
    SZFGConv *conv = szfg_conv_open(harness, "c_mei");
    szfg_conv_layout(conv);
    guint base = g_list_model_get_n_items(szfriends_gtk_history_model(history_of(conv)));
    GtkWidget *pill = szfriends_gtk_history_pill(history_of(conv));
    EXPECT(at_end(conv) && !gtk_widget_get_visible(pill), "a long conversation opens at its end, no pill");

    gtk_adjustment_set_value(adjustment_of(conv), 0);
    szfg_conv_layout(conv);
    serve(conv, harness, 24, "[{\"id\":\"m_new_1\",\"direction\":\"in\",\"text\":\"First new message from Mei.\"}]",
          base + 1);
    EXPECT(gtk_widget_get_visible(pill) && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(pill)), "New message ↓") &&
               gtk_adjustment_get_value(adjustment_of(conv)) < 4,
           "one message below: the pill says so and nothing moves");
    serve(conv, harness, 24, "[{\"id\":\"m_new_1\",\"direction\":\"in\",\"text\":\"First new message from Mei.\"},"
                             "{\"id\":\"m_new_2\",\"direction\":\"in\",\"text\":\"Second.\"},"
                             "{\"id\":\"m_new_3\",\"direction\":\"in\",\"text\":\"Third.\"}]", base + 3);
    EXPECT(gtk_widget_get_visible(pill) && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(pill)), "3 new messages ↓"),
           "several are counted (%s)", gtk_button_get_label(GTK_BUTTON(pill)));
    szfg_render(conv->probe_window, 400, 640, dark ? "conversation-new-messages-dark"
                                                   : "conversation-new-messages-light");
    g_signal_emit_by_name(pill, "clicked");
    szfg_conv_layout(conv);
    EXPECT(!gtk_widget_get_visible(pill) && gtk_adjustment_get_value(adjustment_of(conv)) > 4,
           "the pill scrolls to the first new message and goes");

    gtk_adjustment_set_value(adjustment_of(conv), 0);
    szfg_conv_layout(conv);
    serve(conv, harness, 24, "[{\"id\":\"m_new_1\",\"direction\":\"in\",\"text\":\"First new message from Mei.\"},"
                             "{\"id\":\"m_new_2\",\"direction\":\"in\",\"text\":\"Second.\"},"
                             "{\"id\":\"m_new_3\",\"direction\":\"in\",\"text\":\"Third.\"},"
                             "{\"id\":\"m_sent\",\"direction\":\"out\",\"text\":\"A reply sent from the top.\"}]",
          base + 4);
    szfg_conv_layout(conv);
    EXPECT(at_end(conv) && !gtk_widget_get_visible(pill), "sending from the top takes the history to its end");
    szfg_conv_close(conv);
}

void szfg_run_conversation_follow_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conversation-follow", NULL);
    test_follow(harness, FALSE);
    test_follow(harness, TRUE);
    szfg_set_dark(FALSE);
    szfg_harness_free(harness);
}
