#pragma once
/* Pure geometry for Fill & Sign's pen lines and arrows (docs/plans/fill-and-sign.md, "Pen and arrow"): smoothing a
 * line as it is drawn, thinning it, distances, box selection, the eraser's splitting and arrow heads. No MuPDF, so
 * every front end can use it. Page space: points, top-left origin, y down. */
#include "spdf_fill_items.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The centripetal Catmull-Rom curve from p1 to p2 (p0 and p3 are its neighbours: pass p1 for a missing p0 and p2 for a
 * missing p3), cut into straight pieces that stray less than `tolerance` from the curve and are no longer than
 * `max_step`. Writes the points after p1, ending with p2, and returns how many (at most max_out, which should be at
 * least 2). */
int spdf_ink_flatten_segment(spdf_fill_point p0, spdf_fill_point p1, spdf_fill_point p2, spdf_fill_point p3,
                             float tolerance, float max_step, spdf_fill_point* out, int max_out);

/* Douglas-Peucker in place: drops points closer than `tolerance` to the line kept around them. The first and last
 * points stay. Returns the new count. */
int spdf_ink_simplify(spdf_fill_point* points, int count, float tolerance);

float spdf_ink_distance_to_polyline(const spdf_fill_point* points, int count, spdf_fill_point p);
/* The smallest distance between two polylines; either may be a single point. */
float spdf_ink_polyline_distance(const spdf_fill_point* a, int na, const spdf_fill_point* b, int nb);

/* Bounds of a line drawn `half_width` thick. */
spdf_rect spdf_ink_bounds(const spdf_fill_point* points, int count, float half_width);
/* Whether any part of the line (drawn half_width thick) lies in rect, or all of it does. */
int spdf_ink_touches_rect(const spdf_fill_point* points, int count, float half_width, spdf_rect rect);
int spdf_ink_inside_rect(const spdf_fill_point* points, int count, float half_width, spdf_rect rect);

/* The open head of an arrow drawn `width` thick from tail to tip: out[0] the end of one barb, out[1] the tip, out[2]
 * the end of the other. Each barb is clamp(4 + 3 x width, 6, 24) long, 28 degrees off the shaft. */
void spdf_ink_arrow_head(spdf_fill_point tail, spdf_fill_point tip, float width, spdf_fill_point out[3]);

/* What is left of a line after the eraser passed along `swath`: every point of the line closer than `reach` to the
 * swath is gone. The pieces that remain are runs of points (the line's own points plus the cut points), shorter
 * pieces than min_length dropped. */
typedef struct spdf_ink_runs {
    spdf_fill_point* points; /* all runs, one after the other */
    int* run_lengths;        /* points in each run */
    int run_count;
    int touched;             /* the eraser reached the line at all */
    int last_run_keeps_end;  /* the last run still ends at the line's last point (an arrow's tip) */
} spdf_ink_runs;

int spdf_ink_erase(const spdf_fill_point* line, int count, const spdf_fill_point* swath, int swath_count, float reach,
                   float min_length, spdf_ink_runs* out);
void spdf_ink_free_runs(spdf_ink_runs* runs);

#ifdef __cplusplus
}
#endif
