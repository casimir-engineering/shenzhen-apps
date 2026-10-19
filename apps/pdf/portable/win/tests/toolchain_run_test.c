/* toolchain_run_test.c -- pins the subprocess seam of spdf_win_toolchain.h
 * (spdf_win_toolchain_process.cpp) against a fake tesseract.cmd this test
 * writes into %TEMP%: exit code, streamed lines, separate stderr, stdin, a
 * cancel that must kill a sleeping child, a spawn failure, and the
 * --list-langs probe through the fake. NO real tool is run. Split from
 * toolchain_test.c at the 500-line cap; the pure half stays there.
 */
/* spdf-test-sources: portable/win/src/spdf_win_toolchain.cpp portable/win/src/spdf_win_toolchain_cmd.cpp portable/win/src/spdf_win_toolchain_plan.cpp portable/win/src/spdf_win_toolchain_run.cpp portable/win/src/spdf_win_toolchain_process.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
#include "spdf_win_toolchain.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

static void fail(const char* what, const char* file, int line) {
    fprintf(stderr, "FAIL %s (%s:%d)\n", what, file, line);
    ++g_failures;
}

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) fail(#cond, __FILE__, __LINE__);                                                                   \
    } while (0)

#define CHECK_STR(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (strcmp((a), (b)) != 0) {                                                                                   \
            fprintf(stderr, "FAIL %s == \"%s\" (got \"%s\") (%s:%d)\n", #a, (b), (a), __FILE__, __LINE__);            \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static char g_lines[32][256];
static int g_line_count;
static void collect_line(const char* line, void* user) {
    (void)user;
    if (g_line_count < 32) snprintf(g_lines[g_line_count], 256, "%s", line);
    ++g_line_count;
}

static void write_fake(const char* path, const char* body) {
    FILE* f = fopen(path, "wb");
    if (f) {
        fputs(body, f);
        fclose(f);
    }
}

static DWORD WINAPI cancel_after(LPVOID ev) {
    Sleep(300);
    SetEvent((HANDLE)ev);
    return 0;
}

static void test_run_capture(void) {
    char tmp[MAX_PATH], fake[MAX_PATH], sleeper[MAX_PATH], echo[MAX_PATH], cmd[SPDF_WIN_TC_CMD];
    char* out = NULL;
    char* err = NULL;
    SpdfWinToolchainRun run;
    int rc;
    if (!GetTempPathA(MAX_PATH, tmp)) return;
    snprintf(fake, sizeof(fake), "%sspdf-fake-tesseract.cmd", tmp);
    snprintf(sleeper, sizeof(sleeper), "%sspdf-fake-sleeper.cmd", tmp);
    snprintf(echo, sizeof(echo), "%sspdf-fake-echo.cmd", tmp);
    /* No parentheses inside the block: cmd would read ")" in "(2):" as the
     * block's end. The real tesseract prints "List of available languages (2):"
     * outside any block, so the parser above is exercised on that string
     * separately in test_languages. */
    write_fake(fake, "@echo off\r\nif \"%1\"==\"--list-langs\" (\r\necho List of available languages: 2\r\necho eng\r\n"
                     "echo osd\r\necho warning line 1>&2\r\nexit /b 0\r\n)\r\necho unknown 1>&2\r\nexit /b 3\r\n");
    write_fake(sleeper, "@echo off\r\necho started\r\nping -n 30 127.0.0.1 >nul\r\necho never\r\n");
    write_fake(echo, "@echo off\r\nmore\r\n");

    /* Exit code, separate streams, streamed lines. */
    {
        const char* argv[2] = {fake, "--list-langs"};
        spdf_win_toolchain_join_argv(argv, 2, cmd, sizeof(cmd));
    }
    g_line_count = 0;
    memset(&run, 0, sizeof(run));
    run.command_line = cmd;
    run.on_line = collect_line;
    run.stdout_out = &out;
    run.stderr_out = &err;
    rc = spdf_win_toolchain_run_capture(&run);
    CHECK(rc == 0);
    CHECK(out && strstr(out, "eng") && strstr(out, "osd"));
    CHECK(err && strstr(err, "warning line"));
    CHECK(out && !strstr(out, "warning line"));
    CHECK(g_line_count >= 3);
    CHECK(spdf_win_toolchain_list_output_has_language(out, "eng"));
    CHECK(!spdf_win_toolchain_list_output_has_language(out, "chi_sim"));
    free(out);
    free(err);
    out = err = NULL;

    /* Non-zero exit and merged stderr. */
    {
        const char* argv[2] = {fake, "--bogus"};
        spdf_win_toolchain_join_argv(argv, 2, cmd, sizeof(cmd));
    }
    memset(&run, 0, sizeof(run));
    run.command_line = cmd;
    run.merge_stderr = 1;
    run.stdout_out = &out;
    rc = spdf_win_toolchain_run_capture(&run);
    CHECK(rc == 3);
    CHECK(out && strstr(out, "unknown"));
    free(out);
    out = NULL;

    /* stdin reaches the child (Argos reads its text from stdin). */
    spdf_win_toolchain_quote_arg(echo, cmd, sizeof(cmd));
    memset(&run, 0, sizeof(run));
    run.command_line = cmd;
    run.stdin_text = "hello from stdin\r\n";
    run.stdout_out = &out;
    rc = spdf_win_toolchain_run_capture(&run);
    CHECK(rc == 0);
    CHECK(out && strstr(out, "hello from stdin"));
    free(out);
    out = NULL;

    /* Cancel kills a sleeping child promptly. */
    {
        HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
        HANDLE t = CreateThread(NULL, 0, cancel_after, ev, 0, NULL);
        DWORD t0 = GetTickCount();
        spdf_win_toolchain_quote_arg(sleeper, cmd, sizeof(cmd));
        memset(&run, 0, sizeof(run));
        run.command_line = cmd;
        run.cancel = ev;
        run.merge_stderr = 1;
        run.stdout_out = &out;
        rc = spdf_win_toolchain_run_capture(&run);
        CHECK(rc == SPDF_WIN_TC_CANCELLED);
        CHECK(GetTickCount() - t0 < 10000);
        CHECK(out && strstr(out, "started") && !strstr(out, "never"));
        free(out);
        WaitForSingleObject(t, 2000);
        CloseHandle(t);
        CloseHandle(ev);
    }

    /* A program that does not exist is a spawn failure, not a crash. */
    memset(&run, 0, sizeof(run));
    run.command_line = "C:\\definitely\\not\\here\\tool.exe --version";
    rc = spdf_win_toolchain_run_capture(&run);
    CHECK(rc == SPDF_WIN_TC_SPAWN_FAILED);
    CHECK(run.error[0] != '\0');

    /* missing_components through the fake: eng listed, chi_sim not. */
    {
        char missing[8][32];
        int n = spdf_win_toolchain_missing_components(fake, "", "chi_sim+eng", missing);
        CHECK(n == 1);
        CHECK_STR(missing[0], "chi_sim");
        n = spdf_win_toolchain_missing_components("", "", "eng", missing);
        CHECK(n == 1);
    }
    CHECK(spdf_win_toolchain_cpu_count() >= 1);

    /* TESSDATA_PREFIX completion: a fake tesseract tree ships eng and osd, our
     * directory holds a downloaded chi_sim; completing copies eng and osd in
     * and names our directory. With nothing downloaded it stays out of it. */
    {
        SpdfWinToolchainRoots r;
        char tessexe[MAX_PATH], parent[SPDF_WIN_TC_PATH], f[SPDF_WIN_TC_PATH];
        memset(&r, 0, sizeof(r));
        snprintf(r.user_profile, sizeof(r.user_profile), "%sspdf-tc-local", tmp);
        snprintf(tessexe, sizeof(tessexe), "%sspdf-tc-tess\\tesseract.exe", tmp);
        snprintf(f, sizeof(f), "%sspdf-tc-tess", tmp);
        CreateDirectoryA(f, NULL);
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata", tmp);
        CreateDirectoryA(f, NULL);
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\eng.traineddata", tmp);
        write_fake(f, "eng");
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\osd.traineddata", tmp);
        write_fake(f, "osd");
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\configs", tmp);
        CreateDirectoryA(f, NULL);
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\configs\\hocr", tmp);
        write_fake(f, "tessedit_create_hocr 1");
        CHECK(!spdf_win_toolchain_tessdata_complete(&r, tessexe, "chi_sim+eng", parent, sizeof(parent)));
        snprintf(f, sizeof(f), "%sspdf-tc-local", tmp);
        CreateDirectoryA(f, NULL);
        snprintf(f, sizeof(f), "%sspdf-tc-local\\.shenzhenpdf", tmp);
        CreateDirectoryA(f, NULL);
        snprintf(f, sizeof(f), "%sspdf-tc-local\\.shenzhenpdf\\tesseract", tmp);
        CreateDirectoryA(f, NULL);
        snprintf(f, sizeof(f), "%sspdf-tc-local\\.shenzhenpdf\\tesseract\\tessdata", tmp);
        CreateDirectoryA(f, NULL);
        snprintf(f, sizeof(f), "%sspdf-tc-local\\.shenzhenpdf\\tesseract\\tessdata\\chi_sim.traineddata", tmp);
        write_fake(f, "chi");
        CHECK(spdf_win_toolchain_tessdata_complete(&r, tessexe, "chi_sim+eng", parent, sizeof(parent)));
        CHECK(strstr(parent, "spdf-tc-local\\.shenzhenpdf\\tesseract") != NULL);
        snprintf(f, sizeof(f), "%s\\tessdata\\eng.traineddata", parent);
        CHECK(GetFileAttributesA(f) != INVALID_FILE_ATTRIBUTES);
        DeleteFileA(f);
        snprintf(f, sizeof(f), "%s\\tessdata\\osd.traineddata", parent);
        CHECK(GetFileAttributesA(f) != INVALID_FILE_ATTRIBUTES);
        DeleteFileA(f);
        snprintf(f, sizeof(f), "%s\\tessdata\\configs\\hocr", parent); /* the output-format configs came too */
        CHECK(GetFileAttributesA(f) != INVALID_FILE_ATTRIBUTES);
        DeleteFileA(f);
        snprintf(f, sizeof(f), "%s\\tessdata\\configs", parent);
        RemoveDirectoryA(f);
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\configs\\hocr", tmp);
        DeleteFileA(f);
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\configs", tmp);
        RemoveDirectoryA(f);
        snprintf(f, sizeof(f), "%s\\tessdata\\chi_sim.traineddata", parent);
        DeleteFileA(f);
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\eng.traineddata", tmp);
        DeleteFileA(f);
        snprintf(f, sizeof(f), "%sspdf-tc-tess\\tessdata\\osd.traineddata", tmp);
        DeleteFileA(f);
    }
    DeleteFileA(fake);
    DeleteFileA(sleeper);
    DeleteFileA(echo);
}


int main(void) {
    test_run_capture();
    printf("toolchain_run_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
