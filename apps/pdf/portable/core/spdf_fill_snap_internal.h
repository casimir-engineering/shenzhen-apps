#pragma once
/* CORE-INTERNAL: what the three snap units share (spdf_fill_snap.c reads the page, spdf_fill_snap_clean.c tidies
 * what it read, spdf_fill_snap_place.c answers clicks). */
#include "spdf_fill_snap.h"

#include "mupdf/fitz.h"

/* Merges, filters and groups the raw geometry once, right after the page was read. Throws on allocation failure. */
void spdf_snap_finish_geometry(fz_context* ctx, spdf_snap_geometry* g);

static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }
static inline float rw(spdf_rect r) { return r.x1 - r.x0; }
static inline float rh(spdf_rect r) { return r.y1 - r.y0; }
static inline int inside(spdf_rect r, float x, float y, float slop) {
    return x >= r.x0 - slop && x <= r.x1 + slop && y >= r.y0 - slop && y <= r.y1 + slop;
}
static inline spdf_rect make_rect(float x0, float y0, float x1, float y1) {
    spdf_rect r;
    r.x0 = x0, r.y0 = y0, r.x1 = x1, r.y1 = y1;
    return r;
}
