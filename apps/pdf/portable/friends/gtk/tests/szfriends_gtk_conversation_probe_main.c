/* friends-gtk-conversation-check, widget probes (szfriends_gtk_conversation_probe.h): their harness and their main.
 * Needs a logged-in session for GDK's display; never maps a window and never launches either app.
 *
 * Usage: SZFriendsGtkConversationProbes <fixtures dir> <animals manifest.json> <renders dir> */

#include "szfriends_gtk_conversation_probe.h"

#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <ApplicationServices/ApplicationServices.h>
int szfriends_gtk_quiet_transform_calls(void); /* tests/szfriends_gtk_quiet.c */
#endif

SZFGConvRecords szfg_conv_records;

/* ---- The host ------------------------------------------------------------------------------------------- */

static void attachable_items(gpointer host_data, GtkWindow *window, const char *query, GCancellable *cancellable,
                             SZFriendsGtkItemsReady ready, gpointer ready_data) {
    (void)host_data, (void)window, (void)cancellable;
    static const char *const titles[][3] = {{"Site photos.pdf", "Selected in Downloads", "PDF"},
                                            {"Supplier pricing.md", "In this folder", "MD"},
                                            {"Bracket drawing rev B.pdf", "In this folder", "PDF"}};
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    for (gsize i = 0; i < G_N_ELEMENTS(titles); i++) {
        char *title = g_utf8_strdown(titles[i][0], -1), *wanted = g_utf8_strdown(query ? query : "", -1);
        if (strstr(title, wanted)) {
            char *path = g_build_filename(g_get_tmp_dir(), titles[i][0], NULL);
            g_ptr_array_add(items, szfriends_gtk_host_item_new(titles[i][0], titles[i][1], titles[i][2], path, NULL));
            g_free(path);
        }
        g_free(title);
        g_free(wanted);
    }
    ready(items, ready_data); /* at once, as Files answers for its selection and folder */
}

static void reveal_file(gpointer host_data, GtkWindow *window, const char *path) {
    (void)host_data, (void)window;
    g_ptr_array_add(szfg_conv_records.revealed, g_strdup(path));
}

static void open_uri(const char *uri, gpointer data) {
    (void)data;
    g_ptr_array_add(szfg_conv_records.opened, g_strdup(uri));
}

static void record_popup(GtkPopover *popover) {
    g_ptr_array_add(szfg_conv_records.popovers, popover);
}

/* Details belong to another area's suite; here a page with a title stands in, so this suite tests only that the
 * name opens it. */
static void build_details(SZFriendsGtkPage *page, gpointer data) {
    (void)data;
    szfriends_gtk_page_set_title(page, "Details", NULL);
    szfriends_gtk_page_set_content(page, gtk_box_new(GTK_ORIENTATION_VERTICAL, 0));
}

static gboolean link_ready(gpointer data) {
    return szfriends_gtk_link_get_state(data) == SZFRIENDS_GTK_LINK_READY;
}

SZFGHarness *szfg_conv_harness(const char *label, const char *capabilities_json) {
    SZFGHarness *harness = g_new0(SZFGHarness, 1);
    harness->state = szfg_temp_dir(label);
    g_setenv(SZFRIENDS_ENV_STATE_DIR, harness->state, TRUE);
    harness->host.struct_size = sizeof harness->host;
    harness->host.app_id = "com.intuition.shenzhenfiles";
    harness->host.app_name = "Shenzhen Files";
    harness->host.app_version = "26.10.13";
    harness->host.reveal_in_name = "Shenzhen Files";
    harness->host.attach_placeholder = "Search the selection and this folder";
    harness->host.attachable_items = attachable_items;
    harness->host.reveal_file = reveal_file;
    harness->host.animals_manifest_path = szfg_manifest;
    harness->link = szfriends_gtk_link_new(&harness->host);
    static const SZFriendsGtkPageClass details = {build_details, NULL, NULL, NULL};
    szfriends_gtk_register_page(harness->link, SZFRIENDS_GTK_PAGE_DETAILS, &details, NULL);
    szfriends_fake_helper_config config = {0};
    config.state_dir = harness->state;
    config.fixtures_dir = szfg_fixtures;
    config.capabilities_json = capabilities_json;
    EXPECT(szfriends_fake_helper_start(&config, &harness->fake) == SZFRIENDS_OK, "%s: the fake helper starts", label);
    szfriends_gtk_link_start(harness->link);
    EXPECT(szfg_pump_until(link_ready, harness->link, 5000), "%s: the link reaches READY", label);
    return harness;
}

/* ---- Pages ------------------------------------------------------------------------------------------------- */

static void present_nothing(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown, (void)data;
}

static void dismiss_now(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

SZFriendsGtkPage *szfg_conv_page(SZFGConv *conv) {
    return szfriends_gtk_dropdown_get_top_page(conv->dropdown);
}

GtkWidget *szfg_conv_content(SZFGConv *conv) {
    return szfriends_gtk_dropdown_get_content(conv->dropdown);
}

/* The top page only: the list page under it has buttons of its own. */
GtkWidget *szfg_conv_root(SZFGConv *conv) {
    SZFriendsGtkPage *page = szfg_conv_page(conv);
    return page ? szfriends_gtk_page_get_widget(page) : NULL;
}


static gboolean snapshot_arrived(gpointer data) {
    SZFriendsGtkPage *page = szfg_conv_page(data);
    return page && szfriends_gtk_page_get_kind(page) == SZFRIENDS_GTK_PAGE_CONVERSATION &&
           szfriends_gtk_conversation_page_part(page, "title") != NULL;
}

void szfg_conv_layout(SZFGConv *conv) {
    /* Twice: the list view makes its rows during the first allocation and places them in the second. */
    szfg_layout(conv->probe_window, 400, 640);
    szfg_layout(conv->probe_window, 400, 640);
}

SZFGConv *szfg_conv_open(SZFGHarness *harness, const char *conversation_id) {
    SZFGConv *conv = g_new0(SZFGConv, 1);
    conv->harness = harness;
    conv->window = gtk_window_new();
    conv->anchor = szfriends_gtk_button_new(harness->link, GTK_WINDOW(conv->window));
    gtk_window_set_child(GTK_WINDOW(conv->window), conv->anchor);
    conv->dropdown = szfriends_gtk_dropdown_for_button(conv->anchor);
    static const SZFriendsGtkPresenter presenter = {present_nothing, dismiss_now};
    szfriends_gtk_dropdown_set_presenter(conv->dropdown, &presenter, NULL);
    szfriends_gtk_dropdown_open(conv->dropdown);
    szfriends_gtk_dropdown_open_conversation(conv->dropdown, conversation_id, NULL);
    conv->probe_window = szfg_probe_window(szfg_conv_content(conv));
    EXPECT(szfg_pump_until(snapshot_arrived, conv, 5000), "%s: the conversation's first snapshot", conversation_id);
    szfg_pump_for(50);
    szfg_conv_layout(conv);
    return conv;
}

void szfg_conv_render(SZFGConv *conv, const char *name) {
    GdkTexture *texture = szfg_render(conv->probe_window, 400, 640, name);
    g_object_unref(texture);
}

void szfg_conv_render_widget(GtkWidget *widget, int width, const char *name) {
    GtkWidget *window = szfg_probe_window(widget);
    GdkTexture *texture = szfg_render(window, width, -1, name);
    g_object_unref(texture);
    gtk_window_destroy(GTK_WINDOW(window));
}

void szfg_conv_close(SZFGConv *conv) {
    szfriends_gtk_dropdown_close(conv->dropdown);
    GtkWidget *content = szfg_conv_content(conv);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(conv->probe_window), NULL);
    gtk_window_destroy(GTK_WINDOW(conv->probe_window));
    g_object_unref(content);
    gtk_window_destroy(GTK_WINDOW(conv->window));
    szfg_pump_for(20);
    g_free(conv);
}

/* ---- Finding widgets, waiting, data ------------------------------------------------------------------------ */

GtkWidget *szfg_find_label(GtkWidget *root, const char *prefix) {
    if (!root) return NULL;
    if (GTK_IS_LABEL(root) && g_str_has_prefix(gtk_label_get_text(GTK_LABEL(root)), prefix)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = szfg_find_label(child, prefix);
        if (found) return found;
    }
    return NULL;
}

GtkWidget *szfg_find_button(GtkWidget *root, const char *label) {
    if (!root) return NULL;
    if (GTK_IS_BUTTON(root) && g_strcmp0(gtk_button_get_label(GTK_BUTTON(root)), label) == 0) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = szfg_find_button(child, label);
        if (found) return found;
    }
    return NULL;
}

guint szfg_count_buttons(GtkWidget *root, const char *label) {
    guint count = root && GTK_IS_BUTTON(root) && g_strcmp0(gtk_button_get_label(GTK_BUTTON(root)), label) == 0;
    for (GtkWidget *child = root ? gtk_widget_get_first_child(root) : NULL; child;
         child = gtk_widget_get_next_sibling(child))
        count += szfg_count_buttons(child, label);
    return count;
}

guint szfg_count_type(GtkWidget *root, GType type) {
    guint count = root && G_TYPE_CHECK_INSTANCE_TYPE(root, type) && gtk_widget_get_visible(root);
    for (GtkWidget *child = root ? gtk_widget_get_first_child(root) : NULL; child;
         child = gtk_widget_get_next_sibling(child))
        count += szfg_count_type(child, type);
    return count;
}

typedef struct {
    SZFGHarness *harness;
    const char *type;
    guint before;
} SZFGFrameWait;

static gboolean frame_arrived(gpointer data) {
    SZFGFrameWait *wait = data;
    return szfg_fake_frames(wait->harness, wait->type, NULL, NULL) > wait->before;
}

gboolean szfg_conv_wait_frames(SZFGHarness *harness, const char *type, guint before) {
    SZFGFrameWait wait = {harness, type, before};
    return szfg_pump_until(frame_arrived, &wait, 3000);
}

static gboolean write_png(const char *path, int width, int height) {
    gsize stride = (gsize)width * 4;
    guint8 *pixels = g_malloc(stride * (gsize)height);
    /* A page with a few lines, so the render shows a preview rather than a block of colour. */
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++) {
            guint8 *p = pixels + (gsize)y * stride + (gsize)x * 4;
            gboolean ink = y > height / 8 && y % 14 < 3 && x > width / 8 && x < width - width / 8;
            p[0] = ink ? 0x55 : 0xfb, p[1] = ink ? 0x5f : 0xfa, p[2] = ink ? 0x8a : 0xf5, p[3] = 0xff;
        }
    GBytes *bytes = g_bytes_new_take(pixels, stride * (gsize)height);
    GdkTexture *texture = gdk_memory_texture_new(width, height, GDK_MEMORY_R8G8B8A8, bytes, stride);
    gboolean saved = gdk_texture_save_to_png(texture, path);
    g_object_unref(texture);
    g_bytes_unref(bytes);
    return saved;
}

char *szfg_conv_data_with_previews(SZFGHarness *harness, const char *fixture, const char *missing) {
    char *relative = g_strdup_printf("snapshots/%s", fixture);
    JsonObject *frame = szfg_fixture(relative);
    g_free(relative);
    if (!frame) return NULL;
    JsonObject *data = json_object_get_object_member(frame, "data");
    JsonArray *items = json_object_get_array_member(data, "items");
    char *cache = g_build_filename(harness->state, "thumbnails", NULL);
    g_mkdir_with_parents(cache, 0700);
    for (guint i = 0; i < json_array_get_length(items); i++) {
        JsonObject *item = json_array_get_object_element(items, i);
        JsonNode *node = json_object_get_member(item, "thumbnail");
        if (!node || !JSON_NODE_HOLDS_OBJECT(node)) continue;
        JsonObject *thumbnail = json_node_get_object(node);
        const char *id = json_object_get_string_member(item, "item_id");
        char *name = g_strdup_printf("%s.png", id), *path = g_build_filename(cache, name, NULL);
        if (g_strcmp0(id, missing) != 0)
            write_png(path, (int)json_object_get_int_member(thumbnail, "width"),
                      (int)json_object_get_int_member(thumbnail, "height"));
        json_object_set_string_member(thumbnail, "path", path);
        g_free(name);
        g_free(path);
    }
    g_free(cache);
    JsonNode *root = json_node_init_object(json_node_alloc(), data);
    char *json = json_to_string(root, FALSE);
    json_node_unref(root);
    json_object_unref(frame);
    return json;
}

GValue *szfg_files_value(const char *const *paths) {
    GSList *files = NULL;
    for (const char *const *path = paths; *path; path++) files = g_slist_append(files, g_file_new_for_path(*path));
    GValue *value = g_new0(GValue, 1);
    g_value_init(value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(value, gdk_file_list_new_from_list(files));
    g_slist_free_full(files, g_object_unref);
    return value;
}

void szfg_value_free(GValue *value) {
    g_value_unset(value);
    g_free(value);
}

/* ---- Main ---------------------------------------------------------------------------------------------------- */

/* Before GDK opens the display: prove the interposer will stop it from making this process a foreground app. */
static gboolean quiet_before_display(void) {
#ifdef __APPLE__
    int before = szfriends_gtk_quiet_transform_calls();
    TransformProcessType(NULL, 0); /* the real one refuses NULL and changes nothing */
    if (szfriends_gtk_quiet_transform_calls() != before + 1) {
        fprintf(stderr, "SZFriendsGtkConversationProbes: the interposer is not active; not opening a display\n");
        return FALSE;
    }
#endif
    return TRUE;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <fixtures> <manifest.json> <renders>\n", argv[0]);
        return 2;
    }
    char *fixtures = realpath(argv[1], NULL), *manifest = realpath(argv[2], NULL);
    if (!fixtures || !manifest || !quiet_before_display()) return 2;
    szfg_fixtures = fixtures;
    szfg_manifest = manifest;
    szfg_renders = argv[3];
    g_mkdir_with_parents(szfg_renders, 0755);
    szfg_watch_logs();
    g_unsetenv("SZFRIENDS_AVATARS_MANIFEST");
    if (!gtk_init_check()) {
        fprintf(stderr, "SZFriendsGtkConversationProbes: no display; the widget probes need a logged-in session\n");
        return 1;
    }
    adw_init();
    szfg_conv_records.opened = g_ptr_array_new_with_free_func(g_free);
    szfg_conv_records.revealed = g_ptr_array_new_with_free_func(g_free);
    szfg_conv_records.popovers = g_ptr_array_new();
    szfriends_gtk_conversation_set_uri_opener(open_uri, NULL);
    szfriends_gtk_conversation_set_popup(record_popup);
    szfg_set_dark(FALSE);
    szfg_clock_install(); /* arming and its expiry on the list's hand-moved clock, never real time */
    szfg_run_conversation_mention_probes();
    szfg_run_conversation_composer_probes();
    szfg_run_conversation_transfer_probes();
    szfg_run_conversation_look_probes();
    szfg_run_conversation_card_probes();
    szfg_run_conversation_route_probes();
    szfg_run_conversation_online_probes();
    szfg_run_conversation_device_probes();
    szfg_clock_uninstall();
    g_unsetenv(SZFRIENDS_ENV_STATE_DIR);
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib, GTK or libadwaita warnings (%d)", szfg_unexpected_warnings());
    g_ptr_array_unref(szfg_conv_records.opened);
    g_ptr_array_unref(szfg_conv_records.revealed);
    g_ptr_array_unref(szfg_conv_records.popovers);
    free(fixtures);
    free(manifest);
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkConversationProbes: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkConversationProbes passed\n");
    return 0;
}
