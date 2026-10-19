/* Direct2D compose layer for the Windows frontend.
 *
 * THE LOAD-BEARING RULE OF THIS FILE (windows-port-plan.md sec 3, risk 9):
 * nothing here may require an HWND. spdf_win_paint() takes an
 * ID2D1RenderTarget* and draws into it, and it does not care whether that
 * target is backed by a window or by a WIC bitmap in a session with no
 * desktop at all. The windowed path in spdf_win_window.cpp is a thin caller
 * of it; the headless path (spdf_win_render_scene_to_png, and T4's probe) is
 * another thin caller of the very same function.
 *
 * That is the entire reason Direct2D was chosen over WinUI/Qt: `prlctl exec`
 * runs in the SYSTEM session, so a compose path that needs a window is a
 * compose path no agent can ever verify.
 *
 * This header is C-safe on purpose. In a .c translation unit the Windows SDK
 * declares ID2D1RenderTarget and IWICImagingFactory as opaque interface
 * typedefs, which is all a C caller needs to hold a pointer and hand it back
 * to us -- so T4's spdf_win_probe.c can stay plain C even though the
 * implementation behind this header is C++. See spdf_win_d2d.cpp for why the
 * implementation cannot be C.
 */
#ifndef SPDF_WIN_D2D_H
#define SPDF_WIN_D2D_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef COBJMACROS
#define COBJMACROS
#endif

#include <windows.h>
#include <d2d1.h>
#include <wincodec.h>

#include "shenzhen_pdf_core.h"
#include "spdf_win_chrome.h" /* SpdfWinChromeModel, carried by the scene */

#ifdef __cplusplus
extern "C" {
#endif

/* Factories plus one cached page texture. Created once per process; holds no
 * window, no device, no swap chain. */
typedef struct spdf_win_d2d spdf_win_d2d;

typedef enum spdf_win_fit {
    /* Page blitted 1:1 into the top-left of the target, no background, no
     * chrome. This is the pixel-comparison path: the output PNG is expected
     * to be the core's own RGBA buffer, unresampled, so any difference
     * against the macOS reference render is a real difference. */
    SPDF_WIN_FIT_EXACT = 0,
    /* The continuous scrolling canvas: `pages` carries every page intersecting
     * the viewport, already positioned in target device pixels by
     * spdf_win_canvas.c. Pages outside the target are clipped by Direct2D, not
     * by the caller, so a page straddling the top edge draws its lower half
     * with no special case. This is what the window shows. */
    SPDF_WIN_FIT_CANVAS = 1
} spdf_win_fit;

/* THE READING THEME, AS CONCRETE sRGB.
 *
 * These are the macOS palette's own literals, one variant each, transcribed
 * from portable/mac/markdown/SPDFMarkdownTheme.mm:23-27 -- which is the reading
 * theme for the WHOLE app, not just Markdown: SPDFMacDocumentViewTheme.mm:68-71
 * reads the same object for the PDF canvas. Named here rather than spelled as
 * D2D1::ColorF literals at the draw site for three reasons: the values are
 * citable against the Mac source, the compose path stays a pure function of
 * scene->dark (agents.md's render-determinism rule -- never appearance-dynamic,
 * never ambient), and a test can pin every one of them with no device, no
 * window and no desktop.
 *
 * `draws_page_shadow` / `draws_page_border` mirror SPDFMarkdownTheme's
 * `drawsPaperShadow` seam and are mutually exclusive by construction. Light
 * keeps the soft drop shadow; dark swaps it for a crisp 1 px paper-border frame,
 * because on the #121212 gutter a black shadow is invisible, so only one page
 * edge would ever read (SPDFMacDocumentViewTheme.mm:44-58 states exactly this).
 *
 * The light gutter is a hard-coded #E0E0E2 where macOS derives its own from
 * NSColor.windowBackgroundColor blended 8% toward black
 * (SPDFMacDocumentViewTheme.mm:16-41). Deriving the Windows equivalent from a
 * system colour is a separate change: it makes the value appearance-dynamic and
 * so has to be threaded in as a parameter rather than baked into this table.
 *
 * The shadow's own colour is NOT here. macOS uses a blurred NSShadow (radius
 * 12, offset (0,-2), black at alpha 0.28); Windows deliberately approximates it
 * with one flat band (see draw_canvas_page), and that approximation belongs at
 * its draw site, not in a palette shared with exact values. */
typedef struct spdf_win_theme {
    unsigned int gutter_rgb;      /* 0xRRGGBB behind the sheets (FIT_CANVAS surround) */
    unsigned int paper_rgb;       /* the page underlay; dark is the recolor transform's white endpoint */
    unsigned int page_border_rgb; /* meaningful only when draws_page_border */
    int draws_page_shadow;
    int draws_page_border;
} spdf_win_theme;

static inline spdf_win_theme spdf_win_theme_for(int dark) {
    spdf_win_theme theme;
    /* #1E1E1E is not merely "the palette's dark paper": it is exactly what the
     * luma remap produces for document white (spdf_recolor.h:50-53 -- white
     * Y=255 maps to 255-255+220-190 = 30). Any other value shows a mismatched
     * sliver around a recoloured page at a fractional zoom. */
    theme.gutter_rgb = dark ? 0x121212u : 0xE0E0E2u;
    theme.paper_rgb = dark ? 0x1E1E1Eu : 0xFFFFFFu;
    theme.page_border_rgb = dark ? 0x333333u : 0xD0D7DEu;
    theme.draws_page_shadow = !dark;
    theme.draws_page_border = dark;
    return theme;
}

/* One page placed on the canvas. Destination is in TARGET DEVICE PIXELS and
 * may fall partly or wholly outside the target; the bitmap is drawn stretched
 * to it, which is what keeps geometry independent of the render byte cap (a
 * giant sheet renders at a reduced zoom and is scaled back up to its true slot
 * rather than changing where anything sits). */
typedef struct spdf_win_page_draw {
    const spdf_bitmap* bitmap; /* NULL = not rendered yet; a paper placeholder is drawn */
    int page_index;
    float dest_x;
    float dest_y;
    float dest_w;
    float dest_h;
} spdf_win_page_draw;

/* WHAT GETS DRAWN OVER A PAGE, AND WHY THE COLOURS ARE NOT IN THE THEME.
 *
 * Search highlights and the text selection are **theme-independent and
 * hard-coded** on macOS, in both canvases, and the handoff says explicitly not
 * to route them through the palette (windows-port-handoff.md §3.3). The reason
 * is that they are not surfaces: they are marks ON a surface, and they have to
 * stay legible over a white page and over a #1E1E1E recoloured one. So the
 * values live here beside the reading theme rather than in
 * spdf_win_chrome_theme.h, which is for chrome that SHOULD look native.
 *
 * Values transcribed from portable/mac/SPDFMacDocumentView.mm:
 *   all matches   calibrated(1.0, 0.84, 0.12, 0.38), rounded radius 2.0  (:467-473)
 *   active match  stroke calibrated(0.94, 0.03, 0.02, a), inset -2,-2,
 *                 lineWidth 1.2, alpha fades                            (:475-482)
 *   selection     calibrated(0.40, 0.62, 0.86, 0.20)                    (:485, :11)
 */
typedef enum spdf_win_overlay_kind {
    SPDF_WIN_OVERLAY_SEARCH_MATCH = 0,
    SPDF_WIN_OVERLAY_SEARCH_ACTIVE = 1,
    SPDF_WIN_OVERLAY_SELECTION = 2,
    /* Comment markers (the annotations track). COMMENT is the mac's frame
     * around an annotation's bounds: fill calibrated(1.0, 0.76, 0.10, 0.16),
     * stroke calibrated(0.92, 0.52, 0.0, 0.95) at 1.2, rounded 3, the rect
     * grown 2 (SPDFMacDocumentView.mm:492-502). COMMENT_BADGE is the GTK
     * click-to-edit badge, a 12 pt amber square at the top-right corner: fill
     * (0.98, 0.74, 0.18, 0.92), border (0.55, 0.35, 0.0, 0.9)
     * (spdf_docview.c:1270-1282); its rect is spdf_win_annot_badge()'s, so the
     * pixels drawn and the pixels that open the editor are the same pixels. */
    SPDF_WIN_OVERLAY_COMMENT = 3,
    SPDF_WIN_OVERLAY_COMMENT_BADGE = 4
} spdf_win_overlay_kind;

/* One mark. Coordinates are in the SAME space as spdf_win_page_draw's dest --
 * canvas-local device pixels -- so a producer that already knows where a page
 * landed does not have to convert twice, and a mark partly off-screen is
 * clipped by Direct2D rather than by the caller. */
typedef struct spdf_win_overlay {
    int page_index;
    float x, y, w, h;
    int kind;  /* spdf_win_overlay_kind */
    float alpha; /* multiplies the kind's own alpha; 1.0 for "as specified". The
                  * active match's fade is the only current user. */
} spdf_win_overlay;

/* Everything a paint needs. Deliberately free of Win32 handles: the same
 * struct is filled by the window and by a console probe. */
typedef struct spdf_win_scene {
    /* SPDF_WIN_FIT_EXACT only. Borrowed RGBA page pixels from
     * spdf_render_page_rgba_opts(). NULL is legal and means "nothing to show
     * yet"; `message` is drawn instead. */
    const spdf_bitmap* page;
    /* SPDF_WIN_FIT_CANVAS only. Borrowed; valid until the canvas is next
     * touched. An empty list with a NULL `page` draws `message`. */
    const spdf_win_page_draw* pages;
    int page_count;
    spdf_win_fit fit;
    /* Size of the target in DEVICE PIXELS. Passed in rather than queried off
     * the target: ID2D1RenderTarget::GetSize returns a struct by value, and
     * the calling convention for that has been a portability trap between the
     * C and C++ bindings of every D3D-family header. Whoever created the
     * target already knows the number. */
    unsigned target_px_w;
    unsigned target_px_h;
    /* Size of the WHOLE client area in device pixels, which is not the same as
     * target_px_w/h once there is chrome: spdf_win_canvas_build_scene() sets
     * target_px_w/h from the CANVAS viewport (documented in spdf_win_canvas.h),
     * so after it runs those describe the page region, not the window.
     *
     * The chrome has to be laid out against the window. Keeping a separate pair
     * that the canvas never touches is what stops the chrome from laying itself
     * out inside the canvas it just produced -- which it did, once, and drew the
     * entire window's furniture into the left half of itself. 0 means "same as
     * target_px_w/h", which is every pre-chrome caller and the probe. */
    unsigned client_px_w;
    unsigned client_px_h;
    /* Device pixels per logical pixel (1.0 at 96 dpi, 2.0 on a 2x display).
     * Chrome metrics are multiplied by this; the page itself is already
     * rendered at the right zoom by the caller. */
    float dpi_scale;
    int dark; /* dark surround, to match the dark reading theme */
    /* UTF-16 status or error line, drawn centred when `page` is NULL. May be
     * NULL. A missing font degrades to no text, never to a failed paint. */
    const wchar_t* message;
    /* SPDF_WIN_FIT_CANVAS only. NULL means "no chrome": the canvas gets the
     * whole target, which is what every existing pixel test and the probe
     * expect, so they keep comparing a bare canvas and nothing had to change to
     * accommodate the chrome.
     *
     * When present, spdf_win_paint() divides the target with
     * spdf_win_chrome_layout(), paints the strip/toolbar/panels, and clips the
     * pages to the canvas region. The page positions in `pages` are then in
     * CANVAS-LOCAL device pixels, not target-local -- which is also what
     * --render-window-png prints, so its geometry output stays comparable
     * whether or not chrome is on. The caller must therefore have laid the
     * canvas out against the canvas rect's size, not the client size. */
    const SpdfWinChromeModel* chrome;
    /* Marks drawn OVER the pages, after every page and before the chrome, so a
     * highlight cannot paint over the toolbar and a page scrolled under the
     * strip does not drag its highlights with it. Borrowed; NULL/0 is the norm.
     * Drawn in array order, so a producer that wants the active match on top
     * puts it last. */
    const spdf_win_overlay* overlays;
    int overlay_count;
} spdf_win_scene;

/* err/err_len may be NULL/0. Returns NULL on failure. */
spdf_win_d2d* spdf_win_d2d_create(char* err, size_t err_len);
void spdf_win_d2d_destroy(spdf_win_d2d* d2d);


/* Needed by spdf_win_window.cpp to build its HWND render target, and by any
 * headless caller that wants to make its own WIC target. */
ID2D1Factory* spdf_win_d2d_factory(spdf_win_d2d* d2d);
IWICImagingFactory* spdf_win_d2d_wic(spdf_win_d2d* d2d);

/* THE render entry point. Brackets its own BeginDraw/EndDraw and returns
 * EndDraw's HRESULT, so D2DERR_RECREATE_TARGET reaches the caller that owns
 * the target and can rebuild it. Never touches an HWND. */
HRESULT spdf_win_paint(spdf_win_d2d* d2d, ID2D1RenderTarget* target, const spdf_win_scene* scene);

/* Drop any cached device resources bound to `target` before it is released.
 * Cheap and idempotent; passing NULL drops the cache unconditionally. */
void spdf_win_d2d_release_target(spdf_win_d2d* d2d, ID2D1RenderTarget* target);

/* Headless composite: makes a WIC bitmap of the requested size, runs the very
 * same spdf_win_paint() into a SOFTWARE render target over it, and writes a
 * 32bpp BGRA PNG. No window, no GPU, no desktop session. The scene's
 * target_px_w/h are overridden with px_w/px_h. */
HRESULT spdf_win_render_scene_to_png(spdf_win_d2d* d2d, unsigned px_w, unsigned px_h, const spdf_win_scene* scene,
                                     const wchar_t* png_path);

#ifdef __cplusplus
}
#endif

/* spdf_win_gpu_prewarm_start(d2d): the windowed path calls it right after
 * create() so the factory's GPU device is made on a worker while the session
 * and the document open; destroy() joins it. Header-only and C++-only in its
 * implementation, so it comes after the C declarations it uses and outside
 * the extern "C" block. */
#include "spdf_win_gpu_prewarm.h"

#endif /* SPDF_WIN_D2D_H */
