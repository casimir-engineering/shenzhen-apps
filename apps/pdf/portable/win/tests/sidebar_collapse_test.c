/* Folding the chapter list end to end, on a real outline: the content provider
 * in portable/win/src/spdf_win_chrome_content.cpp over
 * portable/win/tests/fixtures/outline.pdf, whose outline is
 *
 *   0 Introduction         level 0   key 0   (children: 1, 2)
 *   1   Background         level 1   key 0.0
 *   2   U-umlaut-berblick  level 1   key 0.1   (the UTF-16BE title with a BOM)
 *   3 Chapter Two          level 0   key 1   (child: 4)
 *   4   CJK section        level 1   key 1.0   (three CJK characters first)
 *   5 Appendix             level 0   key 2
 *
 * so two rows fold. What is checked, in the order a reader would do it: the
 * rows come out nested with the triangles on 0 and 3; folding row 0 hides its
 * two children and the rest shift up; unfolding restores them; the one button
 * collapses everything while anything is open and expands everything once
 * nothing is; a press is refined against the row's actual triangle slot and the
 * button's slot, and lands nowhere else; a live filter turns nesting off; and
 * the state SURVIVES the document being released and reopened, through
 * chapters.yaml in the scratch state directory (argv[2]) -- the per-document
 * memory, exercised through the real file.
 *
 * The two shared lines that route a press here (spdf_win_chrome_actions.h) are
 * another track's and are requested in this change's report; this test drives
 * the same entry point they will call, so the behaviour is pinned before the
 * wiring lands.
 */

/* spdf-test-sources: portable/win/src/spdf_win_chrome_content.cpp portable/win/src/spdf_win_chrome_content_fold.cpp portable/win/src/spdf_win_chrome_thumbs.cpp portable/win/src/spdf_win_chapter_state.cpp portable/win/src/spdf_win_chapter_store_register.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/win/src/spdf_win_render.c portable/win/src/spdf_win_lru.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_win_compat.c portable/core/spdf_recolor.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/outline.pdf %SCRATCH% */
/* spdf-test-needs: mupdf */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spdf_win_chapter_state.h"
#include "spdf_win_chrome_content.h"
#include "spdf_win_paths.h"
#include "spdf_win_state.h"

static int failures;

static void expect(int condition, const char* what) {
    if (!condition) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static const SpdfWinSidebarContent* sidebar(void) {
    const SpdfWinChromePanelsContent* c = spdf_win_chrome_content_current();
    return c ? c->sidebar : NULL;
}

static SpdfWinChromeRect panel(void) {
    SpdfWinChromeRect r;
    r.x = 0.0f;
    r.y = 84.0f;
    r.w = 240.0f;
    r.h = 700.0f;
    return r;
}

int main(int argc, char** argv) {
    const char* fixture = argc > 1 ? argv[1] : NULL;
    const char* scratch = argc > 2 ? argv[2] : NULL;
    char dir[1024];
    const SpdfWinSidebarContent* sb;
    SpdfWinSidebarLayout l;

    if (!fixture || !scratch) {
        printf("usage: sidebar_collapse_test <outline.pdf> <scratch dir>\n");
        return 2;
    }
    _snprintf_s(dir, sizeof(dir), _TRUNCATE, "%s\\collapse-state", scratch);
    if (!spdf_win_paths_ensure_dir(dir)) {
        printf("FAIL cannot create %s\n", dir);
        return 1;
    }
    spdf_win_paths_set_state_dir_override(dir);
    /* A previous run's memory must not leak into this one. */
    spdf_win_state_write_json(SPDF_WIN_CHAPTER_STATE_FILE, "{}");

    /* --- the nested list ------------------------------------------------ */
    spdf_win_chrome_content_set_document(fixture, 0);
    sb = sidebar();
    expect(sb && sb->loaded, "the outline is loaded on the first paint that needs it");
    if (!sb || !sb->loaded) return 1;
    expect(sb->total_count == 6 && sb->row_count == 6, "six entries, six rows, everything expanded");
    expect(sb->collapsible_count == 2 && sb->open_count == 2, "two rows fold and both are open");
    expect(sb->rows[0].has_children && !sb->rows[0].collapsed, "Introduction has children and is open");
    expect(!sb->rows[1].has_children && sb->rows[1].level == 1, "Background is a leaf at level 1");
    expect(sb->rows[3].has_children && !sb->rows[5].has_children, "Chapter Two folds, Appendix does not");
    expect(sb->rows[2].title[0] == 0x00DC, "the umlaut title survived (no narrow conversion)");

    /* --- one fold ------------------------------------------------------- */
    expect(spdf_win_chrome_content_toggle_row(1) == 0, "a leaf does not fold");
    expect(spdf_win_chrome_content_toggle_row(0) == 1, "Introduction folds");
    sb = sidebar();
    expect(sb->row_count == 4, "its two children are gone from the rows");
    expect(sb->rows[0].collapsed, "and it is marked collapsed");
    expect(sb->rows[1].outline_index == 3 && sb->rows[1].has_children, "Chapter Two moved up, still folding");
    expect(sb->open_count == 1 && sb->collapsible_count == 2, "one of two still open: the button collapses");
    expect(spdf_win_chrome_content_toggle_row(0) == 1, "Introduction unfolds");
    sb = sidebar();
    expect(sb->row_count == 6 && !sb->rows[0].collapsed, "the children are back");

    /* --- the one button ------------------------------------------------- */
    expect(spdf_win_chrome_content_toggle_all() == 1, "collapse all");
    sb = sidebar();
    expect(sb->row_count == 3, "only the three roots remain");
    expect(sb->rows[0].collapsed && sb->rows[1].collapsed && !sb->rows[2].has_children, "both parents are folded");
    expect(sb->open_count == 0, "nothing open: the button now expands");
    expect(spdf_win_chrome_content_toggle_all() == 1, "expand all");
    sb = sidebar();
    expect(sb->row_count == 6 && sb->open_count == 2, "everything is back");

    /* --- a press, refined against the drawn geometry --------------------- */
    spdf_win_sidebar_layout(panel(), 0, 1.0f, &l);
    {
        SpdfWinChromeRect r0 = spdf_win_sidebar_row_rect(&l, 0.0f, 0);
        SpdfWinChromeRect d0 = spdf_win_sidebar_disclosure_rect(r0, 0, 1.0f);
        SpdfWinChromeRect r3 = spdf_win_sidebar_row_rect(&l, 0.0f, 3);
        SpdfWinChromeRect d3 = spdf_win_sidebar_disclosure_rect(r3, 0, 1.0f);
        /* On the title: not consumed, the caller navigates as before. */
        expect(spdf_win_chrome_content_sidebar_press(0, panel(), r0.x + r0.w * 0.5f, r0.y + r0.h * 0.5f, 1.0f) == 0,
               "a press on the title is left to the caller");
        expect(sidebar()->row_count == 6, "and folds nothing");
        /* On the triangle: folds. */
        expect(spdf_win_chrome_content_sidebar_press(0, panel(), d0.x + d0.w * 0.5f, d0.y + d0.h * 0.5f, 1.0f) == 1,
               "a press on the triangle folds the row");
        expect(sidebar()->row_count == 4, "Introduction's children are gone");
        /* Chapter Two is now visible row 1; its triangle is where row 1 draws. */
        {
            SpdfWinChromeRect r1 = spdf_win_sidebar_row_rect(&l, 0.0f, 1);
            SpdfWinChromeRect d1 = spdf_win_sidebar_disclosure_rect(r1, 0, 1.0f);
            expect(spdf_win_chrome_content_sidebar_press(1, panel(), d1.x + 1.0f, d1.y + 1.0f, 1.0f) == 1,
                   "the moved-up row's triangle is where it is drawn");
            expect(sidebar()->row_count == 3, "both folded");
        }
        (void)d3;
        /* A leaf's slot: nothing. Out-of-range rows: nothing. */
        expect(spdf_win_chrome_content_sidebar_press(2, panel(), d0.x + 1.0f, spdf_win_sidebar_row_rect(&l, 0.0f, 2).y + 2.0f,
                                                     1.0f) == 0,
               "a leaf's slot folds nothing");
        expect(spdf_win_chrome_content_sidebar_press(9, panel(), 10.0f, 10.0f, 1.0f) == 0, "a row past the end is nothing");
        /* The button's slot on the filter row: toggles all (everything is folded,
         * so this expands). Elsewhere on the field: left to the caller. */
        expect(spdf_win_chrome_content_sidebar_press(-1, panel(), l.filter.x + 4.0f, l.filter.y + 4.0f, 1.0f) == 0,
               "a press on the field itself is the field's");
        expect(spdf_win_chrome_content_sidebar_press(-1, panel(), l.toggle.x + l.toggle.w * 0.5f,
                                                     l.toggle.y + l.toggle.h * 0.5f, 1.0f) == 1,
               "a press on the button toggles all");
        expect(sidebar()->row_count == 6, "which expanded everything");
    }

    /* --- a live filter turns nesting off ---------------------------------- */
    expect(spdf_win_chrome_content_toggle_row(0) == 1, "fold Introduction again");
    spdf_win_chrome_content_set_filter(L"Uber");
    sb = sidebar();
    expect(sb->row_count == 1 && sb->rows[0].outline_index == 2, "the filter reaches the row under the fold");
    expect(sb->collapsible_count == 0 && !sb->rows[0].has_children, "no triangles and no button under a filter");
    expect(spdf_win_chrome_content_sidebar_press(-1, panel(), l.toggle.x + 2.0f, l.toggle.y + 2.0f, 1.0f) == 0,
           "the button's slot is the field's while the button is hidden");
    spdf_win_chrome_content_set_filter(NULL);
    sb = sidebar();
    expect(sb->row_count == 4 && sb->rows[0].collapsed, "the fold is still there once the filter clears");

    /* --- the memory survives a release and a reopen ----------------------- */
    spdf_win_chrome_content_shutdown();
    {
        char* json = spdf_win_state_read_json(SPDF_WIN_CHAPTER_STATE_FILE);
        expect(json && strstr(json, "\"collapsedChapters\":[\"0\"]") != NULL, "chapters.yaml holds the fold by key");
        free(json);
    }
    spdf_win_chrome_content_set_document(fixture, 0);
    sb = sidebar();
    expect(sb && sb->loaded && sb->row_count == 4 && sb->rows[0].collapsed, "reopened: Introduction comes back folded");
    expect(spdf_win_chrome_content_toggle_all() == 1 && sidebar()->row_count == 3, "collapse all on the reopened document");
    expect(spdf_win_chrome_content_toggle_all() == 1 && sidebar()->row_count == 6, "expand all clears the memory");
    spdf_win_chrome_content_shutdown();
    {
        char* json = spdf_win_state_read_json(SPDF_WIN_CHAPTER_STATE_FILE);
        expect(json && strstr(json, "collapsedChapters") == NULL, "nothing collapsed: the record is gone");
        free(json);
    }
    spdf_win_paths_set_state_dir_override(NULL);

    if (failures) {
        printf("%d sidebar collapse check(s) failed\n", failures);
        return 1;
    }
    printf("All sidebar collapse checks passed\n");
    return 0;
}
