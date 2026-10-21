/* Files another of the person's computers holds, and You (PROTOCOL.md § Devices), offscreen against the fake helper:
 * a file on another computer says where it is and offers Get, which fetches it by its transfer_id; a copy under way
 * shows its progress and the route it comes by, with Cancel; and You copies a file to every computer. Rendered light
 * and dark. */

#include "szfriends_gtk_conversation_probe.h"

#include "gtk/szfriends_gtk_glyphs.h"

#include <string.h>

static void serve(SZFGHarness *harness, const char *fixture) {
    char *data = szfg_conv_data_with_previews(harness, fixture, NULL);
    EXPECT(data && szfriends_fake_helper_set_view_data(harness->fake, "conversation", data) == SZFRIENDS_OK,
           "%s served", fixture);
    g_free(data);
}

/* The fixture with no route on any item, as a helper that names none sends it. */
static void serve_without_route(SZFGHarness *harness, const char *fixture) {
    char *data = szfg_conv_data_with_previews(harness, fixture, NULL);
    JsonNode *root = data ? json_from_string(data, NULL) : NULL;
    g_free(data);
    JsonArray *items = root ? json_object_get_array_member(json_node_get_object(root), "items") : NULL;
    for (guint i = 0; items && i < json_array_get_length(items); i++)
        json_object_remove_member(json_array_get_object_element(items, i), "route");
    data = root ? json_to_string(root, FALSE) : NULL;
    EXPECT(data && szfriends_fake_helper_set_view_data(harness->fake, "conversation", data) == SZFRIENDS_OK,
           "%s served without a route", fixture);
    g_free(data);
    if (root) json_node_unref(root);
}

static void collect_named(GtkWidget *root, const char *name, GPtrArray *found) {
    if (!g_strcmp0(gtk_widget_get_name(root), name)) g_ptr_array_add(found, root);
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        collect_named(child, name, found);
}

/* The history row around `widget`, which carries the row's accessible label. */
static GtkWidget *list_row(GtkWidget *widget) {
    while (widget && g_strcmp0(G_OBJECT_TYPE_NAME(widget), "GtkListItemWidget") != 0)
        widget = gtk_widget_get_parent(widget);
    return widget;
}

static gboolean row_says(GtkWidget *widget, const char *spoken) {
    GtkWidget *row = list_row(widget);
    char *problem = row ? gtk_test_accessible_check_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                                             spoken)
                        : g_strdup("no history row");
    if (problem) g_printerr("  row label: %s\n", problem);
    gboolean ok = problem == NULL;
    g_free(problem);
    return ok;
}

#define SZFG_COPYING_SPOKEN "Mei Lin sent Line 2 layout.pdf, PDF, 58.4 MB, copying from Raph’s Mac mini, 25 percent"

/* The copying file's route: once, on its status line after the words, the LAN icon then "Nearby, on your network". */
static void check_copying_route(GtkWidget *root) {
    GPtrArray *routes = g_ptr_array_new();
    collect_named(root, "szfriends.transfer.route", routes);
    GtkWidget *status = szfg_find_label(root, "Copying from Raph’s Mac mini · 25%");
    GtkWidget *route = routes->len == 1 ? g_ptr_array_index(routes, 0) : NULL;
    GtkWidget *glyph = route ? gtk_widget_get_first_child(route) : NULL;
    GtkWidget *words = glyph ? gtk_widget_get_next_sibling(glyph) : NULL;
    GtkWidget *unit = route ? gtk_widget_get_parent(route) : NULL, *dot = route ? gtk_widget_get_prev_sibling(route) : NULL;
    EXPECT(route && status && unit && gtk_widget_is_ancestor(status, gtk_widget_get_parent(unit)) &&
               gtk_widget_get_visible(route),
           "the copying file's route is on its status line, and only there (%u)", routes->len);
    EXPECT(dot && GTK_IS_LABEL(dot) && !g_strcmp0(gtk_label_get_text(GTK_LABEL(dot)), "·"),
           "the dot before it wraps with it, never left at the end of a line");
    EXPECT(glyph && gtk_widget_get_visible(glyph) &&
               szfriends_gtk_glyph_get_kind(glyph) == SZFRIENDS_GTK_GLYPH_ROUTE_LAN && words &&
               GTK_IS_LABEL(words) && !g_strcmp0(gtk_label_get_text(GTK_LABEL(words)), "Nearby, on your network"),
           "the route's icon, then its words");
    EXPECT(row_says(status, SZFG_COPYING_SPOKEN ", Nearby, on your network"),
           "the row's spoken label ends with the route's words");
    g_ptr_array_unref(routes);
    /* Words that already name the route are left as they are. */
    SZFriendsGtkRoute named = {.kind = SZFRIENDS_GTK_ROUTE_LOCAL, .label = "Nearby, on your network"};
    SZFriendsGtkConversationItem item = {.kind = SZFRIENDS_GTK_ITEM_TRANSFER, .route = &named,
                                         .accessibility_label = "Line 2 layout.pdf, copying, nearby, on your network"};
    char *spoken = szfriends_gtk_item_spoken_label(&item);
    EXPECT(!g_strcmp0(spoken, item.accessibility_label), "a label that names the route already is kept: %s", spoken);
    g_free(spoken);
}

static void test_copying_without_route(SZFGHarness *harness) {
    serve_without_route(harness, "devices-conversation-mei-files.json");
    SZFGConv *conv = szfg_conv_open(harness, "c_mei");
    szfg_pump_for(50);
    szfg_conv_layout(conv);
    GtkWidget *root = szfg_conv_root(conv);
    GPtrArray *routes = g_ptr_array_new();
    collect_named(root, "szfriends.transfer.route", routes);
    GtkWidget *status = szfg_find_label(root, "Copying from Raph’s Mac mini · 25%");
    EXPECT(status && routes->len == 0, "without a route the copy shows just its status (%u routes)", routes->len);
    EXPECT(row_says(status, SZFG_COPYING_SPOKEN), "and its row says just the helper's words");
    g_ptr_array_unref(routes);
    szfg_conv_close(conv);
}

static void test_files_on_other_computers(SZFGHarness *harness) {
    serve(harness, "devices-conversation-mei-files.json");
    SZFGConv *conv = szfg_conv_open(harness, "c_mei");
    szfg_pump_for(50);
    szfg_conv_layout(conv);
    GtkWidget *root = szfg_conv_root(conv);
    EXPECT(szfg_find_label(root, "On Raph’s Mac mini") != NULL, "a file on another computer says where it is");
    GtkWidget *get = szfg_find_button(root, "Get");
    EXPECT(get && gtk_widget_has_css_class(get, "suggested-action"), "and offers Get");
    guint before = szfg_fake_frames(harness, "fetch_from_device", NULL, NULL);
    if (get) g_signal_emit_by_name(get, "clicked");
    EXPECT(szfg_conv_wait_frames(harness, "fetch_from_device", before) &&
               szfg_fake_frames(harness, "fetch_from_device", "transfer_id", "t_c81f04d2") == before + 1,
           "Get fetches it by its transfer_id");
    EXPECT(szfg_find_label(root, "Copying from Raph’s Mac mini · 25%") != NULL &&
               szfg_find_label(root, "Copies when Studio workstation is nearby") != NULL,
           "a copy under way and one waiting for its computer say so");
    check_copying_route(root);
    before = szfg_fake_frames(harness, "cancel_transfer", NULL, NULL);
    GtkWidget *cancel = szfg_find_button(root, "Cancel");
    if (cancel) g_signal_emit_by_name(cancel, "clicked");
    EXPECT(szfg_conv_wait_frames(harness, "cancel_transfer", before) &&
               szfg_fake_frames(harness, "cancel_transfer", "transfer_id", "t_4d9b7a35") >= 1,
           "Cancel stops the copy");
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        szfg_conv_render(conv, dark ? "devices-files-dark" : "devices-files-light");
    }
    szfg_set_dark(FALSE);
    szfg_conv_close(conv);

    serve(harness, "devices-conversation-you.json");
    conv = szfg_conv_open(harness, "you");
    szfg_pump_for(50);
    szfg_conv_layout(conv);
    root = szfg_conv_root(conv);
    EXPECT(szfg_find_label(root, "Copying to your other computers · 40%") != NULL &&
               szfg_find_label(root, "On all your computers") != NULL,
           "You: a file copies to every computer, a message says it is on all of them");
    szfg_conv_render(conv, "devices-you-light");
    szfg_conv_close(conv);
}

void szfg_run_conversation_device_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conversation-devices", NULL);
    test_files_on_other_computers(harness);
    test_copying_without_route(harness);
    szfg_harness_free(harness);
}
