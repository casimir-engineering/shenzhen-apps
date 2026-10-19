/* spdf_win_chrome_empty_paint.h — what the EMPTY canvas's way in looks like.
 *
 * WHY THIS FILE EXISTS. The button pushed spdf_win_chrome_paint.cpp one line
 * past its 500-line cap, and tools/file-size-limits.tsv asks for an extracted
 * file rather than a raised one. The seam is the one
 * spdf_win_chrome_toolbar_controls.h already cut, for the same reason and in the
 * same shape: WHERE and WHETHER a control appears is a pure geometry header that
 * the input router shares (spdf_win_chrome_empty.h), and what it LOOKS like is
 * Direct2D drawing that only the painter can use.
 *
 * HEADER-ONLY AND `static`, included by spdf_win_chrome_paint.cpp and by nothing
 * else, so there is one copy in one translation unit and no ODR question --
 * again spdf_win_chrome_toolbar_controls.h's arrangement, whose header comment
 * explains it at length. C++ only: this speaks Direct2D, unlike
 * spdf_win_chrome_empty.h, which must stay compilable by a plain C test with no
 * device.
 */
#ifndef SPDF_WIN_CHROME_EMPTY_PAINT_H
#define SPDF_WIN_CHROME_EMPTY_PAINT_H

#include "spdf_win_chrome_paint.h"

/* A primary button, and under it the drop hint that used to be the tail of the
 * placeholder sentence. Everything about WHERE and WHETHER is
 * spdf_win_chrome_empty.h's, called with the same layout and model the input
 * router will be handed, so the button is clickable exactly where it is drawn.
 *
 * WHY IT IS A CHROME PAINTER and not part of the canvas. The canvas region is
 * where the pages go, and with no document there is no canvas object at all
 * (spdf_win_chrome_scene.h's `if (!a->canvas)` arm skips every canvas call). The
 * chrome painters, by contrast, run from a hand-built model with no app behind
 * them -- which is what makes this button appear in the headless
 * `--render-window-png --chrome` frame and therefore pixel-testable.
 *
 * ACCENT FILL, WHITE LABEL: Windows 11's own primary button, and the one place
 * in this chrome that is allowed to be the loudest thing on screen, because on
 * this window it is the only thing there is to do. The knockout is white in both
 * appearances for the reason spdf_win_chrome_find.cpp gives for the regex tick:
 * the accent is saturated in either theme, so the colour that reads on it is the
 * same colour. */
static void spdf_win_chrome_paint_empty(const SpdfWinChromePaintCtx& ctx) {
    const SpdfWinChromeTheme* th = ctx.theme;
    SpdfWinChromeRect button = spdf_win_chrome_empty_open_rect(ctx.layout, ctx.model);
    SpdfWinChromeRect hint = spdf_win_chrome_empty_hint_rect(ctx.layout, ctx.model);
    float s = ctx.dpi_scale > 0.0f ? ctx.dpi_scale : 1.0f;
    ID2D1SolidColorBrush* fill;
    ID2D1SolidColorBrush* ring;
    D2D1_ROUNDED_RECT rr;

    if (spdf_win_chrome_rect_empty(button)) return;

    /* THE KEYBOARD'S RING, first so the fill lands on top of its inner edge. The
     * button is a Tab stop (SPDF_WIN_FOCUS_OPEN, spdf_win_chrome_text.h), and a
     * focus a reader cannot see is a focus they cannot use. Doubled hairline in
     * the LABEL colour and OUTSIDE the capsule, where it reads against the
     * gutter; the toolbar fields' ring is the accent against a quiet fill, which
     * would be invisible drawn around an accent-filled button. */
    ring = ctx.model->focus == SPDF_WIN_FOCUS_OPEN ? spdf_win_chrome_brush(ctx.target, th->label) : NULL;
    if (ring) {
        float w = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s) * 2.0f;
        float o = spdf_win_chrome_px(2.0, s);
        SpdfWinChromeRect r = button;
        r.x -= o;
        r.y -= o;
        r.w += 2.0f * o;
        r.h += 2.0f * o;
        rr.rect = spdf_win_chrome_stroke_rect(r, w);
        rr.radiusX = r.h * 0.5f;
        rr.radiusY = rr.radiusX;
        ctx.target->DrawRoundedRectangle(rr, ring, w, NULL);
        ring->Release();
    }

    fill = spdf_win_chrome_brush(ctx.target, th->accent);
    if (fill) {
        rr.rect = spdf_win_chrome_d2d_rect(button);
        rr.radiusX = button.h * 0.5f;
        rr.radiusY = rr.radiusX;
        ctx.target->FillRoundedRectangle(rr, fill);
        fill->Release();
    }
    spdf_win_chrome_draw_text(ctx, SPDF_WIN_CHROME_EMPTY_OPEN_LABEL, button,
                              spdf_win_ct_calibrated(1.0f, 1.0f, 1.0f, 0.98f), spdf_win_chrome_px(13.0, s),
                              DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_ALIGNMENT_CENTER, 0);
    /* An empty rect on a canvas too short for it; draw_text bails on that. */
    spdf_win_chrome_draw_text(ctx, SPDF_WIN_CHROME_EMPTY_DROP_HINT, hint, th->label_secondary,
                              spdf_win_chrome_px(12.0, s), DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_CENTER, 0);
}

#endif /* SPDF_WIN_CHROME_EMPTY_PAINT_H */
