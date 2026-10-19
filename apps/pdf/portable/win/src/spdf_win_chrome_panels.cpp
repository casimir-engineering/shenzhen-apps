/* The panels region: the two split dividers, and the dispatch to the sidebar
 * and minimap painters.
 *
 * THE REGION'S METRICS, all cited to portable/mac/ShenzhenPDFMac.mm. The two
 * panels' own numbers now live with their painters
 * (spdf_win_chrome_sidebar.cpp, spdf_win_chrome_minimap.cpp); what remains here
 * is the frame they sit in:
 *
 * SIDEBAR -- kDefaultSidebarWidth 240.0, min 176.0, max 320.0, search-mode min
 * 216.0, max 0.34 of the split view (:72-76, clamps :179-187). VISIBLE BY
 * DEFAULT (:836-838).
 *
 * MINIMAP -- kDefaultMinimapWidth 126.5 (:71), clamped [72, 260] on read
 * (:1455). VISIBLE BY DEFAULT (:837-840).
 *
 * DIVIDERS -- width 5.0 (:77-78), drawn as windowBackgroundColor with a 1 pt
 * separatorColor line down the CENTRE and a resizeLeftRight cursor
 * (SPDFMacUIHelpers.mm:425-431).
 *
 * WHY THIS FILE IS THREE FILES. The sidebar's chapter list and the minimap's
 * thumbnail strip are each substantial, and together they put this translation
 * unit past the repo's 500-line cap. tools/file-size-limits.md asks for
 * extraction rather than a raised cap, so the region is split along the seam it
 * already had -- see spdf_win_chrome_panels.h. spdf_win_chrome_paint.h still
 * declares exactly one entry point for the region, and the split is invisible
 * from outside.
 *
 * CONTENT IS RESOLVED ONCE, HERE, AND THREADED DOWN. spdf_win_chrome_paint.h's
 * ctx cannot carry the outline or the thumbnail store (it belongs to another
 * track), so this function asks spdf_win_chrome_content.h for the provider at
 * the top of the frame and passes each half to its painter as an argument. No
 * drawing code below reads content from ambient state, which is what keeps the
 * whole region testable with a hand-built content struct and no document.
 */
#include "spdf_win_chrome_panels.h"

#include <math.h>

void spdf_win_chrome_panel_fill_rounded(ID2D1RenderTarget* target, SpdfWinChromeRect r, float radius,
                                        ID2D1Brush* fill, ID2D1Brush* stroke, float stroke_w) {
    D2D1_ROUNDED_RECT rr;
    if (spdf_win_chrome_rect_empty(r)) return;
    rr.rect = stroke ? spdf_win_chrome_stroke_rect(r, stroke_w) : spdf_win_chrome_d2d_rect(r);
    rr.radiusX = radius;
    rr.radiusY = radius;
    if (fill) target->FillRoundedRectangle(rr, fill);
    if (stroke) target->DrawRoundedRectangle(rr, stroke, stroke_w, NULL);
}

namespace {

/* macOS's divider: the window background, with a hairline down the CENTRE
 * rather than at an edge. Reproduced exactly -- an edge line would read as a
 * border on one panel instead of a grabbable seam between two. */
void draw_divider(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect d) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    ID2D1SolidColorBrush* fill;
    ID2D1SolidColorBrush* line;
    float hw;

    if (spdf_win_chrome_rect_empty(d)) return;
    fill = spdf_win_chrome_brush(ctx.target, th->divider_fill);
    if (fill) {
        ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(d), fill);
        fill->Release();
    }
    line = spdf_win_chrome_brush(ctx.target, th->separator);
    if (line) {
        hw = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
        /* Centre the hairline, snapped so it does not straddle two columns. */
        float x = floorf(d.x + (d.w - hw) * 0.5f);
        ctx.target->FillRectangle(D2D1::RectF(x, d.y, x + hw, d.y + d.h), line);
        line->Release();
    }
}

} /* namespace */

void spdf_win_chrome_paint_panels(const SpdfWinChromePaintCtx& ctx) {
    const SpdfWinChromePanelsContent* content;

    if (!ctx.layout || !ctx.model || !ctx.theme) return;

    /* Resolved once, and only when a panel is actually going to be drawn: a
     * hidden sidebar and a hidden minimap must cost nothing, and the built-in
     * provider opens the document lazily from here. Presentation mode and every
     * headless --render-png therefore pay exactly zero. */
    content = (spdf_win_chrome_rect_empty(ctx.layout->sidebar) && spdf_win_chrome_rect_empty(ctx.layout->minimap))
                  ? NULL
                  : spdf_win_chrome_content_current();

    spdf_win_chrome_paint_sidebar(ctx, content ? content->sidebar : NULL);
    spdf_win_chrome_paint_minimap(ctx, content ? content->minimap : NULL);

    /* The two dividers last, so they sit above both panels' edges. */
    draw_divider(ctx, ctx.layout->sidebar_divider);
    draw_divider(ctx, ctx.layout->minimap_divider);
}
