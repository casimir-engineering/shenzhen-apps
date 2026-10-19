#pragma once

/* Internal to the Windows frontend, like spdf_win_canvas_internal.h. Header-only
 * so no build source list outside this directory needs a new .cpp.
 *
 * The 1:1 single-page PNG path, split out of spdf_win_main.cpp to keep that file
 * inside the size ratchet. Its whole value is that nothing has touched the
 * pixels between the core and the PNG, which is what makes it the reference the
 * cross-host comparison trusts. */

/* The 1:1 single-page path. Kept separate from the canvas because its whole
 * value is that nothing has touched the pixels between the core and the PNG. */
static int run_exact(app* a, spdf_win_d2d* d2d, const wchar_t* wpath, int page_index, float zoom,
                     const wchar_t* out_png) {
    spdf_bitmap bitmap;
    spdf_win_scene scene;
    char err[256] = {0};
    wchar_t message[400];
    HRESULT hr;

    if (!open_document(a, wpath, page_index, false)) return 1;

    /* The canvas caps its render surface; this path did not, so a large sheet
     * at a high zoom allocated without bound -- zoom 30 on a 200x260pt page
     * asked for a 6000x7800 RGBA surface, 187MB against a 96MB cap. Apply the
     * same cap the canvas uses so the two paths agree. */
    {
        float page_w = 0.0f, page_h = 0.0f;
        char size_err[256] = {0};
        if (spdf_page_size(a->doc, page_index, &page_w, &page_h, size_err, sizeof(size_err)) && page_w > 0.0f &&
            page_h > 0.0f)
            zoom = (float)spdf_win_capped_render_zoom(zoom, (double)page_w, (double)page_h);
    }

    memset(&bitmap, 0, sizeof(bitmap));
    if (!spdf_render_page_rgba_opts(a->doc, page_index, zoom, a->render_flags, NULL, &bitmap, err, sizeof(err))) {
        _snwprintf_s(message, _TRUNCATE, L"Could not render page %d: %hs", page_index, err[0] ? err : "unknown error");
        report(message, false);
        return 1;
    }

    memset(&scene, 0, sizeof(scene));
    scene.page = &bitmap;
    scene.fit = SPDF_WIN_FIT_EXACT;
    scene.dpi_scale = 1.0f;
    scene.dark = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    int px_w = bitmap.width;
    int px_h = bitmap.height;
    hr = spdf_win_render_scene_to_png(d2d, (unsigned)px_w, (unsigned)px_h, &scene, out_png);
    spdf_free_bitmap(&bitmap);
    if (FAILED(hr)) {
        _snwprintf_s(message, _TRUNCATE, L"Compose to %s failed (hr=0x%08lX)", out_png, (unsigned long)hr);
        report(message, false);
        return 1;
    }
    wprintf(L"wrote %s %dx%d\n", out_png, px_w, px_h);
    return 0;
}

/* --- command line -------------------------------------------------------- */
