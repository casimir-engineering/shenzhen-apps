/* The conversation header's route line starts with the route's icon, one per connection method
 * (szfriends_gtk_glyphs.h), coloured as the words, with the helper's route label as the line's tooltip; a route of
 * kind none draws no icon, as the helper sends it for a blocked friend's "Blocked". The header button's accessible
 * name says the line too ("Mei Lin, nearby, over Bluetooth, show details"), so Orca reads how the friend is
 * connected. Mei's header is served with each route in turn, with that route's words as the line; renders of five
 * of them land beside the other conversation renders. */

#include "szfriends_gtk_conversation_probe.h"

#include "gtk/szfriends_gtk_glyphs.h"

#include <string.h>

static GtkWidget *find_named(GtkWidget *root, const char *name) {
    if (!g_strcmp0(gtk_widget_get_name(root), name)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_named(child, name);
        if (found) return found;
    }
    return NULL;
}

static GtkWidget *header_glyph(SZFGConv *conv) {
    GtkWidget *line = find_named(szfg_conv_content(conv), "szfriends.header-route");
    return line ? gtk_widget_get_first_child(line) : NULL;
}

typedef struct {
    SZFGConv *conv;
    SZFriendsGtkGlyphKind kind;
    const char *label, *spoken;
} SZFGHeaderWait;

/* The button around the name and the route line, which carries the header's accessible name. */
static GtkWidget *header_title(SZFGConv *conv) {
    GtkWidget *line = find_named(szfg_conv_content(conv), "szfriends.header-route");
    return line ? gtk_widget_get_parent(gtk_widget_get_parent(line)) : NULL;
}

static gboolean header_shows(gpointer data) {
    SZFGHeaderWait *wait = data;
    GtkWidget *glyph = header_glyph(wait->conv), *title = header_title(wait->conv);
    GtkWidget *line = glyph ? gtk_widget_get_parent(glyph) : NULL;
    char *problem = title ? gtk_test_accessible_check_property(GTK_ACCESSIBLE(title), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                                                wait->spoken) : g_strdup("no title");
    gboolean shows = !problem && glyph && szfriends_gtk_glyph_get_kind(glyph) == wait->kind &&
                     !g_strcmp0(gtk_widget_get_tooltip_text(line), wait->label);
    g_free(problem);
    return shows;
}

/* What the helper says for the header: the name, the line as a fragment, and that it opens details. */
static char *spoken_header(const char *line) {
    return g_strdup_printf("Mei Lin, %c%s, show details", g_ascii_tolower(line[0]), line + 1);
}

/* Mei's conversation with the header's route (and the line under the name) replaced. */
static void serve_route(SZFGHarness *harness, const char *kind, const char *method, const char *label) {
    JsonObject *frame = szfg_fixture("snapshots/conversation-mei.json");
    JsonObject *data = json_object_get_object_member(frame, "data");
    JsonObject *header = json_object_get_object_member(data, "header"), *route = json_object_new();
    json_object_set_string_member(route, "kind", kind);
    if (method) json_object_set_string_member(route, "method", method);
    else json_object_set_null_member(route, "method");
    if (label) json_object_set_string_member(route, "label", label);
    else json_object_set_null_member(route, "label");
    json_object_set_object_member(header, "route", route);
    json_object_set_string_member(header, "subtitle", label ? label : "Blocked");
    char *spoken = spoken_header(label ? label : "Blocked");
    json_object_set_string_member(header, "accessibility_label", spoken);
    g_free(spoken);
    JsonNode *node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(node, data);
    char *text = json_to_string(node, FALSE);
    EXPECT(szfriends_fake_helper_set_view_data(harness->fake, "conversation", text) == SZFRIENDS_OK,
           "Mei's header served with %s", method ? method : kind);
    g_free(text);
    json_node_unref(node);
    json_object_unref(frame);
}

static void test_header_icons(void) {
    static const struct {
        const char *kind, *method, *label;
        SZFriendsGtkGlyphKind glyph;
        const char *render; /* NULL: not rendered */
    } routes[] = {
        {"local", "lan", "Nearby, on your network", SZFRIENDS_GTK_GLYPH_ROUTE_LAN, NULL},
        {"local", "p2p_wifi", "Nearby, over direct Wi-Fi", SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI, "p2p-wifi"},
        {"local", "bluetooth", "Nearby, over Bluetooth", SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH, "bluetooth"},
        {"online", "internet", "Online, direct", SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET, NULL},
        {"online", "relay", "Online, through the Friends relay", SZFRIENDS_GTK_GLYPH_ROUTE_RELAY, "relay"},
        {"offline", NULL, "Not nearby right now", SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE, "offline"},
        {"none", NULL, NULL, SZFRIENDS_GTK_GLYPH_NONE, "blocked"},
    };
    SZFGHarness *harness = szfg_conv_harness("conversation-routes", NULL);
    /* Each theme on a page opened in it, as the other conversation renders are. */
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        SZFGConv *conv = szfg_conv_open(harness, "c_mei");
        for (gsize i = 0; i < G_N_ELEMENTS(routes); i++) {
            serve_route(harness, routes[i].kind, routes[i].method, routes[i].label);
            char *spoken = spoken_header(routes[i].label ? routes[i].label : "Blocked");
            SZFGHeaderWait wait = {conv, routes[i].glyph, routes[i].label, spoken};
            EXPECT(szfg_pump_until(header_shows, &wait, 3000),
                   "the header shows %s's icon with \"%s\" as its tooltip, and says \"%s\"",
                   routes[i].method ? routes[i].method : routes[i].kind, routes[i].label ? routes[i].label : "",
                   spoken);
            g_free(spoken);
            GtkWidget *glyph = header_glyph(conv);
            EXPECT(glyph && gtk_widget_get_visible(glyph) == (routes[i].glyph != SZFRIENDS_GTK_GLYPH_NONE),
                   "%s: an icon only for a route", routes[i].kind);
            if (!routes[i].render) continue;
            szfg_conv_layout(conv);
            char *name = g_strdup_printf("conversation-route-%s-%s", routes[i].render, dark ? "dark" : "light");
            szfg_conv_render(conv, name);
            g_free(name);
        }
        szfg_conv_close(conv);
    }
    szfg_set_dark(FALSE);
    szfg_harness_free(harness);
}

void szfg_run_conversation_route_probes(void) {
    test_header_icons();
}
