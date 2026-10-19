/* spdf_win_print_dialog_system.cpp — PrintDlgExW, on a thread it is allowed to
 * wedge in. Every measurement and every rule this file follows is written down
 * in spdf_win_print_dialog.h; what is here is the mechanism.
 */

#include "spdf_win_print_dialog.h"

#include "spdf_win_modal_scope.h"
#include "spdf_win_print_scaling.h" /* the Scaling page, Win32 half */

#include <commdlg.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")

/* ONE HEAP BLOCK, owned by whichever side wins the hand-off. Nothing PrintDlgEx
 * can still write into may live on the caller's stack: the caller's frame is
 * gone the moment the watchdog gives up, and the thread inside comdlg32 is
 * still there. */
typedef struct system_dialog_job {
    PRINTDLGEXW pd;
    PRINTPAGERANGE ranges[16];
    spdf_win_print_tpl tpl;
    spdf_win_print_choice choice;
    /* IN THE BLOCK, not on the caller's stack: PRINTDLGEX::lphPropertyPages is
     * an ARRAY the dialog reads while it runs, and an abandoned call would read
     * a frame that no longer exists. */
    HPROPSHEETPAGE page;
    HANDLE done;
    HRESULT hr;
    /* 0 nobody has claimed it yet, 1 the thread returned and the watcher owns
     * the cleanup, 2 the watcher gave up and the THREAD owns the cleanup. One
     * interlocked compare-and-swap each; exactly one side can win. */
    volatile LONG handoff;
} system_dialog_job;

/* 0 never tried, 1 a dialog is in flight, 2 this host abandoned one and is
 * never asked again. Process-wide, and deliberately never reset: a machine
 * whose PrintDlgEx wedged once will wedge again, and paying the watchdog a
 * second time is a worse answer than going straight to the dialog that works. */
static volatile LONG g_system_state;

int spdf_win_print_system_dialog_abandoned(void) {
    return InterlockedCompareExchange(&g_system_state, 2, 2) == 2 ? 1 : 0;
}

static void system_job_release(system_dialog_job* job) {
    if (!job) return;
    if (job->pd.hDC) DeleteDC(job->pd.hDC);
    if (job->pd.hDevMode) GlobalFree(job->pd.hDevMode);
    if (job->pd.hDevNames) GlobalFree(job->pd.hDevNames);
    if (job->done) CloseHandle(job->done);
    free(job);
}

static DWORD WINAPI system_dialog_thread(LPVOID param) {
    system_dialog_job* job = (system_dialog_job*)param;
    HRESULT co;
    HRESULT hr;
    MSG msg;

    /* ITS OWN APARTMENT AND ITS OWN QUEUE. A dialog is an STA affair, and the
     * print experience talks to its host by sending messages, so the thread
     * that owns the call must be in the message system before the call is made.
     * (Neither turns out to matter on this host -- the hang survives MTA, no
     * COM at all and no pump -- but a thread that shows a dialog is written
     * this way regardless, and the port cannot assume this host is every
     * host.) */
    co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    PeekMessageW(&msg, NULL, 0, 0, PM_NOREMOVE);

    hr = PrintDlgExW(&job->pd);

    if (SUCCEEDED(co)) CoUninitialize();

    if (InterlockedCompareExchange(&job->handoff, 1, 0) == 0) {
        /* The watcher is still waiting: hand it the answer and let it clean up. */
        job->hr = hr;
        SetEvent(job->done);
        return 0;
    }
    /* ABANDONED, and this is the only place that can free the block -- the
     * watcher gave up on it long ago. A dialog the reader eventually dismissed
     * therefore leaks nothing; a dialog that never comes back leaks this one
     * block and one thread, per process, once, which is the price of not
     * calling TerminateThread. */
    system_job_release(job);
    return 0;
}

/* --- watching for a window ------------------------------------------------ */

#define SYSTEM_MAX_WINDOWS 128

typedef struct system_windows {
    HWND h[SYSTEM_MAX_WINDOWS];
    int count;
    int found_new;
    /* THE CALLING THREAD'S OWN WINDOWS ARE NOT THE DIALOG. This thread sits
     * in the wait below pumping its queue, and what it dispatches can put a
     * window up: the updater's task dialog is on a timer that fires into
     * exactly this pump (spdf_win_updater_ui.cpp). Counting that as "the
     * print dialog appeared" stops the watchdog clock for good -- section 14
     * of portable/docs/windows-native-observations.md measures it. */
    DWORD skip_thread;
} system_windows;

static BOOL CALLBACK system_collect(HWND hwnd, LPARAM param) {
    system_windows* w = (system_windows*)param;
    DWORD pid = 0;
    DWORD tid = GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || tid == w->skip_thread || !IsWindowVisible(hwnd)) return TRUE;
    if (w->count < SYSTEM_MAX_WINDOWS) w->h[w->count++] = hwnd;
    return TRUE;
}

static BOOL CALLBACK system_look_for_new(HWND hwnd, LPARAM param) {
    system_windows* before = (system_windows*)param;
    DWORD pid = 0;
    DWORD tid;
    int i;
    tid = GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || tid == before->skip_thread || !IsWindowVisible(hwnd)) return TRUE;
    for (i = 0; i < before->count; ++i)
        if (before->h[i] == hwnd) return TRUE;
    before->found_new = 1;
    return FALSE;
}

/* ANY VISIBLE TOP-LEVEL WINDOW OF THIS PROCESS THAT WAS NOT THERE BEFORE, not
 * just one belonging to the dialog's thread: comdlg32 is free to put the sheet
 * on a thread of its own choosing, and a watchdog that only looked at the one
 * thread would cut a working dialog off. The app itself creates nothing during
 * the wait -- the calling thread is in this loop and the parent is disabled --
 * so a new visible window IS the dialog. (A dialog hosted in ANOTHER PROCESS
 * would still be missed; nothing observed here does that, and the fallback is
 * a working dialog rather than a failure, so the cost of guessing wrong is a
 * dialog the reader did not expect and not a lost print.) */
static int system_dialog_window_is_up(system_windows* before) {
    before->found_new = 0;
    EnumWindows(system_look_for_new, (LPARAM)before);
    return before->found_new;
}

/* --- the pages the dialog asked for -------------------------------------- */

static int system_selected_pages(const PRINTDLGEXW* pd, int page_count, int** out) {
    spdf_win_print_page_range stack_ranges[16];
    spdf_win_print_page_range* ranges = NULL;
    int range_count = 0;
    int* pages;
    int written;
    DWORD i;

    *out = NULL;
    if (page_count <= 0) return 0;
    if ((pd->Flags & PD_PAGENUMS) && pd->nPageRanges > 0 && pd->lpPageRanges) {
        range_count = (int)pd->nPageRanges;
        if (range_count > (int)(sizeof(stack_ranges) / sizeof(stack_ranges[0])))
            range_count = (int)(sizeof(stack_ranges) / sizeof(stack_ranges[0]));
        for (i = 0; i < (DWORD)range_count; ++i) {
            stack_ranges[i].from = (int)pd->lpPageRanges[i].nFromPage;
            stack_ranges[i].to = (int)pd->lpPageRanges[i].nToPage;
        }
        ranges = stack_ranges;
    }
    pages = (int*)malloc(sizeof(int) * (size_t)page_count);
    if (!pages) return 0;
    written = spdf_win_print_expand_ranges(ranges, range_count, page_count, pages, page_count);
    if (written <= 0) {
        free(pages);
        return 0;
    }
    *out = pages;
    return written;
}

/* --- the entry point ------------------------------------------------------ */

spdf_win_print_status spdf_win_print_system_dialog(HWND parent, int doc_page_count,
                                                   const spdf_win_print_choice* preset,
                                                   spdf_win_print_system_result* out, char* err, size_t err_len) {
    system_dialog_job* job;
    system_windows before;
    HPROPSHEETPAGE page = NULL;
    HANDLE thread;
    ULONGLONG started;
    int window_up = 0;
    HRESULT hr;
    LONG previous;

    if (err && err_len) err[0] = '\0';
    if (!out) return SPDF_WIN_PRINT_FAILED;
    memset(out, 0, sizeof(*out));
    if (preset) out->choice = *preset;

    /* PRINTDLGEX's hwndOwner cannot be NULL, and this host says so with
     * E_HANDLE. Measured, so the thread is not even started. */
    if (!parent) {
        if (err && err_len)
            _snprintf_s(err, err_len, _TRUNCATE,
                        "Windows' print dialog needs an application window to belong to.");
        return SPDF_WIN_PRINT_NO_DIALOG;
    }
    if (doc_page_count <= 0) return SPDF_WIN_PRINT_NO_DOCUMENT;

    previous = InterlockedCompareExchange(&g_system_state, 1, 0);
    if (previous == 2) {
        /* Already abandoned once on this host. No sentence: the caller shows
         * the in-app dialog, which explains itself. */
        return SPDF_WIN_PRINT_NO_DIALOG;
    }
    if (previous == 1) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "A print dialog is already open.");
        return SPDF_WIN_PRINT_NO_DIALOG;
    }

    job = (system_dialog_job*)calloc(1, sizeof(*job));
    if (!job) {
        InterlockedExchange(&g_system_state, 0);
        return SPDF_WIN_PRINT_FAILED;
    }
    job->choice = out->choice;
    job->choice.custom_scale = spdf_win_print_clamp_custom_scale(job->choice.custom_scale);
    job->done = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!job->done) {
        free(job);
        InterlockedExchange(&g_system_state, 0);
        return SPDF_WIN_PRINT_FAILED;
    }
    job->pd.lStructSize = sizeof(job->pd);
    job->pd.hwndOwner = parent;
    job->pd.Flags = PD_RETURNDC | PD_NOSELECTION | PD_NOCURRENTPAGE;
    job->pd.nStartPage = START_PAGE_GENERAL;
    job->pd.nMinPage = 1;
    job->pd.nMaxPage = (WORD)(doc_page_count > 0xFFFF ? 0xFFFF : doc_page_count);
    job->pd.nCopies = 1;
    job->pd.nMaxPageRanges = (DWORD)(sizeof(job->ranges) / sizeof(job->ranges[0]));
    job->pd.lpPageRanges = job->ranges;
    /* Our tab beside the General page; PrintDlgEx owns it once it has it. A page
     * that could not be built is a dialog without the tab, printing with the
     * choice as given. The template and the choice are inside `job`, so they
     * outlive an abandoned call. */
    job->page = spdf_win_print_scaling_page(&job->tpl, &job->choice);
    page = job->page;
    if (job->page) {
        job->pd.nPropertyPages = 1;
        job->pd.lphPropertyPages = &job->page;
    }

    memset(&before, 0, sizeof(before));
    before.skip_thread = GetCurrentThreadId();
    EnumWindows(system_collect, (LPARAM)&before);

    thread = CreateThread(NULL, 0, system_dialog_thread, job, 0, NULL);
    if (!thread) {
        if (page) DestroyPropertySheetPage(page);
        job->pd.lphPropertyPages = NULL;
        system_job_release(job);
        InterlockedExchange(&g_system_state, 0);
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The print dialog could not be started.");
        return SPDF_WIN_PRINT_NO_DIALOG;
    }
    CloseHandle(thread); /* nothing is ever waited on but `done`; see the header */

    /* MODAL AGAINST THE PARENT ONLY, like every other dialog in this port
     * (spdf_win_about.cpp), and the calling thread KEEPS PUMPING: its window
     * is the dialog's owner, and an owner whose thread stops answering messages
     * is a deadlock waiting to happen. */
    {
        /* The scope, not four hand-written lines: every path out of this block
         * -- the abandonment below included -- re-enables the owner and gives
         * it the activation back. spdf_win_modal_scope.h says why that is not
         * left to the reader of this function. */
        SpdfWinModalGuard modal(parent);
        started = GetTickCount64();
        for (;;) {
            MSG msg;
            DWORD w = MsgWaitForMultipleObjects(1, &job->done, FALSE, 50, QS_ALLINPUT);
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            if (w == WAIT_OBJECT_0) break;
            /* THE CLOCK RUNS ONLY UNTIL THE DIALOG IS UP -- after that the
             * reader may take as long as they like -- AND IT IS RE-ARMED IF
             * THAT WINDOW GOES AWAY AGAIN. A window that appears and then
             * closes while PrintDlgEx has still not returned was never the
             * dialog; leaving the clock stopped for it is how the owner ends up
             * disabled forever with nothing on screen, which is the exact
             * "not responsive and not even focusable" report section 14 of
             * portable/docs/windows-native-observations.md chased down. */
            if (system_dialog_window_is_up(&before)) {
                window_up = 1;
            } else if (window_up) {
                window_up = 0;
                started = GetTickCount64();
            }
            if (!window_up && GetTickCount64() - started >= SPDF_WIN_PRINT_DIALOG_WATCHDOG_MS) {
                if (InterlockedCompareExchange(&job->handoff, 2, 0) == 0) {
                    /* The thread is still inside PrintDlgEx and will free the
                     * block itself if it ever comes out. Nothing here may touch
                     * `job` again. */
                    InterlockedExchange(&g_system_state, 2);
                    modal.end();
                    if (err && err_len)
                        _snprintf_s(err, err_len, _TRUNCATE,
                                    "Windows' print dialog did not open within %d seconds.",
                                    SPDF_WIN_PRINT_DIALOG_WATCHDOG_MS / 1000);
                    return SPDF_WIN_PRINT_NO_DIALOG;
                }
                /* The thread won the race by a hair: its answer is on its way. */
                WaitForSingleObject(job->done, INFINITE);
                break;
            }
        }
    }

    hr = job->hr;
    InterlockedExchange(&g_system_state, 0);

    if (FAILED(hr)) {
        /* THE CODE IS IN THE SENTENCE because the causes are indistinguishable
         * from outside -- a driver that will not load, a property page the
         * sheet refused -- and nobody can narrow it down without the HRESULT. */
        if (err && err_len)
            _snprintf_s(err, err_len, _TRUNCATE, "Windows' print dialog could not be shown (0x%08lX).",
                        (unsigned long)hr);
        system_job_release(job);
        return SPDF_WIN_PRINT_NO_DIALOG;
    }
    if (job->pd.dwResultAction != PD_RESULT_PRINT) {
        system_job_release(job);
        return SPDF_WIN_PRINT_CANCELLED;
    }
    /* PD_RESULT_PRINT WITH NO DC IS NOT A CANCEL, and reporting it as one is how
     * "Print does nothing" happens with nothing on screen to explain it. */
    if (!job->pd.hDC) {
        if (err && err_len)
            _snprintf_s(err, err_len, _TRUNCATE, "The printer did not provide a device to print on.");
        system_job_release(job);
        return SPDF_WIN_PRINT_FAILED;
    }

    out->page_count = system_selected_pages(&job->pd, doc_page_count, &out->pages);
    if (out->page_count <= 0) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "No pages were selected.");
        system_job_release(job);
        return SPDF_WIN_PRINT_CANCELLED;
    }
    out->dc = job->pd.hDC;
    job->pd.hDC = NULL; /* the caller owns it now */
    out->copies = job->pd.nCopies > 0 ? (int)job->pd.nCopies : 1;
    out->choice = job->choice;
    system_job_release(job);
    return SPDF_WIN_PRINT_OK;
}

/* --- Windows' CLASSIC dialog, offered explicitly -------------------------- */

/* WHY THIS ONE IS SAFE ON THE UI THREAD when its sibling above is not. The
 * probe measured both on this host (portable/docs/windows-print-dialog.md
 * section 1): PrintDlgExW with a valid owner never returns, PrintDlgW puts a
 * window up in well under a second and returns TRUE or FALSE like any other
 * comdlg32 dialog. So this needs no thread, no watchdog and no hand-off -- and
 * it is the evidence behind this port's claim that comdlg32 is fine here and
 * only the Windows 11 print experience is not.
 *
 * NO PD_RETURNDC. The caller already has one path from a printer name plus a
 * DEVMODE to a DC (spdf_win_print_dialog_run.cpp's CreateDCW); asking for a
 * second device here would be a second place for the DEVMODE to be dropped.
 * What comes back is the ANSWER, not the device. */
int spdf_win_print_classic_dialog(HWND parent, int page_count, spdf_win_print_request* req, DEVMODEW** devmode) {
    PRINTDLGW pd;
    DEVNAMES* names;
    DEVMODEW* dm;
    size_t bytes;

    if (!req || !devmode || page_count <= 0) return 0;
    memset(&pd, 0, sizeof(pd));
    pd.lStructSize = sizeof(pd);
    pd.hwndOwner = parent;
    /* PD_NOSELECTION because a print here has no "selected pages" concept.
     * PD_USEDEVMODECOPIESANDCOLLATE is deliberately NOT set, so nCopies comes
     * back as a number this code can honour rather than as the driver's private
     * business -- the same choice spdf_win_print_run_job() already assumes. */
    pd.Flags = PD_ALLPAGES | PD_NOSELECTION | PD_HIDEPRINTTOFILE;
    pd.nFromPage = (WORD)(req->range == SPDF_WIN_PRINT_RANGE_FROM_TO && req->from >= 1 ? req->from : 1);
    pd.nToPage = (WORD)(req->range == SPDF_WIN_PRINT_RANGE_FROM_TO && req->to >= 1 ? req->to : page_count);
    pd.nMinPage = 1;
    pd.nMaxPage = (WORD)(page_count > 0xFFFF ? 0xFFFF : page_count);
    pd.nCopies = (WORD)(req->copies > 0 ? req->copies : 1);
    if (!PrintDlgW(&pd)) {
        /* Cancel and "could not be shown" are the same answer to the caller:
         * its own dialog is still on screen and still works. */
        if (pd.hDevMode) GlobalFree(pd.hDevMode);
        if (pd.hDevNames) GlobalFree(pd.hDevNames);
        return 0;
    }

    /* The printer's name lives at an OFFSET INTO the DEVNAMES block, in wchar_t
     * units from its start -- not at a pointer. */
    names = pd.hDevNames ? (DEVNAMES*)GlobalLock(pd.hDevNames) : NULL;
    if (names) {
        wcsncpy_s(req->printer, SPDF_WIN_PRINT_NAME_MAX, (const wchar_t*)names + names->wDeviceOffset, _TRUNCATE);
        GlobalUnlock(pd.hDevNames);
    }
    dm = pd.hDevMode ? (DEVMODEW*)GlobalLock(pd.hDevMode) : NULL;
    if (dm) {
        bytes = (size_t)dm->dmSize + (size_t)dm->dmDriverExtra;
        free(*devmode);
        *devmode = (DEVMODEW*)malloc(bytes);
        if (*devmode) memcpy(*devmode, dm, bytes);
        GlobalUnlock(pd.hDevMode);
    }
    /* PD_PAGENUMS is what the dialog sets when the reader typed a range. The
     * radio they did not choose leaves nFromPage/nToPage at whatever went in,
     * so reading them unconditionally would silently narrow an all-pages job. */
    if (pd.Flags & PD_PAGENUMS) {
        req->range = SPDF_WIN_PRINT_RANGE_FROM_TO;
        req->from = (int)pd.nFromPage;
        req->to = (int)pd.nToPage;
    } else {
        req->range = SPDF_WIN_PRINT_RANGE_ALL;
    }
    req->copies = pd.nCopies > 0 ? (int)pd.nCopies : 1;
    if (pd.hDC) DeleteDC(pd.hDC); /* not asked for, but a driver may hand one over */
    if (pd.hDevMode) GlobalFree(pd.hDevMode);
    if (pd.hDevNames) GlobalFree(pd.hDevNames);
    return req->printer[0] != L'\0';
}
