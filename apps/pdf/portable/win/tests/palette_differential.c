/* THE PALETTE DIFFERENTIAL: portable/win/src/spdf_win_palette_filter.h versus
 * the GTK4 original it was transcribed from -- the pure half of
 * portable/linux/gtk4/spdf_palette.c, compiled here with SPDF_PALETTE_TESTING
 * exactly as its own tests/palette_filter_test.c compiles it -- both in ONE MSVC
 * binary, driven with identical inputs, compared for EXACT equality.
 *
 * Same instrument as search_differential.c and minimap_differential.c, and for
 * the same reason: a hand-written test asserts what its author remembered, while
 * this asserts every function against the implementation it was ported from.
 * Integers with ==, strings with strcmp, ordered result lists element by element.
 *
 * WHAT THE INPUTS AVOID, and why that is not a hole: the port's two documented
 * departures (see spdf_win_palette_filter.h) are Windows-shaped -- '\' is a
 * separator and paths compare case-insensitively. The GTK original runs on a
 * case-sensitive filesystem with '/' alone, so every path here is POSIX-style
 * and no two differ only by case. On that domain the two must agree exactly, and
 * do; off it, the port is deliberately different and palette_filter_test.c pins
 * what it does instead.
 *
 * Not named *_test.c on purpose, so run-tests-native.sh's sweep does not build
 * it without the extra include paths. Build and run it with
 *
 *   portable\win\tests\palette-differential-native.cmd
 *
 * and judge it by its exit code.
 */
#define SPDF_PALETTE_TESTING 1

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The GTK4 original, pure half only. <glib.h> is glib_shim_palette. */
#include "spdf_palette.c"

/* The port. */
#include "spdf_win_palette_filter.h"

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

static const char* const kQueries[] = {
    "",     NULL,   "o",      "op",     "open",  "OPEN",    "zoom",   "Zoom in", "fit",       "page",   "edit",
    "files", "view", "print",  "xyz",    "po",    "a",       "e",      "  ",      "fav",       "FaV",    " fav ",
    "favo", "favorite", "favorites", "favoritess", "fa",  "fax",    "favorite x", "cl", "tab", "c",  "..",
    "/",    "alpha", "beta",   "docs",   "pdf",   "PDF",     "gen2",   "CABLINE", "needle",    "\xC3\xA9",
    "same", "quit",  "q",      "in the", "the",   "document", "d o c", "zz",
};
#define N_QUERIES ((int)(sizeof(kQueries) / sizeof(kQueries[0])))

static const char* const kHaystacks[] = {
    "",
    NULL,
    "Open a document",
    "Copy selected text",
    "Copy",
    "Print",
    "Fit page",
    "Find in the current document",
    "Page setup",
    "Go to page",
    "Zoom in",
    "zoom in",
    "View \xE2\x96\xB8 Zoom in",
    "Files \xE2\x96\xB8 Open a document",
    "Edit \xE2\x96\xB8 Copy selected document text",
    "Close the current tab",
    "Quit Shenzhen PDF",
    "a",
    "aaaaaaaaaaaaaaaaaaaaaaaaaa",
    "o p e n",
    "Caf\xC3\xA9 r\xC3\xA9sum\xC3\xA9",
    "/docs/alpha.pdf",
    "Previous Tab",
    "Next Tab",
    "Close Other Tabs",
    "Show Side Panel",
    "Rotate Anticlockwise",
    "Regex Matches Across Lines",
    "Make Searchable (OCR)...",
    "the the the the the the the the the the the",
};
#define N_HAYSTACKS ((int)(sizeof(kHaystacks) / sizeof(kHaystacks[0])))

static void differential_fuzzy(void) {
    int q, h;
    char label[256];
    for (q = 0; q < N_QUERIES; ++q)
        for (h = 0; h < N_HAYSTACKS; ++h) {
            snprintf(label, sizeof(label), "fuzzy(q=\"%s\", h=\"%s\")", kQueries[q] ? kQueries[q] : "(null)",
                     kHaystacks[h] ? kHaystacks[h] : "(null)");
            same_i(label, spdf_win_palette_fuzzy_score(kQueries[q], kHaystacks[h]),
                   spdf_palette_fuzzy_score(kQueries[q], kHaystacks[h]));
        }
}

/* The GTK test's fake table plus every row shape that exercises a branch:
 * disabled, untitled, NULL breadcrumb, identical labels (tie order). */
static const SpdfPaletteCommand kGtkTable[] = {
    {"win.open", "Open a document", "<Control>o", "Files \xE2\x96\xB8 Open a document", TRUE, FALSE},
    {"win.close-tab", "Close the current tab", "<Control>w", "Files \xE2\x96\xB8 Close the current tab", TRUE, FALSE},
    {"win.print", "Print the document", "<Control>p", "Files \xE2\x96\xB8 Print the document", FALSE, FALSE},
    {"win.copy", "Copy selected document text", "<Control>c", "Edit \xE2\x96\xB8 Copy selected document text", TRUE,
     FALSE},
    {"win.rotate-cw", "", "<Control>r", NULL, TRUE, FALSE},
    {"app.quit", "Quit Shenzhen PDF", "<Control>q", NULL, TRUE, FALSE},
    {"win.a", "Same label", NULL, NULL, TRUE, FALSE},
    {"win.b", "Same label", NULL, NULL, TRUE, TRUE},
    {"win.zoom-in", "Zoom in", NULL, "View \xE2\x96\xB8 Zoom in", TRUE, FALSE},
    {"win.zoom-out", "Zoom out", NULL, "View \xE2\x96\xB8 Zoom out", TRUE, FALSE},
    {"win.fit-page", "Fit page", NULL, "View \xE2\x96\xB8 Fit page", TRUE, FALSE},
    {"win.goto", "Go to page", NULL, "Go \xE2\x96\xB8 Go to page", TRUE, FALSE},
    {"win.null-title", NULL, NULL, "Files \xE2\x96\xB8 (untitled)", TRUE, FALSE},
    {"win.tabs", "Next tab", NULL, "Go \xE2\x96\xB8 Next tab", TRUE, FALSE},
};
#define N_TABLE ((int)(sizeof(kGtkTable) / sizeof(kGtkTable[0])))

static void differential_filter_commands(void) {
    SpdfWinPaletteCommand win[N_TABLE];
    SpdfWinPaletteMatch wout[N_TABLE + 2];
    SpdfPaletteMatch gout[N_TABLE + 2];
    int i, q, count, out_max;
    char label[256];
    for (i = 0; i < N_TABLE; ++i) {
        win[i].command = i;
        win[i].title = kGtkTable[i].title;
        win[i].accel = kGtkTable[i].accel;
        win[i].breadcrumb = kGtkTable[i].breadcrumb;
        win[i].enabled = kGtkTable[i].enabled;
        win[i].toggled = kGtkTable[i].toggled;
    }
    /* Every query, every prefix length of the table, every out_max including
     * the truncating ones. */
    for (q = 0; q < N_QUERIES; ++q)
        for (count = 0; count <= N_TABLE; ++count)
            for (out_max = 0; out_max <= N_TABLE + 1; out_max += (out_max < 3 ? 1 : 4)) {
                int wn = spdf_win_palette_filter_commands(win, count, kQueries[q], wout, out_max);
                int gn = spdf_palette_filter_commands(kGtkTable, count, kQueries[q], gout, out_max);
                snprintf(label, sizeof(label), "filter_commands(q=\"%s\", count=%d, max=%d) n",
                         kQueries[q] ? kQueries[q] : "(null)", count, out_max);
                same_i(label, wn, gn);
                if (wn == gn)
                    for (i = 0; i < wn; ++i) {
                        snprintf(label, sizeof(label), "filter_commands(q=\"%s\", count=%d, max=%d)[%d]",
                                 kQueries[q] ? kQueries[q] : "(null)", count, out_max, i);
                        same_i(label, wout[i].index, gout[i].index);
                        same_i(label, wout[i].score, gout[i].score);
                    }
            }
    same_i("filter_commands NULL table", spdf_win_palette_filter_commands(NULL, 3, "", wout, 2),
           spdf_palette_filter_commands(NULL, 3, "", gout, 2));
    same_i("filter_commands NULL out", spdf_win_palette_filter_commands(win, N_TABLE, "", NULL, 2),
           spdf_palette_filter_commands(kGtkTable, N_TABLE, "", NULL, 2));
}

static void differential_breadcrumb(void) {
    static const char* const parts[] = {NULL, "", "View", "Zoom in", "Open\xE2\x80\xA6", "Tools", "A \xE2\x96\xB8 B"};
    int g, t;
    char label[128], win[256];
    for (g = 0; g < 7; ++g)
        for (t = 0; t < 7; ++t) {
            char* gtk = spdf_palette_menu_breadcrumb(parts[g], parts[t]);
            int ok = spdf_win_palette_menu_breadcrumb(parts[g], parts[t], win, sizeof(win));
            snprintf(label, sizeof(label), "breadcrumb(%d,%d)", g, t);
            same_s(label, ok ? win : NULL, gtk);
            g_free(gtk);
        }
}

static const char* const kTitles[] = {NULL, "", "Title", "M100 Hardware Design", "Datasheet (2)", "alpha",
                                      "Caf\xC3\xA9"};
static const char* const kPaths[] = {NULL, "", "/a/b.pdf", "/docs/Acme_M100.pdf", "/docs/b.pdf",
                                     "/docs/alpha.pdf", "/other/alpha-two.pdf", "alpha.pdf", "/docs/",
                                     "/x/y/Caf\xC3\xA9.pdf"};
#define N_TITLES ((int)(sizeof(kTitles) / sizeof(kTitles[0])))
#define N_PATHS ((int)(sizeof(kPaths) / sizeof(kPaths[0])))

static void differential_open_doc_match(void) {
    int q, t, p;
    char label[256];
    for (q = 0; q < N_QUERIES; ++q)
        for (t = 0; t < N_TITLES; ++t)
            for (p = 0; p < N_PATHS; ++p) {
                snprintf(label, sizeof(label), "open_doc_matches(q=\"%s\", t=%d, p=%d)",
                         kQueries[q] ? kQueries[q] : "(null)", t, p);
                same_i(label, spdf_win_palette_open_document_matches_query(kQueries[q], kTitles[t], kPaths[p]),
                       spdf_palette_open_document_matches_query(kQueries[q], kTitles[t], kPaths[p]));
            }
}

static void differential_filter_open_docs(void) {
    static const SpdfPaletteOpenDoc gdocs[] = {
        {"/docs/alpha.pdf", "alpha"},   {"/docs/beta.pdf", "beta"},          {"/other/alpha-two.pdf", "alpha-two"},
        {"/docs/alpha.pdf", "alpha"},   {"/docs//alpha.pdf", "alpha again"}, {"/docs/./beta.pdf", "beta again"},
        {"/other/../docs/beta.pdf", "beta via .."}, {"", "ghost"},        {NULL, "gone"},
        {"/x/y/Caf\xC3\xA9.pdf", "Caf\xC3\xA9"}, {"/docs/gamma.pdf", NULL},
    };
    enum { N_DOCS = (int)(sizeof(gdocs) / sizeof(gdocs[0])) };
    SpdfWinPaletteOpenDoc wdocs[N_DOCS];
    int wout[N_DOCS + 2], gout[N_DOCS + 2];
    int i, q, count, out_max;
    char label[256];
    for (i = 0; i < N_DOCS; ++i) {
        wdocs[i].path = gdocs[i].path;
        wdocs[i].title = gdocs[i].title;
    }
    for (q = 0; q < N_QUERIES; ++q)
        for (count = 0; count <= N_DOCS; ++count)
            for (out_max = 0; out_max <= N_DOCS + 1; out_max += (out_max < 3 ? 1 : 3)) {
                int wn = spdf_win_palette_filter_open_documents(wdocs, count, kQueries[q], wout, out_max);
                int gn = spdf_palette_filter_open_documents(gdocs, count, kQueries[q], gout, out_max);
                snprintf(label, sizeof(label), "filter_open_docs(q=\"%s\", count=%d, max=%d) n",
                         kQueries[q] ? kQueries[q] : "(null)", count, out_max);
                same_i(label, wn, gn);
                if (wn == gn)
                    for (i = 0; i < wn; ++i) {
                        snprintf(label, sizeof(label), "filter_open_docs(q=\"%s\", count=%d, max=%d)[%d]",
                                 kQueries[q] ? kQueries[q] : "(null)", count, out_max, i);
                        same_i(label, wout[i], gout[i]);
                    }
            }
}

static void differential_reveals_favorites(void) {
    int q;
    char label[128];
    for (q = 0; q < N_QUERIES; ++q) {
        snprintf(label, sizeof(label), "reveals_all_favorites(\"%s\")", kQueries[q] ? kQueries[q] : "(null)");
        same_i(label, spdf_win_palette_query_reveals_all_favorites(kQueries[q]),
               spdf_palette_query_reveals_all_favorites(kQueries[q]));
    }
}

static void differential_favorite_shadowed(void) {
    static const char* const open_paths[] = {"/docs/alpha.pdf", "/other/../docs/beta.pdf", "/x/y/Caf\xC3\xA9.pdf"};
    static const char* const types[] = {NULL, "", "document", "page", "Document"};
    static const char* const fav_paths[] = {NULL, "", "/docs/alpha.pdf", "/docs//alpha.pdf", "/docs/beta.pdf",
                                            "/docs/gamma.pdf", "/x/y/Caf\xC3\xA9.pdf", "/docs/./alpha.pdf"};
    GHashTable* open;
    char keys[3][1024];
    const char* key_ptrs[3];
    int n, t, p;
    char label[128];
    for (n = 0; n <= 3; ++n) {
        int i;
        open = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
        for (i = 0; i < n; ++i) {
            g_hash_table_add(open, g_canonicalize_filename(open_paths[i], "/"));
            spdf_win_palette_canonical_path(open_paths[i], keys[i], sizeof(keys[i]));
            key_ptrs[i] = keys[i];
        }
        for (t = 0; t < 5; ++t)
            for (p = 0; p < 8; ++p) {
                snprintf(label, sizeof(label), "favorite_shadowed(n=%d, type=%d, path=%d)", n, t, p);
                same_i(label, spdf_win_palette_favorite_shadowed_by_open_doc(types[t], fav_paths[p], key_ptrs, n),
                       spdf_palette_favorite_shadowed_by_open_doc(types[t], fav_paths[p], open));
            }
        g_hash_table_unref(open);
    }
    same_i("favorite_shadowed NULL set", spdf_win_palette_favorite_shadowed_by_open_doc("document", "/a", NULL, 0),
           spdf_palette_favorite_shadowed_by_open_doc("document", "/a", NULL));
}

static void differential_snippet(void) {
    static const char* const lines[] = {
        NULL,
        "",
        "USB3.1 Gen2 pinout",
        "nothing to see here",
        "text",
        "The differential pair impedance must be held at 90 ohms across the flex, "
        "including the CABLINE-CA II Plus connector breakout region at both ends.",
        "\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9 needle "
        "\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9",
        "   needle   ",
        "needle",
        "a needle in the middle of a rather long line of ordinary text that keeps going",
        "                          needle                          ",
    };
    static const char* const needles[] = {NULL, "", "gen2", "GEN2", "gasket", "x", "CABLINE", "cabline", "needle",
                                          "NEEDLE", "the", " ", "a", "line"};
    int l, q;
    char label[128], win[1024];
    for (l = 0; l < 11; ++l)
        for (q = 0; q < 14; ++q) {
            char* gtk = spdf_palette_snippet_from_line(lines[l], needles[q]);
            int ok = spdf_win_palette_snippet_from_line(lines[l], needles[q], win, sizeof(win));
            snprintf(label, sizeof(label), "snippet(line=%d, q=%d)", l, q);
            same_s(label, ok ? win : NULL, gtk);
            g_free(gtk);
        }
}

int main(void) {
    differential_fuzzy();
    differential_filter_commands();
    differential_breadcrumb();
    differential_open_doc_match();
    differential_filter_open_docs();
    differential_reveals_favorites();
    differential_favorite_shadowed();
    differential_snippet();
    same_i("section order OPEN_DOCS", SPDF_WIN_PALETTE_SECTION_OPEN_DOCS, SPDF_PALETTE_SECTION_OPEN_DOCS);
    same_i("section order FAVORITES", SPDF_WIN_PALETTE_SECTION_FAVORITES, SPDF_PALETTE_SECTION_FAVORITES);
    same_i("section order COMMANDS", SPDF_WIN_PALETTE_SECTION_COMMANDS, SPDF_PALETTE_SECTION_COMMANDS);
    same_i("section order RECENTS", SPDF_WIN_PALETTE_SECTION_RECENTS, SPDF_PALETTE_SECTION_RECENTS);
    printf("palette differential: %ld comparisons, %d mismatches\n", comparisons, mismatches);
    if (comparisons == 0) return 2;
    return mismatches ? 1 : 0;
}
