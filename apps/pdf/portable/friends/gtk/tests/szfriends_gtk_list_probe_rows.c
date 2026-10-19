/* The list's rows against the fake helper: what each fixture row shows, a request answered from the list (Accept,
 * Decline, the two-click Block and every way its pill turns back), a click opening the conversation, files dropped
 * on a friend sent at once (one offer per file), folders and people who cannot receive refused with the helper's
 * words, and "Send 2 files to…" sending to the friend clicked next. */

#include "szfriends_gtk_list_probe.h"

#include <glib/gstdio.h>
#include <string.h>

static GtkWidget *button(SZFGList *list, const char *conversation_id, SZFriendsGtkRowIcon icon) {
    GtkWidget *actions = szfriends_gtk_row_get_actions(szfg_list_row(list, conversation_id));
    return szfriends_gtk_row_actions_button(actions, icon);
}

static gboolean armed(SZFGList *list) {
    return szfriends_gtk_row_actions_is_armed(szfriends_gtk_row_get_actions(szfg_list_row(list, "c_lena")));
}

/* A deliberate click: a second after the last one, so the double-click guard never applies unless asked for. */
static void click(GtkWidget *target) {
    szfg_clock_advance_ms(1000);
    szfriends_gtk_row_actions_click(target, 1);
}

static const char *part_text(GtkWidget *row, SZFriendsGtkRowPart part) {
    GtkWidget *label = szfriends_gtk_row_get_part(row, part);
    return label && GTK_IS_LABEL(label) ? gtk_label_get_text(GTK_LABEL(label)) : NULL;
}

/* Names and previews are other people's words: shown as typed, never read as markup. */
static void test_plain_text(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    guint seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_data(harness->fake, "list",
        "{\"query\":\"\",\"banner\":null,\"name_prompt\":null,\"rows\":[{\"conversation_id\":\"c_x\",\"title\":"
        "\"<b>Mei</b> &amp;\",\"subtitle\":\"@Leo <i>see</i> pages 3–5\",\"time_label\":\"14:32\",\"route\":"
        "{\"kind\":\"local\",\"method\":\"lan\",\"label\":\"<u>near</u>\"},\"unread\":false,\"waiting\":null,"
        "\"style\":\"normal\",\"drop_label\":\"Send to <b>Mei</b>\",\"drop_refusal\":null,"
        "\"accessibility_label\":\"<b>Mei</b>\",\"actions\":[]}],\"empty\":null,\"footer\":{}}");
    EXPECT(szfg_list_wait_snapshot(list, seen) && szfg_list_wait_rows(list, 1), "the scripted row arrives");
    GtkWidget *row = list->parts->rows->len ? g_ptr_array_index(list->parts->rows, 0) : NULL;
    GtkWidget *title = row ? szfriends_gtk_row_get_part(row, SZFRIENDS_GTK_ROW_PART_TITLE) : NULL;
    EXPECT(title && !g_strcmp0(part_text(row, SZFRIENDS_GTK_ROW_PART_TITLE), "<b>Mei</b> &amp;") &&
               !gtk_label_get_use_markup(GTK_LABEL(title)) &&
               !g_strcmp0(part_text(row, SZFRIENDS_GTK_ROW_PART_SUBTITLE), "@Leo <i>see</i> pages 3–5") &&
               szfg_accessible_label_is(row, "<b>Mei</b>"), "names and previews as typed, @Name included");
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_list_close(list);
}

static void test_fixture_rows(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    EXPECT(szfg_list_wait_rows(list, 7), "the fixture's seven rows");
    JsonObject *frame = szfg_fixture("snapshots/list.json");
    SZFriendsGtkListSnapshot *fixture = szfriends_gtk_list_snapshot_parse(json_object_get_object_member(frame,
                                                                                                        "data"));
    for (guint i = 0; i < list->parts->rows->len && i < fixture->n_rows; i++) {
        GtkWidget *row = g_ptr_array_index(list->parts->rows, i);
        const SZFriendsGtkListRow *expected = &fixture->rows[i];
        EXPECT(!g_strcmp0(szfriends_gtk_row_get_conversation_id(row), expected->conversation_id),
               "row %u is %s, in the helper's order", i, expected->conversation_id);
        EXPECT(szfg_accessible_label_is(row, expected->accessibility_label), "row %u speaks the helper's words", i);
        SZFriendsGtkRowLook look = szfriends_gtk_row_get_look(row);
        SZFriendsGtkRowLook rule = szfriends_gtk_row_look(expected, SZFRIENDS_GTK_ROW_DROP_NONE, FALSE, FALSE, "");
        EXPECT(look.right == rule.right && look.waiting_bar == rule.waiting_bar && look.unread_dot == rule.unread_dot &&
                   look.route_icon == rule.route_icon && look.id_check == rule.id_check && look.muted == rule.muted,
               "row %u shows what the rule says", i);
        EXPECT(gtk_widget_has_css_class(row, "muted") == (expected->style == SZFRIENDS_GTK_ROW_MUTED),
               "row %u is drawn muted only for someone blocked", i);
    }
    /* Lena's own buttons: icons named after her, as tooltip and accessible name. */
    const SZFriendsGtkListRow *lena = &fixture->rows[0];
    static const SZFriendsGtkRowIcon icons[] = {SZFRIENDS_GTK_ICON_ACCEPT, SZFRIENDS_GTK_ICON_DECLINE,
                                                SZFRIENDS_GTK_ICON_BLOCK};
    for (gsize i = 0; i < G_N_ELEMENTS(icons) && i < lena->n_actions; i++) {
        GtkWidget *target = button(list, "c_lena", icons[i]);
        EXPECT(target && !g_strcmp0(gtk_widget_get_tooltip_text(target), lena->actions[i].label) &&
                   szfg_accessible_label_is(target, lena->actions[i].label),
               "%s: tooltip and accessible name", lena->actions[i].label);
    }
    for (guint i = 1; i < list->parts->rows->len; i++)
        EXPECT(!szfriends_gtk_row_get_actions(g_ptr_array_index(list->parts->rows, i)), "only requests answer");
    GtkWidget *mei = szfg_list_row(list, "c_mei"), *kenji = szfg_list_row(list, "c_kenji");
    EXPECT(!g_strcmp0(part_text(mei, SZFRIENDS_GTK_ROW_PART_TITLE), "Mei Lin") &&
               !g_strcmp0(part_text(mei, SZFRIENDS_GTK_ROW_PART_SUBTITLE),
                          "Can you check pages 3–5 before Friday?") &&
               !g_strcmp0(part_text(mei, SZFRIENDS_GTK_ROW_PART_TIME), "14:32"), "name, preview and time");
    EXPECT(!g_strcmp0(gtk_widget_get_tooltip_text(szfriends_gtk_row_get_part(mei, SZFRIENDS_GTK_ROW_PART_ROUTE)),
                      "Nearby, on your network"), "the route icon's tooltip says how Mei is reached");
    EXPECT(!gtk_widget_get_tooltip_text(szfriends_gtk_row_get_part(szfg_list_row(list, "c_jonas"),
                                                                   SZFRIENDS_GTK_ROW_PART_ROUTE)),
           "no route, no tooltip");
    EXPECT(!g_strcmp0(part_text(kenji, SZFRIENDS_GTK_ROW_PART_WAITING), "Waiting for you") &&
               gtk_widget_get_visible(szfriends_gtk_row_get_part(kenji, SZFRIENDS_GTK_ROW_PART_WAITING)),
           "the waiting pill");
    EXPECT(!g_strcmp0(gtk_widget_get_tooltip_text(szfriends_gtk_row_get_part(szfg_list_row(list, "c_tulip"),
                                                                             SZFRIENDS_GTK_ROW_PART_CHECK)),
                      "ID confirmed by the Friends server"), "the confirmed ID's check explains itself");
    /* The badge the button shows counts exactly the rows drawn waiting. */
    gint64 waiting = 0;
    for (guint i = 0; i < list->parts->rows->len; i++)
        waiting += szfriends_gtk_row_get_look(g_ptr_array_index(list->parts->rows, i)).waiting_bar;
    const SZFriendsGtkBadgeSnapshot *badge = szfriends_gtk_link_badge(harness->link);
    EXPECT(badge && badge->count == waiting, "the badge (%" G_GINT64_FORMAT ") counts the waiting rows (%"
           G_GINT64_FORMAT ")", badge ? badge->count : -1, waiting);
    szfriends_gtk_list_snapshot_free(fixture);
    json_object_unref(frame);
    szfg_list_close(list);
}

static void test_answers(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    guint accepted = szfg_frames(harness, "accept_request");
    GtkWidget *accept = button(list, "c_lena", SZFRIENDS_GTK_ICON_ACCEPT);
    click(accept);
    EXPECT(!gtk_widget_get_sensitive(accept), "the buttons rest until the reply");
    click(accept);
    EXPECT(szfg_wait_frames(harness, "accept_request", accepted + 1), "Accept answers at once");
    char *conversation = szfg_last_field(harness, "accept_request", "conversation_id");
    EXPECT(!g_strcmp0(conversation, "c_lena"), "with Lena's conversation (%s)", conversation);
    g_free(conversation);
    szfg_pump_for(100);
    EXPECT(szfg_frames(harness, "accept_request") == accepted + 1, "a double click sends one answer");
    EXPECT(gtk_widget_get_sensitive(accept), "the reply gives the buttons back");
    guint declined = szfg_frames(harness, "decline_request");
    click(button(list, "c_lena", SZFRIENDS_GTK_ICON_DECLINE));
    EXPECT(szfg_wait_frames(harness, "decline_request", declined + 1), "Decline answers at once");
    szfg_pump_for(50);
    /* The rest of the row still opens the request. */
    szfriends_gtk_row_activate(szfg_list_row(list, "c_lena"));
    SZFriendsGtkPage *top = szfriends_gtk_dropdown_get_top_page(list->dropdown);
    EXPECT(szfriends_gtk_page_get_kind(top) == SZFRIENDS_GTK_PAGE_CONVERSATION &&
               !g_strcmp0(szfriends_gtk_page_get_argument(top), "c_lena"), "the row opens Lena's request");
    szfriends_gtk_dropdown_go_back(list->dropdown);
    szfg_list_close(list);
}

static gboolean reordered(gpointer data) {
    SZFGList *list = data;
    return list->parts->rows->len && !g_strcmp0(szfriends_gtk_row_get_conversation_id(
                                                    g_ptr_array_index(list->parts->rows, 0)), "c_kenji");
}

static void test_block(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    guint blocks = szfg_frames(harness, "block");
    GtkWidget *block = button(list, "c_lena", SZFRIENDS_GTK_ICON_BLOCK);
    guint timers = szfg_clock_live(4000);
    click(block);
    EXPECT(armed(list) && gtk_widget_has_css_class(block, "armed"), "the first click arms");
    EXPECT(!g_strcmp0(gtk_widget_get_tooltip_text(block), "Click again to block Lena Weber") &&
               szfg_accessible_label_is(block, "Click again to block Lena Weber"), "and says what the next does");
    EXPECT(szfg_clock_live(4000) == timers + 1, "armed for the snapshot's 4 seconds");
    szfriends_gtk_row_actions_click(block, 2);
    szfg_clock_advance_ms(100);
    szfriends_gtk_row_actions_click(block, 1);
    szfg_pump_for(50);
    EXPECT(armed(list) && szfg_frames(harness, "block") == blocks, "a double-click blocks nobody");
    click(block);
    EXPECT(szfg_wait_frames(harness, "block", blocks + 1) && !armed(list), "a deliberate second click blocks");
    char *conversation = szfg_last_field(harness, "block", "conversation_id");
    EXPECT(!g_strcmp0(conversation, "c_lena"), "Lena (%s)", conversation);
    g_free(conversation);
    EXPECT(szfg_clock_live(4000) == timers, "and its timer goes");
    szfg_pump_for(50);

    /* Every way the pill turns back, sending nothing. */
    blocks = szfg_frames(harness, "block");
    click(block);
    EXPECT(szfg_clock_fire(4000) && !armed(list) && !gtk_widget_has_css_class(block, "armed") &&
               !g_strcmp0(gtk_widget_get_tooltip_text(block), "Block Lena Weber"), "the time passing");
    click(block);
    EXPECT(armed(list), "a click after that arms again");
    szfriends_gtk_dropdown_escape(list->dropdown);
    EXPECT(!armed(list) && szfriends_gtk_dropdown_is_open(list->dropdown), "Escape, closing nothing else");
    szfriends_gtk_dropdown_escape(list->dropdown);
    EXPECT(!szfriends_gtk_dropdown_is_open(list->dropdown), "then Escape closes the dropdown");
    szfriends_gtk_dropdown_open(list->dropdown);
    click(block);
    szfriends_gtk_row_pointer_left(szfg_list_row(list, "c_lena"));
    EXPECT(!armed(list), "the pointer leaving the row");
    click(block);
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    g_ptr_array_add(items, szfriends_gtk_host_item_new("a.pdf", NULL, NULL, "/tmp/szfg-a.pdf", NULL));
    szfriends_gtk_dropdown_begin_send_picker(list->dropdown, items);
    EXPECT(!armed(list) && !gtk_widget_get_sensitive(block), "the send picker fading the request");
    szfriends_gtk_dropdown_finish_send_picker(list->dropdown);
    EXPECT(gtk_widget_get_sensitive(block), "its buttons come back when the picker ends");
    g_ptr_array_unref(items);

    /* A refresh keeps the pill on Lena; a list that moves someone else into her place never inherits it. */
    click(block);
    guint seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    EXPECT(szfg_list_wait_snapshot(list, seen) && armed(list), "an unchanged snapshot keeps it armed");
    JsonObject *frame = szfg_fixture("snapshots/list.json"), *data = json_object_get_object_member(frame, "data");
    JsonArray *rows = json_object_get_array_member(data, "rows"), *swapped = json_array_new();
    for (guint i = 0; i < json_array_get_length(rows); i++) /* Lena and Kenji trade places */
        json_array_add_element(swapped, json_node_copy(json_array_get_element(rows, i == 0 ? 2 : i == 2 ? 0 : i)));
    json_object_set_array_member(data, "rows", swapped);
    JsonNode *node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(node, data);
    char *text = json_to_string(node, FALSE);
    szfriends_fake_helper_set_view_data(harness->fake, "list", text);
    g_free(text);
    json_node_unref(node);
    json_object_unref(frame);
    EXPECT(szfg_pump_until(reordered, list, 3000), "the list reordered");
    for (guint i = 0; i < list->parts->rows->len; i++)
        EXPECT(!szfriends_gtk_row_actions_is_armed(szfriends_gtk_row_get_actions(g_ptr_array_index(list->parts->rows,
                                                                                                   i))),
               "row %u is not armed after the list reordered", i);
    EXPECT(szfg_frames(harness, "block") == blocks, "none of this blocked anyone");
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_list_close(list);
}

/* ---- Files --------------------------------------------------------------------------------------- */

static void file_list(GValue *value, const char *const *paths) {
    GSList *files = NULL;
    for (gsize i = 0; paths[i]; i++) files = g_slist_append(files, g_file_new_for_path(paths[i]));
    g_value_init(value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(value, gdk_file_list_new_from_list(files));
    g_slist_free_full(files, g_object_unref);
}

static guint sent_files(SZFGHarness *harness, const char *conversation_id) {
    JsonObject *frame = szfg_fake_last_frame(harness, "send_files");
    guint count = 0;
    if (frame && !g_strcmp0(json_object_get_string_member_with_default(frame, "conversation_id", ""), conversation_id))
        count = json_array_get_length(json_object_get_array_member(frame, "files"));
    if (frame) json_object_unref(frame);
    return count;
}

static void test_drops(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    char *dir = szfg_temp_dir("list-drop");
    char *a = g_build_filename(dir, "Site photos.pdf", NULL), *b = g_build_filename(dir, "notes.txt", NULL);
    char *folder = g_build_filename(dir, "Photos", NULL);
    g_file_set_contents(a, "%PDF-1.4\n", -1, NULL);
    g_file_set_contents(b, "notes\n", -1, NULL);
    g_mkdir(folder, 0700);
    const char *two[] = {a, b, NULL}, *with_folder[] = {a, folder, NULL};
    GValue files = G_VALUE_INIT, folders = G_VALUE_INIT;
    file_list(&files, two);
    file_list(&folders, with_folder);
    GtkWidget *mei = szfg_list_row(list, "c_mei"), *lena = szfg_list_row(list, "c_lena");
    szfriends_gtk_row_drag_value(mei, &files);
    SZFriendsGtkRowLook look = szfriends_gtk_row_get_look(mei);
    EXPECT(szfriends_gtk_row_get_drop(mei) == SZFRIENDS_GTK_ROW_DROP_ACCEPT &&
               gtk_widget_has_css_class(mei, "drop-accept") && !g_strcmp0(look.pill, "Send to Mei"),
           "files over Mei: highlighted, \"Send to Mei\"");
    guint sends = szfg_frames(harness, "send_files");
    EXPECT(szfriends_gtk_row_drop(mei, &files), "the drop is taken");
    EXPECT(szfg_wait_frames(harness, "send_files", sends + 1) && sent_files(harness, "c_mei") == 2,
           "sent at once to Mei: one offer per file");
    EXPECT(szfriends_gtk_row_get_drop(mei) == SZFRIENDS_GTK_ROW_DROP_NONE, "the highlight goes with the drop");
    szfriends_gtk_row_drag_value(mei, &folders);
    look = szfriends_gtk_row_get_look(mei);
    EXPECT(look.pill_warning && !g_strcmp0(look.pill, "Folders can’t be sent yet"), "a folder: %s", look.pill);
    EXPECT(!szfriends_gtk_row_drop(mei, &folders), "and the drop is refused, sending none of it");
    szfriends_gtk_row_drag_value(lena, &files);
    look = szfriends_gtk_row_get_look(lena);
    EXPECT(look.pill_warning && !g_strcmp0(look.pill, "Lena isn’t your friend yet"), "a request: %s", look.pill);
    EXPECT(!szfriends_gtk_row_drop(lena, &files), "she cannot receive files yet");
    szfriends_gtk_row_drag_value(szfg_list_row(list, "c_jonas"), &files);
    look = szfriends_gtk_row_get_look(szfg_list_row(list, "c_jonas"));
    EXPECT(!g_strcmp0(look.pill, "You blocked Jonas"), "someone blocked: %s", look.pill);
    szfriends_gtk_row_drag_leave(szfg_list_row(list, "c_jonas"));
    szfg_pump_for(100);
    EXPECT(szfg_frames(harness, "send_files") == sends + 1, "only the one drop sent anything");

    /* Released on the button: "Send 2 files to…", then the friend clicked next. */
    GPtrArray *items = szfriends_gtk_drop_items(szfriends_gtk_link_host(harness->link), &files, NULL);
    szfriends_gtk_dropdown_begin_send_picker(list->dropdown, items);
    EXPECT(gtk_widget_get_visible(list->parts->send_notice) && gtk_widget_get_visible(list->parts->send_cancel) &&
               !g_strcmp0(gtk_label_get_text(GTK_LABEL(list->parts->send_text)),
                          szfriends_gtk_dropdown_get_send_title(list->dropdown)), "the picker says what waits");
    EXPECT(!g_strcmp0(gtk_widget_get_tooltip_text(list->parts->send_notice), "Site photos.pdf\nnotes.txt"),
           "and lists every file under the pointer");
    EXPECT(gtk_widget_has_css_class(lena, "dimmed") && !gtk_widget_has_css_class(mei, "dimmed"),
           "people who cannot receive files fade");
    szfriends_gtk_row_activate(lena);
    EXPECT(szfriends_gtk_dropdown_get_send_items(list->dropdown) &&
               szfriends_gtk_dropdown_get_depth(list->dropdown) == 1,
           "a click on a request sends nothing and keeps the picker");
    szfriends_gtk_row_activate(mei);
    EXPECT(szfg_wait_frames(harness, "send_files", sends + 2) && sent_files(harness, "c_mei") == 2,
           "the friend clicked next gets the files");
    EXPECT(!szfriends_gtk_dropdown_get_send_items(list->dropdown) &&
               !g_strcmp0(szfriends_gtk_page_get_argument(szfriends_gtk_dropdown_get_top_page(list->dropdown)),
                          "c_mei"), "and their conversation opens");
    szfriends_gtk_dropdown_pop_to_list(list->dropdown);
    szfriends_gtk_dropdown_begin_send_picker(list->dropdown, items);
    g_signal_emit_by_name(list->parts->send_cancel, "clicked");
    EXPECT(!szfriends_gtk_dropdown_get_send_items(list->dropdown) && !gtk_widget_get_visible(list->parts->send_notice)
               && !gtk_widget_has_css_class(lena, "dimmed"), "Cancel ends the picker");
    szfriends_gtk_dropdown_set_drop_hint(list->dropdown, szfriends_gtk_link_string(harness->link, "drop_hint"));
    EXPECT(gtk_widget_get_visible(list->parts->send_notice) && !gtk_widget_get_visible(list->parts->send_cancel) &&
               gtk_widget_has_css_class(lena, "dimmed"), "files over the button: the hint, requests faded");
    szfriends_gtk_row_drag_value(mei, &files);
    szfriends_gtk_row_drop(mei, &files);
    EXPECT(!szfriends_gtk_dropdown_get_drop_hint(list->dropdown), "a drop on a friend ends the hint");
    g_ptr_array_unref(items);
    g_value_unset(&files);
    g_value_unset(&folders);
    szfg_remove_tree(dir);
    g_free(a), g_free(b), g_free(folder), g_free(dir);
    szfg_pump_for(50);
    szfg_list_close(list);
}

void szfg_run_list_row_probes(SZFGHarness *harness) {
    test_fixture_rows(harness);
    test_plain_text(harness);
    test_answers(harness);
    test_block(harness);
    test_drops(harness);
}
