/* Measurement probe, not part of the suite (build-native.cmd builds it by name;
 * portable/docs/windows-launch-performance.md sec 3.2): does a MULTI_THREADED
 * D2D factory share its internal D3D device across threads? A worker creates a
 * hidden window and an HwndRenderTarget on it; the main thread then creates its
 * own HwndRenderTarget from the same factory and times it. If the device is
 * shared, the main thread's target costs ~1 ms instead of ~60-90. */
#include <windows.h>
#include <d2d1.h>
#include <process.h>
#include <stdio.h>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "user32.lib")

static double now_ms(void) {
    static LARGE_INTEGER f = {0};
    LARGE_INTEGER c;
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}
#define TIME(label, stmt) do { double t0__ = now_ms(); stmt; printf("%-28s %8.1f ms\n", label, now_ms() - t0__); } while (0)

static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(h, m, w, l); }
static ID2D1Factory* g_factory;
static HANDLE g_ready, g_finish;
static ID2D1HwndRenderTarget* g_dummy;

static unsigned __stdcall worker(void*) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wp;
    wc.lpszClassName = L"SpdfGpuProbeWarm";
    wc.hInstance = GetModuleHandleW(NULL);
    RegisterClassW(&wc);
    HWND h = CreateWindowExW(0, wc.lpszClassName, L"warm", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, NULL, NULL, wc.hInstance, NULL);
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.0f, 96.0f);
    TIME("worker: dummy hwnd target", g_factory->CreateHwndRenderTarget(props, D2D1::HwndRenderTargetProperties(h, D2D1::SizeU(64, 64)), &g_dummy));
    SetEvent(g_ready);
    WaitForSingleObject(g_finish, INFINITE);
    if (g_dummy) g_dummy->Release();
    DestroyWindow(h);
    return 0;
}

int main(void) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wp;
    wc.lpszClassName = L"SpdfGpuProbeMain";
    wc.hInstance = GetModuleHandleW(NULL);
    RegisterClassW(&wc);
    HWND h1 = CreateWindowExW(0, wc.lpszClassName, L"p1", WS_OVERLAPPEDWINDOW, 0, 0, 800, 600, NULL, NULL, wc.hInstance, NULL);

    TIME("d2d-factory (multi)", D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, &g_factory));
    g_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    g_finish = CreateEventW(NULL, TRUE, FALSE, NULL);
    double t0 = now_ms();
    HANDLE th = (HANDLE)_beginthreadex(NULL, 0, worker, NULL, 0, NULL);
    /* Pretend to be the UI thread doing 40 ms of other launch work. */
    Sleep(40);
    TIME("main: wait for worker ready", WaitForSingleObject(g_ready, INFINITE));
    printf("%-28s %8.1f ms\n", "worker ready after", now_ms() - t0);
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.0f, 96.0f);
    ID2D1HwndRenderTarget* t1 = NULL;
    TIME("main: real hwnd target", g_factory->CreateHwndRenderTarget(props, D2D1::HwndRenderTargetProperties(h1, D2D1::SizeU(800, 600)), &t1));
    TIME("main: first draw+EndDraw", if (t1) { t1->BeginDraw(); t1->Clear(D2D1::ColorF(0.5f, 0.5f, 0.5f)); t1->EndDraw(); });
    TIME("main: second draw+EndDraw", if (t1) { t1->BeginDraw(); t1->Clear(D2D1::ColorF(0.4f, 0.5f, 0.5f)); t1->EndDraw(); });
    SetEvent(g_finish);
    WaitForSingleObject(th, INFINITE);
    TIME("main: draw after worker gone", if (t1) { t1->BeginDraw(); t1->Clear(D2D1::ColorF(0.3f, 0.5f, 0.5f)); t1->EndDraw(); });
    return 0;
}
