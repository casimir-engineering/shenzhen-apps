/* Annotate's shapes (docs/plans/annotate.md § 2 Shapes, § 8 Core spdf_paint_shapes.c): the 24 shapes of Paint and the
 * arrow line as fz_paths, in Paint's order; their names, bounds and hit tests, and the placement matrix every object
 * uses. Drawing (solid and textured outline and fill styles) and the shape.add handler are in spdf_paint_shapes_draw.c.
 *
 * A shape is built in its own frame: the placement rect with its top-left corner at the origin, before rotation and
 * flips. Its points (line, arrow line, curve, polygon) and a callout's tail are kept in canvas units; the frame matrix
 * (spdf_paint_shape_frame) puts the shape back on the canvas. Textures are sampled in that frame, so a textured shape
 * keeps its texture when it is moved, rotated or flipped. */
#include "spdf_paint_brush_engine.h"
#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <string.h>

static const char* const k_names[SPDF_PAINT_SHAPE_COUNT] = {
    "line", "curve", "oval", "rectangle", "rounded_rectangle", "polygon", "triangle", "right_triangle", "diamond",
    "pentagon", "hexagon", "right_arrow", "left_arrow", "up_arrow", "down_arrow", "star4", "star5", "star6",
    "rounded_callout", "oval_callout", "cloud_callout", "heart", "lightning", "arrow_line"};

#define KAPPA 0.5522848f
#define PI_F 3.14159265f

spdf_paint_shape spdf_paint_shape_from_name(const char* name) {
    int i;
    for (i = 0; name && i < SPDF_PAINT_SHAPE_COUNT; ++i)
        if (!strcmp(name, k_names[i])) return (spdf_paint_shape)i;
    return SPDF_PAINT_SHAPE_COUNT;
}

const char* spdf_paint_shape_name(spdf_paint_shape shape) {
    return shape >= 0 && shape < SPDF_PAINT_SHAPE_COUNT ? k_names[shape] : NULL;
}

int spdf_paint_shape_is_open(spdf_paint_shape shape) {
    return shape == SPDF_PAINT_SHAPE_LINE || shape == SPDF_PAINT_SHAPE_CURVE || shape == SPDF_PAINT_SHAPE_ARROW_LINE;
}

int spdf_paint_shape_uses_points(spdf_paint_shape shape) {
    return spdf_paint_shape_is_open(shape) || shape == SPDF_PAINT_SHAPE_POLYGON;
}

int spdf_paint_shape_is_callout(spdf_paint_shape shape) {
    return shape == SPDF_PAINT_SHAPE_ROUNDED_CALLOUT || shape == SPDF_PAINT_SHAPE_OVAL_CALLOUT ||
           shape == SPDF_PAINT_SHAPE_CLOUD_CALLOUT;
}

fz_matrix spdf_paint_place_matrix(const spdf_paint_placement* place) {
    float cx = (place->rect.x0 + place->rect.x1) / 2, cy = (place->rect.y0 + place->rect.y1) / 2;
    fz_matrix m = fz_translate(-cx, -cy);
    m = fz_concat(m, fz_scale(place->flip_h ? -1.0f : 1.0f, place->flip_v ? -1.0f : 1.0f));
    m = fz_concat(m, fz_rotate(place->rotation));
    return fz_concat(m, fz_translate(cx, cy));
}

fz_matrix spdf_paint_shape_frame(const spdf_paint_placement* place) {
    return fz_concat(fz_translate(place->rect.x0, place->rect.y0), spdf_paint_place_matrix(place));
}

/* ---- Path pieces, in the frame (origin at the rect's top-left) ---- */

typedef struct builder {
    fz_context* ctx;
    fz_path* path;
    float w, h, ox, oy; /* frame size; the rect's canvas origin, taken off canvas-unit points */
} builder;

static void move_to(builder* b, float x, float y) { fz_moveto(b->ctx, b->path, x, y); }
static void line_to(builder* b, float x, float y) { fz_lineto(b->ctx, b->path, x, y); }
static void curve_to(builder* b, float x1, float y1, float x2, float y2, float x3, float y3) {
    fz_curveto(b->ctx, b->path, x1, y1, x2, y2, x3, y3);
}
static void close_path(builder* b) { fz_closepath(b->ctx, b->path); }

/* Unit coordinates (0-1 across the frame) as a closed polygon. */
static void unit_polygon(builder* b, const float* xy, int n) {
    int i;
    move_to(b, xy[0] * b->w, xy[1] * b->h);
    for (i = 1; i < n; ++i) line_to(b, xy[2 * i] * b->w, xy[2 * i + 1] * b->h);
    close_path(b);
}

/* Points of a regular polygon or star on the unit circle, stretched so their bounds fill the frame. */
static void fitted_polygon(builder* b, int corners, float inner, float start_deg) {
    float xy[24], x0 = 1e9f, y0 = 1e9f, x1 = -1e9f, y1 = -1e9f;
    int n = inner > 0 ? corners * 2 : corners, i;
    for (i = 0; i < n; ++i) {
        float a = (start_deg + 360.0f * i / n) * PI_F / 180.0f, r = inner > 0 && i % 2 ? inner : 1.0f;
        xy[2 * i] = r * cosf(a), xy[2 * i + 1] = r * sinf(a);
        x0 = fminf(x0, xy[2 * i]), x1 = fmaxf(x1, xy[2 * i]), y0 = fminf(y0, xy[2 * i + 1]), y1 = fmaxf(y1, xy[2 * i + 1]);
    }
    for (i = 0; i < n; ++i) xy[2 * i] = (xy[2 * i] - x0) / (x1 - x0), xy[2 * i + 1] = (xy[2 * i + 1] - y0) / (y1 - y0);
    unit_polygon(b, xy, n);
}

/* An elliptical arc from angle a0 to a1 (radians, y down: increasing turns clockwise on screen), in pieces of at most
 * a quarter turn; starts with a line (or a move) to its first point. */
static void arc(builder* b, float cx, float cy, float rx, float ry, float a0, float a1, int move) {
    int pieces = (int)ceilf(fabsf(a1 - a0) / (PI_F / 2) - 1e-4f), i;
    float step, k;
    if (pieces < 1) pieces = 1;
    step = (a1 - a0) / pieces, k = 4.0f / 3.0f * tanf(step / 4);
    if (move) move_to(b, cx + rx * cosf(a0), cy + ry * sinf(a0));
    else line_to(b, cx + rx * cosf(a0), cy + ry * sinf(a0));
    for (i = 0; i < pieces; ++i) {
        float s = a0 + step * i, e = s + step;
        curve_to(b, cx + rx * (cosf(s) - k * sinf(s)), cy + ry * (sinf(s) + k * cosf(s)),
                 cx + rx * (cosf(e) + k * sinf(e)), cy + ry * (sinf(e) - k * cosf(e)), cx + rx * cosf(e),
                 cy + ry * sinf(e));
    }
}

static void ellipse(builder* b, float cx, float cy, float rx, float ry) {
    arc(b, cx, cy, rx, ry, 0, 2 * PI_F, 1);
    close_path(b);
}

/* The callout's tail in the frame, and whether it lies outside the body (only then is there a tail). */
static int tail_outside(const builder* b, const spdf_paint_shape_params* s, float* tx, float* ty) {
    *tx = s->tail.x - b->ox, *ty = s->tail.y - b->oy;
    return *tx < -0.5f || *ty < -0.5f || *tx > b->w + 0.5f || *ty > b->h + 0.5f;
}

/* A rounded rectangle; with a tail, the wedge is let into the edge the tail points away from. */
static void rounded_rect(builder* b, float r, int with_tail, float tx, float ty) {
    float w = b->w, h = b->h, k = r * (1 - KAPPA), nx = (tx - w / 2) / (w / 2), ny = (ty - h / 2) / (h / 2);
    int edge = !with_tail ? -1 : fabsf(nx) > fabsf(ny) ? (nx > 0 ? 1 : 3) : (ny > 0 ? 2 : 0); /* top right bottom left */
    float len = edge == 0 || edge == 2 ? w : h, bw = fminf(len * 0.2f, fmaxf(len - 2 * r - 2, 1)), along, lo, hi;
    if (r > w / 2) r = w / 2, k = r * (1 - KAPPA);
    if (r > h / 2) r = h / 2, k = r * (1 - KAPPA);
    lo = r + bw / 2, hi = len - r - bw / 2;
    along = edge == 0 || edge == 2 ? (w / 2 + (tx - w / 2) * 0.5f) : (h / 2 + (ty - h / 2) * 0.5f);
    along = hi > lo ? fminf(fmaxf(along, lo), hi) : len / 2;
    move_to(b, r, 0);
    if (edge == 0) line_to(b, along - bw / 2, 0), line_to(b, tx, ty), line_to(b, along + bw / 2, 0);
    line_to(b, w - r, 0), curve_to(b, w - k, 0, w, k, w, r);
    if (edge == 1) line_to(b, w, along - bw / 2), line_to(b, tx, ty), line_to(b, w, along + bw / 2);
    line_to(b, w, h - r), curve_to(b, w, h - k, w - k, h, w - r, h);
    if (edge == 2) line_to(b, along + bw / 2, h), line_to(b, tx, ty), line_to(b, along - bw / 2, h);
    line_to(b, r, h), curve_to(b, k, h, 0, h - k, 0, h - r);
    if (edge == 3) line_to(b, 0, along + bw / 2), line_to(b, tx, ty), line_to(b, 0, along - bw / 2);
    line_to(b, 0, r), curve_to(b, 0, k, k, 0, r, 0);
    close_path(b);
}

static void oval_callout(builder* b, int with_tail, float tx, float ty) {
    float cx = b->w / 2, cy = b->h / 2, rx = b->w / 2, ry = b->h / 2, a, d = 0.21f;
    if (!with_tail) {
        ellipse(b, cx, cy, rx, ry);
        return;
    }
    a = atan2f((ty - cy) / ry, (tx - cx) / rx);
    arc(b, cx, cy, rx, ry, a + d, a - d + 2 * PI_F, 1);
    line_to(b, tx, ty);
    close_path(b);
}

static void cloud_callout(builder* b, int with_tail, float tx, float ty) {
    /* Bumps on an ellipse (a fixed, slightly irregular pattern), stretched to the frame; then thought bubbles. */
    static const float jitter[11] = {0.00f, 0.05f, -0.04f, 0.03f, -0.02f, 0.06f, -0.05f, 0.02f, 0.04f, -0.03f, 0.01f};
    enum { N = 11 };
    float qx[N + 1], qy[N + 1], c1x[N], c1y[N], c2x[N], c2y[N], x0 = 1e9f, y0 = 1e9f, x1 = -1e9f, y1 = -1e9f, sx, sy;
    int i;
    for (i = 0; i <= N; ++i) {
        float a = -PI_F / 2 + 2 * PI_F * ((i % N) + jitter[i % N]) / N;
        qx[i] = cosf(a), qy[i] = 0.86f * sinf(a);
    }
    for (i = 0; i < N; ++i) {
        float dx = qx[i + 1] - qx[i], dy = qy[i + 1] - qy[i], len = hypotf(dx, dy), nx = dy / len, ny = -dx / len;
        float hgt = len * 0.62f * 4.0f / 3.0f;
        c1x[i] = qx[i] + nx * hgt - dx * 0.18f, c1y[i] = qy[i] + ny * hgt - dy * 0.18f;
        c2x[i] = qx[i + 1] + nx * hgt + dx * 0.18f, c2y[i] = qy[i + 1] + ny * hgt + dy * 0.18f;
        x0 = fminf(x0, fminf(c1x[i], c2x[i])), x1 = fmaxf(x1, fmaxf(c1x[i], c2x[i]));
        y0 = fminf(y0, fminf(c1y[i], c2y[i])), y1 = fmaxf(y1, fmaxf(c1y[i], c2y[i]));
    }
    /* the curve reaches about 3/4 of the way to its control points */
    x0 *= 0.80f, x1 *= 0.80f, y0 *= 0.80f, y1 *= 0.80f;
    sx = b->w / (x1 - x0), sy = b->h / (y1 - y0);
#define CX(v) (((v) - x0) * sx)
#define CY(v) (((v) - y0) * sy)
    move_to(b, CX(qx[0]), CY(qy[0]));
    for (i = 0; i < N; ++i) curve_to(b, CX(c1x[i]), CY(c1y[i]), CX(c2x[i]), CY(c2y[i]), CX(qx[i + 1]), CY(qy[i + 1]));
    close_path(b);
    if (with_tail) { /* three bubbles from the cloud's edge to the tail tip, smaller each time */
        float cx = CX(0), cy = CY(0), dx = tx - cx, dy = ty - cy, d = hypotf(dx, dy), m = fminf(b->w, b->h);
        float ux = dx / d, uy = dy / d, ex = fabsf(ux) * b->w * 0.42f, ey = fabsf(uy) * b->h * 0.42f;
        float edge = hypotf(ex, ey), r[3] = {fmaxf(m * 0.085f, 1.5f), fmaxf(m * 0.06f, 1.2f), fmaxf(m * 0.04f, 1)};
        float t[3] = {0.25f, 0.6f, 1.0f};
        for (i = 0; i < 3 && d > edge; ++i) {
            float at = edge + (d - edge) * t[i] - (i == 2 ? r[2] : 0);
            ellipse(b, cx + ux * at, cy + uy * at, r[i] * 1.25f, r[i]);
        }
    }
#undef CX
#undef CY
}

static void heart(builder* b) {
    float w = b->w, h = b->h;
    move_to(b, 0.5f * w, 0.26f * h);
    curve_to(b, 0.44f * w, 0.06f * h, 0.24f * w, 0.0f * h, 0.12f * w, 0.04f * h);
    curve_to(b, -0.02f * w, 0.09f * h, -0.04f * w, 0.34f * h, 0.07f * w, 0.52f * h);
    curve_to(b, 0.18f * w, 0.70f * h, 0.38f * w, 0.84f * h, 0.5f * w, 1.0f * h);
    curve_to(b, 0.62f * w, 0.84f * h, 0.82f * w, 0.70f * h, 0.93f * w, 0.52f * h);
    curve_to(b, 1.04f * w, 0.34f * h, 1.02f * w, 0.09f * h, 0.88f * w, 0.04f * h);
    curve_to(b, 0.76f * w, 0.0f * h, 0.56f * w, 0.06f * h, 0.5f * w, 0.26f * h);
    close_path(b);
}

static void block_arrow(builder* b, int dir) { /* 0 right, 1 left, 2 up, 3 down; head half the short side long */
    int vertical = dir >= 2;
    float L = vertical ? b->h : b->w, T = vertical ? b->w : b->h, head = fminf(L, T) * 0.5f, s0 = T * 0.25f, s1 = T * 0.75f;
    float p[14] = {0, s0, L - head, s0, L - head, 0, L, T / 2, L - head, T, L - head, s1, 0, s1}; /* pointing +along */
    int i;
    for (i = 0; i < 7; ++i) {
        float a = p[2 * i], c = p[2 * i + 1], x, y;
        if (dir == 1 || dir == 2) a = L - a;
        x = vertical ? c : a, y = vertical ? a : c;
        if (i == 0) move_to(b, x, y);
        else line_to(b, x, y);
    }
    close_path(b);
}

static void lightning(builder* b) {
    static const float bolt[] = {8458, 0, 0, 3923, 7564, 8416, 4993, 9720, 12197, 13904, 9987, 14934, 21600, 21600,
                                 14768, 12911, 16558, 12016, 11030, 6840, 12831, 6120};
    float xy[22];
    int i;
    for (i = 0; i < 22; ++i) xy[i] = bolt[i] / 21600.0f;
    unit_polygon(b, xy, 11);
}

static fz_point frame_point(const builder* b, spdf_paint_point p) { return fz_make_point(p.x - b->ox, p.y - b->oy); }

static void points_path(builder* b, const spdf_paint_shape_params* s, int close) {
    int i;
    for (i = 0; i < s->point_count; ++i) {
        fz_point p = frame_point(b, s->points[i]);
        if (i == 0) move_to(b, p.x, p.y);
        else line_to(b, p.x, p.y);
    }
    if (close) close_path(b);
}

/* The ends of a line-like shape in the frame: its points, or the rect's diagonal. */
static void ends(const builder* b, const spdf_paint_shape_params* s, fz_point* a, fz_point* z) {
    if (s->point_count >= 2) *a = frame_point(b, s->points[0]), *z = frame_point(b, s->points[1]);
    else *a = fz_make_point(0, 0), *z = fz_make_point(b->w, b->h);
}

fz_path* spdf_paint_shape_local_path(fz_context* ctx, const spdf_paint_placement* place,
                                     const spdf_paint_shape_params* s) {
    builder b = {ctx, NULL, fmaxf(place->rect.x1 - place->rect.x0, 0), fmaxf(place->rect.y1 - place->rect.y0, 0),
                 place->rect.x0, place->rect.y0};
    fz_point a, z;
    float tx = 0, ty = 0;
    int tail;
    b.path = fz_new_path(ctx);
    fz_try(ctx) {
        tail = spdf_paint_shape_is_callout(s->shape) && tail_outside(&b, s, &tx, &ty);
        switch (s->shape) {
        case SPDF_PAINT_SHAPE_LINE: ends(&b, s, &a, &z), move_to(&b, a.x, a.y), line_to(&b, z.x, z.y); break;
        case SPDF_PAINT_SHAPE_ARROW_LINE: {
            spdf_fill_point head[3];
            ends(&b, s, &a, &z);
            move_to(&b, a.x, a.y), line_to(&b, z.x, z.y);
            spdf_ink_arrow_head((spdf_fill_point){a.x, a.y}, (spdf_fill_point){z.x, z.y}, s->outline.width, head);
            move_to(&b, head[0].x, head[0].y), line_to(&b, head[1].x, head[1].y), line_to(&b, head[2].x, head[2].y);
            break;
        }
        case SPDF_PAINT_SHAPE_CURVE:
            ends(&b, s, &a, &z);
            move_to(&b, a.x, a.y);
            if (s->point_count >= 3) {
                fz_point c1 = frame_point(&b, s->points[2]), c2 = s->point_count >= 4 ? frame_point(&b, s->points[3]) : c1;
                curve_to(&b, c1.x, c1.y, c2.x, c2.y, z.x, z.y);
            } else {
                line_to(&b, z.x, z.y);
            }
            break;
        case SPDF_PAINT_SHAPE_POLYGON:
            if (s->point_count >= 2) points_path(&b, s, 1);
            else move_to(&b, 0, 0), line_to(&b, b.w, 0), line_to(&b, b.w, b.h), line_to(&b, 0, b.h), close_path(&b);
            break;
        case SPDF_PAINT_SHAPE_OVAL: ellipse(&b, b.w / 2, b.h / 2, b.w / 2, b.h / 2); break;
        case SPDF_PAINT_SHAPE_RECTANGLE: fz_rectto(ctx, b.path, 0, 0, b.w, b.h); break;
        case SPDF_PAINT_SHAPE_ROUNDED_RECTANGLE: rounded_rect(&b, fminf(b.w, b.h) * 0.18f, 0, 0, 0); break;
        case SPDF_PAINT_SHAPE_TRIANGLE: { static const float t[] = {0.5f, 0, 1, 1, 0, 1}; unit_polygon(&b, t, 3); break; }
        case SPDF_PAINT_SHAPE_RIGHT_TRIANGLE: { static const float t[] = {0, 0, 1, 1, 0, 1}; unit_polygon(&b, t, 3); break; }
        case SPDF_PAINT_SHAPE_DIAMOND: {
            static const float d[] = {0.5f, 0, 1, 0.5f, 0.5f, 1, 0, 0.5f};
            unit_polygon(&b, d, 4);
            break;
        }
        case SPDF_PAINT_SHAPE_PENTAGON: fitted_polygon(&b, 5, 0, -90); break;
        case SPDF_PAINT_SHAPE_HEXAGON: fitted_polygon(&b, 6, 0, 0); break;
        case SPDF_PAINT_SHAPE_RIGHT_ARROW: block_arrow(&b, 0); break;
        case SPDF_PAINT_SHAPE_LEFT_ARROW: block_arrow(&b, 1); break;
        case SPDF_PAINT_SHAPE_UP_ARROW: block_arrow(&b, 2); break;
        case SPDF_PAINT_SHAPE_DOWN_ARROW: block_arrow(&b, 3); break;
        case SPDF_PAINT_SHAPE_STAR4: fitted_polygon(&b, 4, 0.30f, -90); break;
        case SPDF_PAINT_SHAPE_STAR5: fitted_polygon(&b, 5, 0.382f, -90); break;
        case SPDF_PAINT_SHAPE_STAR6: fitted_polygon(&b, 6, 0.577f, -90); break;
        case SPDF_PAINT_SHAPE_ROUNDED_CALLOUT: rounded_rect(&b, fminf(b.w, b.h) * 0.16f, tail, tx, ty); break;
        case SPDF_PAINT_SHAPE_OVAL_CALLOUT: oval_callout(&b, tail, tx, ty); break;
        case SPDF_PAINT_SHAPE_CLOUD_CALLOUT: cloud_callout(&b, tail, tx, ty); break;
        case SPDF_PAINT_SHAPE_HEART: heart(&b); break;
        case SPDF_PAINT_SHAPE_LIGHTNING: lightning(&b); break;
        default: break;
        }
    }
    fz_catch(ctx) {
        fz_drop_path(ctx, b.path);
        fz_rethrow(ctx);
    }
    return b.path;
}

fz_path* spdf_paint_shape_path(fz_context* ctx, const spdf_paint_placement* place,
                               const spdf_paint_shape_params* shape) {
    fz_path* path = spdf_paint_shape_local_path(ctx, place, shape);
    fz_transform_path(ctx, path, spdf_paint_shape_frame(place));
    return path;
}

/* ---- Bounds, fitting and hit tests ---- */

static void grow_to(spdf_rect* r, fz_point p) {
    r->x0 = fminf(r->x0, p.x), r->y0 = fminf(r->y0, p.y), r->x1 = fmaxf(r->x1, p.x), r->y1 = fmaxf(r->y1, p.y);
}

spdf_rect spdf_paint_shape_bounds(const spdf_paint_placement* place, const spdf_paint_shape_params* shape) {
    fz_matrix to_canvas = spdf_paint_place_matrix(place);
    spdf_rect r = {1e30f, 1e30f, -1e30f, -1e30f}, rect = place->rect;
    float w = shape->outline.style == SPDF_PAINT_STYLE_NONE ? 0 : shape->outline.width, grow;
    int i;
    if (!spdf_paint_shape_uses_points(shape->shape) || shape->point_count < 2) {
        grow_to(&r, fz_transform_point(fz_make_point(rect.x0, rect.y0), to_canvas));
        grow_to(&r, fz_transform_point(fz_make_point(rect.x1, rect.y0), to_canvas));
        grow_to(&r, fz_transform_point(fz_make_point(rect.x0, rect.y1), to_canvas));
        grow_to(&r, fz_transform_point(fz_make_point(rect.x1, rect.y1), to_canvas));
    }
    for (i = 0; i < shape->point_count; ++i)
        grow_to(&r, fz_transform_point(fz_make_point(shape->points[i].x, shape->points[i].y), to_canvas));
    if (spdf_paint_shape_is_callout(shape->shape))
        grow_to(&r, fz_transform_point(fz_make_point(shape->tail.x, shape->tail.y), to_canvas));
    if (r.x0 > r.x1) return rect;
    /* sharp corners (stars, the bolt) mitre out; textured outlines wobble; an arrow line's head reaches 24 + w */
    grow = w * (shape->outline.style == SPDF_PAINT_STYLE_SOLID ? 2.6f : 1.4f) + 3;
    if (shape->shape == SPDF_PAINT_SHAPE_ARROW_LINE) grow += 24;
    return (spdf_rect){r.x0 - grow, r.y0 - grow, r.x1 + grow, r.y1 + grow};
}

void spdf_paint_shape_fit(spdf_paint_shape_params* shape, spdf_rect from, spdf_rect to) {
    float fw = from.x1 - from.x0, fh = from.y1 - from.y0, tw = to.x1 - to.x0, th = to.y1 - to.y0;
    int i;
#define FIT_X(v) (fw > 1e-6f ? to.x0 + ((v) - from.x0) * tw / fw : (v) + (to.x0 + to.x1 - from.x0 - from.x1) / 2)
#define FIT_Y(v) (fh > 1e-6f ? to.y0 + ((v) - from.y0) * th / fh : (v) + (to.y0 + to.y1 - from.y0 - from.y1) / 2)
    for (i = 0; i < shape->point_count; ++i)
        shape->points[i].x = FIT_X(shape->points[i].x), shape->points[i].y = FIT_Y(shape->points[i].y);
    shape->tail.x = FIT_X(shape->tail.x), shape->tail.y = FIT_Y(shape->tail.y);
#undef FIT_X
#undef FIT_Y
}

/* Coverage of one canvas point by a path (filled, or stroked `width` wide), through a 1 x 1 pixmap. */
static int path_covers(fz_context* ctx, fz_path* path, fz_matrix frame, const fz_stroke_state* stroke, fz_point p) {
    fz_pixmap* pix = NULL;
    fz_device* dev = NULL;
    float black = 1;
    int hit = 0;
    fz_var(pix), fz_var(dev);
    fz_try(ctx) {
        fz_matrix m = fz_concat(frame, fz_translate(-p.x + 0.5f, -p.y + 0.5f));
        pix = fz_new_pixmap(ctx, NULL, 1, 1, NULL, 1);
        fz_clear_pixmap(ctx, pix);
        dev = fz_new_draw_device(ctx, fz_identity, pix);
        if (stroke) fz_stroke_path(ctx, dev, path, stroke, m, fz_device_gray(ctx), &black, 1, fz_default_color_params);
        else fz_fill_path(ctx, dev, path, 0, m, fz_device_gray(ctx), &black, 1, fz_default_color_params);
        fz_close_device(ctx, dev);
        hit = pix->samples[0] >= 96;
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, pix);
    }
    fz_catch(ctx) hit = 0;
    return hit;
}

int spdf_paint_object_hit(spdf_paint_doc* doc, const spdf_paint_object* o, float x, float y, float slop) {
    fz_context* ctx = doc->ctx;
    fz_point p = {x, y}, local;
    spdf_rect r = o->place.rect;
    if (o->bounds.x1 > o->bounds.x0 &&
        (x < o->bounds.x0 - slop || y < o->bounds.y0 - slop || x > o->bounds.x1 + slop || y > o->bounds.y1 + slop))
        return 0;
    switch (o->kind) {
    case SPDF_PAINT_OBJ_SHAPE: {
        const spdf_paint_shape_params* s = &o->u.shape;
        fz_path* path = NULL;
        fz_stroke_state* st = NULL;
        int hit = 0;
        fz_var(path), fz_var(st);
        fz_try(ctx) {
            path = spdf_paint_shape_local_path(ctx, &o->place, s);
            if (!spdf_paint_shape_is_open(s->shape)) hit = path_covers(ctx, path, spdf_paint_shape_frame(&o->place), NULL, p);
            if (!hit) {
                st = fz_new_stroke_state(ctx);
                st->linewidth = (s->outline.style == SPDF_PAINT_STYLE_NONE ? 0 : s->outline.width) + 2 * slop;
                st->start_cap = st->end_cap = st->dash_cap = FZ_LINECAP_ROUND;
                st->linejoin = FZ_LINEJOIN_ROUND;
                hit = path_covers(ctx, path, spdf_paint_shape_frame(&o->place), st, p);
            }
        }
        fz_always(ctx) {
            fz_drop_stroke_state(ctx, st);
            fz_drop_path(ctx, path);
        }
        fz_catch(ctx) hit = 0;
        return hit;
    }
    case SPDF_PAINT_OBJ_PEN: case SPDF_PAINT_OBJ_ARROW: {
        int i, n = o->u.line.point_count;
        float best = 1e30f;
        for (i = 0; i < n; ++i) {
            spdf_fill_point a = {o->u.line.points[i].x, o->u.line.points[i].y};
            spdf_fill_point pair[2] = {a, i + 1 < n ? (spdf_fill_point){o->u.line.points[i + 1].x,
                                                                       o->u.line.points[i + 1].y} : a};
            best = fminf(best, spdf_ink_distance_to_polyline(pair, 2, (spdf_fill_point){x, y}));
        }
        return best <= o->u.line.width / 2 + slop;
    }
    default:
        local = fz_transform_point(p, fz_invert_matrix(spdf_paint_place_matrix(&o->place)));
        return local.x >= r.x0 && local.y >= r.y0 && local.x <= r.x1 && local.y <= r.y1;
    }
}
