/* Document-agnostic dark-reading recolor for rendered page pixmaps.
 *
 * Every fixed-layout format the reader opens (PDF, XPS, CBZ, EPUB/MOBI, plain
 * images) reaches the frontends as one RGBA byte buffer produced by
 * spdf_render_page_*_rgba(). Recoloring that buffer is therefore the single
 * place where "dark mode" can be made to work for all of them at once, without
 * touching a format handler.
 *
 * The transform is LUMA REMAP: for each pixel we compute Rec.601 luma Y, invert
 * it, and remap the inverted value onto the reading theme's paper..ink ramp;
 * the resulting per-channel offset is added to R, G and B alike. Because the
 * SAME offset lands on all three channels, the channel differences (R-G, G-B),
 * i.e. the chroma, survive: a red logo stays red instead of flipping to cyan
 * the way a per-channel inversion (fz_invert_pixmap / fz_tint_pixmap /
 * SumatraPDF's UpdateBitmapColors) would flip it. Paper white lands exactly on
 * the theme paper color and body black lands exactly on the theme ink color,
 * so a recolored PDF page and a dark-themed Markdown page agree pixel for
 * pixel on background and text.
 *
 * Cost is one dot product, three adds and three clamps per pixel, with no
 * table lookup and no floating point; the per-theme constants
 * are computed once by spdf_recolor_table_init(), not once per page.
 *
 * The transform is fused into copy_pixmap_to_bitmap() in shenzhen_pdf_core.c,
 * the single tail of every render path, so it rides the row that pass has just
 * written while it is still in L1 rather than costing a second walk of the
 * whole image. It is a SCREEN transform only: print and export never opt in,
 * because a PDF's colors are the document's own content.
 */
#ifndef SPDF_RECOLOR_H
#define SPDF_RECOLOR_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SPDF_RECOLOR_NONE = 0,
    /* Recommended. Luma inverted and remapped onto paper..ink, chroma kept. */
    SPDF_RECOLOR_LUMA_REMAP = 1,
    /* Per-channel linear map black->ink, white->paper. This is exactly
     * fz_tint_pixmap() and SumatraPDF's UpdateBitmapColors(). Crisp on text,
     * but it is a channel-wise inversion, so photographs come out as negatives.
     * Kept for comparison and measurement. */
    SPDF_RECOLOR_TINT = 2,
    /* Naive 255-c, i.e. fz_invert_pixmap(). Comparison baseline only. */
    SPDF_RECOLOR_INVERT = 3
} spdf_recolor_mode;

/* 0xRRGGBB endpoints of the reading theme. paper_rgb is what document white
 * becomes, ink_rgb is what document black becomes. The Obsidian-dark palette
 * used by the Markdown reader is paper #1E1E1E / ink #DCDDDE. */
typedef struct {
    unsigned int paper_rgb;
    unsigned int ink_rgb;
} spdf_recolor_theme;

typedef struct {
    int kind; /* spdf_recolor_mode */
    /* TINT/INVERT are per-channel-value maps, so a plain 256-entry table per
     * channel says everything. */
    short r[256];
    short g[256];
    short b[256];
    /* LUMA_REMAP is luma-driven, so the offset cannot be indexed by a channel.
     * Substituting the paper..ink ramp into the offset collapses it to
     *   out_c = c - Y + ink_c - Y*span_c/255
     * which is branch-free arithmetic and measurably faster than a per-luma
     * table lookup (the lookup defeats vectorization). */
    int ink[3];
    int span[3]; /* ink_c - paper_c */
} spdf_recolor_table;

/* Pixel rectangle, half-open, in the rendered bitmap's own pixel coordinates. */
typedef struct {
    int x0, y0, x1, y1;
} spdf_recolor_irect;

/* Builds the lookup table for one mode+theme. Cheap; safe to call per render,
 * but a frontend normally keeps one table per theme. */
void spdf_recolor_table_init(spdf_recolor_table* table, spdf_recolor_mode mode, spdf_recolor_theme theme);

/* The Obsidian-dark theme shared with the Markdown reader. */
spdf_recolor_theme spdf_recolor_default_dark_theme(void);

/* In-place recolor of a tightly packed RGBA8 buffer. Alpha is untouched. */
void spdf_recolor_rgba(unsigned char* rgba, int width, int height, int stride, const spdf_recolor_table* table);

/* Same, but pixels inside any of `count` exclusion rectangles are left BYTE
 * IDENTICAL. Used to protect photographic image regions, whose lightness must
 * not be inverted: a portrait with a luma-inverted face reads as a negative
 * even though its hue is intact. */
void spdf_recolor_rgba_excluding(unsigned char* rgba, int width, int height, int stride,
                                 const spdf_recolor_table* table, const spdf_recolor_irect* exclusions, int count);

/* One row of the above, so a caller that is already walking rows (the fused
 * render tail) can recolor each row it has just written without a second walk
 * of the whole image. `y` is the row's index in the exclusion coordinate
 * space; `row` points at its first pixel. */
void spdf_recolor_rgba_row(unsigned char* row, int width, int y, const spdf_recolor_table* table,
                           const spdf_recolor_irect* exclusions, int count);

/* One scanline span [x0, x1) of a packed RGBA8 row. This is the primitive the
 * fused render tail calls once per non-excluded run of a row it has just
 * converted, so the pixels are still in L1. */
void spdf_recolor_rgba_span(unsigned char* row, int x0, int x1, const spdf_recolor_table* table);

/* A CBZ, a comic archive or a bare image file is a PICTURE, not a document:
 * inverting its lightness is never what anyone wants, and SumatraPDF skips its
 * own color override for image collections for the same reason. Returns 1 for
 * those container formats, 0 for PDF/XPS/EPUB/MOBI/SVG and anything unknown --
 * unknown defaults to "document" so a new text format is dark by default.
 * Matched on the path's extension, case insensitively; a NULL or extensionless
 * path is a document. */
int spdf_recolor_path_is_picture(const char* path);

/* ---- Per-page image regions -------------------------------------------- *
 *
 * "Leave images alone" needs the page's image rectangles, which cost one
 * structured-text pass to find. That pass is per PAGE, while renders are per
 * page AND zoom AND size, so the rectangles are cached in page space and
 * scaled per render. The cache is plain data with no mupdf types in it, so it
 * lives here rather than growing the document core.
 */
#define SPDF_RECOLOR_MAX_REGIONS 24
#define SPDF_RECOLOR_PAGE_SLOTS 4

typedef struct {
    float x0, y0, x1, y1;
} spdf_recolor_frect;

typedef struct {
    int page_index; /* < 0 when the slot has never been filled */
    /* Set when the page is (nearly) one big image -- a SCAN. Excluding that
     * image would make dark mode a silent no-op on the whole document, so a
     * page marked this way is recolored WHOLE even when the user asked for
     * images to be preserved. See spdf_recolor_page_entry_exclusions(). */
    int image_backed;
    int count; /* image rectangles found, clamped to SPDF_RECOLOR_MAX_REGIONS */
    spdf_recolor_frect rects[SPDF_RECOLOR_MAX_REGIONS]; /* unscaled page space */
    unsigned long long stamp;
} spdf_recolor_page_entry;

typedef struct {
    spdf_recolor_page_entry slots[SPDF_RECOLOR_PAGE_SLOTS];
    unsigned long long counter;
} spdf_recolor_page_cache;

void spdf_recolor_page_cache_reset(spdf_recolor_page_cache* cache);

/* Cached entry for a page, or NULL. Touches the entry's LRU stamp. */
spdf_recolor_page_entry* spdf_recolor_page_cache_find(spdf_recolor_page_cache* cache, int page_index);

/* Least-recently-used slot, reset and stamped for `page_index`. The caller
 * fills in rects/count/image_backed. */
spdf_recolor_page_entry* spdf_recolor_page_cache_claim(spdf_recolor_page_cache* cache, int page_index);

/* Scales a cached entry's page-space rectangles into the coordinates of a
 * bitmap rendered at `zoom` whose top-left pixel is device pixel
 * (origin_x, origin_y). Returns the count written, or 0 -- meaning "recolor
 * the whole page" -- for an image-backed page. */
int spdf_recolor_page_entry_exclusions(const spdf_recolor_page_entry* entry, float zoom, int origin_x, int origin_y,
                                       spdf_recolor_irect* out, int max);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_RECOLOR_H */
