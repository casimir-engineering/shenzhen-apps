#include "spdf_selection_adapter.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_SELECTION_ERROR_CAPACITY 1024

static char* copy_string(const char* text) {
    size_t size;
    char* copy;

    if (!text) return NULL;
    size = strlen(text) + 1;
    copy = malloc(size);
    if (copy) memcpy(copy, text, size);
    return copy;
}

static void set_error(SpdfSelectionAdapterResult* result, const char* message) {
    result->status = SPDF_SELECTION_ADAPTER_ERROR;
    result->error_message = copy_string(message && message[0] ? message : "Text selection failed.");
}

void spdf_selection_adapter_result_init(SpdfSelectionAdapterResult* result) {
    if (result) memset(result, 0, sizeof(*result));
}

void spdf_selection_adapter_result_reset(SpdfSelectionAdapterResult* result) {
    spdf_text_selection core;

    if (!result) return;
    if (result->text || result->rects) {
        memset(&core, 0, sizeof(core));
        core.text = result->text;
        core.rects = result->rects;
        core.rect_count = result->rect_count > (size_t)INT_MAX ? INT_MAX : (int)result->rect_count;
        core.flags = result->flags;
        spdf_free_text_selection(&core);
    }
    free(result->error_message);
    memset(result, 0, sizeof(*result));
}

void spdf_selection_adapter_result_free(SpdfSelectionAdapterResult* result) {
    spdf_selection_adapter_result_reset(result);
}

SpdfSelectionAdapterStatus spdf_selection_adapter_select(spdf_document* document, int page_index,
                                                         spdf_selection_granularity granularity, float ax, float ay,
                                                         float bx, float by, SpdfSelectionAdapterResult* result) {
    spdf_text_selection core = {0};
    spdf_selection_status status;
    char error[SPDF_SELECTION_ERROR_CAPACITY] = {0};

    if (!result) return SPDF_SELECTION_ADAPTER_ERROR;
    spdf_selection_adapter_result_reset(result);
    status = spdf_select_text(document, page_index, granularity, ax, ay, bx, by, &core, error, sizeof(error));
    result->flags = core.flags;

    if (status == SPDF_SELECTION_OK) {
        if (!core.text || !core.text[0] || !core.rects || core.rect_count <= 0) {
            set_error(result, "Text selection returned incomplete data.");
        } else {
            result->status = SPDF_SELECTION_ADAPTER_SELECTED;
            result->text = core.text;
            result->rects = core.rects;
            result->rect_count = (size_t)core.rect_count;
            core.text = NULL;
            core.rects = NULL;
            core.rect_count = 0;
        }
    } else if (status == SPDF_SELECTION_NONE) {
        result->status = SPDF_SELECTION_ADAPTER_NONE;
    } else {
        set_error(result, error);
    }

    spdf_free_text_selection(&core);
    return result->status;
}

SpdfSelectionClickPolicy spdf_selection_click_policy(unsigned press_count) {
    SpdfSelectionClickPolicy policy = {SPDF_SELECTION_RANGE, 1, 0};

    if (press_count >= 3) {
        policy.granularity = SPDF_SELECTION_BLOCK;
        policy.uses_range_path = 0;
        policy.cancels_pending_link = 1;
    } else if (press_count == 2) {
        policy.granularity = SPDF_SELECTION_WORD;
        policy.uses_range_path = 0;
        policy.cancels_pending_link = 1;
    }
    return policy;
}

int spdf_selection_drag_threshold_crossed(double start_x, double start_y, double current_x, double current_y,
                                          double threshold) {
    double dx = current_x - start_x;
    double dy = current_y - start_y;

    if (threshold < 0.0) threshold = 0.0;
    if (dx < 0.0) dx = -dx;
    if (dy < 0.0) dy = -dy;
    return dx > threshold || dy > threshold;
}

void spdf_selection_gesture_reset(SpdfSelectionGestureState* state) {
    if (state) memset(state, 0, sizeof(*state));
}

SpdfSelectionClickPolicy spdf_selection_gesture_begin(SpdfSelectionGestureState* state, unsigned press_count,
                                                      int over_link) {
    SpdfSelectionClickPolicy policy = spdf_selection_click_policy(press_count);

    if (!state) return policy;
    state->press_count = press_count;
    state->dragging = 0;
    state->link_cancelled = policy.cancels_pending_link && state->pending_link;
    if (policy.cancels_pending_link) {
        state->pending_link = 0;
    } else {
        state->pending_link = over_link != 0;
    }
    return policy;
}

int spdf_selection_gesture_update_drag(SpdfSelectionGestureState* state, double start_x, double start_y,
                                       double current_x, double current_y, double threshold) {
    if (!state) return 0;
    if (!state->dragging && spdf_selection_drag_threshold_crossed(start_x, start_y, current_x, current_y, threshold)) {
        state->dragging = 1;
        if (state->pending_link) {
            state->pending_link = 0;
            state->link_cancelled = 1;
        }
    }
    return state->dragging;
}

void spdf_selection_gesture_cancel(SpdfSelectionGestureState* state) {
    if (!state) return;
    if (state->pending_link) state->link_cancelled = 1;
    state->pending_link = 0;
    state->dragging = 0;
}

int spdf_selection_gesture_take_link(SpdfSelectionGestureState* state) {
    int activate;

    if (!state) return 0;
    activate = state->pending_link && !state->dragging;
    state->pending_link = 0;
    return activate;
}
