/* link_test.c — link hit-testing, the cursor regions above it, and what an
 * internal link actually resolves to.
 *
 * WHY A REAL DOCUMENT. The pure half of spdf_win_links.h is a transcription of
 * the GTK4 cursor-region model and is compared against the original,
 * exhaustively, by portable/win/tests/selection-differential-native.cmd. What
 * that cannot check is the part with no original: which rects the core hands
 * back for a real page's annotations, whether hover and click agree about where
 * a link is, and which way up the destination point of a /GoTo is. So this
 * opens portable/win/tests/fixtures/selection.pdf, whose page 1 carries exactly
 * one internal /GoTo link to page 3 and one external /URI link -- see
 * make_selection_fixture.py.
 *
 * NO COORDINATE IS HARD-CODED. The rects come from spdf_page_link_rects and
 * every hit test is derived from them, so regenerating the fixture cannot
 * silently invalidate an expectation here. The one number this file DOES pin is
 * the ORIENTATION of the internal target's y, which is stated nowhere in the
 * core's header and which a later "scroll to the exact destination point"
 * refinement would otherwise have to rediscover.
 */
/* spdf-test-sources: portable/win/src/spdf_win_links.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/selection.pdf */
/* spdf-test-needs: mupdf */
#include "spdf_win_links.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h> /* Sleep, for polling the text-URL worker */

#include <math.h>
#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        long long va = (long long)(a);                                                                                 \
        long long vb = (long long)(b);                                                                                 \
        ++g_checks;                                                                                                    \
        if (va != vb) {                                                                                                \
            printf("FAIL %s:%d: %s (%lld) != %s (%lld)\n", __FILE__, __LINE__, #a, va, #b, vb);                        \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- the pure model ------------------------------------------------------- */

static void test_pure_regions(void) {
    spdf_rect links[2];
    spdf_rect text[2];
    spdf_rect degenerate;
    int count = 0;

    links[0].x0 = 10.0f;
    links[0].y0 = 10.0f;
    links[0].x1 = 50.0f;
    links[0].y1 = 30.0f;
    /* Overlaps the link: LINK MUST WIN, which is the precedence the mac model
     * states and the reason a hand never turns into an I-beam over a link. */
    text[0] = links[0];
    text[1].x0 = 60.0f;
    text[1].y0 = 10.0f;
    text[1].x1 = 90.0f;
    text[1].y1 = 30.0f;

    CHECK_EQI(spdf_win_cursor_region_at_point(links, 1, text, 2, 20.0, 20.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING),
              SPDF_WIN_CURSOR_REGION_LINK);
    CHECK_EQI(spdf_win_cursor_region_at_point(links, 1, text, 2, 70.0, 20.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING),
              SPDF_WIN_CURSOR_REGION_TEXT);
    CHECK_EQI(spdf_win_cursor_region_at_point(links, 1, text, 2, 200.0, 200.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING),
              SPDF_WIN_CURSOR_REGION_NONE);

    /* THE SLOP IS FOR LINKS ONLY. 1 pt outside the link is still a link;
     * 1 pt outside a text line is not text. */
    CHECK_EQI(spdf_win_cursor_region_at_point(links, 1, NULL, 0, 51.0, 20.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING),
              SPDF_WIN_CURSOR_REGION_LINK);
    CHECK_EQI(spdf_win_cursor_region_at_point(links, 1, NULL, 0, 53.0, 20.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING),
              SPDF_WIN_CURSOR_REGION_NONE);
    CHECK_EQI(spdf_win_cursor_region_at_point(NULL, 0, &text[1], 1, 91.0, 20.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING),
              SPDF_WIN_CURSOR_REGION_NONE);
    /* Exactly on the edge is inside, both for links and for text. */
    CHECK_EQI(spdf_win_cursor_region_at_point(NULL, 0, &text[1], 1, 90.0, 30.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING),
              SPDF_WIN_CURSOR_REGION_TEXT);

    /* A DEGENERATE RECT NEVER ENTERS THE CACHE, so it can never own a hit
     * test -- mac's buildCursorRegionsForPageIfNeeded skips NSIsEmptyRect. */
    degenerate.x0 = degenerate.x1 = 5.0f;
    degenerate.y0 = 0.0f;
    degenerate.y1 = 10.0f;
    CHECK_EQI(spdf_win_cursor_rect_empty(&degenerate), 1);
    CHECK_EQI(spdf_win_cursor_region_append_rect(links, &count, 2, &degenerate), 0);
    CHECK_EQI(count, 0);
    CHECK_EQI(spdf_win_cursor_region_append_rect(links, &count, 2, &text[1]), 1);
    CHECK_EQI(count, 1);
    /* Full is full. */
    CHECK_EQI(spdf_win_cursor_region_append_rect(links, &count, 1, &text[1]), 0);
    CHECK_EQI(spdf_win_cursor_region_append_rect(NULL, &count, 2, &text[1]), 0);
    CHECK_EQI(spdf_win_cursor_rect_empty(NULL), 1);
}

/* --- the real document ---------------------------------------------------- */

static spdf_rect center_of(spdf_rect r, float* x, float* y) {
    *x = (r.x0 + r.x1) * 0.5f;
    *y = (r.y0 + r.y1) * 0.5f;
    return r;
}

static void test_link_rects(spdf_document* doc) {
    spdf_rect rects[16];
    char err[256];
    int count, i;
    int internal = 0, external = 0;

    /* detect_text_links = 0: the ANNOTATIONS, which is what hover uses. */
    count = spdf_page_link_rects(doc, 0, 0, rects, 16, err, sizeof(err));
    printf("      page 1 link annotations: %d (%s)\n", count, err);
    CHECK_EQI(count, 2);
    /* Page 2 has none, and asking is not an error. */
    CHECK_EQI(spdf_page_link_rects(doc, 1, 0, rects + 8, 8, err, sizeof(err)), 0);

    for (i = 0; i < count && i < 2; ++i) {
        spdf_link_target target;
        float x, y;
        center_of(rects[i], &x, &y);
        CHECK(!spdf_win_cursor_rect_empty(&rects[i]));
        CHECK_EQI(spdf_win_links_target_at(doc, 0, x, y, &target), 1);
        if (target.kind == SPDF_LINK_INTERNAL) {
            ++internal;
            /* The /GoTo destination in the fixture is page 3, written as
             * [<page 3> /XYZ 60 700 0]. */
            CHECK_EQI(target.page_index, 2);
            /* WHICH WAY UP. The destination was authored at PDF user-space
             * y = 700 on a 792 pt page. MEASURED: the core hands back
             * y = 92 = 792 - 700, so fz_resolve_link's point arrives already
             * in PAGE space -- y DOWN, the same space every rect in this port
             * uses, and NOT the bottom-left user space spdf_outline_item.dest_y
             * documents for outline entries. The two are different, which is
             * exactly why this is pinned: a later "scroll to the exact
             * destination point" refinement must not reuse the outline code's
             * flip. */
            printf("      internal target: page %d, point (%.1f, %.1f) on a 792 pt page\n", target.page_index,
                   target.x, target.y);
            CHECK(fabs((double)target.x - 60.0) < 1.0);
            CHECK(fabs((double)target.y - 92.0) < 1.0);
        } else if (target.kind == SPDF_LINK_URI) {
            ++external;
            CHECK(target.uri != NULL);
            printf("      external target: %s\n", target.uri ? target.uri : "(null)");
            CHECK(target.uri && strstr(target.uri, "example.invalid") != NULL);
        }
        spdf_free_link_target(&target);
    }
    CHECK_EQI(internal, 1);
    CHECK_EQI(external, 1);

    /* Off every link: no target, and NOT an error. */
    {
        spdf_link_target target;
        CHECK_EQI(spdf_win_links_target_at(doc, 0, 5.0f, 5.0f, &target), 0);
        CHECK_EQI(target.kind, SPDF_LINK_NONE);
        spdf_free_link_target(&target);
        /* A page that does not exist IS an error, distinguishable from "none". */
        CHECK_EQI(spdf_win_links_target_at(doc, 99, 5.0f, 5.0f, &target), -1);
        CHECK_EQI(spdf_win_links_target_at(NULL, 0, 5.0f, 5.0f, &target), -1);
        CHECK_EQI(spdf_win_links_target_at(doc, 0, 5.0f, 5.0f, NULL), -1);
    }
}

static void test_cache(spdf_document* doc) {
    spdf_win_links* cache = spdf_win_links_new();
    spdf_rect rects[16];
    char err[256];
    float x, y;
    int count;

    CHECK(cache != NULL);
    if (!cache) return;

    count = spdf_page_link_rects(doc, 0, 0, rects, 16, err, sizeof(err));
    CHECK(count >= 1);
    if (count < 1) {
        spdf_win_links_free(cache);
        return;
    }
    center_of(rects[0], &x, &y);

    /* HOVER AND CLICK MUST AGREE. The cheap cached hit test and the expensive
     * spdf_link_at_point are asked about the same point, and a hand that
     * appears over something a click does not follow is the defect the shared
     * 2 pt slop exists to prevent. */
    CHECK_EQI(spdf_win_links_hit(cache, doc, 0, x, y), 1);
    CHECK_EQI(spdf_win_links_region_at(cache, doc, 0, 0, x, y), SPDF_WIN_CURSOR_REGION_LINK);
    {
        spdf_link_target target;
        CHECK_EQI(spdf_win_links_target_at(doc, 0, x, y, &target), 1);
        spdf_free_link_target(&target);
    }

    /* Off the links: no hand. Without text regions there is no I-beam either,
     * which is the documented cost of keeping hover free of a structured-text
     * pass. */
    CHECK_EQI(spdf_win_links_hit(cache, doc, 0, 5.0f, 5.0f), 0);
    CHECK_EQI(spdf_win_links_region_at(cache, doc, 0, 0, 500.0f, 700.0f), SPDF_WIN_CURSOR_REGION_NONE);

    /* WITH text regions, the same point over a line of body text is an I-beam.
     * This is the one call that builds the page's structured text. */
    {
        spdf_rect line;
        int found = spdf_search_page_rects(doc, 0, "Selection fixture alpha", &line, 1, err, sizeof(err));
        CHECK_EQI(found, 1);
        if (found == 1) {
            center_of(line, &x, &y);
            CHECK_EQI(spdf_win_links_region_at(cache, doc, 0, 1, x, y), SPDF_WIN_CURSOR_REGION_TEXT);
            /* Blank paper is still nothing, even with text regions built. */
            CHECK_EQI(spdf_win_links_region_at(cache, doc, 0, 1, 560.0f, 760.0f), SPDF_WIN_CURSOR_REGION_NONE);
        }
    }

    /* Switching pages rebuilds: page 2 has no links, so the page-1 rects must
     * not answer for it. */
    CHECK_EQI(spdf_win_links_hit(cache, doc, 1, x, y), 0);
    /* And switching back rebuilds again rather than serving page 2's emptiness. */
    center_of(rects[0], &x, &y);
    CHECK_EQI(spdf_win_links_hit(cache, doc, 0, x, y), 1);

    /* Invalidation drops everything without breaking the next query. */
    spdf_win_links_invalidate(cache);
    CHECK_EQI(spdf_win_links_hit(cache, doc, 0, x, y), 1);

    /* NULLs everywhere. */
    CHECK_EQI(spdf_win_links_hit(NULL, doc, 0, x, y), 0);
    CHECK_EQI(spdf_win_links_hit(cache, NULL, 0, x, y), 0);
    CHECK_EQI(spdf_win_links_region_at(NULL, doc, 0, 1, x, y), SPDF_WIN_CURSOR_REGION_NONE);
    CHECK_EQI(spdf_win_links_ensure_page(cache, doc, -1, 0), 0);
    spdf_win_links_invalidate(NULL);
    spdf_win_links_free(NULL);
    spdf_win_links_free(cache);
}

/* THE TEXT-URL WORKER. With a source path the cache runs the structured-text
 * pass on its own thread and merges the full link set on a later hover; without
 * one it never does. The fixture's only link is an annotation, so "full set"
 * and "annotation set" have the same count here -- what is being checked is
 * that the thread runs, delivers, is adopted on the UI side, survives an
 * invalidation and is joined by free. The hand over a printed URL is the same
 * merge with a longer list. */
static void test_text_url_worker(spdf_document* doc, const char* path) {
    spdf_win_links* cache = spdf_win_links_new();
    spdf_rect rects[16];
    char err[256];
    int full, spins, x_ok;
    float x, y;

    CHECK(cache != NULL);
    if (!cache) return;
    full = spdf_page_link_rects(doc, 0, 1, rects, 16, err, sizeof(err));
    CHECK(full >= 1);
    center_of(rects[0], &x, &y);

    /* No source: annotation links only, and the worker never reports. */
    CHECK_EQI(spdf_win_links_ensure_page(cache, doc, 0, 0), 1);
    CHECK_EQI(spdf_win_links_text_urls_ready(cache), 0);
    spdf_win_links_free(cache);

    cache = spdf_win_links_new();
    CHECK(cache != NULL);
    if (!cache) return;
    spdf_win_links_set_source(cache, path);
    CHECK_EQI(spdf_win_links_ensure_page(cache, doc, 0, 0), 1);
    /* Poll the way hover does; 10 s is a hang detector, not a timing claim. */
    for (spins = 0; spins < 2000 && !spdf_win_links_text_urls_ready(cache); ++spins) {
        Sleep(5);
        spdf_win_links_ensure_page(cache, doc, 0, 0);
    }
    printf("      text-URL worker delivered after %d polls\n", spins);
    CHECK_EQI(spdf_win_links_text_urls_ready(cache), 1);
    /* The merged set still answers the annotation, and a page switch drops it. */
    x_ok = spdf_win_links_hit(cache, doc, 0, x, y);
    CHECK_EQI(x_ok, 1);
    CHECK_EQI(spdf_win_links_region_at(cache, doc, 0, 0, x, y), SPDF_WIN_CURSOR_REGION_LINK);
    CHECK_EQI(spdf_win_links_hit(cache, doc, 1, x, y), 0);
    CHECK_EQI(spdf_win_links_text_urls_ready(cache), 0); /* page 1's answer has not landed yet */
    /* Invalidate, then the same page again: a second delivery, not a stale one. */
    spdf_win_links_invalidate(cache);
    CHECK_EQI(spdf_win_links_text_urls_ready(cache), 0);
    CHECK_EQI(spdf_win_links_hit(cache, doc, 0, x, y), 1);
    for (spins = 0; spins < 2000 && !spdf_win_links_text_urls_ready(cache); ++spins) {
        Sleep(5);
        spdf_win_links_ensure_page(cache, doc, 0, 0);
    }
    CHECK_EQI(spdf_win_links_text_urls_ready(cache), 1);
    CHECK_EQI(spdf_win_links_hit(cache, doc, 0, x, y), 1);
    CHECK_EQI(spdf_win_links_text_urls_ready(NULL), 0);
    spdf_win_links_set_source(NULL, path);
    spdf_win_links_free(cache); /* joins the worker */
}

int main(int argc, char** argv) {
    char err[512];
    spdf_document* doc;

    if (argc < 2) {
        printf("usage: %s <selection.pdf>\n", argv[0]);
        return 2;
    }
    test_pure_regions();

    doc = spdf_open(argv[1], err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", argv[1], err);
        return 2;
    }
    test_link_rects(doc);
    test_cache(doc);
    test_text_url_worker(doc, argv[1]);
    spdf_close(doc);

    printf("link_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
