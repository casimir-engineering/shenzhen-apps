#pragma once

/* spdf_win_chrome_caption.h -- drawing the three Windows caption buttons at the
 * tab strip's trailing end. For spdf_win_chrome_paint.cpp only.
 *
 * NOT A NEW LAYER: header-only, included from exactly one translation unit,
 * after that file's helpers, the same arrangement as spdf_win_window_frame.h
 * beside the window proc. It is a separate file because chrome_paint.cpp sits
 * near the 500-line cap (tools/file-size-limits.md) and because the caption
 * buttons are the one part of the strip with no macOS counterpart to cite --
 * everything else in that file is a transcription of SPDFMacTabStripView.mm.
 *
 * SAME RULE AS spdf_win_chrome_paint.h: nothing here may require an HWND. The
 * buttons are drawn from SpdfWinChromeModel::maximized / caption_hot /
 * caption_pressed and from spdf_win_tabstrip_caption_rect(), the same function
 * WM_NCHITTEST asks (through spdf_win_chrome_input.h) when it decides that a
 * point is HTCLOSE. So the pixel that closes the window is the pixel drawn red,
 * and the headless `--render-window-png --chrome` frame shows the three buttons
 * at rest exactly where the live window has them.
 *
 * THE GLYPHS ARE STROKES, NOT FONT GLYPHS, and that is a decision rather than a
 * shortcut. Windows 11 draws its caption glyphs from Segoe Fluent Icons (E921
 * minimize, E922 maximize, E923 restore, E8BB close); Windows 10 has only Segoe
 * MDL2 Assets, and DirectWrite's CreateTextFormat SUCCEEDS for a family that is
 * not installed and silently substitutes -- so a font-based caption would draw
 * tofu boxes on a Windows 10 machine and nothing in the build would notice. The
 * four glyphs are a line, a square, two squares and an X, at 10 px on a 96-dpi
 * grid; drawing them as strokes puts them on the pixel grid at every DPI (the
 * reason the strip's `+` is already two strokes rather than a "+" character) and
 * makes them byte-stable across font versions, which is what a pixel test needs.
 */

/* One stroke width for all four glyphs. 1 px up to 150%, where Fluent's own
 * caption glyphs are still hairline-thin, and rounding up from 175%. Not
 * spdf_win_chrome_stroke_px(), which rounds 1.5 up to 2 -- right for a hairline
 * that must never disappear, too heavy for a glyph on a 15 px grid. */
static float caption_line_px(float s) {
    float w = floorf(s + 0.25f);
    return w < 1.0f ? 1.0f : w;
}

/* The square-ish glyphs are built from whole-pixel rectangles so their edges
 * never straddle two columns. Every coordinate here is already snapped. */
static void caption_fill_px(ID2D1RenderTarget* t, float x, float y, float w, float h, ID2D1Brush* b) {
    if (w <= 0.0f || h <= 0.0f || !b) return;
    t->FillRectangle(D2D1::RectF(x, y, x + w, y + h), b);
}

/* An outlined square of side `g` whose stroke is `lw` wide, drawn as four fills
 * so it is crisp with no half-pixel arithmetic. */
static void caption_square_px(ID2D1RenderTarget* t, float x, float y, float g, float lw, ID2D1Brush* b) {
    caption_fill_px(t, x, y, g, lw, b);           /* top */
    caption_fill_px(t, x, y + g - lw, g, lw, b);  /* bottom */
    caption_fill_px(t, x, y, lw, g, b);           /* left */
    caption_fill_px(t, x + g - lw, y, lw, g, b);  /* right */
}

static void caption_draw_glyph(const SpdfWinChromePaintCtx& ctx, int button, int maximized, SpdfWinChromeRect r,
                               ID2D1Brush* brush, float s) {
    ID2D1RenderTarget* t = ctx.target;
    /* 10 px at 96 dpi, the size of every Windows caption glyph. */
    float g = spdf_win_chrome_px(10.0, s);
    float lw = caption_line_px(s);
    float x0 = floorf(r.x + (r.w - g) * 0.5f);
    float y0 = floorf(r.y + (r.h - g) * 0.5f);
    if (!brush) return;

    switch (button) {
        case SPDF_WIN_CAPTION_MINIMIZE:
            /* A single horizontal line on the glyph box's centre row. */
            caption_fill_px(t, x0, floorf(y0 + (g - lw) * 0.5f + 0.5f), g, lw, brush);
            return;
        case SPDF_WIN_CAPTION_MAXIMIZE:
            if (!maximized) {
                caption_square_px(t, x0, y0, g, lw, brush);
                return;
            }
            /* Restore: the front square, offset down-left, and the back square's
             * top and right edges showing behind it -- ChromeRestore's shape. */
            {
                float d = spdf_win_chrome_px(2.0, s);
                float f = g - d;
                caption_square_px(t, x0, y0 + d, f, lw, brush);
                caption_fill_px(t, x0 + d, y0, f, lw, brush);           /* back top */
                caption_fill_px(t, x0 + g - lw, y0, lw, f, brush);      /* back right */
            }
            return;
        case SPDF_WIN_CAPTION_CLOSE: {
            /* Diagonals cannot sit on the grid; they are the one antialiased
             * stroke here, the same as the tab close box's X. Pixel-centred so a
             * 1 px line does not smear across two columns at 45 degrees. */
            float half = lw * 0.5f;
            float ax = x0 + half, ay = y0 + half;
            float bx = x0 + g - half, by = y0 + g - half;
            t->DrawLine(D2D1::Point2F(ax, ay), D2D1::Point2F(bx, by), brush, lw, NULL);
            t->DrawLine(D2D1::Point2F(bx, ay), D2D1::Point2F(ax, by), brush, lw, NULL);
            return;
        }
        default: return;
    }
}

/* The three buttons, from the model. `strip` is the strip's client-space rect,
 * `s` the DPI scale -- the same two values the tab painter converts with, so a
 * button lands on the pixels spdf_win_chrome_layout's `caption` rect names. */
static void spdf_win_chrome_paint_caption(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect strip, float s) {
    const SpdfWinChromeModel* m = ctx.model;
    const SpdfWinChromeTheme* th = ctx.theme;
    double strip_w_pt = strip.w / s;
    double strip_h_pt = strip.h / s;
    int b;

    if (!m || !th || spdf_win_chrome_rect_empty(strip)) return;

    for (b = SPDF_WIN_CAPTION_MINIMIZE; b <= SPDF_WIN_CAPTION_CLOSE; ++b) {
        SpdfWinTabRect tr = spdf_win_tabstrip_caption_rect(strip_w_pt, strip_h_pt, b);
        SpdfWinChromeRect r;
        int is_close = b == SPDF_WIN_CAPTION_CLOSE;
        int pressed = m->caption_pressed == b;
        int hot = pressed || m->caption_hot == b;
        ID2D1SolidColorBrush* glyph;

        if (spdf_win_tabstrip_rect_is_empty(tr)) continue;
        /* Whole pixels, the way to_client() snaps a tab. */
        r.x = strip.x + spdf_win_chrome_px(tr.x, s);
        r.y = strip.y + spdf_win_chrome_px(tr.y, s);
        r.w = spdf_win_chrome_px(tr.w, s);
        r.h = spdf_win_chrome_px(tr.h, s);

        /* At rest a caption button is invisible -- the band shows through. It
         * lifts on hover and drops a step when held; close alone goes red. */
        if (hot) {
            SpdfWinChromeColor c;
            ID2D1SolidColorBrush* fill;
            if (is_close) c = pressed ? th->caption_close_pressed : th->caption_close_hot;
            else c = pressed ? th->caption_fill_pressed : th->caption_fill_hot;
            fill = spdf_win_chrome_brush(ctx.target, c);
            if (fill) {
                ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(r), fill);
                fill->Release();
            }
        }
        glyph = spdf_win_chrome_brush(ctx.target, (is_close && hot) ? th->caption_glyph_on_close : th->caption_glyph);
        caption_draw_glyph(ctx, b, m->maximized, r, glyph, s);
        if (glyph) glyph->Release();
    }
}
