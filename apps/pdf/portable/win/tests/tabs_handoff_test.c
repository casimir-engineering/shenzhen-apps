/* tabs_handoff_test.c — the three decisions behind "drop a torn-off tab
 * directly onto another window's tab bar" (release note 26.7.17-1), each of
 * which is a way the gesture could look right and land wrong.
 *
 *   1. WHICH INDEX A SLOT MEANS when the tab is arriving from somewhere else.
 *      spdf_win_tabstrip_insert_index() must NOT do what
 *      spdf_win_tabstrip_move_index() does: a tab already in the strip
 *      collapses the two slots either side of itself, a tab arriving from
 *      another window collapses nothing. Sharing one function would be
 *      invisible until a reader dropped a tab in the last gap and it landed one
 *      place short.
 *   2. WHERE ANOTHER WINDOW'S TAB BAR IS. The source process hit-tests a
 *      foreign HWND with spdf_win_chrome_layout() over its client rect
 *      (spdf_win_tabs_handoff.h, handoff_strip_hit) — so the properties that
 *      hit-test relies on are pinned here: the band's position and height at
 *      several DPIs, the caption reserve that must NOT accept a drop, and the
 *      short window where there is no band at all.
 *   3. THAT THE TAB'S WHOLE VIEW STATE SURVIVES THE HAND-OVER. The tab travels
 *      through session.yaml under SPDF_WIN_SESSION_HANDOFF_ID; page, zoom,
 *      scroll offset, search text and the read-only shadow-copy binding must
 *      come out the other side identical, the entry must be gone afterwards,
 *      and a parked tab must be INVISIBLE to a launch — otherwise a hand-over
 *      interrupted by a crash reopens as a phantom window.
 *
 * Exit code is the whole signal: 0 pass, 1 fail.
 */

/* spdf-test-sources: portable/win/src/spdf_win_session.cpp portable/win/src/spdf_win_tabs.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "silent_failure_support.h" /* check/note, remove_file */

#include "../src/spdf_win_chrome.h"
#include "../src/spdf_win_session.h"
#include "../src/spdf_win_state.h"
#include "../src/spdf_win_tabs_drag.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static void check_eq(int got, int want, const char* what) {
    if (got != want) {
        printf("FAIL: %s (got %d, want %d)\n", what, got, want);
        g_failures++;
    }
}

static void check_near(double got, double want, const char* what) {
    if (fabs(got - want) > 0.0005) {
        printf("FAIL: %s (got %f, want %f)\n", what, got, want);
        g_failures++;
    }
}

/* --- 1. a slot from ANOTHER window collapses nothing ---------------------- */

static void test_insert_index_is_not_move_index(void) {
    int count = 5, slot;

    /* The plain reading: slot 0 is before the first tab, `count` is after the
     * last, and every slot in between is that many tabs in. */
    for (slot = 0; slot <= count; ++slot)
        check_eq(spdf_win_tabstrip_insert_index(0, slot, count), slot, "an unscrolled slot IS the insertion index");

    /* THE DIFFERENCE FROM A REORDER. With the dragged tab at index 2, a reorder
     * treats slots 2 and 3 as the same no-op place (move_index collapses both
     * to 2, because lifting tab 2 out shifts slot 3 down). A tab arriving from
     * another window is not in this strip, so slot 3 means "third from the
     * left" and nothing collapses. */
    check_eq(spdf_win_tabstrip_move_index(2, 2, count), 2, "a reorder's slot 2 is a no-op");
    check_eq(spdf_win_tabstrip_move_index(3, 2, count), 2, "and so is its slot 3");
    check_eq(spdf_win_tabstrip_insert_index(0, 2, count), 2, "an arriving tab's slot 2 inserts at 2");
    check_eq(spdf_win_tabstrip_insert_index(0, 3, count), 3, "and its slot 3 inserts at 3 -- not collapsed");

    /* A SCROLLED STRIP. Slots are positions among the VISIBLE tabs, so the
     * visible window's start is what turns one into a model index. Dropping in
     * the last visible gap of a strip scrolled to tab 3 must reach index 6, not
     * index 3. */
    check_eq(spdf_win_tabstrip_insert_index(3, 0, 9), 3, "the leading gap of a strip scrolled to 3");
    check_eq(spdf_win_tabstrip_insert_index(3, 3, 9), 6, "and its third gap");

    /* Degenerate input can never produce an index the model would reject. */
    check_eq(spdf_win_tabstrip_insert_index(0, 99, count), count, "a slot past the end clamps to the end");
    check_eq(spdf_win_tabstrip_insert_index(7, 7, count), count, "and so does a stale visible start");
    check_eq(spdf_win_tabstrip_insert_index(-4, -9, count), 0, "negatives clamp to the front");
    check_eq(spdf_win_tabstrip_insert_index(0, 0, 0), 0, "an empty strip takes the tab at 0");
}

/* --- 2. where another window's tab bar is --------------------------------- */

/* The band exactly as the cross-process hit test computes it: the real layout
 * function over a client rect, with a zeroed model — which is all the source
 * process can know about a window belonging to somebody else. */
static void strip_band(unsigned w, unsigned h, float scale, SpdfWinChromeRect* strip, SpdfWinChromeRect* caption) {
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    memset(&model, 0, sizeof(model));
    spdf_win_chrome_layout(&model, w, h, scale, &l);
    *strip = l.tabstrip;
    *caption = l.caption;
}

static void test_foreign_strip_band(void) {
    SpdfWinChromeRect strip, caption;

    /* AT 100%: the band is the top of the client area, the strip's own height,
     * full width. A drop is tested against this rect in the OTHER process, so
     * if it ever stopped being the top-left corner the cross-window drop would
     * silently start missing. */
    strip_band(1120, 800, 1.0f, &strip, &caption);
    check_near(strip.x, 0.0, "the band starts at the client's left edge");
    check_near(strip.y, 0.0, "and at its top");
    check_near(strip.w, 1120.0, "and spans the whole width");
    check_near(strip.h, SPDF_WIN_TABSTRIP_HEIGHT, "at the strip's own height in points at 100%");

    /* AT 150% AND 200%: the band scales, which is why the hit test converts the
     * pointer into strip-local POINTS before asking spdf_win_tabstrip.h
     * anything. A missing conversion would put every drop a third of the strip
     * out at 150%. */
    strip_band(1120, 800, 1.5f, &strip, &caption);
    check_near(strip.h, SPDF_WIN_TABSTRIP_HEIGHT * 1.5, "the band is 1.5x tall at 150%");
    strip_band(1120, 800, 2.0f, &strip, &caption);
    check_near(strip.h, SPDF_WIN_TABSTRIP_HEIGHT * 2.0, "and 2x tall at 200%");

    /* THE CAPTION RESERVE IS INSIDE THE BAND AND MUST NOT TAKE A DROP: it is
     * where the other window's Minimise/Maximise/Close are drawn, and a tab
     * handed to a Close button would be a tab handed to nothing. */
    strip_band(1120, 800, 1.0f, &strip, &caption);
    check(!spdf_win_chrome_rect_empty(caption), "the band has a caption reserve");
    check_near(caption.w, SPDF_WIN_TABSTRIP_TRAILING_INSET, "three caption buttons wide");
    check_near(caption.x + caption.w, strip.w, "flush with the band's trailing edge");
    check_near(caption.h, strip.h, "and as tall as the band");
    check(spdf_win_chrome_contains(strip, caption.x + 2.0f, 4.0f), "a point on a caption button IS in the band");

    /* A WINDOW TOO SHORT FOR CHROME HAS NO BAND, so nothing can be dropped into
     * it. The hit test must read that from the layout rather than assume a
     * strip is always there. */
    strip_band(1120, 40, 1.0f, &strip, &caption);
    check(spdf_win_chrome_rect_empty(strip), "a 40 px-tall window has no tab bar to drop onto");
    check(spdf_win_chrome_rect_empty(caption), "and no caption reserve either");
}

/* --- 3. the tab's view state survives the hand-over ----------------------- */

static char g_session_path[SPDF_WIN_PATH_MAX];

static spdf_win_tabs* one_tab_with_full_view(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tab_view* v;
    if (!tabs) return NULL;
    if (spdf_win_tabs_append(tabs, "C:\\docs\\Rapha\xc3\xabl.pdf", "Rapha\xc3\xabl") < 0) {
        spdf_win_tabs_destroy(tabs);
        return NULL;
    }
    v = spdf_win_tabs_view(tabs, 0);
    v->page = 41;
    v->zoom = 1.75;
    v->custom_zoom = 1.75;
    v->fit_mode = SPDF_WIN_TAB_FIT_CUSTOM;
    v->scroll_x = 12.5;
    v->scroll_y = 3480.25;
    v->has_scroll_origin = 1;
    strcpy(v->search_text, "trans\xc3\xa9quatorial");
    v->read_only = 1;
    strcpy(v->working_path, "C:\\copies\\Rapha\xc3\xabl-copy.pdf");
    v->ro_copy_file_size = 987654ull;
    v->ro_copy_modified_at = 1756900000.1234567;
    spdf_win_tabs_select_deferred(tabs, 0);
    return tabs;
}

static void test_handoff_round_trip(void) {
    spdf_win_tabs* source = one_tab_with_full_view();
    spdf_win_tabs* other = spdf_win_tabs_create();
    spdf_win_tabs* launch = spdf_win_tabs_create();
    char path[SPDF_WIN_TAB_PATH_MAX] = {0};
    char title[SPDF_WIN_TAB_PATH_MAX] = {0};
    spdf_win_tab_view got;
    char id[SPDF_WIN_SESSION_ID_MAX] = {0};

    remove_file(g_session_path);
    if (!source || !other || !launch) {
        printf("FAIL: out of memory building the fixture\n");
        g_failures++;
        return;
    }
    /* A window of somebody else's in the file, so the park and the take are
     * exercised as the merges they really are rather than against an empty
     * file. */
    check_eq(spdf_win_tabs_append(other, "C:\\docs\\other.pdf", NULL), 0, "a second window's tab");
    spdf_win_tabs_select_deferred(other, 0);
    check_eq(spdf_win_session_save(other, "win-other"), 1, "the other window saved");

    /* PARK IT. Same call the drag makes when the pointer is over another
     * window's bar. */
    check_eq(spdf_win_session_detach_tab_as(source, 0, NULL, SPDF_WIN_SESSION_HANDOFF_ID), 1,
             "the tab parked under the hand-off id");

    /* A PARKED TAB IS NOT A WINDOW. A launch that asks for "the first window in
     * the file" must get the real one, and an emptied window must not stay open
     * for a parking spot's sake. */
    check_eq((int)spdf_win_session_restore(launch, NULL, id, sizeof(id)), SPDF_WIN_SESSION_RESTORED,
             "a plain launch still restores a window");
    check(strcmp(id, "win-other") == 0, "and it is the real window, not the parking spot");
    check_eq(spdf_win_tabs_count(launch), 1, "with only that window's tab");
    check_eq(spdf_win_session_other_windows("win-other"), 0, "a parked tab is not another window");

    /* TAKE IT. Same call the receiving window makes on the drop. */
    memset(&got, 0xAB, sizeof(got));
    check_eq(spdf_win_session_handoff_take(path, sizeof(path), title, sizeof(title), &got), 1,
             "the receiving window took the parked tab");
    check(strcmp(path, "C:\\docs\\Rapha\xc3\xabl.pdf") == 0, "with its non-ASCII path intact");
    check(strcmp(title, "Rapha\xc3\xabl") == 0, "and its title");
    check_eq(got.page, 41, "the page it was left on");
    check_near(got.zoom, 1.75, "its zoom");
    check_near(got.custom_zoom, 1.75, "its custom zoom");
    check_eq(got.fit_mode, SPDF_WIN_TAB_FIT_CUSTOM, "its fit mode");
    check_near(got.scroll_x, 12.5, "its horizontal offset");
    check_near(got.scroll_y, 3480.25, "its vertical offset");
    check_eq(got.has_scroll_origin, 1, "and that the offset is real");
    check(strcmp(got.search_text, "trans\xc3\xa9quatorial") == 0, "its live search text");
    check_eq(got.read_only, 1, "its read-only flag");
    check(strcmp(got.working_path, "C:\\copies\\Rapha\xc3\xabl-copy.pdf") == 0, "the shadow copy it renders from");
    check(got.ro_copy_file_size == 987654ull, "the size that copy was made from");
    check_near(got.ro_copy_modified_at, 1756900000.1234567, "and that source's mtime, at stat resolution");

    /* THE ENTRY IS GONE, so a second drop cannot adopt the same tab twice --
     * which would be one document in two windows, both writing the same file. */
    check_eq(spdf_win_session_handoff_take(path, sizeof(path), title, sizeof(title), &got), 0,
             "nothing is parked any more");
    /* And the merge left the other window alone throughout. */
    spdf_win_tabs_destroy(launch);
    launch = spdf_win_tabs_create();
    check_eq((int)spdf_win_session_restore(launch, "win-other", NULL, 0), SPDF_WIN_SESSION_RESTORED,
             "the other window survived both merges");

    spdf_win_tabs_destroy(launch);
    spdf_win_tabs_destroy(other);
    spdf_win_tabs_destroy(source);
}

/* A drag that was abandoned must leave nothing behind for the next one. */
static void test_handoff_discard(void) {
    spdf_win_tabs* source = one_tab_with_full_view();
    char path[SPDF_WIN_TAB_PATH_MAX] = {0};
    spdf_win_tab_view got;

    remove_file(g_session_path);
    if (!source) return;
    check_eq(spdf_win_session_detach_tab_as(source, 0, NULL, SPDF_WIN_SESSION_HANDOFF_ID), 1, "parked");
    spdf_win_session_handoff_discard();
    check_eq(spdf_win_session_handoff_take(path, sizeof(path), NULL, 0, &got), 0,
             "a discarded hand-off leaves nothing to take");
    spdf_win_tabs_destroy(source);
}

/* --- drive ---------------------------------------------------------------- */

int main(int argc, char** argv) {
    char scratch[SPDF_WIN_PATH_MAX];
    char dir[SPDF_WIN_PATH_MAX];
    const char* base = argc > 1 ? argv[1] : NULL;

    printf("tab hand-off tests\n");

    test_insert_index_is_not_move_index();
    test_foreign_strip_band();

    if (!base || !*base) {
#if defined(_WIN32)
        base = getenv("TEMP");
#else
        base = getenv("TMPDIR");
#endif
    }
    if (!base || !*base) base = ".";
    if (!spdf_win_path_join(base, "spdf_tabs_handoff_test", scratch, sizeof(scratch))) return 1;
    if (!spdf_win_path_join(scratch, "Rapha\xc3\xabl", dir, sizeof(dir))) return 1;
    if (!spdf_win_paths_ensure_dir(dir)) {
        printf("FAIL: could not create the scratch directory under %s\n", scratch);
        return 1;
    }
    spdf_win_paths_set_state_dir_override(dir);
    if (!spdf_win_paths_state_file(SPDF_WIN_STATE_SESSION, g_session_path, sizeof(g_session_path))) return 1;

    test_handoff_round_trip();
    test_handoff_discard();

    remove_file(g_session_path);
    spdf_win_paths_set_state_dir_override(NULL);
    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
