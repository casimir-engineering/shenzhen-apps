/* Drawing avatars: the circle, then the animal's SVG, the photo once read, or the initials (szfriends_gtk_avatars.h).
 *
 * Animals are drawn with GtkSvg (GTK 4.22). Their SVGs ship with the app and use no text, links or animation, so the
 * renderer is given system resources only: without them GtkSvg builds a fontconfig map of its own, which the macOS
 * backend's CoreText font map rejects with a critical per file. */

#include "gtk/szfriends_gtk_avatars.h"

#include <adwaita.h>
#include <math.h>
#include <string.h>

/* Animals by path for the life of the process: a set has 24 small SVGs that ship with the app. */
static GHashTable *animal_cache(void) {
    static GHashTable *cache;
    if (!cache) cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    return cache;
}

static GdkPaintable *load_animal(const char *path) {
    GdkPaintable *paintable = g_hash_table_lookup(animal_cache(), path);
    if (paintable) return paintable;
    GtkSvg *svg = gtk_svg_new();
    gtk_svg_set_features(svg, GTK_SVG_SYSTEM_RESOURCES);
    char *data = NULL;
    gsize length = 0;
    if (g_file_get_contents(path, &data, &length, NULL)) {
        GBytes *bytes = g_bytes_new_take(data, length);
        gtk_svg_load_from_bytes(svg, bytes);
        g_bytes_unref(bytes);
    }
    g_hash_table_insert(animal_cache(), g_strdup(path), svg);
    return GDK_PAINTABLE(svg);
}

/* Photos by path, read off the main thread (szfriends_gtk_avatar_photo_load): the helper names each by its content
 * hash, so a path never changes what it holds and a decoded one is kept for the life of the process. One that could
 * not be read is forgotten, so a view that shows it later tries again; the views waiting for one are redrawn when it
 * arrives. */
typedef struct {
    GdkPaintable *paintable; /* NULL while loading */
    GPtrArray *waiting;      /* GWeakRef * to the avatar views that asked */
} SZFriendsGtkPhoto;

static void weak_free(gpointer data) {
    g_weak_ref_clear(data);
    g_free(data);
}

static void photo_free(gpointer data) {
    SZFriendsGtkPhoto *photo = data;
    g_clear_object(&photo->paintable);
    g_ptr_array_unref(photo->waiting);
    g_free(photo);
}

static GHashTable *photo_cache(void) {
    static GHashTable *cache;
    if (!cache) cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, photo_free);
    return cache;
}

GdkPaintable *szfriends_gtk_avatar_cached_photo(const char *path) {
    SZFriendsGtkPhoto *photo = path ? g_hash_table_lookup(photo_cache(), path) : NULL;
    return photo ? photo->paintable : NULL;
}

static void photo_read(GTask *task, gpointer source, gpointer data, GCancellable *cancellable) {
    (void)source, (void)cancellable;
    GError *error = NULL;
    GdkTexture *texture = szfriends_gtk_avatar_photo_load(data, g_object_get_data(G_OBJECT(task), "pictures"), &error);
    if (texture) g_task_return_pointer(task, texture, g_object_unref);
    else g_task_return_error(task, error);
}

static void photo_arrived(GObject *source, GAsyncResult *result, gpointer data) {
    (void)source, (void)data;
    const char *path = g_task_get_task_data(G_TASK(result));
    GError *error = NULL;
    GdkTexture *texture = g_task_propagate_pointer(G_TASK(result), &error);
    if (error) g_debug("Shenzhen Friends: %s", error->message); /* shows as initials, by design */
    g_clear_error(&error);
    SZFriendsGtkPhoto *photo = g_hash_table_lookup(photo_cache(), path);
    if (!photo) {
        g_clear_object(&texture);
        return;
    }
    GPtrArray *waiting = g_steal_pointer(&photo->waiting);
    photo->waiting = g_ptr_array_new_with_free_func(weak_free);
    if (texture) photo->paintable = GDK_PAINTABLE(texture);
    else g_hash_table_remove(photo_cache(), path);
    for (guint i = 0; texture && i < waiting->len; i++) {
        GtkWidget *view = g_weak_ref_get(g_ptr_array_index(waiting, i));
        if (view) gtk_widget_queue_draw(view);
        g_clear_object(&view);
    }
    g_ptr_array_unref(waiting);
}

static void request_photo(GtkWidget *view, const char *path) {
    SZFriendsGtkPhoto *photo = g_hash_table_lookup(photo_cache(), path);
    if (photo && photo->paintable) return;
    if (!photo) {
        photo = g_new0(SZFriendsGtkPhoto, 1);
        photo->waiting = g_ptr_array_new_with_free_func(weak_free);
        g_hash_table_insert(photo_cache(), g_strdup(path), photo);
        GTask *task = g_task_new(NULL, NULL, photo_arrived, NULL);
        g_task_set_task_data(task, g_strdup(path), g_free);
        g_object_set_data_full(G_OBJECT(task), "pictures", szfriends_gtk_avatar_pictures_dir(), g_free);
        g_task_run_in_thread(task, photo_read);
        g_object_unref(task);
    }
    GWeakRef *ref = g_new0(GWeakRef, 1);
    g_weak_ref_init(ref, view);
    g_ptr_array_add(photo->waiting, ref);
}

static void draw_initials(GtkSnapshot *snapshot, PangoContext *widget_context, const char *initials, double size) {
    if (!initials || !*initials) return;
    /* The widget's context carries the toolkit's font; a bare font map would pick its own default, a serif. */
    PangoContext *context = widget_context ? g_object_ref(widget_context)
                                           : pango_font_map_create_context(pango_cairo_font_map_get_default());
    PangoLayout *layout = pango_layout_new(context);
    const PangoFontDescription *base = pango_context_get_font_description(context);
    PangoFontDescription *font = base ? pango_font_description_copy(base) : pango_font_description_new();
    if (!base) pango_font_description_set_family(font, "sans-serif");
    pango_font_description_set_weight(font, PANGO_WEIGHT_SEMIBOLD);
    pango_font_description_set_absolute_size(font, floor(size * 0.38) * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, initials, -1); /* plain text: initials come from another person's name */
    int width = 0, height = 0;
    pango_layout_get_pixel_size(layout, &width, &height);
    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT((float)((size - width) / 2), (float)((size - height) / 2)));
    gtk_snapshot_append_layout(snapshot, layout, &(GdkRGBA){1, 1, 1, 1});
    gtk_snapshot_restore(snapshot);
    pango_font_description_free(font);
    g_object_unref(layout);
    g_object_unref(context);
}

void szfriends_gtk_avatar_snapshot(GtkSnapshot *snapshot, const SZFriendsGtkAvatar *avatar,
                                   const SZFriendsGtkAnimalSet *set, double size, PangoContext *context) {
    if (!avatar || size <= 0) return;
    GdkRGBA fill = {0.45f, 0.45f, 0.45f, 1};
    szfriends_gtk_parse_hex_color(avatar->color, &fill);
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, (float)size, (float)size);
    GskRoundedRect circle;
    gsk_rounded_rect_init_from_rect(&circle, &bounds, (float)size / 2);
    gtk_snapshot_push_rounded_clip(snapshot, &circle);
    gtk_snapshot_append_color(snapshot, &fill, &bounds);
    const char *path = NULL;
    SZFriendsGtkAvatarDraw draw = szfriends_gtk_avatar_draw_kind(avatar, set, &path);
    /* A photo is drawn only once read; snapshotting never touches its file. */
    GdkPaintable *picture = draw == SZFRIENDS_GTK_AVATAR_DRAW_ANIMAL  ? load_animal(path)
                            : draw == SZFRIENDS_GTK_AVATAR_DRAW_PHOTO ? szfriends_gtk_avatar_cached_photo(path)
                                                                      : NULL;
    if (picture) {
        /* Aspect fill: an animal is square already; a photo is re-encoded square by the helper. */
        double w = gdk_paintable_get_intrinsic_width(picture), h = gdk_paintable_get_intrinsic_height(picture);
        double scale = w > 0 && h > 0 ? MAX(size / w, size / h) : 1;
        double dw = w > 0 ? w * scale : size, dh = h > 0 ? h * scale : size;
        gtk_snapshot_save(snapshot);
        gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT((float)((size - dw) / 2), (float)((size - dh) / 2)));
        gdk_paintable_snapshot(picture, GDK_SNAPSHOT(snapshot), dw, dh);
        gtk_snapshot_restore(snapshot);
    } else {
        draw_initials(snapshot, context, avatar->initials, size);
    }
    gtk_snapshot_pop(snapshot);
}

/* ---- The widget ---------------------------------------------------------------------------------- */

#define SZFRIENDS_GTK_TYPE_AVATAR_VIEW (szfriends_gtk_avatar_view_get_type())
G_DECLARE_FINAL_TYPE(SZFriendsGtkAvatarView, szfriends_gtk_avatar_view, SZFRIENDS_GTK, AVATAR_VIEW, GtkWidget)

struct _SZFriendsGtkAvatarView {
    GtkWidget parent;
    SZFriendsGtkLink *link;
    int size;
    SZFriendsGtkAvatar avatar; /* a copy; strings owned */
};

G_DEFINE_FINAL_TYPE(SZFriendsGtkAvatarView, szfriends_gtk_avatar_view, GTK_TYPE_WIDGET)

static void clear_avatar(SZFriendsGtkAvatar *avatar) {
    g_free(avatar->initials);
    g_free(avatar->color);
    g_free(avatar->path);
    memset(avatar, 0, sizeof *avatar);
}

static void avatar_view_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    SZFriendsGtkAvatarView *view = SZFRIENDS_GTK_AVATAR_VIEW(widget);
    double side = MIN(gtk_widget_get_width(widget), gtk_widget_get_height(widget));
    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT((float)((gtk_widget_get_width(widget) - side) / 2),
                                                          (float)((gtk_widget_get_height(widget) - side) / 2)));
    szfriends_gtk_avatar_snapshot(snapshot, &view->avatar, szfriends_gtk_link_animal_set(view->link), side,
                                  gtk_widget_get_pango_context(widget));
    gtk_snapshot_restore(snapshot);
}

static void avatar_view_measure(GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum,
                                int *natural, int *minimum_baseline, int *natural_baseline) {
    (void)orientation, (void)for_size, (void)minimum_baseline, (void)natural_baseline;
    *minimum = *natural = SZFRIENDS_GTK_AVATAR_VIEW(widget)->size;
}

static void avatar_view_finalize(GObject *object) {
    clear_avatar(&SZFRIENDS_GTK_AVATAR_VIEW(object)->avatar);
    G_OBJECT_CLASS(szfriends_gtk_avatar_view_parent_class)->finalize(object);
}

static void szfriends_gtk_avatar_view_class_init(SZFriendsGtkAvatarViewClass *klass) {
    GTK_WIDGET_CLASS(klass)->snapshot = avatar_view_snapshot;
    GTK_WIDGET_CLASS(klass)->measure = avatar_view_measure;
    G_OBJECT_CLASS(klass)->finalize = avatar_view_finalize;
    gtk_widget_class_set_accessible_role(GTK_WIDGET_CLASS(klass), GTK_ACCESSIBLE_ROLE_PRESENTATION);
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(klass), "szfriends-avatar");
}

static void szfriends_gtk_avatar_view_init(SZFriendsGtkAvatarView *view) {
    view->size = 28;
}

GtkWidget *szfriends_gtk_avatar_new(SZFriendsGtkLink *link, int size) {
    SZFriendsGtkAvatarView *view = g_object_new(SZFRIENDS_GTK_TYPE_AVATAR_VIEW, NULL);
    view->link = link;
    view->size = size > 0 ? size : 28;
    return GTK_WIDGET(view);
}

void szfriends_gtk_avatar_set(GtkWidget *widget, const SZFriendsGtkAvatar *avatar) {
    g_return_if_fail(SZFRIENDS_GTK_IS_AVATAR_VIEW(widget));
    SZFriendsGtkAvatarView *view = SZFRIENDS_GTK_AVATAR_VIEW(widget);
    /* Snapshots repeat the same avatar up to ten times a second: a photo is asked for when the path changes. */
    gboolean same_photo = avatar && !g_strcmp0(view->avatar.path, avatar->path);
    clear_avatar(&view->avatar);
    if (avatar) {
        view->avatar = *avatar;
        view->avatar.initials = g_strdup(avatar->initials);
        view->avatar.color = g_strdup(avatar->color);
        view->avatar.path = g_strdup(avatar->path);
    }
    const char *path = NULL;
    if (!same_photo && szfriends_gtk_avatar_draw_kind(&view->avatar, NULL, &path) == SZFRIENDS_GTK_AVATAR_DRAW_PHOTO)
        request_photo(widget, path);
    gtk_widget_queue_draw(widget);
}
