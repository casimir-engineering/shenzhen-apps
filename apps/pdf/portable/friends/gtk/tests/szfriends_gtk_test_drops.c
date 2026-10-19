/* Drop classification on real files (display-free): files accept, folders refuse (packages and links to folders
 * too), so do other links, FIFOs and devices, a mixture refuses because one bad file sends none, and the host's own
 * types count by presence. Also the animal set's manifest and which picture an avatar draws. */

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_drops.h"

#include <gdk/gdk.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static GValue *file_list_value(const char *dir, const char *const *names) {
    GSList *files = NULL;
    for (const char *const *name = names; *name; name++)
        files = g_slist_append(files, g_file_new_build_filename(dir, *name, NULL));
    GValue *value = g_new0(GValue, 1);
    g_value_init(value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(value, gdk_file_list_new_from_list(files));
    g_slist_free_full(files, g_object_unref);
    return value;
}

static void value_free(GValue *value) {
    g_value_unset(value);
    g_free(value);
}

static SZFriendsGtkDropVerdict verdict_for(const char *dir, const char *const *names) {
    GValue *value = file_list_value(dir, names);
    SZFriendsGtkDropVerdict verdict = szfriends_gtk_drop_verdict(NULL, value);
    value_free(value);
    return verdict;
}

static GPtrArray *host_items(gpointer data, const GValue *value) {
    (void)data;
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    g_ptr_array_add(items, szfriends_gtk_host_item_new(g_value_get_string(value), "Open in this window", "PDF",
                                                       "/tmp/tab.pdf", "{\"source\":\"x\"}"));
    return items;
}

static void test_drop_classification(void) {
    char *dir = szfg_temp_dir("drops");
    char *file = g_build_filename(dir, "Site photos.pdf", NULL), *folder = g_build_filename(dir, "Site visit", NULL);
    char *package = g_build_filename(dir, "Notes.pages", NULL), *link = g_build_filename(dir, "Shortcut", NULL);
    char *second = g_build_filename(dir, "Plan.pdf", NULL);
    g_file_set_contents(file, "%PDF-1.7\n", -1, NULL);
    g_file_set_contents(second, "%PDF-1.7\n", -1, NULL);
    g_mkdir(folder, 0700);
    g_mkdir(package, 0700);
    EXPECT(symlink(folder, link) == 0, "a link to the folder");
    const char *one[] = {"Site photos.pdf", NULL}, *two[] = {"Site photos.pdf", "Plan.pdf", NULL};
    const char *dirs[] = {"Site visit", NULL}, *mixed[] = {"Site photos.pdf", "Site visit", NULL};
    const char *packages[] = {"Notes.pages", NULL}, *links[] = {"Shortcut", NULL}, *gone[] = {"Missing.pdf", NULL};
    EXPECT(verdict_for(dir, one) == SZFRIENDS_GTK_DROP_ACCEPT, "a file is accepted");
    EXPECT(verdict_for(dir, two) == SZFRIENDS_GTK_DROP_ACCEPT, "two files are accepted");
    EXPECT(verdict_for(dir, dirs) == SZFRIENDS_GTK_DROP_REFUSE_FOLDER, "a folder is refused");
    EXPECT(verdict_for(dir, mixed) == SZFRIENDS_GTK_DROP_REFUSE_FOLDER, "one folder refuses the whole drop");
    EXPECT(verdict_for(dir, packages) == SZFRIENDS_GTK_DROP_REFUSE_FOLDER, "a package is a folder on disk");
    EXPECT(verdict_for(dir, links) == SZFRIENDS_GTK_DROP_REFUSE_FOLDER, "a link to a folder is refused");
    EXPECT(verdict_for(dir, gone) == SZFRIENDS_GTK_DROP_ACCEPT, "a vanished file is left to the helper's words");
    /* Security review, wave 6a: links and special files were accepted while the helper refuses them unread. */
    char *to_file = g_build_filename(dir, "Photos link", NULL), *dangling = g_build_filename(dir, "Old link", NULL);
    char *fifo = g_build_filename(dir, "Pipe", NULL);
    EXPECT(symlink(file, to_file) == 0 && symlink("/nonexistent/szfriends", dangling) == 0 && mkfifo(fifo, 0600) == 0,
           "a link to a file, a broken link and a FIFO");
    const char *file_links[] = {"Photos link", NULL}, *dangling_links[] = {"Old link", NULL};
    const char *fifos[] = {"Pipe", NULL}, *file_and_link[] = {"Site photos.pdf", "Photos link", NULL};
    const char *folder_and_link[] = {"Photos link", "Site visit", NULL};
    EXPECT(verdict_for(dir, file_links) == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE, "a link to a file is refused");
    EXPECT(verdict_for(dir, dangling_links) == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE, "a broken link is refused");
    EXPECT(verdict_for(dir, fifos) == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE, "a FIFO is refused");
    EXPECT(verdict_for(dir, file_and_link) == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE, "one link refuses the drop");
    EXPECT(verdict_for(dir, folder_and_link) == SZFRIENDS_GTK_DROP_REFUSE_FOLDER, "a folder's words come first");
    GSList *device = g_slist_append(NULL, g_file_new_for_path("/dev/null"));
    EXPECT(szfriends_gtk_drop_verdict_for_files(device) == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE, "a device is refused");
    g_slist_free_full(device, g_object_unref);
    EXPECT(szfriends_gtk_drop_refused(SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE) &&
               szfriends_gtk_drop_refused(SZFRIENDS_GTK_DROP_REFUSE_FOLDER) &&
               !szfriends_gtk_drop_refused(SZFRIENDS_GTK_DROP_ACCEPT) &&
               !szfriends_gtk_drop_refused(SZFRIENDS_GTK_DROP_NONE),
           "both refusals are refusals");
    GValue *refused = file_list_value(dir, file_and_link);
    SZFriendsGtkDropVerdict link_verdict = SZFRIENDS_GTK_DROP_NONE;
    GPtrArray *none = szfriends_gtk_drop_items(NULL, refused, &link_verdict);
    EXPECT(link_verdict == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE && none->len == 0, "a drop with a link sends nothing");
    g_ptr_array_unref(none);
    value_free(refused);
    g_unlink(to_file), g_unlink(dangling), g_unlink(fifo);
    g_free(to_file), g_free(dangling), g_free(fifo);
    GValue *value = file_list_value(dir, two);
    SZFriendsGtkDropVerdict verdict = SZFRIENDS_GTK_DROP_NONE;
    GPtrArray *items = szfriends_gtk_drop_items(NULL, value, &verdict);
    EXPECT(verdict == SZFRIENDS_GTK_DROP_ACCEPT && items->len == 2, "two items from two files");
    if (items->len == 2) {
        SZFriendsGtkHostItem *item = g_ptr_array_index(items, 0);
        EXPECT(strcmp(item->title, "Site photos.pdf") == 0 && strcmp(item->path, file) == 0 && !item->revision_json,
               "a dropped file is its name and path, a plain file");
    }
    g_ptr_array_unref(items);
    value_free(value);
    value = file_list_value(dir, mixed);
    items = szfriends_gtk_drop_items(NULL, value, &verdict);
    EXPECT(verdict == SZFRIENDS_GTK_DROP_REFUSE_FOLDER && items->len == 0, "a refused drop sends nothing");
    g_ptr_array_unref(items);
    value_free(value);
    GSList *remote = g_slist_append(NULL, g_file_new_for_uri("https://example.invalid/report.pdf"));
    EXPECT(szfriends_gtk_drop_verdict_for_files(remote) == SZFRIENDS_GTK_DROP_NONE, "a file with no path is nothing");
    g_slist_free_full(remote, g_object_unref);
    EXPECT(szfriends_gtk_drop_verdict_for_files(NULL) == SZFRIENDS_GTK_DROP_NONE, "an empty drop is nothing");
    /* The host's own type: accepted by presence, resolved once on the drop. */
    GType tab = G_TYPE_STRING;
    SZFriendsGtkHost host = {.struct_size = sizeof host, .extra_drop_types = &tab, .n_extra_drop_types = 1,
                             .items_from_drop = host_items};
    GValue text = G_VALUE_INIT;
    g_value_init(&text, G_TYPE_STRING);
    g_value_set_string(&text, "Contract.pdf");
    EXPECT(szfriends_gtk_drop_verdict(&host, &text) == SZFRIENDS_GTK_DROP_ACCEPT, "the host's type is accepted");
    EXPECT(szfriends_gtk_drop_verdict(NULL, &text) == SZFRIENDS_GTK_DROP_NONE, "without the host it is nothing");
    items = szfriends_gtk_drop_items(&host, &text, &verdict);
    EXPECT(items->len == 1 && strcmp(((SZFriendsGtkHostItem *)items->pdata[0])->title, "Contract.pdf") == 0 &&
               ((SZFriendsGtkHostItem *)items->pdata[0])->revision_json, "the host resolves its item with a revision");
    g_ptr_array_unref(items);
    g_value_unset(&text);
    gsize n = 0;
    GType *types = szfriends_gtk_drop_types(&host, &n);
    EXPECT(n == 2 && types[0] == GDK_TYPE_FILE_LIST && types[1] == G_TYPE_STRING, "files first, then the host's");
    g_free(types);
    g_unlink(link);
    g_free(file), g_free(folder), g_free(package), g_free(link), g_free(second);
    szfg_remove_tree(dir);
    g_free(dir);
}

static void test_animal_set(const char *manifest_path) {
    GError *error = NULL;
    SZFriendsGtkAnimalSet *set = szfriends_gtk_animal_set_load(manifest_path, &error);
    EXPECT(set != NULL, "the bundled set loads: %s", error ? error->message : "");
    g_clear_error(&error);
    if (!set) return;
    EXPECT(szfriends_gtk_animal_set_version(set) == 1 && szfriends_gtk_animal_set_count(set) == 24,
           "set 1, 24 animals");
    /* The colours the fixtures rely on (avatars/SZFriendsAvatars.h). */
    EXPECT(g_strcmp0(szfriends_gtk_animal_set_color(set, 3), "#7a3f4f") == 0, "the cat's circle colour");
    EXPECT(g_strcmp0(szfriends_gtk_animal_set_name(set, 7), "Fox") == 0, "index 7 is the fox");
    EXPECT(szfriends_gtk_animal_set_svg_path(set, 24) == NULL && szfriends_gtk_animal_set_svg_path(set, -1) == NULL,
           "no animal outside the set");
    SZFriendsGtkAvatar cat = {.kind = SZFRIENDS_GTK_AVATAR_ANIMAL, .index = 3, .initials = "LW", .color = "#7a3f4f"};
    const char *path = NULL;
    EXPECT(szfriends_gtk_avatar_draw_kind(&cat, set, &path) == SZFRIENDS_GTK_AVATAR_DRAW_ANIMAL && path &&
               g_str_has_suffix(path, "03-cat.svg"), "an animal draws its SVG");
    SZFriendsGtkAvatar newer = cat;
    newer.index = 99;
    EXPECT(szfriends_gtk_avatar_draw_kind(&newer, set, &path) == SZFRIENDS_GTK_AVATAR_DRAW_INITIALS && !path,
           "an index newer than this set draws initials");
    SZFriendsGtkAvatar photo = {.kind = SZFRIENDS_GTK_AVATAR_IMAGE, .path = "relative.jpg"};
    EXPECT(szfriends_gtk_avatar_draw_kind(&photo, set, NULL) == SZFRIENDS_GTK_AVATAR_DRAW_INITIALS,
           "a photo path must lie in the helper's pictures/");
    EXPECT(szfriends_gtk_avatar_draw_kind(&cat, NULL, NULL) == SZFRIENDS_GTK_AVATAR_DRAW_INITIALS,
           "without a set every animal is initials");
    szfriends_gtk_animal_set_free(set);
    GdkRGBA rgba;
    EXPECT(szfriends_gtk_parse_hex_color("#7a3f4f", &rgba) && rgba.red > 0.47f && rgba.red < 0.49f, "#rrggbb");
    EXPECT(!szfriends_gtk_parse_hex_color("red", NULL) && !szfriends_gtk_parse_hex_color("#7a3f4", NULL) &&
               !szfriends_gtk_parse_hex_color("rgb(1,2,3)", NULL), "nothing looser than #rrggbb");
    /* Damaged manifests: a packaging bug, refused with a reason. */
    char *dir = szfg_temp_dir("manifest"), *bad = g_build_filename(dir, "manifest.json", NULL);
    const char *cases[] = {"[1]", "{\"set\":1,\"count\":1,\"animals\":[{\"index\":0,\"name\":\"Goose\","
                           "\"color\":\"#5a4a7a\",\"svg\":\"../../etc/x.svg\",\"pdf\":\"pdf/00.pdf\"}]}",
                           "{\"set\":1,\"count\":2,\"animals\":[{\"index\":0,\"name\":\"Goose\",\"color\":\"#5a4a7a\","
                           "\"svg\":\"svg/00.svg\",\"pdf\":\"pdf/00.pdf\"}]}",
                           "{\"set\":0,\"count\":0,\"animals\":[]}"};
    for (gsize i = 0; i < G_N_ELEMENTS(cases); i++) {
        g_file_set_contents(bad, cases[i], -1, NULL);
        set = szfriends_gtk_animal_set_load(bad, &error);
        EXPECT(set == NULL && error != NULL, "damaged manifest %zu is refused", i);
        g_clear_error(&error);
        szfriends_gtk_animal_set_free(set);
    }
    g_free(bad);
    szfg_remove_tree(dir);
    g_free(dir);
    SZFriendsGtkHost host = {.struct_size = sizeof host,
                             .helper_path = "/Applications/Shenzhen Files.app/Contents/Helpers/Shenzhen Friends.app"
                                            "/Contents/MacOS/Shenzhen Friends"};
    char *derived = szfriends_gtk_animals_manifest_path(&host);
    EXPECT(g_strcmp0(derived, "/Applications/Shenzhen Files.app/Contents/Resources/Friends/animals/manifest.json") == 0,
           "the set is found in the host app's Resources: %s", derived);
    g_free(derived);
}

void szfg_run_drop_tests(void) {
    test_drop_classification();
}

void szfg_run_avatar_photo_tests(void); /* szfriends_gtk_test_avatars.c */

void szfg_run_avatar_data_tests(const char *manifest_path) {
    test_animal_set(manifest_path);
    szfg_run_avatar_photo_tests();
}
