/* The details, profile and Settings pages without a display: the crop square, which photos the views decode, the
 * EXIF turn, the arming rule, and the intents built from what was typed or placed. */

#include "szfriends_gtk_details_probe.h"
#include "gtk/szfriends_gtk_crop.h"
#include "gtk/szfriends_gtk_details_page.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static JsonObject *fields_of(szfriends_intent *intent) {
    char *json = intent ? szfriends_intent_fields_json(intent) : NULL;
    JsonObject *fields = json ? szfriends_gtk_json_object_from_text(json, -1) : NULL;
    szfriends_free(json);
    return fields;
}

static void test_geometry(void) {
    SZFriendsGtkCropGeometry crop;
    szfriends_gtk_crop_init(&crop, 4000, 3000);
    EXPECT(crop.zoom == 1 && szfriends_gtk_crop_side(&crop) == 3000 && crop.x == 500 && crop.y == 0,
           "a landscape photo starts centred on its whole shorter side (%.0f,%.0f)", crop.x, crop.y);
    szfriends_gtk_crop_set_zoom(&crop, 2);
    EXPECT(szfriends_gtk_crop_side(&crop) == 1500 && crop.x == 1250 && crop.y == 750,
           "zooming keeps the centre (%.0f,%.0f)", crop.x, crop.y);
    szfriends_gtk_crop_set_zoom(&crop, 9);
    EXPECT(crop.zoom == SZFRIENDS_GTK_CROP_MAX_ZOOM, "zoom stops at 4");
    szfriends_gtk_crop_set_zoom(&crop, 0.2);
    EXPECT(crop.zoom == 1 && crop.x == 500 && crop.y == 0, "and at 1, back inside the photo (%.0f,%.0f)", crop.x,
           crop.y);
    /* 3000 px under 200 on screen: 15 px a point. Dragging right shows more of the left. */
    szfriends_gtk_crop_drag(&crop, 500, 0, 20, 0);
    EXPECT(crop.x == 200 && crop.y == 0, "the photo follows the pointer (%.0f)", crop.x);
    szfriends_gtk_crop_drag(&crop, 500, 0, -500, -500);
    EXPECT(crop.x == 1000 && crop.y == 0, "the square never leaves the photo (%.0f,%.0f)", crop.x, crop.y);
    szfriends_gtk_crop_init(&crop, 1001, 1003);
    szfriends_gtk_crop_set_zoom(&crop, 3);
    szfriends_crop square = szfriends_gtk_crop_square(&crop);
    EXPECT(square.side == 333 && square.x >= 0 && square.y >= 0 && square.x + square.side <= 1001 &&
               square.y + square.side <= 1003, "whole pixels inside the photo (%lld %lld %lld)", (long long)square.x,
           (long long)square.y, (long long)square.side);
    szfriends_gtk_crop_init(&crop, 2, 2);
    szfriends_gtk_crop_set_zoom(&crop, 4);
    square = szfriends_gtk_crop_square(&crop);
    EXPECT(square.side == 1 && square.x <= 1 && square.y <= 1, "a tiny photo still crops a pixel the helper takes");
    szfriends_gtk_crop_init(&crop, 4000, 3000);
    JsonObject *fields = fields_of(szfriends_gtk_crop_intent("/p/me.jpg", &crop));
    JsonObject *picture = fields ? json_object_get_object_member(fields, "picture") : NULL;
    JsonObject *sent = picture && json_object_has_member(picture, "crop") ? json_object_get_object_member(picture,
                                                                                                      "crop")
                                                                         : NULL;
    EXPECT(sent && !g_strcmp0(json_object_get_string_member(picture, "kind"), "image") &&
               !g_strcmp0(json_object_get_string_member(picture, "path"), "/p/me.jpg") &&
               json_object_get_int_member(sent, "x") == 500 && json_object_get_int_member(sent, "side") == 3000,
           "Use Picture sends the path and the square, nothing decoded");
    if (fields) json_object_unref(fields);
    fields = fields_of(szfriends_gtk_crop_intent("/p/me.heic", NULL));
    picture = fields ? json_object_get_object_member(fields, "picture") : NULL;
    EXPECT(picture && (!json_object_has_member(picture, "crop") || json_object_get_null_member(picture, "crop")),
           "a photo the views cannot show goes uncropped, for the helper to decide");
    if (fields) json_object_unref(fields);
}

static guint32 crc32_of(const guint8 *bytes, gsize length) {
    guint32 crc = 0xFFFFFFFFu;
    for (gsize i = 0; i < length; i++) {
        crc ^= bytes[i];
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1)));
    }
    return ~crc;
}

static void put32(GByteArray *out, guint32 value) {
    guint8 bytes[4] = {value >> 24, value >> 16, value >> 8, value};
    g_byte_array_append(out, bytes, 4);
}

static void chunk(GByteArray *out, const char *type, const guint8 *data, guint32 length) {
    put32(out, length);
    gsize start = out->len;
    g_byte_array_append(out, (const guint8 *)type, 4);
    if (length) g_byte_array_append(out, data, length);
    put32(out, crc32_of(out->data + start, length + 4));
}

/* A PNG whose header declares width x height, padded to `size` bytes: what a decompression bomb looks like. */
static void write_declared_png(const char *path, guint32 width, guint32 height, gsize size) {
    GByteArray *out = g_byte_array_new();
    static const guint8 signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    g_byte_array_append(out, signature, 8);
    guint8 header[13] = {width >> 24, width >> 16, width >> 8, width, height >> 24, height >> 16, height >> 8, height,
                         8, 2, 0, 0, 0};
    chunk(out, "IHDR", header, 13);
    gsize padding = size > out->len + 24 ? size - out->len - 24 : 1;
    guint8 *zeros = g_malloc0(padding);
    chunk(out, "IDAT", zeros, (guint32)padding);
    g_free(zeros);
    chunk(out, "IEND", NULL, 0);
    g_file_set_contents(path, (const char *)out->data, out->len, NULL);
    g_byte_array_unref(out);
}

static char *write_image(const char *dir, const char *name, const char *type, int width, int height) {
    GdkPixbuf *pixbuf = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, width, height);
    gdk_pixbuf_fill(pixbuf, 0x3f6b4fff);
    char *path = g_build_filename(dir, name, NULL);
    EXPECT(gdk_pixbuf_save(pixbuf, path, type, NULL, NULL), "%s written", name);
    g_object_unref(pixbuf);
    return path;
}

/* An EXIF segment saying "turn a quarter clockwise" (orientation 6), right after the JPEG's start marker. */
static void add_orientation(const char *path) {
    static const guint8 exif[] = {0xFF, 0xE1, 0x00, 0x22, 'E', 'x', 'i', 'f', 0, 0, 'M', 'M', 0, 0x2A, 0, 0, 0, 8,
                                  0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0};
    char *text = NULL;
    gsize length = 0;
    g_file_get_contents(path, &text, &length, NULL);
    GByteArray *out = g_byte_array_new();
    g_byte_array_append(out, (const guint8 *)text, 2);
    g_byte_array_append(out, exif, sizeof exif);
    g_byte_array_append(out, (const guint8 *)text + 2, (guint)length - 2);
    g_file_set_contents(path, (const char *)out->data, out->len, NULL);
    g_byte_array_unref(out);
    g_free(text);
}

static void test_photos(void) {
    char *dir = szfg_temp_dir("photos");
    char *png = write_image(dir, "wide.png", "png", 300, 200);
    SZFriendsGtkPhotoCheck check = szfriends_gtk_photo_check(png);
    EXPECT(check.showable && check.width == 300 && check.height == 200, "a PNG within the limits is shown");
    char *jpeg = write_image(dir, "turned.jpg", "jpeg", 200, 100);
    add_orientation(jpeg);
    cairo_surface_t *surface = szfriends_gtk_photo_decode(jpeg, &check);
    EXPECT(surface && check.showable && check.width == 100 && check.height == 200 &&
               cairo_image_surface_get_width(surface) == 100 && cairo_image_surface_get_height(surface) == 200,
           "a JPEG turned by its EXIF is cropped in displayed pixels (%dx%d)", check.width, check.height);
    if (surface) cairo_surface_destroy(surface);
    char *bmp = write_image(dir, "old.bmp", "bmp", 40, 40);
    EXPECT(!szfriends_gtk_photo_check(bmp).showable, "a format the helper refuses is never decoded here");
    char *link = g_build_filename(dir, "link.png", NULL), *fifo = g_build_filename(dir, "pipe.png", NULL);
    EXPECT(symlink(png, link) == 0 && !szfriends_gtk_photo_check(link).showable, "a link is the helper's to refuse");
    /* A pipe would block whoever opens it: lstat must turn it away first, so this returns at once. */
    EXPECT(mkfifo(fifo, 0600) == 0 && !szfriends_gtk_photo_check(fifo).showable, "a pipe is never opened");
    EXPECT(!szfriends_gtk_photo_check(dir).showable, "nor a folder");
    char *bomb = g_build_filename(dir, "bomb.png", NULL), *wide = g_build_filename(dir, "huge.png", NULL);
    write_declared_png(bomb, 8192, 8192, 4096);
    check = szfriends_gtk_photo_check(bomb);
    EXPECT(check.width == 8192 && !check.showable, "a few kilobytes declaring 8192 x 8192 is a bomb (%d)",
           check.width);
    write_declared_png(wide, 5000, 5000, 512 * 1024);
    check = szfriends_gtk_photo_check(wide);
    EXPECT(check.width == 5000 && !check.showable, "an honest 25-megapixel PNG would decode at 100 MB: not here");
    write_declared_png(wide, 9000, 10, 4096);
    EXPECT(!szfriends_gtk_photo_check(wide).showable, "over 8192 px on a side");
    write_declared_png(wide, 1200, 900, SZFRIENDS_GTK_PHOTO_MAX_BYTES + 1);
    EXPECT(!szfriends_gtk_photo_check(wide).showable, "over 5 MiB");
    write_declared_png(wide, 1200, 900, SZFRIENDS_GTK_PHOTO_MAX_BYTES - 64);
    EXPECT(szfriends_gtk_photo_check(wide).showable, "just under 5 MiB is fine");
    char *paths[] = {png, jpeg, bmp, link, fifo, bomb, wide};
    for (gsize i = 0; i < G_N_ELEMENTS(paths); i++) g_free(paths[i]);
    szfg_remove_tree(dir);
    g_free(dir);
}

/* The details buttons arm through the list's rule (szfriends_gtk_row.h); its clock is checked in the probes. */
static void test_arming(void) {
    const gint64 double_click = 400 * 1000;
    EXPECT(szfriends_gtk_arm_accepts_confirm(0, 500 * 1000, 1, double_click), "a separate second click confirms");
    EXPECT(!szfriends_gtk_arm_accepts_confirm(0, 500 * 1000, 2, double_click), "never a double-click's second half");
    EXPECT(!szfriends_gtk_arm_accepts_confirm(0, 300 * 1000, 1, double_click),
           "nor two single clicks inside the double-click time");
}

static void test_typed(void) {
    EXPECT(szfriends_gtk_details_name_intent("Raph", "Raph") == NULL, "an unchanged name sends nothing");
    JsonObject *fields = fields_of(szfriends_gtk_details_name_intent("", "Raph"));
    EXPECT(fields && !g_strcmp0(json_object_get_string_member(fields, "name"), ""),
           "an emptied name clears it (friends then see the ID)");
    if (fields) json_object_unref(fields);
    fields = fields_of(szfriends_gtk_details_add_intent("  willow‑breeze\n"));
    EXPECT(fields && !g_strcmp0(json_object_get_string_member(fields, "friends_id"), "willow‑breeze"),
           "a pasted ID loses its spaces and keeps its hyphen for the helper to read");
    if (fields) json_object_unref(fields);
    EXPECT(szfriends_gtk_details_add_intent(" \t ") == NULL && szfriends_gtk_details_add_intent(NULL) == NULL,
           "nothing typed asks nobody");
}

void szfg_run_details_tests(void) {
    test_geometry();
    test_photos();
    test_arming();
    test_typed();
}
