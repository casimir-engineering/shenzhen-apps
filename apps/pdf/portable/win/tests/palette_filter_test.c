/* palette_filter_test.c — pins portable/win/src/spdf_win_palette_filter.h.
 *
 * TWO JOBS. First, the GTK original's own test (portable/linux/gtk4/tests/
 * palette_filter_test.c) transcribed case for case, so the documented arithmetic
 * -- "op" on "Open a document" = 7, on "Copy" = 3 -- is asserted here too and
 * not only by the differential (which needs its own .cmd and is not in the
 * harness sweep). Second, the two DELIBERATE departures the differential's
 * inputs avoid: '\' is a path separator and paths compare case-insensitively.
 * Those are Windows facts, and this is the only place they are pinned.
 *
 * Header-only under test, so no `spdf-test-sources` line.
 */
#include "spdf_win_palette_filter.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        long long va = (long long)(a), vb = (long long)(b);                                                            \
        ++g_checks;                                                                                                    \
        if (va != vb) {                                                                                                \
            printf("FAIL %s:%d: %s (%lld) != %s (%lld)\n", __FILE__, __LINE__, #a, va, #b, vb);                        \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_STR(got, want)                                                                                           \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (strcmp((got), (want)) != 0) {                                                                              \
            printf("FAIL %s:%d: \"%s\" != \"%s\"\n", __FILE__, __LINE__, (got), (want));                               \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- the GTK test, transcribed ------------------------------------------ */

static void test_fuzzy(void) {
    CHECK_EQI(spdf_win_palette_fuzzy_score("", "Open a document"), 0);
    CHECK_EQI(spdf_win_palette_fuzzy_score(NULL, "Open a document"), 0);
    CHECK_EQI(spdf_win_palette_fuzzy_score("", ""), 0);
    CHECK_EQI(spdf_win_palette_fuzzy_score("xyz", "Open a document"), -1);
    CHECK_EQI(spdf_win_palette_fuzzy_score("po", "Print"), -1);
    CHECK_EQI(spdf_win_palette_fuzzy_score("a", ""), -1);
    CHECK_EQI(spdf_win_palette_fuzzy_score("a", NULL), -1);
    {
        int lower = spdf_win_palette_fuzzy_score("zoom", "Zoom in");
        CHECK(lower > 0);
        CHECK_EQI(spdf_win_palette_fuzzy_score("ZOOM", "Zoom in"), lower);
        CHECK_EQI(spdf_win_palette_fuzzy_score("Zoom", "zoom in"), lower);
    }
    CHECK(spdf_win_palette_fuzzy_score("op", "Open a document") > spdf_win_palette_fuzzy_score("op", "Copy selected text"));
    CHECK(spdf_win_palette_fuzzy_score("op", "Copy selected text") >= 0);
    CHECK(spdf_win_palette_fuzzy_score("fit", "Fit page") >
          spdf_win_palette_fuzzy_score("fit", "Find in the current document"));
    CHECK(spdf_win_palette_fuzzy_score("page", "Page setup") > spdf_win_palette_fuzzy_score("page", "Go to page"));
    /* The documented arithmetic, pinned. */
    CHECK_EQI(spdf_win_palette_fuzzy_score("op", "Open a document"), 7);
    CHECK_EQI(spdf_win_palette_fuzzy_score("op", "Copy"), 3);
}

static const SpdfWinPaletteCommand k_fake_table[] = {
    {1, "Open a document", "Ctrl+O", "File \xE2\x96\xB8 Open a document", 1, 0},
    {2, "Close the current tab", "Ctrl+W", "File \xE2\x96\xB8 Close the current tab", 1, 0},
    {3, "Print the document", "Ctrl+P", "File \xE2\x96\xB8 Print the document", 0, 0},
    {4, "Copy selected document text", "Ctrl+C", "Edit \xE2\x96\xB8 Copy selected document text", 1, 0},
    {5, "", "Ctrl+R", NULL, 1, 0},
    {6, "Quit Shenzhen PDF", "Ctrl+Q", NULL, 1, 0},
};
#define FAKE_COUNT ((int)(sizeof(k_fake_table) / sizeof(k_fake_table[0])))

static void test_filter_commands(void) {
    SpdfWinPaletteMatch matches[FAKE_COUNT];
    int n = spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "", matches, FAKE_COUNT), i;
    CHECK_EQI(n, 4);
    CHECK_EQI(matches[0].index, 0);
    CHECK_EQI(matches[1].index, 1);
    CHECK_EQI(matches[2].index, 3);
    CHECK_EQI(matches[3].index, 5);
    for (i = 0; i < n; ++i) CHECK_EQI(matches[i].score, 0);
    CHECK_EQI(spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "print", matches, FAKE_COUNT), 0);
    n = spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "op", matches, FAKE_COUNT);
    CHECK(n >= 2);
    CHECK_EQI(matches[0].index, 0);
    for (i = 1; i < n; ++i) CHECK(matches[0].score >= matches[i].score);
    {
        static const SpdfWinPaletteCommand twins[] = {{1, "Same label", NULL, NULL, 1, 0},
                                                      {2, "Same label", NULL, NULL, 1, 0}};
        SpdfWinPaletteMatch two[2];
        CHECK_EQI(spdf_win_palette_filter_commands(twins, 2, "same", two, 2), 2);
        CHECK_EQI(two[0].score, two[1].score);
        CHECK_EQI(two[0].index, 0);
        CHECK_EQI(two[1].index, 1);
    }
    CHECK_EQI(spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "", matches, 2), 2);
    CHECK_EQI(spdf_win_palette_filter_commands(NULL, 3, "", matches, 2), 0);
    CHECK_EQI(spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "", NULL, 2), 0);
    CHECK_EQI(spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "", matches, 0), 0);
    CHECK_EQI(spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "zzzz", matches, FAKE_COUNT), 0);
    /* The breadcrumb is part of the haystack: "edit" finds only the Edit item;
     * "file" finds the two enabled File items and never the NULL-breadcrumb quit. */
    n = spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "edit", matches, FAKE_COUNT);
    CHECK_EQI(n, 1);
    CHECK_EQI(matches[0].index, 3);
    n = spdf_win_palette_filter_commands(k_fake_table, FAKE_COUNT, "file", matches, FAKE_COUNT);
    CHECK_EQI(n, 2);
    for (i = 0; i < n; ++i) CHECK(matches[i].index != 5);
    {
        static const SpdfWinPaletteCommand one[] = {{1, "Zoom in", NULL, "View \xE2\x96\xB8 Zoom in", 1, 0}};
        SpdfWinPaletteMatch m1[1];
        CHECK_EQI(spdf_win_palette_filter_commands(one, 1, "zoom", m1, 1), 1);
        CHECK_EQI(m1[0].score, spdf_win_palette_fuzzy_score("zoom", "Zoom in"));
    }
}

static void test_breadcrumb(void) {
    char out[128];
    CHECK(spdf_win_palette_menu_breadcrumb("View", "Zoom in", out, sizeof(out)));
    CHECK_STR(out, "View \xE2\x96\xB8 Zoom in");
    CHECK(spdf_win_palette_menu_breadcrumb("", "Open\xE2\x80\xA6", out, sizeof(out)));
    CHECK_STR(out, "Open\xE2\x80\xA6");
    CHECK(spdf_win_palette_menu_breadcrumb("Tools", NULL, out, sizeof(out)));
    CHECK_STR(out, "Tools");
    CHECK(!spdf_win_palette_menu_breadcrumb(NULL, "", out, sizeof(out)));
    CHECK_STR(out, "");
    CHECK(!spdf_win_palette_menu_breadcrumb("View", "Zoom in", out, 8)); /* does not fit */
}

static const SpdfWinPaletteOpenDoc k_open_docs[] = {
    {"/docs/alpha.pdf", "alpha"}, {"/docs/beta.pdf", "beta"}, {"/other/alpha-two.pdf", "alpha-two"}};

static void test_open_docs(void) {
    int picks[3], n;
    CHECK(spdf_win_palette_open_document_matches_query("", "Title", "/a/b.pdf"));
    CHECK(spdf_win_palette_open_document_matches_query(NULL, "Title", "/a/b.pdf"));
    CHECK(spdf_win_palette_open_document_matches_query("hard", "M100 Hardware Design", "/a/b.pdf"));
    CHECK(spdf_win_palette_open_document_matches_query("acme", "Datasheet (2)", "/docs/Acme_M100.pdf"));
    CHECK(!spdf_win_palette_open_document_matches_query("missing", "Title", "/a/b.pdf"));
    CHECK(!spdf_win_palette_open_document_matches_query("docs", "Title", "/docs/b.pdf"));
    n = spdf_win_palette_filter_open_documents(k_open_docs, 3, "", picks, 3);
    CHECK_EQI(n, 3);
    CHECK_EQI(picks[0], 0);
    CHECK_EQI(picks[2], 2);
    n = spdf_win_palette_filter_open_documents(k_open_docs, 3, "alpha", picks, 3);
    CHECK_EQI(n, 2);
    CHECK_EQI(picks[0], 0);
    CHECK_EQI(picks[1], 2);
    CHECK_EQI(spdf_win_palette_filter_open_documents(k_open_docs, 3, "gamma", picks, 3), 0);
    {
        static const SpdfWinPaletteOpenDoc dup[] = {
            {"/docs/alpha.pdf", "alpha"}, {"/docs/alpha.pdf", "alpha"}, {"/docs//alpha.pdf", "alpha"}};
        CHECK_EQI(spdf_win_palette_filter_open_documents(dup, 3, "", picks, 3), 1);
        CHECK_EQI(picks[0], 0);
    }
    {
        static const SpdfWinPaletteOpenDoc ghost[] = {{"", "ghost"}, {NULL, "gone"}};
        CHECK_EQI(spdf_win_palette_filter_open_documents(ghost, 2, "", picks, 2), 0);
        CHECK_EQI(spdf_win_palette_filter_open_documents(NULL, 2, "", picks, 2), 0);
        CHECK_EQI(spdf_win_palette_filter_open_documents(k_open_docs, 3, "", NULL, 2), 0);
        CHECK_EQI(spdf_win_palette_filter_open_documents(k_open_docs, 3, "", picks, 0), 0);
    }
    CHECK(SPDF_WIN_PALETTE_SECTION_OPEN_DOCS < SPDF_WIN_PALETTE_SECTION_FAVORITES);
    CHECK(SPDF_WIN_PALETTE_SECTION_FAVORITES < SPDF_WIN_PALETTE_SECTION_COMMANDS);
    CHECK(SPDF_WIN_PALETTE_SECTION_COMMANDS < SPDF_WIN_PALETTE_SECTION_RECENTS);
}

static void test_favorites_rules(void) {
    char key[1024];
    const char* keys[1];
    CHECK(spdf_win_palette_canonical_path("/docs/alpha.pdf", key, sizeof(key)));
    keys[0] = key;
    CHECK(spdf_win_palette_favorite_shadowed_by_open_doc("document", "/docs/alpha.pdf", keys, 1));
    CHECK(spdf_win_palette_favorite_shadowed_by_open_doc("document", "/docs//alpha.pdf", keys, 1));
    CHECK(!spdf_win_palette_favorite_shadowed_by_open_doc("page", "/docs/alpha.pdf", keys, 1));
    CHECK(!spdf_win_palette_favorite_shadowed_by_open_doc("document", "/docs/beta.pdf", keys, 1));
    CHECK(!spdf_win_palette_favorite_shadowed_by_open_doc("document", "", keys, 1));
    CHECK(!spdf_win_palette_favorite_shadowed_by_open_doc("document", NULL, keys, 1));
    CHECK(!spdf_win_palette_favorite_shadowed_by_open_doc("document", "/docs/alpha.pdf", NULL, 0));
    CHECK(!spdf_win_palette_favorite_shadowed_by_open_doc("document", "/docs/alpha.pdf", keys, 0));

    CHECK(spdf_win_palette_query_reveals_all_favorites("fav"));
    CHECK(spdf_win_palette_query_reveals_all_favorites("favo"));
    CHECK(spdf_win_palette_query_reveals_all_favorites("favorite"));
    CHECK(spdf_win_palette_query_reveals_all_favorites("favorites"));
    CHECK(spdf_win_palette_query_reveals_all_favorites("FaV"));
    CHECK(spdf_win_palette_query_reveals_all_favorites(" fav "));
    CHECK(!spdf_win_palette_query_reveals_all_favorites("fa"));
    CHECK(!spdf_win_palette_query_reveals_all_favorites(""));
    CHECK(!spdf_win_palette_query_reveals_all_favorites(NULL));
    CHECK(!spdf_win_palette_query_reveals_all_favorites("fax"));
    CHECK(!spdf_win_palette_query_reveals_all_favorites("favorite x"));
    CHECK(!spdf_win_palette_query_reveals_all_favorites("favoritess"));
}

static void test_snippet(void) {
    char out[256];
    const char* line = "The differential pair impedance must be held at 90 ohms across the flex, "
                       "including the CABLINE-CA II Plus connector breakout region at both ends.";
    CHECK(spdf_win_palette_snippet_from_line("USB3.1 Gen2 pinout", "gen2", out, sizeof(out)));
    CHECK_STR(out, "USB3.1 Gen2 pinout");
    CHECK(!spdf_win_palette_snippet_from_line("nothing to see here", "gasket", out, sizeof(out)));
    CHECK(!spdf_win_palette_snippet_from_line("", "x", out, sizeof(out)));
    CHECK(!spdf_win_palette_snippet_from_line("text", "", out, sizeof(out)));
    CHECK(!spdf_win_palette_snippet_from_line(NULL, "x", out, sizeof(out)));
    CHECK(spdf_win_palette_snippet_from_line(line, "CABLINE", out, sizeof(out)));
    CHECK(strstr(out, "CABLINE") != NULL);
    CHECK(strncmp(out, "\xE2\x80\xA6", 3) == 0);
    CHECK(strcmp(out + strlen(out) - 3, "\xE2\x80\xA6") == 0);
    CHECK(strlen(out) <= strlen("CABLINE") + 2 * 24 + 2 * 3);
    {
        const char* utf8 = "\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9"
                           "\xC3\xA9 needle \xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9"
                           "\xC3\xA9\xC3\xA9\xC3\xA9";
        size_t i;
        CHECK(spdf_win_palette_snippet_from_line(utf8, "needle", out, sizeof(out)));
        CHECK(strstr(out, "needle") != NULL);
        /* Every byte belongs to a complete sequence: no lone continuation
         * byte at either end. */
        CHECK(((unsigned char)out[0] & 0xC0) != 0x80);
        for (i = 0; out[i]; ++i)
            if (((unsigned char)out[i] & 0xE0) == 0xC0) CHECK(((unsigned char)out[i + 1] & 0xC0) == 0x80);
    }
    CHECK(!spdf_win_palette_snippet_from_line(line, "CABLINE", out, 10)); /* does not fit */
}

/* --- the two Windows departures ------------------------------------------ */

static void test_windows_paths(void) {
    char key[1024];
    int picks[4];
    /* '\' is a separator: the last component of a Windows path is the file. */
    CHECK(spdf_win_palette_open_document_matches_query("manual", "Title", "C:\\docs\\Manual.pdf"));
    CHECK(!spdf_win_palette_open_document_matches_query("docs", "Title", "C:\\docs\\Manual.pdf"));
    CHECK_STR(spdf_win_pf_basename("C:\\docs\\Manual.pdf"), "Manual.pdf");
    CHECK_STR(spdf_win_pf_basename("C:/docs/Manual.pdf"), "Manual.pdf");
    CHECK_STR(spdf_win_pf_basename("Manual.pdf"), "Manual.pdf");
    /* The canonical form: case folded, separators normalised, dots resolved,
     * the root kept. */
    CHECK(spdf_win_palette_canonical_path("C:/Docs//./Sub/../Manual.PDF", key, sizeof(key)));
    CHECK_STR(key, "c:\\docs\\manual.pdf");
    CHECK(spdf_win_palette_canonical_path("\\\\server\\share\\x\\..\\..\\..\\y.pdf", key, sizeof(key)));
    CHECK_STR(key, "\\\\server\\share\\y.pdf"); /* never above the share, which is the root */
    CHECK(spdf_win_palette_canonical_path("C:\\..\\a.pdf", key, sizeof(key)));
    CHECK_STR(key, "c:\\a.pdf");
    CHECK(spdf_win_palette_canonical_path("/docs//alpha.pdf", key, sizeof(key)));
    CHECK_STR(key, "\\docs\\alpha.pdf");
    CHECK(spdf_win_palette_canonical_path("relative\\x.pdf", key, sizeof(key)));
    CHECK_STR(key, "relative\\x.pdf");
    CHECK(spdf_win_palette_canonical_path("", key, sizeof(key)));
    CHECK_STR(key, "");
    CHECK(!spdf_win_palette_canonical_path("C:\\docs\\Manual.pdf", key, 8));
    /* The same file spelled three ways is one open document. */
    {
        static const SpdfWinPaletteOpenDoc spelled[] = {{"C:\\docs\\Manual.pdf", "Manual"},
                                                        {"c:/DOCS/manual.pdf", "Manual"},
                                                        {"C:\\docs\\.\\Manual.pdf", "Manual"},
                                                        {"C:\\docs\\Other.pdf", "Other"}};
        CHECK_EQI(spdf_win_palette_filter_open_documents(spelled, 4, "", picks, 4), 2);
        CHECK_EQI(picks[0], 0);
        CHECK_EQI(picks[1], 3);
    }
    /* And a document favorite of it is shadowed however it is spelled. */
    {
        const char* keys[1];
        CHECK(spdf_win_palette_canonical_path("C:\\docs\\Manual.pdf", key, sizeof(key)));
        keys[0] = key;
        CHECK(spdf_win_palette_favorite_shadowed_by_open_doc("document", "c:/docs/MANUAL.PDF", keys, 1));
        CHECK(!spdf_win_palette_favorite_shadowed_by_open_doc("page", "c:/docs/MANUAL.PDF", keys, 1));
    }
}

int main(void) {
    test_fuzzy();
    test_filter_commands();
    test_breadcrumb();
    test_open_docs();
    test_favorites_rules();
    test_snippet();
    test_windows_paths();
    printf("palette_filter_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
