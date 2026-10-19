#include "spdf_recolor.h"

#include <string.h>

/* Rec.601 luma with integer weights that sum to exactly 256, so pure white
 * lands on Y=255 and pure black on Y=0 with no rounding drift. */
#define SPDF_LUMA_R 77
#define SPDF_LUMA_G 150
#define SPDF_LUMA_B 29

static int spdf_clamp_byte(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

static int spdf_lerp255(int from, int to, int t) { return from + ((t * (to - from) + 127) / 255); }

spdf_recolor_theme spdf_recolor_default_dark_theme(void) {
    spdf_recolor_theme theme;
    theme.paper_rgb = 0x1E1E1Eu; /* SPDFMarkdownTheme dark paperColor */
    theme.ink_rgb = 0xDCDDDEu;   /* SPDFMarkdownTheme dark bodyTextColor */
    return theme;
}

void spdf_recolor_table_init(spdf_recolor_table* table, spdf_recolor_mode mode, spdf_recolor_theme theme) {
    int paper[3];
    int ink[3];
    int i;

    if (!table) return;
    memset(table, 0, sizeof(*table));
    table->kind = (int)mode;
    if (mode == SPDF_RECOLOR_NONE) return;

    paper[0] = (int)((theme.paper_rgb >> 16) & 0xFFu);
    paper[1] = (int)((theme.paper_rgb >> 8) & 0xFFu);
    paper[2] = (int)(theme.paper_rgb & 0xFFu);
    ink[0] = (int)((theme.ink_rgb >> 16) & 0xFFu);
    ink[1] = (int)((theme.ink_rgb >> 8) & 0xFFu);
    ink[2] = (int)(theme.ink_rgb & 0xFFu);

    if (mode == SPDF_RECOLOR_LUMA_REMAP) {
        for (i = 0; i < 3; ++i) {
            table->ink[i] = ink[i];
            table->span[i] = ink[i] - paper[i];
        }
        return;
    }

    for (i = 0; i < 256; ++i) {
        switch (mode) {
            case SPDF_RECOLOR_TINT: {
                /* fz_tint_pixmap()/UpdateBitmapColors(): each channel is mapped
                 * independently, so a channel that was high becomes low. */
                table->r[i] = (short)spdf_lerp255(ink[0], paper[0], i);
                table->g[i] = (short)spdf_lerp255(ink[1], paper[1], i);
                table->b[i] = (short)spdf_lerp255(ink[2], paper[2], i);
                break;
            }
            case SPDF_RECOLOR_INVERT:
            default:
                table->r[i] = (short)(255 - i);
                table->g[i] = (short)(255 - i);
                table->b[i] = (short)(255 - i);
                break;
        }
    }
}

/* One scanline span [x0, x1). Public so the fused render tail and the
 * exclusion walker can both drive it without duplicating the inner loops. */
void spdf_recolor_rgba_span(unsigned char* row, int x0, int x1, const spdf_recolor_table* table) {
    int x;

    if (!row || !table || table->kind == SPDF_RECOLOR_NONE) return;
    if (x0 < 0) x0 = 0;
    if (x1 <= x0) return;
    if (table->kind == SPDF_RECOLOR_LUMA_REMAP) {
        int ir = table->ink[0], ig = table->ink[1], ib = table->ink[2];
        int jr = table->span[0], jg = table->span[1], jb = table->span[2];
        for (x = x0; x < x1; ++x) {
            unsigned char* px = row + (size_t)x * 4;
            int r = px[0];
            int g = px[1];
            int b = px[2];
            int y = (SPDF_LUMA_R * r + SPDF_LUMA_G * g + SPDF_LUMA_B * b + 128) >> 8;
            /* (v*32897)>>23 is an exact unsigned divide by 255 for v < 2^24,
             * which the products here are comfortably under. */
            px[0] = (unsigned char)spdf_clamp_byte(r - y + ir - (((y * jr + 127) * 32897) >> 23));
            px[1] = (unsigned char)spdf_clamp_byte(g - y + ig - (((y * jg + 127) * 32897) >> 23));
            px[2] = (unsigned char)spdf_clamp_byte(b - y + ib - (((y * jb + 127) * 32897) >> 23));
        }
    } else {
        for (x = x0; x < x1; ++x) {
            unsigned char* px = row + (size_t)x * 4;
            px[0] = (unsigned char)table->r[px[0]];
            px[1] = (unsigned char)table->g[px[1]];
            px[2] = (unsigned char)table->b[px[2]];
        }
    }
}

void spdf_recolor_rgba(unsigned char* rgba, int width, int height, int stride, const spdf_recolor_table* table) {
    int y;

    if (!rgba || !table || table->kind == SPDF_RECOLOR_NONE || width <= 0 || height <= 0) return;
    for (y = 0; y < height; ++y) spdf_recolor_rgba_span(rgba + (size_t)y * (size_t)stride, 0, width, table);
}

void spdf_recolor_rgba_row(unsigned char* row, int width, int y, const spdf_recolor_table* table,
                           const spdf_recolor_irect* exclusions, int count) {
    int cursor = 0;
    int i;

    if (!row || !table || table->kind == SPDF_RECOLOR_NONE || width <= 0) return;
    if (!exclusions || count <= 0) {
        spdf_recolor_rgba_span(row, 0, width, table);
        return;
    }

    /* Walk this scanline left to right, taking the next exclusion that starts
     * at or after the cursor and recoloring only the gaps between them.
     * Exclusion counts are small (a handful of image blocks per page), so the
     * linear scan costs nothing next to the per-pixel work it saves -- and
     * unlike a per-pixel "am I inside a rectangle?" test (zathura's
     * pixel_inside_rectangles, whose own source carries a TODO about it) it
     * never touches the excluded pixels at all, so they stay byte-identical. */
    for (;;) {
        int best = -1;
        int best_x0 = width;
        for (i = 0; i < count; ++i) {
            const spdf_recolor_irect* r = &exclusions[i];
            int x0 = r->x0 < 0 ? 0 : r->x0;
            int x1 = r->x1 > width ? width : r->x1;
            if (y < r->y0 || y >= r->y1 || x1 <= cursor || x1 <= x0) continue;
            if (x0 < cursor) x0 = cursor;
            if (x0 < best_x0) {
                best_x0 = x0;
                best = i;
            }
        }
        if (best < 0) break;
        spdf_recolor_rgba_span(row, cursor, best_x0, table);
        cursor = exclusions[best].x1 > width ? width : exclusions[best].x1;
        if (cursor >= width) return;
    }
    spdf_recolor_rgba_span(row, cursor, width, table);
}

void spdf_recolor_rgba_excluding(unsigned char* rgba, int width, int height, int stride,
                                 const spdf_recolor_table* table, const spdf_recolor_irect* exclusions, int count) {
    int y;

    if (!rgba || !table || table->kind == SPDF_RECOLOR_NONE || width <= 0 || height <= 0) return;
    for (y = 0; y < height; ++y)
        spdf_recolor_rgba_row(rgba + (size_t)y * (size_t)stride, width, y, table, exclusions, count);
}

int spdf_recolor_path_is_picture(const char* path) {
    /* Comic archives and every still-image format mupdf will open as a
     * one-page document. Kept as an explicit allow-list of PICTURES rather
     * than of documents so that an unrecognized text format still gets the
     * theme. */
    static const char* const picture_extensions[] = {"cbz", "cbr", "cb7",  "cbt",  "zip", "tar", "png",
                                                     "jpg", "jpeg", "jpe", "jfif", "gif", "bmp", "tif",
                                                     "tiff", "pnm", "pam", "pgm",  "ppm", "pbm", "jxr",
                                                     "hdp", "wdp",  "jpx", "jp2",  "j2k", "psd", "webp",
                                                     "svg", "svgz", "jb2", "jbig2", "pfm", "jfif-tbnl"};
    const char* dot = NULL;
    const char* p;
    size_t i;

    if (!path) return 0;
    for (p = path; *p; ++p) {
        if (*p == '/' || *p == '\\')
            dot = NULL;
        else if (*p == '.')
            dot = p;
    }
    if (!dot || !dot[1]) return 0;
    for (i = 0; i < sizeof(picture_extensions) / sizeof(picture_extensions[0]); ++i) {
        const char* want = picture_extensions[i];
        const char* have = dot + 1;
        while (*want && *have) {
            int a = *have >= 'A' && *have <= 'Z' ? *have + 32 : *have;
            if (a != *want) break;
            ++want;
            ++have;
        }
        if (!*want && !*have) return 1;
    }
    return 0;
}

/* ---- Per-page image regions -------------------------------------------- */

void spdf_recolor_page_cache_reset(spdf_recolor_page_cache* cache) {
    int i;

    if (!cache) return;
    memset(cache, 0, sizeof(*cache));
    for (i = 0; i < SPDF_RECOLOR_PAGE_SLOTS; ++i) cache->slots[i].page_index = -1;
}

spdf_recolor_page_entry* spdf_recolor_page_cache_find(spdf_recolor_page_cache* cache, int page_index) {
    int i;

    if (!cache || page_index < 0) return NULL;
    for (i = 0; i < SPDF_RECOLOR_PAGE_SLOTS; ++i) {
        spdf_recolor_page_entry* slot = &cache->slots[i];
        if (slot->page_index != page_index) continue;
        slot->stamp = ++cache->counter;
        return slot;
    }
    return NULL;
}

spdf_recolor_page_entry* spdf_recolor_page_cache_claim(spdf_recolor_page_cache* cache, int page_index) {
    spdf_recolor_page_entry* victim;
    int i;

    if (!cache || page_index < 0) return NULL;
    victim = &cache->slots[0];
    for (i = 0; i < SPDF_RECOLOR_PAGE_SLOTS; ++i) {
        spdf_recolor_page_entry* slot = &cache->slots[i];
        if (slot->page_index < 0) {
            victim = slot;
            break;
        }
        if (slot->stamp < victim->stamp) victim = slot;
    }
    memset(victim, 0, sizeof(*victim));
    victim->page_index = page_index;
    victim->stamp = ++cache->counter;
    return victim;
}

int spdf_recolor_page_entry_exclusions(const spdf_recolor_page_entry* entry, float zoom, int origin_x, int origin_y,
                                       spdf_recolor_irect* out, int max) {
    int count = 0;
    int i;

    if (!entry || !out || max <= 0 || zoom <= 0.0f) return 0;
    /* A full-page scan is still an image. Honor the explicit preservation
     * flag exactly as for an embedded figure or a standalone picture. */

    for (i = 0; i < entry->count && count < max; ++i) {
        const spdf_recolor_frect* r = &entry->rects[i];
        int x0 = (int)(r->x0 * zoom) - origin_x;
        int y0 = (int)(r->y0 * zoom) - origin_y;
        /* Round the far edges outward so an exclusion never leaves a recolored
         * seam of stray pixels along the image's right or bottom border. */
        int x1 = (int)(r->x1 * zoom + 0.9999f) - origin_x;
        int y1 = (int)(r->y1 * zoom + 0.9999f) - origin_y;
        if (x1 <= x0 || y1 <= y0) continue;
        out[count].x0 = x0;
        out[count].y0 = y0;
        out[count].x1 = x1;
        out[count].y1 = y1;
        count++;
    }
    return count;
}
