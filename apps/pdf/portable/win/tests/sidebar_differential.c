/* THE SIDEBAR DIFFERENTIAL: portable/win/src/spdf_win_sidebar_results.h versus
 * the GTK4 original it was transcribed from,
 * portable/linux/gtk4/spdf_sidebar_internal.h, both compiled into ONE binary,
 * driven with identical inputs, compared for EXACT equality.
 *
 * Same instrument as search_differential.c and minimap_differential.c, for the
 * same reason: a hand-written test asserts what its author remembered, this one
 * asserts each function against the implementation it was ported from. Strings
 * are compared with strcmp and integers with ==; a one-byte difference is a
 * transcription error, not a rounding question.
 *
 * ONE HONEST LIMIT. The GTK header casefolds with g_utf8_casefold, which the
 * shim in portable/win/tests/glib_shim_sidebar/ cannot reproduce and therefore
 * aliases to the port's own fold. Every comparison below that goes through a
 * fold checks the STRUCTURE around it -- ranges, windows, word walking,
 * escaping -- with the fold held equal on both sides by construction. The fold
 * itself is not under test here and is said so in three places.
 *
 * Not named *_test.c on purpose, so run-tests-native.sh's sweep does not build
 * it without the three include paths. Build and run it with:
 *
 *   portable\win\tests\sidebar-differential-native.cmd
 *
 * and judge it by its exit code.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The GTK4 original, under the layered shim (glib_shim_sidebar first). */
#include "spdf_sidebar_internal.h"

/* The port. (Already pulled in by the shim for the fold; harmless twice.) */
#include "spdf_win_sidebar_results.h"

static int mismatches;
static long comparisons;

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
 * 1. Levels: normalisation, then the child edges over the normalised array. */
static const int kLevelSets[][12] = {
    {0, 1, 2, 1, 0, 1, 2, 3, 2, 1, 0, 0},
    {0, 5, 1, 9, 0, -1, -3, 2, 2, 2, 7, 1},
    {3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3},
    {-1, -1, -1, 0, 0, 1, 1, 0, 1, 2, 3, 4},
    {0, 1, 1, 1, 2, 2, 0, 1, 2, 1, 2, 0},
    {2, 1, 0, 1, 2, 1, 0, 2, 1, 0, 2, 1},
};

static void differential_levels(void) {
    char label[160];
    int set, count, i, parent, nth;
    for (set = 0; set < (int)(sizeof(kLevelSets) / sizeof(kLevelSets[0])); ++set) {
        for (count = 0; count <= 12; ++count) {
            int w[12], g[12];
            memcpy(w, kLevelSets[set], sizeof(w));
            memcpy(g, kLevelSets[set], sizeof(g));
            spdf_win_sidebar_outline_normalize_levels(w, count);
            spdf_sidebar_outline_normalize_levels(g, count);
            for (i = 0; i < count; ++i) {
                sprintf(label, "normalize[set=%d][n=%d][%d]", set, count, i);
                same_i(label, w[i], g[i]);
            }
            for (parent = -1; parent <= count; ++parent) {
                if (parent >= count && parent >= 0) continue; /* the original indexes levels[parent] first */
                sprintf(label, "child_count[set=%d][n=%d][parent=%d]", set, count, parent);
                same_i(label, spdf_win_sidebar_outline_child_count(w, count, parent),
                       spdf_sidebar_outline_child_count(g, count, parent));
                for (nth = -1; nth <= count; ++nth) {
                    sprintf(label, "child_at[set=%d][n=%d][parent=%d][nth=%d]", set, count, parent, nth);
                    same_i(label, spdf_win_sidebar_outline_child_at(w, count, parent, nth),
                           spdf_sidebar_outline_child_at(g, count, parent, nth));
                }
            }
        }
    }
    /* NULL arrays. */
    same_i("normalize[null]", (spdf_win_sidebar_outline_normalize_levels(NULL, 3), 0),
           (spdf_sidebar_outline_normalize_levels(NULL, 3), 0));
    same_i("child_count[null]", spdf_win_sidebar_outline_child_count(NULL, 3, -1),
           spdf_sidebar_outline_child_count(NULL, 3, -1));
    same_i("child_at[null]", spdf_win_sidebar_outline_child_at(NULL, 3, -1, 0),
           spdf_sidebar_outline_child_at(NULL, 3, -1, 0));
}

/* --------------------------------------------------------------------------
 * 2. Chapter attribution by page: ties, unresolved (-1) pages, unsorted. */
static void differential_index_for_page(void) {
    static const int kPages[][8] = {
        {0, 2, 2, 5, 5, 5, 9, 12},
        {-1, 0, -1, 3, 3, 8, -1, 8},
        {12, 9, 5, 5, 2, 2, 0, 0},
        {4, 4, 4, 4, 4, 4, 4, 4},
        {0, 1, 2, 3, 4, 5, 6, 7},
    };
    static const int kLevels[][8] = {
        {0, 0, 1, 0, 1, 2, 0, 1},
        {0, 1, 0, 2, 1, 0, 0, 3},
        {1, 1, 1, 1, 1, 1, 1, 1},
        {0, 1, 2, 3, -1, -2, 1, 0},
    };
    char label[160];
    int p, l, count, page;
    for (p = 0; p < (int)(sizeof(kPages) / sizeof(kPages[0])); ++p) {
        for (l = 0; l <= (int)(sizeof(kLevels) / sizeof(kLevels[0])); ++l) {
            const int* levels = l < (int)(sizeof(kLevels) / sizeof(kLevels[0])) ? kLevels[l] : NULL;
            for (count = 0; count <= 8; ++count) {
                for (page = -2; page <= 14; ++page) {
                    sprintf(label, "index_for_page[p=%d][l=%d][n=%d][page=%d]", p, l, count, page);
                    same_i(label, spdf_win_sidebar_outline_index_for_page(kPages[p], levels, count, page),
                           spdf_sidebar_outline_index_for_page(kPages[p], levels, count, page));
                }
            }
        }
    }
    same_i("index_for_page[null]", spdf_win_sidebar_outline_index_for_page(NULL, NULL, 3, 1),
           spdf_sidebar_outline_index_for_page(NULL, NULL, 3, 1));
}

/* --------------------------------------------------------------------------
 * 3. Grouping: the same chapter sequence fed match by match to both sides. */
static void differential_grouping(void) {
    static const int kChapters[][10] = {
        {-1, -1, 0, 0, 0, 1, 1, 3, 3, 3},
        {0, 1, 2, 3, 4, 5, 6, 7, 8, 9},
        {2, 2, 2, 2, 2, 2, 2, 2, 2, 2},
        {-1, 0, -1, 0, -1, 0, 5, 5, 4, 4},
        {7, 7, 6, 6, 7, 7, 6, 6, -1, -1},
    };
    char label[160];
    int seq, has_outline, i, r;
    for (seq = 0; seq < (int)(sizeof(kChapters) / sizeof(kChapters[0])); ++seq) {
        for (has_outline = 0; has_outline <= 1; ++has_outline) {
            SpdfWinSidebarGroupRow w[64];
            int wcount = 0;
            int wprev = SPDF_WIN_SIDEBAR_NO_CHAPTER;
            GArray* g = g_array_new(FALSE, FALSE, sizeof(SpdfSidebarGroupRow));
            int gprev = SPDF_SIDEBAR_NO_CHAPTER;
            same_i("NO_CHAPTER", SPDF_WIN_SIDEBAR_NO_CHAPTER, SPDF_SIDEBAR_NO_CHAPTER);
            for (i = 0; i < 10; ++i) {
                spdf_win_sidebar_group_append(w, &wcount, 64, &wprev, kChapters[seq][i], has_outline, i);
                spdf_sidebar_group_append(g, &gprev, kChapters[seq][i], has_outline, i);
            }
            sprintf(label, "group[seq=%d][outline=%d].count", seq, has_outline);
            same_i(label, wcount, (long long)g->len);
            for (r = 0; r < wcount && r < (int)g->len; ++r) {
                const SpdfSidebarGroupRow* gr = &g_array_index(g, SpdfSidebarGroupRow, r);
                sprintf(label, "group[seq=%d][outline=%d][%d].is_header", seq, has_outline, r);
                same_i(label, w[r].is_header, gr->is_header);
                sprintf(label, "group[seq=%d][outline=%d][%d].value", seq, has_outline, r);
                same_i(label, w[r].value, gr->value);
            }
            sprintf(label, "group[seq=%d][outline=%d].prev", seq, has_outline);
            same_i(label, wprev, gprev);
            g_array_free(g, TRUE);
        }
    }
}

/* --------------------------------------------------------------------------
 * 4. Header titles. */
static void differential_chapter_title(void) {
    static const char* kTitles[] = {"Introduction", "", NULL, "\xC3\x9C" "berblick", "\xE7\xAC\xAC\xE4\xB8\x80\xE7\xAB\xA0"};
    char label[160];
    int count, index;
    for (count = -1; count <= 5; ++count) {
        for (index = -3; index <= 7; ++index) {
            sprintf(label, "chapter_title[n=%d][i=%d]", count, index);
            same_s(label, spdf_win_sidebar_chapter_title(kTitles, count, index),
                   spdf_sidebar_chapter_title(kTitles, count, index));
            sprintf(label, "chapter_title[null][n=%d][i=%d]", count, index);
            same_s(label, spdf_win_sidebar_chapter_title(NULL, count, index),
                   spdf_sidebar_chapter_title(NULL, count, index));
        }
    }
}

/* --------------------------------------------------------------------------
 * 5-7. The text half: filter, match range, window, markup. The fold is shared
 * (see the file header); everything else is compared. */
static const char* kLines[] = {
    "",
    "ShenzhenPDF outline fixture",
    "  leading and trailing spaces   ",
    "one two three four FIVE six seven eight nine ten",
    "a\tb\nc\x0bd\x0c" "e\rf",
    "Z\xC3\xBCrich is not Zurich; Z\xC3\xBCRICH is",
    "\xE7\xAC\xAC\xE4\xB8\x80\xE7\xAB\xA0\xE3\x80\x80\xE7\xAC\xAC\xE4\xBA\x8C\xE7\xAB\xA0 CJK\xE3\x80\x80section",
    "nbsp\xC2\xA0separated\xC2\xA0words here",
    "tags <b>&amp;</b> \"quotes\" 'apostrophes' & ampersands > gt < lt",
    "control\x01char\x7fhere\xC2\x85nel\xC2\x9f" "end",
    "broken \xE2\x82 sequence \xFF byte \xC0\xAF overlong",
    "the quick brown fox jumps over the lazy dog the quick brown fox jumps over the lazy dog",
    "match at the very end",
    "start of the line matches",
    "x",
};

static const char* kQueries[] = {
    "", "fixture", "FIXTURE", "outline fixture", "the", "  ", "Zurich", "z\xC3\xBCrich", "\xE7\xAC\xAC", "CJK",
    "section", "&amp;", "quotes", "end", "start", "x", "nonexistent", "[a-z]+", "e", "fox jumps",
    "\xE3\x80\x80", "nbsp\xC2\xA0separated", "\x7f", "seven eight", "dog the",
};

static void differential_text(void) {
    char label[200];
    int l, q;
    for (l = 0; l < (int)(sizeof(kLines) / sizeof(kLines[0])); ++l) {
        for (q = 0; q < (int)(sizeof(kQueries) / sizeof(kQueries[0])); ++q) {
            const char* line = kLines[l];
            const char* query = kQueries[q];
            const char *ws = NULL, *we = NULL, *gs = NULL, *ge = NULL;
            int wf, gf;
            char *wwin, *gwin, *wmk, *gmk, *wfold;

            wfold = spdf_win_sidebar_casefold(query, -1);
            sprintf(label, "filter[l=%d][q=%d]", l, q);
            same_i(label, spdf_win_sidebar_filter_matches(line, wfold), spdf_sidebar_filter_matches(line, wfold));
            free(wfold);

            wf = spdf_win_sidebar_snippet_match_range(line, query, &ws, &we);
            gf = spdf_sidebar_snippet_match_range(line, query, &gs, &ge);
            sprintf(label, "range[l=%d][q=%d].found", l, q);
            same_i(label, wf, gf);
            if (wf && gf) {
                sprintf(label, "range[l=%d][q=%d].start", l, q);
                same_i(label, (long long)(ws - line), (long long)(gs - line));
                sprintf(label, "range[l=%d][q=%d].end", l, q);
                same_i(label, (long long)(we - line), (long long)(ge - line));
            }

            wwin = spdf_win_sidebar_snippet_window(line, query);
            gwin = spdf_sidebar_snippet_window(line, query);
            sprintf(label, "window[l=%d][q=%d]", l, q);
            same_s(label, wwin, gwin);
            free(wwin);
            free(gwin);

            wmk = spdf_win_sidebar_snippet_markup(line, query);
            gmk = spdf_sidebar_snippet_markup(line, query);
            sprintf(label, "markup[l=%d][q=%d]", l, q);
            same_s(label, wmk, gmk);
            free(wmk);
            free(gmk);
        }
        /* NULL line and NULL query. */
        {
            char* w = spdf_win_sidebar_snippet_window(NULL, kQueries[1]);
            char* g = spdf_sidebar_snippet_window(NULL, kQueries[1]);
            sprintf(label, "window[null-line][l=%d]", l);
            same_s(label, w, g);
            free(w);
            free(g);
            w = spdf_win_sidebar_snippet_window(kLines[l], NULL);
            g = spdf_sidebar_snippet_window(kLines[l], NULL);
            sprintf(label, "window[null-query][l=%d]", l);
            same_s(label, w, g);
            free(w);
            free(g);
            w = spdf_win_sidebar_snippet_markup(kLines[l], NULL);
            g = spdf_sidebar_snippet_markup(kLines[l], NULL);
            sprintf(label, "markup[null-query][l=%d]", l);
            same_s(label, w, g);
            free(w);
            free(g);
        }
    }
    /* The UTF-8 walkers directly, since the port re-spells glib's table. */
    for (l = 0; l < (int)(sizeof(kLines) / sizeof(kLines[0])); ++l) {
        const char* p = kLines[l];
        long max;
        int step = 0;
        while (*p) {
            sprintf(label, "utf8.get[l=%d][%d]", l, step);
            same_i(label, spdf_win_sidebar_utf8_get(p), g_utf8_get_char(p));
            sprintf(label, "utf8.next[l=%d][%d]", l, step);
            same_i(label, (long long)(spdf_win_sidebar_utf8_next(p) - kLines[l]),
                   (long long)(g_utf8_next_char(p) - kLines[l]));
            sprintf(label, "utf8.isspace[l=%d][%d]", l, step);
            same_i(label, spdf_win_sidebar_unichar_isspace(spdf_win_sidebar_utf8_get(p)),
                   g_unichar_isspace(g_utf8_get_char(p)));
            p = spdf_win_sidebar_utf8_next(p);
            ++step;
        }
        for (max = -1; max <= (long)strlen(kLines[l]) + 2; ++max) {
            sprintf(label, "utf8.strlen[l=%d][max=%ld]", l, max);
            same_i(label, spdf_win_sidebar_utf8_strlen(kLines[l], max), g_utf8_strlen(kLines[l], max));
        }
        for (max = 0; max <= spdf_win_sidebar_utf8_strlen(kLines[l], -1); ++max) {
            sprintf(label, "utf8.offset[l=%d][%ld]", l, max);
            same_i(label, (long long)(spdf_win_sidebar_utf8_offset_to_pointer(kLines[l], max) - kLines[l]),
                   (long long)(g_utf8_offset_to_pointer(kLines[l], max) - kLines[l]));
        }
        for (max = -1; max <= (long)strlen(kLines[l]); ++max) {
            char* w = spdf_win_sidebar_markup_escape(kLines[l], max);
            char* g = g_markup_escape_text(kLines[l], max);
            sprintf(label, "escape[l=%d][len=%ld]", l, max);
            same_s(label, w, g);
            free(w);
            free(g);
        }
    }
}

int main(void) {
    differential_levels();
    differential_index_for_page();
    differential_grouping();
    differential_chapter_title();
    differential_text();

    printf("[sidebar-differential] %ld comparisons, %d differ\n", comparisons, mismatches);
    if (comparisons <= 0) {
        printf("[sidebar-differential] the matrix did not run\n");
        return 2;
    }
    return mismatches == 0 ? 0 : 1;
}
