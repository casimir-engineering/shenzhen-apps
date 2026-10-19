/* session_test.c — portable/win/src/spdf_win_session.{h,cpp} against the real,
 * shared portable/core/spdf_yaml.c codec and the real spdf_win_state file shell.
 *
 * Five claims, each about a way this feature could quietly ruin somebody's day
 * rather than merely fail:
 *
 *   1. A session round-trips THROUGH THE SHARED CODEC, and a session.yaml
 *      written by the mac app restores here with its pages, zooms and non-ASCII
 *      paths intact. A Windows-only schema would look perfect in a
 *      Windows-only test and silently strand every cross-platform user.
 *   2. RESTORING OPENS NOTHING: ten restored tabs must cost what one costs
 *      until the reader touches something. The assertion is a hook-invocation
 *      count, so an open that merely failed still counts.
 *   3. A CORRUPT session degrades to "start empty"; an UNREADABLE one is never
 *      written over. Opposite outcomes for the same NULL, and collapsing them
 *      is how one antivirus scan replaces a reader's open documents with none.
 *   4. SAVING PRESERVES WHAT IT DOES NOT UNDERSTAND — another process's
 *      windows, and the per-tab keys this port has no feature for yet.
 *   5. TWO WINDOWS SAVING AT ONCE SERIALISE. That merge is a read-modify-write
 *      across processes; unlocked, the loser's whole window disappears.
 *
 * The unreadable-file plumbing (ACL deny on Windows, chmod on POSIX) is reused
 * from silent_failure_support.h rather than reimplemented; it is header-only
 * harness code, independent of the modules under test.
 *
 * Native (macOS/Linux): compile spdf_win_session.cpp and spdf_win_tabs.cpp with
 * c++, this file plus spdf_win_state.c, spdf_win_paths.c and spdf_yaml.c with
 * cc -std=c99, then link them with c++ (add -lpthread on Linux; claim 5 starts
 * threads). Guest: portable/win/vm-build.sh --run session_test with the same
 * source list as the spdf-test-sources line below — note spdf_win_compat.c
 * lives in portable/core, and omitting it is a wall of LNK2019.
 *
 * Exit code is the whole signal: 0 pass, 1 fail.
 */

/* spdf-test-sources: portable/win/src/spdf_win_session.cpp portable/win/src/spdf_win_tabs.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "scratch_leaf.h" /* a scratch leaf unique to this process */
#include "silent_failure_support.h" /* check/note, write_whole/read_whole, make_unreadable */

#include "../src/spdf_win_session.h"
#include "../src/spdf_win_state.h"

static void check_eq(int got, int want, const char* what) {
    if (got != want) {
        printf("FAIL: %s (got %d, want %d)\n", what, got, want);
        g_failures++;
    }
}

static void check_near(double got, double want, const char* what) {
    double delta = got > want ? got - want : want - got;
    if (delta > 0.00005) {
        printf("FAIL: %s (got %f, want %f)\n", what, got, want);
        g_failures++;
    }
}

static char g_session_path[SPDF_WIN_PATH_MAX];

static void reset_session_file(void) { remove_file(g_session_path); }

/* A session.yaml in the shape the mac app writes: block mappings, sorted keys,
 * double-quoted strings, the standard header comment, non-ASCII paths, and
 * per-tab keys this port has no feature for. Deliberately hand-written rather
 * than produced by the code under test — a round trip that only ever sees its
 * own output proves nothing about the other two frontends. */
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
    "        path: \"/Users/rapha\xc3\xabl/Documents/rapport financi\xc3\xa8r.pdf\"\n"
    "        scrollY: 240.5\n"
    "        searchText: \"budget\"\n"
    "        showSidebar: false\n"
    "        viewMode: 2\n"
    "        zoom: 1.25\n"
    "      - page: 1\n"
    "        path: \"/Users/rapha\xc3\xabl/Documents/\xe5\xbc\xa0\xe4\xbc\x9f.pdf\"\n"
    "        viewMode: 1\n"
    "        zoom: 1\n";

/* --- 1. the shared schema, both directions -------------------------------- */

static void test_reads_a_mac_written_session(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    char id[SPDF_WIN_SESSION_ID_MAX] = {0};
    const spdf_win_tab_view* view;

    reset_session_file();
    if (!write_whole(g_session_path, kMacSessionYaml)) {
        check(0, "seed a mac-written session.yaml");
        spdf_win_tabs_destroy(tabs);
        return;
    }
    check_eq((int)spdf_win_session_restore(tabs, NULL, id, sizeof(id)), SPDF_WIN_SESSION_RESTORED,
             "a mac-written session restores");
    check_eq(spdf_win_tabs_count(tabs), 2, "both tabs came back");
    check(strcmp(id, "win-mac-1") == 0, "and the window id came back with them");
    check(spdf_win_tabs_path(tabs, 0) && strstr(spdf_win_tabs_path(tabs, 0), "financi\xc3\xa8r.pdf"),
          "a non-ASCII path survives the codec and the file layer");
    check(spdf_win_tabs_path(tabs, 1) && strstr(spdf_win_tabs_path(tabs, 1), "\xe5\xbc\xa0\xe4\xbc\x9f"), "so does a CJK one");
    check(strcmp(spdf_win_tabs_title(tabs, 1), "\xe5\xbc\xa0\xe4\xbc\x9f.pdf") == 0,
          "a tab with no title falls back to the file name");
    view = spdf_win_tabs_view_const(tabs, 0);
    check_eq(view->page, 12, "the page is read 0-based, as the mac schema writes it");
    check_near(view->zoom, 1.25, "the zoom survives");
    check_eq(view->fit_mode, SPDF_WIN_TAB_FIT_WIDTH, "so does the fit mode");
    check_near(view->scroll_y, 240.5, "and the scroll offset");
    check(view->has_scroll_origin, "a tab carrying scrollY is treated as having a scroll origin");
    check_eq(spdf_win_tabs_selected_index(tabs), 1, "the persisted selection is restored");
    spdf_win_tabs_destroy(tabs);
}

static void test_round_trips_through_the_shared_codec(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs* back = spdf_win_tabs_create();
    spdf_win_tab_view* view;
    char* on_disk;

    reset_session_file();
    check(!path_exists(g_session_path), "the scratch session file starts absent");
    spdf_win_tabs_append(tabs, "C:\\Users\\rapha\xc3\xabl\\a.pdf", NULL);
    spdf_win_tabs_append(tabs, "C:\\Users\\rapha\xc3\xabl\\b.pdf", "Custom \"quoted\" title");
    view = spdf_win_tabs_view(tabs, 0);
    view->page = 41;
    view->zoom = 1.7500;
    view->custom_zoom = 2.25;
    view->fit_mode = SPDF_WIN_TAB_FIT_ACTUAL;
    view->scroll_x = 12.5;
    view->scroll_y = -33.25;
    view->has_scroll_origin = 1;
    spdf_win_tabs_select_deferred(tabs, 1);

    check(spdf_win_session_save(tabs, "win-test-1") == 1, "the session saves");
    on_disk = read_whole(g_session_path);
    check(on_disk != NULL, "session.yaml exists afterwards");
    /* It must be the shared YAML, not JSON and not a Windows-only shape. */
    check(on_disk && strstr(on_disk, "# ShenzhenPDF session") == on_disk,
          "with the standard header comment the shared codec emits");
    check(on_disk && strstr(on_disk, "windows:") != NULL && strstr(on_disk, "{\"") == NULL,
          "and it is YAML, not the JSON the model happens to marshal through");
    check(on_disk && strstr(on_disk, "viewMode: 1"), "viewMode is written; without it the GTK reader shifts pages");
    free(on_disk);

    check_eq((int)spdf_win_session_restore(back, "win-test-1", NULL, 0), SPDF_WIN_SESSION_RESTORED, "and restores");
    check_eq(spdf_win_tabs_count(back), 2, "with both tabs");
    check(strcmp(spdf_win_tabs_path(back, 0), "C:\\Users\\rapha\xc3\xabl\\a.pdf") == 0,
          "a backslashed non-ASCII Windows path survives verbatim");
    check(strcmp(spdf_win_tabs_title(back, 1), "Custom \"quoted\" title") == 0, "an embedded quote survives escaping");
    view = spdf_win_tabs_view(back, 0);
    check_eq(view->page, 41, "page");
    check_near(view->zoom, 1.75, "zoom");
    check_near(view->custom_zoom, 2.25, "customZoom");
    check_eq(view->fit_mode, SPDF_WIN_TAB_FIT_ACTUAL, "fitMode");
    check_near(view->scroll_x, 12.5, "scrollX");
    check_near(view->scroll_y, -33.25, "scrollY (negative, and still fixed-point)");
    check(view->has_scroll_origin, "hasScrollOrigin");
    check_eq(spdf_win_tabs_selected_index(back), 1, "selectedTab");

    spdf_win_tabs_destroy(back);
    spdf_win_tabs_destroy(tabs);
}

/* A GTK3-era file: 1-based pages, no viewMode, no "windows" wrapper. */
static void test_legacy_single_window_session(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    reset_session_file();
    write_whole(g_session_path, "tabs:\n  - page: 4\n    path: \"/tmp/legacy.pdf\"\n");
    check_eq((int)spdf_win_session_restore(tabs, NULL, NULL, 0), SPDF_WIN_SESSION_RESTORED,
             "a pre-multi-window session still restores");
    check_eq(spdf_win_tabs_count(tabs), 1, "as one tab");
    check_eq(spdf_win_tabs_view_const(tabs, 0)->page, 3, "and its 1-based page is migrated to 0-based");
    spdf_win_tabs_destroy(tabs);
}

/* --- 2. restoring opens nothing ------------------------------------------- */

typedef struct fake_docs {
    int opens;
    char last_path[SPDF_WIN_PATH_MAX];
} fake_docs;

static void* fake_open(void* user, const char* path, char* err, size_t err_len) {
    fake_docs* docs = (fake_docs*)user;
    (void)err, (void)err_len;
    docs->opens++;
    snprintf(docs->last_path, sizeof(docs->last_path), "%s", path ? path : "");
    return docs;
}

static void test_restore_opens_no_documents(void) {
    spdf_win_tabs* seed = spdf_win_tabs_create();
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    fake_docs docs;
    char name[64];
    int i;

    memset(&docs, 0, sizeof(docs));
    reset_session_file();
    for (i = 0; i < 10; ++i) {
        snprintf(name, sizeof(name), "C:\\docs\\file-%d.pdf", i);
        spdf_win_tabs_append(seed, name, NULL);
    }
    spdf_win_tabs_select_deferred(seed, 7);
    check(spdf_win_session_save(seed, "win-lazy") == 1, "a ten-tab session saves");

    spdf_win_tabs_set_document_hooks(tabs, fake_open, NULL, &docs);
    check_eq((int)spdf_win_session_restore(tabs, "win-lazy", NULL, 0), SPDF_WIN_SESSION_RESTORED, "and restores");
    check_eq(spdf_win_tabs_count(tabs), 10, "all ten tabs");
    check_eq(spdf_win_tabs_selected_index(tabs), 7, "with the persisted selection");

    /* THE ASSERTION. Ten restored tabs, zero documents opened: the difference
     * between a 200 ms launch and a several-second one. */
    check_eq(docs.opens, 0, "restoring ten tabs opened no documents at all");
    check_eq((int)spdf_win_tabs_materialize_count(tabs), 0, "not even an attempt");
    for (i = 0; i < 10; ++i) check(!spdf_win_tabs_is_materialized(tabs, i), "no restored tab holds a document");

    spdf_win_tabs_select(tabs, 7);
    check_eq(docs.opens, 1, "selecting the restored tab opens exactly one document");
    check(strcmp(docs.last_path, "C:\\docs\\file-7.pdf") == 0, "and it is the selected tab's");
    spdf_win_tabs_select(tabs, 2);
    check_eq(docs.opens, 2, "selecting a second opens exactly one more");
    for (i = 0; i < 10; ++i)
        if (i != 2 && i != 7) check(!spdf_win_tabs_is_materialized(tabs, i), "the other eight are still promises");

    spdf_win_tabs_destroy(tabs);
    spdf_win_tabs_destroy(seed);
}

/* --- 3. corrupt degrades, unreadable is untouchable ----------------------- */

static void test_corrupt_session_degrades_safely(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    char* after;

    reset_session_file();
    write_whole(g_session_path, "windows: [ this is not\n\tthe supported subset ]]]\n");
    check_eq((int)spdf_win_session_restore(tabs, NULL, NULL, 0), SPDF_WIN_SESSION_ABSENT,
             "a corrupt session reads as absent, not as an error the user sees");
    check_eq(spdf_win_tabs_count(tabs), 0, "and leaves the model empty rather than half-filled");

    /* The inherited policy: corrupt CONTENT is deterministic, and a rewrite is
     * the documented recovery. It must not be widened into "never write". */
    spdf_win_tabs_append(tabs, "C:\\docs\\recovered.pdf", NULL);
    check(spdf_win_session_save(tabs, "win-corrupt") == 1, "and the next save recovers the file");
    after = read_whole(g_session_path);
    check(after != NULL && strstr(after, "recovered.pdf") != NULL, "with the user's current tabs in it");
    free(after);
    spdf_win_tabs_destroy(tabs);
}

static void test_unreadable_session_is_never_destroyed(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    unreadable_guard guard;
    char* before;
    char* after;

    reset_session_file();
    if (!write_whole(g_session_path, kMacSessionYaml)) {
        check(0, "seed the session to be protected");
        spdf_win_tabs_destroy(tabs);
        return;
    }
    before = read_whole(g_session_path);
    if (!make_unreadable(g_session_path, &guard)) {
        note("SKIPPED: this environment would not deny a read (root? exotic filesystem?)");
        free(before);
        spdf_win_tabs_destroy(tabs);
        return;
    }

    check_eq((int)spdf_win_session_restore(tabs, NULL, NULL, 0), SPDF_WIN_SESSION_UNREADABLE,
             "an unreadable session reports UNREADABLE, not ABSENT");
    check_eq(spdf_win_tabs_count(tabs), 0, "and the model is left alone");

    /* THE ASSERTION. Reported as absent, this save would replace the reader's
     * two open documents with one — silently, permanently. */
    spdf_win_tabs_append(tabs, "C:\\docs\\whatever.pdf", NULL);
    check_eq(spdf_win_session_save(tabs, "win-mac-1"), 0, "a save refuses to run over a session it cannot read");

    make_readable(g_session_path, &guard);
    after = read_whole(g_session_path);
    check(after != NULL && before != NULL && strcmp(after, before) == 0,
          "the session file is byte-for-byte what it was");
    check(after != NULL && strstr(after, "financi\xc3\xa8r.pdf") != NULL, "the reader's documents are still listed");
    free(before);
    free(after);
    spdf_win_tabs_destroy(tabs);
}

/* --- 4. saving preserves what it does not understand ---------------------- */

static void test_save_preserves_other_windows_and_unknown_keys(void) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    char* after;

    reset_session_file();
    if (!write_whole(g_session_path, kMacSessionYaml)) {
        check(0, "seed the mac session");
        spdf_win_tabs_destroy(tabs);
        return;
    }
    check_eq((int)spdf_win_session_restore(tabs, "win-mac-1", NULL, 0), SPDF_WIN_SESSION_RESTORED, "restore ours");
    spdf_win_tabs_view(tabs, 0)->page = 30;
    check(spdf_win_session_save(tabs, "win-mac-1") == 1, "save ours back");

    after = read_whole(g_session_path);
    check(after != NULL, "the file is still there");
    check(after && strstr(after, "page: 30") != NULL, "our own change landed");
    /* Keys this port has no feature for, carried through rather than dropped. */
    check(after && strstr(after, "searchText: \"budget\"") != NULL, "a tab's find state survived a Windows save");
    check(after && strstr(after, "showSidebar: false") != NULL, "so did its sidebar preference");
    check(after && strstr(after, "viewMode: 2") != NULL, "and its view mode was not reset to the default");
    check(after && strstr(after, "width: 1120") != NULL, "the window frame survived too");
    free(after);

    /* Now a SECOND window, as another ShenzhenPDF process would leave it. Ours
     * is rewritten; theirs must come through untouched. */
    check(spdf_win_session_save(tabs, "win-other") == 1, "a second window writes itself into the same file");
    after = read_whole(g_session_path);
    check(after && strstr(after, "\"win-mac-1\"") != NULL && strstr(after, "\"win-other\"") != NULL,
          "both windows are in the file");
    check(after && strstr(after, "searchText: \"budget\"") != NULL,
          "and the other window's tab state was not disturbed");
    free(after);

    /* A window whose last tab closed is REMOVED, not left as an empty husk. */
    while (spdf_win_tabs_count(tabs) > 0) spdf_win_tabs_close(tabs, 0, 0);
    check(spdf_win_session_save(tabs, "win-other") == 1, "an empty window saves");
    after = read_whole(g_session_path);
    check(after && strstr(after, "\"win-other\"") == NULL, "and is gone from the file");
    check(after && strstr(after, "\"win-mac-1\"") != NULL, "while the other window is still there");
    free(after);
    spdf_win_tabs_destroy(tabs);
}

/* --- 5. two windows saving at once ---------------------------------------- */

/* ShenzhenPDF runs ONE PROCESS PER WINDOW and every save is a read-modify-write
 * over one shared file, so without session.lock the two processes race and the
 * loser's window simply disappears. spdf_win_session_save() holds the lock
 * across read, merge and write; this is what that buys.
 *
 * Threads rather than processes because the assertion has to hold in the guest,
 * where there is no fork(). Both LockFileEx (Windows) and flock() (POSIX)
 * conflict between two separate opens of the same file even within one process,
 * so the exclusion under test is the real one.
 *
 * The per-round check is the sharp one: after MY save, MY window must still be
 * in the file. An unlocked merge by the other writer drops it, because that
 * writer read the file before my write and wrote its copy after. */
typedef struct writer {
    const char* window_id;
    const char* path;
    const char* dir;
    int rounds;
    int lost_updates;
    int refused_saves;
} writer;

static volatile int g_inside_lock = 0;
static volatile int g_lock_overlaps = 0;

static void writer_body(void* argument) {
    writer* w = (writer*)argument;
    int round;
    for (round = 0; round < w->rounds; ++round) {
        spdf_win_tabs* mine = spdf_win_tabs_create();
        spdf_win_tabs* back = spdf_win_tabs_create();
        /* Directly: is the lock the save path uses actually exclusive? */
        spdf_win_state_session_lock* lock = spdf_win_state_session_lock_acquire(w->dir);
        if (++g_inside_lock != 1) g_lock_overlaps++;
        --g_inside_lock;
        spdf_win_state_session_lock_release(lock);

        spdf_win_tabs_append(mine, w->path, NULL);
        spdf_win_tabs_view(mine, 0)->page = round;
        if (!spdf_win_session_save(mine, w->window_id)) w->refused_saves++;
        if (spdf_win_session_restore(back, w->window_id, NULL, 0) != SPDF_WIN_SESSION_RESTORED ||
            spdf_win_tabs_count(back) != 1)
            w->lost_updates++;
        spdf_win_tabs_destroy(back);
        spdf_win_tabs_destroy(mine);
    }
}

#if defined(_WIN32)
static DWORD WINAPI thread_entry(LPVOID a) { writer_body(a); return 0; }
static void run_both(writer* a, writer* b) {
    HANDLE t[2];
    t[0] = CreateThread(NULL, 0, thread_entry, a, 0, NULL);
    t[1] = CreateThread(NULL, 0, thread_entry, b, 0, NULL);
    if (!t[0] || !t[1]) {
        check(0, "could not start the two writer threads");
        return;
    }
    WaitForMultipleObjects(2, t, TRUE, INFINITE);
    CloseHandle(t[0]);
    CloseHandle(t[1]);
}
#else
#include <pthread.h>
static void* thread_entry(void* a) { writer_body(a); return NULL; }
static void run_both(writer* a, writer* b) {
    pthread_t t[2];
    if (pthread_create(&t[0], NULL, thread_entry, a) || pthread_create(&t[1], NULL, thread_entry, b)) {
        check(0, "could not start the two writer threads");
        return;
    }
    pthread_join(t[0], NULL);
    pthread_join(t[1], NULL);
}
#endif

static void test_concurrent_writers_serialise(const char* dir) {
    writer first, second;
    spdf_win_tabs* a = spdf_win_tabs_create();
    spdf_win_tabs* b = spdf_win_tabs_create();

    reset_session_file();
    memset(&first, 0, sizeof(first));
    memset(&second, 0, sizeof(second));
    first.window_id = "win-A";
    first.path = "C:\\docs\\alpha.pdf";
    second.window_id = "win-B";
    second.path = "C:\\docs\\beta.pdf";
    first.dir = second.dir = dir;
    first.rounds = second.rounds = 40;
    run_both(&first, &second);

    check_eq(g_lock_overlaps, 0, "the session lock was never held by two writers at once");
    check_eq(first.refused_saves + second.refused_saves, 0, "no save was refused during the run");
    check_eq(first.lost_updates + second.lost_updates, 0, "no writer found its own window missing after saving it");
    check_eq((int)spdf_win_session_restore(a, "win-A", NULL, 0), SPDF_WIN_SESSION_RESTORED,
             "window A survived 80 interleaved merges");
    check_eq((int)spdf_win_session_restore(b, "win-B", NULL, 0), SPDF_WIN_SESSION_RESTORED, "and so did window B");
    check(strcmp(spdf_win_tabs_path(a, 0), first.path) == 0, "with A's own document");
    check(strcmp(spdf_win_tabs_path(b, 0), second.path) == 0, "and B's");
    spdf_win_tabs_destroy(b);
    spdf_win_tabs_destroy(a);
}

/* --- drive ---------------------------------------------------------------- */

int main(int argc, char** argv) {
    char dir[SPDF_WIN_PATH_MAX];

    printf("spdf_win_session tests\n");
    if (!spdf_test_state_dir(argc, argv, "spdf_session_test", SPDF_TEST_SCRATCH_STEM, dir, sizeof(dir))) {
        printf("FAIL: could not create the scratch directory\n");
        return 1;
    }
    spdf_win_paths_set_state_dir_override(dir);
    if (!spdf_win_paths_state_file(SPDF_WIN_STATE_SESSION, g_session_path, sizeof(g_session_path))) return 1;

    test_reads_a_mac_written_session();
    test_round_trips_through_the_shared_codec();
    test_legacy_single_window_session();
    test_restore_opens_no_documents();
    test_corrupt_session_degrades_safely();
    test_unreadable_session_is_never_destroyed();
    test_save_preserves_other_windows_and_unknown_keys();
    test_concurrent_writers_serialise(dir);

    reset_session_file();
    spdf_win_paths_set_state_dir_override(NULL);
    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
