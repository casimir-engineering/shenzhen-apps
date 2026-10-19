#include "../spdf_selection_adapter.c"
#include "../spdf_docview_selection.c"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static spdf_selection_granularity selected_granularity;
static int selected_rect_count = 3;
static int link_activations;
static int selected_page;

static char* copy_text(const char* text) {
    size_t size = strlen(text) + 1;
    char* copy = malloc(size);
    assert(copy);
    memcpy(copy, text, size);
    return copy;
}

spdf_selection_status spdf_select_text(spdf_document* document, int page_index, spdf_selection_granularity granularity,
                                       float ax, float ay, float bx, float by, spdf_text_selection* out, char* error,
                                       size_t error_length) {
    int i;
    (void)ax;
    (void)ay;
    (void)bx;
    (void)by;
    (void)error;
    (void)error_length;
    assert(document == (spdf_document*)0x1);
    selected_granularity = granularity;
    selected_page = page_index;
    memset(out, 0, sizeof(*out));
    out->text = copy_text(granularity == SPDF_SELECTION_WORD    ? "word"
                          : granularity == SPDF_SELECTION_BLOCK ? "paragraph"
                                                                : "range");
    out->rect_count = selected_rect_count;
    out->rects = calloc((size_t)out->rect_count, sizeof(*out->rects));
    assert(out->rects);
    for (i = 0; i < out->rect_count; ++i) {
        out->rects[i].x0 = (float)i;
        out->rects[i].x1 = (float)i + 0.5f;
        out->rects[i].y1 = 1.0f;
    }
    return SPDF_SELECTION_OK;
}

void spdf_free_text_selection(spdf_text_selection* selection) {
    free(selection->text);
    free(selection->rects);
    memset(selection, 0, sizeof(*selection));
}

static gboolean activate_link(gpointer user_data, int page, double page_x, double page_y) {
    int* expected_page = user_data;
    assert(page == *expected_page);
    assert(page_x == 4.0);
    assert(page_y == 5.0);
    ++link_activations;
    return TRUE;
}

static void spin_main_context(guint milliseconds) {
    gint64 until = g_get_monotonic_time() + (gint64)milliseconds * 1000;
    while (g_get_monotonic_time() < until) {
        while (g_main_context_iteration(NULL, FALSE)) {
        }
        g_usleep(1000);
    }
    while (g_main_context_iteration(NULL, FALSE)) {
    }
}

static void test_dynamic_drag_selection_and_bounded_copy(void) {
    SpdfDocViewSelection selection;
    spdf_rect copied[7];
    int page = -1;

    spdf_docview_selection_init(&selection);
    selected_rect_count = 513;
    assert(!spdf_docview_selection_press(&selection, (spdf_document*)0x1, 8, 10, 20, 1, 2, 1));
    assert(!spdf_docview_selection_drag(&selection, (spdf_document*)0x1, 12, 22, 3, 4, 4));
    assert(spdf_docview_selection_drag(&selection, (spdf_document*)0x1, 16, 20, 7, 2, 4));
    assert(selected_granularity == SPDF_SELECTION_RANGE);
    assert(selected_page == 8);
    assert(selection.result.rect_count == 513);
    assert(spdf_docview_selection_copy_rects(&selection, &page, copied, 7) == 7);
    assert(page == 8);
    assert(copied[6].x0 == 6.0f);
    assert(spdf_docview_selection_copy_rects(&selection, &page, copied, 0) == 0);
    spdf_docview_selection_release(&selection, 5, activate_link, &page);
    spin_main_context(10);
    assert(link_activations == 0);
    spdf_docview_selection_reset(&selection);
}

static void test_multi_click_selects_and_cancels_link(void) {
    SpdfDocViewSelection selection;
    int page = 3;

    spdf_docview_selection_init(&selection);
    selected_rect_count = 3;
    assert(!spdf_docview_selection_press(&selection, (spdf_document*)0x1, page, 10, 20, 4, 5, 1));
    spdf_docview_selection_release(&selection, 30, activate_link, &page);
    assert(link_activations == 0);
    assert(spdf_docview_selection_press(&selection, (spdf_document*)0x1, page, 10, 20, 4, 5, 2));
    assert(selected_granularity == SPDF_SELECTION_WORD);
    assert(strcmp(selection.result.text, "word") == 0);
    spdf_docview_selection_release(&selection, 30, activate_link, &page);
    spin_main_context(45);
    assert(link_activations == 0);

    assert(spdf_docview_selection_press(&selection, (spdf_document*)0x1, page, 10, 20, 4, 5, 3));
    assert(selected_granularity == SPDF_SELECTION_BLOCK);
    assert(strcmp(selection.result.text, "paragraph") == 0);
    spdf_docview_selection_reset(&selection);
}

static void test_deferred_link_and_lifecycle_cancellation(void) {
    SpdfDocViewSelection selection;
    int page = 6;

    spdf_docview_selection_init(&selection);
    assert(!spdf_docview_selection_press(&selection, (spdf_document*)0x1, page, 1, 2, 4, 5, 1));
    spdf_docview_selection_release(&selection, 8, activate_link, &page);
    assert(link_activations == 0);
    spin_main_context(15);
    assert(link_activations == 1);

    assert(!spdf_docview_selection_press(&selection, (spdf_document*)0x1, page, 1, 2, 4, 5, 1));
    spdf_docview_selection_release(&selection, 8, activate_link, &page);
    spdf_docview_selection_reset(&selection);
    spin_main_context(15);
    assert(link_activations == 1);
    assert(selection.delayed_link_id == 0);
    assert(selection.result.text == NULL);
    assert(selection.page == -1);
}

static void test_deadline_uses_initial_press(void) {
    SpdfDocViewSelection selection;
    const gint64 pressed_us = 1000000;
    int page = 6;
    int before = link_activations;

    assert(spdf_docview_selection_remaining_delay_ms(pressed_us, 250, pressed_us + 100000) == 150);
    assert(spdf_docview_selection_remaining_delay_ms(pressed_us, 250, pressed_us + 249001) == 1);
    assert(spdf_docview_selection_remaining_delay_ms(pressed_us, 250, pressed_us + 250000) == 0);

    spdf_docview_selection_init(&selection);
    assert(!spdf_docview_selection_press_at(&selection, (spdf_document*)0x1, page, 1, 2, 4, 5, 1, pressed_us));
    spdf_docview_selection_release_at(&selection, 250, activate_link, &page, pressed_us + 100000);
    assert(selection.delayed_link_id != 0);
    assert(link_activations == before);
    spdf_docview_selection_cancel(&selection);

    assert(!spdf_docview_selection_press_at(&selection, (spdf_document*)0x1, page, 1, 2, 4, 5, 1, pressed_us));
    spdf_docview_selection_release_at(&selection, 250, activate_link, &page, pressed_us + 400000);
    assert(selection.delayed_link_id == 0);
    assert(link_activations == before + 1);
    spdf_docview_selection_reset(&selection);
}

static void test_cancel_and_stopped_preserve_completed_selection(void) {
    SpdfDocViewSelection selection;
    const gint64 pressed_us = 2000000;
    int page = 3;
    int before = link_activations;

    spdf_docview_selection_init(&selection);
    assert(!spdf_docview_selection_press_at(&selection, (spdf_document*)0x1, page, 10, 20, 4, 5, 1, pressed_us));
    spdf_docview_selection_release_at(&selection, 1000, activate_link, &page, pressed_us + 10);
    assert(selection.delayed_link_id != 0);
    spdf_docview_selection_click_stopped(&selection);
    assert(selection.delayed_link_id != 0); /* normal click-series expiry */
    spdf_docview_selection_cancel(&selection);
    assert(selection.delayed_link_id == 0);
    assert(!selection.active);
    assert(!selection.gesture.dragging);
    assert(link_activations == before);

    assert(spdf_docview_selection_press_at(&selection, (spdf_document*)0x1, page, 10, 20, 4, 5, 2, pressed_us));
    assert(strcmp(selection.result.text, "word") == 0);
    spdf_docview_selection_click_stopped(&selection);
    assert(!selection.active);
    assert(spdf_docview_selection_has_text(&selection));
    assert(strcmp(selection.result.text, "word") == 0);
    spdf_docview_selection_cancel(&selection);
    assert(spdf_docview_selection_has_text(&selection));

    assert(spdf_docview_selection_press_at(&selection, (spdf_document*)0x1, page, 10, 20, 4, 5, 1, pressed_us));
    assert(spdf_docview_selection_drag(&selection, (spdf_document*)0x1, 20, 20, 8, 5, 4));
    spdf_docview_selection_click_stopped(&selection);
    assert(selection.active); /* click distance stopping must not kill a valid drag */
    spdf_docview_selection_cancel(&selection);
    assert(!selection.active);
    assert(!selection.gesture.dragging);
    assert(spdf_docview_selection_has_text(&selection));
    spdf_docview_selection_reset(&selection);
}

int main(void) {
    test_dynamic_drag_selection_and_bounded_copy();
    test_multi_click_selects_and_cancels_link();
    test_deferred_link_and_lifecycle_cancellation();
    test_deadline_uses_initial_press();
    test_cancel_and_stopped_preserve_completed_selection();
    puts("All Linux document-view selection tests passed");
    return 0;
}
