/* spdf_svg_font_subset.c -- spdf_svg_run_page (spdf_svg_font.h): each CFF font an SVG draws, cut down to the glyphs
 * it draws. */
#include "spdf_cff_subset.h"
#include "spdf_svg_font.h"

#include <string.h>

typedef struct {
    fz_font* font;   /* as the SVG draws it */
    int* ucs;        /* per glyph: 0 not drawn, -1 drawn for no character, else the first character it was drawn for */
    fz_font* subset; /* NULL: drawn as it is */
    int* to_subset;  /* per glyph of `font`, its id in `subset`, or -1 */
} spdf_svg_used_font;

typedef struct {
    int len, cap;
    spdf_svg_used_font* fonts;
} spdf_svg_fonts;

typedef struct {
    fz_device super;
    spdf_svg_fonts* fonts;
    fz_device* target; /* NULL while finding out which glyphs are drawn */
} spdf_svg_font_device;

/* The CFF program of `font`: its whole buffer, or the 'CFF ' table of an OpenType font. NULL for any other font, and
 * for one MuPDF would not embed. */
static const unsigned char* spdf_svg_cff_program(fz_context* ctx, fz_font* font, size_t* len) {
    unsigned char* data;
    size_t n;
    if (!font->buffer || fz_font_t3_procs(ctx, font) || font->flags.ft_substitute ||
        !pdf_font_writing_supported(ctx, font))
        return NULL;
    n = fz_buffer_storage(ctx, font->buffer, &data);
    if (n > 4 && data[0] == 1 && data[1] == 0 && data[2] >= 4) {
        *len = n;
        return data;
    }
    return spdf_sfnt_cff_table(data, n, font->subfont, len);
}

static spdf_svg_used_font* spdf_svg_find_font(spdf_svg_fonts* fonts, fz_font* font) {
    int i;
    for (i = 0; i < fonts->len; i++)
        if (fonts->fonts[i].font == font) return &fonts->fonts[i];
    return NULL;
}

static void spdf_svg_collect(fz_context* ctx, spdf_svg_fonts* fonts, const fz_text* text) {
    fz_text_span* span;
    for (span = text->head; span; span = span->next) {
        spdf_svg_used_font* used = spdf_svg_find_font(fonts, span->font);
        int i;
        if (!used) {
            size_t len;
            if (fonts->len == fonts->cap) {
                int cap = fonts->cap ? fonts->cap * 2 : 8;
                fonts->fonts = fz_realloc_array(ctx, fonts->fonts, cap, spdf_svg_used_font);
                fonts->cap = cap;
            }
            used = &fonts->fonts[fonts->len];
            memset(used, 0, sizeof *used);
            if (spdf_svg_cff_program(ctx, span->font, &len) && span->font->glyph_count > 0)
                used->ucs = fz_calloc(ctx, (size_t)span->font->glyph_count, sizeof *used->ucs);
            used->font = fz_keep_font(ctx, span->font);
            fonts->len++;
        }
        if (!used->ucs) continue;
        for (i = 0; i < span->len; i++) {
            const fz_text_item* item = &span->items[i];
            if (item->gid >= 0 && item->gid < span->font->glyph_count && !used->ucs[item->gid])
                used->ucs[item->gid] = item->ucs > 0 ? item->ucs : -1;
        }
    }
}

/* The subset of one font, or nothing when it cannot be made: the font is then drawn as it is. */
static void spdf_svg_make_subset(fz_context* ctx, spdf_svg_used_font* used) {
    fz_font* font = used->font;
    int glyphs = font->glyph_count, count = 0, g, i;
    int* gids = NULL;
    int* advance = NULL;
    unsigned* unicode = NULL;
    fz_buffer* cff = NULL;
    fz_buffer* otf = NULL;
    const unsigned char* program;
    size_t len = 0;
    char name[32];

    fz_var(gids);
    fz_var(advance);
    fz_var(unicode);
    fz_var(cff);
    fz_var(otf);
    fz_try(ctx) {
        unsigned char digest[16];
        fz_md5 md5;
        const char* p;
        size_t n = 7;
        program = spdf_svg_cff_program(ctx, font, &len);
        gids = fz_malloc_array(ctx, glyphs, int);
        gids[count++] = 0; /* .notdef */
        for (g = 1; g < glyphs; g++)
            if (used->ucs[g]) gids[count++] = g;
        used->to_subset = fz_malloc_array(ctx, glyphs, int);
        for (g = 0; g < glyphs; g++) used->to_subset[g] = -1;
        unicode = fz_malloc_array(ctx, count, unsigned);
        advance = fz_malloc_array(ctx, count, int);
        for (i = 0; i < count; i++) {
            used->to_subset[gids[i]] = i;
            unicode[i] = used->ucs[gids[i]] > 0 ? (unsigned)used->ucs[gids[i]] : 0;
            advance[i] = (int)(fz_advance_glyph(ctx, font, gids[i], 0) * 1000 + 0.5f);
            if (advance[i] < 0) advance[i] = 0;
            if (advance[i] > 0xffff) advance[i] = 0xffff;
        }

        /* "ABCDEF+Helvetica": a subset's name has a tag of its own, from the glyphs it keeps (PDF 32000 9.6.4). */
        fz_md5_init(&md5);
        fz_md5_update(&md5, (const unsigned char*)font->name, strlen(font->name));
        fz_md5_update(&md5, (const unsigned char*)gids, sizeof *gids * (size_t)count);
        fz_md5_final(&md5, digest);
        for (i = 0; i < 6; i++) name[i] = (char)('A' + digest[i] % 26);
        name[6] = '+';
        for (p = font->name; *p && n + 1 < sizeof name; p++)
            if (*p > 32 && *p < 127 && !strchr("[](){}<>/%", *p)) name[n++] = *p;
        name[n] = 0;

        cff = spdf_cff_subset(ctx, program, len, gids, count, name);
        otf = spdf_sfnt_from_cff(ctx, cff->data, cff->len, count, unicode, advance, name, fz_font_bbox(ctx, font),
                                 fz_font_ascender(ctx, font), fz_font_descender(ctx, font), fz_font_is_bold(ctx, font),
                                 fz_font_is_italic(ctx, font), fz_font_is_monospaced(ctx, font));
        used->subset = fz_new_font_from_buffer(ctx, name, otf, 0, 0);
        used->subset->flags = font->flags;
    }
    fz_always(ctx) {
        fz_free(ctx, gids);
        fz_free(ctx, advance);
        fz_free(ctx, unicode);
        fz_drop_buffer(ctx, cff);
        fz_drop_buffer(ctx, otf);
    }
    fz_catch(ctx) {
        fz_rethrow_if(ctx, FZ_ERROR_SYSTEM);
        fz_report_error(ctx);
        fz_drop_font(ctx, used->subset);
        used->subset = NULL;
    }
}

/* What spdf_svg_swap changed, for spdf_svg_unswap. */
typedef struct {
    fz_font** fonts; /* per span: the font it had, or NULL when unchanged */
    int* gids;       /* per item */
} spdf_svg_swapped;

/* Points the spans of `text` at the subset fonts and their glyphs at the subsets' glyph ids, for the one call that
 * draws it. A span with a glyph its subset lacks keeps its font. */
static void spdf_svg_swap(fz_context* ctx, spdf_svg_fonts* fonts, const fz_text* text, spdf_svg_swapped* saved) {
    fz_text_span* span;
    int spans = 0, items = 0, s, k, i;
    for (span = text->head; span; span = span->next) spans++, items += span->len;
    saved->fonts = fz_calloc(ctx, (size_t)spans + 1, sizeof *saved->fonts);
    fz_try(ctx) saved->gids = fz_malloc_array(ctx, items + 1, int);
    fz_catch(ctx) {
        fz_free(ctx, saved->fonts);
        saved->fonts = NULL;
        fz_rethrow(ctx);
    }
    for (span = text->head, s = 0, k = 0; span; span = span->next, s++) {
        spdf_svg_used_font* used = spdf_svg_find_font(fonts, span->font);
        int ok = used && used->subset;
        for (i = 0; ok && i < span->len; i++) {
            int gid = span->items[i].gid;
            ok = gid < 0 || (gid < span->font->glyph_count && used->to_subset[gid] >= 0);
        }
        for (i = 0; i < span->len; i++, k++) {
            saved->gids[k] = span->items[i].gid;
            if (ok && saved->gids[k] >= 0) span->items[i].gid = used->to_subset[saved->gids[k]];
        }
        if (ok) {
            saved->fonts[s] = span->font;
            span->font = used->subset;
        }
    }
}

static void spdf_svg_unswap(fz_context* ctx, const fz_text* text, spdf_svg_swapped* saved) {
    fz_text_span* span;
    int s, k, i;
    if (!saved->fonts) return;
    for (span = text->head, s = 0, k = 0; span; span = span->next, s++) {
        if (saved->fonts[s]) span->font = saved->fonts[s];
        for (i = 0; i < span->len; i++, k++) span->items[i].gid = saved->gids[k];
    }
    fz_free(ctx, saved->fonts);
    fz_free(ctx, saved->gids);
}

#define SPDF_SVG_TEXT(call)                               \
    spdf_svg_font_device* d = (spdf_svg_font_device*)dev; \
    spdf_svg_swapped saved = {NULL, NULL};                \
    if (!d->target) {                                     \
        spdf_svg_collect(ctx, d->fonts, text);            \
        return;                                           \
    }                                                     \
    spdf_svg_swap(ctx, d->fonts, text, &saved);           \
    fz_try(ctx) call;                                     \
    fz_always(ctx) spdf_svg_unswap(ctx, text, &saved);    \
    fz_catch(ctx) fz_rethrow(ctx);

static void spdf_svg_fill_text(fz_context* ctx, fz_device* dev, const fz_text* text, fz_matrix ctm, fz_colorspace* cs,
                               const float* color, float alpha, fz_color_params cp) {
    SPDF_SVG_TEXT(fz_fill_text(ctx, d->target, text, ctm, cs, color, alpha, cp))
}

static void spdf_svg_stroke_text(fz_context* ctx, fz_device* dev, const fz_text* text, const fz_stroke_state* stroke,
                                 fz_matrix ctm, fz_colorspace* cs, const float* color, float alpha,
                                 fz_color_params cp) {
    SPDF_SVG_TEXT(fz_stroke_text(ctx, d->target, text, stroke, ctm, cs, color, alpha, cp))
}

static void spdf_svg_clip_text(fz_context* ctx, fz_device* dev, const fz_text* text, fz_matrix ctm, fz_rect scissor) {
    SPDF_SVG_TEXT(fz_clip_text(ctx, d->target, text, ctm, scissor))
}

static void spdf_svg_clip_stroke_text(fz_context* ctx, fz_device* dev, const fz_text* text,
                                      const fz_stroke_state* stroke, fz_matrix ctm, fz_rect scissor) {
    SPDF_SVG_TEXT(fz_clip_stroke_text(ctx, d->target, text, stroke, ctm, scissor))
}

static void spdf_svg_ignore_text(fz_context* ctx, fz_device* dev, const fz_text* text,
                                 fz_matrix ctm){SPDF_SVG_TEXT(fz_ignore_text(ctx, d -> target, text, ctm))}
/* Everything else goes to the PDF device unchanged. */
#define SPDF_SVG_TARGET (((spdf_svg_font_device*)dev)->target)

static void spdf_svg_fill_path(fz_context* ctx, fz_device* dev, const fz_path* path, int even_odd, fz_matrix ctm,
                               fz_colorspace* cs, const float* color, float alpha, fz_color_params cp) {
    fz_fill_path(ctx, SPDF_SVG_TARGET, path, even_odd, ctm, cs, color, alpha, cp);
}

static void spdf_svg_stroke_path(fz_context* ctx, fz_device* dev, const fz_path* path, const fz_stroke_state* stroke,
                                 fz_matrix ctm, fz_colorspace* cs, const float* color, float alpha,
                                 fz_color_params cp) {
    fz_stroke_path(ctx, SPDF_SVG_TARGET, path, stroke, ctm, cs, color, alpha, cp);
}

static void spdf_svg_clip_path(fz_context* ctx, fz_device* dev, const fz_path* path, int even_odd, fz_matrix ctm,
                               fz_rect scissor) {
    fz_clip_path(ctx, SPDF_SVG_TARGET, path, even_odd, ctm, scissor);
}

static void spdf_svg_clip_stroke_path(fz_context* ctx, fz_device* dev, const fz_path* path,
                                      const fz_stroke_state* stroke, fz_matrix ctm, fz_rect scissor) {
    fz_clip_stroke_path(ctx, SPDF_SVG_TARGET, path, stroke, ctm, scissor);
}

static void spdf_svg_fill_shade(fz_context* ctx, fz_device* dev, fz_shade* shade, fz_matrix ctm, float alpha,
                                fz_color_params cp) {
    fz_fill_shade(ctx, SPDF_SVG_TARGET, shade, ctm, alpha, cp);
}

static void spdf_svg_fill_image(fz_context* ctx, fz_device* dev, fz_image* image, fz_matrix ctm, float alpha,
                                fz_color_params cp) {
    fz_fill_image(ctx, SPDF_SVG_TARGET, image, ctm, alpha, cp);
}

static void spdf_svg_fill_image_mask(fz_context* ctx, fz_device* dev, fz_image* image, fz_matrix ctm, fz_colorspace* cs,
                                     const float* color, float alpha, fz_color_params cp) {
    fz_fill_image_mask(ctx, SPDF_SVG_TARGET, image, ctm, cs, color, alpha, cp);
}

static void spdf_svg_clip_image_mask(fz_context* ctx, fz_device* dev, fz_image* image, fz_matrix ctm, fz_rect scissor) {
    fz_clip_image_mask(ctx, SPDF_SVG_TARGET, image, ctm, scissor);
}

static void spdf_svg_pop_clip(fz_context* ctx, fz_device* dev) {
    fz_pop_clip(ctx, SPDF_SVG_TARGET);
}

static void spdf_svg_begin_mask(fz_context* ctx, fz_device* dev, fz_rect area, int luminosity, fz_colorspace* cs,
                                const float* bc, fz_color_params cp) {
    fz_begin_mask(ctx, SPDF_SVG_TARGET, area, luminosity, cs, bc, cp);
}

static void spdf_svg_end_mask(fz_context* ctx, fz_device* dev, fz_function* fn) {
    fz_end_mask_tr(ctx, SPDF_SVG_TARGET, fn);
}

static void spdf_svg_begin_group(fz_context* ctx, fz_device* dev, fz_rect area, fz_colorspace* cs, int isolated,
                                 int knockout, int blendmode, float alpha) {
    fz_begin_group(ctx, SPDF_SVG_TARGET, area, cs, isolated, knockout, blendmode, alpha);
}

static void spdf_svg_end_group(fz_context* ctx, fz_device* dev) {
    fz_end_group(ctx, SPDF_SVG_TARGET);
}

static int spdf_svg_begin_tile(fz_context* ctx, fz_device* dev, fz_rect area, fz_rect view, float xstep, float ystep,
                               fz_matrix ctm, int id, int doc_id) {
    return fz_begin_tile_tid(ctx, SPDF_SVG_TARGET, area, view, xstep, ystep, ctm, id, doc_id);
}

static void spdf_svg_end_tile(fz_context* ctx, fz_device* dev) {
    fz_end_tile(ctx, SPDF_SVG_TARGET);
}

static void spdf_svg_render_flags(fz_context* ctx, fz_device* dev, int set, int clear) {
    fz_render_flags(ctx, SPDF_SVG_TARGET, set, clear);
}

static void spdf_svg_default_colorspaces(fz_context* ctx, fz_device* dev, fz_default_colorspaces* cs) {
    fz_set_default_colorspaces(ctx, SPDF_SVG_TARGET, cs);
}

static void spdf_svg_begin_layer(fz_context* ctx, fz_device* dev, const char* name) {
    fz_begin_layer(ctx, SPDF_SVG_TARGET, name);
}

static void spdf_svg_end_layer(fz_context* ctx, fz_device* dev) {
    fz_end_layer(ctx, SPDF_SVG_TARGET);
}

static void spdf_svg_begin_structure(fz_context* ctx, fz_device* dev, fz_structure standard, const char* raw, int idx) {
    fz_begin_structure(ctx, SPDF_SVG_TARGET, standard, raw, idx);
}

static void spdf_svg_end_structure(fz_context* ctx, fz_device* dev) {
    fz_end_structure(ctx, SPDF_SVG_TARGET);
}

static void spdf_svg_begin_metatext(fz_context* ctx, fz_device* dev, fz_metatext meta, const char* text) {
    fz_begin_metatext(ctx, SPDF_SVG_TARGET, meta, text);
}

static void spdf_svg_end_metatext(fz_context* ctx, fz_device* dev) {
    fz_end_metatext(ctx, SPDF_SVG_TARGET);
}

static void spdf_svg_text_callbacks(fz_device* dev) {
    dev->fill_text = spdf_svg_fill_text;
    dev->stroke_text = spdf_svg_stroke_text;
    dev->clip_text = spdf_svg_clip_text;
    dev->clip_stroke_text = spdf_svg_clip_stroke_text;
    dev->ignore_text = spdf_svg_ignore_text;
}

static void spdf_svg_forward_callbacks(fz_device* dev, fz_device* target) {
    dev->hints = target->hints;
    dev->flags = target->flags;
    dev->fill_path = spdf_svg_fill_path;
    dev->stroke_path = spdf_svg_stroke_path;
    dev->clip_path = spdf_svg_clip_path;
    dev->clip_stroke_path = spdf_svg_clip_stroke_path;
    dev->fill_shade = spdf_svg_fill_shade;
    dev->fill_image = spdf_svg_fill_image;
    dev->fill_image_mask = spdf_svg_fill_image_mask;
    dev->clip_image_mask = spdf_svg_clip_image_mask;
    dev->pop_clip = spdf_svg_pop_clip;
    dev->begin_mask = spdf_svg_begin_mask;
    dev->end_mask = spdf_svg_end_mask;
    dev->begin_group = spdf_svg_begin_group;
    dev->end_group = spdf_svg_end_group;
    dev->begin_tile = spdf_svg_begin_tile;
    dev->end_tile = spdf_svg_end_tile;
    dev->render_flags = spdf_svg_render_flags;
    dev->set_default_colorspaces = spdf_svg_default_colorspaces;
    dev->begin_layer = spdf_svg_begin_layer;
    dev->end_layer = spdf_svg_end_layer;
    dev->begin_structure = spdf_svg_begin_structure;
    dev->end_structure = spdf_svg_end_structure;
    dev->begin_metatext = spdf_svg_begin_metatext;
    dev->end_metatext = spdf_svg_end_metatext;
}

void spdf_svg_run_page(fz_context* ctx, fz_page* page, fz_device* dev) {
    spdf_svg_fonts fonts = {0, 0, NULL};
    spdf_svg_font_device* pass = NULL;
    int i, subsets = 0;

    fz_var(pass);
    fz_try(ctx) {
        pass = fz_new_derived_device(ctx, spdf_svg_font_device);
        pass->fonts = &fonts;
        spdf_svg_text_callbacks(&pass->super);
        fz_run_page(ctx, page, &pass->super, fz_identity, NULL);
        fz_close_device(ctx, &pass->super);
        fz_drop_device(ctx, &pass->super);
        pass = NULL;

        for (i = 0; i < fonts.len; i++)
            if (fonts.fonts[i].ucs) {
                spdf_svg_make_subset(ctx, &fonts.fonts[i]);
                subsets += fonts.fonts[i].subset != NULL;
            }
        if (!subsets)
            fz_run_page(ctx, page, dev, fz_identity, NULL);
        else {
            pass = fz_new_derived_device(ctx, spdf_svg_font_device);
            pass->fonts = &fonts;
            pass->target = dev;
            spdf_svg_text_callbacks(&pass->super);
            spdf_svg_forward_callbacks(&pass->super, dev);
            fz_run_page(ctx, page, &pass->super, fz_identity, NULL);
            fz_close_device(ctx, &pass->super);
        }
    }
    fz_always(ctx) {
        fz_drop_device(ctx, (fz_device*)pass);
        for (i = 0; i < fonts.len; i++) {
            fz_drop_font(ctx, fonts.fonts[i].font);
            fz_drop_font(ctx, fonts.fonts[i].subset);
            fz_free(ctx, fonts.fonts[i].ucs);
            fz_free(ctx, fonts.fonts[i].to_subset);
        }
        fz_free(ctx, fonts.fonts);
    }
    fz_catch(ctx) fz_rethrow(ctx);
}
