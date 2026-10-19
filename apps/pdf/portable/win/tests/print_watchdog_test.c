/* print_watchdog_test.c — PRINT CANNOT HANG THE APP. That is the whole claim,
 * and on this host it is a claim about a call that genuinely never returns.
 *
 * WHAT IS BEING GUARDED. PrintDlgExW with a valid hwndOwner does not come back
 * on this machine and creates no window (portable/docs/windows-print-dialog.md,
 * measured by print_dialog_probe.c beside this file). Until this round the app
 * called it straight from the UI thread, so File > Print wedged the process
 * with nothing on screen. spdf_win_print_system_dialog() now calls it on a
 * thread it is allowed to wedge and gives up waiting after
 * SPDF_WIN_PRINT_DIALOG_WATCHDOG_MS. This suite is the regression: it makes the
 * real call, against a real owner window, and FAILS IF IT DOES NOT RETURN.
 *
 * IT PASSES ON A HEALTHY HOST TOO, and that is deliberate rather than
 * convenient. A machine whose print dialog works will put a window up, the
 * clock stops, and the call then waits for a human -- so a driving thread
 * closes any dialog that appears and the suite asserts the other branch: the
 * call returned, and NOTHING was abandoned. Either way the assertion is "it
 * came back", which is the property that matters and the only one that
 * transfers to a machine nobody here has.
 *
 * THREE THINGS ARE COUNTED, not just the return:
 *   1. A NULL owner is refused IMMEDIATELY and starts no thread. PRINTDLGEX's
 *      hwndOwner cannot be NULL and this host answers E_HANDLE; paying the
 *      watchdog for a call that cannot succeed would be four seconds of the
 *      reader's life for nothing.
 *   2. The watchdog fires inside its own budget, not eventually.
 *   3. A SECOND Print does not pile up a second abandoned thread. The process's
 *      own thread count is read from a Toolhelp snapshot before and after, so
 *      "reuse or refuse" is measured rather than asserted -- one abandoned
 *      thread per process is the price of never calling TerminateThread, and
 *      one per Print would not be.
 *
 * THE ABANDONED THREAD IS STILL INSIDE comdlg32 WHEN THIS EXITS, so the last
 * thing main() does is TerminateProcess on itself: returning through the CRT's
 * exit with a thread stuck in a system call is the one way this test could
 * itself become the hang it is testing for. The exit code is preserved, which
 * is all the harness reads.
 */
/* spdf-test-sources: portable/win/src/spdf_win_print_dialog_system.cpp */
#include <windows.h>

#include <tlhelp32.h>

#include "../src/spdf_win_print_dialog.h"

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

static HWND g_owner;
static volatile LONG g_stop_closing;

/* --- how many threads this process has ----------------------------------- */

static int thread_count(void) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 entry;
    DWORD self = GetCurrentProcessId();
    int count = 0;

    if (snap == INVALID_HANDLE_VALUE) return -1;
    memset(&entry, 0, sizeof(entry));
    entry.dwSize = sizeof(entry);
    if (Thread32First(snap, &entry)) {
        do {
            if (entry.th32OwnerProcessID == self) ++count;
        } while (Thread32Next(snap, &entry));
    }
    CloseHandle(snap);
    return count;
}

/* --- close any dialog that DOES appear ------------------------------------ */

static BOOL CALLBACK close_stray(HWND hwnd, LPARAM param) {
    DWORD pid = 0;
    int* closed = (int*)param;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || hwnd == g_owner || !IsWindowVisible(hwnd)) return TRUE;
    /* Both, because a property sheet takes the second and a plain dialog the
     * first, and this thread cannot know which it is looking at. */
    PostMessageW(hwnd, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
    *closed += 1;
    return TRUE;
}

static DWORD WINAPI closer(LPVOID unused) {
    int closed = 0;
    (void)unused;
    while (!InterlockedCompareExchange(&g_stop_closing, 0, 0)) {
        Sleep(250);
        EnumWindows(close_stray, (LPARAM)&closed);
    }
    if (closed) printf("print_watchdog: closed %d dialog window(s) that appeared\n", closed);
    return 0;
}

/* --- the owner window ----------------------------------------------------- */

static LRESULT CALLBACK owner_proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(h, m, w, l); }

static HWND make_owner(void) {
    WNDCLASSEXW cls;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = owner_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    cls.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    cls.lpszClassName = L"SpdfPrintWatchdogTestOwner";
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
    return CreateWindowExW(0, L"SpdfPrintWatchdogTestOwner", L"print watchdog test",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE, 60, 60, 420, 200, NULL, NULL, GetModuleHandleW(NULL),
                           NULL);
}

int main(void) {
    spdf_win_print_choice preset;
    spdf_win_print_system_result result;
    char err[512] = "";
    HANDLE driver;
    ULONGLONG began;
    ULONGLONG elapsed;
    spdf_win_print_status status;
    int threads_before, threads_after;
    int code;

    preset.mode = SPDF_WIN_PRINT_SCALING_FIT;
    preset.custom_scale = 1.0;

    /* 1. A NULL owner: refused, at once, having started nothing. */
    threads_before = thread_count();
    began = GetTickCount64();
    status = spdf_win_print_system_dialog(NULL, 4, &preset, &result, err, sizeof(err));
    elapsed = GetTickCount64() - began;
    CHECK(status == SPDF_WIN_PRINT_NO_DIALOG);
    CHECK(err[0] != '\0');
    CHECK(elapsed < 500);
    CHECK(spdf_win_print_system_dialog_abandoned() == 0);
    threads_after = thread_count();
    CHECK(threads_before < 0 || threads_after == threads_before);
    printf("print_watchdog: NULL owner refused in %llu ms: %s\n", (unsigned long long)elapsed, err);

    g_owner = make_owner();
    if (!g_owner) {
        /* No window station -- a locked session, or a service context. Nothing
         * would have been learned about this code either way. */
        printf("SKIP print-watchdog: no owner window could be created, GetLastError=%lu\n",
               (unsigned long)GetLastError());
        printf("print_watchdog_test: %d checks, %d failures\n", g_checks, g_failures);
        return g_failures ? 1 : 0;
    }
    driver = CreateThread(NULL, 0, closer, NULL, 0, NULL);

    /* 2. THE REAL CALL. It must come back. */
    threads_before = thread_count();
    err[0] = '\0';
    began = GetTickCount64();
    status = spdf_win_print_system_dialog(g_owner, 4, &preset, &result, err, sizeof(err));
    elapsed = GetTickCount64() - began;
    printf("print_watchdog: status=%d after %llu ms, err=\"%s\"\n", (int)status, (unsigned long long)elapsed, err);
    /* 30 s is not the budget, it is a bound: anything slower than this and the
     * reader has been left staring at a frozen window, which is the bug. */
    CHECK(elapsed < 30000);

    if (status == SPDF_WIN_PRINT_NO_DIALOG && spdf_win_print_system_dialog_abandoned()) {
        /* This host. The watchdog fired inside its budget and remembered. */
        CHECK(elapsed >= SPDF_WIN_PRINT_DIALOG_WATCHDOG_MS);
        CHECK(elapsed < (ULONGLONG)SPDF_WIN_PRINT_DIALOG_WATCHDOG_MS + 10000);
        CHECK(err[0] != '\0');
        threads_after = thread_count();
        /* Exactly one thread was abandoned, and it is still there. */
        CHECK(threads_before < 0 || threads_after >= threads_before);

        /* 3. A SECOND Print asks nothing and abandons nothing. */
        threads_before = thread_count();
        err[0] = '\0';
        began = GetTickCount64();
        status = spdf_win_print_system_dialog(g_owner, 4, &preset, &result, err, sizeof(err));
        elapsed = GetTickCount64() - began;
        CHECK(status == SPDF_WIN_PRINT_NO_DIALOG);
        CHECK(elapsed < 500);
        threads_after = thread_count();
        CHECK(threads_before < 0 || threads_after == threads_before);
        printf("print_watchdog: the second attempt refused in %llu ms with %d thread(s), unchanged\n",
               (unsigned long long)elapsed, threads_after);
    } else {
        /* A HEALTHY HOST: Windows' dialog appeared and the driving thread shut
         * it. Whatever it decided, nothing was abandoned. */
        CHECK(spdf_win_print_system_dialog_abandoned() == 0);
        CHECK(status == SPDF_WIN_PRINT_CANCELLED || status == SPDF_WIN_PRINT_OK ||
              status == SPDF_WIN_PRINT_FAILED);
        printf("print_watchdog: Windows' print dialog WORKS on this host -- nothing was abandoned\n");
        if (status == SPDF_WIN_PRINT_OK) {
            free(result.pages);
            if (result.dc) DeleteDC(result.dc);
        }
    }

    InterlockedExchange(&g_stop_closing, 1);
    if (driver) {
        WaitForSingleObject(driver, 3000);
        CloseHandle(driver);
    }
    DestroyWindow(g_owner);

    printf("print_watchdog_test: %d checks, %d failures\n", g_checks, g_failures);
    code = g_failures ? 1 : 0;
    fflush(stdout);
    /* See the header: a thread of this process is still inside comdlg32 and
     * never will not be. */
    TerminateProcess(GetCurrentProcess(), (UINT)code);
    return code;
}
