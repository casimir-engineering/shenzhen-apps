/* print_dialog_probe.c — WHY DOES WINDOWS' PRINT DIALOG NEVER OPEN HERE?
 *
 * NOT A SUITE CASE, AND THE FILENAME SAYS SO. run-tests-native.sh discovers
 * `*_test.c` and RUNS it; this file calls comdlg32 entry points that are
 * measured to hang forever on this host, so the glob must not match it. Build
 * and run it by hand, ALWAYS UNDER A TIMEOUT:
 *
 *   portable\win\build-native.cmd print_dialog_probe portable/win/tests/print_dialog_probe.c
 *   %SPDF_OUT%\print_dialog_probe.exe <scenario> [options]
 *
 * HOW IT AVOIDS BEING A HANG ITSELF -- the same shape as the watchdog that
 * shipped in spdf_win_print_dialog.cpp because of what this measured. The
 * comdlg32 call goes on a worker thread with its own apartment and its own
 * message pump; the MAIN thread only watches, enumerating this process's own
 * top-level windows every 250 ms. So a scenario answers two questions a plain
 * synchronous call conflates -- did the call RETURN, and did a WINDOW appear --
 * and the exit code says which: 0 returned, 10 deadline with NO window of ours
 * (the hang), 11 deadline with a window (an ordinary modal dialog waiting for a
 * human), 64 bad usage, 65 the scenario could not be set up.
 *
 * SCENARIOS, one variable each. What each one ANSWERED here is the table in
 * portable/docs/windows-print-dialog.md; the short version is that only `ex`
 * hangs.
 *   returndefault  PrintDlgW PD_RETURNDEFAULT: the default printer's DEVMODE,
 *                  no UI. If this returns and the others do not, comdlg32
 *                  loaded and ran and only the showing is broken.
 *   classic        PrintDlgW PD_RETURNDC|PD_NOPAGENUMS, no page ranges.
 *   setup          PrintDlgW PD_PRINTSETUP: the old Print Setup sheet.
 *   pagesetup      PageSetupDlgW, comdlg32's OTHER printing dialog, which does
 *                  not go through the Windows 11 print experience.
 *   ex             PrintDlgExW with spdf_win_print.cpp's own flags.
 *   docprops       DocumentPropertiesW DM_IN_PROMPT: the DRIVER's own property
 *                  sheet without comdlg32. Whether it opens decides whether the
 *                  in-app dialog can have a Properties button at all.
 *
 * OPTIONS. --com=sta|mta|none picks the worker's apartment (default sta, which
 * is what the app's main thread is: spdf_win_d2d.cpp CoInitializeEx
 * COINIT_APARTMENTTHREADED, never uninitialized). --owner puts a visible
 * window on the WORKER thread and hands it over; --owner-main puts it on the
 * MAIN thread, which goes on pumping while the worker sits in the call;
 * --window-noowner makes that same window and passes NULL, so the only
 * difference between the two is the hwndOwner field. --nopump leaves the worker
 * out of the message system. --actctx=v6 activates a Common Controls 6 context
 * around the call, which the app has from its manifest and this unmanifested
 * probe otherwise does not. --dpi=pmv2|system|unaware sets process DPI
 * awareness (default: untouched). --printer=NAME overrides the default printer,
 * --seconds=N the 8 s deadline, --exflags=0xN PrintDlgEx's Flags (default
 * 0x00800104). --drive=ok|cancel makes the WATCHER press that button on our own
 * #32770 once it has settled: a dialog nobody can dismiss is worth no more than
 * one that never opens, so this is what proves the classic PrintDlgW RETURNS,
 * with the DC PD_RETURNDC asked for, and not merely that it appears.
 */
#include <windows.h>

#include <commdlg.h>
#include <winspool.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "winspool.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "kernel32.lib")

typedef enum probe_com { PROBE_COM_STA = 0, PROBE_COM_MTA = 1, PROBE_COM_NONE = 2 } probe_com;

typedef struct probe_opts {
    const char* scenario;
    probe_com com;
    const char* dpi;   /* NULL leaves the process alone */
    int owner;         /* 0 none, 1 worker-thread window, 3 main-thread window as owner,
                        * 4 main-thread window exists and is NOT handed over */
    int pump;
    int actctx_v6;
    int drive; /* 0 none, IDOK or IDCANCEL: the watcher presses it */
    int seconds;
    DWORD ex_flags;
    wchar_t printer[256];
} probe_opts;

typedef struct probe_result {
    probe_opts opts;
    volatile LONG entered;  /* the worker reached the call */
    volatile LONG returned; /* ...and came back */
    volatile LONG ok;
    volatile LONG last_error;
    volatile LONG hresult;
    volatile LONG got_dc;
    HWND owner;
} probe_result;

static void say(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(stdout, fmt, args);
    va_end(args);
    fputc('\n', stdout);
    fflush(stdout);
}

/* --- the watcher: this process's own top-level windows -------------------- */

#define PROBE_MAX_SEEN 64

typedef struct probe_walk {
    HWND hwnd[PROBE_MAX_SEEN];
    int count;
    int announced;
} probe_walk;

static BOOL CALLBACK probe_enum_proc(HWND hwnd, LPARAM param) {
    probe_walk* walk = (probe_walk*)param;
    DWORD pid = 0;
    wchar_t cls[128] = L"", title[128] = L"";
    int i;

    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    for (i = 0; i < walk->count; ++i)
        if (walk->hwnd[i] == hwnd) return TRUE;
    if (walk->count < PROBE_MAX_SEEN) walk->hwnd[walk->count++] = hwnd;
    GetClassNameW(hwnd, cls, 128);
    GetWindowTextW(hwnd, title, 128);
    say("  window  hwnd=%p class=%ls visible=%d title=\"%ls\"", (void*)hwnd, cls, IsWindowVisible(hwnd) ? 1 : 0,
        title);
    walk->announced++;
    return TRUE;
}

static int probe_scan(probe_walk* walk) {
    walk->announced = 0;
    EnumWindows(probe_enum_proc, (LPARAM)walk);
    return walk->announced;
}

/* --- pressing a button on our own dialog, for --drive --------------------- */

static HWND g_found_dialog;

static BOOL CALLBACK probe_find_dlg(HWND hwnd, LPARAM param) {
    DWORD pid = 0;
    wchar_t cls[64] = L"";
    (void)param;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd)) return TRUE;
    GetClassNameW(hwnd, cls, 64);
    /* #32770 is the system dialog class; the probe's own owner window has a
     * class of its own, so there is nothing else of ours to confuse it with. */
    if (wcscmp(cls, L"#32770") != 0) return TRUE;
    g_found_dialog = hwnd;
    return FALSE;
}

/* WM_COMMAND rather than a synthesised click: a click needs the dialog focused
 * and the cursor moved, and the dialog's own button sends exactly this. */
static int probe_press(int id) {
    g_found_dialog = NULL;
    EnumWindows(probe_find_dlg, 0);
    if (!g_found_dialog) return 0;
    say("watcher pressing %s on %p", id == IDOK ? "OK" : "Cancel", (void*)g_found_dialog);
    PostMessageW(g_found_dialog, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), (LPARAM)GetDlgItem(g_found_dialog, id));
    return 1;
}

/* --- an owner window, when one is asked for ------------------------------- */

static const wchar_t* k_probe_class = L"SpdfPrintDialogProbeOwner";

static LRESULT CALLBACK probe_owner_proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(h, m, w, l); }

static HWND probe_make_owner(void) {
    WNDCLASSEXW cls;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = probe_owner_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    cls.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    cls.lpszClassName = k_probe_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
    return CreateWindowExW(0, k_probe_class, L"probe owner", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, 420, 200, NULL,
                           NULL, GetModuleHandleW(NULL), NULL);
}

/* --- Common Controls 6, which this unmanifested binary otherwise lacks ---- */

static const char* k_v6_manifest =
    "<assembly xmlns='urn:schemas-microsoft-com:asm.v1' manifestVersion='1.0'>"
    "<assemblyIdentity type='win32' name='SpdfPrintDialogProbe' version='1.0.0.0'/>"
    "<dependency><dependentAssembly><assemblyIdentity type='win32'"
    " name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*'"
    " publicKeyToken='6595b64144ccf1df' language='*'/></dependentAssembly></dependency></assembly>";

static HANDLE probe_v6_context(void) {
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    ACTCTXW ctx;
    HANDLE h;
    FILE* f = NULL;

    if (!GetTempPathW(MAX_PATH, dir)) return NULL;
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%sspdf-probe-v6-%lu.manifest", dir, (unsigned long)GetCurrentProcessId());
    if (_wfopen_s(&f, path, L"wb") != 0 || !f) return NULL;
    fwrite(k_v6_manifest, 1, strlen(k_v6_manifest), f);
    fclose(f);
    memset(&ctx, 0, sizeof(ctx));
    ctx.cbSize = sizeof(ctx);
    ctx.lpSource = path;
    h = CreateActCtxW(&ctx);
    if (h == INVALID_HANDLE_VALUE) {
        say("setup   CreateActCtxW failed, error %lu", GetLastError());
        return NULL;
    }
    return h;
}

/* --- the scenarios -------------------------------------------------------- */

static void scenario_print_dlg(probe_result* r, DWORD flags) {
    PRINTDLGW pd;
    memset(&pd, 0, sizeof(pd));
    pd.lStructSize = sizeof(pd);
    pd.hwndOwner = r->owner;
    pd.Flags = flags;
    pd.nCopies = 1;
    pd.nFromPage = pd.nToPage = pd.nMinPage = pd.nMaxPage = 1;
    say("worker  calling PrintDlgW flags=0x%08lX owner=%p", (unsigned long)flags, (void*)r->owner);
    InterlockedExchange(&r->entered, 1);
    if (PrintDlgW(&pd)) InterlockedExchange(&r->ok, 1);
    InterlockedExchange(&r->last_error, (LONG)CommDlgExtendedError());
    if (pd.hDC) InterlockedExchange(&r->got_dc, 1);
    InterlockedExchange(&r->returned, 1);
    if (pd.hDC) {
        /* Exactly what spdf_win_print_paper_from_caps() reads, so a returned
         * dialog is distinguishable from one that handed back nothing usable. */
        say("worker  hDC dpi=%dx%d res=%dx%d", GetDeviceCaps(pd.hDC, LOGPIXELSX), GetDeviceCaps(pd.hDC, LOGPIXELSY),
            GetDeviceCaps(pd.hDC, HORZRES), GetDeviceCaps(pd.hDC, VERTRES));
        DeleteDC(pd.hDC);
    }
    if (pd.hDevMode) GlobalFree(pd.hDevMode);
    if (pd.hDevNames) GlobalFree(pd.hDevNames);
}

static void scenario_print_dlg_ex(probe_result* r) {
    PRINTDLGEXW pd;
    PRINTPAGERANGE ranges[16];
    HRESULT hr;
    memset(&pd, 0, sizeof(pd));
    memset(ranges, 0, sizeof(ranges));
    pd.lStructSize = sizeof(pd);
    pd.hwndOwner = r->owner;
    pd.Flags = r->opts.ex_flags ? r->opts.ex_flags : (PD_RETURNDC | PD_NOSELECTION | PD_NOCURRENTPAGE);
    pd.nStartPage = START_PAGE_GENERAL;
    pd.nMinPage = 1;
    pd.nMaxPage = 4;
    pd.nCopies = 1;
    pd.nMaxPageRanges = (DWORD)(sizeof(ranges) / sizeof(ranges[0]));
    pd.lpPageRanges = ranges;
    say("worker  calling PrintDlgExW flags=0x%08lX owner=%p", (unsigned long)pd.Flags, (void*)r->owner);
    InterlockedExchange(&r->entered, 1);
    hr = PrintDlgExW(&pd);
    InterlockedExchange(&r->hresult, (LONG)hr);
    if (SUCCEEDED(hr) && pd.dwResultAction == PD_RESULT_PRINT) InterlockedExchange(&r->ok, 1);
    InterlockedExchange(&r->returned, 1);
    if (pd.hDC) DeleteDC(pd.hDC);
    if (pd.hDevMode) GlobalFree(pd.hDevMode);
    if (pd.hDevNames) GlobalFree(pd.hDevNames);
}

static void scenario_page_setup(probe_result* r) {
    PAGESETUPDLGW ps;
    memset(&ps, 0, sizeof(ps));
    ps.lStructSize = sizeof(ps);
    ps.hwndOwner = r->owner;
    say("worker  calling PageSetupDlgW owner=%p", (void*)r->owner);
    InterlockedExchange(&r->entered, 1);
    if (PageSetupDlgW(&ps)) InterlockedExchange(&r->ok, 1);
    InterlockedExchange(&r->last_error, (LONG)CommDlgExtendedError());
    InterlockedExchange(&r->returned, 1);
    if (ps.hDevMode) GlobalFree(ps.hDevMode);
    if (ps.hDevNames) GlobalFree(ps.hDevNames);
}

/* The driver's own property sheet: OpenPrinterW + DocumentPropertiesW with
 * DM_IN_PROMPT. Not comdlg32, and the only documented way to reach printer
 * preferences when the print dialog cannot be shown. */
static void scenario_doc_props(probe_result* r) {
    HANDLE printer = NULL;
    DEVMODEW* dm;
    LONG bytes, rc;

    if (!OpenPrinterW(r->opts.printer, &printer, NULL)) {
        say("worker  OpenPrinterW failed, error %lu", GetLastError());
        InterlockedExchange(&r->returned, 1);
        return;
    }
    bytes = DocumentPropertiesW(NULL, printer, r->opts.printer, NULL, NULL, 0);
    if (bytes <= 0) {
        say("worker  DocumentPropertiesW sizing failed, error %lu", GetLastError());
        ClosePrinter(printer);
        InterlockedExchange(&r->returned, 1);
        return;
    }
    dm = (DEVMODEW*)calloc(1, (size_t)bytes);
    if (!dm || DocumentPropertiesW(NULL, printer, r->opts.printer, dm, NULL, DM_OUT_BUFFER) != IDOK) {
        say("worker  DM_OUT_BUFFER failed, error %lu", GetLastError());
        free(dm);
        ClosePrinter(printer);
        InterlockedExchange(&r->returned, 1);
        return;
    }
    say("worker  calling DocumentPropertiesW DM_IN_PROMPT on \"%ls\" owner=%p", r->opts.printer, (void*)r->owner);
    InterlockedExchange(&r->entered, 1);
    rc = DocumentPropertiesW(r->owner, printer, r->opts.printer, dm, dm, DM_IN_BUFFER | DM_IN_PROMPT | DM_OUT_BUFFER);
    say("worker  DM_IN_PROMPT returned %ld (IDOK=%d IDCANCEL=%d) error=%lu", rc, IDOK, IDCANCEL, GetLastError());
    if (rc == IDOK) InterlockedExchange(&r->ok, 1);
    InterlockedExchange(&r->returned, 1);
    free(dm);
    ClosePrinter(printer);
}

/* --- the worker ----------------------------------------------------------- */

static DWORD WINAPI probe_worker(LPVOID param) {
    probe_result* r = (probe_result*)param;
    const char* s = r->opts.scenario;
    HANDLE actctx = NULL;
    ULONG_PTR cookie = 0;
    HRESULT co = S_OK;

    if (r->opts.com == PROBE_COM_STA) co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    else if (r->opts.com == PROBE_COM_MTA) co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    say("worker  tid=%lu com=%s hr=0x%08lX", GetCurrentThreadId(),
        r->opts.com == PROBE_COM_STA ? "sta" : r->opts.com == PROBE_COM_MTA ? "mta" : "none", (unsigned long)co);

    /* A message queue before anything else, so a cross-thread SendMessage from
     * the print experience has somewhere to land. */
    if (r->opts.pump) {
        MSG msg;
        PeekMessageW(&msg, NULL, 0, 0, PM_NOREMOVE);
    }
    if (r->opts.actctx_v6) {
        actctx = probe_v6_context();
        if (actctx && !ActivateActCtx(actctx, &cookie)) say("worker  ActivateActCtx failed, error %lu", GetLastError());
        else if (actctx) say("worker  Common Controls 6 context activated");
    }
    if (r->opts.owner == 1) {
        r->owner = probe_make_owner();
        say("worker  owner window %p on this thread", (void*)r->owner);
    }

    if (strcmp(s, "returndefault") == 0) scenario_print_dlg(r, PD_RETURNDEFAULT);
    else if (strcmp(s, "classic") == 0) scenario_print_dlg(r, PD_RETURNDC | PD_NOPAGENUMS | PD_NOSELECTION);
    else if (strcmp(s, "setup") == 0) scenario_print_dlg(r, PD_PRINTSETUP);
    else if (strcmp(s, "pagesetup") == 0) scenario_page_setup(r);
    else if (strcmp(s, "ex") == 0) scenario_print_dlg_ex(r);
    else if (strcmp(s, "docprops") == 0) scenario_doc_props(r);
    else {
        say("worker  unknown scenario \"%s\"", s);
        InterlockedExchange(&r->returned, 1);
    }

    if (cookie) DeactivateActCtx(0, cookie);
    if (actctx) ReleaseActCtx(actctx);
    if (r->opts.com != PROBE_COM_NONE && SUCCEEDED(co)) CoUninitialize();
    return 0;
}

static void probe_set_dpi(const char* which) {
    typedef DPI_AWARENESS_CONTEXT(WINAPI * set_ctx)(DPI_AWARENESS_CONTEXT);
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    set_ctx fn = u32 ? (set_ctx)GetProcAddress(u32, "SetProcessDpiAwarenessContext") : NULL;
    DPI_AWARENESS_CONTEXT ctx = strcmp(which, "pmv2") == 0   ? DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
                                : strcmp(which, "system") == 0 ? DPI_AWARENESS_CONTEXT_SYSTEM_AWARE
                                                               : DPI_AWARENESS_CONTEXT_UNAWARE;
    if (fn) say("setup   dpi=%s applied=%d", which, fn(ctx) ? 1 : 0);
}

int main(int argc, char** argv) {
    probe_result r;
    probe_opts* o;
    probe_walk seen;
    HANDLE thread;
    DWORD deadline, waited = 0;
    int windows = 0, i, code;

    memset(&r, 0, sizeof(r));
    memset(&seen, 0, sizeof(seen));
    o = &r.opts;
    o->com = PROBE_COM_STA;
    o->pump = 1;
    o->seconds = 8;

    if (argc < 2) {
        say("usage: print_dialog_probe <returndefault|classic|setup|pagesetup|ex|docprops> [options]");
        say("       --com=sta|mta|none --owner --owner-main --window-noowner --nopump");
        say("       --actctx=v6 --dpi=pmv2|system|unaware --printer=NAME --seconds=N --exflags=0xN --drive=ok|cancel");
        return 64;
    }
    o->scenario = argv[1];
    for (i = 2; i < argc; ++i) {
        const char* a = argv[i];
        if (strncmp(a, "--com=", 6) == 0) {
            const char* v = a + 6;
            o->com = strcmp(v, "mta") == 0 ? PROBE_COM_MTA : strcmp(v, "none") == 0 ? PROBE_COM_NONE : PROBE_COM_STA;
        } else if (strncmp(a, "--dpi=", 6) == 0) o->dpi = a + 6;
        else if (strcmp(a, "--owner") == 0) o->owner = 1;
        else if (strcmp(a, "--owner-main") == 0) o->owner = 3;
        else if (strcmp(a, "--window-noowner") == 0) o->owner = 4;
        else if (strcmp(a, "--nopump") == 0) o->pump = 0;
        else if (strcmp(a, "--actctx=v6") == 0) o->actctx_v6 = 1;
        else if (strncmp(a, "--drive=", 8) == 0) o->drive = strcmp(a + 8, "ok") == 0 ? IDOK : IDCANCEL;
        else if (strncmp(a, "--printer=", 10) == 0)
            MultiByteToWideChar(CP_UTF8, 0, a + 10, -1, o->printer, 256);
        else if (strncmp(a, "--seconds=", 10) == 0) o->seconds = atoi(a + 10) < 1 ? 1 : atoi(a + 10);
        else if (strncmp(a, "--exflags=", 10) == 0) o->ex_flags = (DWORD)strtoul(a + 10, NULL, 0);
        else {
            say("unknown option \"%s\"", a);
            return 64;
        }
    }

    say("probe   scenario=%s pid=%lu", o->scenario, GetCurrentProcessId());
    if (o->dpi) probe_set_dpi(o->dpi);
    if (!o->printer[0]) {
        DWORD n = 256;
        if (!GetDefaultPrinterW(o->printer, &n)) {
            say("setup   no default printer -- nothing to open a dialog for");
            return 65;
        }
    }
    say("setup   printer \"%ls\"", o->printer);

    /* A main-thread window, which keeps pumping below: --owner-main hands it
     * over, --window-noowner makes the same window and does not, so the only
     * difference between them is the hwndOwner field. */
    if (o->owner == 3 || o->owner == 4) {
        HWND w = probe_make_owner();
        if (!w) return 65;
        if (o->owner == 3) r.owner = w;
        say("setup   window %p on the main thread; passed as owner=%d", (void*)w, o->owner == 3 ? 1 : 0);
    }

    thread = CreateThread(NULL, 0, probe_worker, &r, 0, NULL);
    if (!thread) {
        say("setup   CreateThread failed, error %lu", GetLastError());
        return 65;
    }

    deadline = (DWORD)o->seconds * 1000u;
    while (waited < deadline) {
        DWORD w;
        if (o->owner == 3 || o->owner == 4) {
            /* The owner's thread must stay responsive: a SendMessage from
             * another thread is only serviced by a thread in the message
             * system, so this wait pumps rather than sleeping. */
            MSG msg;
            w = MsgWaitForMultipleObjects(1, &thread, FALSE, 250, QS_ALLINPUT);
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        } else {
            w = WaitForSingleObject(thread, 250);
        }
        if (w == WAIT_OBJECT_0) {
            windows += probe_scan(&seen);
            say("result  scenario=%s RETURNED entered=%ld ok=%ld dc=%ld commdlgerr=0x%lX hr=0x%08lX windows=%d",
                o->scenario, r.entered, r.ok, r.got_dc, (unsigned long)r.last_error, (unsigned long)r.hresult,
                windows);
            CloseHandle(thread);
            return 0;
        }
        waited += 250;
        windows += probe_scan(&seen);
        /* Once, after the dialog has had time to settle: a second press would
         * land on whatever came after it. */
        if (o->drive && waited >= 1500 && r.entered && !r.returned && probe_press(o->drive)) o->drive = 0;
    }

    /* Deadline. The worker is still inside the call and is NOT terminated:
     * TerminateThread on a thread holding the loader lock or a COM apartment
     * corrupts the process, and this probe's whole job is to report honestly.
     * That constraint is exactly why the shipping watchdog abandons its thread
     * too (spdf_win_print_dialog.cpp). */
    code = windows > 0 ? 11 : 10;
    say("result  scenario=%s HUNG entered=%ld returned=%ld windows=%d after=%lums", o->scenario, r.entered, r.returned,
        windows, (unsigned long)waited);
    say("result  %s", code == 10 ? "NO window of ours ever existed -- the dialog was never created"
                                 : "a window DID appear and the call still had not returned");
    fflush(stdout);
    /* Not a return from main: the CRT's exit can wait on the abandoned thread.
     * TerminateProcess on ourselves is the one clean way out. */
    TerminateProcess(GetCurrentProcess(), (UINT)code);
    return code;
}
