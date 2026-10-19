#include "spdf_window_interactions.h"

static int history_index_of(const SpdfWindowTabHistory* history, gpointer page) {
    if (!history || !history->pages || !page) return -1;
    for (guint i = 0; i < history->pages->len; ++i)
        if (g_ptr_array_index(history->pages, i) == page) return (int)i;
    return -1;
}

static gpointer history_most_recent_present(const SpdfWindowTabHistory* history, SpdfWindowPagePresentFunc is_present,
                                            gpointer user_data) {
    if (!history || !history->pages || !is_present) return NULL;
    for (guint i = 0; i < history->pages->len; ++i) {
        gpointer page = g_ptr_array_index(history->pages, i);
        if (is_present(page, user_data)) return page;
    }
    return NULL;
}

void spdf_window_tab_history_init(SpdfWindowTabHistory* history) {
    g_return_if_fail(history != NULL);
    history->pages = g_ptr_array_new();
    history->selected = NULL;
}

void spdf_window_tab_history_clear(SpdfWindowTabHistory* history) {
    if (!history) return;
    g_clear_pointer(&history->pages, g_ptr_array_unref);
    history->selected = NULL;
}

void spdf_window_tab_history_activate(SpdfWindowTabHistory* history, gpointer page) {
    int index;

    g_return_if_fail(history != NULL);
    if (!page) {
        history->selected = NULL;
        return;
    }
    if (!history->pages) history->pages = g_ptr_array_new();
    index = history_index_of(history, page);
    if (index >= 0) g_ptr_array_remove_index(history->pages, (guint)index);
    g_ptr_array_insert(history->pages, 0, page);
    history->selected = page;
}

gpointer spdf_window_tab_history_remove(SpdfWindowTabHistory* history, gpointer page, gboolean restore_previous,
                                        SpdfWindowPagePresentFunc is_present, gpointer user_data) {
    gboolean was_selected;
    int index;
    gpointer replacement = NULL;

    g_return_val_if_fail(history != NULL, NULL);
    was_selected = page && history->selected == page;
    index = history_index_of(history, page);
    if (index >= 0) g_ptr_array_remove_index(history->pages, (guint)index);
    if (!was_selected) return NULL;

    history->selected = NULL;
    if (restore_previous) replacement = history_most_recent_present(history, is_present, user_data);
    if (replacement) spdf_window_tab_history_activate(history, replacement);
    return replacement;
}

gpointer spdf_window_tab_history_selection_changed(SpdfWindowTabHistory* history, gpointer page,
                                                   SpdfWindowPagePresentFunc is_present, gpointer user_data) {
    gpointer old_page;
    gpointer replacement;

    g_return_val_if_fail(history != NULL, NULL);
    old_page = history->selected;
    if (old_page && old_page != page && is_present && !is_present(old_page, user_data)) {
        replacement = spdf_window_tab_history_remove(history, old_page, TRUE, is_present, user_data);
        if (replacement) return replacement;
    }
    spdf_window_tab_history_activate(history, page);
    return NULL;
}

gboolean spdf_window_header_should_toggle_maximize(guint press_count, guint button, SpdfHeaderHitKind hit,
                                                   gboolean fullscreen_or_presentation) {
    return press_count == 2 && button == SPDF_WINDOW_PRIMARY_BUTTON && hit == SPDF_HEADER_HIT_EMPTY &&
           !fullscreen_or_presentation;
}
