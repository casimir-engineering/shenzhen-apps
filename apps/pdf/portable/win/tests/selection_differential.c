/* selection_differential.c — the Windows selection port against the GTK4
 * originals it was transcribed from, compiled side by side in ONE program.
 *
 * WHAT IS COMPARED, and where each original lives:
 *
 *   spdf_win_selection.h  section 2   <- portable/linux/gtk4/spdf_selection_adapter.c
 *     spdf_win_selection_click_policy            spdf_selection_click_policy
 *     spdf_win_selection_drag_threshold_crossed  spdf_selection_drag_threshold_crossed
 *     spdf_win_selection_gesture_*               spdf_selection_gesture_*
 *
 *   spdf_win_links.h      section 1   <- portable/linux/gtk4/spdf_docview_internal.h
 *     spdf_win_cursor_rect_empty                 spdf_cursor_rect_empty
 *     spdf_win_cursor_rect_contains              spdf_cursor_rect_contains
 *     spdf_win_cursor_region_at_point            spdf_cursor_region_at_point
 *
 * WHY THIS EXISTS AT ALL. Both ports are transcriptions, so a result that
 * differs by one ulp or by one boundary case is a transcription ERROR and not a
 * rounding question -- and this repo's differentials have already caught
 * exactly that once (see spdf_win_layout.h's header). Comparison is therefore
 * EXACT everywhere.
 *
 * HOW THE GTK HEADER COMPILES UNDER MSVC. portable/win/tests/glib_shim/glib.h
 * supplies the glib typedefs and DECLARES (never defines) GArray/GHashTable, so
 * spdf_docview_internal.h compiles and the parts that would need a real glib
 * simply are not called. spdf_selection_adapter.c needs no shim at all -- it is
 * already toolkit-free -- but it does need the core, which is why this program
 * links MuPDF.
 *
 * CONTRACT: the exit code is the whole truth.
 *   0  every comparison identical
 *   1  at least one comparison DIFFERs
 *   2  the matrix did not run
 */
#include "../src/spdf_win_links.h"
#include "../src/spdf_win_selection.h"

/* The GTK4 originals. Included AFTER the port so a name collision would be a
 * compile error here rather than a silent one-definition surprise. */
#include "spdf_docview_internal.h"
#include "spdf_selection_adapter.h"

#include <stdio.h>
#include <string.h>

static int mismatches = 0;
static int comparisons = 0;

static void same_i(const char* what, long long win, long long gtk) {
    ++comparisons;
    if (win != gtk) {
        printf("DIFFER %-46s win=%lld gtk=%lld\n", what, win, gtk);
        ++mismatches;
    }
}

static void same_d(const char* what, double win, double gtk) {
    ++comparisons;
    if (!(win == gtk)) {
        printf("DIFFER %-46s win=%.17g gtk=%.17g\n", what, win, gtk);
        ++mismatches;
    }
}

/* --- the click policy ----------------------------------------------------- */

static void differential_click_policy(void) {
    unsigned counts[] = {0, 1, 2, 3, 4, 7, 100, 4294967295u};
    size_t i;
    char label[96];

    for (i = 0; i < sizeof(counts) / sizeof(counts[0]); ++i) {
        SpdfWinSelectionClickPolicy w = spdf_win_selection_click_policy(counts[i]);
        SpdfSelectionClickPolicy g = spdf_selection_click_policy(counts[i]);
        sprintf(label, "click_policy(%u).granularity", counts[i]);
        same_i(label, (long long)w.granularity, (long long)g.granularity);
        sprintf(label, "click_policy(%u).uses_range_path", counts[i]);
        same_i(label, w.uses_range_path, g.uses_range_path);
        sprintf(label, "click_policy(%u).cancels_pending_link", counts[i]);
        same_i(label, w.cancels_pending_link, g.cancels_pending_link);
    }
}

/* --- the drag threshold --------------------------------------------------- */

static void differential_drag_threshold(void) {
    static const double coords[] = {-1e9, -8.0, -0.5, 0.0, 0.5, 3.0, 8.0, 8.000000000000002, 1e9};
    static const double thresholds[] = {-5.0, -0.0, 0.0, 1e-15, 4.0, 8.0, 1e9};
    size_t a, b, c, d, t;
    char label[128];

    for (a = 0; a < sizeof(coords) / sizeof(coords[0]); ++a)
        for (b = 0; b < sizeof(coords) / sizeof(coords[0]); ++b)
            for (c = 0; c < sizeof(coords) / sizeof(coords[0]); ++c)
                for (d = 0; d < sizeof(coords) / sizeof(coords[0]); ++d)
                    for (t = 0; t < sizeof(thresholds) / sizeof(thresholds[0]); ++t) {
                        int w = spdf_win_selection_drag_threshold_crossed(coords[a], coords[b], coords[c], coords[d],
                                                                          thresholds[t]);
                        int g = spdf_selection_drag_threshold_crossed(coords[a], coords[b], coords[c], coords[d],
                                                                      thresholds[t]);
                        if (w == g) {
                            ++comparisons;
                            continue;
                        }
                        sprintf(label, "drag_crossed(%g,%g,%g,%g,%g)", coords[a], coords[b], coords[c], coords[d],
                                thresholds[t]);
                        same_i(label, w, g);
                    }
}

/* --- the gesture state machine -------------------------------------------- */

/* Every reachable transition, driven identically through both ports and
 * compared field by field after each step. `pending_link` surviving a drag that
 * never crossed the threshold, and `link_cancelled` being SET by a double press
 * that lands on an already-pending link, are the two the mac and GTK code
 * comment on -- so they are what a transcription is most likely to get wrong. */
static void compare_state(const char* where, const SpdfWinSelectionGesture* w, const SpdfSelectionGestureState* g) {
    char label[128];
    sprintf(label, "%s.press_count", where);
    same_i(label, (long long)w->press_count, (long long)g->press_count);
    sprintf(label, "%s.pending_link", where);
    same_i(label, w->pending_link, g->pending_link);
    sprintf(label, "%s.link_cancelled", where);
    same_i(label, w->link_cancelled, g->link_cancelled);
    sprintf(label, "%s.dragging", where);
    same_i(label, w->dragging, g->dragging);
}

static void differential_gesture(void) {
    unsigned presses[] = {0, 1, 2, 3, 5};
    int over_link_values[] = {0, 1};
    double moves[] = {0.0, 2.0, 4.0, 4.5, 40.0};
    size_t p, o, m;
    char where[160];

    for (p = 0; p < sizeof(presses) / sizeof(presses[0]); ++p)
        for (o = 0; o < 2; ++o)
            for (m = 0; m < sizeof(moves) / sizeof(moves[0]); ++m) {
                SpdfWinSelectionGesture w;
                SpdfSelectionGestureState g;
                int over = over_link_values[o];

                spdf_win_selection_gesture_reset(&w);
                spdf_selection_gesture_reset(&g);
                sprintf(where, "reset");
                compare_state(where, &w, &g);

                /* A FIRST press that arms a pending link, so the SECOND press
                 * has something to cancel -- the transition the comments warn
                 * about. */
                spdf_win_selection_gesture_begin(&w, 1, 1);
                spdf_selection_gesture_begin(&g, 1, 1);
                sprintf(where, "begin(1,1) p=%u o=%d m=%g", presses[p], over, moves[m]);
                compare_state(where, &w, &g);

                {
                    SpdfWinSelectionClickPolicy wp = spdf_win_selection_gesture_begin(&w, presses[p], over);
                    SpdfSelectionClickPolicy gp = spdf_selection_gesture_begin(&g, presses[p], over);
                    sprintf(where, "begin(%u,%d).granularity", presses[p], over);
                    same_i(where, (long long)wp.granularity, (long long)gp.granularity);
                    sprintf(where, "begin(%u,%d).uses_range_path", presses[p], over);
                    same_i(where, wp.uses_range_path, gp.uses_range_path);
                    sprintf(where, "begin(%u,%d) state", presses[p], over);
                    compare_state(where, &w, &g);
                }

                {
                    int wd = spdf_win_selection_gesture_update_drag(&w, 10.0, 10.0, 10.0 + moves[m], 10.0, 4.0);
                    int gd = spdf_selection_gesture_update_drag(&g, 10.0, 10.0, 10.0 + moves[m], 10.0, 4.0);
                    sprintf(where, "update_drag(%g) return", moves[m]);
                    same_i(where, wd, gd);
                    sprintf(where, "update_drag(%g) state", moves[m]);
                    compare_state(where, &w, &g);
                }

                {
                    int wt = spdf_win_selection_gesture_take_link(&w);
                    int gt = spdf_selection_gesture_take_link(&g);
                    sprintf(where, "take_link p=%u o=%d m=%g", presses[p], over, moves[m]);
                    same_i(where, wt, gt);
                    compare_state(where, &w, &g);
                }

                /* And the cancellation path, from a fresh armed state. */
                spdf_win_selection_gesture_begin(&w, 1, over);
                spdf_selection_gesture_begin(&g, 1, over);
                spdf_win_selection_gesture_cancel(&w);
                spdf_selection_gesture_cancel(&g);
                sprintf(where, "cancel o=%d", over);
                compare_state(where, &w, &g);
            }
}

/* --- the cursor regions --------------------------------------------------- */

static void differential_cursor_regions(void) {
    /* Two links and two text lines, one of each overlapping, plus degenerate
     * and inverted rects the empty-test must reject. */
    static spdf_rect links[3];
    static spdf_rect text[3];
    static const double xs[] = {-1.0, 0.0, 9.9, 10.0, 10.1, 30.0, 49.9, 50.0, 51.0, 52.0, 52.1, 60.0, 1e9};
    static const double ys[] = {-1.0, 9.0, 10.0, 20.0, 30.0, 31.0, 32.0, 33.0, 1e9};
    static const double slops[] = {0.0, 2.0, SPDF_WIN_CURSOR_LINK_HIT_PADDING, 10.0};
    size_t xi, yi, si;
    char label[160];
    int i;

    links[0].x0 = 10.0f;
    links[0].y0 = 10.0f;
    links[0].x1 = 50.0f;
    links[0].y1 = 30.0f;
    links[1].x0 = 5.0f; /* inverted: empty, must never match */
    links[1].y0 = 40.0f;
    links[1].x1 = 5.0f;
    links[1].y1 = 20.0f;
    links[2] = links[0];
    text[0] = links[0]; /* overlaps a link, so precedence is exercised */
    text[1].x0 = 55.0f;
    text[1].y0 = 12.0f;
    text[1].x1 = 80.0f;
    text[1].y1 = 28.0f;
    text[2].x0 = 0.0f; /* degenerate height */
    text[2].y0 = 20.0f;
    text[2].x1 = 100.0f;
    text[2].y1 = 20.0f;

    for (i = 0; i < 3; ++i) {
        sprintf(label, "cursor_rect_empty(link %d)", i);
        same_i(label, spdf_win_cursor_rect_empty(&links[i]), spdf_cursor_rect_empty(&links[i]) ? 1 : 0);
        sprintf(label, "cursor_rect_empty(text %d)", i);
        same_i(label, spdf_win_cursor_rect_empty(&text[i]), spdf_cursor_rect_empty(&text[i]) ? 1 : 0);
    }
    same_i("cursor_rect_empty(NULL)", spdf_win_cursor_rect_empty(NULL), spdf_cursor_rect_empty(NULL) ? 1 : 0);

    for (xi = 0; xi < sizeof(xs) / sizeof(xs[0]); ++xi)
        for (yi = 0; yi < sizeof(ys) / sizeof(ys[0]); ++yi)
            for (si = 0; si < sizeof(slops) / sizeof(slops[0]); ++si) {
                int w, g;
                for (i = 0; i < 3; ++i) {
                    w = spdf_win_cursor_rect_contains(&links[i], xs[xi], ys[yi], slops[si]);
                    g = spdf_cursor_rect_contains(&links[i], xs[xi], ys[yi], slops[si]) ? 1 : 0;
                    if (w != g) {
                        sprintf(label, "rect_contains(link %d, %g, %g, %g)", i, xs[xi], ys[yi], slops[si]);
                        same_i(label, w, g);
                    } else {
                        ++comparisons;
                    }
                }
                w = (int)spdf_win_cursor_region_at_point(links, 3, text, 3, xs[xi], ys[yi], slops[si]);
                g = (int)spdf_cursor_region_at_point(links, 3, text, 3, xs[xi], ys[yi], slops[si]);
                if (w != g) {
                    sprintf(label, "region_at_point(%g, %g, %g)", xs[xi], ys[yi], slops[si]);
                    same_i(label, w, g);
                } else {
                    ++comparisons;
                }
                /* Empty arrays on either side. */
                w = (int)spdf_win_cursor_region_at_point(NULL, 0, text, 3, xs[xi], ys[yi], slops[si]);
                g = (int)spdf_cursor_region_at_point(NULL, 0, text, 3, xs[xi], ys[yi], slops[si]);
                same_i("region_at_point(no links)", w, g);
                w = (int)spdf_win_cursor_region_at_point(links, 3, NULL, 0, xs[xi], ys[yi], slops[si]);
                g = (int)spdf_cursor_region_at_point(links, 3, NULL, 0, xs[xi], ys[yi], slops[si]);
                same_i("region_at_point(no text)", w, g);
            }

    /* The constants themselves, which is how a "harmless" retune of one side
     * gets caught. */
    same_d("LINK_HIT_PADDING", (double)SPDF_WIN_CURSOR_LINK_HIT_PADDING, (double)SPDF_CURSOR_LINK_HIT_PADDING);
    same_i("MAX_LINK_RECTS", SPDF_WIN_CURSOR_REGION_MAX_LINK_RECTS, SPDF_CURSOR_REGION_MAX_LINK_RECTS);
    same_i("REGION_NONE", SPDF_WIN_CURSOR_REGION_NONE, SPDF_CURSOR_REGION_NONE);
    same_i("REGION_LINK", SPDF_WIN_CURSOR_REGION_LINK, SPDF_CURSOR_REGION_LINK);
    same_i("REGION_TEXT", SPDF_WIN_CURSOR_REGION_TEXT, SPDF_CURSOR_REGION_TEXT);
}

int main(void) {
    differential_click_policy();
    differential_drag_threshold();
    differential_gesture();
    differential_cursor_regions();

    if (comparisons == 0) {
        printf("selection-differential: NOTHING COMPARED -- refusing to report success\n");
        return 2;
    }
    printf("selection-differential: %d comparisons, %d differ\n", comparisons, mismatches);
    return mismatches ? 1 : 0;
}
