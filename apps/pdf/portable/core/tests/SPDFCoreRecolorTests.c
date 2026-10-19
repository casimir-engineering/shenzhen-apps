/* Unit coverage for the dark-reading recolor. Pure pixel math, no document. */
#include "spdf_recolor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void check(int ok, const char* what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void check_rgb(const unsigned char* px, int r, int g, int b, const char* what) {
    if (px[0] != r || px[1] != g || px[2] != b) {
        printf("FAIL %s: got #%02X%02X%02X want #%02X%02X%02X\n", what, px[0], px[1], px[2], r, g, b);
        failures++;
    }
}

static void set(unsigned char* px, int r, int g, int b) {
    px[0] = (unsigned char)r;
    px[1] = (unsigned char)g;
    px[2] = (unsigned char)b;
    px[3] = 255;
}

int main(void) {
    spdf_recolor_theme theme = spdf_recolor_default_dark_theme();
    spdf_recolor_table table;
    unsigned char px[16 * 4];

    check(theme.paper_rgb == 0x1E1E1Eu, "default paper is the Markdown dark paper");
    check(theme.ink_rgb == 0xDCDDDEu, "default ink is the Markdown dark body text");

    spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, theme);

    /* The two endpoints must land exactly on the theme, so a recolored page and
     * a dark Markdown page agree on paper and body text. */
    set(px + 0, 255, 255, 255);
    set(px + 4, 0, 0, 0);
    spdf_recolor_rgba(px, 2, 1, 8, &table);
    check_rgb(px + 0, 0x1E, 0x1E, 0x1E, "document white becomes theme paper");
    check_rgb(px + 4, 0xDC, 0xDD, 0xDE, "document black becomes theme ink");

    /* Hue survives: a saturated red must stay red-dominant, not become cyan. */
    set(px, 255, 0, 0);
    spdf_recolor_rgba(px, 1, 1, 4, &table);
    check(px[0] > px[1] && px[0] > px[2], "saturated red stays red-dominant");
    /* The offset is the same for all three channels up to the theme's own
     * slight tint (#1E1E1E paper, #DCDDDE ink differ by a level per channel),
     * so red's other two channels stay within a level of each other rather
     * than separating the way a hue rotation would separate them. */
    check(abs((int)px[1] - (int)px[2]) <= 2, "red's green and blue stay balanced (no hue rotation)");

    set(px, 0, 0, 255);
    spdf_recolor_rgba(px, 1, 1, 4, &table);
    check(px[2] > px[0] && px[2] > px[1], "saturated blue stays blue-dominant");

    /* The per-channel modes are the ones that flip hue; assert that so the
     * comparison in the exploration notes stays honest. */
    spdf_recolor_table_init(&table, SPDF_RECOLOR_TINT, theme);
    set(px, 255, 0, 0);
    spdf_recolor_rgba(px, 1, 1, 4, &table);
    check(px[1] > px[0] && px[2] > px[0], "tint turns red into its complement");

    spdf_recolor_table_init(&table, SPDF_RECOLOR_INVERT, theme);
    set(px, 255, 0, 0);
    spdf_recolor_rgba(px, 1, 1, 4, &table);
    check_rgb(px, 0, 255, 255, "naive invert turns red into cyan");

    /* NONE is a no-op, and alpha is never touched. */
    spdf_recolor_table_init(&table, SPDF_RECOLOR_NONE, theme);
    set(px, 10, 20, 30);
    px[3] = 77;
    spdf_recolor_rgba(px, 1, 1, 4, &table);
    check_rgb(px, 10, 20, 30, "NONE leaves pixels alone");
    check(px[3] == 77, "alpha is preserved");

    /* Exclusions: pixels inside an image rect are left BYTE IDENTICAL, so a
     * photograph renders in its own colors on the dark paper around it. */
    {
        spdf_recolor_irect ex = {1, 0, 3, 1};
        int i;
        spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, theme);
        for (i = 0; i < 4; ++i) set(px + i * 4, 200, 100, 50);
        spdf_recolor_rgba_excluding(px, 4, 1, 16, &table, &ex, 1);
        check(px[0] != 200, "pixel left of the exclusion is recolored");
        check_rgb(px + 4, 200, 100, 50, "first excluded pixel is byte identical");
        check_rgb(px + 8, 200, 100, 50, "last excluded pixel is byte identical");
        check(px[12] != 200, "pixel right of the exclusion is recolored");
    }

    /* A zero-count exclusion list is the plain full-page path. */
    {
        spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, theme);
        set(px, 255, 255, 255);
        spdf_recolor_rgba_excluding(px, 1, 1, 4, &table, NULL, 0);
        check_rgb(px, 0x1E, 0x1E, 0x1E, "no exclusions recolors everything");
    }

    /* spdf_recolor_rgba_row is the fused tail's primitive; it must agree with
     * the whole-buffer form row for row. */
    {
        spdf_recolor_irect ex = {2, 0, 3, 2};
        unsigned char whole[4 * 2 * 4];
        unsigned char rows[4 * 2 * 4];
        int i;
        spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, theme);
        for (i = 0; i < 8; ++i) {
            set(whole + i * 4, 30 + i * 7, 200 - i * 5, 90);
            set(rows + i * 4, 30 + i * 7, 200 - i * 5, 90);
        }
        spdf_recolor_rgba_excluding(whole, 4, 2, 16, &table, &ex, 1);
        for (i = 0; i < 2; ++i) spdf_recolor_rgba_row(rows + i * 16, 4, i, &table, &ex, 1);
        check(memcmp(whole, rows, sizeof(whole)) == 0, "row-at-a-time recolor matches the whole-buffer form");
    }

    /* Comic archives and bare images are pictures. Rendering uses this
     * classification to honor the preserve-images setting. Unknown suffixes
     * are resolved lazily by the renderer when preservation needs it. */
    check(spdf_recolor_path_is_picture("/books/Volume 1.cbz"), "a comic archive is a picture");
    check(spdf_recolor_path_is_picture("/photos/IMG_0042.JPEG"), "an image is a picture, case insensitively");
    check(!spdf_recolor_path_is_picture("/docs/datasheet.pdf"), "a PDF is a document");
    check(!spdf_recolor_path_is_picture("/books/novel.epub"), "an EPUB is a document");
    check(!spdf_recolor_path_is_picture("/docs/report.xps"), "an XPS is a document");
    check(!spdf_recolor_path_is_picture("/docs/notes"), "an extensionless path is a document");
    check(!spdf_recolor_path_is_picture("/my.cbz.archive/report.pdf"), "only the basename's extension counts");
    check(!spdf_recolor_path_is_picture(NULL), "a NULL path is a document");

    /* The page-region cache and the scanned-page guard. */
    {
        spdf_recolor_page_cache cache;
        spdf_recolor_page_entry* entry;
        spdf_recolor_irect out[SPDF_RECOLOR_MAX_REGIONS];
        int i;

        spdf_recolor_page_cache_reset(&cache);
        check(spdf_recolor_page_cache_find(&cache, 0) == NULL, "a reset cache holds nothing");

        entry = spdf_recolor_page_cache_claim(&cache, 7);
        check(entry != NULL && entry->page_index == 7, "claim stamps the page index");
        entry->count = 1;
        entry->rects[0].x0 = 10.0f;
        entry->rects[0].y0 = 20.0f;
        entry->rects[0].x1 = 30.0f;
        entry->rects[0].y1 = 40.0f;
        check(spdf_recolor_page_cache_find(&cache, 7) == entry, "a claimed page is found again");
        check(spdf_recolor_page_cache_find(&cache, 8) == NULL, "an unclaimed page is not found");

        /* Page space scales by zoom; the bitmap's own origin is subtracted, and
         * the far edges round outward so no recolored seam is left behind. */
        check(spdf_recolor_page_entry_exclusions(entry, 2.0f, 5, 6, out, SPDF_RECOLOR_MAX_REGIONS) == 1,
              "one image rect yields one exclusion");
        check(out[0].x0 == 15 && out[0].y0 == 34 && out[0].x1 == 55 && out[0].y1 == 74,
              "the exclusion is scaled to the render and offset to the bitmap origin");

        entry->image_backed = 1;
        check(spdf_recolor_page_entry_exclusions(entry, 2.0f, 0, 0, out, SPDF_RECOLOR_MAX_REGIONS) == 1,
              "an image-backed page respects the preserve-images setting");

        /* Least-recently-used eviction, so a long document cannot grow the
         * cache without bound. */
        spdf_recolor_page_cache_reset(&cache);
        for (i = 0; i < SPDF_RECOLOR_PAGE_SLOTS; ++i) spdf_recolor_page_cache_claim(&cache, i);
        check(spdf_recolor_page_cache_find(&cache, 0) != NULL, "page 0 is cached and now most recently used");
        spdf_recolor_page_cache_claim(&cache, 99);
        check(spdf_recolor_page_cache_find(&cache, 0) != NULL, "the touched page survives the next claim");
        check(spdf_recolor_page_cache_find(&cache, 1) == NULL, "the least recently used page was evicted");
        check(spdf_recolor_page_cache_find(&cache, 99) != NULL, "the newly claimed page is cached");
    }

    if (failures) {
        printf("%d recolor test(s) failed\n", failures);
        return 1;
    }
    printf("All recolor tests passed\n");
    return 0;
}
