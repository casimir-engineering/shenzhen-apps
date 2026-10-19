/* session_readonly_test.c — the read-only binding round-trips through
 * session.yaml: readOnly, workingPath, roCopyFileSize, roCopyModifiedAt.
 *
 * WHAT IT IS FOR. spdf_win_watcher.h renders a read-only source from a private
 * shadow copy and needs, on the next launch, the stat the copy reflects, so an
 * unchanged source reopens the copy without a content read. The four keys are
 * the ones the mac writes; this pins that a Windows save writes them for a
 * read-only tab and ONLY for one, that the mtime keeps its 100 ns resolution
 * (a rounded value would never compare equal to a fresh stat, and every
 * relaunch would recopy), that `missing` -- runtime state -- is never written,
 * and that a restore reads all four back. Split from session_test.c, which is
 * at the 500-line cap.
 */
/* spdf-test-sources: portable/win/src/spdf_win_session.cpp portable/win/src/spdf_win_tabs.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
/* spdf-test-args: %SCRATCH% */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include "spdf_win_paths.h"
#include "spdf_win_session.h"
#include "spdf_win_state.h"

#include <direct.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
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

static int count_of(const char* haystack, const char* needle) {
    int n = 0;
    const char* p = haystack;
    size_t len = strlen(needle);
    if (!haystack) return 0;
    while ((p = strstr(p, needle)) != NULL) {
        ++n;
        p += len;
    }
    return n;
}

int main(int argc, char** argv) {
    const char* scratch = argc > 1 ? argv[1] : ".";
    char dir[1024];
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    spdf_win_tabs* back = spdf_win_tabs_create();
    spdf_win_tab_view* view;
    char* json;

    snprintf(dir, sizeof(dir), "%s/session-readonly", scratch);
    (void)_mkdir(dir);
    spdf_win_paths_set_state_dir_override(dir);
    /* A known starting point, whatever the last run left. */
    spdf_win_state_write_json(SPDF_WIN_STATE_SESSION, "{\"version\":2,\"windows\":[]}");

    /* Tab 0: a read-only source rendered from a copy. Tab 1: a plain file the
     * watcher has reported missing -- runtime state, never persisted. */
    CHECK(spdf_win_tabs_append(tabs, "C:/Share/locked.pdf", NULL) == 0);
    CHECK(spdf_win_tabs_append(tabs, "C:/Docs/plain.pdf", NULL) == 1);
    view = spdf_win_tabs_view(tabs, 0);
    view->read_only = 1;
    strcpy(view->working_path, "C:/State/ReadOnlyCopies/ro-abc123.pdf");
    view->ro_copy_file_size = 123456789ULL;
    view->ro_copy_modified_at = 1725000000.5;
    view = spdf_win_tabs_view(tabs, 1);
    view->missing = 1;
    spdf_win_tabs_select_deferred(tabs, 0);

    CHECK(spdf_win_session_save(tabs, "win-ro") == 1);
    json = spdf_win_state_read_json(SPDF_WIN_STATE_SESSION);
    CHECK(json != NULL);
    if (json) {
        CHECK(count_of(json, "\"readOnly\":true") == 1); /* the read-only tab, and only it */
        CHECK(count_of(json, "\"readOnly\"") == 1);
        CHECK(strstr(json, "\"workingPath\":\"C:/State/ReadOnlyCopies/ro-abc123.pdf\"") != NULL);
        CHECK(strstr(json, "\"roCopyFileSize\":123456789") != NULL);
        CHECK(strstr(json, "\"roCopyModifiedAt\":1725000000.5000000") != NULL); /* 7 decimals: 100 ns */
        CHECK(strstr(json, "missing") == NULL);
        free(json);
    }

    CHECK(spdf_win_session_restore(back, "win-ro", NULL, 0) == SPDF_WIN_SESSION_RESTORED);
    CHECK(spdf_win_tabs_count(back) == 2);
    view = spdf_win_tabs_view(back, 0);
    CHECK(view && view->read_only == 1);
    CHECK(view && strcmp(view->working_path, "C:/State/ReadOnlyCopies/ro-abc123.pdf") == 0);
    CHECK(view && view->ro_copy_file_size == 123456789ULL);
    CHECK(view && fabs(view->ro_copy_modified_at - 1725000000.5) < 1e-6);
    CHECK(view && view->missing == 0);
    view = spdf_win_tabs_view(back, 1);
    CHECK(view && view->read_only == 0);
    CHECK(view && view->working_path[0] == 0);
    CHECK(view && view->ro_copy_file_size == 0);
    CHECK(view && view->missing == 0); /* a restored tab is presumed present until the watcher says otherwise */
    /* Nothing was opened to learn any of this: the lazy-restore promise holds
     * for read-only tabs too. */
    CHECK(spdf_win_tabs_materialize_count(back) == 0);

    spdf_win_tabs_destroy(back);
    spdf_win_tabs_destroy(tabs);
    spdf_win_paths_set_state_dir_override(NULL);
    printf("session_readonly_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
