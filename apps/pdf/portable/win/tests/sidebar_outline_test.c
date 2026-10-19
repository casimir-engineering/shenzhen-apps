/* The chapter list's nesting, tested without a table, a document or a window:
 * portable/win/src/spdf_win_sidebar_outline.h, the rows the builder in
 * spdf_win_sidebar_rows.h derives from it, the geometry each row draws with, and
 * the per-document memory in spdf_win_chapter_state.h.
 *
 * THE FIRST HALF IS THE MAC'S OWN TEST, portable/mac/tests/SPDFMacSidebarOutlineTests.mm,
 * case for case with the same fixtures and the same expected rows: the
 * README-shaped outline (one H1, two H2s, the first with two H3s), what gets a
 * triangle, what a collapse hides, that a sibling AFTER a collapsed section is
 * still shown, an outline that does not start at level 0, a skipped heading
 * level, and a stale key hiding nothing. spdf_win_sidebar_outline.h is a
 * transcription of SPDFMacSidebarOutline.mm, and this is what holds the two to
 * one answer -- the GTK differential cannot, because GTK has no collapse state.
 *
 * THE SECOND HALF is what the Windows side adds around it: the builder applying
 * a collapsed set and a filter, the disclosure / title rects the mac's
 * constraints put at 6 + level*13 and +16 pt, the toggle button's slot on the
 * filter row, and chapters.yaml -- the file's JSON in and out, a mac-written
 * documents.yaml record honoured, and a real round trip through the state
 * directory (argv[1] is a scratch directory; the file lands under it).
 *
 * Judged by exit code.
 */

/* spdf-test-sources: portable/win/src/spdf_win_chapter_state.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
/* spdf-test-args: %SCRATCH% */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spdf_win_chapter_state.h"
#include "spdf_win_paths.h"
#include "spdf_win_sidebar_rows.h"
#include "spdf_win_state.h"

static int failures;

static void expect(int condition, const char* what) {
    if (!condition) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void expect_str(const char* got, const char* want, const char* what) {
    if (!got || strcmp(got, want) != 0) {
        printf("FAIL %s: got \"%s\" want \"%s\"\n", what, got ? got : "(null)", want);
        failures++;
    }
}

static void expect_near(float got, float want, const char* what) {
    float d = got - want;
    if (d < 0.0f) d = -d;
    if (d > 0.001f) {
        printf("FAIL %s: got %.4f want %.4f\n", what, got, want);
        failures++;
    }
}

/* The visible rows as "0,1,4" -- the mac test's VisibleString. */
static const char* visible_string(const int* levels, int count, const char* const* collapsed, int collapsed_count) {
    static char out[256];
    unsigned char flags[64];
    int i;
    size_t n = 0;
    out[0] = '\0';
    spdf_win_sidebar_outline_visible(levels, count, collapsed, collapsed_count, flags);
    for (i = 0; i < count; ++i) {
        if (!flags[i]) continue;
        n += (size_t)_snprintf_s(out + n, sizeof(out) - n, _TRUNCATE, n ? ",%d" : "%d", i);
    }
    return out;
}

static const char* key_of(const int* levels, int count, int index) {
    static char key[SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX];
    spdf_win_sidebar_outline_key(levels, count, index, key, sizeof(key));
    return key;
}

/* --- the mac's cases ----------------------------------------------------- */

static void test_mac_cases(void) {
    /* A README-shaped outline: one H1, two H2s, the first with two H3s.
     *   0 Title          level 0   key 0
     *   1   Install      level 1   key 0.0
     *   2     macOS      level 2   key 0.0.0
     *   3     Linux      level 2   key 0.0.1
     *   4   Usage        level 1   key 0.1 */
    static const int doc[] = {0, 1, 2, 2, 1};
    static const char* k00[] = {"0.0"};
    static const char* k0[] = {"0"};
    static const char* stale[] = {"9.9.9"};
    static const char* all[] = {"0", "0.0"};
    static const int deep[] = {2, 3, 3, 2};
    static const int flat[] = {0, 0, 0};
    static const int skipped[] = {0, 2};
    const char* deep_root[1];

    /* --- Which rows get a triangle --- */
    expect(spdf_win_sidebar_outline_has_children(doc, 5, 0), "a row with a deeper row after it has children");
    expect(!spdf_win_sidebar_outline_has_children(doc, 5, 2), "a row whose next sibling is at its level has none");
    expect(!spdf_win_sidebar_outline_has_children(doc, 5, 4), "the last row never has children");

    /* --- Keys are positional, so duplicate titles stay distinct --- */
    expect_str(key_of(doc, 5, 0), "0", "the root's key");
    expect_str(key_of(doc, 5, 1), "0.0", "a child's key nests under its parent");
    expect_str(key_of(doc, 5, 2), "0.0.0", "siblings differ only in the last ordinal (first)");
    expect_str(key_of(doc, 5, 3), "0.0.1", "siblings differ only in the last ordinal (second)");
    expect_str(key_of(doc, 5, 4), "0.1", "a later sibling of a parent advances that parent's ordinal");

    /* --- Expanded is the default --- */
    expect_str(visible_string(doc, 5, NULL, 0), "0,1,2,3,4", "no collapsed keys shows every row");

    /* --- Collapsing hides descendants, not the row itself --- */
    expect_str(visible_string(doc, 5, k00, 1), "0,1,4", "collapsing a section hides its children but keeps it visible");
    expect_str(visible_string(doc, 5, k0, 1), "0", "collapsing the root hides everything below it");
    /* The bug this guards: a collapsed subtree must stop hiding when the list
     * comes back up to its level, or the sections after it vanish too. */
    expect(strstr(visible_string(doc, 5, k00, 1), "4") != NULL, "a sibling after a collapsed section is still shown");

    /* --- Collapse all / expand all --- */
    expect(spdf_win_sidebar_outline_collapsible_count(doc, 5) == 2, "only rows with children are collapsible");
    expect_str(visible_string(doc, 5, all, 2), "0", "collapse all leaves just the roots of each branch");
    expect(!spdf_win_sidebar_outline_has_children(doc, 5, 2), "a leaf is never stored as collapsible");
    expect(spdf_win_sidebar_outline_open_count(doc, 5, NULL, 0) == 2, "everything open: two to collapse");
    expect(spdf_win_sidebar_outline_open_count(doc, 5, k00, 1) == 1, "one folded: one still open");
    expect(spdf_win_sidebar_outline_open_count(doc, 5, all, 2) == 0, "all folded: nothing open, the button expands");

    /* --- A key from a document that has since changed --- */
    expect_str(visible_string(doc, 5, stale, 1), "0,1,2,3,4", "an unknown key hides nothing");

    /* --- An outline that does not start at level 0 --- */
    expect(spdf_win_sidebar_outline_has_children(deep, 4, 0), "a deeper-rooted outline still nests");
    deep_root[0] = key_of(deep, 4, 0);
    expect_str(visible_string(deep, 4, deep_root, 1), "0,3", "collapsing its root hides its children");

    /* --- Degenerate shapes --- */
    expect_str(visible_string(doc, 0, NULL, 0), "", "an empty outline has no rows");
    expect(spdf_win_sidebar_outline_collapsible_count(flat, 3) == 0, "a flat outline has no triangles");
    expect(spdf_win_sidebar_outline_has_children(skipped, 2, 0), "a skipped level still nests");

    /* --- Bounds the mac never needed --- */
    expect(spdf_win_sidebar_outline_key(doc, 5, 7, (char*)deep_root, 0) == 0, "no buffer, no key");
    {
        char tiny[3];
        expect(spdf_win_sidebar_outline_key(doc, 5, 2, tiny, sizeof(tiny)) == 0 && tiny[0] == '\0',
               "a buffer too small yields an empty key, never a truncated one");
    }
}

/* --- the builder and the row geometry ------------------------------------ */

static void test_builder(void) {
    static const char* titles[] = {"Title", "Install", "macOS", "Linux", "Usage"};
    static const int pages[] = {0, 1, 2, 3, 4};
    static const int levels[] = {0, 1, 2, 2, 1};
    static const char* k00[] = {"0.0"};
    SpdfWinSidebarRow rows[8];
    wchar_t arena[512];
    unsigned char visible[8];
    int n;

    n = spdf_win_sidebar_build_rows_ex(titles, pages, levels, 5, NULL, NULL, 0, visible, rows, 8, arena, 512);
    expect(n == 5, "nothing collapsed: every entry is a row");
    expect(rows[0].has_children && rows[1].has_children && !rows[2].has_children && !rows[4].has_children,
           "has_children follows the level shape");
    expect(!rows[0].collapsed && !rows[1].collapsed, "nothing is collapsed by default");

    n = spdf_win_sidebar_build_rows_ex(titles, pages, levels, 5, NULL, k00, 1, visible, rows, 8, arena, 512);
    expect(n == 3, "collapsing Install hides its two children");
    expect(rows[1].collapsed && rows[1].has_children, "the collapsed row is a row, marked collapsed");
    expect(rows[2].outline_index == 4 && wcscmp(rows[2].title, L"Usage") == 0, "Usage, after the fold, survives");
    expect(!rows[0].collapsed, "the root is open");

    /* A live filter turns nesting off: matches under a collapsed parent show,
     * and no row claims a triangle. */
    n = spdf_win_sidebar_build_rows_ex(titles, pages, levels, 5, L"a", k00, 1, visible, rows, 8, arena, 512);
    expect(n == 3 && rows[1].outline_index == 2, "the filter reaches macOS under the collapsed Install");
    expect(!rows[0].has_children && !rows[1].has_children && !rows[2].has_children && !rows[0].collapsed,
           "a filtered list has no triangles");

    /* The plain builder is the nested one with nothing collapsed. */
    n = spdf_win_sidebar_build_rows(titles, pages, levels, 5, NULL, rows, 8, arena, 512);
    expect(n == 5 && rows[0].has_children && !rows[0].collapsed, "build_rows marks children and folds nothing");
}

static void test_geometry(float dpi) {
    SpdfWinChromeRect row, slot, title, side;
    SpdfWinSidebarLayout l;
    row.x = 0.0f;
    row.y = 0.0f;
    row.w = spdf_win_chrome_px(400.0, dpi);
    row.h = spdf_win_chrome_px(25.0, dpi);

    /* styleSidebarCell: indent 6 + level*13, triangle 14 wide, title +2, -6. */
    slot = spdf_win_sidebar_disclosure_rect(row, 0, dpi);
    title = spdf_win_sidebar_title_rect(row, 0, dpi);
    expect_near(slot.x, spdf_win_chrome_px(6.0, dpi), "a root row's triangle is 6 pt in");
    expect_near(slot.w, spdf_win_chrome_px(14.0, dpi), "the triangle's slot is 14 pt wide");
    expect_near(slot.h, row.h, "the slot is the row's height");
    expect_near(title.x, spdf_win_chrome_px(22.0, dpi), "a root title starts 22 pt in");
    expect_near(title.x + title.w, row.w - spdf_win_chrome_px(6.0, dpi), "the title stops 6 pt before the edge");
    title = spdf_win_sidebar_title_rect(row, 1, dpi);
    expect_near(title.x, spdf_win_chrome_px(35.0, dpi), "a nested title sits 13 pt further in");
    slot = spdf_win_sidebar_disclosure_rect(row, 16, dpi);
    expect_near(slot.x, spdf_win_chrome_px(214.0, dpi), "level 16 indents the triangle 6 + 16*13 pt");
    slot = spdf_win_sidebar_disclosure_rect(row, 99, dpi);
    expect_near(slot.x, spdf_win_chrome_px(214.0, dpi), "the rect clamps the level like the builder");

    /* The toggle button's slot: the field's own row, 22 pt at its trailing end,
     * the field beside it 26 pt shorter. Chapters only. */
    side.x = 0.0f;
    side.y = spdf_win_chrome_px(84.0, dpi);
    side.w = spdf_win_chrome_px(240.0, dpi);
    side.h = spdf_win_chrome_px(700.0, dpi);
    spdf_win_sidebar_layout(side, 0, dpi, &l);
    expect_near(l.toggle.w, spdf_win_chrome_px(SPDF_WIN_SIDEBAR_TOGGLE_W, dpi), "the toggle slot is 22 pt wide");
    expect_near(l.toggle.x + l.toggle.w, l.filter.x + l.filter.w, "the toggle slot ends where the field would");
    expect_near(l.toggle.y, l.filter.y, "the toggle sits on the field's row");
    expect_near(l.toggle.h, l.filter.h, "and is as tall as the field");
    expect_near(spdf_win_sidebar_filter_beside_toggle(&l, dpi).w,
                l.filter.w - spdf_win_chrome_px(SPDF_WIN_SIDEBAR_TOGGLE_W + SPDF_WIN_SIDEBAR_TOGGLE_GAP, dpi),
                "the field beside the button gives up the button and the 4 pt gap");
    expect(l.list.y > l.toggle.y + l.toggle.h - 0.001f, "the list follows the field's row: the button costs no height");
    spdf_win_sidebar_layout(side, 1, dpi, &l);
    expect(spdf_win_chrome_rect_empty(l.toggle), "Comments has no toggle slot");
    expect_near(spdf_win_sidebar_filter_beside_toggle(&l, dpi).w, l.filter.w, "without a slot the field is full width");
}

/* --- chapters.yaml: the JSON half ----------------------------------------- */

static void test_state_json(void) {
    /* A documents.yaml record as the mac writes it, with members this module
     * does not model around the one it reads. The key is JSON-escaped. */
    static const char* mac =
        "{\"C:\\\\Docs\\\\a.pdf\":{\"collapsedChapters\":[\"0\",\"0.2.1\"],\"path\":\"C:\\\\Docs\\\\a.pdf\","
        "\"showSidebar\":true,\"updatedAt\":1},\"D:\\\\other.pdf\":{\"path\":\"D:\\\\other.pdf\"}}";
    const char *v, *ve;
    char** keys = NULL;
    int count = 0;
    char* merged;
    char* again;

    expect(spdf_win_chapter_state_path_equal("C:\\Docs\\A.PDF", "c:/docs/a.pdf"), "the path rule folds case and slashes");
    expect(!spdf_win_chapter_state_path_equal("C:\\Docs\\a.pdf", "C:\\Docs\\b.pdf"), "different files differ");

    expect(spdf_win_chapter_state_find_member(mac, "c:/docs/a.pdf", 1, NULL, NULL, &v, &ve),
           "the record is found by the path rule through the JSON escaping");
    expect(v && *v == '{', "the record is an object");
    {
        char record[512];
        memcpy(record, v, (size_t)(ve - v));
        record[ve - v] = '\0';
        expect(spdf_win_chapter_state_keys_from_record(record, &keys, &count), "the record carries collapsedChapters");
        expect(count == 2 && keys && strcmp(keys[0], "0") == 0 && strcmp(keys[1], "0.2.1") == 0,
               "the two keys come out in order");
        spdf_win_chapter_state_free_keys(keys, count);
        expect(!spdf_win_chapter_state_keys_from_record("{\"path\":\"x\"}", &keys, &count),
               "a record without the member is expanded");
    }
    expect(!spdf_win_chapter_state_find_member(mac, "E:\\nowhere.pdf", 1, NULL, NULL, &v, &ve), "an unknown path is not found");

    /* Merging into an empty file: exactly the mac's record shape, keys sorted. */
    {
        static const char* unsorted[] = {"0.2.1", "0"};
        merged = spdf_win_chapter_state_merge(NULL, "C:\\Docs\\a.pdf", unsorted, 2);
        expect_str(merged, "{\"C:\\\\Docs\\\\a.pdf\":{\"collapsedChapters\":[\"0\",\"0.2.1\"],\"path\":\"C:\\\\Docs\\\\a.pdf\"}}",
                   "a first record is the mac's shape with sorted keys");
        /* Replacing it keeps the other record and does not duplicate this one. */
        again = spdf_win_chapter_state_merge(mac, "c:/docs/a.pdf", unsorted, 1);
        expect(again && strstr(again, "\"D:\\\\other.pdf\":{\"path\":\"D:\\\\other.pdf\"}") != NULL,
               "another document's record is carried through");
        expect(again && strstr(again, "[\"0.2.1\"]") != NULL && strstr(again, "[\"0\",\"0.2.1\"]") == NULL,
               "the document's record is replaced, not appended");
        expect(again && strstr(again, "showSidebar") == NULL, "the replaced record is this module's shape");
        free(again);
        /* Nothing collapsed: the record goes away. */
        again = spdf_win_chapter_state_merge(merged, "C:\\Docs\\a.pdf", NULL, 0);
        expect_str(again, "{}", "an empty set removes the record");
        free(again);
        free(merged);
    }
}

/* --- chapters.yaml: the files ---------------------------------------------- */

static void test_state_files(const char* scratch) {
    char dir[1024];
    char** keys = NULL;
    int count = 0;
    static const char* two[] = {"1", "0"};

    if (!scratch || !scratch[0]) {
        printf("FAIL no scratch directory argument\n");
        failures++;
        return;
    }
    _snprintf_s(dir, sizeof(dir), _TRUNCATE, "%s\\chapter-state", scratch);
    expect(spdf_win_paths_ensure_dir(dir), "the scratch state directory exists");
    spdf_win_paths_set_state_dir_override(dir);

    expect(!spdf_win_chapter_state_load("C:\\Docs\\a.pdf", &keys, &count), "an empty directory remembers nothing");
    expect(spdf_win_chapter_state_save("C:\\Docs\\a.pdf", two, 2), "the first save writes the file");
    expect(spdf_win_chapter_state_load("c:/docs/A.pdf", &keys, &count) && count == 2, "the keys come back by the path rule");
    expect(count == 2 && strcmp(keys[0], "0") == 0 && strcmp(keys[1], "1") == 0, "sorted on the way out, in order on the way in");
    spdf_win_chapter_state_free_keys(keys, count);
    keys = NULL;
    expect(spdf_win_chapter_state_save("C:\\Docs\\a.pdf", NULL, 0), "saving an empty set succeeds");
    expect(!spdf_win_chapter_state_load("C:\\Docs\\a.pdf", &keys, &count), "and the document is forgotten");

    /* The file is YAML through the one codec, with the standard header. */
    {
        char* json;
        expect(spdf_win_chapter_state_save("C:\\Docs\\b.pdf", two, 1), "another save");
        json = spdf_win_state_read_json(SPDF_WIN_CHAPTER_STATE_FILE);
        expect(json && strstr(json, "\"collapsedChapters\":[\"1\"]") != NULL, "the file round-trips through spdf_yaml");
        free(json);
    }

    /* A documents.yaml the mac wrote, in the same directory: honoured when
     * chapters.yaml says nothing about the document. */
    expect(spdf_win_state_write_json(SPDF_WIN_STATE_DOCUMENTS,
                                     "{\"C:\\\\Docs\\\\mac.pdf\":{\"collapsedChapters\":[\"0.1\"],\"path\":\"C:\\\\Docs\\\\mac.pdf\","
                                     "\"showMinimap\":false}}"),
           "a mac-shaped documents.yaml is written");
    expect(spdf_win_chapter_state_load("C:\\Docs\\mac.pdf", &keys, &count) && count == 1 && strcmp(keys[0], "0.1") == 0,
           "the mac's collapsedChapters is honoured");
    spdf_win_chapter_state_free_keys(keys, count);
    spdf_win_paths_set_state_dir_override(NULL);
}

int main(int argc, char** argv) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f;
    scales[2] = 2.0f;

    test_mac_cases();
    test_builder();
    for (i = 0; i < 3; ++i) test_geometry(scales[i]);
    test_state_json();
    test_state_files(argc > 1 ? argv[1] : NULL);

    if (failures) {
        printf("%d sidebar outline check(s) failed\n", failures);
        return 1;
    }
    printf("All sidebar outline checks passed\n");
    return 0;
}
