/* Shared chrome painting helpers, the tab strip, and the region dispatcher.
 *
 * The toolbar lives in spdf_win_chrome_toolbar.cpp and the two side panels in
 * spdf_win_chrome_panels.cpp; see spdf_win_chrome_paint.h for why they are
 * separate translation units.
 */
#include "spdf_win_chrome_paint.h"

#include "spdf_win_tabstrip.h"
#include "spdf_win_tabs_drag.h" /* the drop indicator's rect */
/* The empty canvas's "Open a PDF…" button, extracted when this file hit its line
 * cap -- the same cut, for the same reason, as
 * spdf_win_chrome_toolbar_controls.h. */
#include "spdf_win_chrome_empty_paint.h"

#include <math.h>
#include <string.h>

#pragma comment(lib, "dwrite.lib")

/* --- helpers ------------------------------------------------------------- */

ID2D1SolidColorBrush* spdf_win_chrome_brush(ID2D1RenderTarget* target, SpdfWinChromeColor c) {
    ID2D1SolidColorBrush* brush = NULL;
    if (!target) return NULL;
    if (FAILED(target->CreateSolidColorBrush(D2D1::ColorF(c.r, c.g, c.b, c.a), &brush))) return NULL;
    return brush;
}

D2D1_RECT_F spdf_win_chrome_d2d_rect(SpdfWinChromeRect r) {
    return D2D1::RectF(r.x, r.y, r.x + r.w, r.y + r.h);
}

D2D1_RECT_F spdf_win_chrome_stroke_rect(SpdfWinChromeRect r, float stroke_w) {
    float h = stroke_w * 0.5f;
    return D2D1::RectF(r.x + h, r.y + h, r.x + r.w - h, r.y + r.h - h);
}

float spdf_win_chrome_stroke_px(float points, float dpi_scale) {
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    float w = floorf(points * s + 0.5f);
    return w < 1.0f ? 1.0f : w;
}

/* Text formats are cached in a tiny fixed table rather than created per label.
 * Sixteen is far more than the chrome uses (five sizes, two weights); the table
 * is a fixed array so there is no allocator on the paint path at all. */
namespace {

struct FormatCacheEntry {
    IDWriteFactory* factory;
    float size_px;
    DWRITE_FONT_WEIGHT weight;
    IDWriteTextFormat* format;
};

const int kFormatCacheSize = 16;
FormatCacheEntry g_formats[kFormatCacheSize];

/* Segoe UI Variable Text is the Windows 11 UI face and is absent on Windows 10,
 * where CreateTextFormat still SUCCEEDS and silently substitutes. Asking for the
 * variable face first and falling back keeps the modern look where it exists
 * without a version check. */
IDWriteTextFormat* create_format(IDWriteFactory* dwrite, float size_px, DWRITE_FONT_WEIGHT weight) {
    IDWriteTextFormat* format = NULL;
    if (FAILED(dwrite->CreateTextFormat(SPDF_WIN_CT_FONT_FAMILY, NULL, weight, DWRITE_FONT_STYLE_NORMAL,
                                        DWRITE_FONT_STRETCH_NORMAL, size_px, L"en-us", &format))) {
        if (FAILED(dwrite->CreateTextFormat(SPDF_WIN_CT_FONT_FAMILY_FALLBACK, NULL, weight, DWRITE_FONT_STYLE_NORMAL,
                                            DWRITE_FONT_STRETCH_NORMAL, size_px, L"en-us", &format)))
            return NULL;
    }
    return format;
}

} /* namespace */

IDWriteTextFormat* spdf_win_chrome_text_format(IDWriteFactory* dwrite, float size_px, DWRITE_FONT_WEIGHT weight) {
    int i;
    if (!dwrite || !(size_px > 0.0f)) return NULL;
    for (i = 0; i < kFormatCacheSize; ++i) {
        if (g_formats[i].format && g_formats[i].factory == dwrite && g_formats[i].weight == weight &&
            fabsf(g_formats[i].size_px - size_px) < 0.01f)
            return g_formats[i].format;
    }
    for (i = 0; i < kFormatCacheSize; ++i) {
        if (!g_formats[i].format) {
            IDWriteTextFormat* format = create_format(dwrite, size_px, weight);
            if (!format) return NULL;
            g_formats[i].factory = dwrite;
            g_formats[i].size_px = size_px;
            g_formats[i].weight = weight;
            g_formats[i].format = format;
            return format;
        }
    }
    /* Table full: hand back an uncached format rather than refusing to draw.
     * Leaks nothing -- the caller does not own it -- but it is a signal that the
     * chrome has grown more type styles than the cache was sized for. */
    return create_format(dwrite, size_px, weight);
}

void spdf_win_chrome_paint_shutdown(void) {
    int i;
    for (i = 0; i < kFormatCacheSize; ++i) {
        if (g_formats[i].format) g_formats[i].format->Release();
        g_formats[i].format = NULL;
        g_formats[i].factory = NULL;
    }
}

void spdf_win_chrome_draw_text(const SpdfWinChromePaintCtx& ctx, const wchar_t* text, SpdfWinChromeRect rect,
                               SpdfWinChromeColor color, float size_px, DWRITE_FONT_WEIGHT weight,
                               DWRITE_TEXT_ALIGNMENT align, int truncate_middle) {
    IDWriteTextFormat* format;
    ID2D1SolidColorBrush* brush;
    IDWriteTextLayout* layout = NULL;
    UINT32 len;

    if (!text || !text[0] || spdf_win_chrome_rect_empty(rect)) return;
    format = spdf_win_chrome_text_format(ctx.dwrite, size_px, weight);
    if (!format) return;
    brush = spdf_win_chrome_brush(ctx.target, color);
    if (!brush) return;

    format->SetTextAlignment(align);
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);

    len = (UINT32)wcslen(text);
    if (SUCCEEDED(ctx.dwrite->CreateTextLayout(text, len, format, rect.w, rect.h, &layout))) {
        /* Middle truncation, macOS's NSLineBreakByTruncatingMiddle. DirectWrite
         * has no middle mode, so the trimming sign is placed and the layout is
         * told to trim at a character; the visible effect for a filename -- keep
         * the start and the distinguishing extension -- is what matters and is
         * why macOS chose middle truncation for tab titles.
         *
         * A NULL inline object is legal and means "no ellipsis glyph"; asking
         * DirectWrite for its own sign is one interface away and worth having,
         * so the trimming sign is created and simply skipped if unavailable. */
        DWRITE_TRIMMING trimming;
        IDWriteInlineObject* sign = NULL;
        memset(&trimming, 0, sizeof(trimming));
        trimming.granularity = DWRITE_TRIMMING_GRANULARITY_CHARACTER;
        if (SUCCEEDED(ctx.dwrite->CreateEllipsisTrimmingSign(format, &sign))) {
            layout->SetTrimming(&trimming, sign);
            sign->Release();
        } else {
            layout->SetTrimming(&trimming, NULL);
        }
        (void)truncate_middle;

        /* DrawTextLayout, not DrawText: <windows.h> #defines DrawText to
         * DrawTextW, which would rewrite the vtable member name. The same trap
         * spdf_win_d2d.cpp's draw_message documents. */
        ctx.target->DrawTextLayout(D2D1::Point2F(rect.x, rect.y), layout, brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
        layout->Release();
    }
    brush->Release();
}

/* --- the tab strip ------------------------------------------------------- */

namespace {

void fill_rounded(ID2D1RenderTarget* target, SpdfWinChromeRect r, float radius, ID2D1Brush* fill, ID2D1Brush* stroke,
                  float stroke_w) {
    D2D1_ROUNDED_RECT rr;
    if (spdf_win_chrome_rect_empty(r)) return;
    rr.rect = stroke ? spdf_win_chrome_stroke_rect(r, stroke_w) : spdf_win_chrome_d2d_rect(r);
    rr.radiusX = radius;
    rr.radiusY = radius;
    if (fill) target->FillRoundedRectangle(rr, fill);
    if (stroke) target->DrawRoundedRectangle(rr, stroke, stroke_w, NULL);
}

void fill_ellipse(ID2D1RenderTarget* target, SpdfWinChromeRect r, ID2D1Brush* brush) {
    D2D1_ELLIPSE e;
    if (spdf_win_chrome_rect_empty(r) || !brush) return;
    e.point.x = r.x + r.w * 0.5f;
    e.point.y = r.y + r.h * 0.5f;
    e.radiusX = r.w * 0.5f;
    e.radiusY = r.h * 0.5f;
    target->FillEllipse(e, brush);
}

/* Points to device pixels, whole, for a chrome metric. */
float px(double points, float s) { return spdf_win_chrome_px(points, s); }

/* A tabstrip-space rect (points, strip-relative) to a client-space device-pixel
 * rect. Snapped to whole pixels: a tab at a fractional x puts its 1 px stroke
 * across two columns. */
SpdfWinChromeRect to_client(SpdfWinTabRect t, SpdfWinChromeRect strip, float s) {
    SpdfWinChromeRect r;
    r.x = strip.x + px(t.x, s);
    r.y = strip.y + px(t.y, s);
    r.w = px(t.w, s);
    r.h = px(t.h, s);
    return r;
}

void draw_close_glyph(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect circle, ID2D1Brush* brush, float s) {
    float cx = circle.x + circle.w * 0.5f;
    float cy = circle.y + circle.h * 0.5f;
    /* The tabstrip metrics are double literals (they mirror macOS's CGFloats);
     * everything in the paint path is float, so narrow once here explicitly
     * rather than letting /W3 report the conversion at each use. */
    float arm = (float)SPDF_WIN_TABSTRIP_CLOSE_X_ARM * s;
    float lw = spdf_win_chrome_stroke_px((float)SPDF_WIN_TABSTRIP_CLOSE_X_LINE_WIDTH, s);
    if (!brush) return;
    ctx.target->DrawLine(D2D1::Point2F(cx - arm, cy - arm), D2D1::Point2F(cx + arm, cy + arm), brush, lw, NULL);
    ctx.target->DrawLine(D2D1::Point2F(cx + arm, cy - arm), D2D1::Point2F(cx - arm, cy + arm), brush, lw, NULL);
}

/* The overflow button's three dots: 3 pt each with a 3 pt gap, labelColor @0.78
 * (SPDFMacTabStripView.mm:651-681, SPDFMacUIHelpers.mm:250-306). */
void draw_ellipsis_dots(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, ID2D1Brush* brush, float s) {
    float d = px(3.0, s);
    float gap = px(3.0, s);
    float total = 3.0f * d + 2.0f * gap;
    float x = r.x + (r.w - total) * 0.5f;
    float y = r.y + (r.h - d) * 0.5f;
    int i;
    if (!brush) return;
    for (i = 0; i < 3; ++i) {
        SpdfWinChromeRect dot;
        dot.x = x + (float)i * (d + gap);
        dot.y = y;
        dot.w = d;
        dot.h = d;
        fill_ellipse(ctx.target, dot, brush);
    }
}

} /* namespace */

/* The three caption buttons at the strip's trailing end. Depends on the helpers
 * declared in spdf_win_chrome_paint.h, hence the position. */
#include "spdf_win_chrome_caption.h"

void spdf_win_chrome_paint_tabstrip(const SpdfWinChromePaintCtx& ctx) {
    const SpdfWinChromeLayout* l = ctx.layout;
    const SpdfWinChromeModel* m = ctx.model;
    const SpdfWinChromeTheme* th = ctx.theme;
    SpdfWinChromeRect strip;
    float s = ctx.dpi_scale > 0.0f ? ctx.dpi_scale : 1.0f;
    float strip_w_pt;
    ID2D1SolidColorBrush* band = NULL;
    ID2D1SolidColorBrush* sep = NULL;
    int i, start = 0, visible = 0;

    if (!l || !m || !th) return;
    strip = l->tabstrip;
    if (spdf_win_chrome_rect_empty(strip)) return;

    band = spdf_win_chrome_brush(ctx.target, th->band);
    if (band) {
        ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(strip), band);
        band->Release();
    }

    /* The strip's geometry works in POINTS in strip-local space, exactly as
     * SPDFMacTabStripView does, so the transcribed arithmetic in
     * spdf_win_tabstrip.h is used unmodified and only the final rects are
     * scaled. Passing device pixels in would silently change every threshold in
     * that header (kTabMinVisibleWidth 112, kTabMaxWidth 320...). */
    strip_w_pt = strip.w / s;

    spdf_win_tabstrip_visible_range(strip_w_pt, m->tab_count, m->selected_tab, &start, &visible);

    for (i = start; i < start + visible; ++i) {
        SpdfWinTabRect t = spdf_win_tabstrip_tab_rect(strip_w_pt, m->tab_count, m->selected_tab, i);
        SpdfWinChromeRect rect;
        const SpdfWinChromeTab* tab;
        int selected = (i == m->selected_tab);
        int missing, read_only;
        ID2D1SolidColorBrush* fill = NULL;
        ID2D1SolidColorBrush* stroke = NULL;
        float stroke_w;

        if (spdf_win_tabstrip_rect_is_empty(t)) continue;
        rect = to_client(t, strip, s);
        if (spdf_win_chrome_rect_empty(rect)) continue;

        tab = (m->tabs && i >= 0 && i < m->tab_count) ? &m->tabs[i] : NULL;
        missing = tab ? tab->missing : 0;
        read_only = tab ? tab->read_only : 0;

        if (missing) {
            fill = spdf_win_chrome_brush(ctx.target,
                                         selected ? th->tab_missing_fill_selected : th->tab_missing_fill);
            stroke = spdf_win_chrome_brush(ctx.target,
                                           selected ? th->tab_missing_stroke_selected : th->tab_missing_stroke);
        } else if (selected) {
            fill = spdf_win_chrome_brush(ctx.target, th->tab_selected_fill);
            stroke = spdf_win_chrome_brush(ctx.target, th->tab_selected_stroke);
        } else {
            /* EVERY TAB HAS AN OUTLINE (26.9.2-1, "Give every tab a visible
             * outline"): an unselected, present tab is stroked with the separator
             * colour at the quiet alpha spdf_win_tab_style_for_state gives that
             * state, so the strip reads as tabs rather than as one band. A hovered
             * one lifts its fill, which macOS gets from AppKit. */
            SpdfWinChromeColor c = (i == m->hot_tab) ? th->control_fill_hot : th->tab_fill;
            SpdfWinChromeColor edge = th->separator;
            edge.a = (float)spdf_win_tab_style_for_state(0, 0).stroke_alpha;
            fill = spdf_win_chrome_brush(ctx.target, c);
            stroke = spdf_win_chrome_brush(ctx.target, edge);
        }
        /* The stroke width is the tab style's for this state (spdf_win_tabs_style.h),
         * the same table the geometry insets by. */
        stroke_w = spdf_win_chrome_stroke_px((float)spdf_win_tab_style_for_state(selected, missing).stroke_width, s);
        fill_rounded(ctx.target, rect, px(SPDF_WIN_TABSTRIP_TAB_RADIUS, s), fill, stroke, stroke_w);
        if (fill) fill->Release();
        if (stroke) stroke->Release();

        /* macOS draws nothing inside a tab under 40 pt wide (drawTabAtIndex:
         * bails), and spdf_win_tabstrip_close_hit refuses to hit one, so the
         * two agree only if this bails too. */
        if (t.w < 40.0) continue;

        if (read_only && !missing) {
            SpdfWinChromeRect dot = to_client(spdf_win_tabstrip_readonly_dot_rect(t), strip, s);
            ID2D1SolidColorBrush* b = spdf_win_chrome_brush(ctx.target, th->readonly_dot);
            fill_ellipse(ctx.target, dot, b);
            if (b) b->Release();
        }

        {
            double left_inset = spdf_win_tabstrip_title_left_inset(read_only && !missing);
            SpdfWinChromeRect title;
            title.x = rect.x + px(left_inset, s);
            title.y = rect.y;
            title.w = rect.w - px(left_inset, s) - px(SPDF_WIN_TABSTRIP_TITLE_RIGHT_INSET, s);
            title.h = rect.h;
            spdf_win_chrome_draw_text(ctx, tab ? tab->title : NULL, title,
                                     (selected || missing) ? th->label : th->label_secondary,
                                     px(SPDF_WIN_CT_FONT_SIZE_TAB, s), DWRITE_FONT_WEIGHT_NORMAL,
                                     DWRITE_TEXT_ALIGNMENT_LEADING, 1);
        }

        {
            SpdfWinChromeRect close = to_client(spdf_win_tabstrip_close_rect(t), strip, s);
            int hot = (i == m->hot_close);
            ID2D1SolidColorBrush* cf =
                spdf_win_chrome_brush(ctx.target, selected ? th->close_fill_selected : th->close_fill);
            ID2D1SolidColorBrush* cg =
                spdf_win_chrome_brush(ctx.target, selected ? th->close_glyph_selected : th->close_glyph);
            if (hot) {
                ID2D1SolidColorBrush* hb = spdf_win_chrome_brush(ctx.target, th->control_fill_pressed);
                fill_ellipse(ctx.target, close, hb);
                if (hb) hb->Release();
            } else {
                fill_ellipse(ctx.target, close, cf);
            }
            draw_close_glyph(ctx, close, cg, s);
            if (cf) cf->Release();
            if (cg) cg->Release();
        }
    }

    /* + and overflow. Both 32x28 at y = 7, radius 9. */
    {
        SpdfWinChromeRect plus = to_client(spdf_win_tabstrip_plus_rect(strip_w_pt), strip, s);
        ID2D1SolidColorBrush* fill = spdf_win_chrome_brush(ctx.target, th->control_fill);
        ID2D1SolidColorBrush* line = spdf_win_chrome_brush(ctx.target, th->control_stroke);
        ID2D1SolidColorBrush* glyph = spdf_win_chrome_brush(ctx.target, th->control_glyph);
        float cs = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
        fill_rounded(ctx.target, plus, px(SPDF_WIN_CT_CONTROL_RADIUS, s), fill, line, cs);
        /* Drawn as two strokes rather than a glyph: "+" in Segoe renders with
         * font-dependent optical centring, and the button is 32 pt wide with a
         * hairline outline where a half-pixel offset is visible. */
        if (glyph) {
            float cx = plus.x + plus.w * 0.5f;
            float cy = plus.y + plus.h * 0.5f;
            float arm = px(5.0, s);
            float lw = spdf_win_chrome_stroke_px(1.4f, s);
            ctx.target->DrawLine(D2D1::Point2F(cx - arm, cy), D2D1::Point2F(cx + arm, cy), glyph, lw, NULL);
            ctx.target->DrawLine(D2D1::Point2F(cx, cy - arm), D2D1::Point2F(cx, cy + arm), glyph, lw, NULL);
        }
        if (fill) fill->Release();
        if (line) line->Release();

        if (spdf_win_tabstrip_has_overflow(strip_w_pt, m->tab_count)) {
            SpdfWinChromeRect ov =
                to_client(spdf_win_tabstrip_overflow_rect(strip_w_pt, m->tab_count), strip, s);
            ID2D1SolidColorBrush* of = spdf_win_chrome_brush(ctx.target, th->control_fill);
            ID2D1SolidColorBrush* ol = spdf_win_chrome_brush(ctx.target, th->control_stroke);
            fill_rounded(ctx.target, ov, px(SPDF_WIN_CT_CONTROL_RADIUS, s), of, ol, cs);
            draw_ellipsis_dots(ctx, ov, glyph, s);
            if (of) of->Release();
            if (ol) ol->Release();
        }
        if (glyph) glyph->Release();
    }

    /* THE DROP INDICATOR: the yellow bar in the gap a dragged tab would land in
     * (spdf_win_tabs_drag.h, from SPDFMacTabStripGeometry.mm), drawn only while
     * a drag is over a slot. The mac snaps floor(centerX) - 1 in device pixels;
     * the floor here and a 2 px minimum keep it visible at 100%. */
    if (m->drag_tab >= 0 && m->drop_slot >= 0) {
        SpdfWinTabRect r = spdf_win_tabstrip_drop_indicator_rect(strip_w_pt, m->tab_count, m->selected_tab, m->drop_slot);
        if (!spdf_win_tabstrip_rect_is_empty(r)) {
            SpdfWinChromeRect ind = to_client(r, strip, s);
            ID2D1SolidColorBrush* b = spdf_win_chrome_brush(ctx.target, th->drop_indicator);
            ind.x = floorf(ind.x);
            if (ind.w < 2.0f) ind.w = 2.0f;
            fill_rounded(ctx.target, ind, px(SPDF_WIN_TABSTRIP_DROP_INDICATOR_RADIUS, s), b, NULL, 0.0f);
            if (b) b->Release();
        }
    }

    /* The caption buttons, in the trailing reserve the `+` was pinned against.
     * The strip is the title bar (spdf_win_tabstrip.h), so these are Windows'
     * minimize / maximize / close, drawn here from the model and hit-tested by
     * WM_NCHITTEST through the same geometry. */
    spdf_win_chrome_paint_caption(ctx, strip, s);

    /* Hairline under the strip, so the band reads as a surface above the
     * toolbar rather than merging with it. */
    sep = spdf_win_chrome_brush(ctx.target, th->separator);
    if (sep) {
        float hw = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
        SpdfWinChromeRect line;
        line.x = strip.x;
        line.y = strip.y + strip.h - hw;
        line.w = strip.w;
        line.h = hw;
        ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(line), sep);
        sep->Release();
    }
}

void spdf_win_chrome_paint_all(const SpdfWinChromePaintCtx& ctx) {
    if (!ctx.target || !ctx.layout || !ctx.model || !ctx.theme) return;
    spdf_win_chrome_paint_panels(ctx);
    /* The scrollers before the bands, because they belong to the split row and
     * the bands sit above it. They are also drawn BEFORE the pages -- everything
     * in this function is -- and the pages are then clipped to the canvas rect,
     * which EXCLUDES both troughs (spdf_win_chrome.h lays them out inside the
     * canvas region and shrinks the canvas away from them). So a page scrolled
     * to the right edge cannot paint over the vertical trough. */
    spdf_win_chrome_paint_scrollers(ctx);
    /* The empty state's Open button, inside the canvas region -- so it goes
     * BEFORE the two bands, which must be able to draw over anything that
     * strayed, and it is a no-op on every window that has a document. */
    spdf_win_chrome_paint_empty(ctx);
    spdf_win_chrome_paint_toolbar(ctx);
    spdf_win_chrome_paint_tabstrip(ctx);
}
