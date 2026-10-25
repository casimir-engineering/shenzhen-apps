/* The views' vector glyphs (szfriends_gtk_glyphs.h): mac/SZFriendsIcons.m's paths, stroked with GskPath. */

#include "gtk/szfriends_gtk_glyphs.h"

#include <math.h>

#define SZFRIENDS_GTK_TYPE_GLYPH (szfriends_gtk_glyph_get_type())
G_DECLARE_FINAL_TYPE(SZFriendsGtkGlyph, szfriends_gtk_glyph, SZFRIENDS_GTK, GLYPH, GtkWidget)

struct _SZFriendsGtkGlyph {
    GtkWidget parent;
    SZFriendsGtkGlyphKind kind;
    int size;
    GdkRGBA drawn; /* the colour the last snapshot stroked with */
};

G_DEFINE_FINAL_TYPE(SZFriendsGtkGlyph, szfriends_gtk_glyph, GTK_TYPE_WIDGET)

/* An arc around (cx, cy) from `from` to `to` degrees, y down as in the mockups' SVGs: a growing angle turns
 * clockwise on screen, which is SVG's positive sweep. */
static void arc(GskPathBuilder *builder, float cx, float cy, float r, float from, float to) {
    double a = from * G_PI / 180, b = to * G_PI / 180;
    gsk_path_builder_move_to(builder, cx + r * (float)cos(a), cy + r * (float)sin(a));
    gsk_path_builder_svg_arc_to(builder, r, r, 0, fabsf(to - from) > 180, to > from, cx + r * (float)cos(b),
                                cy + r * (float)sin(b));
}

static void line(GskPathBuilder *builder, float x1, float y1, float x2, float y2) {
    gsk_path_builder_move_to(builder, x1, y1);
    gsk_path_builder_line_to(builder, x2, y2);
}

static void circle(GskPathBuilder *builder, float cx, float cy, float r) {
    gsk_path_builder_add_circle(builder, &GRAPHENE_POINT_INIT(cx, cy), r);
}

static void rounded(GskPathBuilder *builder, float x, float y, float width, float height, float radius) {
    GskRoundedRect rect;
    gsk_rounded_rect_init_from_rect(&rect, &GRAPHENE_RECT_INIT(x, y, width, height), radius);
    gsk_path_builder_add_rounded_rect(builder, &rect);
}

SZFriendsGtkGlyphKind szfriends_gtk_route_glyph(SZFriendsGtkRouteKind kind, SZFriendsGtkRouteMethod method) {
    if (kind == SZFRIENDS_GTK_ROUTE_OFFLINE) return SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE;
    if (kind == SZFRIENDS_GTK_ROUTE_CONNECTING) return SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET;
    if (kind != SZFRIENDS_GTK_ROUTE_LOCAL && kind != SZFRIENDS_GTK_ROUTE_ONLINE) return SZFRIENDS_GTK_GLYPH_NONE;
    switch (method) {
    case SZFRIENDS_GTK_METHOD_LAN: return SZFRIENDS_GTK_GLYPH_ROUTE_LAN;
    case SZFRIENDS_GTK_METHOD_P2P_WIFI: return SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI;
    case SZFRIENDS_GTK_METHOD_BLUETOOTH: return SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH;
    case SZFRIENDS_GTK_METHOD_INTERNET: return SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET;
    case SZFRIENDS_GTK_METHOD_RELAY: return SZFRIENDS_GTK_GLYPH_ROUTE_RELAY;
    case SZFRIENDS_GTK_METHOD_UNSET: break;
    }
    return kind == SZFRIENDS_GTK_ROUTE_LOCAL ? SZFRIENDS_GTK_GLYPH_ROUTE_LAN : SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET;
}

/* The stroked outline of `kind` in its unit box; `width` is the stroke and `dots` up to two filled circles (x, y, r;
 * r 0 for none) for the glyphs that carry them. Returns the box's side in units. The route icons are
 * mac/SZFriendsIcons.m's SZFRoutePaths, point for point. */
static float build(SZFriendsGtkGlyphKind kind, GskPathBuilder *builder, float *width, float dots[2][3]) {
    switch (kind) {
    case SZFRIENDS_GTK_GLYPH_CHECK:
        *width = 1.8f;
        gsk_path_builder_move_to(builder, 3, 8.5f);
        gsk_path_builder_line_to(builder, 6.5f, 12);
        gsk_path_builder_line_to(builder, 13, 4.5f);
        return 16;
    case SZFRIENDS_GTK_GLYPH_CLOSE:
        *width = 1.5f;
        line(builder, 4.5f, 4.5f, 11.5f, 11.5f);
        line(builder, 11.5f, 4.5f, 4.5f, 11.5f);
        return 16;
    case SZFRIENDS_GTK_GLYPH_BLOCK:
        *width = 1.6f;
        circle(builder, 8, 8, 6);
        line(builder, 3.8f, 12.2f, 12.2f, 3.8f);
        return 16;
    case SZFRIENDS_GTK_GLYPH_ROUTE_LAN:
        *width = 1.2f;
        for (int i = 0; i < 2; i++) {
            float r = i ? 5.8f : 3.4f;
            arc(builder, 6, 6, r, 135, 225);
            arc(builder, 6, 6, r, -45, 45);
        }
        dots[0][0] = 6, dots[0][1] = 6, dots[0][2] = 1.4f;
        return 12;
    case SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI:
        /* Two laptops joined by a wave arching over them (mac/SZFriendsIcons.m, the same paths). */
        *width = 1.1f;
        rounded(builder, 1.3f, 4.4f, 3.2f, 2.6f, 0.5f);
        rounded(builder, 7.5f, 4.4f, 3.2f, 2.6f, 0.5f);
        line(builder, 0.8f, 9.27f, 5, 9.27f);
        line(builder, 7, 9.27f, 11.2f, 9.27f);
        gsk_path_builder_move_to(builder, 3.4f, 2.4f);
        gsk_path_builder_cubic_to(builder, 4.8f, 0.5f, 7.2f, 0.5f, 8.6f, 2.4f);
        return 12;
    case SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH:
        *width = 1.1f;
        gsk_path_builder_move_to(builder, 3.5f, 3.75f);
        gsk_path_builder_line_to(builder, 8.4f, 8.25f);
        gsk_path_builder_line_to(builder, 6.1f, 10.5f);
        gsk_path_builder_line_to(builder, 6.1f, 1.5f);
        gsk_path_builder_line_to(builder, 8.4f, 3.75f);
        gsk_path_builder_line_to(builder, 3.5f, 8.25f);
        return 12;
    case SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET: {
        *width = 1.1f;
        circle(builder, 6, 6, 4.6f);
        line(builder, 1.4f, 6, 10.6f, 6);
        GskRoundedRect meridian;
        gsk_rounded_rect_init(&meridian, &GRAPHENE_RECT_INIT(4, 1.4f, 4, 9.2f), &GRAPHENE_SIZE_INIT(2, 4.6f),
                              &GRAPHENE_SIZE_INIT(2, 4.6f), &GRAPHENE_SIZE_INIT(2, 4.6f),
                              &GRAPHENE_SIZE_INIT(2, 4.6f));
        gsk_path_builder_add_rounded_rect(builder, &meridian);
        return 12;
    }
    case SZFRIENDS_GTK_GLYPH_ROUTE_RELAY:
        *width = 1.1f;
        rounded(builder, 1.5f, 1.5f, 9, 4, 1);
        rounded(builder, 1.5f, 6.5f, 9, 4, 1);
        dots[0][0] = 3.6f, dots[0][1] = 3.5f, dots[0][2] = 0.75f;
        dots[1][0] = 3.6f, dots[1][1] = 8.5f, dots[1][2] = 0.75f;
        return 12;
    case SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE:
        /* A hollow dot crossed out, "not reachable now"; a dashed ring read as a loading spinner. */
        *width = 1.2f;
        circle(builder, 6, 6, 3.6f);
        line(builder, 1.6f, 10.4f, 10.4f, 1.6f);
        return 12;
    case SZFRIENDS_GTK_GLYPH_INFO:
        *width = 1.4f;
        circle(builder, 8, 8, 6.5f);
        line(builder, 8, 7.5f, 8, 11.5f);
        dots[0][0] = 8, dots[0][1] = 5, dots[0][2] = 0.9f;
        return 16;
    case SZFRIENDS_GTK_GLYPH_COPY: {
        *width = 1.4f;
        GskRoundedRect front;
        gsk_rounded_rect_init_from_rect(&front, &GRAPHENE_RECT_INIT(5, 5, 8.5f, 8.5f), 1.5f);
        gsk_path_builder_add_rounded_rect(builder, &front);
        gsk_path_builder_move_to(builder, 3, 10.5f);
        gsk_path_builder_line_to(builder, 3, 3.5f);
        gsk_path_builder_svg_arc_to(builder, 1, 1, 0, FALSE, TRUE, 4, 2.5f);
        gsk_path_builder_line_to(builder, 10.5f, 2.5f);
        return 16;
    }
    case SZFRIENDS_GTK_GLYPH_PENCIL:
        *width = 1.4f;
        gsk_path_builder_move_to(builder, 3, 13);
        gsk_path_builder_line_to(builder, 4, 9.5f);
        gsk_path_builder_line_to(builder, 11, 2.5f);
        gsk_path_builder_line_to(builder, 13.5f, 5);
        gsk_path_builder_line_to(builder, 6.5f, 12);
        gsk_path_builder_close(builder);
        return 16;
    case SZFRIENDS_GTK_GLYPH_PAPERCLIP:
        /* mac/SZFriendsIcons.m's SZFriendsDrawPaperclipIcon: three half turns joined by straight legs. */
        *width = 1.3f;
        gsk_path_builder_move_to(builder, 11.54f, 8);
        gsk_path_builder_line_to(builder, 7.47f, 12.07f);
        gsk_path_builder_svg_arc_to(builder, 2.5f, 2.5f, 0, FALSE, TRUE, 3.93f, 8.53f);
        gsk_path_builder_line_to(builder, 9.24f, 3.23f);
        gsk_path_builder_svg_arc_to(builder, 1.75f, 1.75f, 0, FALSE, TRUE, 11.71f, 5.7f);
        gsk_path_builder_line_to(builder, 6.76f, 10.65f);
        gsk_path_builder_svg_arc_to(builder, 0.75f, 0.75f, 0, FALSE, TRUE, 5.7f, 9.59f);
        gsk_path_builder_line_to(builder, 9.41f, 5.88f);
        return 16;
    case SZFRIENDS_GTK_GLYPH_ARC:
        *width = 1.8f;
        arc(builder, 8, 8, 6, -90, 180);
        return 16;
    case SZFRIENDS_GTK_GLYPH_NONE: break;
    }
    return 0;
}

static void glyph_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    SZFriendsGtkGlyph *glyph = SZFRIENDS_GTK_GLYPH(widget);
    GskPathBuilder *builder = gsk_path_builder_new();
    float width = 1, dots[2][3] = {{0, 0, 0}, {0, 0, 0}};
    float units = build(glyph->kind, builder, &width, dots);
    GskPath *path = gsk_path_builder_free_to_path(builder);
    int w = gtk_widget_get_width(widget), h = gtk_widget_get_height(widget);
    if (units > 0 && w > 0 && h > 0) {
        float scale = MIN(w, h) / units;
        GdkRGBA color;
        gtk_widget_get_color(widget, &color);
        glyph->drawn = color;
        gtk_snapshot_save(snapshot);
        gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT((w - units * scale) / 2, (h - units * scale) / 2));
        gtk_snapshot_scale(snapshot, scale, scale);
        GskStroke *stroke = gsk_stroke_new(width);
        gsk_stroke_set_line_cap(stroke, GSK_LINE_CAP_ROUND);
        gsk_stroke_set_line_join(stroke, GSK_LINE_JOIN_ROUND);
        gtk_snapshot_append_stroke(snapshot, path, stroke, &color);
        gsk_stroke_free(stroke);
        if (dots[0][2] > 0) {
            GskPathBuilder *fill = gsk_path_builder_new();
            for (int i = 0; i < 2; i++)
                if (dots[i][2] > 0) circle(fill, dots[i][0], dots[i][1], dots[i][2]);
            GskPath *filled = gsk_path_builder_free_to_path(fill);
            gtk_snapshot_append_fill(snapshot, filled, GSK_FILL_RULE_WINDING, &color);
            gsk_path_unref(filled);
        }
        gtk_snapshot_restore(snapshot);
    }
    gsk_path_unref(path);
}

static void glyph_measure(GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum, int *natural,
                          int *minimum_baseline, int *natural_baseline) {
    (void)orientation, (void)for_size, (void)minimum_baseline, (void)natural_baseline;
    *minimum = *natural = SZFRIENDS_GTK_GLYPH(widget)->size;
}

/* A glyph strokes in its CSS `color`, which GTK does not treat as a reason to redraw custom drawing: after a live
 * switch to dark, the glyphs that inherit their colour (the footer's pencil and copy marks, a request's Decline) kept
 * their light ink on the dark page (UX verification, wave 6c). Once the new style is in, a changed colour redraws. */
static void glyph_css_changed(GtkWidget *widget, GtkCssStyleChange *change) {
    GTK_WIDGET_CLASS(szfriends_gtk_glyph_parent_class)->css_changed(widget, change);
    GdkRGBA color;
    gtk_widget_get_color(widget, &color);
    if (!gdk_rgba_equal(&color, &SZFRIENDS_GTK_GLYPH(widget)->drawn)) gtk_widget_queue_draw(widget);
}

static void szfriends_gtk_glyph_class_init(SZFriendsGtkGlyphClass *klass) {
    GTK_WIDGET_CLASS(klass)->snapshot = glyph_snapshot;
    GTK_WIDGET_CLASS(klass)->css_changed = glyph_css_changed;
    GTK_WIDGET_CLASS(klass)->measure = glyph_measure;
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(klass), "szfriends-glyph");
    gtk_widget_class_set_accessible_role(GTK_WIDGET_CLASS(klass), GTK_ACCESSIBLE_ROLE_PRESENTATION);
}

static void szfriends_gtk_glyph_init(SZFriendsGtkGlyph *glyph) {
    glyph->size = 16;
    gtk_widget_set_can_target(GTK_WIDGET(glyph), FALSE); /* clicks belong to the control around it */
}

GtkWidget *szfriends_gtk_glyph_new(SZFriendsGtkGlyphKind kind, int size) {
    SZFriendsGtkGlyph *glyph = g_object_new(SZFRIENDS_GTK_TYPE_GLYPH, NULL);
    glyph->kind = kind;
    glyph->size = size > 0 ? size : 16;
    gtk_widget_set_halign(GTK_WIDGET(glyph), GTK_ALIGN_CENTER);
    gtk_widget_set_valign(GTK_WIDGET(glyph), GTK_ALIGN_CENTER);
    return GTK_WIDGET(glyph);
}

void szfriends_gtk_glyph_set_kind(GtkWidget *widget, SZFriendsGtkGlyphKind kind) {
    g_return_if_fail(SZFRIENDS_GTK_IS_GLYPH(widget));
    if (SZFRIENDS_GTK_GLYPH(widget)->kind == kind) return;
    SZFRIENDS_GTK_GLYPH(widget)->kind = kind;
    gtk_widget_queue_draw(widget);
}

SZFriendsGtkGlyphKind szfriends_gtk_glyph_get_kind(GtkWidget *widget) {
    return SZFRIENDS_GTK_IS_GLYPH(widget) ? SZFRIENDS_GTK_GLYPH(widget)->kind : SZFRIENDS_GTK_GLYPH_NONE;
}

void szfriends_gtk_glyph_set_size(GtkWidget *widget, int size) {
    g_return_if_fail(SZFRIENDS_GTK_IS_GLYPH(widget));
    if (size <= 0 || SZFRIENDS_GTK_GLYPH(widget)->size == size) return;
    SZFRIENDS_GTK_GLYPH(widget)->size = size;
    gtk_widget_queue_resize(widget);
}
