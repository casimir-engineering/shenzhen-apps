/* spdf_win_chrome_find.h — FIND: the engine's public surface, the toolbar's find
 * controls, and the heat-map ticks.
 *
 * WHY THE ENGINE API IS HERE AND NOT IN spdf_win_search.h. That header is a
 * line-for-line transcription of portable/linux/gtk4/spdf_search_internal.h and
 * is differentially tested against it
 * (portable/win/tests/search-differential-native.cmd). Its value comes entirely
 * from being a pure transcription: anything added to it is something the
 * differential cannot check, sitting in the one file whose whole point is that
 * every line IS checked. So the engine that DRIVES that logic -- the worker
 * thread, the generation counter, the document handle -- declares itself here
 * instead, and spdf_win_search.h stays comparable to its original.
 *
 * THE THREE THINGS THIS FILE OWNS:
 *
 *   1. THE SESSION. One search per document: set the query, poll for results,
 *      step through matches. Everything expensive happens on a worker thread
 *      that opens its own spdf_document, so nothing here runs on the paint path
 *      or the launch path -- a document nobody searches costs one struct and no
 *      thread, which is the repo's standing speed rule (a feature costs nothing
 *      for documents that do not use it).
 *
 *   2. THE TOOLBAR'S READOUT. macOS's counter, which is NOT the GTK counter:
 *      "" with no query, "..." while searching, "0 / 0" on no match, else
 *      "<index+1> / <total>" (ShenzhenPDFMac.mm:3081-3086, 10631-10652). The
 *      counter AND the prev/next pill are hidden whenever the query is empty,
 *      which is a MODEL question rather than a layout one and so is answered by
 *      a predicate here that both the layout and the painter call.
 *
 *   3. THE HEAT-MAP TICKS, as document-height fractions in [0,1], thinned the
 *      way macOS thins them (SPDFMacUIHelpers.mm:453-479: a marker closer than
 *      1.5 pt to the previous one is dropped). The vertical trough is drawn by
 *      another track; this file produces what it draws, already deduplicated,
 *      because SpdfWinChromeModel's own comment forbids sorting or thinning on
 *      the paint path.
 *
 * The pure parts are C-compatible and free of Direct2D so a plain C test can
 * compile them; the painter declaration at the bottom is C++ only.
 */
#ifndef SPDF_WIN_CHROME_FIND_H
#define SPDF_WIN_CHROME_FIND_H

#include "spdf_win_chrome.h"
#include "spdf_win_chrome_toolbar.h"
#include "spdf_win_search.h"

/* Declared, not included: the overlay pass takes a scene, and pulling
 * spdf_win_d2d.h (and therefore d2d1.h) into every C consumer of this header
 * would cost them Direct2D for a pointer they never dereference. */
struct spdf_win_scene;

#ifdef __cplusplus
extern "C" {
#endif

/* --- 1. the toolbar readout ---------------------------------------------- */

/* Longest counter text is "20000 / 20000" plus the NUL; 24 leaves room for the
 * cap moving without a second look at every buffer. */
#define SPDF_WIN_FIND_COUNTER_MAX 24

/* Is the find group live at all? macOS hides the counter and the prev/next pill
 * whenever the query is empty, and shows them the moment a character is typed --
 * before any result exists, which is why this asks about the QUERY and not about
 * match_count. A NULL query is empty. */
static SPDF_WIN_TB_INLINE int spdf_win_find_has_query(const SpdfWinChromeModel* m) {
    return m && m->query && m->query[0] != L'\0';
}

/* macOS's counter, into a UTF-16 buffer. Deliberately NOT the GTK counter
 * spdf_win_search.h ports: macOS shows an ellipsis while the search runs where
 * GTK shows the running total. Both exist, both are cited, and neither is a
 * "fixed" version of the other.
 *
 * Hand-formatted rather than swprintf'd because this is called from the paint
 * path once per frame and the format is two integers -- and because a swprintf
 * here would drag <stdio.h>'s wide half into a header that a geometry test
 * includes. */
static SPDF_WIN_TB_INLINE void spdf_win_find_counter_text(const SpdfWinChromeModel* m, wchar_t* buf, int len) {
    int total, index, n = 0;
    wchar_t digits[12];
    int d;

    if (!buf || len < 1) return;
    buf[0] = L'\0';
    if (!spdf_win_find_has_query(m)) return; /* "" with no query */
    if (m->searching && m->match_count <= 0) {
        if (len > 3) {
            buf[0] = buf[1] = buf[2] = L'.'; /* "..." while searching */
            buf[3] = L'\0';
        }
        return;
    }
    total = m->match_count > 0 ? m->match_count : 0;
    index = m->match_index;
    if (total <= 0) {
        static const wchar_t* zero = L"0 / 0";
        int i;
        for (i = 0; zero[i] && n < len - 1; ++i) buf[n++] = zero[i];
        buf[n] = L'\0';
        return;
    }
    /* "<index+1> / <total>", and the bare total when nothing is selected yet --
     * which is what a partial batch looks like while the worker is still going. */
    if (index >= 0) {
        int v = index + 1;
        d = 0;
        do {
            digits[d++] = (wchar_t)(L'0' + v % 10);
            v /= 10;
        } while (v > 0 && d < (int)(sizeof(digits) / sizeof(digits[0])));
        while (d > 0 && n < len - 1) buf[n++] = digits[--d];
        if (n < len - 1) buf[n++] = L' ';
        if (n < len - 1) buf[n++] = L'/';
        if (n < len - 1) buf[n++] = L' ';
    }
    d = 0;
    do {
        digits[d++] = (wchar_t)(L'0' + total % 10);
        total /= 10;
    } while (total > 0 && d < (int)(sizeof(digits) / sizeof(digits[0])));
    while (d > 0 && n < len - 1) buf[n++] = digits[--d];
    buf[n] = L'\0';
}

/* --- 2. the heat-map ticks ----------------------------------------------- */

/* Thin a sorted run of document-height fractions the way the macOS scroller
 * does: convert each to a lane offset and drop any marker within `min_gap_px`
 * of the last one KEPT (not of the last one seen -- dropping against the last
 * seen would let a dense run creep, one gap at a time, past a marker it should
 * have merged with).
 *
 * The active mark survives thinning: it is the one tick the reader is looking
 * for, so when it would be dropped it REPLACES the marker that swallowed it and
 * `*active_out` follows it. Returns how many were written.
 *
 * `in` must be non-decreasing, which the session guarantees because matches
 * arrive in document order. */
static SPDF_WIN_TB_INLINE int spdf_win_find_thin_marks(const float* in, int count, int active_in, float lane_h,
                                                       float min_gap_px, float* out, int out_max, int* active_out) {
    int i, n = 0;
    float last_y = 0.0f;

    if (active_out) *active_out = -1;
    if (!in || !out || count <= 0 || out_max <= 0) return 0;
    if (!(lane_h > 0.0f)) lane_h = 1.0f;
    for (i = 0; i < count; ++i) {
        float f = in[i] < 0.0f ? 0.0f : (in[i] > 1.0f ? 1.0f : in[i]);
        float y = f * lane_h;
        if (n > 0 && y - last_y < min_gap_px) {
            /* Swallowed. If this was the active match, it takes the kept
             * marker's slot so the reader still sees where they are. */
            if (i == active_in) {
                out[n - 1] = f;
                if (active_out) *active_out = n - 1;
            }
            continue;
        }
        if (n >= out_max) break;
        if (i == active_in && active_out) *active_out = n;
        out[n++] = f;
        last_y = y;
    }
    return n;
}

/* --- 3. the session ------------------------------------------------------ */

typedef struct SpdfWinFindSession SpdfWinFindSession;

/* Opens nothing, starts nothing, allocates one struct. NULL on allocation
 * failure, and every function below tolerates a NULL session so a failed one
 * degrades to "no search" rather than to a crash. */
SpdfWinFindSession* spdf_win_find_session_new(void);
void spdf_win_find_session_free(SpdfWinFindSession* s);

/* UI thread. The whole input surface: the document to search, the query and the
 * regex flag. Restarts the worker ONLY when one of the three actually changed,
 * so calling this once per paint (which is what the model builder does) costs a
 * strcmp on the steady path. An empty or NULL query cancels and clears.
 *
 * `utf8_query` is capped and truncated on a character boundary by
 * spdf_win_search_dup_query, so a paste of a megabyte cannot become a
 * megabyte-wide regex. */
void spdf_win_find_set(SpdfWinFindSession* s, const char* utf8_path, const char* utf8_query, int regex);

/* UI thread. Adopts everything the worker has published since the last call.
 * Returns 1 when anything visible changed, which is the caller's cue to repaint.
 * O(1) per delivered batch; never blocks and never renders. */
int spdf_win_find_poll(SpdfWinFindSession* s);

int spdf_win_find_searching(const SpdfWinFindSession* s);
int spdf_win_find_match_count(const SpdfWinFindSession* s);
int spdf_win_find_match_index(const SpdfWinFindSession* s); /* 0-based; -1 = none */
/* NULL when the last search succeeded; otherwise the core's message (an invalid
 * regex is the case that matters). A failed search shows NO matches, which is
 * GTK3's semantic and the one the mac app inherits. */
const char* spdf_win_find_error(const SpdfWinFindSession* s);

/* Move the selection by `delta` matches with wraparound, as GTK3 find_step and
 * macOS findFromCurrentForward do. Returns the new index, or -1. */
int spdf_win_find_step(SpdfWinFindSession* s, int delta);
/* Make match `index` the current one -- a click on a results row, or the
 * nearest-match jump. Returns 1 when it changed; out of range is a no-op. */
int spdf_win_find_set_current(SpdfWinFindSession* s, int index);
/* Where the current match is, for the caller that scrolls to it. Returns 0 when
 * there is no current match. */
int spdf_win_find_current_target(const SpdfWinFindSession* s, int* out_page, spdf_rect* out_rect);

/* ONE MATCH, for the results sidebar and the nearest-match jump. `snippet` is
 * the surrounding text line (borrowed UTF-8, never NULL, valid until the next
 * poll/set on this session); `chapter_index` is the pre-order outline index the
 * match falls under, -1 before the first chapter or with no outline
 * (spdf_win_search_chapter_for_page). Returns 0 when `index` is out of range. */
typedef struct SpdfWinFindMatchInfo {
    int page;
    spdf_rect rect;
    const char* snippet;
    int chapter_index;
} SpdfWinFindMatchInfo;
int spdf_win_find_match_at(const SpdfWinFindSession* s, int index, SpdfWinFindMatchInfo* out);

/* The document's outline titles in spdf_load_outline order, published by the
 * worker once per search and adopted by poll(). What the results sidebar's
 * chapter headers are made of (spdf_win_sidebar_chapter_title takes exactly
 * this array's shape). 0 / NULL without an outline, or before the first poll
 * that saw one. Borrowed, valid until the next poll/set. */
int spdf_win_find_chapter_count(const SpdfWinFindSession* s);
const char* spdf_win_find_chapter_title(const SpdfWinFindSession* s, int chapter_index);

/* The query the session is (or was last) searching for, UTF-8, borrowed; NULL
 * when empty. What the results rows bold and the status lines quote. */
const char* spdf_win_find_query(const SpdfWinFindSession* s);

/* Bumped on every change a reader of the results could observe: a batch
 * adopted, the current match moved, the query replaced. A consumer that caches
 * a view of the results compares this one integer per frame. */
unsigned spdf_win_find_revision(const SpdfWinFindSession* s);

/* Forget the document and drop the results, so the next spdf_win_find_set()
 * with the same query reruns it. For a page rotation: the rects the old search
 * produced describe pages that no longer look like that. */
void spdf_win_find_restart(SpdfWinFindSession* s);

/* REGEX MULTILINE -- whether a pattern may span line and paragraph breaks
 * (spdf_search_page_rects_options' fourth argument). Process-wide, like the
 * regex flag itself: it is the reader's setting, not a property of one search.
 * spdf_win_find_set() reads it as a fourth input and restarts the running
 * search when it changed. Defaults ON, as both originals do
 * (SPDFMacModels.mm:15, spdf_state.c:780). The Edit menu's check mark reads it
 * back from here: this IS the source of truth, there is no copy on `app`. */
void spdf_win_find_set_regex_multiline(int on);
int spdf_win_find_regex_multiline(void);

/* The heat-map ticks: document-height fractions in [0,1], already sorted and
 * thinned. Borrowed, valid until the next poll/set. `*out_active` is an index
 * into the returned array, or -1.
 *
 * THEY ARE APPROXIMATE BY AT MOST THE INTER-PAGE MARGINS' SHARE of the document
 * (~3% at zoom 1, less as the reader zooms in, and a position error only -- no
 * tick appears, disappears or reorders). The fractions are laid out at zoom 1.0
 * because the exact answer needs the canvas's live layout; rebuild_marks() in
 * spdf_win_search_geometry.h states the bound and what would have to change to
 * remove it. A caller must not treat a tick as an exact scroll target: to GO to
 * a match, use spdf_win_find_current_target(), which is exact. */
const float* spdf_win_find_marks(const SpdfWinFindSession* s, int* out_count, int* out_active);

/* THE MINIMAP STRIP'S MARKERS: every match as (page, fraction of that page's
 * height), in match order, so the strip painter can place each tick inside its
 * page's slot with spdf_win_minimap_marker_y. EXACT within the page, unlike the
 * scroller fractions above, because the strip draws pages rather than a lane.
 * `*out_active` is the index of the current match in this array (which is the
 * match index itself), or -1. Borrowed, valid until the next poll/set. */
typedef struct SpdfWinFindPageMark {
    int page;
    float fraction; /* match centre y over page height, in [0,1] */
} SpdfWinFindPageMark;
const SpdfWinFindPageMark* spdf_win_find_page_marks(const SpdfWinFindSession* s, int* out_count, int* out_active);

/* A batch lands on a worker thread milliseconds to seconds after the frame that
 * asked for it, so something must ask for a repaint or the highlights and the
 * counter wait for the next mouse move. This remembers the top-level windows of
 * the thread that PAINTS and invalidates them when a batch arrives -- exactly
 * spdf_win_thumbs_note_paint_thread's arrangement and its justification.
 * Idempotent; a no-op in a headless process, where the painting thread owns no
 * windows. spdf_win_paint() itself still needs no HWND: this is the session's
 * side channel, not the painter's. */
void spdf_win_find_note_paint_thread(SpdfWinFindSession* s);

/* --- 4. the process-wide session, and the temporary query bridge ---------
 *
 * SAME SEAM, SAME REASON as spdf_win_chrome_content.h's: the painters are
 * reached only through spdf_win_paint(), whose scene carries a
 * SpdfWinChromeModel and no document. Until the model or the scene carries a
 * find session, the model builder resolves this one, and the query comes from
 * the environment because no keyboard input reaches this track yet.
 *
 * spdf_win_find_shared() is lazy: the first call that has a non-empty query
 * creates the session, so a process that never searches never allocates one and
 * never starts a thread. */
SpdfWinFindSession* spdf_win_find_shared(void);

/* Fills the model's find fields from the shared session, starting or restarting
 * the search if the document or the query changed. Called from
 * spdf_win_chrome_model.cpp. `utf8_path` may be NULL. */
void spdf_win_find_fill_model(SpdfWinChromeModel* model, const char* utf8_path);

/* THE ONE HOOK THIS TRACK NEEDS FROM THE SCENE BUILDER. Produces the search
 * highlights for the pages the scene is about to draw and points
 * scene->overlays/overlay_count at them. Call it AFTER
 * spdf_win_canvas_build_scene(), which is what fills scene->pages. It reads only
 * `pages`, `page_count`, `target_px_h` and `dpi_scale`, and writes only
 * `overlays` and `overlay_count`.
 *
 * IT OVERWRITES, IT DOES NOT APPEND. `scene->overlays` and `overlay_count` are
 * unconditionally replaced -- set to NULL/0 on every path that produces nothing,
 * including no query, no matches and no visible pages. Nothing else contributes
 * overlays today, so nothing is lost; a SELECTION track that also wants to
 * contribute must not simply call this after filling the array itself, because
 * its rects would vanish. The two ways out, in order of preference: give the
 * selection track its own kind and let ONE producer build the combined array, or
 * have each producer append into a scene-owned buffer with a length. Do not
 * discover this by debugging a disappearing selection.
 *
 * ORDER IS DRAW ORDER, which the overlay painter states. Every match is emitted
 * as SPDF_WIN_OVERLAY_SEARCH_MATCH in document order, and the ACTIVE match's
 * ring is held back and appended LAST so it draws over every fill -- including
 * the fills of matches on pages further down the canvas.
 *
 * LIFETIME. The array belongs to the SESSION, not to the scene and not to the
 * caller, and stays valid until the next spdf_win_find_apply_overlays() /
 * _apply_overlays_for() on that same session or until the session is freed --
 * which is the same contract spdf_win_canvas.h states for the page list it
 * borrows the geometry from. In particular it outlives the spdf_win_paint() that
 * follows, INCLUDING when a worker thread finishes a search in between: a worker
 * only ever appends to the session's private pending list under the lock, and
 * the match list the overlays were computed from is touched exclusively by
 * spdf_win_find_poll() on the UI thread. So a search completing mid-frame cannot
 * move, reallocate or free anything the scene is pointing at; the new matches
 * simply appear in the NEXT frame, which the session asks for by invalidating.
 *
 * The _for form takes the session explicitly, which is what makes the mapping
 * testable: portable/win/tests/find_overlay_test.c drives a session of its own
 * against a hand-built scene, with no window, no app and no environment. */
void spdf_win_find_apply_overlays_for(SpdfWinFindSession* s, struct spdf_win_scene* scene);
void spdf_win_find_apply_overlays(struct spdf_win_scene* scene);

#ifdef __cplusplus
} /* extern "C" */

/* --- 5. the toolbar's find controls, drawn ------------------------------- */
#include "spdf_win_chrome_paint.h"

/* Draws items 12-15 of the row: the search field with the live query, the regex
 * checkbox, the counter label and the prev/next pill. Split out of
 * spdf_win_chrome_toolbar.cpp, which is at its size cap; called from it so the
 * row is still drawn by one walk of one table. Every rect it uses comes from
 * `tb`, so the input router hit-tests exactly what was drawn. */
void spdf_win_chrome_paint_find(const SpdfWinChromePaintCtx& ctx, const SpdfWinToolbarLayout& tb);
#endif

#endif /* SPDF_WIN_CHROME_FIND_H */
