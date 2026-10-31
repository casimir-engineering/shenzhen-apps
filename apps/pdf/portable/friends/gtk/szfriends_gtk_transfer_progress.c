/* Shenzhen Friends GTK views: a moving transfer's progress by route (PROTOCOL.md § Fast transfers, Progress by
 * route), the route icons beside its card's name and the 8 px bar split by what each route carried. The glyphs are
 * the approved mockup's 16-unit SVG paths, read by GSK, and its colours, so the AppKit views
 * (mac/SZFriendsTransferProgress.m) and Shenzhen 3D (apps/3d/src/friends/TransferProgress.tsx) draw the same ones.
 * Route colours are the same in light and dark and never grey or red, which say "not working". */

#include "gtk/szfriends_gtk_conversation.h"

#include <adwaita.h>
#include <math.h>

typedef struct {
    const char *name;
    guint32 rgb;
} SZFriendsGtkRouteColor;

/* Indexed by SZFriendsGtkRouteMethod (szfriends_gtk_schema_names.h: none, lan, p2p_wifi, bluetooth, internet, relay). */
static const SZFriendsGtkRouteColor route_colors[] = {
    {"relay", 0x3983f7}, {"lan", 0x22a35a}, {"p2p_wifi", 0x0ea5b0}, {"bluetooth", 0xf59e0b}, {"internet", 0x8b5cf6},
    {"relay", 0x3983f7},
};

static void set_rgb(cairo_t *cr, guint32 rgb, double alpha) {
    cairo_set_source_rgba(cr, ((rgb >> 16) & 0xff) / 255.0, ((rgb >> 8) & 0xff) / 255.0, (rgb & 0xff) / 255.0, alpha);
}

static guint32 route_rgb(SZFriendsGtkRouteMethod method) {
    return (guint)method < G_N_ELEMENTS(route_colors) ? route_colors[method].rgb : 0x3983f7;
}

static void stroke_svg(cairo_t *cr, const char *data) {
    GskPath *path = gsk_path_parse(data);
    if (!path) return;
    cairo_new_path(cr);
    gsk_path_to_cairo(path, cr);
    gsk_path_unref(path);
    cairo_stroke(cr);
}

static void dot(cairo_t *cr, double cx, double cy, double r) {
    cairo_new_path(cr);
    cairo_arc(cr, cx, cy, r, 0, 2 * G_PI);
    cairo_fill(cr);
}

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
    cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

/* The mockup's glyph in the current source colour, in a 16 x 16 box at the origin. */
static void draw_glyph(cairo_t *cr, SZFriendsGtkRouteMethod method) {
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    switch (method) {
    case SZFRIENDS_GTK_METHOD_LAN:
        cairo_set_line_width(cr, 1.7);
        stroke_svg(cr, "M1.8 6.2a9 9 0 0 1 12.4 0");
        stroke_svg(cr, "M4.1 8.7a5.7 5.7 0 0 1 7.8 0");
        stroke_svg(cr, "M6.4 11.1a2.4 2.4 0 0 1 3.2 0");
        dot(cr, 8, 13.2, 0.9);
        break;
    case SZFRIENDS_GTK_METHOD_P2P_WIFI:
        cairo_set_line_width(cr, 1.4);
        cairo_new_path(cr);
        rounded_rect(cr, 1.4, 8.2, 3.6, 6.2, 0.9);
        rounded_rect(cr, 11, 8.2, 3.6, 6.2, 0.9);
        cairo_stroke(cr);
        stroke_svg(cr, "M4.6 5.2a4.8 4.8 0 0 1 6.8 0");
        stroke_svg(cr, "M6.2 7a2.5 2.5 0 0 1 3.6 0");
        dot(cr, 8, 8.6, 0.75);
        break;
    case SZFRIENDS_GTK_METHOD_INTERNET: {
        cairo_set_line_width(cr, 1.2);
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT);
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER);
        cairo_new_path(cr);
        cairo_arc(cr, 8, 5.4, 4.4, 0, 2 * G_PI);
        cairo_stroke(cr);
        stroke_svg(cr, "M3.6 5.4h8.8M8 1c1.6 1.6 1.6 7.2 0 8.8M8 1c-1.6 1.6-1.6 7.2 0 8.8");
        /* "P2P" under the globe: 5.6 units, heavy, centred on x 8 with its baseline at y 15.6. */
        PangoLayout *layout = pango_cairo_create_layout(cr);
        PangoFontDescription *font = pango_font_description_from_string("Sans Heavy");
        pango_font_description_set_absolute_size(font, 5.6 * PANGO_SCALE);
        pango_layout_set_font_description(layout, font);
        PangoAttrList *attributes = pango_attr_list_new();
        pango_attr_list_insert(attributes, pango_attr_letter_spacing_new((int)(0.2 * PANGO_SCALE)));
        pango_layout_set_attributes(layout, attributes);
        pango_layout_set_text(layout, "P2P", -1);
        PangoRectangle ink, logical;
        pango_layout_get_extents(layout, &ink, &logical);
        double baseline = pango_layout_get_baseline(layout) / (double)PANGO_SCALE;
        cairo_move_to(cr, 8 - logical.width / (2.0 * PANGO_SCALE), 15.6 - baseline);
        pango_cairo_show_layout(cr, layout);
        pango_attr_list_unref(attributes);
        pango_font_description_free(font);
        g_object_unref(layout);
        break;
    }
    case SZFRIENDS_GTK_METHOD_BLUETOOTH:
        cairo_set_line_width(cr, 1.7);
        stroke_svg(cr, "M4.6 5.2 11.2 10.8 8 13.6V2.4l3.2 2.8-6.6 5.6");
        break;
    default:
        cairo_set_line_width(cr, 1.5);
        stroke_svg(cr, "M4.6 12.4h7a2.8 2.8 0 0 0 .4-5.6 4 4 0 0 0-7.7.9 2.4 2.4 0 0 0 .3 4.7Z");
        break;
    }
}

typedef struct {
    SZFriendsGtkRouteMethod method;
    gboolean active;
} SZFriendsGtkRouteIcon;

static void draw_route_icon(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    const SZFriendsGtkRouteIcon *icon = data;
    gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    double side = MIN(width, height), radius = side * 6 / 24;
    if (icon->active) {
        rounded_rect(cr, 0, 0, side, side, radius);
        set_rgb(cr, route_rgb(icon->method), 1);
        cairo_fill(cr);
        cairo_set_source_rgb(cr, 1, 1, 1);
    } else {
        /* Used earlier, not now: an outline, the glyph in the quiet text colour. */
        rounded_rect(cr, 0.5, 0.5, side - 1, side - 1, radius - 0.5);
        set_rgb(cr, dark ? 0x4a4a4a : 0xc4c4c4, 1);
        cairo_set_line_width(cr, 1);
        cairo_stroke(cr);
        set_rgb(cr, 0x8a8a8a, 1);
    }
    double glyph = side * 16 / 24;
    cairo_translate(cr, (side - glyph) / 2, (side - glyph) / 2);
    cairo_scale(cr, glyph / 16, glyph / 16);
    draw_glyph(cr, icon->method);
}

GtkWidget *szfriends_gtk_transfer_routes_new(const SZFriendsGtkProgress *progress) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_set_name(box, "szfriends.transfer.routes");
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    for (gsize i = 0; progress && i < progress->n_routes; i++) {
        const SZFriendsGtkTransferRoute *route = &progress->routes[i];
        SZFriendsGtkRouteIcon *icon = g_new0(SZFriendsGtkRouteIcon, 1);
        icon->method = route->method;
        icon->active = route->active;
        GtkWidget *area = g_object_new(GTK_TYPE_DRAWING_AREA, "accessible-role", GTK_ACCESSIBLE_ROLE_IMG, NULL);
        gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), 24);
        gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), 24);
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw_route_icon, icon, g_free);
        if (route->label && *route->label) {
            gtk_widget_set_tooltip_text(area, route->label);
            gtk_accessible_update_property(GTK_ACCESSIBLE(area), GTK_ACCESSIBLE_PROPERTY_LABEL, route->label, -1);
        }
        gtk_box_append(GTK_BOX(box), area);
    }
    gtk_widget_set_visible(box, progress && progress->n_routes > 0);
    return box;
}

/* ---- The split bar ------------------------------------------------------------------------------- */

typedef struct {
    double fraction;
    gboolean determinate, finishing;
    SZFriendsGtkTransferSegment *segments;
    gsize n_segments;
    gint64 start;
} SZFriendsGtkSplitBar;

static void split_bar_free(gpointer data) {
    SZFriendsGtkSplitBar *bar = data;
    g_free(bar->segments);
    g_free(bar);
}

static gboolean animations_enabled(GtkWidget *widget) {
    gboolean enabled = TRUE;
    g_object_get(gtk_widget_get_settings(widget), "gtk-enable-animations", &enabled, NULL);
    return enabled;
}

static void draw_split_bar(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    const SZFriendsGtkSplitBar *bar = data;
    gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    rounded_rect(cr, 0, 0, width, height, height / 2.0);
    /* On the card's own fill: a step darker (lighter in dark) than it, so the empty part reads as a track. */
    set_rgb(cr, dark ? 0x4a4a4a : 0xdadada, 1);
    cairo_fill_preserve(cr);
    cairo_clip(cr);
    if (bar->finishing) {
        /* A full bar whose lighter band slides across, once every 1.4 s (still without animations). */
        double phase = 0;
        if (animations_enabled(GTK_WIDGET(area))) {
            GdkFrameClock *clock = gtk_widget_get_frame_clock(GTK_WIDGET(area));
            gint64 now = clock ? gdk_frame_clock_get_frame_time(clock) : bar->start;
            phase = fmod((now - bar->start) / 1.4e6, 1.0);
        }
        double tile = 2.0 * width;
        for (int i = 0; i < 2; i++) {
            double x = -phase * tile + i * tile;
            cairo_pattern_t *gradient = cairo_pattern_create_linear(x, 0, x + tile, 0);
            cairo_pattern_add_color_stop_rgb(gradient, 0, 0x39 / 255.0, 0x83 / 255.0, 0xf7 / 255.0);
            cairo_pattern_add_color_stop_rgb(gradient, 0.5, (0x39 * 0.6 + 255 * 0.4) / 255.0,
                                             (0x83 * 0.6 + 255 * 0.4) / 255.0, (0xf7 * 0.6 + 255 * 0.4) / 255.0);
            cairo_pattern_add_color_stop_rgb(gradient, 1, 0x39 / 255.0, 0x83 / 255.0, 0xf7 / 255.0);
            cairo_set_source(cr, gradient);
            cairo_rectangle(cr, x, 0, tile, height);
            cairo_fill(cr);
            cairo_pattern_destroy(gradient);
        }
        return;
    }
    if (!bar->determinate) {
        set_rgb(cr, 0x3983f7, 1);
        cairo_rectangle(cr, width * 0.3, 0, width * 0.3, height);
        cairo_fill(cr);
        return;
    }
    if (bar->n_segments == 0) {
        set_rgb(cr, 0x3983f7, 1);
        cairo_rectangle(cr, 0, 0, round(width * CLAMP(bar->fraction, 0, 1)), height);
        cairo_fill(cr);
        return;
    }
    double x = 0;
    for (gsize i = 0; i < bar->n_segments; i++) {
        double w = width * CLAMP(bar->segments[i].fraction, 0, 1);
        set_rgb(cr, route_rgb(bar->segments[i].method), 1);
        cairo_rectangle(cr, x, 0, w, height);
        cairo_fill(cr);
        x += w;
    }
}

static gboolean split_bar_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    (void)clock, (void)data;
    if (animations_enabled(widget)) gtk_widget_queue_draw(widget);
    return G_SOURCE_CONTINUE;
}

GtkWidget *szfriends_gtk_split_bar_new(const SZFriendsGtkProgress *progress) {
    SZFriendsGtkSplitBar *bar = g_new0(SZFriendsGtkSplitBar, 1);
    bar->fraction = progress->fraction;
    bar->determinate = progress->determinate;
    bar->finishing = progress->finishing;
    bar->n_segments = progress->n_segments;
    bar->segments = g_memdup2(progress->segments, sizeof *progress->segments * progress->n_segments);
    for (gsize i = 0; i < bar->n_segments; i++) bar->segments[i].present = 0; /* plain values, nothing to free */
    bar->start = g_get_monotonic_time();
    GtkWidget *area = g_object_new(GTK_TYPE_DRAWING_AREA, "accessible-role", GTK_ACCESSIBLE_ROLE_PROGRESS_BAR, NULL);
    gtk_widget_set_name(area, "szfriends.transfer.bar");
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), 8);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw_split_bar, bar, split_bar_free);
    if (progress->accessibility_label && *progress->accessibility_label)
        gtk_accessible_update_property(GTK_ACCESSIBLE(area), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       progress->accessibility_label, -1);
    if (progress->determinate)
        gtk_accessible_update_property(GTK_ACCESSIBLE(area), GTK_ACCESSIBLE_PROPERTY_VALUE_MIN, 0.0,
                                       GTK_ACCESSIBLE_PROPERTY_VALUE_MAX, 1.0, GTK_ACCESSIBLE_PROPERTY_VALUE_NOW,
                                       CLAMP(progress->fraction, 0, 1), -1);
    if (bar->finishing) gtk_widget_add_tick_callback(area, split_bar_tick, NULL, NULL);
    return area;
}
