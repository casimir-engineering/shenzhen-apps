/* Annotate's text boxes (docs/plans/annotate.md § 2 Text box, § 8 Core spdf_paint_text.c): text objects drawn with
 * MuPDF fonts, the system font found through the frontend's resolver (spdf_paint_set_font_resolver; the Mac's uses
 * CoreText), MuPDF's Helvetica, Times or Courier otherwise; any character the face lacks (Chinese in Helvetica, say)
 * comes from MuPDF's fallback fonts. Bold, italic (synthesised when the family has no such face), underline,
 * strikethrough, left/centre/right alignment, Color 1, a transparent or opaque (Color 2) background, words wrapped
 * in the box, and boxes made by a click that grow with their text. The text.add handler and its argument reader.
 *
 * Sizes are points; on a picture or canvas one point is one pixel (what 100 % zoom shows), on a PDF page a point. */
#include "spdf_paint_brush_engine.h"
#include "spdf_paint_handlers.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

/* Set once by the frontend before the first text object is drawn (spdf_paint.h). */
static spdf_paint_font_resolver g_resolver;
static void* g_resolver_user;

void spdf_paint_set_font_resolver(spdf_paint_font_resolver resolver, void* user) {
    g_resolver = resolver;
    g_resolver_user = user;
}

/* ---- Fonts, kept per canvas ---- */

enum { CACHE_FONTS = 24 };
typedef struct font_entry { char key[320]; fz_font* font; char* resolved; } font_entry;
typedef struct text_cache { int count; font_entry e[CACHE_FONTS]; } text_cache;

void spdf_paint_text_cache_drop(spdf_paint_doc* doc) {
    text_cache* c = doc ? doc->text_cache : NULL;
    int i;
    if (!c) return;
    for (i = 0; i < c->count; ++i) fz_drop_font(doc->ctx, c->e[i].font), fz_free(doc->ctx, c->e[i].resolved);
    fz_free(doc->ctx, c);
    doc->text_cache = NULL;
}

static int contains_ci(const char* hay, const char* needle) {
    size_t n = strlen(needle), i, j;
    for (i = 0; hay[i]; ++i) {
        for (j = 0; j < n && hay[i + j] && (hay[i + j] | 32) == (needle[j] | 32); ++j) {}
        if (j == n) return 1;
    }
    return 0;
}

static fz_font* base14(fz_context* ctx, const char* family, int bold, int italic, const char** resolved) {
    static const char* const names[3][4] = {
        {"Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"},
        {"Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic"},
        {"Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"}};
    int k = contains_ci(family, "courier") || contains_ci(family, "mono") || contains_ci(family, "menlo") ? 2
          : contains_ci(family, "times") || contains_ci(family, "serif") || contains_ci(family, "georgia") ? 1 : 0;
    if (k == 1 && contains_ci(family, "sans")) k = 0;
    *resolved = k == 2 ? "Courier" : k == 1 ? "Times" : "Helvetica";
    return fz_new_base14_font(ctx, names[k][(bold ? 1 : 0) + (italic ? 2 : 0)]);
}

/* The face for the text's family and style, kept. With record, the choice is written into text->resolved_font. */
static fz_font* font_for(spdf_paint_doc* doc, const spdf_paint_text_params* text, char** record) {
    fz_context* ctx = doc->ctx;
    text_cache* c = doc->text_cache;
    const char* family = text->font ? text->font : "";
    char key[320], path[1024];
    const char* resolved = NULL;
    fz_font* font = NULL;
    int i, face = 0;
    snprintf(key, sizeof(key), "%s|%d|%d", family, text->bold ? 1 : 0, text->italic ? 1 : 0);
    if (!c) c = doc->text_cache = fz_malloc_struct(ctx, text_cache);
    for (i = 0; i < c->count; ++i)
        if (!strcmp(c->e[i].key, key)) {
            if (record) fz_free(ctx, *record), *record = fz_strdup(ctx, c->e[i].resolved);
            return fz_keep_font(ctx, c->e[i].font);
        }
    if (g_resolver && g_resolver(g_resolver_user, family, text->bold, text->italic, path, sizeof(path), &face)) {
        fz_try(ctx) font = fz_new_font_from_file(ctx, NULL, path, face, 0);
        fz_catch(ctx) font = NULL;
        if (font) {
            resolved = path;
            if (text->italic && !fz_font_is_italic(ctx, font)) fz_font_flags(font)->fake_italic = 1;
        }
    }
    if (!font) font = base14(ctx, family, text->bold, text->italic, &resolved);
    if (c->count == CACHE_FONTS) { /* the oldest goes */
        fz_drop_font(ctx, c->e[0].font), fz_free(ctx, c->e[0].resolved);
        memmove(&c->e[0], &c->e[1], sizeof(c->e[0]) * (CACHE_FONTS - 1));
        c->count--;
    }
    snprintf(c->e[c->count].key, sizeof(c->e[0].key), "%s", key);
    c->e[c->count].font = font;
    c->e[c->count].resolved = fz_strdup(ctx, resolved);
    c->count++;
    if (record) fz_free(ctx, *record), *record = fz_strdup(ctx, resolved);
    return fz_keep_font(ctx, font);
}

fz_font* spdf_paint_text_font(spdf_paint_doc* doc, spdf_paint_text_params* text) {
    fz_font* font = NULL;
    if (!doc || !text) return NULL;
    fz_try(doc->ctx) font = font_for(doc, text, &text->resolved_font);
    fz_catch(doc->ctx) font = NULL;
    return font;
}

/* ---- Layout ---- */

typedef struct glyph { fz_font* font; int gid, ucs; float x, adv; int line; } glyph;
typedef struct layout {
    glyph* g;
    int count;
    int lines;
    float* widths;   /* per line, trailing spaces left out */
    float pad, ascent, line_height, width, height;
} layout;

static int breaks_after(int ucs) { return ucs == ' ' || ucs == '\t' || ucs == '-' || (ucs >= 0x2E80 && ucs < 0xFF00); }
static int is_space(int ucs) { return ucs == ' ' || ucs == '\t'; }

static void layout_free(fz_context* ctx, layout* l) {
    fz_free(ctx, l->g), fz_free(ctx, l->widths);
    memset(l, 0, sizeof(*l));
}

/* Glyphs placed in lines; wraps at max_width (frame units; 0: only at line breaks). */
static void layout_text(fz_context* ctx, fz_font* font, const spdf_paint_text_params* t, float max_width, layout* l) {
    const char* s = t->utf8 ? t->utf8 : "";
    float size = t->size > 0 ? t->size : 24, x = 0, inner;
    int n = 0, cap = (int)strlen(s) + 1, line = 0, line_start = 0, last_break = -1, i;
    memset(l, 0, sizeof(*l));
    l->pad = fmaxf(2, size * 0.08f);
    l->ascent = fz_font_ascender(ctx, font) * size;
    l->line_height = size * 1.25f;
    inner = max_width > 0 ? fmaxf(max_width - 2 * l->pad, size * 0.6f) : 0;
    l->g = fz_malloc(ctx, (size_t)cap * sizeof(glyph));
    while (*s) {
        int ucs;
        s += fz_chartorune(&ucs, s);
        if (ucs == '\r') continue;
        if (ucs == '\n') {
            ++line, x = 0, line_start = n, last_break = -1;
            continue;
        }
        if (ucs == '\t') ucs = ' ';
        l->g[n].gid = fz_encode_character_with_fallback(ctx, font, ucs, 0, FZ_LANG_UNSET, &l->g[n].font);
        l->g[n].ucs = ucs;
        l->g[n].adv = fz_advance_glyph(ctx, l->g[n].font, l->g[n].gid, 0) * size;
        if (inner > 0 && x + l->g[n].adv > inner && !is_space(ucs) && n > line_start) {
            int from = last_break >= line_start ? last_break + 1 : n; /* the word moves down, or the glyph does */
            ++line, x = 0;
            for (i = from; i < n; ++i) l->g[i].line = line, l->g[i].x = x, x += l->g[i].adv;
            line_start = from, last_break = -1;
        }
        l->g[n].line = line, l->g[n].x = x, x += l->g[n].adv;
        if (breaks_after(ucs)) last_break = n;
        ++n;
    }
    l->count = n, l->lines = line + 1;
    l->widths = fz_calloc(ctx, (size_t)l->lines, sizeof(float));
    for (i = 0; i < n; ++i)
        if (!is_space(l->g[i].ucs)) l->widths[l->g[i].line] = fmaxf(l->widths[l->g[i].line], l->g[i].x + l->g[i].adv);
    for (i = 0; i < l->lines; ++i) l->width = fmaxf(l->width, l->widths[i]);
    l->width += 2 * l->pad;
    l->height = 2 * l->pad + l->lines * l->line_height;
}

int spdf_paint_text_measure(spdf_paint_doc* doc, const spdf_paint_text_params* text, float max_width, float* width,
                            float* height) {
    fz_context* ctx = doc ? doc->ctx : NULL;
    fz_font* font = NULL;
    layout l;
    int ok = 1;
    if (width) *width = 0;
    if (height) *height = 0;
    if (!doc || !text) return 0;
    memset(&l, 0, sizeof(l));
    fz_var(font);
    fz_try(ctx) {
        font = font_for(doc, text, NULL);
        layout_text(ctx, font, text, max_width, &l);
        if (width) *width = fmaxf(l.width, (text->size > 0 ? text->size : 24) * 0.6f);
        if (height) *height = l.height;
    }
    fz_always(ctx) {
        layout_free(ctx, &l);
        fz_drop_font(ctx, font);
    }
    fz_catch(ctx) ok = 0;
    return ok;
}

/* ---- Drawing ---- */

static void fill_rect(fz_context* ctx, fz_device* dev, fz_rect r, fz_matrix m, spdf_paint_color c) {
    fz_path* path = fz_new_path(ctx);
    float rgb[3] = {((c >> 24) & 0xFF) / 255.0f, ((c >> 16) & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f};
    fz_try(ctx) {
        fz_rectto(ctx, path, r.x0, r.y0, r.x1, r.y1);
        fz_fill_path(ctx, dev, path, 0, m, fz_device_rgb(ctx), rgb, (c & 0xFF) / 255.0f, fz_default_color_params);
    }
    fz_always(ctx) fz_drop_path(ctx, path);
    fz_catch(ctx) fz_rethrow(ctx);
}

int spdf_paint_text_draw(spdf_paint_doc* doc, const spdf_paint_placement* place, const spdf_paint_text_params* t,
                         fz_matrix ctm, fz_pixmap* dest, fz_irect clip, float opacity) {
    fz_context* ctx = doc->ctx;
    float w = place->rect.x1 - place->rect.x0, h = place->rect.y1 - place->rect.y0, size = t->size > 0 ? t->size : 24;
    fz_matrix frame_to_dev = fz_concat(spdf_paint_shape_frame(place), ctm);
    fz_irect box = fz_round_rect(fz_transform_rect(fz_make_rect(0, 0, w, h), frame_to_dev));
    fz_font* font = NULL;
    fz_text *text = NULL, *heavy = NULL;
    fz_stroke_state* stroke = NULL;
    fz_device* dev = NULL;
    layout l;
    int ok = 1, i, line;
    memset(&l, 0, sizeof(l));
    box = fz_intersect_irect(fz_intersect_irect(box, clip), fz_pixmap_bbox(ctx, dest));
    if (fz_is_empty_irect(box) || opacity <= 0 || w <= 0 || h <= 0) return 1;
    fz_var(font), fz_var(text), fz_var(dev), fz_var(heavy), fz_var(stroke);
    fz_try(ctx) {
        float rgb[3] = {((t->color >> 24) & 0xFF) / 255.0f, ((t->color >> 16) & 0xFF) / 255.0f,
                        ((t->color >> 8) & 0xFF) / 255.0f};
        float alpha = (t->color & 0xFF) / 255.0f, deco = fmaxf(size * 0.06f, 0.5f);
        fz_path* clip_path;
        font = font_for(doc, t, NULL);
        layout_text(ctx, font, t, t->grows ? 0 : w, &l);
        dev = fz_new_draw_device_with_bbox(ctx, fz_identity, dest, &box);
        fz_begin_group(ctx, dev, fz_rect_from_irect(box), NULL, 1, 0, FZ_BLEND_NORMAL, opacity);
        if (t->background & 0xFF) fill_rect(ctx, dev, fz_make_rect(0, 0, w, h), frame_to_dev, t->background);
        clip_path = fz_new_path(ctx); /* the box clips what runs past its edges */
        fz_try(ctx) {
            fz_rectto(ctx, clip_path, 0, 0, w, h);
            fz_clip_path(ctx, dev, clip_path, 0, frame_to_dev, fz_infinite_rect);
        }
        fz_always(ctx) fz_drop_path(ctx, clip_path);
        fz_catch(ctx) fz_rethrow(ctx);
        text = fz_new_text(ctx), heavy = fz_new_text(ctx);
        for (line = 0, i = 0; line < l.lines; ++line) {
            float lw = l.widths[line], x0 = t->align == SPDF_PAINT_ALIGN_CENTER ? (w - lw) / 2
                                          : t->align == SPDF_PAINT_ALIGN_RIGHT ? w - l.pad - lw : l.pad;
            float base = l.pad + l.ascent + line * l.line_height;
            if (base - l.ascent > h) break;
            for (; i < l.count && l.g[i].line == line; ++i) {
                fz_matrix trm = fz_make_matrix(size, 0, 0, -size, x0 + l.g[i].x, base);
                if (t->italic && l.g[i].font != font && !fz_font_is_italic(ctx, l.g[i].font))
                    trm = fz_pre_shear(trm, 0.2f, 0);
                fz_show_glyph(ctx, text, l.g[i].font, trm, l.g[i].gid, l.g[i].ucs, 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
                if (t->bold && !fz_font_is_bold(ctx, l.g[i].font)) /* no bold face: drawn heavier by an outline */
                    fz_show_glyph(ctx, heavy, l.g[i].font, trm, l.g[i].gid, l.g[i].ucs, 0, 0, FZ_BIDI_LTR,
                                  FZ_LANG_UNSET);
            }
            if (lw > 0 && t->underline)
                fill_rect(ctx, dev, fz_make_rect(x0, base + size * 0.10f, x0 + lw, base + size * 0.10f + deco),
                          frame_to_dev, t->color);
            if (lw > 0 && t->strikethrough)
                fill_rect(ctx, dev, fz_make_rect(x0, base - size * 0.30f, x0 + lw, base - size * 0.30f + deco),
                          frame_to_dev, t->color);
        }
        fz_begin_group(ctx, dev, fz_rect_from_irect(box), NULL, 1, 1, FZ_BLEND_NORMAL, 1); /* knockout: no double ink */
        fz_fill_text(ctx, dev, text, frame_to_dev, fz_device_rgb(ctx), rgb, alpha, fz_default_color_params);
        if (heavy->head) {
            stroke = fz_new_stroke_state(ctx);
            stroke->linewidth = size * 0.045f, stroke->linejoin = FZ_LINEJOIN_ROUND;
            fz_stroke_text(ctx, dev, heavy, stroke, frame_to_dev, fz_device_rgb(ctx), rgb, alpha, fz_default_color_params);
        }
        fz_end_group(ctx, dev);
        fz_pop_clip(ctx, dev);
        fz_end_group(ctx, dev);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_text(ctx, text), fz_drop_text(ctx, heavy);
        fz_drop_stroke_state(ctx, stroke);
        fz_drop_device(ctx, dev);
        fz_drop_font(ctx, font);
        layout_free(ctx, &l);
    }
    fz_catch(ctx) ok = 0;
    return ok;
}

/* ---- text.add ---- */

static int read_bool(const spdf_paint_call* call, const char* name, int* out) {
    int v = 0;
    if (!spdf_paint_arg_bool(call, name, &v)) return 0;
    *out = v;
    return 1;
}

spdf_paint_status spdf_paint_text_read_args(spdf_paint_call* call, spdf_paint_object* object, int update) {
    spdf_paint_doc* doc = call->doc;
    fz_context* ctx = doc->ctx;
    spdf_paint_text_params t = update ? object->u.text : (spdf_paint_text_params){0};
    spdf_paint_placement place = update ? object->place : (spdf_paint_placement){{0, 0, 0, 0}, 0, 0, 0};
    const char *text = spdf_paint_arg_string(call, "text"), *font = spdf_paint_arg_string(call, "font");
    const char* align = spdf_paint_arg_string(call, "align");
    spdf_rect rect;
    int has_rect = spdf_paint_arg_rect(call, "rect", &rect), restyled = 0;
    spdf_paint_color c;
    double v = 24;
    float w = 0, h = 0;
    if (!update) {
        t.size = 24, t.color = doc->color1, t.background = 0, t.align = SPDF_PAINT_ALIGN_LEFT;
        if (!has_rect) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Give the text box a rect.");
    }
    if (spdf_paint_arg_number(call, "size", &v) || !update) t.size = (float)fmin(fmax(v > 0 ? v : 24, 8), 400), restyled = 1;
    restyled |= read_bool(call, "bold", &t.bold) | read_bool(call, "italic", &t.italic);
    restyled |= read_bool(call, "underline", &t.underline) | read_bool(call, "strikethrough", &t.strikethrough);
    if (align) t.align = !strcmp(align, "center") ? SPDF_PAINT_ALIGN_CENTER : !strcmp(align, "right")
                         ? SPDF_PAINT_ALIGN_RIGHT : SPDF_PAINT_ALIGN_LEFT;
    if (spdf_paint_arg_color(call, "color", &c)) t.color = c;
    if (cJSON_GetObjectItemCaseSensitive(call->args, "background") && spdf_paint_arg_color(call, "background", &c))
        t.background = c;
    fz_try(ctx) {
        if (text) {
            if (update && t.utf8) fz_free(ctx, t.utf8);
            t.utf8 = fz_strdup(ctx, text), restyled = 1;
        }
        if (font) {
            if (update && t.font) fz_free(ctx, t.font);
            t.font = fz_strdup(ctx, font), restyled = 1;
        }
        if (has_rect) place.rect = rect;
        if (!update) t.grows = place.rect.x1 - place.rect.x0 < 4; /* a click: the box grows with its text */
        if (restyled || has_rect || !update) {
            fz_font* f = font_for(doc, &t, &t.resolved_font);
            fz_drop_font(ctx, f);
        }
        if (!spdf_paint_text_measure(doc, &t, t.grows ? 0 : place.rect.x1 - place.rect.x0, &w, &h))
            fz_throw(ctx, FZ_ERROR_GENERIC, "measure");
        if (t.grows) place.rect.x1 = place.rect.x0 + w;
        if (place.rect.y1 - place.rect.y0 < h) place.rect.y1 = place.rect.y0 + h; /* grows down to fit, as Paint's */
    }
    fz_catch(ctx) {
        if (!update) fz_free(ctx, t.utf8), fz_free(ctx, t.font), fz_free(ctx, t.resolved_font);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_FAILED, "The text couldn't be set.");
    }
    if (spdf_paint_arg_number(call, "rotation", &v)) place.rotation = (float)fmod(v, 360.0);
    object->u.text = t;
    object->place = place;
    spdf_paint_object_update_bounds(object);
    return SPDF_PAINT_OK;
}

/* "Text: Hello" for the Layers panel: the first line, cut at a word near 24 characters. */
static void name_text_layer(spdf_paint_layer* layer, const char* utf8) {
    char first[64];
    size_t n = 0;
    int chars = 0;
    while (utf8 && utf8[n] && utf8[n] != '\n' && n < sizeof(first) - 4 && chars < 24) {
        int ucs, len = fz_chartorune(&ucs, utf8 + n);
        if (n + (size_t)len >= sizeof(first) - 4) break;
        memcpy(first + n, utf8 + n, (size_t)len), n += (size_t)len, ++chars;
    }
    first[n] = 0;
    if (utf8 && (utf8[n] && utf8[n] != '\n')) snprintf(first + n, sizeof(first) - n, "...");
    snprintf(layer->name, sizeof(layer->name), n ? "Text: %s" : "Text", first);
}

spdf_paint_status spdf_paint_op_text_add(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_object scratch, *object;
    spdf_paint_layer* layer;
    spdf_paint_id id = 0;
    spdf_paint_status st = spdf_paint_arg_check_page(call);
    if (st != SPDF_PAINT_OK) return call->message[0] ? st : spdf_paint_call_fail(call, st, "That page is not here.");
    memset(&scratch, 0, sizeof(scratch));
    scratch.kind = SPDF_PAINT_OBJ_TEXT;
    st = spdf_paint_text_read_args(call, &scratch, 0);
    if (st != SPDF_PAINT_OK) return st;
    object = spdf_paint_object_new(doc, SPDF_PAINT_OBJ_TEXT, &id);
    if (!object) {
        fz_free(doc->ctx, scratch.u.text.utf8), fz_free(doc->ctx, scratch.u.text.font);
        fz_free(doc->ctx, scratch.u.text.resolved_font);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_FAILED, "The text box couldn't be added.");
    }
    object->place = scratch.place;
    object->u.text = scratch.u.text;
    spdf_paint_object_update_bounds(object);
    if ((layer = spdf_paint_layer_find(doc, id))) name_text_layer(layer, object->u.text.utf8);
    spdf_paint_damage(doc, object->bounds);
    if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_pdf_note_change(doc, layer);
    cJSON_AddNumberToObject(call->reply, "id", id);
    return SPDF_PAINT_OK;
}
