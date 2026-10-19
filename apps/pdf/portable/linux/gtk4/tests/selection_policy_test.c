#include "../spdf_selection_adapter.h"
#include "../spdf_selection_adapter.c"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* The policy binary links the complete adapter translation unit. These core
 * stubs make an accidental selection call fail loudly while keeping this test
 * independent of MuPDF. */
spdf_selection_status spdf_select_text(spdf_document* document, int page_index, spdf_selection_granularity granularity,
                                       float ax, float ay, float bx, float by, spdf_text_selection* out, char* error,
                                       size_t error_length) {
    (void)document;
    (void)page_index;
    (void)granularity;
    (void)ax;
    (void)ay;
    (void)bx;
    (void)by;
    if (out) memset(out, 0, sizeof(*out));
    if (error && error_length) error[0] = '\0';
    assert(!"policy test unexpectedly called spdf_select_text");
    return SPDF_SELECTION_ERROR;
}

void spdf_free_text_selection(spdf_text_selection* selection) {
    (void)selection;
    assert(!"policy test unexpectedly called spdf_free_text_selection");
}

static void test_click_mapping(void) {
    SpdfSelectionClickPolicy policy;

    policy = spdf_selection_click_policy(0);
    assert(policy.granularity == SPDF_SELECTION_RANGE);
    assert(policy.uses_range_path);
    assert(!policy.cancels_pending_link);
    policy = spdf_selection_click_policy(1);
    assert(policy.granularity == SPDF_SELECTION_RANGE);
    assert(policy.uses_range_path);
    policy = spdf_selection_click_policy(2);
    assert(policy.granularity == SPDF_SELECTION_WORD);
    assert(!policy.uses_range_path);
    assert(policy.cancels_pending_link);
    policy = spdf_selection_click_policy(3);
    assert(policy.granularity == SPDF_SELECTION_BLOCK);
    assert(policy.cancels_pending_link);
    assert(spdf_selection_click_policy(99).granularity == SPDF_SELECTION_BLOCK);
}

static void test_drag_threshold(void) {
    assert(!spdf_selection_drag_threshold_crossed(10, 10, 14, 14, 4));
    assert(spdf_selection_drag_threshold_crossed(10, 10, 14.01, 10, 4));
    assert(spdf_selection_drag_threshold_crossed(10, 10, 10, 5.99, 4));
    assert(!spdf_selection_drag_threshold_crossed(10, 10, 10, 10, -1));
    assert(spdf_selection_drag_threshold_crossed(10, 10, 10.01, 10, -1));
}

static void test_single_link_and_drag(void) {
    SpdfSelectionGestureState state;
    SpdfSelectionClickPolicy policy;

    spdf_selection_gesture_reset(&state);
    policy = spdf_selection_gesture_begin(&state, 1, 1);
    assert(policy.uses_range_path);
    assert(state.pending_link);
    assert(!spdf_selection_gesture_update_drag(&state, 0, 0, 3, 3, 4));
    assert(state.pending_link);
    assert(spdf_selection_gesture_update_drag(&state, 0, 0, 5, 1, 4));
    assert(state.dragging);
    assert(state.link_cancelled);
    assert(!state.pending_link);
    assert(!spdf_selection_gesture_take_link(&state));

    spdf_selection_gesture_reset(&state);
    (void)spdf_selection_gesture_begin(&state, 1, 1);
    assert(spdf_selection_gesture_take_link(&state));
    assert(!spdf_selection_gesture_take_link(&state));
}

static void test_multi_click_cancels_pending_link(void) {
    SpdfSelectionGestureState state;
    SpdfSelectionClickPolicy policy;

    spdf_selection_gesture_reset(&state);
    (void)spdf_selection_gesture_begin(&state, 1, 1);
    policy = spdf_selection_gesture_begin(&state, 2, 1);
    assert(policy.granularity == SPDF_SELECTION_WORD);
    assert(state.link_cancelled);
    assert(!state.pending_link);
    assert(!spdf_selection_gesture_take_link(&state));

    (void)spdf_selection_gesture_begin(&state, 1, 1);
    policy = spdf_selection_gesture_begin(&state, 3, 1);
    assert(policy.granularity == SPDF_SELECTION_BLOCK);
    assert(state.link_cancelled);
    assert(!state.pending_link);
}

static void test_cancel_and_replacement_reset(void) {
    SpdfSelectionGestureState state;

    spdf_selection_gesture_reset(&state);
    (void)spdf_selection_gesture_begin(&state, 1, 1);
    spdf_selection_gesture_cancel(&state);
    assert(state.link_cancelled);
    assert(!state.pending_link);
    assert(!state.dragging);
    spdf_selection_gesture_reset(&state);
    assert(state.press_count == 0);
    assert(!state.link_cancelled);
}

static void* policy_stress_thread(void* context) {
    unsigned seed = *(unsigned*)context;
    unsigned i;

    for (i = 0; i < 100000; ++i) {
        SpdfSelectionGestureState state;
        unsigned count = ((i + seed) % 5) + 1;
        SpdfSelectionClickPolicy policy;

        spdf_selection_gesture_reset(&state);
        policy = spdf_selection_gesture_begin(&state, count, (i & 1) != 0);
        assert(policy.granularity == spdf_selection_click_policy(count).granularity);
        (void)spdf_selection_gesture_update_drag(&state, 0, 0, (double)(i % 9), (double)(i % 7), 4);
        spdf_selection_gesture_cancel(&state);
    }
    return NULL;
}

static void test_independent_thread_safety(void) {
    pthread_t threads[8];
    unsigned seeds[8];
    int i;

    for (i = 0; i < 8; ++i) {
        seeds[i] = (unsigned)i;
        assert(pthread_create(&threads[i], NULL, policy_stress_thread, &seeds[i]) == 0);
    }
    for (i = 0; i < 8; ++i) assert(pthread_join(threads[i], NULL) == 0);
}

int main(void) {
    test_click_mapping();
    test_drag_threshold();
    test_single_link_and_drag();
    test_multi_click_cancels_pending_link();
    test_cancel_and_replacement_reset();
    test_independent_thread_safety();
    puts("All Linux selection-policy tests passed");
    return 0;
}
