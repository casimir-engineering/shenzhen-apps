/* A PDF page canvas's layers and objects as JSON (docs/plans/annotate.md § 5 PDFs): the operation arguments kept in
 * an annotation's /SPDFAnnotate so it can be edited again, a layer's whole state as one string so the bridge writes
 * only what changed, and an annotation's fingerprint so a reload reads only what someone else changed. */
#include "spdf_paint_pdf_internal.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char* const k_shape_names[SPDF_PAINT_SHAPE_COUNT] = {
    "line", "curve", "oval", "rectangle", "rounded_rectangle", "polygon", "triangle", "right_triangle", "diamond",
    "pentagon", "hexagon", "right_arrow", "left_arrow", "up_arrow", "down_arrow", "star4", "star5", "star6",
    "rounded_callout", "oval_callout", "cloud_callout", "heart", "lightning", "arrow_line"};
static const char* const k_style_names[] = {"none", "solid", "crayon", "marker", "oil", "natural_pencil",
                                            "watercolor"};
static const char* const k_align_names[] = {"left", "center", "right"};

char* spdf_paint_pdf_strdup(const char* text) {
    size_t n = strlen(text ? text : "");
    char* copy = (char*)malloc(n + 1);
    if (copy) memcpy(copy, text ? text : "", n + 1);
    return copy;
}

void spdf_paint_pdf_uuid(char out[33]) {
    static unsigned counter;
    unsigned char bytes[16];
    int i;
#if defined(__APPLE__)
    arc4random_buf(bytes, sizeof bytes);
#else
    FILE* f = fopen("/dev/urandom", "rb");
    size_t got = f ? fread(bytes, 1, sizeof bytes, f) : 0;
    if (f) fclose(f);
    for (i = (int)got; i < 16; ++i) bytes[i] = (unsigned char)(rand() ^ (int)time(NULL) ^ (int)(++counter * 2654435761u));
#endif
    bytes[0] ^= (unsigned char)++counter;
    for (i = 0; i < 16; ++i) snprintf(out + i * 2, 3, "%02x", bytes[i]);
}

void spdf_paint_pdf_color_text(spdf_paint_color color, char out[10]) {
    if ((color & 0xFF) == 0xFF) snprintf(out, 10, "#%06X", (unsigned)(color >> 8));
    else snprintf(out, 10, "#%08X", (unsigned)color);
}

int spdf_paint_pdf_color_parse(const char* text, spdf_paint_color* out) {
    size_t n;
    char* end;
    unsigned long v;
    if (!text || text[0] != '#') return 0;
    n = strlen(text + 1);
    if (n != 6 && n != 8) return 0;
    v = strtoul(text + 1, &end, 16);
    if (*end) return 0;
    *out = n == 6 ? (spdf_paint_color)((v << 8) | 0xFF) : (spdf_paint_color)v;
    return 1;
}

void spdf_paint_pdf_rgb(spdf_paint_color color, float rgb[3]) {
    rgb[0] = (float)((color >> 24) & 0xFF) / 255.0f;
    rgb[1] = (float)((color >> 16) & 0xFF) / 255.0f;
    rgb[2] = (float)((color >> 8) & 0xFF) / 255.0f;
}

spdf_paint_color spdf_paint_pdf_from_rgb(const float* rgb, int n) {
    float c[3] = {0, 0, 0};
    int i;
    for (i = 0; i < 3; ++i) c[i] = n >= 3 ? rgb[i] : n == 1 ? rgb[0] : 0;
    return ((spdf_paint_color)lroundf(fminf(fmaxf(c[0], 0), 1) * 255) << 24) |
           ((spdf_paint_color)lroundf(fminf(fmaxf(c[1], 0), 1) * 255) << 16) |
           ((spdf_paint_color)lroundf(fminf(fmaxf(c[2], 0), 1) * 255) << 8) | 0xFF;
}

uint64_t spdf_paint_pdf_hash_pixmap(fz_context* ctx, const fz_pixmap* pixmap) {
    uint64_t h = 1469598103934665603ull;
    int y, w, n, stride, height;
    const unsigned char* s;
    if (!pixmap) return 0;
    w = fz_pixmap_width(ctx, (fz_pixmap*)pixmap), height = fz_pixmap_height(ctx, (fz_pixmap*)pixmap);
    n = fz_pixmap_components(ctx, (fz_pixmap*)pixmap), stride = (int)fz_pixmap_stride(ctx, (fz_pixmap*)pixmap);
    s = fz_pixmap_samples(ctx, (fz_pixmap*)pixmap);
    h = (h ^ (uint64_t)w) * 1099511628211ull;
    h = (h ^ (uint64_t)height) * 1099511628211ull;
    for (y = 0; y < height; ++y) {
        const uint64_t* row = (const uint64_t*)(const void*)(s + (size_t)y * stride);
        size_t bytes = (size_t)w * n, i, words = bytes / 8;
        for (i = 0; i < words; ++i) {
            uint64_t v;
            memcpy(&v, row + i, 8);
            h = (h ^ v) * 1099511628211ull;
        }
        for (i = words * 8; i < bytes; ++i) h = (h ^ s[(size_t)y * stride + i]) * 1099511628211ull;
    }
    return h;
}

/* ---- JSON helpers ---- */

static void add_color(cJSON* to, const char* key, spdf_paint_color color) {
    char text[10];
    spdf_paint_pdf_color_text(color, text);
    cJSON_AddStringToObject(to, key, text);
}

static cJSON* point_json(spdf_paint_point p) {
    cJSON* a = cJSON_CreateArray();
    cJSON_AddItemToArray(a, cJSON_CreateNumber(p.x));
    cJSON_AddItemToArray(a, cJSON_CreateNumber(p.y));
    if (p.pressure != 1.0f && p.pressure > 0) cJSON_AddItemToArray(a, cJSON_CreateNumber(p.pressure));
    return a;
}

static cJSON* points_json(const spdf_paint_point* points, int count) {
    cJSON* a = cJSON_CreateArray();
    int i;
    for (i = 0; i < count; ++i) cJSON_AddItemToArray(a, point_json(points[i]));
    return a;
}

static void add_placement(cJSON* to, const spdf_paint_placement* place) {
    cJSON* r = cJSON_AddObjectToObject(to, "rect");
    cJSON_AddNumberToObject(r, "x", place->rect.x0);
    cJSON_AddNumberToObject(r, "y", place->rect.y0);
    cJSON_AddNumberToObject(r, "w", place->rect.x1 - place->rect.x0);
    cJSON_AddNumberToObject(r, "h", place->rect.y1 - place->rect.y0);
    if (place->rotation != 0) cJSON_AddNumberToObject(to, "rotation", place->rotation);
    if (place->flip_h) cJSON_AddBoolToObject(to, "flipH", 1);
    if (place->flip_v) cJSON_AddBoolToObject(to, "flipV", 1);
}

static double num(const cJSON* o, const char* key, double fallback) {
    const cJSON* v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsNumber(v) ? v->valuedouble : fallback;
}

static int flag(const cJSON* o, const char* key) { return cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(o, key)); }

static const char* str(const cJSON* o, const char* key) {
    const cJSON* v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}

static spdf_paint_color color_of(const cJSON* o, const char* key, spdf_paint_color fallback) {
    spdf_paint_color c = fallback;
    const char* text = str(o, key);
    if (text && strcmp(text, "transparent") == 0) return 0;
    if (text) spdf_paint_pdf_color_parse(text, &c);
    return c;
}

static int name_index(const char* const* names, int count, const char* name, int fallback) {
    int i;
    for (i = 0; name && i < count; ++i)
        if (strcmp(names[i], name) == 0) return i;
    return fallback;
}

static spdf_paint_point read_point(const cJSON* a) {
    spdf_paint_point p = {0, 0, 1};
    if (cJSON_IsArray(a) && cJSON_GetArraySize(a) >= 2) {
        p.x = (float)cJSON_GetArrayItem(a, 0)->valuedouble;
        p.y = (float)cJSON_GetArrayItem(a, 1)->valuedouble;
        if (cJSON_GetArraySize(a) > 2) p.pressure = (float)cJSON_GetArrayItem(a, 2)->valuedouble;
    }
    return p;
}

static spdf_paint_point* read_points(fz_context* ctx, const cJSON* a, int* count) {
    int i, n = cJSON_IsArray(a) ? cJSON_GetArraySize(a) : 0;
    spdf_paint_point* out;
    *count = 0;
    if (n <= 0) return NULL;
    out = fz_malloc_array(ctx, n, spdf_paint_point);
    for (i = 0; i < n; ++i) out[i] = read_point(cJSON_GetArrayItem(a, i));
    *count = n;
    return out;
}

static void read_placement(const cJSON* args, spdf_paint_placement* place) {
    const cJSON* r = cJSON_GetObjectItemCaseSensitive(args, "rect");
    place->rect.x0 = (float)num(r, "x", 0), place->rect.y0 = (float)num(r, "y", 0);
    place->rect.x1 = place->rect.x0 + (float)num(r, "w", 0), place->rect.y1 = place->rect.y0 + (float)num(r, "h", 0);
    place->rotation = (float)num(args, "rotation", 0);
    place->flip_h = flag(args, "flipH"), place->flip_v = flag(args, "flipV");
}

/* ---- Our objects <-> their operation arguments ---- */

cJSON* spdf_paint_pdf_object_args(const spdf_paint_object* object) {
    cJSON* args = cJSON_CreateObject();
    if (!args) return NULL;
    add_placement(args, &object->place);
    if (object->kind == SPDF_PAINT_OBJ_SHAPE) {
        const spdf_paint_shape_params* s = &object->u.shape;
        cJSON *outline, *fill;
        cJSON_AddStringToObject(args, "shape", s->shape < SPDF_PAINT_SHAPE_COUNT ? k_shape_names[s->shape] : "rectangle");
        if (s->point_count > 0) cJSON_AddItemToObject(args, "points", points_json(s->points, s->point_count));
        outline = cJSON_AddObjectToObject(args, "outline");
        cJSON_AddStringToObject(outline, "style", k_style_names[s->outline.style]);
        add_color(outline, "color", s->outline.color);
        cJSON_AddNumberToObject(outline, "width", s->outline.width);
        fill = cJSON_AddObjectToObject(args, "fill");
        cJSON_AddStringToObject(fill, "style", k_style_names[s->fill.style]);
        add_color(fill, "color", s->fill.color);
        if (s->shape == SPDF_PAINT_SHAPE_ROUNDED_CALLOUT || s->shape == SPDF_PAINT_SHAPE_OVAL_CALLOUT ||
            s->shape == SPDF_PAINT_SHAPE_CLOUD_CALLOUT)
            cJSON_AddItemToObject(args, "tail", point_json(s->tail));
    } else if (object->kind == SPDF_PAINT_OBJ_TEXT) {
        const spdf_paint_text_params* t = &object->u.text;
        cJSON_AddStringToObject(args, "text", t->utf8 ? t->utf8 : "");
        if (t->font) cJSON_AddStringToObject(args, "font", t->font);
        if (t->resolved_font) cJSON_AddStringToObject(args, "resolvedFont", t->resolved_font);
        cJSON_AddNumberToObject(args, "size", t->size);
        cJSON_AddBoolToObject(args, "bold", t->bold);
        cJSON_AddBoolToObject(args, "italic", t->italic);
        cJSON_AddBoolToObject(args, "underline", t->underline);
        cJSON_AddBoolToObject(args, "strikethrough", t->strikethrough);
        cJSON_AddStringToObject(args, "align", k_align_names[t->align <= SPDF_PAINT_ALIGN_RIGHT ? t->align : 0]);
        add_color(args, "color", t->color);
        if (t->background) add_color(args, "background", t->background);
        else cJSON_AddStringToObject(args, "background", "transparent");
        if (t->grows) cJSON_AddBoolToObject(args, "grows", 1);
    }
    return args;
}

int spdf_paint_pdf_object_from_args(fz_context* ctx, spdf_paint_object* object, const cJSON* args) {
    read_placement(args, &object->place);
    if (object->kind == SPDF_PAINT_OBJ_SHAPE) {
        spdf_paint_shape_params* s = &object->u.shape;
        const cJSON* outline = cJSON_GetObjectItemCaseSensitive(args, "outline");
        const cJSON* fill = cJSON_GetObjectItemCaseSensitive(args, "fill");
        s->shape = (spdf_paint_shape)name_index(k_shape_names, SPDF_PAINT_SHAPE_COUNT, str(args, "shape"),
                                                SPDF_PAINT_SHAPE_RECTANGLE);
        s->points = read_points(ctx, cJSON_GetObjectItemCaseSensitive(args, "points"), &s->point_count);
        s->tail = read_point(cJSON_GetObjectItemCaseSensitive(args, "tail"));
        s->outline.style = (spdf_paint_style)name_index(k_style_names, 7, str(outline, "style"), SPDF_PAINT_STYLE_SOLID);
        s->outline.color = color_of(outline, "color", 0x000000FF);
        s->outline.width = (float)num(outline, "width", 3);
        s->fill.style = (spdf_paint_style)name_index(k_style_names, 7, str(fill, "style"), SPDF_PAINT_STYLE_NONE);
        s->fill.color = color_of(fill, "color", 0xFFFFFFFF);
    } else if (object->kind == SPDF_PAINT_OBJ_TEXT) {
        spdf_paint_text_params* t = &object->u.text;
        const char* font = str(args, "font");
        const char* resolved = str(args, "resolvedFont");
        t->utf8 = fz_strdup(ctx, str(args, "text") ? str(args, "text") : "");
        t->font = font ? fz_strdup(ctx, font) : NULL;
        t->resolved_font = resolved ? fz_strdup(ctx, resolved) : NULL;
        t->size = (float)num(args, "size", 24);
        t->bold = flag(args, "bold"), t->italic = flag(args, "italic");
        t->underline = flag(args, "underline"), t->strikethrough = flag(args, "strikethrough");
        t->align = (spdf_paint_align)name_index(k_align_names, 3, str(args, "align"), SPDF_PAINT_ALIGN_LEFT);
        t->color = color_of(args, "color", 0x000000FF);
        t->background = color_of(args, "background", 0);
        t->grows = flag(args, "grows");
    }
    return 1;
}

/* ---- A layer's whole state ---- */

char* spdf_paint_pdf_layer_state(spdf_paint_doc* doc, const spdf_paint_layer* layer) {
    cJSON* s = cJSON_CreateObject();
    char hash[24], *text, *copy;
    const spdf_paint_object* o = layer->object;
    cJSON_AddNumberToObject(s, "k", layer->kind);
    cJSON_AddStringToObject(s, "n", layer->name);
    cJSON_AddBoolToObject(s, "v", layer->visible);
    cJSON_AddNumberToObject(s, "o", floorf(layer->opacity * 1000.0f + 0.5f));
    if (layer->kind == SPDF_PAINT_LAYER_RASTER) {
        snprintf(hash, sizeof hash, "%016llx", (unsigned long long)spdf_paint_pdf_hash_pixmap(doc->ctx, layer->pixels));
        cJSON_AddStringToObject(s, "h", hash);
    }
    if (o) {
        cJSON_AddNumberToObject(s, "ok", o->kind);
        switch (o->kind) {
        case SPDF_PAINT_OBJ_SHAPE:
        case SPDF_PAINT_OBJ_TEXT:
            cJSON_AddItemToObject(s, "a", spdf_paint_pdf_object_args(o));
            break;
        case SPDF_PAINT_OBJ_PICTURE:
            add_placement(s, &o->place);
            snprintf(hash, sizeof hash, "%016llx",
                     (unsigned long long)spdf_paint_pdf_hash_pixmap(doc->ctx, o->u.picture.pixels));
            cJSON_AddStringToObject(s, "h", hash);
            break;
        case SPDF_PAINT_OBJ_PEN:
        case SPDF_PAINT_OBJ_ARROW:
            cJSON_AddItemToObject(s, "pts", points_json(o->u.line.points, o->u.line.point_count));
            add_color(s, "c", o->u.line.color);
            cJSON_AddNumberToObject(s, "w", o->u.line.width);
            break;
        case SPDF_PAINT_OBJ_FILL_TEXT:
        case SPDF_PAINT_OBJ_FILL_MARK:
        case SPDF_PAINT_OBJ_FILL_SIGNATURE:
            add_placement(s, &o->place);
            cJSON_AddStringToObject(s, "nm", o->u.fill.nm ? o->u.fill.nm : "");
            cJSON_AddNumberToObject(s, "fk", o->u.fill.fill_kind);
            if (o->u.fill.text) cJSON_AddStringToObject(s, "t", o->u.fill.text);
            cJSON_AddNumberToObject(s, "fs", o->u.fill.font_size);
            break;
        case SPDF_PAINT_OBJ_FOREIGN:
            add_placement(s, &o->place);
            cJSON_AddNumberToObject(s, "num", o->u.foreign.object_number);
            break;
        }
    }
    text = cJSON_PrintUnformatted(s);
    cJSON_Delete(s);
    copy = spdf_paint_pdf_strdup(text ? text : "");
    cJSON_free(text);
    return copy;
}

/* ---- An annotation's fingerprint ---- */

char* spdf_paint_pdf_annot_fingerprint(fz_context* ctx, pdf_obj* annot) {
    static const char* const keys[] = {"Subtype", "Rect", "F", "CA", "Contents", "InkList", "C", "IC", "BS", "DA",
                                       "Vertices", "Name", "M", NULL};
    fz_buffer* volatile buf = NULL;
    fz_output* volatile out = NULL;
    char* volatile result = NULL;
    fz_try(ctx) {
        pdf_obj* ours = pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY);
        int i;
        unsigned char* data;
        size_t len;
        buf = fz_new_buffer(ctx, 256);
        out = fz_new_output_with_buffer(ctx, buf);
        for (i = 0; keys[i]; ++i) {
            pdf_obj* v = pdf_dict_gets(ctx, annot, keys[i]);
            fz_write_string(ctx, out, keys[i]);
            if (v) pdf_print_obj(ctx, out, v, 1, 1);
        }
        if (ours) pdf_print_obj(ctx, out, pdf_dict_gets(ctx, ours, "Rev"), 1, 1);
        fz_close_output(ctx, out);
        len = fz_buffer_storage(ctx, buf, &data);
        result = (char*)malloc(len + 1);
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        memcpy(result, data, len);
        result[len] = 0;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_drop_buffer(ctx, buf);
    }
    fz_catch(ctx) {
        free(result);
        fz_rethrow(ctx);
    }
    return result;
}
