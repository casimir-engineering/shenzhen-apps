#pragma once

/* spdf_win_tabs_hover.h -- the tab strip's hover preview.
 *
 * Header-only and included from spdf_win_main.cpp before
 * spdf_win_chrome_actions.h, whose hover branch calls the one function here.
 * Same arrangement as spdf_win_tabs_app.h beside it; not part of the port's
 * public surface.
 *
 * macOS shows a borderless panel with the tab's full title when the pointer
 * rests on a tab (SPDFMacTabStripView.mm:317-345). The Windows form is a
 * tooltip under the tab (spdf_win_window_tooltip, which delays it so a pointer
 * crossing the strip flashes nothing), and it shows the PATH: the strip already
 * disambiguates same-name tabs by folder (spdf_win_tabs_names.h), and the whole
 * path is what a reader hovering wants to know when two documents are called
 * the same thing.
 */

static void chrome_hover_tooltip(app* a, const SpdfWinChromeLayout* l, int hot_tab) {
    wchar_t wide[SPDF_WIN_PATH_MAX];
    SpdfWinTabRect t;
    const char* path;
    float s;
    if (!a->window) return;
    path = hot_tab >= 0 && a->tabs ? spdf_win_tabs_path(a->tabs, hot_tab) : NULL;
    if (!path || !*path ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) <= 0) {
        spdf_win_window_tooltip(a->window, NULL, 0, 0);
        return;
    }
    s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    t = spdf_win_tabstrip_tab_rect(l->tabstrip.w / s, a->tabs ? spdf_win_tabs_count(a->tabs) : 0,
                                   a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1, hot_tab);
    spdf_win_window_tooltip(a->window, wide, (int)(l->tabstrip.x + (float)t.x * s),
                            (int)(l->tabstrip.y + l->tabstrip.h + 4.0f * s));
}
