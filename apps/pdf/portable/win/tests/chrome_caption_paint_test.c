/* chrome_caption_paint_test.c — pins the three caption buttons the tab strip
 * draws (portable/win/src/spdf_win_chrome_caption.h), at rest, hovered, pressed
 * and maximized, in both appearances.
 *
 * WHY OFFSCREEN. The buttons' hover and pressed looks are driven by
 * WM_NCMOUSEMOVE and WM_NCLBUTTONDOWN in the live window, and a synthetic
 * WM_NCMOUSEMOVE cannot hold a hover: TrackMouseEvent(TME_NONCLIENT) sees that
 * the real pointer is not over the window and posts WM_NCMOUSELEAVE at once,
 * which puts the button out again before a capture can see it. That is the
 * harness being honest about a pointer that is not there, not a defect -- but
 * it means the live probe can only check the HT codes, not the pixels. The
 * pixels are checked HERE, from a hand-built model, because that is exactly what
 * spdf_win_chrome_state.h promises: the buttons are painted from
 * SpdfWinChromeModel::maximized / caption_hot / caption_pressed and from nothing
 * an HWND knows, so the frame a real hover produces is the frame this test
 * composes by setting caption_hot.
 *
 * Same arrangement as overlay_paint_test.c: spdf_win_render_scene_to_png() over
 * a WIC target, read back through WIC, expectations computed from the theme
 * rather than pasted. The chrome is laid out at 100% with no tabs -- the strip
 * with nothing in it but the `+` and the three buttons, which is the bare-launch
 * window -- and read at the pixels spdf_win_tabstrip_caption_rect() names.
 */
/* spdf-test-sources: portable/win/src/spdf_win_d2d.cpp portable/win/src/spdf_win_chrome_paint.cpp portable/win/src/spdf_win_chrome_scrollbar.cpp portable/win/src/spdf_win_chrome_find.cpp portable/win/src/spdf_win_chrome_toolbar.cpp portable/win/src/spdf_win_chrome_panels.cpp portable/win/src/spdf_win_chrome_sidebar.cpp portable/win/src/spdf_win_chrome_minimap.cpp portable/win/src/spdf_win_chrome_content.cpp portable/win/src/spdf_win_chrome_thumbs.cpp portable/win/src/spdf_win_render.c portable/win/src/spdf_win_lru.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_win_compat.c portable/core/spdf_recolor.c portable/win/src/spdf_win_open.c */
/* spdf-test-needs: mupdf */

#include "spdf_win_d2d.h"
#include "spdf_win_chrome_theme.h"
#include "spdf_win_tabstrip.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wincodec.h>

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

static int g_failures = 0;
static int g_checks = 0;

/* A strip wide enough for the `+` to clear the reserve, and tall enough for the
 * strip and toolbar plus a sliver of canvas. 100%, so points are pixels and the
 * rects spdf_win_tabstrip_caption_rect() returns can be read directly. */
#define CLIENT_W 600
#define CLIENT_H 200

static void fail(const char* what, const char* file, int line) {
    fprintf(stderr, "FAIL %s (%s:%d)\n", what, file, line);
    ++g_failures;
}

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) fail(#cond, __FILE__, __LINE__);                                                                  \
    } while (0)

/* --- reading the composed frame back (overlay_paint_test.c's reader) ---- */

typedef struct Frame {
    unsigned char* bgra;
    unsigned w, h;
} Frame;

static int frame_load(IWICImagingFactory* wic, const wchar_t* path, Frame* out) {
    IWICBitmapDecoder* decoder = NULL;
    IWICBitmapFrameDecode* frame = NULL;
    IWICFormatConverter* conv = NULL;
    HRESULT hr;
    UINT w = 0, h = 0;

    memset(out, 0, sizeof(*out));
    hr = IWICImagingFactory_CreateDecoderFromFilename(wic, path, NULL, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                                      &decoder);
    if (SUCCEEDED(hr)) hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame);
    if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateFormatConverter(wic, &conv);
    if (SUCCEEDED(hr))
        hr = IWICFormatConverter_Initialize(conv, (IWICBitmapSource*)frame, &GUID_WICPixelFormat32bppBGRA,
                                            WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom);
    if (SUCCEEDED(hr)) hr = IWICBitmapFrameDecode_GetSize(frame, &w, &h);
    if (SUCCEEDED(hr)) {
        out->w = w;
        out->h = h;
        out->bgra = (unsigned char*)malloc((size_t)w * h * 4);
        if (!out->bgra) hr = E_OUTOFMEMORY;
        if (SUCCEEDED(hr))
            hr = IWICFormatConverter_CopyPixels(conv, NULL, w * 4, (UINT)((size_t)w * h * 4), out->bgra);
    }
    if (conv) IWICFormatConverter_Release(conv);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    return SUCCEEDED(hr);
}

static void frame_free(Frame* f) {
    free(f->bgra);
    f->bgra = NULL;
}

static unsigned frame_rgb(const Frame* f, unsigned x, unsigned y) {
    const unsigned char* p;
    if (!f->bgra || x >= f->w || y >= f->h) return 0xFF00FFu;
    p = f->bgra + ((size_t)y * f->w + x) * 4;
    return ((unsigned)p[2] << 16) | ((unsigned)p[1] << 8) | (unsigned)p[0];
}

/* --- expectations from the theme ----------------------------------------- */

static unsigned rgb_of(SpdfWinChromeColor c) {
    return ((unsigned)(c.r * 255.0f + 0.5f) << 16) | ((unsigned)(c.g * 255.0f + 0.5f) << 8) |
           (unsigned)(c.b * 255.0f + 0.5f);
}

/* Source-over of a straight-alpha colour on an opaque backdrop. */
static unsigned blend(unsigned backdrop, SpdfWinChromeColor c) {
    double a = c.a;
    unsigned r = (unsigned)(c.r * 255.0 * a + (double)((backdrop >> 16) & 0xFF) * (1.0 - a) + 0.5);
    unsigned g = (unsigned)(c.g * 255.0 * a + (double)((backdrop >> 8) & 0xFF) * (1.0 - a) + 0.5);
    unsigned b = (unsigned)(c.b * 255.0 * a + (double)(backdrop & 0xFF) * (1.0 - a) + 0.5);
    return (r << 16) | (g << 8) | b;
}

static int near_rgb(unsigned a, unsigned b, int tol) {
    int i;
    for (i = 0; i < 3; ++i) {
        int d = (int)((a >> (i * 8)) & 0xFF) - (int)((b >> (i * 8)) & 0xFF);
        if (d < 0) d = -d;
        if (d > tol) return 0;
    }
    return 1;
}

/* --- composing one frame ------------------------------------------------- */

static SpdfWinChromeModel bare_model(int dark) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.dark = dark;
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.selected_tab = -1;
    m.drag_tab = -1;
    m.drop_slot = -1;
    m.page_index = -1;
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    return m;
}

static int compose(spdf_win_d2d* d2d, const SpdfWinChromeModel* m, const wchar_t* path) {
    spdf_win_scene scene;
    memset(&scene, 0, sizeof(scene));
    scene.fit = SPDF_WIN_FIT_CANVAS;
    scene.target_px_w = CLIENT_W;
    scene.target_px_h = CLIENT_H;
    scene.client_px_w = CLIENT_W;
    scene.client_px_h = CLIENT_H;
    scene.dpi_scale = 1.0f;
    scene.dark = m->dark;
    scene.chrome = m;
    return SUCCEEDED(spdf_win_render_scene_to_png(d2d, CLIENT_W, CLIENT_H, &scene, path));
}

/* Points inside each button that are OFF the glyph: the glyph is 10 px centred,
 * so 14 px left of the button's centre is fill, and the glyph's own centre row
 * is glyph for minimize (a full-width line) and for the maximize square's top
 * edge. */
static void button_fill_point(int button, unsigned* x, unsigned* y) {
    SpdfWinTabRect r = spdf_win_tabstrip_caption_rect((double)CLIENT_W, SPDF_WIN_TABSTRIP_HEIGHT, button);
    *x = (unsigned)(r.x + r.w / 2.0 - 14.0);
    *y = (unsigned)(r.h / 2.0 - 12.0);
}

/* The top-left pixel of the 10 px glyph box: the maximize square's corner is
 * ink there, and the restore glyph's front square starts 2 px lower and its
 * back square 2 px further right, so that pixel is band again when maximized. */
static void maximize_corner_point(unsigned* x, unsigned* y) {
    SpdfWinTabRect r =
        spdf_win_tabstrip_caption_rect((double)CLIENT_W, SPDF_WIN_TABSTRIP_HEIGHT, SPDF_WIN_CAPTION_MAXIMIZE);
    *x = (unsigned)(r.x + (r.w - 10.0) / 2.0);
    *y = (unsigned)((r.h - 10.0) / 2.0);
}

static void test_appearance(spdf_win_d2d* d2d, IWICImagingFactory* wic, int dark, const wchar_t* dir) {
    SpdfWinChromeTheme th = spdf_win_chrome_theme_for(dark);
    unsigned band = rgb_of(th.band);
    unsigned glyph = rgb_of(th.caption_glyph);
    wchar_t path[MAX_PATH];
    Frame f;
    unsigned fx, fy, cx, cy;
    SpdfWinChromeModel m;

    /* AT REST: every button is invisible -- band where there is no glyph -- and
     * the glyph is the label colour. */
    m = bare_model(dark);
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%s\\caption-rest-%s.png", dir, dark ? L"dark" : L"light");
    CHECK(compose(d2d, &m, path));
    CHECK(frame_load(wic, path, &f));
    button_fill_point(SPDF_WIN_CAPTION_MINIMIZE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), band, 1));
    button_fill_point(SPDF_WIN_CAPTION_MAXIMIZE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), band, 1));
    button_fill_point(SPDF_WIN_CAPTION_CLOSE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), band, 1));
    maximize_corner_point(&cx, &cy);
    CHECK(near_rgb(frame_rgb(&f, cx, cy), glyph, 1));
    /* The minimize line: the centre pixel of the button is ink. */
    {
        SpdfWinTabRect r =
            spdf_win_tabstrip_caption_rect((double)CLIENT_W, SPDF_WIN_TABSTRIP_HEIGHT, SPDF_WIN_CAPTION_MINIMIZE);
        CHECK(near_rgb(frame_rgb(&f, (unsigned)(r.x + r.w / 2.0), (unsigned)(r.h / 2.0)), glyph, 1));
        /* And the row above it is band: a 1 px line at 100%, not a smear. */
        CHECK(near_rgb(frame_rgb(&f, (unsigned)(r.x + r.w / 2.0), (unsigned)(r.h / 2.0) - 2), band, 1));
    }
    /* The buttons never bleed left into the `+`. */
    {
        SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect((double)CLIENT_W);
        CHECK(plus.x + plus.w <= (double)CLIENT_W - SPDF_WIN_TABSTRIP_TRAILING_INSET);
    }
    frame_free(&f);

    /* HOVER ON CLOSE: Windows 11's red, with a white glyph. */
    m = bare_model(dark);
    m.caption_hot = SPDF_WIN_CAPTION_CLOSE;
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%s\\caption-close-hot-%s.png", dir, dark ? L"dark" : L"light");
    CHECK(compose(d2d, &m, path));
    CHECK(frame_load(wic, path, &f));
    button_fill_point(SPDF_WIN_CAPTION_CLOSE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), 0xC42B1Cu, 1));
    /* The other two stay at rest. */
    button_fill_point(SPDF_WIN_CAPTION_MAXIMIZE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), band, 1));
    /* The X's centre pixel is white on red: both diagonals cross there. */
    {
        SpdfWinTabRect r =
            spdf_win_tabstrip_caption_rect((double)CLIENT_W, SPDF_WIN_TABSTRIP_HEIGHT, SPDF_WIN_CAPTION_CLOSE);
        unsigned c = frame_rgb(&f, (unsigned)(r.x + r.w / 2.0), (unsigned)(r.h / 2.0));
        CHECK(((c >> 8) & 0xFF) > 0xA0); /* far from the red's 0x2B green */
    }
    frame_free(&f);

    /* HOVER ON MAXIMIZE: the faint lift, computed from the theme's alpha. */
    m = bare_model(dark);
    m.caption_hot = SPDF_WIN_CAPTION_MAXIMIZE;
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%s\\caption-max-hot-%s.png", dir, dark ? L"dark" : L"light");
    CHECK(compose(d2d, &m, path));
    CHECK(frame_load(wic, path, &f));
    button_fill_point(SPDF_WIN_CAPTION_MAXIMIZE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), blend(band, th.caption_fill_hot), 2));
    CHECK(!near_rgb(frame_rgb(&f, fx, fy), band, 1)); /* visibly lifted */
    frame_free(&f);

    /* PRESSED wins over hot, and is a different step. */
    m = bare_model(dark);
    m.caption_hot = SPDF_WIN_CAPTION_MINIMIZE;
    m.caption_pressed = SPDF_WIN_CAPTION_MINIMIZE;
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%s\\caption-min-pressed-%s.png", dir, dark ? L"dark" : L"light");
    CHECK(compose(d2d, &m, path));
    CHECK(frame_load(wic, path, &f));
    button_fill_point(SPDF_WIN_CAPTION_MINIMIZE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), blend(band, th.caption_fill_pressed), 2));
    frame_free(&f);

    /* PRESSED CLOSE: the red at 90%. */
    m = bare_model(dark);
    m.caption_pressed = SPDF_WIN_CAPTION_CLOSE;
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%s\\caption-close-pressed-%s.png", dir, dark ? L"dark" : L"light");
    CHECK(compose(d2d, &m, path));
    CHECK(frame_load(wic, path, &f));
    button_fill_point(SPDF_WIN_CAPTION_CLOSE, &fx, &fy);
    CHECK(near_rgb(frame_rgb(&f, fx, fy), blend(band, th.caption_close_pressed), 2));
    frame_free(&f);

    /* MAXIMIZED: the restore glyph replaces the square, so the square's top-left
     * corner pixel is band again, and the fill state is unaffected. */
    m = bare_model(dark);
    m.maximized = 1;
    _snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%s\\caption-maximized-%s.png", dir, dark ? L"dark" : L"light");
    CHECK(compose(d2d, &m, path));
    CHECK(frame_load(wic, path, &f));
    maximize_corner_point(&cx, &cy);
    CHECK(near_rgb(frame_rgb(&f, cx, cy), band, 1));
    /* ...and the back square's top edge, 2 px right of the corner, is ink. */
    CHECK(near_rgb(frame_rgb(&f, cx + 2, cy), glyph, 1));
    /* The front square's left edge, 2 px down, is ink too. */
    CHECK(near_rgb(frame_rgb(&f, cx, cy + 2), glyph, 1));
    frame_free(&f);
}

int main(void) {
    char err[256] = {0};
    spdf_win_d2d* d2d;
    IWICImagingFactory* wic = NULL;
    wchar_t dir[MAX_PATH];
    HRESULT hr;

    if (!GetTempPathW(MAX_PATH, dir)) return 2;
    wcscat_s(dir, MAX_PATH, L"spdf-caption-paint");
    CreateDirectoryW(dir, NULL);

    d2d = spdf_win_d2d_create(err, sizeof(err));
    if (!d2d) {
        fprintf(stderr, "chrome_caption_paint_test: Direct2D unavailable: %s\n", err);
        return 2;
    }
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return 2;
    if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                                (void**)&wic)))
        return 2;

    test_appearance(d2d, wic, 0, dir);
    test_appearance(d2d, wic, 1, dir);

    IWICImagingFactory_Release(wic);
    spdf_win_d2d_destroy(d2d);
    printf("chrome_caption_paint_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
