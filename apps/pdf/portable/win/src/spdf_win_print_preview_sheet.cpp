/* spdf_win_print_preview_sheet.cpp — ASKING THE PRINTER HOW BIG THE PAPER IS,
 * ON A THREAD THAT IS ALLOWED TO WAIT. Contract: the four functions declared in
 * spdf_win_print_preview_internal.h. What the numbers mean is
 * spdf_win_print_preview_geom.h; the window is spdf_win_print_preview.cpp.
 *
 * WHY THIS IS NOT A FUNCTION CALL ON THE UI THREAD, WHICH IS WHAT IT WAS FIRST.
 * PHYSICALWIDTH, PHYSICALOFFSETX and HORZRES exist nowhere but on a real
 * printer DC, so the sheet cannot be known without opening one — and opening one
 * for a NETWORK printer talks to the device. MEASURED on this host
 * (2026-09-05): selecting "Brother DCP-L3550CDW series Printer", a Microsoft
 * IPP Class Driver queue, made CreateICW take **48 seconds**. The first version
 * of this preview called it from the combo's CBN_SELCHANGE handler, so the
 * whole print dialog froze for those 48 seconds and every control in it stopped
 * answering. That is precisely the failure this port already refuses to accept
 * from PrintDlgExW (portable/docs/windows-print-dialog.md), and it is not
 * acceptable from us either.
 *
 * SO IT IS A MAILBOX, NOT A CALL. The UI thread leaves a request (printer +
 * DEVMODE) and bumps a generation; one worker picks the LATEST request up,
 * measures, stores the answer and PostMessages the window. A reader clicking
 * through four printers queues one measurement, not four, because the worker
 * always reads the newest request rather than a queue of them.
 *
 * AND THE MAILBOX OUTLIVES THE PREVIEW. A worker wedged inside a driver for
 * most of a minute must not be waited for when the dialog closes -- and must
 * never be TerminateThread'd, for the reason spdf_win_print_dialog.h gives at
 * length: a thread killed inside a driver holds the loader lock and a COM
 * apartment. So this block is REFERENCE COUNTED, held by the preview and by the
 * worker, freed by whichever releases last; the preview clears the HWND on its
 * way out, under the lock, so a late PostMessage cannot land on a recycled
 * handle. Nothing here ever touches spdf_win_print_preview.
 */

#include "spdf_win_print_preview_internal.h"

#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "user32.lib")

struct spdf_win_preview_measure {
    volatile LONG refs;
    CRITICAL_SECTION lock;
    HWND hwnd; /* NULL once the preview has gone */
    int running;
    unsigned want_gen; /* bumped by the UI thread for each new request */
    unsigned done_gen; /* the generation the result below answers */
    /* the pending request */
    wchar_t printer[SPDF_WIN_PRINT_NAME_MAX];
    DEVMODEW* devmode;
    /* the newest result */
    spdf_win_preview_sheet sheet;
    int ok;
};

static DEVMODEW* devmode_clone(const DEVMODEW* devmode) {
    size_t bytes;
    DEVMODEW* copy;
    if (!devmode) return NULL;
    bytes = (size_t)devmode->dmSize + (size_t)devmode->dmDriverExtra;
    copy = (DEVMODEW*)malloc(bytes);
    if (copy) memcpy(copy, devmode, bytes);
    return copy;
}

/* --- the measurement itself, on a worker thread --------------------------- */

/* Everything a printer is asked, in one place. Takes no preview and no shared
 * state: a copy of the printer name and a copy of the DEVMODE, so it can run
 * for as long as the driver makes it. */
static int measure_sheet(const wchar_t* printer, const DEVMODEW* devmode, spdf_win_preview_sheet* out) {
    HDC dc;
    double paper_w = 0.0;
    double paper_h = 0.0;
    int ok;

    spdf_win_preview_sheet_clear(out);
    if (!printer || !printer[0]) return 0;

    /* The DEVMODE's own stock first, so it is ready as the fallback if the
     * driver turns out to report no physical sheet. dmFields is what says
     * whether dmPaperWidth/dmPaperLength mean anything at all — a DEVMODE
     * naming only a dmPaperSize code leaves them zero, and inventing A4 from
     * the code would be inventing paper. */
    if (devmode)
        spdf_win_preview_paper_pt(
            (devmode->dmFields & (DM_PAPERWIDTH | DM_PAPERLENGTH)) == (DM_PAPERWIDTH | DM_PAPERLENGTH),
            devmode->dmPaperWidth, devmode->dmPaperLength,
            (devmode->dmFields & DM_ORIENTATION) && devmode->dmOrientation == DMORIENT_LANDSCAPE, &paper_w, &paper_h);

    /* An INFORMATION context, not a full DC: every question below is a
     * GetDeviceCaps and CreateICW does not reserve the printer's drawing
     * resources. It is still the call that can take 48 seconds. */
    dc = CreateICW(L"WINSPOOL", printer, NULL, devmode);
    if (!dc) return 0;
    ok = spdf_win_preview_sheet_build(GetDeviceCaps(dc, LOGPIXELSX), GetDeviceCaps(dc, LOGPIXELSY),
                                      GetDeviceCaps(dc, PHYSICALWIDTH), GetDeviceCaps(dc, PHYSICALHEIGHT),
                                      GetDeviceCaps(dc, PHYSICALOFFSETX), GetDeviceCaps(dc, PHYSICALOFFSETY),
                                      GetDeviceCaps(dc, HORZRES), GetDeviceCaps(dc, VERTRES), paper_w, paper_h, out);
    DeleteDC(dc);
    return ok;
}

static DWORD WINAPI measure_thread(LPVOID param) {
    spdf_win_preview_measure* ms = (spdf_win_preview_measure*)param;

    for (;;) {
        wchar_t printer[SPDF_WIN_PRINT_NAME_MAX];
        DEVMODEW* devmode;
        spdf_win_preview_sheet sheet;
        unsigned gen;
        HWND hwnd;
        int ok;

        /* THE LATEST REQUEST, not the next one: a reader clicking through four
         * printers must cost one measurement, not four. */
        EnterCriticalSection(&ms->lock);
        if (ms->want_gen == ms->done_gen) {
            ms->running = 0;
            LeaveCriticalSection(&ms->lock);
            break;
        }
        gen = ms->want_gen;
        wcsncpy_s(printer, SPDF_WIN_PRINT_NAME_MAX, ms->printer, _TRUNCATE);
        devmode = devmode_clone(ms->devmode);
        LeaveCriticalSection(&ms->lock);

        ok = measure_sheet(printer, devmode, &sheet);
        free(devmode);

        EnterCriticalSection(&ms->lock);
        ms->done_gen = gen;
        ms->sheet = sheet;
        ms->ok = ok;
        hwnd = ms->hwnd;
        LeaveCriticalSection(&ms->lock);
        /* A dead window makes this fail harmlessly, and the HWND was cleared
         * under the lock, so it cannot be a handle Windows has since reused. */
        if (hwnd) PostMessageW(hwnd, SPDF_WIN_PREVIEW_WM_SHEET, 0, 0);
    }
    spdf_win_preview_measure_release(ms);
    return 0;
}

/* --- the UI thread's side ------------------------------------------------- */

spdf_win_preview_measure* spdf_win_preview_measure_new(HWND hwnd) {
    spdf_win_preview_measure* ms = (spdf_win_preview_measure*)calloc(1, sizeof(*ms));
    if (!ms) return NULL;
    InitializeCriticalSection(&ms->lock);
    ms->refs = 1;
    ms->hwnd = hwnd;
    return ms;
}

void spdf_win_preview_measure_release(spdf_win_preview_measure* ms) {
    if (!ms) return;
    if (InterlockedDecrement(&ms->refs) != 0) return;
    DeleteCriticalSection(&ms->lock);
    free(ms->devmode);
    free(ms);
}

void spdf_win_preview_measure_detach(spdf_win_preview_measure* ms) {
    if (!ms) return;
    EnterCriticalSection(&ms->lock);
    ms->hwnd = NULL;
    LeaveCriticalSection(&ms->lock);
}

void spdf_win_preview_measure_ask(spdf_win_preview_measure* ms, const wchar_t* printer, const DEVMODEW* devmode) {
    HANDLE thread;
    int start = 0;

    if (!ms) return;
    EnterCriticalSection(&ms->lock);
    wcsncpy_s(ms->printer, SPDF_WIN_PRINT_NAME_MAX, printer ? printer : L"", _TRUNCATE);
    free(ms->devmode);
    ms->devmode = devmode_clone(devmode);
    ++ms->want_gen;
    if (!ms->running) {
        ms->running = 1;
        start = 1;
    }
    LeaveCriticalSection(&ms->lock);
    if (!start) return; /* the worker already running will pick this up */

    /* The worker's own reference, taken BEFORE the thread exists so it can
     * never observe a count it has not been given. */
    InterlockedIncrement(&ms->refs);
    thread = CreateThread(NULL, 0, measure_thread, ms, 0, NULL);
    if (thread) {
        CloseHandle(thread); /* never joined -- see this file's header */
        return;
    }
    EnterCriticalSection(&ms->lock);
    ms->running = 0;
    LeaveCriticalSection(&ms->lock);
    spdf_win_preview_measure_release(ms);
}

int spdf_win_preview_measure_take(spdf_win_preview_measure* ms, spdf_win_preview_sheet* out, int* pending) {
    int ok;

    if (pending) *pending = 0;
    if (!ms || !out) return 0;
    EnterCriticalSection(&ms->lock);
    *out = ms->sheet;
    ok = ms->done_gen != 0 && ms->ok;
    /* PENDING IS NOT THE SAME AS "no sheet". A printer still being asked and a
     * printer that answered nothing are different sentences to show a reader,
     * and this is what lets the window say the right one. */
    if (pending) *pending = ms->want_gen != ms->done_gen;
    LeaveCriticalSection(&ms->lock);
    return ok;
}
