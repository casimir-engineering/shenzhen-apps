/* spdf_win_selection.h — text selection for the Win32 frontend: the pure
 * device-pixel <-> page-point mapping, the click/drag gesture model, the
 * core-backed selection itself, the overlay rects it contributes, and the
 * clipboard.
 *
 * WHAT IS PURE AND WHAT IS NOT, because the split is the whole design:
 *
 *   Section 1 and 2 are `static inline` and take a HAND-BUILT PAGE LIST. They
 *   need no document, no window, no canvas and no allocation, which is what
 *   lets portable/win/tests/selection_model_test.c drive every corner of the
 *   geometry and the gesture machine from plain C. This is the shape every
 *   other layer of this port takes -- spdf_win_layout.h, spdf_win_chrome.h,
 *   spdf_win_tabstrip.h, spdf_win_chrome_scroll.h.
 *
 *   Section 3 onwards needs a spdf_document, so it lives in
 *   spdf_win_selection.cpp and is exercised against a real fixture.
 *
 * SECTION 2 IS A TRANSCRIPTION, NOT A DESIGN. The click policy, the drag
 * threshold and the four-function gesture machine are ported line for line from
 * portable/linux/gtk4/spdf_selection_adapter.c, which is itself toolkit-free
 * and ships. portable/win/tests/selection_differential.c, driven by
 * selection-differential-native.cmd, compiles the GTK original beside this
 * header and compares them exhaustively (50171 comparisons) -- the same
 * differential discipline as layout.differential, the minimap differential and
 * the search differential, and for the same reason: that discipline has already
 * caught a one-ulp transcription error in this port.
 *
 * COORDINATE SPACES, all three of them, because mixing two of them up is the
 * only way this file can be wrong:
 *
 *   CANVAS-LOCAL DEVICE PIXELS  what the mouse reports and what
 *                               spdf_win_page_draw.dest_* is in. Origin at the
 *                               top-left of the CANVAS region, not the window.
 *   PAGE POINTS                 what the core takes and returns (PDF points,
 *                               y increasing DOWNWARD, matching the rendered
 *                               bitmap, which is why spdf_win_search_geometry.h
 *                               can map a rect with a bare multiply).
 *   PDF USER SPACE              origin bottom-left, y up. NOTHING HERE USES IT.
 *                               The core hands it out only in
 *                               spdf_outline_item.dest_y.
 *
 * The scale factor is dest_w / page_width_pt and dest_h / page_height_pt -- the
 * two are equal up to rounding, and both are used, exactly as
 * spdf_win_find_apply_overlays_for() does it. Deriving them from the page draw
 * rather than from the canvas's zoom is deliberate: the render byte cap shrinks
 * a giant sheet's TEXTURE but never its slot, so the slot is the only honest
 * source for where a page point landed.
 */
#ifndef SPDF_WIN_SELECTION_H
#define SPDF_WIN_SELECTION_H

#include "spdf_win_d2d.h"    /* spdf_win_page_draw, spdf_win_overlay, spdf_win_scene */
#include "spdf_win_layout.h" /* SpdfWinPageSizePt, SPDF_WIN_INLINE */

#ifdef __cplusplus
extern "C" {
#endif

/* --- 1. the pure mapping -------------------------------------------------- */

/* Where a canvas-local device point landed. `page_index` is -1 only when the
 * page list is empty or carries no usable geometry; otherwise a point over the
 * gutter still resolves, to the NEAREST page with x/y clamped into it, and
 * `inside` says which of the two happened.
 *
 * Resolving out-of-page points rather than rejecting them is what makes a drag
 * that leaves the page behave: a reader who sweeps down past the last line
 * expects the selection to run to the end of the text, not to stop the instant
 * the cursor crosses the paper's edge. macOS and GTK both clamp; so does
 * spdf_win_zoom_anchor_capture() for the same reason, and this uses that
 * function's nearest-page rule (smallest squared distance to the rect, first
 * page wins a tie, exact containment short-circuits) so the two never disagree
 * about which page a gutter point belongs to. */
typedef struct spdf_win_page_point {
    int page_index;
    float x; /* page points, clamped to [0, page width]  */
    float y; /* page points, clamped to [0, page height] */
    int inside;
} spdf_win_page_point;

/* Page size in points for `page_index`, from the sizes array the caller holds.
 * Returns 0 when the index is out of range or the size is not positive. */
static SPDF_WIN_INLINE int spdf_win_selection_page_size(const SpdfWinPageSizePt* sizes, int size_count, int page_index,
                                                        double* out_w, double* out_h) {
    if (!sizes || page_index < 0 || page_index >= size_count) return 0;
    if (!(sizes[page_index].width > 0.0 && sizes[page_index].height > 0.0)) return 0;
    if (out_w) *out_w = sizes[page_index].width;
    if (out_h) *out_h = sizes[page_index].height;
    return 1;
}

/* Map a device point onto ONE named page draw, clamping. Returns 0 when that
 * draw has no usable geometry or no known page size. */
static SPDF_WIN_INLINE int spdf_win_selection_point_on_draw(const spdf_win_page_draw* draw,
                                                            const SpdfWinPageSizePt* sizes, int size_count, float x,
                                                            float y, spdf_win_page_point* out) {
    double pw = 0.0, ph = 0.0;
    double px, py;

    if (!draw || !out) return 0;
    if (!(draw->dest_w > 0.0f && draw->dest_h > 0.0f)) return 0;
    if (!spdf_win_selection_page_size(sizes, size_count, draw->page_index, &pw, &ph)) return 0;

    out->inside = (x >= draw->dest_x && x <= draw->dest_x + draw->dest_w && y >= draw->dest_y &&
                   y <= draw->dest_y + draw->dest_h)
                      ? 1
                      : 0;
    px = ((double)x - (double)draw->dest_x) * pw / (double)draw->dest_w;
    py = ((double)y - (double)draw->dest_y) * ph / (double)draw->dest_h;
    out->page_index = draw->page_index;
    out->x = (float)spdf_win_clamp_d(px, 0.0, pw);
    out->y = (float)spdf_win_clamp_d(py, 0.0, ph);
    return 1;
}

/* Resolve a device point against the whole visible page list. */
static SPDF_WIN_INLINE int spdf_win_selection_point_on_page(const spdf_win_page_draw* pages, int page_count,
                                                            const SpdfWinPageSizePt* sizes, int size_count, float x,
                                                            float y, spdf_win_page_point* out) {
    int best = -1;
    double best_distance = 0.0;
    int i;

    if (out) {
        out->page_index = -1;
        out->x = out->y = 0.0f;
        out->inside = 0;
    }
    if (!pages || page_count <= 0 || !out) return 0;

    for (i = 0; i < page_count; ++i) {
        const spdf_win_page_draw* d = &pages[i];
        double dx = 0.0, dy = 0.0, distance;
        double pw = 0.0, ph = 0.0;
        if (!(d->dest_w > 0.0f && d->dest_h > 0.0f)) continue;
        if (!spdf_win_selection_page_size(sizes, size_count, d->page_index, &pw, &ph)) continue;
        if ((double)x < (double)d->dest_x)
            dx = (double)d->dest_x - (double)x;
        else if ((double)x > (double)d->dest_x + (double)d->dest_w)
            dx = (double)x - ((double)d->dest_x + (double)d->dest_w);
        if ((double)y < (double)d->dest_y)
            dy = (double)d->dest_y - (double)y;
        else if ((double)y > (double)d->dest_y + (double)d->dest_h)
            dy = (double)y - ((double)d->dest_y + (double)d->dest_h);
        distance = dx * dx + dy * dy;
        if (best < 0 || distance < best_distance) {
            best = i;
            best_distance = distance;
        }
        if (distance == 0.0) break;
    }
    if (best < 0) return 0;
    return spdf_win_selection_point_on_draw(&pages[best], sizes, size_count, x, y, out);
}

/* The same, pinned to one page index -- what a drag endpoint uses. A range
 * selection is a SINGLE-PAGE operation in the core (spdf_select_text takes one
 * page_index), so once a press has chosen a page every later point in that
 * gesture is clamped into it rather than allowed to wander onto the next one.
 * Returns 0 when that page is not in the list. */
static SPDF_WIN_INLINE int spdf_win_selection_point_on_page_index(const spdf_win_page_draw* pages, int page_count,
                                                                  const SpdfWinPageSizePt* sizes, int size_count,
                                                                  int page_index, float x, float y,
                                                                  spdf_win_page_point* out) {
    int i;
    if (out) {
        out->page_index = -1;
        out->x = out->y = 0.0f;
        out->inside = 0;
    }
    if (!pages || page_count <= 0) return 0;
    for (i = 0; i < page_count; ++i)
        if (pages[i].page_index == page_index)
            return spdf_win_selection_point_on_draw(&pages[i], sizes, size_count, x, y, out);
    return 0;
}

/* The inverse: one page-space rect to a canvas-local device rect. Identical
 * arithmetic to spdf_win_find_apply_overlays_for()'s, kept here so the two
 * producers cannot drift. Returns 0 when the draw has no usable geometry. */
static SPDF_WIN_INLINE int spdf_win_selection_rect_to_device(const spdf_win_page_draw* draw,
                                                             const SpdfWinPageSizePt* sizes, int size_count,
                                                             spdf_rect page_rect, spdf_win_overlay* out) {
    double pw = 0.0, ph = 0.0, sx, sy;

    if (!draw || !out) return 0;
    if (!(draw->dest_w > 0.0f && draw->dest_h > 0.0f)) return 0;
    if (!spdf_win_selection_page_size(sizes, size_count, draw->page_index, &pw, &ph)) return 0;
    sx = (double)draw->dest_w / pw;
    sy = (double)draw->dest_h / ph;
    out->page_index = draw->page_index;
    out->x = draw->dest_x + (float)((double)page_rect.x0 * sx);
    out->y = draw->dest_y + (float)((double)page_rect.y0 * sy);
    out->w = (float)(((double)page_rect.x1 - (double)page_rect.x0) * sx);
    out->h = (float)(((double)page_rect.y1 - (double)page_rect.y0) * sy);
    out->kind = SPDF_WIN_OVERLAY_SELECTION;
    out->alpha = 1.0f;
    return 1;
}

/* --- 2. the gesture model (transcribed from GTK4) ------------------------- */

/* Port of SpdfSelectionClickPolicy / spdf_selection_click_policy. */
typedef struct SpdfWinSelectionClickPolicy {
    spdf_selection_granularity granularity;
    int uses_range_path;
    int cancels_pending_link;
} SpdfWinSelectionClickPolicy;

/* A press count of zero is treated defensively as a single press, exactly as
 * the GTK original does. Single presses stay range/link candidates, double
 * presses select a word, triple-or-later select the containing block. */
static SPDF_WIN_INLINE SpdfWinSelectionClickPolicy spdf_win_selection_click_policy(unsigned press_count) {
    SpdfWinSelectionClickPolicy policy;
    policy.granularity = SPDF_SELECTION_RANGE;
    policy.uses_range_path = 1;
    policy.cancels_pending_link = 0;
    if (press_count >= 3) {
        policy.granularity = SPDF_SELECTION_BLOCK;
        policy.uses_range_path = 0;
        policy.cancels_pending_link = 1;
    } else if (press_count == 2) {
        policy.granularity = SPDF_SELECTION_WORD;
        policy.uses_range_path = 0;
        policy.cancels_pending_link = 1;
    }
    return policy;
}

/* AXIS BASED, not radial, and that is GTK's rule rather than an approximation
 * of it: crossing the threshold on EITHER axis starts the drag. Windows spells
 * the same policy SM_CXDRAG/SM_CYDRAG, so the shape survives the port intact --
 * only the number changes, and the number is the caller's. A negative threshold
 * is treated as zero. */
static SPDF_WIN_INLINE int spdf_win_selection_drag_threshold_crossed(double start_x, double start_y, double current_x,
                                                                     double current_y, double threshold) {
    double dx = current_x - start_x;
    double dy = current_y - start_y;

    if (threshold < 0.0) threshold = 0.0;
    if (dx < 0.0) dx = -dx;
    if (dy < 0.0) dy = -dy;
    return dx > threshold || dy > threshold;
}

/* Port of SpdfSelectionGestureState. */
typedef struct SpdfWinSelectionGesture {
    unsigned press_count;
    int pending_link;
    int link_cancelled;
    int dragging;
} SpdfWinSelectionGesture;

static SPDF_WIN_INLINE void spdf_win_selection_gesture_reset(SpdfWinSelectionGesture* state) {
    if (!state) return;
    state->press_count = 0;
    state->pending_link = 0;
    state->link_cancelled = 0;
    state->dragging = 0;
}

static SPDF_WIN_INLINE SpdfWinSelectionClickPolicy spdf_win_selection_gesture_begin(SpdfWinSelectionGesture* state,
                                                                                    unsigned press_count,
                                                                                    int over_link) {
    SpdfWinSelectionClickPolicy policy = spdf_win_selection_click_policy(press_count);

    if (!state) return policy;
    state->press_count = press_count;
    state->dragging = 0;
    state->link_cancelled = policy.cancels_pending_link && state->pending_link;
    if (policy.cancels_pending_link) {
        state->pending_link = 0;
    } else {
        state->pending_link = over_link != 0;
    }
    return policy;
}

static SPDF_WIN_INLINE int spdf_win_selection_gesture_update_drag(SpdfWinSelectionGesture* state, double start_x,
                                                                  double start_y, double current_x, double current_y,
                                                                  double threshold) {
    if (!state) return 0;
    if (!state->dragging &&
        spdf_win_selection_drag_threshold_crossed(start_x, start_y, current_x, current_y, threshold)) {
        state->dragging = 1;
        if (state->pending_link) {
            state->pending_link = 0;
            state->link_cancelled = 1;
        }
    }
    return state->dragging;
}

static SPDF_WIN_INLINE void spdf_win_selection_gesture_cancel(SpdfWinSelectionGesture* state) {
    if (!state) return;
    if (state->pending_link) state->link_cancelled = 1;
    state->pending_link = 0;
    state->dragging = 0;
}

static SPDF_WIN_INLINE int spdf_win_selection_gesture_take_link(SpdfWinSelectionGesture* state) {
    int activate;

    if (!state) return 0;
    activate = state->pending_link && !state->dragging;
    state->pending_link = 0;
    return activate;
}

/* --- 3. the live selection ------------------------------------------------ */

typedef struct spdf_win_selection spdf_win_selection;

/* Allocates one struct; opens nothing and starts no thread. Every function
 * below tolerates a NULL selection, so a failed allocation degrades to "no
 * selection" rather than to a crash -- the same rule the find session states. */
spdf_win_selection* spdf_win_selection_new(void);
void spdf_win_selection_free(spdf_win_selection* sel);

/* Drops any text, rects and error. Call it when the document is replaced. */
void spdf_win_selection_clear(spdf_win_selection* sel);

/* THE DOCUMENT HANDLE MUST BELONG TO THE CALLING THREAD. The core allows one
 * spdf_document per thread with no locking inside (shenzhen_pdf_core.c:40-43),
 * so these run on the UI thread against the UI thread's handle -- the canvas's.
 * Nothing here is ever called from a render worker or the thumbnail store,
 * which hold handles of their own for exactly this reason. */

/* Begin a gesture. `press_count` is the accumulated click count (1, 2, 3...),
 * `over_link` says whether a link sits under the point (spdf_win_links.h
 * answers that). A double or triple press selects immediately; a single press
 * only arms the range path. Returns 1 when the visible selection changed. */
int spdf_win_selection_press(spdf_win_selection* sel, spdf_document* doc, const spdf_win_page_draw* pages,
                             int page_count, const SpdfWinPageSizePt* sizes, int size_count, float x, float y,
                             unsigned press_count, int over_link);

/* Extend a single-press range drag to (x, y). `threshold` is the drag slop in
 * device pixels (the canvas passes SM_CXDRAG). Word and block selections stay
 * put while their gesture finishes, as GTK's do. Returns 1 when the visible
 * selection changed. */
int spdf_win_selection_drag(spdf_win_selection* sel, spdf_document* doc, const spdf_win_page_draw* pages,
                            int page_count, const SpdfWinPageSizePt* sizes, int size_count, float x, float y,
                            double threshold);

/* End the gesture. Returns 1 when this release should ACTIVATE A LINK, i.e. it
 * was a single click on a link that never became a drag. The completed
 * selection is preserved. */
int spdf_win_selection_release(spdf_win_selection* sel);

/* Abandon the in-flight gesture (capture lost, Escape) but keep a completed
 * selection, matching spdf_docview_selection_cancel. */
void spdf_win_selection_cancel(spdf_win_selection* sel);

int spdf_win_selection_has_text(const spdf_win_selection* sel);
int spdf_win_selection_is_dragging(const spdf_win_selection* sel);
/* Borrowed UTF-8, valid until the next press/drag/clear. NULL when empty. */
const char* spdf_win_selection_text(const spdf_win_selection* sel);
/* The page the selection lives on, or -1. */
int spdf_win_selection_page(const spdf_win_selection* sel);
/* Borrowed page-space rects, same lifetime as the text. */
const spdf_rect* spdf_win_selection_rects(const spdf_win_selection* sel, int* out_count);
/* NULL when the last selection did not error. */
const char* spdf_win_selection_error(const spdf_win_selection* sel);

/* --- 4. overlays: the SECOND producer ------------------------------------- */

/* Appends this selection's rects to whatever the scene already carries and
 * re-points scene->overlays at the combined array.
 *
 * WHY APPEND-OVER-A-BASE RATHER THAN A COMBINED PRODUCER. spdf_win_chrome_find.h
 * offers two ways for a second producer to coexist: one producer builds the
 * combined array, or every producer appends into a scene-owned buffer. Neither
 * is available without editing files this track does not own -- the first would
 * put find's engine inside this one, the second would change spdf_win_scene.
 * So this takes the third shape, which needs neither: it reads whatever
 * scene->overlays currently points at as an immutable BASE, copies it into a
 * buffer of its own, appends the selection, and re-points the scene. Call it
 * AFTER spdf_win_find_apply_overlays(); the shell's hook grows by exactly one
 * line and spdf_win_chrome_find.h does not change at all. It composes with any
 * future producer that follows the same "overwrite, then let the next one
 * append" convention, and calling it with no base (NULL/0) is normal.
 *
 * ORDER: base first, selection LAST, which is macOS's own draw order --
 * SPDFMacDocumentView.mm draws find highlights (:467), then the active match's
 * ring (:475), then the selection (:485). It also keeps find's contract intact,
 * since find's ring is still the last thing find itself emits.
 *
 * LIFETIME, stated the way find states it: the array belongs to the SELECTION,
 * not to the scene and not to the caller, and stays valid until the next
 * compose/press/drag/clear on the same selection or until it is freed. It
 * outlives the spdf_win_paint() that follows.
 *
 * On allocation failure the scene keeps its base overlays untouched, so a
 * selection that cannot be drawn never takes the search highlights down with
 * it. */
void spdf_win_selection_compose_overlays(spdf_win_selection* sel, const spdf_win_page_draw* pages, int page_count,
                                         const SpdfWinPageSizePt* sizes, int size_count, struct spdf_win_scene* scene);

/* --- 5. the clipboard ----------------------------------------------------- */

/* UTF-8 -> UTF-16, the pure half, so the conversion is testable without a
 * clipboard, a window or a message loop. Returns the number of wchar_t written
 * INCLUDING the terminating NUL, or 0 on failure. Pass out=NULL to size the
 * buffer. */
int spdf_win_utf8_to_utf16(const char* utf8, wchar_t* out, int out_len);

/* The exact GMEM_MOVEABLE block spdf_win_clipboard_put_utf8() hands to
 * SetClipboardData: `n` UTF-16 code units plus the terminator, and nothing
 * else. Exported so the copy path can be proved BYTE FOR BYTE without a
 * clipboard -- which matters on this machine, where a locked workstation makes
 * OpenClipboard fail with ERROR_ACCESS_DENIED and the round-trip half of
 * clipboard_test.c can only report SKIP. Everything that could corrupt (the
 * sizing, the surrogate pairs, the terminator, the moveable allocation) is in
 * here; what is left in put_utf8 is OpenClipboard/SetClipboardData.
 *
 * The caller owns the returned handle and must GlobalFree it. NULL on failure. */
HGLOBAL spdf_win_clipboard_alloc_utf16(const char* utf8);

/* Put UTF-8 text on the clipboard as CF_UNICODETEXT.
 *
 * CF_UNICODETEXT AND NOTHING ELSE, DELIBERATELY. This machine's ANSI code page
 * is 1252, so CF_TEXT would round-trip a selection through
 * WideCharToMultiByte(CP_ACP) and replace every CJK character with '?' -- and a
 * selection is precisely where that shows up, which is why the core carries a
 * whole CJK selection suite. Windows synthesises CF_TEXT from CF_UNICODETEXT
 * for the few consumers that still ask for it, so publishing the wide format
 * alone loses nothing and mangles nothing.
 *
 * NO HWND. OpenClipboard(NULL) associates the clipboard with the current task,
 * which is all a copy needs; keeping it window-free means the copy path works
 * in the headless probe exactly as it does in the app.
 *
 * Returns 1 on success. 0 means the clipboard could not be opened (another
 * process owns it -- it retries briefly first) or the text could not be
 * converted; the previous clipboard contents are then left alone. */
int spdf_win_clipboard_put_utf8(const char* utf8);

/* Read CF_UNICODETEXT back as UTF-8, for the round-trip test. Returns the
 * number of bytes written including the NUL, or 0. */
int spdf_win_clipboard_get_utf8(char* out, int out_len);

/* NO COPY PERMISSION GATE EXISTS HERE, AND NONE MAY BE ADDED.
 * spdf_has_permission(doc, 'c') returns 1 unconditionally by product decision
 * (shenzhen_pdf_core.h:209-214): the PDF copy flag is advisory, the document is
 * already decrypted and on screen by the time it could be consulted, and
 * honouring it only ever stopped a reader quoting a document they are looking
 * at. The GTK frontend keeps a deliberately-dead gate that its own test pins;
 * that is its business and is not a pattern to copy. */

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_SELECTION_H */
