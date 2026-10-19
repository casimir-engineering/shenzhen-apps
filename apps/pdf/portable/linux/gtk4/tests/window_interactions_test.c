// Pure MRU/maximize policy tests plus source-level guards for the GTK wiring.
#include <string.h>

#include "../spdf_window_interactions.c"

typedef struct {
    gpointer pages[8];
    int count;
} PresentPages;

static gboolean page_is_present(gpointer page, gpointer user_data) {
    PresentPages* present = user_data;
    for (int i = 0; i < present->count; ++i)
        if (present->pages[i] == page) return TRUE;
    return FALSE;
}

static void present_remove(PresentPages* present, gpointer page) {
    for (int i = 0; i < present->count; ++i) {
        if (present->pages[i] != page) continue;
        memmove(&present->pages[i], &present->pages[i + 1], (gsize)(present->count - i - 1) * sizeof(gpointer));
        present->count--;
        return;
    }
}

static void test_detach_active_restores_mru(void) {
    SpdfWindowTabHistory history;
    int a, b, c;
    PresentPages present = {{&a, &b, &c}, 3};

    spdf_window_tab_history_init(&history);
    spdf_window_tab_history_activate(&history, &a);
    spdf_window_tab_history_activate(&history, &b);
    spdf_window_tab_history_activate(&history, &a);
    spdf_window_tab_history_activate(&history, &c);
    present_remove(&present, &c);

    g_assert_true(spdf_window_tab_history_remove(&history, &c, TRUE, page_is_present, &present) == &a);
    g_assert_true(history.selected == &a);
    spdf_window_tab_history_clear(&history);
}

static void test_detach_notification_order_restores_mru(void) {
    SpdfWindowTabHistory history;
    int a, b, c;
    PresentPages present = {{&a, &b, &c}, 3};

    spdf_window_tab_history_init(&history);
    spdf_window_tab_history_activate(&history, &a);
    spdf_window_tab_history_activate(&history, &b);
    spdf_window_tab_history_activate(&history, &a);
    spdf_window_tab_history_activate(&history, &c);
    present_remove(&present, &c);

    // AdwTabView may notify the adjacent B before ::page-detached. That
    // automatic adjacency must not enter the MRU history.
    g_assert_true(spdf_window_tab_history_selection_changed(&history, &b, page_is_present, &present) == &a);
    g_assert_true(history.selected == &a);
    spdf_window_tab_history_clear(&history);
}

static void test_detach_inactive_keeps_selection(void) {
    SpdfWindowTabHistory history;
    int a, b, c;
    PresentPages present = {{&a, &b}, 2};

    spdf_window_tab_history_init(&history);
    spdf_window_tab_history_activate(&history, &b);
    spdf_window_tab_history_activate(&history, &c);
    spdf_window_tab_history_activate(&history, &a);
    g_assert_null(spdf_window_tab_history_remove(&history, &c, TRUE, page_is_present, &present));
    g_assert_true(history.selected == &a);
    spdf_window_tab_history_clear(&history);
}

static void test_close_uses_native_adjacent_selection(void) {
    SpdfWindowTabHistory history;
    int a, b;
    PresentPages present = {{&a, &b}, 2};

    spdf_window_tab_history_init(&history);
    spdf_window_tab_history_activate(&history, &a);
    spdf_window_tab_history_activate(&history, &b);
    g_assert_null(spdf_window_tab_history_remove(&history, &b, FALSE, page_is_present, &present));
    g_assert_null(history.selected);
    g_assert_null(spdf_window_tab_history_selection_changed(&history, &a, page_is_present, &present));
    g_assert_true(history.selected == &a);
    spdf_window_tab_history_clear(&history);
}

static void test_header_double_click_policy(void) {
    g_assert_true(
        spdf_window_header_should_toggle_maximize(2, SPDF_WINDOW_PRIMARY_BUTTON, SPDF_HEADER_HIT_EMPTY, FALSE));
    g_assert_false(
        spdf_window_header_should_toggle_maximize(1, SPDF_WINDOW_PRIMARY_BUTTON, SPDF_HEADER_HIT_EMPTY, FALSE));
    g_assert_false(
        spdf_window_header_should_toggle_maximize(3, SPDF_WINDOW_PRIMARY_BUTTON, SPDF_HEADER_HIT_EMPTY, FALSE));
    g_assert_false(spdf_window_header_should_toggle_maximize(2, 3, SPDF_HEADER_HIT_EMPTY, FALSE));
    g_assert_false(
        spdf_window_header_should_toggle_maximize(2, SPDF_WINDOW_PRIMARY_BUTTON, SPDF_HEADER_HIT_CONTROL, FALSE));
    g_assert_false(
        spdf_window_header_should_toggle_maximize(2, SPDF_WINDOW_PRIMARY_BUTTON, SPDF_HEADER_HIT_EMPTY, TRUE));
}

static char* read_gtk_source(const char* name) {
    char* test_dir = g_path_get_dirname(__FILE__);
    char* path = g_build_filename(test_dir, "..", name, NULL);
    char* source = NULL;

    g_assert_true(g_file_get_contents(path, &source, NULL, NULL));
    g_free(path);
    g_free(test_dir);
    return source;
}

static void test_close_shortcut_source_contract(void) {
    char* window_source = read_gtk_source("spdf_window.c");
    char* shortcut_source = read_gtk_source("spdf_shortcuts.c");
    const char* action = strstr(window_source, "static void action_close_tab");
    const char* next_action = action ? strstr(action + 1, "static void action_") : NULL;

    g_assert_nonnull(action);
    g_assert_nonnull(next_action);
    g_assert_nonnull(g_strstr_len(action, next_action - action, "adw_tab_view_get_selected_page"));
    g_assert_nonnull(g_strstr_len(action, next_action - action, "adw_tab_view_close_page"));
    g_assert_null(g_strstr_len(action, next_action - action, "tab->doc"));
    g_assert_nonnull(strstr(shortcut_source, "{\"win.close-tab\", {\"<Control>w\""));
    g_free(shortcut_source);
    g_free(window_source);
}

static void test_tab_menu_source_contract(void) {
    char* source = read_gtk_source("spdf_window.c");
    const char* menu = strstr(source, "static GMenuModel* build_tab_context_menu");
    const char* next = menu ? strstr(menu + 1, "static GMenuModel*") : NULL;

    g_assert_nonnull(menu);
    g_assert_nonnull(next);
    g_assert_nonnull(g_strstr_len(menu, next - menu, "Copy Document"));
    g_assert_nonnull(g_strstr_len(menu, next - menu, "Copy Title"));
    g_assert_nonnull(g_strstr_len(menu, next - menu, "Copy Path"));
    g_assert_nonnull(strstr(source, "GDK_TYPE_FILE_LIST"));
    g_assert_nonnull(strstr(source, "G_FILE_TEST_IS_REGULAR"));
    g_free(source);
}

static void test_header_gesture_source_contract(void) {
    char* source = read_gtk_source("spdf_window.c");
    const char* constructor = strstr(source, "static GtkWidget* header_bar_new");
    const char* constructor_end = constructor ? strstr(constructor + 1, "static gboolean deferred_menus_idle") : NULL;

    g_assert_nonnull(constructor);
    g_assert_nonnull(constructor_end);
    g_assert_nonnull(g_strstr_len(constructor, constructor_end - constructor,
                                  "gtk_widget_add_controller(header, GTK_EVENT_CONTROLLER(header_click))"));
    g_assert_null(strstr(source, "gtk_widget_add_controller(GTK_WIDGET(self->tab_bar)"));
    g_assert_nonnull(strstr(source, "g_signal_connect(self->tab_view, \"create-window\""));
    g_assert_nonnull(strstr(source, "adw_tab_bar_set_view(self->tab_bar, self->tab_view)"));
    g_free(source);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/window/history/detach-active", test_detach_active_restores_mru);
    g_test_add_func("/window/history/detach-notify-order", test_detach_notification_order_restores_mru);
    g_test_add_func("/window/history/detach-inactive", test_detach_inactive_keeps_selection);
    g_test_add_func("/window/history/close-native-selection", test_close_uses_native_adjacent_selection);
    g_test_add_func("/window/header/double-click-policy", test_header_double_click_policy);
    g_test_add_func("/window/source/close-shortcut", test_close_shortcut_source_contract);
    g_test_add_func("/window/source/tab-menu", test_tab_menu_source_contract);
    g_test_add_func("/window/source/header-does-not-own-tabs", test_header_gesture_source_contract);
    return g_test_run();
}
