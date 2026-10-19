/* spdf_win_search_map.h — what the MINIMAP painter records for the input layer,
 * and what the search layer hands the minimap painter: two side channels.
 *
 * THE FRAME. A click on the strip must land on the page that was DRAWN under
 * the pointer, so the input layer hit-tests the painter's own strip -- the same
 * cached SpdfWinMinimapStrip, the same content_top, the same panel rect -- and
 * never re-derives it from page sizes it might have a different copy of. That
 * is spdf_win_canvas_selection.cpp's argument for hit-testing `draws` rather
 * than the layout, applied to the minimap: "a hit test against it cannot
 * disagree with what was drawn". The painter records the frame at the end of
 * each paint; spdf_win_map_frame_current() reads it back. Before the first
 * paint, or with no document, it reports 0 and the input layer does nothing.
 *
 * THE MARKERS. The GTK4 minimap draws every search hit as a tick inside its
 * page's slot (spdf_minimap.c minimap_draw_search_markers, the same yellow and
 * hot-orange lanes as the scroller heat-map); macOS draws the highlight rects
 * themselves into the thumbnails (drawSearchRects). The Windows painter cannot
 * reach the find session -- portable/win/tests/d2d_theme_test.c links the
 * painters without the engine, and must keep doing so -- so the scene builder
 * PUBLISHES the session's per-page marks before the paint and the painter reads
 * them during it: spdf_win_chrome_scroll_set_hot()'s precedent, "one piece of
 * chrome state that travels ... as a setter rather than in the model". A
 * headless test that publishes nothing draws no ticks, which is what it drew.
 *
 * Both are defined in spdf_win_chrome_minimap.cpp so every binary that draws
 * the strip has them. C-compatible; no Direct2D type appears here.
 */
#ifndef SPDF_WIN_SEARCH_MAP_H
#define SPDF_WIN_SEARCH_MAP_H

#include "spdf_win_chrome.h"
#include "spdf_win_chrome_find.h" /* SpdfWinFindPageMark */
#include "spdf_win_minimap.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpdfWinMapFrame {
    SpdfWinChromeRect panel;          /* the minimap rect, client device px */
    double content_top;               /* strip y = 0 sits at panel.y + content_top */
    const SpdfWinMinimapStrip* strip; /* borrowed: the painter's cached strip, valid until the next paint */
    int page_count;
    const SpdfWinPageSizePt* sizes;   /* borrowed, page_count entries, PDF points */
    SpdfWinRect band;                 /* the viewport indicator as drawn, in UNSCROLLED strip space */
    float dpi_scale;
} SpdfWinMapFrame;

/* 1 and `out` filled when the last paint drew a strip; 0 otherwise. */
int spdf_win_map_frame_current(SpdfWinMapFrame* out);

/* The session's per-page marks for the coming paint. Borrowed until the next
 * publish; NULL/0 clears. `active` is an index into `marks` or -1. */
void spdf_win_map_marks_publish(const SpdfWinFindPageMark* marks, int count, int active);
const SpdfWinFindPageMark* spdf_win_map_marks_current(int* out_count, int* out_active);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SEARCH_MAP_H */
