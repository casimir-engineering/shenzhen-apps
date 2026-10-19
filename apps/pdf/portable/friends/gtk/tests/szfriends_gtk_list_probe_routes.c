/* A row's route icon follows the connection method (szfriends_gtk_glyphs.h): Mei's row is served with each route in
 * turn and draws that method's glyph, in its kind's colour, with the helper's label as its tooltip; and the fixtures'
 * rows show theirs (list.json: Mei on the network, Daniel over direct Wi-Fi, Priya offline; online-list.json: Mei
 * direct and Daniel through the relay in the online colour, Priya's globe grey while an attempt connects). */

#include "szfriends_gtk_list_probe.h"

#include "gtk/szfriends_gtk_glyphs.h"

static GtkWidget *route_glyph(GtkWidget *root) {
    if (!root) return NULL;
    if (gtk_widget_has_css_class(root, "szfriends-route")) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = route_glyph(child);
        if (found) return found;
    }
    return NULL;
}

/* list.json with Mei's route replaced. */
static void serve_route(SZFGHarness *harness, const char *kind, const char *method, const char *label) {
    JsonObject *frame = szfg_fixture("snapshots/list.json"), *data = json_object_get_object_member(frame, "data");
    JsonObject *mei = json_array_get_object_element(json_object_get_array_member(data, "rows"), 1);
    JsonObject *route = json_object_get_object_member(mei, "route");
    json_object_set_string_member(route, "kind", kind);
    if (method) json_object_set_string_member(route, "method", method);
    else json_object_set_null_member(route, "method");
    json_object_set_string_member(route, "label", label);
    JsonNode *node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(node, data);
    char *text = json_to_string(node, FALSE);
    szfriends_fake_helper_set_view_data(harness->fake, "list", text);
    g_free(text);
    json_node_unref(node);
    json_object_unref(frame);
}

typedef struct {
    SZFGList *list;
    SZFriendsGtkGlyphKind kind;
    const char *label;
} SZFGRouteWait;

static gboolean mei_shows(gpointer data) {
    SZFGRouteWait *wait = data;
    GtkWidget *glyph = route_glyph(szfg_list_row(wait->list, "c_mei"));
    return glyph && szfriends_gtk_glyph_get_kind(glyph) == wait->kind &&
           !g_strcmp0(gtk_widget_get_tooltip_text(glyph), wait->label);
}

typedef struct {
    const char *conversation_id;
    SZFriendsGtkGlyphKind glyph;
    gboolean online; /* drawn in the online colour */
} SZFGRowIcon;

static void expect_icons(SZFGList *list, const SZFGRowIcon *rows, gsize count, const char *fixture) {
    for (gsize i = 0; i < count; i++) {
        GtkWidget *glyph = route_glyph(szfg_list_row(list, rows[i].conversation_id));
        EXPECT(glyph && szfriends_gtk_glyph_get_kind(glyph) == rows[i].glyph && gtk_widget_get_opacity(glyph) == 1 &&
                   gtk_widget_has_css_class(glyph, "online") == rows[i].online,
               "%s: %s's row shows its route's icon (%d)%s", fixture, rows[i].conversation_id,
               glyph ? (int)szfriends_gtk_glyph_get_kind(glyph) : -1, rows[i].online ? " in the online colour" : "");
    }
}

static void test_fixture_icons(SZFGList *list) {
    static const SZFGRowIcon rows[] = {{"c_mei", SZFRIENDS_GTK_GLYPH_ROUTE_LAN, FALSE},
                                       {"c_daniel", SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI, FALSE},
                                       {"c_priya", SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE, FALSE}};
    expect_icons(list, rows, G_N_ELEMENTS(rows), "list.json");
}

typedef struct {
    SZFGList *list;
    const char *conversation_id;
    SZFriendsGtkGlyphKind kind;
} SZFGRowWait;

static gboolean row_shows(gpointer data) {
    SZFGRowWait *wait = data;
    GtkWidget *glyph = route_glyph(szfg_list_row(wait->list, wait->conversation_id));
    return glyph && szfriends_gtk_glyph_get_kind(glyph) == wait->kind;
}

static void test_online_icons(SZFGHarness *harness, SZFGList *list) {
    static const SZFGRowIcon rows[] = {{"c_mei", SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET, TRUE},
                                       {"c_daniel", SZFRIENDS_GTK_GLYPH_ROUTE_RELAY, TRUE},
                                       {"c_priya", SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET, FALSE},
                                       {"c_tulip", SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE, FALSE}};
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "online-list.json");
    SZFGRowWait wait = {list, "c_daniel", SZFRIENDS_GTK_GLYPH_ROUTE_RELAY};
    EXPECT(szfg_pump_until(row_shows, &wait, 3000), "online-list.json arrives");
    expect_icons(list, rows, G_N_ELEMENTS(rows), "online-list.json");
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
}

static void test_each_method(SZFGHarness *harness, SZFGList *list) {
    static const struct {
        const char *kind, *method, *label, *color;
        SZFriendsGtkGlyphKind glyph;
    } routes[] = {
        {"local", "p2p_wifi", "Nearby, over direct Wi-Fi", "local", SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI},
        {"local", "bluetooth", "Nearby, over Bluetooth", "local", SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH},
        {"online", "internet", "Online, direct", "online", SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET},
        {"connecting", NULL, "Connecting to Mei…", NULL, SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET},
        {"online", "relay", "Online, through the Friends relay", "online", SZFRIENDS_GTK_GLYPH_ROUTE_RELAY},
        {"local", NULL, "Nearby", "local", SZFRIENDS_GTK_GLYPH_ROUTE_LAN},
        {"online", NULL, "Online", "online", SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET},
        {"local", "lan", "Nearby, on your network", "local", SZFRIENDS_GTK_GLYPH_ROUTE_LAN},
    };
    for (gsize i = 0; i < G_N_ELEMENTS(routes); i++) {
        serve_route(harness, routes[i].kind, routes[i].method, routes[i].label);
        SZFGRouteWait wait = {list, routes[i].glyph, routes[i].label};
        EXPECT(szfg_pump_until(mei_shows, &wait, 3000), "Mei's row draws %s's icon with \"%s\" as its tooltip",
               routes[i].method ? routes[i].method : routes[i].kind, routes[i].label);
        GtkWidget *glyph = route_glyph(szfg_list_row(list, "c_mei"));
        /* No colour class: the offline colour every route icon starts from. */
        EXPECT(glyph && (routes[i].color ? gtk_widget_has_css_class(glyph, routes[i].color)
                                         : !gtk_widget_has_css_class(glyph, "online") &&
                                               !gtk_widget_has_css_class(glyph, "local")),
               "in the %s route's colour", routes[i].color ? routes[i].color : "offline");
    }
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
}

void szfg_run_list_route_probes(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    EXPECT(szfg_list_wait_rows(list, 7), "the fixture's rows");
    test_fixture_icons(list);
    test_each_method(harness, list);
    test_online_icons(harness, list);
    szfg_list_close(list);
}
