#pragma once

/* Resolve unknown formats only when a dark render actually preserves images.
 * Byte-identical reading/Collection copies can have a generic suffix. Never
 * sniff metadata during open or a light render merely to classify them. */
static int render_document_is_picture(spdf_document* doc) {
    char format[96] = {0};
    char name[112];
    if (doc->picture_document >= 0) return doc->picture_document;
    fz_lookup_metadata(doc->ctx, doc->doc, FZ_META_FORMAT, format, sizeof(format));
    snprintf(name, sizeof(name), "document.%s", format);
    doc->picture_document = !strcmp(format, "Image") || spdf_recolor_path_is_picture(name);
    return doc->picture_document;
}

/* Shared pixmap -> RGBA bitmap tail of every render path: validates the pixmap
 * layout (render_pixmap_allocation_size guards), allocates and fills out->rgba.
 * Must be called inside fz_try; throws on failure (after which out is untouched,
 * since out->rgba is only assigned once everything has succeeded). */
/* Defined next to text_page_is_image_backed(), which it shares. */
static int page_recolor_exclusions(spdf_document* doc, int page_index, float zoom, int origin_x, int origin_y,
                                   spdf_recolor_irect* out, int max);

static void copy_pixmap_to_bitmap(spdf_document* doc, fz_pixmap* pix, int page_index, float zoom, unsigned flags,
                                  spdf_bitmap* out, char* err, size_t err_len) {
    spdf_recolor_table recolor;
    spdf_recolor_irect exclusions[SPDF_RECOLOR_MAX_REGIONS];
    int exclusion_count = 0;
    unsigned char* dst;
    unsigned char* src;
    size_t byte_count;
    int width;
    int height;
    int stride;
    int comps;
    int alpha;
    int src_stride;
    int y;
    int x;

    width = fz_pixmap_width(doc->ctx, pix);
    height = fz_pixmap_height(doc->ctx, pix);
    comps = fz_pixmap_components(doc->ctx, pix);
    alpha = fz_pixmap_alpha(doc->ctx, pix);
    src_stride = fz_pixmap_stride(doc->ctx, pix);
    src = fz_pixmap_samples(doc->ctx, pix);
    if (!src || !render_pixmap_allocation_size(width, height, comps, src_stride, &stride, &byte_count, err, err_len))
        fz_throw(doc->ctx, FZ_ERROR_FORMAT, "%s", err && *err ? err : "Rendered page is too large.");

    /* The dark reading theme rides along here rather than in a pass of its
     * own: this loop already walks every pixel of every render on every path
     * and format, and recoloring each row right after writing it keeps that
     * row in L1 instead of paying a second walk of the whole image. */
    spdf_recolor_table_init(
        &recolor, ((flags & SPDF_RENDER_DARK_THEME) && !doc->dark_doc &&
                      (!(flags & SPDF_RENDER_PRESERVE_IMAGES) || !render_document_is_picture(doc)))
                      ? SPDF_RECOLOR_LUMA_REMAP
                      : SPDF_RECOLOR_NONE,
        spdf_recolor_default_dark_theme());
    if (recolor.kind != SPDF_RECOLOR_NONE && (flags & SPDF_RENDER_PRESERVE_IMAGES))
        exclusion_count = page_recolor_exclusions(doc, page_index, zoom, pix->x, pix->y, exclusions,
                                                  SPDF_RECOLOR_MAX_REGIONS);

    dst = (unsigned char*)malloc(byte_count);
    if (!dst) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");

    for (y = 0; y < height; ++y) {
        const unsigned char* row = src + (size_t)y * (size_t)src_stride;
        unsigned char* out_row = dst + (size_t)y * (size_t)stride;
        for (x = 0; x < width; ++x) {
            const unsigned char* px = row + (size_t)x * (size_t)comps;
            unsigned char* opx = out_row + (size_t)x * 4;
            opx[0] = comps > 0 ? px[0] : 255;
            opx[1] = comps > 1 ? px[1] : opx[0];
            opx[2] = comps > 2 ? px[2] : opx[0];
            opx[3] = alpha ? px[comps - 1] : 255;
        }
        if (recolor.kind != SPDF_RECOLOR_NONE)
            spdf_recolor_rgba_row(out_row, width, y, &recolor, exclusions, exclusion_count);
    }

    out->width = width;
    out->height = height;
    out->stride = stride;
    out->rgba = dst;
}
