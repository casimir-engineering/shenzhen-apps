/* spdf_win_tabs_style.h — how one tab's chip is painted: which colour role, at
 * what alpha, at what stroke width.
 *
 * Split out of spdf_win_tabstrip.h for the file-size ratchet
 * (tools/file-size-limits.md), along the seam the mac itself has:
 * SPDFMacTabStripStyle.{h,mm} beside SPDFMacTabStripView.mm. Included by
 * spdf_win_tabstrip.h, so a consumer of the geometry sees the style too;
 * toolkit-free, header-only, compiled by MSVC as C and as C++, pinned by
 * portable/win/tests/tabstrip_geometry_test.c.
 */
#ifndef SPDF_WIN_TABS_STYLE_H
#define SPDF_WIN_TABS_STYLE_H

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_TSTYLE_INLINE __inline
#else
#define SPDF_WIN_TSTYLE_INLINE inline
#endif

/* --- tab chip style (SPDFMacTabStripStyle.{h,mm}, 26.9.2-1) ---------------
 *
 * How one tab's chip is painted: which semantic colour family, at what alpha,
 * at what stroke width. Transcribed rather than restated so the painter cannot
 * drift from the mac: EVERY tab is outlined now. An unselected present tab used
 * to have no stroke at all over a fill identical to the strip behind it, so it
 * had no discernible edge in either theme -- the defect that commit fixed. The
 * selected tab keeps a nearly opaque accent outline at twice the neutral width
 * over an accent-tinted fill; an unselected one gets a translucent neutral
 * hairline over an untinted one; a missing file is red at either width.
 *
 * Roles name the theme colour rather than an RGB value, as the mac names the
 * AppKit semantic colour: spdf_win_chrome_theme.h resolves them per theme. */
typedef enum spdf_win_tab_style_role {
    SPDF_WIN_TAB_ROLE_CONTROL_BACKGROUND = 0, /* controlBackgroundColor: the body of a present tab */
    SPDF_WIN_TAB_ROLE_SEPARATOR,              /* separatorColor: the neutral hairline round an unselected tab */
    SPDF_WIN_TAB_ROLE_ACCENT,                 /* controlAccentColor: the selected tab, fill and outline */
    SPDF_WIN_TAB_ROLE_ALERT                   /* systemRedColor: a tab whose file has gone missing */
} spdf_win_tab_style_role;

typedef struct SpdfWinTabStyle {
    int fill_role;       /* spdf_win_tab_style_role */
    double fill_alpha;   /* 0 means "the role's own alpha", i.e. leave it alone */
    int stroke_role;
    double stroke_alpha;
    double stroke_width; /* points */
} SpdfWinTabStyle;

/* SPDFMacTabStripStyle.mm:8-23. Both widths are whole device pixels at 1x and
 * 2x once inset by half their width; 1.4 (the old selected width) was neither
 * and smeared at both scales. 0.26 is the neutral alpha that keeps every tab
 * edged while staying quieter than the selected accent (0.42 overshot). */
#define SPDF_WIN_TAB_STROKE_UNSELECTED 1.0
#define SPDF_WIN_TAB_STROKE_SELECTED 2.0
#define SPDF_WIN_TAB_STROKE_UNSELECTED_ALPHA 0.26

/* spdf_tab_style_for_state (SPDFMacTabStripStyle.mm:25-47). */
static SPDF_WIN_TSTYLE_INLINE SpdfWinTabStyle spdf_win_tab_style_for_state(int selected, int missing) {
    SpdfWinTabStyle s;
    s.stroke_width = selected ? SPDF_WIN_TAB_STROKE_SELECTED : SPDF_WIN_TAB_STROKE_UNSELECTED;
    if (missing) {
        s.fill_role = SPDF_WIN_TAB_ROLE_ALERT;
        s.fill_alpha = selected ? 0.36 : 0.22;
        s.stroke_role = SPDF_WIN_TAB_ROLE_ALERT;
        s.stroke_alpha = selected ? 0.95 : 0.65;
        return s;
    }
    if (selected) {
        s.fill_role = SPDF_WIN_TAB_ROLE_ACCENT;
        s.fill_alpha = 0.34;
        s.stroke_role = SPDF_WIN_TAB_ROLE_ACCENT;
        s.stroke_alpha = 0.95;
        return s;
    }
    s.fill_role = SPDF_WIN_TAB_ROLE_CONTROL_BACKGROUND;
    s.fill_alpha = 0.0;
    s.stroke_role = SPDF_WIN_TAB_ROLE_SEPARATOR;
    s.stroke_alpha = SPDF_WIN_TAB_STROKE_UNSELECTED_ALPHA;
    return s;
}

/* spdf_tab_stroke_inset (:49-51): inset the chip by half the stroke width and
 * the outline's centreline lands on a device-pixel boundary, so the hairline
 * stays crisp instead of straddling the fill edge across two rows. */
static SPDF_WIN_TSTYLE_INLINE double spdf_win_tab_stroke_inset(double stroke_width) { return stroke_width / 2.0; }

#endif /* SPDF_WIN_TABS_STYLE_H */
