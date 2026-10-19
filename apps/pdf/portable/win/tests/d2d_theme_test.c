/* The reading theme of the Direct2D compose path, pinned in pixels.
 *
 * WHAT THIS EXISTS TO STOP.
 *
 * Three of the theme's values were wrong at once and every one of them was a
 * literal typed at a draw site, so nothing could disagree with anything:
 *
 *   - the dark gutter was #212123, *lighter* than the paper it surrounds;
 *   - the dark paper placeholder was #1D1D1F, off the palette and carrying a
 *     blue tint the palette does not have;
 *   - the 10%-black page-separation band was drawn in BOTH themes, where macOS
 *     draws a shadow in light and a 1 px #333333 frame in dark instead --
 *     because on the #121212 gutter a black shadow is invisible, so only one
 *     page edge would ever read (SPDFMacDocumentViewTheme.mm:44-58).
 *
 * The first two are one-line constants and a constant is not a behaviour, so
 * this file does not stop at reading them back: it composes a real FIT_CANVAS
 * frame through spdf_win_paint() and looks at the pixels that came out. The
 * gutter, the paper, the presence of the light band and the presence of the
 * dark frame are each read at a named coordinate.
 *
 * NO WINDOW AND NO DOCUMENT ARE INVOLVED, which is the whole point of
 * spdf_win_d2d.h's no-HWND rule: the frame goes through
 * spdf_win_render_scene_to_png()'s SOFTWARE render target, and the pages carry a
 * NULL bitmap so the paper placeholder is what gets drawn. So this suite needs
 * neither MuPDF nor a desktop session, and it is the first C translation unit to
 * include spdf_win_d2d.h -- which that header claims to support and until now
 * nothing exercised.
 *
 * The dark paper is checked twice over: against the palette literal #1E1E1E
 * (SPDFMarkdownTheme.mm:23) AND against what portable/core's luma remap actually
 * produces for document white. Those two must be the same number or a fractional
 * zoom shows a mismatched sliver around a recoloured page, and asserting the
 * second is how the two files can never drift apart silently.
 */
/* spdf-test-sources: portable/win/src/spdf_win_d2d.cpp portable/win/src/spdf_win_chrome_paint.cpp portable/win/src/spdf_win_chrome_scrollbar.cpp portable/win/src/spdf_win_chrome_find.cpp portable/win/src/spdf_win_chrome_toolbar.cpp portable/win/src/spdf_win_chrome_panels.cpp portable/win/src/spdf_win_chrome_sidebar.cpp portable/win/src/spdf_win_chrome_minimap.cpp portable/win/src/spdf_win_chrome_content.cpp portable/win/src/spdf_win_chrome_thumbs.cpp portable/win/src/spdf_win_render.c portable/win/src/spdf_win_lru.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_win_compat.c portable/core/spdf_recolor.c portable/win/src/spdf_win_open.c */
/* spdf-test-needs: mupdf */
/* The spdf_win_chrome_*.cpp units are here because spdf_win_paint() now calls
 * spdf_win_chrome_paint_all(). This suite passes scene.chrome == NULL, so none
 * of that code RUNS -- but it still has to LINK, and omitting a translation
 * unit from a Windows link line produces a wall of LNK2019 rather than an error
 * at the file that wanted it (portable/win/README.md's gotcha about
 * spdf_win_compat.c is the same trap).
 *
 * The list grew when the sidebar and minimap were given real content: the
 * panels painter now reaches spdf_win_chrome_content.cpp, which reaches the
 * thumbnail store, which reaches spdf_win_render.c and the core. Hence the
 * `spdf-test-needs: mupdf` line -- this suite still needs no document and no
 * desktop, but it now needs libmupdf on the LINK line. None of that code runs
 * here, for the same reason as above: scene.chrome is NULL, so
 * spdf_win_chrome_paint_panels() is never called and no document is ever
 * opened. */

#include "spdf_win_d2d.h"

#include "spdf_recolor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "windowscodecs.lib")

static int failures;

static void expect(int condition, const char* what) {
    if (!condition) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

/* --- the theme table, with no device at all ------------------------------- */

static void test_theme_table(void) {
    spdf_win_theme light = spdf_win_theme_for(0);
    spdf_win_theme dark = spdf_win_theme_for(1);

    printf("light gutter=%06X paper=%06X border=%06X shadow=%d frame=%d\n", light.gutter_rgb, light.paper_rgb,
           light.page_border_rgb, light.draws_page_shadow, light.draws_page_border);
    printf("dark  gutter=%06X paper=%06X border=%06X shadow=%d frame=%d\n", dark.gutter_rgb, dark.paper_rgb,
           dark.page_border_rgb, dark.draws_page_shadow, dark.draws_page_border);

    /* SPDFMarkdownTheme.mm:23-27, the reading theme for the whole app. */
    expect(light.paper_rgb == 0xFFFFFFu, "light paper is #FFFFFF");
    expect(light.page_border_rgb == 0xD0D7DEu, "light paper border is #D0D7DE");
    expect(dark.gutter_rgb == 0x121212u, "dark gutter is #121212, not #212123");
    expect(dark.paper_rgb == 0x1E1E1Eu, "dark paper is #1E1E1E, not #1D1D1F");
    expect(dark.page_border_rgb == 0x333333u, "dark paper border is #333333");

    /* The defect that made #212123 obviously wrong rather than merely off: a
     * gutter must be darker than the sheet lying on it, in either theme. */
    expect(dark.gutter_rgb < dark.paper_rgb, "the dark gutter is darker than the dark paper");
    expect(light.gutter_rgb < light.paper_rgb, "the light gutter is darker than the light paper");

    /* drawsPaperShadow is a seam, not two independent flags. */
    expect(light.draws_page_shadow && !light.draws_page_border, "light separates with a shadow only");
    expect(dark.draws_page_border && !dark.draws_page_shadow, "dark separates with a border only");

    /* No blue tint anywhere in the dark greys -- #1D1D1F had one. */
    expect((dark.paper_rgb & 0xFFu) == ((dark.paper_rgb >> 8) & 0xFFu) &&
               ((dark.paper_rgb >> 8) & 0xFFu) == ((dark.paper_rgb >> 16) & 0xFFu),
           "the dark paper is a neutral grey");
    expect((dark.gutter_rgb & 0xFFu) == ((dark.gutter_rgb >> 8) & 0xFFu) &&
               ((dark.gutter_rgb >> 8) & 0xFFu) == ((dark.gutter_rgb >> 16) & 0xFFu),
           "the dark gutter is a neutral grey");
}

/* The paper placeholder must be the very colour the recolor transform turns
 * document white into, or the placeholder and the page it stands in for are two
 * different greys. Measured through the real transform rather than restating
 * spdf_recolor.h's arithmetic. */
static void test_paper_matches_the_recolor_endpoint(void) {
    spdf_recolor_theme theme = spdf_recolor_default_dark_theme();
    spdf_recolor_table table;
    unsigned char white[4];
    unsigned int produced;

    expect(theme.paper_rgb == spdf_win_theme_for(1).paper_rgb, "the dark paper is the recolor paper endpoint");

    white[0] = 255;
    white[1] = 255;
    white[2] = 255;
    white[3] = 255;
    spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, theme);
    spdf_recolor_rgba(white, 1, 1, 4, &table);
    produced = ((unsigned int)white[0] << 16) | ((unsigned int)white[1] << 8) | (unsigned int)white[2];
    printf("luma remap of white = %06X (alpha %u)\n", produced, (unsigned)white[3]);
    expect(produced == spdf_win_theme_for(1).paper_rgb, "the dark paper is what the luma remap makes of white");
}

/* --- one composed frame, read back pixel by pixel ------------------------- */

/* The frame is 64x64 with one page at (12,12) sized 40x40, so every region has a
 * coordinate that belongs to it and nothing else:
 *
 *   x=3            far gutter
 *   x=10..11       the light shadow band (dest.left - 2 .. dest.left)
 *   x=12, x=51     the page's outer columns -- the dark frame
 *   x=30           page interior
 *   y=53           the light shadow band below the page (dest.bottom + 3)
 *   y=11           just above the page: no band, because the shade rect's top
 *                  IS dest.top (there is no top offset)
 */
#define FRAME_PX 64
#define PAGE_X 12
#define PAGE_Y 12
#define PAGE_W 40
#define PAGE_H 40

static unsigned char* frame_bgra;
static unsigned frame_w;
static unsigned frame_h;

static unsigned int pixel_rgb(unsigned x, unsigned y) {
    const unsigned char* p;
    if (!frame_bgra || x >= frame_w || y >= frame_h) return 0xFFFFFFFFu;
    p = frame_bgra + ((size_t)y * frame_w + x) * 4u;
    return ((unsigned int)p[2] << 16) | ((unsigned int)p[1] << 8) | (unsigned int)p[0];
}

static int luma_sum(unsigned int rgb) {
    return (int)((rgb >> 16) & 0xFFu) + (int)((rgb >> 8) & 0xFFu) + (int)(rgb & 0xFFu);
}

/* Decode the PNG spdf_win_paint() just produced. WIC through COBJMACROS, which
 * is why spdf_win_d2d.h defines it: the same factory the compose layer already
 * owns, so no second imaging dependency enters the test. */
static int load_frame(spdf_win_d2d* d2d, const wchar_t* path) {
    IWICImagingFactory* wic = spdf_win_d2d_wic(d2d);
    IWICBitmapDecoder* decoder = NULL;
    IWICBitmapFrameDecode* frame = NULL;
    IWICBitmapSource* bgra = NULL;
    HRESULT hr;

    free(frame_bgra);
    frame_bgra = NULL;
    frame_w = frame_h = 0;
    if (!wic) return 0;

    hr = IWICImagingFactory_CreateDecoderFromFilename(wic, path, NULL, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                                      &decoder);
    if (SUCCEEDED(hr)) hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame);
    /* &GUID, not GUID: in C, REFWICPixelFormatGUID is a pointer, where the C++
     * bindings spdf_win_d2d.cpp uses make it a reference. */
    if (SUCCEEDED(hr)) hr = WICConvertBitmapSource(&GUID_WICPixelFormat32bppBGRA, (IWICBitmapSource*)frame, &bgra);
    if (SUCCEEDED(hr)) hr = IWICBitmapSource_GetSize(bgra, &frame_w, &frame_h);
    if (SUCCEEDED(hr) && frame_w && frame_h) {
        size_t bytes = (size_t)frame_w * frame_h * 4u;
        frame_bgra = (unsigned char*)malloc(bytes);
        if (!frame_bgra) hr = E_OUTOFMEMORY;
        else hr = IWICBitmapSource_CopyPixels(bgra, NULL, frame_w * 4u, (UINT)bytes, frame_bgra);
    }
    if (bgra) IWICBitmapSource_Release(bgra);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (FAILED(hr)) {
        printf("FAIL could not read the composed frame back (hr=0x%08lX)\n", (unsigned long)hr);
        failures++;
        return 0;
    }
    return 1;
}

static int compose_frame(spdf_win_d2d* d2d, int dark, const wchar_t* path) {
    spdf_win_page_draw page;
    spdf_win_scene scene;
    HRESULT hr;

    memset(&page, 0, sizeof(page));
    page.bitmap = NULL; /* the paper placeholder is exactly what we want to read */
    page.page_index = 0;
    page.dest_x = (float)PAGE_X;
    page.dest_y = (float)PAGE_Y;
    page.dest_w = (float)PAGE_W;
    page.dest_h = (float)PAGE_H;

    memset(&scene, 0, sizeof(scene));
    scene.fit = SPDF_WIN_FIT_CANVAS;
    scene.pages = &page;
    scene.page_count = 1;
    scene.dpi_scale = 1.0f;
    scene.dark = dark;

    hr = spdf_win_render_scene_to_png(d2d, FRAME_PX, FRAME_PX, &scene, path);
    if (FAILED(hr)) {
        printf("FAIL compose failed for dark=%d (hr=0x%08lX)\n", dark, (unsigned long)hr);
        failures++;
        return 0;
    }
    return load_frame(d2d, path);
}

static void test_light_frame(spdf_win_d2d* d2d, const wchar_t* path) {
    unsigned int gutter, band_left, band_below, edge, interior;
    if (!compose_frame(d2d, 0, path)) return;

    gutter = pixel_rgb(3, 3);
    band_left = pixel_rgb(10, 30);
    band_below = pixel_rgb(30, 53);
    edge = pixel_rgb(PAGE_X, 30);
    interior = pixel_rgb(30, 30);
    printf("light gutter=%06X band=%06X below=%06X edge=%06X interior=%06X above=%06X\n", gutter, band_left, band_below,
           edge, interior, pixel_rgb(30, 11));

    expect(gutter == 0xE0E0E2u, "the light surround is #E0E0E2");
    expect(interior == 0xFFFFFFu, "the light paper placeholder is #FFFFFF");
    /* The band's exact value is a 10%-black composite over the gutter and its
     * rounding is D2D's business; that it is DARKER than the gutter is the
     * behaviour, and it is the behaviour dark must not have. */
    expect(luma_sum(band_left) < luma_sum(gutter), "light draws a shadow band beside the page");
    expect(luma_sum(band_below) < luma_sum(gutter), "light draws a shadow band below the page");
    expect(pixel_rgb(30, 11) == gutter, "there is no band above the page in either theme");
    expect(edge == 0xFFFFFFu, "light does not frame the page: its outer column is paper");
}

static void test_dark_frame(spdf_win_d2d* d2d, const wchar_t* path) {
    unsigned int gutter, beside, below, interior;
    if (!compose_frame(d2d, 1, path)) return;

    gutter = pixel_rgb(3, 3);
    beside = pixel_rgb(10, 30);
    below = pixel_rgb(30, 53);
    interior = pixel_rgb(30, 30);
    printf("dark  gutter=%06X beside=%06X below=%06X interior=%06X frame=%06X/%06X/%06X/%06X\n", gutter, beside, below,
           interior, pixel_rgb(PAGE_X, 30), pixel_rgb(PAGE_X + PAGE_W - 1, 30), pixel_rgb(30, PAGE_Y),
           pixel_rgb(30, PAGE_Y + PAGE_H - 1));

    expect(gutter == 0x121212u, "the dark surround is #121212");
    expect(interior == 0x1E1E1Eu, "the dark paper placeholder is #1E1E1E");
    expect(luma_sum(gutter) < luma_sum(interior), "the composed dark gutter is darker than the composed paper");

    /* THE FIX: no 10%-black band in dark. Every pixel that would have been
     * shaded is plain gutter. */
    expect(beside == gutter, "dark draws no shadow band beside the page");
    expect(below == gutter, "dark draws no shadow band below the page");
    expect(pixel_rgb(30, 11) == gutter, "there is no band above the page in either theme");

    /* ...and all four page edges carry the border instead, which is the reason
     * the band could be dropped. The half-stroke inset is what makes these
     * exact rather than antialiased. */
    expect(pixel_rgb(PAGE_X, 30) == 0x333333u, "the dark page's left edge is a #333333 frame");
    expect(pixel_rgb(PAGE_X + PAGE_W - 1, 30) == 0x333333u, "the dark page's right edge is a #333333 frame");
    expect(pixel_rgb(30, PAGE_Y) == 0x333333u, "the dark page's top edge is a #333333 frame");
    expect(pixel_rgb(30, PAGE_Y + PAGE_H - 1) == 0x333333u, "the dark page's bottom edge is a #333333 frame");
    expect(pixel_rgb(PAGE_X + 1, 30) == 0x1E1E1Eu, "the frame is one pixel wide at dpi_scale 1");
}

int main(void) {
    wchar_t dir[MAX_PATH];
    wchar_t path[MAX_PATH + 64];
    spdf_win_d2d* d2d;
    char err[256] = {0};

    printf("== d2d reading theme transcript ==\n");
    test_theme_table();
    test_paper_matches_the_recolor_endpoint();

    d2d = spdf_win_d2d_create(err, sizeof(err));
    if (!d2d) {
        /* Direct2D missing is a real failure on a machine that ships the app,
         * and the message is the diagnosis. */
        printf("FAIL Direct2D is unavailable: %s\n", err[0] ? err : "unknown error");
        printf("== %d failures ==\n", failures + 1);
        return 1;
    }
    if (!GetTempPathW(MAX_PATH, dir)) dir[0] = L'\0';
    _snwprintf_s(path, MAX_PATH + 64, _TRUNCATE, L"%sspdf_d2d_theme_test.png", dir);
    test_light_frame(d2d, path);
    test_dark_frame(d2d, path);
    DeleteFileW(path);
    free(frame_bgra);
    spdf_win_d2d_destroy(d2d);

    printf("== %d failures ==\n", failures);
    return failures == 0 ? 0 : 1;
}
