/* Avatar photos without a display (szfriends_gtk_avatars.h; security review, wave 6b): a snapshot's path is read only
 * when it lies directly in the helper's <state>/pictures/, never through a link, never a FIFO or an oversized file,
 * and never a picture whose header declares more than an avatar could need; the helper's JPEG and a PNG load. */

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_avatars.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void szfg_run_avatar_photo_tests(void);

static char *write_image(const char *dir, const char *name, const char *type, int side) {
    GdkPixbuf *pixbuf = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, side, side);
    gdk_pixbuf_fill(pixbuf, 0xff8c00ff);
    char *path = g_build_filename(dir, name, NULL);
    EXPECT(gdk_pixbuf_save(pixbuf, path, type, NULL, NULL), "%s written", name);
    g_object_unref(pixbuf);
    return path;
}

/* A PNG whose header declares `side` pixels a side, followed by nothing a decoder could use. */
static char *write_declared_png(const char *dir, const char *name, guint32 side) {
    guint8 bytes[64] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R'};
    for (int i = 0; i < 4; i++) bytes[16 + i] = bytes[20 + i] = (guint8)(side >> (24 - 8 * i));
    char *path = g_build_filename(dir, name, NULL);
    g_file_set_contents(path, (const char *)bytes, sizeof bytes, NULL);
    return path;
}

static gboolean loads(const char *path, const char *pictures, int side) {
    GError *error = NULL;
    GdkTexture *texture = szfriends_gtk_avatar_photo_load(path, pictures, &error);
    gboolean ok = texture && gdk_texture_get_width(texture) == side && gdk_texture_get_height(texture) == side;
    if (!texture && side) fprintf(stderr, "  %s\n", error ? error->message : "(no error)");
    g_clear_error(&error);
    g_clear_object(&texture);
    return ok;
}

static gboolean refused(const char *path, const char *pictures) {
    GError *error = NULL;
    GdkTexture *texture = szfriends_gtk_avatar_photo_load(path, pictures, &error);
    gboolean no = !texture && error;
    g_clear_error(&error);
    g_clear_object(&texture);
    return no;
}

static void test_containment(void) {
    EXPECT(szfriends_gtk_avatar_photo_allowed("/s/pictures/ab12.jpg", "/s/pictures"), "a name directly inside");
    const char *outside[] = {"/s/pictures", "/s/pictures/", "/s/pictures/sub/ab12.jpg", "/s/pictures/..",
                             "/s/pictures/.", "/s/picturesX/ab12.jpg", "/s/other/ab12.jpg", "pictures/ab12.jpg", NULL};
    for (gsize i = 0; outside[i]; i++)
        EXPECT(!szfriends_gtk_avatar_photo_allowed(outside[i], "/s/pictures"), "%s is not the helper's", outside[i]);
    EXPECT(!szfriends_gtk_avatar_photo_allowed(NULL, "/s/pictures") &&
               !szfriends_gtk_avatar_photo_allowed("/s/pictures/a.jpg", NULL) &&
               !szfriends_gtk_avatar_photo_allowed("/s/pictures/a.jpg", ""), "no path or no directory, nothing");
}

void szfg_run_avatar_photo_tests(void) {
    test_containment();
    char *state = szfg_temp_dir("avatar-photos"), *saved = g_strdup(g_getenv(SZFRIENDS_ENV_STATE_DIR));
    g_setenv(SZFRIENDS_ENV_STATE_DIR, state, TRUE);
    char *pictures = szfriends_gtk_avatar_pictures_dir();
    char *expected = g_build_filename(state, "pictures", NULL);
    EXPECT(!g_strcmp0(pictures, expected), "the helper's pictures/ in the state directory: %s", pictures);
    g_mkdir(pictures, 0700);
    char *jpeg = write_image(pictures, "a1b2.jpg", "jpeg", 256), *png = write_image(pictures, "c3d4.png", "png", 16);
    EXPECT(loads(jpeg, pictures, 256) && loads(png, pictures, 16), "the helper's JPEG, and a PNG, load");
    SZFriendsGtkAvatar photo = {.kind = SZFRIENDS_GTK_AVATAR_IMAGE, .initials = "JB", .color = "#4a6a2f", .path = jpeg};
    const char *drawn = NULL;
    EXPECT(szfriends_gtk_avatar_draw_kind(&photo, NULL, &drawn) == SZFRIENDS_GTK_AVATAR_DRAW_PHOTO && drawn == jpeg,
           "a photo in pictures/ draws as a photo");

    /* Elsewhere: outside pictures/, through a link, a FIFO, too large, or declaring more than an avatar needs. */
    char *outside = write_image(state, "e5f6.jpg", "jpeg", 64);
    char *link = g_build_filename(pictures, "link.jpg", NULL), *fifo = g_build_filename(pictures, "fifo.jpg", NULL);
    EXPECT(symlink(jpeg, link) == 0 && mkfifo(fifo, 0600) == 0, "a link and a FIFO in pictures/");
    char *large = g_build_filename(pictures, "large.jpg", NULL);
    char *padding = g_malloc0(300 * 1024);
    g_file_set_contents(large, padding, 300 * 1024, NULL);
    g_free(padding);
    char *bomb = write_declared_png(pictures, "bomb.png", 30000);
    char *wide = write_image(pictures, "wide.png", "png", 1100); /* a real picture, small on disk, too wide */
    char *text = g_build_filename(pictures, "text.jpg", NULL);
    g_file_set_contents(text, "not a picture, but long enough to read", -1, NULL);
    const char *bad[] = {outside, link, fifo, large, bomb, wide, text};
    for (gsize i = 0; i < G_N_ELEMENTS(bad); i++)
        EXPECT(refused(bad[i], pictures), "%s is refused", strrchr(bad[i], '/') + 1);
    photo.path = outside;
    EXPECT(szfriends_gtk_avatar_draw_kind(&photo, NULL, &drawn) == SZFRIENDS_GTK_AVATAR_DRAW_INITIALS && !drawn,
           "a photo anywhere else draws as initials");

    g_free(outside), g_free(link), g_free(fifo), g_free(large), g_free(bomb), g_free(wide), g_free(text);
    g_free(jpeg), g_free(png), g_free(pictures), g_free(expected);
    if (saved) g_setenv(SZFRIENDS_ENV_STATE_DIR, saved, TRUE);
    else g_unsetenv(SZFRIENDS_ENV_STATE_DIR);
    g_free(saved);
    szfg_remove_tree(state);
    g_free(state);
}
