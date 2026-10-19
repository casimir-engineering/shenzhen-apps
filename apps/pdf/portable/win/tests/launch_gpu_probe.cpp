/* Measurement probe, not part of the suite (build-native.cmd builds it by name;
 * numbers in portable/docs/windows-launch-performance.md sec 3.2): what does
 * each way of getting a hardware Direct2D surface cost on this machine?
 *   d3d11-device-1      D3D11CreateDevice(HARDWARE) cold in the process
 *   d3d11-device-2      the same again (driver already loaded)
 *   warp-device         D3D11CreateDevice(WARP)
 *   hwnd-target-1       ID2D1Factory::CreateHwndRenderTarget on a hidden window
 *   hwnd-target-2       a second one, same factory, second window
 *   d2d11-device        ID2D1Factory1::CreateDevice(IDXGIDevice of device-1)
 *   d2d11-context       + CreateDeviceContext
 *   swapchain           IDXGIFactory2::CreateSwapChainForHwnd on device-1
 *   dxgi-surface-bitmap CreateBitmapFromDxgiSurface + SetTarget
 *   first-present       one Clear + EndDraw + Present(1,0) on that chain
 *   hwnd-target-1 first EndDraw: Clear + EndDraw on the HwndRenderTarget */
#include <windows.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "user32.lib")

static double now_ms(void) {
    static LARGE_INTEGER f = {0};
    LARGE_INTEGER c;
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}
#define TIME(label, stmt) do { double t0__ = now_ms(); stmt; printf("%-22s %8.1f ms\n", label, now_ms() - t0__); } while (0)

static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(h, m, w, l); }

int main(void) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wp;
    wc.lpszClassName = L"SpdfGpuProbe";
    wc.hInstance = GetModuleHandleW(NULL);
    RegisterClassW(&wc);
    HWND h1 = CreateWindowExW(0, wc.lpszClassName, L"p1", WS_OVERLAPPEDWINDOW, 0, 0, 800, 600, NULL, NULL, wc.hInstance, NULL);
    HWND h2 = CreateWindowExW(0, wc.lpszClassName, L"p2", WS_OVERLAPPEDWINDOW, 0, 0, 800, 600, NULL, NULL, wc.hInstance, NULL);

    ID3D11Device* dev1 = NULL; ID3D11Device* dev2 = NULL; ID3D11Device* warp = NULL;
    ID3D11DeviceContext* ctx1 = NULL;
    D3D_FEATURE_LEVEL fl;
    TIME("d3d11-device-1", D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &dev1, &fl, &ctx1));
    TIME("d3d11-device-2", D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &dev2, &fl, NULL));
    TIME("warp-device", D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &warp, &fl, NULL));

    ID2D1Factory1* factory = NULL;
    TIME("d2d-factory", D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), NULL, (void**)&factory));
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.0f, 96.0f);
    ID2D1HwndRenderTarget* t1 = NULL; ID2D1HwndRenderTarget* t2 = NULL;
    TIME("hwnd-target-1", factory->CreateHwndRenderTarget(props, D2D1::HwndRenderTargetProperties(h1, D2D1::SizeU(800, 600)), &t1));
    TIME("hwnd-target-1 draw", if (t1) { t1->BeginDraw(); t1->Clear(D2D1::ColorF(0.5f, 0.5f, 0.5f)); t1->EndDraw(); });
    TIME("hwnd-target-1 draw2", if (t1) { t1->BeginDraw(); t1->Clear(D2D1::ColorF(0.4f, 0.5f, 0.5f)); t1->EndDraw(); });
    TIME("hwnd-target-2", factory->CreateHwndRenderTarget(props, D2D1::HwndRenderTargetProperties(h2, D2D1::SizeU(800, 600)), &t2));
    TIME("hwnd-target-2 draw", if (t2) { t2->BeginDraw(); t2->Clear(D2D1::ColorF(0.5f, 0.5f, 0.5f)); t2->EndDraw(); });

    /* The D2D 1.1 path on the device already made. */
    IDXGIDevice* dxgi = NULL; ID2D1Device* d2dev = NULL; ID2D1DeviceContext* dc = NULL;
    IDXGIFactory2* dxf = NULL; IDXGISwapChain1* sc = NULL; IDXGISurface* surf = NULL; ID2D1Bitmap1* bb = NULL;
    dev1->QueryInterface(__uuidof(IDXGIDevice), (void**)&dxgi);
    TIME("d2d11-device", factory->CreateDevice(dxgi, &d2dev));
    TIME("d2d11-context", if (d2dev) d2dev->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &dc));
    TIME("dxgi-factory", CreateDXGIFactory1(__uuidof(IDXGIFactory2), (void**)&dxf));
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = 800; sd.Height = 600; sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    TIME("swapchain", if (dxf) dxf->CreateSwapChainForHwnd(dev1, h1, &sd, NULL, NULL, &sc));
    TIME("dxgi-surface-bitmap", if (sc && dc) { sc->GetBuffer(0, __uuidof(IDXGISurface), (void**)&surf);
        D2D1_BITMAP_PROPERTIES1 bp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.0f, 96.0f);
        dc->CreateBitmapFromDxgiSurface(surf, &bp, &bb); dc->SetTarget(bb); });
    TIME("first-present", if (dc && sc) { dc->BeginDraw(); dc->Clear(D2D1::ColorF(0.5f, 0.5f, 0.5f)); dc->EndDraw(); sc->Present(1, 0); });
    TIME("second-present", if (dc && sc) { dc->BeginDraw(); dc->Clear(D2D1::ColorF(0.6f, 0.5f, 0.5f)); dc->EndDraw(); sc->Present(1, 0); });
    return 0;
}
