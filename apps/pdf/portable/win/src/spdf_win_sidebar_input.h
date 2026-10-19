#pragma once

/* spdf_win_sidebar_input.h -- what a mouse event over the SIDEBAR means: a
 * segment, the filter field, or a row.
 *
 * The sidebar case of spdf_win_chrome_input_route(), extracted when the router
 * passed the repo's 500-line cap (tools/file-size-limits.md asks for a file,
 * not a raised cap). Same rules as its caller: pure, header-only, no app state,
 * and every rect comes from the functions the sidebar painter draws with --
 * spdf_win_sidebar_layout() for the bands, spdf_win_sidebar_sections_rect() for
 * the segment control, spdf_win_sidebar_row_at() for the Chapters rows -- so a
 * click lands on what was drawn. Included by spdf_win_chrome_input.h only, after
 * the action enum and the hit struct it fills are complete.
 *
 * THE SEARCH SECTION'S ROWS have three heights (spdf_win_sidebar_view.h) and
 * this header has no view of them, so a click on that list reports the
 * LIST-LOCAL Y in `out->index` (the list's scroll offset included) and the app
 * resolves the row against the rows it published. The empty space below the
 * last row is swallowed rather than forwarded: a drag begun on the panel that
 * panned the document would be a worse bug than a panel that does nothing.
 */

#include "spdf_win_chrome_content.h"
#include "spdf_win_sidebar_view.h"

static SPDF_WIN_CI_INLINE void spdf_win_sidebar_route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m,
                                                      float x, float y, int button, float s,
                                                      SpdfWinChromeHit* out) {
    SpdfWinSidebarLayout sb;
    SpdfWinChromeRect bar;
    int segments = m->search_active ? 3 : 2;
    int row, seg;
    if (button != SPDF_WIN_CB_LEFT) return;
    spdf_win_sidebar_layout(l->sidebar, m->sidebar_section, s, &sb);
    bar = spdf_win_sidebar_sections_rect(sb.sections, l->sidebar, segments, s);
    seg = spdf_win_sidebar_section_at(bar, segments, x, y);
    if (seg >= 0) {
        out->action = SPDF_WIN_CA_SIDEBAR_SECTION;
        out->index = seg;
        return;
    }
    if (spdf_win_chrome_contains(sb.filter, x, y)) {
        out->action = SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER;
        return;
    }
    if (m->sidebar_section != 0) {
        /* The Search and Comments sections' rows have three heights and are
         * the caller's to resolve: the list-local y travels in `index` (see
         * SPDF_WIN_CA_SIDEBAR_ROW). */
        if (spdf_win_chrome_contains(sb.list, x, y)) {
            out->action = SPDF_WIN_CA_SIDEBAR_ROW;
            out->index = (int)floorf(y - sb.list.y + m->sidebar_scroll_y);
            if (out->index < 0) out->index = 0;
        }
        return;
    }
    row = spdf_win_sidebar_row_at(&sb, m->sidebar_scroll_y, m->sidebar_row_count, x, y);
    if (row >= 0) {
        out->action = SPDF_WIN_CA_SIDEBAR_ROW;
        out->index = row;
    }
    return;
}
