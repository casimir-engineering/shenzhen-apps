/* link_destination_test.c — a click on a real link in a real document lands on
 * the destination's OWN Y, not at the top of the target page.
 *
 * WHAT THIS ADDS OVER link_nav_test.c. That one drives the arithmetic directly
 * and is exhaustive about it. This one drives the whole path -- press, release,
 * the canvas resolving the link, the canvas scrolling -- and then checks the
 * resulting scroll offset against the destination the FIXTURE authored, so the
 * binding between "fz_resolve_link said y = 232" and "the viewport moved 232
 * points down page 4 at this zoom" is measured rather than assumed. It is the
 * proof for the "Links" row of portable/docs/windows-feature-matrix.md.
 *
 * WHY ITS OWN FIXTURE. selection.pdf's only internal link points at the last of
 * three pages, where every scroll clamps at the document's end -- so
 * "destination y" and "page top" are the same number there and neither can be
 * distinguished from the other. portable/win/tests/make_link_dest_fixture.py
 * writes eight pages and four links whose destinations are chosen so that all
 * four cases are separable: a NAMED destination 232 pt down page 4, a direct
 * array destination 642 pt down page 6, a /Fit destination with no point at all
 * on page 8, and an external URI.
 *
 * NO OFFSET IS HARD-CODED. The destinations come back from the core through
 * spdf_win_links_target_at and the page slots from spdf_win_canvas_page_rect,
 * so regenerating the fixture cannot silently invalidate an expectation. What
 * IS pinned is that the y is honoured at all, and that the page-only case still
 * lands exactly where spdf_win_canvas_scroll_to_page() puts it.
 *
 * NO HWND, like canvas_selection_test.c beside it: this is the same canvas the
 * window drives, with no window.
 */
/* spdf-test-sources: portable/win/src/spdf_win_canvas.cpp portable/win/src/spdf_win_canvas_prefetch.cpp portable/win/src/spdf_win_canvas_selection.cpp portable/win/src/spdf_win_find_canvas.cpp portable/win/src/spdf_win_selection.cpp portable/win/src/spdf_win_links.cpp portable/win/src/spdf_win_lru.c portable/win/src/spdf_win_render.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/link_dest.pdf */
/* spdf-test-needs: mupdf */
#include <math.h>

#include "spdf_win_canvas.h"
#include "spdf_win_links.h"

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

static const spdf_win_page_draw* draw_for(const spdf_win_scene* scene, int page) {
    int i;
    for (i = 0; i < scene->page_count; ++i)
        if (scene->pages[i].page_index == page) return &scene->pages[i];
    return NULL;
}

/* Page point -> canvas-local device pixels through the scene's own geometry,
 * written independently here (the inverse of what the code under test does). */
static void device_of(const spdf_win_page_draw* d, float pw, float ph, float px, float py, float* x, float* y) {
    *x = d->dest_x + px * (d->dest_w / pw);
    *y = d->dest_y + py * (d->dest_h / ph);
}

/* The scroll offset the canvas would settle on for `raw`, i.e. `raw` clamped to
 * the document's travel exactly as clamp_scroll() does. Written here so the
 * expectations below stay in the same units the canvas reports. */
static double clamped(spdf_win_canvas* canvas, double raw) {
    unsigned vw = 0, vh = 0;
    double max_y;
    spdf_win_canvas_viewport(canvas, &vw, &vh);
    max_y = (double)spdf_win_canvas_content_h(canvas) - (double)vh;
    if (max_y < 0.0) max_y = 0.0;
    if (raw > max_y) raw = max_y;
    if (raw < 0.0) raw = 0.0;
    return raw;
}

/* Click the centre of `rect` on page 0 and report where the canvas ended up.
 * Every case below is this one gesture: press, release, read the offset. */
static double follow_link(spdf_win_canvas* canvas, spdf_rect rect, float pw, float ph,
                          spdf_win_canvas_link_nav* out_nav) {
    spdf_win_scene scene;
    const spdf_win_page_draw* page0;
    float lx = 0.0f, ly = 0.0f;

    memset(&scene, 0, sizeof(scene));
    /* Back to page 1 first, so each case starts from the same place and the
     * offset it produces is the jump's and not the previous jump's. */
    spdf_win_canvas_scroll_to_page(canvas, 0);
    CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
    page0 = draw_for(&scene, 0);
    CHECK(page0 != NULL);
    if (!page0) return -1.0;
    device_of(page0, pw, ph, (rect.x0 + rect.x1) * 0.5f, (rect.y0 + rect.y1) * 0.5f, &lx, &ly);
    /* The hand and the click must agree about what is here. */
    CHECK_EQI(spdf_win_canvas_cursor_at(canvas, lx, ly, 0), SPDF_WIN_CANVAS_CURSOR_HAND);
    spdf_win_canvas_pointer_press(canvas, lx, ly, 1);
    spdf_win_canvas_pointer_release(canvas, out_nav);
    return (double)spdf_win_canvas_scroll_y(canvas);
}

int main(int argc, char** argv) {
    char err[512];
    spdf_document* doc;
    spdf_win_canvas* canvas;
    spdf_rect rects[16];
    spdf_link_target targets[16];
    float pw = 0.0f, ph = 0.0f;
    double zoom;
    int count, i;
    int named = -1, array = -1, fit = -1, uri = -1;

    if (argc < 2) {
        printf("usage: %s <link_dest.pdf>\n", argv[0]);
        return 2;
    }
    doc = spdf_open(argv[1], err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", argv[1], err);
        return 2;
    }
    CHECK_EQI(spdf_page_count(doc), 8);
    if (!spdf_page_size(doc, 0, &pw, &ph, err, sizeof(err))) {
        printf("FAIL page size: %s\n", err);
        spdf_close(doc);
        return 2;
    }

    /* --- what the fixture's four links resolve to -------------------------- */

    count = spdf_page_link_rects(doc, 0, 0, rects, 16, err, sizeof(err));
    printf("      page 1 link annotations: %d (%s)\n", count, err);
    CHECK_EQI(count, 4);
    if (count != 4) {
        spdf_close(doc);
        return 2;
    }
    for (i = 0; i < count; ++i) {
        float cx = (rects[i].x0 + rects[i].x1) * 0.5f;
        float cy = (rects[i].y0 + rects[i].y1) * 0.5f;
        memset(&targets[i], 0, sizeof(targets[i]));
        CHECK_EQI(spdf_win_links_target_at(doc, 0, cx, cy, &targets[i]), 1);
        printf("      link %d: kind %d page %d point (%.1f, %.1f) uri %s\n", i, (int)targets[i].kind,
               targets[i].page_index, targets[i].x, targets[i].y, targets[i].uri ? targets[i].uri : "-");
        if (targets[i].kind == SPDF_LINK_URI) uri = i;
        else if (targets[i].page_index == 3) named = i;
        else if (targets[i].page_index == 5) array = i;
        else if (targets[i].page_index == 7) fit = i;
    }
    /* THE NAMED DESTINATION RESOLVED AT ALL, which is the case that separates
     * this fixture from selection.pdf's direct array: a /GoTo whose /D is the
     * NAME (chapter-two) had to be looked up in the catalog's dests. If this
     * fails, everything below is measuring the wrong thing. */
    CHECK(named >= 0);
    CHECK(array >= 0);
    CHECK(fit >= 0);
    CHECK(uri >= 0);
    if (named < 0 || array < 0 || fit < 0 || uri < 0) {
        spdf_close(doc);
        return 2;
    }
    /* PAGE SPACE, y DOWN: the fixture authored /XYZ 72 560 on a 792 pt page and
     * the core reports 792 - 560 = 232 down from the page's top. Pinned in
     * link_test.c too; repeated here because every number below rests on it. */
    CHECK(fabs((double)targets[named].y - ((double)ph - 560.0)) < 1.0);
    CHECK(fabs((double)targets[array].y - ((double)ph - 150.0)) < 1.0);
    /* /Fit CARRIES NO POINT, AND THE CORE SAYS SO WITH NaN, not with 0 -- which
     * is why the extraction tests isfinite on both axes (mac's own guard) and
     * not `y > 0`. Measured here so the guard has a reason on this platform
     * too, rather than being inherited on faith. */
    CHECK(!isfinite((double)targets[fit].x));
    CHECK(!isfinite((double)targets[fit].y));
    CHECK_EQI(spdf_win_link_destination_page_y(&targets[fit]) > 0.0, 0);
    CHECK_EQI(spdf_win_link_destination_page_y(&targets[fit]) == 0.0, 1);
    CHECK(spdf_win_link_destination_page_y(&targets[named]) > 200.0);

    /* --- the same links, followed through a real canvas -------------------- */

    canvas = spdf_win_canvas_create(doc, argv[1], SPDF_RENDER_DEFAULT, err, sizeof(err));
    if (!canvas) {
        printf("FAIL canvas: %s\n", err);
        spdf_close(doc);
        return 2;
    }
    spdf_win_canvas_set_viewport(canvas, 900, 1200, 1.0f);
    spdf_win_canvas_set_zoom_mode(canvas, SPDF_WIN_ZOOM_FIT_WIDTH);
    zoom = (double)spdf_win_canvas_zoom(canvas);
    printf("      viewport 900x1200, zoom %.4f, content %.1f\n", zoom, (double)spdf_win_canvas_content_h(canvas));

    {
        spdf_win_canvas_link_nav nav;
        double slot_y = 0.0, sx, sw, sh, got, want, page_top;

        /* --- 1. the NAMED destination, 232 pt down page 4 ------------------ */
        memset(&nav, 0, sizeof(nav));
        got = follow_link(canvas, rects[named], pw, ph, &nav);
        CHECK_EQI(nav.kind, SPDF_LINK_INTERNAL);
        CHECK_EQI(nav.page_index, 3);
        CHECK(nav.uri == NULL);
        CHECK(spdf_win_canvas_page_rect(canvas, 3, &sx, &slot_y, &sw, &sh));
        want = clamped(canvas, spdf_win_link_destination_scroll_y(slot_y, (double)targets[named].y, zoom));
        page_top = clamped(canvas, slot_y - SPDF_WIN_PAGE_MARGIN_V);
        printf("      named dest: slot %.2f + %.1f pt * %.4f - %.1f -> want %.2f got %.2f (page top would be %.2f)\n",
               slot_y, (double)targets[named].y, zoom, (double)SPDF_WIN_PAGE_MARGIN_V, want, got, page_top);
        CHECK(fabs(got - want) < 0.5);
        /* THE DIVERGENCE THIS TEST EXISTS FOR: the page top is a DIFFERENT
         * number here, and the jump did not land on it. Nothing clamps, so the
         * gap is the destination's offset scaled by the zoom. */
        CHECK(want > page_top + 1.0);
        CHECK(fabs((want - page_top) - (double)targets[named].y * zoom) < 0.5);
        CHECK(fabs(got - page_top) > 1.0);
        /* And the destination is genuinely inside the target page's slot, not
         * past its end -- top-aligning something off the page would be a
         * different bug that the arithmetic above cannot see. */
        CHECK(got + (double)SPDF_WIN_PAGE_MARGIN_V < slot_y + sh);

        /* --- 2. a direct ARRAY destination, 642 pt down page 6 ------------- */
        memset(&nav, 0, sizeof(nav));
        got = follow_link(canvas, rects[array], pw, ph, &nav);
        CHECK_EQI(nav.kind, SPDF_LINK_INTERNAL);
        CHECK_EQI(nav.page_index, 5);
        CHECK(spdf_win_canvas_page_rect(canvas, 5, &sx, &slot_y, &sw, &sh));
        want = clamped(canvas, spdf_win_link_destination_scroll_y(slot_y, (double)targets[array].y, zoom));
        page_top = clamped(canvas, slot_y - SPDF_WIN_PAGE_MARGIN_V);
        printf("      array dest: want %.2f got %.2f (page top would be %.2f)\n", want, got, page_top);
        CHECK(fabs(got - want) < 0.5);
        CHECK(want > page_top + 1.0);

        /* --- 3. /Fit: NO point, so the page's start ------------------------ */
        memset(&nav, 0, sizeof(nav));
        got = follow_link(canvas, rects[fit], pw, ph, &nav);
        CHECK_EQI(nav.kind, SPDF_LINK_INTERNAL);
        CHECK_EQI(nav.page_index, 7);
        CHECK(spdf_win_canvas_page_rect(canvas, 7, &sx, &slot_y, &sw, &sh));
        page_top = clamped(canvas, slot_y - SPDF_WIN_PAGE_MARGIN_V);
        printf("      fit dest: want %.2f got %.2f\n", page_top, got);
        CHECK(fabs(got - page_top) < 0.5);
        /* EXACTLY WHERE "GO TO PAGE N" LANDS, checked against that call rather
         * than against a repetition of its arithmetic. */
        spdf_win_canvas_scroll_to_page(canvas, 7);
        CHECK(fabs((double)spdf_win_canvas_scroll_y(canvas) - got) < 0.5);

        /* --- 4. the EXTERNAL link: resolved, and NOT scrolled to ----------- */
        memset(&nav, 0, sizeof(nav));
        got = follow_link(canvas, rects[uri], pw, ph, &nav);
        CHECK_EQI(nav.kind, SPDF_LINK_URI);
        CHECK(nav.uri != NULL && strstr(nav.uri, "example.invalid") != NULL);
        CHECK_EQI(nav.page_index, -1);
        printf("      uri link: '%s', still at %.2f\n", nav.uri ? nav.uri : "(null)", got);
        /* follow_link() scrolled back to page 1 before clicking, and an
         * external link must leave the view exactly there: whether and when it
         * opens is the shell's decision (spdf_win_chrome_canvas_ui.h), and the
         * canvas must not move the document for it. */
        CHECK(fabs(got - 0.0) < 0.5);
        CHECK_EQI(spdf_win_canvas_current_page(canvas), 0);
    }

    spdf_win_canvas_destroy(canvas);
    for (i = 0; i < count; ++i) spdf_free_link_target(&targets[i]);
    spdf_close(doc);

    printf("link_destination_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
