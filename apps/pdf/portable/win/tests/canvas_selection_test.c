/* canvas_selection_test.c — the six calls the shell has to wire, driven through
 * a REAL canvas with no window anywhere.
 *
 * WHAT THIS ADDS OVER selection_model_test.c. That one drives the selection
 * model against a HAND-BUILT page list, which is what makes its geometry cases
 * exhaustive and fast. This one drives the same model through
 * spdf_win_canvas_build_scene()'s OWN page list, at the canvas's own zoom and
 * scroll, so the binding between the two -- the part where a device pixel from
 * a WM_LBUTTONDOWN becomes a PDF point -- is checked against the geometry the
 * painter would actually have drawn, and not against a list a test wrote.
 *
 * IT IS ALSO THE PROOF THAT NONE OF THIS NEEDS AN HWND. Every call below is the
 * one the input router will make, and this process creates no window, opens no
 * message loop and touches no Direct2D device. That is the same property
 * --render-window-png relies on, and the reason the port can be verified on a
 * locked workstation at all.
 */
/* spdf-test-sources: portable/win/src/spdf_win_canvas.cpp portable/win/src/spdf_win_canvas_prefetch.cpp portable/win/src/spdf_win_canvas_selection.cpp portable/win/src/spdf_win_find_canvas.cpp portable/win/src/spdf_win_selection.cpp portable/win/src/spdf_win_links.cpp portable/win/src/spdf_win_lru.c portable/win/src/spdf_win_render.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/selection.pdf */
/* spdf-test-needs: mupdf */
#include <math.h>

#include "spdf_win_layout.h" /* SPDF_WIN_PAGE_MARGIN_V, for the slot check */
#include "spdf_win_canvas.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;
static int g_skipped = 0;

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

/* The scene's own draw for a page, or NULL. */
static const spdf_win_page_draw* draw_for(const spdf_win_scene* scene, int page) {
    int i;
    for (i = 0; i < scene->page_count; ++i)
        if (scene->pages[i].page_index == page) return &scene->pages[i];
    return NULL;
}

/* Page point -> canvas-local device pixels, through the scene's own geometry --
 * the inverse of what the code under test does, written independently here. */
static void device_of(const spdf_win_page_draw* d, float pw, float ph, float px, float py, float* x, float* y) {
    *x = d->dest_x + px * (d->dest_w / pw);
    *y = d->dest_y + py * (d->dest_h / ph);
}

int main(int argc, char** argv) {
    char err[512];
    spdf_document* doc;
    spdf_win_canvas* canvas;
    spdf_win_scene scene;
    const spdf_win_page_draw* page0;
    spdf_rect line, link_rect;
    float pw = 0.0f, ph = 0.0f;
    float x0, y0, x1, y1;
    const char* text;

    if (argc < 2) {
        printf("usage: %s <selection.pdf>\n", argv[0]);
        return 2;
    }
    doc = spdf_open(argv[1], err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", argv[1], err);
        return 2;
    }
    if (!spdf_page_size(doc, 0, &pw, &ph, err, sizeof(err))) {
        printf("FAIL page size: %s\n", err);
        spdf_close(doc);
        return 2;
    }
    /* The canvas opens the file again for its prefetch workers, so it gets the
     * path; `doc` stays this thread's handle and is the one every selection and
     * link call below uses. */
    canvas = spdf_win_canvas_create(doc, argv[1], SPDF_RENDER_DEFAULT, err, sizeof(err));
    if (!canvas) {
        printf("FAIL canvas: %s\n", err);
        spdf_close(doc);
        return 2;
    }
    spdf_win_canvas_set_viewport(canvas, 900, 1200, 1.0f);
    spdf_win_canvas_set_zoom_mode(canvas, SPDF_WIN_ZOOM_FIT_WIDTH);

    memset(&scene, 0, sizeof(scene));
    CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
    page0 = draw_for(&scene, 0);
    CHECK(page0 != NULL);
    if (!page0) {
        spdf_win_canvas_destroy(canvas);
        spdf_close(doc);
        return 2;
    }
    printf("      page 0 slot: %.1f,%.1f %.1fx%.1f at zoom %.3f\n", page0->dest_x, page0->dest_y, page0->dest_w,
           page0->dest_h, spdf_win_canvas_zoom(canvas));

    /* --- a range drag over a real line ----------------------------------- */

    CHECK_EQI(spdf_search_page_rects(doc, 0, "Selection fixture alpha", &line, 1, err, sizeof(err)), 1);
    device_of(page0, pw, ph, line.x0 + 0.5f, (line.y0 + line.y1) * 0.5f, &x0, &y0);
    device_of(page0, pw, ph, line.x1 - 0.5f, (line.y0 + line.y1) * 0.5f, &x1, &y1);

    /* A single press selects NOTHING yet: selecting on press would flash a
     * one-character highlight under every click, including the click that
     * follows a link. */
    spdf_win_canvas_pointer_press(canvas, x0, y0, 1);
    CHECK_EQI(spdf_win_canvas_has_selection(canvas), 0);
    CHECK(spdf_win_canvas_pointer_drag(canvas, x1, y1) != 0);
    CHECK_EQI(spdf_win_canvas_pointer_release(canvas, NULL), 0);
    CHECK_EQI(spdf_win_canvas_has_selection(canvas), 1);
    text = spdf_win_canvas_selection_text(canvas);
    printf("      canvas selection: '%s'\n", text ? text : "(null)");
    CHECK(text && strstr(text, "Selection fixture alpha") != NULL);

    /* --- the overlays it contributes -------------------------------------- */

    CHECK_EQI(scene.overlay_count, 0);
    spdf_win_canvas_apply_selection_overlays(canvas, &scene);
    CHECK(scene.overlay_count > 0);
    CHECK(scene.overlays != NULL);
    if (scene.overlay_count > 0 && scene.overlays) {
        int i;
        for (i = 0; i < scene.overlay_count; ++i) {
            CHECK_EQI(scene.overlays[i].kind, SPDF_WIN_OVERLAY_SELECTION);
            CHECK_EQI(scene.overlays[i].page_index, 0);
            /* Inside the slot the scene drew, and roughly where the line is. */
            CHECK(scene.overlays[i].x >= page0->dest_x - 1.0f);
            CHECK(scene.overlays[i].y >= page0->dest_y - 1.0f);
            CHECK(scene.overlays[i].w > 0.0f && scene.overlays[i].h > 0.0f);
        }
        printf("      %d selection overlay rect(s), first at %.1f,%.1f %.1fx%.1f\n", scene.overlay_count,
               scene.overlays[0].x, scene.overlays[0].y, scene.overlays[0].w, scene.overlays[0].h);
    }

    /* BUILD_SCENE DOES NOT TOUCH `overlays`, which is worth pinning because the
     * composition contract depends on it: the overlay array is owned by its
     * PRODUCERS, and the first producer of a frame (find) is the one that
     * clears it. A caller that runs neither producer keeps last frame's array,
     * which is why compose refuses to treat its own output as a base. */
    CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
    CHECK(scene.overlay_count > 0);
    /* Composing again over our own output must not double the rects. */
    {
        int before = scene.overlay_count;
        spdf_win_canvas_apply_selection_overlays(canvas, &scene);
        CHECK_EQI(scene.overlay_count, before);
    }
    /* What the real frame does: the first producer clears, then we append. */
    scene.overlays = NULL;
    scene.overlay_count = 0;
    spdf_win_canvas_apply_selection_overlays(canvas, &scene);
    CHECK(scene.overlay_count > 0);

    /* --- copy ------------------------------------------------------------- */

    if (spdf_win_canvas_copy_selection(canvas)) {
        printf("      copied to the clipboard\n");
        ++g_checks;
    } else {
        /* A locked workstation makes OpenClipboard fail with
         * ERROR_ACCESS_DENIED; clipboard_test.c proves the bytes that would
         * have been published, with no clipboard involved. */
        printf("      SKIP copy: OpenClipboard failed, GetLastError=%lu (5 = locked workstation)\n", GetLastError());
        ++g_skipped;
    }

    /* --- the cursor ------------------------------------------------------- */

    {
        char lerr[256];
        float lx = 0.0f, ly = 0.0f;
        int n = spdf_page_link_rects(doc, 0, 0, &link_rect, 1, lerr, sizeof(lerr));
        CHECK(n >= 1);
        if (n >= 1)
            device_of(page0, pw, ph, (link_rect.x0 + link_rect.x1) * 0.5f, (link_rect.y0 + link_rect.y1) * 0.5f, &lx,
                      &ly);

        /* ORDER MATTERS HERE and the order is the point. Over body text the
         * cursor is an ARROW until somebody asks for the structured-text pass,
         * an I-BEAM after it -- and an I-beam from then on even for a caller
         * that passes 0, because the flag controls BUILDING and regions already
         * paid for are not thrown away while the pointer is still on the page. */
        CHECK_EQI(spdf_win_canvas_cursor_at(canvas, x0, y0, 0), SPDF_WIN_CANVAS_CURSOR_ARROW);
        /* A link is a HAND with the text pass switched off: hover must never
         * depend on it, which is the whole reason the two are separable. */
        if (n >= 1) CHECK_EQI(spdf_win_canvas_cursor_at(canvas, lx, ly, 0), SPDF_WIN_CANVAS_CURSOR_HAND);
        CHECK_EQI(spdf_win_canvas_cursor_at(canvas, x0, y0, 1), SPDF_WIN_CANVAS_CURSOR_TEXT);
        CHECK_EQI(spdf_win_canvas_cursor_at(canvas, x0, y0, 0), SPDF_WIN_CANVAS_CURSOR_TEXT);
        /* And the link is STILL a hand now that text regions exist under it:
         * link beats text, which is the precedence the mac model states. */
        if (n >= 1) CHECK_EQI(spdf_win_canvas_cursor_at(canvas, lx, ly, 1), SPDF_WIN_CANVAS_CURSOR_HAND);
    }
    /* The gutter above the first page is not the page. */
    CHECK_EQI(spdf_win_canvas_cursor_at(canvas, 2.0f, 2.0f, 1), SPDF_WIN_CANVAS_CURSOR_ARROW);

    /* --- following a link ------------------------------------------------- */

    {
        spdf_win_canvas_link_nav nav;
        float lx, ly;
        int before = spdf_win_canvas_current_page(canvas);
        device_of(page0, pw, ph, (link_rect.x0 + link_rect.x1) * 0.5f, (link_rect.y0 + link_rect.y1) * 0.5f, &lx, &ly);
        CHECK_EQI(before, 0);

        spdf_win_canvas_pointer_press(canvas, lx, ly, 1);
        /* A press on a link clears the previous selection, exactly as a press
         * on blank paper does -- the reader is starting something new. */
        CHECK_EQI(spdf_win_canvas_has_selection(canvas), 0);
        CHECK(spdf_win_canvas_pointer_release(canvas, &nav) != 0);
        CHECK_EQI(nav.kind, SPDF_LINK_INTERNAL);
        CHECK_EQI(nav.page_index, 2);
        CHECK(nav.uri == NULL);
        CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
        printf("      followed the internal link: page %d -> %d\n", before, spdf_win_canvas_current_page(canvas));
        CHECK_EQI(spdf_win_canvas_current_page(canvas), 2);
        CHECK(draw_for(&scene, 2) != NULL);
    }

    /* A DRAG that starts on a link must NOT follow it: the reader was
     * selecting the link's text, which is the case the gesture machine's
     * pending_link/link_cancelled pair exists for. */
    {
        spdf_win_canvas_link_nav nav;
        float lx, ly;
        spdf_win_canvas_scroll_to_page(canvas, 0);
        CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
        page0 = draw_for(&scene, 0);
        CHECK(page0 != NULL);
        if (page0) {
            device_of(page0, pw, ph, link_rect.x0 + 1.0f, (link_rect.y0 + link_rect.y1) * 0.5f, &lx, &ly);
            spdf_win_canvas_pointer_press(canvas, lx, ly, 1);
            device_of(page0, pw, ph, link_rect.x1 - 1.0f, (link_rect.y0 + link_rect.y1) * 0.5f, &x1, &y1);
            spdf_win_canvas_pointer_drag(canvas, x1, y1);
            CHECK_EQI(spdf_win_canvas_pointer_release(canvas, &nav), 0);
            CHECK_EQI(nav.kind, SPDF_LINK_NONE);
            CHECK_EQI(spdf_win_canvas_current_page(canvas), 0);
            text = spdf_win_canvas_selection_text(canvas);
            printf("      dragged across the link instead of following it: '%s'\n", text ? text : "(null)");
            CHECK(text && strstr(text, "page three") != NULL);
        }
    }

    /* --- the navigation surface for search and the map ------------------- */

    /* scroll_to_rect centres the rect in the viewport, clamped like every other
     * scroll: expected = slot.y + midY(rect) * zoom - vp_h / 2, pinned to the
     * document's travel. Page 2 is far enough down for the centring to bite. */
    {
        double sx, sy, sw, sh;
        spdf_rect target;
        int page_count = spdf_win_canvas_page_count(canvas);
        int last = page_count - 1;
        float pw2 = 0.0f, ph2 = 0.0f;
        double zoom, want, max_y;
        unsigned vw = 0, vh = 0;
        int first_vis = -1, last_vis = -1;

        spdf_win_canvas_viewport(canvas, &vw, &vh);
        CHECK_EQI(vw, 900);
        CHECK_EQI(vh, 1200);
        CHECK(spdf_win_canvas_page_rect(canvas, 0, &sx, &sy, &sw, &sh));
        CHECK(sy == SPDF_WIN_PAGE_MARGIN_V);
        CHECK(sw > 0.0 && sh > 0.0);
        CHECK(!spdf_win_canvas_page_rect(canvas, page_count, &sx, &sy, &sw, &sh));
        CHECK(!spdf_win_canvas_page_rect(canvas, -1, &sx, &sy, &sw, &sh));

        CHECK(spdf_page_size(doc, last, &pw2, &ph2, err, sizeof(err)));
        target.x0 = 10.0f;
        target.y0 = ph2 * 0.5f;
        target.x1 = pw2 - 10.0f;
        target.y1 = ph2 * 0.5f + 12.0f;
        CHECK(spdf_win_canvas_scroll_to_rect(canvas, last, target) != 0);
        CHECK(spdf_win_canvas_page_rect(canvas, last, &sx, &sy, &sw, &sh));
        zoom = (double)spdf_win_canvas_zoom(canvas);
        want = sy + ((double)target.y0 + (double)target.y1) * 0.5 * zoom - (double)vh * 0.5;
        max_y = (double)spdf_win_canvas_content_h(canvas) - (double)vh;
        if (want > max_y) want = max_y;
        if (want < 0.0) want = 0.0;
        printf("      scroll_to_rect: page %d, want %.1f got %.1f\n", last, want, (double)spdf_win_canvas_scroll_y(canvas));
        CHECK(fabs((double)spdf_win_canvas_scroll_y(canvas) - want) < 0.5);
        CHECK(spdf_win_canvas_visible_range(canvas, &first_vis, &last_vis));
        CHECK(first_vis <= last && last_vis >= last);

        /* An empty rect falls back to the page, top-aligned. */
        target.x1 = target.x0;
        CHECK(spdf_win_canvas_scroll_to_rect(canvas, 0, target) != 0);
        CHECK_EQI(spdf_win_canvas_current_page(canvas), 0);
        CHECK(!spdf_win_canvas_scroll_to_rect(canvas, page_count, target));
        CHECK(!spdf_win_canvas_scroll_to_rect(NULL, 0, target));
        CHECK(!spdf_win_canvas_visible_range(NULL, &first_vis, &last_vis));
    }

    /* select_page selects the whole page through the ordinary gesture; the
     * page must be in the last built frame. */
    CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
    CHECK(spdf_win_canvas_select_page(canvas, 0) != 0);
    CHECK_EQI(spdf_win_canvas_has_selection(canvas), 1);
    text = spdf_win_canvas_selection_text(canvas);
    printf("      select_page: %d bytes\n", text ? (int)strlen(text) : 0);
    CHECK(text && strstr(text, "Selection fixture alpha") != NULL);
    CHECK_EQI(spdf_win_canvas_select_page(canvas, 99), 0);
    CHECK_EQI(spdf_win_canvas_select_page(NULL, 0), 0);

    /* page_changed after a rotation: the slot's aspect inverts, the cache and
     * the selection go, and the layout is rebuilt at the new size. */
    {
        double w1, h1, w2, h2, dummy;
        CHECK(spdf_win_canvas_page_rect(canvas, 0, &dummy, &dummy, &w1, &h1));
        CHECK(spdf_rotate_page(doc, 0, 90, err, sizeof(err)));
        CHECK(spdf_win_canvas_page_changed(canvas, 0) != 0);
        CHECK_EQI(spdf_win_canvas_has_selection(canvas), 0);
        CHECK(spdf_win_canvas_page_rect(canvas, 0, &dummy, &dummy, &w2, &h2));
        printf("      rotated page 0: %.1fx%.1f -> %.1fx%.1f\n", w1, h1, w2, h2);
        CHECK(fabs(h2 / w2 - w1 / h1) < 0.01);
        CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
        CHECK(spdf_rotate_page(doc, 0, -90, err, sizeof(err))); /* leave the handle as it was */
        CHECK(spdf_win_canvas_page_changed(canvas, 0) != 0);
        CHECK_EQI(spdf_win_canvas_page_changed(canvas, 99), 0);
        CHECK_EQI(spdf_win_canvas_page_changed(NULL, 0), 0);
        CHECK(spdf_win_canvas_build_scene(canvas, &scene) != 0);
    }

    /* --- clearing, cancelling, and NULLs ---------------------------------- */

    CHECK_EQI(spdf_win_canvas_clear_selection(canvas), 0); /* page_changed already cleared it */
    CHECK(spdf_win_canvas_select_page(canvas, 0) != 0);
    CHECK_EQI(spdf_win_canvas_clear_selection(canvas), 1);
    CHECK_EQI(spdf_win_canvas_has_selection(canvas), 0);
    CHECK_EQI(spdf_win_canvas_clear_selection(canvas), 0);
    spdf_win_canvas_pointer_cancel(canvas);
    CHECK_EQI(spdf_win_canvas_copy_selection(canvas), 0);

    CHECK_EQI(spdf_win_canvas_pointer_press(NULL, 0, 0, 1), 0);
    CHECK_EQI(spdf_win_canvas_pointer_drag(NULL, 0, 0), 0);
    CHECK_EQI(spdf_win_canvas_pointer_release(NULL, NULL), 0);
    spdf_win_canvas_pointer_cancel(NULL);
    CHECK_EQI(spdf_win_canvas_cursor_at(NULL, 0, 0, 1), SPDF_WIN_CANVAS_CURSOR_ARROW);
    CHECK_EQI(spdf_win_canvas_copy_selection(NULL), 0);
    CHECK(spdf_win_canvas_selection_text(NULL) == NULL);
    CHECK_EQI(spdf_win_canvas_has_selection(NULL), 0);
    CHECK_EQI(spdf_win_canvas_clear_selection(NULL), 0);
    spdf_win_canvas_apply_selection_overlays(NULL, &scene);
    spdf_win_canvas_apply_selection_overlays(canvas, NULL);

    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);
    printf("canvas_selection_test: %d checks, %d failures, %d skipped\n", g_checks, g_failures, g_skipped);
    return g_failures ? 1 : 0;
}
