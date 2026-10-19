#pragma once

/* Internal to spdf_win_d2d.cpp -- included at its end, not by anyone else.
 *
 * The headless composite: a WIC bitmap, a SOFTWARE Direct2D target over it, the
 * very same spdf_win_paint(), and a 32bpp BGRA PNG out. Split out of
 * spdf_win_d2d.cpp to keep that file inside the size ratchet
 * (tools/file-size-limits.md), the same move spdf_win_headless.h and
 * spdf_win_headless_viewport.h made in spdf_win_main.cpp.
 *
 * D2D1_RENDER_TARGET_TYPE_SOFTWARE is deliberate and load-bearing, not a
 * fallback: the harness host may have no display adapter at all -- `prlctl exec`
 * runs in the SYSTEM session -- so a DEFAULT target would fail there and take
 * every pixel test with it.
 *
 * It also means this path and the window's GPU path do not agree bit-for-bit on
 * bilinear resampling: measured maxdelta 2 near a 1:1 blit, and 43 with MAE 0.60
 * when a page bitmap is squeezed into a 208 px canvas
 * (portable/docs/windows-native-observations.md). Every zero-tolerance case in
 * this repo compares SOFTWARE against SOFTWARE and is unaffected; what they do
 * not certify is the GPU window's resampled pixels.
 */

static HRESULT write_wic_png(spdf_win_d2d* d2d, IWICBitmap* bitmap, unsigned w, unsigned h, const wchar_t* path) {
    IWICStream* stream = NULL;
    IWICBitmapEncoder* encoder = NULL;
    IWICBitmapFrameEncode* frame = NULL;
    IWICBitmapSource* converted = NULL;
    IPropertyBag2* options = NULL;
    GUID format = GUID_WICPixelFormat32bppBGRA;

    IWICImagingFactory* wic = spdf_win_d2d_wic(d2d); /* created on first use */
    if (!wic) return E_FAIL;
    HRESULT hr = wic->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(path, GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = wic->CreateEncoder(GUID_ContainerFormatPng, NULL, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &options);
    if (SUCCEEDED(hr)) hr = frame->Initialize(options);
    if (SUCCEEDED(hr)) hr = frame->SetSize(w, h);
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    /* D2D can only draw into a premultiplied target, but a PNG's alpha is
     * straight. Convert rather than hand the encoder a format it has to guess
     * about. With an opaque page the two are byte-identical anyway. */
    if (SUCCEEDED(hr)) hr = WICConvertBitmapSource(GUID_WICPixelFormat32bppBGRA, bitmap, &converted);
    if (SUCCEEDED(hr)) hr = frame->WriteSource(converted, NULL);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();

    safe_release(converted);
    safe_release(options);
    safe_release(frame);
    safe_release(encoder);
    safe_release(stream);
    return hr;
}

HRESULT spdf_win_render_scene_to_png(spdf_win_d2d* d2d, unsigned px_w, unsigned px_h, const spdf_win_scene* scene,
                                     const wchar_t* png_path) {
    if (!d2d || !scene || !png_path) return E_POINTER;
    if (px_w == 0 || px_h == 0) return E_INVALIDARG;

    IWICBitmap* bitmap = NULL;
    IWICImagingFactory* wic = spdf_win_d2d_wic(d2d); /* created on first use: the window never needs WIC */
    if (!wic) return E_FAIL;
    HRESULT hr = wic->CreateBitmap(px_w, px_h, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &bitmap);
    if (FAILED(hr)) return hr;

    /* SOFTWARE, not DEFAULT. `prlctl exec` runs in the SYSTEM session: there
     * is no desktop and there may be no usable display adapter, and a target
     * that quietly wants a GPU is a target that fails only on the machine we
     * cannot see. */
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);

    ID2D1RenderTarget* target = NULL;
    hr = d2d->factory->CreateWicBitmapRenderTarget(bitmap, props, &target);
    if (SUCCEEDED(hr)) {
        spdf_win_scene local = *scene;
        local.target_px_w = px_w;
        local.target_px_h = px_h;
        hr = spdf_win_paint(d2d, target, &local);
        spdf_win_d2d_release_target(d2d, target);
    }
    safe_release(target);

    if (SUCCEEDED(hr)) hr = write_wic_png(d2d, bitmap, px_w, px_h, png_path);
    safe_release(bitmap);
    return hr;
}
