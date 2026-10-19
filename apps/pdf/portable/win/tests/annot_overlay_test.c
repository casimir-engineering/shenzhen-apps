/* annot_overlay_test.c — pins the two comment-marker overlay kinds in PIXELS,
 * the way overlay_paint_test.c pins the search and selection marks.
 *
 * Values under test:
 *   COMMENT        fill calibrated(1.0, 0.76, 0.10, 0.16), stroke (0.92, 0.52,
 *                  0.0, 0.95) at 1.2, radius 3, rect grown 2
 *                  (SPDFMacDocumentView.mm:492-502)
 *   COMMENT_BADGE  fill (0.98, 0.74, 0.18, 0.92), 1 px border (0.55, 0.35,
 *                  0.0, 0.9) inside the edge (spdf_docview.c:1270-1282)
 *
 * Same technique: spdf_win_paint() needs no HWND, so the frame is composed
 * over a WIC bitmap with a SOFTWARE target; the page carries a NULL bitmap, so
 * its paper placeholder is the known flat backdrop. Every expectation is
 * computed from the source colour and the backdrop rather than pasted, so a
 * change to both the colour and the expectation together would still be
 * caught by the arithmetic in blend().
 */
/* spdf-test-sources: portable/win/src/spdf_win_d2d.cpp portable/win/src/spdf_win_chrome_paint.cpp portable/win/src/spdf_win_chrome_scrollbar.cpp portable/win/src/spdf_win_chrome_find.cpp portable/win/src/spdf_win_chrome_toolbar.cpp portable/win/src/spdf_win_chrome_panels.cpp portable/win/src/spdf_win_chrome_sidebar.cpp portable/win/src/spdf_win_chrome_minimap.cpp portable/win/src/spdf_win_chrome_content.cpp portable/win/src/spdf_win_chrome_thumbs.cpp portable/win/src/spdf_win_render.c portable/win/src/spdf_win_lru.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_win_compat.c portable/core/spdf_recolor.c portable/win/src/spdf_win_open.c */
/* spdf-test-needs: mupdf */

#include "spdf_win_d2d.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define FRAME_PX 240
#define PAGE_X 20
#define PAGE_Y 20
#define PAGE_W 200
#define PAGE_H 200

static void fail(const char* what, const char* file, int line) {
    fprintf(stderr, "FAIL %s (%s:%d)\n", what, file, line);
    ++g_failures;
}

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) fail(#cond, __FILE__, __LINE__);                                                                  \
    } while (0)

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

static unsigned frame_rgb(const Frame* f, unsigned x, unsigned y) {
    const unsigned char* p;
    if (!f->bgra || x >= f->w || y >= f->h) return 0xFF00FFu;
    p = f->bgra + ((size_t)y * f->w + x) * 4;
    return ((unsigned)p[2] << 16) | ((unsigned)p[1] << 8) | (unsigned)p[0];
}

static unsigned blend(unsigned backdrop_rgb, double r, double g, double b, double a) {
    double br = (double)((backdrop_rgb >> 16) & 0xFF);
    double bg = (double)((backdrop_rgb >> 8) & 0xFF);
    double bb = (double)(backdrop_rgb & 0xFF);
    unsigned orr = (unsigned)(r * 255.0 * a + br * (1.0 - a) + 0.5);
    unsigned og = (unsigned)(g * 255.0 * a + bg * (1.0 - a) + 0.5);
    unsigned ob = (unsigned)(b * 255.0 * a + bb * (1.0 - a) + 0.5);
    return (orr << 16) | (og << 8) | ob;
}

static int close_rgb(unsigned a, unsigned b, int tol) {
    int dr = (int)((a >> 16) & 0xFF) - (int)((b >> 16) & 0xFF);
    int dg = (int)((a >> 8) & 0xFF) - (int)((b >> 8) & 0xFF);
    int db = (int)(a & 0xFF) - (int)(b & 0xFF);
    return abs(dr) <= tol && abs(dg) <= tol && abs(db) <= tol;
}

static int compose(spdf_win_d2d* d2d, const spdf_win_overlay* overlays, int count, int dark, const wchar_t* out,
                   Frame* frame) {
    spdf_win_page_draw page;
    spdf_win_scene scene;
    memset(&page, 0, sizeof(page));
    page.bitmap = NULL;
    page.page_index = 0;
    page.dest_x = PAGE_X;
    page.dest_y = PAGE_Y;
    page.dest_w = PAGE_W;
    page.dest_h = PAGE_H;
    memset(&scene, 0, sizeof(scene));
    scene.pages = &page;
    scene.page_count = 1;
    scene.fit = SPDF_WIN_FIT_CANVAS;
    scene.target_px_w = FRAME_PX;
    scene.target_px_h = FRAME_PX;
    scene.dpi_scale = 1.0f;
    scene.dark = dark;
    scene.overlays = overlays;
    scene.overlay_count = count;
    if (FAILED(spdf_win_render_scene_to_png(d2d, FRAME_PX, FRAME_PX, &scene, out))) return 0;
    return frame_load(spdf_win_d2d_wic(d2d), out, frame);
}

int main(void) {
    char err[256] = {0};
    spdf_win_d2d* d2d = spdf_win_d2d_create(err, sizeof(err));
    wchar_t path[MAX_PATH];
    Frame f;
    spdf_win_overlay o[2];
    unsigned paper, want;
    int dark;

    if (!d2d) {
        fprintf(stderr, "FAIL spdf_win_d2d_create: %s\n", err);
        return 1;
    }
    GetTempPathW(MAX_PATH, path);
    wcscat_s(path, MAX_PATH, L"spdf_annot_overlay_test.png");

    for (dark = 0; dark <= 1; ++dark) {
        spdf_win_theme theme = spdf_win_theme_for(dark);
        paper = theme.paper_rgb;

        /* A comment frame over the middle of the page: 60x20 at (70, 90). */
        memset(o, 0, sizeof(o));
        o[0].kind = SPDF_WIN_OVERLAY_COMMENT;
        o[0].x = PAGE_X + 50;
        o[0].y = PAGE_Y + 70;
        o[0].w = 60;
        o[0].h = 20;
        o[0].alpha = 1.0f;
        /* And a badge, 12x12 at the frame's top-right corner (4 in, 8 out). */
        o[1].kind = SPDF_WIN_OVERLAY_COMMENT_BADGE;
        o[1].x = o[0].x + o[0].w - 4;
        o[1].y = o[0].y - 8;
        o[1].w = 12;
        o[1].h = 12;
        o[1].alpha = 1.0f;

        CHECK(compose(d2d, o, 2, dark, path, &f));
        if (!f.bgra) continue;
        /* Untouched paper well away from the marks. */
        CHECK(frame_rgb(&f, PAGE_X + 10, PAGE_Y + 10) == paper);
        /* Inside the frame: the 0.16 fill over paper. */
        want = blend(paper, 1.0, 0.76, 0.10, 0.16);
        CHECK(close_rgb(frame_rgb(&f, (unsigned)(o[0].x + 20), (unsigned)(o[0].y + 10)), want, 2));
        /* The frame is drawn 2 px OUTSIDE the rect: the stroke's centreline is
         * 2 px beyond the left edge. A 1.2 px stroke is antialiased across the
         * two pixels either side of it, so the test is for the stroke's
         * PRESENCE there -- the pixel has moved well off the paper towards the
         * stroke colour -- and, three pixels further out, for its absence. */
        want = blend(paper, 0.92, 0.52, 0.0, 0.95);
        CHECK(!close_rgb(frame_rgb(&f, (unsigned)(o[0].x - 2), (unsigned)(o[0].y + 10)), paper, 30));
        CHECK(frame_rgb(&f, (unsigned)(o[0].x - 6), (unsigned)(o[0].y + 10)) == paper);
        /* And one pixel further in the fill is back to the 0.16 tint, not the
         * stroke: the stroke did not smear inward. */
        CHECK(!close_rgb(frame_rgb(&f, (unsigned)(o[0].x + 4), (unsigned)(o[0].y + 10)), want, 40));
        /* The badge: the 0.92 fill at its centre... */
        want = blend(paper, 0.98, 0.74, 0.18, 0.92);
        CHECK(close_rgb(frame_rgb(&f, (unsigned)(o[1].x + 6), (unsigned)(o[1].y + 6)), want, 3));
        /* ...and the dark border on its edge pixel. */
        want = blend(paper, 0.55, 0.35, 0.0, 0.9);
        CHECK(close_rgb(frame_rgb(&f, (unsigned)(o[1].x + 6), (unsigned)(o[1].y)), want, 40));
        /* The badge draws OVER the frame where they overlap (array order). */
        want = blend(paper, 0.98, 0.74, 0.18, 0.92);
        CHECK(close_rgb(frame_rgb(&f, (unsigned)(o[1].x + 2), (unsigned)(o[1].y + 10)), want, 6));
        free(f.bgra);
    }

    /* alpha multiplies the kind's own alpha, as for the other kinds. */
    {
        spdf_win_theme theme = spdf_win_theme_for(0);
        memset(o, 0, sizeof(o));
        o[0].kind = SPDF_WIN_OVERLAY_COMMENT;
        o[0].x = PAGE_X + 50;
        o[0].y = PAGE_Y + 70;
        o[0].w = 60;
        o[0].h = 20;
        o[0].alpha = 0.5f;
        CHECK(compose(d2d, o, 1, 0, path, &f));
        if (f.bgra) {
            want = blend(theme.paper_rgb, 1.0, 0.76, 0.10, 0.08);
            CHECK(close_rgb(frame_rgb(&f, (unsigned)(o[0].x + 20), (unsigned)(o[0].y + 10)), want, 2));
            free(f.bgra);
        }
    }

    spdf_win_d2d_destroy(d2d);
    DeleteFileW(path);
    printf("[annot_overlay_test] %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
