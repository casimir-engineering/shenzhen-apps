/* The continuous scrolling document canvas -- Phase 2's model layer.
 *
 * This is the piece that turns "a window showing page 1" into "a document":
 * every page stacked on one vertical strip, a scroll offset, a zoom with fit
 * modes and cursor anchoring, and a render cache that only ever holds pages
 * somebody can actually see.
 *
 * IT OWNS NO WIN32 AND NO DIRECT2D. It takes a spdf_document and a viewport
 * size in device pixels, and it produces a spdf_win_scene -- a list of page
 * bitmaps with destination rectangles. spdf_win_window.cpp feeds it input,
 * spdf_win_d2d.cpp draws what it produces, and neither of those two files
 * knows how a page is placed. That split is what lets the headless probe and
 * the real window scroll to the same pixel: spdf_win_main.cpp's
 * --render-window-png drives this same canvas with no HWND in sight.
 *
 * Geometry comes from T3's spdf_win_layout.h, the page cache is T3's
 * spdf_win_lru, and neighbour prefetch runs on T5's spdf_win_render worker
 * pool. Nothing here re-derives any of the three. The page under the viewport
 * renders synchronously unless a shell arms
 * spdf_win_canvas_set_async_visible() -- and even then never on the first
 * frame (unless that frame was given a budget,
 * spdf_win_canvas_set_first_frame_budget), and never without a stand-in to
 * draw. See the .cpp's header.
 *
 * `path` is the document's UTF-8 path, used only to give the render workers
 * something to open (the core allows one spdf_document per thread, so they
 * cannot share ours). NULL disables prefetch; everything still works, just on
 * the calling thread.
 */
#ifndef SPDF_WIN_CANVAS_H
#define SPDF_WIN_CANVAS_H

#include "spdf_win_d2d.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_win_canvas spdf_win_canvas;

typedef enum spdf_win_zoom_mode {
    SPDF_WIN_ZOOM_FREE = 0,       /* whatever zoom was last set */
    SPDF_WIN_ZOOM_FIT_WIDTH = 1,  /* page width fills the viewport; re-fits on resize */
    SPDF_WIN_ZOOM_FIT_PAGE = 2,   /* whole page visible */
    SPDF_WIN_ZOOM_ACTUAL = 3,     /* 1 PDF point = 1 logical pixel, times the DPI scale */
    /* Page HEIGHT fills the viewport, letting a wide sheet overflow sideways.
     * macOS's fit popup has offered this from the start (SPDFFitModeHeight,
     * ShenzhenPDFMac.mm:3006-3011) and spdf_win_layout.h has carried the
     * arithmetic for it since the layout port (spdf_win_fit_height_zoom); only
     * this enum was missing, so the toolbar's fit cycle silently skipped one of
     * macOS's four items. Numbered last so no persisted or scripted value moves. */
    SPDF_WIN_ZOOM_FIT_HEIGHT = 4
} spdf_win_zoom_mode;

/* Borrows `doc` -- the caller keeps ownership and must outlive the canvas.
 * Cheap: it reads page 1's size and NOTHING else, because that is all the
 * first frame needs and launch time is the product's headline promise. Sizes
 * for later pages are measured as the viewport reaches them. */
spdf_win_canvas* spdf_win_canvas_create(spdf_document* doc, const char* path, unsigned render_flags, char* err,
                                        size_t err_len);
void spdf_win_canvas_destroy(spdf_win_canvas* canvas);

/* Viewport in DEVICE PIXELS, plus the display's device-pixels-per-logical-pixel.
 * Idempotent: relaying out only happens when something actually changed. A
 * resize under a fit mode re-derives the zoom and keeps the anchored page. */
void spdf_win_canvas_set_viewport(spdf_win_canvas* canvas, unsigned px_w, unsigned px_h, float dpi_scale);

void spdf_win_canvas_set_zoom_mode(spdf_win_canvas* canvas, spdf_win_zoom_mode mode);
spdf_win_zoom_mode spdf_win_canvas_zoom_mode(const spdf_win_canvas* canvas);
float spdf_win_canvas_zoom(const spdf_win_canvas* canvas);

/* Multiplies the zoom by `factor`, keeping the document point currently under
 * viewport pixel (vx, vy) under that same pixel afterwards. This is the
 * operation Ctrl+wheel and pinch perform, and the one the zoom-anchor test
 * checks: the anchor is captured in document space (page + PDF point), so it
 * stays exact even when the render byte cap shrinks the texture. Switches the
 * zoom mode to FREE. */
void spdf_win_canvas_zoom_at(spdf_win_canvas* canvas, float factor, float vx, float vy);
void spdf_win_canvas_set_zoom_at(spdf_win_canvas* canvas, float zoom, float vx, float vy);

/* Scrolling, in viewport device pixels. Both clamp to the scrollable range;
 * scroll_by returns non-zero when the offset actually moved, so the window can
 * skip an invalidate that would repaint identical pixels. */
int spdf_win_canvas_scroll_by(spdf_win_canvas* canvas, float dx, float dy);
int spdf_win_canvas_scroll_to(spdf_win_canvas* canvas, float x, float y);
/* Puts the top of `page_index` at the top of the viewport (minus the slot
 * margin), measuring intervening pages as needed. */
int spdf_win_canvas_scroll_to_page(spdf_win_canvas* canvas, int page_index);

/* --- navigation for search and the map (spdf_win_find_canvas.cpp) ----------
 *
 * CENTRE A PAGE RECT IN THE VIEWPORT -- what stepping to a find match does on
 * macOS (scrollToPageRect:pageIndex:, ShenzhenPDFMac.mm:10680-10709): the
 * match's rect is mapped through the page's slot at the current zoom and the
 * viewport origin is set to its centre minus half the viewport, both axes, then
 * clamped like every other scroll. `rect` is in page space (PDF points, y down,
 * the space the core returns match rects in). An empty rect falls back to
 * scroll_to_page, as macOS does. Returns non-zero when the offset moved. */
int spdf_win_canvas_scroll_to_rect(spdf_win_canvas* canvas, int page_index, spdf_rect rect);

/* A page's slot in the CONTINUOUS layout, in content pixels at the current zoom
 * -- the same rects build_scene draws from, before the scroll offset is taken
 * off. Pages the viewport has not reached carry page 0's size as an estimate
 * (spdf_win_canvas_internal.h explains why launch measures one page). Returns
 * 0 when the page is out of range. What the minimap's document<->strip mapping
 * and the nearest-match search consume. */
int spdf_win_canvas_page_rect(const spdf_win_canvas* canvas, int page_index, double* x, double* y, double* w,
                              double* h);
/* The viewport size in device pixels, as last set. */
void spdf_win_canvas_viewport(const spdf_win_canvas* canvas, unsigned* w, unsigned* h);
/* The pages whose slots intersect the viewport, inclusive. Falls back to the
 * current page when the layout has nothing in range. Returns 0 with no canvas. */
int spdf_win_canvas_visible_range(const spdf_win_canvas* canvas, int* first, int* last);

/* ONE PAGE CHANGED SHAPE -- rotated by spdf_rotate_page. Re-measures it, drops
 * every cached bitmap (the old ones are the old orientation), invalidates the
 * in-flight prefetches, the link regions and the selection, and rebuilds the
 * layout. Returns non-zero. The document itself was changed by the caller; the
 * canvas only re-learns it. */
int spdf_win_canvas_page_changed(spdf_win_canvas* canvas, int page_index);

/* THE WHOLE DOCUMENT CHANGED UNDER THE CANVAS -- a Markdown file re-read after
 * it changed on disk (spdf_win_md_reload.h), or any other re-open of the same
 * path. The canvas keeps its viewport: zoom mode, zoom and scroll offset stay
 * where they were and are clamped to the new document, so the reader's place
 * survives (the mac's preserveCurrentState:YES). Page sizes are re-estimated
 * from the new first page and measured lazily as before; every cached bitmap
 * goes, the in-flight renders are superseded, the link regions and the
 * selection are dropped, and the render workers are restarted so their handles
 * re-open the path -- they are keyed on path alone (spdf_win_render.h) and
 * would otherwise keep rendering the old bytes.
 *
 * NO EMPTY FRAME, by construction: nothing here paints. The old document keeps
 * drawing until this returns, and the next build_scene finds an empty cache and
 * renders the visible page on the calling thread, exactly as the first frame of
 * a fresh canvas does -- the compose layer never sees a hole.
 *
 * OWNERSHIP: unlike create(), this TAKES `doc`; it is closed when replaced again
 * or when the canvas is destroyed. The document create() was given stays the
 * caller's, untouched -- the caller decides when the old bytes go. Returns 0,
 * taking nothing, for a NULL or empty document, so the caller can keep what it
 * has on screen. Implemented in spdf_win_canvas_swap.cpp. */
int spdf_win_canvas_replace_document(spdf_win_canvas* canvas, spdf_document* doc);

/* SELECT EVERY GLYPH ON A PAGE (Edit > Select All). Runs the ordinary range
 * gesture from the page's top-left to its bottom-right through the same three
 * calls the pointer uses, so what Ctrl+A selects is exactly what a drag across
 * the whole page would. The page must be in the last built frame -- the
 * selection model hit-tests against what was drawn, by design. Returns non-zero
 * when the visible selection changed. */
int spdf_win_canvas_select_page(spdf_win_canvas* canvas, int page_index);

/* WHAT A SCROLLBAR NEEDS, and nothing else: two fractions per axis plus whether
 * the content overflows sideways at all.
 *
 * FRACTIONS, NOT OFFSETS, and that is the whole point of this call existing
 * rather than the chrome dividing scroll_y by content_h itself. `visible` is
 * viewport/content, which IS the thumb's proportional length, and `pos` is
 * offset/(content - viewport), which IS where the thumb sits in its travel. Both
 * are unitless, so spdf_win_chrome_scroll.h needs no notion of a PDF point, a
 * zoom or a page -- and neither can be got wrong by a caller that does not know
 * the canvas measures page heights lazily.
 *
 * `h_scrollable` says whether there is anything to drag SIDEWAYS, which is not
 * the same question as "is the content wider than the viewport". The canvas is
 * always at least `widest page + 2 * 22 pt` wide, so at fit width the content
 * permanently overflows by 44 px -- and spdf_win_hscroll_clamp then pins a page
 * that fits the viewport CENTRED, so the offset never moves. A trough drawn
 * from the overflow alone would therefore be present on every ordinary document
 * with a thumb nobody can move. So this reports the CURRENT PAGE's pan range,
 * which is exactly what the clamp permits, and the horizontal `pos`/`visible`
 * are measured against that same page. (This does not contradict
 * spdf_win_layout.h:349-355: that warns against keying the canvas's WIDTH on
 * the current page, which nothing here does.)
 *
 * It decides whether a horizontal trough exists at all, so painter and hit-test
 * must both take it from here and from nowhere else. */
typedef struct spdf_win_canvas_scroll {
    float v_pos;
    float v_visible;
    float h_pos;
    float h_visible;
    int h_scrollable;
} spdf_win_canvas_scroll;

/* Always fully written, so a caller may read every field after any call. A NULL
 * canvas yields "nothing to scroll": both fractions 0 and both `visible` 1,
 * which spdf_win_chrome_scroll.h draws as a full-length thumb -- the honest
 * picture of a window with no document. */
void spdf_win_canvas_scroll_state(const spdf_win_canvas* canvas, spdf_win_canvas_scroll* out);

/* Scroll one axis to a fraction in [0,1] of its travel -- the inverse of the
 * `pos` above, and what a thumb drag performs. Returns non-zero when the offset
 * actually moved. Clamps like every other scroll entry point. */
int spdf_win_canvas_scroll_to_fraction(spdf_win_canvas* canvas, int vertical, float pos);

float spdf_win_canvas_scroll_x(const spdf_win_canvas* canvas);
float spdf_win_canvas_scroll_y(const spdf_win_canvas* canvas);
float spdf_win_canvas_content_w(const spdf_win_canvas* canvas);
float spdf_win_canvas_content_h(const spdf_win_canvas* canvas);
int spdf_win_canvas_page_count(const spdf_win_canvas* canvas);
/* The page whose centre is nearest the viewport's middle -- what a page
 * indicator would show, and what the horizontal clamp policy keys on. */
int spdf_win_canvas_current_page(const spdf_win_canvas* canvas);

/* Fills `scene` with every page intersecting the viewport, rendering the ones
 * that are not cached. `scene`'s target_px_w/h, dpi_scale and dark are set
 * from the canvas. The page list it points at stays valid until the next call
 * on this canvas. Returns non-zero when there is something to draw. */
int spdf_win_canvas_build_scene(spdf_win_canvas* canvas, spdf_win_scene* scene);

/* RENDER THE VISIBLE PAGE OFF-THREAD TOO, from the next frame on.
 *
 * Off by default, and every headless path leaves it off, which is what keeps
 * --render-window-png and the d2d.compose cases byte-identical by construction.
 * A windowed shell arms it once, right after creating the canvas; the FIRST
 * frame is still rendered on the calling thread whatever this says, so a launch
 * still paints a complete window before ShowWindow. Read spdf_win_canvas.cpp's
 * header before changing any of that: the three guards are the design.
 *
 * `ready` is called ON A WORKER THREAD when a render becomes drainable, and
 * must be cheap and thread-safe -- PostMessage(hwnd, ..., 0, 0) is the intended
 * implementation, and it is REQUIRED rather than optional: without it a bitmap
 * lands and nothing asks for the repaint that would show it, so the reader
 * keeps looking at the soft stand-in until they move the mouse. The next paint
 * adopts it, as it always did.
 *
 * WRITE-ONCE. The pair is published to the worker with one interlocked store
 * and never rewritten, so a call with a DIFFERENT hook changes nothing at all:
 * the canvas keeps the hook it has and stays armed, because silently turning
 * async off would be a worse surprise than ignoring a call that should not have
 * been made. `ready` NULL turns async off and leaves the hook in place, so
 * re-arming with the same hook works. One shell, one canvas, one arming -- and
 * a canvas dies with its tab. */
void spdf_win_canvas_set_async_visible(spdf_win_canvas* canvas, void (*ready)(void*), void* ready_ctx);

/* HOW LONG THE FIRST FRAME MAY TAKE, in milliseconds; 0 (the default) means no
 * bound at all, which is what every headless path keeps.
 *
 * The first frame of a fresh document has nothing in the cache and no stand-in
 * to draw, so it renders on the calling thread however long that takes, and a
 * launch paints it BEFORE ShowWindow so the window appears complete. On a page
 * with 400,000 stroked paths that is 4.5 s (2,000,000: 35 s) with NO WINDOW ON
 * SCREEN, the process IsHungAppWindow-hung, which is exactly the report this
 * bound exists for (windows-native-observations.md sections 16 and 18).
 *
 * With a budget set, and only with async armed first, the first frame ASKS the
 * pool for its page and waits that long for it. Inside the budget nothing
 * changes: the same pixels, from the same render, before the same ShowWindow.
 * Past it the frame comes back with NO page draws and the canvas's status line
 * instead ("Opening…"), the window goes up enabled and answering, and the
 * `ready` hook above brings the page in when it lands. The invariant that a
 * frame never has a HOLE in it is kept by dropping the draw rather than
 * drawing an empty one -- a missing page is a message, not a blank slot.
 *
 * Set it on the LAUNCH path only, before the first paint. A canvas whose first
 * frame is already built ignores it. */
void spdf_win_canvas_set_first_frame_budget(spdf_win_canvas* canvas, int ms);

/* 250 ms. Longer than the whole healthy launch this port measures -- 194 ms
 * from process creation to the first composed frame, of which the page render
 * is 39 ms -- so no launch that is fast today waits any differently; and short
 * enough that the worst case is a window in about a third of a second rather
 * than one in nine seconds. Justified with numbers in section 18 of
 * portable/docs/windows-native-observations.md; move it with a measurement. */
#define SPDF_WIN_CANVAS_FIRST_FRAME_BUDGET_MS 250

/* Bytes currently held by the page-bitmap cache. For the render-budget check;
 * never used to make a drawing decision. */
size_t spdf_win_canvas_cache_bytes(const spdf_win_canvas* canvas);
/* How many pages the LAST build_scene had to render on the calling thread. 0
 * means every visible page came from the cache -- which, after a scroll onto a
 * new page, is the observable proof that prefetch did its job. */
int spdf_win_canvas_sync_renders(const spdf_win_canvas* canvas);
/* How many pages the LAST build_scene drew from a NEARBY zoom because the exact
 * one was still rendering. Non-zero means the frame is provisional: it is the
 * right content at the wrong resolution, and the `ready` hook above will ask for
 * the repaint that replaces it. 0 in a synchronous canvas, always. */
int spdf_win_canvas_stale_draws(const spdf_win_canvas* canvas);
/* How many renders the worker pool has started. Diagnostic only. */
unsigned long long spdf_win_canvas_prefetched(spdf_win_canvas* canvas);

/* HEADLESS ONLY. Drains completions, waiting up to timeout_ms for outstanding
 * prefetches, and returns how many were adopted. A window must never call this
 * -- it drains as it paints, and blocking the UI thread on a prefetch gives
 * back the stall the prefetch exists to remove. It exists so a probe can make
 * a multi-frame scroll deterministic. */
int spdf_win_canvas_settle(spdf_win_canvas* canvas, int timeout_ms);

/* --- text selection and links -------------------------------------------
 *
 * THE WHOLE INPUT SURFACE THE SHELL HAS TO WIRE, and deliberately no more: six
 * calls, all of them taking CANVAS-LOCAL DEVICE PIXELS and nothing else. No
 * HWND, no document, no page number, no PDF point crosses this line, so the
 * input router can stay a router. spdf_win_selection.h and spdf_win_links.h
 * hold the model; this is the canvas binding it to its own geometry.
 *
 * Everything here runs on the UI thread against the canvas's own document
 * handle, which is the thread that owns it (shenzhen_pdf_core.c:40-43).
 * Nothing here needs a window, so the headless probe drives the same calls.
 *
 * Each of the three pointer calls returns non-zero when the VISIBLE selection
 * changed, i.e. when the caller should invalidate. */

typedef enum spdf_win_canvas_cursor {
    SPDF_WIN_CANVAS_CURSOR_ARROW = 0, /* IDC_ARROW  */
    SPDF_WIN_CANVAS_CURSOR_TEXT = 1,  /* IDC_IBEAM  */
    SPDF_WIN_CANVAS_CURSOR_HAND = 2   /* IDC_HAND   */
} spdf_win_canvas_cursor;

/* What a release wants done about a link, if anything. `uri` is borrowed and
 * valid until the next pointer call on this canvas. An INTERNAL target has
 * ALREADY been scrolled to by the time this is filled -- the canvas can do that
 * itself and the shell would only be forwarding it back. A URI target is NOT
 * opened here: launching a browser is a shell decision with a shell's security
 * questions, and the canvas has no business making it. */
typedef struct spdf_win_canvas_link_nav {
    int kind;        /* spdf_link_kind: NONE / URI / INTERNAL */
    int page_index;  /* INTERNAL only: the page scrolled to */
    const char* uri; /* URI only: borrowed UTF-8 */
} spdf_win_canvas_link_nav;

/* `click_count` is the accumulated count for a multi-click series (1, 2, 3...).
 * Win32 does not accumulate it: WM_LBUTTONDBLCLK is the SECOND click, so the
 * router counts, and a triple click is a WM_LBUTTONDOWN inside
 * GetDoubleClickTime() of a WM_LBUTTONDBLCLK. Two selects a word, three or more
 * selects the block. */
int spdf_win_canvas_pointer_press(spdf_win_canvas* canvas, float x, float y, unsigned click_count);
/* Only meaningful while a button is down; a no-op otherwise. */
int spdf_win_canvas_pointer_drag(spdf_win_canvas* canvas, float x, float y);
/* `out_nav` may be NULL. */
int spdf_win_canvas_pointer_release(spdf_win_canvas* canvas, spdf_win_canvas_link_nav* out_nav);
/* Capture lost, or Escape: ends the gesture, keeps a completed selection. */
void spdf_win_canvas_pointer_cancel(spdf_win_canvas* canvas);

/* Which cursor belongs at this point. `want_text_cursor` asks for the I-beam
 * over text, which costs one structured-text pass per page visited (see
 * spdf_win_links.h); 0 answers hand-or-arrow for free. */
spdf_win_canvas_cursor spdf_win_canvas_cursor_at(spdf_win_canvas* canvas, float x, float y, int want_text_cursor);

/* Copy the selection to the clipboard as CF_UNICODETEXT. Returns 1 when
 * something was copied. NO PERMISSION GATE, by product decision -- see
 * spdf_win_selection.h section 5 and shenzhen_pdf_core.h:209-214. */
int spdf_win_canvas_copy_selection(spdf_win_canvas* canvas);
/* Borrowed UTF-8, NULL when nothing is selected. */
const char* spdf_win_canvas_selection_text(const spdf_win_canvas* canvas);
/* The selection's rects in PAGE space (PDF points, y down) and the page they
 * are on -- exactly what spdf_add_highlight_comment takes, which is the one
 * caller (the annotations track). Copies up to `max`; returns the count, 0
 * with no selection (page_index then -1). */
int spdf_win_canvas_selection_rects(const spdf_win_canvas* canvas, int* page_index, spdf_rect* rects, int max);
int spdf_win_canvas_has_selection(const spdf_win_canvas* canvas);
/* Returns non-zero when something was actually cleared. */
int spdf_win_canvas_clear_selection(spdf_win_canvas* canvas);

/* THE SECOND OVERLAY PRODUCER. Call it AFTER spdf_win_canvas_build_scene() and
 * AFTER spdf_win_find_apply_overlays(): it takes whatever overlays the scene
 * already carries as a base, appends the selection's rects, and re-points the
 * scene at the combined array. Selection last is macOS's own draw order
 * (SPDFMacDocumentView.mm :467 highlights, :475 active ring, :485 selection),
 * and it leaves find's "the active ring is the last thing I emit" contract
 * intact. See spdf_win_selection.h section 4 for why this shape rather than one
 * combined producer. A no-op when nothing is selected. */
void spdf_win_canvas_apply_selection_overlays(spdf_win_canvas* canvas, spdf_win_scene* scene);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_CANVAS_H */
