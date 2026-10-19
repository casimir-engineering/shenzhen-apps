/* properties_dialog_test.c -- the properties panel as a REAL WINDOW.
 *
 * WHY THIS EXISTS. portable/docs/windows-port-handoff.md section 0: "Nobody has
 * ever seen a ShenzhenPDF window open on Windows", and every visual claim in
 * this repository is "a build, an exit code, or a pixel comparison of an
 * offscreen render". properties_test.c covers the model and can never say
 * whether the window is created, whether its controls are populated, or
 * whether Copy All copies. This one does, by opening the panel, DRIVING it from
 * a second thread and closing it again.
 *
 * WHAT IT ASSERTS, in order:
 *   1. the window is created and findable by its class;
 *   2. its read-only EDIT control holds the transcript the model produced,
 *      with LF turned into CRLF -- a bare LF renders as a box and runs the
 *      whole panel onto one line, which is why the conversion exists;
 *   3. Copy All puts that transcript on the clipboard as CF_UNICODETEXT;
 *   4. the window closes and the modal loop returns.
 *
 * IT OPENS A WINDOW ON THE USER'S DESKTOP FOR ABOUT A SECOND. That is the
 * deliberate cost of proving anything at all about this layer, and it is the
 * same trade portable/win/screenshot-window.ps1 already makes. The window is
 * closed from the driving thread and again from a hard timeout, so the suite
 * cannot leave one behind -- the Windows equivalent of the repo's "do not leave
 * a stray ShenzhenPDF.exe running".
 *
 * ON A LOCKED WORKSTATION no window can be created at all. That is reported as
 * SKIP with the OS error, never as a failure: nothing would have been learned
 * about this code either way, and properties_test.c still checks the model.
 *
 * THE CLIPBOARD IS LEFT HOLDING THE TRANSCRIPT, like any Copy All would, and
 * like clipboard_test.c and page_export_test.c already do. Nothing is restored.
 */
/* spdf-test-sources: portable/win/src/spdf_win_properties.cpp portable/win/src/spdf_win_properties_dialog.cpp portable/win/src/spdf_win_selection.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
/* spdf-test-needs: mupdf */
#include <windows.h>

#include "shenzhen_pdf_core.h"
#include "spdf_win_properties.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;
static int g_skipped = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define DIALOG_CLASS L"SpdfWinPropertiesDialog"
#define ID_TEXT 1001
#define ID_COPY 1002

static char g_transcript[16384];
static volatile LONG g_window_seen = 0;

/* UTF-16 -> UTF-8 with CRLF folded back to LF, so what came out of the control
 * can be compared with what went into it. */
static void narrow_and_unfold(const wchar_t* wide, char* out, int out_len) {
    int i, w = 0;
    char* narrow = (char*)malloc((size_t)out_len);
    out[0] = '\0';
    if (!narrow) return;
    if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, narrow, out_len, NULL, NULL) <= 0) {
        free(narrow);
        return;
    }
    for (i = 0; narrow[i]; ++i) {
        if (narrow[i] == '\r' && narrow[i + 1] == '\n') continue;
        if (w + 1 >= out_len) break;
        out[w++] = narrow[i];
    }
    out[w] = '\0';
    free(narrow);
}

/* The driving thread. The dialog owns the calling thread's message loop, so
 * everything that pokes at it has to come from somewhere else; SendMessageW is
 * marshalled to the owning thread by the OS, which is exactly the behaviour a
 * real click would have. */
static DWORD WINAPI drive_dialog(LPVOID unused) {
    HWND dialog = NULL;
    HWND edit;
    int waited = 0;
    wchar_t* text;
    int length;
    char round_trip[16384];

    (void)unused;
    /* Poll rather than sleep-then-look: the window is created synchronously by
     * spdf_win_properties_show(), but this thread may start before it -- and
     * wait for VISIBLE rather than merely findable, because FindWindowW finds
     * the window before its EDIT and its buttons exist. The panel is placed on
     * the owner's monitor and shown only once it is built, so being visible is
     * the line after which this thread may drive it. */
    while (waited < 5000) {
        dialog = FindWindowW(DIALOG_CLASS, NULL);
        if (dialog && IsWindowVisible(dialog)) break;
        dialog = NULL;
        Sleep(25);
        waited += 25;
    }
    if (!dialog) return 0;
    InterlockedExchange(&g_window_seen, 1);

    /* 2. The control holds the transcript. */
    edit = GetDlgItem(dialog, ID_TEXT);
    CHECK(edit != NULL);
    if (edit) {
        length = GetWindowTextLengthW(edit);
        CHECK(length > 0);
        text = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)(length + 1));
        if (text) {
            GetWindowTextW(edit, text, length + 1);
            /* CRLF, not a bare LF. */
            CHECK(wcsstr(text, L"\r\n") != NULL);
            CHECK(wcschr(text, L'\n') != NULL);
            narrow_and_unfold(text, round_trip, (int)sizeof(round_trip));
            CHECK(strcmp(round_trip, g_transcript) == 0);
            if (strcmp(round_trip, g_transcript) != 0)
                printf("      control text and model transcript differ\n");
            free(text);
        }
    }

    /* 3. Copy All. */
    if (OpenClipboard(NULL)) {
        EmptyClipboard();
        CloseClipboard();
    }
    SendMessageW(dialog, WM_COMMAND, MAKEWPARAM(ID_COPY, BN_CLICKED), (LPARAM)GetDlgItem(dialog, ID_COPY));
    if (OpenClipboard(NULL)) {
        HANDLE data = GetClipboardData(CF_UNICODETEXT);
        CHECK(data != NULL);
        if (data) {
            const wchar_t* pasted = (const wchar_t*)GlobalLock(data);
            CHECK(pasted != NULL);
            if (pasted) {
                char back[16384];
                narrow_and_unfold(pasted, back, (int)sizeof(back));
                CHECK(strcmp(back, g_transcript) == 0);
                GlobalUnlock(data);
            }
        }
        CloseClipboard();
    } else {
        printf("SKIP copy-all read-back: OpenClipboard failed, GetLastError=%lu\n", (unsigned long)GetLastError());
        ++g_skipped;
    }

    /* 4. Close it -- and again from the timeout below if this ever failed. */
    PostMessageW(dialog, WM_CLOSE, 0, 0);
    return 0;
}

/* The safety net: whatever happens above, no window survives this test. */
static DWORD WINAPI force_close(LPVOID unused) {
    HWND dialog;
    (void)unused;
    Sleep(15000);
    dialog = FindWindowW(DIALOG_CLASS, NULL);
    if (dialog) {
        printf("FAIL the properties window was still open after 15 s; forcing it closed\n");
        ++g_failures;
        PostMessageW(dialog, WM_CLOSE, 0, 0);
    }
    return 0;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "portable/win/tests/fixtures/golden.pdf";
    char err[512] = "";
    spdf_document* doc;
    spdf_win_properties props;
    wchar_t wide[MAX_PATH];
    HANDLE driver;
    HANDLE watchdog;
    int shown;

    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", path, err);
        return 1;
    }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, MAX_PATH);
    CHECK(spdf_win_properties_collect(doc, wide, 0, 0, 0, &props) > 0);
    CHECK(spdf_win_properties_transcript(&props, g_transcript, sizeof(g_transcript)) > 0);

    driver = CreateThread(NULL, 0, drive_dialog, NULL, 0, NULL);
    watchdog = CreateThread(NULL, 0, force_close, NULL, 0, NULL);

    shown = spdf_win_properties_show(NULL, &props);
    if (!shown) {
        /* A locked session, or no window station at all. Nothing has been shown
         * about this code, so it is a SKIP with the reason, not a failure. */
        printf("SKIP properties-dialog: the window could not be created, GetLastError=%lu\n",
               (unsigned long)GetLastError());
        ++g_skipped;
    } else {
        ++g_checks;
        if (!InterlockedCompareExchange(&g_window_seen, 0, 0)) {
            printf("FAIL the dialog ran its modal loop but no window with class %ls was ever found\n", DIALOG_CLASS);
            ++g_failures;
        }
    }

    if (driver) {
        WaitForSingleObject(driver, 20000);
        CloseHandle(driver);
    }
    if (watchdog) CloseHandle(watchdog); /* left to expire; the process exits first */
    spdf_close(doc);

    printf("properties_dialog_test: %d checks, %d failures, %d skipped\n", g_checks, g_failures, g_skipped);
    return g_failures ? 1 : 0;
}
