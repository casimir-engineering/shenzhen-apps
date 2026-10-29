/* Writing translated lines into a PDF copy whose original text
 * spdf_translate_redact.h has removed. Included in place by
 * shenzhen_pdf_core.c.
 *
 * The translation is laid out with mupdf's HTML engine (shaping, bidi,
 * per-script fallback fonts) and written as real text into one Form XObject
 * per page, so it embeds its fonts (subset) and stays selectable and
 * searchable. It is shrunk to the line's box width, and wrapped inside the
 * box only when that keeps it clearly larger than one shrunken line. */

/* What each embedded glyph stands for, as the layout drew it: a ligature or a
 * contextual Arabic form maps back to its source characters, which the
 * font's own cmap (all mupdf's ToUnicode uses) cannot say. */
typedef struct tr_glyph_text {
    int font;
    int gid;
    int ucs[4];
    int n;
} tr_glyph_text;

typedef struct tr_recorder {
    fz_device super;
    pdf_document* pdf;
    fz_buffer* cjk; /* every story loads its own font from this buffer... */
    unsigned char cjk_digest[16]; /* ...so hash its 5 MB once, not per line */
    int cjk_hashed;
    tr_glyph_text* items;
    int len;
    int cap;
} tr_recorder;

static int tr_text_is_rtl(const char* text) {
    while (*text) {
        int c;
        text += fz_chartorune(&c, text);
        if ((c >= 0x0590 && c <= 0x08FF) || (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF)) return 1;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c >= 0x00C0) return 0;
    }
    return 0;
}

/* mupdf picks the CJK fallback face by language: kana means Japanese, hangul
 * Korean, otherwise Han text is set as Simplified Chinese. */
static const char* tr_text_language(const char* text) {
    int han = 0;
    while (*text) {
        int c;
        text += fz_chartorune(&c, text);
        if (c >= 0x3040 && c <= 0x30FF) return "ja";
        if ((c >= 0xAC00 && c <= 0xD7AF) || (c >= 0x1100 && c <= 0x11FF)) return "ko";
        if (c >= 0x4E00 && c <= 0x9FFF) han = 1;
    }
    return han ? "zh-Hans" : NULL;
}

/* Reference size the HTML engine lays text out at; the result is scaled. */
#define TR_LAYOUT_EM 12.0f

/* Lays out the line at TR_LAYOUT_EM in a box `width` wide (0 = one unwrapped
 * line) and records it into a display list. Returns NULL when it does not
 * fit (a word wider than the box, or more text than `max_height`). */
static fz_display_list* tr_layout_line(fz_context* ctx, const tr_line* line, fz_archive* fonts, float width,
                                       float max_height, fz_rect* block, fz_rect* ink) {
    int rtl = tr_text_is_rtl(line->text);
    const char* lang = tr_text_language(line->text);
    int cjk = lang && fonts;
    fz_buffer* html = NULL;
    fz_story* story = NULL;
    fz_display_list* list = NULL;
    fz_device* dev = NULL;
    char css[400];
    const char* p;
    fz_rect where;
    int more;

    fz_var(html);
    fz_var(story);
    fz_var(list);
    fz_var(dev);
    fz_try(ctx) {
        html = fz_new_buffer(ctx, strlen(line->text) + 64);
        fz_append_printf(ctx, html, "<p dir=\"%s\" lang=\"%s\">", rtl ? "rtl" : "ltr", lang ? lang : "und");
        for (p = line->text; *p; ++p) {
            if (*p == '&') fz_append_string(ctx, html, "&amp;");
            else if (*p == '<') fz_append_string(ctx, html, "&lt;");
            else if (*p == '>') fz_append_string(ctx, html, "&gt;");
            else fz_append_byte(ctx, html, *p);
        }
        fz_append_string(ctx, html, "</p>");
        snprintf(css, sizeof css,
                 "%sbody,p{margin:0;padding:0}p{font-family:%s;line-height:1.2;color:#%06x;text-align:%s;"
                 "font-weight:%s;font-style:%s;white-space:%s}",
                 cjk ? "@font-face{font-family:spdfcjk;src:url(cjk.ttf)}" : "", cjk ? "spdfcjk" : "sans-serif",
                 line->rgb & 0xffffff, rtl ? "right" : "left", line->bold ? "bold" : "normal",
                 line->italic ? "italic" : "normal",
                 width > 0.0f ? "normal" : "nowrap");
        story = fz_new_story(ctx, html, css, TR_LAYOUT_EM, cjk ? fonts : NULL);
        where = fz_make_rect(0, 0, width > 0.0f ? width : 100000.0f, max_height > 0.0f ? max_height : 100000.0f);
        more = fz_place_story_flags(ctx, story, where, block, width > 0.0f ? FZ_PLACE_STORY_FLAG_NO_OVERFLOW : 0);
        if (!more) {
            list = fz_new_display_list(ctx, where);
            dev = fz_new_list_device(ctx, list);
            fz_draw_story(ctx, story, dev, fz_identity);
            fz_close_device(ctx, dev);
            fz_drop_device(ctx, dev);
            dev = NULL;
            *ink = fz_empty_rect;
            dev = fz_new_bbox_device(ctx, ink);
            fz_run_display_list(ctx, list, dev, fz_identity, fz_infinite_rect, NULL);
            fz_close_device(ctx, dev);
        }
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_story(ctx, story);
        fz_drop_buffer(ctx, html);
    }
    fz_catch(ctx) {
        fz_drop_display_list(ctx, list);
        fz_rethrow(ctx);
    }
    return list;
}

static void tr_draw_line(fz_context* ctx, fz_device* dev, const tr_line* line, fz_archive* fonts,
                         fz_device* recorder) {
    fz_rect box = line->box;
    float w = box.x1 - box.x0;
    float h = box.y1 - box.y0;
    float size = line->font_size > 0.0f ? line->font_size : h * 0.8f;
    float k_max;
    float k = 0.0f;
    float tx;
    float ty;
    int wrapped = 0;
    fz_rect block;
    fz_rect ink;
    fz_display_list* list = NULL;
    fz_display_list* probe = NULL;

    if (h > 1.0f && size > h * 1.1f) size = h * 1.1f;
    size = fz_clamp(size, 2.0f, 96.0f);
    k_max = size / TR_LAYOUT_EM;
    fz_var(list);
    fz_var(probe);
    fz_var(k);
    fz_var(wrapped);
    fz_try(ctx) {
        list = tr_layout_line(ctx, line, fonts, 0.0f, 0.0f, &block, &ink);
        if (list && !fz_is_empty_rect(ink)) {
            k = fz_min(k_max, w * 0.98f / (ink.x1 - ink.x0));
            /* Wrap only when one line would have to shrink a lot and the box
             * holds two lines at least 1.4 times that size: wrapping splits
             * the text, so a small gain is not worth it. A single token (a
             * part number, a code) is never split. */
            if (k < k_max * 0.7f && h >= 2.0f * (block.y1 - block.y0) * k * 1.4f &&
                (strchr(line->text, ' ') || tr_text_language(line->text))) {
                float lo = k * 1.4f;
                float hi = k_max;
                int step;
                for (step = 0; step < 7 && hi - lo > k_max * 0.02f; ++step) {
                    float mid = step == 0 ? lo : (lo + hi) * 0.5f;
                    fz_rect b;
                    fz_rect i;
                    probe = tr_layout_line(ctx, line, fonts, w / mid, h * 1.05f / mid, &b, &i);
                    if (!probe) {
                        hi = mid;
                        continue;
                    }
                    fz_drop_display_list(ctx, list);
                    list = probe;
                    probe = NULL;
                    k = mid;
                    block = b;
                    ink = i;
                    wrapped = 1;
                    lo = mid;
                }
            }
            if (wrapped)
                tx = box.x0 - block.x0 * k;
            else
                tx = tr_text_is_rtl(line->text) ? box.x1 - ink.x1 * k : box.x0 - ink.x0 * k;
            ty = box.y0 + (h - (block.y1 - block.y0) * k) * 0.5f - block.y0 * k;
            fz_run_display_list(ctx, list, recorder, fz_identity, fz_infinite_rect, NULL);
            fz_run_display_list(ctx, list, dev, fz_make_matrix(k, 0, 0, k, tx, ty), fz_infinite_rect, NULL);
        }
    }
    fz_always(ctx) {
        fz_drop_display_list(ctx, probe);
        fz_drop_display_list(ctx, list);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

static void tr_record_text(fz_context* ctx, fz_device* dev, const fz_text* text, fz_matrix ctm, fz_colorspace* cs,
                           const float* color, float alpha, fz_color_params params) {
    tr_recorder* rec = (tr_recorder*)dev;
    fz_text_span* span;
    int i;

    (void)ctm;
    (void)cs;
    (void)color;
    (void)alpha;
    (void)params;
    for (span = text->head; span; span = span->next) {
        pdf_obj* font;
        int num;
        tr_glyph_text* last = NULL;
        if (rec->cjk && span->font->buffer == rec->cjk && !span->font->has_digest) {
            if (!rec->cjk_hashed) fz_font_digest(ctx, span->font, rec->cjk_digest);
            memcpy(span->font->digest, rec->cjk_digest, 16);
            span->font->has_digest = rec->cjk_hashed = 1;
        }
        font = pdf_add_cid_font(ctx, rec->pdf, span->font);
        num = pdf_to_num(ctx, font);
        pdf_drop_obj(ctx, font);
        for (i = 0; i < span->len; ++i) {
            const fz_text_item* item = &span->items[i];
            if (item->gid < 0) {
                if (last && last->n < 4 && item->ucs > 0) last->ucs[last->n++] = item->ucs;
                continue;
            }
            if (rec->len == rec->cap) {
                int cap = rec->cap ? rec->cap * 2 : 256;
                rec->items = (tr_glyph_text*)fz_realloc(ctx, rec->items, (size_t)cap * sizeof *rec->items);
                rec->cap = cap;
            }
            last = &rec->items[rec->len++];
            last->font = num;
            last->gid = item->gid;
            last->n = item->ucs > 0 ? 1 : 0;
            last->ucs[0] = item->ucs;
        }
    }
}

static int tr_compare_glyph_text(const void* a, const void* b) {
    const tr_glyph_text* ga = (const tr_glyph_text*)a;
    const tr_glyph_text* gb = (const tr_glyph_text*)b;
    if (ga->font != gb->font) return ga->font < gb->font ? -1 : 1;
    if (ga->gid != gb->gid) return ga->gid < gb->gid ? -1 : 1;
    return ga < gb ? -1 : 1; /* first drawn wins */
}

/* Replaces the cmap-derived ToUnicode of every font the translation used. */
static void tr_write_to_unicode(fz_context* ctx, pdf_document* pdf, tr_recorder* rec) {
    fz_buffer* buf = NULL;
    pdf_obj* font = NULL;
    int start;
    int i;

    qsort(rec->items, (size_t)rec->len, sizeof *rec->items, tr_compare_glyph_text);
    fz_var(buf);
    fz_var(font);
    fz_try(ctx) {
        for (start = 0; start < rec->len;) {
            int end = start;
            int count = 0;
            buf = fz_new_buffer(ctx, 1024);
            fz_append_string(ctx, buf,
                             "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
                             "/CIDSystemInfo <</Registry(Adobe)/Ordering(UCS)/Supplement 0>> def\n"
                             "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
                             "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
            while (end < rec->len && rec->items[end].font == rec->items[start].font) {
                const tr_glyph_text* g = &rec->items[end++];
                if (g->n == 0 || (end - 1 > start && rec->items[end - 2].gid == g->gid)) continue;
                if (count % 100 == 0) fz_append_string(ctx, buf, count ? "endbfchar\n100 beginbfchar\n" : "100 beginbfchar\n");
                fz_append_printf(ctx, buf, "<%04x> <", g->gid);
                for (i = 0; i < g->n; ++i) {
                    int c = g->ucs[i];
                    if (c >= 0x10000)
                        fz_append_printf(ctx, buf, "%04x%04x", 0xD800 + ((c - 0x10000) >> 10), 0xDC00 + ((c - 0x10000) & 0x3FF));
                    else
                        fz_append_printf(ctx, buf, "%04x", c);
                }
                fz_append_string(ctx, buf, ">\n");
                count++;
            }
            if (count) fz_append_string(ctx, buf, "endbfchar\n");
            fz_append_string(ctx, buf, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
            if (count) {
                font = pdf_load_object(ctx, pdf, rec->items[start].font);
                pdf_dict_put_drop(ctx, font, PDF_NAME(ToUnicode), pdf_add_stream(ctx, pdf, buf, NULL, 0));
                pdf_drop_obj(ctx, font);
                font = NULL;
            }
            fz_drop_buffer(ctx, buf);
            buf = NULL;
            start = end;
        }
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buf);
        pdf_drop_obj(ctx, font);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

/* Writes every translated line of one page, all of them in one Form XObject
 * drawn after the (now text-free) original content. */
static void tr_write_page_text(fz_context* ctx, pdf_document* pdf, pdf_page* page, tr_page* lines,
                               fz_matrix page_ctm, fz_rect mediabox) {
    pdf_obj* res = NULL;
    pdf_obj* xobj = NULL;
    pdf_obj* page_res;
    pdf_obj* xobjects;
    fz_buffer* buf = NULL;
    fz_device* dev = NULL;
    char name[32];
    int i;
    int n = 0;

    fz_var(res);
    fz_var(xobj);
    fz_var(buf);
    fz_var(dev);
    fz_try(ctx) {
        res = pdf_new_dict(ctx, pdf, 4);
        buf = fz_new_buffer(ctx, 1024);
        dev = pdf_new_pdf_device(ctx, pdf, fz_invert_matrix(page_ctm), res, buf);
        for (i = 0; i < lines->count; ++i) tr_draw_line(ctx, dev, &lines->lines[i], lines->fonts, &lines->recorder->super);
        fz_close_device(ctx, dev);
        xobj = pdf_new_xobject(ctx, pdf, mediabox, fz_identity, res, buf);

        page_res = ensure_page_resources(ctx, page->obj);
        xobjects = pdf_dict_get(ctx, page_res, PDF_NAME(XObject));
        if (!xobjects) xobjects = pdf_dict_put_dict(ctx, page_res, PDF_NAME(XObject), 4);
        do snprintf(name, sizeof name, "SPDFTr%d", n++);
        while (pdf_dict_gets(ctx, xobjects, name));
        pdf_dict_puts(ctx, xobjects, name, xobj);

        /* The XObject keeps a reference to buf: the page's call gets its own. */
        fz_drop_buffer(ctx, buf);
        buf = NULL;
        buf = fz_new_buffer(ctx, 32);
        fz_append_printf(ctx, buf, "q\n/%s Do\nQ\n", name);
        append_page_content_stream(ctx, pdf, page->obj, buf);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_buffer(ctx, buf);
        pdf_drop_obj(ctx, xobj);
        pdf_drop_obj(ctx, res);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

/* Replaces the original text of `page->count` lines on one page of `pdf`
 * (a clone of `source`) with their translations. */
static void tr_replace_page_lines(fz_context* ctx, pdf_document* pdf, fz_document* source, int page_index,
                                  tr_page* lines) {
    pdf_page* page = NULL;
    fz_matrix page_ctm;
    fz_matrix to_pdf;
    fz_rect mediabox;
    int i;
    int scans = 0;

    fz_var(page);
    fz_try(ctx) {
        page = pdf_load_page(ctx, pdf, page_index);
        pdf_page_transform(ctx, page, &mediabox, &page_ctm);
        to_pdf = fz_invert_matrix(page_ctm);
        for (i = 0; i < lines->count; ++i)
            lines->lines[i].pdf_box = fz_expand_rect(fz_transform_rect(lines->lines[i].box, to_pdf), 0.5f);

        tr_filter_page(ctx, pdf, page, lines, 0);
        for (i = 0; i < lines->count; ++i) scans += tr_line_is_scan(&lines->lines[i]);
        if (scans) tr_filter_page(ctx, pdf, page, lines, 1);
        tr_pick_text_colors(ctx, source, page_index, lines);

        balance_page_contents_for_overlays(ctx, pdf, page->obj, ensure_page_resources(ctx, page->obj));
        tr_write_page_text(ctx, pdf, page, lines, page_ctm, mediabox);
    }
    fz_always(ctx) {
        pdf_drop_page(ctx, page);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

/* Built into libmupdf (resources/fonts/droid) but outside its font table in
 * this configuration, which maps CJK to the Source Han Serif collection: a
 * CFF face that pdf_subset_fonts cannot shrink and whose language faces share
 * one digest, so it would embed ~19 MB and mix up ToUnicode maps. */
extern const unsigned char _binary_DroidSansFallbackFull_ttf[];
extern const unsigned int _binary_DroidSansFallbackFull_ttf_size;

static int tr_compare_line_pages(const void* a, const void* b) {
    const spdf_translated_line* la = *(const spdf_translated_line* const*)a;
    const spdf_translated_line* lb = *(const spdf_translated_line* const*)b;
    if (la->page_index != lb->page_index) return la->page_index < lb->page_index ? -1 : 1;
    return la < lb ? -1 : (la > lb ? 1 : 0);
}

/* Applies every translated line, page by page, then subsets the fonts the
 * translation embedded (unless the document has form fields, whose fonts
 * must keep every glyph for editing). */
static void tr_replace_lines(fz_context* ctx, pdf_document* pdf, fz_document* source, const spdf_translated_line* lines,
                             int line_count) {
    const spdf_translated_line** order = NULL;
    tr_page page;
    tr_recorder* recorder = NULL;
    fz_buffer* cjk = NULL;
    int start;
    int i;
    pdf_obj* fields;

    if (line_count <= 0) return;
    memset(&page, 0, sizeof page);
    fz_var(order);
    fz_var(cjk);
    fz_var(recorder);
    fz_try(ctx) {
        recorder = fz_new_derived_device(ctx, tr_recorder);
        recorder->super.fill_text = tr_record_text;
        recorder->pdf = pdf;
        page.recorder = recorder;
        cjk = fz_new_buffer_from_shared_data(ctx, _binary_DroidSansFallbackFull_ttf,
                                             _binary_DroidSansFallbackFull_ttf_size);
        page.fonts = fz_new_tree_archive(ctx, NULL);
        fz_tree_archive_add_buffer(ctx, page.fonts, "cjk.ttf", cjk);
        recorder->cjk = cjk;
        order = (const spdf_translated_line**)fz_malloc_array(ctx, line_count, const spdf_translated_line*);
        page.lines = (tr_line*)fz_calloc(ctx, (size_t)line_count, sizeof(tr_line));
        for (i = 0; i < line_count; ++i) order[i] = &lines[i];
        qsort(order, (size_t)line_count, sizeof *order, tr_compare_line_pages);
        for (start = 0; start < line_count;) {
            int end = start;
            page.count = 0;
            while (end < line_count && order[end]->page_index == order[start]->page_index) {
                const spdf_translated_line* src = order[end++];
                tr_line* dst = &page.lines[page.count];
                memset(dst, 0, sizeof *dst);
                dst->text = translated_text_single_line(src->text);
                if (!dst->text) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
                if (!*dst->text) {
                    free(dst->text);
                    continue;
                }
                dst->box = normalized_public_rect(&src->bounds);
                dst->font_size = src->font_size;
                page.count++;
            }
            if (page.count > 0) tr_replace_page_lines(ctx, pdf, source, order[start]->page_index, &page);
            for (i = 0; i < page.count; ++i) free(page.lines[i].text);
            page.count = 0;
            start = end;
        }
        tr_write_to_unicode(ctx, pdf, recorder);
        fields = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm/Fields");
        if (pdf_array_len(ctx, fields) == 0) {
            fz_try(ctx) pdf_subset_fonts(ctx, pdf, 0, NULL);
            fz_catch(ctx) fz_report_error(ctx);
        }
    }
    fz_always(ctx) {
        for (i = 0; i < page.count; ++i) free(page.lines[i].text);
        fz_free(ctx, page.lines);
        fz_free(ctx, order);
        fz_drop_archive(ctx, page.fonts);
        if (recorder) {
            fz_free(ctx, recorder->items);
            fz_drop_device(ctx, &recorder->super);
        }
        fz_drop_buffer(ctx, cjk);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}
