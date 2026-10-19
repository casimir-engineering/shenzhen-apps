/* The two-people icon: loaded by name from the views' resource, recoloured like any symbolic icon, and the same
 * picture as the AppKit icon: the probe strokes SZFriendsDrawPeopleIcon's paths (mac/SZFriendsIcons.m) with GSK and
 * compares the two renders pixel by pixel. */

#include "szfriends_gtk_probe.h"

#include <string.h>

/* SZFriendsDrawPeopleIcon in its 16-unit box: two heads, two shoulders, width 1.3, round caps and joins. */
static GskPath *appkit_people_path(void) {
    GskPathBuilder *builder = gsk_path_builder_new();
    gsk_path_builder_add_circle(builder, &GRAPHENE_POINT_INIT(6, 5.5f), 2.5f);
    gsk_path_builder_move_to(builder, 1.5f, 13.5f);
    gsk_path_builder_cubic_to(builder, 1.5f, 11, 3.5f, 9.5f, 6, 9.5f);
    gsk_path_builder_cubic_to(builder, 8.5f, 9.5f, 10.5f, 11, 10.5f, 13.5f);
    gsk_path_builder_add_circle(builder, &GRAPHENE_POINT_INIT(11.2f, 5), 2);
    gsk_path_builder_move_to(builder, 11.2f, 9.4f);
    gsk_path_builder_cubic_to(builder, 13.2f, 9.5f, 14.6f, 10.9f, 14.6f, 13);
    return gsk_path_builder_free_to_path(builder);
}

/* Darkness of each pixel (0 white, 255 black), the measure both renders share. */
static double darkness(const SZFGPixels *pixels, int x, int y) {
    const guint8 *p = szfg_pixel(pixels, x, y);
    return 255.0 - (p[0] + p[1] + p[2]) / 3.0;
}

static GdkTexture *render_node(GskRenderNode *node, int side) {
    GskRenderer *renderer = gsk_cairo_renderer_new();
    gsk_renderer_realize_for_display(renderer, gdk_display_get_default(), NULL);
    GdkTexture *texture = gsk_renderer_render_texture(renderer, node, &GRAPHENE_RECT_INIT(0, 0, side, side));
    gsk_renderer_unrealize(renderer);
    g_object_unref(renderer);
    return texture;
}

static void test_icon_matches_appkit_paths(void) {
    szfg_set_dark(FALSE);
    GtkCssProvider *black = gtk_css_provider_new();
    gtk_css_provider_load_from_string(black, ".szfg-icon { color: #000000; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(black),
                                               GTK_STYLE_PROVIDER_PRIORITY_USER);
    GtkWidget *image = gtk_image_new_from_icon_name(SZFRIENDS_GTK_ICON_PEOPLE);
    gtk_image_set_pixel_size(GTK_IMAGE(image), 32);
    gtk_widget_add_css_class(image, "szfg-icon");
    GtkWidget *window = szfg_probe_window(image);
    GdkTexture *icon = szfg_render(window, 32, 32, "icon-people-64px");
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gtk_snapshot_append_color(snapshot, &(GdkRGBA){1, 1, 1, 1}, &GRAPHENE_RECT_INIT(0, 0, 64, 64));
    gtk_snapshot_scale(snapshot, 4, 4);
    GskPath *path = appkit_people_path();
    GskStroke *stroke = gsk_stroke_new(1.3f);
    gsk_stroke_set_line_cap(stroke, GSK_LINE_CAP_ROUND);
    gsk_stroke_set_line_join(stroke, GSK_LINE_JOIN_ROUND);
    gtk_snapshot_append_stroke(snapshot, path, stroke, &(GdkRGBA){0, 0, 0, 1});
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    GdkTexture *appkit = render_node(node, 64);
    char *file = g_strdup_printf("%s/icon-appkit-paths-64px.png", szfg_renders);
    gdk_texture_save_to_png(appkit, file);
    g_free(file);
    SZFGPixels a = szfg_pixels(icon), b = szfg_pixels(appkit);
    EXPECT(a.width == 64 && b.width == 64, "both renders are 64 px");
    double both = 0, either = 0;
    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 64; x++) {
            double p = darkness(&a, x, y), q = darkness(&b, x, y);
            both += MIN(p, q);
            either += MAX(p, q);
        }
    double overlap = either > 0 ? both / either : 0;
    EXPECT(overlap > 0.93, "the GTK icon is the AppKit icon's picture (overlap %.3f)", overlap);
    EXPECT(either > 64 * 64 * 255 * 0.15, "the icon is drawn at all");
    szfg_pixels_free(&a);
    szfg_pixels_free(&b);
    g_object_unref(icon);
    g_object_unref(appkit);
    gsk_render_node_unref(node);
    gsk_path_unref(path);
    gsk_stroke_free(stroke);
    gtk_window_destroy(GTK_WINDOW(window));
    gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(black));
    g_object_unref(black);
}

/* A symbolic icon takes the colour around it, so it reads in light and dark like the host's other icons. */
static void test_icon_is_symbolic(void) {
    GtkCssProvider *red = gtk_css_provider_new();
    gtk_css_provider_load_from_string(red, ".szfg-red { color: #ff0000; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(red),
                                               GTK_STYLE_PROVIDER_PRIORITY_USER);
    GtkWidget *image = gtk_image_new_from_icon_name(SZFRIENDS_GTK_ICON_PEOPLE);
    gtk_image_set_pixel_size(GTK_IMAGE(image), 32);
    gtk_widget_add_css_class(image, "szfg-red");
    GtkWidget *window = szfg_probe_window(image);
    GdkTexture *texture = szfg_render(window, 32, 32, "icon-people-recoloured");
    SZFGPixels pixels = szfg_pixels(texture);
    int red_pixels = 0, other = 0;
    for (int y = 0; y < pixels.height; y++)
        for (int x = 0; x < pixels.width; x++) {
            const guint8 *p = szfg_pixel(&pixels, x, y);
            if (p[0] > 200 && p[1] < 60 && p[2] < 60) red_pixels++;
            else if (p[0] < 200) other++; /* red over white keeps full red: anything else is another colour */
        }
    EXPECT(red_pixels > 200, "the icon is drawn in the surrounding colour (%d red pixels)", red_pixels);
    EXPECT(other < red_pixels / 4, "and only in it (%d other)", other);
    szfg_pixels_free(&pixels);
    g_object_unref(texture);
    gtk_window_destroy(GTK_WINDOW(window));
    gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(red));
    g_object_unref(red);
}

void szfg_run_icon_probes(void) {
    /* The views install their resource, icon path and stylesheet on first use, as a button would. */
    SZFriendsGtkHost host = {.struct_size = sizeof host};
    szfriends_gtk_style_ensure(gdk_display_get_default(), &host);
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    EXPECT(gtk_icon_theme_has_icon(theme, SZFRIENDS_GTK_ICON_PEOPLE), "the icon theme finds the two-people icon");
    test_icon_matches_appkit_paths();
    test_icon_is_symbolic();
}
