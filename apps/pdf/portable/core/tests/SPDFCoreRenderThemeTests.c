/* The dark reading theme as the frontends actually see it: whole renders
 * through spdf_render_page_rgba_opts(), on real PDFs, with the flags the mac
 * and GTK call sites pass.
 *
 * SPDFCoreRecolorTests covers the pixel math in isolation; this covers the
 * three integration properties that matter and cannot be checked there:
 *   - the theme is a per-render flag, so toggling it back returns the ORIGINAL
 *     bytes and nothing sticks to the document;
 *   - the print path (plain spdf_render_page_rgba, exactly what
 *     SPDFMacPrintView calls) keeps the document's own colors even on a
 *     document that has just rendered dark for the screen;
 *   - "leave images alone" protects figures and standalone pictures.
 */
#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#include "shenzhen_pdf_core.h"
#include "spdf_win_compat.h"
#include "spdf_recolor.h"
#include "spdf_core_document.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++g_failures;                              \
        }                                              \
    } while (0)

/* Page is 200x200 at zoom 1, so these sample points are stable. In DEVICE
 * pixels (y down): the image sits at 0,0-64,64, the black square at
 * 10,160-40,190, the red square at 60,160-90,190, and bare paper everywhere
 * else -- 150,100 is the sample point well clear of all three. */
#define PAGE_SIDE 200
#define ZOOM 1.0f
#define PAPER_X 150
#define PAPER_Y 100

static const unsigned char* pixel_at(const spdf_bitmap* bitmap, int x, int y) {
    return bitmap->rgba + (size_t)y * (size_t)bitmap->stride + (size_t)x * 4;
}

static int rgb_is(const spdf_bitmap* bitmap, int x, int y, int r, int g, int b) {
    const unsigned char* px = pixel_at(bitmap, x, y);
    return px[0] == r && px[1] == g && px[2] == b;
}

static void report_pixel(const char* what, const spdf_bitmap* bitmap, int x, int y) {
    const unsigned char* px = pixel_at(bitmap, x, y);
    fprintf(stderr, "      %s at %d,%d = #%02X%02X%02X\n", what, x, y, px[0], px[1], px[2]);
}

/* A 4x4 continuous-tone image, so an exclusion has something to protect and a
 * lightness inversion has something to ruin. */
static fz_image* make_photo(fz_context* ctx, int side) {
    fz_pixmap* pix = fz_new_pixmap(ctx, fz_device_rgb(ctx), side, side, NULL, 0);
    int x, y;
    for (y = 0; y < side; ++y) {
        unsigned char* row = pix->samples + (size_t)y * (size_t)pix->stride;
        for (x = 0; x < side; ++x) {
            row[x * 3 + 0] = (unsigned char)(40 + (200 * x) / side);
            row[x * 3 + 1] = (unsigned char)(90 + (100 * y) / side);
            row[x * 3 + 2] = (unsigned char)(200 - (150 * x) / side);
        }
    }
    {
        fz_image* image = fz_new_image_from_pixmap(ctx, pix, NULL);
        fz_drop_pixmap(ctx, pix);
        return image;
    }
}

/* One 200x200 page: white paper, a black square, a saturated red square, and an
 * image whose size the caller chooses. An image covering the whole page makes
 * the page image-backed, i.e. a scan. */
static int write_pdf(fz_context* ctx, const char* path, int image_side) {
    pdf_document* doc = NULL;
    fz_buffer* contents = NULL;
    pdf_obj* resources = NULL;
    pdf_obj* page = NULL;
    fz_image* photo = NULL;
    char content[512];

    fz_var(doc);
    fz_var(contents);
    fz_var(resources);
    fz_var(page);
    fz_var(photo);
    fz_try(ctx) {
        doc = pdf_create_document(ctx);
        resources = pdf_new_dict(ctx, doc, 1);
        snprintf(content, sizeof(content),
                 "1 1 1 rg 0 0 %d %d re f\n"  /* white paper */
                 "0 0 0 rg 10 10 30 30 re f\n" /* black ink */
                 "1 0 0 rg 60 10 30 30 re f\n" /* saturated red */
                 "q %d 0 0 %d 0 %d cm /Im0 Do Q\n",
                 PAGE_SIDE, PAGE_SIDE, image_side, image_side, PAGE_SIDE - image_side);
        photo = make_photo(ctx, 64);
        {
            pdf_obj* xobjects = pdf_dict_put_dict(ctx, resources, PDF_NAME(XObject), 1);
            pdf_dict_puts_drop(ctx, xobjects, "Im0", pdf_add_image(ctx, doc, photo));
        }
        contents = fz_new_buffer_from_copied_data(ctx, (const unsigned char*)content, strlen(content));
        if (image_side == PAGE_SIDE) {
            /* OCR retains the full-page image and adds invisible searchable text. */
            pdf_obj* fonts = pdf_dict_put_dict(ctx, resources, PDF_NAME(Font), 1);
            pdf_obj* font = pdf_dict_puts_dict(ctx, fonts, "F1", 3);
            pdf_dict_put(ctx, font, PDF_NAME(Type), PDF_NAME(Font));
            pdf_dict_put(ctx, font, PDF_NAME(Subtype), PDF_NAME(Type1));
            pdf_dict_put_name(ctx, font, PDF_NAME(BaseFont), "Helvetica");
            fz_append_string(ctx, contents, "BT /F1 12 Tf 3 Tr 20 100 Td (OCR searchable text) Tj ET\n");
        }
        page = pdf_add_page(ctx, doc, fz_make_rect(0, 0, PAGE_SIDE, PAGE_SIDE), 0, resources, contents);
        pdf_insert_page(ctx, doc, -1, page);
        pdf_save_document(ctx, doc, path, NULL);
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, page);
        pdf_drop_obj(ctx, resources);
        fz_drop_buffer(ctx, contents);
        fz_drop_image(ctx, photo);
        pdf_drop_document(ctx, doc);
    }
    fz_catch(ctx) {
        fprintf(stderr, "Could not write PDF fixture: %s\n", fz_caught_message(ctx));
        return 0;
    }
    return 1;
}

static int render(spdf_document* doc, unsigned flags, spdf_bitmap* out) {
    char err[512];
    if (spdf_render_page_rgba_opts(doc, 0, ZOOM, flags, NULL, out, err, sizeof(err))) return 1;
    fprintf(stderr, "render failed (flags %u): %s\n", flags, err);
    ++g_failures;
    return 0;
}

static size_t bitmap_bytes(const spdf_bitmap* bitmap) {
    return (size_t)bitmap->stride * (size_t)bitmap->height;
}

/* Pixels a render left byte identical to the reference. */
static long identical_pixels(const spdf_bitmap* a, const spdf_bitmap* b) {
    long count = 0;
    int x, y;
    if (a->width != b->width || a->height != b->height) return -1;
    for (y = 0; y < a->height; ++y)
        for (x = 0; x < a->width; ++x)
            if (memcmp(pixel_at(a, x, y), pixel_at(b, x, y), 3) == 0) count++;
    return count;
}

static void test_figure_page(const char* path) {
    spdf_document* doc;
    spdf_bitmap plain, dark, again, preserved;
    char err[512];

    doc = spdf_open(path, err, sizeof(err));
    EXPECT(doc != NULL, "figure page opens: %s", err);
    if (!doc) return;

    if (!render(doc, SPDF_RENDER_DEFAULT, &plain)) {
        spdf_close(doc);
        return;
    }
    EXPECT(rgb_is(&plain, PAPER_X, PAPER_Y, 255, 255, 255), "plain render keeps white paper");
    if (!rgb_is(&plain, PAPER_X, PAPER_Y, 255, 255, 255)) report_pixel("paper", &plain, PAPER_X, PAPER_Y);

    if (!render(doc, SPDF_RENDER_DARK_THEME, &dark)) {
        spdf_free_bitmap(&plain);
        spdf_close(doc);
        return;
    }
    /* The exact endpoints, so a recolored page and a dark Markdown page agree.
     * Not pure black: the paper is the Markdown theme's #1E1E1E. */
    EXPECT(rgb_is(&dark, PAPER_X, PAPER_Y, 0x1E, 0x1E, 0x1E), "dark render paints paper #1E1E1E");
    if (!rgb_is(&dark, PAPER_X, PAPER_Y, 0x1E, 0x1E, 0x1E)) report_pixel("paper", &dark, PAPER_X, PAPER_Y);
    EXPECT(rgb_is(&dark, 25, 175, 0xDC, 0xDD, 0xDE), "dark render paints black ink #DCDDDE");
    if (!rgb_is(&dark, 25, 175, 0xDC, 0xDD, 0xDE)) report_pixel("ink", &dark, 25, 175);
    {
        /* The red square keeps its hue: red dominant, with the other two
         * channels level rather than separated the way a rotation separates
         * them. A per-channel inversion would have made this cyan. */
        const unsigned char* px = pixel_at(&dark, 75, 175);
        EXPECT(px[0] > px[1] && px[0] > px[2], "dark render keeps a red figure red");
        EXPECT(abs((int)px[1] - (int)px[2]) <= 2, "dark render does not rotate the red figure's hue");
        if (!(px[0] > px[1] && px[0] > px[2])) report_pixel("red", &dark, 75, 175);
    }

    /* THE TOGGLE ROUND TRIP. The theme is a per-render flag, not state pushed
     * onto the document, so a plain render AFTER a dark one on the SAME handle
     * has to come back byte for byte identical to the first. This is what lets
     * the frontend drop its page cache and re-render on toggle without ever
     * having to un-recolor anything. */
    if (render(doc, SPDF_RENDER_DEFAULT, &again)) {
        EXPECT(bitmap_bytes(&again) == bitmap_bytes(&plain) &&
                   memcmp(again.rgba, plain.rgba, bitmap_bytes(&plain)) == 0,
               "toggling back returns the original bytes");
        spdf_free_bitmap(&again);
    }

    /* PRINT AND EXPORT. This is exactly the call SPDFMacPrintView makes, on a
     * document that has just rendered dark for the screen. A PDF's colors are
     * its content; a printed or exported page must never carry ours. */
    if (spdf_render_page_rgba(doc, 0, ZOOM, &again, err, sizeof(err))) {
        EXPECT(rgb_is(&again, PAPER_X, PAPER_Y, 255, 255, 255), "the print path keeps the document's own white paper");
        if (!rgb_is(&again, PAPER_X, PAPER_Y, 255, 255, 255)) report_pixel("print paper", &again, PAPER_X, PAPER_Y);
        spdf_free_bitmap(&again);
    } else {
        EXPECT(0, "print-path render failed: %s", err);
    }

    /* Preserving images leaves the figure alone and the paper dark. */
    if (render(doc, SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES, &preserved)) {
        long identical = identical_pixels(&plain, &preserved);
        EXPECT(rgb_is(&preserved, PAPER_X, PAPER_Y, 0x1E, 0x1E, 0x1E), "preserving images still darkens the paper");
        EXPECT(identical > 3000, "the image region is left byte identical (%ld px)", identical);
        EXPECT(memcmp(pixel_at(&plain, 32, 32), pixel_at(&preserved, 32, 32), 3) == 0,
               "a pixel inside the image is byte identical");
        EXPECT(identical < (long)plain.width * plain.height / 2, "only the image is spared, not the page");
        spdf_free_bitmap(&preserved);
    }

    spdf_free_bitmap(&plain);
    spdf_free_bitmap(&dark);
    spdf_close(doc);
}

static void test_scanned_page(const char* path) {
    spdf_document* doc;
    spdf_bitmap plain, preserved;
    char err[512];

    doc = spdf_open(path, err, sizeof(err));
    EXPECT(doc != NULL, "scanned page opens: %s", err);
    if (!doc) return;

    if (render(doc, SPDF_RENDER_DEFAULT, &plain)) {
        if (render(doc, SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES, &preserved)) {
            long identical = identical_pixels(&plain, &preserved);
            EXPECT(identical == (long)plain.width * plain.height,
                   "full-page scan retains original pixels when preservation is enabled");
            spdf_free_bitmap(&preserved);
        }
        if (render(doc, SPDF_RENDER_DARK_THEME, &preserved)) {
            long identical = identical_pixels(&plain, &preserved);
            EXPECT(identical * 20 < (long)plain.width * plain.height,
                   "full-page scan is recolored when preservation is disabled");
            spdf_free_bitmap(&preserved);
        }
        spdf_free_bitmap(&plain);
    }
    spdf_close(doc);
}

/* A comic archive or a bare image is a picture, not a document. */
static void test_picture_document(fz_context* ctx, const char* path) {
    spdf_document* doc;
    spdf_bitmap plain, dark;
    char err[512];

    {
        fz_pixmap* pix = NULL;
        fz_var(pix);
        fz_try(ctx) {
            pix = fz_new_pixmap(ctx, fz_device_rgb(ctx), 32, 32, NULL, 0);
            fz_clear_pixmap_with_value(ctx, pix, 0xFF);
            fz_save_pixmap_as_png(ctx, pix, path);
        }
        fz_always(ctx) {
            fz_drop_pixmap(ctx, pix);
        }
        fz_catch(ctx) {
            EXPECT(0, "could not write the PNG fixture: %s", fz_caught_message(ctx));
            return;
        }
    }

    doc = spdf_open(path, err, sizeof(err));
    EXPECT(doc != NULL, "image document opens: %s", err);
    if (!doc) return;
    int unknown=doc->picture_document<0;
    EXPECT(!strstr(path,".bin") || unknown,"generic image is not inspected during open");
    if (render(doc, SPDF_RENDER_DEFAULT, &plain)) {
        EXPECT(!unknown || doc->picture_document==-1,"light render does not resolve picture metadata");
        if (render(doc, SPDF_RENDER_DARK_THEME, &dark)) {
            EXPECT(memcmp(dark.rgba,plain.rgba,bitmap_bytes(&plain))!=0,
                "standalone picture darkens only when preservation is disabled");
            EXPECT(!unknown || doc->picture_document==-1,"disabled preservation needs no picture metadata");
            spdf_free_bitmap(&dark);
        }
        if (render(doc, SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES, &dark)) {
            EXPECT(bitmap_bytes(&dark)==bitmap_bytes(&plain) &&
                memcmp(dark.rgba,plain.rgba,bitmap_bytes(&plain))==0,
                "standalone picture colors survive dark theme with preservation enabled");
            EXPECT(doc->picture_document==1,"generic-suffix image is identified by its renderer format lazily");
            spdf_free_bitmap(&dark);
        }
        spdf_rect crop={4,4,20,20}; spdf_bitmap normal_crop={0},dark_crop={0};
        if(spdf_render_page_region_rgba_opts(doc,0,1,crop,0,NULL,&normal_crop,err,sizeof(err)) &&
           spdf_render_page_region_rgba_opts(doc,0,1,crop,SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES,NULL,&dark_crop,err,sizeof(err)))
            EXPECT(bitmap_bytes(&normal_crop)==bitmap_bytes(&dark_crop) &&
                memcmp(normal_crop.rgba,dark_crop.rgba,bitmap_bytes(&normal_crop))==0,"cropped picture also preserves colors");
        else EXPECT(0,"picture crop renders: %s",err);
        spdf_free_bitmap(&normal_crop); spdf_free_bitmap(&dark_crop);
        spdf_free_bitmap(&plain);
    }
    spdf_close(doc);
}

int main(void) {
    char dir[SPDF_COMPAT_PATH_MAX];
    char figure_path[SPDF_COMPAT_PATH_MAX];
    char scan_path[SPDF_COMPAT_PATH_MAX];
    char picture_path[SPDF_COMPAT_PATH_MAX];
    char generic_path[SPDF_COMPAT_PATH_MAX];
    fz_context* ctx;

    if (!spdf_compat_make_temp_dir(dir, sizeof(dir), "spdf-core-render-theme-tests.")) {
        fprintf(stderr, "Could not create a temporary directory\n");
        return 1;
    }
    snprintf(figure_path, sizeof(figure_path), "%s" SPDF_PATH_SEP_STR "figure.pdf", dir);
    snprintf(scan_path, sizeof(scan_path), "%s" SPDF_PATH_SEP_STR "scan.pdf", dir);
    snprintf(picture_path, sizeof(picture_path), "%s" SPDF_PATH_SEP_STR "picture.png", dir);

    snprintf(generic_path,sizeof(generic_path),"%s" SPDF_PATH_SEP_STR "copy.bin",dir);

    ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        fprintf(stderr, "Could not create a mupdf context\n");
        return 1;
    }
    fz_register_document_handlers(ctx);

    if (write_pdf(ctx, figure_path, 64) && write_pdf(ctx, scan_path, PAGE_SIDE)) {
        test_figure_page(figure_path);
        test_scanned_page(scan_path);
        test_picture_document(ctx, picture_path);
        test_picture_document(ctx, generic_path);
    } else {
        ++g_failures;
    }

    fz_drop_context(ctx);
    spdf_compat_unlink(figure_path);
    spdf_compat_unlink(scan_path);
    spdf_compat_unlink(picture_path);
    spdf_compat_unlink(generic_path);
    spdf_compat_rmdir(dir);

    if (g_failures) {
        fprintf(stderr, "%d render-theme test(s) failed\n", g_failures);
        return 1;
    }
    printf("All render theme tests passed\n");
    return 0;
}
