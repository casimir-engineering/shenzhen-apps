/* print_dialog_test.c — THE FALLBACK PRINT DIALOG, as a real window a real
 * reader could use, plus the two pieces of it that need no window at all.
 *
 * WHY IT MATTERS MORE HERE THAN IT WOULD ELSEWHERE. On this host Windows' own
 * print dialog never opens (portable/docs/windows-print-dialog.md), so
 * spdf_win_print_dialog.cpp is not a nicety behind a watchdog -- it IS the
 * print dialog, and every choice a reader can make about a print goes through
 * it. A dialog that opens but whose combo is empty, or whose page range comes
 * back as the whole document, would lose prints silently.
 *
 * FOUR CLAIMS.
 *   1. THE PRINTERS ARE REAL. spdf_win_print_dialog_printers() enumerates this
 *      machine through EnumPrintersW and the DEFAULT printer -- the one
 *      GetDefaultPrinterW names -- is the one it preselects. A machine with no
 *      printers is a SKIP with the reason, not a pass: there would be nothing
 *      to choose.
 *   2. THE RANGE MODEL. Fed to the SAME spdf_win_print_expand_ranges() the
 *      system dialog's ranges go through (spdf_win_print_math.h, differentially
 *      tested against the GTK original), so "pages 3-5" means the same three
 *      sheets whichever dialog asked. Reversed ends, a range off the end of the
 *      document, and a current page nobody told us are each their own check.
 *   3. THE WINDOW. It is created, its combo holds the printers, its fields take
 *      a page range and a scale, and Print returns them -- driven from a second
 *      thread with SendMessageW, which the OS marshals to the dialog's thread
 *      exactly as a real click would. The same shape as
 *      properties_dialog_test.c beside it, for the same reason: nothing else in
 *      this port can say whether a window's controls are populated.
 *   4. THE PREVIEW IS LIVE. It exists as a child window, and its page stepper
 *      follows the range the reader typed -- "Page 2 of N", forward, and no
 *      stepper at all once the range is one page. That is the part of the
 *      preview a window is needed for; the geometry it draws, and that the page
 *      rectangle IS spdf_win_print_dest_rect()'s output scaled, is
 *      print_preview_test.c's business and needs no window.
 *
 * IT OPENS A WINDOW ON THE DESKTOP FOR ABOUT A SECOND, and closes it from the
 * driving thread and again from a hard timeout, so the suite cannot leave one
 * behind. NOTHING IS PRINTED: spdf_win_print_dialog_show() only collects the
 * answer, and the job it would feed is print_e2e_test.c's business.
 *
 * ON A LOCKED WORKSTATION no window can be created; that is a SKIP with the OS
 * error, and claims 1 and 2 still run.
 *
 * TO LOOK AT IT: `print_dialog_test.exe --hold=20 [--dark]` leaves the dialog
 * on screen for twenty seconds before pressing Print, and changes no
 * assertion. That is how it was checked in both themes while
 * portable/docs/windows-print-dialog.md was written, and it is also how the
 * Properties button was shown to reach the driver's own sheet.
 */
/* spdf-test-sources: portable/win/src/spdf_win_print_dialog.cpp portable/win/src/spdf_win_print_dialog_controls.cpp portable/win/src/spdf_win_print_dialog_run.cpp portable/win/src/spdf_win_print_dialog_system.cpp portable/win/src/spdf_win_print_preview.cpp portable/win/src/spdf_win_print_preview_measure.cpp portable/win/src/spdf_win_print_preview_sheet.cpp portable/win/src/spdf_win_render.c portable/win/src/spdf_win_open.c portable/win/src/spdf_win_print.cpp portable/win/src/spdf_win_about.cpp portable/win/src/spdf_win_export.cpp portable/win/src/spdf_win_clipboard_page.cpp portable/win/src/spdf_win_selection.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c */
/* spdf-test-args: portable/win/tests/fixtures/outline.pdf */
/* spdf-test-needs: mupdf */
#include <windows.h>

#include <winspool.h>

#include "../src/spdf_win_print_dialog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wctype.h>

#pragma comment(lib, "winspool.lib")

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

#define DIALOG_CLASS L"SpdfWinPrintDialog"
/* The ids come from the header now (spdf_win_print_dialog.h), not from a copy
 * in this file: the dialog, the preview and this test all read the same
 * controls, and three private lists would drift. */
#define ID_PRINTER SPDF_WIN_PD_ID_PRINTER
#define ID_RANGE_ALL SPDF_WIN_PD_ID_RANGE_ALL
#define ID_RANGE_FROMTO SPDF_WIN_PD_ID_RANGE_FROMTO
#define ID_FROM SPDF_WIN_PD_ID_FROM
#define ID_TO SPDF_WIN_PD_ID_TO
#define ID_COPIES SPDF_WIN_PD_ID_COPIES
#define ID_SCALE_FIT SPDF_WIN_PD_ID_SCALE_FIT
#define ID_SCALE_CUSTOM SPDF_WIN_PD_ID_SCALE_CUSTOM
#define ID_PERCENT SPDF_WIN_PD_ID_PERCENT
#define ID_PRINT SPDF_WIN_PD_ID_PRINT

/* The preview child and its page stepper (spdf_win_print_preview_internal.h). */
#define PREVIEW_CLASS L"SpdfWinPrintPreview"
#define ID_PREVIEW_PREV 1301
#define ID_PREVIEW_NEXT 1302
#define ID_PREVIEW_COUNT 1303

/* --- 1. the printers ------------------------------------------------------ */

static int test_printers(spdf_win_print_printers* list) {
    wchar_t def[SPDF_WIN_PRINT_NAME_MAX];
    DWORD len = SPDF_WIN_PRINT_NAME_MAX;
    int count = spdf_win_print_dialog_printers(list);

    if (count <= 0) {
        printf("SKIP printers: this machine has no printers at all\n");
        ++g_skipped;
        return 0;
    }
    CHECK(count == list->count);
    CHECK(list->selected >= 0 && list->selected < list->count);
    CHECK(list->name[0][0] != L'\0');
    printf("print_dialog: %d printer(s), preselected \"%ls\"\n", count, list->name[list->selected]);

    if (GetDefaultPrinterW(def, &len)) {
        int at = spdf_win_print_printers_index_of(list, def);
        CHECK(at >= 0);
        CHECK(at == list->selected);
        /* Case-insensitively, because a name persisted in settings.yaml comes
         * back from the spooler with whatever case the spooler feels like. */
        {
            wchar_t shouted[SPDF_WIN_PRINT_NAME_MAX];
            int i;
            for (i = 0; def[i] && i < SPDF_WIN_PRINT_NAME_MAX - 1; ++i) shouted[i] = (wchar_t)towupper(def[i]);
            shouted[i] = L'\0';
            CHECK(spdf_win_print_printers_index_of(list, shouted) == at);
        }
    } else {
        printf("SKIP default-printer match: GetDefaultPrinterW failed, GetLastError=%lu\n",
               (unsigned long)GetLastError());
        ++g_skipped;
    }
    CHECK(spdf_win_print_printers_index_of(list, L"No Such Printer Exists Here") == -1);
    CHECK(spdf_win_print_printers_index_of(list, NULL) == -1);
    CHECK(spdf_win_print_printers_index_of(NULL, L"anything") == -1);
    return 1;
}

/* --- 2. the range model, through the shipping expansion ------------------- */

/* What spdf_win_print_dialog_run() does with the range, minus the printing:
 * `out` receives the 0-based page indices the job would be given. */
static int expand(spdf_win_print_range_mode mode, int from, int to, int current_page, int page_count, int* out,
                  int out_max) {
    spdf_win_print_request req;
    spdf_win_print_page_range range;
    int ranges;
    memset(&req, 0, sizeof(req));
    req.range = mode;
    req.from = from;
    req.to = to;
    ranges = spdf_win_print_dialog_range(&req, current_page, page_count, &range);
    return spdf_win_print_expand_ranges(ranges ? &range : NULL, ranges, page_count, out, out_max);
}

static void test_range_model(void) {
    spdf_win_print_request req;
    spdf_win_print_page_range range;
    int pages[16];

    /* ALL asks for no range at all, which is what the expansion reads as "the
     * whole document" -- the same convention the system dialog's zero
     * nPageRanges uses. */
    memset(&req, 0, sizeof(req));
    req.range = SPDF_WIN_PRINT_RANGE_ALL;
    CHECK(spdf_win_print_dialog_range(&req, 3, 10, &range) == 0);
    CHECK(expand(SPDF_WIN_PRINT_RANGE_ALL, 0, 0, 3, 4, pages, 16) == 4);
    CHECK(pages[0] == 0 && pages[3] == 3);

    /* CURRENT is 1-based on the way out and 0-based on the way in. */
    req.range = SPDF_WIN_PRINT_RANGE_CURRENT;
    CHECK(spdf_win_print_dialog_range(&req, 3, 10, &range) == 1);
    CHECK(range.from == 4 && range.to == 4);
    CHECK(expand(SPDF_WIN_PRINT_RANGE_CURRENT, 0, 0, 3, 10, pages, 16) == 1);
    CHECK(pages[0] == 3);
    /* A caller that does not know the page gets page 1, never an empty job.
     * The dialog greys the choice out in that case (spdf_win_print_dialog.cpp),
     * so a reader is never the one making this substitution. */
    CHECK(spdf_win_print_dialog_range(&req, -1, 10, &range) == 1);
    CHECK(range.from == 1 && range.to == 1);
    /* And a current page past the end still names a page that exists. */
    CHECK(spdf_win_print_dialog_range(&req, 99, 10, &range) == 1);
    CHECK(range.from == 10 && range.to == 10);

    /* FROM_TO: reversed ends are swapped rather than yielding nothing... */
    CHECK(expand(SPDF_WIN_PRINT_RANGE_FROM_TO, 5, 2, 0, 10, pages, 16) == 4);
    CHECK(pages[0] == 1 && pages[3] == 4);
    /* ...both ends are clamped into the document... */
    CHECK(expand(SPDF_WIN_PRINT_RANGE_FROM_TO, 0, 99, 0, 3, pages, 16) == 3);
    CHECK(pages[0] == 0 && pages[2] == 2);
    /* ...and a single page is a single sheet. */
    CHECK(expand(SPDF_WIN_PRINT_RANGE_FROM_TO, 2, 2, 0, 10, pages, 16) == 1);
    CHECK(pages[0] == 1);

    CHECK(spdf_win_print_dialog_range(NULL, 0, 10, &range) == 0);
    CHECK(spdf_win_print_dialog_range(&req, 0, 0, &range) == 0);
}

/* --- 3. the window -------------------------------------------------------- */

static volatile LONG g_window_seen = 0;
static int g_expected_printers = 0;
/* --hold=SECONDS keeps the dialog on screen before Print is pressed, and
 * --dark opens it in the dark theme. Neither changes a single assertion: they
 * exist so "look at the print dialog" is a repeatable command rather than a
 * human favour, which is the same reason portable/win/screenshot-window.ps1
 * exists for the main window (windows-port-handoff.md sec 0). The suite runs
 * with both off and closes the window in about a second. */
static int g_hold_ms = 0;
static int g_dark = 0;
/* The fixture's real page count, so the stepper's words can be predicted
 * without this file hard-coding a fixture's shape. */
static int g_page_count = 4;
static spdf_document* g_doc = NULL;
static const char* g_doc_path = NULL;

/* --- 4. the preview, as a live child of the dialog ------------------------ */

/* THE PREVIEW FOLLOWS THE CONTROLS, checked through the one thing about it that
 * is visible from outside: its page stepper. With "pages 2 to 3" chosen the
 * stepper must say "Page 2 of N" and be SHOWN; narrowing to a single page must
 * take it away entirely rather than leave two dead arrows. Both go through
 * spdf_win_print_expand_ranges(), the same expansion the job uses, so this also
 * says the preview cannot offer a page the job would not print.
 *
 * The geometry -- that the page rectangle IS spdf_win_print_dest_rect()'s,
 * scaled -- is print_preview_test.c's business and needs no window at all. */
static void test_preview(HWND dialog) {
    HWND preview = FindWindowExW(dialog, NULL, PREVIEW_CLASS, NULL);
    wchar_t label[64] = L"";
    wchar_t want[64];

    if (g_page_count < 3) return; /* already recorded as a skip in main */
    if (!preview) {
        printf("SKIP print preview: no child with class %ls\n", PREVIEW_CLASS);
        ++g_skipped;
        return;
    }
    _snwprintf_s(want, 64, _TRUNCATE, L"Page 2 of %d", g_page_count);
    GetWindowTextW(GetDlgItem(preview, ID_PREVIEW_COUNT), label, 64);
    CHECK(wcscmp(label, want) == 0);
    CHECK(IsWindowVisible(GetDlgItem(preview, ID_PREVIEW_NEXT)) != 0);
    /* Two pages in the range: back is dead at the first of them, forward is not. */
    CHECK(IsWindowEnabled(GetDlgItem(preview, ID_PREVIEW_PREV)) == 0);
    CHECK(IsWindowEnabled(GetDlgItem(preview, ID_PREVIEW_NEXT)) != 0);
    /* Forward once, and the stepper names the DOCUMENT page it moved to, not an
     * index into the range. */
    SendMessageW(preview, WM_COMMAND, MAKEWPARAM(ID_PREVIEW_NEXT, BN_CLICKED),
                 (LPARAM)GetDlgItem(preview, ID_PREVIEW_NEXT));
    _snwprintf_s(want, 64, _TRUNCATE, L"Page 3 of %d", g_page_count);
    GetWindowTextW(GetDlgItem(preview, ID_PREVIEW_COUNT), label, 64);
    CHECK(wcscmp(label, want) == 0);
    CHECK(IsWindowEnabled(GetDlgItem(preview, ID_PREVIEW_NEXT)) == 0);

    /* One page in the range: no stepper. */
    SetDlgItemInt(dialog, ID_TO, 2, FALSE);
    SendMessageW(dialog, WM_COMMAND, MAKEWPARAM(ID_RANGE_FROMTO, BN_CLICKED),
                 (LPARAM)GetDlgItem(dialog, ID_RANGE_FROMTO));
    CHECK(IsWindowVisible(GetDlgItem(preview, ID_PREVIEW_NEXT)) == 0);
    CHECK(IsWindowVisible(GetDlgItem(preview, ID_PREVIEW_COUNT)) == 0);
    /* Put the range back, so claim 3's assertions still describe pages 2-3. */
    SetDlgItemInt(dialog, ID_TO, 3, FALSE);
    SendMessageW(dialog, WM_COMMAND, MAKEWPARAM(ID_RANGE_FROMTO, BN_CLICKED),
                 (LPARAM)GetDlgItem(dialog, ID_RANGE_FROMTO));
    printf("print_dialog: the preview stepper followed the range\n");
}

static DWORD WINAPI drive_dialog(LPVOID unused) {
    HWND dialog = NULL;
    int waited = 0;
    (void)unused;

    /* Poll rather than sleep-then-look: the window is created synchronously by
     * the show function, but this thread may start before it.
     *
     * AND WAIT FOR IT TO BE VISIBLE, not merely findable. FindWindowW finds a
     * window the moment CreateWindowExW returns -- before its printer combo,
     * its radio groups and its preview exist -- and a driver that wins that
     * race reads an empty combo, writes into controls that are not there yet,
     * and then fails a dozen assertions about state it never actually set. The
     * dialog is shown only once it is completely built, so IsWindowVisible is
     * exactly the "a reader could now use this" line, and it is the only one
     * this thread is entitled to act after. */
    while (waited < 5000) {
        dialog = FindWindowW(DIALOG_CLASS, NULL);
        if (dialog && IsWindowVisible(dialog)) break;
        dialog = NULL;
        Sleep(25);
        waited += 25;
    }
    if (!dialog) return 0;
    InterlockedExchange(&g_window_seen, 1);

    /* The combo really holds the machine's printers, and one is chosen. */
    CHECK((int)SendMessageW(GetDlgItem(dialog, ID_PRINTER), CB_GETCOUNT, 0, 0) == g_expected_printers);
    CHECK((int)SendMessageW(GetDlgItem(dialog, ID_PRINTER), CB_GETCURSEL, 0, 0) >= 0);

    /* Choose pages 2 to 3, three copies, and 25%. CheckRadioButton rather than
     * a synthesised click: the radio's own auto behaviour is the button
     * control's, not this dialog's, and what is under test is what Print reads
     * back out of the controls. */
    CheckRadioButton(dialog, ID_RANGE_ALL, ID_RANGE_FROMTO, ID_RANGE_FROMTO);
    SetDlgItemInt(dialog, ID_FROM, 2, FALSE);
    SetDlgItemInt(dialog, ID_TO, 3, FALSE);
    SetDlgItemInt(dialog, ID_COPIES, 3, FALSE);
    CheckRadioButton(dialog, ID_SCALE_FIT, ID_SCALE_CUSTOM, ID_SCALE_CUSTOM);
    SetDlgItemTextW(dialog, ID_PERCENT, L"25");
    /* CheckRadioButton does not notify the dialog -- a real click also sends
     * BN_CLICKED, and that is what makes the preview follow. Sent, not posted,
     * so the sync has finished before the stepper is read below. */
    SendMessageW(dialog, WM_COMMAND, MAKEWPARAM(ID_RANGE_FROMTO, BN_CLICKED),
                 (LPARAM)GetDlgItem(dialog, ID_RANGE_FROMTO));
    test_preview(dialog);

    if (g_hold_ms > 0) Sleep((DWORD)g_hold_ms);
    SendMessageW(dialog, WM_COMMAND, MAKEWPARAM(ID_PRINT, BN_CLICKED), (LPARAM)GetDlgItem(dialog, ID_PRINT));
    return 0;
}

/* The safety net: whatever happens above, no window survives this test. */
static DWORD WINAPI force_close(LPVOID unused) {
    HWND dialog;
    (void)unused;
    Sleep(20000 + (DWORD)g_hold_ms);
    dialog = FindWindowW(DIALOG_CLASS, NULL);
    if (dialog) {
        printf("FAIL the print dialog was still open after 20 s; forcing it closed\n");
        ++g_failures;
        PostMessageW(dialog, WM_CLOSE, 0, 0);
    }
    return 0;
}

static void test_window(const spdf_win_print_printers* list) {
    spdf_win_print_request req;
    char err[512] = "";
    HANDLE driver, watchdog;
    int accepted;

    memset(&req, 0, sizeof(req));
    req.copies = 1;
    req.range = SPDF_WIN_PRINT_RANGE_ALL;
    req.choice.mode = SPDF_WIN_PRINT_SCALING_FIT;
    req.choice.custom_scale = 1.0;
    g_expected_printers = list->count;

    driver = CreateThread(NULL, 0, drive_dialog, NULL, 0, NULL);
    watchdog = CreateThread(NULL, 0, force_close, NULL, 0, NULL);

    accepted = spdf_win_print_dialog_show(NULL, g_dark, L"print_dialog_test.pdf", g_page_count, 1,
                                          "Windows' own print dialog did not open on this computer, so this is "
                                          "Shenzhen PDF's.",
                                          g_doc, g_doc_path, &req, err, sizeof(err));
    if (!InterlockedCompareExchange(&g_window_seen, 0, 0)) {
        printf("SKIP print-dialog window: no window with class %ls was created, err=\"%s\"\n", DIALOG_CLASS, err);
        ++g_skipped;
    } else {
        ++g_checks;
        if (!accepted) {
            printf("FAIL Print was pressed but the dialog reported a cancel\n");
            ++g_failures;
        }
        CHECK(req.printer[0] != L'\0');
        CHECK(spdf_win_print_printers_index_of(list, req.printer) >= 0);
        CHECK(req.range == SPDF_WIN_PRINT_RANGE_FROM_TO);
        CHECK(req.from == 2 && req.to == 3);
        CHECK(req.copies == 3);
        CHECK(req.choice.mode == SPDF_WIN_PRINT_SCALING_CUSTOM);
        CHECK(req.choice.custom_scale > 0.2499 && req.choice.custom_scale < 0.2501);
        printf("print_dialog: Print returned \"%ls\", pages %d-%d, %d copies, custom %.2f\n", req.printer, req.from,
               req.to, req.copies, req.choice.custom_scale);
        /* And the answer feeds the same expansion the job uses. */
        {
            int pages[8];
            int n = expand(req.range, req.from, req.to, 1, 4, pages, 8);
            CHECK(n == 2);
            CHECK(pages[0] == 1 && pages[1] == 2);
        }
    }
    spdf_win_print_request_free(&req);
    if (driver) {
        WaitForSingleObject(driver, 10000);
        CloseHandle(driver);
    }
    if (watchdog) CloseHandle(watchdog); /* left to expire; the process exits first */
}

/* PER-MONITOR-AWARE, LIKE THE APP. The shipping exe declares PerMonitorV2 in
 * its manifest; a test binary has no manifest and is DPI-UNAWARE, which makes
 * GetDpiForWindow answer 96 and hands the dialog back its 96-dpi layout,
 * stretched by the compositor. The dialog's whole DPI path -- MulDiv on every
 * coordinate, the font, the preview's stepper -- would then never run here, and
 * a screenshot taken from this binary would not be a screenshot of the dialog
 * the app shows. Resolved dynamically because a missing export must be a plain
 * 96 and not a crash, exactly as spdf_win_print_dialog.cpp resolves
 * GetDpiForWindow. */
static void claim_dpi_awareness(void) {
    typedef BOOL(WINAPI * set_ctx_fn)(HANDLE);
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    set_ctx_fn fn = user32 ? (set_ctx_fn)GetProcAddress(user32, "SetProcessDpiAwarenessContext") : NULL;
    /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == -4. */
    if (fn) fn((HANDLE)(INT_PTR)-4);
}

int main(int argc, char** argv) {
    spdf_win_print_printers list;
    char err[512] = "";
    int i;

    claim_dpi_awareness();
    for (i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--dark") == 0) g_dark = 1;
        else if (strncmp(argv[i], "--hold=", 7) == 0) g_hold_ms = atoi(argv[i] + 7) * 1000;
        else if (argv[i][0] != '-') g_doc_path = argv[i];
    }

    /* A REAL DOCUMENT, because the preview is only worth looking at with one:
     * the dialog measures pages on this thread through the handle and the
     * preview's own workers open the path for themselves. A fixture that cannot
     * be opened is not fatal -- the dialog then shows the sheet with no page
     * bitmap, which is a state it has to survive anyway. */
    if (g_doc_path) g_doc = spdf_open(g_doc_path, err, sizeof(err));
    if (g_doc) g_page_count = spdf_page_count(g_doc);
    else printf("SKIP preview bitmap: \"%s\" could not be opened: %s\n", g_doc_path ? g_doc_path : "(none)", err);
    if (g_page_count < 3) {
        printf("SKIP preview stepper: the fixture has only %d page(s)\n", g_page_count);
        ++g_skipped;
    }

    test_range_model();
    if (test_printers(&list)) test_window(&list);

    if (g_doc) spdf_close(g_doc);
    printf("print_dialog_test: %d checks, %d failures, %d skipped\n", g_checks, g_failures, g_skipped);
    return g_failures ? 1 : 0;
}
