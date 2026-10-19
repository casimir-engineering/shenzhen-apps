#include "spdf_docview_selection.h"

#include <limits.h>
#include <string.h>

static gboolean result_equal(const SpdfSelectionAdapterResult* a, const SpdfSelectionAdapterResult* b) {
    if (a->status != b->status || a->rect_count != b->rect_count || a->flags != b->flags) return FALSE;
    if (g_strcmp0(a->text, b->text) != 0) return FALSE;
    if (a->rect_count == 0) return TRUE;
    return a->rects && b->rects && memcmp(a->rects, b->rects, a->rect_count * sizeof(*a->rects)) == 0;
}

static gboolean replace_result(SpdfDocViewSelection* selection, spdf_document* document,
                               spdf_selection_granularity granularity, double ax, double ay, double bx, double by) {
    SpdfSelectionAdapterResult next;
    gboolean changed;

    spdf_selection_adapter_result_init(&next);
    spdf_selection_adapter_select(document, selection->page, granularity, (float)ax, (float)ay, (float)bx, (float)by,
                                  &next);
    changed = !result_equal(&selection->result, &next);
    spdf_selection_adapter_result_reset(&selection->result);
    selection->result = next;
    return changed;
}

static void cancel_delayed_link(SpdfDocViewSelection* selection) {
    if (selection->delayed_link_id) {
        g_source_remove(selection->delayed_link_id);
        selection->delayed_link_id = 0;
    }
    selection->link_activation = NULL;
    selection->link_user_data = NULL;
}

static gboolean activate_delayed_link(gpointer data) {
    SpdfDocViewSelection* selection = data;
    SpdfDocViewLinkActivation activate = selection->link_activation;
    gpointer user_data = selection->link_user_data;
    int page = selection->page;
    double page_x = selection->link_page_x;
    double page_y = selection->link_page_y;

    selection->delayed_link_id = 0;
    selection->link_activation = NULL;
    selection->link_user_data = NULL;
    if (spdf_selection_gesture_take_link(&selection->gesture) && activate) activate(user_data, page, page_x, page_y);
    return G_SOURCE_REMOVE;
}

guint spdf_docview_selection_remaining_delay_ms(gint64 press_started_us, guint interval_ms, gint64 now_us) {
    gint64 interval_us = (gint64)interval_ms * 1000;
    gint64 deadline;
    gint64 remaining_us;

    if (press_started_us <= 0 || now_us <= 0) return interval_ms;
    deadline = press_started_us > G_MAXINT64 - interval_us ? G_MAXINT64 : press_started_us + interval_us;
    if (now_us >= deadline) return 0;
    remaining_us = deadline - now_us;
    return (guint)MIN((guint64)G_MAXUINT, ((guint64)remaining_us + 999) / 1000);
}

void spdf_docview_selection_init(SpdfDocViewSelection* selection) {
    if (!selection) return;
    memset(selection, 0, sizeof(*selection));
    selection->page = -1;
    spdf_selection_adapter_result_init(&selection->result);
    spdf_selection_gesture_reset(&selection->gesture);
}

void spdf_docview_selection_reset(SpdfDocViewSelection* selection) {
    if (!selection) return;
    spdf_docview_selection_cancel(selection);
    spdf_selection_adapter_result_reset(&selection->result);
    spdf_selection_gesture_reset(&selection->gesture);
    selection->page = -1;
}

gboolean spdf_docview_selection_clear(SpdfDocViewSelection* selection) {
    gboolean had;

    if (!selection) return FALSE;
    had = selection->result.status != SPDF_SELECTION_ADAPTER_NONE || selection->result.text ||
          selection->result.rect_count > 0;
    spdf_selection_adapter_result_reset(&selection->result);
    selection->page = -1;
    selection->active = FALSE;
    selection->range_path = FALSE;
    return had;
}

gboolean spdf_docview_selection_press_at(SpdfDocViewSelection* selection, spdf_document* document, int page,
                                         double widget_x, double widget_y, double page_x, double page_y,
                                         unsigned press_count, gint64 now_us) {
    SpdfSelectionClickPolicy policy;
    gboolean changed;

    if (!selection) return FALSE;
    cancel_delayed_link(selection);
    policy = spdf_selection_gesture_begin(&selection->gesture, press_count, page >= 0);
    changed = spdf_docview_selection_clear(selection);
    selection->gesture.press_count = press_count;
    selection->gesture.pending_link = page >= 0 && policy.uses_range_path;
    selection->page = page;
    selection->start_widget_x = widget_x;
    selection->start_widget_y = widget_y;
    selection->start_page_x = page_x;
    selection->start_page_y = page_y;
    selection->link_page_x = page_x;
    selection->link_page_y = page_y;
    selection->press_started_us = now_us;
    selection->active = document && page >= 0;
    selection->range_path = policy.uses_range_path;
    if (!selection->active || policy.uses_range_path) return changed;
    return replace_result(selection, document, policy.granularity, page_x, page_y, page_x, page_y) || changed;
}

gboolean spdf_docview_selection_press(SpdfDocViewSelection* selection, spdf_document* document, int page,
                                      double widget_x, double widget_y, double page_x, double page_y,
                                      unsigned press_count) {
    return spdf_docview_selection_press_at(selection, document, page, widget_x, widget_y, page_x, page_y, press_count,
                                           g_get_monotonic_time());
}

gboolean spdf_docview_selection_drag(SpdfDocViewSelection* selection, spdf_document* document, double widget_x,
                                     double widget_y, double page_x, double page_y, double threshold) {
    if (!selection || !selection->active || !selection->range_path || !document) return FALSE;
    if (!spdf_selection_gesture_update_drag(&selection->gesture, selection->start_widget_x, selection->start_widget_y,
                                            widget_x, widget_y, threshold))
        return FALSE;
    return replace_result(selection, document, SPDF_SELECTION_RANGE, selection->start_page_x, selection->start_page_y,
                          page_x, page_y);
}

void spdf_docview_selection_release_at(SpdfDocViewSelection* selection, guint multi_click_delay_ms,
                                       SpdfDocViewLinkActivation activate, gpointer user_data, gint64 now_us) {
    guint remaining_ms;

    if (!selection) return;
    selection->active = FALSE;
    if (!selection->gesture.pending_link || selection->gesture.dragging || spdf_docview_selection_has_text(selection))
        return;
    cancel_delayed_link(selection);
    selection->link_activation = activate;
    selection->link_user_data = user_data;
    remaining_ms = spdf_docview_selection_remaining_delay_ms(selection->press_started_us, multi_click_delay_ms, now_us);
    if (remaining_ms == 0) {
        activate_delayed_link(selection);
        return;
    }
    selection->delayed_link_id = g_timeout_add(remaining_ms, activate_delayed_link, selection);
}

void spdf_docview_selection_release(SpdfDocViewSelection* selection, guint multi_click_delay_ms,
                                    SpdfDocViewLinkActivation activate, gpointer user_data) {
    spdf_docview_selection_release_at(selection, multi_click_delay_ms, activate, user_data, g_get_monotonic_time());
}

void spdf_docview_selection_cancel(SpdfDocViewSelection* selection) {
    if (!selection) return;
    cancel_delayed_link(selection);
    spdf_selection_gesture_cancel(&selection->gesture);
    selection->press_started_us = 0;
    selection->active = FALSE;
    selection->range_path = FALSE;
}

void spdf_docview_selection_click_stopped(SpdfDocViewSelection* selection) {
    if (!selection || !selection->active || selection->gesture.pending_link || selection->gesture.dragging) return;
    spdf_docview_selection_cancel(selection);
}

gboolean spdf_docview_selection_has_text(const SpdfDocViewSelection* selection) {
    return selection && selection->page >= 0 && selection->result.status == SPDF_SELECTION_ADAPTER_SELECTED &&
           selection->result.text && selection->result.text[0] && selection->result.rects &&
           selection->result.rect_count;
}

gboolean spdf_docview_selection_is_dragging(const SpdfDocViewSelection* selection) {
    return selection && selection->active && selection->gesture.dragging;
}

char* spdf_docview_selection_copy_text(const SpdfDocViewSelection* selection) {
    return spdf_docview_selection_has_text(selection) ? g_strdup(selection->result.text) : NULL;
}

int spdf_docview_selection_copy_rects(const SpdfDocViewSelection* selection, int* page, spdf_rect* rects,
                                      int rect_max) {
    size_t count;

    if (!spdf_docview_selection_has_text(selection) || rect_max <= 0) return 0;
    count = MIN(selection->result.rect_count, (size_t)rect_max);
    count = MIN(count, (size_t)INT_MAX);
    if (rects) memcpy(rects, selection->result.rects, count * sizeof(*rects));
    if (page) *page = selection->page;
    return (int)count;
}
