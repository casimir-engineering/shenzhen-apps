/* Online friends in the conversation (PROTOCOL.md § Shared objects, Route, online), from the fixtures the helper's
 * presentation builds: Kenji through the relay shows the server icon in the online colour and the relay's estimate on
 * his offer; Priya while an attempt runs shows the globe in the offline colour; Priya unreachable shows the crossed dot
 * and a composer note saying everything waits. Each is rendered light and dark beside the other conversation renders,
 * as AppKit's online/ renders are. */

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

/* The label starting with `prefix` under the page, shown: it and every parent up to the probe window, which is never
 * mapped, are visible. */
static gboolean shows_label(SZFGConv *conv, const char *prefix) {
    GtkWidget *label = szfg_find_label(szfg_conv_root(conv), prefix);
    for (GtkWidget *widget = label; widget && !GTK_IS_ROOT(widget); widget = gtk_widget_get_parent(widget))
        if (!gtk_widget_get_visible(widget)) return FALSE;
    return label != NULL;
}

static const struct {
    const char *fixture, *conversation_id, *tooltip, *css_class, *says;
    SZFriendsGtkGlyphKind glyph;
} cases[] = {
    {"online-conversation-kenji-relay.json", "c_kenji", "Online, through the Friends relay", "szfriends-route-online",
     "Through the Friends relay, about 1 min", SZFRIENDS_GTK_GLYPH_ROUTE_RELAY},
    {"online-conversation-priya-connecting.json", "c_priya", "Connecting to Priya…", "szfriends-route-offline",
     "Connecting to Priya…", SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET},
    {"online-conversation-priya-unreachable.json", "c_priya", "Couldn’t connect just now", "szfriends-route-offline",
     "Couldn’t connect to Priya just now. Friends keeps trying, and sends what’s waiting as soon as it can.",
     SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE},
};

static void test_online_conversations(void) {
    SZFGHarness *harness = szfg_conv_harness("conversation-online", NULL);
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        for (gsize i = 0; i < G_N_ELEMENTS(cases); i++) {
            char *data = szfg_conv_data_with_previews(harness, cases[i].fixture, NULL);
            EXPECT(data && szfriends_fake_helper_set_view_data(harness->fake, "conversation", data) == SZFRIENDS_OK,
                   "%s served", cases[i].fixture);
            g_free(data);
            SZFGConv *conv = szfg_conv_open(harness, cases[i].conversation_id);
            szfg_pump_for(50);
            szfg_conv_layout(conv);
            GtkWidget *line = find_named(szfg_conv_content(conv), "szfriends.header-route");
            GtkWidget *glyph = line ? gtk_widget_get_first_child(line) : NULL;
            EXPECT(glyph && szfriends_gtk_glyph_get_kind(glyph) == cases[i].glyph && gtk_widget_get_visible(glyph) &&
                       gtk_widget_has_css_class(glyph, cases[i].css_class) &&
                       !g_strcmp0(gtk_widget_get_tooltip_text(line), cases[i].tooltip),
                   "%s: the header draws its route's icon (%d) in %s, with \"%s\" as its tooltip", cases[i].fixture,
                   glyph ? (int)szfriends_gtk_glyph_get_kind(glyph) : -1, cases[i].css_class, cases[i].tooltip);
            EXPECT(shows_label(conv, cases[i].says), "%s says \"%s\"", cases[i].fixture, cases[i].says);
            /* "online-conversation-kenji-relay-light": the fixture's name without ".json". */
            char *name = g_strdup_printf("%.*s-%s", (int)(strlen(cases[i].fixture) - strlen(".json")),
                                         cases[i].fixture, dark ? "dark" : "light");
            szfg_conv_render(conv, name);
            g_free(name);
            szfg_conv_close(conv);
        }
    }
    szfg_set_dark(FALSE);
    szfg_harness_free(harness);
}

void szfg_run_conversation_online_probes(void) {
    test_online_conversations();
}
