#import <Cocoa/Cocoa.h>

#import "../SPDFMacSelectionAdapter.h"

#include <stdlib.h>
#include <string.h>

static spdf_selection_status gCoreStatus;
static spdf_selection_granularity gCoreGranularity;
static BOOL gCoreResultFreed;
static BOOL gReturnInvalidUTF8;
static int gFailureCount;

spdf_selection_status spdf_select_text(spdf_document* document, int pageIndex,
                                       spdf_selection_granularity granularity, float ax, float ay, float bx,
                                       float by, spdf_text_selection* out, char* error, size_t errorLength) {
    (void)document;
    (void)pageIndex;
    (void)ax;
    (void)ay;
    (void)bx;
    (void)by;
    gCoreGranularity = granularity;
    memset(out, 0, sizeof(*out));
    if (gCoreStatus == SPDF_SELECTION_ERROR) {
        snprintf(error, errorLength, "selection failed");
        return gCoreStatus;
    }
    if (gCoreStatus == SPDF_SELECTION_NONE) return gCoreStatus;

    const char validText[] = "h\xC3\xA9llo";
    const char invalidText[] = {'x', (char)0xFF, '\0'};
    const char* text = gReturnInvalidUTF8 ? invalidText : validText;
    out->text = strdup(text);
    out->rect_count = 2;
    out->rects = (spdf_rect*)calloc((size_t)out->rect_count, sizeof(spdf_rect));
    out->rects[0] = (spdf_rect){1, 2, 11, 12};
    out->rects[1] = (spdf_rect){20, 30, 44, 55};
    out->flags = SPDF_SELECTION_UNICODE_INCOMPLETE;
    return gCoreStatus;
}

void spdf_free_text_selection(spdf_text_selection* selection) {
    gCoreResultFreed = YES;
    free(selection->text);
    free(selection->rects);
    memset(selection, 0, sizeof(*selection));
}

static void expect_integer(NSString* label, NSInteger expected, NSInteger actual) {
    if (expected == actual) return;
    fprintf(stderr, "FAIL %s: expected %ld, got %ld\n", label.UTF8String, (long)expected, (long)actual);
    ++gFailureCount;
}

static void expect_bool(NSString* label, BOOL expected, BOOL actual) {
    if (expected == actual) return;
    fprintf(stderr, "FAIL %s: expected %s, got %s\n", label.UTF8String, expected ? "YES" : "NO",
            actual ? "YES" : "NO");
    ++gFailureCount;
}

static SPDFMacSelectionResult* select_with_granularity(SPDFMacSelectionGranularity granularity) {
    gCoreResultFreed = NO;
    return spdf_mac_select_text((spdf_document*)0x1, 3, granularity, NSMakePoint(4, 5), NSMakePoint(6, 7));
}

static void test_selected_result_and_ownership(void) {
    gCoreStatus = SPDF_SELECTION_OK;
    gReturnInvalidUTF8 = NO;
    SPDFMacSelectionResult* result = select_with_granularity(SPDFMacSelectionGranularityWord);
    expect_integer(@"word maps to core word", SPDF_SELECTION_WORD, gCoreGranularity);
    expect_integer(@"selected status", SPDFMacSelectionStatusSelected, result.status);
    expect_bool(@"selected result is non-empty", YES, result.hasSelection);
    expect_bool(@"UTF-8 converted", YES, [result.text isEqualToString:@"héllo"]);
    expect_integer(@"all rectangles converted", 2, (NSInteger)result.rects.count);
    expect_bool(@"first rectangle converted", YES,
                NSEqualRects(result.rects[0].rectValue, NSMakeRect(1, 2, 10, 10)));
    expect_bool(@"second rectangle converted", YES,
                NSEqualRects(result.rects[1].rectValue, NSMakeRect(20, 30, 24, 25)));
    expect_integer(@"selection flags preserved", SPDF_SELECTION_UNICODE_INCOMPLETE, result.flags);
    expect_bool(@"core-owned buffers freed", YES, gCoreResultFreed);
}

static void test_granularity_mapping(void) {
    gCoreStatus = SPDF_SELECTION_NONE;
    (void)select_with_granularity(SPDFMacSelectionGranularityRange);
    expect_integer(@"range maps to core range", SPDF_SELECTION_RANGE, gCoreGranularity);
    (void)select_with_granularity(SPDFMacSelectionGranularityBlock);
    expect_integer(@"block maps to core block", SPDF_SELECTION_BLOCK, gCoreGranularity);
}

static void test_none_and_error(void) {
    gCoreStatus = SPDF_SELECTION_NONE;
    SPDFMacSelectionResult* none = select_with_granularity(SPDFMacSelectionGranularityWord);
    expect_integer(@"NONE preserved", SPDFMacSelectionStatusNone, none.status);
    expect_bool(@"NONE has no selection", NO, none.hasSelection);
    expect_integer(@"NONE has no rectangles", 0, (NSInteger)none.rects.count);
    expect_bool(@"NONE ownership cleanup runs", YES, gCoreResultFreed);

    gCoreStatus = SPDF_SELECTION_ERROR;
    SPDFMacSelectionResult* error = select_with_granularity(SPDFMacSelectionGranularityBlock);
    expect_integer(@"error preserved", SPDFMacSelectionStatusError, error.status);
    expect_bool(@"error message converted", YES, [error.errorMessage isEqualToString:@"selection failed"]);
    expect_bool(@"error ownership cleanup runs", YES, gCoreResultFreed);
}

static void test_invalid_utf8_fails_closed(void) {
    gCoreStatus = SPDF_SELECTION_OK;
    gReturnInvalidUTF8 = YES;
    SPDFMacSelectionResult* result = select_with_granularity(SPDFMacSelectionGranularityWord);
    expect_integer(@"invalid UTF-8 is adapter error", SPDFMacSelectionStatusError, result.status);
    expect_bool(@"invalid UTF-8 has no selection", NO, result.hasSelection);
    expect_bool(@"invalid UTF-8 buffers freed", YES, gCoreResultFreed);
    gReturnInvalidUTF8 = NO;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        test_selected_result_and_ownership();
        test_granularity_mapping();
        test_none_and_error();
        test_invalid_utf8_fails_closed();
    }
    if (gFailureCount > 0) {
        fprintf(stderr, "%d macOS selection-adapter test(s) failed\n", gFailureCount);
        return 1;
    }
    printf("All macOS selection-adapter tests passed\n");
    return 0;
}
