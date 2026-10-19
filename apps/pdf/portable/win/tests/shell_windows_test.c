/* shell_windows_test.c -- the About box and the Keyboard Shortcuts sheet as
 * REAL WINDOWS, opened, driven from a second thread, and closed.
 *
 * about_test.c and shortcuts_test.c pin the TEXT and the ROWS; neither can say
 * whether a window opens, whether the About box's copyable field carries the
 * version, or whether the sheet scrolls. This one does, on the model of
 * properties_dialog_test.c: the show function owns the calling thread's
 * message loop, so a second thread finds each window by its class, reads and
 * pokes it with SendMessageW (marshalled to the owning thread, exactly as a
 * click would be), and closes it. A hard timeout closes it if the checks do
 * not, so the suite never leaves a window behind.
 *
 * IT OPENS TWO WINDOWS ON THE USER'S DESKTOP FOR ABOUT A SECOND. On a locked
 * workstation no window can be created: that is reported as SKIP with the OS
 * error, and the exit code stays 0, because nothing was learned about this
 * code either way -- the same honesty properties_dialog_test.c practises.
 *
 * The test binary carries no icon resource, so the About box draws without
 * one; that path (LoadImage returning NULL) is therefore the one exercised
 * here, and the one with the icon is exercised by the app itself.
 */
/* spdf-test-sources: portable/win/src/spdf_win_about.cpp portable/win/src/spdf_win_shortcuts.cpp portable/win/src/spdf_win_updater_version.c */
#include <windows.h>

#include "spdf_win_about.h"
#include "spdf_win_about_version.h"
#include "spdf_win_shortcuts.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                      \
    do {                                                                                 \
        ++g_checks;                                                                      \
        if (!(cond)) {                                                                   \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                       \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

#define ABOUT_CLASS L"SpdfWinAboutBox"
#define ABOUT_ID_TEXT 1101
#define SHEET_CLASS L"SpdfWinShortcutsSheet"

static volatile LONG g_about_seen = 0;
static volatile LONG g_sheet_seen = 0;

/* Find OUR window of a class: FindWindowW alone answers with any process's
 * window of that class, and on this machine several ShenzhenPDF instances run
 * at once (the user's, other tracks'), each able to have its own About box
 * open. Measured: the suite run found a foreign About box mid-construction
 * and reported its EDIT missing. Filtering on the process id is what makes
 * the answer about this binary. */
typedef struct find_own {
    const wchar_t* cls;
    HWND found;
} find_own;

static BOOL CALLBACK find_own_cb(HWND hwnd, LPARAM param) {
    find_own* f = (find_own*)param;
    wchar_t name[128];
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    if (!GetClassNameW(hwnd, name, 128) || wcscmp(name, f->cls) != 0) return TRUE;
    f->found = hwnd;
    return FALSE;
}

static HWND find_own_window(const wchar_t* cls) {
    find_own f;
    f.cls = cls;
    f.found = NULL;
    EnumWindows(find_own_cb, (LPARAM)&f);
    return f.found;
}

static HWND wait_for(const wchar_t* cls) {
    HWND hwnd = NULL;
    int waited = 0;
    while (waited < 5000 && !(hwnd = find_own_window(cls))) {
        Sleep(25);
        waited += 25;
    }
    return hwnd;
}

static DWORD WINAPI drive_about(LPVOID unused) {
    HWND box = wait_for(ABOUT_CLASS);
    HWND edit;
    wchar_t text[1024];
    wchar_t want[64];
    (void)unused;
    if (!box) return 0;
    InterlockedExchange(&g_about_seen, 1);
    edit = GetDlgItem(box, ABOUT_ID_TEXT);
    CHECK(edit != NULL);
    if (edit) {
        GetWindowTextW(edit, text, 1024);
        MultiByteToWideChar(CP_UTF8, 0, "Version " SPDF_WIN_VERSION_STR " (build " SPDF_WIN_BUILD_STR ")", -1, want, 64);
        CHECK(wcsstr(text, want) != NULL);
        CHECK(wcsstr(text, L"MuPDF ") != NULL);
        CHECK(wcsstr(text, L"\r\n") != NULL); /* an EDIT wants CRLF */
    }
    /* The title bar says what it is. */
    GetWindowTextW(box, text, 1024);
    CHECK(wcscmp(text, L"About Shenzhen PDF") == 0);
    SendMessageW(box, WM_CLOSE, 0, 0);
    return 0;
}

static DWORD WINAPI drive_sheet(LPVOID unused) {
    HWND sheet = wait_for(SHEET_CLASS);
    SCROLLINFO si;
    int before, after;
    (void)unused;
    if (!sheet) return 0;
    InterlockedExchange(&g_sheet_seen, 1);
    /* It scrolls: the content is taller than the window and a page-down moves
     * the position. */
    memset(&si, 0, sizeof(si));
    si.cbSize = sizeof(si);
    si.fMask = SIF_ALL;
    CHECK(GetScrollInfo(sheet, SB_VERT, &si));
    CHECK(si.nMax > (int)si.nPage);
    before = si.nPos;
    SendMessageW(sheet, WM_VSCROLL, SB_PAGEDOWN, 0);
    GetScrollInfo(sheet, SB_VERT, &si);
    after = si.nPos;
    CHECK(after > before);
    SendMessageW(sheet, WM_VSCROLL, SB_TOP, 0);
    GetScrollInfo(sheet, SB_VERT, &si);
    CHECK(si.nPos == 0);
    /* Repaints without complaint at the top and the bottom. */
    SendMessageW(sheet, WM_VSCROLL, SB_BOTTOM, 0);
    UpdateWindow(sheet);
    /* Escape closes it, as the sheet's own key handler promises. */
    SendMessageW(sheet, WM_KEYDOWN, VK_ESCAPE, 0);
    return 0;
}

static DWORD WINAPI watchdog(LPVOID unused) {
    HWND w;
    (void)unused;
    Sleep(15000);
    if ((w = find_own_window(ABOUT_CLASS)) != NULL) PostMessageW(w, WM_CLOSE, 0, 0);
    if ((w = find_own_window(SHEET_CLASS)) != NULL) PostMessageW(w, WM_CLOSE, 0, 0);
    return 0;
}

int main(void) {
    HANDLE t;
    int shown;
    HWND probe;

    /* Unbuffered, so a hang leaves the last step on the harness's log. */
    setvbuf(stdout, NULL, _IONBF, 0);

    /* Can this session create a window at all? */
    probe = CreateWindowExW(0, L"STATIC", L"", WS_POPUP, 0, 0, 1, 1, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!probe) {
        printf("SKIP shell_windows_test: no window can be created in this session (GetLastError=%lu); "
               "the workstation is probably locked\n",
               (unsigned long)GetLastError());
        return 0;
    }
    DestroyWindow(probe);
    CloseHandle(CreateThread(NULL, 0, watchdog, NULL, 0, NULL));

    printf("shell_windows_test: opening the About box\n");
    t = CreateThread(NULL, 0, drive_about, NULL, 0, NULL);
    shown = spdf_win_about_show(NULL, 1);
    printf("shell_windows_test: About box returned %d\n", shown);
    WaitForSingleObject(t, 6000);
    CloseHandle(t);
    CHECK(shown == 1);
    CHECK(g_about_seen == 1);
    CHECK(find_own_window(ABOUT_CLASS) == NULL); /* gone */

    printf("shell_windows_test: opening the Keyboard Shortcuts sheet\n");
    t = CreateThread(NULL, 0, drive_sheet, NULL, 0, NULL);
    shown = spdf_win_shortcuts_show(NULL, 0);
    printf("shell_windows_test: sheet returned %d\n", shown);
    WaitForSingleObject(t, 6000);
    CloseHandle(t);
    CHECK(shown == 1);
    CHECK(g_sheet_seen == 1);
    CHECK(find_own_window(SHEET_CLASS) == NULL);

    printf("shell_windows_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
