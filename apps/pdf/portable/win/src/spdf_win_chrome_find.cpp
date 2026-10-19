/* The toolbar's find controls: items 12-15 of the row.
 *
 * Split out of spdf_win_chrome_toolbar.cpp rather than added to it, because that
 * file is at its size cap and tools/file-size-limits.md prefers a focused file
 * over a raised cap. It is called from that file's one walk of the layout table,
 * so the row is still drawn by a single pass and every rect still comes from
 * spdf_win_chrome_toolbar.h -- the rule spdf_win_chrome.h states, that
 * hit-testing and painting agree only if they call the same functions.
 *
 * macOS (ShenzhenPDFMac.mm:3032-3086):
 *   12 SPDFFindSearchField, placeholder "Find", width 88-141
 *   13 regex checkbox, width 68
 *   14 count label, width 64, CENTRED, monospacedDigitSystemFontOfSize:12,
 *      secondaryLabelColor
 *   15 find pill, previous / next match
 *
 * HIDE-WHEN-EMPTY, AND THE ONE DELIBERATE DEVIATION. macOS hides the counter and
 * the prev/next pill whenever the query is empty, and its stack view then
 * reflows the row. This port hides them by NOT DRAWING them and leaves the
 * layout alone. Reflowing would mean the painter and the input router laying the
 * row out from different inputs, so the search field would sit in one place and
 * be clickable in another -- which is exactly the silent drift
 * spdf_win_chrome_toolbar.h was created to prevent. The cost is a little empty
 * band to the right of the field before a query is typed; the alternative costs
 * a control that responds two pixels away. Revisit when the router takes the
 * model, at which point both sides can hide together.
 *
 * WHAT IS *NOT* HERE. The find session, the temporary query bridge and
 * spdf_win_find_fill_model() are in spdf_win_chrome_model.cpp, deliberately:
 * everything this file needs is inline in spdf_win_chrome_find.h, so a test that
 * links the toolbar painter does not also drag in the search engine, its worker
 * thread and MuPDF behind it.
 *
 * MONOSPACED DIGITS. macOS uses monospacedDigitSystemFontOfSize:12 for the
 * counter so the label does not jitter as the running total ticks over from 9 to
 * 10. DirectWrite's equivalent is the OpenType `tnum` feature on the UI face,
 * which the shared text helper does not expose; the counter is CENTRED instead,
 * which is also what macOS does, so the jitter is symmetric and half as large.
 * Noted rather than silently dropped -- see this change's report.
 */
#include "spdf_win_chrome_find.h"

#include <math.h>

namespace {

float px(double points, float s) { return spdf_win_chrome_px(points, s); }

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

/* The same capsule spdf_win_chrome_toolbar.cpp draws, because macOS builds every
 * pill through one factory (spdf_toolbar_segments, SPDFMacSupport.mm:325-352)
 * "so a single-segment control and a paired one share background, height and
 * icon tint exactly". Duplicated as ten lines rather than exported from the
 * toolbar painter: exporting it would put a drawing helper in a header that a
 * geometry test includes, and ten lines is cheaper than that. */
void draw_pill(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, int segments, float alpha) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, ctx.dpi_scale);
    ID2D1SolidColorBrush* fill;
    ID2D1SolidColorBrush* stroke;
    int i;

    if (spdf_win_chrome_rect_empty(r)) return;
    fill = spdf_win_chrome_brush(ctx.target, th->control_fill);
    stroke = spdf_win_chrome_brush(ctx.target, th->control_stroke);
    if (fill) fill->SetOpacity(alpha);
    if (stroke) stroke->SetOpacity(alpha);
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

void draw_chevron(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect cell, int pointing_left, ID2D1Brush* brush) {
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

/* A text field: recessed capsule, then either the live text or the placeholder.
 * `placeholder` is drawn in the secondary label colour, which is what makes an
 * empty field read as empty rather than as containing the word "Find". */
void draw_field(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, const wchar_t* text,
                const wchar_t* placeholder, int enabled) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    ID2D1SolidColorBrush* fill;
    ID2D1SolidColorBrush* stroke;
    int empty;

    if (spdf_win_chrome_rect_empty(r)) return;
    fill = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(th->field_fill, enabled));
    stroke = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(th->control_stroke, enabled));
    fill_rounded(ctx.target, r, px(5.0, s), fill, stroke, spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s));
    if (fill) fill->Release();
    if (stroke) stroke->Release();

    empty = !(text && text[0]);
    {
        /* A magnifier is what makes this field readable AS a search field before
         * anything is typed; macOS gets one free from NSSearchField. Two strokes
         * -- a circle and a handle -- so it stays crisp at any DPI. */
        ID2D1SolidColorBrush* glyph = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(th->label_secondary, enabled));
        SpdfWinChromeRect t = r;
        float inset = px(8.0, s);
        if (glyph) {
            float cx = r.x + px(13.0, s);
            float cy = r.y + r.h * 0.5f;
            float rad = px(4.0, s);
            float lw = spdf_win_chrome_stroke_px(1.3f, s);
            D2D1_ELLIPSE e;
            e.point.x = cx;
            e.point.y = cy - px(1.0, s);
            e.radiusX = rad;
            e.radiusY = rad;
            ctx.target->DrawEllipse(e, glyph, lw, NULL);
            ctx.target->DrawLine(D2D1::Point2F(cx + rad * 0.7f, cy + rad * 0.7f - px(1.0, s)),
                                 D2D1::Point2F(cx + rad * 1.6f, cy + rad * 1.6f - px(1.0, s)), glyph, lw, NULL);
            glyph->Release();
        }
        t.x = r.x + px(22.0, s);
        t.w = r.w - px(22.0, s) - inset;
        if (t.w > 0.0f)
            spdf_win_chrome_draw_text(ctx, empty ? placeholder : text, t,
                                      spdf_win_chrome_dim(empty ? th->label_secondary : th->label, enabled),
                                      px(SPDF_WIN_CT_FONT_SIZE_FIELD, s), DWRITE_FONT_WEIGHT_NORMAL,
                                      DWRITE_TEXT_ALIGNMENT_LEADING, 1);
    }
}

/* The regex checkbox: a 14 pt square box with a tick when on, then the label.
 * NSButton's checkbox is system-drawn on macOS, so as with the pills the thing
 * to reproduce is the relationship -- box, tick, label, all on the row's
 * baseline -- rather than a literal. */
void draw_checkbox(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, const wchar_t* label, int on, int enabled) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    float box = px(14.0, s);
    SpdfWinChromeRect b;
    SpdfWinChromeRect t;
    ID2D1SolidColorBrush* fill;
    ID2D1SolidColorBrush* stroke;

    if (spdf_win_chrome_rect_empty(r)) return;
    b.x = r.x;
    b.y = r.y + (r.h - box) * 0.5f;
    b.w = box;
    b.h = box;
    fill = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(on ? th->accent : th->field_fill, enabled));
    stroke = spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(th->control_stroke, enabled));
    fill_rounded(ctx.target, b, px(3.0, s), fill, stroke, spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s));
    if (fill) fill->Release();
    if (stroke) stroke->Release();

    if (on) {
        /* White on the accent fill, in BOTH themes and as a literal rather than
         * a palette entry: the accent is a saturated colour in either theme (it
         * is the same NSColor.controlAccentColor the selected tab is stroked
         * with), so the knockout that reads on it is the same knockout. A
         * theme-following tick would be invisible in one of the two. */
        ID2D1SolidColorBrush* tick =
            spdf_win_chrome_brush(ctx.target, spdf_win_chrome_dim(spdf_win_ct_calibrated(1.0f, 1.0f, 1.0f, 0.96f), enabled));
        if (tick) {
            float lw = spdf_win_chrome_stroke_px(1.6f, s);
            float cx = b.x + b.w * 0.5f;
            float cy = b.y + b.h * 0.5f;
            ctx.target->DrawLine(D2D1::Point2F(cx - px(3.2, s), cy), D2D1::Point2F(cx - px(0.8, s), cy + px(2.6, s)),
                                 tick, lw, NULL);
            ctx.target->DrawLine(D2D1::Point2F(cx - px(0.8, s), cy + px(2.6, s)),
                                 D2D1::Point2F(cx + px(3.4, s), cy - px(3.0, s)), tick, lw, NULL);
            tick->Release();
        }
    }

    t = r;
    t.x = b.x + box + px(5.0, s);
    t.w = r.x + r.w - t.x;
    if (t.w > 0.0f)
        spdf_win_chrome_draw_text(ctx, label, t, spdf_win_chrome_dim(th->label, enabled),
                                  px(SPDF_WIN_CT_FONT_SIZE_LABEL, s), DWRITE_FONT_WEIGHT_NORMAL,
                                  DWRITE_TEXT_ALIGNMENT_LEADING, 0);
}

} /* namespace */

void spdf_win_chrome_paint_find(const SpdfWinChromePaintCtx& ctx, const SpdfWinToolbarLayout& tb) {
    const SpdfWinChromeModel* m = ctx.model;
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    int live = spdf_win_find_has_query(m);
    ID2D1SolidColorBrush* glyph;
    /* THERE IS NOTHING TO SEARCH WITH NO DOCUMENT, and macOS says so control by
     * control: `_searchField.enabled = hasDoc` (:10232) and
     * `_findRegexCheckbox.enabled = hasDoc` (:10233). Same test the input router
     * refuses these two from (spdf_win_chrome_empty.h), so the field cannot be
     * drawn grey and still take the keyboard. */
    int has_doc;

    if (!m || !th) return;
    has_doc = spdf_win_chrome_has_document(m);

    /* 12. The search field, showing the live query. */
    draw_field(ctx, tb.item[SPDF_WIN_TB_FIND_FIELD], m->query, L"Find", has_doc);

    /* 13. The regex checkbox. Always shown -- it is not hidden with the query on
     * macOS either; it is only collapsed by width, which the layout already
     * did. */
    draw_checkbox(ctx, tb.item[SPDF_WIN_TB_FIND_REGEX], L"Regex", m->regex, has_doc);

    if (!live) return; /* the counter and the pill are hidden with no query */

    /* 14. The counter, centred in its 64 pt slot in secondaryLabelColor. */
    {
        wchar_t text[SPDF_WIN_FIND_COUNTER_MAX];
        spdf_win_find_counter_text(m, text, SPDF_WIN_FIND_COUNTER_MAX);
        spdf_win_chrome_draw_text(ctx, text, tb.item[SPDF_WIN_TB_FIND_COUNT],
                                  spdf_win_chrome_dim(th->label_secondary, has_doc),
                                  px(SPDF_WIN_CT_FONT_SIZE_LABEL, s), DWRITE_FONT_WEIGHT_NORMAL,
                                  DWRITE_TEXT_ALIGNMENT_CENTER, 0);
    }

    /* 15. The prev/next pill. Dimmed with nothing to step through, which is what
     * an NSSegmentedControl with both segments disabled looks like -- and the
     * state a reader is in for the whole of a query that matches nothing. */
    {
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_FIND_PILL];
        /* The literal 0.44 that was here is SPDF_WIN_CHROME_DISABLED_ALPHA now:
         * this pill's "nothing to step through" grey IS the row's disabled grey,
         * and the whole point of naming it is that the two cannot drift. */
        int enabled = has_doc && m->match_count > 0;
        float alpha = enabled ? 1.0f : SPDF_WIN_CHROME_DISABLED_ALPHA;
        draw_pill(ctx, r, 2, alpha);
        glyph = spdf_win_chrome_brush(ctx.target, th->control_glyph);
        if (glyph) {
            glyph->SetOpacity(alpha);
            draw_chevron(ctx, spdf_win_toolbar_cell(r, 0, 2), 1, glyph);
            draw_chevron(ctx, spdf_win_toolbar_cell(r, 1, 2), 0, glyph);
            glyph->Release();
        }
    }
}
