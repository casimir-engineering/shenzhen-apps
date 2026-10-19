/* The route icons (szfriends_gtk_glyphs.h): one per connection method, so the person can tell at a glance how a
 * friend is connected (the owner's request: local Wi-Fi, direct Wi-Fi, Bluetooth, online peer to peer, the relay).
 * Each method picks its own glyph, the six glyphs differ from one another, and each matches the shape AppKit draws
 * (szfriends_gtk_route_cells.h, which the AppKit suite checks too). Renders of all six side by side, at 1x and 2x in
 * light and dark, land in the renders directory for review. */

#include "szfriends_gtk_probe.h"
#include "szfriends_gtk_route_cells.h"

#include "gtk/szfriends_gtk_glyphs.h"

#include <math.h>
#include <string.h>

#define SIDE SZFRIENDS_ROUTE_CELLS_SIDE

static const struct {
    const char *name;            /* the method, as the cells table names it */
    SZFriendsGtkGlyphKind glyph;
    const char *color;           /* the route colour of its kind */
} routes[SZFRIENDS_ROUTE_CELLS_COUNT] = {
    {"lan", SZFRIENDS_GTK_GLYPH_ROUTE_LAN, "local"},
    {"p2p_wifi", SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI, "local"},
    {"bluetooth", SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH, "local"},
    {"internet", SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET, "online"},
    {"relay", SZFRIENDS_GTK_GLYPH_ROUTE_RELAY, "online"},
    {"offline", SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE, "offline"},
};

/* The method picks the icon when the helper names one; the kind only when it does not (or names one unknown here). */
static void test_glyph_choice(void) {
    static const struct {
        SZFriendsGtkRouteKind kind;
        SZFriendsGtkRouteMethod method;
        SZFriendsGtkGlyphKind expected;
    } cases[] = {
        {SZFRIENDS_GTK_ROUTE_LOCAL, SZFRIENDS_GTK_METHOD_LAN, SZFRIENDS_GTK_GLYPH_ROUTE_LAN},
        {SZFRIENDS_GTK_ROUTE_LOCAL, SZFRIENDS_GTK_METHOD_P2P_WIFI, SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI},
        {SZFRIENDS_GTK_ROUTE_LOCAL, SZFRIENDS_GTK_METHOD_BLUETOOTH, SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH},
        {SZFRIENDS_GTK_ROUTE_ONLINE, SZFRIENDS_GTK_METHOD_INTERNET, SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET},
        {SZFRIENDS_GTK_ROUTE_ONLINE, SZFRIENDS_GTK_METHOD_RELAY, SZFRIENDS_GTK_GLYPH_ROUTE_RELAY},
        {SZFRIENDS_GTK_ROUTE_LOCAL, SZFRIENDS_GTK_METHOD_UNSET, SZFRIENDS_GTK_GLYPH_ROUTE_LAN},
        {SZFRIENDS_GTK_ROUTE_ONLINE, SZFRIENDS_GTK_METHOD_UNSET, SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET},
        {SZFRIENDS_GTK_ROUTE_OFFLINE, SZFRIENDS_GTK_METHOD_UNSET, SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE},
        {SZFRIENDS_GTK_ROUTE_OFFLINE, SZFRIENDS_GTK_METHOD_LAN, SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE},
        {SZFRIENDS_GTK_ROUTE_NONE, SZFRIENDS_GTK_METHOD_UNSET, SZFRIENDS_GTK_GLYPH_NONE},
        {SZFRIENDS_GTK_ROUTE_UNKNOWN, SZFRIENDS_GTK_METHOD_RELAY, SZFRIENDS_GTK_GLYPH_NONE},
        /* An online attempt still connecting: the globe (styles draw it in the offline colour). */
        {SZFRIENDS_GTK_ROUTE_CONNECTING, SZFRIENDS_GTK_METHOD_UNSET, SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET},
    };
    for (gsize i = 0; i < G_N_ELEMENTS(cases); i++)
        EXPECT(szfriends_gtk_route_glyph(cases[i].kind, cases[i].method) == cases[i].expected,
               "route %d with method %d draws glyph %d", cases[i].kind, cases[i].method, cases[i].expected);
}

/* Coverage of each 4 x 4 px cell of a 48 px render over white (12 units at 4 px), 0 to 1, from its darkness. */
static void coverage(GdkTexture *texture, double cells[SIDE][SIDE]) {
    SZFGPixels pixels = szfg_pixels(texture);
    EXPECT(pixels.width == 4 * SIDE && pixels.height == 4 * SIDE, "a 48 px render (%d x %d)", pixels.width,
           pixels.height);
    for (int cy = 0; cy < SIDE; cy++)
        for (int cx = 0; cx < SIDE; cx++) {
            double sum = 0;
            for (int y = 0; y < 4 && pixels.width == 4 * SIDE; y++)
                for (int x = 0; x < 4; x++) {
                    const guint8 *p = szfg_pixel(&pixels, cx * 4 + x, cy * 4 + y);
                    sum += 1 - (p[0] + p[1] + p[2]) / (3 * 255.0);
                }
            cells[cy][cx] = sum / 16;
        }
    szfg_pixels_free(&pixels);
}

/* Each glyph drawn black at 24 pt and scale 2 (48 px, AppKit's matched scale) against the shared table: inked where
 * the AppKit drawing inks, clear where it is clear. On a mismatch, prints the cells GTK drew. */
static void test_shapes(double cells[SZFRIENDS_ROUTE_CELLS_COUNT][SIDE][SIDE]) {
    szfg_set_dark(FALSE);
    GtkCssProvider *black = gtk_css_provider_new();
    gtk_css_provider_load_from_string(black, ".szfg-route-black { color: #000000; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(black),
                                               GTK_STYLE_PROVIDER_PRIORITY_USER);
    for (int i = 0; i < SZFRIENDS_ROUTE_CELLS_COUNT; i++) {
        const SZFriendsRouteCells *shape = &szfriends_route_cells[i];
        EXPECT(!strcmp(shape->glyph, routes[i].name), "the table's order: %s", shape->glyph);
        GtkWidget *glyph = szfriends_gtk_glyph_new(routes[i].glyph, 24);
        gtk_widget_add_css_class(glyph, "szfg-route-black");
        GtkWidget *window = szfg_probe_window(glyph);
        char *name = g_strdup_printf("route-cells-%s", routes[i].name);
        GdkTexture *texture = szfg_render(window, 24, 24, name);
        coverage(texture, cells[i]);
        int wrong = 0;
        for (int y = 0; y < SIDE; y++)
            for (int x = 0; x < SIDE; x++) {
                char expected = shape->rows[y][x];
                double got = cells[i][y][x];
                if ((expected == '#' && got < 0.25) || (expected == '.' && got > 0.1)) wrong++;
            }
        EXPECT(wrong == 0, "%s: GTK draws AppKit's shape (%d cells differ)", routes[i].name, wrong);
        for (int y = 0; wrong && y < SIDE; y++) {
            fprintf(stderr, "  %s  \"", shape->rows[y]);
            for (int x = 0; x < SIDE; x++)
                fputc(cells[i][y][x] >= 0.45 ? '#' : cells[i][y][x] <= 0.02 ? '.' : '+', stderr);
            fprintf(stderr, "\" (AppKit, then GTK)\n");
        }
        g_free(name);
        g_object_unref(texture);
        gtk_window_destroy(GTK_WINDOW(window));
    }
    gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(black));
    g_object_unref(black);
}

/* Told apart at a glance: every pair differs clearly (ink in one, nothing in the other) in at least eight cells. */
static void test_distinct(double cells[SZFRIENDS_ROUTE_CELLS_COUNT][SIDE][SIDE]) {
    for (int a = 0; a < SZFRIENDS_ROUTE_CELLS_COUNT; a++)
        for (int b = a + 1; b < SZFRIENDS_ROUTE_CELLS_COUNT; b++) {
            int differing = 0;
            for (int y = 0; y < SIDE; y++)
                for (int x = 0; x < SIDE; x++) differing += fabs(cells[a][y][x] - cells[b][y][x]) > 0.4;
            EXPECT(differing >= 8, "%s and %s differ in %d cells", routes[a].name, routes[b].name, differing);
        }
}

/* All six side by side in their route colours on the dropdown's background, as rows show them, at 1x and 2x. */
static void render_row_of_icons(void) {
    GtkCssProvider *colors = gtk_css_provider_new();
    gtk_css_provider_load_from_string(colors, ".szfg-routes { background-color: @szfriends_background;"
                                              " padding: 6px 8px; }\n"
                                              ".szfg-route-local { color: @szfriends_local_route; }\n"
                                              ".szfg-route-online { color: @szfriends_online_route; }\n"
                                              ".szfg-route-offline { color: @szfriends_offline_route; }\n");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(colors),
                                               GTK_STYLE_PROVIDER_PRIORITY_USER);
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        for (int scale = 1; scale <= 2; scale++) {
            GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
            gtk_widget_add_css_class(box, "szfg-routes");
            for (int i = 0; i < SZFRIENDS_ROUTE_CELLS_COUNT; i++) {
                GtkWidget *glyph = szfriends_gtk_glyph_new(routes[i].glyph, 12);
                char *color = g_strdup_printf("szfg-route-%s", routes[i].color);
                gtk_widget_add_css_class(glyph, color);
                gtk_box_append(GTK_BOX(box), glyph);
                g_free(color);
            }
            /* Wrapped: the render measures its root's content box, which leaves the root's own padding out. */
            GtkWidget *root = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_box_append(GTK_BOX(root), box);
            GtkWidget *window = szfg_probe_window(root);
            char *name = g_strdup_printf("route-icons-%s%s", dark ? "dark" : "light", scale == 1 ? "@1x" : "");
            g_object_unref(szfg_render_at(window, 6 * 12 + 5 * 10 + 16, -1, scale, name));
            g_free(name);
            gtk_window_destroy(GTK_WINDOW(window));
        }
    }
    szfg_set_dark(FALSE);
    gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(colors));
    g_object_unref(colors);
}

void szfg_run_route_probes(void) {
    test_glyph_choice();
    static double cells[SZFRIENDS_ROUTE_CELLS_COUNT][SIDE][SIDE];
    test_shapes(cells);
    test_distinct(cells);
    render_row_of_icons();
}
