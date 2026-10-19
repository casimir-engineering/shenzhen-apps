/* spdf_win_sidebar_view.h — the sidebar's SEARCH section as rows, the segment
 * control's geometry and policy, and the side channels that carry both from the
 * app to the painter and the router.
 *
 * WHAT THE SEARCH SECTION SHOWS (mac rebuildSearchSidebarItems,
 * ShenzhenPDFMac.mm:9506-9550, cells :16151-16300, heights :15859-15871):
 *
 *   - a STATUS row while nothing is listed: "Searching for "q"..." during the
 *     search, "No matches for "q"" after it, or the engine's error; 36 pt,
 *     centred, systemFontOfSize:12, secondaryLabelColor;
 *   - a HEADER row whenever a match's chapter differs from the previous match's
 *     (spdf_win_sidebar_group_append -- the port of the grouping rule), titled
 *     with spdf_win_sidebar_chapter_title's "Untitled"/"Document" fallbacks;
 *     30 pt, a capsule around the title;
 *   - a MATCH row per match: the snippet cut to two words each side of the
 *     query (spdf_win_sidebar_snippet_window) with the query's first
 *     occurrence bold (spdf_win_sidebar_snippet_match_range), over the subtitle
 *     "Page N - match I of M"; 46 pt, title 12 pt medium at top 7, subtitle
 *     11 pt secondary 2 below it, trailing inset 8 (kSidebarSearchTrailingInset).
 *
 * VARIABLE ROW HEIGHTS are what set this apart from the Chapters list, whose
 * rows are all 25 pt and whose hit-test is one division. Here a hit is a walk
 * over the rows, so the pure functions below take the view, and the input
 * router -- which has no view -- reports the LIST-LOCAL Y of a click in the
 * Search section and lets the app resolve it (spdf_win_chrome_input.h says
 * where). The painter and that resolution both use spdf_win_sidebar_results_*
 * below, so they cannot disagree.
 *
 * THE SIDE CHANNELS, and why. The painters are reached only through
 * spdf_win_paint(), whose scene carries a SpdfWinChromeModel and nothing else,
 * and the model belongs to another track. spdf_win_chrome_scroll_set_hot() set
 * the precedent for "one piece of chrome state that travels from input to
 * painter as a setter rather than in the model", and these four follow it: the
 * app publishes before the paint, the painter reads during it. A headless test
 * that publishes nothing gets the empty state, which is what it drew before.
 * Defined in spdf_win_chrome_sidebar.cpp so every binary that draws the
 * sidebar has them, engine or no engine.
 *
 * C-compatible and Direct2D-free; the geometry is header-only so
 * portable/win/tests/sidebar_rows_test.c drives it with hand-built views.
 */
#ifndef SPDF_WIN_SIDEBAR_VIEW_H
#define SPDF_WIN_SIDEBAR_VIEW_H

#include <math.h>

#include "spdf_win_chrome.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Row heights and insets, POINTS (ShenzhenPDFMac.mm:15869-15871, :16238,
 * :16278-16281, :79-80). */
#define SPDF_WIN_SIDEBAR_RESULT_MATCH_H 46.0
#define SPDF_WIN_SIDEBAR_RESULT_HEADER_H 30.0
#define SPDF_WIN_SIDEBAR_RESULT_STATUS_H 36.0
#define SPDF_WIN_SIDEBAR_RESULT_TITLE_TOP 7.0
#define SPDF_WIN_SIDEBAR_RESULT_SUBTITLE_GAP 2.0
#define SPDF_WIN_SIDEBAR_RESULT_TITLE_FONT 12.0
#define SPDF_WIN_SIDEBAR_RESULT_SUBTITLE_FONT 11.0
#define SPDF_WIN_SIDEBAR_RESULT_STATUS_FONT 12.0
#define SPDF_WIN_SIDEBAR_RESULT_TRAILING 8.0
#define SPDF_WIN_SIDEBAR_RESULT_HEADER_FONT 11.0

typedef enum spdf_win_sidebar_result_kind {
    SPDF_WIN_SIDEBAR_RESULT_STATUS = 0,
    SPDF_WIN_SIDEBAR_RESULT_HEADER,
    SPDF_WIN_SIDEBAR_RESULT_MATCH
} spdf_win_sidebar_result_kind;

typedef struct SpdfWinSidebarResultRow {
    int kind;                 /* spdf_win_sidebar_result_kind */
    const wchar_t* title;     /* borrowed UTF-16; the snippet, the chapter, or the status line */
    const wchar_t* subtitle;  /* MATCH only: "Page N - match I of M"; NULL otherwise */
    int match_index;          /* MATCH only: index into the find session; -1 otherwise */
    int bold_start;           /* MATCH only: first UTF-16 unit of the query in `title`, -1 for none */
    int bold_len;             /* MATCH only: its length in UTF-16 units */
} SpdfWinSidebarResultRow;

typedef struct SpdfWinSidebarResultsView {
    const SpdfWinSidebarResultRow* rows;
    int row_count;
    int current_row; /* the row of the current match, or -1 */
    float scroll_y;  /* device px, 0 at the top of the list */
} SpdfWinSidebarResultsView;

static SPDF_WIN_CHROME_INLINE float spdf_win_sidebar_result_row_h(int kind, float dpi_scale) {
    double pt = kind == SPDF_WIN_SIDEBAR_RESULT_MATCH    ? SPDF_WIN_SIDEBAR_RESULT_MATCH_H
                : kind == SPDF_WIN_SIDEBAR_RESULT_HEADER ? SPDF_WIN_SIDEBAR_RESULT_HEADER_H
                                                         : SPDF_WIN_SIDEBAR_RESULT_STATUS_H;
    return spdf_win_chrome_px(pt, dpi_scale);
}

/* The UNSCROLLED top of `row`, device px; the caller subtracts scroll_y. */
static SPDF_WIN_CHROME_INLINE float spdf_win_sidebar_results_row_top(const SpdfWinSidebarResultsView* v, int row,
                                                                     float dpi_scale) {
    float y = 0.0f;
    int i;
    if (!v || !v->rows || row < 0) return 0.0f;
    for (i = 0; i < row && i < v->row_count; ++i) y += spdf_win_sidebar_result_row_h(v->rows[i].kind, dpi_scale);
    return y;
}

/* The whole list's height, device px. */
static SPDF_WIN_CHROME_INLINE float spdf_win_sidebar_results_height(const SpdfWinSidebarResultsView* v,
                                                                    float dpi_scale) {
    return v ? spdf_win_sidebar_results_row_top(v, v->row_count, dpi_scale) : 0.0f;
}

/* Which row a LIST-LOCAL y lands in (scroll already added), or -1. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_results_row_at(const SpdfWinSidebarResultsView* v, float local_y,
                                                                  float dpi_scale) {
    float y = 0.0f;
    int i;
    if (!v || !v->rows || local_y < 0.0f) return -1;
    for (i = 0; i < v->row_count; ++i) {
        float h = spdf_win_sidebar_result_row_h(v->rows[i].kind, dpi_scale);
        if (local_y < y + h) return i;
        y += h;
    }
    return -1;
}

/* How far the list can scroll, device px. */
static SPDF_WIN_CHROME_INLINE float spdf_win_sidebar_results_max_scroll(const SpdfWinSidebarResultsView* v,
                                                                        float list_h, float dpi_scale) {
    float content = spdf_win_sidebar_results_height(v, dpi_scale);
    return spdf_win_chrome_max(0.0f, content - list_h);
}

/* --- the segment control --------------------------------------------------
 *
 * macOS normalises the segment width to floor(max(minSeg, (sidebarWidth - 16)
 * / segments)) with minSeg 66 for three segments and 78 for two
 * (:3138-3144), so on a narrow sidebar the control can be WIDER than the
 * panel's inner width; it is clamped rather than allowed to overhang. Used by
 * the painter and the router both -- spdf_win_chrome.h's rule that hit-testing
 * and painting agree only if they call the same function. */
static SPDF_WIN_CHROME_INLINE SpdfWinChromeRect spdf_win_sidebar_sections_rect(SpdfWinChromeRect base,
                                                                              SpdfWinChromeRect sidebar,
                                                                              int segments, float dpi_scale) {
    double min_seg = (segments == 3) ? 66.0 : 78.0;
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    double side_pt = sidebar.w / s;
    double seg_pt = floor((side_pt - 16.0) / (double)(segments > 0 ? segments : 1));
    SpdfWinChromeRect bar = base;
    if (seg_pt < min_seg) seg_pt = min_seg;
    bar.w = spdf_win_chrome_px(seg_pt * (double)segments, s);
    if (bar.w > sidebar.w - spdf_win_chrome_px(16.0, s)) bar.w = sidebar.w - spdf_win_chrome_px(16.0, s);
    return bar;
}

/* Which segment a point is on, or -1. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_section_at(SpdfWinChromeRect bar, int segments, float x, float y) {
    int seg;
    if (segments <= 0 || spdf_win_chrome_rect_empty(bar) || !spdf_win_chrome_contains(bar, x, y)) return -1;
    seg = (int)floorf((x - bar.x) / (bar.w / (float)segments));
    if (seg < 0) seg = 0;
    if (seg >= segments) seg = segments - 1;
    return seg;
}

/* WHICH SECTION IS SHOWN, given what the document has to list -- mac
 * rebuildSidebar's cascade (:9552-9580) transcribed: a selected section that
 * has nothing falls back to the first that has something, chapters preferred;
 * a document with exactly one thing to list shows that. 0 chapters, 1 comments,
 * 2 search. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_resolve_section(int selected, int has_chapters, int has_comments,
                                                                   int has_search) {
    if (selected == 2 && !has_search) return has_chapters ? 0 : (has_comments ? 1 : 0);
    if (selected == 1 && !has_comments) return has_chapters ? 0 : (has_search ? 2 : 0);
    if (selected == 0 && !has_chapters) return has_comments ? 1 : (has_search ? 2 : 0);
    if (has_chapters && !has_comments && !has_search) return 0;
    if (!has_chapters && has_comments && !has_search) return 1;
    if (!has_chapters && !has_comments && has_search) return 2;
    if (!has_chapters && !has_comments && !has_search) return 0;
    return selected < 0 || selected > 2 ? 0 : selected;
}

/* --- the builder (spdf_win_sidebar_view.cpp) -------------------------------
 *
 * Turns the find session's matches into the rows above, rebuilding only when
 * the session's revision (or its searching flag) changed, and keeps the list's
 * scroll offset -- revealing the current match's row when it moves, the way an
 * NSTableView scrolls to its selection. `list_h_px` is the list viewport's
 * height in device pixels, for the reveal and the clamp. The returned view is
 * owned by the builder and valid until the next build or free. Linked into the
 * app only; the painters read the published view, never this. */
struct SpdfWinFindSession;
typedef struct SpdfWinSidebarResultsBuilder SpdfWinSidebarResultsBuilder;
SpdfWinSidebarResultsBuilder* spdf_win_sidebar_results_builder_new(void);
void spdf_win_sidebar_results_builder_free(SpdfWinSidebarResultsBuilder* b);
const SpdfWinSidebarResultsView* spdf_win_sidebar_results_build(SpdfWinSidebarResultsBuilder* b,
                                                                struct SpdfWinFindSession* s, int searching,
                                                                float list_h_px, float dpi_scale);
/* Wheel over the list. Returns non-zero when the offset moved. */
int spdf_win_sidebar_results_scroll_by(SpdfWinSidebarResultsBuilder* b, float dy, float list_h_px, float dpi_scale);

/* --- the side channels (spdf_win_chrome_sidebar.cpp) ----------------------- */

/* The Search section's rows for the coming paint. Borrowed: the app keeps the
 * view alive across the paint (it owns the builder). NULL means "nothing
 * built", drawn as the empty state. */
void spdf_win_sidebar_results_publish(const SpdfWinSidebarResultsView* view);
const SpdfWinSidebarResultsView* spdf_win_sidebar_results_current(void);

/* The Comments section's rows for the coming paint, in the SAME row shape --
 * a header per page, a row per comment -- and drawn by the same painter, so the
 * two lists cannot look different. Built by spdf_win_annot.h from the comment
 * cache; borrowed like the results; NULL means none, drawn as "No Comments". */
void spdf_win_sidebar_comments_publish(const SpdfWinSidebarResultsView* view);
const SpdfWinSidebarResultsView* spdf_win_sidebar_comments_current(void);

/* The section the reader chose (0 chapters, 1 comments, 2 search). The app
 * resolves it against what the document has before each paint and pushes the
 * result into both models; this is the chosen value, not the resolved one. */
void spdf_win_sidebar_set_section(int section);
int spdf_win_sidebar_section(void);

/* Whether the sidebar is actually shown: the reader's preference AND the
 * document having something to list, mac rebuildSidebar's
 * `hasSidebar && _sidebarPreferredVisible`. The app decides it once per paint;
 * the input router's layout must read the same answer or a click on the canvas's
 * left 240 px would be swallowed by a panel that is not there. */
void spdf_win_sidebar_set_effective_visible(int visible);
int spdf_win_sidebar_effective_visible(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SIDEBAR_VIEW_H */
