/* A row's menu against the fake helper (PROTOCOL.md list_row menu): a right-click opens Remove, which asks first in
 * the dropdown's card with "Also delete chat history" unticked; confirming sends remove_friend for that person, with
 * delete_history only when ticked, and the row goes at once. Cancel sends nothing and keeps the row; a refusal brings
 * it back. Delete on the focused row and Shift+F10 reach the same menu from the keyboard; the You row has none. */

#include "szfriends_gtk_list_probe.h"

#include <string.h>

static const char list_with_menus[] =
    "{\"query\":\"\",\"banner\":null,\"name_prompt\":null,\"rows\":["
    "{\"conversation_id\":\"you\",\"title\":\"You\",\"subtitle\":\"Your computers\",\"time_label\":\"\","
    "\"route\":{\"kind\":\"none\",\"method\":null,\"label\":null},\"unread\":false,\"waiting\":null,"
    "\"blocked\":false,\"id_confirmed\":false,\"id_confirmed_label\":null,\"style\":\"normal\",\"drop_label\":null,"
    "\"drop_refusal\":null,\"accessibility_label\":\"You\",\"actions\":[],\"kind\":\"you\",\"menu\":[]},"
    "{\"conversation_id\":\"c_mei\",\"title\":\"Mei Lin\",\"subtitle\":\"See you Friday\",\"time_label\":\"14:32\","
    "\"route\":{\"kind\":\"local\",\"method\":\"lan\",\"label\":\"Nearby\"},\"unread\":false,\"waiting\":null,"
    "\"blocked\":false,\"id_confirmed\":false,\"id_confirmed_label\":null,\"style\":\"normal\","
    "\"drop_label\":\"Send to Mei\",\"drop_refusal\":null,\"accessibility_label\":\"Mei Lin\",\"actions\":[],"
    "\"kind\":\"person\",\"menu\":[{\"action\":\"remove_friend\",\"label\":\"Remove\",\"style\":\"destructive\","
    "\"note\":null,\"arm\":null,\"confirm\":{\"title\":\"Remove Mei?\",\"body\":\"Mei leaves your list and isn’t "
    "told. Your chat history with Mei is kept unless you also delete it.\",\"confirm_label\":\"Remove\","
    "\"cancel_label\":\"Cancel\",\"destructive\":true,\"option\":{\"label\":\"Also delete chat history\","
    "\"field\":\"delete_history\"}}}]},"
    "{\"conversation_id\":\"c_jonas\",\"title\":\"Jonas\",\"subtitle\":\"\",\"time_label\":\"\","
    "\"route\":{\"kind\":\"none\",\"method\":null,\"label\":null},\"unread\":false,\"waiting\":null,"
    "\"blocked\":false,\"id_confirmed\":false,\"id_confirmed_label\":null,\"style\":\"normal\",\"drop_label\":null,"
    "\"drop_refusal\":null,\"accessibility_label\":\"Jonas\",\"actions\":[],\"kind\":\"person\",\"menu\":[]}],"
    "\"empty\":null,\"footer\":{}}";

static GtkWidget *find_named(GtkWidget *root, const char *name) {
    if (!root) return NULL;
    if (!g_strcmp0(gtk_widget_get_name(root), name)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_named(child, name);
        if (found) return found;
    }
    return NULL;
}

static gboolean find_text(GtkWidget *root, const char *text) {
    if (!root) return FALSE;
    if (GTK_IS_LABEL(root) && !g_strcmp0(gtk_label_get_text(GTK_LABEL(root)), text)) return TRUE;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        if (find_text(child, text)) return TRUE;
    return FALSE;
}

static gboolean mei_shown(gpointer data) {
    return szfg_list_row(data, "c_mei") != NULL;
}

static SZFGList *open_with_menus(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    guint seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_data(harness->fake, "list", list_with_menus);
    EXPECT(szfg_list_wait_snapshot(list, seen) && szfg_list_wait_rows(list, 3), "the rows with menus arrive");
    return list;
}

static void click_named(GtkWidget *card, const char *name) {
    GtkWidget *button = find_named(card, name);
    EXPECT(button != NULL, "the card has %s", name);
    if (button) g_signal_emit_by_name(button, "clicked");
}

/* Right-click, Remove, tick "Also delete chat history", Remove: one remove_friend for Mei that deletes the history
 * too, and Mei's row is gone before the helper has answered. */
static void test_remove_with_history(SZFGHarness *harness) {
    SZFGList *list = open_with_menus(harness);
    GtkWidget *mei = szfg_list_row(list, "c_mei");
    EXPECT(!szfriends_gtk_row_open_menu(szfg_list_row(list, "you"), 4, 4) &&
               !szfriends_gtk_row_open_menu(szfg_list_row(list, "c_jonas"), 4, 4),
           "no menu on the You row or on a row whose menu is empty");
    EXPECT(mei && szfriends_gtk_row_open_menu(mei, 40, 20), "a right-click on Mei opens her menu");
    GtkWidget *menu = mei ? szfriends_gtk_row_get_menu(mei) : NULL;
    EXPECT(menu && GTK_IS_POPOVER_MENU(menu) && find_text(menu, "Remove"), "the menu offers Remove");
    guint removed = szfg_frames(harness, "remove_friend");
    szfriends_fake_helper_hold_replies(harness->fake, TRUE); /* the helper has not answered yet */
    gtk_widget_activate_action(mei, "row-menu.choose", "u", 0u);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(list->dropdown);
    GtkWidget *option = card ? find_named(card, "szfriends.confirmation.option") : NULL;
    EXPECT(card && find_text(card, "Remove Mei?") && option && GTK_IS_CHECK_BUTTON(option) &&
               !gtk_check_button_get_active(GTK_CHECK_BUTTON(option)) &&
               !g_strcmp0(gtk_check_button_get_label(GTK_CHECK_BUTTON(option)), "Also delete chat history"),
           "Remove asks first, with Also delete chat history unticked");
    EXPECT(!szfriends_gtk_row_get_menu(mei), "choosing closes the menu");
    EXPECT(szfg_frames(harness, "remove_friend") == removed, "nothing is sent before the answer");
    if (option) gtk_check_button_set_active(GTK_CHECK_BUTTON(option), TRUE);
    GtkWidget *ok = card ? find_named(card, "szfriends.confirmation.confirm") : NULL;
    EXPECT(ok && gtk_widget_has_css_class(ok, "destructive-action"), "the confirm button is red");
    click_named(card, "szfriends.confirmation.confirm");
    EXPECT(!szfg_list_row(list, "c_mei") && list->parts->rows->len == 2, "Mei's row goes at once");
    EXPECT(szfg_wait_frames(harness, "remove_friend", removed + 1), "remove_friend goes to the helper");
    JsonObject *frame = szfg_fake_last_frame(harness, "remove_friend");
    EXPECT(frame && !g_strcmp0(json_object_get_string_member_with_default(frame, "conversation_id", ""), "c_mei") &&
               json_object_has_member(frame, "delete_history") &&
               json_object_get_boolean_member(frame, "delete_history"),
           "for Mei, deleting the chat history too");
    if (frame) json_object_unref(frame);
    /* A snapshot that still has her (sent before the helper took her off) does not bring her back early. */
    guint seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_data(harness->fake, "list", list_with_menus);
    EXPECT(szfg_list_wait_snapshot(list, seen) && !szfg_list_row(list, "c_mei"), "she stays off until the reply");
    szfriends_fake_helper_hold_replies(harness->fake, FALSE);
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_list_close(list);
}

/* Delete on the focused row asks the same question; left unticked, the history stays (no delete_history). The
 * helper refuses: the row comes back where it was. Cancel sends nothing; Shift+F10 opens the menu. */
static void test_keys_cancel_and_refusal(SZFGHarness *harness) {
    SZFGList *list = open_with_menus(harness);
    GtkWidget *mei = szfg_list_row(list, "c_mei");
    guint removed = szfg_frames(harness, "remove_friend");
    EXPECT(mei && szfriends_gtk_row_key(mei, GDK_KEY_F10, GDK_SHIFT_MASK) && szfriends_gtk_row_get_menu(mei),
           "Shift+F10 opens the menu");
    EXPECT(szfriends_gtk_row_key(mei, GDK_KEY_Menu, 0) && szfriends_gtk_row_get_menu(mei), "so does the Menu key");
    EXPECT(!szfriends_gtk_row_key(szfg_list_row(list, "c_jonas"), GDK_KEY_Delete, 0) &&
               !szfriends_gtk_dropdown_get_overlay(list->dropdown), "Delete does nothing on a row without a menu");
    EXPECT(!szfriends_gtk_row_key(mei, GDK_KEY_BackSpace, 0), "Backspace never removes anyone");
    EXPECT(szfriends_gtk_row_key(mei, GDK_KEY_Delete, 0), "Delete on Mei's row");
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(list->dropdown);
    EXPECT(card && find_text(card, "Remove Mei?"), "asks the same question");
    click_named(card, "szfriends.confirmation.cancel");
    szfg_pump_for(50);
    EXPECT(!szfriends_gtk_dropdown_get_overlay(list->dropdown) && szfg_list_row(list, "c_mei") &&
               szfg_frames(harness, "remove_friend") == removed, "Cancel sends nothing and keeps the row");
    szfriends_fake_helper_set_reply(harness->fake, "remove_friend",
                                    "{\"type\":\"reply\",\"re\":\"0\",\"ok\":false,\"error\":{\"code\":\"not_found\","
                                    "\"message\":\"Mei isn’t on this computer any more.\",\"retryable\":false,"
                                    "\"details\":{}}}");
    szfg_pump_for(50);
    szfriends_gtk_row_key(mei, GDK_KEY_Delete, 0);
    card = szfriends_gtk_dropdown_get_overlay(list->dropdown);
    click_named(card, "szfriends.confirmation.confirm");
    EXPECT(!szfg_list_row(list, "c_mei"), "the row goes as soon as the person confirms");
    EXPECT(szfg_wait_frames(harness, "remove_friend", removed + 1), "remove_friend goes to the helper");
    JsonObject *frame = szfg_fake_last_frame(harness, "remove_friend");
    EXPECT(frame && !g_strcmp0(json_object_get_string_member_with_default(frame, "conversation_id", ""), "c_mei") &&
               !json_object_has_member(frame, "delete_history"), "unticked, the history is kept");
    if (frame) json_object_unref(frame);
    EXPECT(szfg_pump_until(mei_shown, list, 3000),
           "refused, Mei's row comes back");
    GtkWidget *back = szfg_list_row(list, "c_mei");
    EXPECT(back && g_ptr_array_index(list->parts->rows, 1) == back, "in the place it had");
    szfriends_fake_helper_set_reply(harness->fake, "remove_friend", NULL);
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_list_close(list);
}

void szfg_run_list_menu_probes(SZFGHarness *harness) {
    test_remove_with_history(harness);
    test_keys_cancel_and_refusal(harness);
}
