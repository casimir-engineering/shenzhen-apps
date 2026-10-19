/* session_frame_test.c — the second half of portable/win/src/spdf_win_session.{h,cpp}:
 * the window's frame, the per-tab search text, and the detach hand-over.
 *
 * Split from session_test.c, which is at its 500-line cap; same subject, same
 * codec, same file shell, same scratch layout. Three claims:
 *
 *   1. THE FRAME ROUND-TRIPS as the mac schema spells it ("frame": {x, y,
 *      width, height}), a save with no frame keeps the one on disk, and a mac
 *      frame reads back through the same path.
 *   2. searchText ROUND-TRIPS per tab -- written only when there is a query,
 *      read back into the tab's view, and a mac tab's query lands in the right
 *      tab -- because "each tab remembers its query across relaunches" is the
 *      readme's promise and it was carried through untouched until now.
 *   3. DETACHING A TAB writes it as a NEW window under a fresh id with its
 *      whole view state, leaves the source window untouched in the file, and
 *      the new id restores to exactly that one tab -- which is the whole
 *      hand-over a second process needs.
 *   4. THE DISPLAY IDENTITY AND THE FOCUS STAMP (the 26.9.4-3 port): "display"
 *      rides beside the frame and reads back; "focusedAt" is stamped only by a
 *      save that says the window is in front and kept otherwise; a plain
 *      restore takes the NEWEST stamp, and the first window when no entry has
 *      one; and spdf_win_session_window_ids() names every window a launch
 *      spawns, the hand-off parking spot excluded.
 *   5. KEEP IMAGE COLORS IS PER TAB: "preservesImageColors" is written for each
 *      tab and read back into it -- two tabs holding opposite values -- and a
 *      tab from a file written before the key existed reads as -1, the "seed
 *      me with the default" the frontend acts on (mac: SPDFMacTabStateTests).
 *
 * Exit code is the whole signal: 0 pass, 1 fail.
 */
/* spdf-test-sources: portable/win/src/spdf_win_session.cpp portable/win/src/spdf_win_tabs.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "silent_failure_support.h" /* check, write_whole/read_whole, remove_file */

#include "../src/spdf_win_session.h"
#include "../src/spdf_win_state.h"

static void check_eq(int got, int want, const char* what) {
    if (got != want) {
        printf("FAIL: %s (got %d, want %d)\n", what, got, want);
        g_failures++;
    }
}

static char g_session_path[SPDF_WIN_PATH_MAX];

static const char* const kMacSessionYaml =
    "# ShenzhenPDF session \xe2\x80\x94 edit while the app is closed\n"
    "version: 2\n"
    "windows:\n"
    "  - frame:\n"
    "      height: 800\n"
    "      width: 1120\n"
    "      x: 100\n"
    "      y: 120\n"
    "    id: \"win-mac-1\"\n"
    "    selectedTab: 1\n"
    "    tabs:\n"
    "      - fitMode: 2\n"
    "        page: 12\n"
    "        path: \"/Users/r/a.pdf\"\n"
    "        searchText: \"budget \xe5\xbc\xa0\"\n"
    "        viewMode: 1\n"
    "        zoom: 1.25\n"
    "      - page: 1\n"
    "        path: \"/Users/r/b.pdf\"\n"
    "        viewMode: 1\n"
    "        zoom: 1\n";

static void test_frame_and_search_read_from_a_mac_file(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_session_frame frame;
    char id[SPDF_WIN_SESSION_ID_MAX] = {0};

    remove_file(g_session_path);
    if (!write_whole(g_session_path, kMacSessionYaml)) {
        check(0, "seed a mac-written session.yaml");
        spdf_win_tabs_destroy(tabs);
        return;
    }
    check_eq((int)spdf_win_session_restore_ex(tabs, NULL, id, sizeof(id), &frame), SPDF_WIN_SESSION_RESTORED,
             "restore_ex restores");
    check_eq(frame.x, 100, "frame.x");
    check_eq(frame.y, 120, "frame.y");
    check_eq(frame.w, 1120, "frame.width");
    check_eq(frame.h, 800, "frame.height");
    check(strcmp(spdf_win_tabs_view_const(tabs, 0)->search_text, "budget \xe5\xbc\xa0") == 0,
          "the first tab's searchText lands in the first tab, UTF-8 intact");
    check(spdf_win_tabs_view_const(tabs, 1)->search_text[0] == '\0', "a tab with no searchText has none");
    /* A mac file: no display identity, and tabs written before the key. */
    check(frame.display[0] == '\0', "a mac frame names no display");
    check_eq(spdf_win_tabs_view_const(tabs, 0)->preserves_image_colors, -1,
             "a tab from before preservesImageColors reads as 'seed me'");
    spdf_win_tabs_destroy(tabs);
}

/* Two windows, the SECOND one stamped newer: the reader left it in front. The
 * third entry is the hand-off parking spot, which is never a window. */
static const char* const kTwoWindowsYaml =
    "version: 2\n"
    "windows:\n"
    "  - focusedAt: 100.5\n"
    "    id: \"win-first\"\n"
    "    selectedTab: 0\n"
    "    tabs:\n"
    "      - path: \"C:\\\\docs\\\\first.pdf\"\n"
    "        preservesImageColors: false\n"
    "        viewMode: 1\n"
    "  - display:\n"
    "      height: 1440\n"
    "      name: \"\\\\\\\\.\\\\DISPLAY2\"\n"
    "      width: 3440\n"
    "      x: -820\n"
    "      y: -1440\n"
    "    focusedAt: 200.5\n"
    "    frame:\n"
    "      height: 900\n"
    "      width: 1300\n"
    "      x: 220\n"
    "      y: -1319\n"
    "    id: \"win-second\"\n"
    "    selectedTab: 0\n"
    "    tabs:\n"
    "      - path: \"C:\\\\docs\\\\second.pdf\"\n"
    "        preservesImageColors: true\n"
    "        viewMode: 1\n"
    "  - id: \"tab-handoff\"\n"
    "    selectedTab: 0\n"
    "    tabs:\n"
    "      - path: \"C:\\\\docs\\\\flying.pdf\"\n"
    "        viewMode: 1\n";

static void test_plain_restore_takes_the_focused_window(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_session_frame frame;
    char id[SPDF_WIN_SESSION_ID_MAX] = {0};
    char ids[SPDF_WIN_SESSION_MAX_WINDOWS][SPDF_WIN_SESSION_ID_MAX];
    int n;

    remove_file(g_session_path);
    if (!write_whole(g_session_path, kTwoWindowsYaml)) {
        check(0, "seed a two-window session.yaml");
        spdf_win_tabs_destroy(tabs);
        return;
    }
    check_eq((int)spdf_win_session_restore_ex(tabs, NULL, id, sizeof(id), &frame), SPDF_WIN_SESSION_RESTORED,
             "a plain restore restores");
    check(strcmp(id, "win-second") == 0, "the window with the newest focusedAt, not the first in the file");
    check_eq(spdf_win_tabs_count(tabs), 1, "and only that window's tabs");
    check(strcmp(spdf_win_tabs_path(tabs, 0), "C:\\docs\\second.pdf") == 0, "its document");
    /* The display identity reads back beside the frame. */
    check_eq(frame.y, -1319, "the frame is read raw, negative y included");
    check(strcmp(frame.display, "\\\\.\\DISPLAY2") == 0, "the display's device name");
    check_eq(frame.display_x, -820, "display.x");
    check_eq(frame.display_y, -1440, "display.y");
    check_eq(frame.display_w, 3440, "display.width");
    check_eq(frame.display_h, 1440, "display.height");
    /* Every window a launch spawns, in file order, the parking spot excluded. */
    n = spdf_win_session_window_ids(ids, SPDF_WIN_SESSION_MAX_WINDOWS);
    check_eq(n, 2, "two windows to launch");
    check(n == 2 && strcmp(ids[0], "win-first") == 0 && strcmp(ids[1], "win-second") == 0,
          "named in file order; the caller skips its own");
    /* Per tab: the two documents disagree, and each keeps its own answer. */
    check_eq(spdf_win_tabs_view_const(tabs, 0)->preserves_image_colors, 1, "second.pdf keeps image colours");
    spdf_win_tabs_destroy(tabs);
    tabs = spdf_win_tabs_create();
    check_eq((int)spdf_win_session_restore(tabs, "win-first", NULL, 0), SPDF_WIN_SESSION_RESTORED, "the other by id");
    check_eq(spdf_win_tabs_view_const(tabs, 0)->preserves_image_colors, 0, "first.pdf does not");
    spdf_win_tabs_destroy(tabs);
}

static void test_no_stamp_means_the_first_window(void) {
    spdf_win_tabs* a = spdf_win_tabs_create();
    spdf_win_tabs* b = spdf_win_tabs_create();
    spdf_win_tabs* back = spdf_win_tabs_create();
    char id[SPDF_WIN_SESSION_ID_MAX] = {0};

    remove_file(g_session_path);
    spdf_win_tabs_append(a, "C:\\docs\\a.pdf", NULL);
    spdf_win_tabs_select_deferred(a, 0);
    spdf_win_tabs_append(b, "C:\\docs\\b.pdf", NULL);
    spdf_win_tabs_select_deferred(b, 0);
    /* Two unfocused saves: both stamped 0, as a file from before the key. */
    check(spdf_win_session_save_focused(a, "win-a", NULL, 0), "save a, not in front");
    check(spdf_win_session_save_focused(b, "win-b", NULL, 0), "save b, not in front");
    check_eq((int)spdf_win_session_restore(back, NULL, id, sizeof(id)), SPDF_WIN_SESSION_RESTORED, "restores");
    check(strcmp(id, "win-a") == 0, "all equal: the first window, exactly as before the key existed");
    spdf_win_tabs_destroy(back);
    spdf_win_tabs_destroy(b);
    spdf_win_tabs_destroy(a);
}

static void test_focus_stamp_is_written_in_front_and_kept_otherwise(void) {
    spdf_win_tabs* a = spdf_win_tabs_create();
    spdf_win_tabs* b = spdf_win_tabs_create();
    spdf_win_tabs* back = spdf_win_tabs_create();
    spdf_win_session_frame frame, got;
    char id[SPDF_WIN_SESSION_ID_MAX] = {0};
    char* yaml;
    char* stamp;
    char kept[64] = {0};

    remove_file(g_session_path);
    spdf_win_tabs_append(a, "C:\\docs\\a.pdf", NULL);
    spdf_win_tabs_select_deferred(a, 0);
    spdf_win_tabs_append(b, "C:\\docs\\b.pdf", NULL);
    spdf_win_tabs_select_deferred(b, 0);
    memset(&frame, 0, sizeof(frame));
    frame.x = 220;
    frame.y = -1319;
    frame.w = 1300;
    frame.h = 900;
    strcpy(frame.display, "\\\\.\\DISPLAY2");
    frame.display_x = -820;
    frame.display_y = -1440;
    frame.display_w = 3440;
    frame.display_h = 1440;
    /* a is written first and IN FRONT; b afterwards and not. Newest wins, so
     * the order in the file must not be what decides. */
    check(spdf_win_session_save_focused(a, "win-a", &frame, 1), "save a in front");
    check(spdf_win_session_save_focused(b, "win-b", NULL, 0), "save b behind");
    yaml = read_whole(g_session_path);
    /* Emission order, as the frame: the name first, then the rectangle in the
     * frame's own key order, and the backslashes escaped as the codec writes
     * every string. */
    if (!yaml || strstr(yaml, "    display:\n      name: \"\\\\\\\\.\\\\DISPLAY2\"\n      height: 1440\n      width: 3440\n"
                              "      x: -820\n      y: -1440\n") == NULL) {
        check(0, "the display is written beside the frame, name first, then the rectangle");
        printf("--- session.yaml ---\n%s--- end ---\n", yaml ? yaml : "(unreadable)");
    }
    stamp = yaml ? strstr(yaml, "focusedAt: ") : NULL;
    /* Seconds since 2001-01-01: anything written after 2026 is past 7.9e8. */
    check(stamp != NULL && strtod(stamp + 11, NULL) > 7.9e8, "a's stamp is a real time in the mac's unit, not 0");
    if (stamp) {
        size_t n = strcspn(stamp, "\n");
        if (n < sizeof(kept)) memcpy(kept, stamp, n);
    }
    free(yaml);
    check_eq((int)spdf_win_session_restore_ex(back, NULL, id, sizeof(id), &got), SPDF_WIN_SESSION_RESTORED, "restores");
    check(strcmp(id, "win-a") == 0, "the window saved in front comes back, though it is not last in the file");
    check(strcmp(got.display, "\\\\.\\DISPLAY2") == 0 && got.display_w == 3440, "with its display identity");
    /* A later save of a that is NOT in front keeps the stamp it had. */
    spdf_win_tabs_view(a, 0)->page = 5;
    check(spdf_win_session_save_focused(a, "win-a", &frame, 0), "save a behind");
    yaml = read_whole(g_session_path);
    check(yaml && kept[0] && strstr(yaml, kept) != NULL, "the stamp is carried through a save that is not in front");
    free(yaml);
    /* And a save with no frame keeps the display too, not only the frame. */
    check(spdf_win_session_save(a, "win-a"), "frameless save");
    spdf_win_tabs_destroy(back);
    back = spdf_win_tabs_create();
    check_eq((int)spdf_win_session_restore_ex(back, "win-a", NULL, 0, &got), SPDF_WIN_SESSION_RESTORED, "reads back");
    check(got.w == 1300 && strcmp(got.display, "\\\\.\\DISPLAY2") == 0, "frame and display both survived");
    spdf_win_tabs_destroy(back);
    spdf_win_tabs_destroy(b);
    spdf_win_tabs_destroy(a);
}

static void test_keep_image_colors_round_trips_per_tab(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs* back = spdf_win_tabs_create();
    char* yaml;

    remove_file(g_session_path);
    spdf_win_tabs_append(tabs, "C:\\docs\\datasheet.pdf", NULL);
    spdf_win_tabs_append(tabs, "C:\\docs\\scan.pdf", NULL);
    spdf_win_tabs_append(tabs, "C:\\docs\\undecided.pdf", NULL);
    spdf_win_tabs_select_deferred(tabs, 0);
    spdf_win_tabs_view(tabs, 0)->preserves_image_colors = 1;
    spdf_win_tabs_view(tabs, 1)->preserves_image_colors = 0;
    spdf_win_tabs_view(tabs, 2)->preserves_image_colors = -1; /* never seeded: no key */
    check(spdf_win_session_save(tabs, "win-K"), "save");
    yaml = read_whole(g_session_path);
    check(yaml && strstr(yaml, "preservesImageColors: true") != NULL, "the mac's key, true for the datasheet");
    check(yaml && strstr(yaml, "preservesImageColors: false") != NULL, "and false for the scan");
    {
        int keys = 0;
        const char* p = yaml;
        while (p && (p = strstr(p, "preservesImageColors")) != NULL) {
            ++keys;
            ++p;
        }
        check_eq(keys, 2, "exactly two: a tab with no choice gets no key");
    }
    free(yaml);
    check_eq((int)spdf_win_session_restore(back, "win-K", NULL, 0), SPDF_WIN_SESSION_RESTORED, "reads back");
    check_eq(spdf_win_tabs_view_const(back, 0)->preserves_image_colors, 1, "the datasheet keeps its colours");
    check_eq(spdf_win_tabs_view_const(back, 1)->preserves_image_colors, 0, "the scan does not");
    check_eq(spdf_win_tabs_view_const(back, 2)->preserves_image_colors, -1, "the undecided one is still to seed");
    spdf_win_tabs_destroy(back);
    spdf_win_tabs_destroy(tabs);
}

static void test_frame_round_trips_and_is_kept_when_unknown(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs* back = spdf_win_tabs_create();
    spdf_win_session_frame frame, got;
    char* yaml;

    remove_file(g_session_path);
    spdf_win_tabs_append(tabs, "C:\\docs\\one.pdf", NULL);
    spdf_win_tabs_select_deferred(tabs, 0);
    frame.x = -8;
    frame.y = 32;
    frame.w = 1400;
    frame.h = 900;
    check(spdf_win_session_save_ex(tabs, "win-A", &frame), "save with a frame");
    yaml = read_whole(g_session_path);
    /* The codec keeps emission order (the mac's sorted-key files read the same),
     * so the frame follows the id; its own keys are in the mac's order. */
    if (!yaml || strstr(yaml, "    frame:\n      height: 900\n      width: 1400\n      x: -8\n      y: 32\n") == NULL) {
        check(0, "the frame is written in the mac schema's shape and key order");
        printf("--- session.yaml ---\n%s--- end ---\n", yaml ? yaml : "(unreadable)");
    }
    free(yaml);

    /* A save that knows no geometry keeps the frame on disk. */
    spdf_win_tabs_view(tabs, 0)->page = 3;
    check(spdf_win_session_save(tabs, "win-A"), "save without a frame");
    check_eq((int)spdf_win_session_restore_ex(back, "win-A", NULL, 0, &got), SPDF_WIN_SESSION_RESTORED, "reads back");
    check_eq(got.w, 1400, "the frame survived a frameless save");
    check_eq(got.x, -8, "negative coordinates included");
    check_eq(spdf_win_tabs_view_const(back, 0)->page, 3, "and the page moved");
    spdf_win_tabs_destroy(back);
    spdf_win_tabs_destroy(tabs);
}

static void test_search_text_round_trips(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs* back = spdf_win_tabs_create();
    char* yaml;

    remove_file(g_session_path);
    spdf_win_tabs_append(tabs, "C:\\docs\\one.pdf", NULL);
    spdf_win_tabs_append(tabs, "C:\\docs\\two.pdf", NULL);
    spdf_win_tabs_select_deferred(tabs, 1);
    strcpy(spdf_win_tabs_view(tabs, 1)->search_text, "quote \"me\" \\ back");
    check(spdf_win_session_save(tabs, "win-S"), "save");
    yaml = read_whole(g_session_path);
    check(yaml && strstr(yaml, "searchText") != NULL, "a live query is written");
    /* Exactly one: the tab without a query gets no key at all. */
    check(yaml && strstr(strstr(yaml, "searchText") + 1, "searchText") == NULL, "and only for the tab that has one");
    free(yaml);
    check_eq((int)spdf_win_session_restore(back, "win-S", NULL, 0), SPDF_WIN_SESSION_RESTORED, "reads back");
    check(spdf_win_tabs_view_const(back, 0)->search_text[0] == '\0', "no query, no text");
    check(strcmp(spdf_win_tabs_view_const(back, 1)->search_text, "quote \"me\" \\ back") == 0,
          "the query comes back through the codec, escapes and all");
    spdf_win_tabs_destroy(back);
    spdf_win_tabs_destroy(tabs);
}

static void test_detach_hands_a_tab_to_a_new_window(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs* other = spdf_win_tabs_create();
    spdf_win_tabs* source = spdf_win_tabs_create();
    spdf_win_tab_view* v;
    spdf_win_session_frame frame, got;
    char new_id[SPDF_WIN_SESSION_ID_MAX] = {0};

    remove_file(g_session_path);
    spdf_win_tabs_append(tabs, "C:\\docs\\keep.pdf", NULL);
    spdf_win_tabs_append(tabs, "C:\\docs\\torn.pdf", "Torn Off");
    spdf_win_tabs_select_deferred(tabs, 0);
    v = spdf_win_tabs_view(tabs, 1);
    v->page = 41;
    v->zoom = 1.5;
    v->fit_mode = SPDF_WIN_TAB_FIT_CUSTOM;
    v->scroll_y = 300.25;
    v->has_scroll_origin = 1;
    strcpy(v->search_text, "torn");
    check(spdf_win_session_save(tabs, "win-src"), "the source window is on disk");

    frame.x = 40;
    frame.y = 40;
    frame.w = 1120;
    frame.h = 800;
    check(spdf_win_session_detach_tab(tabs, 1, &frame, new_id, sizeof(new_id)), "detach writes");
    check(new_id[0] != '\0' && strcmp(new_id, "win-src") != 0, "under a fresh id");
    /* The source model is untouched: closing the tab is the caller's, after
     * the hand-over has landed on disk. */
    check_eq(spdf_win_tabs_count(tabs), 2, "the source model still has both tabs");

    check_eq((int)spdf_win_session_restore_ex(other, new_id, NULL, 0, &got), SPDF_WIN_SESSION_RESTORED,
             "the new id restores");
    check_eq(spdf_win_tabs_count(other), 1, "to exactly one tab");
    check(strcmp(spdf_win_tabs_path(other, 0), "C:\\docs\\torn.pdf") == 0, "the torn-off one");
    check(strcmp(spdf_win_tabs_title(other, 0), "Torn Off") == 0, "with its title");
    check_eq(spdf_win_tabs_view_const(other, 0)->page, 41, "its page");
    check_eq(spdf_win_tabs_view_const(other, 0)->fit_mode, SPDF_WIN_TAB_FIT_CUSTOM, "its fit mode");
    check(spdf_win_tabs_view_const(other, 0)->zoom > 1.49 && spdf_win_tabs_view_const(other, 0)->zoom < 1.51,
          "its zoom");
    check(spdf_win_tabs_view_const(other, 0)->scroll_y > 300.0, "its scroll offset");
    check(strcmp(spdf_win_tabs_view_const(other, 0)->search_text, "torn") == 0, "and its query");
    check_eq(got.w, 1120, "the frame the caller gave it");

    check_eq((int)spdf_win_session_restore(source, "win-src", NULL, 0), SPDF_WIN_SESSION_RESTORED,
             "the source window is still in the file");
    check_eq(spdf_win_tabs_count(source), 2, "unchanged: the caller removes the tab and saves");

    check(!spdf_win_session_detach_tab(tabs, 7, NULL, new_id, sizeof(new_id)), "a bad index detaches nothing");
    spdf_win_tabs_destroy(source);
    spdf_win_tabs_destroy(other);
    spdf_win_tabs_destroy(tabs);
}

int main(int argc, char** argv) {
    char scratch[SPDF_WIN_PATH_MAX];
    char dir[SPDF_WIN_PATH_MAX];
    const char* base = argc > 1 ? argv[1] : NULL;

    printf("spdf_win_session frame/search/detach tests\n");
    if (!base || !*base) {
#if defined(_WIN32)
        base = getenv("TEMP");
#else
        base = getenv("TMPDIR");
#endif
    }
    if (!base || !*base) base = ".";
    if (!spdf_win_path_join(base, "spdf_session_frame_test", scratch, sizeof(scratch))) return 1;
    if (!spdf_win_path_join(scratch, "Rapha\xc3\xabl", dir, sizeof(dir))) return 1;
    if (!spdf_win_paths_ensure_dir(dir)) {
        printf("FAIL: could not create the scratch directory under %s\n", scratch);
        return 1;
    }
    spdf_win_paths_set_state_dir_override(dir);
    if (!spdf_win_paths_state_file(SPDF_WIN_STATE_SESSION, g_session_path, sizeof(g_session_path))) return 1;

    test_frame_and_search_read_from_a_mac_file();
    test_frame_round_trips_and_is_kept_when_unknown();
    test_search_text_round_trips();
    test_detach_hands_a_tab_to_a_new_window();
    test_plain_restore_takes_the_focused_window();
    test_no_stamp_means_the_first_window();
    test_focus_stamp_is_written_in_front_and_kept_otherwise();
    test_keep_image_colors_round_trips_per_tab();

    remove_file(g_session_path);
    spdf_win_paths_set_state_dir_override(NULL);
    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
