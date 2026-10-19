/* overlay_paint_test.c — pins the search/selection overlay marks in PIXELS.
 *
 * The three overlay kinds are the marks drawn over a page: the all-matches
 * search highlight, the active match's outline, and the text selection. Their
 * colours are hard-coded and THEME-INDEPENDENT on macOS, in both canvases, and
 * windows-port-handoff.md §3.3 says explicitly not to route them through the
 * palette. This suite is what stops someone doing that anyway: it composes real
 * frames through the real paint path and reads the bytes back.
 *
 * Values under test, from portable/mac/SPDFMacDocumentView.mm:
 *   all matches   calibrated(1.0, 0.84, 0.12, 0.38), rounded radius 2.0  :467-473
 *   active match  stroke calibrated(0.94, 0.03, 0.02, a), rect grown 2,
 *                 lineWidth 1.2                                          :475-482
 *   selection     calibrated(0.40, 0.62, 0.86, 0.20), square fill        :485, :11
 *
 * WHY IT NEEDS NO WINDOW AND NO DOCUMENT. spdf_win_paint() never requires an
 * HWND, so spdf_win_render_scene_to_png() composes the same frame over a WIC
 * bitmap with a SOFTWARE target. The pages carry a NULL bitmap, which makes the
 * canvas draw its paper placeholder — a known flat colour, which is exactly what
 * a blend test wants underneath. Same trick d2d_theme_test.c uses.
 *
 * The alpha values are the point of this suite, so every expectation is computed
 * from the source colour and the known backdrop rather than pasted as a literal:
 * a test that hard-codes the blended result would pass just as happily if
 * someone changed both the colour and the expectation together.
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
/* The page slot inside the frame. Whole numbers so nothing here depends on the
 * pixel-snapping in draw_canvas_page. */
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

/* --- reading the composed frame back ------------------------------------ */

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

/* 0xRRGGBB at (x, y). */
static unsigned frame_rgb(const Frame* f, unsigned x, unsigned y) {
    const unsigned char* p;
    if (!f->bgra || x >= f->w || y >= f->h) return 0xFF00FFu; /* magenta: out of range */
    p = f->bgra + ((size_t)y * f->w + x) * 4;
    return ((unsigned)p[2] << 16) | ((unsigned)p[1] << 8) | (unsigned)p[0];
}

/* --- the expectation, computed rather than pasted ----------------------- */

/* Source-over of a straight-alpha colour onto an opaque backdrop, per channel,
 * rounded the way a rasteriser rounds. This is the arithmetic the expectation
 * has to agree with; writing it out is what makes the test about the ALPHA
 * rather than about a magic number. */
static unsigned blend(unsigned backdrop_rgb, double r, double g, double b, double a) {
    double br = (double)((backdrop_rgb >> 16) & 0xFF);
    double bg = (double)((backdrop_rgb >> 8) & 0xFF);
    double bb = (double)(backdrop_rgb & 0xFF);
    unsigned orr = (unsigned)(r * 255.0 * a + br * (1.0 - a) + 0.5);
    unsigned og = (unsigned)(g * 255.0 * a + bg * (1.0 - a) + 0.5);
    unsigned ob = (unsigned)(b * 255.0 * a + bb * (1.0 - a) + 0.5);
    if (orr > 255) orr = 255;
    if (og > 255) og = 255;
    if (ob > 255) ob = 255;
    return (orr << 16) | (og << 8) | ob;
}

/* Channel-wise closeness. A rasteriser may round a blend differently by a bit,
 * and antialiasing at a rounded corner is real; 3 is loose enough for that and
 * far tighter than any wrong colour or wrong alpha would be. A wrong alpha on
 * these three marks moves a channel by tens. */
static int near_rgb(unsigned a, unsigned b, int tol) {
    int i;
    for (i = 0; i < 3; ++i) {
        int shift = i * 8;
        int d = (int)((a >> shift) & 0xFF) - (int)((b >> shift) & 0xFF);
        if (d < 0) d = -d;
        if (d > tol) return 0;
    }
    return 1;
}

/* --- composing one frame ------------------------------------------------ */

static int compose(spdf_win_d2d* d2d, int dark, const spdf_win_overlay* overlays, int overlay_count,
                   const wchar_t* path, Frame* out) {
    spdf_win_scene scene;
    spdf_win_page_draw page;
    HRESULT hr;

    memset(&scene, 0, sizeof(scene));
    memset(&page, 0, sizeof(page));
    page.bitmap = NULL; /* paper placeholder: a known flat backdrop */
    page.page_index = 0;
    page.dest_x = (float)PAGE_X;
    page.dest_y = (float)PAGE_Y;
    page.dest_w = (float)PAGE_W;
    page.dest_h = (float)PAGE_H;

    scene.fit = SPDF_WIN_FIT_CANVAS;
    scene.pages = &page;
    scene.page_count = 1;
    scene.target_px_w = FRAME_PX;
    scene.target_px_h = FRAME_PX;
    scene.dpi_scale = 1.0f;
    scene.dark = dark;
    scene.overlays = overlays;
    scene.overlay_count = overlay_count;
    /* No chrome: this suite is about the marks, and chrome would move the page. */
    scene.chrome = NULL;

    hr = spdf_win_render_scene_to_png(d2d, FRAME_PX, FRAME_PX, &scene, path);
    if (FAILED(hr)) {
        fprintf(stderr, "FAIL compose hr=0x%08lX\n", (unsigned long)hr);
        ++g_failures;
        return 0;
    }
    return frame_load(spdf_win_d2d_wic(d2d), path, out);
}

static spdf_win_overlay mk(int kind, float x, float y, float w, float h, float alpha) {
    spdf_win_overlay o;
    memset(&o, 0, sizeof(o));
    o.page_index = 0;
    o.x = x;
    o.y = y;
    o.w = w;
    o.h = h;
    o.kind = kind;
    o.alpha = alpha;
    return o;
}

int main(void) {
    char err[256] = {0};
    spdf_win_d2d* d2d = spdf_win_d2d_create(err, sizeof(err));
    const wchar_t* png = L"overlay_paint_test.png";
    int theme;

    if (!d2d) {
        fprintf(stderr, "FAIL spdf_win_d2d_create: %s\n", err[0] ? err : "unknown");
        return 1;
    }

    for (theme = 0; theme <= 1; ++theme) {
        /* The page underlay: #FFFFFF light, #1E1E1E dark. That is the backdrop
         * every blend below is computed against, and asserting it first means a
         * later failure cannot be blamed on the wrong ground. */
        unsigned paper = theme ? 0x1E1E1Eu : 0xFFFFFFu;
        Frame f;

        /* --- no overlays: the page is untouched ------------------------- */
        if (compose(d2d, theme, NULL, 0, png, &f)) {
            CHECK(frame_rgb(&f, PAGE_X + 100, PAGE_Y + 100) == paper);
            frame_free(&f);
        } else {
            CHECK(0);
        }

        /* --- all-matches highlight ------------------------------------- */
        {
            spdf_win_overlay o = mk(SPDF_WIN_OVERLAY_SEARCH_MATCH, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 80.0f,
                                    40.0f, 1.0f);
            if (compose(d2d, theme, &o, 1, png, &f)) {
                unsigned want = blend(paper, 1.0, 0.84, 0.12, 0.38);
                /* Centre of the highlight, well clear of the 2 pt corner radius. */
                unsigned got = frame_rgb(&f, PAGE_X + 80, PAGE_Y + 60);
                if (!near_rgb(got, want, 3)) {
                    fprintf(stderr, "FAIL match highlight theme=%d got #%06X want #%06X\n", theme, got, want);
                    ++g_failures;
                }
                ++g_checks;
                /* Outside it, the page is still the page. */
                CHECK(frame_rgb(&f, PAGE_X + 10, PAGE_Y + 10) == paper);
                /* The mark must be INSIDE the page, not over the gutter. */
                CHECK(frame_rgb(&f, PAGE_X / 2, PAGE_Y / 2) != want);
                frame_free(&f);
            } else {
                CHECK(0);
            }
        }

        /* --- active match: an OUTLINE, and a hollow one ----------------- */
        {
            spdf_win_overlay o = mk(SPDF_WIN_OVERLAY_SEARCH_ACTIVE, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 80.0f,
                                    40.0f, 1.0f);
            if (compose(d2d, theme, &o, 1, png, &f)) {
                unsigned got_ring = frame_rgb(&f, PAGE_X + 40 - 2, PAGE_Y + 60);
                /* The ring sits 2 px OUTSIDE the rect: macOS's NSInsetRect with
                 * negative deltas GROWS it, so the outline clears the glyphs
                 * instead of striking through them. Sample the left edge of the
                 * grown rect, vertically centred.
                 *
                 * ASSERTED AS A PROPERTY, NOT A COLOUR, and deliberately. A
                 * 1.2 px stroke centred on a whole-pixel boundary spans 0.6 of
                 * each of two columns, so NO pixel on a vertical edge ever
                 * reaches full coverage: measured #F66563 on white and #A1100E
                 * on #1E1E1E, against a pure stroke of #F00805. Widening the
                 * tolerance until those pass would admit almost any colour and
                 * assert nothing. What actually distinguishes "the ring is there
                 * and it is the red macOS specifies" from every failure mode --
                 * no ring, wrong colour, a filled rect, the ring drawn inside --
                 * is that the pixel is strongly red-dominant and is not the
                 * page. */
                int rr = (int)((got_ring >> 16) & 0xFF);
                int gg = (int)((got_ring >> 8) & 0xFF);
                int bb = (int)(got_ring & 0xFF);
                int other = gg > bb ? gg : bb;
                if (rr - other < 60) {
                    fprintf(stderr, "FAIL active ring theme=%d got #%06X is not red-dominant\n", theme, got_ring);
                    ++g_failures;
                }
                ++g_checks;
                CHECK(got_ring != paper);
                /* HOLLOW: the middle must still be paper. This is the property
                 * that separates an outline from a fill, and the one a
                 * well-meaning "simplification" to FillRectangle would break. */
                CHECK(frame_rgb(&f, PAGE_X + 80, PAGE_Y + 60) == paper);
                frame_free(&f);
            } else {
                CHECK(0);
            }
        }

        /* --- selection: a SQUARE fill ---------------------------------- */
        {
            spdf_win_overlay o = mk(SPDF_WIN_OVERLAY_SELECTION, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 80.0f,
                                    40.0f, 1.0f);
            if (compose(d2d, theme, &o, 1, png, &f)) {
                unsigned want = blend(paper, 0.40, 0.62, 0.86, 0.20);
                unsigned got = frame_rgb(&f, PAGE_X + 80, PAGE_Y + 60);
                if (!near_rgb(got, want, 3)) {
                    fprintf(stderr, "FAIL selection theme=%d got #%06X want #%06X\n", theme, got, want);
                    ++g_failures;
                }
                ++g_checks;
                /* Square, not rounded: the very corner is filled. macOS's
                 * Markdown canvas rounds its selection; the PDF canvas does not
                 * (SPDFMacDocumentView.mm:485 versus
                 * SPDFMacMarkdownPageCanvas.mm:193-197). */
                got = frame_rgb(&f, PAGE_X + 40, PAGE_Y + 40);
                if (!near_rgb(got, want, 3)) {
                    fprintf(stderr, "FAIL selection corner theme=%d got #%06X want #%06X\n", theme, got, want);
                    ++g_failures;
                }
                ++g_checks;
                frame_free(&f);
            } else {
                CHECK(0);
            }
        }

        /* --- alpha multiplies, and 0 draws nothing visible ------------- */
        {
            spdf_win_overlay o = mk(SPDF_WIN_OVERLAY_SELECTION, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 80.0f,
                                    40.0f, 0.5f);
            if (compose(d2d, theme, &o, 1, png, &f)) {
                unsigned want = blend(paper, 0.40, 0.62, 0.86, 0.20 * 0.5);
                unsigned got = frame_rgb(&f, PAGE_X + 80, PAGE_Y + 60);
                if (!near_rgb(got, want, 3)) {
                    fprintf(stderr, "FAIL selection alpha theme=%d got #%06X want #%06X\n", theme, got, want);
                    ++g_failures;
                }
                ++g_checks;
                frame_free(&f);
            } else {
                CHECK(0);
            }
        }

        /* --- ordering: later overlays draw over earlier ones ------------ */
        {
            spdf_win_overlay o[2];
            o[0] = mk(SPDF_WIN_OVERLAY_SEARCH_MATCH, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 80.0f, 40.0f, 1.0f);
            o[1] = mk(SPDF_WIN_OVERLAY_SELECTION, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 80.0f, 40.0f, 1.0f);
            if (compose(d2d, theme, o, 2, png, &f)) {
                unsigned only_match = blend(paper, 1.0, 0.84, 0.12, 0.38);
                unsigned both = blend(only_match, 0.40, 0.62, 0.86, 0.20);
                unsigned got = frame_rgb(&f, PAGE_X + 80, PAGE_Y + 60);
                /* Selection over highlight, not the other way round. */
                if (!near_rgb(got, both, 3)) {
                    fprintf(stderr, "FAIL overlay order theme=%d got #%06X want #%06X\n", theme, got, both);
                    ++g_failures;
                }
                ++g_checks;
                frame_free(&f);
            } else {
                CHECK(0);
            }
        }

        /* --- degenerate marks are skipped, not drawn as artefacts ------- */
        {
            spdf_win_overlay o[3];
            o[0] = mk(SPDF_WIN_OVERLAY_SELECTION, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 0.0f, 40.0f, 1.0f);
            o[1] = mk(SPDF_WIN_OVERLAY_SELECTION, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), 80.0f, 0.0f, 1.0f);
            o[2] = mk(SPDF_WIN_OVERLAY_SELECTION, (float)(PAGE_X + 40), (float)(PAGE_Y + 40), -10.0f, -10.0f, 1.0f);
            if (compose(d2d, theme, o, 3, png, &f)) {
                CHECK(frame_rgb(&f, PAGE_X + 80, PAGE_Y + 60) == paper);
                CHECK(frame_rgb(&f, PAGE_X + 40, PAGE_Y + 40) == paper);
                frame_free(&f);
            } else {
                CHECK(0);
            }
        }
    }

    spdf_win_d2d_destroy(d2d);
    _wremove(png);

    printf("overlay_paint_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
