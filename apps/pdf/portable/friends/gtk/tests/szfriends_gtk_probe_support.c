/* Offscreen rendering for the probes (szfriends_gtk_probe.h).
 *
 * A widget needs a root for its style and a mapped parent chain to be snapshotted, so it sits in a GtkWindow that is
 * realized (a surface exists) but never mapped or presented, and the probe maps the window's child itself. The
 * renderer is realized for the display, not for a surface. */

#include "szfriends_gtk_probe.h"

const char *szfg_renders;
const char *szfg_manifest;

GtkWidget *szfg_probe_window(GtkWidget *child) {
    GtkWidget *window = gtk_window_new();
    gtk_window_set_child(GTK_WINDOW(window), child);
    gtk_widget_realize(window);
    return window;
}

void szfg_set_dark(gboolean dark) {
    adw_style_manager_set_color_scheme(adw_style_manager_get_default(),
                                       dark ? ADW_COLOR_SCHEME_FORCE_DARK : ADW_COLOR_SCHEME_FORCE_LIGHT);
    szfg_pump_for(30); /* style changes settle on the main loop */
}

void szfg_layout(GtkWidget *window, int width, int height) {
    GtkWidget *child = gtk_window_get_child(GTK_WINDOW(window));
    if (!gtk_widget_get_mapped(child)) gtk_widget_map(child);
    int minimum = 0, natural = 0;
    gtk_widget_measure(child, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, NULL, NULL);
    gtk_widget_allocate(child, width, height > 0 ? MAX(height, minimum) : natural, -1, NULL);
}

static GskRenderer *renderer(void) {
    static GskRenderer *shared;
    if (shared) return shared;
    GError *error = NULL;
    shared = gsk_gl_renderer_new();
    if (!gsk_renderer_realize_for_display(shared, gdk_display_get_default(), &error)) {
        /* Cairo draws the same nodes without a GPU context, e.g. under a remote session. */
        g_clear_error(&error);
        g_object_unref(shared);
        shared = gsk_cairo_renderer_new();
        gsk_renderer_realize_for_display(shared, gdk_display_get_default(), &error);
    }
    EXPECT(error == NULL, "a renderer realized for the display: %s", error ? error->message : "");
    g_clear_error(&error);
    return shared;
}

GdkTexture *szfg_render(GtkWidget *window, int width, int height, const char *name) {
    return szfg_render_at(window, width, height, 2, name);
}

GdkTexture *szfg_render_at(GtkWidget *window, int width, int height, int scale, const char *name) {
    GtkWidget *child = gtk_window_get_child(GTK_WINDOW(window));
    szfg_layout(window, width, height);
    int h = gtk_widget_get_height(child);
    EXPECT(!gtk_widget_get_mapped(window), "%s: the window itself is never mapped", name);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gtk_snapshot_scale(snapshot, (float)scale, (float)scale);
    GdkRGBA background = {1, 1, 1, 1};
    gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    if (dark) background = (GdkRGBA){0.14f, 0.14f, 0.15f, 1};
    gtk_snapshot_append_color(snapshot, &background, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)h));
    gtk_widget_snapshot_child(window, child, snapshot);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    GdkTexture *texture = gsk_renderer_render_texture(renderer(), node,
                                                      &GRAPHENE_RECT_INIT(0, 0, (float)(width * scale),
                                                                          (float)(h * scale)));
    gsk_render_node_unref(node);
    char *file = g_strdup_printf("%s/%s.png", szfg_renders, name);
    EXPECT(gdk_texture_save_to_png(texture, file), "%s written", file);
    g_free(file);
    return texture;
}

SZFGPixels szfg_pixels(GdkTexture *texture) {
    SZFGPixels pixels = {gdk_texture_get_width(texture), gdk_texture_get_height(texture), 0, NULL};
    GdkTextureDownloader *downloader = gdk_texture_downloader_new(texture);
    gdk_texture_downloader_set_format(downloader, GDK_MEMORY_R8G8B8A8);
    pixels.bytes = gdk_texture_downloader_download_bytes(downloader, &pixels.stride);
    gdk_texture_downloader_free(downloader);
    return pixels;
}

void szfg_pixels_free(SZFGPixels *pixels) {
    g_bytes_unref(pixels->bytes);
}

const guint8 *szfg_pixel(const SZFGPixels *pixels, int x, int y) {
    x = CLAMP(x, 0, pixels->width - 1);
    y = CLAMP(y, 0, pixels->height - 1);
    return (const guint8 *)g_bytes_get_data(pixels->bytes, NULL) + (gsize)y * pixels->stride + (gsize)x * 4;
}

int szfg_count_differing(const SZFGPixels *pixels, int x, int y, int width, int height, const guint8 *background,
                         int tolerance) {
    int count = 0;
    for (int j = MAX(y, 0); j < MIN(y + height, pixels->height); j++)
        for (int i = MAX(x, 0); i < MIN(x + width, pixels->width); i++) {
            const guint8 *p = szfg_pixel(pixels, i, j);
            int d = ABS(p[0] - background[0]) + ABS(p[1] - background[1]) + ABS(p[2] - background[2]);
            if (d > tolerance) count++;
        }
    return count;
}

SZFGHarness *szfg_probe_harness(const char *label) {
    SZFGHarness *harness = szfg_harness_new(label, TRUE);
    szfg_harness_ready(harness, 5000);
    return harness;
}
