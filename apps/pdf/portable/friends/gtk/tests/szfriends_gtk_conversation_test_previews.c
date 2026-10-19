/* friends-gtk-conversation-check, display-free: previews (PROTOCOL.md § Thumbnails). A view decodes only a PNG of
 * exactly the snapshot's width and height (at most 192 px a side), directly in the helper's <state>/thumbnails/,
 * reached without following a link; anything else (missing, outside, a link, a FIFO, another format, another size,
 * too large, damaged) reads as no preview, and the card shows the type's icon, found from the file name's extension
 * alone. */

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_conversation.h"

#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* A PNG of `width` x `height` written by GDK, as the helper writes its own. */
static gboolean write_png(const char *path, int width, int height) {
    gsize stride = (gsize)width * 4;
    guint8 *pixels = g_malloc0(stride * (gsize)height);
    for (gsize i = 0; i < stride * (gsize)height; i += 4) pixels[i] = 0xc0, pixels[i + 1] = 0x40, pixels[i + 3] = 0xff;
    GBytes *bytes = g_bytes_new_take(pixels, stride * (gsize)height);
    GdkTexture *texture = gdk_memory_texture_new(width, height, GDK_MEMORY_R8G8B8A8, bytes, stride);
    gboolean saved = gdk_texture_save_to_png(texture, path);
    g_object_unref(texture);
    g_bytes_unref(bytes);
    return saved;
}

/* Refused when the snapshot says `width` x `height`. */
static void expect_refused_sized(const char *path, const char *state, gint64 width, gint64 height, const char *what) {
    GError *error = NULL;
    GdkTexture *texture = szfriends_gtk_thumbnail_load(path, state, width, height, &error);
    EXPECT(!texture && error, "%s: refused, so the type's icon shows", what);
    g_clear_object(&texture);
    g_clear_error(&error);
}

/* Refused with the size the good preview has, so only what is named fails. */
static void expect_refused(const char *path, const char *state, const char *what) {
    expect_refused_sized(path, state, 136, 192, what);
}

static void test_thumbnail_loading(void) {
    char *state = szfg_temp_dir("conv-preview");
    char *cache = g_build_filename(state, "thumbnails", NULL);
    g_mkdir(cache, 0700);
    char *good = g_build_filename(cache, "0f7d3b9e2c5a4168a4e0b7c91d26f835.png", NULL);
    EXPECT(write_png(good, 136, 192), "a preview written");
    GError *error = NULL;
    GdkTexture *texture = szfriends_gtk_thumbnail_load(good, state, 136, 192, &error);
    EXPECT(texture && gdk_texture_get_width(texture) == 136 && gdk_texture_get_height(texture) == 192,
           "the helper's preview loads: %s", error ? error->message : "");
    g_clear_object(&texture);
    g_clear_error(&error);
    /* Exactly the snapshot's size, as AppKit loads it: a preview of any other size shows the type's icon in both apps
     * rather than being stretched into the box laid out for the snapshot (UX verification, wave 6c). */
    expect_refused_sized(good, state, 135, 192, "a preview one pixel wider than the snapshot says");
    expect_refused_sized(good, state, 136, 191, "or one pixel taller");
    expect_refused_sized(good, state, 192, 136, "or turned on its side");
    expect_refused_sized(good, state, 0, 0, "a snapshot without a size");
    expect_refused_sized(good, state, -136, -192, "or with a nonsense one");
    char *wide = g_build_filename(cache, "wide.png", NULL);
    EXPECT(write_png(wide, 192, 100), "a landscape preview written");
    expect_refused_sized(wide, state, 135, 192, "a 192 x 100 PNG where the snapshot says 135 x 192");

    char *outside = g_build_filename(state, "elsewhere.png", NULL);
    write_png(outside, 10, 10);
    expect_refused(outside, state, "a PNG outside the cache");
    char *relative = g_strdup_printf("%s/../thumbnails/x.png", cache);
    expect_refused(relative, state, "a path climbing out and back");
    expect_refused(good, cache, "the right file under another state directory");
    char *missing = g_build_filename(cache, "missing.png", NULL);
    expect_refused(missing, state, "a file that is gone");
    char *link = g_build_filename(cache, "link.png", NULL);
    EXPECT(symlink(good, link) == 0, "a link planted in the cache");
    expect_refused(link, state, "a link, even to a good preview");
    char *fifo = g_build_filename(cache, "fifo.png", NULL);
    EXPECT(mkfifo(fifo, 0600) == 0, "a FIFO planted in the cache");
    expect_refused(fifo, state, "a FIFO, without blocking");
    char *folder = g_build_filename(cache, "folder.png", NULL);
    g_mkdir(folder, 0700);
    expect_refused(folder, state, "a folder");
    char *large = g_build_filename(cache, "large.png", NULL);
    write_png(large, 193, 20);
    expect_refused_sized(large, state, 193, 20, "a picture over 192 px a side, even when the snapshot agrees");
    char *jpeg = g_build_filename(cache, "jpeg.png", NULL);
    static const guint8 jfif[64] = {0xff, 0xd8, 0xff, 0xe0, 0, 16, 'J', 'F', 'I', 'F'};
    g_file_set_contents(jpeg, (const char *)jfif, sizeof jfif, NULL);
    expect_refused(jpeg, state, "another format under a .png name");
    char *damaged = g_build_filename(cache, "damaged.png", NULL), *bytes = NULL;
    gsize length = 0;
    if (g_file_get_contents(good, &bytes, &length, NULL)) {
        g_file_set_contents(damaged, bytes, (gssize)(length / 2), NULL); /* the header is fine, the data stops */
        expect_refused(damaged, state, "a PNG cut short");
        memset(bytes + 40, 0x5a, MIN(length - 40, 200)); /* the data is garbage */
        g_file_set_contents(damaged, bytes, (gssize)length, NULL);
        expect_refused(damaged, state, "a PNG with garbage data");
    }
    g_free(bytes);
    char *huge = g_build_filename(cache, "huge.png", NULL);
    FILE *file = fopen(huge, "wb");
    if (file) {
        fseek(file, 2 * 1024 * 1024, SEEK_SET);
        fputc(0, file);
        fclose(file);
    }
    expect_refused(huge, state, "a file larger than any preview");
    expect_refused(NULL, state, "no path");
    expect_refused(good, NULL, "no state directory");
    for (char **path = (char *[]){good, wide, outside, relative, missing, link, fifo, folder, large, jpeg, damaged,
                                  huge, NULL}; *path; path++)
        g_free(*path);
    g_free(cache);
    szfg_remove_tree(state);
    g_free(state);
}

static void test_boxes_and_icons(void) {
    /* Both apps lay a preview out at most 64 points on its longer side and never past one point per pixel
     * (PROTOCOL.md § Thumbnails; mac/SZFriendsFilePreview.m draws Kenji's 136 x 192 offer at 45 x 64). */
    static const struct {
        gint64 width, height;
        int box_width, box_height;
        const char *what;
    } boxes[] = {{136, 192, 45, 64, "a portrait preview is laid out before it loads"},
                 {192, 136, 64, 45, "and a landscape one"},
                 {192, 192, 64, 64, "a square one at the largest size the helper writes"},
                 {64, 64, 64, 64, "one exactly the box's size"},
                 {40, 30, 40, 30, "a small one keeps one point per pixel, never blown up"},
                 {192, 1, 64, 1, "a sliver keeps a point"},
                 {0, -4, 64, 64, "nonsense sizes still give a box"}};
    for (gsize i = 0; i < G_N_ELEMENTS(boxes); i++) {
        int width = 0, height = 0;
        szfriends_gtk_thumbnail_box(boxes[i].width, boxes[i].height, SZFRIENDS_GTK_PREVIEW_LIMIT, &width, &height);
        EXPECT(width == boxes[i].box_width && height == boxes[i].box_height, "%s: %" G_GINT64_FORMAT "x%"
               G_GINT64_FORMAT " px in %dx%d points, not %dx%d", boxes[i].what, boxes[i].width, boxes[i].height,
               boxes[i].box_width, boxes[i].box_height, width, height);
    }
    EXPECT(SZFRIENDS_GTK_PREVIEW_LIMIT == 64, "the 64-point box both apps use (%d)", SZFRIENDS_GTK_PREVIEW_LIMIT);

    struct {
        const char *extension, *expected;
    } icons[] = {{"pdf", "x-office-document"}, {"png", "image-x-generic"}, {"mp4", "video-x-generic"},
                 {"zip", "package-x-generic"}, {"PDF", "text-x-generic"}, {"../pdf", "text-x-generic"},
                 {"averyveryverylongextension", "text-x-generic"}, {NULL, "text-x-generic"},
                 {"", "text-x-generic"}};
    for (gsize i = 0; i < G_N_ELEMENTS(icons); i++) {
        GIcon *icon = szfriends_gtk_file_type_icon(icons[i].extension);
        const char *const *names = G_IS_THEMED_ICON(icon) ? g_themed_icon_get_names(G_THEMED_ICON(icon)) : NULL;
        EXPECT(names && g_strv_contains(names, icons[i].expected), "the icon for \"%s\" falls back to %s",
               icons[i].extension ? icons[i].extension : "(none)", icons[i].expected);
        g_object_unref(icon);
    }
}

void szfg_run_conversation_preview_tests(void) {
    test_thumbnail_loading();
    test_boxes_and_icons();
}
