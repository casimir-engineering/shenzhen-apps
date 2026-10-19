/* The toolbar row.
 *
 * macOS: SPDFToolbarStackView, horizontal, alignment CenterY, spacing 4.0,
 * edgeInsets (7, 6, 7, 6), height pinned to 42.0 (ShenzhenPDFMac.mm:2964-2968,
 * :3293), with 18 arranged subviews left to right (:3105-3122):
 *
 *   1 sidebar toggle ("Side Panel")            10 markdown font-size pill (A- / A+)
 *   2 OCR button (icon, 32)                    11 reading-theme button (single pill, 32)
 *   3 translate button (icon, 32)              12 search field ("Find", 88-141)
 *   4 separator (NSBox, width 1)               13 regex checkbox (68)
 *   5 page field (NSTextField, 50, right)      14 find count label (64)
 *   6 page-count label ("/ N")                 15 find pill (prev / next)
 *   7 page pill (chevron.left / .right)        16 flexible spacer
 *   8 fit-mode popup (96)                      17 overflow "..." (30)
 *   9 zoom pill (minus / plus)                 18 minimap toggle ("Map")
 *
 * Custom spacing 8.0 after the zoom pill, the reading-theme button and the
 * search field. Overflow collapses group by group (:2866-2909):
 *   [ocr, translate, separator], [findCountLabel], [findSegments],
 *   [findRegexCheckbox], [markdownFontSizeSegments, readingThemeButton],
 *   [fitModePopup, zoomSegments]
 *
 * THE PILLS ARE THE VISUAL SIGNATURE. spdf_toolbar_segments()
 * (SPDFMacSupport.mm:325-352) builds every one identically -- NSSegmentedControl,
 * NSSegmentStyleRounded, NSSegmentSwitchTrackingMomentary (no sticky selection),
 * hugging and compression resistance both Required so they are never squeezed --
 * and spdf_single_toolbar_segment() uses the SAME factory deliberately, "so a
 * single-segment control and a paired one share background, height and icon tint
 * exactly" (:324-325). Their radius and height are system-drawn on macOS, so on
 * Windows they are ours to choose; what must be reproduced is the RELATIONSHIP:
 * one rounded capsule, a hairline divider between segments, momentary press
 * feedback, and a lone button that is visibly the same object as half of a pair.
 *
 * WHERE THE CONTROLS ARE is no longer decided here. It moved to
 * spdf_win_chrome_toolbar.h the moment the row became clickable, for the reason
 * spdf_win_chrome.h gives: hit-testing and painting agree only if they call the
 * same functions, and a router that re-derived the zoom pill's position would
 * drift from these pixels silently. This file walks that table and draws.
 *
 * WHAT A CONTROL LOOKS LIKE is not decided here either, since the Markdown pill
 * needed room: the capsule, the chevron, the plus/minus, the text field and the
 * labelled switch are in spdf_win_chrome_toolbar_controls.h. This file is the
 * ROW -- which controls it has, in what state, with what text.
 *
 * STATE OF THIS FILE: the page number, the page count, the zoom percentage, the
 * fit mode and the whole find group are REAL, fed from the chrome model. The
 * find group's own drawing lives in spdf_win_chrome_find.cpp -- called from
 * here, so the row is still laid out and drawn in one pass -- because this file
 * is at its size cap and tools/file-size-limits.md prefers a focused file over a
 * raised one. Still placeholders: the OCR and translate marks, and the icons
 * generally, which are stroked primitives rather than an icon font.
 */
#include "spdf_win_chrome_find.h"
#include "spdf_win_chrome_toolbar.h"
/* The capsule, the chevron, the plus/minus, the field and the labelled switch,
 * extracted when this file hit its line cap; see that header for the seam. */
#include "spdf_win_chrome_toolbar_controls.h"

#include <stdio.h>

namespace {

/* Both halves of a two-segment pill, from the SAME function the router splits it
 * with -- spdf_win_toolbar_cell(). A locally recomputed midpoint would put the
 * chevron on one side of an odd-width pill and the click boundary on the other. */
SpdfWinChromeRect cell_of(SpdfWinChromeRect pill, int index, int segments) {
    return spdf_win_toolbar_cell(pill, index, segments);
}

/* --- the two power-tool buttons -------------------------------------------
 * macOS uses SF Symbols "doc.text.viewfinder" and "character.book.closed"; the
 * port draws its icons as strokes, so OCR is a viewfinder (four corner brackets
 * around two text lines) and translate is the two letters the feature is about,
 * "A" and U+6587 (文), set small in the UI face -- DirectWrite's per-run font
 * fallback supplies the CJK glyph. Disabled: the secondary label colour. */
struct ToolsState {
    int ocr_busy, translate_busy, has_selection;
};
ToolsState g_tools; /* written by spdf_win_chrome_toolbar_set_tools_state() below */

/* `enabled` is this tool's own state -- a document open and that tool not
 * already running -- and drives the GLYPH colour, exactly as it always has.
 * `alpha` is the ROW's state, which is 1.0 whenever a document is open, so a
 * busy tool looks precisely as it did and only an empty window dims the capsule
 * as well (spdf_win_chrome_empty.h). Two parameters rather than one because they
 * answer two different questions and collapsing them would change how a running
 * OCR looks on a window that has a document -- which this change is not
 * entitled to touch. */
void draw_tool_button(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, int translate, int enabled, float alpha) {
    float s = ctx.dpi_scale, cx = r.x + r.w * 0.5f, cy = r.y + r.h * 0.5f, a = px(6.0, s);
    float lw = spdf_win_chrome_stroke_px(1.4f, s);
    SpdfWinChromeColor col = enabled ? ctx.theme->control_glyph : ctx.theme->label_secondary;
    ID2D1SolidColorBrush* b;
    if (spdf_win_chrome_rect_empty(r)) return;
    col.a *= alpha;
    draw_pill(ctx, r, 1, alpha);
    if (translate) {
        SpdfWinChromeRect t = r;
        t.w = r.w * 0.5f;
        t.x = r.x + px(3.0, s);
        t.y = r.y - px(3.0, s);
        spdf_win_chrome_draw_text(ctx, L"A", t, col, px(11.0, s), DWRITE_FONT_WEIGHT_SEMI_BOLD,
                                  DWRITE_TEXT_ALIGNMENT_LEADING, 0);
        t.x = r.x + r.w * 0.5f - px(2.0, s);
        t.y = r.y + px(3.0, s);
        spdf_win_chrome_draw_text(ctx, L"文", t, col, px(11.0, s), DWRITE_FONT_WEIGHT_NORMAL,
                                  DWRITE_TEXT_ALIGNMENT_LEADING, 0);
        return;
    }
    b = spdf_win_chrome_brush(ctx.target, col);
    if (!b) return;
    for (int i = 0; i < 4; ++i) { /* the four bracket corners */
        float sx = i % 2 ? cx + a : cx - a, sy = i < 2 ? cy - a : cy + a, c = px(2.5, s);
        float dx = i % 2 ? -c : c, dy = i < 2 ? c : -c;
        ctx.target->DrawLine(D2D1::Point2F(sx, sy), D2D1::Point2F(sx + dx, sy), b, lw, NULL);
        ctx.target->DrawLine(D2D1::Point2F(sx, sy), D2D1::Point2F(sx, sy + dy), b, lw, NULL);
    }
    ctx.target->DrawLine(D2D1::Point2F(cx - a * 0.5f, cy - px(1.5, s)), D2D1::Point2F(cx + a * 0.5f, cy - px(1.5, s)), b,
                         lw, NULL);
    ctx.target->DrawLine(D2D1::Point2F(cx - a * 0.5f, cy + px(1.5, s)), D2D1::Point2F(cx + a * 0.2f, cy + px(1.5, s)), b,
                         lw, NULL);
    b->Release();
}

/* --- the readouts -------------------------------------------------------
 *
 * Formatted here rather than in the model, because a string is presentation and
 * the model carries measurements. Both take a caller buffer: the paint path does
 * not allocate.
 *
 * PAGES ARE 0-BASED EVERYWHERE INTERNALLY -- spdf_win_main.cpp's header comment
 * is explicit that a human-facing 1-based indicator is a presentation concern
 * for whoever draws one. This is that place, and the `+ 1` below is the whole of
 * the conversion, exactly as macOS does it at ShenzhenPDFMac.mm:10528. An empty
 * field for "no document" is macOS's own `hasDoc` branch on that line. */
void page_labels(const SpdfWinChromeModel* m, wchar_t* number, size_t number_n, wchar_t* count, size_t count_n) {
    /* WHILE THE FIELD IS BEING TYPED INTO IT SHOWS WHAT WAS TYPED, and nothing
     * else. A field that re-derived its text from page_index on every frame
     * could not be edited: the first keystroke would be overwritten by the next
     * paint, which arrives immediately because the keystroke asked for one. An
     * EMPTY page_text is still page_text -- that is a reader who has just
     * cleared the field, and snapping the current page back in would make
     * Backspace look broken. */
    if (m->page_text)
        _snwprintf_s(number, number_n, _TRUNCATE, L"%s", m->page_text);
    else if (m->page_count > 0 && m->page_index >= 0)
        _snwprintf_s(number, number_n, _TRUNCATE, L"%d", m->page_index + 1);
    else
        number[0] = L'\0';
    _snwprintf_s(count, count_n, _TRUNCATE, L"/ %d", m->page_count > 0 ? m->page_count : 0);
}

/* One of the popup's four fixed titles, or the percentage macOS inserts as a
 * fifth item while the zoom is custom and removes again at 100%
 * (syncToolbarState, :10484-10505). */
void fit_label(const SpdfWinChromeModel* m, wchar_t* out, size_t n) {
    const wchar_t* fixed = spdf_win_chrome_fit_label(m->fit_mode);
    if (fixed) _snwprintf_s(out, n, _TRUNCATE, L"%s", fixed);
    else _snwprintf_s(out, n, _TRUNCATE, L"%d%%", spdf_win_chrome_zoom_percent(m));
}

} /* namespace */

extern "C" void spdf_win_chrome_toolbar_set_tools_state(int ocr_busy, int translate_busy, int has_selection) {
    g_tools.ocr_busy = ocr_busy;
    g_tools.translate_busy = translate_busy;
    g_tools.has_selection = has_selection;
}

void spdf_win_chrome_paint_toolbar(const SpdfWinChromePaintCtx& ctx) {
    const SpdfWinChromeLayout* l = ctx.layout;
    const SpdfWinChromeTheme* th = ctx.theme;
    const SpdfWinChromeModel* m = ctx.model;
    SpdfWinToolbarLayout tb;
    SpdfWinChromeRect bar;
    float s = ctx.dpi_scale > 0.0f ? ctx.dpi_scale : 1.0f;
    ID2D1SolidColorBrush* band = NULL;
    ID2D1SolidColorBrush* glyph = NULL;
    /* WITH NO DOCUMENT MOST OF THIS ROW IS DEAD, and it now looks it. macOS
     * disables the same controls one by one in -updateControls
     * (ShenzhenPDFMac.mm:10218-10248); which ones, and the alpha they dim to,
     * are spdf_win_chrome_empty.h's -- the SAME header the input router refuses
     * them from, so a control cannot be drawn grey and still be clickable, or
     * drawn live and be refused. `live` is the row's own answer, kept in a local
     * because a dozen call sites below ask it. */
    int live;
    float dim;

    if (!l || !th || !m) return;
    live = spdf_win_chrome_has_document(m);
    dim = live ? 1.0f : SPDF_WIN_CHROME_DISABLED_ALPHA;
    bar = l->toolbar;
    if (spdf_win_chrome_rect_empty(bar)) return;

    band = spdf_win_chrome_brush(ctx.target, th->band);
    if (band) {
        ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(bar), band);
        band->Release();
    }
    /* ONE glyph brush for the row, at the row's opacity. The two controls that
     * stay live with no document -- the reading theme and the overflow `...` --
     * set it back to 1.0 for themselves below, which is a smaller and more
     * visible exception than a second brush would be. */
    glyph = spdf_win_chrome_brush(ctx.target, th->control_glyph);
    if (glyph) glyph->SetOpacity(dim);

    /* WHERE each control goes comes from spdf_win_chrome_toolbar.h and from
     * nowhere else, so the input router hit-tests the rectangles this function
     * actually drew. A control the layout left empty is drawn by nobody: every
     * helper above bails on an empty rect. */
    spdf_win_toolbar_layout(bar, s, m->markdown, &tb);

    /* 1. Side Panel toggle. Disabled with no document, as :10227 does -- and
     * disabled is the honest state rather than a courtesy: the panel is hidden
     * whatever the switch says while there is nothing to list
     * (spdf_win_chrome_scene.h chrome_sidebar_decide), so flicking it changed
     * literally nothing on screen. */
    draw_toggle(ctx, tb.item[SPDF_WIN_TB_SIDEBAR_TOGGLE], L"Side Panel", m->show_sidebar, live);

    /* 2-3. OCR and translate, icon buttons 32 wide. Drawn as capsule singles so
     * they match half a pill, per the shared-factory rule. Enabled while a
     * document is open and that tool is not already running -- the Mac policy
     * (SPDFMacTranslationPolicy.mm: a PDF tab is enabled whenever a document is
     * open and idle; with a selection the button translates that). */
    draw_tool_button(ctx, tb.item[SPDF_WIN_TB_OCR], 0, live && !g_tools.ocr_busy, dim);
    draw_tool_button(ctx, tb.item[SPDF_WIN_TB_TRANSLATE], 1, live && !g_tools.translate_busy, dim);

    /* 4. Separator: an NSBox of width 1, inset 4 pt top and bottom. */
    {
        ID2D1SolidColorBrush* sep = spdf_win_chrome_brush(ctx.target, th->separator);
        if (sep) {
            ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(tb.item[SPDF_WIN_TB_SEPARATOR]), sep);
            sep->Release();
        }
    }

    /* 5-6. Page field and "/ N", both real. */
    {
        wchar_t number[16], count[24];
        page_labels(m, number, sizeof(number) / sizeof(number[0]), count, sizeof(count) / sizeof(count[0]));
        draw_field(ctx, tb.item[SPDF_WIN_TB_PAGE_FIELD], number, 0, DWRITE_TEXT_ALIGNMENT_TRAILING,
                   m->focus == SPDF_WIN_FOCUS_PAGE, live);
        spdf_win_chrome_draw_text(ctx, count, tb.item[SPDF_WIN_TB_PAGE_COUNT],
                                  spdf_win_chrome_dim(th->label_secondary, live),
                                  px(SPDF_WIN_CT_FONT_SIZE_FIELD, s), DWRITE_FONT_WEIGHT_NORMAL,
                                  DWRITE_TEXT_ALIGNMENT_LEADING, 0);
    }

    /* 7. Page pill: chevron.left / chevron.right. */
    {
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_PAGE_PILL];
        draw_pill(ctx, r, 2, dim);
        draw_chevron(ctx, cell_of(r, 0, 2), 1, glyph);
        draw_chevron(ctx, cell_of(r, 1, 2), 0, glyph);
    }

    /* 8. Fit-mode popup, showing the canvas's ACTUAL mode. */
    {
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_FIT_POPUP];
        wchar_t label[24];
        fit_label(m, label, sizeof(label) / sizeof(label[0]));
        draw_pill(ctx, r, 1, dim);
        if (!spdf_win_chrome_rect_empty(r)) {
            SpdfWinChromeRect t = r;
            t.x += px(8.0, s);
            t.w -= px(24.0, s);
            spdf_win_chrome_draw_text(ctx, label, t, spdf_win_chrome_dim(th->label, live),
                                      px(SPDF_WIN_CT_FONT_SIZE_LABEL, s), DWRITE_FONT_WEIGHT_NORMAL,
                                      DWRITE_TEXT_ALIGNMENT_LEADING, 0);
            /* The popup's disclosure chevron, pointing down. */
            if (glyph) {
                float cx = r.x + r.w - px(11.0, s);
                float cy = r.y + r.h * 0.5f;
                float a = px(3.0, s);
                float lw = spdf_win_chrome_stroke_px(1.4f, s);
                ctx.target->DrawLine(D2D1::Point2F(cx - a, cy - a * 0.5f), D2D1::Point2F(cx, cy + a * 0.5f), glyph, lw,
                                     NULL);
                ctx.target->DrawLine(D2D1::Point2F(cx, cy + a * 0.5f), D2D1::Point2F(cx + a, cy - a * 0.5f), glyph, lw,
                                     NULL);
            }
        }
    }

    /* 9. Zoom pill: minus / plus. */
    {
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_ZOOM_PILL];
        draw_pill(ctx, r, 2, dim);
        draw_plus_minus(ctx, cell_of(r, 0, 2), 0, glyph);
        draw_plus_minus(ctx, cell_of(r, 1, 2), 1, glyph);
    }

    /* 10. The Markdown text-size pill: A− / A＋, and only on a Markdown tab --
     * the layout leaves its rect empty otherwise, so a PDF row is the row it
     * always was. LETTERS rather than the zoom pill's plus and minus, because
     * this changes the em MuPDF lays the document out at and not the scale the
     * page is drawn at, and macOS says so the same way (item 10 is a titled
     * segmented control where item 9 is an icon one). The glyphs are U+2212
     * MINUS SIGN and U+FF0B FULLWIDTH PLUS SIGN, which sit on the same optical
     * line as the A rather than the hyphen's and ASCII plus's lower, shorter
     * bars. Each half is centred in the cell the router splits with. */
    {
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_MD_TEXT_PILL];
        draw_pill(ctx, r, 2, dim);
        if (!spdf_win_chrome_rect_empty(r)) {
            spdf_win_chrome_draw_text(ctx, L"A−", cell_of(r, 0, 2), spdf_win_chrome_dim(th->label, live), px(12.0, s),
                                      DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_CENTER, 0);
            spdf_win_chrome_draw_text(ctx, L"A＋", cell_of(r, 1, 2), spdf_win_chrome_dim(th->label, live), px(12.0, s),
                                      DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_CENTER, 0);
        }
    }

    /* 11. Reading-theme button: a SINGLE-segment pill, 32 wide -- deliberately
     * the same object as half of a pair. moon.stars in light, sun.max in dark,
     * following model->dark.
     *
     * FULL CONTRAST EVEN ON AN EMPTY WINDOW, and it earns it: macOS does not
     * disable this one (it is absent from -updateControls's list) because the
     * reading theme is a setting, and chrome_toggle_theme() now flips it with no
     * canvas to rebuild. The glyph brush is set back to 1.0 for the two live
     * controls and left there -- nothing after them is dimmed. */
    if (glyph) glyph->SetOpacity(1.0f);
    {
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_READING_THEME];
        draw_pill(ctx, r, 1);
        if (glyph && !spdf_win_chrome_rect_empty(r)) {
            float cx = r.x + r.w * 0.5f, cy = r.y + r.h * 0.5f;
            float rad = px(5.0, s);
            float lw = spdf_win_chrome_stroke_px(1.4f, s);
            D2D1_ELLIPSE e;
            e.point.x = cx;
            e.point.y = cy;
            e.radiusX = rad;
            e.radiusY = rad;
            ctx.target->DrawEllipse(e, glyph, lw, NULL);
            if (m->dark) {
                /* sun: four short rays */
                float o = rad + px(3.0, s);
                ctx.target->DrawLine(D2D1::Point2F(cx - o, cy), D2D1::Point2F(cx - rad - px(1.0, s), cy), glyph, lw,
                                     NULL);
                ctx.target->DrawLine(D2D1::Point2F(cx + rad + px(1.0, s), cy), D2D1::Point2F(cx + o, cy), glyph, lw,
                                     NULL);
                ctx.target->DrawLine(D2D1::Point2F(cx, cy - o), D2D1::Point2F(cx, cy - rad - px(1.0, s)), glyph, lw,
                                     NULL);
                ctx.target->DrawLine(D2D1::Point2F(cx, cy + rad + px(1.0, s)), D2D1::Point2F(cx, cy + o), glyph, lw,
                                     NULL);
            } else {
                /* moon: bite the circle with a control-coloured disc */
                ID2D1SolidColorBrush* band2 = spdf_win_chrome_brush(ctx.target, th->control_fill);
                if (band2) {
                    D2D1_ELLIPSE bite;
                    bite.point.x = cx + rad * 0.55f;
                    bite.point.y = cy - rad * 0.45f;
                    bite.radiusX = rad * 0.95f;
                    bite.radiusY = rad * 0.95f;
                    ctx.target->FillEllipse(bite, band2);
                    band2->Release();
                }
            }
        }
    }

    /* 18. Minimap toggle, from the trailing edge. 17. Overflow next to it.
     *
     * The Map switch goes with the document (:10236), and so does the strip:
     * -setMinimapActuallyVisible: is `visible && hasActiveDocument` (:9137), so
     * an empty window has no strip for the switch to show. An accent-filled
     * switch on an empty window was the loudest false promise in the row. */
    draw_toggle(ctx, tb.item[SPDF_WIN_TB_MINIMAP_TOGGLE], L"Map", m->show_minimap, live);
    {
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_OVERFLOW];
        draw_pill(ctx, r, 1);
        if (glyph && !spdf_win_chrome_rect_empty(r)) {
            float d = px(3.0, s);
            float gap = px(3.0, s);
            float total = 3.0f * d + 2.0f * gap;
            float gx = r.x + (r.w - total) * 0.5f;
            float gy = r.y + (r.h - d) * 0.5f;
            int i;
            for (i = 0; i < 3; ++i) {
                D2D1_ELLIPSE e;
                e.point.x = gx + (float)i * (d + gap) + d * 0.5f;
                e.point.y = gy + d * 0.5f;
                e.radiusX = d * 0.5f;
                e.radiusY = d * 0.5f;
                ctx.target->FillEllipse(e, glyph);
            }
        }
    }

    if (glyph) glyph->Release();

    /* 12-15. The find group -- search field, regex checkbox, counter and the
     * prev/next pill -- in spdf_win_chrome_find.cpp, which owns the whole
     * feature's drawing. Called from here rather than from paint_all so the row
     * is still one walk of one layout table; every rect it uses comes out of
     * `tb`, so the router hit-tests exactly what it drew. Each of those rects is
     * empty when the row was too narrow to hold that control, and the find
     * painter bails on an empty rect like every helper above. */
    spdf_win_chrome_paint_find(ctx, tb);

    /* Hairline under the toolbar: the boundary between chrome and document. */
    {
        ID2D1SolidColorBrush* sep = spdf_win_chrome_brush(ctx.target, th->separator);
        if (sep) {
            float hw = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
            ctx.target->FillRectangle(D2D1::RectF(bar.x, bar.y + bar.h - hw, bar.x + bar.w, bar.y + bar.h), sep);
            sep->Release();
        }
    }
}
