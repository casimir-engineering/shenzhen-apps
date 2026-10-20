/* The list across a live switch of appearance: opened in light, switched to dark while open (and back), it must
 * match a list opened fresh in the new theme. The glyphs drawn in their inherited colour are checked one by one: the
 * footer's pencil and copy marks and a request's Decline kept their light ink on the dark page until the glyph
 * redrew on a style change (UX verification, wave 6c). */

#include "szfriends_gtk_list_probe.h"

#include "gtk/szfriends_gtk_glyphs.h"

typedef struct {
    SZFGList *list;
    GtkWidget *window;
} SZFGShown;

static SZFGShown shown_open(SZFGHarness *harness) {
    SZFGShown shown = {szfg_list_open(harness), NULL};
    EXPECT(szfg_list_wait_rows(shown.list, 7), "the fixture's rows arrive");
    shown.window = szfg_probe_window(szfriends_gtk_dropdown_get_content(shown.list->dropdown));
    return shown;
}

static void shown_close(SZFGShown *shown) {
    GtkWidget *content = szfriends_gtk_dropdown_get_content(shown->list->dropdown);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(shown->window), NULL);
    gtk_window_destroy(GTK_WINDOW(shown->window));
    g_object_unref(content);
    szfg_list_close(shown->list);
}

/* The first glyph of `kind` under `widget`, depth first. */
static GtkWidget *glyph_of(GtkWidget *widget, SZFriendsGtkGlyphKind kind) {
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        if (gtk_widget_get_visible(child) && szfriends_gtk_glyph_get_kind(child) == kind) return child;
        GtkWidget *found = glyph_of(child, kind);
        if (found) return found;
    }
    return NULL;
}

/* Render pixels (scale 2) inside `kind`'s glyph, the first under `conversation_id`'s row (or anywhere for NULL),
 * that differ between two renders of the same list. */
static int glyph_differs(SZFGShown *shown, const char *conversation_id, SZFriendsGtkGlyphKind kind, GdkTexture *a,
                         GdkTexture *b) {
    GtkWidget *content = szfriends_gtk_dropdown_get_content(shown->list->dropdown);
    GtkWidget *root = conversation_id ? szfg_list_row(shown->list, conversation_id) : content;
    GtkWidget *glyph = root ? glyph_of(root, kind) : NULL;
    graphene_rect_t box;
    if (!glyph || !gtk_widget_compute_bounds(glyph, content, &box)) return -1;
    SZFGPixels pa = szfg_pixels(a), pb = szfg_pixels(b);
    int differing = 0;
    for (int y = (int)box.origin.y * 2; y < (int)(box.origin.y + box.size.height) * 2 && y < pa.height; y++)
        for (int x = (int)box.origin.x * 2; x < (int)(box.origin.x + box.size.width) * 2 && x < pa.width; x++) {
            const guint8 *p = szfg_pixel(&pa, x, y), *q = szfg_pixel(&pb, x, y);
            if (ABS(p[0] - q[0]) + ABS(p[1] - q[1]) + ABS(p[2] - q[2]) > 24) differing++;
        }
    szfg_pixels_free(&pa);
    szfg_pixels_free(&pb);
    return differing;
}

static int all_differ(GdkTexture *a, GdkTexture *b) {
    SZFGPixels pa = szfg_pixels(a), pb = szfg_pixels(b);
    int differing = pa.width == pb.width && pa.height == pb.height ? 0 : -1;
    for (int y = 0; differing >= 0 && y < pa.height; y++)
        for (int x = 0; x < pa.width; x++) {
            const guint8 *p = szfg_pixel(&pa, x, y), *q = szfg_pixel(&pb, x, y);
            if (ABS(p[0] - q[0]) + ABS(p[1] - q[1]) + ABS(p[2] - q[2]) > 24) differing++;
        }
    szfg_pixels_free(&pa);
    szfg_pixels_free(&pb);
    return differing;
}

static void switch_live(SZFGHarness *harness, gboolean to_dark) {
    const char *theme = to_dark ? "dark" : "light";
    szfg_set_dark(!to_dark);
    SZFGShown live = shown_open(harness);
    char *name = g_strdup_printf("list-live-before-%s", theme);
    g_object_unref(szfg_render(live.window, 400, 640, name));
    g_free(name);
    szfg_set_dark(to_dark);
    /* What GTK does on the next frame after a style change: the probe window is never shown, so its frame clock never
     * runs, and emitting its update phase is that frame (as the conversation's look probe does). */
    GdkFrameClock *clock = gtk_widget_get_frame_clock(live.window);
    EXPECT(clock != NULL, "the probe window has a frame clock to emulate");
    if (clock) g_signal_emit_by_name(clock, "update");
    szfg_pump_for(50);
    name = g_strdup_printf("list-live-%s", theme);
    GdkTexture *after = szfg_render(live.window, 400, 640, name);
    g_free(name);
    SZFGShown fresh = shown_open(harness);
    name = g_strdup_printf("list-fresh-%s", theme);
    GdkTexture *expected = szfg_render(fresh.window, 400, 640, name);
    g_free(name);
    static const struct {
        const char *row;
        SZFriendsGtkGlyphKind kind;
        const char *what;
    } glyphs[] = {{NULL, SZFRIENDS_GTK_GLYPH_PENCIL, "the footer's pencil"},
                  {NULL, SZFRIENDS_GTK_GLYPH_COPY, "the footer's copy mark"},
                  {"c_lena", SZFRIENDS_GTK_GLYPH_BLOCK, "Lena's Block"}};
    for (gsize i = 0; i < G_N_ELEMENTS(glyphs); i++) {
        int differing = glyph_differs(&live, glyphs[i].row, glyphs[i].kind, after, expected);
        EXPECT(differing == 0, "after a live switch to %s, %s draws as on a fresh %s list (%d px differ)", theme,
               glyphs[i].what, theme, differing);
    }
    int differing = all_differ(after, expected);
    EXPECT(differing == 0, "the whole list after a live switch to %s matches a fresh one (%d px differ)", theme,
           differing);
    g_object_unref(after);
    g_object_unref(expected);
    shown_close(&fresh);
    shown_close(&live);
}

void szfg_run_list_live_probes(SZFGHarness *harness) {
    switch_live(harness, TRUE);
    switch_live(harness, FALSE);
    szfg_set_dark(FALSE);
}
