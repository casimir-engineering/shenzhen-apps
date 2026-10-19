#ifndef SPDF_DOCVIEW_SELECTION_H
#define SPDF_DOCVIEW_SELECTION_H

#include "spdf_selection_adapter.h"

#include <glib.h>

typedef gboolean (*SpdfDocViewLinkActivation)(gpointer user_data, int page, double page_x, double page_y);

typedef struct SpdfDocViewSelection {
    SpdfSelectionAdapterResult result;
    SpdfSelectionGestureState gesture;
    guint delayed_link_id;
    SpdfDocViewLinkActivation link_activation;
    gpointer link_user_data;
    int page;
    double start_widget_x;
    double start_widget_y;
    double start_page_x;
    double start_page_y;
    double link_page_x;
    double link_page_y;
    gint64 press_started_us;
    gboolean active;
    gboolean range_path;
} SpdfDocViewSelection;

void spdf_docview_selection_init(SpdfDocViewSelection* selection);
void spdf_docview_selection_reset(SpdfDocViewSelection* selection);
gboolean spdf_docview_selection_clear(SpdfDocViewSelection* selection);

/* Starts one GTK multi-click sequence. A page below zero clears/cancels the
 * interaction without selecting. Returns TRUE when visible selection changed. */
gboolean spdf_docview_selection_press(SpdfDocViewSelection* selection, spdf_document* document, int page,
                                      double widget_x, double widget_y, double page_x, double page_y,
                                      unsigned press_count);
gboolean spdf_docview_selection_press_at(SpdfDocViewSelection* selection, spdf_document* document, int page,
                                         double widget_x, double widget_y, double page_x, double page_y,
                                         unsigned press_count, gint64 now_us);

/* Updates a single-click range drag. Multi-click point selections remain
 * stable while their companion GtkGestureDrag finishes. */
gboolean spdf_docview_selection_drag(SpdfDocViewSelection* selection, spdf_document* document, double widget_x,
                                     double widget_y, double page_x, double page_y, double threshold);

/* Defers a click candidate for GTK's multi-click interval. A later press,
 * document replacement, or teardown cancels it before activation. */
void spdf_docview_selection_release(SpdfDocViewSelection* selection, guint multi_click_delay_ms,
                                    SpdfDocViewLinkActivation activate, gpointer user_data);
void spdf_docview_selection_release_at(SpdfDocViewSelection* selection, guint multi_click_delay_ms,
                                       SpdfDocViewLinkActivation activate, gpointer user_data, gint64 now_us);

/* Cancellation ends the in-flight gesture and delayed link, but preserves a
 * completed range/word/block result. Click "stopped" only ends a live
 * non-link selection; normal click-series expiry must not cancel its timer. */
void spdf_docview_selection_cancel(SpdfDocViewSelection* selection);
void spdf_docview_selection_click_stopped(SpdfDocViewSelection* selection);
guint spdf_docview_selection_remaining_delay_ms(gint64 press_started_us, guint interval_ms, gint64 now_us);

gboolean spdf_docview_selection_has_text(const SpdfDocViewSelection* selection);
gboolean spdf_docview_selection_is_dragging(const SpdfDocViewSelection* selection);
char* spdf_docview_selection_copy_text(const SpdfDocViewSelection* selection);
int spdf_docview_selection_copy_rects(const SpdfDocViewSelection* selection, int* page, spdf_rect* rects, int rect_max);

#endif
