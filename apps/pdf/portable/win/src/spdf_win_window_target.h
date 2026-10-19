#pragma once

/* The HWND render target and the one paint -- for spdf_win_window.cpp only.
 *
 * NOT A NEW LAYER, and the same arrangement as spdf_win_window_input.h,
 * spdf_win_window_caption.h and spdf_win_window_frame.h beside it: header-only,
 * included from exactly one translation unit, AFTER `struct spdf_win_window`
 * because it dereferences it, and not part of the port's public surface. These
 * three functions were in spdf_win_window.cpp and do exactly what they did
 * there; they moved out when full screen, the tick and the tooltip pushed that
 * file past its 500-line cap, and tools/file-size-limits.md asks for an
 * extracted file rather than a raised one.
 *
 * WHAT BELONGS HERE: the ID2D1HwndRenderTarget's lifetime and the single call
 * that hands it to spdf_win_paint(). The rule that governs both is
 * spdf_win_d2d.h's: nothing about HOW a page is drawn lives on this side of
 * that call, which is what keeps the headless probe drawing the same pixels as
 * the window.
 *
 * THE ORDER INSIDE paint() IS A MEASURED DECISION, not an accident of editing:
 * the scene is built BEFORE the target is created. The long note at that line
 * says why and what it is worth.
 */

static void discard_target(spdf_win_window* window) {
    if (!window->target) return;
    spdf_win_d2d_release_target(window->d2d, window->target);
    window->target->Release();
    window->target = NULL;
}

/* Creates the HWND render target on first paint, and resizes it in place
 * afterwards. Lazily, because a target created before the window has its
 * final size is a target that gets resized immediately anyway, and Phase 1's
 * whole point is that nothing eager happens on the launch path. */
static HRESULT ensure_target(spdf_win_window* window, UINT px_w, UINT px_h) {
    if (window->target) {
        return window->target->Resize(D2D1::SizeU(px_w, px_h));
    }
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
        96.0f, 96.0f);
    D2D1_HWND_RENDER_TARGET_PROPERTIES hwnd_props =
        D2D1::HwndRenderTargetProperties(window->hwnd, D2D1::SizeU(px_w, px_h), D2D1_PRESENT_OPTIONS_NONE);
    return spdf_win_d2d_factory(window->d2d)->CreateHwndRenderTarget(props, hwnd_props, &window->target);
}

static void paint(spdf_win_window* window) {
    RECT rc;
    if (!GetClientRect(window->hwnd, &rc)) return;

    UINT px_w = (UINT)(rc.right - rc.left);
    UINT px_h = (UINT)(rc.bottom - rc.top);
    if (px_w == 0 || px_h == 0) return;

    SPDF_WIN_LAUNCH_MARK_ONCE("first-paint-begin");

    spdf_win_scene scene;
    memset(&scene, 0, sizeof(scene));
    scene.fit = SPDF_WIN_FIT_CANVAS;
    scene.target_px_w = px_w;
    scene.target_px_h = px_h;
    /* The chrome lays itself out against these, not target_px_w/h, which the
     * canvas overwrites with its own viewport. */
    scene.client_px_w = px_w;
    scene.client_px_h = px_h;
    scene.dpi_scale = spdf_win_window_dpi_scale(window);
    /* A handler that declines leaves an EMPTY scene, not a half-filled one: it
     * may have written a page list and then decided against it, and drawing from
     * a list its owner has disclaimed is how a stale pointer is dereferenced. */
    if (window->scene_fn && !window->scene_fn(window->user, &scene)) {
        scene.page = NULL;
        scene.pages = NULL;
        scene.page_count = 0;
    }
    SPDF_WIN_LAUNCH_MARK_ONCE("first-scene-built");

    /* THE TARGET AFTER THE SCENE, NOT BEFORE, and the order is worth 30% of the
     * first page (portable/docs/windows-launch-performance.md §4.1, experiment
     * E2). The scene is where page 0 is rendered and the outline read -- pure
     * CPU. The target is where Direct2D creates its D3D device, which since
     * spdf_win_gpu_prewarm.h happens on a worker; but if that worker has not
     * finished, THIS CALL WAITS FOR IT. Building the scene first spends the
     * document's CPU work inside that wait instead of queueing it behind the
     * wait. Measured: page render done at 58-110 ms against a device ready at
     * 124-160, so the render is free. On every later frame the target already
     * exists and the order is immaterial.
     *
     * Nothing about the PIXELS moves with it: the same scene is handed to the
     * same spdf_win_paint() through the same target, created by the same call
     * with the same properties. That is what the d2d.compose-* byte comparisons
     * and a before/after --render-window-png check are for. */
    if (FAILED(ensure_target(window, px_w, px_h))) {
        discard_target(window);
        return;
    }
    SPDF_WIN_LAUNCH_MARK_ONCE("first-hwnd-target");

    HRESULT hr = spdf_win_paint(window->d2d, window->target, &scene);
    SPDF_WIN_LAUNCH_MARK_ONCE("first-paint-end");
    if (hr == D2DERR_RECREATE_TARGET) {
        /* The display changed, the GPU was reset, or the session was locked.
         * Throw the target away and ask for another paint; the next one
         * rebuilds it. */
        discard_target(window);
        InvalidateRect(window->hwnd, NULL, FALSE);
    }
}
