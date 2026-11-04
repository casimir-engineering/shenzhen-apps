#pragma once

#import <Foundation/Foundation.h>

// Where one wheel or trackpad step puts a document scroll view's origin: on a
// whole device pixel on each axis that moves.
//
// A document view redraws only the strip a scroll uncovers and moves the rest
// of its pixels along. When the origin lands between pixels, that strip stops
// partway through a pixel row, and the rest of the row keeps whatever the
// buffer held before; step after step those rows streak the background with
// faint lines. A fractional Markdown zoom lands every step there (at 82%,
// 3 points of travel is 4.9 pixels), and a trackpad's fractional deltas do the
// same to a PDF.
//
// A step continues from where the previous one aimed while the view is still
// where that step left it, so travel shorter than a pixel adds up instead of
// being rounded away each time.
typedef struct {
    CGPoint aimed;   // where the last step was headed
    CGPoint landed;  // the whole pixel it landed on
} spdf_scroll_step_state;

// The new origin for `origin` moved back by `delta` (document units, the
// scroll view's sign), kept within [lo, hi] per axis (the document's edges and
// any page lock), at `pixels` device pixels per unit. An axis that does not
// move keeps its origin, clamped. A moving axis takes the nearest whole pixel
// inside its range, or where it aimed when the range holds none.
static inline CGPoint spdf_scroll_step(spdf_scroll_step_state* state, CGPoint origin, CGPoint delta, CGPoint lo,
                                       CGPoint hi, CGFloat pixels) {
    BOOL carry = fabs(origin.x - state->landed.x) < 0.001 && fabs(origin.y - state->landed.y) < 0.001;
    CGFloat from[2] = {origin.x, origin.y}, d[2] = {delta.x, delta.y}, l[2] = {lo.x, lo.y}, h[2] = {hi.x, hi.y};
    CGFloat aim[2] = {carry ? state->aimed.x : origin.x, carry ? state->aimed.y : origin.y}, out[2];
    for (int i = 0; i < 2; i++) {
        if (fabs(d[i]) < 0.0001) {
            out[i] = aim[i] = MAX(l[i], MIN(h[i], from[i]));
            continue;
        }
        aim[i] = MAX(l[i], MIN(h[i], aim[i] - d[i]));
        CGFloat whole = MIN(MAX(round(aim[i] * pixels), ceil(l[i] * pixels - 1e-6)), floor(h[i] * pixels + 1e-6));
        out[i] = whole / pixels >= l[i] - 1e-6 && whole / pixels <= h[i] + 1e-6 ? whole / pixels : aim[i];
    }
    state->aimed = CGPointMake(aim[0], aim[1]);
    state->landed = CGPointMake(out[0], out[1]);
    return state->landed;
}
