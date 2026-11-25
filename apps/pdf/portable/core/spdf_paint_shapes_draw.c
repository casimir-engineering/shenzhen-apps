/* Drawing a shape (docs/plans/annotate.md § 2 Shapes): fill, then outline, into a picture of the shape that is laid
 * on the destination once at the object's opacity (so where outline and fill overlap nothing shows through twice).
 * Solid styles are MuPDF's fz_fill_path / fz_stroke_path; the textured styles run the brush engine: an outline is
 * the brush drawn along the path, a fill is the brush hatched across the shape and masked by its area, Watercolor's
 * fill is the shape's area with the wet edge and rim. Outline uses Color 1, fill Color 2, as in Paint.
 * Also the shape.add handler and the reader of its arguments (shared with object.update). */
#include "spdf_paint_brush_engine.h"
#include "spdf_paint_handlers.h"

#include <math.h>
#include <string.h>

static const char* const k_styles[] = {"none", "solid", "crayon", "marker", "oil", "natural_pencil", "watercolor"};

static spdf_paint_brush style_brush(spdf_paint_style style) {
    switch (style) {
    case SPDF_PAINT_STYLE_CRAYON: return SPDF_PAINT_BRUSH_CRAYON;
    case SPDF_PAINT_STYLE_MARKER: return SPDF_PAINT_BRUSH_MARKER;
    case SPDF_PAINT_STYLE_OIL: return SPDF_PAINT_BRUSH_OIL;
    case SPDF_PAINT_STYLE_NATURAL_PENCIL: return SPDF_PAINT_BRUSH_NATURAL_PENCIL;
    case SPDF_PAINT_STYLE_WATERCOLOR: return SPDF_PAINT_BRUSH_WATERCOLOR;
    default: return SPDF_PAINT_BRUSH_BRUSH;
    }
}

static void color_floats(spdf_paint_color c, float rgb[3]) {
    rgb[0] = ((c >> 24) & 0xFF) / 255.0f, rgb[1] = ((c >> 16) & 0xFF) / 255.0f, rgb[2] = ((c >> 8) & 0xFF) / 255.0f;
}

/* Colour through a coverage mask, over what the picture already holds. */
static void lay_color(fz_pixmap* pix, const spdf_brush_mask* m, spdf_paint_color c) {
    float r = (c >> 24) & 0xFF, g = (c >> 16) & 0xFF, b = (c >> 8) & 0xFF, ca = (c & 0xFF) / 255.0f;
    fz_irect box = fz_intersect_irect(m->box, fz_make_irect(pix->x, pix->y, pix->x + pix->w, pix->y + pix->h));
    int x, y;
    for (y = box.y0; y < box.y1; ++y)
        for (x = box.x0; x < box.x1; ++x) {
            float a = m->a[(size_t)(y - m->box.y0) * m->w + (x - m->box.x0)] / 255.0f * ca, k = 1 - a;
            unsigned char* p = pix->samples + (size_t)(y - pix->y) * pix->stride + (size_t)(x - pix->x) * 4;
            if (a <= 0) continue;
            p[0] = (unsigned char)(r * a + p[0] * k + 0.5f), p[1] = (unsigned char)(g * a + p[1] * k + 0.5f);
            p[2] = (unsigned char)(b * a + p[2] * k + 0.5f), p[3] = (unsigned char)(255 * a + p[3] * k + 0.5f);
        }
}

/* ---- The path as polylines, for brushes along an outline ---- */

typedef struct polylines {
    fz_context* ctx;
    spdf_paint_point* pts;
    int count, cap;
    int* starts;       /* index of each polyline's first point */
    int lines, lines_cap;
    fz_point first, last;
} polylines;

static void pl_add(polylines* pl, float x, float y) {
    if (pl->count == pl->cap) {
        pl->cap = pl->cap ? pl->cap * 2 : 256;
        pl->pts = fz_realloc(pl->ctx, pl->pts, (size_t)pl->cap * sizeof(spdf_paint_point));
    }
    pl->pts[pl->count++] = (spdf_paint_point){x, y, 1};
    pl->last = fz_make_point(x, y);
}

static void pl_move(fz_context* ctx, void* arg, float x, float y) {
    polylines* pl = arg;
    (void)ctx;
    if (pl->lines == pl->lines_cap) {
        pl->lines_cap = pl->lines_cap ? pl->lines_cap * 2 : 16;
        pl->starts = fz_realloc(pl->ctx, pl->starts, (size_t)(pl->lines_cap + 1) * sizeof(int));
    }
    pl->starts[pl->lines++] = pl->count;
    pl->first = fz_make_point(x, y);
    pl_add(pl, x, y);
}

static void pl_line(fz_context* ctx, void* arg, float x, float y) {
    (void)ctx;
    pl_add(arg, x, y);
}

static void pl_curve(fz_context* ctx, void* arg, float x1, float y1, float x2, float y2, float x3, float y3) {
    polylines* pl = arg;
    fz_point p0 = pl->last;
    float len = hypotf(x1 - p0.x, y1 - p0.y) + hypotf(x2 - x1, y2 - y1) + hypotf(x3 - x2, y3 - y2);
    int n = (int)fminf(fmaxf(len / 1.5f, 4), 96), i;
    (void)ctx;
    for (i = 1; i <= n; ++i) {
        float t = (float)i / n, u = 1 - t;
        pl_add(pl, u * u * u * p0.x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
               u * u * u * p0.y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3);
    }
}

static void pl_close(fz_context* ctx, void* arg) {
    polylines* pl = arg;
    (void)ctx;
    pl_add(pl, pl->first.x, pl->first.y);
}

static const fz_path_walker k_walker = {pl_move, pl_line, pl_curve, pl_close, NULL, NULL, NULL, NULL};

/* ---- Drawing ---- */

static void textured_outline(fz_context* ctx, fz_path* path, const spdf_paint_shape_params* s, uint32_t seed,
                             fz_matrix frame_to_dev, fz_pixmap* pic) {
    polylines pl;
    spdf_brush_mask m;
    int i;
    memset(&pl, 0, sizeof(pl));
    pl.ctx = ctx;
    if (!spdf_brush_mask_init(ctx, &m, fz_pixmap_bbox(ctx, pic))) return;
    fz_try(ctx) {
        fz_walk_path(ctx, path, &k_walker, &pl);
        for (i = 0; i < pl.lines; ++i) {
            spdf_brush_job job;
            int end = i + 1 < pl.lines ? pl.starts[i + 1] : pl.count;
            memset(&job, 0, sizeof(job));
            job.tool = style_brush(s->outline.style), job.points = pl.pts + pl.starts[i];
            job.count = end - pl.starts[i], job.size = s->outline.width, job.seed = seed + (uint32_t)i * 31u;
            job.to_device = frame_to_dev, job.steady = 1;
            if (job.count > 0) spdf_brush_render(ctx, &job, &m);
        }
        lay_color(pic, &m, s->outline.color);
    }
    fz_always(ctx) {
        fz_free(ctx, pl.pts), fz_free(ctx, pl.starts);
        spdf_brush_mask_drop(ctx, &m);
    }
    fz_catch(ctx) fz_rethrow(ctx);
}

static void textured_fill(fz_context* ctx, fz_path* path, const spdf_paint_placement* place,
                          const spdf_paint_shape_params* s, uint32_t seed, fz_matrix frame_to_dev, fz_pixmap* pic) {
    float w = place->rect.x1 - place->rect.x0, h = place->rect.y1 - place->rect.y0, ex = fz_matrix_expansion(frame_to_dev);
    fz_pixmap* area = NULL;
    fz_device* dev = NULL;
    spdf_brush_mask m;
    float one = 1;
    int i;
    if (!spdf_brush_mask_init(ctx, &m, fz_pixmap_bbox(ctx, pic))) return;
    fz_var(area), fz_var(dev);
    fz_try(ctx) {
        area = fz_new_pixmap_with_bbox(ctx, NULL, m.box, NULL, 1);
        fz_clear_pixmap(ctx, area);
        dev = fz_new_draw_device(ctx, fz_identity, area);
        fz_fill_path(ctx, dev, path, 0, frame_to_dev, fz_device_gray(ctx), &one, 1, fz_default_color_params);
        fz_close_device(ctx, dev);
        if (s->fill.style == SPDF_PAINT_STYLE_WATERCOLOR) {
            memcpy(m.a, area->samples, (size_t)m.w * m.h);
            spdf_brush_wet(ctx, &m, fminf(fmaxf(fminf(w, h) * 0.12f, 3), 30) * ex, fz_invert_matrix(frame_to_dev), seed);
        } else {
            float spacing = s->fill.style == SPDF_PAINT_STYLE_NATURAL_PENCIL ? 3.0f
                          : s->fill.style == SPDF_PAINT_STYLE_MARKER ? fmaxf(6, fminf(w, h) / 6) : 7.0f;
            spdf_brush_hatch(ctx, style_brush(s->fill.style), (spdf_rect){0, 0, w, h}, spacing, seed, frame_to_dev, &m);
            for (i = 0; i < m.w * m.h; ++i) m.a[i] = (unsigned char)((m.a[i] * area->samples[i] + 127) / 255);
        }
        lay_color(pic, &m, s->fill.color);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, area);
        spdf_brush_mask_drop(ctx, &m);
    }
    fz_catch(ctx) fz_rethrow(ctx);
}

/* The picture laid over dest at `opacity` (both premultiplied). */
static void lay_picture(fz_pixmap* dest, const fz_pixmap* pic, fz_irect within, float opacity) {
    fz_irect box = fz_intersect_irect(fz_make_irect(pic->x, pic->y, pic->x + pic->w, pic->y + pic->h), within);
    int x, y, c, n = dest->n;
    for (y = box.y0; y < box.y1; ++y)
        for (x = box.x0; x < box.x1; ++x) {
            const unsigned char* s = pic->samples + (size_t)(y - pic->y) * pic->stride + (size_t)(x - pic->x) * 4;
            unsigned char* d = dest->samples + (size_t)(y - dest->y) * dest->stride + (size_t)(x - dest->x) * n;
            float k;
            if (!s[3]) continue;
            k = 1 - s[3] * opacity / 255.0f;
            for (c = 0; c < 3 && c < n; ++c) d[c] = (unsigned char)fminf(255, s[c] * opacity + d[c] * k + 0.5f);
            if (dest->alpha) d[n - 1] = (unsigned char)fminf(255, s[3] * opacity + d[n - 1] * k + 0.5f);
        }
}

/* Curvy shapes meet themselves at cusps (a cloud's bumps, a heart's dip, a callout's tail on an oval), where a
 * mitre would stick out: they get round joins; straight-sided shapes keep Paint's sharp corners. */
static int rounded_joins(spdf_paint_shape s) {
    return s == SPDF_PAINT_SHAPE_ARROW_LINE || s == SPDF_PAINT_SHAPE_CURVE || s == SPDF_PAINT_SHAPE_CLOUD_CALLOUT ||
           s == SPDF_PAINT_SHAPE_HEART || s == SPDF_PAINT_SHAPE_OVAL || s == SPDF_PAINT_SHAPE_OVAL_CALLOUT;
}

static uint32_t shape_seed(const spdf_paint_shape_params* s) {
    return spdf_brush_hash((int32_t)s->shape, (int32_t)(s->outline.style * 8 + s->fill.style), 0x5a17e5u);
}

int spdf_paint_shape_draw(spdf_paint_doc* doc, const spdf_paint_placement* place, const spdf_paint_shape_params* shape,
                          fz_matrix ctm, fz_pixmap* dest, fz_irect clip, float opacity) {
    fz_context* ctx = doc->ctx;
    fz_matrix frame_to_dev = fz_concat(spdf_paint_shape_frame(place), ctm);
    spdf_rect b = spdf_paint_shape_bounds(place, shape);
    fz_irect box = fz_round_rect(fz_transform_rect(fz_make_rect(b.x0, b.y0, b.x1, b.y1), ctm));
    fz_path* path = NULL;
    fz_pixmap* pic = NULL;
    fz_device* dev = NULL;
    fz_stroke_state* st = NULL;
    int open = spdf_paint_shape_is_open(shape->shape), ok = 1;
    uint32_t seed = shape_seed(shape);
    float rgb[3];
    fz_irect shown = fz_intersect_irect(fz_intersect_irect(box, clip), fz_pixmap_bbox(ctx, dest));
    if (fz_is_empty_irect(shown) || opacity <= 0) return 1;
    if (shape->outline.style > SPDF_PAINT_STYLE_SOLID || shape->fill.style > SPDF_PAINT_STYLE_SOLID) {
        /* Textures look at their neighbours (Watercolor's blur): worked out past the edges of what is shown, so a
         * tile drawn alone matches the same place drawn whole. */
        float ex = fz_matrix_expansion(ctm), w = place->rect.x1 - place->rect.x0, h = place->rect.y1 - place->rect.y0;
        int margin = (int)ceilf((3 * shape->outline.width + 1.5f * fminf(fmaxf(fminf(w, h) * 0.12f, 3), 30)) * ex) + 8;
        box = fz_intersect_irect(box, fz_expand_irect(shown, margin));
    } else {
        box = shown;
    }
    fz_var(path), fz_var(pic), fz_var(dev), fz_var(st);
    fz_try(ctx) {
        path = spdf_paint_shape_local_path(ctx, place, shape);
        pic = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 1);
        fz_clear_pixmap(ctx, pic);
        if (!open && shape->fill.style == SPDF_PAINT_STYLE_SOLID) {
            dev = fz_new_draw_device(ctx, fz_identity, pic);
            color_floats(shape->fill.color, rgb);
            fz_fill_path(ctx, dev, path, 0, frame_to_dev, fz_device_rgb(ctx), rgb, (shape->fill.color & 0xFF) / 255.0f,
                         fz_default_color_params);
            fz_close_device(ctx, dev), fz_drop_device(ctx, dev), dev = NULL;
        } else if (!open && shape->fill.style > SPDF_PAINT_STYLE_SOLID) {
            textured_fill(ctx, path, place, shape, seed, frame_to_dev, pic);
        }
        if (shape->outline.style == SPDF_PAINT_STYLE_SOLID && shape->outline.width > 0) {
            st = fz_new_stroke_state(ctx);
            st->linewidth = shape->outline.width;
            st->start_cap = st->end_cap = st->dash_cap = open ? FZ_LINECAP_ROUND : FZ_LINECAP_BUTT;
            st->linejoin = rounded_joins(shape->shape) ? FZ_LINEJOIN_ROUND : FZ_LINEJOIN_MITER;
            st->miterlimit = 4; /* the bolt's sharpest points are bevelled rather than spiking out */
            dev = fz_new_draw_device(ctx, fz_identity, pic);
            color_floats(shape->outline.color, rgb);
            fz_stroke_path(ctx, dev, path, st, frame_to_dev, fz_device_rgb(ctx), rgb,
                           (shape->outline.color & 0xFF) / 255.0f, fz_default_color_params);
            fz_close_device(ctx, dev);
        } else if (shape->outline.style > SPDF_PAINT_STYLE_SOLID && shape->outline.width > 0) {
            textured_outline(ctx, path, shape, seed ^ 0x9e37u, frame_to_dev, pic);
        }
        lay_picture(dest, pic, shown, opacity);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_stroke_state(ctx, st);
        fz_drop_pixmap(ctx, pic);
        fz_drop_path(ctx, path);
    }
    fz_catch(ctx) ok = 0;
    return ok;
}

/* ---- shape.add ---- */

static spdf_paint_style style_from_name(const char* name, spdf_paint_style fallback) {
    int i;
    for (i = 0; name && i < (int)(sizeof(k_styles) / sizeof(k_styles[0])); ++i)
        if (!strcmp(name, k_styles[i])) return (spdf_paint_style)i;
    return fallback;
}

static int read_color(const cJSON* item, spdf_paint_color* out) {
    return item && cJSON_IsString(item) && spdf_paint_parse_color(item->valuestring, out);
}

static spdf_rect points_bounds(const spdf_paint_point* p, int n) {
    spdf_rect r = {p[0].x, p[0].y, p[0].x, p[0].y};
    int i;
    for (i = 1; i < n; ++i)
        r.x0 = fminf(r.x0, p[i].x), r.y0 = fminf(r.y0, p[i].y), r.x1 = fmaxf(r.x1, p[i].x), r.y1 = fmaxf(r.y1, p[i].y);
    return r;
}

spdf_paint_status spdf_paint_shape_read_args(spdf_paint_call* call, spdf_paint_object* object, int update) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_shape_params s = update ? object->u.shape : (spdf_paint_shape_params){0};
    spdf_paint_placement place = update ? object->place : (spdf_paint_placement){{0, 0, 0, 0}, 0, 0, 0};
    const cJSON *outline = cJSON_GetObjectItemCaseSensitive(call->args, "outline");
    const cJSON *fill = cJSON_GetObjectItemCaseSensitive(call->args, "fill"), *tail;
    const char* name = spdf_paint_arg_string(call, "shape");
    spdf_paint_point* points = NULL;
    spdf_rect rect;
    int count = 0, has_rect = spdf_paint_arg_rect(call, "rect", &rect), has_points;
    double v;
    if (name || !update) {
        s.shape = spdf_paint_shape_from_name(name);
        if (s.shape == SPDF_PAINT_SHAPE_COUNT)
            return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "There is no shape with that name.");
    }
    if (!update) {
        s.outline = (spdf_paint_stroke_style){SPDF_PAINT_STYLE_SOLID, doc->color1, 3};
        s.fill = (spdf_paint_fill_style){SPDF_PAINT_STYLE_NONE, doc->color2};
    }
    has_points = spdf_paint_arg_points(call, "points", &points, &count) && count > 0;
    if (spdf_paint_shape_uses_points(s.shape) && has_points) {
        int need = s.shape == SPDF_PAINT_SHAPE_POLYGON ? 3 : 2, most = s.shape == SPDF_PAINT_SHAPE_CURVE ? 4
                 : s.shape == SPDF_PAINT_SHAPE_POLYGON ? 4096 : 2;
        if (count < need || count > most) {
            fz_free(doc->ctx, points);
            return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT,
                                        s.shape == SPDF_PAINT_SHAPE_POLYGON ? "A polygon needs at least 3 corners."
                                        : s.shape == SPDF_PAINT_SHAPE_CURVE ? "A curve takes its 2 ends and up to 2 bends."
                                                                            : "A line takes its 2 ends.");
        }
    } else if (!has_rect && !update && !has_points) {
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Give the shape a rect or its points.");
    } else if (s.shape == SPDF_PAINT_SHAPE_POLYGON && !update && !has_points) {
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "A polygon needs at least 3 corners.");
    }
    if (spdf_paint_arg_number(call, "rotation", &v)) place.rotation = (float)fmod(v, 360.0);
    if (outline) {
        const cJSON* w = cJSON_GetObjectItemCaseSensitive(outline, "width");
        s.outline.style = style_from_name(cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(outline, "style")),
                                          update ? s.outline.style : SPDF_PAINT_STYLE_SOLID);
        read_color(cJSON_GetObjectItemCaseSensitive(outline, "color"), &s.outline.color);
        if (cJSON_IsNumber(w)) s.outline.width = (float)fmin(fmax(w->valuedouble, 1), 50);
    }
    if (fill) {
        s.fill.style = style_from_name(cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(fill, "style")),
                                       update ? s.fill.style : SPDF_PAINT_STYLE_NONE);
        read_color(cJSON_GetObjectItemCaseSensitive(fill, "color"), &s.fill.color);
    }
    /* Points and rect: a line or polygon is placed by its points; the rect then moves and scales them. */
    if (has_points && spdf_paint_shape_uses_points(s.shape)) {
        if (update && s.points != points) fz_free(doc->ctx, s.points);
        s.points = points, s.point_count = count, points = NULL;
        place.rect = points_bounds(s.points, s.point_count);
    } else if (has_rect) {
        spdf_rect to = {rect.x0, rect.y0, rect.x1, rect.y1};
        if (update) spdf_paint_shape_fit(&s, place.rect, to);
        place.rect = to;
    } else if (has_points) {
        place.rect = points_bounds(points, count);
    }
    fz_free(doc->ctx, points);
    if (!spdf_paint_shape_uses_points(s.shape) && (place.rect.x1 - place.rect.x0 < 0.5f || place.rect.y1 - place.rect.y0 < 0.5f)) {
        if (!update && s.points) fz_free(doc->ctx, s.points);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "The shape needs some width and height.");
    }
    tail = cJSON_GetObjectItemCaseSensitive(call->args, "tail");
    if (cJSON_IsArray(tail) && cJSON_GetArraySize(tail) >= 2) {
        s.tail.x = (float)cJSON_GetArrayItem(tail, 0)->valuedouble, s.tail.y = (float)cJSON_GetArrayItem(tail, 1)->valuedouble;
        s.tail.pressure = 1;
    } else if (!update || (has_rect && spdf_paint_shape_is_callout(s.shape) && s.tail.pressure == 0)) {
        /* Paint's default: the tail points down and to the left, below the box */
        float w = place.rect.x1 - place.rect.x0, h = place.rect.y1 - place.rect.y0;
        s.tail = (spdf_paint_point){place.rect.x0 + w * 0.22f, place.rect.y1 + h * 0.45f, 1};
    }
    object->u.shape = s;
    object->place = place;
    spdf_paint_object_update_bounds(object);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_shape_add(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_object scratch, *object;
    spdf_paint_id id = 0;
    spdf_paint_status st = spdf_paint_arg_check_page(call);
    if (st != SPDF_PAINT_OK) return call->message[0] ? st : spdf_paint_call_fail(call, st, "That page is not here.");
    memset(&scratch, 0, sizeof(scratch));
    scratch.kind = SPDF_PAINT_OBJ_SHAPE;
    st = spdf_paint_shape_read_args(call, &scratch, 0); /* first, so a refused shape adds no layer */
    if (st != SPDF_PAINT_OK) return st;
    object = spdf_paint_object_new(doc, SPDF_PAINT_OBJ_SHAPE, &id);
    if (!object) {
        fz_free(doc->ctx, scratch.u.shape.points);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_FAILED, "The shape couldn't be added.");
    }
    object->place = scratch.place;
    object->u.shape = scratch.u.shape;
    spdf_paint_object_update_bounds(object);
    spdf_paint_damage(doc, object->bounds);
    if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_pdf_note_change(doc, spdf_paint_layer_find(doc, id));
    cJSON_AddNumberToObject(call->reply, "id", id);
    return SPDF_PAINT_OK;
}
