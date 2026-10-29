/* Removing the original text of translated lines from a PDF copy: the first
 * half of spdf_save_translated_copy_full's replacement step (the second half,
 * writing the translations, is spdf_translate_write.h). Included in place by
 * shenzhen_pdf_core.c.
 *
 *   1. The original glyphs whose centre lies in a line's box are removed from
 *      the page contents (Form XObjects are instanced, so text drawn by a
 *      shared form is removed too). Nothing is painted over them, so
 *      backgrounds, images and vector art under the text stay as they were.
 *   2. When the removed glyphs were invisible (an OCR layer over a scan), the
 *      visible text is the image itself: the image pixels inside the line's
 *      box are set to the box's own background colour (its per-channel
 *      median), and the rest of the image is left untouched. */

typedef struct tr_line {
    fz_rect box;     /* page space, as the line was extracted */
    fz_rect pdf_box; /* the same box in PDF user space, for the content filter */
    char* text;      /* single-line translation */
    float font_size;
    int visible_glyphs;
    int invisible_glyphs;
    unsigned int rgb;
    int bold;
    int italic;
} tr_line;

typedef struct tr_page {
    tr_line* lines;
    int count;
    fz_archive* fonts; /* cjk.ttf: Droid Sans Fallback, a TrueType face that subsets */
    struct tr_recorder* recorder;
} tr_page;

static int tr_line_is_scan(const tr_line* line) { return line->invisible_glyphs > line->visible_glyphs; }

/* Removes every glyph whose centre falls in a translated line's box. */
static int tr_text_filter(fz_context* ctx, void* opaque, int* ucsbuf, int ucslen, fz_matrix trm, fz_matrix ctm,
                          fz_rect bbox, int tr, float ca, float CA) {
    tr_page* page = (tr_page*)opaque;
    fz_rect r = fz_transform_rect(bbox, fz_concat(trm, ctm));
    float cx = (r.x0 + r.x1) * 0.5f;
    float cy = (r.y0 + r.y1) * 0.5f;
    int i;

    (void)ctx;
    (void)ucsbuf;
    (void)ucslen;
    (void)CA;
    for (i = 0; i < page->count; ++i) {
        tr_line* line = &page->lines[i];
        if (cx < line->pdf_box.x0 || cx > line->pdf_box.x1 || cy < line->pdf_box.y0 || cy > line->pdf_box.y1) continue;
        if (tr == 3 || tr == 7 || ca <= 0.0f)
            line->invisible_glyphs++;
        else
            line->visible_glyphs++;
        return 1;
    }
    return 0;
}

/* Sets the pixels inside [x0,x1)x[y0,y1) to the region's per-channel median,
 * i.e. the background the scanned glyphs were printed on. */
static void tr_fill_region_with_median(fz_pixmap* pix, int x0, int y0, int x1, int y1) {
    int channels = pix->n - pix->alpha;
    int c;
    int x;
    int y;

    if (channels <= 0) channels = pix->n;
    if (x1 <= x0 || y1 <= y0) return;
    for (c = 0; c < channels; ++c) {
        unsigned int hist[256];
        unsigned int total = (unsigned int)((x1 - x0) * (y1 - y0));
        unsigned int seen = 0;
        int median = 0;
        memset(hist, 0, sizeof hist);
        for (y = y0; y < y1; ++y)
            for (x = x0; x < x1; ++x) hist[pix->samples[(size_t)y * pix->stride + (size_t)x * pix->n + c]]++;
        while (median < 255 && (seen += hist[median]) * 2 < total) median++;
        for (y = y0; y < y1; ++y)
            for (x = x0; x < x1; ++x) pix->samples[(size_t)y * pix->stride + (size_t)x * pix->n + c] = (unsigned char)median;
    }
}

static fz_image* tr_image_filter(fz_context* ctx, void* opaque, fz_matrix ctm, const char* name, fz_image* image,
                                 fz_rect scissor) {
    tr_page* page = (tr_page*)opaque;
    fz_rect area = fz_transform_rect(fz_unit_rect, ctm);
    fz_pixmap* pix = NULL;
    fz_image* out = NULL;
    fz_buffer* jpeg = NULL;
    fz_compressed_buffer* compressed;
    int i;

    (void)name;
    (void)scissor;
    fz_var(pix);
    fz_var(jpeg);
    fz_try(ctx) {
        for (i = 0; i < page->count; ++i) {
            tr_line* line = &page->lines[i];
            float pad = (line->pdf_box.y1 - line->pdf_box.y0) * 0.12f;
            fz_irect r;
            fz_matrix to_pixels;
            if (!tr_line_is_scan(line)) continue;
            if (fz_is_empty_rect(fz_intersect_rect(fz_expand_rect(line->pdf_box, pad), area))) continue;
            if (!pix) {
                fz_pixmap* decoded = fz_get_pixmap_from_image(ctx, image, NULL, NULL, NULL, NULL);
                fz_try(ctx) pix = fz_clone_pixmap(ctx, decoded);
                fz_always(ctx) fz_drop_pixmap(ctx, decoded);
                fz_catch(ctx) fz_rethrow(ctx);
            }
            to_pixels = fz_post_scale(fz_invert_matrix(ctm), (float)pix->w, (float)pix->h);
            r = fz_round_rect(fz_transform_rect(fz_expand_rect(line->pdf_box, pad), to_pixels));
            /* Image space has y up; pixmap rows run top-down. */
            tr_fill_region_with_median(pix, fz_clampi(r.x0, 0, pix->w), fz_clampi(pix->h - r.y1, 0, pix->h),
                                       fz_clampi(r.x1, 0, pix->w), fz_clampi(pix->h - r.y0, 0, pix->h));
        }
        if (!pix) {
            out = fz_keep_image(ctx, image);
        } else {
            compressed = fz_compressed_image_buffer(ctx, image);
            if (compressed && compressed->params.type == FZ_IMAGE_JPEG && !pix->alpha && (pix->n == 1 || pix->n == 3)) {
                jpeg = fz_new_buffer_from_pixmap_as_jpeg(ctx, pix, fz_default_color_params, 90, 0);
                out = fz_new_image_from_buffer(ctx, jpeg);
            } else {
                out = fz_new_image_from_pixmap(ctx, pix, NULL);
            }
            out->imagemask = image->imagemask;
            out->mask = fz_keep_image(ctx, image->mask);
        }
    }
    fz_always(ctx) {
        fz_drop_pixmap(ctx, pix);
        fz_drop_buffer(ctx, jpeg);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
    return out;
}

static void tr_filter_page(fz_context* ctx, pdf_document* pdf, pdf_page* page, tr_page* lines, int images) {
    pdf_filter_options filter_opts;
    pdf_sanitize_filter_options sanitize_opts;
    pdf_filter_factory filter_list[2];

    memset(&filter_opts, 0, sizeof filter_opts);
    memset(&sanitize_opts, 0, sizeof sanitize_opts);
    memset(filter_list, 0, sizeof filter_list);
    filter_opts.instance_forms = 1;
    filter_opts.ascii = 1;
    filter_opts.filters = filter_list;
    sanitize_opts.opaque = lines;
    if (images)
        sanitize_opts.image_filter = tr_image_filter;
    else
        sanitize_opts.text_filter = tr_text_filter;
    filter_list[0].filter = pdf_new_sanitize_filter;
    filter_list[0].options = &sanitize_opts;
    pdf_filter_page_contents(ctx, pdf, page, &filter_opts);
}

/* The most common colour of the original characters in each line, so white
 * text on a dark band stays white, and whether most were bold or italic.
 * Lines over a scan are drawn black. */
static void tr_pick_text_colors(fz_context* ctx, fz_document* source, int page_index, tr_page* page) {
    fz_stext_options opts;
    fz_stext_page* text = NULL;
    fz_stext_block* block;
    fz_stext_line* tline;
    fz_stext_char* ch;
    int i;

    memset(&opts, 0, sizeof opts);
    fz_var(text);
    fz_try(ctx) {
        text = fz_new_stext_page_from_page_number(ctx, source, page_index, &opts);
        for (i = 0; i < page->count; ++i) {
            tr_line* line = &page->lines[i];
            unsigned int colors[8];
            int counts[8];
            int used = 0;
            int total = 0;
            int bold = 0;
            int italic = 0;
            int j;
            line->rgb = 0;
            if (tr_line_is_scan(line)) continue;
            for (block = text->first_block; block; block = block->next) {
                if (block->type != FZ_STEXT_BLOCK_TEXT || fz_is_empty_rect(fz_intersect_rect(block->bbox, line->box)))
                    continue;
                for (tline = block->u.t.first_line; tline; tline = tline->next)
                    for (ch = tline->first_char; ch; ch = ch->next) {
                        fz_rect q = fz_rect_from_quad(ch->quad);
                        unsigned int rgb = ch->argb & 0xffffff;
                        if (ch->c == ' ' ||
                            !fz_is_point_inside_rect(fz_make_point((q.x0 + q.x1) * 0.5f, (q.y0 + q.y1) * 0.5f),
                                                     line->box))
                            continue;
                        for (j = 0; j < used && colors[j] != rgb; ++j) {}
                        if (j == used && used < 8) {
                            colors[used] = rgb;
                            counts[used++] = 0;
                        }
                        if (j < used) counts[j]++;
                        total++;
                        bold += ch->font && fz_font_is_bold(ctx, ch->font);
                        italic += ch->font && fz_font_is_italic(ctx, ch->font);
                    }
            }
            for (j = 0; j < used; ++j)
                if (counts[j] > counts[0]) {
                    counts[0] = counts[j];
                    colors[0] = colors[j];
                }
            if (used) line->rgb = colors[0];
            line->bold = bold * 2 > total;
            line->italic = italic * 2 > total;
        }
    }
    fz_always(ctx) {
        fz_drop_stext_page(ctx, text);
    }
    fz_catch(ctx) {
        fz_report_error(ctx);
    }
}
