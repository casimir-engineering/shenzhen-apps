/* tabs_test.c — portable/win/src/spdf_win_tabs.{h,cpp}.
 *
 * Two things are under test and they are different in kind.
 *
 * THE CLOSE/SELECT POLICY. Every case in the first half is the Windows
 * transcription of a case in portable/mac/tests/SPDFMacTabLifecycleTests.mm,
 * asserting the same outcome. That is the point: the policy was not invented
 * here, it was ported, and if the mac app's rules change these tests are where
 * the drift shows up. Where the mac test names an NSObject identity, this one
 * names a tab index into the same ordering — spdf_win_tabs keeps identity
 * internally for exactly the reason the mac lifecycle does, and
 * `test_identity_survives_equal_paths` is what proves it.
 *
 * THE LAZINESS. The second half asserts that a tab is a promise, not a
 * document: nothing opens until somebody looks. The counter it reads
 * (spdf_win_tabs_materialize_count) counts hook invocations, so a "restore is
 * cheap" claim cannot be satisfied by an open that merely failed.
 *
 * No Win32, no Direct2D, no PDF: the open hook hands back a dummy pointer. A
 * test that needed a real document could not assert "nothing was opened"
 * without also being a test of MuPDF.
 *
 * Native (macOS/Linux):
 *   c++ -std=c++14 -O2 -Wall -Wextra -Werror -c portable/win/src/spdf_win_tabs.cpp -o build/tabs.o
 *   cc  -std=c99  -O2 -Wall -Wextra -Werror -c portable/win/tests/tabs_test.c   -o build/tabs_test.o
 *   c++ build/tabs.o build/tabs_test.o -o build/tabs_test
 *   ./build/tabs_test ; echo $?      # 0 = pass
 *
 * Guest (Windows/MSVC/ARM64):
 *   portable/win/vm-build.sh --run tabs_test \
 *      portable/win/tests/tabs_test.c portable/win/src/spdf_win_tabs.cpp
 *
 * Exit code is the whole signal: 0 pass, 1 fail.
 */
/* spdf-test-sources: portable/win/src/spdf_win_tabs.cpp */
#include "../src/spdf_win_tabs.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;

static void check(int ok, const char* what) {
    if (!ok) {
        printf("FAIL: %s\n", what);
        g_failures++;
    }
}

static void check_eq(int got, int want, const char* what) {
    if (got != want) {
        printf("FAIL: %s (got %d, want %d)\n", what, got, want);
        g_failures++;
    }
}

/* Three tabs, a b c, nothing selected yet. */
static spdf_win_tabs* three_tabs(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs_append(tabs, "a.pdf", NULL);
    spdf_win_tabs_append(tabs, "b.pdf", NULL);
    spdf_win_tabs_append(tabs, "c.pdf", NULL);
    return tabs;
}

static int path_at_is(const spdf_win_tabs* tabs, int index, const char* want) {
    const char* got = spdf_win_tabs_path(tabs, index);
    return got && strcmp(got, want) == 0;
}

static int selected_path_is(const spdf_win_tabs* tabs, const char* want) {
    return path_at_is(tabs, spdf_win_tabs_selected_index(tabs), want);
}

/* --- the ported policy ---------------------------------------------------- */

/* SPDFMacTabLifecycleTests test_close_prefers_adjacent_over_history: Ctrl+W and
 * the close box pass preferMostRecentActive:NO (ShenzhenPDFMac.mm:9115), so the
 * neighbour wins even when history says otherwise. */
static void test_close_prefers_adjacent_over_history(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tabs_select(tabs, 0);
    spdf_win_tabs_select(tabs, 1);
    spdf_win_tabs_select(tabs, 2);
    check_eq(spdf_win_tabs_close(tabs, 2, 0), 1, "closing the last tab selects its left neighbour");
    check(selected_path_is(tabs, "b.pdf"), "and that neighbour is b, not the most recent a");
    spdf_win_tabs_destroy(tabs);
}

/* test_active_detach_restores_mru: detach (:9300) asks for the most recently
 * active survivor instead. */
static void test_detach_restores_most_recent(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tabs_select(tabs, 0);
    spdf_win_tabs_select(tabs, 1);
    spdf_win_tabs_select(tabs, 0);
    spdf_win_tabs_select(tabs, 2);
    spdf_win_tabs_close(tabs, 2, 1);
    check(selected_path_is(tabs, "a.pdf"), "detaching c returns to the most recently active a");
    spdf_win_tabs_close(tabs, 0, 1);
    check(selected_path_is(tabs, "b.pdf"), "detaching a then returns to b");
    spdf_win_tabs_destroy(tabs);
}

/* test_detach_fallback_is_adjacent: with no surviving history entry, MRU falls
 * back to the deterministic neighbour — right, else left. */
static void test_mru_falls_back_to_adjacent(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tabs_select(tabs, 1);
    spdf_win_tabs_close(tabs, 1, 1);
    check(selected_path_is(tabs, "c.pdf"), "with no history survivor, the tab to the right wins");
    spdf_win_tabs_destroy(tabs);

    tabs = three_tabs();
    spdf_win_tabs_select(tabs, 2);
    spdf_win_tabs_close(tabs, 2, 1);
    check(selected_path_is(tabs, "b.pdf"), "closing the rightmost falls back to the left");
    spdf_win_tabs_destroy(tabs);

    tabs = spdf_win_tabs_create();
    spdf_win_tabs_append(tabs, "only.pdf", NULL);
    spdf_win_tabs_select(tabs, 0);
    check_eq(spdf_win_tabs_close(tabs, 0, 1), -1, "closing the last remaining tab leaves no selection");
    check_eq(spdf_win_tabs_count(tabs), 0, "and no tabs");
    spdf_win_tabs_destroy(tabs);
}

/* test_inactive_removal_preserves_selection: the SELECTION FOLLOWS THE TAB. */
static void test_inactive_close_keeps_the_same_tab_selected(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tabs_select(tabs, 1);
    spdf_win_tabs_select(tabs, 0);
    check_eq(spdf_win_tabs_close(tabs, 2, 1), 0, "closing an unselected tab does not move the selection");
    check(selected_path_is(tabs, "a.pdf"), "a is still the selected tab");
    spdf_win_tabs_close(tabs, 0, 1);
    check(selected_path_is(tabs, "b.pdf"), "and closing a then hands over to b");
    spdf_win_tabs_destroy(tabs);

    /* The index half of the same rule: closing to the LEFT of the selection
     * shifts its index down without changing which tab is selected. */
    tabs = three_tabs();
    spdf_win_tabs_select(tabs, 2);
    check_eq(spdf_win_tabs_close(tabs, 0, 0), 1, "the selected index shifts down by one");
    check(selected_path_is(tabs, "c.pdf"), "but c is still the selected tab");
    spdf_win_tabs_destroy(tabs);
}

/* CLOSE OTHER TABS, which is not a model operation but a LOOP over this one --
 * spdf_win_cmd_window.h cmd_window_close_other_tabs(). The loop walks the strip
 * downwards and skips one index, and what makes that correct is a property of
 * spdf_win_tabs_close() rather than of the loop: it shifts every index above
 * the closed one down and leaves those below it alone. So the loop is run here,
 * against the model and nothing else, on the case that would expose an
 * off-by-one -- a kept tab in the MIDDLE, so tabs are closed on both sides of
 * it, at both ends of the walk.
 *
 * What a wrong walk looks like: the reader presses Close Other Tabs and is left
 * looking at a different document. */
static void test_close_others_keeps_the_selected_tab(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    int keep, i;
    spdf_win_tabs_append(tabs, "a.pdf", NULL);
    spdf_win_tabs_append(tabs, "b.pdf", NULL);
    spdf_win_tabs_append(tabs, "c.pdf", NULL);
    spdf_win_tabs_append(tabs, "d.pdf", NULL);
    spdf_win_tabs_append(tabs, "e.pdf", NULL);
    spdf_win_tabs_select(tabs, 2);

    keep = spdf_win_tabs_selected_index(tabs);
    for (i = spdf_win_tabs_count(tabs) - 1; i >= 0; --i) {
        if (i == keep) continue;
        spdf_win_tabs_close(tabs, i, 0);
    }
    check_eq(spdf_win_tabs_count(tabs), 1, "every tab but one is gone");
    check(selected_path_is(tabs, "c.pdf"), "and the one left is the tab that was selected");
    check_eq(spdf_win_tabs_selected_index(tabs), 0, "which is now the only index there is");
    spdf_win_tabs_destroy(tabs);

    /* The first and last positions too: the walk starts and ends at a closed
     * tab in one of them, which is where a `>= 0` written `> 0` would show. */
    tabs = three_tabs();
    spdf_win_tabs_select(tabs, 0);
    keep = 0;
    for (i = spdf_win_tabs_count(tabs) - 1; i >= 0; --i)
        if (i != keep) spdf_win_tabs_close(tabs, i, 0);
    check(selected_path_is(tabs, "a.pdf"), "keeping the leftmost tab keeps a");
    check_eq(spdf_win_tabs_count(tabs), 1, "and closes the two to its right");
    spdf_win_tabs_destroy(tabs);

    tabs = three_tabs();
    spdf_win_tabs_select(tabs, 2);
    keep = 2;
    for (i = spdf_win_tabs_count(tabs) - 1; i >= 0; --i)
        if (i != keep) spdf_win_tabs_close(tabs, i, 0);
    check(selected_path_is(tabs, "c.pdf"), "keeping the rightmost tab keeps c");
    check_eq(spdf_win_tabs_count(tabs), 1, "and closes the two to its left");
    spdf_win_tabs_destroy(tabs);
}

/* test_identity_survives_reorder_and_equal_values. Two tabs on the SAME path
 * are two different tabs; a history keyed on the path would restore the wrong
 * one here, and would look correct in every single-path test. */
static void test_identity_survives_equal_paths(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs_append(tabs, "same.pdf", "first");
    spdf_win_tabs_append(tabs, "same.pdf", "second");
    spdf_win_tabs_append(tabs, "third.pdf", NULL);
    spdf_win_tabs_move(tabs, 2, 0); /* third, first, second */
    spdf_win_tabs_select(tabs, 1);  /* first  */
    spdf_win_tabs_select(tabs, 2);  /* second */
    spdf_win_tabs_select(tabs, 0);  /* third  */
    spdf_win_tabs_close(tabs, 0, 1);
    check_eq(spdf_win_tabs_selected_index(tabs), 1, "the MRU survivor is the second same-path tab");
    check(strcmp(spdf_win_tabs_title(tabs, spdf_win_tabs_selected_index(tabs)), "second") == 0,
          "and it is 'second', not the identically-pathed 'first'");
    spdf_win_tabs_destroy(tabs);
}

/* test_stale_history_is_ignored: a closed tab may not come back as the MRU
 * survivor of a later close. */
static void test_closed_tabs_leave_no_history(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tabs_select(tabs, 0); /* a */
    spdf_win_tabs_select(tabs, 1); /* b */
    spdf_win_tabs_select(tabs, 2); /* c */
    spdf_win_tabs_close(tabs, 0, 1);
    check(selected_path_is(tabs, "c.pdf"), "closing unselected a leaves c selected");
    spdf_win_tabs_close(tabs, spdf_win_tabs_selected_index(tabs), 1);
    check(selected_path_is(tabs, "b.pdf"), "the MRU survivor is b -- the closed a is gone from history");
    spdf_win_tabs_destroy(tabs);
}

/* spdf_mac_tab_close_action_enabled, assertion for assertion. */
static void test_close_action_policy(void) {
    check(spdf_win_tabs_close_enabled(2, 1, 0), "a valid selection is closable");
    check(spdf_win_tabs_close_enabled(0, -1, 1), "an open document with no tab strip is closable");
    check(!spdf_win_tabs_close_enabled(2, -1, 0), "no selection and no document is not");
    check(!spdf_win_tabs_close_enabled(2, 2, 0), "an out-of-range selection is not");
    check(!spdf_win_tabs_close_enabled(0, 0, 0), "and neither is a selection into an empty strip");
}

/* --- model mechanics ------------------------------------------------------ */

static void test_insert_and_move_track_the_selection(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tabs_select(tabs, 1);
    spdf_win_tabs_insert(tabs, 0, "new.pdf", NULL);
    check_eq(spdf_win_tabs_selected_index(tabs), 2, "inserting to the left pushes the selected index along");
    check(selected_path_is(tabs, "b.pdf"), "the selected tab is unchanged");
    spdf_win_tabs_move(tabs, 2, 0);
    check_eq(spdf_win_tabs_selected_index(tabs), 0, "moving the selected tab moves the selection with it");
    check(path_at_is(tabs, 1, "new.pdf") && path_at_is(tabs, 2, "a.pdf"), "the rest shift right");
    check_eq(spdf_win_tabs_index_of_path(tabs, "c.pdf"), 3, "lookup by path finds the moved-down tab");
    spdf_win_tabs_destroy(tabs);
}

static void test_select_relative_wraps(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tabs_select(tabs, 2);
    spdf_win_tabs_select_relative(tabs, 1);
    check_eq(spdf_win_tabs_selected_index(tabs), 0, "Ctrl+Tab wraps past the end");
    spdf_win_tabs_select_relative(tabs, -1);
    check_eq(spdf_win_tabs_selected_index(tabs), 2, "Ctrl+Shift+Tab wraps past the start");
    spdf_win_tabs_destroy(tabs);
}

static void test_view_state_is_per_tab(void) {
    spdf_win_tabs* tabs = three_tabs();
    spdf_win_tab_view* first = spdf_win_tabs_view(tabs, 0);
    const spdf_win_tab_view* second = spdf_win_tabs_view_const(tabs, 1);
    check(first->zoom == 1.0 && first->fit_mode == SPDF_WIN_TAB_FIT_PAGE, "a new tab starts at the shared defaults");
    /* The mac's default (SPDFDocumentTab: _preservesImageColors = YES), and per
     * tab: two documents may disagree (SPDFMacTabStateTests, 42e8c9ca7). */
    check(first->preserves_image_colors == 1, "a new tab keeps image colours, the mac's default");
    first->preserves_image_colors = 0;
    check(second->preserves_image_colors == 1, "and the choice is the tab's own, not its neighbour's");
    first->page = 17;
    first->zoom = 2.5;
    first->scroll_y = 400.0;
    check(second->page == 0 && second->zoom == 1.0, "editing one tab's view state leaves its neighbour alone");
    spdf_win_tabs_close(tabs, 1, 0);
    check(spdf_win_tabs_view(tabs, 0)->page == 17 && spdf_win_tabs_view(tabs, 0)->scroll_y == 400.0,
          "and a close elsewhere does not disturb it");
    spdf_win_tabs_destroy(tabs);
}

/* --- laziness ------------------------------------------------------------- */

typedef struct fake_docs {
    int opens;
    int closes;
    char last_path[128];
} fake_docs;

static void* fake_open(void* user, const char* path, char* err, size_t err_len) {
    fake_docs* docs = (fake_docs*)user;
    (void)err;
    (void)err_len;
    docs->opens++;
    snprintf(docs->last_path, sizeof(docs->last_path), "%s", path ? path : "");
    return docs;
}

static void fake_close(void* user, void* document) {
    fake_docs* docs = (fake_docs*)user;
    (void)document;
    docs->closes++;
}

static void test_nothing_opens_until_it_is_looked_at(void) {
    fake_docs docs;
    spdf_win_tabs* tabs = three_tabs();
    int i;

    memset(&docs, 0, sizeof(docs));
    spdf_win_tabs_set_document_hooks(tabs, fake_open, fake_close, &docs);
    spdf_win_tabs_append(tabs, "d.pdf", NULL);

    check_eq(docs.opens, 0, "adding four tabs opens nothing");
    check_eq((int)spdf_win_tabs_materialize_count(tabs), 0, "and the model agrees it has materialised nothing");
    for (i = 0; i < spdf_win_tabs_count(tabs); ++i)
        check(!spdf_win_tabs_is_materialized(tabs, i), "no tab holds a document yet");

    /* A deferred selection is still free -- this is what session restore uses. */
    spdf_win_tabs_select_deferred(tabs, 3);
    check_eq(docs.opens, 0, "select_deferred moves the selection without opening anything");
    check_eq(spdf_win_tabs_selected_index(tabs), 3, "but the selection did move");

    spdf_win_tabs_select(tabs, 2);
    check_eq(docs.opens, 1, "selecting a tab opens exactly one document");
    check(strcmp(docs.last_path, "c.pdf") == 0, "and it is that tab's document");
    check(spdf_win_tabs_is_materialized(tabs, 2), "the selected tab is materialised");
    check(!spdf_win_tabs_is_materialized(tabs, 3), "the deferred one still is not");

    spdf_win_tabs_select(tabs, 2);
    check_eq(docs.opens, 1, "re-selecting the same tab does not open it twice");
    check(spdf_win_tabs_document(tabs, 2, NULL, 0) != NULL, "the document is handed back from the tab");
    check_eq(docs.opens, 1, "asking for an already-open document opens nothing");

    spdf_win_tabs_release_document(tabs, 2);
    check_eq(docs.closes, 1, "releasing hands the document back to the close hook");
    check(!spdf_win_tabs_is_materialized(tabs, 2), "and the tab is a promise again");
    check(spdf_win_tabs_path(tabs, 2) != NULL && spdf_win_tabs_view(tabs, 2) != NULL,
          "while keeping its path and view state");

    spdf_win_tabs_document(tabs, 3, NULL, 0);
    check_eq(docs.opens, 2, "materialising the deferred tab is the second open, not the fifth");
    spdf_win_tabs_close(tabs, 3, 0);
    check_eq(docs.closes, 2, "closing a materialised tab closes its document");
    spdf_win_tabs_destroy(tabs);
    check_eq(docs.closes, 2, "and destroying the model closes only what was open");
}

static void test_a_failing_open_is_still_counted_and_retried(void) {
    fake_docs docs;
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    char err[64];

    memset(&docs, 0, sizeof(docs));
    spdf_win_tabs_append(tabs, "gone.pdf", NULL);
    /* No hooks: the model must say so rather than pretend the tab is open. */
    err[0] = '\0';
    check(spdf_win_tabs_document(tabs, 0, err, sizeof(err)) == NULL, "with no hook there is no document");
    check(err[0] != '\0', "and the caller is told why");

    spdf_win_tabs_set_document_hooks(tabs, fake_open, fake_close, &docs);
    check(spdf_win_tabs_document(tabs, 0, err, sizeof(err)) != NULL, "with a hook the document appears");
    check_eq((int)spdf_win_tabs_materialize_count(tabs), 1, "one hook invocation");
    check(spdf_win_tabs_document(tabs, -1, err, sizeof(err)) == NULL, "a bad index yields nothing");
    check_eq((int)spdf_win_tabs_materialize_count(tabs), 1, "and costs no open");
    spdf_win_tabs_destroy(tabs);
}

int main(void) {
    printf("spdf_win_tabs tests\n");
    test_close_prefers_adjacent_over_history();
    test_detach_restores_most_recent();
    test_mru_falls_back_to_adjacent();
    test_inactive_close_keeps_the_same_tab_selected();
    test_close_others_keeps_the_selected_tab();
    test_identity_survives_equal_paths();
    test_closed_tabs_leave_no_history();
    test_close_action_policy();
    test_insert_and_move_track_the_selection();
    test_select_relative_wraps();
    test_view_state_is_per_tab();
    test_nothing_opens_until_it_is_looked_at();
    test_a_failing_open_is_still_counted_and_retried();

    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
