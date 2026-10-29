/* How someone nearby was found (PROTOCOL.md found, client capability nearby.found): on Nearby's people and on a
 * friend's list row, one route icon per method seeing them (the network's waves, the Bluetooth rune, both) and the
 * helper's words for them; nothing at all for someone not nearby. */

#include "szfriends_gtk_list_probe.h"

#include "gtk/szfriends_gtk_glyphs.h"

const char szfg_list_found[] =
    "{\"query\":\"\",\"banner\":null,\"name_prompt\":null,\"rows\":[{\"conversation_id\":\"c_mei\",\"avat"
    "ar\":{\"kind\":\"placeholder\",\"initials\":\"M\",\"color\":\"#5a5a66\"},\"title\":\"Mei\",\"subtitl"
    "e\":\"Hi\",\"time_label\":\"\",\"route\":{\"kind\":\"local\",\"method\":\"lan\",\"label\":\"Nearby\""
    "},\"unread\":false,\"waiting\":null,\"blocked\":false,\"id_confirmed\":false,\"id_confirmed_label\":"
    "null,\"style\":\"normal\",\"drop_label\":null,\"drop_refusal\":null,\"accessibility_label\":\"Mei\","
    "\"actions\":[],\"found\":{\"methods\":[\"lan\"],\"label\":\"Local network\"}},{\"conversation_id\":\""
    "c_jonas\",\"avatar\":{\"kind\":\"placeholder\",\"initials\":\"J\",\"color\":\"#5a5a66\"},\"title\":\""
    "Jonas\",\"subtitle\":\"Hi\",\"time_label\":\"\",\"route\":{\"kind\":\"local\",\"method\":\"lan\",\"l"
    "abel\":\"Nearby\"},\"unread\":false,\"waiting\":null,\"blocked\":false,\"id_confirmed\":false,\"id_c"
    "onfirmed_label\":null,\"style\":\"normal\",\"drop_label\":null,\"drop_refusal\":null,\"accessibility"
    "_label\":\"Jonas\",\"actions\":[],\"found\":{\"methods\":[\"bluetooth\"],\"label\":\"Bluetooth\"}},{"
    "\"conversation_id\":\"c_kenji\",\"avatar\":{\"kind\":\"placeholder\",\"initials\":\"K\",\"color\":\""
    "#5a5a66\"},\"title\":\"Kenji\",\"subtitle\":\"Hi\",\"time_label\":\"\",\"route\":{\"kind\":\"local\""
    ",\"method\":\"lan\",\"label\":\"Nearby\"},\"unread\":false,\"waiting\":null,\"blocked\":false,\"id_c"
    "onfirmed\":false,\"id_confirmed_label\":null,\"style\":\"normal\",\"drop_label\":null,\"drop_refusal"
    "\":null,\"accessibility_label\":\"Kenji\",\"actions\":[],\"found\":{\"methods\":[\"lan\",\"bluetooth"
    "\"],\"label\":\"Local network and Bluetooth\"}},{\"conversation_id\":\"c_lena\",\"avatar\":{\"kind\""
    ":\"placeholder\",\"initials\":\"L\",\"color\":\"#5a5a66\"},\"title\":\"Lena\",\"subtitle\":\"Hi\",\""
    "time_label\":\"\",\"route\":{\"kind\":\"local\",\"method\":\"lan\",\"label\":\"Nearby\"},\"unread\":"
    "false,\"waiting\":null,\"blocked\":false,\"id_confirmed\":false,\"id_confirmed_label\":null,\"style\""
    ":\"normal\",\"drop_label\":null,\"drop_refusal\":null,\"accessibility_label\":\"Lena\",\"actions\":["
    "],\"found\":null}],\"empty\":null,\"footer\":{}}";

const char szfg_nearby_found[] =
    "{\"query\":\"\",\"visibility\":{\"state\":\"visible\",\"title\":\"You’re visible to people nearby\","
    "\"body\":\"Anyone nearby can see your name and picture and send you a request.\",\"remaining_label\""
    ":\"4:12\",\"remaining_accessibility_label\":\"4 minutes 12 seconds left\",\"deadline\":\"2026-10-12T"
    "06:52:00Z\",\"action\":{\"action\":\"stop_visibility\",\"label\":\"Stop\",\"style\":\"secondary\"}},"
    "\"methods\":[{\"method\":\"network\",\"state\":\"working\",\"label\":\"Looking on your network and o"
    "ver Wi-Fi\"},{\"method\":\"bluetooth\",\"state\":\"radio_off\",\"label\":\"Bluetooth is off\"}],\"al"
    "ert\":null,\"note\":{\"text\":\"Bluetooth is off. People nearby without Wi-Fi won’t appear.\",\"acti"
    "on\":{\"action\":\"open_settings\",\"label\":\"Open Bluetooth settings\",\"style\":\"link\",\"settin"
    "gs_target\":\"bluetooth\"}},\"status\":{\"kind\":\"searching\",\"label\":\"Still looking\"},\"people"
    "\":[{\"nearby_id\":null,\"conversation_id\":\"c_kenji\",\"avatar\":{\"kind\":\"animal\",\"set\":1,\""
    "index\":1,\"initials\":\"KS\",\"color\":\"#2f6474\"},\"title\":\"Kenji Sato\",\"subtitle\":\"On your"
    " network\",\"status_label\":\"Friend\",\"action\":null,\"accessibility_label\":\"Kenji Sato, friend,"
    " on your network\",\"found\":{\"methods\":[\"lan\"],\"label\":\"Local network\"}},{\"nearby_id\":\"n"
    "_7c1e\",\"conversation_id\":null,\"avatar\":{\"kind\":\"animal\",\"set\":1,\"index\":3,\"initials\":"
    "\"LW\",\"color\":\"#7a3f4f\"},\"title\":\"Lena Weber\",\"subtitle\":\"Visible now\",\"status_label\""
    ":null,\"action\":{\"action\":\"send_request\",\"label\":\"Request\",\"style\":\"primary\"},\"accessi"
    "bility_label\":\"Lena Weber, visible now\",\"found\":{\"methods\":[\"bluetooth\"],\"label\":\"Blueto"
    "oth\"}},{\"nearby_id\":\"n_2b90\",\"conversation_id\":\"c_tomas\",\"avatar\":{\"kind\":\"animal\",\""
    "set\":1,\"index\":4,\"initials\":\"TR\",\"color\":\"#4a6a2f\"},\"title\":\"Tomás Rivera\",\"subtitle"
    "\":\"Visible now\",\"status_label\":\"Request sent\",\"action\":null,\"accessibility_label\":\"Tomás"
    " Rivera, request sent\",\"found\":{\"methods\":[\"lan\",\"bluetooth\"],\"label\":\"Local network and"
    " Bluetooth\"}},{\"nearby_id\":\"n_9d44\",\"conversation_id\":null,\"avatar\":{\"kind\":\"animal\",\""
    "set\":1,\"index\":10,\"initials\":\"CL\",\"color\":\"#5a5a66\"},\"title\":\"coral‑lagoon\",\"subtitl"
    "e\":\"No name set\",\"status_label\":null,\"action\":{\"action\":\"send_request\",\"label\":\"Reques"
    "t\",\"style\":\"primary\"},\"accessibility_label\":\"coral‑lagoon, no name set\",\"found\":null}],\""
    "empty\":null,\"footer\":{\"avatar\":{\"kind\":\"animal\",\"set\":1,\"index\":0,\"initials\":\"R\",\""
    "color\":\"#5a4a7a\"},\"name\":\"Raph\",\"name_placeholder\":\"Choose your name\",\"id_label\":\"ID c"
    "ottage‑violet\",\"id_note\":null,\"friends_id\":\"cottage-violet\",\"add_label\":\"Add by ID\"}}";

/* The glyphs shown in the row's found icons, in order. */
static guint shown_glyphs(GtkWidget *row, SZFriendsGtkGlyphKind *kinds) {
    GtkWidget *icons = szfriends_gtk_row_get_part(row, SZFRIENDS_GTK_ROW_PART_FOUND_ICONS);
    guint count = 0;
    for (GtkWidget *glyph = icons ? gtk_widget_get_first_child(icons) : NULL; glyph;
         glyph = gtk_widget_get_next_sibling(glyph))
        if (gtk_widget_get_visible(glyph) && count < 3) kinds[count++] = szfriends_gtk_glyph_get_kind(glyph);
    return count;
}

/* A Nearby row says how in words too (`spelled`); a friend's list row shows the icons alone, the words its tooltip. */
static void expect_found(GtkWidget *row, const char *name, const char *label, SZFriendsGtkGlyphKind first,
                         SZFriendsGtkGlyphKind second, gboolean spelled) {
    SZFriendsGtkGlyphKind kinds[3] = {0};
    guint count = row ? shown_glyphs(row, kinds) : 0;
    GtkWidget *words = row ? szfriends_gtk_row_get_part(row, SZFRIENDS_GTK_ROW_PART_FOUND) : NULL;
    guint want = (first != SZFRIENDS_GTK_GLYPH_NONE) + (second != SZFRIENDS_GTK_GLYPH_NONE);
    gboolean shown = words && gtk_widget_get_visible(gtk_widget_get_parent(words));
    if (!label) {
        EXPECT(row && !shown, "%s: nothing about how they were found while not nearby", name);
        return;
    }
    EXPECT(shown && !g_strcmp0(gtk_label_get_text(GTK_LABEL(words)), label) &&
               !g_strcmp0(gtk_widget_get_tooltip_text(gtk_widget_get_parent(words)), label) &&
               gtk_widget_get_visible(words) == spelled,
           "%s: says \"%s\"%s", name, label, spelled ? "" : " in its tooltip only");
    EXPECT(count == want && kinds[0] == first && (want < 2 || kinds[1] == second),
           "%s: one route icon per method (%u)", name, count);
}

static void test_list_rows(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    guint seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_data(harness->fake, "list", szfg_list_found);
    EXPECT(szfg_list_wait_snapshot(list, seen) && szfg_list_wait_rows(list, 4), "the friends seen nearby arrive");
    expect_found(szfg_list_row(list, "c_mei"), "Mei", "Local network", SZFRIENDS_GTK_GLYPH_ROUTE_LAN,
                 SZFRIENDS_GTK_GLYPH_NONE, FALSE);
    expect_found(szfg_list_row(list, "c_jonas"), "Jonas", "Bluetooth", SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH,
                 SZFRIENDS_GTK_GLYPH_NONE, FALSE);
    expect_found(szfg_list_row(list, "c_kenji"), "Kenji", "Local network and Bluetooth",
                 SZFRIENDS_GTK_GLYPH_ROUTE_LAN, SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH, FALSE);
    expect_found(szfg_list_row(list, "c_lena"), "Lena", NULL, SZFRIENDS_GTK_GLYPH_NONE, SZFRIENDS_GTK_GLYPH_NONE,
                 FALSE);
    /* Rows are reused by position: the next snapshot's people never keep the last one's icons. */
    seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    EXPECT(szfg_list_wait_snapshot(list, seen) && szfg_list_wait_rows(list, 7), "the usual list comes back");
    for (guint i = 0; i < list->parts->rows->len; i++) {
        SZFriendsGtkGlyphKind kinds[3];
        EXPECT(shown_glyphs(g_ptr_array_index(list->parts->rows, i), kinds) == 0 &&
                   !gtk_widget_get_visible(gtk_widget_get_parent(szfriends_gtk_row_get_part(
                       g_ptr_array_index(list->parts->rows, i), SZFRIENDS_GTK_ROW_PART_FOUND))),
               "row %u: no found line without found", i);
    }
    szfg_list_close(list);
}

static gboolean nearby_rows(gpointer data) {
    SZFGList *list = data;
    const SZFriendsGtkNearbyParts *parts = szfriends_gtk_nearby_pane_parts(list->parts->nearby);
    const SZFriendsGtkNearbySnapshot *snapshot = szfriends_gtk_nearby_pane_snapshot(list->parts->nearby);
    return parts && snapshot && snapshot->n_people == 4 && snapshot->people[0].found && parts->rows->len == 4;
}

static void test_nearby_people(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_data(harness->fake, "nearby", szfg_nearby_found);
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    adw_toggle_group_set_active_name(ADW_TOGGLE_GROUP(list->parts->tabs), "nearby");
    EXPECT(szfg_pump_until(nearby_rows, list, 3000), "Nearby arrives with how each person was found");
    const SZFriendsGtkNearbyParts *parts = szfriends_gtk_nearby_pane_parts(list->parts->nearby);
    GPtrArray *rows = parts->rows;
    if (rows->len == 4) {
        expect_found(g_ptr_array_index(rows, 0), "Kenji (a friend)", "Local network", SZFRIENDS_GTK_GLYPH_ROUTE_LAN,
                     SZFRIENDS_GTK_GLYPH_NONE, TRUE);
        expect_found(g_ptr_array_index(rows, 1), "Lena", "Bluetooth", SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH,
                     SZFRIENDS_GTK_GLYPH_NONE, TRUE);
        expect_found(g_ptr_array_index(rows, 2), "Tomás", "Local network and Bluetooth",
                     SZFRIENDS_GTK_GLYPH_ROUTE_LAN, SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH, TRUE);
        expect_found(g_ptr_array_index(rows, 3), "coral-lagoon", NULL, SZFRIENDS_GTK_GLYPH_NONE,
                     SZFRIENDS_GTK_GLYPH_NONE, TRUE);
    }
    szfriends_fake_helper_set_view_fixture(harness->fake, "nearby", "nearby-visible-bluetooth-off.json");
    szfg_list_close(list);
}

void szfg_run_list_found_probes(SZFGHarness *harness) {
    test_list_rows(harness);
    test_nearby_people(harness);
}
