/* The list and Nearby offscreen, in light and dark, in the mockups' states: the fixture's list, a request with its
 * Block armed, a fresh list whose ID changed with the name field, "Send 2 files to…", files and a link over a
 * friend (through the Friends button, and straight into the open list), Nearby while visible with Bluetooth off, and
 * Nearby with Local Network denied. Each state is built fresh in its theme, since an unmapped window never restyles
 * what already exists. */

#include "szfriends_gtk_list_probe.h"

#include <string.h>
#include <unistd.h>

typedef void (*SZFGPrepare)(SZFGList *list);

static gboolean nearby_in(gpointer data) {
    return ((SZFGList *)data)->parts->nearby_snapshots > 0;
}

static GdkTexture *render(SZFGHarness *harness, const char *name, gboolean dark, gboolean nearby, SZFGPrepare prepare,
                          SZFGList **kept) {
    szfg_set_dark(dark);
    SZFGList *list = szfg_list_open(harness);
    if (nearby) {
        szfriends_gtk_list_page_show_nearby(list->page, TRUE);
        EXPECT(szfg_pump_until(nearby_in, list, 3000), "%s: Nearby arrives", name);
    }
    if (prepare) prepare(list);
    char *file = g_strdup_printf("%s-%s", name, dark ? "dark" : "light");
    GtkWidget *content = szfriends_gtk_dropdown_get_content(list->dropdown);
    GtkWidget *window = szfg_probe_window(content);
    GdkTexture *texture = szfg_render(window, 400, 640, file);
    g_free(file);
    if (kept) {
        *kept = list;
        g_object_set_data(G_OBJECT(list->window), "szfg-probe-window", window);
        return texture;
    }
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    szfg_list_close(list);
    return texture;
}

static void release(SZFGList *list) {
    GtkWidget *window = g_object_get_data(G_OBJECT(list->window), "szfg-probe-window");
    GtkWidget *content = szfriends_gtk_dropdown_get_content(list->dropdown);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    szfg_list_close(list);
}

static void wait_list(SZFGList *list) {
    EXPECT(szfg_list_wait_rows(list, 7), "the fixture's rows arrive");
}

static void prepare_list(SZFGList *list) {
    wait_list(list);
}

static void prepare_armed(SZFGList *list) {
    wait_list(list);
    GtkWidget *actions = szfriends_gtk_row_get_actions(szfg_list_row(list, "c_lena"));
    szfg_clock_advance_ms(1000);
    szfriends_gtk_row_actions_click(szfriends_gtk_row_actions_button(actions, SZFRIENDS_GTK_ICON_BLOCK), 1);
    EXPECT(szfriends_gtk_row_actions_is_armed(actions), "Block is armed for the render");
}

static gboolean empty_list(gpointer data) {
    SZFGList *list = data;
    return list->parts->list_snapshots > 0 && list->parts->rows->len == 0;
}

static void prepare_fresh(SZFGList *list) {
    EXPECT(szfg_pump_until(empty_list, list, 3000), "the fresh list arrives");
}

static GPtrArray *two_items(void) {
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    g_ptr_array_add(items, szfriends_gtk_host_item_new("Site photos.pdf", NULL, NULL, "/tmp/szfg-none-1.pdf", NULL));
    g_ptr_array_add(items, szfriends_gtk_host_item_new("Floor plan.pdf", NULL, NULL, "/tmp/szfg-none-2.pdf", NULL));
    return items;
}

static void prepare_picker(SZFGList *list) {
    wait_list(list);
    GPtrArray *items = two_items();
    szfriends_gtk_dropdown_begin_send_picker(list->dropdown, items);
    g_ptr_array_unref(items);
}

static void drag_over_mei(SZFGList *list, gboolean as_link) {
    /* A real file (or a link to one), so the drop is classified as it would be on screen. */
    char *dir = szfg_temp_dir("list-render"), *path = g_build_filename(dir, "Site photos.pdf", NULL);
    g_file_set_contents(path, "%PDF-1.4\n", -1, NULL);
    char *link = g_build_filename(dir, "Site photos link.pdf", NULL);
    EXPECT(!as_link || symlink(path, link) == 0, "a link to drag");
    GFile *file = g_file_new_for_path(as_link ? link : path);
    GSList *files = g_slist_append(NULL, file);
    GValue value = G_VALUE_INIT;
    g_value_init(&value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(&value, gdk_file_list_new_from_list(files));
    szfriends_gtk_row_drag_value(szfg_list_row(list, "c_mei"), &value);
    g_value_unset(&value);
    g_slist_free(files);
    g_object_unref(file);
    szfg_remove_tree(dir);
    g_free(path), g_free(link);
    g_free(dir);
}

static void prepare_drop(SZFGList *list) {
    wait_list(list);
    szfriends_gtk_dropdown_set_drop_hint(list->dropdown, szfriends_gtk_link_string(list->harness->link, "drop_hint"));
    drag_over_mei(list, FALSE);
}

/* A link over the Friends button and then over Mei: the helper's refusal above the rows, and her row in the refuse
 * style alone, so the sentence is not read twice and her name and last message stay whole (lead decision after
 * wave 6c). */
static void prepare_drop_link(SZFGList *list) {
    wait_list(list);
    const char *refusal = szfriends_gtk_link_string(list->harness->link, "drop_not_a_file");
    szfriends_gtk_dropdown_set_drop_hint(list->dropdown, refusal);
    drag_over_mei(list, TRUE);
    GtkWidget *mei = szfg_list_row(list, "c_mei");
    SZFriendsGtkRowLook look = szfriends_gtk_row_get_look(mei);
    GtkWidget *pill = szfriends_gtk_row_get_part(mei, SZFRIENDS_GTK_ROW_PART_PILL);
    EXPECT(*refusal && szfriends_gtk_row_get_drop(mei) == SZFRIENDS_GTK_ROW_DROP_REFUSE &&
               gtk_widget_has_css_class(mei, "drop-refuse") && !look.pill && !gtk_widget_get_visible(pill),
           "with the refusal above the rows, Mei's row is refused by its style alone (%s)", look.pill);
}

/* A link dragged straight into the open list, which the Friends button never saw: no header, so the row says why. */
static void prepare_drop_link_open(SZFGList *list) {
    wait_list(list);
    const char *refusal = szfriends_gtk_link_string(list->harness->link, "drop_not_a_file");
    drag_over_mei(list, TRUE);
    GtkWidget *mei = szfg_list_row(list, "c_mei");
    EXPECT(*refusal && !g_strcmp0(szfriends_gtk_row_get_look(mei).pill, refusal), "without a header the row says why");
}

/* Mei's name and last message are whole: nothing on the row repeats the header. */
static void expect_row_whole(SZFGList *list) {
    GtkWidget *row = szfg_list_row(list, "c_mei");
    for (int i = 0; i < 2; i++) {
        GtkWidget *label = szfriends_gtk_row_get_part(row, i ? SZFRIENDS_GTK_ROW_PART_SUBTITLE
                                                             : SZFRIENDS_GTK_ROW_PART_TITLE);
        EXPECT(label && !pango_layout_is_ellipsized(gtk_label_get_layout(GTK_LABEL(label))), "Mei's %s is whole",
               i ? "last message" : "name");
    }
}

/* The row's name stays whole beside a long refusal, which wraps to two lines in its pill: the pill gives way, never
 * the name of the person the files would have gone to. */
static void expect_name_room(SZFGList *list) {
    GtkWidget *row = szfg_list_row(list, "c_mei");
    GtkWidget *title = szfriends_gtk_row_get_part(row, SZFRIENDS_GTK_ROW_PART_TITLE);
    GtkWidget *pill = szfriends_gtk_row_get_part(row, SZFRIENDS_GTK_ROW_PART_PILL);
    EXPECT(title && !pango_layout_is_ellipsized(gtk_label_get_layout(GTK_LABEL(title))), "Mei's name is whole");
    EXPECT(pill && pango_layout_get_line_count(gtk_label_get_layout(GTK_LABEL(pill))) == 2,
           "and the refusal takes two lines");
}

/* Pixels in the row's leading column: the waiting bar is drawn there and nowhere else. */
static int leading_ink(SZFGList *list, GdkTexture *texture, const char *conversation_id, gboolean dark) {
    GtkWidget *row = szfg_list_row(list, conversation_id);
    GtkWidget *content = szfriends_gtk_dropdown_get_content(list->dropdown);
    graphene_rect_t bounds;
    if (!row || !gtk_widget_compute_bounds(row, content, &bounds)) return -1;
    SZFGPixels pixels = szfg_pixels(texture);
    const guint8 *background = szfg_pixel(&pixels, (int)(bounds.origin.x + bounds.size.width / 2) * 2,
                                          (int)(bounds.origin.y + 3) * 2);
    guint8 bg[3] = {background[0], background[1], background[2]};
    (void)dark;
    int ink = szfg_count_differing(&pixels, (int)bounds.origin.x * 2, (int)(bounds.origin.y + 12) * 2, 10,
                                   (int)(bounds.size.height - 24) * 2, bg, 60);
    szfg_pixels_free(&pixels);
    return ink;
}

void szfg_run_list_renders(SZFGHarness *harness) {
    szfriends_fake_helper *fake = harness->fake;
    for (int dark = 0; dark < 2; dark++) {
        SZFGList *list = NULL;
        GdkTexture *texture = render(harness, "list", dark, FALSE, prepare_list, &list);
        EXPECT(leading_ink(list, texture, "c_lena", dark) > 20, "Lena's row carries the waiting bar (%d)",
               leading_ink(list, texture, "c_lena", dark));
        EXPECT(leading_ink(list, texture, "c_daniel", dark) == 0, "Daniel's row has no marker (%d)",
               leading_ink(list, texture, "c_daniel", dark));
        g_object_unref(texture);
        release(list);
        g_object_unref(render(harness, "list-armed", dark, FALSE, prepare_armed, NULL));
        g_object_unref(render(harness, "list-send-picker", dark, FALSE, prepare_picker, NULL));
        g_object_unref(render(harness, "list-drop", dark, FALSE, prepare_drop, NULL));
        texture = render(harness, "list-drop-link", dark, FALSE, prepare_drop_link, &list);
        expect_row_whole(list);
        g_object_unref(texture);
        release(list);
        texture = render(harness, "list-drop-link-open", dark, FALSE, prepare_drop_link_open, &list);
        expect_name_room(list);
        g_object_unref(texture);
        release(list);
        szfriends_fake_helper_set_view_fixture(fake, "list", "list-id-changed.json");
        g_object_unref(render(harness, "list-id-changed", dark, FALSE, prepare_fresh, NULL));
        szfriends_fake_helper_set_view_fixture(fake, "list", "online-list.json");
        g_object_unref(render(harness, "online-list", dark, FALSE, prepare_list, NULL));
        szfriends_fake_helper_set_view_fixture(fake, "list", "list.json");
        g_object_unref(render(harness, "nearby-visible", dark, TRUE, NULL, NULL));
        szfriends_fake_helper_set_view_fixture(fake, "nearby", "nearby-local-network-denied.json");
        g_object_unref(render(harness, "nearby-denied", dark, TRUE, NULL, NULL));
        szfriends_fake_helper_set_view_fixture(fake, "nearby", "nearby-visible-bluetooth-off.json");
    }
    szfg_set_dark(FALSE);
}
