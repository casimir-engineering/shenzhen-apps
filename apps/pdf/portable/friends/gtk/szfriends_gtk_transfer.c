/* Transfer cards (szfriends_gtk_conversation.h; mirrors SZFriendsTransferItemView in mac/SZFriendsItemViews.m): the
 * file's preview or its type's icon, name, kind and size, the route note, progress, the status line with its links
 * (Cancel, Show in Shenzhen Files, Try again) and the buttons (Accept, Decline, Open), then the time line.
 *
 * Previews (PROTOCOL.md § Thumbnails): the card is laid out from the snapshot's width and height before the picture
 * loads, the PNG is decoded off the main thread, once per path and size for the page, and a missing or unreadable
 * file, or one of any other size, reads as no preview, so the type's icon shows. Nothing else a friend sent is ever
 * loaded: the icon comes from the file name's extension through GIO, by name only. */

#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_glyphs.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The helper writes previews of at most 192 px a side as stored-deflate PNGs of about 148 KB; anything far larger is
 * not one of them. */
#define SZFRIENDS_GTK_THUMBNAIL_MAX_BYTES (1024 * 1024)
#define SZFRIENDS_GTK_THUMBNAIL_MAX_SIDE 192
/* The type icon's slot, smaller than a preview's (SZFRIENDS_GTK_PREVIEW_LIMIT, the same 64 points as AppKit's). */
#define SZFRIENDS_GTK_ICON_SIZE 32

static GdkTexture *refuse(GError **error, const char *path, const char *why) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "preview %s: %s", path ? path : "(none)", why);
    return NULL;
}

static guint32 be32(const guint8 *bytes) {
    return (guint32)bytes[0] << 24 | (guint32)bytes[1] << 16 | (guint32)bytes[2] << 8 | bytes[3];
}

GdkTexture *szfriends_gtk_thumbnail_load(const char *path, const char *state_dir, gint64 width, gint64 height,
                                         GError **error) {
    if (!path || !state_dir || !*state_dir) return refuse(error, path, "no path or state directory");
    if (width < 1 || height < 1 || width > SZFRIENDS_GTK_THUMBNAIL_MAX_SIDE ||
        height > SZFRIENDS_GTK_THUMBNAIL_MAX_SIDE)
        return refuse(error, path, "the snapshot gives no preview size of 1 to 192 pixels a side");
    /* Only the helper's own cache: a file directly in <state>/thumbnails/, by a name the helper chose. */
    char *cache = g_build_filename(state_dir, "thumbnails", NULL);
    gsize prefix = strlen(cache);
    gboolean inside = strncmp(path, cache, prefix) == 0 && path[prefix] == '/' && path[prefix + 1] != '\0' &&
                      !strchr(path + prefix + 1, '/') && strcmp(path + prefix + 1, "..") != 0 &&
                      strcmp(path + prefix + 1, ".") != 0;
    g_free(cache);
    if (!inside) return refuse(error, path, "not in the helper's preview cache");
    /* No link followed, and a FIFO or device never blocks or streams: a regular file of bounded size only. */
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return refuse(error, path, g_strerror(errno));
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 33 ||
        info.st_size > SZFRIENDS_GTK_THUMBNAIL_MAX_BYTES) {
        close(fd);
        return refuse(error, path, "not a regular file of a preview's size");
    }
    gsize size = (gsize)info.st_size, done = 0;
    guint8 *bytes = g_malloc(size);
    while (done < size) {
        ssize_t got = read(fd, bytes + done, size - done);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        done += (gsize)got;
    }
    close(fd);
    static const guint8 signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    /* The header says the size before anything is decoded, so nothing large is ever allocated for it, and it must be
     * the snapshot's own: AppKit refuses any other, so both apps show the same card (PROTOCOL.md § Thumbnails). */
    guint32 header_width = done == size ? be32(bytes + 16) : 0, header_height = done == size ? be32(bytes + 20) : 0;
    if (done != size || memcmp(bytes, signature, 8) != 0 || be32(bytes + 8) != 13 || memcmp(bytes + 12, "IHDR", 4) ||
        header_width != (guint32)width || header_height != (guint32)height) {
        g_free(bytes);
        return refuse(error, path, "not a PNG of the snapshot's width and height");
    }
    GBytes *data = g_bytes_new_take(bytes, size);
    GdkTexture *texture = gdk_texture_new_from_bytes(data, error);
    g_bytes_unref(data);
    if (texture && (gdk_texture_get_width(texture) != width || gdk_texture_get_height(texture) != height)) {
        g_object_unref(texture);
        return refuse(error, path, "decoded size differs from its header");
    }
    return texture;
}

void szfriends_gtk_thumbnail_box(gint64 width, gint64 height, int limit, int *box_width, int *box_height) {
    /* The same card in both apps (wave 6b drew 96 points here against AppKit's 64): a 192 px preview takes 64 points,
     * sharp at 2x and 3x, and a small picture is never blown up past one point per pixel. */
    double w = width > 0 ? (double)width : limit, h = height > 0 ? (double)height : limit;
    double scale = MIN(1.0, (double)limit / MAX(w, h));
    *box_width = MAX(1, (int)(w * scale + 0.5));
    *box_height = MAX(1, (int)(h * scale + 0.5));
}

GIcon *szfriends_gtk_file_type_icon(const char *extension) {
    gboolean usable = extension && *extension && strlen(extension) <= 16;
    for (const char *p = extension; usable && *p; p++) usable = g_ascii_islower(*p) || g_ascii_isdigit(*p);
    char *name = usable ? g_strconcat("file.", extension, NULL) : NULL;
    /* By name only (no data): nothing of the file is read, and on macOS the content type is the system's UTI. */
    char *type = name ? g_content_type_guess(name, NULL, 0, NULL) : g_content_type_from_mime_type("text/plain");
    GIcon *icon = type ? g_content_type_get_icon(type) : NULL;
    g_free(type);
    g_free(name);
    return icon ? icon : g_themed_icon_new("text-x-generic");
}

/* ---- The preview's widget ---------------------------------------------------------------------------- */

/* Exactly the box the snapshot's width and height give, before and after the picture loads: a GtkPicture would ask
 * for the image's own pixel size once it has one, and the card would grow under the person's eyes. */
#define SZFRIENDS_GTK_TYPE_PREVIEW (szfriends_gtk_preview_get_type())
G_DECLARE_FINAL_TYPE(SZFriendsGtkPreview, szfriends_gtk_preview, SZFRIENDS_GTK, PREVIEW, GtkWidget)

struct _SZFriendsGtkPreview {
    GtkWidget parent;
    int width, height;
    GdkTexture *texture;
};

G_DEFINE_FINAL_TYPE(SZFriendsGtkPreview, szfriends_gtk_preview, GTK_TYPE_WIDGET)

static void preview_measure(GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum, int *natural,
                            int *minimum_baseline, int *natural_baseline) {
    (void)for_size, (void)minimum_baseline, (void)natural_baseline;
    SZFriendsGtkPreview *preview = SZFRIENDS_GTK_PREVIEW(widget);
    *minimum = *natural = orientation == GTK_ORIENTATION_HORIZONTAL ? preview->width : preview->height;
}

static void preview_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    SZFriendsGtkPreview *preview = SZFRIENDS_GTK_PREVIEW(widget);
    if (!preview->texture) return;
    graphene_rect_t box = GRAPHENE_RECT_INIT(0, 0, (float)gtk_widget_get_width(widget),
                                             (float)gtk_widget_get_height(widget));
    /* A 192 px preview in 64 points is drawn smaller on every screen (128 px at 2x): trilinear filtering averages the
     * pixels it drops, where linear filtering skips some and a page's thin text lines break up. A small preview
     * drawn larger keeps linear filtering, which does not blur it further. */
    int pixels = gtk_widget_get_width(widget) * gtk_widget_get_scale_factor(widget);
    GskScalingFilter filter = gdk_texture_get_width(preview->texture) > pixels ? GSK_SCALING_FILTER_TRILINEAR
                                                                               : GSK_SCALING_FILTER_LINEAR;
    gtk_snapshot_append_scaled_texture(snapshot, preview->texture, filter, &box);
}

static void preview_finalize(GObject *object) {
    g_clear_object(&SZFRIENDS_GTK_PREVIEW(object)->texture);
    G_OBJECT_CLASS(szfriends_gtk_preview_parent_class)->finalize(object);
}

static void szfriends_gtk_preview_class_init(SZFriendsGtkPreviewClass *klass) {
    GTK_WIDGET_CLASS(klass)->measure = preview_measure;
    GTK_WIDGET_CLASS(klass)->snapshot = preview_snapshot;
    G_OBJECT_CLASS(klass)->finalize = preview_finalize;
    /* Decorative: the item's accessible label already names the file. */
    gtk_widget_class_set_accessible_role(GTK_WIDGET_CLASS(klass), GTK_ACCESSIBLE_ROLE_PRESENTATION);
}

static void szfriends_gtk_preview_init(SZFriendsGtkPreview *preview) {
    (void)preview;
}

gboolean szfriends_gtk_preview_is_loaded(GtkWidget *widget) {
    return widget && SZFRIENDS_GTK_IS_PREVIEW(widget) && SZFRIENDS_GTK_PREVIEW(widget)->texture;
}

gboolean szfriends_gtk_is_preview(GtkWidget *widget) {
    return widget && SZFRIENDS_GTK_IS_PREVIEW(widget);
}

/* ---- Previews, loaded once per path for the page --------------------------------------------------- */

typedef struct {
    GdkTexture *texture;
    gboolean done;
    GPtrArray *waiting; /* gpointer * slots, each a weak pointer to a lead; slots never move when the array grows */
} SZFriendsGtkThumbnailEntry;

/* What a lead needs to fall back to the type's icon after its row's item is gone. */
typedef struct {
    SZFriendsGtkConversation *conversation;
    char *kind_label, *extension;
} SZFriendsGtkLeadFile;

static void lead_file_free(gpointer data) {
    SZFriendsGtkLeadFile *file = data;
    szfriends_gtk_conversation_unref(file->conversation);
    g_free(file->kind_label);
    g_free(file->extension);
    g_free(file);
}

static void slot_free(gpointer data) {
    gpointer *slot = data;
    if (*slot) g_object_remove_weak_pointer(G_OBJECT(*slot), slot);
    g_free(slot);
}

static void entry_free(gpointer data) {
    SZFriendsGtkThumbnailEntry *entry = data;
    g_ptr_array_unref(entry->waiting);
    g_clear_object(&entry->texture);
    g_free(entry);
}

static GtkWidget *icon_view(SZFriendsGtkConversation *conversation, const char *kind_label, const char *extension) {
    GIcon *icon = szfriends_gtk_file_type_icon(extension);
    GdkDisplay *display = conversation->content ? gtk_widget_get_display(conversation->content)
                                                : gdk_display_get_default();
    GtkWidget *view;
    if (display && gtk_icon_theme_has_gicon(gtk_icon_theme_get_for_display(display), icon)) {
        view = gtk_image_new_from_gicon(icon);
        gtk_image_set_pixel_size(GTK_IMAGE(view), SZFRIENDS_GTK_ICON_SIZE);
    } else {
        /* A theme without document icons: the kind label on a page shape, as the AppKit card draws it. */
        view = gtk_label_new(kind_label ? kind_label : "");
        gtk_widget_add_css_class(view, "szfriends-file-glyph");
        gtk_label_set_ellipsize(GTK_LABEL(view), PANGO_ELLIPSIZE_END);
        gtk_label_set_yalign(GTK_LABEL(view), 1);
    }
    g_object_unref(icon);
    gtk_widget_set_valign(view, GTK_ALIGN_START);
    return view;
}

static void lead_show(GtkWidget *lead, GdkTexture *texture) {
    GtkWidget *child = gtk_widget_get_first_child(lead);
    if (texture && child && SZFRIENDS_GTK_IS_PREVIEW(child)) {
        g_set_object(&SZFRIENDS_GTK_PREVIEW(child)->texture, texture);
        gtk_widget_add_css_class(lead, "szfriends-preview-loaded");
        gtk_widget_queue_draw(child);
        return;
    }
    /* Unreadable: the card becomes the one without a preview, the type's icon in the same place. */
    SZFriendsGtkLeadFile *file = g_object_get_data(G_OBJECT(lead), "szfriends-lead-file");
    if (!file) return;
    if (child) gtk_box_remove(GTK_BOX(lead), child);
    gtk_widget_remove_css_class(lead, "szfriends-preview");
    gtk_box_append(GTK_BOX(lead), icon_view(file->conversation, file->kind_label, file->extension));
}

/* What a load needs, copied for the worker thread; `key` names its entry: the path and the size it must have. */
typedef struct {
    char *key, *path, *state_dir;
    gint64 width, height;
} SZFriendsGtkThumbnailLoad;

static void thumbnail_load_free(gpointer data) {
    SZFriendsGtkThumbnailLoad *load = data;
    g_free(load->key);
    g_free(load->path);
    g_free(load->state_dir);
    g_free(load);
}

static void loaded(GObject *source, GAsyncResult *result, gpointer data) {
    (void)source;
    SZFriendsGtkConversation *conversation = data;
    const SZFriendsGtkThumbnailLoad *load = g_task_get_task_data(G_TASK(result));
    GError *error = NULL;
    GdkTexture *texture = g_task_propagate_pointer(G_TASK(result), &error);
    SZFriendsGtkThumbnailEntry *entry = conversation->page && conversation->thumbnails
                                            ? g_hash_table_lookup(conversation->thumbnails, load->key) : NULL;
    if (error) g_debug("Shenzhen Friends: %s", error->message); /* shows as no preview, by design */
    g_clear_error(&error);
    if (entry) {
        entry->done = TRUE;
        entry->texture = texture ? g_object_ref(texture) : NULL;
        GPtrArray *waiting = g_steal_pointer(&entry->waiting);
        entry->waiting = g_ptr_array_new_with_free_func(slot_free);
        for (guint i = 0; i < waiting->len; i++) {
            gpointer *slot = g_ptr_array_index(waiting, i);
            if (*slot) lead_show(*slot, texture);
        }
        g_ptr_array_unref(waiting);
    }
    g_clear_object(&texture);
    szfriends_gtk_conversation_unref(conversation);
}

static void load_in_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancellable) {
    (void)task, (void)source, (void)cancellable;
    const SZFriendsGtkThumbnailLoad *load = data;
    GError *error = NULL;
    GdkTexture *texture = szfriends_gtk_thumbnail_load(load->path, load->state_dir, load->width, load->height, &error);
    if (texture) g_task_return_pointer(task, texture, g_object_unref);
    else g_task_return_error(task, error);
}

/* Once per path and size for the page: a snapshot that gives the same path another size loads it again, and is
 * refused unless the file has that size too. */
static void request_preview(SZFriendsGtkConversation *conversation, GtkWidget *lead,
                            const SZFriendsGtkThumbnail *thumbnail) {
    if (!conversation->thumbnails)
        conversation->thumbnails = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, entry_free);
    char *key = g_strdup_printf("%" G_GINT64_FORMAT "x%" G_GINT64_FORMAT " %s", thumbnail->width, thumbnail->height,
                                thumbnail->path);
    SZFriendsGtkThumbnailEntry *entry = g_hash_table_lookup(conversation->thumbnails, key);
    if (entry && entry->done) {
        g_free(key);
        lead_show(lead, entry->texture);
        return;
    }
    if (!entry) {
        entry = g_new0(SZFriendsGtkThumbnailEntry, 1);
        entry->waiting = g_ptr_array_new_with_free_func(slot_free);
        g_hash_table_insert(conversation->thumbnails, g_strdup(key), entry);
        SZFriendsGtkThumbnailLoad *load = g_new0(SZFriendsGtkThumbnailLoad, 1);
        load->key = g_strdup(key);
        load->path = g_strdup(thumbnail->path);
        load->state_dir = g_strdup(conversation->state_dir);
        load->width = thumbnail->width, load->height = thumbnail->height;
        GTask *task = g_task_new(NULL, conversation->cancellable, loaded, szfriends_gtk_conversation_ref(conversation));
        g_task_set_task_data(task, load, thumbnail_load_free);
        g_task_run_in_thread(task, load_in_thread);
        g_object_unref(task);
    }
    g_free(key);
    gpointer *slot = g_new(gpointer, 1);
    *slot = lead;
    g_object_add_weak_pointer(G_OBJECT(lead), slot);
    g_ptr_array_add(entry->waiting, slot);
}

/* The leading slot: the preview's box, sized before it loads, or the type's icon. */
static GtkWidget *lead_new(SZFriendsGtkConversation *conversation, const SZFriendsGtkConversationItem *item) {
    GtkWidget *lead = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_valign(lead, GTK_ALIGN_START);
    const SZFriendsGtkThumbnail *thumbnail = item->thumbnail;
    if (!thumbnail || !thumbnail->path || !*thumbnail->path) {
        gtk_box_append(GTK_BOX(lead), icon_view(conversation, item->file.kind_label, item->file.extension));
        return lead;
    }
    int width = 0, height = 0;
    szfriends_gtk_thumbnail_box(thumbnail->width, thumbnail->height, SZFRIENDS_GTK_PREVIEW_LIMIT, &width, &height);
    gtk_widget_add_css_class(lead, "szfriends-preview");
    gtk_widget_set_overflow(lead, GTK_OVERFLOW_HIDDEN);
    SZFriendsGtkPreview *preview = g_object_new(SZFRIENDS_GTK_TYPE_PREVIEW, NULL);
    preview->width = width, preview->height = height;
    gtk_box_append(GTK_BOX(lead), GTK_WIDGET(preview));
    SZFriendsGtkLeadFile *file = g_new0(SZFriendsGtkLeadFile, 1);
    file->conversation = szfriends_gtk_conversation_ref(conversation);
    file->kind_label = g_strdup(item->file.kind_label);
    file->extension = g_strdup(item->file.extension);
    g_object_set_data_full(G_OBJECT(lead), "szfriends-lead-file", file, lead_file_free);
    request_preview(conversation, lead, thumbnail);
    return lead;
}

/* ---- The card ------------------------------------------------------------------------------------ */

static GtkWidget *label(const char *text, const char *css_class) {
    GtkWidget *widget = gtk_label_new(text ? text : "");
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(widget), PANGO_WRAP_WORD_CHAR);
    if (css_class) gtk_widget_add_css_class(widget, css_class);
    gtk_widget_set_visible(widget, text && *text);
    return widget;
}

static const char *status_class(SZFriendsGtkTransferState state) {
    if (state == SZFRIENDS_GTK_TRANSFER_DELIVERED || state == SZFRIENDS_GTK_TRANSFER_RECEIVED)
        return "szfriends-success";
    return state == SZFRIENDS_GTK_TRANSFER_FAILED ? "szfriends-failure" : "szfriends-secondary";
}

/* The status words, and while a file copies here from another of the person's computers the route it comes by after
 * them, drawn as the conversation header's: the route's icon, then its words ("… · 25% · Nearby, on your network").
 * The separator, icon and words are one unit, so a narrow card moves them to the next line together and never ends
 * a line on a dot. */
static GtkWidget *status_new(const SZFriendsGtkConversationItem *item) {
    GtkWidget *status = label(item->status_label, status_class(item->state));
    const SZFriendsGtkRoute *route = item->route;
    if (!route || !route->label || !*route->label) return status;
    GtkWidget *line = adw_wrap_box_new();
    adw_wrap_box_set_child_spacing(ADW_WRAP_BOX(line), 4);
    adw_wrap_box_append(ADW_WRAP_BOX(line), status);
    GtkWidget *unit = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    if (item->status_label && *item->status_label)
        gtk_box_append(GTK_BOX(unit), label("·", "szfriends-secondary"));
    GtkWidget *route_line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_set_name(route_line, "szfriends.transfer.route");
    const char *css_class = szfriends_gtk_route_class(route->kind);
    SZFriendsGtkGlyphKind kind = szfriends_gtk_route_glyph(route->kind, route->method);
    GtkWidget *glyph = szfriends_gtk_glyph_new(kind, 11);
    gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class(glyph, css_class);
    gtk_widget_set_visible(glyph, kind != SZFRIENDS_GTK_GLYPH_NONE);
    GtkWidget *words = gtk_label_new(route->label);
    gtk_widget_add_css_class(words, css_class);
    gtk_box_append(GTK_BOX(route_line), glyph);
    gtk_box_append(GTK_BOX(route_line), words);
    gtk_box_append(GTK_BOX(unit), route_line);
    adw_wrap_box_append(ADW_WRAP_BOX(line), unit);
    return line;
}

GtkWidget *szfriends_gtk_transfer_row_new(SZFriendsGtkConversation *conversation,
                                          const SZFriendsGtkConversationItem *item) {
    gboolean outgoing = item->direction == SZFRIENDS_GTK_DIRECTION_OUT;
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_set_halign(row, outgoing ? GTK_ALIGN_END : GTK_ALIGN_START);
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(card, "szfriends-transfer-card");
    if (item->highlighted) gtk_widget_add_css_class(card, "szfriends-highlighted");
    gtk_widget_set_size_request(card, 280, -1);
    gtk_box_append(GTK_BOX(row), card);

    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_box_append(GTK_BOX(top), lead_new(conversation, item));
    GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(texts, TRUE);
    GtkWidget *name = label(item->file.name, "szfriends-file-name");
    gtk_label_set_wrap(GTK_LABEL(name), FALSE);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_MIDDLE);
    gtk_box_append(GTK_BOX(texts), name);
    gtk_box_append(GTK_BOX(texts), label(item->meta_label, "szfriends-secondary"));
    gtk_box_append(GTK_BOX(top), texts);
    /* Progress by route (PROTOCOL.md § Fast transfers): the routes beside the name, the split bar, the amount and
     * time left under it, then the detail line, which takes the status line's place and its links. */
    const SZFriendsGtkProgress *by_route = item->progress && *item->progress->amount_label ? item->progress : NULL;
    if (by_route) gtk_box_append(GTK_BOX(top), szfriends_gtk_transfer_routes_new(by_route));
    gtk_box_append(GTK_BOX(card), top);
    gtk_box_append(GTK_BOX(card), label(item->route_note, NULL));
    if (by_route) {
        gtk_box_append(GTK_BOX(card), szfriends_gtk_split_bar_new(by_route));
        GtkWidget *amounts = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *amount = label(by_route->amount_label, "szfriends-secondary");
        gtk_label_set_wrap(GTK_LABEL(amount), FALSE);
        gtk_label_set_ellipsize(GTK_LABEL(amount), PANGO_ELLIPSIZE_END);
        gtk_widget_add_css_class(amount, "numeric");
        gtk_widget_set_hexpand(amount, TRUE);
        gtk_box_append(GTK_BOX(amounts), amount);
        GtkWidget *left = label(by_route->time_left_label, "szfriends-secondary");
        gtk_label_set_wrap(GTK_LABEL(left), FALSE);
        gtk_widget_add_css_class(left, "numeric");
        gtk_box_append(GTK_BOX(amounts), left);
        gtk_box_append(GTK_BOX(card), amounts);
    } else if (item->progress) {
        GtkWidget *bar = gtk_progress_bar_new();
        if (item->progress->determinate)
            gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), CLAMP(item->progress->fraction, 0, 1));
        else gtk_progress_bar_pulse(GTK_PROGRESS_BAR(bar));
        if (*item->progress->accessibility_label)
            gtk_accessible_update_property(GTK_ACCESSIBLE(bar), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                           item->progress->accessibility_label, -1);
        gtk_box_append(GTK_BOX(card), bar);
    }

    /* Link actions (Cancel, Show in Shenzhen Files) share the status line, right-aligned; buttons get their own row. */
    GtkWidget *status_line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *status = by_route ? label(by_route->detail_label, "szfriends-secondary") : status_new(item);
    gtk_widget_set_hexpand(status, TRUE);
    gtk_box_append(GTK_BOX(status_line), status);
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    SZFriendsGtkActionIds ids = {.transfer_id = item->transfer_id, .item_id = item->item_id};
    gboolean cancels = szfriends_gtk_conversation_helper_cancels(conversation);
    gboolean status_shown = by_route ? by_route->detail_label && *by_route->detail_label : *item->status_label;
    for (gsize i = 0; i < item->n_actions; i++) {
        const SZFriendsGtkAction *action = &item->actions[i];
        if (!szfriends_gtk_item_shows_action(action, cancels)) continue;
        GtkWidget *button = szfriends_gtk_action_button_new(conversation, action, &ids, NULL, NULL, NULL);
        gboolean link = action->style == SZFRIENDS_GTK_STYLE_LINK || action->style == SZFRIENDS_GTK_STYLE_DESTRUCTIVE;
        gtk_widget_set_valign(button, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(link ? status_line : buttons), button);
        status_shown = status_shown || link;
    }
    gtk_widget_set_visible(status_line, status_shown);
    gtk_box_append(GTK_BOX(card), status_line);
    gtk_widget_set_visible(buttons, gtk_widget_get_first_child(buttons) != NULL);
    gtk_box_append(GTK_BOX(card), buttons);

    /* A file the assistant sent says so on the time line under its card, before the time, as a bubble does. */
    GtkWidget *time_line = adw_wrap_box_new();
    adw_wrap_box_set_child_spacing(ADW_WRAP_BOX(time_line), 10);
    adw_wrap_box_set_align(ADW_WRAP_BOX(time_line), outgoing ? 1 : 0);
    gtk_widget_add_css_class(time_line, "szfriends-time-line");
    if (item->assistant_label && *item->assistant_label)
        adw_wrap_box_append(ADW_WRAP_BOX(time_line), szfriends_gtk_assistant_label_new(item->assistant_label));
    if (item->time_label && *item->time_label) adw_wrap_box_append(ADW_WRAP_BOX(time_line),
                                                                   label(item->time_label, NULL));
    gtk_widget_set_visible(time_line, gtk_widget_get_first_child(time_line) != NULL);
    gtk_box_append(GTK_BOX(row), time_line);
    return row;
}
