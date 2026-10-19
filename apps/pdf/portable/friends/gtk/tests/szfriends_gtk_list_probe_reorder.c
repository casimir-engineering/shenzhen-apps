/* Rows reused by position while the list moves (security review, wave 6b): a snapshot that slides someone else under
 * a drag or a held mouse button never completes it for them. Files dragged over Mei are refused once Kenji holds her
 * row, a click pressed on Mei and released over Kenji opens nothing, and the send picker sends to nobody the person
 * did not click; an unchanged snapshot changes none of this, and a request taken over by someone with the same words
 * gets new buttons. Links and special files are refused over a friend with the helper's words for them. */

#include "szfriends_gtk_list_probe.h"

#include <glib/gstdio.h>
#include <sys/stat.h>
#include <unistd.h>

static void file_list(GValue *value, const char *path) {
    GSList *files = g_slist_append(NULL, g_file_new_for_path(path));
    g_value_init(value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(value, gdk_file_list_new_from_list(files));
    g_slist_free_full(files, g_object_unref);
}

/* list.json with the rows at `a` and `b` trading places, or the fixture itself when a == b. */
static void script_list(SZFGHarness *harness, guint a, guint b) {
    if (a == b) {
        szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
        return;
    }
    JsonObject *frame = szfg_fixture("snapshots/list.json"), *data = json_object_get_object_member(frame, "data");
    JsonArray *rows = json_object_get_array_member(data, "rows"), *swapped = json_array_new();
    for (guint i = 0; i < json_array_get_length(rows); i++)
        json_array_add_element(swapped, json_node_copy(json_array_get_element(rows, i == a ? b : i == b ? a : i)));
    json_object_set_array_member(data, "rows", swapped);
    JsonNode *node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(node, data);
    char *text = json_to_string(node, FALSE);
    szfriends_fake_helper_set_view_data(harness->fake, "list", text);
    g_free(text);
    json_node_unref(node);
    json_object_unref(frame);
}

typedef struct {
    SZFGList *list;
    const char *conversation_id;
} SZFGHolder;

static gboolean second_row_is(gpointer data) {
    SZFGHolder *holder = data;
    const SZFriendsGtkListParts *parts = holder->list->parts;
    return parts->rows->len > 1 &&
           !g_strcmp0(szfriends_gtk_row_get_conversation_id(g_ptr_array_index(parts->rows, 1)),
                      holder->conversation_id);
}

/* Scripts the list and waits until the second row (Mei's in the fixture) holds `conversation_id`. */
static gboolean move(SZFGHarness *harness, SZFGList *list, guint a, guint b, const char *conversation_id) {
    script_list(harness, a, b);
    SZFGHolder holder = {list, conversation_id};
    return szfg_pump_until(second_row_is, &holder, 3000);
}

static void test_drag(SZFGHarness *harness, SZFGList *list, GtkWidget *row, const GValue *files) {
    szfriends_gtk_row_drag_enter(row);
    szfriends_gtk_row_drag_value(row, files);
    SZFriendsGtkRowLook look = szfriends_gtk_row_get_look(row);
    EXPECT(szfriends_gtk_row_get_drop(row) == SZFRIENDS_GTK_ROW_DROP_ACCEPT && !g_strcmp0(look.pill, "Send to Mei"),
           "files over Mei: \"Send to Mei\"");
    EXPECT(move(harness, list, 1, 2, "c_kenji"), "Kenji takes Mei's row while the files hover");
    look = szfriends_gtk_row_get_look(row);
    EXPECT(szfriends_gtk_row_get_drop(row) == SZFRIENDS_GTK_ROW_DROP_NONE && look.right != SZFRIENDS_GTK_ROW_RIGHT_PILL
               && !gtk_widget_has_css_class(row, "drop-accept"),
           "the row promises Kenji nothing: no highlight, no \"Send to Kenji\"");
    guint sends = szfg_frames(harness, "send_files");
    EXPECT(!szfriends_gtk_row_drop(row, files), "and the drop is refused");
    szfg_pump_for(100);
    EXPECT(szfg_frames(harness, "send_files") == sends, "nothing went to Kenji");
    EXPECT(move(harness, list, 1, 1, "c_mei"), "Mei back in her row");
    /* An unchanged snapshot during a drag keeps it: only a different person cancels. */
    szfriends_gtk_row_drag_enter(row);
    szfriends_gtk_row_drag_value(row, files);
    guint seen = list->parts->list_snapshots;
    script_list(harness, 1, 1);
    EXPECT(szfg_list_wait_snapshot(list, seen) && szfriends_gtk_row_get_drop(row) == SZFRIENDS_GTK_ROW_DROP_ACCEPT,
           "a refresh that leaves Mei in place keeps the highlight");
    EXPECT(szfriends_gtk_row_drop(row, files) && szfg_wait_frames(harness, "send_files", sends + 1),
           "and the drop goes to Mei");
    char *to = szfg_last_field(harness, "send_files", "conversation_id");
    EXPECT(!g_strcmp0(to, "c_mei"), "to Mei (%s)", to);
    g_free(to);
}

static void test_click(SZFGHarness *harness, SZFGList *list, GtkWidget *row) {
    szfriends_gtk_row_press(row);
    EXPECT(move(harness, list, 1, 2, "c_kenji"), "Kenji takes Mei's row under the held button");
    szfriends_gtk_row_release(row, TRUE);
    EXPECT(szfriends_gtk_dropdown_get_depth(list->dropdown) == 1, "the release opens nobody's conversation");
    EXPECT(move(harness, list, 1, 1, "c_mei"), "Mei back in her row");
    szfriends_gtk_row_press(row);
    szfriends_gtk_row_release(row, TRUE);
    SZFriendsGtkPage *top = szfriends_gtk_dropdown_get_top_page(list->dropdown);
    EXPECT(szfriends_gtk_dropdown_get_depth(list->dropdown) == 2 &&
               !g_strcmp0(szfriends_gtk_page_get_argument(top), "c_mei"), "a click on an unmoved row opens Mei");
    szfriends_gtk_dropdown_go_back(list->dropdown);
    szfriends_gtk_row_press(row);
    szfriends_gtk_row_release(row, FALSE);
    EXPECT(szfriends_gtk_dropdown_get_depth(list->dropdown) == 1, "a release outside the row opens nothing");

    /* The send picker: the friend clicked gets the files, never whoever slid under the pointer meanwhile. */
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    g_ptr_array_add(items, szfriends_gtk_host_item_new("a.pdf", NULL, NULL, "/tmp/szfg-reorder-a.pdf", NULL));
    szfriends_gtk_dropdown_begin_send_picker(list->dropdown, items);
    guint sends = szfg_frames(harness, "send_files");
    szfriends_gtk_row_press(row);
    EXPECT(move(harness, list, 1, 2, "c_kenji"), "Kenji takes Mei's row while the picker waits");
    szfriends_gtk_row_release(row, TRUE);
    szfg_pump_for(100);
    EXPECT(szfg_frames(harness, "send_files") == sends && szfriends_gtk_dropdown_get_send_items(list->dropdown),
           "nothing is sent and the picker still waits");
    szfriends_gtk_dropdown_finish_send_picker(list->dropdown);
    g_ptr_array_unref(items);
    EXPECT(move(harness, list, 1, 1, "c_mei"), "Mei back in her row");
}

static void test_not_a_file(SZFGHarness *harness, SZFGList *list, const char *dir, const char *file) {
    char *link = g_build_filename(dir, "Link to plan.pdf", NULL), *fifo = g_build_filename(dir, "pipe", NULL);
    EXPECT(symlink(file, link) == 0 && mkfifo(fifo, 0600) == 0, "a link and a FIFO");
    const char *words = szfriends_gtk_link_string(harness->link, "drop_not_a_file");
    GtkWidget *mei = szfg_list_row(list, "c_mei"), *lena = szfg_list_row(list, "c_lena");
    const char *paths[] = {link, fifo};
    for (gsize i = 0; i < G_N_ELEMENTS(paths); i++) {
        GValue value = G_VALUE_INIT;
        file_list(&value, paths[i]);
        szfriends_gtk_row_drag_value(mei, &value);
        SZFriendsGtkRowLook look = szfriends_gtk_row_get_look(mei);
        EXPECT(*words && szfriends_gtk_row_get_drop(mei) == SZFRIENDS_GTK_ROW_DROP_REFUSE && look.pill_warning &&
                   !g_strcmp0(look.pill, words), "%s over Mei: refused with the helper's words (%s)",
               i ? "a FIFO" : "a link", look.pill);
        EXPECT(!szfriends_gtk_row_drop(mei, &value), "and the drop is refused");
        szfriends_gtk_row_drag_value(lena, &value);
        look = szfriends_gtk_row_get_look(lena);
        EXPECT(!g_strcmp0(look.pill, "Lena isn’t your friend yet"), "over a request, the request's own reason");
        szfriends_gtk_row_drag_leave(lena);
        g_value_unset(&value);
    }
    g_unlink(link), g_unlink(fifo);
    g_free(link), g_free(fifo);
}

typedef struct {
    SZFGList *list;
    const char *conversation_id;
} SZFGFirst;

static gboolean first_row_is(gpointer data) {
    SZFGFirst *first = data;
    const SZFriendsGtkListParts *parts = first->list->parts;
    return parts->rows->len && !g_strcmp0(szfriends_gtk_row_get_conversation_id(g_ptr_array_index(parts->rows, 0)),
                                          first->conversation_id);
}

/* Two requests can carry the same words (two people named Lena Weber): a row someone else takes gets new buttons,
 * so a press on the old person's Accept can never complete for the new one. */
static void test_same_words(SZFGHarness *harness, SZFGList *list) {
    GtkWidget *row = g_ptr_array_index(list->parts->rows, 0);
    GtkWidget *accept = szfriends_gtk_row_actions_button(szfriends_gtk_row_get_actions(row), SZFRIENDS_GTK_ICON_ACCEPT);
    EXPECT(accept != NULL, "Lena's Accept");
    g_object_add_weak_pointer(G_OBJECT(accept), (gpointer *)&accept);
    JsonObject *frame = szfg_fixture("snapshots/list.json"), *data = json_object_get_object_member(frame, "data");
    JsonObject *lena = json_array_get_object_element(json_object_get_array_member(data, "rows"), 0);
    json_object_set_string_member(lena, "conversation_id", "c_lena_too");
    JsonNode *node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(node, data);
    char *text = json_to_string(node, FALSE);
    szfriends_fake_helper_set_view_data(harness->fake, "list", text);
    g_free(text);
    json_node_unref(node);
    json_object_unref(frame);
    SZFGFirst first = {list, "c_lena_too"};
    EXPECT(szfg_pump_until(first_row_is, &first, 3000), "another Lena Weber takes the first row");
    EXPECT(!accept && szfriends_gtk_row_actions_button(szfriends_gtk_row_get_actions(row), SZFRIENDS_GTK_ICON_ACCEPT),
           "with buttons of her own, though their words are the same");
    if (accept) g_object_remove_weak_pointer(G_OBJECT(accept), (gpointer *)&accept);
    script_list(harness, 1, 1);
    first.conversation_id = "c_lena";
    EXPECT(szfg_pump_until(first_row_is, &first, 3000), "the fixture's Lena again");
}

void szfg_run_list_reorder_probes(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    EXPECT(szfg_list_wait_rows(list, 7), "the fixture's seven rows");
    char *dir = szfg_temp_dir("reorder"), *file = g_build_filename(dir, "Plan.pdf", NULL);
    g_file_set_contents(file, "%PDF-1.4\n", -1, NULL);
    GValue files = G_VALUE_INIT;
    file_list(&files, file);
    GtkWidget *row = g_ptr_array_index(list->parts->rows, 1);
    EXPECT(!g_strcmp0(szfriends_gtk_row_get_conversation_id(row), "c_mei"), "Mei holds the second row");
    test_drag(harness, list, row, &files);
    test_click(harness, list, row);
    test_not_a_file(harness, list, dir, file);
    test_same_words(harness, list);
    g_value_unset(&files);
    szfg_remove_tree(dir);
    g_free(file), g_free(dir);
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_pump_for(50);
    szfg_list_close(list);
}
