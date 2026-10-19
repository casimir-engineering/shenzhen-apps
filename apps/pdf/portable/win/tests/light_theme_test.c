/* light_theme_test.c -- THE REGRESSION THAT THIS WHOLE TRACK EXISTS TO PROTECT.
 *
 * portable/docs/windows-port-handoff.md section 4, settled and not to be
 * relitigated:
 *
 *     Print, Save as PDF, Copy Page and Copy Page Image always render the LIGHT
 *     theme, even while the user is reading in dark. SPDF_RENDER_DARK_THEME is
 *     opt-in per render precisely so these get the document's own colours by
 *     doing nothing. A file that left the app with our dark paper baked in
 *     would be wrong everywhere it lands.
 *
 * "Do nothing" is the correct implementation and it is also the one that rots.
 * A future reader threading the app's `render_flags` into a print or export
 * call would produce code that looks MORE consistent than the code that is
 * right, and every other test in this repository would still pass. So this
 * suite exists, and it checks the rule THREE WAYS, because each one catches a
 * different way of getting it wrong:
 *
 *   1. THE FLAG WORD. spdf_win_export_render_flags() is SPDF_RENDER_DEFAULT and
 *      carries neither theme bit. Catches somebody editing that function.
 *
 *   2. THE PIXELS THROUGH EACH PATH. What spdf_win_clipboard_render_page()
 *      produces is byte-identical to an explicit light render and DIFFERENT
 *      from an explicit dark one, and the same holds after the CF_DIB packing.
 *      Catches somebody routing around the function -- calling
 *      spdf_render_page_rgba_opts directly with the reading theme -- which the
 *      first check cannot see.
 *
 *   3. THE PRINTED SHEET. A page put through spdf_win_print_page_to_dc() onto a
 *      memory DC comes out with LIGHT paper. Catches the same mistake in the
 *      print path, which has its own render call.
 *
 * EVERY CHECK IS PAIRED WITH ITS OWN NEGATIVE. A test that asserts "this is
 * light" proves nothing unless it also demonstrates that it would have noticed
 * dark, so each comparison is made against an explicit dark render taken here,
 * and the suite fails if that dark render is NOT distinguishable. Without that,
 * a change to the recolour transform could quietly make the whole file vacuous.
 *
 * A locked workstation does not affect any of this: no clipboard is opened, no
 * dialog is shown and no printer is touched. A memory DC is all check 3 needs,
 * and if even that cannot be created the case reports SKIP with the OS error
 * rather than failing for a reason that is not about this code.
 */
/* spdf-test-sources: portable/win/src/spdf_win_export.cpp portable/win/src/spdf_win_clipboard_page.cpp portable/win/src/spdf_win_print.cpp portable/win/src/spdf_win_selection.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
/* spdf-test-needs: mupdf */
#include <windows.h>

#include "shenzhen_pdf_core.h"
#include "spdf_win_clipboard_page.h"
#include "spdf_win_export.h"
#include "spdf_win_print.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;
static int g_skipped = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define COPY_ZOOM 1.5f
#define COPY_DPI (72.0 * 1.5)

static double mean_luma_rgba(const spdf_bitmap* b) {
    double total = 0.0;
    long count = 0;
    int y, x;
    for (y = 0; y < b->height; ++y) {
        const unsigned char* row = b->rgba + (size_t)y * (size_t)b->stride;
        for (x = 0; x < b->width; ++x) {
            total += 0.299 * row[x * 4 + 0] + 0.587 * row[x * 4 + 1] + 0.114 * row[x * 4 + 2];
            ++count;
        }
    }
    return count ? total / (double)count : 0.0;
}

/* Fraction of pixels whose bytes differ between two same-sized renders. */
static double differing_fraction(const spdf_bitmap* a, const spdf_bitmap* b) {
    long differ = 0;
    long total = 0;
    int y, x;
    if (a->width != b->width || a->height != b->height) return 1.0;
    for (y = 0; y < a->height; ++y) {
        const unsigned char* ra = a->rgba + (size_t)y * (size_t)a->stride;
        const unsigned char* rb = b->rgba + (size_t)y * (size_t)b->stride;
        for (x = 0; x < a->width; ++x) {
            if (memcmp(ra + x * 4, rb + x * 4, 4) != 0) ++differ;
            ++total;
        }
    }
    return total ? (double)differ / (double)total : 0.0;
}

/* Carried from the copy check to the print check so the printed sheet is
 * compared against the SAME two references rather than against a threshold
 * that would have to be re-tuned for every fixture. */
static double g_light_mean = -1.0;
static double g_dark_mean = -1.0;

static int bitmaps_identical(const spdf_bitmap* a, const spdf_bitmap* b) {
    int y;
    if (a->width != b->width || a->height != b->height) return 0;
    for (y = 0; y < a->height; ++y) {
        if (memcmp(a->rgba + (size_t)y * (size_t)a->stride, b->rgba + (size_t)y * (size_t)b->stride,
                   (size_t)a->width * 4) != 0)
            return 0;
    }
    return 1;
}

/* --- 1. the flag word ----------------------------------------------------- */

static void test_flag_word(void) {
    unsigned flags = spdf_win_export_render_flags();

    /* Not vacuous: the bit being asserted absent must actually exist and be
     * non-zero, or every check below would pass on a typo. */
    CHECK(SPDF_RENDER_DARK_THEME != 0);
    CHECK(SPDF_RENDER_PRESERVE_IMAGES != 0);

    CHECK(flags == (unsigned)SPDF_RENDER_DEFAULT);
    CHECK((flags & (unsigned)SPDF_RENDER_DARK_THEME) == 0);
    CHECK((flags & (unsigned)SPDF_RENDER_PRESERVE_IMAGES) == 0);
    /* Called twice: nothing may make it stateful, because "the export flags"
     * must not depend on what the reader last looked at. */
    CHECK(spdf_win_export_render_flags() == flags);
}

/* --- 2. the pixels -------------------------------------------------------- */

static void test_copy_page_image_pixels(const char* path) {
    char err[512] = "";
    spdf_document* doc;
    spdf_bitmap through_export;
    spdf_bitmap explicit_light;
    spdf_bitmap explicit_dark;
    double light_mean, dark_mean;
    HGLOBAL dib_export;
    HGLOBAL dib_light;
    HGLOBAL dib_dark;
    SIZE_T size_export = 0, size_light = 0, size_dark = 0;

    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", path, err);
        ++g_failures;
        return;
    }

    memset(&through_export, 0, sizeof(through_export));
    memset(&explicit_light, 0, sizeof(explicit_light));
    memset(&explicit_dark, 0, sizeof(explicit_dark));

    /* The path Copy Page Image actually takes. */
    CHECK(spdf_win_clipboard_render_page(doc, 0, COPY_DPI, &through_export, err, sizeof(err)));
    /* The two references, taken here so the comparison cannot drift. */
    CHECK(spdf_render_page_rgba_opts(doc, 0, COPY_ZOOM, SPDF_RENDER_DEFAULT, NULL, &explicit_light, err,
                                     sizeof(err)));
    CHECK(spdf_render_page_rgba_opts(doc, 0, COPY_ZOOM, SPDF_RENDER_DARK_THEME, NULL, &explicit_dark, err,
                                     sizeof(err)));
    if (!through_export.rgba || !explicit_light.rgba || !explicit_dark.rgba) {
        spdf_close(doc);
        return;
    }

    /* THE NEGATIVE FIRST. If the dark render were not clearly different from
     * the light one, everything after it would be vacuous, so the suite fails
     * here rather than reporting a meaningless pass. Both a per-pixel count
     * and the mean, because either alone can be fooled: a recolour that moved
     * every pixel by one level would pass the mean test, and one that inverted
     * two halves of the page would pass the count test. */
    light_mean = mean_luma_rgba(&explicit_light);
    dark_mean = mean_luma_rgba(&explicit_dark);
    g_light_mean = light_mean;
    g_dark_mean = dark_mean;
    printf("light_theme_test: light mean luma %.1f, dark mean luma %.1f, %.1f%% of pixels differ\n", light_mean,
           dark_mean, 100.0 * differing_fraction(&explicit_light, &explicit_dark));
    CHECK(light_mean - dark_mean > 20.0);
    CHECK(differing_fraction(&explicit_light, &explicit_dark) > 0.5);
    CHECK(!bitmaps_identical(&explicit_light, &explicit_dark));

    /* THE RULE. */
    CHECK(bitmaps_identical(&through_export, &explicit_light));
    CHECK(!bitmaps_identical(&through_export, &explicit_dark));

    /* And after the CF_DIB packing, because that is what actually reaches the
     * clipboard and a recolour applied there would be invisible above. */
    dib_export = spdf_win_clipboard_alloc_dib(&through_export, 0, &size_export);
    dib_light = spdf_win_clipboard_alloc_dib(&explicit_light, 0, &size_light);
    dib_dark = spdf_win_clipboard_alloc_dib(&explicit_dark, 0, &size_dark);
    CHECK(dib_export != NULL && dib_light != NULL && dib_dark != NULL);
    if (dib_export && dib_light && dib_dark) {
        const unsigned char* a = (const unsigned char*)GlobalLock(dib_export);
        const unsigned char* b = (const unsigned char*)GlobalLock(dib_light);
        const unsigned char* c = (const unsigned char*)GlobalLock(dib_dark);
        CHECK(size_export == size_light && size_light == size_dark);
        CHECK(a && b && c);
        if (a && b && c) {
            CHECK(memcmp(a, b, (size_t)size_export) == 0);
            CHECK(memcmp(a, c, (size_t)size_export) != 0);
        }
        GlobalUnlock(dib_export);
        GlobalUnlock(dib_light);
        GlobalUnlock(dib_dark);
    }
    if (dib_export) GlobalFree(dib_export);
    if (dib_light) GlobalFree(dib_light);
    if (dib_dark) GlobalFree(dib_dark);

    spdf_free_bitmap(&through_export);
    spdf_free_bitmap(&explicit_light);
    spdf_free_bitmap(&explicit_dark);
    spdf_close(doc);
}

/* --- 3. the printed sheet ------------------------------------------------- */

/* Mean luma of a 32-bit top-down BGRA DIB section. */
static double mean_luma_bgra(const unsigned char* bits, int width, int height) {
    double total = 0.0;
    long count = 0;
    int y, x;
    for (y = 0; y < height; ++y) {
        const unsigned char* row = bits + (size_t)y * (size_t)width * 4;
        for (x = 0; x < width; ++x) {
            total += 0.299 * row[x * 4 + 2] + 0.587 * row[x * 4 + 1] + 0.114 * row[x * 4 + 0];
            ++count;
        }
    }
    return count ? total / (double)count : 0.0;
}

static void test_printed_sheet(const char* path) {
    /* A 300 dpi US Letter sheet with quarter-inch hardware margins -- the caps
     * a real laser reports, fed to the same conversion the job uses. Kept small
     * enough (2400 x 3150) that the DIB section is 30 MB. */
    const int dpi = 300;
    const int horz_res = 2400;
    const int vert_res = 3150;
    spdf_win_print_paper paper;
    char err[512] = "";
    spdf_document* doc;
    HDC dc;
    BITMAPINFO info;
    void* bits = NULL;
    HBITMAP bitmap;
    HGDIOBJ previous;
    RECT all;
    double printed_mean;
    double dark_mean;
    spdf_bitmap dark;

    CHECK(spdf_win_print_paper_from_caps(dpi, dpi, horz_res, vert_res, &paper));

    dc = CreateCompatibleDC(NULL);
    if (!dc) {
        printf("SKIP printed-sheet: CreateCompatibleDC failed, GetLastError=%lu\n", (unsigned long)GetLastError());
        ++g_skipped;
        return;
    }
    memset(&info, 0, sizeof(info));
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = horz_res;
    info.bmiHeader.biHeight = -vert_res; /* top-down, so row 0 is the top of the sheet */
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!bitmap || !bits) {
        printf("SKIP printed-sheet: CreateDIBSection failed, GetLastError=%lu\n", (unsigned long)GetLastError());
        ++g_skipped;
        DeleteDC(dc);
        return;
    }
    previous = SelectObject(dc, bitmap);

    /* Paper starts white, like paper. */
    all.left = 0;
    all.top = 0;
    all.right = horz_res;
    all.bottom = vert_res;
    FillRect(dc, &all, (HBRUSH)GetStockObject(WHITE_BRUSH));

    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", path, err);
        ++g_failures;
        SelectObject(dc, previous);
        DeleteObject(bitmap);
        DeleteDC(dc);
        return;
    }

    CHECK(spdf_win_print_page_to_dc(dc, doc, 0, &paper, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 1, err, sizeof(err)));
    GdiFlush();

    printed_mean = mean_luma_bgra((const unsigned char*)bits, horz_res, vert_res);

    /* NO MAGIC THRESHOLD. Which absolute brightness a printed sheet lands at
     * depends entirely on the fixture, so the sheet is compared against the
     * SAME TWO REFERENCES the copy check measured: it must be far closer to
     * the light render than to the dark one. Fit-to-page adds white margins
     * and HALFTONE stretching moves the mean by a fraction of a level, so a
     * few levels of slack is all this needs -- and a threaded-through dark
     * theme would move it by tens. */
    memset(&dark, 0, sizeof(dark));
    CHECK(spdf_render_page_rgba_opts(doc, 0, 1.0f, SPDF_RENDER_DARK_THEME, NULL, &dark, err, sizeof(err)));
    dark_mean = dark.rgba ? mean_luma_rgba(&dark) : 0.0;
    printf("light_theme_test: printed sheet mean luma %.1f (light reference %.1f, dark reference %.1f)\n",
           printed_mean, g_light_mean, g_dark_mean);
    CHECK(g_light_mean >= 0.0 && g_dark_mean >= 0.0); /* the copy check ran first */
    if (g_light_mean >= 0.0 && g_dark_mean >= 0.0) {
        double to_light = printed_mean - g_light_mean;
        double to_dark = printed_mean - g_dark_mean;
        if (to_light < 0.0) to_light = -to_light;
        if (to_dark < 0.0) to_dark = -to_dark;
        CHECK(to_light < to_dark);
        CHECK(to_light < 15.0);
    }
    /* And the fixture's own dark render is still clearly a different picture,
     * so the comparison above is not comparing two identical numbers. */
    CHECK(dark.rgba != NULL && g_light_mean - dark_mean > 20.0);
    if (dark.rgba) spdf_free_bitmap(&dark);

    spdf_close(doc);
    SelectObject(dc, previous);
    DeleteObject(bitmap);
    DeleteDC(dc);
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "portable/win/tests/fixtures/golden.pdf";

    test_flag_word();
    test_copy_page_image_pixels(path);
    test_printed_sheet(path);

    printf("light_theme_test: %d checks, %d failures, %d skipped\n", g_checks, g_failures, g_skipped);
    return g_failures ? 1 : 0;
}
