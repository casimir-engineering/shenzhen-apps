/* THE SEARCH DIFFERENTIAL: portable/win/src/spdf_win_search.h versus the GTK4
 * original it was transcribed from, portable/linux/gtk4/spdf_search_internal.h,
 * both compiled into ONE binary, driven with identical inputs, compared for
 * EXACT equality.
 *
 * Same instrument as portable/win/tests/minimap_differential.c and for the same
 * reason: a hand-written test can only assert what its author remembered, while
 * this one asserts each function against the implementation it was ported from.
 * Doubles are compared with `==` rather than an epsilon and strings with strcmp
 * -- the port is a transcription, so a difference of one ulp or one byte is a
 * transcription error and not a rounding question. Both sides are built by the
 * SAME MSVC into the SAME binary, so a difference cannot be two compilers
 * disagreeing. The GTK header needs glib for GArray, its string helpers and its
 * MAX/CLAMP macros; portable/win/tests/glib_shim_search/ supplies exactly those
 * over the shared portable/win/tests/glib_shim/ (see that file's header for why
 * it is a second directory rather than a bigger shim).
 *
 * Not named *_test.c on purpose -- same convention as minimap_differential.c --
 * so run-tests-native.sh's `*_test.c` sweep does not try to build it without the
 * three extra include paths. Build and run it with:
 *
 *   portable\win\tests\search-differential-native.cmd
 *
 * and judge it by its exit code.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The GTK4 original. The .cmd puts glib_shim_search on the include path first,
 * so its <glib.h> is the layered shim. */
#include "spdf_search_internal.h"

/* The port. */
#include "spdf_win_search.h"

static int mismatches;
static long comparisons;

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

static void same_s(const char* what, const char* win, const char* gtk) {
    comparisons++;
    if ((win == NULL) != (gtk == NULL) || (win && gtk && strcmp(win, gtk) != 0)) {
        printf("DIFFER %s: win=\"%s\" gtk=\"%s\"\n", what, win ? win : "(null)", gtk ? gtk : "(null)");
        mismatches++;
    }
}

/* --------------------------------------------------------------------------
 * 1. The counter string.
 *
 * Every buffer length from 1 up, because g_strlcpy's truncation is part of what
 * is being reproduced: "0 / 0" into a 3-byte buffer must give "0 " and a NUL on
 * both sides, and the port had to spell that out by hand. */
static void differential_counter(void) {
    static const int kTotals[] = {-5, -1, 0, 1, 2, 9, 10, 99, 100, 1000, 19999, 20000, 2147483647};
    static const int kCurrents[] = {-2, -1, 0, 1, 8, 98, 999, 19998, 2147483646};
    static const size_t kLens[] = {1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 32, 64};
    char label[160];
    int has_query, t, c;
    size_t l;

    for (has_query = 0; has_query <= 1; ++has_query) {
        for (t = 0; t < (int)(sizeof(kTotals) / sizeof(kTotals[0])); ++t) {
            for (c = 0; c < (int)(sizeof(kCurrents) / sizeof(kCurrents[0])); ++c) {
                for (l = 0; l < sizeof(kLens) / sizeof(kLens[0]); ++l) {
                    char wbuf[80];
                    char gbuf[80];
                    /* Prefilled with a sentinel so a function that writes
                     * nothing is distinguishable from one that writes "". */
                    memset(wbuf, '#', sizeof(wbuf));
                    memset(gbuf, '#', sizeof(gbuf));
                    wbuf[sizeof(wbuf) - 1] = 0;
                    gbuf[sizeof(gbuf) - 1] = 0;
                    spdf_win_search_counter_text(wbuf, kLens[l], has_query, kCurrents[c], kTotals[t]);
                    spdf_search_counter_text(gbuf, kLens[l], has_query, kCurrents[c], kTotals[t]);
                    sprintf(label, "counter[q=%d,cur=%d,total=%d,len=%u]", has_query, kCurrents[c], kTotals[t],
                            (unsigned)kLens[l]);
                    same_s(label, wbuf, gbuf);
                }
            }
        }
    }
}

/* --------------------------------------------------------------------------
 * 2. Query duplication and the 2048-byte cap on a UTF-8 boundary. The
 * interesting inputs are the ones where byte 2048 lands INSIDE a character: 2
 * bytes per char divides 2048 exactly, 3 does not, 4 does. */
static char* repeat(const char* unit, size_t times) {
    size_t n = strlen(unit);
    char* out = (char*)malloc(n * times + 1);
    size_t i;
    for (i = 0; i < times; ++i) memcpy(out + i * n, unit, n);
    out[n * times] = 0;
    return out;
}

static void one_query(const char* label, const char* text) {
    char* w = spdf_win_search_dup_query(text);
    char* g = spdf_search_dup_query(text);
    same_s(label, w, g);
    same_i(label, w ? (long long)strlen(w) : -1, g ? (long long)strlen(g) : -1);
    free(w);
    g_free(g);
}

static void differential_dup_query(void) {
    static const char* kUnits[] = {"a", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x94\x8d"};
    static const char* kNames[] = {"ascii", "2byte", "3byte", "4byte"};
    char label[96];
    int u;
    size_t chars;

    one_query("query[null]", NULL);
    one_query("query[empty]", "");
    one_query("query[plain]", "invoice");
    one_query("query[spaces]", "  spaced  out  ");

    for (u = 0; u < 4; ++u) {
        /* Straddle the cap: enough characters that the total goes from just
         * under 2048 bytes to well over it, one character at a time. */
        for (chars = 500; chars <= 700; ++chars) {
            char* text = repeat(kUnits[u], chars);
            sprintf(label, "query[%s x %u]", kNames[u], (unsigned)chars);
            one_query(label, text);
            free(text);
        }
        {
            char* text = repeat(kUnits[u], 4000);
            sprintf(label, "query[%s x 4000]", kNames[u]);
            one_query(label, text);
            free(text);
        }
    }
}

/* --------------------------------------------------------------------------
 * 3. Nearest-match selection. */
static void differential_nearest(void) {
    static const int kPagesA[] = {0, 0, 3, 3, 7, 12, 12, 40};
    static const double kCentersA[] = {10.0, 900.0, 2400.0, 2500.0, 5600.0, 9000.0, 9100.0, 32000.0};
    static const int kPagesB[] = {5};
    static const double kCentersB[] = {4000.0};
    static const int kPagesC[] = {2, 2, 2, 2};
    /* Equal centres, so only the strict-comparison tie rule decides. */
    static const double kCentersC[] = {1600.0, 1600.0, 1600.0, 1600.0};
    static const double kViewports[] = {-1000.0, 0.0, 500.0, 2450.0, 9050.0, 32000.0, 1e9};
    struct {
        const char* name;
        const int* pages;
        const double* centers;
        int count;
    } sets[3];
    char label[128];
    int s, first, last, v, n;

    sets[0].name = "spread";
    sets[0].pages = kPagesA;
    sets[0].centers = kCentersA;
    sets[0].count = 8;
    sets[1].name = "single";
    sets[1].pages = kPagesB;
    sets[1].centers = kCentersB;
    sets[1].count = 1;
    sets[2].name = "ties";
    sets[2].pages = kPagesC;
    sets[2].centers = kCentersC;
    sets[2].count = 4;

    /* count = 0 and NULL inputs, which are the -1 paths. */
    same_i("nearest[empty]", spdf_win_search_nearest_match(kPagesA, kCentersA, 0, 0, 0, 0.0),
           spdf_search_nearest_match(kPagesA, kCentersA, 0, 0, 0, 0.0));
    same_i("nearest[nullpages]", spdf_win_search_nearest_match(NULL, kCentersA, 4, 0, 0, 0.0),
           spdf_search_nearest_match(NULL, kCentersA, 4, 0, 0, 0.0));
    same_i("nearest[nullcenters]", spdf_win_search_nearest_match(kPagesA, NULL, 4, 0, 0, 0.0),
           spdf_search_nearest_match(kPagesA, NULL, 4, 0, 0, 0.0));

    for (s = 0; s < 3; ++s) {
        for (n = 1; n <= sets[s].count; ++n) {
            /* Reversed ranges too: the port swaps them, and a swap done in the
             * wrong order changes which page distance wins. */
            for (first = -2; first <= 14; ++first) {
                for (last = -2; last <= 14; ++last) {
                    for (v = 0; v < (int)(sizeof(kViewports) / sizeof(kViewports[0])); ++v) {
                        sprintf(label, "nearest[%s,n=%d,%d..%d,v=%d]", sets[s].name, n, first, last, v);
                        same_i(label,
                               spdf_win_search_nearest_match(sets[s].pages, sets[s].centers, n, first, last,
                                                             kViewports[v]),
                               spdf_search_nearest_match(sets[s].pages, sets[s].centers, n, first, last,
                                                         kViewports[v]));
                    }
                }
            }
        }
    }
}

/* --------------------------------------------------------------------------
 * 4. Heat-map tick layout. CLAMP's argument order decides the lane_h < tick_h
 * and negative-fraction cases -- what a "tidied" rewrite gets wrong. */
static void differential_markers(void) {
    static const double kCenters[] = {-100.0, 0.0, 1.0, 400.0, 12345.5, 1e6};
    static const double kDocHeights[] = {0.0, -50.0, 1.0, 792.0, 12345.5, 1e6};
    static const double kFractions[] = {-1.0, -0.001, 0.0, 0.25, 0.5, 0.75, 1.0, 1.001, 2.0};
    static const double kLanes[] = {0.0, 1.0, 2.5, 3.0, 3.5, 15.0, 63.0, 800.0, 1200.5};
    static const double kTicks[] = {0.0, 1.0, 1.5, 2.0, 3.0, 4.5};
    char label[128];
    int c, d, f, l, t;

    for (c = 0; c < 6; ++c)
        for (d = 0; d < 6; ++d) {
            sprintf(label, "marker_fraction[c=%d,d=%d]", c, d);
            same_d(label, spdf_win_search_marker_fraction(kCenters[c], kDocHeights[d]),
                   spdf_search_marker_fraction(kCenters[c], kDocHeights[d]));
        }

    for (f = 0; f < 9; ++f)
        for (l = 0; l < 9; ++l)
            for (t = 0; t < 6; ++t) {
                sprintf(label, "marker_y[f=%d,l=%d,t=%d]", f, l, t);
                same_d(label, spdf_win_search_marker_y(kFractions[f], kLanes[l], kTicks[t]),
                       spdf_search_marker_y(kFractions[f], kLanes[l], kTicks[t]));
            }

    /* The default tick height must be the same constant on both sides. */
    same_d("marker_tick_h", (double)SPDF_WIN_SEARCH_MARKER_TICK_H, (double)SPDF_SEARCH_MARKER_TICK_H);
    same_i("max_matches", SPDF_WIN_SEARCH_MAX_MATCHES, SPDF_SEARCH_MAX_MATCHES);
    same_i("max_query_bytes", SPDF_WIN_SEARCH_MAX_QUERY_BYTES, SPDF_SEARCH_MAX_QUERY_BYTES);
}

/* --------------------------------------------------------------------------
 * 5. Chapter attribution. */
static void differential_chapters(void) {
    static const int kNone[] = {0};
    static const int kFlat[] = {0, 0, 0};
    static const int kSteps[] = {0, 3, 3, 8, 20, 20, 21, 99};
    static const int kLate[] = {5, 6, 7};
    struct {
        const char* name;
        const int* pages;
        int count;
    } sets[4];
    char label[96];
    int s, n, page;

    sets[0].name = "none";
    sets[0].pages = kNone;
    sets[0].count = 0;
    sets[1].name = "flat";
    sets[1].pages = kFlat;
    sets[1].count = 3;
    sets[2].name = "steps";
    sets[2].pages = kSteps;
    sets[2].count = 8;
    sets[3].name = "late";
    sets[3].pages = kLate;
    sets[3].count = 3;

    same_i("chapter[null]", spdf_win_search_chapter_for_page(NULL, 4, 3), spdf_search_chapter_for_page(NULL, 4, 3));

    for (s = 0; s < 4; ++s)
        for (n = 0; n <= sets[s].count; ++n)
            for (page = -3; page <= 105; ++page) {
                sprintf(label, "chapter[%s,n=%d,p=%d]", sets[s].name, n, page);
                same_i(label, spdf_win_search_chapter_for_page(sets[s].pages, n, page),
                       spdf_search_chapter_for_page(sets[s].pages, n, page));
            }
}

/* --------------------------------------------------------------------------
 * 6. Rect intersection and 7. the snippet. */
static void differential_snippet(void) {
    /* Lines down a page, plus two degenerate ones and two with whitespace that
     * only the strip removes. */
    static const char* kTexts[] = {"  Chapter One  ",
                                   "",
                                   "The quick brown fox",
                                   "\t\ttabbed line\r\n",
                                   "jumps over the lazy dog",
                                   "   ",
                                   "final line"};
    static const spdf_rect kBounds[] = {{72.0f, 60.0f, 520.0f, 78.0f},   {72.0f, 90.0f, 520.0f, 108.0f},
                                        {72.0f, 120.0f, 520.0f, 138.0f}, {72.0f, 150.0f, 520.0f, 168.0f},
                                        {72.0f, 180.0f, 520.0f, 198.0f}, {72.0f, 210.0f, 520.0f, 228.0f},
                                        {72.0f, 700.0f, 520.0f, 718.0f}};
    static const double kSlops[] = {-1.0, 0.0, 0.5, 2.0, 40.0};
    char label[128];
    int i, j, s, n;

    for (i = 0; i < 7; ++i)
        for (j = 0; j < 7; ++j)
            for (s = 0; s < 5; ++s) {
                sprintf(label, "intersect[%d,%d,slop=%d]", i, j, s);
                same_i(label, spdf_win_search_rects_intersect(&kBounds[i], &kBounds[j], kSlops[s]) ? 1 : 0,
                       spdf_search_rects_intersect(&kBounds[i], &kBounds[j], kSlops[s]) ? 1 : 0);
            }

    /* Match rects that hit a line, that fall between two lines, that sit above
     * the first and below the last, and one with zero height. */
    for (n = 0; n <= 7; ++n) {
        float y;
        for (y = 0.0f; y < 780.0f; y += 7.0f) {
            spdf_rect match;
            char* w;
            char* g;
            match.x0 = 100.0f;
            match.x1 = 160.0f;
            match.y0 = y;
            match.y1 = y + (float)(((int)y % 3) * 6);
            w = spdf_win_search_snippet(kTexts, kBounds, n, match);
            g = spdf_search_snippet(kTexts, kBounds, n, match);
            sprintf(label, "snippet[n=%d,y=%.0f]", n, (double)y);
            same_s(label, w, g);
            free(w);
            g_free(g);
        }
    }

    /* A NULL text array is the "no lines at all" path. */
    {
        spdf_rect match;
        char* w;
        char* g;
        match.x0 = 0.0f;
        match.y0 = 0.0f;
        match.x1 = 10.0f;
        match.y1 = 10.0f;
        w = spdf_win_search_snippet(NULL, kBounds, 3, match);
        g = spdf_search_snippet(NULL, kBounds, 3, match);
        same_s("snippet[nulltexts]", w, g);
        free(w);
        g_free(g);
    }
}

/* --------------------------------------------------------------------------
 * 8. The match list: append order, the cap, clear and the batch steal.
 *
 * The cap is checked at its exact boundary rather than near it: the original's
 * test is `>=` on the length BEFORE the append, and an off-by-one there is
 * invisible at any other size. Snippets are compared too. */
static char* snippet_for(int i) {
    char buf[32];
    sprintf(buf, "snip-%d", i);
    return spdf_win_search_dup_bytes(buf, strlen(buf));
}

static char* g_snippet_for(int i) {
    char buf[32];
    sprintf(buf, "snip-%d", i);
    return g_strdup(buf);
}

static void compare_lists(const char* what, const SpdfWinSearchMatchList* w, const SpdfSearchMatchList* g) {
    char label[160];
    unsigned i;
    unsigned wn = spdf_win_search_match_list_count(w);
    guint gn = spdf_search_match_list_count(g);
    sprintf(label, "%s.count", what);
    same_i(label, wn, gn);
    if (wn != gn) return;
    for (i = 0; i < wn; ++i) {
        const SpdfWinSearchMatch* wm = spdf_win_search_match_list_get(w, i);
        const SpdfSearchMatch* gm = spdf_search_match_list_get(g, i);
        sprintf(label, "%s[%u].page", what, i);
        same_i(label, wm->page, gm->page);
        sprintf(label, "%s[%u].chapter", what, i);
        same_i(label, wm->chapter_index, gm->chapter_index);
        sprintf(label, "%s[%u].y0", what, i);
        same_d(label, wm->rect.y0, gm->rect.y0);
        sprintf(label, "%s[%u].snippet", what, i);
        same_s(label, wm->snippet, gm->snippet);
    }
    /* Out of range on both sides. */
    sprintf(label, "%s[oob]", what);
    same_i(label, spdf_win_search_match_list_get(w, wn) == NULL, spdf_search_match_list_get(g, gn) == NULL);
}

static void differential_match_list(void) {
    SpdfWinSearchMatchList w, wb;
    SpdfSearchMatchList g, gb;
    int i;

    spdf_win_search_match_list_init(&w);
    spdf_search_match_list_init(&g);

    for (i = 0; i < 300; ++i) {
        spdf_rect r;
        char label[64];
        int wok, gok;
        r.x0 = (float)i;
        r.y0 = (float)(i * 3);
        r.x1 = (float)(i + 40);
        r.y1 = (float)(i * 3 + 12);
        wok = spdf_win_search_match_list_append(&w, i % 17, r, snippet_for(i), i % 5 - 1);
        gok = spdf_search_match_list_append(&g, i % 17, r, g_snippet_for(i), i % 5 - 1) ? 1 : 0;
        sprintf(label, "append[%d].accepted", i);
        same_i(label, wok, gok);
    }
    compare_lists("list.grown", &w, &g);

    /* Batch steal, the worker->main delivery path. */
    spdf_win_search_match_list_init(&wb);
    spdf_search_match_list_init(&gb);
    for (i = 0; i < 90; ++i) {
        spdf_rect r;
        r.x0 = 1.0f;
        r.y0 = (float)(1000 + i);
        r.x1 = 2.0f;
        r.y1 = (float)(1010 + i);
        spdf_win_search_match_list_append(&wb, 99, r, snippet_for(1000 + i), 7);
        spdf_search_match_list_append(&gb, 99, r, g_snippet_for(1000 + i), 7);
    }
    spdf_win_search_match_list_steal_into(&w, &wb);
    spdf_search_match_list_steal_into(&g, &gb);
    compare_lists("list.stolen", &w, &g);
    same_i("steal.src_emptied", spdf_win_search_match_list_count(&wb), spdf_search_match_list_count(&gb));

    spdf_win_search_match_list_clear(&w);
    spdf_search_match_list_clear(&g);
    compare_lists("list.cleared", &w, &g);

    /* Now the cap, exactly. Filling to MAX and one past it on both sides. */
    for (i = 0; i < SPDF_WIN_SEARCH_MAX_MATCHES + 3; ++i) {
        spdf_rect r;
        r.x0 = 0.0f;
        r.y0 = (float)i;
        r.x1 = 1.0f;
        r.y1 = (float)i + 1.0f;
        {
            int wok = spdf_win_search_match_list_append(&w, i & 255, r, snippet_for(i), -1);
            int gok = spdf_search_match_list_append(&g, i & 255, r, g_snippet_for(i), -1) ? 1 : 0;
            if (wok != gok || i >= SPDF_WIN_SEARCH_MAX_MATCHES - 2) {
                char label[64];
                sprintf(label, "cap[%d].accepted", i);
                same_i(label, wok, gok);
            }
        }
    }
    same_i("cap.count", spdf_win_search_match_list_count(&w), spdf_search_match_list_count(&g));

    /* And a steal INTO a full list: every stolen snippet must be freed rather
     * than appended, and the count must not move. */
    for (i = 0; i < 5; ++i) {
        spdf_rect r;
        r.x0 = r.y0 = r.x1 = r.y1 = (float)i;
        spdf_win_search_match_list_append(&wb, 1, r, snippet_for(i), 0);
        spdf_search_match_list_append(&gb, 1, r, g_snippet_for(i), 0);
    }
    spdf_win_search_match_list_steal_into(&w, &wb);
    spdf_search_match_list_steal_into(&g, &gb);
    same_i("cap.after_steal", spdf_win_search_match_list_count(&w), spdf_search_match_list_count(&g));
    same_i("cap.steal_src", spdf_win_search_match_list_count(&wb), spdf_search_match_list_count(&gb));

    spdf_win_search_match_list_deinit(&wb);
    spdf_search_match_list_deinit(&gb);
    spdf_win_search_match_list_deinit(&w);
    spdf_search_match_list_deinit(&g);

    /* Deinit is idempotent and NULL-safe on both sides. */
    spdf_win_search_match_list_deinit(&w);
    spdf_search_match_list_deinit(&g);
    spdf_win_search_match_list_deinit(NULL);
    spdf_search_match_list_deinit(NULL);
    same_i("deinit.count", spdf_win_search_match_list_count(&w), spdf_search_match_list_count(&g));
}

int main(void) {
    differential_counter();
    differential_dup_query();
    differential_nearest();
    differential_markers();
    differential_chapters();
    differential_snippet();
    differential_match_list();

    printf("[search-differential] %ld comparisons, %d differ\n", comparisons, mismatches);
    if (comparisons <= 0) {
        printf("[search-differential] the matrix did not run\n");
        return 2;
    }
    return mismatches == 0 ? 0 : 1;
}
