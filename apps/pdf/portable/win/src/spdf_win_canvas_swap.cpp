/* spdf_win_canvas_swap.cpp -- the one operation that changes the DOCUMENT under
 * a live viewport: spdf_win_canvas_replace_document().
 *
 * WHAT THIS IS THE PORT OF. macOS 26.9.4-1's in-place Markdown reload
 * (SPDFMacMarkdownSession+Reload.mm, +ViewSwap.mm: e6f900f7f, 301348473,
 * b44018932). There, a reload used to be a full reopen -- tear the session down,
 * show the placeholder, build a new view -- and the window blanked and came back
 * on every save. The fix was to treat a disk reload as a RERENDER whose source
 * is the file: render off the main thread, then install the result under the
 * reader's viewport with preserveCurrentState:YES, the outgoing view drawing the
 * last good frame until the incoming one is ready.
 *
 * On Windows the same shape falls out of the canvas's own rules. The expensive
 * part -- md4c, the HTML, MuPDF's layout -- is spdf_open_markdown(), which
 * spdf_win_md_reload.cpp runs on its own thread; the canvas meanwhile keeps
 * drawing the old document. This function is the "install": it swaps the handle
 * and everything derived from it, keeps the viewport, and paints nothing. The
 * next build_scene finds an empty cache and renders the visible page on the
 * calling thread, exactly as the first frame of a fresh canvas does
 * (spdf_win_canvas.cpp's header, guard 3: never without a stand-in, and when
 * there is none, render here). So there is no frame in which the canvas is
 * empty -- the mac's "held transparent while it settles" is, here, simply that
 * no empty frame is ever composed.
 *
 * WHAT IS KEPT AND WHAT GOES. Zoom mode, zoom and the scroll offset are kept
 * and re-clamped against the new layout: a Markdown document's pages are all
 * one sheet, so an offset into page 3 is the same place in the re-read file,
 * and where the document grew or shrank the clamp lands the reader as close as
 * the new pages allow. Page sizes are re-estimated from the new first page and
 * measured lazily as the viewport reaches them, as at create() -- EXCEPT the
 * pages the reader had already reached, which are measured again before the
 * relayout. The fit modes key on the current page (spdf_win_canvas_relayout),
 * so a current page left at page 0's estimate would fit the wrong sheet: a
 * mixed-size file re-read after an edit would jump 1.5x and the kept offset
 * would then land in another page. Measuring [0, measured) of the new document
 * costs one spdf_page_size() per page already seen and makes an identical
 * sheet lay out identically, to the pixel. Every cached
 * bitmap goes (they are the old text), the link regions go (old geometry), the
 * selection goes (old ranges), and the render workers are RESTARTED: their
 * per-thread handles are keyed on path alone (spdf_win_render.h's own note says
 * re-opening after a rewrite "belongs with the file watcher"), so a service that
 * outlived the swap would keep rendering the old bytes for every neighbour
 * prefetch. Freeing it delivers every outstanding request SHUTDOWN into the
 * canvas's adopt callback, which is why it happens while the canvas is whole,
 * as destroy() does; the new service carries the same notify trampoline, so a
 * shell's async arming (notify_armed, on the canvas) survives untouched.
 *
 * OWNERSHIP. create() borrows; this takes. The two never mix: the document the
 * canvas was created over stays the caller's whatever happens here, and the one
 * adopted here is closed on the next replace or on destroy. A document that
 * cannot be measured is refused with nothing taken, so the caller can keep
 * showing what it has -- the mac's "a read that fails keeps the last good render
 * on screen".
 */
#include "spdf_win_canvas_internal.h"

#include <stdlib.h>
#include <string.h>

int spdf_win_canvas_replace_document(spdf_win_canvas* canvas, spdf_document* doc) {
    int page_count, i, measured_before;
    float w = 0.0f, h = 0.0f;
    char err[128];
    SpdfWinPageSizePt* sizes;

    if (!canvas || !doc) return 0;
    measured_before = canvas->measured;
    page_count = spdf_page_count(doc);
    if (page_count <= 0) return 0;
    if (!spdf_page_size(doc, 0, &w, &h, err, sizeof(err)) || w <= 0.0f || h <= 0.0f) return 0;
    sizes = (SpdfWinPageSizePt*)calloc((size_t)page_count, sizeof(*sizes));
    if (!sizes) return 0;
    for (i = 0; i < page_count; ++i) {
        sizes[i].width = w;
        sizes[i].height = h;
    }

    /* The workers first, while the canvas is still whole: freeing the service
     * delivers each outstanding request SPDF_WIN_RENDER_SHUTDOWN into the
     * adopt callback, which touches the in-flight table. Then a fresh pool over
     * the same path, whose threads open the file as it is now. */
    spdf_win_render_service_free(canvas->service);
    canvas->service = spdf_win_render_service_new(canvas->path, NULL, SPDF_WIN_MAX_RENDER_SURFACE_BYTES,
                                                 spdf_win_canvas_render_notify, canvas);
    canvas->inflight_count = 0;

    /* The selection and the links are dropped BEFORE the handle changes, so
     * nothing that names the old document runs against the new one. */
    spdf_win_canvas_clear_selection(canvas);
    spdf_win_links_invalidate(canvas->links);
    spdf_win_lru_remove_all(&canvas->cache);

    if (canvas->owned_doc) spdf_close(canvas->owned_doc);
    canvas->owned_doc = doc;
    canvas->doc = doc;
    free(canvas->sizes);
    canvas->sizes = sizes;
    canvas->page_count = page_count;
    canvas->measured = 1;
    canvas->status[0] = 0;

    /* The pages the reader had reached are measured for real before the
     * relayout: the fit is keyed on the current page, and an estimate there
     * (page 0's sheet) would re-derive the wrong zoom and move the offset into
     * another page. ensure_measured() clamps `through` to the new page count,
     * so a document that shrank measures what it has. */
    if (measured_before > 1) spdf_win_canvas_ensure_measured(canvas, measured_before - 1);

    /* Zoom mode, zoom and scroll offset are untouched; the relayout re-derives
     * a fit zoom from the current page's (now measured) size and clamps the
     * offset into the new document, which is what keeps the reader's place. */
    spdf_win_canvas_relayout(canvas);
    return 1;
}
