/* spdf_win_gpu_prewarm.h — create Direct2D's GPU device early, on a worker.
 *
 * THE COST THIS HIDES. The window's first WM_PAINT creates the
 * ID2D1HwndRenderTarget, and the first hardware render target a Direct2D
 * factory makes creates the factory's D3D device -- which maps and initialises
 * dxgi.dll, d3d11.dll and the vendor's user-mode driver. Measured with the
 * SPDF-LAUNCH timeline (portable/docs/windows-launch-performance.md): 80-117 ms
 * on this machine, the single largest item between process creation and the
 * first page, and it ran AFTER the window was already visible, so the reader
 * saw an empty frame for that long. Nothing before the first paint needs the
 * GPU, and nothing in session restore, spdf_open, page-0 measurement or
 * CreateWindowExW needs more than one core, so the two overlap here.
 *
 * HOW. Measured with the two probes recorded in the doc: a D3D11 device made
 * on a worker does NOT help -- Direct2D 1.0 still creates its own device for
 * its first hardware target (a second device on this driver costs 50-90 ms
 * even with the driver resident). But a factory shares its internal device
 * between ALL its hardware render targets, and with a MULTI_THREADED factory
 * that holds across threads: after a worker has created a throwaway
 * HwndRenderTarget on a hidden window of its own, the UI thread's real target
 * costs 0.4-0.5 ms instead of ~80. The real target is still created exactly as
 * before, on the UI thread, through the same call with the same properties, on
 * the same kind of device; only WHEN the device is created has moved. The first
 * frame's pixels are unchanged, which the d2d.compose-* cases pin.
 *
 * The dummy target is KEPT until finish(): releasing the last hardware target
 * lets the factory drop the device, which would be the same cost paid twice.
 * Its window belongs to the worker thread (DestroyWindow must run there), so
 * the thread parks until finish() and tears both down itself -- parks with
 * MsgWaitForMultipleObjects, dispatching what arrives, because a thread that
 * owns a window and stops pumping is a hung window to the whole desktop.
 *
 *   start(d2d): windowed path only, right after spdf_win_d2d_create(). The
 *          headless PNG paths must NOT call it: they draw through a software
 *          WIC target and would only wait for a driver load at exit.
 *   finish(): joins the worker; called from spdf_win_d2d_destroy() BEFORE the
 *          factory is released; a no-op when start() was never called.
 *
 * HEADER-ONLY, like spdf_win_launch_profile.h and for the same reason: every
 * test that links spdf_win_d2d.cpp lists its translation units by hand, and a
 * new .cpp would have to be added to each of those lists or the link fails.
 * The state is one __declspec(selectany) object shared by every TU; the
 * functions are static. Only C++ TUs get the implementation (it drives COM
 * vtables); a C TU that includes spdf_win_d2d.h sees the declarations alone
 * and never calls them. */
#ifndef SPDF_WIN_GPU_PREWARM_H
#define SPDF_WIN_GPU_PREWARM_H

#ifndef __cplusplus

/* Declarations only; the C tests that include spdf_win_d2d.h do not call these. */
void spdf_win_gpu_prewarm_start(spdf_win_d2d* d2d);
void spdf_win_gpu_prewarm_finish(void);

#else

#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */

#include <process.h>
#include <string.h>

typedef struct spdf_win_gpu_prewarm_state {
    HANDLE thread;
    HANDLE finish; /* set by finish(); the worker tears down and exits */
    ID2D1Factory* factory;
} spdf_win_gpu_prewarm_state;

__declspec(selectany) spdf_win_gpu_prewarm_state spdf_win_gpu_prewarm_shared = {NULL, NULL, NULL};

static LRESULT CALLBACK spdf_win_gpu_prewarm_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static unsigned __stdcall spdf_win_gpu_prewarm_thread(void* arg) {
    spdf_win_gpu_prewarm_state* s = (spdf_win_gpu_prewarm_state*)arg;
    ID2D1HwndRenderTarget* target = NULL;
    HWND hwnd;
    WNDCLASSW wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = spdf_win_gpu_prewarm_wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ShenzhenPDFGpuPrewarm";
    RegisterClassW(&wc); /* ERROR_CLASS_ALREADY_EXISTS is fine: start() runs once */
    /* Never shown and never painted -- CreateHwndRenderTarget only needs a live
     * HWND to size itself against -- but NOT never pumped, and not an ordinary
     * top-level window. See the park below.
     *
     * WS_POPUP with WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE: an unowned
     * WS_OVERLAPPEDWINDOW is a window the SHELL takes an interest in even while
     * it is invisible -- it is enumerated, asked for its title and its icon, and
     * considered when the window manager decides what to activate. A tool window
     * is excluded from the Alt+Tab list and the taskbar by definition, and
     * NOACTIVATE says it must never take the foreground. This window exists only
     * to hold a render target's back buffer; it should be invisible to the
     * desktop in every sense, not just unmapped. */
    hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, wc.lpszClassName, L"", WS_POPUP, 0, 0, 64, 64, NULL,
                           NULL, wc.hInstance, NULL);
    if (hwnd) {
        /* The same properties spdf_win_window.cpp's ensure_target uses, so the
         * device the factory creates for this is the one the real target gets. */
        D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
            96.0f, 96.0f);
        s->factory->CreateHwndRenderTarget(props, D2D1::HwndRenderTargetProperties(hwnd, D2D1::SizeU(64, 64)), &target);
    }
    spdf_win_launch_mark(target ? "gpu-prewarm-done" : "gpu-prewarm-failed");
    /* PARK, BUT KEEP PUMPING. The dummy target is held until finish() because
     * releasing the factory's last hardware target lets it drop the device --
     * the whole cost this exists to hide, paid twice. So this thread outlives
     * the prewarm, and it owns a window.
     *
     * A thread that owns a window and stops dispatching messages is a HUNG
     * window as far as Windows is concerned, for as long as the app runs, and
     * that is not a private matter: USER32 answers cross-process SendMessage on
     * behalf of a window's thread, so a hung window stalls every broadcast on
     * the desktop (WM_SETTINGCHANGE, theme and DPI changes, device arrival) for
     * its timeout, the shell's own enumeration of this process slows to that
     * same timeout, and activating this app's real window becomes unreliable --
     * which is exactly how it was reported: "I can't interact with it at all,
     * not even focus it with alt tab". Measured before this change with
     * IsHungAppWindow: true, from a few seconds after launch until exit.
     *
     * MsgWaitForMultipleObjects wakes on the event OR on an arriving message,
     * so the wait still costs nothing while idle and the window stays
     * answerable. DispatchMessageW goes to DefWindowProc, which is all this
     * window has ever needed. */
    for (;;) {
        DWORD w = MsgWaitForMultipleObjects(1, &s->finish, FALSE, INFINITE, QS_ALLINPUT);
        MSG msg;
        if (w == WAIT_OBJECT_0) break;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        /* WAIT_FAILED would spin: the event is the caller's and cannot vanish
         * while this thread runs, so treat anything unexpected as "stop". */
        if (w != WAIT_OBJECT_0 + 1) break;
    }
    if (target) target->Release();
    if (hwnd) DestroyWindow(hwnd);
    return 0;
}

static void spdf_win_gpu_prewarm_start(spdf_win_d2d* d2d) {
    spdf_win_gpu_prewarm_state* s = &spdf_win_gpu_prewarm_shared;
    if (s->thread || !d2d) return;
    s->factory = spdf_win_d2d_factory(d2d);
    if (!s->factory) return;
    s->finish = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!s->finish) return;
    spdf_win_launch_mark("gpu-prewarm-begin");
    s->thread = (HANDLE)_beginthreadex(NULL, 0, spdf_win_gpu_prewarm_thread, s, 0, NULL);
    if (!s->thread) {
        CloseHandle(s->finish);
        s->finish = NULL;
    }
}

static void spdf_win_gpu_prewarm_finish(void) {
    spdf_win_gpu_prewarm_state* s = &spdf_win_gpu_prewarm_shared;
    if (!s->thread) return;
    SetEvent(s->finish);
    WaitForSingleObject(s->thread, INFINITE);
    CloseHandle(s->thread);
    CloseHandle(s->finish);
    s->thread = NULL;
    s->finish = NULL;
    s->factory = NULL;
}

#endif /* __cplusplus */
#endif /* SPDF_WIN_GPU_PREWARM_H */
