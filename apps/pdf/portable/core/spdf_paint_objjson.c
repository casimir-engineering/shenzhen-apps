/* Objects and layers as JSON (docs/plans/annotate.md § 5 .szpaint, § 6 doc.state, object.update): every object's
 * settings under the names its add operation uses, so doc.state, the .szpaint manifest and object.update speak the
 * same language. Reading them back (object.update, opening a project) goes through spdf_paint_object_apply_json. */
#include "spdf_paint_model.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static const char* k_styles[] = {"none", "solid", "crayon", "marker", "oil", "natural_pencil", "watercolor"};
static const char* k_aligns[] = {"left", "center", "right"};

const char* spdf_paint_style_name(spdf_paint_style style) {
    return (unsigned)style < sizeof(k_styles) / sizeof(k_styles[0]) ? k_styles[style] : "none";
}

int spdf_paint_style_from_name(const char* name, spdf_paint_style* out) {
    for (size_t i = 0; name && i < sizeof(k_styles) / sizeof(k_styles[0]); i++)
        if (!strcmp(name, k_styles[i])) { *out = (spdf_paint_style)i; return 1; }
    return 0;
}

/* ---- Out ---- */

/* doc.state rounds to 1/1000 for people and agents; a project keeps every digit (g_exact while it is written). */
static int g_exact;

static double tidy(double v) { return g_exact ? v : round(v * 1000.0) / 1000.0; }

cJSON* spdf_paint_rect_json(spdf_rect r) {
    cJSON* o = cJSON_CreateObject();
    cJSON_AddNumberToObject(o, "x", tidy(r.x0));
    cJSON_AddNumberToObject(o, "y", tidy(r.y0));
    cJSON_AddNumberToObject(o, "w", tidy(r.x1 - r.x0));
    cJSON_AddNumberToObject(o, "h", tidy(r.y1 - r.y0));
    return o;
}

cJSON* spdf_paint_point_json(spdf_paint_point p) {
    cJSON* a = cJSON_CreateArray();
    cJSON_AddItemToArray(a, cJSON_CreateNumber(tidy(p.x)));
    cJSON_AddItemToArray(a, cJSON_CreateNumber(tidy(p.y)));
    if (p.pressure != 1.0f && p.pressure > 0) cJSON_AddItemToArray(a, cJSON_CreateNumber(tidy(p.pressure)));
    return a;
}

cJSON* spdf_paint_color_json(spdf_paint_color color) {
    char text[10];
    spdf_paint_format_color(color, text);
    return cJSON_CreateString(text);
}

static cJSON* points_json(const spdf_paint_point* p, int n) {
    cJSON* a = cJSON_CreateArray();
    for (int i = 0; i < n; i++) cJSON_AddItemToArray(a, spdf_paint_point_json(p[i]));
    return a;
}

static void add_shape(cJSON* o, const spdf_paint_shape_params* s) {
    const char* name = spdf_paint_shape_name(s->shape);
    if (name) cJSON_AddStringToObject(o, "shape", name);
    else cJSON_AddNumberToObject(o, "shapeIndex", s->shape);
    if (s->point_count) cJSON_AddItemToObject(o, "points", points_json(s->points, s->point_count));
    if (s->tail.x || s->tail.y) cJSON_AddItemToObject(o, "tail", spdf_paint_point_json(s->tail));
    cJSON* outline = cJSON_AddObjectToObject(o, "outline");
    cJSON_AddStringToObject(outline, "style", spdf_paint_style_name(s->outline.style));
    cJSON_AddItemToObject(outline, "color", spdf_paint_color_json(s->outline.color));
    cJSON_AddNumberToObject(outline, "width", tidy(s->outline.width));
    cJSON* fill = cJSON_AddObjectToObject(o, "fill");
    cJSON_AddStringToObject(fill, "style", spdf_paint_style_name(s->fill.style));
    cJSON_AddItemToObject(fill, "color", spdf_paint_color_json(s->fill.color));
}

static void add_text(cJSON* o, const spdf_paint_text_params* t) {
    cJSON_AddStringToObject(o, "text", t->utf8 ? t->utf8 : "");
    if (t->font) cJSON_AddStringToObject(o, "font", t->font);
    if (t->resolved_font) cJSON_AddStringToObject(o, "resolvedFont", t->resolved_font);
    cJSON_AddNumberToObject(o, "size", tidy(t->size));
    cJSON_AddBoolToObject(o, "bold", t->bold);
    cJSON_AddBoolToObject(o, "italic", t->italic);
    cJSON_AddBoolToObject(o, "underline", t->underline);
    cJSON_AddBoolToObject(o, "strikethrough", t->strikethrough);
    cJSON_AddStringToObject(o, "align", k_aligns[(unsigned)t->align < 3 ? t->align : 0]);
    cJSON_AddItemToObject(o, "color", spdf_paint_color_json(t->color));
    if (t->background) cJSON_AddItemToObject(o, "background", spdf_paint_color_json(t->background));
    else cJSON_AddStringToObject(o, "background", "transparent");
    cJSON_AddBoolToObject(o, "grows", t->grows);
}

cJSON* spdf_paint_object_json(const spdf_paint_doc* doc, const spdf_paint_object* ob, int exact) {
    SPDF_PAINT_UNUSED(doc);
    g_exact = exact;
    cJSON* o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "type", spdf_paint_object_kind_name(ob->kind));
    if (!exact) cJSON_AddStringToObject(o, "kind", spdf_paint_object_kind_name(ob->kind)); /* doc.state readers */
    cJSON_AddItemToObject(o, "rect", spdf_paint_rect_json(ob->place.rect));
    cJSON_AddNumberToObject(o, "rotation", tidy(ob->place.rotation));
    if (ob->place.flip_h) cJSON_AddTrueToObject(o, "flipHorizontal");
    if (ob->place.flip_v) cJSON_AddTrueToObject(o, "flipVertical");
    cJSON_AddItemToObject(o, "bounds", spdf_paint_rect_json(ob->bounds));
    const spdf_paint_line_params* line = &ob->u.line;
    switch (ob->kind) {
    case SPDF_PAINT_OBJ_SHAPE: add_shape(o, &ob->u.shape); break;
    case SPDF_PAINT_OBJ_TEXT: add_text(o, &ob->u.text); break;
    case SPDF_PAINT_OBJ_PICTURE:
        cJSON_AddNumberToObject(o, "pixelWidth", ob->u.picture.pixels ? ob->u.picture.pixels->w : 0);
        cJSON_AddNumberToObject(o, "pixelHeight", ob->u.picture.pixels ? ob->u.picture.pixels->h : 0);
        break;
    case SPDF_PAINT_OBJ_PEN:
    case SPDF_PAINT_OBJ_ARROW:
        if (ob->kind == SPDF_PAINT_OBJ_PEN) cJSON_AddItemToObject(o, "points", points_json(line->points, line->point_count));
        else if (line->point_count >= 2) {
            cJSON_AddItemToObject(o, "tail", spdf_paint_point_json(line->points[0]));
            cJSON_AddItemToObject(o, "tip", spdf_paint_point_json(line->points[line->point_count - 1]));
        }
        cJSON_AddItemToObject(o, "color", spdf_paint_color_json(line->color));
        cJSON_AddNumberToObject(o, "width", tidy(line->width));
        break;
    case SPDF_PAINT_OBJ_FILL_TEXT:
    case SPDF_PAINT_OBJ_FILL_MARK:
    case SPDF_PAINT_OBJ_FILL_SIGNATURE:
        if (ob->u.fill.nm) cJSON_AddStringToObject(o, "nm", ob->u.fill.nm);
        cJSON_AddNumberToObject(o, "fillKind", ob->u.fill.fill_kind);
        if (ob->u.fill.text) cJSON_AddStringToObject(o, "text", ob->u.fill.text);
        if (ob->u.fill.font_size > 0) cJSON_AddNumberToObject(o, "size", tidy(ob->u.fill.font_size));
        break;
    case SPDF_PAINT_OBJ_FOREIGN:
        cJSON_AddStringToObject(o, "subtype", ob->u.foreign.subtype);
        cJSON_AddNumberToObject(o, "objectNumber", ob->u.foreign.object_number);
        break;
    }
    if (ob->pdf_nm) cJSON_AddStringToObject(o, "pdfName", ob->pdf_nm);
    g_exact = 0;
    return o;
}

cJSON* spdf_paint_layer_json(const spdf_paint_doc* doc, const spdf_paint_layer* layer) {
    cJSON* o = cJSON_CreateObject();
    char name[SPDF_PAINT_NAME_MAX + 40];
    spdf_paint_layer_display_name(doc, layer, name, sizeof(name));
    cJSON_AddNumberToObject(o, "id", layer->id);
    cJSON_AddStringToObject(o, "kind", spdf_paint_layer_kind_name(layer->kind));
    cJSON_AddStringToObject(o, "name", name);
    cJSON_AddBoolToObject(o, "visible", layer->visible);
    cJSON_AddNumberToObject(o, "opacity", round(layer->opacity * 1000.0) / 10.0);
    int index = spdf_paint_layer_index(doc, layer->id);
    cJSON_AddBoolToObject(o, "locked", layer->locked || spdf_paint_layer_is_base(layer) ||
                                           (layer->object && spdf_paint_entry_locked(doc, index)));
    cJSON_AddBoolToObject(o, "active", layer->id == doc->active);
    if (layer->object) {
        spdf_paint_object_update_bounds(layer->object);
        cJSON_AddItemToObject(o, "bounds", spdf_paint_rect_json(layer->object->bounds));
        cJSON_AddItemToObject(o, "object", spdf_paint_object_json(doc, layer->object, 0));
    } else {
        cJSON_AddItemToObject(o, "bounds", spdf_paint_rect_json(spdf_paint_canvas_rect(doc)));
        cJSON_AddBoolToObject(o, "painted", layer->pixels != NULL);
    }
    return o;
}

/* ---- In ---- */

int spdf_paint_json_rect(const cJSON* item, spdf_rect* out) {
    const cJSON* x = cJSON_GetObjectItemCaseSensitive(item, "x");
    const cJSON* y = cJSON_GetObjectItemCaseSensitive(item, "y");
    const cJSON* w = cJSON_GetObjectItemCaseSensitive(item, "w");
    const cJSON* h = cJSON_GetObjectItemCaseSensitive(item, "h");
    if (!cJSON_IsNumber(x) || !cJSON_IsNumber(y) || !cJSON_IsNumber(w) || !cJSON_IsNumber(h)) return 0;
    out->x0 = (float)x->valuedouble;
    out->y0 = (float)y->valuedouble;
    out->x1 = (float)(x->valuedouble + w->valuedouble);
    out->y1 = (float)(y->valuedouble + h->valuedouble);
    return 1;
}

int spdf_paint_json_point(const cJSON* item, spdf_paint_point* out) {
    if (!cJSON_IsArray(item) || cJSON_GetArraySize(item) < 2) return 0;
    const cJSON* x = cJSON_GetArrayItem(item, 0);
    const cJSON* y = cJSON_GetArrayItem(item, 1);
    const cJSON* p = cJSON_GetArrayItem(item, 2);
    if (!cJSON_IsNumber(x) || !cJSON_IsNumber(y)) return 0;
    out->x = (float)x->valuedouble;
    out->y = (float)y->valuedouble;
    out->pressure = cJSON_IsNumber(p) ? (float)p->valuedouble : 1.0f;
    return 1;
}

int spdf_paint_json_points(fz_context* ctx, const cJSON* item, spdf_paint_point** out, int* count) {
    *out = NULL;
    *count = 0;
    int n = cJSON_IsArray(item) ? cJSON_GetArraySize(item) : 0;
    if (n <= 0) return 0;
    spdf_paint_point* points = NULL;
    fz_try(ctx) points = fz_malloc(ctx, (size_t)n * sizeof(*points));
    fz_catch(ctx) { fz_ignore_error(ctx); return 0; }
    int k = 0;
    const cJSON* p = NULL;
    cJSON_ArrayForEach(p, item) if (spdf_paint_json_point(p, &points[k])) k++;
    if (!k) { fz_free(ctx, points); return 0; }
    *out = points;
    *count = k;
    return 1;
}

int spdf_paint_json_color(const cJSON* item, spdf_paint_color* out) {
    return cJSON_IsString(item) && spdf_paint_parse_color(item->valuestring, out);
}

static int json_bool(const cJSON* item, int* out) {
    if (!cJSON_IsBool(item)) return 0;
    *out = cJSON_IsTrue(item);
    return 1;
}

static void set_string(fz_context* ctx, char** field, const cJSON* item) {
    if (!cJSON_IsString(item)) return;
    fz_free(ctx, *field);
    *field = NULL;
    fz_try(ctx) *field = fz_strdup(ctx, item->valuestring);
    fz_catch(ctx) fz_ignore_error(ctx);
}

static int is_line(const spdf_paint_object* o) { return o->kind == SPDF_PAINT_OBJ_PEN || o->kind == SPDF_PAINT_OBJ_ARROW; }

static spdf_paint_status apply_style(spdf_paint_doc* doc, const cJSON* item, spdf_paint_style* style,
                                     spdf_paint_color* color, float* width, spdf_paint_color fallback) {
    spdf_paint_style was = *style;
    const cJSON* s = cJSON_GetObjectItemCaseSensitive(item, "style");
    if (s && !spdf_paint_style_from_name(cJSON_GetStringValue(s), style)) return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    if (was == SPDF_PAINT_STYLE_NONE && *style != SPDF_PAINT_STYLE_NONE && !*color) *color = fallback;
    spdf_paint_json_color(cJSON_GetObjectItemCaseSensitive(item, "color"), color);
    const cJSON* w = cJSON_GetObjectItemCaseSensitive(item, "width");
    if (width && cJSON_IsNumber(w)) *width = (float)w->valuedouble;
    SPDF_PAINT_UNUSED(doc);
    return SPDF_PAINT_OK;
}

static spdf_paint_status apply_one(spdf_paint_doc* doc, spdf_paint_object* o, const cJSON* item) {
    fz_context* ctx = doc->ctx;
    const char* key = item->string;
    spdf_paint_object_kind k = o->kind;
    int text = k == SPDF_PAINT_OBJ_TEXT, shape = k == SPDF_PAINT_OBJ_SHAPE;
    int fill = k >= SPDF_PAINT_OBJ_FILL_TEXT && k <= SPDF_PAINT_OBJ_FILL_SIGNATURE;
    spdf_paint_point pt;
    spdf_rect rect;
    double num = cJSON_IsNumber(item) ? item->valuedouble : 0;
    if (!strcmp(key, "rect") && spdf_paint_json_rect(item, &rect)) {
        spdf_rect from = o->place.rect;
        spdf_paint_point* pts = is_line(o) ? o->u.line.points : shape ? o->u.shape.points : NULL;
        int n = is_line(o) ? o->u.line.point_count : shape ? o->u.shape.point_count : 0;
        float fw = from.x1 - from.x0, fh = from.y1 - from.y0;
        if (shape) spdf_paint_shape_fit(&o->u.shape, from, rect); /* points and a callout's tail */
        else
            for (int i = 0; i < n; i++) {
                pts[i].x = fw > 1e-4f ? rect.x0 + (pts[i].x - from.x0) * (rect.x1 - rect.x0) / fw : pts[i].x + rect.x0 - from.x0;
                pts[i].y = fh > 1e-4f ? rect.y0 + (pts[i].y - from.y0) * (rect.y1 - rect.y0) / fh : pts[i].y + rect.y0 - from.y0;
            }
        o->place.rect = rect;
    } else if (!strcmp(key, "rotation") && cJSON_IsNumber(item)) {
        if (!is_line(o)) o->place.rotation = (float)num;
        else if (num != 0) { /* lines keep turns in their points: turned by num about their box */
            spdf_rect b = spdf_paint_points_box(o->u.line.points, o->u.line.point_count);
            float cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2;
            fz_matrix m = fz_concat(fz_concat(fz_translate(-cx, -cy), fz_rotate((float)num)), fz_translate(cx, cy));
            for (int i = 0; i < o->u.line.point_count; i++) {
                fz_point q = fz_transform_point_xy(o->u.line.points[i].x, o->u.line.points[i].y, m);
                o->u.line.points[i].x = q.x;
                o->u.line.points[i].y = q.y;
            }
        }
    } else if (!strcmp(key, "flipHorizontal")) json_bool(item, &o->place.flip_h);
    else if (!strcmp(key, "flipVertical")) json_bool(item, &o->place.flip_v);
    else if (!strcmp(key, "shape") && shape) {
        spdf_paint_shape s = spdf_paint_shape_from_name(cJSON_GetStringValue(item));
        if (s == SPDF_PAINT_SHAPE_COUNT) return SPDF_PAINT_ERR_INVALID_ARGUMENT;
        o->u.shape.shape = s;
    } else if (!strcmp(key, "shapeIndex") && shape && num >= 0 && num < SPDF_PAINT_SHAPE_COUNT)
        o->u.shape.shape = (spdf_paint_shape)(int)num;
    else if (!strcmp(key, "points") && (shape || k == SPDF_PAINT_OBJ_PEN)) {
        spdf_paint_point* pts = NULL;
        int n = 0;
        if (!spdf_paint_json_points(ctx, item, &pts, &n)) return SPDF_PAINT_ERR_INVALID_ARGUMENT;
        spdf_paint_point** field = shape ? &o->u.shape.points : &o->u.line.points;
        fz_free(ctx, *field);
        *field = pts;
        if (shape) o->u.shape.point_count = n; else o->u.line.point_count = n;
    } else if ((!strcmp(key, "tail") || !strcmp(key, "tip")) && (shape || k == SPDF_PAINT_OBJ_ARROW) &&
               spdf_paint_json_point(item, &pt)) {
        if (k == SPDF_PAINT_OBJ_ARROW && o->u.line.point_count < 2) { /* a project being read: tail first */
            spdf_paint_point ends[2] = {pt, pt};
            fz_free(ctx, o->u.line.points);
            o->u.line.points = spdf_paint_points_copy(ctx, ends, 2);
            o->u.line.point_count = o->u.line.points ? 2 : 0;
        }
        if (shape && !strcmp(key, "tail")) o->u.shape.tail = pt;
        else if (k == SPDF_PAINT_OBJ_ARROW && o->u.line.point_count >= 2)
            o->u.line.points[key[1] == 'a' ? 0 : o->u.line.point_count - 1] = pt;
        else return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    } else if (!strcmp(key, "outline") && shape)
        return apply_style(doc, item, &o->u.shape.outline.style, &o->u.shape.outline.color, &o->u.shape.outline.width,
                           doc->color1);
    else if (!strcmp(key, "fill") && shape)
        return apply_style(doc, item, &o->u.shape.fill.style, &o->u.shape.fill.color, NULL, doc->color2);
    else if (!strcmp(key, "text") && (text || fill)) set_string(ctx, text ? &o->u.text.utf8 : &o->u.fill.text, item);
    else if (!strcmp(key, "font") && text) {
        set_string(ctx, &o->u.text.font, item);
        fz_free(ctx, o->u.text.resolved_font);
        o->u.text.resolved_font = NULL;
    } else if (!strcmp(key, "resolvedFont") && text) set_string(ctx, &o->u.text.resolved_font, item);
    else if (!strcmp(key, "size") && (text || fill) && cJSON_IsNumber(item)) {
        if (text) o->u.text.size = (float)num; else o->u.fill.font_size = (float)num;
    } else if (!strcmp(key, "bold") && text) json_bool(item, &o->u.text.bold);
    else if (!strcmp(key, "italic") && text) json_bool(item, &o->u.text.italic);
    else if (!strcmp(key, "underline") && text) json_bool(item, &o->u.text.underline);
    else if (!strcmp(key, "strikethrough") && text) json_bool(item, &o->u.text.strikethrough);
    else if (!strcmp(key, "grows") && text) json_bool(item, &o->u.text.grows);
    else if (!strcmp(key, "align") && text) {
        for (int i = 0; i < 3; i++)
            if (!strcmp(cJSON_GetStringValue(item) ? item->valuestring : "", k_aligns[i])) o->u.text.align = (spdf_paint_align)i;
    } else if (!strcmp(key, "color") && (text || is_line(o))) {
        if (!spdf_paint_json_color(item, text ? &o->u.text.color : &o->u.line.color)) return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    } else if (!strcmp(key, "background") && text) {
        if (!spdf_paint_json_color(item, &o->u.text.background)) return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    } else if (!strcmp(key, "width") && is_line(o) && cJSON_IsNumber(item)) o->u.line.width = (float)num;
    else if (!strcmp(key, "nm") && fill) set_string(ctx, &o->u.fill.nm, item);
    else if (!strcmp(key, "fillKind") && fill) o->u.fill.fill_kind = (int)num;
    else if (!strcmp(key, "pdfName")) set_string(ctx, &o->pdf_nm, item);
    else if (!strcmp(key, "subtype") && k == SPDF_PAINT_OBJ_FOREIGN && cJSON_IsString(item))
        snprintf(o->u.foreign.subtype, sizeof(o->u.foreign.subtype), "%s", item->valuestring);
    else if (!strcmp(key, "objectNumber") && k == SPDF_PAINT_OBJ_FOREIGN) o->u.foreign.object_number = (int)num;
    else if (!strcmp(key, "type") || !strcmp(key, "bounds") || !strcmp(key, "pixelWidth") || !strcmp(key, "pixelHeight"))
        return SPDF_PAINT_OK;
    else return SPDF_PAINT_ERR_NOT_IMPLEMENTED; /* not a setting of this kind */
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_object_apply_json(spdf_paint_doc* doc, spdf_paint_object* o, const cJSON* args,
                                               char* msg, size_t msg_cap) {
    const cJSON* item = NULL;
    cJSON_ArrayForEach(item, args) {
        if (!item->string || !strcmp(item->string, "op") || !strcmp(item->string, "id") ||
            !strcmp(item->string, "page"))
            continue;
        spdf_paint_status status = apply_one(doc, o, item);
        if (status == SPDF_PAINT_OK) continue;
        if (status == SPDF_PAINT_ERR_NOT_IMPLEMENTED)
            snprintf(msg, msg_cap, "This %s has no \"%s\" setting.", spdf_paint_object_kind_name(o->kind), item->string);
        else snprintf(msg, msg_cap, "\"%s\" isn't a value this object can take.", item->string);
        return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    }
    if (is_line(o)) o->place.rect = spdf_paint_points_box(o->u.line.points, o->u.line.point_count);
    spdf_paint_object_update_bounds(o);
    return SPDF_PAINT_OK;
}
