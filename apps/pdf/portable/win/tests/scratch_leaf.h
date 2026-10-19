#pragma once

/* THE SCRATCH STATE DIRECTORY that session_test, state_test and settings_test
 * each need: a real directory under %TEMP%, private to this process, with a
 * non-ASCII leaf.
 *
 * WHY IT IS PRIVATE TO THE PROCESS. %TEMP% is one directory for the whole
 * machine, and several suites run at once here -- one per parallel worktree,
 * each with its own SPDF_OUT but the same %TEMP%. The three tests each built a
 * FIXED leaf under it, so two runs rewrote each other's settings.yaml and
 * session.yaml mid-assertion. That surfaced as failures reading exactly like
 * real regressions ("the session file is byte-for-byte what it was", "a save
 * refuses to run over a session it cannot read") and cost an integration a
 * rollback before the collision was understood. The process id is appended.
 *
 * WHY THE LEAF IS NON-ASCII. Putting every file operation through a path the
 * narrow CRT would mangle is the point of it, not decoration: it is how the
 * port's UTF-8 path boundary gets exercised on every run. So the id is
 * appended to those bytes rather than replacing them, and the bytes live here
 * as C escapes so no call site needs a non-ASCII literal.
 *
 * Header-only, included from tests that link quite different halves of the
 * port, so it leans on nothing but spdf_win_paths.h and the CRT. getenv is
 * fine: build-native.cmd compiles everything with /D_CRT_SECURE_NO_WARNINGS.
 */

#include <stdio.h>
#include <stdlib.h>

#include "../src/spdf_win_paths.h"

#if defined(_WIN32)
/* GetCurrentProcessId, without pulling the rest of windows.h into a test that
 * may not want it. */
__declspec(dllimport) unsigned long __stdcall GetCurrentProcessId(void);
#else
#include <unistd.h>
#endif

/* The proven non-ASCII leaf: "Raphael" with a diaeresis, in UTF-8. */
#define SPDF_TEST_SCRATCH_STEM "Rapha\xc3\xabl"

/* Writes "<stem>-<pid>" into `out`. No allocation: the caller keeps a buffer. */
static void spdf_test_scratch_leaf(char* out, size_t out_len, const char* stem) {
    unsigned long pid;
#if defined(_WIN32)
    pid = GetCurrentProcessId();
#else
    pid = (unsigned long)getpid();
#endif
    snprintf(out, out_len, "%s-%lu", stem, pid);
}

/* Creates <base>/<group>/<leaf_stem>-<pid> and writes it to `out`, where
 * `base` is argv[1] if the runner gave one, else %TEMP% (TMPDIR off Windows),
 * else the working directory. Returns 0 if any step failed, having printed
 * nothing -- the caller says what it was trying to do. Call it twice with
 * different leaf stems for two sibling directories under one group. */
static int spdf_test_state_dir(int argc, char** argv, const char* group, const char* leaf_stem, char* out,
                               size_t out_len) {
    char scratch[SPDF_WIN_PATH_MAX];
    char leaf[64];
    const char* base = argc > 1 ? argv[1] : NULL;

    if (!base || !*base) {
#if defined(_WIN32)
        base = getenv("TEMP");
#else
        base = getenv("TMPDIR");
#endif
    }
    if (!base || !*base) base = ".";
    if (!spdf_win_path_join(base, group, scratch, sizeof(scratch))) return 0;
    spdf_test_scratch_leaf(leaf, sizeof(leaf), leaf_stem);
    if (!spdf_win_path_join(scratch, leaf, out, out_len)) return 0;
    return spdf_win_paths_ensure_dir(out);
}
