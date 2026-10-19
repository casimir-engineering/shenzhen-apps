/* spdf_win_links.h — link hit-testing, link navigation, and the cursor regions
 * that decide between an arrow, an I-beam and a hand.
 *
 * SECTION 1 IS A TRANSCRIPTION. The cursor-region model is ported from
 * portable/linux/gtk4/spdf_docview_internal.h (spdf_cursor_rect_empty,
 * spdf_cursor_rect_contains, spdf_cursor_region_at_point and the two constants
 * beside them), which is itself a port of portable/mac/SPDFMacCursorRegions.mm.
 * portable/win/tests/selection_differential.c compiles the real GTK header
 * under portable/win/tests/glib_shim and compares the two exhaustively --
 * boundaries, slop, empty rects, link-beats-text precedence and NaN -- because
 * that discipline has already caught a one-ulp transcription error in this
 * port. Do not "improve" any of it in place; fix it in all three or in none.
 *
 * SECTION 2 IS THIS PORT'S OWN, and its one interesting decision is WHERE THE
 * EXPENSIVE SCAN RUNS:
 *
 *   Hover asks about links on every mouse move, so hover must be cheap. The
 *   UI thread builds its link rects with detect_text_links = 0, which reads the
 *   page's link ANNOTATIONS only. spdf_page_link_rects's own header says to do
 *   exactly that -- "pass 0 for hover/cursor hit-testing and 1 only when
 *   actually following a link on click" -- because detecting plain-text URLs
 *   builds the whole structured-text page and costs hundreds of milliseconds on
 *   a dense one.
 *
 *   The plain-text URLs come from a WORKER THREAD with a document handle of its
 *   own (the core allows one spdf_document per thread and locks nothing inside
 *   it, shenzhen_pdf_core.c:40-43), which is what macOS and GTK both do. The
 *   cache asks for the page the pointer is over, the worker runs the
 *   structured-text pass once for it, and the UI thread merges the full set --
 *   annotations plus text URLs -- on the next hover, at which point a bare URL
 *   printed in the text shows the hand exactly as an annotation does. Until it
 *   lands the URL is still CLICKABLE: the click path resolves the target itself
 *   with detect_text_links = 1, once, and never waits for the worker.
 *
 *   spdf_win_links_set_source() gives the cache the path the worker opens;
 *   without one there is no worker and hover shows annotations only, which is
 *   the headless probe's case.
 *
 * SECTIONS 3 AND 4 ARE TRANSCRIPTIONS AGAIN, of the two halves of macOS's link
 * activation: where an internal jump lands
 * (spdf_mac_link_destination_scroll_origin_y) and the counter that lets a
 * second click cancel a link about to leave the document
 * (SPDFMacDelayedLinkActivation). Both are pure and both are pinned against the
 * mac unit tests' own numbers and scenarios -- see each section.
 *
 * Every function here is main-thread, against the caller's own document handle;
 * the worker's handle is its own and never escapes spdf_win_links.cpp.
 */
#ifndef SPDF_WIN_LINKS_H
#define SPDF_WIN_LINKS_H

#include "shenzhen_pdf_core.h"
#include "spdf_win_layout.h" /* SPDF_WIN_INLINE, SPDF_WIN_PAGE_MARGIN_V, <math.h> */

#include <string.h> /* memcpy/strlen, for the deferred activation's URI copy */

#ifdef __cplusplus
extern "C" {
#endif

/* --- 1. cursor regions (transcribed from GTK4) ---------------------------- */

/* Matches spdf_link_at_point's 2 pt text-URL slop (mac kSPDFCursorLinkHitPadding),
 * so what hover shows as a hand is exactly what a click follows. */
#define SPDF_WIN_CURSOR_LINK_HIT_PADDING 2.0
/* mac kSPDFCursorRegionMaxLinkRects. */
#define SPDF_WIN_CURSOR_REGION_MAX_LINK_RECTS 512

typedef enum SpdfWinCursorRegionKind {
    SPDF_WIN_CURSOR_REGION_NONE = 0,
    SPDF_WIN_CURSOR_REGION_LINK,
    SPDF_WIN_CURSOR_REGION_TEXT
} SpdfWinCursorRegionKind;

static SPDF_WIN_INLINE int spdf_win_cursor_rect_empty(const spdf_rect* rect) {
    return !rect || rect->x1 <= rect->x0 || rect->y1 <= rect->y0;
}

/* Merge policy for the built region arrays (mac
 * buildCursorRegionsForPageIfNeeded skips NSIsEmptyRect rects): only non-empty
 * rects enter the cache, so a degenerate rect from the core can never own a hit
 * test. Returns 1 when the rect was appended. GTK's counterpart appends into a
 * GArray; this one takes an explicit array, count and capacity, which is the
 * only difference and is a container change, not a policy one. */
static SPDF_WIN_INLINE int spdf_win_cursor_region_append_rect(spdf_rect* rects, int* count, int capacity,
                                                              const spdf_rect* rect) {
    if (!rects || !count || *count >= capacity) return 0;
    if (spdf_win_cursor_rect_empty(rect)) return 0;
    rects[(*count)++] = *rect;
    return 1;
}

static SPDF_WIN_INLINE int spdf_win_cursor_rect_contains(const spdf_rect* rect, double x, double y, double slop) {
    return rect && x >= rect->x0 - slop && x <= rect->x1 + slop && y >= rect->y0 - slop && y <= rect->y1 + slop;
}

/* Link beats text beats none (SPDFMacCursorRegions.mm spdf_cursor_region_at_point);
 * only link rects get the padding slop. */
static SPDF_WIN_INLINE SpdfWinCursorRegionKind spdf_win_cursor_region_at_point(const spdf_rect* links,
                                                                               unsigned link_count,
                                                                               const spdf_rect* text,
                                                                               unsigned text_count, double x, double y,
                                                                               double link_padding) {
    unsigned i;
    for (i = 0; i < link_count; ++i)
        if (spdf_win_cursor_rect_contains(&links[i], x, y, link_padding)) return SPDF_WIN_CURSOR_REGION_LINK;
    for (i = 0; i < text_count; ++i)
        if (spdf_win_cursor_rect_contains(&text[i], x, y, 0.0)) return SPDF_WIN_CURSOR_REGION_TEXT;
    return SPDF_WIN_CURSOR_REGION_NONE;
}

/* --- 2. the per-page region cache ----------------------------------------- */

/* One page's regions at a time. A reader's pointer is over one page; caching
 * more would buy nothing and would have to be invalidated on the same events.
 * Rebuilding costs one fz_load_links (cheap) plus, when text regions are
 * wanted, one structured-text pass over the page (not cheap -- see below). */
typedef struct spdf_win_links spdf_win_links;

spdf_win_links* spdf_win_links_new(void);
/* Joins the worker, bounded by one structured-text pass. */
void spdf_win_links_free(spdf_win_links* links);
/* Drop everything cached. Call when the document is replaced or reloaded, or a
 * page changed shape. A worker result in flight for the old page is ignored. */
void spdf_win_links_invalidate(spdf_win_links* links);

/* The document's UTF-8 path, copied, for the text-URL worker's own handle. Set
 * once, before the first ensure; later calls are ignored. NULL or empty means
 * no worker -- annotation links only, which is what the headless paths get. */
void spdf_win_links_set_source(spdf_win_links* links, const char* utf8_path);

/* Has the worker's full link set for the cached page been merged in? For the
 * test that waits for the hand; nothing in the app needs to ask. */
int spdf_win_links_text_urls_ready(const spdf_win_links* links);

/* WHAT `want_text_regions` COSTS. The link half is fz_load_links: microseconds,
 * and safe on every mouse move. The text half is spdf_extract_page_text_lines,
 * which builds the page's structured text -- tens of milliseconds on a dense
 * page, once per page, cached until the pointer leaves it. It buys the I-beam
 * over text, which is the difference between a canvas that looks selectable and
 * one that does not. Pass 0 and the cursor is a plain arrow over text.
 *
 * THE FLAG CONTROLS BUILDING, NOT ANSWERING. Once a page's text regions exist
 * they stay until the pointer leaves that page, and a later query with
 * want_text_regions = 0 still gets the I-beam from them -- throwing away work
 * already paid for, only to rebuild it on the next move, would be the expensive
 * choice dressed up as the cheap one.
 *
 * `doc` MUST BELONG TO THE CALLING THREAD (shenzhen_pdf_core.c:40-43). Returns
 * 1 when the page's regions are available. */
int spdf_win_links_ensure_page(spdf_win_links* links, spdf_document* doc, int page_index, int want_text_regions);

/* The cursor's answer for a PAGE POINT (PDF points, y down -- the space
 * spdf_win_selection.h documents). Builds the page's regions if needed. */
SpdfWinCursorRegionKind spdf_win_links_region_at(spdf_win_links* links, spdf_document* doc, int page_index,
                                                 int want_text_regions, float x, float y);

/* Is there a link under this page point? The cheap question, answered from the
 * cached annotation rects with the 2 pt slop, for the press path -- which has
 * to decide "range candidate or link candidate" before it can do anything
 * else. */
int spdf_win_links_hit(spdf_win_links* links, spdf_document* doc, int page_index, float x, float y);

/* --- 3. following one ----------------------------------------------------- */

/* Resolve the link under a page point, WITH plain-text URL detection, because
 * this only runs on an actual click. Returns 1 and fills `out` (owned: free it
 * with spdf_free_link_target) when a link is there, 0 when there is none, -1 on
 * error. */
int spdf_win_links_target_at(spdf_document* doc, int page_index, float x, float y, spdf_link_target* out);

/* WHERE AN INTERNAL LINK LANDS. The core hands back the target page plus a
 * point from fz_resolve_link, and this port TOP-ALIGNS THE DESTINATION'S OWN Y
 * in the viewport -- the two functions below are the whole of it.
 *
 * TRANSCRIBED from spdf_mac_link_destination_scroll_origin_y
 * (portable/mac/SPDFMacPageRendering.mm:45-51), reached through
 * scrollToLinkDestinationOnPage:pageY: and pinned on that side by
 * portable/mac/tests/SPDFMacSelectionClickTests.mm's
 * test_link_destination_scroll_is_target_page_top. Same three inputs, same
 * three rules: scale the destination's offset by the zoom, ignore an offset
 * that is not positive, and clamp at the document top.
 *
 * TOP-ALIGNED AND NOT CENTRED, which is the decision the mac file argues at
 * length: centring the destination (what spdf_win_canvas_scroll_to_rect does
 * for a find hit, correctly) hangs half a viewport of the PRECEDING page above
 * the thing the reader asked to see, and makes the resulting offset depend on
 * page N-1's height. Top alignment depends on the TARGET page's slot and the
 * destination's own y, and nothing else.
 *
 * THE LEAD-IN IS THIS PLATFORM'S OWN NUMBER. macOS subtracts
 * kSPDFPageTopScrollLeadIn (12 pt); this port subtracts SPDF_WIN_PAGE_MARGIN_V
 * (13 px), because that is what spdf_win_canvas_scroll_to_page() subtracts and
 * the invariant that matters is the one mac's own comment states: A DESTINATION
 * WITH NO OFFSET MUST LAND EXACTLY WHERE "GO TO PAGE N" LANDS. The two gutters
 * differ by a pixel; the equality does not.
 *
 * WHICH WAY UP THE Y IS, measured rather than assumed and pinned by
 * portable/win/tests/link_test.c: fz_resolve_link's y arrives in PAGE space, y
 * DOWN -- the same space as every rect here, and NOT the bottom-left PDF user
 * space that spdf_outline_item.dest_y documents for outline entries. The two
 * differ, so nothing here borrows the outline code's flip. */

/* The destination's offset down its target page, in PDF points, or 0 when the
 * link names only a page. mac's `hasDestinationY` is
 * `isfinite(target.x) && isfinite(target.y)` -- BOTH axes, because
 * fz_resolve_link fills them together and a half-finite point is a point the
 * core could not resolve. And that guard EARNS ITS KEEP: a /Fit-style
 * destination carries no point, and link_destination_test.c MEASURES what
 * fz_resolve_link reports for one -- (nan, nan), not (0, 0). Only the isfinite
 * pair sends that to the page's start; a `> 0.0` test on y alone would too, but
 * only by accident of how NaN compares. */
static SPDF_WIN_INLINE double spdf_win_link_destination_page_y(const spdf_link_target* target) {
    if (!target || target->kind != SPDF_LINK_INTERNAL) return 0.0;
    if (!isfinite((double)target->x) || !isfinite((double)target->y)) return 0.0;
    return (double)target->y;
}

/* The canvas scroll offset that puts `destination_page_y` at the top of the
 * viewport, given the target page's slot y in CONTENT PIXELS at `zoom` (what
 * spdf_win_canvas_page_rect reports) and `destination_page_y` in PDF points
 * (what spdf_win_link_destination_page_y returns).
 *
 * The MAX(0, ...) mirrors mac's; spdf_win_canvas_scroll_to() would clamp
 * anyway, and a destination past the document's end clamps there too. A
 * non-positive offset -- a page-only destination, or a negative y from a
 * malformed dest -- cannot pull the preceding page into view. */
static SPDF_WIN_INLINE double spdf_win_link_destination_scroll_y(double page_slot_y, double destination_page_y,
                                                                 double zoom) {
    double scale = zoom > 0.0 ? zoom : 1.0;
    double offset = destination_page_y > 0.0 ? destination_page_y * scale : 0.0;
    return spdf_win_max_d(0.0, page_slot_y + offset - SPDF_WIN_PAGE_MARGIN_V);
}

/* --- 4. the deliberate wait before a link LEAVES the document ------------- */

/* WHY ONE OF THE TWO KINDS OF LINK WAITS AND THE OTHER DOES NOT. Transcribed
 * from portable/mac/SPDFMacDelayedLinkActivation.mm, whose argument is in
 * SPDFMacLinkNavigation.mm and in the 26.9.1-1 release note: a jump inside the
 * document is a scroll, so it is taken IMMEDIATELY and a following multi-click
 * can take it back; a link that hands the point to another application cannot
 * be undone by a second click, so it waits out the double-click interval first
 * and a second click cancels it. Before this the Win32 shell opened the browser
 * on mouse-up, so a double-click on link text launched it and then selected the
 * word underneath.
 *
 * THE MAC MECHANISM IS A GENERATION COUNTER, and that is what makes this pure.
 * dispatch_after cannot be cancelled, so the scheduled block captures the
 * generation it was scheduled at and drops itself when the counter has moved;
 * -cancel just moves the counter. Every timer facility has the same problem
 * (WM_TIMER is already queued when KillTimer runs), so the same counter is the
 * fix here, and it is the half worth testing:
 * portable/win/tests/link_nav_test.c drives it through the mac unit test's own
 * scenarios.
 *
 * WHAT IS DEFERRED DIFFERS FROM MAC BY ONE STEP, deliberately. Mac defers the
 * PAGE POINT and re-resolves the link when the timer fires. On Windows the
 * canvas has already resolved it by the time the shell hears about it
 * (spdf_win_canvas_link_nav), so the shell defers the RESOLVED URI -- one fewer
 * resolution, and therefore one fewer chance for the two to disagree about what
 * is under the point. The URI is copied because the canvas only lends it until
 * the next pointer call.
 *
 * NOT THREAD-SAFE and does not need to be: schedule, cancel and fire all run on
 * the UI thread, exactly as the mac original's main-queue block does. */

/* Longer than any URI canvas_open_uri() can widen into its 2048 wchar_t buffer,
 * so a URI that fits here fits there. A URI that does NOT fit is refused rather
 * than truncated -- opening a PREFIX of a link is opening a different link. */
#define SPDF_WIN_LINK_ACTIVATION_URI_MAX 2048

typedef struct spdf_win_link_activation {
    /* mac's _generation. A live token equals this; anything else is stale. */
    unsigned generation;
    int pending;
    char uri[SPDF_WIN_LINK_ACTIVATION_URI_MAX];
} spdf_win_link_activation;

/* Zeroing the struct is a valid initial state; this is for clarity at the
 * declaration and for a re-arm after a document is replaced. */
static SPDF_WIN_INLINE void spdf_win_link_activation_init(spdf_win_link_activation* a) {
    if (!a) return;
    memset(a, 0, sizeof(*a));
}

/* mac's default delay is NSEvent.doubleClickInterval; this port's caller passes
 * GetDoubleClickTime(). Signed so a bogus system value cannot become an
 * enormous unsigned one, and clamped at 0 exactly as mac's MAX(0.0, delay) is. */
static SPDF_WIN_INLINE unsigned spdf_win_link_activation_delay_ms(long system_double_click_ms) {
    return system_double_click_ms > 0 ? (unsigned)system_double_click_ms : 0u;
}

/* Arm an activation for `uri` and return the TOKEN the eventual fire must
 * present. Supersedes any pending one (mac: `NSUInteger generation =
 * ++_generation`), so the reader's latest click is the one that counts.
 *
 * Returns 0 -- never a live token, because the counter skips 0 -- when there is
 * nothing schedulable: no state, no URI, or a URI too long to copy whole. The
 * pending activation is still superseded in that case: a click that cannot be
 * honoured must not leave the previous one to fire. */
static SPDF_WIN_INLINE unsigned spdf_win_link_activation_schedule(spdf_win_link_activation* a, const char* uri) {
    size_t n = uri ? strlen(uri) : (size_t)0;

    if (!a) return 0u;
    ++a->generation;
    if (a->generation == 0u) ++a->generation; /* wrapped: 0 stays "no token" */
    a->pending = 0;
    a->uri[0] = '\0';
    if (n == 0 || n >= sizeof(a->uri)) return 0u;
    memcpy(a->uri, uri, n + 1);
    a->pending = 1;
    return a->generation;
}

/* mac's -cancel, which is the counter bump and nothing else. Safe to call with
 * nothing pending, and safe to call twice. */
static SPDF_WIN_INLINE void spdf_win_link_activation_cancel(spdf_win_link_activation* a) {
    if (!a) return;
    ++a->generation;
    if (a->generation == 0u) ++a->generation;
    a->pending = 0;
    a->uri[0] = '\0';
}

/* The timer's side. Returns 1 and lends the URI through `out_uri` (valid until
 * the next call on `a`) when `token` is still the live one; 0 -- having changed
 * nothing -- when it is stale, which is every cancelled and every superseded
 * activation. The counter is bumped on success too, mac's `++self->_generation`
 * before the handler runs, so one schedule can never fire twice. */
static SPDF_WIN_INLINE int spdf_win_link_activation_fire(spdf_win_link_activation* a, unsigned token,
                                                         const char** out_uri) {
    if (out_uri) *out_uri = NULL;
    if (!a || token == 0u || token != a->generation || !a->pending) return 0;
    ++a->generation;
    if (a->generation == 0u) ++a->generation;
    a->pending = 0;
    if (out_uri) *out_uri = a->uri;
    return 1;
}

/* Is a link still waiting to be handed to another application? */
static SPDF_WIN_INLINE int spdf_win_link_activation_pending(const spdf_win_link_activation* a) {
    return a && a->pending;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_LINKS_H */
