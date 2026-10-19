/* The two scrollers, painted.
 *
 * WHAT THE WINDOW WAS MISSING. Every other piece of Windows chrome that landed
 * before this was cosmetic parity -- the strip looked like macOS's strip, the
 * toolbar like macOS's toolbar. A scrollbar is not cosmetic: without one a long
 * document gives the reader no idea where in it they are, and no way to get
 * somewhere else in one gesture. macOS shows native scrollers on BOTH scroll
 * views with `autohidesScrollers = NO` (ShenzhenPDFMac.mm:3225-3227), so its
 * trough is always there, always saying "you are a fifth of the way down", and it
 * doubles as the surface the search heat-map is drawn on.
 *
 * WHAT IS macOS'S AND WHAT IS WINDOWS'. The thumb's POSITION and LENGTH are
 * macOS's arithmetic, and so is every number in the heat-map
 * (SPDFMacUIHelpers.mm:453-479, transcribed in spdf_win_chrome_scroll.h). The
 * LOOK is Windows 11's: a quiet trough with a thin rounded pill on it, rather
 * than AppKit's near-full-width knob. spdf_win_chrome_theme.h's header already
 * sets that policy for chrome -- keep the relationships, use native values.
 *
 * NO HWND, as spdf_win_chrome_paint.h requires: everything here draws into an
 * ID2D1RenderTarget, so `--render-window-png --chrome` composes the scrollers
 * offscreen and they are pixel-testable like the rest of the window.
 *
 * THE GEOMETRY IS NOT HERE. It is in spdf_win_chrome_scroll.h, because the input
 * router needs precisely the same rects and the only defence against a thumb you
 * cannot grab is that both callers ask the same function.
 */
#include "spdf_win_chrome_paint.h"

#include "spdf_win_chrome_scroll.h"

namespace {

/* The ambient hover/press state. See the long note at
 * spdf_win_chrome_scroll_set_hot() in spdf_win_chrome_paint.h for why this is a
 * global rather than a ctx or model field. Zero means "nothing hovered", which
 * is the state every headless compose is in. */
int g_hot_bar = SPDF_WIN_CHROME_NONE;
int g_hot_part = SPDF_WIN_SCROLL_NONE;
int g_hot_pressed = 0;

void fill(ID2D1RenderTarget* target, SpdfWinChromeRect r, SpdfWinChromeColor c) {
    ID2D1SolidColorBrush* brush;
    if (spdf_win_chrome_rect_empty(r)) return;
    brush = spdf_win_chrome_brush(target, c);
    if (!brush) return;
    target->FillRectangle(spdf_win_chrome_d2d_rect(r), brush);
    brush->Release();
}

void fill_pill(ID2D1RenderTarget* target, SpdfWinChromeRect r, float radius, SpdfWinChromeColor c) {
    D2D1_ROUNDED_RECT rr;
    ID2D1SolidColorBrush* brush;
    if (spdf_win_chrome_rect_empty(r)) return;
    brush = spdf_win_chrome_brush(target, c);
    if (!brush) return;
    /* Never a radius larger than half the short side: D2D would clamp it
     * silently, but at 100% the vertical thumb is 7 px wide and a 3 px radius is
     * already the whole of it. */
    if (radius > r.w * 0.5f) radius = r.w * 0.5f;
    if (radius > r.h * 0.5f) radius = r.h * 0.5f;
    rr.rect = spdf_win_chrome_d2d_rect(r);
    rr.radiusX = radius;
    rr.radiusY = radius;
    target->FillRoundedRectangle(rr, brush);
    brush->Release();
}

/* Which thumb colour this scroller's thumb wants right now. Three states, and
 * the hover one only lights the scroller the pointer is actually over -- the
 * ambient state carries WHICH bar for exactly that reason. */
SpdfWinChromeColor thumb_color(const SpdfWinChromeTheme* th, int bar) {
    if (g_hot_bar != bar || g_hot_part != SPDF_WIN_SCROLL_THUMB) return th->scroll_thumb;
    return g_hot_pressed ? th->scroll_thumb_pressed : th->scroll_thumb_hot;
}

/* The search heat-map, on the vertical trough only -- which is where macOS puts
 * it (SPDFFindMarkerScroller is the vertical scroller of both its scroll views).
 *
 * The marks arrive already sorted and deduplicated by the search layer
 * (spdf_win_chrome_state.h says so), so this walks them once, in order, and
 * applies macOS's one remaining rule: a marker closer than 1.5 pt to the last
 * one KEPT is dropped rather than drawn over it. The active match is drawn LAST
 * and is never dropped, because it is the one the reader is looking for and a
 * cluster of ordinary matches must not be able to hide it. */
void draw_marks(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect track) {
    const SpdfWinChromeModel* m = ctx.model;
    float s = ctx.dpi_scale > 0.0f ? ctx.dpi_scale : 1.0f;
    float prev_y = -1.0f;
    int i;

    if (!m->marks || m->mark_count <= 0 || spdf_win_chrome_rect_empty(track)) return;
    for (i = 0; i < m->mark_count; ++i) {
        SpdfWinChromeRect r;
        if (i == m->active_mark) continue; /* drawn below, on top */
        r = spdf_win_scroll_marker_rect(track, m->marks[i], 0, s);
        if (!spdf_win_scroll_marker_keep(r.y, prev_y, s)) continue;
        prev_y = r.y;
        fill(ctx.target, r, ctx.theme->find_mark);
    }
    if (m->active_mark >= 0 && m->active_mark < m->mark_count)
        fill(ctx.target, spdf_win_scroll_marker_rect(track, m->marks[m->active_mark], 1, s),
             ctx.theme->find_mark_active);
}

/* One scroller. Both axes go through here so neither can quietly acquire a
 * behaviour the other lacks. */
void draw_scroller(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect bar, int bar_part, float pos, float visible,
                   int axis) {
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale > 0.0f ? ctx.dpi_scale : 1.0f;
    SpdfWinChromeRect track, thumb;

    if (spdf_win_chrome_rect_empty(bar)) return;

    fill(ctx.target, bar, th->scroll_trough);

    /* A hairline on the DOCUMENT-facing edge, so the trough has a visible
     * boundary against the gutter instead of floating. Vertical scroller: its
     * left edge. Horizontal: its top. */
    {
        float hw = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
        SpdfWinChromeRect line = bar;
        if (axis == SPDF_WIN_SCROLL_H) line.h = hw;
        else line.w = hw;
        fill(ctx.target, line, th->separator);
    }

    track = spdf_win_scroll_track(bar, s, axis);
    if (spdf_win_chrome_rect_empty(track)) return;

    /* Marks UNDER the thumb: a match the reader has scrolled to is exactly the
     * one the thumb is sitting on, and hiding the thumb behind the heat-map would
     * lose the position indicator the trough exists to be. */
    if (axis == SPDF_WIN_SCROLL_V) draw_marks(ctx, track);

    thumb = spdf_win_scroll_thumb(track, pos, visible, spdf_win_scroll_thumb_min(s), axis);
    fill_pill(ctx.target, spdf_win_scroll_thumb_visual(thumb, s, axis),
              spdf_win_chrome_px(SPDF_WIN_SCROLL_THUMB_RADIUS, s), thumb_color(th, bar_part));
}

} /* namespace */

void spdf_win_chrome_scroll_set_hot(int bar, int part, int pressed) {
    if (bar != SPDF_WIN_CHROME_VSCROLL && bar != SPDF_WIN_CHROME_HSCROLL) {
        g_hot_bar = SPDF_WIN_CHROME_NONE;
        g_hot_part = SPDF_WIN_SCROLL_NONE;
        g_hot_pressed = 0;
        return;
    }
    g_hot_bar = bar;
    g_hot_part = part;
    g_hot_pressed = pressed ? 1 : 0;
}

void spdf_win_chrome_scroll_hot(int* bar, int* part, int* pressed) {
    if (bar) *bar = g_hot_bar;
    if (part) *part = g_hot_part;
    if (pressed) *pressed = g_hot_pressed;
}

void spdf_win_chrome_paint_scrollers(const SpdfWinChromePaintCtx& ctx) {
    const SpdfWinChromeLayout* l = ctx.layout;
    const SpdfWinChromeModel* m = ctx.model;

    if (!l || !m || !ctx.theme || !ctx.target) return;
    draw_scroller(ctx, l->vscroll, SPDF_WIN_CHROME_VSCROLL, m->v_pos, m->v_visible, SPDF_WIN_SCROLL_V);
    draw_scroller(ctx, l->hscroll, SPDF_WIN_CHROME_HSCROLL, m->h_pos, m->h_visible, SPDF_WIN_SCROLL_H);

    /* THE CORNER. The vertical trough stops where the horizontal one begins and
     * the horizontal one is only as wide as the canvas, so with both showing
     * there is a scrollbar-square hole between them -- and the ground behind it
     * is the document gutter, which reads as a notch bitten out of the window's
     * bottom-right corner. macOS fills it with a corner view; this fills it with
     * the trough colour and leaves the layout header alone, deriving the rect
     * from the two rects that bound it rather than re-deriving the metric. */
    if (!spdf_win_chrome_rect_empty(l->vscroll) && !spdf_win_chrome_rect_empty(l->hscroll)) {
        SpdfWinChromeRect corner;
        corner.x = l->hscroll.x + l->hscroll.w;
        corner.y = l->vscroll.y + l->vscroll.h;
        corner.w = (l->vscroll.x + l->vscroll.w) - corner.x;
        corner.h = (l->hscroll.y + l->hscroll.h) - corner.y;
        fill(ctx.target, corner, ctx.theme->scroll_trough);
    }
}
