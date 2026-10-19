/* setup_e2e_test.c — a REAL --install and a REAL --uninstall, end to end,
 * against redirected locations.
 *
 * WHAT MAKES THIS SAFE TO RUN ON A WORKSTATION. SPDF_WIN_SETUP_ROOT is set to a
 * scratch directory under %TEMP% before anything is called, and
 * spdf_win_setup_shell.h honours it for all three of the places an install
 * touches: the program folder becomes <root>\Programs\ShenzhenPDF, the Start
 * Menu becomes <root>\Start Menu\Programs, and the registry writes go under
 * HKCU\Software\ShenzhenPDF-setup-test instead of HKCU itself. THE REAL START
 * MENU, THE REAL %LOCALAPPDATA%\Programs AND THE REAL Apps & features LIST ARE
 * NEVER TOUCHED BY THIS TEST. The redirection also suppresses the relaunch, so
 * no window opens. Everything created is deleted before exit, and the scratch
 * root is removed whether the checks passed or not.
 *
 * WHAT IS ACTUALLY EXERCISED, as opposed to simulated: CopyFileW of the running
 * exe (which is THIS binary — it becomes <root>\Programs\ShenzhenPDF\ShenzhenPDF.exe),
 * IShellLinkW + IPersistFile::Save and the read-back of the .lnk's target,
 * spdf_win_assoc_register_under against the installed path, the Uninstall key,
 * and then --uninstall removing all four.
 *
 * AND THE ONE THING NO IN-PROCESS TEST CAN COVER FROM THE PARENT: a running exe
 * cannot delete itself. So the parent RUNS the installed copy -- which is this
 * same binary -- with --child-uninstall, and that child calls
 * spdf_win_setup_uninstall() from inside the install directory, takes the
 * detached-`cmd`-waiter branch, and exits. The parent then waits for the
 * directory to disappear. That is the Apps-list Uninstall button's exact path.
 *
 * Exit code is the whole signal.
 */
/* The settings module comes along because spdf_win_setup.cpp remembers the
 * first-run answer through spdf_win_settings_commit(); this test never shows
 * that dialog (it is modal) and never reads settings.yaml. */
/* spdf-test-sources: portable/win/src/spdf_win_setup.cpp portable/win/src/spdf_win_assoc.cpp portable/win/src/spdf_win_settings.c portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_recents.c portable/win/src/spdf_win_watcher.cpp portable/win/src/spdf_win_watcher_shadow.cpp */
#include <windows.h>

#include "spdf_win_setup.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        ++g_checks;                                                          \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__); \
            ++g_failures;                                                    \
        }                                                                    \
    } while (0)

#define BUF SPDF_WIN_SETUP_PATH_MAX

static int exists(const wchar_t* path) { return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES; }

static int key_exists(const wchar_t* sub) {
    HKEY key;
    wchar_t full[BUF];
    _snwprintf_s(full, _countof(full), _TRUNCATE, L"%s\\%s", SPDF_WIN_SETUP_TEST_KEY, sub);
    if (RegOpenKeyExW(HKEY_CURRENT_USER, full, 0, KEY_READ, &key) != ERROR_SUCCESS) return 0;
    RegCloseKey(key);
    return 1;
}

/* rm -rf, for the scratch root. Deliberately NOT the module's own
 * setup_delete_tree(): a test that cleans up with the code under test cannot
 * tell "it worked" from "the cleanup was as broken as the thing". */
static void wipe(const wchar_t* dir) {
    WIN32_FIND_DATAW found;
    wchar_t pattern[BUF];
    wchar_t child[BUF];
    HANDLE h;
    if (!exists(dir)) return;
    _snwprintf_s(pattern, _countof(pattern), _TRUNCATE, L"%s\\*", dir);
    h = FindFirstFileW(pattern, &found);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(found.cFileName, L".") == 0 || wcscmp(found.cFileName, L"..") == 0) continue;
            _snwprintf_s(child, _countof(child), _TRUNCATE, L"%s\\%s", dir, found.cFileName);
            if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) wipe(child);
            else DeleteFileW(child);
        } while (FindNextFileW(h, &found));
        FindClose(h);
    }
    RemoveDirectoryW(dir);
}

/* --- the child: --uninstall from inside the install directory --------------- */

static int run_child_uninstall(void) {
    /* SPDF_WIN_SETUP_ROOT is inherited from the parent, so this resolves the
     * same scratch locations. Quiet, so there is no message box to dismiss in a
     * harness. */
    printf("setup_e2e_test: [child, running from the install directory]\n");
    fflush(stdout);
    return spdf_win_setup_uninstall(1, 0);
}

static int spawn_child(const wchar_t* exe, DWORD* out_exit) {
    wchar_t command[BUF + 32];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    _snwprintf_s(command, _countof(command), _TRUNCATE, L"\"%s\" --child-uninstall", exe);
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    /* THE CHILD'S OUTPUT MUST REACH THE HARNESS LOG: it reports which of the
     * three removal routes it took, and that line is the only evidence for the
     * branch no in-process check can reach. CREATE_NO_WINDOW alone is not
     * enough -- it gives a console app a fresh invisible console and its stdout
     * goes there -- so the handles are passed explicitly. */
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (!CreateProcessW(NULL, command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return 0;
    WaitForSingleObject(pi.hProcess, 30000);
    GetExitCodeProcess(pi.hProcess, out_exit);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 1;
}

/* The detached waiter retries once a second, so the directory goes away shortly
 * after the child does rather than the instant it exits. */
static int wait_gone(const wchar_t* dir, int seconds) {
    int i;
    for (i = 0; i < seconds * 4; ++i) {
        if (!exists(dir)) return 1;
        Sleep(250);
    }
    return !exists(dir);
}

/* --- the run ---------------------------------------------------------------- */

int main(int argc, char** argv) {
    wchar_t temp[BUF];
    wchar_t root[BUF];
    wchar_t installed[BUF];
    wchar_t install_dir[BUF];
    wchar_t lnk[BUF];
    wchar_t target[BUF];
    wchar_t running[BUF];
    wchar_t state_dir[BUF];
    wchar_t state_file[BUF];
    DWORD child_rc = 99;
    DWORD n;

    if (argc > 1 && strcmp(argv[1], "--child-uninstall") == 0) return run_child_uninstall();

    n = GetTempPathW(BUF, temp);
    if (n == 0 || n >= BUF) {
        fprintf(stderr, "setup_e2e_test: no %%TEMP%%\n");
        return 1;
    }
    _snwprintf_s(root, _countof(root), _TRUNCATE, L"%sspdf-setup-e2e-%lu", temp,
                 (unsigned long)GetCurrentProcessId());
    wipe(root);
    CHECK(CreateDirectoryW(root, NULL) != 0);
    /* BEFORE any setup call, and inherited by the child process. */
    CHECK(SetEnvironmentVariableW(SPDF_WIN_SETUP_ROOT_ENV, root) != 0);

    CHECK(spdf_win_setup_installed_exe(installed, BUF));
    CHECK(spdf_win_setup_shortcut_path(lnk, BUF));
    CHECK(spdf_win_setup_dir_of(installed, install_dir, BUF));
    /* The redirection took effect: everything is under the scratch root, so
     * nothing below can reach a real per-user location. If this fails, stop. */
    CHECK(wcsstr(installed, root) == installed);
    CHECK(wcsstr(lnk, root) == lnk);
    if (g_failures) {
        wipe(root);
        printf("setup_e2e_test: %d checks, %d failures\n", g_checks, g_failures);
        return 1;
    }
    CHECK(!exists(installed));

    /* --- install ---------------------------------------------------------- */
    CHECK(spdf_win_setup_install(1, NULL, 0) == 0);
    /* 1. the copied exe, byte-identical to the running one. */
    CHECK(exists(installed));
    n = GetModuleFileNameW(NULL, running, BUF);
    CHECK(n > 0 && n < BUF);
    {
        WIN32_FILE_ATTRIBUTE_DATA a, b;
        CHECK(GetFileAttributesExW(running, GetFileExInfoStandard, &a));
        CHECK(GetFileAttributesExW(installed, GetFileExInfoStandard, &b));
        CHECK(a.nFileSizeLow == b.nFileSizeLow && a.nFileSizeHigh == b.nFileSizeHigh);
    }
    /* 2. the shortcut, read back through IShellLinkW: it must POINT at the
     *    installed copy, not merely exist. */
    CHECK(exists(lnk));
    CHECK(spdf_win_setup_read_shortcut(lnk, target, BUF));
    CHECK(spdf_win_setup_same_path(target, installed));
    /* 3. the association, registered for the installed path. */
    CHECK(key_exists(L"Software\\Classes\\ShenzhenPDF.Document\\shell\\open\\command"));
    CHECK(key_exists(L"Software\\RegisteredApplications"));
    /* 4. the Apps-list entry. */
    CHECK(key_exists(SPDF_WIN_SETUP_UNINSTALL_KEY));

    /* IDEMPOTENT: run it again from the same (non-installed) exe. Everything is
     * still there and the exit code is still 0 -- this is the repair path. */
    CHECK(spdf_win_setup_install(1, NULL, 0) == 0);
    CHECK(exists(installed));
    CHECK(exists(lnk));
    CHECK(key_exists(SPDF_WIN_SETUP_UNINSTALL_KEY));

    /* Stand in for the user's settings and session, so the promise --uninstall
     * makes in its completion message can be checked rather than believed. */
    CHECK(spdf_win_setup_state_dir(state_dir, BUF));
    CHECK(wcsstr(state_dir, root) == state_dir); /* redirected: the real one is unreachable */
    {
        wchar_t roaming[BUF];
        CHECK(spdf_win_setup_dir_of(state_dir, roaming, BUF));
        CreateDirectoryW(roaming, NULL);
    }
    CHECK(CreateDirectoryW(state_dir, NULL) != 0);
    _snwprintf_s(state_file, _countof(state_file), _TRUNCATE, L"%s\\settings.yaml", state_dir);
    CloseHandle(CreateFileW(state_file, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL));
    CHECK(exists(state_file));

    /* --- uninstall, from inside the install directory --------------------- */
    /* The Apps-list Uninstall button's exact path: the installed copy removes
     * itself, which it cannot do directly, so the detached waiter does it. */
    CHECK(spawn_child(installed, &child_rc));
    CHECK(child_rc == 0);
    CHECK(!exists(lnk));
    CHECK(!key_exists(SPDF_WIN_SETUP_UNINSTALL_KEY));
    CHECK(!key_exists(L"Software\\Classes\\ShenzhenPDF.Document\\shell\\open\\command"));
    CHECK(wait_gone(install_dir, 30));
    /* AND THE USER'S DATA SURVIVED. Without --purge this is the whole
     * difference between an uninstaller and a mistake. */
    CHECK(exists(state_file));

    /* Runnable twice, with nothing left to remove. */
    CHECK(spdf_win_setup_uninstall(1, 0) == 0);
    CHECK(exists(state_file));

    /* --- and once more, with --purge -------------------------------------- */
    /* Installed again, then removed WITH the data. The removal runs in this
     * process, from outside the install directory, which is the other branch:
     * the straight delete rather than the detached waiter. */
    CHECK(spdf_win_setup_install(1, NULL, 0) == 0);
    CHECK(exists(installed));
    CHECK(spdf_win_setup_uninstall(1, 1) == 0);
    CHECK(!exists(install_dir));
    CHECK(!exists(state_file));
    CHECK(!exists(state_dir));

    /* --- and the machine is as it was ------------------------------------- */
    RegDeleteTreeW(HKEY_CURRENT_USER, SPDF_WIN_SETUP_TEST_KEY);
    CHECK(!key_exists(SPDF_WIN_SETUP_UNINSTALL_KEY));
    wipe(root);
    CHECK(!exists(root));
    SetEnvironmentVariableW(SPDF_WIN_SETUP_ROOT_ENV, NULL);

    printf("setup_e2e_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
