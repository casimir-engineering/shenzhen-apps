/* spdf_win_chrome_toolbar_controls.h — what a toolbar control LOOKS like.
 *
 * WHY THIS FILE EXISTS. spdf_win_chrome_toolbar.cpp reached its 500-line cap
 * again (498 of 500) with the Markdown A−/A＋ pill still to draw, and
 * tools/file-size-limits.md asks for an extracted file rather than a raised cap.
 * The seam is the one that file's own header comment already draws twice: WHERE
 * a control goes moved to spdf_win_chrome_toolbar.h when the row became
 * clickable, and the find group's drawing moved to spdf_win_chrome_find.cpp when
 * the row ran out of lines. This is the third cut along the same grain: the
 * capsule, the chevron, the plus/minus, the text field and the labelled switch
 * are what a control looks like, and next door is which controls the row has and
 * in what state.
 *
 * NOT A NEW ABSTRACTION. Every function here is the one that was in
 * spdf_win_chrome_toolbar.cpp, moved verbatim, so the pixels are unchanged --
 * which the headless compose comparison (portable/win/tests/run-tests-native.d2d.sh,
 * d2d.compose-*) is what actually proves.
 *
 * spdf_win_chrome_find.cpp carries its OWN fill_rounded/draw_pill/draw_chevron/
 * draw_field and is deliberately left alone: its pill takes an alpha, its field
 * takes a placeholder and a 5 pt radius, and unifying four near-variants is a
 * pixel risk with nothing to buy it. If a fifth caller ever appears, that is the
 * moment to reconcile them, with a byte comparison in hand.
 *
 * HEADER-ONLY AND `static`, included by spdf_win_chrome_toolbar.cpp and by
 * nothing else -- so there is one copy in one translation unit and no ODR
 * question. C++ only: these speak Direct2D, unlike spdf_win_chrome_toolbar.h,
 * which must stay compilable by a plain C test with no device.
 */
#ifndef SPDF_WIN_CHROME_TOOLBAR_CONTROLS_H
#define SPDF_WIN_CHROME_TOOLBAR_CONTROLS_H

#include "spdf_win_chrome_paint.h"

#include <math.h>

static float px(double points, float s) { return spdf_win_chrome_px(points, s); }

static void fill_rounded(ID2D1RenderTarget* target, SpdfWinChromeRect r, float radius, ID2D1Brush* fill,
                         ID2D1Brush* stroke, float stroke_w) {
    D2D1_ROUNDED_RECT rr;
    if (spdf_win_chrome_rect_empty(r)) return;
    rr.rect = stroke ? spdf_win_chrome_stroke_rect(r, stroke_w) : spdf_win_chrome_d2d_rect(r);
    rr.radiusX = radius;
    rr.radiusY = radius;
    if (fill) target->FillRoundedRectangle(rr, fill);
    if (stroke) target->DrawRoundedRectangle(rr, stroke, stroke_w, NULL);
}

/* A capsule of `segments` equal cells with hairline dividers between them. One
 * function for both the paired and the single form, which is the whole point of
 * macOS routing both through spdf_toolbar_segments().
 *
 * `alpha` is 1.0 for a live control and SPDF_WIN_CHROME_DISABLED_ALPHA for one
 * the row has greyed out. A DEFAULT ARGUMENT rather than a second function,
 * because every one of the eight existing call sites means "live" and having to
 * restate that eight times is how one of them would come to say something else
 * by accident. spdf_win_chrome_find.cpp's own copy of this helper has taken an
 * alpha since the find pill needed to dim itself with nothing to step through;
 * this is the same number, now named (spdf_win_chrome_empty.h). */
static void draw_pill(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, int segments, float alpha = 1.0f) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
    ID2D1SolidColorBrush* fill;
    ID2D1SolidColorBrush* stroke;
    int i;

    /* An absent control is one the layout left empty -- the find group in a
     * narrow window, or the Markdown pill on a PDF tab. Every drawing helper
     * here bails on it, so the painter can walk the whole table unconditionally
     * instead of repeating the test. */
    if (spdf_win_chrome_rect_empty(r)) return;
    fill = spdf_win_chrome_brush(ctx.target, th->control_fill);
    stroke = spdf_win_chrome_brush(ctx.target, th->control_stroke);
    if (fill) fill->SetOpacity(alpha);
    if (stroke) stroke->SetOpacity(alpha);

    /* Fully rounded: radius half the height makes a capsule, which is what
     * NSSegmentStyleRounded looks like at 28 pt. */
    fill_rounded(ctx.target, r, r.h * 0.5f, fill, stroke, hair);

    if (stroke && segments > 1) {
        for (i = 1; i < segments; ++i) {
            float x = floorf(r.x + r.w * (float)i / (float)segments) + 0.5f * hair;
            ctx.target->DrawLine(D2D1::Point2F(x, r.y + hair), D2D1::Point2F(x, r.y + r.h - hair), stroke, hair, NULL);
        }
    }
    if (fill) fill->Release();
    if (stroke) stroke->Release();
}

/* Chevron, minus, plus and the letter-ish marks are drawn as strokes so they
 * stay crisp at any DPI and need no icon font. */
static void draw_chevron(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect cell, int pointing_left,
                         ID2D1Brush* brush) {
    float s = ctx.dpi_scale;
    float cx = cell.x + cell.w * 0.5f;
    float cy = cell.y + cell.h * 0.5f;
    float a = px(3.5, s);
    float lw = spdf_win_chrome_stroke_px(1.5f, s);
    float dir = pointing_left ? -1.0f : 1.0f;
    if (!brush || spdf_win_chrome_rect_empty(cell)) return;
    ctx.target->DrawLine(D2D1::Point2F(cx - dir * a * 0.5f, cy - a), D2D1::Point2F(cx + dir * a * 0.5f, cy), brush, lw,
                         NULL);
    ctx.target->DrawLine(D2D1::Point2F(cx + dir * a * 0.5f, cy), D2D1::Point2F(cx - dir * a * 0.5f, cy + a), brush, lw,
                         NULL);
}

static void draw_plus_minus(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect cell, int plus, ID2D1Brush* brush) {
    float s = ctx.dpi_scale;
    float cx = cell.x + cell.w * 0.5f;
    float cy = cell.y + cell.h * 0.5f;
    float a = px(5.0, s);
    float lw = spdf_win_chrome_stroke_px(1.5f, s);
    if (!brush || spdf_win_chrome_rect_empty(cell)) return;
    ctx.target->DrawLine(D2D1::Point2F(cx - a, cy), D2D1::Point2F(cx + a, cy), brush, lw, NULL);
    if (plus) ctx.target->DrawLine(D2D1::Point2F(cx, cy - a), D2D1::Point2F(cx, cy + a), brush, lw, NULL);
}

/* A text field: rounded, filled, hairline outline, with a Windows 11-ish
 * 4 pt corner rather than a capsule, so it reads as editable. */
static void draw_field(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, const wchar_t* text, int placeholder,
                       DWRITE_TEXT_ALIGNMENT align, int focused, int enabled = 1) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
    ID2D1SolidColorBrush* fill;
    ID2D1SolidColorBrush* stroke;
    SpdfWinChromeRect text_rect = r;

    if (spdf_win_chrome_rect_empty(r)) return;
    fill = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(th->field_fill, enabled));
    /* THE FOCUS RING, and it is the accent colour rather than a second border:
     * a field the keyboard is talking to has to be distinguishable from the one
     * next to it, and there is no caret to say so (spdf_win_chrome_text.h
     * explains why there is none). A DOUBLED hairline, so the ring reads at 100%
     * as well as at 200%. */
    stroke = spdf_win_chrome_brush(ctx.target,
                                   spdf_win_chrome_dim(focused ? th->accent : th->field_stroke, enabled));

    fill_rounded(ctx.target, r, px(4.0, s), fill, stroke, focused ? hair * 2.0f : hair);
    if (fill) fill->Release();
    if (stroke) stroke->Release();

    text_rect.x += px(6.0, s);
    text_rect.w -= px(12.0, s);
    spdf_win_chrome_draw_text(ctx, text, text_rect,
                              spdf_win_chrome_dim(placeholder ? th->field_placeholder : th->label, enabled),
                              px(SPDF_WIN_CT_FONT_SIZE_FIELD, s), DWRITE_FONT_WEIGHT_NORMAL, align, 0);
}

/* The "Side Panel" / "Map" toggles. macOS custom-draws these
 * (SPDFToolbarToggleButton, SPDFMacUIHelpers.mm:144-246), so its numbers
 * transfer directly: intrinsic width titleWidth + 50.0, height 28.0, title at
 * systemFontOfSize:12 Light, switch track 32.0 x 18.0 anchored 5 pt from maxX,
 * fully rounded, knob 14.0 inset 2 pt. */
static void draw_toggle(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, const wchar_t* title, int on,
                        int enabled = 1) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
    SpdfWinChromeRect track, knob, label;

    if (spdf_win_chrome_rect_empty(r)) return;
    track.w = px(32.0, s);
    track.h = px(18.0, s);
    track.x = r.x + r.w - px(5.0, s) - track.w;
    track.y = r.y + (r.h - track.h) * 0.5f;

    label = r;
    label.w = track.x - r.x - px(4.0, s);
    spdf_win_chrome_draw_text(ctx, title, label, spdf_win_chrome_dim(th->label, enabled),
                              px(SPDF_WIN_CT_FONT_SIZE_LABEL, s), DWRITE_FONT_WEIGHT_NORMAL,
                              DWRITE_TEXT_ALIGNMENT_LEADING, 0);

    {
        /* THE TRACK IS WHERE A DISABLED SWITCH HAS TO BE BELIEVED. An accent
         * track reads as "on and ready" from across a room, which is exactly
         * what the empty window's Map switch was saying while nothing could
         * change it -- the single most misleading pixel in the whole defect.
         * Dimmed, the switch still tells the reader which way it is set. */
        ID2D1SolidColorBrush* tf = spdf_win_chrome_brush(
            ctx.target, spdf_win_chrome_dim(on ? th->accent : th->control_fill_pressed, enabled));
        ID2D1SolidColorBrush* ts = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(th->control_stroke, enabled));
        fill_rounded(ctx.target, track, track.h * 0.5f, tf, ts, hair);
        if (tf) tf->Release();
        if (ts) ts->Release();
    }

    knob.w = px(14.0, s);
    knob.h = knob.w;
    knob.y = track.y + (track.h - knob.h) * 0.5f;
    knob.x = on ? (track.x + track.w - knob.w - px(2.0, s)) : (track.x + px(2.0, s));
    {
        /* macOS: fill calibratedWhite:0.14 when on, white @0.96 when off -- a
         * DARK knob on a light track, which is the opposite of the Windows
         * convention. Windows' own switch keeps the knob light on an accent
         * track, so that is what is used here; the toggle's meaning is carried
         * by the track colour either way. */
        SpdfWinChromeColor c = on ? spdf_win_ct_rgb(0xFFFFFFu, 1.0f) : ctx.theme->label_secondary;
        ID2D1SolidColorBrush* kb = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(c, enabled));
        D2D1_ELLIPSE e;
        e.point.x = knob.x + knob.w * 0.5f;
        e.point.y = knob.y + knob.h * 0.5f;
        e.radiusX = knob.w * 0.5f;
        e.radiusY = knob.h * 0.5f;
        if (kb) {
            ctx.target->FillEllipse(e, kb);
            kb->Release();
        }
    }
}

#endif /* SPDF_WIN_CHROME_TOOLBAR_CONTROLS_H */
