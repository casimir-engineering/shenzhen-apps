/* spdf_win_toolchain_install.cpp -- running one install-plan step with a live
 * log. Every step is a single streamed command: winget for Tesseract and
 * Python, pip --user for the Python packages, argospm for a language package,
 * curl for a tessdata_fast file. Nothing here elevates: winget performs its
 * own consent prompt for a machine-wide installer (Tesseract's), and the log
 * says so before it appears.
 *
 * Ghostscript is deliberately NOT a step. The first real run on this machine
 * showed two things: Artifex's NSIS installer has no silent mode (its
 * documentation lists /NCRC and /D= as the only honoured switches, and /S
 * opened the wizard anyway, behind a UAC prompt), and OCRmyPDF 17 no longer
 * needs it -- it rasterises with pypdfium2 and uses gs only to produce PDF/A,
 * falling back to a plain PDF ("Auto mode: could not produce PDF/A, outputting
 * regular PDF"), which is the output this port wants anyway. So gs is detected
 * and put on the child's PATH when present, and never installed. */
#include "spdf_win_toolchain.h"

#include <windows.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void say(spdf_win_toolchain_line_fn cb, void* user, const char* fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (cb) cb(line, user);
}

static int run_streamed(const char* cmd, void* cancel, spdf_win_toolchain_line_fn cb, void* user) {
    SpdfWinToolchainRun run;
    int rc;
    memset(&run, 0, sizeof(run));
    run.command_line = cmd;
    run.cancel = cancel;
    run.merge_stderr = 1;
    run.on_line = cb;
    run.user = user;
    say(cb, user, "> %s", cmd);
    rc = spdf_win_toolchain_run_capture(&run);
    if (rc == SPDF_WIN_TC_SPAWN_FAILED) say(cb, user, "Could not start: %s", run.error);
    else if (rc == SPDF_WIN_TC_CANCELLED) say(cb, user, "Cancelled.");
    else if (rc != 0) say(cb, user, "Exited with code %d.", rc);
    return rc;
}

static int ensure_dir_utf8(const char* dir) {
    wchar_t w[SPDF_WIN_TC_PATH];
    wchar_t* p;
    if (!MultiByteToWideChar(CP_UTF8, 0, dir, -1, w, SPDF_WIN_TC_PATH)) return 0;
    /* mkdir -p, one component at a time. */
    for (p = w + 3; *p; ++p) {
        if (*p == L'\\' || *p == L'/') {
            *p = 0;
            CreateDirectoryW(w, NULL);
            *p = L'\\';
        }
    }
    CreateDirectoryW(w, NULL);
    return GetFileAttributesW(w) != INVALID_FILE_ATTRIBUTES;
}

int spdf_win_toolchain_run_step(const SpdfWinToolchainStep* step, const SpdfWinToolchainRoots* roots, void* cancel,
                                spdf_win_toolchain_line_fn on_line, void* user) {
    (void)roots;
    if (!step) return 0;
    say(on_line, user, "");
    say(on_line, user, "== %s", step->label);
    switch (step->kind) {
        case SPDF_WIN_TC_STEP_BLOCKED: say(on_line, user, "Cannot continue automatically."); return 0;
        case SPDF_WIN_TC_STEP_TRAINEDDATA: {
            char dir[SPDF_WIN_TC_PATH];
            if (spdf_win_toolchain_dirname(step->dest, dir, sizeof(dir))) ensure_dir_utf8(dir);
            return run_streamed(step->command, cancel, on_line, user) == 0;
        }
        case SPDF_WIN_TC_STEP_VENV: {
            char dir[SPDF_WIN_TC_PATH];
            if (spdf_win_toolchain_dirname(step->dest, dir, sizeof(dir))) ensure_dir_utf8(dir);
            say(on_line, user, "A private environment at %s keeps the torch stack out of your own site-packages.",
                step->dest);
        }
        /* fallthrough: the same "python" re-resolution as pip */
        case SPDF_WIN_TC_STEP_PIP: {
            /* The plan said "python" when Python was not yet installed; the
             * winget step before this one may have changed that. */
            char cmd[SPDF_WIN_TC_CMD];
            const char* line = step->command;
            if (strncmp(line, "python -m ", 10) == 0) {
                SpdfWinToolchainRoots fresh;
                char python[SPDF_WIN_TC_PATH], q[SPDF_WIN_TC_PATH];
                spdf_win_toolchain_roots_from_env(&fresh);
                if (spdf_win_toolchain_find(SPDF_WIN_TOOL_PYTHON, &fresh, python, sizeof(python))) {
                    spdf_win_toolchain_quote_arg(python, q, sizeof(q));
                    snprintf(cmd, sizeof(cmd), "%s%s", q, line + 6);
                    line = cmd;
                } else {
                    say(on_line, user,
                        "Python is still not installed; pip cannot run. Open a new session after installing Python.");
                    return 0;
                }
            }
            return run_streamed(line, cancel, on_line, user) == 0;
        }
        case SPDF_WIN_TC_STEP_WINGET:
            if (!strstr(step->command, "--scope user"))
                say(on_line, user, "This installer is machine-wide; Windows may show a consent prompt.");
            /* fallthrough */
        case SPDF_WIN_TC_STEP_ARGOSPM:
        default: return run_streamed(step->command, cancel, on_line, user) == 0;
    }
}
