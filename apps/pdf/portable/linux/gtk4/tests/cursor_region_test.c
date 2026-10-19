/* Cursor-region hit-test and merge-policy tests (spdf_docview_internal.h).
 * glib-only, exercising the exact shipping logic like the other linux/gtk4
 * tests. Port provenance: SPDFMacCursorRegions.mm spdf_cursor_region_at_point
 * (+ its tests) and the empty-rect merge policy of ShenzhenPDFMac.mm
 * buildCursorRegionsForPageIfNeeded — the same arrays now also carry the
 * plain-text URL rects (spdf_page_link_rects detect_text_links=1). */

#include <glib.h>

#include "spdf_docview_internal.h"

static spdf_rect make_rect(float x0, float y0, float x1, float y1) {
    spdf_rect rect;
    rect.x0 = x0;
    rect.y0 = y0;
    rect.x1 = x1;
    rect.y1 = y1;
    return rect;
}

/* --------------------------------------------------------------------------
 * Priority: link beats text beats none (SPDFMacCursorRegionsTests parity). */

static void test_region_priority(void) {
    spdf_rect links[1] = {make_rect(10, 10, 60, 24)};
    spdf_rect text[1] = {make_rect(0, 0, 200, 40)};

    /* Inside both: the link wins even though the text line contains it. */
    g_assert_cmpint(spdf_cursor_region_at_point(links, 1, text, 1, 20.0, 15.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_LINK);
    /* Inside the text line only. */
    g_assert_cmpint(spdf_cursor_region_at_point(links, 1, text, 1, 150.0, 30.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_TEXT);
    /* Outside both. */
    g_assert_cmpint(spdf_cursor_region_at_point(links, 1, text, 1, 300.0, 300.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_NONE);
    /* Empty arrays resolve to none (a page cached after a failed build). */
    g_assert_cmpint(spdf_cursor_region_at_point(NULL, 0, NULL, 0, 20.0, 15.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_NONE);
}

/* --------------------------------------------------------------------------
 * Link padding slop: links get the 2pt text-URL slop of spdf_link_at_point,
 * text lines do not (Mac kSPDFCursorLinkHitPadding). */

static void test_link_padding_slop(void) {
    spdf_rect links[1] = {make_rect(10, 10, 60, 24)};
    spdf_rect text[1] = {make_rect(10, 10, 60, 24)};

    /* 1pt outside the raw rect: still a link thanks to the padding... */
    g_assert_cmpint(spdf_cursor_region_at_point(links, 1, NULL, 0, 61.0, 15.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_LINK);
    g_assert_cmpint(spdf_cursor_region_at_point(links, 1, NULL, 0, 9.0, 8.5, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_LINK);
    /* ...but past the slop it is not. */
    g_assert_cmpint(spdf_cursor_region_at_point(links, 1, NULL, 0, 62.5, 15.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_NONE);
    /* The same rect as a text line gets no slop. */
    g_assert_cmpint(spdf_cursor_region_at_point(NULL, 0, text, 1, 61.0, 15.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_NONE);
    g_assert_cmpint(spdf_cursor_region_at_point(NULL, 0, text, 1, 60.0, 15.0, SPDF_CURSOR_LINK_HIT_PADDING), ==,
                    SPDF_CURSOR_REGION_TEXT);
}

/* --------------------------------------------------------------------------
 * Merge policy: worker-built arrays drop empty/degenerate rects before they
 * enter the cache, so a zero-area rect (whose padded hit test could shadow
 * real regions) never participates. */

static void test_merge_policy_drops_empty_rects(void) {
    GArray* rects = g_array_new(FALSE, FALSE, sizeof(spdf_rect));
    spdf_rect good = make_rect(10, 10, 60, 24);
    spdf_rect zero_w = make_rect(10, 10, 10, 24);
    spdf_rect zero_h = make_rect(10, 10, 60, 10);
    spdf_rect inverted = make_rect(60, 24, 10, 10);

    g_assert_true(spdf_cursor_region_append_rect(rects, &good));
    g_assert_false(spdf_cursor_region_append_rect(rects, &zero_w));
    g_assert_false(spdf_cursor_region_append_rect(rects, &zero_h));
    g_assert_false(spdf_cursor_region_append_rect(rects, &inverted));
    g_assert_false(spdf_cursor_region_append_rect(rects, NULL));
    g_assert_false(spdf_cursor_region_append_rect(NULL, &good));
    g_assert_cmpuint(rects->len, ==, 1);

    /* The merged array behaves: the one real link answers, the dropped
     * degenerates cannot. */
    g_assert_cmpint(spdf_cursor_region_at_point((const spdf_rect*)rects->data, rects->len, NULL, 0, 20.0, 15.0,
                                                SPDF_CURSOR_LINK_HIT_PADDING),
                    ==, SPDF_CURSOR_REGION_LINK);
    g_array_free(rects, TRUE);
}

/* Annotation links and detected plain-text URLs merge into ONE link array
 * (the core appends text-URL rects after the annotations in
 * spdf_page_link_rects); both must answer as links. */
static void test_merge_annotation_and_text_urls(void) {
    GArray* links = g_array_new(FALSE, FALSE, sizeof(spdf_rect));
    spdf_rect annotation = make_rect(10, 10, 60, 24);
    spdf_rect text_url = make_rect(100, 200, 260, 214);

    g_assert_true(spdf_cursor_region_append_rect(links, &annotation));
    g_assert_true(spdf_cursor_region_append_rect(links, &text_url));
    g_assert_cmpuint(links->len, ==, 2);
    g_assert_cmpint(spdf_cursor_region_at_point((const spdf_rect*)links->data, links->len, NULL, 0, 20.0, 15.0,
                                                SPDF_CURSOR_LINK_HIT_PADDING),
                    ==, SPDF_CURSOR_REGION_LINK);
    g_assert_cmpint(spdf_cursor_region_at_point((const spdf_rect*)links->data, links->len, NULL, 0, 180.0, 207.0,
                                                SPDF_CURSOR_LINK_HIT_PADDING),
                    ==, SPDF_CURSOR_REGION_LINK);
    g_array_free(links, TRUE);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/cursor-region/priority", test_region_priority);
    g_test_add_func("/cursor-region/link-padding-slop", test_link_padding_slop);
    g_test_add_func("/cursor-region/merge-drops-empty", test_merge_policy_drops_empty_rects);
    g_test_add_func("/cursor-region/merge-annotation-and-text-urls", test_merge_annotation_and_text_urls);
    return g_test_run();
}
