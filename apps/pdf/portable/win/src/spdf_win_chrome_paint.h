/* spdf_win_chrome_paint.h — drawing the Win32 chrome.
 *
 * SAME RULE AS spdf_win_d2d.h, AND FOR THE SAME REASON: nothing here may
 * require an HWND. Every function takes an ID2D1RenderTarget* and rects that
 * spdf_win_chrome.h computed, so the chrome is drawn identically by the window's
 * WM_PAINT and by the headless WIC target. That is not a style preference: the
 * live window's client area was measured byte-identical to the offscreen
 * compose path (portable/docs/windows-native-observations.md §0), so keeping
 * chrome inside that path is what makes chrome pixel-testable at all.
 *
 * Split into one translation unit per region -- strip, toolbar, panels -- so the
 * files stay small and so tracks working on different chrome do not collide.
 * They share the theme (spdf_win_chrome_theme.h), the geometry
 * (spdf_win_chrome.h, spdf_win_tabstrip.h) and the small brush/text helpers
 * declared at the bottom of this header.
 *
 * C++ only: these take ID2D1RenderTarget and IDWriteFactory by pointer and call
 * methods on them. Unlike spdf_win_d2d.h there is no C consumer to keep happy.
 */
#ifndef SPDF_WIN_CHROME_PAINT_H
#define SPDF_WIN_CHROME_PAINT_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>

#include "spdf_win_chrome.h"
#include "spdf_win_chrome_theme.h"
/* WHICH CONTROLS ARE LIVE, and the one disabled alpha they all share. Here
 * rather than in each region painter because the answer must be the same in all
 * of them and the same one the input router refuses by
 * (spdf_win_chrome_empty.h). */
#include "spdf_win_chrome_empty.h"

/* Everything a region painter is handed. One struct rather than eight
 * arguments, because each painter needs almost all of it and a positional list
 * that long is how a dpi_scale ends up where a font size belongs. */
struct SpdfWinChromePaintCtx {
    ID2D1RenderTarget* target;
    IDWriteFactory* dwrite;
    const SpdfWinChromeTheme* theme;
    const SpdfWinChromeModel* model;
    const SpdfWinChromeLayout* layout;
    float dpi_scale;
};

/* --- the regions. Each is a no-op when its rect is empty. ---------------- */

/* Tab strip: band fill, tabs, close boxes, read-only dots, + and overflow
 * buttons, and the hairline under the strip. */
void spdf_win_chrome_paint_tabstrip(const SpdfWinChromePaintCtx& ctx);

/* Toolbar: the control row. Owns portable/win/src/spdf_win_chrome_toolbar.cpp. */
void spdf_win_chrome_paint_toolbar(const SpdfWinChromePaintCtx& ctx);

/* Sidebar and minimap, plus the two split dividers.
 * Owns portable/win/src/spdf_win_chrome_panels.cpp. */
void spdf_win_chrome_paint_panels(const SpdfWinChromePaintCtx& ctx);

/* The two scrollers: trough, thumb, and the search heat-map on the vertical
 * one. Owns portable/win/src/spdf_win_chrome_scrollbar.cpp. Geometry comes from
 * spdf_win_chrome_scroll.h, which the input router uses too -- that shared
 * header is the only thing that keeps a click landing on the thumb that was
 * drawn. */
void spdf_win_chrome_paint_scrollers(const SpdfWinChromePaintCtx& ctx);

/* WHICH SCROLLER PART IS HOVERED OR HELD, as ambient state rather than as a
 * ctx field or a model field, and this seam deserves an explanation because it
 * is the one place the chrome reaches for a global.
 *
 * SpdfWinChromePaintCtx is assembled field by field in spdf_win_d2d.cpp and
 * SpdfWinChromeModel is filled by spdf_win_chrome_model.cpp; both belong to
 * other tracks, and a new field in either arrives UNINITIALISED at the existing
 * call site, which for a hover flag means a thumb that is randomly lit. So the
 * scroller's interaction state travels the same way the sidebar's and minimap's
 * CONTENT does -- spdf_win_chrome_content_set_document() next door -- as a
 * setter the input layer calls and the painter reads once at the top of its
 * frame. The state is deliberately tiny and deliberately DEFAULTS TO NOTHING
 * HOVERED, so every offscreen pixel test composes the same window it always did
 * without knowing this exists.
 *
 * `bar` is SPDF_WIN_CHROME_VSCROLL or _HSCROLL (anything else clears);
 * `part` is a spdf_win_scroll_part; `pressed` distinguishes a held thumb from a
 * hovered one. */
void spdf_win_chrome_scroll_set_hot(int bar, int part, int pressed);
void spdf_win_chrome_scroll_hot(int* bar, int* part, int* pressed);

/* Paints every region present in the layout, in back-to-front order. This is
 * what spdf_win_paint() calls; it does not begin or end a draw.
 *
 * The EMPTY canvas's "Open a PDF…" button and drop hint are drawn from inside
 * it and are deliberately NOT declared here: the drawing is a `static` function
 * in spdf_win_chrome_empty_paint.h, included by spdf_win_chrome_paint.cpp alone,
 * exactly as the toolbar's control helpers are. WHETHER and WHERE -- the part a
 * test or the input router needs -- is in spdf_win_chrome_empty.h, which is pure
 * and included above. */
void spdf_win_chrome_paint_all(const SpdfWinChromePaintCtx& ctx);

/* --- shared helpers, implemented in spdf_win_chrome_paint.cpp ------------ */

/* A solid brush for one theme colour. Returns NULL on failure and every caller
 * must tolerate that: a chrome element that cannot get a brush is skipped, and a
 * failed paint is never allowed to become a failed frame. */
ID2D1SolidColorBrush* spdf_win_chrome_brush(ID2D1RenderTarget* target, SpdfWinChromeColor c);

/* D2D1_RECT_F from a chrome rect, and the half-pixel-inset variant for a
 * stroked outline. The inset takes the stroke width so the centreline lands on
 * a device-pixel boundary -- and the width should already be whole pixels, for
 * the reason spdf_win_d2d.cpp's page border documents: a 1.5 px stroke at 150%
 * cannot land on the grid and blurs across two rows. */
D2D1_RECT_F spdf_win_chrome_d2d_rect(SpdfWinChromeRect r);
D2D1_RECT_F spdf_win_chrome_stroke_rect(SpdfWinChromeRect r, float stroke_w);

/* Whole device pixels for a stroke of `points` logical pixels, never below 1. */
float spdf_win_chrome_stroke_px(float points, float dpi_scale);

/* One reusable text format. Cached per (size, weight) inside the
 * implementation, because CreateTextFormat on every label of every frame is an
 * allocation on the paint path and architecture.md §9 requires paint to stay
 * O(1)-ish per event. Returns NULL if DirectWrite has no usable face, and a
 * caller then draws no text rather than failing. */
IDWriteTextFormat* spdf_win_chrome_text_format(IDWriteFactory* dwrite, float size_px, DWRITE_FONT_WEIGHT weight);

/* Draw a single line of text clipped to `rect`, with the given alignment.
 * `truncate_middle` reproduces the tab strip's middle ellipsis
 * (SPDFMacTabStripView.mm:565-604), which is what keeps the distinguishing end
 * of a long filename visible instead of trimming it away. */
void spdf_win_chrome_draw_text(const SpdfWinChromePaintCtx& ctx, const wchar_t* text, SpdfWinChromeRect rect,
                               SpdfWinChromeColor color, float size_px, DWRITE_FONT_WEIGHT weight,
                               DWRITE_TEXT_ALIGNMENT align, int truncate_middle);

/* Release the cached text formats. Called from spdf_win_d2d_destroy so the
 * process leaves no DirectWrite objects behind. */
void spdf_win_chrome_paint_shutdown(void);

#endif /* SPDF_WIN_CHROME_PAINT_H */
