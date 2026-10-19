/* open_dialog_probe.cpp — DOES THE SHELL'S OPEN DIALOG RENDER, AND WHAT BREAKS IT?
 *
 * NOT A SUITE CASE, AND THE FILENAME SAYS SO: run-tests-native.sh discovers
 * `*_test.c` and runs it. Build and run this one by hand:
 *
 *   portable\win\build-native.cmd open_dialog_probe portable/win/tests/open_dialog_probe.cpp
 *   %SPDF_OUT%\open_dialog_probe.exe [options]
 *
 * WHAT IT MEASURES. `IFileOpenDialog::Show` on the MAIN thread, exactly as
 * spdf_win_menu_open_dialog_in() calls it, while a WATCHER thread finds the
 * resulting `#32770` and captures its CLIENT area off the screen. A dialog that
 * rendered has hundreds of distinct colours and almost no flat white; the defect
 * this probe was written for is 13 colours and 77% near-white -- every child
 * window erased and none of them painted. The watcher then closes the dialog, so
 * the probe never needs a human.
 *
 * Exit codes: 0 rendered, 1 blank, 10 no dialog ever appeared, 64 bad usage,
 * 65 could not be set up, 68 no usable desktop (nothing is composited).
 *
 * OPTIONS, one app ingredient each, so the difference between two runs is one
 * thing:
 *   --dpi=pmv2|system|unaware  process DPI awareness (default untouched; the
 *                              app's manifest says PerMonitorV2)
 *   --actctx=v6                activate Common Controls 6 around the call, which
 *                              the app has from its manifest and this
 *                              unmanifested probe otherwise does not
 *   --darkmode=N               uxtheme ordinal 135 SetPreferredAppMode(N) +
 *                              FlushMenuThemes, as spdf_win_enable_dark_menus()
 *                              does with N=1
 *   --owner                    a plain WS_OVERLAPPEDWINDOW owner
 *   --owner-frame              an owner with the app's frame: WM_NCCALCSIZE
 *                              giving the top back so the caption is client
 *   --d2d / --d2d-multi        a live ID2D1HwndRenderTarget on the owner, from a
 *                              SINGLE_ or MULTI_THREADED factory, with a frame
 *                              drawn -- what spdf_win_window.cpp leaves behind
 *   --from-wndproc             pump first, then open the dialog from INSIDE a
 *                              window-procedure dispatch, as a click or a Ctrl+O
 *                              handler does
 *   --com=sta|mta|none         the calling thread's apartment (default sta)
 *   --seconds=N                how long to let the dialog settle (default 4)
 *
 * WHAT IT ANSWERED (2026-09-07, windows-native-observations.md 20). EVERY
 * combination above RENDERS -- 219-523 distinct colours, 0% near-white. That is
 * the finding: none of the app's ingredients breaks this dialog, so the fault was
 * not in how the port asks for it. It was our own window proc pinning the UI
 * thread in a WM_MOUSELEAVE loop, which starved the WM_PAINT the shell was
 * waiting to be asked for. Keep this probe: the next time the dialog misbehaves,
 * the first question is again "is it us or the machine", and one run of the bare
 * probe answers it.
 */
#include <windows.h>

#include <shobjidl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <d2d1.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "d2d1.lib")

namespace {

int g_seconds = 4;
volatile LONG g_distinct = -1;
volatile LONG g_white = -1;
volatile LONG g_found = 0;

void say(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

/* --- what the screen shows inside a window's client area ------------------ */

/* Distinct colours and the near-white fraction of `hwnd`'s client rect, taken
 * off the SCREEN -- what a person sees, not what the window would draw if
 * asked. Every fourth pixel in each direction: enough to separate "hundreds of
 * colours" from "a dozen flat rectangles" at a fraction of the cost. */
int measure_client(HWND hwnd, int* out_distinct, int* out_white_pct) {
    RECT c;
    POINT origin = {0, 0};
    HDC screen, mem;
    HBITMAP bmp, old;
    BITMAPINFO bi;
    int w, h, x, y, total = 0, white = 0, distinct = 0;
    unsigned char* seen;
    unsigned* pixels;

    if (!GetClientRect(hwnd, &c) || !ClientToScreen(hwnd, &origin)) return 0;
    w = c.right - c.left;
    h = c.bottom - c.top;
    if (w < 40 || h < 40) return 0;

    screen = GetDC(NULL);
    if (!screen) return 0;
    mem = CreateCompatibleDC(screen);
    bmp = CreateCompatibleBitmap(screen, w, h);
    if (!mem || !bmp) {
        if (bmp) DeleteObject(bmp);
        if (mem) DeleteDC(mem);
        ReleaseDC(NULL, screen);
        return 0;
    }
    old = (HBITMAP)SelectObject(mem, bmp);
    BitBlt(mem, 0, 0, w, h, screen, origin.x, origin.y, SRCCOPY);
    SelectObject(mem, old);

    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    pixels = (unsigned*)calloc((size_t)w * (size_t)h, sizeof(unsigned));
    /* 4096 buckets over the top bits of each channel: a hash big enough that
     * "a dozen flat rectangles" and "a themed dialog" never collide into the
     * same answer, and small enough to sit on the stack of the caller's heap. */
    seen = (unsigned char*)calloc(4096, 1);
    if (pixels && seen && GetDIBits(mem, bmp, 0, (UINT)h, pixels, &bi, DIB_RGB_COLORS)) {
        for (y = 0; y < h; y += 4)
            for (x = 0; x < w; x += 4) {
                unsigned p = pixels[(size_t)y * (size_t)w + (size_t)x];
                int r = (int)((p >> 16) & 0xFF), g = (int)((p >> 8) & 0xFF), b = (int)(p & 0xFF);
                int key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
                ++total;
                if (r > 245 && g > 245 && b > 245) ++white;
                if (!seen[key]) {
                    seen[key] = 1;
                    ++distinct;
                }
            }
    }
    free(pixels);
    free(seen);
    DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);
    if (!total) return 0;
    *out_distinct = distinct;
    *out_white_pct = white * 100 / total;
    return 1;
}

/* --- the watcher: find our dialog, measure it, close it ------------------- */

HWND g_dialog;

BOOL CALLBACK find_dialog(HWND hwnd, LPARAM param) {
    DWORD pid = 0;
    wchar_t cls[64] = L"";
    (void)param;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd)) return TRUE;
    GetClassNameW(hwnd, cls, 64);
    if (wcscmp(cls, L"#32770") != 0) return TRUE;
    g_dialog = hwnd;
    return FALSE;
}

DWORD WINAPI watcher(LPVOID param) {
    int waited = 0;
    int distinct = 0, white = 0;
    (void)param;
    /* Let the dialog be created AND settle: the shell lays the item dialog out
     * in several passes and a measurement taken mid-layout says nothing. */
    while (waited < g_seconds * 1000) {
        Sleep(250);
        waited += 250;
        g_dialog = NULL;
        EnumWindows(find_dialog, 0);
        if (g_dialog) InterlockedExchange(&g_found, 1);
    }
    if (!g_dialog) return 0;
    if (measure_client(g_dialog, &distinct, &white)) {
        InterlockedExchange(&g_distinct, distinct);
        InterlockedExchange(&g_white, white);
    }
    PostMessageW(g_dialog, WM_CLOSE, 0, 0);
    return 0;
}

/* --- the ingredients ----------------------------------------------------- */

void set_dpi(const char* which) {
    typedef DPI_AWARENESS_CONTEXT(WINAPI * set_ctx)(DPI_AWARENESS_CONTEXT);
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    set_ctx fn = u32 ? (set_ctx)GetProcAddress(u32, "SetProcessDpiAwarenessContext") : NULL;
    DPI_AWARENESS_CONTEXT ctx = strcmp(which, "pmv2") == 0     ? DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
                                : strcmp(which, "system") == 0 ? DPI_AWARENESS_CONTEXT_SYSTEM_AWARE
                                                               : DPI_AWARENESS_CONTEXT_UNAWARE;
    if (fn) say("setup   dpi=%s applied=%d", which, fn(ctx) ? 1 : 0);
}

void set_dark_mode(int mode) {
    typedef int(WINAPI * set_mode_fn)(int);
    typedef void(WINAPI * flush_fn)(void);
    HMODULE ux = LoadLibraryW(L"uxtheme.dll");
    set_mode_fn set_mode = ux ? (set_mode_fn)GetProcAddress(ux, (LPCSTR)135) : NULL;
    flush_fn flush = ux ? (flush_fn)GetProcAddress(ux, (LPCSTR)136) : NULL;
    if (!set_mode) {
        say("setup   uxtheme ordinal 135 not found");
        return;
    }
    say("setup   SetPreferredAppMode(%d) previous=%d", mode, set_mode(mode));
    if (flush) flush();
}

const char* k_v6_manifest =
    "<assembly xmlns='urn:schemas-microsoft-com:asm.v1' manifestVersion='1.0'>"
    "<assemblyIdentity type='win32' name='SpdfOpenDialogProbe' version='1.0.0.0'/>"
    "<dependency><dependentAssembly><assemblyIdentity type='win32'"
    " name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*'"
    " publicKeyToken='6595b64144ccf1df' language='*'/></dependentAssembly></dependency></assembly>";

HANDLE v6_context(void) {
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    ACTCTXW ctx;
    HANDLE h;
    FILE* f = NULL;
    if (!GetTempPathW(MAX_PATH, dir)) return NULL;
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%sspdf-opendlg-v6-%lu.manifest", dir,
                 (unsigned long)GetCurrentProcessId());
    if (_wfopen_s(&f, path, L"wb") != 0 || !f) return NULL;
    fwrite(k_v6_manifest, 1, strlen(k_v6_manifest), f);
    fclose(f);
    memset(&ctx, 0, sizeof(ctx));
    ctx.cbSize = sizeof(ctx);
    ctx.lpSource = path;
    h = CreateActCtxW(&ctx);
    return h == INVALID_HANDLE_VALUE ? NULL : h;
}

/* THE APP CALLS Show() FROM INSIDE A WINDOW-PROCEDURE DISPATCH -- a click or a
 * Ctrl+O handler -- after its own message loop has been running. This runs the
 * same call from the same place: a pump, a posted WM_APP, and the dialog opened
 * inside the handler. */
IFileOpenDialog* g_pending_dialog;
HWND g_pending_owner;
HRESULT g_pending_hr = E_FAIL;
volatile LONG g_pending_done;

/* An owner window, plain or with the app's frame. THE APP'S FRAME is the
 * interesting one: spdf_win_window_frame.h answers WM_NCCALCSIZE by giving the
 * whole top back, so the caption is client area the app draws itself. */
int g_owner_custom_frame;

LRESULT CALLBACK owner_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_APP + 7) {
        say("owner   inside the window procedure: calling Show(%p)", (void*)g_pending_owner);
        g_pending_hr = g_pending_dialog->Show(g_pending_owner);
        InterlockedExchange(&g_pending_done, 1);
        PostQuitMessage(0);
        return 0;
    }
    if (m == WM_NCCALCSIZE && w && g_owner_custom_frame) {
        NCCALCSIZE_PARAMS* p = (NCCALCSIZE_PARAMS*)l;
        RECT before = p->rgrc[0];
        DefWindowProcW(h, m, w, l);
        p->rgrc[0].top = before.top; /* the caption becomes client */
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

HWND make_owner(int custom_frame) {
    WNDCLASSEXW cls;
    g_owner_custom_frame = custom_frame;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = owner_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    cls.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    cls.lpszClassName = L"SpdfOpenDialogProbeOwner";
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
    return CreateWindowExW(0, cls.lpszClassName, L"probe owner", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 60, 60, 700, 460,
                           NULL, NULL, cls.hInstance, NULL);
}

} /* namespace */

int main(int argc, char** argv) {
    const char* dpi = NULL;
    int actctx_v6 = 0, dark_mode = -1, owner_kind = 0, com = 0, d2d_kind = 0, from_wndproc = 0, i;
    ID2D1Factory* factory = NULL;
    ID2D1HwndRenderTarget* target = NULL;
    HANDLE actctx = NULL, thread;
    ULONG_PTR cookie = 0;
    HWND owner = NULL;
    IFileOpenDialog* dialog = NULL;
    HRESULT hr, co = S_OK;
    static const COMDLG_FILTERSPEC types[] = {{L"Documents", L"*.pdf;*.xps;*.epub;*.md"},
                                              {L"PDF", L"*.pdf"},
                                              {L"All Files", L"*.*"}};

    for (i = 1; i < argc; ++i) {
        const char* a = argv[i];
        if (strncmp(a, "--dpi=", 6) == 0) dpi = a + 6;
        else if (strcmp(a, "--actctx=v6") == 0) actctx_v6 = 1;
        else if (strncmp(a, "--darkmode=", 11) == 0) dark_mode = atoi(a + 11);
        else if (strcmp(a, "--owner") == 0) owner_kind = 1;
        else if (strcmp(a, "--owner-frame") == 0) owner_kind = 2;
        else if (strcmp(a, "--from-wndproc") == 0) from_wndproc = 1;
        else if (strcmp(a, "--d2d") == 0) d2d_kind = 1;
        else if (strcmp(a, "--d2d-multi") == 0) d2d_kind = 2;
        else if (strncmp(a, "--com=", 6) == 0)
            com = strcmp(a + 6, "mta") == 0 ? 1 : strcmp(a + 6, "none") == 0 ? 2 : 0;
        else if (strncmp(a, "--seconds=", 10) == 0) g_seconds = atoi(a + 10) < 1 ? 1 : atoi(a + 10);
        else {
            say("usage: open_dialog_probe [--dpi=pmv2|system|unaware] [--actctx=v6] [--darkmode=N]");
            say("       [--owner|--owner-frame] [--d2d|--d2d-multi] [--com=sta|mta|none] [--seconds=N]");
            return 64;
        }
    }

    say("probe   pid=%lu", (unsigned long)GetCurrentProcessId());
    if (dpi) set_dpi(dpi);
    if (dark_mode >= 0) set_dark_mode(dark_mode);
    if (actctx_v6) {
        actctx = v6_context();
        if (actctx && ActivateActCtx(actctx, &cookie)) say("setup   Common Controls 6 activated");
        else if (actctx) say("setup   ActivateActCtx failed, error %lu", GetLastError());
    }
    if (com == 0) co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    else if (com == 1) co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    say("setup   com=%s hr=0x%08lX", com == 0 ? "sta" : com == 1 ? "mta" : "none", (unsigned long)co);
    if (owner_kind) {
        owner = make_owner(owner_kind == 2);
        if (!owner) return 65;
        say("setup   owner %p %s", (void*)owner, owner_kind == 2 ? "with the app's custom frame" : "plain");
    }

    /* THE APP'S GRAPHICS STACK, on this thread and on this window: a
     * MULTI_THREADED Direct2D factory and a live ID2D1HwndRenderTarget that has
     * drawn a frame, which is what spdf_win_window.cpp's ensure_target leaves
     * behind before any dialog is opened. */
    if (d2d_kind && owner) {
        RECT rc;
        GetClientRect(owner, &rc);
        hr = D2D1CreateFactory(d2d_kind == 2 ? D2D1_FACTORY_TYPE_MULTI_THREADED : D2D1_FACTORY_TYPE_SINGLE_THREADED,
                               &factory);
        if (SUCCEEDED(hr) && factory) {
            D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
                D2D1_RENDER_TARGET_TYPE_DEFAULT,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.0f, 96.0f);
            hr = factory->CreateHwndRenderTarget(
                props,
                D2D1::HwndRenderTargetProperties(owner, D2D1::SizeU((UINT32)(rc.right - rc.left),
                                                                    (UINT32)(rc.bottom - rc.top))),
                &target);
        }
        say("setup   d2d factory=%p target=%p hr=0x%08lX", (void*)factory, (void*)target, (unsigned long)hr);
        if (target) {
            target->BeginDraw();
            target->Clear(D2D1::ColorF(0.11f, 0.11f, 0.12f));
            say("setup   d2d first frame EndDraw hr=0x%08lX", (unsigned long)target->EndDraw());
        }
    }

    hr = CoCreateInstance(CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || !dialog) {
        say("setup   CoCreateInstance(CLSID_FileOpenDialog) failed hr=0x%08lX", (unsigned long)hr);
        return 65;
    }
    dialog->SetFileTypes((UINT)(sizeof(types) / sizeof(types[0])), types);
    dialog->SetFileTypeIndex(1);
    dialog->SetTitle(L"Open");
    {
        DWORD flags = 0;
        if (SUCCEEDED(dialog->GetOptions(&flags)))
            dialog->SetOptions(flags | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
    }

    thread = CreateThread(NULL, 0, watcher, NULL, 0, NULL);
    if (!thread) return 65;
    if (from_wndproc && owner) {
        /* Pump first, exactly as the app has been doing for seconds, and then
         * open the dialog from inside a dispatch. */
        MSG msg;
        DWORD until = GetTickCount() + 600;
        while (GetTickCount() < until) {
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            Sleep(15);
        }
        g_pending_dialog = dialog;
        g_pending_owner = owner;
        PostMessageW(owner, WM_APP + 7, 0, 0);
        while (GetMessageW(&msg, NULL, 0, 0) > 0) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        hr = g_pending_hr;
    } else {
        hr = dialog->Show(owner);
    }
    say("result  Show returned hr=0x%08lX", (unsigned long)hr);
    WaitForSingleObject(thread, 5000);
    CloseHandle(thread);
    dialog->Release();
    if (target) target->Release();
    if (factory) factory->Release();
    if (cookie) DeactivateActCtx(0, cookie);
    if (actctx) ReleaseActCtx(actctx);
    if (com != 2 && SUCCEEDED(co)) CoUninitialize();

    if (!g_found) {
        say("result  NO DIALOG ever appeared");
        return 10;
    }
    if (g_distinct < 0) {
        say("result  the dialog appeared but could not be captured -- no usable desktop?");
        return 68;
    }
    say("result  client distinct_colours=%ld near_white=%ld%%", g_distinct, g_white);
    /* THE THRESHOLD. Measured on this host: a dialog that rendered is 400-1300
     * distinct colours and under 5% near-white; the defect is 13 colours and
     * 77%. Anything in between is not a pass. */
    if (g_distinct >= 100 && g_white <= 20) {
        say("result  RENDERED");
        return 0;
    }
    say("result  BLANK -- the dialog is up and painted nothing");
    return 1;
}
