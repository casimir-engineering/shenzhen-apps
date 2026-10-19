/* Internal split of the panels painter.
 *
 * spdf_win_chrome_paint.h declares ONE entry point for the panels region,
 * spdf_win_chrome_paint_panels(). The sidebar's chapter list and the minimap's
 * thumbnail strip are each substantial enough that keeping them in one
 * translation unit put it past the repo's 500-line cap, so the region is split
 * three ways -- dispatcher, sidebar, minimap -- with this header as the seam.
 * Extraction, not a raised cap (tools/file-size-limits.md).
 *
 * Both painters take their CONTENT as an explicit argument. The dispatcher
 * resolves the provider once per frame (spdf_win_chrome_content.h) and hands
 * each half its own half, so no drawing function reads content from ambient
 * state, and a test can drive either painter with a hand-built content struct
 * and no document at all. NULL content is legal and means "nothing loaded":
 * both painters then draw the empty state rather than nothing.
 *
 * Nothing here may require an HWND -- spdf_win_chrome_paint.h's rule, and the
 * reason the whole chrome is pixel-testable offscreen.
 */
#ifndef SPDF_WIN_CHROME_PANELS_H
#define SPDF_WIN_CHROME_PANELS_H

#include "spdf_win_chrome_content.h"
#include "spdf_win_chrome_paint.h"

/* Sidebar: panel fill, the Chapters/Comments/Search segmented control, the
 * filter field, and the chapter rows (or the empty state). */
void spdf_win_chrome_paint_sidebar(const SpdfWinChromePaintCtx& ctx, const SpdfWinSidebarContent* content);

/* Minimap: panel fill, the leading separator, the page strip with thumbnails or
 * placeholders, the current-page outline and the viewport rectangle. */
void spdf_win_chrome_paint_minimap(const SpdfWinChromePaintCtx& ctx, const SpdfWinMinimapContent* content);

/* Shared with the dispatcher: a rounded rect, filled and/or stroked, with the
 * stroke inset so its centreline lands on the pixel grid. Same helper the tab
 * strip and toolbar have privately; declared here rather than copied a fourth
 * time now that three files in this region need it. */
void spdf_win_chrome_panel_fill_rounded(ID2D1RenderTarget* target, SpdfWinChromeRect r, float radius,
                                        ID2D1Brush* fill, ID2D1Brush* stroke, float stroke_w);

#endif /* SPDF_WIN_CHROME_PANELS_H */
