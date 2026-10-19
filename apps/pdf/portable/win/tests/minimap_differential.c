/* THE MINIMAP DIFFERENTIAL: portable/win/src/spdf_win_minimap.h versus the GTK4
 * original it was transcribed from, portable/linux/gtk4/spdf_minimap_internal.h,
 * both compiled into ONE binary, driven with identical inputs, compared for
 * EXACT equality.
 *
 * A hand-written test can only assert what its author remembered to assert.
 * This one asserts the whole function against the implementation it was ported
 * from. Doubles are compared with `==` and not an epsilon: the port is a
 * transcription, so a difference of one ulp is a transcription error and not a
 * rounding question. That is not hypothetical -- the same pattern already caught
 * a one-ulp transcription error elsewhere in this port.
 *
 * IT RUNS ON WINDOWS, which is new. portable/win/tests/gtk_differential.c is
 * macOS/Linux-only and run-tests-native.sh records it BLOCKED for want of glib.
 * The two GTK headers this port transcribes need glib only for typedefs, the
 * MAX/MIN/CLAMP macros and g_new0/g_free, so portable/win/tests/glib_shim/glib.h
 * supplies exactly those and the REAL GTK header compiles here unmodified. Both
 * sides are then built by the same MSVC into the same binary, which makes this a
 * PURER transcription check than the cross-host one: a difference cannot be two
 * compilers disagreeing, so it can only be the code.
 *
 * Not named *_test.c on purpose -- same convention as gtk_differential.c -- so
 * run-tests-native.sh's `*_test.c` sweep does not try to build it without the
 * two extra include paths. Build and run it with:
 *
 *   portable\win\tests\minimap-differential-native.cmd
 *
 * and judge it by its exit code.
 */

#include <stdio.h>
#include <string.h>

/* The GTK4 original. Include order matters only in that the shim must be
 * reachable as <glib.h>; the .cmd puts glib_shim on the include path. */
#include "spdf_minimap_internal.h"

/* The port: the geometry header and the input-policy header that continues it. */
#include "spdf_win_minimap.h"
#include "spdf_win_search_map_input.h"

static int mismatches;
static int comparisons;

static void same_d(const char* what, double win, double gtk) {
    comparisons++;
    if (win != gtk) {
        printf("DIFFER %s: win=%.17g gtk=%.17g\n", what, win, gtk);
        mismatches++;
    }
}

static void same_i(const char* what, long long win, long long gtk) {
    comparisons++;
    if (win != gtk) {
        printf("DIFFER %s: win=%lld gtk=%lld\n", what, win, gtk);
        mismatches++;
    }
}

/* Input space, deliberately awkward. A 10900 pt schematic foldout beside an A5
 * page is what the 2.5x median cap exists for; a document of two pages exercises
 * the even-count median; a single page exercises the degenerate strip. Panel
 * widths include macOS's odd 126.5 default and both ends of its [72, 260] clamp,
 * plus a panel narrower than the 18 pt inset. */
static const double kPanelWidths[] = {126.5, 72.0, 260.0, 90.0, 17.0, 18.5, 400.0, 1.0};
static const double kPanelHeights[] = {800.0, 380.0, 40.0, 17.0, 2000.0};
static const double kFractions[] = {0.0, 0.25, 0.5, 0.75, 1.0, -0.5, 1.5};

/* Page-size fixtures, as the two headers' parallel size types. */
#define MAX_PAGES 12
static SpdfPageSizePt g_gtk_sizes[MAX_PAGES];
static SpdfWinPageSizePt g_win_sizes[MAX_PAGES];

static void set_sizes(const double* wh, int count) {
    int i;
    for (i = 0; i < count; ++i) {
        g_gtk_sizes[i].width = wh[i * 2];
        g_gtk_sizes[i].height = wh[i * 2 + 1];
        g_win_sizes[i].width = wh[i * 2];
        g_win_sizes[i].height = wh[i * 2 + 1];
    }
}

/* Six documents: uniform, one foldout, all-different, two pages, one page, and
 * a set with equal widths so the median's insertion-sort tie order is exercised. */
static const double kUniform[] = {612, 792, 612, 792, 612, 792, 612, 792};
static const double kFoldout[] = {612, 792, 10900, 7539, 420, 595, 612, 1584, 612, 792};
static const double kAllDifferent[] = {200, 260, 300, 400, 595, 842, 1000, 500, 90, 700};
static const double kTwoPages[] = {612, 792, 10900, 7539};
static const double kOnePage[] = {595, 842};
static const double kTies[] = {612, 792, 612, 100, 612, 5000, 612, 792};

struct Doc {
    const char* name;
    const double* wh;
    int count;
};

static const struct Doc kDocs[] = {
    {"uniform", kUniform, 4},   {"foldout", kFoldout, 5}, {"alldiff", kAllDifferent, 5},
    {"twopages", kTwoPages, 2}, {"onepage", kOnePage, 1}, {"ties", kTies, 4},
};
static const int kDocCount = (int)(sizeof(kDocs) / sizeof(kDocs[0]));

static void differential_scale(void) {
    int d, p;
    char label[128];

    for (d = 0; d < kDocCount; ++d) {
        set_sizes(kDocs[d].wh, kDocs[d].count);
        sprintf(label, "median[%s]", kDocs[d].name);
        same_d(label, spdf_win_minimap_median_width(g_win_sizes, kDocs[d].count),
               spdf_minimap_median_width(g_gtk_sizes, kDocs[d].count));
        /* Every prefix, so the even/odd median branch and the insertion sort are
         * both walked at every length rather than only the full one. */
        for (p = 0; p <= kDocs[d].count; ++p) {
            sprintf(label, "median[%s][n=%d]", kDocs[d].name, p);
            same_d(label, spdf_win_minimap_median_width(g_win_sizes, p), spdf_minimap_median_width(g_gtk_sizes, p));
        }
        for (p = 0; p < (int)(sizeof(kPanelWidths) / sizeof(kPanelWidths[0])); ++p) {
            double usable = kPanelWidths[p] - SPDF_MINIMAP_SIDE_INSET;
            sprintf(label, "point_scale[%s][panel=%g]", kDocs[d].name, kPanelWidths[p]);
            same_d(label, spdf_win_minimap_point_scale(g_win_sizes, kDocs[d].count, usable),
                   spdf_minimap_point_scale(g_gtk_sizes, kDocs[d].count, usable));
        }
    }
}

static void differential_strip(void) {
    SpdfMinimapStrip gtk;
    SpdfWinMinimapStrip win;
    int d, p, i;
    char label[160];

    memset(&gtk, 0, sizeof(gtk));
    memset(&win, 0, sizeof(win));
    for (d = 0; d < kDocCount; ++d) {
        set_sizes(kDocs[d].wh, kDocs[d].count);
        for (p = 0; p < (int)(sizeof(kPanelWidths) / sizeof(kPanelWidths[0])); ++p) {
            spdf_minimap_strip_compute(&gtk, g_gtk_sizes, kDocs[d].count, kPanelWidths[p]);
            spdf_win_minimap_strip_compute(&win, g_win_sizes, kDocs[d].count, kPanelWidths[p],
                                           SPDF_WIN_MINIMAP_SIDE_INSET, SPDF_WIN_MINIMAP_GAP);
            sprintf(label, "strip.count[%s][panel=%g]", kDocs[d].name, kPanelWidths[p]);
            same_i(label, win.count, gtk.count);
            sprintf(label, "strip.content_h[%s][panel=%g]", kDocs[d].name, kPanelWidths[p]);
            same_d(label, win.content_h, gtk.content_h);
            sprintf(label, "strip.point_scale[%s][panel=%g]", kDocs[d].name, kPanelWidths[p]);
            same_d(label, win.point_scale, gtk.point_scale);
            for (i = 0; i < gtk.count && i < win.count; ++i) {
                sprintf(label, "strip[%s][panel=%g][%d].x", kDocs[d].name, kPanelWidths[p], i);
                same_d(label, win.rects[i].x, gtk.rects[i].x);
                sprintf(label, "strip[%s][panel=%g][%d].y", kDocs[d].name, kPanelWidths[p], i);
                same_d(label, win.rects[i].y, gtk.rects[i].y);
                sprintf(label, "strip[%s][panel=%g][%d].w", kDocs[d].name, kPanelWidths[p], i);
                same_d(label, win.rects[i].w, gtk.rects[i].w);
                sprintf(label, "strip[%s][panel=%g][%d].h", kDocs[d].name, kPanelWidths[p], i);
                same_d(label, win.rects[i].h, gtk.rects[i].h);
            }
        }
    }
    spdf_minimap_strip_clear(&gtk);
    spdf_win_minimap_strip_clear(&win);
}

static void differential_content_top(void) {
    static const double kContentHeights[] = {0.0, 10.0, 300.0, 684.0, 700.0, 2000.0, 100000.0};
    int c, h, f;
    char label[160];

    for (c = 0; c < (int)(sizeof(kContentHeights) / sizeof(kContentHeights[0])); ++c)
        for (h = 0; h < (int)(sizeof(kPanelHeights) / sizeof(kPanelHeights[0])); ++h)
            for (f = 0; f < (int)(sizeof(kFractions) / sizeof(kFractions[0])); ++f) {
                sprintf(label, "content_top[content=%g][panel_h=%g][frac=%g]", kContentHeights[c], kPanelHeights[h],
                        kFractions[f]);
                same_d(label,
                       spdf_win_minimap_content_top(kContentHeights[c], kPanelHeights[h], SPDF_WIN_MINIMAP_EDGE_INSET,
                                                    SPDF_WIN_MINIMAP_TOP_PAD, kFractions[f]),
                       spdf_minimap_content_top(kContentHeights[c], kPanelHeights[h], kFractions[f]));
            }
}

static void differential_hit_and_range(void) {
    SpdfMinimapStrip gtk;
    SpdfWinMinimapStrip win;
    int d, i, step;
    char label[160];

    memset(&gtk, 0, sizeof(gtk));
    memset(&win, 0, sizeof(win));
    for (d = 0; d < kDocCount; ++d) {
        set_sizes(kDocs[d].wh, kDocs[d].count);
        spdf_minimap_strip_compute(&gtk, g_gtk_sizes, kDocs[d].count, 126.5);
        spdf_win_minimap_strip_compute(&win, g_win_sizes, kDocs[d].count, 126.5, SPDF_WIN_MINIMAP_SIDE_INSET,
                                       SPDF_WIN_MINIMAP_GAP);
        /* Sweep the whole strip, plus above and below it, at a step small
         * enough to land inside pages AND inside gaps. */
        for (step = -20; step * 7 < (int)gtk.content_h + 40; ++step) {
            double y = (double)(step * 7);
            int gp = -1, wp = -1;
            double gx = -1.0, gy = -1.0, wx = -1.0, wy = -1.0;
            int ghit = spdf_minimap_page_hit(&gtk, 40.0, y, &gp, &gx, &gy) ? 1 : 0;
            int whit = spdf_win_minimap_page_hit(&win, 40.0, y, &wp, &wx, &wy) ? 1 : 0;
            sprintf(label, "page_hit[%s][y=%g].hit", kDocs[d].name, y);
            same_i(label, whit, ghit);
            if (ghit && whit) {
                sprintf(label, "page_hit[%s][y=%g].page", kDocs[d].name, y);
                same_i(label, wp, gp);
                sprintf(label, "page_hit[%s][y=%g].xf", kDocs[d].name, y);
                same_d(label, wx, gx);
                sprintf(label, "page_hit[%s][y=%g].yf", kDocs[d].name, y);
                same_d(label, wy, gy);
            }
            /* x outside the rect on both sides: the clamp is part of the port. */
            spdf_minimap_page_hit(&gtk, -99.0, y, &gp, &gx, NULL);
            spdf_win_minimap_page_hit(&win, -99.0, y, &wp, &wx, NULL);
            sprintf(label, "page_hit[%s][y=%g].xf_left", kDocs[d].name, y);
            same_d(label, wx, gx);
            spdf_minimap_page_hit(&gtk, 9999.0, y, &gp, &gx, NULL);
            spdf_win_minimap_page_hit(&win, 9999.0, y, &wp, &wx, NULL);
            sprintf(label, "page_hit[%s][y=%g].xf_right", kDocs[d].name, y);
            same_d(label, wx, gx);
        }
        for (i = -1; i < 6; ++i) {
            double y0 = (double)i * 60.0;
            double y1 = y0 + 150.0;
            int gf = -9, gl = -9, wf = -9, wl = -9;
            int gr = spdf_minimap_strip_visible_range(&gtk, y0, y1, &gf, &gl) ? 1 : 0;
            int wr = spdf_win_minimap_strip_visible_range(&win, y0, y1, &wf, &wl) ? 1 : 0;
            sprintf(label, "visible_range[%s][%g,%g].ok", kDocs[d].name, y0, y1);
            same_i(label, wr, gr);
            sprintf(label, "visible_range[%s][%g,%g].first", kDocs[d].name, y0, y1);
            same_i(label, wf, gf);
            sprintf(label, "visible_range[%s][%g,%g].last", kDocs[d].name, y0, y1);
            same_i(label, wl, gl);
        }
    }
    spdf_minimap_strip_clear(&gtk);
    spdf_win_minimap_strip_clear(&win);
}

static void differential_mapping(void) {
    SpdfMinimapStrip gtk;
    SpdfWinMinimapStrip win;
    double doc_x[MAX_PAGES], doc_y[MAX_PAGES], doc_w[MAX_PAGES], doc_h[MAX_PAGES];
    int d, i, step;
    char label[192];

    memset(&gtk, 0, sizeof(gtk));
    memset(&win, 0, sizeof(win));
    for (d = 0; d < kDocCount; ++d) {
        double y = 13.0;
        set_sizes(kDocs[d].wh, kDocs[d].count);
        spdf_minimap_strip_compute(&gtk, g_gtk_sizes, kDocs[d].count, 126.5);
        spdf_win_minimap_strip_compute(&win, g_win_sizes, kDocs[d].count, 126.5, SPDF_WIN_MINIMAP_SIDE_INSET,
                                       SPDF_WIN_MINIMAP_GAP);
        /* A plausible document layout at zoom 1.2, with the 26 px inter-page gap
         * the shared layout layer uses. */
        for (i = 0; i < kDocs[d].count; ++i) {
            doc_w[i] = g_gtk_sizes[i].width * 1.2;
            doc_h[i] = g_gtk_sizes[i].height * 1.2;
            doc_x[i] = (2000.0 - doc_w[i]) * 0.5;
            doc_y[i] = y;
            y += doc_h[i] + 26.0;
        }
        for (step = -3; step * 137 < (int)y + 400; ++step) {
            double dy = (double)(step * 137);
            sprintf(label, "strip_y_for_doc_y[%s][%g]", kDocs[d].name, dy);
            same_d(label, spdf_win_minimap_strip_y_for_document_y(&win, doc_y, doc_h, kDocs[d].count, dy),
                   spdf_minimap_strip_y_for_document_y(&gtk, doc_y, doc_h, kDocs[d].count, dy));
        }
        for (step = -3; step * 11 < (int)gtk.content_h + 40; ++step) {
            double sy = (double)(step * 11);
            sprintf(label, "doc_y_for_strip_y[%s][%g]", kDocs[d].name, sy);
            same_d(label, spdf_win_minimap_document_y_for_strip_y(&win, doc_y, doc_h, kDocs[d].count, sy),
                   spdf_minimap_document_y_for_strip_y(&gtk, doc_y, doc_h, kDocs[d].count, sy));
        }
        /* The viewport rect, at three zoom-ish horizontal windows and several
         * scroll positions -- the union-of-page-intersections branch AND the
         * full-width fallback. */
        for (step = 0; step < 8; ++step) {
            double top = (double)step * 260.0;
            double left = (double)step * 40.0;
            static const double kVisW[] = {2000.0, 400.0, 60.0, 0.0};
            int v;
            for (v = 0; v < 4; ++v) {
                double gx = -1, gy = -1, gw = -1, gh = -1, wx = -1, wy = -1, ww = -1, wh = -1;
                spdf_minimap_viewport_rect(&gtk, doc_x, doc_y, doc_w, doc_h, kDocs[d].count, left, top, kVisW[v],
                                           700.0, 126.5, &gx, &gy, &gw, &gh);
                spdf_win_minimap_viewport_rect(&win, doc_x, doc_y, doc_w, doc_h, kDocs[d].count, left, top, kVisW[v],
                                               700.0, 126.5, &wx, &wy, &ww, &wh);
                sprintf(label, "viewport[%s][top=%g][visw=%g].x", kDocs[d].name, top, kVisW[v]);
                same_d(label, wx, gx);
                sprintf(label, "viewport[%s][top=%g][visw=%g].y", kDocs[d].name, top, kVisW[v]);
                same_d(label, wy, gy);
                sprintf(label, "viewport[%s][top=%g][visw=%g].w", kDocs[d].name, top, kVisW[v]);
                same_d(label, ww, gw);
                sprintf(label, "viewport[%s][top=%g][visw=%g].h", kDocs[d].name, top, kVisW[v]);
                same_d(label, wh, gh);
            }
        }
        /* Search-hit tick placement, per page and per page fraction. */
        for (i = 0; i < gtk.count && i < win.count; ++i) {
            int k;
            for (k = -1; k <= 11; ++k) {
                double center = g_gtk_sizes[i].height * (double)k / 10.0;
                sprintf(label, "marker_y[%s][%d][%d]", kDocs[d].name, i, k);
                same_d(label,
                       spdf_win_minimap_marker_y(&win.rects[i], center, g_win_sizes[i].height,
                                                 SPDF_WIN_MINIMAP_MARKER_TICK_H),
                       spdf_minimap_marker_y(&gtk.rects[i], center, g_gtk_sizes[i].height, SPDF_MINIMAP_MARKER_TICK_H));
            }
        }
    }
    spdf_minimap_strip_clear(&gtk);
    spdf_win_minimap_strip_clear(&win);
}

static void differential_thumb_window(void) {
    static const int kCounts[] = {0, 1, 5, 40, 200, 500};
    SpdfMinimapThumbWindow gtk_prev = spdf_minimap_thumb_window_empty();
    SpdfWinMinimapThumbWindow win_prev = spdf_win_minimap_thumb_window_empty();
    int c, first, page;
    char label[160];

    for (c = 0; c < (int)(sizeof(kCounts) / sizeof(kCounts[0])); ++c) {
        gtk_prev = spdf_minimap_thumb_window_empty();
        win_prev = spdf_win_minimap_thumb_window_empty();
        /* Walk a viewport across the document in fives, carrying the previous
         * window forward -- which is the only way the hysteresis branch is
         * reached at all. Also feed a REVERSED range, which the function swaps. */
        for (first = -10; first <= kCounts[c] + 10; first += 5) {
            SpdfMinimapThumbWindow g = spdf_minimap_thumb_window_for_visible_range(kCounts[c], first, first + 4,
                                                                                  gtk_prev);
            SpdfWinMinimapThumbWindow w =
                spdf_win_minimap_thumb_window_for_visible_range(kCounts[c], first, first + 4, win_prev);
            sprintf(label, "thumb_window[n=%d][first=%d].start", kCounts[c], first);
            same_i(label, w.start, g.start);
            sprintf(label, "thumb_window[n=%d][first=%d].end", kCounts[c], first);
            same_i(label, w.end, g.end);
            sprintf(label, "thumb_window[n=%d][first=%d].valid", kCounts[c], first);
            same_i(label, spdf_win_minimap_thumb_window_valid(w) ? 1 : 0,
                   spdf_minimap_thumb_window_valid(g) ? 1 : 0);
            for (page = -1; page <= kCounts[c] + 1; ++page) {
                sprintf(label, "thumb_window[n=%d][first=%d].contains(%d)", kCounts[c], first, page);
                same_i(label, spdf_win_minimap_thumb_window_contains(w, page) ? 1 : 0,
                       spdf_minimap_thumb_window_contains(g, page) ? 1 : 0);
                sprintf(label, "thumb_window[n=%d][first=%d].evict(%d)", kCounts[c], first, page);
                same_i(label, spdf_win_minimap_thumb_window_should_evict(w, page) ? 1 : 0,
                       spdf_minimap_thumb_window_should_evict(g, page) ? 1 : 0);
            }
            gtk_prev = g;
            win_prev = w;
        }
        /* The reversed-range swap, from a clean slate. */
        {
            SpdfMinimapThumbWindow g = spdf_minimap_thumb_window_for_visible_range(
                kCounts[c], 30, 10, spdf_minimap_thumb_window_empty());
            SpdfWinMinimapThumbWindow w = spdf_win_minimap_thumb_window_for_visible_range(
                kCounts[c], 30, 10, spdf_win_minimap_thumb_window_empty());
            sprintf(label, "thumb_window[n=%d][reversed].start", kCounts[c]);
            same_i(label, w.start, g.start);
            sprintf(label, "thumb_window[n=%d][reversed].end", kCounts[c]);
            same_i(label, w.end, g.end);
        }
    }
    /* The constants themselves must be the same numbers in both headers. */
    same_d("const.GAP", SPDF_WIN_MINIMAP_GAP, SPDF_MINIMAP_GAP);
    same_d("const.SIDE_INSET", SPDF_WIN_MINIMAP_SIDE_INSET, SPDF_MINIMAP_SIDE_INSET);
    same_d("const.EDGE_INSET", SPDF_WIN_MINIMAP_EDGE_INSET, SPDF_MINIMAP_EDGE_INSET);
    same_d("const.TOP_PAD", SPDF_WIN_MINIMAP_TOP_PAD, SPDF_MINIMAP_TOP_PAD);
    same_d("const.MAX_WIDTH_RATIO", SPDF_WIN_MINIMAP_MAX_WIDTH_RATIO, SPDF_MINIMAP_MAX_WIDTH_RATIO);
    same_d("const.MARKER_TICK_H", SPDF_WIN_MINIMAP_MARKER_TICK_H, SPDF_MINIMAP_MARKER_TICK_H);
    same_i("const.THUMB_MAX_BYTES", (long long)SPDF_WIN_MINIMAP_THUMB_MAX_BYTES,
           (long long)SPDF_MINIMAP_THUMB_MAX_BYTES);
    same_i("const.WINDOW_EXTRA_PAGES", SPDF_WIN_MINIMAP_WINDOW_EXTRA_PAGES, SPDF_MINIMAP_WINDOW_EXTRA_PAGES);
    same_i("const.RECENTER_MARGIN", SPDF_WIN_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES,
           SPDF_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES);
    same_i("const.EVICT_SLACK", SPDF_WIN_MINIMAP_WINDOW_EVICT_SLACK_PAGES, SPDF_MINIMAP_WINDOW_EVICT_SLACK_PAGES);
}

/* The input-policy section, spdf_win_search_map_input.h versus the same GTK
 * header: in minimap_differential_input.h, included here so it sees the
 * fixtures and comparators above. */
#include "minimap_differential_input.h"

int main(void) {
    differential_scale();
    differential_strip();
    differential_content_top();
    differential_hit_and_range();
    differential_mapping();
    differential_thumb_window();
    differential_input_policy();

    /* One program, one verdict: refuse to report success unless the whole matrix
     * actually ran. The count is a floor, not an exact figure, so adding cases
     * does not force an edit here. */
    if (comparisons < 20000) {
        printf("DIFFER matrix did not run: only %d comparisons\n", comparisons);
        return 2;
    }
    if (mismatches) {
        printf("%d of %d minimap differential comparison(s) DIFFER\n", mismatches, comparisons);
        return 1;
    }
    printf("All %d minimap differential comparisons identical\n", comparisons);
    return 0;
}
