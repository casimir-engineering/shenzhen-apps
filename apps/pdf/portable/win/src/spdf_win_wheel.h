#pragma once

/* spdf_win_wheel.h -- WHAT ONE WM_MOUSEWHEEL IS WORTH, in pixels and in zoom.
 *
 * The arithmetic that was inline in spdf_win_window_input.h's on_wheel(),
 * lifted out for one reason: a window procedure cannot be tested and this can
 * (portable/win/tests/wheel_input_test.c). No Win32, no app state, no
 * allocation, header-only -- the same family as spdf_win_page_wheel.h and
 * spdf_win_chrome_input.h, and the same argument for existing.
 *
 * ------------------------------------------------------------------------
 * A PRECISION TOUCHPAD DOES NOT SEND NOTCHES.
 *
 * WM_MOUSEWHEEL's delta is documented as a multiple of WHEEL_DELTA (120), and
 * for a mouse with a detented wheel it is. A Windows Precision Touchpad is not
 * that: it reports the finger's actual travel, so the deltas are small and
 * arbitrary -- 3, 8, 17, and the sign flips the instant the finger does. The
 * same is true of the inertial tail it sends after the fingers lift, and of the
 * pinch gesture, which arrives as Ctrl + wheel with those same small deltas.
 *
 * So every conversion here is FRACTIONAL and none of them rounds. A notch count
 * of 8/120 is 0.0667 of a notch and yields 0.0667 of a notch's distance; a
 * hundred and twenty deltas of 1 travel exactly as far as one delta of 120,
 * which is the property wheel_input_test.c asserts and the property that keeps
 * a slow two-finger drag from being silently discarded. Rounding a notch count
 * to an integer -- the obvious reading of the documentation -- gives zero for
 * every one of those events, and a view that never moves however long the
 * reader scrolls. That is what "the app is not responsive" looks like to
 * someone with a touchpad and no mouse.
 *
 * THE ZOOM IS GEOMETRIC for the same reason it is in on_wheel(): N notches out
 * exactly undo N notches in, and a pinch composed of forty small deltas lands
 * on the same zoom as one notch of the same total travel. Multiplication of
 * factors is what makes that true, and it is true for fractional exponents.
 *
 * ------------------------------------------------------------------------
 * UNITS. `delta` is the raw GET_WHEEL_DELTA_WPARAM value. `lines` is the user's
 * own SPI_GETWHEELSCROLLLINES, including its WHEEL_PAGESCROLL (0xFFFFFFFF)
 * spelling of "a screenful"; honouring it is the difference between a viewer
 * that feels like the rest of the desktop and one that does not. Distances come
 * back in DEVICE PIXELS, positive for a wheel turned AWAY from the reader --
 * the caller negates to get a scroll offset, exactly as on_wheel() always did.
 *
 * spdf_win_page_wheel.h states the same notch formula for Alt + wheel paging
 * and keeps its own copy so it can stay free of every include. The two are
 * pinned equal in wheel_input_test.c rather than by a shared call, so a change
 * to one that is not made to the other fails a test instead of quietly making
 * Alt + wheel page at a different rate than the wheel scrolls.
 */
#ifndef SPDF_WIN_WHEEL_H
#define SPDF_WIN_WHEEL_H

#include <math.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_WHEEL_INLINE __inline
#else
#define SPDF_WIN_WHEEL_INLINE inline
#endif

/* WHEEL_DELTA and WHEEL_PAGESCROLL, restated so this header needs no
 * <windows.h>. Both are ABI and have not moved since Win16. */
#define SPDF_WIN_WHEEL_DELTA 120
#define SPDF_WIN_WHEEL_LINES_PAGESCROLL 0xFFFFFFFFu

/* How far ONE FULL NOTCH scrolls, in device pixels. 20 logical pixels a line is
 * the port's line height, scaled by the DPI so a notch covers the same amount
 * of the page at 96 and at 144. */
static SPDF_WIN_WHEEL_INLINE float spdf_win_wheel_notch_px(unsigned lines, float dpi_scale, unsigned view_px_h) {
    if (lines == SPDF_WIN_WHEEL_LINES_PAGESCROLL) return (float)view_px_h * 0.9f;
    if (lines == 0) lines = 3; /* a zero from a broken SystemParametersInfo call */
    if (!(dpi_scale > 0.0f)) dpi_scale = 1.0f;
    return (float)lines * 20.0f * dpi_scale;
}

/* The notch count this event is worth: FRACTIONAL, never rounded. See the
 * header note -- this is the whole precision-touchpad case in one line. */
static SPDF_WIN_WHEEL_INLINE float spdf_win_wheel_notches(int delta) {
    return (float)delta / (float)SPDF_WIN_WHEEL_DELTA;
}

/* How far this event scrolls, in device pixels, positive for a wheel turned
 * away from the reader. */
static SPDF_WIN_WHEEL_INLINE float spdf_win_wheel_distance_px(int delta, unsigned lines, float dpi_scale,
                                                              unsigned view_px_h) {
    return spdf_win_wheel_notches(delta) * spdf_win_wheel_notch_px(lines, dpi_scale, view_px_h);
}

/* Ctrl + wheel, and a precision touchpad's pinch. Geometric, so N notches out
 * exactly undo N notches in and a gesture split into many small deltas lands
 * where the same travel in one delta would. */
static SPDF_WIN_WHEEL_INLINE float spdf_win_wheel_zoom_factor(int delta) {
    return powf(1.1f, spdf_win_wheel_notches(delta));
}

#endif /* SPDF_WIN_WHEEL_H */
