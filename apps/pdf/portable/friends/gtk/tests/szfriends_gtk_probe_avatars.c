/* Avatars offscreen: animals from the set's SVGs on their circles, the helper's photos once read off the main thread,
 * and initials on the circle colour for anything this app cannot or may not draw (an index newer than its set, a
 * placeholder, a photo outside the helper's pictures/). Corners stay clear: it is a circle. */

#include "szfriends_gtk_probe.h"
#include "gtk/szfriends_gtk_avatars.h"

#include <glib/gstdio.h>
#include <string.h>

static void expect_near(const guint8 *pixel, guint32 rgb, const char *what) {
    int r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
    EXPECT(ABS(pixel[0] - r) + ABS(pixel[1] - g) + ABS(pixel[2] - b) < 24, "%s: #%02x%02x%02x, expected #%06x", what,
           pixel[0], pixel[1], pixel[2], rgb);
}

static gboolean photo_read(gpointer data) {
    return szfriends_gtk_avatar_cached_photo(data) != NULL;
}

void szfg_run_avatar_probes(void) {
    szfg_set_dark(FALSE);
    char *dir = szfg_temp_dir("avatars"), *saved = g_strdup(g_getenv(SZFRIENDS_ENV_STATE_DIR));
    g_setenv(SZFRIENDS_ENV_STATE_DIR, dir, TRUE); /* the helper's photos are in <state>/pictures/ */
    char *pictures = g_build_filename(dir, "pictures", NULL), *photo = g_build_filename(pictures, "photo.png", NULL);
    char *stray = g_build_filename(dir, "stray.png", NULL);
    g_mkdir(pictures, 0700);
    /* A stand-in for the helper's re-encoded photo: a solid colour, so the probe can tell it was drawn. */
    guint8 orange[16 * 16 * 4];
    for (gsize i = 0; i < sizeof orange; i += 4)
        orange[i] = 0xff, orange[i + 1] = 0x8c, orange[i + 2] = 0, orange[i + 3] = 0xff;
    GBytes *bytes = g_bytes_new(orange, sizeof orange);
    GdkTexture *texture = gdk_memory_texture_new(16, 16, GDK_MEMORY_R8G8B8A8, bytes, 16 * 4);
    EXPECT(gdk_texture_save_to_png(texture, photo) && gdk_texture_save_to_png(texture, stray),
           "the stand-in photo is written, in pictures/ and beside it");
    g_object_unref(texture);
    g_bytes_unref(bytes);
    SZFriendsGtkHost host = {.struct_size = sizeof host, .app_id = "a", .app_name = "A", .app_version = "1",
                             .reveal_in_name = "A", .animals_manifest_path = szfg_manifest};
    SZFriendsGtkLink *link = szfriends_gtk_link_new(&host);
    EXPECT(szfriends_gtk_link_animal_set(link) != NULL, "the link loads the set from the host's manifest");
    SZFriendsGtkAvatar avatars[] = {
        {.kind = SZFRIENDS_GTK_AVATAR_ANIMAL, .index = 0, .initials = "R", .color = "#5a4a7a"},
        {.kind = SZFRIENDS_GTK_AVATAR_ANIMAL, .index = 3, .initials = "LW", .color = "#7a3f4f"},
        {.kind = SZFRIENDS_GTK_AVATAR_ANIMAL, .index = 7, .initials = "MC", .color = "#3f6b4f"},
        {.kind = SZFRIENDS_GTK_AVATAR_ANIMAL, .index = 99, .initials = "KS", .color = "#2f6474"},
        {.kind = SZFRIENDS_GTK_AVATAR_PLACEHOLDER, .initials = "PN", .color = "#7a5a34"},
        {.kind = SZFRIENDS_GTK_AVATAR_IMAGE, .initials = "JB", .color = "#4a6a2f", .path = photo},
        {.kind = SZFRIENDS_GTK_AVATAR_IMAGE, .initials = "ST", .color = "#2f4a6a", .path = stray}};
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    for (gsize i = 0; i < G_N_ELEMENTS(avatars); i++) {
        GtkWidget *view = szfriends_gtk_avatar_new(link, 40);
        szfriends_gtk_avatar_set(view, &avatars[i]);
        gtk_box_append(GTK_BOX(row), view);
    }
    GtkWidget *window = szfg_probe_window(row);
    /* The decoded photo arrives through the main loop from a worker thread: nothing is decoded while views are set. */
    EXPECT(!szfriends_gtk_avatar_cached_photo(photo), "the photo is not decoded on the main thread");
    EXPECT(!szfriends_gtk_avatar_cached_photo(stray), "a photo outside pictures/ is never read");
    EXPECT(szfg_pump_until(photo_read, photo, 3000), "the photo is read off the main thread");
    GdkTexture *render = szfg_render(window, 40 * 7 + 8 * 6, 40, "avatars-light");
    SZFGPixels pixels = szfg_pixels(render);
    /* At scale 2 each avatar is 80 px wide, 96 px apart. */
    for (gsize i = 0; i < G_N_ELEMENTS(avatars); i++) {
        int left = (int)i * 96;
        expect_near(szfg_pixel(&pixels, left + 2, 2), 0xffffff, "a corner outside the circle is clear");
    }
    /* Initials on the circle colour: the colour fills it near its edge, the white letters sit in the middle. */
    expect_near(szfg_pixel(&pixels, 3 * 96 + 40, 6), 0x2f6474, "an index newer than the set draws its colour");
    int letters = szfg_count_differing(&pixels, 3 * 96 + 16, 16, 48, 48, (const guint8[]){0x2f, 0x64, 0x74, 255}, 60);
    EXPECT(letters > 80, "and the person's initials on it (%d pixels)", letters);
    expect_near(szfg_pixel(&pixels, 4 * 96 + 40, 6), 0x7a5a34, "a placeholder draws its colour");
    expect_near(szfg_pixel(&pixels, 5 * 96 + 40, 40), 0xff8c00, "a photo draws the photo");
    expect_near(szfg_pixel(&pixels, 6 * 96 + 40, 6), 0x2f4a6a, "a photo outside pictures/ draws its initials' colour");
    /* An animal is its SVG: it differs from a bare circle of its colour. */
    int drawn = szfg_count_differing(&pixels, 1 * 96 + 10, 10, 60, 60, (const guint8[]){0x7a, 0x3f, 0x4f, 255}, 60);
    EXPECT(drawn > 800, "the cat is drawn from its SVG (%d pixels differ from its circle)", drawn);
    szfg_pixels_free(&pixels);
    g_object_unref(render);
    szfg_set_dark(TRUE);
    render = szfg_render(window, 40 * 7 + 8 * 6, 40, "avatars-dark");
    g_object_unref(render);
    szfg_set_dark(FALSE);
    gtk_window_destroy(GTK_WINDOW(window));
    szfriends_gtk_link_free(link);
    if (saved) g_setenv(SZFRIENDS_ENV_STATE_DIR, saved, TRUE);
    else g_unsetenv(SZFRIENDS_ENV_STATE_DIR);
    g_free(saved), g_free(photo), g_free(stray), g_free(pictures);
    szfg_remove_tree(dir);
    g_free(dir);
}
