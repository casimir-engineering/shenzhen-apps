#ifndef SPDF_SELECTION_ADAPTER_H
#define SPDF_SELECTION_ADAPTER_H

#include "../../core/shenzhen_pdf_core.h"

#include <stddef.h>

typedef enum SpdfSelectionAdapterStatus {
    SPDF_SELECTION_ADAPTER_ERROR = -1,
    SPDF_SELECTION_ADAPTER_NONE = 0,
    SPDF_SELECTION_ADAPTER_SELECTED = 1,
} SpdfSelectionAdapterStatus;

typedef struct SpdfSelectionAdapterResult {
    SpdfSelectionAdapterStatus status;
    char* text;
    spdf_rect* rects;
    size_t rect_count;
    unsigned flags;
    char* error_message;
} SpdfSelectionAdapterResult;

/* A result owns its text, rectangles, and error message. Reset before a tab
 * replaces its document and on cancellation or teardown. Repeated reset is
 * safe. spdf_selection_adapter_select() resets an existing result first. */
void spdf_selection_adapter_result_init(SpdfSelectionAdapterResult* result);
void spdf_selection_adapter_result_reset(SpdfSelectionAdapterResult* result);
void spdf_selection_adapter_result_free(SpdfSelectionAdapterResult* result);

SpdfSelectionAdapterStatus spdf_selection_adapter_select(spdf_document* document, int page_index,
                                                         spdf_selection_granularity granularity, float ax, float ay,
                                                         float bx, float by, SpdfSelectionAdapterResult* result);

typedef struct SpdfSelectionClickPolicy {
    spdf_selection_granularity granularity;
    int uses_range_path;
    int cancels_pending_link;
} SpdfSelectionClickPolicy;

/* GTK reports the accumulated press count. Zero is treated defensively as a
 * single press. Single presses remain range/link candidates, double presses
 * select a word, and triple-or-later presses select the containing block. */
SpdfSelectionClickPolicy spdf_selection_click_policy(unsigned press_count);

/* GTK drag thresholds are axis based: crossing the threshold on either axis
 * starts a drag. A negative threshold is treated as zero. */
int spdf_selection_drag_threshold_crossed(double start_x, double start_y, double current_x, double current_y,
                                          double threshold);

typedef struct SpdfSelectionGestureState {
    unsigned press_count;
    int pending_link;
    int link_cancelled;
    int dragging;
} SpdfSelectionGestureState;

void spdf_selection_gesture_reset(SpdfSelectionGestureState* state);
SpdfSelectionClickPolicy spdf_selection_gesture_begin(SpdfSelectionGestureState* state, unsigned press_count,
                                                      int over_link);
int spdf_selection_gesture_update_drag(SpdfSelectionGestureState* state, double start_x, double start_y,
                                       double current_x, double current_y, double threshold);
void spdf_selection_gesture_cancel(SpdfSelectionGestureState* state);
int spdf_selection_gesture_take_link(SpdfSelectionGestureState* state);

#endif
