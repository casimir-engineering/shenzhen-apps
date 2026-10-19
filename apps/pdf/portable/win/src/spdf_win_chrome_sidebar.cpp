/* The sidebar: the Chapters/Comments/Search segmented control, the filter
 * field, the document's real chapter list, and the Search section's results.
 *
 * macOS (ShenzhenPDFMac.mm) -- every number below is cited, and the ones that
 * are not literals there are marked as such:
 *
 *   - Segmented control of Chapters (0), Comments (1) and Search (2), Search
 *     present only while a query is live (:3138-3144, :9603-9615), segment
 *     widths normalised to floor(max(minSeg, (sidebarWidth - 16) / segments))
 *     with minSeg 66.0 for three segments and 78.0 for two
 *     (spdf_win_sidebar_sections_rect, shared with the input router).
 *   - Filter field, "Filter Chapters" / "Filter Comments", hidden and disabled
 *     in Search mode (:3149-3157, :9641).
 *   - A headerless SPDFSidebarTableView, rowHeight 25.0, one column 230.0 wide
 *     (:3149-3213). The row view is SPDFMacSidebarChapters.mm's (a5820117a):
 *     a 14 pt disclosure chevron -- pointing down when open, right when
 *     collapsed, 9 pt semibold in the secondary tint, HIDDEN but keeping its
 *     width on a childless row -- whose leading edge is 6 + level*13 pt, then
 *     the title 2 pt after it, inset 6 trailing, vertically centred,
 *     systemFontOfSize:13, single line, truncating TAIL. The geometry is
 *     spdf_win_sidebar_rows.h's, shared with the press resolution.
 *   - ONE EXPAND / COLLAPSE BUTTON at the trailing end of the filter field's
 *     row (0a1f0845c), 22 pt wide, 4 pt from the field, icon only, secondary
 *     tint, bezel shown only under the pointer (so none here): arrows drawing
 *     in while anything is expanded ("Collapse All"), arrows opening out once
 *     everything is collapsed ("Expand All"). Hidden -- and the field takes
 *     the width back -- when nothing nests: a flat outline, a live filter,
 *     Comments, search results.
 *   - A row whose destination did not resolve is secondaryLabelColor rather
 *     than labelColor (:16623). The core's outline suite has three such cases
 *     (a missing target, an external URL, a dest-less entry), so this is not a
 *     hypothetical branch.
 *   - Selection follows the current page: the FIRST row whose page equals the
 *     current one (:10613-10620).
 *   - Filtering ignores case AND diacritics (:9666-9670) -- see
 *     spdf_win_sidebar_title_matches.
 *   - THE SEARCH SECTION (:9506-9550, :15859-15871, :16151-16300): a status
 *     line while nothing is listed; a 30 pt capsule header whenever the chapter
 *     changes; a 46 pt row per match with the snippet at 12 pt medium (the
 *     query's first occurrence bold, as the GTK rows do) over "Page N - match I
 *     of M" at 11 pt secondary. The rows arrive built -- spdf_win_sidebar_view.h
 *     explains the side channel and why -- so this file only draws them.
 *
 * NO OUTLINE, AND WHAT macOS ACTUALLY DOES. rebuildSidebar (:9552-9580)
 * computes `hasSidebar = _doc && (hasChapters || hasComments || hasSearch)` and
 * ends with `[self setSidebarActuallyVisible:hasSidebar && _sidebarPreferredVisible]`.
 * So a document with no outline, no comments and no live search does not get an
 * empty list on macOS -- IT GETS NO SIDEBAR. The app decides that per paint
 * (spdf_win_sidebar_set_effective_visible) and the panel is not laid out at
 * all; the "No Chapters" line below is what a filter-less empty Chapters
 * section draws in the one state that still reaches it, a document whose only
 * content is a live search. A filter that excludes everything is a DIFFERENT
 * state and says so ("No matching chapters"), because on macOS the panel stays
 * visible then.
 */
#include "spdf_win_chrome_panels.h"
#include "spdf_win_sidebar_view.h"

#include <math.h>

/* --- the side channels (declared in spdf_win_sidebar_view.h) --------------- */

namespace {
const SpdfWinSidebarResultsView* g_results;
const SpdfWinSidebarResultsView* g_comments;
int g_section;
int g_effective_visible = 1;
} /* namespace */

void spdf_win_sidebar_results_publish(const SpdfWinSidebarResultsView* view) { g_results = view; }
const SpdfWinSidebarResultsView* spdf_win_sidebar_results_current(void) { return g_results; }
void spdf_win_sidebar_comments_publish(const SpdfWinSidebarResultsView* view) { g_comments = view; }
const SpdfWinSidebarResultsView* spdf_win_sidebar_comments_current(void) { return g_comments; }
void spdf_win_sidebar_set_section(int section) { g_section = section < 0 || section > 2 ? 0 : section; }
int spdf_win_sidebar_section(void) { return g_section; }
void spdf_win_sidebar_set_effective_visible(int visible) { g_effective_visible = visible ? 1 : 0; }
int spdf_win_sidebar_effective_visible(void) { return g_effective_visible; }

namespace {

float px(double points, float s) {
    return spdf_win_chrome_px(points, s);
}

/* The Chapters / Comments / Search segmented control, with macOS's own width
 * normalisation so the segments sit where they sit on the Mac. */
void draw_sections(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect bar, int segments, int selected) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
    ID2D1SolidColorBrush* fill = spdf_win_chrome_brush(ctx.target, th->control_fill);
    ID2D1SolidColorBrush* stroke = spdf_win_chrome_brush(ctx.target, th->control_stroke);
    ID2D1SolidColorBrush* sel = spdf_win_chrome_brush(ctx.target, th->accent);
    const wchar_t* titles[3] = {L"Chapters", L"Comments", L"Search"};
    int i;

    spdf_win_chrome_panel_fill_rounded(ctx.target, bar, px(4.0, s), fill, stroke, hair);

    for (i = 0; i < segments; ++i) {
        SpdfWinChromeRect cell = bar;
        cell.w = bar.w / (float)segments;
        cell.x = bar.x + cell.w * (float)i;
        if (i == selected && sel) {
            D2D1_ROUNDED_RECT rr;
            rr.rect = spdf_win_chrome_d2d_rect(cell);
            rr.radiusX = px(4.0, s);
            rr.radiusY = px(4.0, s);
            ctx.target->FillRoundedRectangle(rr, sel);
        }
        spdf_win_chrome_draw_text(ctx, titles[i], cell,
                                  (i == selected) ? spdf_win_ct_rgb(0xFFFFFFu, 1.0f) : th->label_secondary,
                                  px(SPDF_WIN_CT_FONT_SIZE_LABEL, s), DWRITE_FONT_WEIGHT_NORMAL,
                                  DWRITE_TEXT_ALIGNMENT_CENTER, 0);
        if (i > 0 && stroke && i != selected && (i - 1) != selected) {
            float x = floorf(cell.x) + 0.5f * hair;
            ctx.target->DrawLine(D2D1::Point2F(x, cell.y + hair), D2D1::Point2F(x, cell.y + cell.h - hair), stroke,
                                 hair, NULL);
        }
    }

    if (fill) fill->Release();
    if (stroke) stroke->Release();
    if (sel) sel->Release();
}

void draw_filter_field(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect f, int section, const wchar_t* text) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
    ID2D1SolidColorBrush* fill = spdf_win_chrome_brush(ctx.target, th->field_fill);
    ID2D1SolidColorBrush* stroke = spdf_win_chrome_brush(ctx.target, th->field_stroke);
    int live = text && text[0];

    spdf_win_chrome_panel_fill_rounded(ctx.target, f, px(4.0, s), fill, stroke, hair);
    if (fill) fill->Release();
    if (stroke) stroke->Release();

    {
        SpdfWinChromeRect t = f;
        t.x += px(22.0, s);
        t.w -= px(28.0, s);
        spdf_win_chrome_draw_text(ctx, live ? text : (section == 1 ? L"Filter Comments" : L"Filter Chapters"), t,
                                  live ? th->label : th->field_placeholder, px(SPDF_WIN_CT_FONT_SIZE_LABEL, s),
                                  DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING, 0);
    }
    /* The search field's magnifier: a circle and a tail. */
    {
        ID2D1SolidColorBrush* g = spdf_win_chrome_brush(ctx.target, live ? th->label : th->field_placeholder);
        if (g) {
            float cx = f.x + px(12.0, s), cy = f.y + f.h * 0.5f;
            float rad = px(4.0, s);
            float lw = spdf_win_chrome_stroke_px(1.3f, s);
            D2D1_ELLIPSE e;
            e.point.x = cx;
            e.point.y = cy - px(1.0, s);
            e.radiusX = rad;
            e.radiusY = rad;
            ctx.target->DrawEllipse(e, g, lw, NULL);
            ctx.target->DrawLine(D2D1::Point2F(cx + rad * 0.7f, cy + rad * 0.7f - px(1.0, s)),
                                 D2D1::Point2F(cx + rad * 1.6f, cy + rad * 1.6f - px(1.0, s)), g, lw, NULL);
            g->Release();
        }
    }
}

/* The disclosure chevron: SF Symbols chevron.right / chevron.down at 9 pt
 * semibold, drawn as two strokes so it stays crisp at any DPI. Centred in the
 * 14 pt slot; half-extent 3 pt, which is what a 9 pt chevron glyph measures. */
void draw_disclosure(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect slot, int collapsed, ID2D1Brush* brush) {
    float s = ctx.dpi_scale;
    float cx = slot.x + slot.w * 0.5f;
    float cy = slot.y + slot.h * 0.5f;
    float a = px(3.0, s);
    float lw = spdf_win_chrome_stroke_px(1.5f, s);
    if (!brush || spdf_win_chrome_rect_empty(slot)) return;
    if (collapsed) {
        /* Pointing right: the section is folded away. */
        ctx.target->DrawLine(D2D1::Point2F(cx - a * 0.5f, cy - a), D2D1::Point2F(cx + a * 0.5f, cy), brush, lw, NULL);
        ctx.target->DrawLine(D2D1::Point2F(cx + a * 0.5f, cy), D2D1::Point2F(cx - a * 0.5f, cy + a), brush, lw, NULL);
    } else {
        /* Pointing down: open. */
        ctx.target->DrawLine(D2D1::Point2F(cx - a, cy - a * 0.5f), D2D1::Point2F(cx, cy + a * 0.5f), brush, lw, NULL);
        ctx.target->DrawLine(D2D1::Point2F(cx, cy + a * 0.5f), D2D1::Point2F(cx + a, cy - a * 0.5f), brush, lw, NULL);
    }
}

/* One diagonal arrow from `from` to `to` with its head at `to`: a shaft and two
 * 2.5 pt barbs at 45 degrees to it. */
void draw_arrow(const SpdfWinChromePaintCtx& ctx, D2D1_POINT_2F from, D2D1_POINT_2F to, ID2D1Brush* brush, float s) {
    float lw = spdf_win_chrome_stroke_px(1.5f, s);
    float dx = to.x - from.x, dy = to.y - from.y;
    float len = sqrtf(dx * dx + dy * dy);
    float ux, uy, barb;
    if (len <= 0.0f) return;
    ux = dx / len;
    uy = dy / len;
    barb = px(2.5, s);
    ctx.target->DrawLine(from, to, brush, lw, NULL);
    /* The barbs run back from the tip along the axes, which for a diagonal
     * shaft are the two directions 45 degrees off it -- the SF Symbol's shape. */
    ctx.target->DrawLine(to, D2D1::Point2F(to.x - ux * barb * 1.41421f, to.y), brush, lw, NULL);
    ctx.target->DrawLine(to, D2D1::Point2F(to.x, to.y - uy * barb * 1.41421f), brush, lw, NULL);
}

/* The expand / collapse button's glyph: arrow.down.right.and.arrow.up.left
 * while it collapses (two arrows drawing IN toward the centre from the
 * top-left and bottom-right), arrow.up.left.and.arrow.down.right once it
 * expands (the same two arrows pointing OUT). 10 pt medium on the mac; the
 * glyph box here is 10 pt centred in the 22 pt slot. */
void draw_toggle(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect slot, int collapses, SpdfWinChromeColor color) {
    float s = ctx.dpi_scale;
    float cx = slot.x + slot.w * 0.5f;
    float cy = slot.y + slot.h * 0.5f;
    float outer = px(5.0, s);
    float inner = px(1.0, s);
    ID2D1SolidColorBrush* brush;
    if (spdf_win_chrome_rect_empty(slot)) return;
    brush = spdf_win_chrome_brush(ctx.target, color);
    if (!brush) return;
    if (collapses) {
        draw_arrow(ctx, D2D1::Point2F(cx - outer, cy - outer), D2D1::Point2F(cx - inner, cy - inner), brush, s);
        draw_arrow(ctx, D2D1::Point2F(cx + outer, cy + outer), D2D1::Point2F(cx + inner, cy + inner), brush, s);
    } else {
        draw_arrow(ctx, D2D1::Point2F(cx - inner, cy - inner), D2D1::Point2F(cx - outer, cy - outer), brush, s);
        draw_arrow(ctx, D2D1::Point2F(cx + inner, cy + inner), D2D1::Point2F(cx + outer, cy + outer), brush, s);
    }
    brush->Release();
}

void draw_empty_state(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect list, const wchar_t* line) {
    SpdfWinChromeRect r = list;
    float s = ctx.dpi_scale;
    if (spdf_win_chrome_rect_empty(r)) return;
    r.y += px(12.0, s);
    r.h = px(SPDF_WIN_SIDEBAR_ROW_H, s);
    spdf_win_chrome_draw_text(ctx, line, r, ctx.theme->label_secondary, px(SPDF_WIN_CT_FONT_SIZE_LABEL, s),
                              DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_CENTER, 0);
}

/* The rows. Only the ones that intersect the list viewport are laid out at all,
 * so a 4000-entry outline costs the same per frame as a 20-entry one -- the
 * standing speed rule applied to the one place in this panel that could scale
 * with document size. */
void draw_rows(const SpdfWinChromePaintCtx& ctx, const SpdfWinSidebarLayout& l, const SpdfWinSidebarContent* c) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    int first, last, i;
    ID2D1SolidColorBrush* sel = NULL;
    ID2D1SolidColorBrush* hot = NULL;
    ID2D1SolidColorBrush* chevron = NULL;

    if (l.row_h <= 0.0f || c->row_count <= 0) return;
    first = (int)floorf(c->scroll_y / l.row_h);
    last = (int)ceilf((c->scroll_y + l.list.h) / l.row_h);
    if (first < 0) first = 0;
    if (last > c->row_count - 1) last = c->row_count - 1;

    ctx.target->PushAxisAlignedClip(spdf_win_chrome_d2d_rect(l.list), D2D1_ANTIALIAS_MODE_ALIASED);
    sel = spdf_win_chrome_brush(ctx.target, th->row_selected_fill);
    hot = spdf_win_chrome_brush(ctx.target, th->row_hot_fill);
    chevron = spdf_win_chrome_brush(ctx.target, th->label_secondary);
    for (i = first; i <= last; ++i) {
        SpdfWinChromeRect row = spdf_win_sidebar_row_rect(&l, c->scroll_y, i);
        if (i == c->selected_row && sel)
            ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(row), sel);
        else if (i == c->hot_row && hot)
            ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(row), hot);
        /* The chevron's slot is the indent; a childless row keeps the slot
         * empty so titles at one depth align (spdf_win_sidebar_rows.h). */
        if (c->rows[i].has_children)
            draw_disclosure(ctx, spdf_win_sidebar_disclosure_rect(row, c->rows[i].level, s), c->rows[i].collapsed,
                            chevron);
        spdf_win_chrome_draw_text(ctx, c->rows[i].title, spdf_win_sidebar_title_rect(row, c->rows[i].level, s),
                                  c->rows[i].page_index >= 0 ? th->label : th->label_secondary,
                                  px(SPDF_WIN_SIDEBAR_FONT_SIZE, s), DWRITE_FONT_WEIGHT_NORMAL,
                                  DWRITE_TEXT_ALIGNMENT_LEADING, 0);
    }
    if (sel) sel->Release();
    if (hot) hot->Release();
    if (chevron) chevron->Release();
    ctx.target->PopAxisAlignedClip();
}

/* One line of text with a BOLD RANGE -- the query inside a snippet. The shared
 * helper draws a whole string at one weight, and a range needs the layout in
 * hand (IDWriteTextLayout::SetFontWeight), so this builds it here from the same
 * cached format. Trimmed with an ellipsis at the end, as the macOS cell
 * (NSLineBreakByTruncatingTail). */
void draw_snippet(const SpdfWinChromePaintCtx& ctx, const wchar_t* text, SpdfWinChromeRect rect,
                  SpdfWinChromeColor color, float size_px, int bold_start, int bold_len) {
    IDWriteTextFormat* format;
    ID2D1SolidColorBrush* brush;
    IDWriteTextLayout* layout = NULL;
    UINT32 len;

    if (!text || !text[0] || spdf_win_chrome_rect_empty(rect)) return;
    format = spdf_win_chrome_text_format(ctx.dwrite, size_px, DWRITE_FONT_WEIGHT_MEDIUM);
    if (!format) return;
    brush = spdf_win_chrome_brush(ctx.target, color);
    if (!brush) return;
    format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    len = (UINT32)wcslen(text);
    if (SUCCEEDED(ctx.dwrite->CreateTextLayout(text, len, format, rect.w, rect.h, &layout))) {
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
        if (bold_start >= 0 && bold_len > 0 && (UINT32)bold_start < len) {
            DWRITE_TEXT_RANGE range;
            range.startPosition = (UINT32)bold_start;
            range.length = (UINT32)bold_start + (UINT32)bold_len > len ? len - (UINT32)bold_start : (UINT32)bold_len;
            layout->SetFontWeight(DWRITE_FONT_WEIGHT_BOLD, range);
        }
        ctx.target->DrawTextLayout(D2D1::Point2F(rect.x, rect.y), layout, brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
        layout->Release();
    }
    brush->Release();
}

/* The Search section: the published rows, variable heights, clipped to the
 * list, only the visible ones drawn. */
void draw_results(const SpdfWinChromePaintCtx& ctx, const SpdfWinSidebarLayout& l,
                  const SpdfWinSidebarResultsView* v) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale;
    float y = l.list.y - v->scroll_y;
    ID2D1SolidColorBrush* sel = spdf_win_chrome_brush(ctx.target, th->row_selected_fill);
    ID2D1SolidColorBrush* capsule = spdf_win_chrome_brush(ctx.target, th->control_fill);
    ID2D1SolidColorBrush* line = spdf_win_chrome_brush(ctx.target, th->separator);
    int i;

    ctx.target->PushAxisAlignedClip(spdf_win_chrome_d2d_rect(l.list), D2D1_ANTIALIAS_MODE_ALIASED);
    for (i = 0; i < v->row_count; ++i) {
        const SpdfWinSidebarResultRow* row = &v->rows[i];
        float h = spdf_win_sidebar_result_row_h(row->kind, s);
        SpdfWinChromeRect r;
        r.x = l.list.x;
        r.y = y;
        r.w = l.list.w;
        r.h = h;
        y += h;
        if (r.y + r.h < l.list.y || r.y > l.list.y + l.list.h) continue; /* off the list: not laid out */

        if (row->kind == SPDF_WIN_SIDEBAR_RESULT_STATUS) {
            SpdfWinChromeRect t = r;
            t.x += px(8.0, s);
            t.w -= px(16.0, s);
            spdf_win_chrome_draw_text(ctx, row->title, t, th->label_secondary,
                                      px(SPDF_WIN_SIDEBAR_RESULT_STATUS_FONT, s), DWRITE_FONT_WEIGHT_NORMAL,
                                      DWRITE_TEXT_ALIGNMENT_CENTER, 0);
            continue;
        }
        if (row->kind == SPDF_WIN_SIDEBAR_RESULT_HEADER) {
            /* :16151-16200: a capsule (cornerRadius 8) around the title, a
             * hairline after it to the trailing inset. */
            SpdfWinChromeRect cap = r;
            SpdfWinChromeRect t;
            cap.y += px(7.0, s);
            cap.h = px(16.0, s);
            cap.w = spdf_win_chrome_max(0.0f, r.w - px(SPDF_WIN_SIDEBAR_RESULT_TRAILING, s));
            spdf_win_chrome_panel_fill_rounded(ctx.target, cap, px(8.0, s), capsule, NULL, 0.0f);
            t = cap;
            t.x += px(8.0, s);
            t.w -= px(12.0, s);
            spdf_win_chrome_draw_text(ctx, row->title, t, th->label_secondary,
                                      px(SPDF_WIN_SIDEBAR_RESULT_HEADER_FONT, s), DWRITE_FONT_WEIGHT_MEDIUM,
                                      DWRITE_TEXT_ALIGNMENT_LEADING, 0);
            if (line) {
                float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
                float ly = floorf(r.y + r.h - px(2.0, s)) + 0.5f * hair;
                ctx.target->DrawLine(D2D1::Point2F(r.x, ly), D2D1::Point2F(r.x + cap.w, ly), line, hair, NULL);
            }
            continue;
        }
        /* A match. The current one is highlighted like a selected chapter row. */
        if (i == v->current_row && sel) ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(r), sel);
        {
            SpdfWinChromeRect title = r;
            SpdfWinChromeRect sub;
            title.x += px(SPDF_WIN_SIDEBAR_CELL_LEADING, s);
            title.w -= px(SPDF_WIN_SIDEBAR_CELL_LEADING, s) + px(SPDF_WIN_SIDEBAR_RESULT_TRAILING, s);
            title.y += px(SPDF_WIN_SIDEBAR_RESULT_TITLE_TOP, s);
            title.h = px(16.0, s);
            draw_snippet(ctx, row->title, title, th->label, px(SPDF_WIN_SIDEBAR_RESULT_TITLE_FONT, s),
                         row->bold_start, row->bold_len);
            sub = title;
            sub.y = title.y + title.h + px(SPDF_WIN_SIDEBAR_RESULT_SUBTITLE_GAP, s);
            sub.h = px(14.0, s);
            spdf_win_chrome_draw_text(ctx, row->subtitle, sub, th->label_secondary,
                                      px(SPDF_WIN_SIDEBAR_RESULT_SUBTITLE_FONT, s), DWRITE_FONT_WEIGHT_NORMAL,
                                      DWRITE_TEXT_ALIGNMENT_LEADING, 0);
        }
    }
    if (sel) sel->Release();
    if (capsule) capsule->Release();
    if (line) line->Release();
    ctx.target->PopAxisAlignedClip();
}

} /* namespace */

void spdf_win_chrome_paint_sidebar(const SpdfWinChromePaintCtx& ctx, const SpdfWinSidebarContent* content) {
    const SpdfWinChromeModel* m = ctx.model;
    SpdfWinChromeRect side = ctx.layout->sidebar;
    float s = ctx.dpi_scale > 0.0f ? ctx.dpi_scale : 1.0f;
    int segments = m->search_active ? 3 : 2;
    SpdfWinSidebarLayout l;
    ID2D1SolidColorBrush* panel;

    if (spdf_win_chrome_rect_empty(side)) return;
    panel = spdf_win_chrome_brush(ctx.target, ctx.theme->panel);
    if (panel) {
        ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(side), panel);
        panel->Release();
    }

    spdf_win_sidebar_layout(side, m->sidebar_section, s, &l);
    {
        SpdfWinChromeRect bar = spdf_win_sidebar_sections_rect(l.sections, side, segments, s);
        if (bar.w > 0.0f) draw_sections(ctx, bar, segments, m->sidebar_section);
    }
    if (!spdf_win_chrome_rect_empty(l.filter)) {
        /* The one expand / collapse button shares the field's row while the
         * list nests; the field stops short of it and takes the width back when
         * it goes away (see this file's header). */
        int nestable = m->sidebar_section == 0 && content && content->loaded && content->collapsible_count > 0 &&
                       !spdf_win_chrome_rect_empty(l.toggle);
        draw_filter_field(ctx, nestable ? spdf_win_sidebar_filter_beside_toggle(&l, s) : l.filter, m->sidebar_section,
                          content ? content->filter : NULL);
        if (nestable) draw_toggle(ctx, l.toggle, content->open_count > 0, ctx.theme->label_secondary);
    }

    /* Comments: the published rows -- a header per page, a row per comment,
     * built by spdf_win_annot.h from the comment cache -- through the Search
     * section's painter, so the two lists cannot look different. GTK's pane
     * shows "No comments in this document" as its placeholder; the two words
     * here match the Chapters section's own empty state beside it. */
    if (m->sidebar_section == 1) {
        const SpdfWinSidebarResultsView* v = spdf_win_sidebar_comments_current();
        if (v && v->rows && v->row_count > 0) draw_results(ctx, l, v);
        else draw_empty_state(ctx, l.list, L"No Comments");
        return;
    }
    if (m->sidebar_section == 2) {
        const SpdfWinSidebarResultsView* v = spdf_win_sidebar_results_current();
        if (v && v->rows && v->row_count > 0) draw_results(ctx, l, v);
        else draw_empty_state(ctx, l.list, L"No Results");
        return;
    }

    if (!content || !content->loaded) return; /* nothing known yet; never block */
    if (content->row_count > 0) {
        draw_rows(ctx, l, content);
        return;
    }
    /* The two empty states are genuinely different and macOS treats them
     * differently -- see this file's header. */
    draw_empty_state(ctx, l.list, content->total_count > 0 ? L"No matching chapters" : L"No Chapters");
}
