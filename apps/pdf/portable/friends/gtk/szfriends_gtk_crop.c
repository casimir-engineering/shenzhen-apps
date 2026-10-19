/* The crop step for your own picture (szfriends_gtk_crop.h). Mirrors mac/SZFriendsCropView.m: the photo under a
 * 200 px circle, dragged to place and zoomed with the slider; Use Picture sends only the square. */

#include "gtk/szfriends_gtk_crop.h"

#include <adwaita.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>
#include <math.h>
#include <stdlib.h>
#include <sys/stat.h>

/* ---- Geometry ------------------------------------------------------------------------------------------- */

double szfriends_gtk_crop_side(const SZFriendsGtkCropGeometry *crop) {
    return crop->zoom > 0 ? MIN(crop->width, crop->height) / crop->zoom : 0;
}

static void clamp(SZFriendsGtkCropGeometry *crop) {
    double side = szfriends_gtk_crop_side(crop);
    crop->x = CLAMP(crop->x, 0, MAX(0, crop->width - side));
    crop->y = CLAMP(crop->y, 0, MAX(0, crop->height - side));
}

void szfriends_gtk_crop_init(SZFriendsGtkCropGeometry *crop, double width, double height) {
    crop->width = MAX(width, 0);
    crop->height = MAX(height, 0);
    crop->zoom = 1;
    double side = szfriends_gtk_crop_side(crop);
    crop->x = (crop->width - side) / 2;
    crop->y = (crop->height - side) / 2;
}

void szfriends_gtk_crop_set_zoom(SZFriendsGtkCropGeometry *crop, double zoom) {
    double side = szfriends_gtk_crop_side(crop);
    double centre_x = crop->x + side / 2, centre_y = crop->y + side / 2;
    crop->zoom = isfinite(zoom) ? CLAMP(zoom, 1, SZFRIENDS_GTK_CROP_MAX_ZOOM) : 1;
    side = szfriends_gtk_crop_side(crop);
    crop->x = centre_x - side / 2;
    crop->y = centre_y - side / 2;
    clamp(crop);
}

void szfriends_gtk_crop_drag(SZFriendsGtkCropGeometry *crop, double start_x, double start_y, double dx, double dy) {
    double pixels_per_point = szfriends_gtk_crop_side(crop) / SZFRIENDS_GTK_CROP_VIEWPORT;
    crop->x = start_x - dx * pixels_per_point;
    crop->y = start_y - dy * pixels_per_point;
    clamp(crop);
}

szfriends_crop szfriends_gtk_crop_square(const SZFriendsGtkCropGeometry *crop) {
    /* Whole pixels, at least one, never past the photo's edge: the helper refuses a square that leaves it. */
    double side = MAX(1, floor(szfriends_gtk_crop_side(crop)));
    double x = MAX(0, MIN(floor(crop->x), floor(crop->width) - side));
    double y = MAX(0, MIN(floor(crop->y), floor(crop->height) - side));
    return (szfriends_crop){(int64_t)x, (int64_t)y, (int64_t)side};
}

szfriends_intent *szfriends_gtk_crop_intent(const char *path, const SZFriendsGtkCropGeometry *geometry) {
    if (!path || !*path) return NULL;
    if (!geometry) return szfriends_intent_set_picture_image_path(path, NULL);
    szfriends_crop square = szfriends_gtk_crop_square(geometry);
    return szfriends_intent_set_picture_image_path(path, &square);
}

/* ---- What the views decode ---------------------------------------------------------------------------- */

SZFriendsGtkPhotoCheck szfriends_gtk_photo_check(const char *path) {
    SZFriendsGtkPhotoCheck check = {0};
    GStatBuf status;
    /* lstat: a link or a pipe is never opened here (a pipe would block the reader for good); the helper refuses
     * them in its own words. */
    if (!path || g_lstat(path, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size <= 0 ||
        status.st_size > SZFRIENDS_GTK_PHOTO_MAX_BYTES)
        return check;
    int width = 0, height = 0;
    GdkPixbufFormat *format = gdk_pixbuf_get_file_info(path, &width, &height);
    char *name = format ? gdk_pixbuf_format_get_name(format) : NULL;
    gboolean png = g_strcmp0(name, "png") == 0, jpeg = g_strcmp0(name, "jpeg") == 0;
    g_free(name);
    check.width = width;
    check.height = height;
    if (!(png || jpeg) || width <= 0 || height <= 0 || width > SZFRIENDS_GTK_PHOTO_MAX_SIDE ||
        height > SZFRIENDS_GTK_PHOTO_MAX_SIDE)
        return check;
    double pixels = (double)width * height;
    /* A few kilobytes of PNG can declare 8192 x 8192 pixels; an honest picture that large carries a byte per
     * 1,024 pixels at least (the helper's rule, avatars/SZFriendsPicturePipeline.m). */
    if (pixels > 2048.0 * 2048.0 && pixels / (double)status.st_size > 1024.0) return check;
    /* JPEG decodes straight to a reduced size; PNG only at full size, 64 MiB at 4096 x 4096. */
    if (png && pixels > 4096.0 * 4096.0) return check;
    check.showable = TRUE;
    return check;
}

/* ---- Decoding, off the main thread ---------------------------------------------------------------------- */

#define PREVIEW_SIDE 1600 /* enough for the circle at 2x and 4x zoom */

typedef struct {
    char *path;
    SZFriendsGtkPhotoCheck check;
    cairo_surface_t *surface; /* the reduced photo, orientation applied */
} SZFriendsGtkCropLoad;

static void load_free(gpointer data) {
    SZFriendsGtkCropLoad *load = data;
    g_free(load->path);
    if (load->surface) cairo_surface_destroy(load->surface);
    g_free(load);
}

/* Cairo's premultiplied ARGB from the pixbuf's RGB(A): GTK 4.20 deprecated drawing a pixbuf directly. */
static cairo_surface_t *surface_from_pixbuf(GdkPixbuf *pixbuf) {
    int width = gdk_pixbuf_get_width(pixbuf), height = gdk_pixbuf_get_height(pixbuf);
    int channels = gdk_pixbuf_get_n_channels(pixbuf), stride = gdk_pixbuf_get_rowstride(pixbuf);
    gboolean alpha = gdk_pixbuf_get_has_alpha(pixbuf);
    const guint8 *pixels = gdk_pixbuf_read_pixels(pixbuf);
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) return surface;
    cairo_surface_flush(surface);
    guint8 *out = cairo_image_surface_get_data(surface);
    int out_stride = cairo_image_surface_get_stride(surface);
    for (int y = 0; y < height; y++) {
        const guint8 *in = pixels + (gsize)y * stride;
        guint32 *row = (guint32 *)(void *)(out + (gsize)y * out_stride);
        for (int x = 0; x < width; x++, in += channels) {
            guint a = alpha ? in[3] : 255;
            guint r = in[0] * a / 255, g = in[1] * a / 255, b = in[2] * a / 255;
            row[x] = (guint32)a << 24 | r << 16 | g << 8 | b;
        }
    }
    cairo_surface_mark_dirty(surface);
    return surface;
}

cairo_surface_t *szfriends_gtk_photo_decode(const char *path, SZFriendsGtkPhotoCheck *check) {
    *check = szfriends_gtk_photo_check(path);
    if (!check->showable) return NULL;
    int longest = MAX(check->width, check->height);
    GdkPixbuf *pixbuf = longest > PREVIEW_SIDE ? gdk_pixbuf_new_from_file_at_scale(path, PREVIEW_SIDE, PREVIEW_SIDE,
                                                                                   TRUE, NULL)
                                               : gdk_pixbuf_new_from_file(path, NULL);
    GdkPixbuf *oriented = pixbuf ? gdk_pixbuf_apply_embedded_orientation(pixbuf) : NULL;
    cairo_surface_t *surface = NULL;
    if (oriented) {
        /* EXIF orientations 5 to 8 turn the photo a quarter: the helper crops in displayed pixels. */
        const char *orientation = gdk_pixbuf_get_option(pixbuf, "orientation");
        int turn = orientation ? atoi(orientation) : 1;
        if (turn >= 5 && turn <= 8) {
            int width = check->width;
            check->width = check->height;
            check->height = width;
        }
        surface = surface_from_pixbuf(oriented);
        g_object_unref(oriented);
    }
    if (pixbuf) g_object_unref(pixbuf);
    check->showable = surface != NULL;
    return surface;
}

static void load_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancellable) {
    (void)source;
    SZFriendsGtkCropLoad *load = data;
    if (!g_cancellable_is_cancelled(cancellable)) load->surface = szfriends_gtk_photo_decode(load->path, &load->check);
    g_task_return_boolean(task, TRUE);
}

/* ---- The widget --------------------------------------------------------------------------------------- */

typedef struct {
    char *path;
    SZFriendsGtkCropUse use;
    SZFriendsGtkCropCancel cancel;
    gpointer data;
    GCancellable *cancellable;
    cairo_surface_t *surface;
    SZFriendsGtkCropGeometry geometry;
    gboolean loaded;
    double drag_x, drag_y;
    GtkWidget *box, *area, *loading, *scale, *use_button;
} SZFriendsGtkCrop;

static void crop_free(gpointer data) {
    SZFriendsGtkCrop *crop = data;
    g_cancellable_cancel(crop->cancellable);
    g_object_unref(crop->cancellable);
    if (crop->surface) cairo_surface_destroy(crop->surface);
    g_free(crop->path);
    g_free(crop);
}

static void area_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    SZFriendsGtkCrop *crop = data;
    double side = MIN(width, height);
    GdkRGBA ink;
    gtk_widget_get_color(GTK_WIDGET(area), &ink);
    cairo_set_source_rgba(cr, ink.red, ink.green, ink.blue, 0.06);
    cairo_rectangle(cr, 0, 0, side, side);
    cairo_fill(cr);
    if (crop->loaded && crop->surface) {
        /* White under the photo: the helper turns transparency white, so the preview shows what friends see. */
        cairo_set_source_rgb(cr, 1, 1, 1);
        cairo_rectangle(cr, 0, 0, side, side);
        cairo_fill(cr);
        double scale = cairo_image_surface_get_width(crop->surface) / MAX(crop->geometry.width, 1);
        double visible = szfriends_gtk_crop_side(&crop->geometry) * scale;
        cairo_save(cr);
        cairo_rectangle(cr, 0, 0, side, side);
        cairo_clip(cr);
        cairo_scale(cr, side / MAX(visible, 1e-6), side / MAX(visible, 1e-6));
        cairo_translate(cr, -crop->geometry.x * scale, -crop->geometry.y * scale);
        cairo_set_source_surface(cr, crop->surface, 0, 0);
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
        cairo_paint(cr);
        cairo_restore(cr);
    }
    /* Outside the circle dimmed, the circle ringed: what becomes the picture is what stays bright. */
    cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
    cairo_rectangle(cr, 0, 0, side, side);
    cairo_arc(cr, side / 2, side / 2, side / 2, 0, 2 * G_PI);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.45);
    cairo_fill(cr);
    cairo_arc(cr, side / 2, side / 2, side / 2 - 0.5, 0, 2 * G_PI);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.85);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);
}

static void drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer data) {
    (void)gesture, (void)x, (void)y;
    SZFriendsGtkCrop *crop = data;
    crop->drag_x = crop->geometry.x;
    crop->drag_y = crop->geometry.y;
}

static void drag_update(GtkGestureDrag *gesture, double dx, double dy, gpointer data) {
    (void)gesture;
    SZFriendsGtkCrop *crop = data;
    if (!crop->loaded) return;
    szfriends_gtk_crop_drag(&crop->geometry, crop->drag_x, crop->drag_y, dx, dy);
    gtk_widget_queue_draw(crop->area);
}

static void zoom_changed(GtkRange *range, gpointer data) {
    SZFriendsGtkCrop *crop = data;
    szfriends_gtk_crop_set_zoom(&crop->geometry, gtk_range_get_value(range));
    gtk_widget_queue_draw(crop->area);
}

static void use_clicked(GtkButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkCrop *crop = data;
    if (crop->loaded) crop->use(crop->path, &crop->geometry, crop->data);
}

static void cancel_clicked(GtkButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkCrop *crop = data;
    crop->cancel(crop->data);
}

static void loaded(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GtkWidget *box = GTK_WIDGET(source);
    SZFriendsGtkCrop *crop = g_object_get_data(G_OBJECT(box), "szfriends-crop");
    SZFriendsGtkCropLoad *load = g_task_get_task_data(G_TASK(result));
    /* Dismissed while decoding (Cancel, Escape, the page gone): nothing more to do. */
    if (!crop || g_cancellable_is_cancelled(crop->cancellable) || !gtk_widget_get_parent(box)) return;
    if (!load->check.showable || !load->surface) {
        crop->use(crop->path, NULL, crop->data);
        return;
    }
    crop->surface = g_steal_pointer(&load->surface);
    szfriends_gtk_crop_init(&crop->geometry, load->check.width, load->check.height);
    crop->loaded = TRUE;
    gtk_widget_set_visible(crop->loading, FALSE);
    gtk_widget_set_sensitive(crop->scale, TRUE);
    gtk_widget_set_sensitive(crop->use_button, TRUE);
    gtk_widget_queue_draw(crop->area);
}

GtkWidget *szfriends_gtk_crop_new(SZFriendsGtkLink *link, const char *path, SZFriendsGtkCropUse use,
                                  SZFriendsGtkCropCancel cancel, gpointer data) {
    SZFriendsGtkCrop *crop = g_new0(SZFriendsGtkCrop, 1);
    *crop = (SZFriendsGtkCrop){.path = g_strdup(path), .use = use, .cancel = cancel, .data = data};
    crop->cancellable = g_cancellable_new();
    crop->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_name(crop->box, "szfriends.crop");
    gtk_widget_set_margin_top(crop->box, 14);
    gtk_widget_set_margin_bottom(crop->box, 14);
    g_object_set_data_full(G_OBJECT(crop->box), "szfriends-crop", crop, crop_free);
    GtkWidget *title = gtk_label_new(szfriends_gtk_link_string(link, "crop_title"));
    gtk_widget_add_css_class(title, "heading");
    gtk_box_append(GTK_BOX(crop->box), title);
    GtkWidget *viewport = gtk_overlay_new();
    gtk_widget_set_halign(viewport, GTK_ALIGN_CENTER);
    crop->area = gtk_drawing_area_new();
    gtk_widget_set_size_request(crop->area, SZFRIENDS_GTK_CROP_VIEWPORT, SZFRIENDS_GTK_CROP_VIEWPORT);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(crop->area), area_draw, crop, NULL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(crop->area), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   szfriends_gtk_link_string(link, "crop_title"), -1);
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(drag_begin), crop);
    g_signal_connect(drag, "drag-update", G_CALLBACK(drag_update), crop);
    gtk_widget_add_controller(crop->area, GTK_EVENT_CONTROLLER(drag));
    gtk_overlay_set_child(GTK_OVERLAY(viewport), crop->area);
    crop->loading = gtk_label_new(szfriends_gtk_link_string(link, "loading"));
    gtk_widget_add_css_class(crop->loading, "szfriends-secondary");
    gtk_overlay_add_overlay(GTK_OVERLAY(viewport), crop->loading);
    gtk_box_append(GTK_BOX(crop->box), viewport);
    crop->scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 1, SZFRIENDS_GTK_CROP_MAX_ZOOM, 0.01);
    gtk_scale_set_draw_value(GTK_SCALE(crop->scale), FALSE);
    gtk_widget_set_size_request(crop->scale, SZFRIENDS_GTK_CROP_VIEWPORT, -1);
    gtk_widget_set_halign(crop->scale, GTK_ALIGN_CENTER);
    gtk_widget_set_sensitive(crop->scale, FALSE);
    g_signal_connect(crop->scale, "value-changed", G_CALLBACK(zoom_changed), crop);
    gtk_box_append(GTK_BOX(crop->box), crop->scale);
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(buttons, GTK_ALIGN_CENTER);
    GtkWidget *cancel_button = gtk_button_new_with_label(szfriends_gtk_link_string(link, "cancel"));
    gtk_widget_set_name(cancel_button, "szfriends.crop.cancel");
    g_signal_connect(cancel_button, "clicked", G_CALLBACK(cancel_clicked), crop);
    crop->use_button = gtk_button_new_with_label(szfriends_gtk_link_string(link, "crop_use"));
    gtk_widget_set_name(crop->use_button, "szfriends.crop.use");
    gtk_widget_add_css_class(crop->use_button, "suggested-action");
    gtk_widget_set_sensitive(crop->use_button, FALSE);
    g_signal_connect(crop->use_button, "clicked", G_CALLBACK(use_clicked), crop);
    gtk_box_append(GTK_BOX(buttons), cancel_button);
    gtk_box_append(GTK_BOX(buttons), crop->use_button);
    gtk_box_append(GTK_BOX(crop->box), buttons);
    SZFriendsGtkCropLoad *load = g_new0(SZFriendsGtkCropLoad, 1);
    load->path = g_strdup(path);
    GTask *task = g_task_new(crop->box, crop->cancellable, loaded, NULL);
    g_task_set_task_data(task, load, load_free);
    g_task_run_in_thread(task, load_thread);
    g_object_unref(task);
    return crop->box;
}

gboolean szfriends_gtk_crop_is_loaded(GtkWidget *widget) {
    SZFriendsGtkCrop *crop = widget ? g_object_get_data(G_OBJECT(widget), "szfriends-crop") : NULL;
    return crop && crop->loaded;
}

SZFriendsGtkCropGeometry *szfriends_gtk_crop_geometry(GtkWidget *widget) {
    SZFriendsGtkCrop *crop = widget ? g_object_get_data(G_OBJECT(widget), "szfriends-crop") : NULL;
    return crop ? &crop->geometry : NULL;
}
