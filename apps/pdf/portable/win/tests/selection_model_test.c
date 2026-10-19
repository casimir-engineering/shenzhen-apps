/* selection_model_test.c — the selection layer end to end: the pure
 * device-pixel <-> page-point mapping, the drag that turns into selected text,
 * the granularity a multi-click asks for, and the overlay rects that have to
 * coexist with find's.
 *
 * WHAT IS AND IS NOT CHECKED HERE. Everything about the selection logic itself
 * -- which glyphs a range covers, where a word ends, how a block is bounded,
 * how CJK runs without spaces are segmented -- belongs to
 * portable/core/spdf_selection.c and is pinned by SPDFCoreSelectionTests and
 * SPDFCoreCJKSelectionTests, both of which already run in this suite. The
 * gesture state machine and the click policy are transcriptions of the GTK4
 * original and are pinned exhaustively by
 * portable/win/tests/selection-differential-native.cmd. What is left, and what
 * this file exists for, is the part with NO original and no core coverage: the
 * two coordinate mappings, and the second overlay producer.
 *
 * IT NEEDS A REAL DOCUMENT for the mappings to mean anything, so it opens
 * portable/win/tests/fixtures/selection.pdf -- see make_selection_fixture.py
 * for what is on each page and why. It finds its own coordinates with
 * spdf_search_page_rects() rather than hard-coding a rectangle, so the fixture
 * can be regenerated without editing an expectation here.
 *
 * EACH DIRECTIVE BELOW IS ITS OWN ONE-LINE COMMENT: harness-lib.sh's `declared`
 * stops at a closing comment marker, so a directive continued onto a second
 * line is silently ignored and the test then fails to link for a reason that
 * looks nothing like the cause.
 */
/* spdf-test-sources: portable/win/src/spdf_win_selection.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/selection.pdf */
/* spdf-test-needs: mupdf */
#include "spdf_win_selection.h"

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

#define CHECK_NEAR(a, b, tol)                                                                                          \
    do {                                                                                                               \
        double va = (double)(a);                                                                                        \
        double vb = (double)(b);                                                                                        \
        ++g_checks;                                                                                                    \
        if (!(fabs(va - vb) <= (tol))) {                                                                               \
            printf("FAIL %s:%d: %s (%g) != %s (%g) within %g\n", __FILE__, __LINE__, #a, va, #b, vb, (double)(tol));   \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- a hand-built canvas ------------------------------------------------- */

/* Two pages of different sizes, both drawn at 1.5x, page 1 at the top of the
 * canvas and page 2 below it with a 26 px gutter between them -- the same
 * arrangement spdf_win_layout_compute produces, written out by hand so this
 * test depends on no layout code at all. */
#define ZOOM 1.5f

static SpdfWinPageSizePt g_sizes[2] = {{612.0, 792.0}, {1224.0, 792.0}};
static spdf_win_page_draw g_pages[2];

static void build_pages(void) {
    g_pages[0].bitmap = NULL;
    g_pages[0].page_index = 0;
    g_pages[0].dest_x = 100.0f;
    g_pages[0].dest_y = 13.0f;
    g_pages[0].dest_w = (float)g_sizes[0].width * ZOOM;
    g_pages[0].dest_h = (float)g_sizes[0].height * ZOOM;

    g_pages[1].bitmap = NULL;
    g_pages[1].page_index = 1;
    g_pages[1].dest_x = -200.0f; /* a foldout wider than the viewport, panned */
    g_pages[1].dest_y = g_pages[0].dest_y + g_pages[0].dest_h + 26.0f;
    g_pages[1].dest_w = (float)g_sizes[1].width * ZOOM;
    g_pages[1].dest_h = (float)g_sizes[1].height * ZOOM;
}

static void test_mapping(void) {
    spdf_win_page_point p;

    /* Dead centre of page 1 is the centre of the page in points. */
    CHECK(spdf_win_selection_point_on_page(g_pages, 2, g_sizes, 2, g_pages[0].dest_x + g_pages[0].dest_w * 0.5f,
                                           g_pages[0].dest_y + g_pages[0].dest_h * 0.5f, &p));
    CHECK_EQI(p.page_index, 0);
    CHECK_EQI(p.inside, 1);
    CHECK_NEAR(p.x, 306.0, 0.01);
    CHECK_NEAR(p.y, 396.0, 0.01);

    /* The top-left corner is the origin, and y runs DOWN -- the space the core
     * takes, not PDF user space. */
    CHECK(spdf_win_selection_point_on_page(g_pages, 2, g_sizes, 2, g_pages[0].dest_x, g_pages[0].dest_y, &p));
    CHECK_NEAR(p.x, 0.0, 0.001);
    CHECK_NEAR(p.y, 0.0, 0.001);

    /* A point in the gutter BETWEEN the pages resolves to the nearer one, is
     * reported as not inside, and is clamped to that page's edge. Just below
     * page 1's bottom is 13 px from page 1 and 13 px from page 2, and the
     * nearest-page rule breaks the tie in favour of the FIRST page -- the same
     * tie-break spdf_win_zoom_anchor_capture uses. */
    CHECK(spdf_win_selection_point_on_page(g_pages, 2, g_sizes, 2, g_pages[0].dest_x + 10.0f,
                                           g_pages[0].dest_y + g_pages[0].dest_h + 13.0f, &p));
    CHECK_EQI(p.page_index, 0);
    CHECK_EQI(p.inside, 0);
    CHECK_NEAR(p.y, g_sizes[0].height, 0.01);

    /* Well below page 1 is page 2, clamped to its top. */
    CHECK(spdf_win_selection_point_on_page(g_pages, 2, g_sizes, 2, 300.0f, g_pages[1].dest_y - 2.0f, &p));
    CHECK_EQI(p.page_index, 1);
    CHECK_EQI(p.inside, 0);
    CHECK_NEAR(p.y, 0.0, 0.001);

    /* Far left of the canvas, level with page 1: clamped to x = 0, still page 1. */
    CHECK(spdf_win_selection_point_on_page(g_pages, 2, g_sizes, 2, -500.0f, g_pages[0].dest_y + 100.0f, &p));
    CHECK_EQI(p.page_index, 0);
    CHECK_EQI(p.inside, 0);
    CHECK_NEAR(p.x, 0.0, 0.001);

    /* A page whose SIZE is unknown (size_count short of the page index) yields
     * no hit rather than a wrong point. */
    CHECK(!spdf_win_selection_point_on_page(&g_pages[1], 1, g_sizes, 1, g_pages[1].dest_x + 10.0f,
                                            g_pages[1].dest_y + 10.0f, &p));
    CHECK_EQI(p.page_index, -1);

    /* Pinned to one page: a point deep inside page 2 clamps into page 1 when
     * page 1 is the anchor, which is what keeps a range drag on one page. */
    CHECK(spdf_win_selection_point_on_page_index(g_pages, 2, g_sizes, 2, 0, 300.0f, g_pages[1].dest_y + 400.0f, &p));
    CHECK_EQI(p.page_index, 0);
    CHECK_NEAR(p.y, g_sizes[0].height, 0.01);
    /* And a page that is not in the list is not resolvable at all. */
    CHECK(!spdf_win_selection_point_on_page_index(g_pages, 2, g_sizes, 2, 7, 300.0f, 300.0f, &p));

    /* An empty list, and a NULL out, are both survivable. */
    CHECK(!spdf_win_selection_point_on_page(NULL, 0, g_sizes, 2, 0.0f, 0.0f, &p));
    CHECK(!spdf_win_selection_point_on_page(g_pages, 2, g_sizes, 2, 0.0f, 0.0f, NULL));
}

/* The inverse must undo the forward map, on the foldout as well as the letter
 * page -- the foldout is here precisely so a wrong page size shows up as a
 * rectangle in the wrong place rather than as no rectangle at all. */
static void test_rect_round_trip(void) {
    spdf_rect page_rect;
    spdf_win_overlay o;
    spdf_win_page_point p;
    int i;

    for (i = 0; i < 2; ++i) {
        page_rect.x0 = 72.0f;
        page_rect.y0 = 100.0f;
        page_rect.x1 = 172.0f;
        page_rect.y1 = 118.0f;
        CHECK(spdf_win_selection_rect_to_device(&g_pages[i], g_sizes, 2, page_rect, &o));
        CHECK_EQI(o.kind, SPDF_WIN_OVERLAY_SELECTION);
        CHECK_EQI(o.page_index, i);
        CHECK_NEAR(o.alpha, 1.0, 0.0);
        CHECK_NEAR(o.w, 100.0 * ZOOM, 0.01);
        CHECK_NEAR(o.h, 18.0 * ZOOM, 0.01);
        CHECK(spdf_win_selection_point_on_page_index(g_pages, 2, g_sizes, 2, i, o.x, o.y, &p));
        CHECK_NEAR(p.x, page_rect.x0, 0.01);
        CHECK_NEAR(p.y, page_rect.y0, 0.01);
    }
    /* A draw with no geometry produces nothing. */
    {
        spdf_win_page_draw empty = g_pages[0];
        empty.dest_w = 0.0f;
        CHECK(!spdf_win_selection_rect_to_device(&empty, g_sizes, 2, page_rect, &o));
    }
}

static void test_click_policy(void) {
    /* Spot checks only; selection-differential-native.cmd compares every press
     * count against the GTK4 original. */
    CHECK_EQI(spdf_win_selection_click_policy(0).granularity, SPDF_SELECTION_RANGE);
    CHECK_EQI(spdf_win_selection_click_policy(1).granularity, SPDF_SELECTION_RANGE);
    CHECK_EQI(spdf_win_selection_click_policy(1).uses_range_path, 1);
    CHECK_EQI(spdf_win_selection_click_policy(2).granularity, SPDF_SELECTION_WORD);
    CHECK_EQI(spdf_win_selection_click_policy(2).cancels_pending_link, 1);
    CHECK_EQI(spdf_win_selection_click_policy(3).granularity, SPDF_SELECTION_BLOCK);
    CHECK_EQI(spdf_win_selection_click_policy(9).granularity, SPDF_SELECTION_BLOCK);
}

/* --- the real document --------------------------------------------------- */

/* Page-space rect of a string on page 0, so no coordinate is hard-coded. */
static int text_rect(spdf_document* doc, const char* needle, spdf_rect* out) {
    char err[256];
    int count = spdf_search_page_rects(doc, 0, needle, out, 1, err, sizeof(err));
    if (count != 1) printf("      note: '%s' matched %d rect(s): %s\n", needle, count, err);
    return count == 1;
}

/* Device point for a page point on page 0 of the hand-built canvas. */
static void device_of(float px, float py, float* dx, float* dy) {
    *dx = g_pages[0].dest_x + px * (g_pages[0].dest_w / (float)g_sizes[0].width);
    *dy = g_pages[0].dest_y + py * (g_pages[0].dest_h / (float)g_sizes[0].height);
}

/* Drag across a line's own rectangle and report what came back. */
static int drag_over(spdf_win_selection* sel, spdf_document* doc, spdf_rect r, unsigned click_count) {
    float x0, y0, x1, y1;
    float mid = (r.y0 + r.y1) * 0.5f;

    device_of(r.x0 + 0.5f, mid, &x0, &y0);
    device_of(r.x1 - 0.5f, mid, &x1, &y1);
    spdf_win_selection_press(sel, doc, g_pages, 1, g_sizes, 1, x0, y0, click_count, 0);
    if (click_count == 1) spdf_win_selection_drag(sel, doc, g_pages, 1, g_sizes, 1, x1, y1, 0.0);
    spdf_win_selection_release(sel);
    return spdf_win_selection_has_text(sel);
}

static void test_live_selection(spdf_document* doc) {
    spdf_win_selection* sel = spdf_win_selection_new();
    spdf_rect r;
    const char* text;

    CHECK(sel != NULL);
    if (!sel) return;

    /* 1. an ASCII range drag. */
    if (text_rect(doc, "Selection fixture alpha", &r)) {
        CHECK(drag_over(sel, doc, r, 1));
        text = spdf_win_selection_text(sel);
        printf("      range ASCII: '%s'\n", text ? text : "(null)");
        CHECK(text && strstr(text, "Selection fixture alpha") != NULL);
        CHECK_EQI(spdf_win_selection_page(sel), 0);
        {
            int n = 0;
            CHECK(spdf_win_selection_rects(sel, &n) != NULL);
            CHECK(n > 0);
        }
        CHECK(spdf_win_selection_error(sel) == NULL);
    }

    /* 2. ACCENTED text, drawn through /WinAnsiEncoding, must come back as
     *    UTF-8 and not as three question marks. */
    if (text_rect(doc, "r\xc3\xa9sum\xc3\xa9", &r)) {
        CHECK(drag_over(sel, doc, r, 1));
        text = spdf_win_selection_text(sel);
        printf("      range accented: '%s'\n", text ? text : "(null)");
        /* U+00E9 is 0xC3 0xA9 in UTF-8. Asserting the BYTES is the point: a
         * narrow conversion anywhere in this path would leave '?' or 0xE9. */
        CHECK(text && strstr(text, "\xc3\xa9") != NULL);
    }

    /* 3. CJK, through the glyphless Type3 font with a ToUnicode CMap -- the
     *    shape of an OCR text layer, and the case CP1252 destroys. */
    if (text_rect(doc, "\xe4\xb8\xad\xe6\x96\x87", &r)) {
        CHECK(drag_over(sel, doc, r, 1));
        text = spdf_win_selection_text(sel);
        printf("      range CJK: '%s'\n", text ? text : "(null)");
        CHECK(text && strstr(text, "\xe4\xb8\xad\xe6\x96\x87") != NULL);
    }

    /* 4. a DOUBLE click selects one word and needs no drag at all. */
    if (text_rect(doc, "fixture", &r)) {
        CHECK(drag_over(sel, doc, r, 2));
        text = spdf_win_selection_text(sel);
        printf("      word: '%s'\n", text ? text : "(null)");
        CHECK(text && strstr(text, "fixture") != NULL);
        /* A word selection is one word, not the line it sits on. */
        CHECK(text && strstr(text, "Selection fixture alpha") == NULL);
    }

    /* 5. a TRIPLE click selects the containing block, which spans lines. */
    if (text_rect(doc, "fixture", &r)) {
        CHECK(drag_over(sel, doc, r, 3));
        text = spdf_win_selection_text(sel);
        printf("      block: '%s'\n", text ? text : "(null)");
        CHECK(text && strstr(text, "fixture") != NULL);
    }

    /* 6. a click on blank paper CLEARS the selection rather than keeping a
     *    stale highlight the reader cannot see the origin of. */
    {
        float x, y;
        device_of(500.0f, 60.0f, &x, &y); /* above and right of every line */
        spdf_win_selection_press(sel, doc, g_pages, 1, g_sizes, 1, x, y, 1, 0);
        spdf_win_selection_release(sel);
        CHECK(!spdf_win_selection_has_text(sel));
    }

    /* 7. a press with no page under it selects nothing and does not crash. */
    spdf_win_selection_press(sel, doc, NULL, 0, g_sizes, 1, 5.0f, 5.0f, 1, 0);
    CHECK(!spdf_win_selection_has_text(sel));

    /* 8. every entry point tolerates a NULL selection. */
    CHECK_EQI(spdf_win_selection_press(NULL, doc, g_pages, 1, g_sizes, 1, 0, 0, 1, 0), 0);
    CHECK_EQI(spdf_win_selection_drag(NULL, doc, g_pages, 1, g_sizes, 1, 0, 0, 0.0), 0);
    CHECK_EQI(spdf_win_selection_release(NULL), 0);
    spdf_win_selection_cancel(NULL);
    spdf_win_selection_clear(NULL);
    CHECK_EQI(spdf_win_selection_has_text(NULL), 0);
    CHECK(spdf_win_selection_text(NULL) == NULL);

    spdf_win_selection_free(sel);
}

/* --- two overlay producers ----------------------------------------------- */

/* The base array a prior producer (find) would have left on the scene. Its
 * contents are checked byte for byte after the compose, because the failure
 * this coexistence exists to prevent is find's highlights VANISHING. */
static const spdf_win_overlay k_base[3] = {
    {0, 10.0f, 20.0f, 30.0f, 40.0f, SPDF_WIN_OVERLAY_SEARCH_MATCH, 1.0f},
    {1, 11.0f, 21.0f, 31.0f, 41.0f, SPDF_WIN_OVERLAY_SEARCH_MATCH, 1.0f},
    {0, 10.0f, 20.0f, 30.0f, 40.0f, SPDF_WIN_OVERLAY_SEARCH_ACTIVE, 0.5f},
};

static void test_overlay_coexistence(spdf_document* doc) {
    spdf_win_selection* sel = spdf_win_selection_new();
    spdf_win_scene scene;
    spdf_rect r;
    int i, selection_rects;

    CHECK(sel != NULL);
    if (!sel) return;
    if (!text_rect(doc, "Selection fixture alpha", &r)) {
        spdf_win_selection_free(sel);
        return;
    }
    CHECK(drag_over(sel, doc, r, 1));
    spdf_win_selection_rects(sel, &selection_rects);
    CHECK(selection_rects > 0);

    /* With a base: base first, verbatim, selection appended after it. */
    memset(&scene, 0, sizeof(scene));
    scene.pages = g_pages;
    scene.page_count = 1;
    scene.overlays = k_base;
    scene.overlay_count = 3;
    spdf_win_selection_compose_overlays(sel, g_pages, 1, g_sizes, 1, &scene);
    CHECK(scene.overlays != k_base);
    CHECK_EQI(scene.overlay_count, 3 + selection_rects);
    if (scene.overlay_count == 3 + selection_rects) {
        for (i = 0; i < 3; ++i) {
            CHECK_EQI(scene.overlays[i].kind, k_base[i].kind);
            CHECK_EQI(scene.overlays[i].page_index, k_base[i].page_index);
            CHECK_NEAR(scene.overlays[i].x, k_base[i].x, 0.0);
            CHECK_NEAR(scene.overlays[i].alpha, k_base[i].alpha, 0.0);
        }
        /* Find's ACTIVE ring is still the last thing find emitted, and the
         * selection sits after it -- macOS's own order. */
        CHECK_EQI(scene.overlays[2].kind, SPDF_WIN_OVERLAY_SEARCH_ACTIVE);
        for (i = 3; i < scene.overlay_count; ++i) {
            CHECK_EQI(scene.overlays[i].kind, SPDF_WIN_OVERLAY_SELECTION);
            CHECK_EQI(scene.overlays[i].page_index, 0);
            CHECK(scene.overlays[i].w > 0.0f && scene.overlays[i].h > 0.0f);
            /* Inside the page it was mapped onto. */
            CHECK(scene.overlays[i].x >= g_pages[0].dest_x - 0.01f);
            CHECK(scene.overlays[i].x <= g_pages[0].dest_x + g_pages[0].dest_w + 0.01f);
        }
    }

    /* COMPOSING TWICE over our own output must not duplicate the selection.
     * The scene still points at our array from the call above, which is the
     * exact state a caller that forgets to re-run find would produce. */
    spdf_win_selection_compose_overlays(sel, g_pages, 1, g_sizes, 1, &scene);
    CHECK_EQI(scene.overlay_count, selection_rects);
    CHECK_EQI(scene.overlays[0].kind, SPDF_WIN_OVERLAY_SELECTION);

    /* With no base at all -- the ordinary case, nobody searching. */
    memset(&scene, 0, sizeof(scene));
    scene.pages = g_pages;
    scene.page_count = 1;
    spdf_win_selection_compose_overlays(sel, g_pages, 1, g_sizes, 1, &scene);
    CHECK_EQI(scene.overlay_count, selection_rects);
    CHECK(scene.overlays != NULL);

    /* THE SELECTION IS ON PAGE 0, so a scene showing only page 1 gets the base
     * back untouched: a highlight must not follow a page it does not belong to. */
    memset(&scene, 0, sizeof(scene));
    scene.pages = &g_pages[1];
    scene.page_count = 1;
    scene.overlays = k_base;
    scene.overlay_count = 3;
    spdf_win_selection_compose_overlays(sel, &g_pages[1], 1, g_sizes, 2, &scene);
    CHECK_EQI(scene.overlay_count, 3);
    CHECK(scene.overlays == k_base);

    /* A cleared selection contributes nothing and leaves the base alone. */
    spdf_win_selection_clear(sel);
    memset(&scene, 0, sizeof(scene));
    scene.pages = g_pages;
    scene.page_count = 1;
    scene.overlays = k_base;
    scene.overlay_count = 3;
    spdf_win_selection_compose_overlays(sel, g_pages, 1, g_sizes, 1, &scene);
    CHECK_EQI(scene.overlay_count, 3);
    CHECK(scene.overlays == k_base);

    /* NULLs everywhere. */
    spdf_win_selection_compose_overlays(NULL, g_pages, 1, g_sizes, 1, &scene);
    spdf_win_selection_compose_overlays(sel, g_pages, 1, g_sizes, 1, NULL);
    spdf_win_selection_free(sel);
}

int main(int argc, char** argv) {
    char err[512];
    spdf_document* doc;

    if (argc < 2) {
        printf("usage: %s <selection.pdf>\n", argv[0]);
        return 2;
    }
    build_pages();
    test_mapping();
    test_rect_round_trip();
    test_click_policy();

    doc = spdf_open(argv[1], err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", argv[1], err);
        return 2;
    }
    CHECK_EQI(spdf_page_count(doc), 3);
    test_live_selection(doc);
    test_overlay_coexistence(doc);
    spdf_close(doc);

    printf("selection_model_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
