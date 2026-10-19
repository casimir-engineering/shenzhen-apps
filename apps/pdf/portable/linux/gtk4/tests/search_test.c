/* Pure search-logic tests for the GTK4 frontend (spdf_search_internal.h).
 * glib-only; build via `make -C portable linux-gtk4-tests`.
 *
 * Covers: match-list bookkeeping (GTK3 append_find_match semantics incl. the
 * 20000 cap), nearest-match selection (mirrors mac/tests/
 * SPDFMacFindNearestTests.mm), counter formatting (GTK3
 * update_find_controls), heat-map tick layout math (Mac findScrollbarMarkers
 * + GTK3 draw_find_marker clamping), chapter attribution, query byte-cap
 * truncation and snippet line selection (Mac findContextForQuery). */

#include <glib.h>

#include "spdf_search_internal.h"

#define EPS 1e-9

static spdf_rect rect_make(float x0, float y0, float x1, float y1) {
    spdf_rect r;
    r.x0 = x0;
    r.y0 = y0;
    r.x1 = x1;
    r.y1 = y1;
    return r;
}

/* ---------------------------------------------------------------------- */

static void test_match_list_bookkeeping(void) {
    SpdfSearchMatchList list;
    const SpdfSearchMatch* m;

    spdf_search_match_list_init(&list);
    g_assert_cmpuint(spdf_search_match_list_count(&list), ==, 0);
    g_assert_null(spdf_search_match_list_get(&list, 0));

    g_assert_true(spdf_search_match_list_append(&list, 3, rect_make(1, 2, 3, 4), g_strdup("hello"), 0));
    g_assert_true(spdf_search_match_list_append(&list, 7, rect_make(5, 6, 7, 8), g_strdup("world"), -1));
    g_assert_cmpuint(spdf_search_match_list_count(&list), ==, 2);

    m = spdf_search_match_list_get(&list, 0);
    g_assert_nonnull(m);
    g_assert_cmpint(m->page, ==, 3);
    g_assert_cmpfloat_with_epsilon(m->rect.x1, 3.0, EPS);
    g_assert_cmpstr(m->snippet, ==, "hello");
    g_assert_cmpint(m->chapter_index, ==, 0);

    m = spdf_search_match_list_get(&list, 1);
    g_assert_cmpint(m->page, ==, 7);
    g_assert_cmpint(m->chapter_index, ==, -1);
    g_assert_null(spdf_search_match_list_get(&list, 2));

    spdf_search_match_list_clear(&list);
    g_assert_cmpuint(spdf_search_match_list_count(&list), ==, 0);
    /* list stays usable after clear */
    g_assert_true(spdf_search_match_list_append(&list, 0, rect_make(0, 0, 1, 1), NULL, -1));
    g_assert_cmpuint(spdf_search_match_list_count(&list), ==, 1);
    spdf_search_match_list_deinit(&list);
}

static void test_match_list_cap(void) {
    SpdfSearchMatchList list;

    spdf_search_match_list_init(&list);
    for (int i = 0; i < SPDF_SEARCH_MAX_MATCHES; ++i)
        g_assert_true(spdf_search_match_list_append(&list, i, rect_make(0, 0, 1, 1), NULL, -1));
    /* GTK3 MAX_FIND_MATCHES: the 20001st match is rejected (snippet freed). */
    g_assert_false(spdf_search_match_list_append(&list, 1, rect_make(0, 0, 1, 1), g_strdup("over"), -1));
    g_assert_cmpuint(spdf_search_match_list_count(&list), ==, SPDF_SEARCH_MAX_MATCHES);
    spdf_search_match_list_deinit(&list);
}

static void test_match_list_steal_into(void) {
    SpdfSearchMatchList dst;
    SpdfSearchMatchList src;
    const SpdfSearchMatch* m;

    spdf_search_match_list_init(&dst);
    spdf_search_match_list_init(&src);
    spdf_search_match_list_append(&dst, 0, rect_make(0, 0, 1, 1), g_strdup("a"), -1);
    spdf_search_match_list_append(&src, 5, rect_make(1, 1, 2, 2), g_strdup("b"), 2);
    spdf_search_match_list_append(&src, 6, rect_make(2, 2, 3, 3), g_strdup("c"), 2);

    spdf_search_match_list_steal_into(&dst, &src);
    g_assert_cmpuint(spdf_search_match_list_count(&dst), ==, 3);
    g_assert_cmpuint(spdf_search_match_list_count(&src), ==, 0);
    m = spdf_search_match_list_get(&dst, 2);
    g_assert_cmpint(m->page, ==, 6);
    g_assert_cmpstr(m->snippet, ==, "c");
    /* src stays usable (worker reuses its batch list) */
    g_assert_true(spdf_search_match_list_append(&src, 9, rect_make(0, 0, 1, 1), NULL, -1));
    spdf_search_match_list_deinit(&src);
    spdf_search_match_list_deinit(&dst);
}

/* ---------------------------------------------------------------------- */

static void test_counter_formatting(void) {
    char buf[64];

    /* GTK3 update_find_controls: no query -> empty (label hidden). */
    spdf_search_counter_text(buf, sizeof(buf), FALSE, -1, 0);
    g_assert_cmpstr(buf, ==, "");
    /* Query without matches -> "0 / 0". */
    spdf_search_counter_text(buf, sizeof(buf), TRUE, -1, 0);
    g_assert_cmpstr(buf, ==, "0 / 0");
    /* Current match is 1-based in the counter. */
    spdf_search_counter_text(buf, sizeof(buf), TRUE, 0, 17);
    g_assert_cmpstr(buf, ==, "1 / 17");
    spdf_search_counter_text(buf, sizeof(buf), TRUE, 16, 17);
    g_assert_cmpstr(buf, ==, "17 / 17");
    /* Matches streaming in before a selection exists: live total only. */
    spdf_search_counter_text(buf, sizeof(buf), TRUE, -1, 42);
    g_assert_cmpstr(buf, ==, "42");
}

/* ---------------------------------------------------------------------- */
/* Nearest-match selection: the cases from mac/tests/SPDFMacFindNearestTests. */

static void test_nearest_match(void) {
    g_assert_cmpint(spdf_search_nearest_match(NULL, NULL, 0, 0, 0, 0.0), ==, -1);

    {
        int pages[] = {7};
        double centers[] = {7400.0};
        /* single match wins regardless of distance */
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 1, 0, 0, 100.0), ==, 0);
    }
    {
        /* One match per page 0..9, page height 1000; viewport shows page 4:
         * the fifth match wins ("5 / 10"), not match #1. */
        int pages[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9};
        double centers[] = {50, 1050, 2050, 3050, 4450, 5050, 6050, 7050, 8050, 9050};
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 10, 4, 4, 4500.0), ==, 4);
    }
    {
        /* No match on a visible page: page distance decides. */
        int pages[] = {0, 5};
        double centers[] = {50.0, 5050.0};
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 2, 3, 4, 3600.0), ==, 1);
    }
    {
        /* Equal page distance: vertical distance from the center decides. */
        int pages[] = {2, 6};
        double centers[] = {2950.0, 6050.0};
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 2, 3, 5, 4200.0), ==, 0);
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 2, 3, 5, 4800.0), ==, 1);
    }
    {
        /* Several matches on the visible page: closest to the center wins. */
        int pages[] = {4, 4, 4};
        double centers[] = {4100.0, 4480.0, 4900.0};
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 3, 4, 4, 4500.0), ==, 1);
    }
    {
        /* Exact tie keeps document order (lowest index). */
        int pages[] = {4, 4};
        double centers[] = {4400.0, 4600.0};
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 2, 4, 4, 4500.0), ==, 0);
    }
    {
        /* Swapped visible range is normalized. */
        int pages[] = {0, 5};
        double centers[] = {50.0, 5050.0};
        g_assert_cmpint(spdf_search_nearest_match(pages, centers, 2, 4, 3, 3600.0), ==, 1);
    }
}

/* ---------------------------------------------------------------------- */

static void test_marker_fraction(void) {
    /* Mac findScrollbarMarkers: proportional, clamped to [0, 1]. */
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_fraction(500.0, 1000.0), 0.5, EPS);
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_fraction(-40.0, 1000.0), 0.0, EPS);
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_fraction(2000.0, 1000.0), 1.0, EPS);
    /* Degenerate document height never divides by zero. */
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_fraction(500.0, 0.0), 0.0, EPS);
}

static void test_marker_tick_layout(void) {
    /* GTK3 draw_find_marker: y = fraction * (lane - tick), pinned inside. */
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_y(0.0, 100.0, 3.0), 0.0, EPS);
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_y(0.5, 100.0, 3.0), 48.5, EPS);
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_y(1.0, 100.0, 3.0), 97.0, EPS);
    /* Out-of-range fractions clamp. */
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_y(1.5, 100.0, 3.0), 97.0, EPS);
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_y(-0.5, 100.0, 3.0), 0.0, EPS);
    /* A lane shorter than the tick draws at the top instead of negative y. */
    g_assert_cmpfloat_with_epsilon(spdf_search_marker_y(1.0, 2.0, 3.0), 0.0, EPS);
    /* The tick never leaves the lane, whatever the sizes. */
    for (int lane = 4; lane <= 400; lane += 7) {
        for (double f = 0.0; f <= 1.0; f += 0.13) {
            double y = spdf_search_marker_y(f, lane, SPDF_SEARCH_MARKER_TICK_H);
            g_assert_cmpfloat(y, >=, 0.0);
            g_assert_cmpfloat(y + SPDF_SEARCH_MARKER_TICK_H, <=, (double)lane);
        }
    }
}

/* ---------------------------------------------------------------------- */

static void test_chapter_attribution(void) {
    int chapters[] = {0, 4, 4, 9}; /* pre-order outline start pages */

    g_assert_cmpint(spdf_search_chapter_for_page(NULL, 0, 3), ==, -1);
    g_assert_cmpint(spdf_search_chapter_for_page(chapters, 4, 0), ==, 0);
    g_assert_cmpint(spdf_search_chapter_for_page(chapters, 4, 3), ==, 0);
    /* Two chapters starting on the same page: the later one wins (it is the
     * innermost/latest heading before the match). */
    g_assert_cmpint(spdf_search_chapter_for_page(chapters, 4, 4), ==, 2);
    g_assert_cmpint(spdf_search_chapter_for_page(chapters, 4, 8), ==, 2);
    g_assert_cmpint(spdf_search_chapter_for_page(chapters, 4, 9), ==, 3);
    g_assert_cmpint(spdf_search_chapter_for_page(chapters, 4, 100), ==, 3);
    {
        /* Match before the first chapter. */
        int late[] = {5, 8};
        g_assert_cmpint(spdf_search_chapter_for_page(late, 2, 2), ==, -1);
    }
}

/* ---------------------------------------------------------------------- */

static void test_query_truncation(void) {
    char* q;
    GString* big;

    q = spdf_search_dup_query(NULL);
    g_assert_cmpstr(q, ==, "");
    g_free(q);

    q = spdf_search_dup_query("shenzhen");
    g_assert_cmpstr(q, ==, "shenzhen");
    g_free(q);

    /* Exactly at the cap survives untouched. */
    big = g_string_new(NULL);
    for (int i = 0; i < SPDF_SEARCH_MAX_QUERY_BYTES; ++i) g_string_append_c(big, 'a');
    q = spdf_search_dup_query(big->str);
    g_assert_cmpuint(strlen(q), ==, SPDF_SEARCH_MAX_QUERY_BYTES);
    g_free(q);

    /* Over the cap truncates to the cap... */
    g_string_append_c(big, 'a');
    q = spdf_search_dup_query(big->str);
    g_assert_cmpuint(strlen(q), ==, SPDF_SEARCH_MAX_QUERY_BYTES);
    g_free(q);
    g_string_free(big, TRUE);

    /* ...but never splits a multibyte character: 3-byte CJK chars, cap not a
     * multiple of 3 => the cut backs up to the previous boundary. */
    big = g_string_new(NULL);
    while (big->len <= SPDF_SEARCH_MAX_QUERY_BYTES) g_string_append(big, "\xe6\xb7\xb1"); /* 深 */
    q = spdf_search_dup_query(big->str);
    g_assert_cmpuint(strlen(q), <=, SPDF_SEARCH_MAX_QUERY_BYTES);
    g_assert_cmpuint(strlen(q) % 3, ==, 0);
    g_assert_true(g_utf8_validate(q, -1, NULL));
    g_free(q);
    g_string_free(big, TRUE);
}

/* ---------------------------------------------------------------------- */

static void test_snippet_selection(void) {
    const char* texts[] = {"First line", "  Match line  ", "Last line"};
    spdf_rect bounds[] = {
        {10, 10, 200, 22},
        {10, 40, 200, 52},
        {10, 80, 200, 92},
    };
    char* s;

    /* Intersecting line wins (2pt slop, Mac findContextForQuery). */
    s = spdf_search_snippet(texts, bounds, 3, rect_make(50, 42, 80, 50));
    g_assert_cmpstr(s, ==, "Match line"); /* trimmed */
    g_free(s);

    /* No intersection: nearest vertical center wins. */
    s = spdf_search_snippet(texts, bounds, 3, rect_make(50, 70, 80, 74));
    g_assert_cmpstr(s, ==, "Last line"); /* centers: 46 vs 86; match center 72 */
    g_free(s);

    /* Empty lines are skipped; no usable line -> "". */
    {
        const char* empties[] = {"", NULL};
        spdf_rect eb[] = {{0, 0, 1, 1}, {0, 2, 1, 3}};
        s = spdf_search_snippet(empties, eb, 2, rect_make(0, 0, 1, 1));
        g_assert_cmpstr(s, ==, "");
        g_free(s);
    }
    s = spdf_search_snippet(NULL, NULL, 0, rect_make(0, 0, 1, 1));
    g_assert_cmpstr(s, ==, "");
    g_free(s);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/search/match-list/bookkeeping", test_match_list_bookkeeping);
    g_test_add_func("/search/match-list/cap", test_match_list_cap);
    g_test_add_func("/search/match-list/steal-into", test_match_list_steal_into);
    g_test_add_func("/search/counter", test_counter_formatting);
    g_test_add_func("/search/nearest-match", test_nearest_match);
    g_test_add_func("/search/marker-fraction", test_marker_fraction);
    g_test_add_func("/search/marker-tick-layout", test_marker_tick_layout);
    g_test_add_func("/search/chapter-attribution", test_chapter_attribution);
    g_test_add_func("/search/query-truncation", test_query_truncation);
    g_test_add_func("/search/snippet", test_snippet_selection);
    return g_test_run();
}
