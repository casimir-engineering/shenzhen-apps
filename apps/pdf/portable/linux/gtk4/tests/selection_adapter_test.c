#include "../spdf_selection_adapter.h"
#include "../spdf_selection_adapter.c"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static spdf_selection_status stub_status;
static spdf_selection_granularity stub_granularity;
static int stub_rect_count;
static int stub_free_calls;
static int stub_return_partial;

static char* duplicate_text(const char* text) {
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

    assert(document == (spdf_document*)0x1);
    assert(page_index == 7);
    assert(ax == 1.0f && ay == 2.0f && bx == 3.0f && by == 4.0f);
    stub_granularity = granularity;
    memset(out, 0, sizeof(*out));
    out->flags = SPDF_SELECTION_UNICODE_INCOMPLETE;
    if (stub_status == SPDF_SELECTION_NONE) return stub_status;
    if (stub_status == SPDF_SELECTION_ERROR) {
        out->text = duplicate_text("partial");
        out->rects = calloc(1, sizeof(*out->rects));
        out->rect_count = 1;
        snprintf(error, error_length, "fixture selection error");
        return stub_status;
    }

    out->text = duplicate_text(stub_return_partial ? "" : "selected text");
    if (!stub_return_partial) {
        out->rect_count = stub_rect_count;
        out->rects = calloc((size_t)out->rect_count, sizeof(*out->rects));
        assert(out->rects);
        for (i = 0; i < out->rect_count; ++i) {
            out->rects[i].x0 = (float)i;
            out->rects[i].x1 = (float)i + 0.5f;
            out->rects[i].y1 = 1.0f;
        }
    }
    return stub_status;
}

void spdf_free_text_selection(spdf_text_selection* selection) {
    ++stub_free_calls;
    free(selection->text);
    free(selection->rects);
    memset(selection, 0, sizeof(*selection));
}

static SpdfSelectionAdapterStatus select_fixture(SpdfSelectionAdapterResult* result,
                                                 spdf_selection_granularity granularity) {
    return spdf_selection_adapter_select((spdf_document*)0x1, 7, granularity, 1.0f, 2.0f, 3.0f, 4.0f, result);
}

static void test_dynamic_geometry_and_mapping(void) {
    SpdfSelectionAdapterResult result;

    spdf_selection_adapter_result_init(&result);
    stub_status = SPDF_SELECTION_OK;
    stub_rect_count = 513;
    stub_return_partial = 0;
    assert(select_fixture(&result, SPDF_SELECTION_RANGE) == SPDF_SELECTION_ADAPTER_SELECTED);
    assert(stub_granularity == SPDF_SELECTION_RANGE);
    assert(result.rect_count == 513);
    assert(result.rects[512].x0 == 512.0f);
    assert(strcmp(result.text, "selected text") == 0);
    assert(result.flags == SPDF_SELECTION_UNICODE_INCOMPLETE);

    assert(select_fixture(&result, SPDF_SELECTION_WORD) == SPDF_SELECTION_ADAPTER_SELECTED);
    assert(stub_granularity == SPDF_SELECTION_WORD);
    assert(result.rect_count == 513);
    assert(select_fixture(&result, SPDF_SELECTION_BLOCK) == SPDF_SELECTION_ADAPTER_SELECTED);
    assert(stub_granularity == SPDF_SELECTION_BLOCK);
    spdf_selection_adapter_result_free(&result);
    spdf_selection_adapter_result_reset(&result);
}

static void test_none_clears_previous_selection(void) {
    SpdfSelectionAdapterResult result;

    spdf_selection_adapter_result_init(&result);
    stub_status = SPDF_SELECTION_OK;
    stub_rect_count = 4;
    assert(select_fixture(&result, SPDF_SELECTION_WORD) == SPDF_SELECTION_ADAPTER_SELECTED);
    stub_status = SPDF_SELECTION_NONE;
    assert(select_fixture(&result, SPDF_SELECTION_WORD) == SPDF_SELECTION_ADAPTER_NONE);
    assert(result.text == NULL);
    assert(result.rects == NULL);
    assert(result.rect_count == 0);
    assert(result.error_message == NULL);
    spdf_selection_adapter_result_reset(&result);
}

static void test_error_is_honest_and_frees_partial_core_data(void) {
    SpdfSelectionAdapterResult result;

    spdf_selection_adapter_result_init(&result);
    stub_status = SPDF_SELECTION_ERROR;
    assert(select_fixture(&result, SPDF_SELECTION_BLOCK) == SPDF_SELECTION_ADAPTER_ERROR);
    assert(result.text == NULL);
    assert(result.rects == NULL);
    assert(result.rect_count == 0);
    assert(strcmp(result.error_message, "fixture selection error") == 0);
    spdf_selection_adapter_result_reset(&result);
}

static void test_incomplete_success_fails_closed(void) {
    SpdfSelectionAdapterResult result;

    spdf_selection_adapter_result_init(&result);
    stub_status = SPDF_SELECTION_OK;
    stub_return_partial = 1;
    assert(select_fixture(&result, SPDF_SELECTION_RANGE) == SPDF_SELECTION_ADAPTER_ERROR);
    assert(strcmp(result.error_message, "Text selection returned incomplete data.") == 0);
    stub_return_partial = 0;
    spdf_selection_adapter_result_reset(&result);
}

static void test_replacement_and_teardown_stress(void) {
    SpdfSelectionAdapterResult result;
    int i;

    spdf_selection_adapter_result_init(&result);
    stub_status = SPDF_SELECTION_OK;
    stub_rect_count = 300;
    for (i = 0; i < 2000; ++i) {
        assert(select_fixture(&result, (spdf_selection_granularity)(i % 3)) == SPDF_SELECTION_ADAPTER_SELECTED);
        if ((i % 7) == 0) spdf_selection_adapter_result_reset(&result);
    }
    spdf_selection_adapter_result_reset(&result);
}

int main(void) {
    int free_calls_before = stub_free_calls;

    test_dynamic_geometry_and_mapping();
    test_none_clears_previous_selection();
    test_error_is_honest_and_frees_partial_core_data();
    test_incomplete_success_fails_closed();
    test_replacement_and_teardown_stress();
    assert(stub_free_calls - free_calls_before == 4011);
    puts("All Linux selection-adapter tests passed");
    return 0;
}
