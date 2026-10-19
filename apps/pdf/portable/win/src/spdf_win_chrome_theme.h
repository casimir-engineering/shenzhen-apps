/* spdf_win_chrome_theme.h — chrome colours for the Win32 frontend.
 *
 * WHY THIS FILE EXISTS AT ALL. The macOS chrome is drawn almost entirely in
 * SYSTEM colours -- controlAccentColor, controlBackgroundColor, labelColor,
 * secondaryLabelColor, separatorColor, windowBackgroundColor, systemOrange,
 * systemRed, systemYellow. Those are semantic names with no fixed value: AppKit
 * resolves them per appearance, and the user's accent colour changes them. So
 * unlike the READING theme, whose hex values are literals in
 * SPDFMarkdownTheme.mm and must be matched exactly, the chrome cannot be matched
 * by copying numbers -- there are no numbers to copy.
 *
 * What transfers is the RELATIONSHIP: a selected tab is its accent at 34% over
 * the strip; an unselected one is the control background; a separator is a
 * hairline a little darker than the surface it divides; secondary text is
 * visibly quieter than primary. So this header names the same ROLES the macOS
 * code names, and gives each a concrete Windows 11 value.
 *
 * CONCRETE sRGB, NOT SYSTEM QUERIES, AND THAT IS DELIBERATE.
 * agents.md requires rendered colour to be concrete sRGB rather than
 * appearance-dynamic, so that screen, print and export agree. Chrome is not
 * rendered document content, so that rule does not strictly bind it -- but two
 * things argue for constants anyway:
 *
 *   1. The chrome is painted through spdf_win_paint(), which must work with no
 *      HWND and no desktop (spdf_win_d2d.h). A colour read from
 *      DwmGetColorizationColor or UISettings is unavailable in exactly the
 *      environment the pixel tests run in, so chrome colour would become
 *      untestable -- and the offscreen tests were just shown to be
 *      byte-identical to the live window, which is the property worth keeping.
 *   2. A pixel test whose expected value depends on the user's accent colour is
 *      not a test.
 *
 * The accent is therefore the Windows 11 DEFAULT accent, not the user's. That is
 * a known, deliberate divergence from macOS, which does follow the user's
 * accent. Following it later is a small change -- one field in this struct, fed
 * from the window layer where an HWND exists, with the pixel tests pinned to the
 * default -- and the place to do it is here, not at each call site.
 *
 * Values are Windows 11 system palette (WinUI 2/3 "Mica" light and dark), chosen
 * so the window reads as a Windows app rather than a transplanted Mac one, while
 * keeping every macOS relationship intact.
 *
 * The READING theme is NOT here. Paper #FFFFFF/#1E1E1E, the gutter, the page
 * border, ink #DCDDDE and the recolor endpoints live in spdf_win_d2d.h /
 * portable/core/spdf_recolor.h and are exact matches for SPDFMarkdownTheme.mm.
 * Chrome and reading surface are different problems: one should look native,
 * the other must look identical across platforms. The one exception is the
 * minimap strip's four roles at the end of the struct, which the mac draws in
 * the reading theme because the strip IS the document; the note there says why.
 */
#ifndef SPDF_WIN_CHROME_THEME_H
#define SPDF_WIN_CHROME_THEME_H

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CT_INLINE __inline
#else
#define SPDF_WIN_CT_INLINE inline
#endif

/* 0xRRGGBB, with alpha carried separately where macOS applies one, so a reader
 * can compare against the AppKit call that produced it. */
typedef struct SpdfWinChromeColor {
    float r, g, b, a;
} SpdfWinChromeColor;

/* For the two colours macOS states as calibrated components rather than as a
 * hex triple. Rounding 0.38 to 0x61 and back would move it by 0.0004 -- nothing
 * a human sees, but it would also make this file stop being a transcription of
 * SPDFMacUIHelpers.mm:453-479, and being able to diff a constant against the
 * line that produced it is most of what this header is for. */
static SPDF_WIN_CT_INLINE SpdfWinChromeColor spdf_win_ct_calibrated(float r, float g, float b, float a) {
    SpdfWinChromeColor c;
    c.r = r;
    c.g = g;
    c.b = b;
    c.a = a;
    return c;
}

static SPDF_WIN_CT_INLINE SpdfWinChromeColor spdf_win_ct_rgb(unsigned rgb, float a) {
    SpdfWinChromeColor c;
    c.r = (float)((rgb >> 16) & 0xFFu) / 255.0f;
    c.g = (float)((rgb >> 8) & 0xFFu) / 255.0f;
    c.b = (float)(rgb & 0xFFu) / 255.0f;
    c.a = a;
    return c;
}

typedef struct SpdfWinChromeTheme {
    /* Surfaces. `band` is the tab strip and toolbar; `panel` is the sidebar and
     * minimap; macOS uses windowBackgroundColor for all of them and separates
     * them with hairlines rather than with fill. */
    SpdfWinChromeColor band;
    SpdfWinChromeColor panel;
    SpdfWinChromeColor separator;      /* separatorColor */
    SpdfWinChromeColor divider_fill;   /* windowBackgroundColor behind the 1pt line */

    /* Text. */
    SpdfWinChromeColor label;           /* labelColor */
    SpdfWinChromeColor label_secondary; /* secondaryLabelColor */

    /* Accent, and the two derived values macOS builds from it for a selected
     * tab: fill at 0.34 alpha, stroke at 0.95 (SPDFMacTabStripView.mm:556-558). */
    SpdfWinChromeColor accent;
    SpdfWinChromeColor tab_selected_fill;
    SpdfWinChromeColor tab_selected_stroke;

    /* An unselected tab is controlBackgroundColor with no stroke (:559-561). */
    SpdfWinChromeColor tab_fill;

    /* A tab whose file has gone missing goes red (:552-555). */
    SpdfWinChromeColor tab_missing_fill_selected;
    SpdfWinChromeColor tab_missing_fill;
    SpdfWinChromeColor tab_missing_stroke_selected;
    SpdfWinChromeColor tab_missing_stroke;

    /* Read-only dot: systemOrange (:585). */
    SpdfWinChromeColor readonly_dot;

    /* Close button: labelColor @0.16 selected / secondaryLabelColor @0.13, with
     * the X at @0.76 / @0.82 (:604-616). */
    SpdfWinChromeColor close_fill_selected;
    SpdfWinChromeColor close_fill;
    SpdfWinChromeColor close_glyph_selected;
    SpdfWinChromeColor close_glyph;

    /* Toolbar controls. macOS gets the pill's background and radius from
     * NSSegmentedControl, so these are ours to choose; what must survive is that
     * a lone button looks like half of a pair (SPDFMacSupport.mm:324-325). */
    SpdfWinChromeColor control_fill;
    SpdfWinChromeColor control_fill_hot;
    SpdfWinChromeColor control_fill_pressed;
    SpdfWinChromeColor control_stroke;
    SpdfWinChromeColor control_glyph;

    /* Text field (page number, find, filter): NSTextField / NSSearchField. */
    SpdfWinChromeColor field_fill;
    SpdfWinChromeColor field_stroke;
    SpdfWinChromeColor field_placeholder;

    /* Sidebar row selection, matching an NSTableView's selected row. */
    SpdfWinChromeColor row_selected_fill;
    SpdfWinChromeColor row_hot_fill;

    /* Drop indicator for a tab reattach drag: systemYellow, 2 pt wide
     * (:684-699). */
    SpdfWinChromeColor drop_indicator;

    /* --- caption buttons ---------------------------------------------------
     *
     * Nothing to transcribe: macOS's traffic lights are AppKit's and Windows'
     * caption buttons are ours once the strip is the title bar. These are the
     * Windows 11 relationships -- a button is invisible at rest, lifts to a faint
     * fill on hover, drops back a step when pressed, and CLOSE alone turns red
     * (#C42B1C) with a white glyph on hover, as every Win11 window's does. The
     * glyph is the label colour otherwise. */
    SpdfWinChromeColor caption_fill_hot;
    SpdfWinChromeColor caption_fill_pressed;
    SpdfWinChromeColor caption_close_hot;
    SpdfWinChromeColor caption_close_pressed;
    SpdfWinChromeColor caption_glyph;
    SpdfWinChromeColor caption_glyph_on_close;

    /* --- scrollers -------------------------------------------------------
     *
     * macOS uses a legacy NSScroller and gets all four of these from AppKit, so
     * there are no numbers to copy; what transfers is the RELATIONSHIP, which is
     * that the trough is a quiet surface distinguishable from the document
     * gutter behind it and the thumb is clearly darker (light) or lighter (dark)
     * than its trough at every one of its three states.
     *
     * The trough MUST be distinguishable from the gutter (spdf_win_d2d.h's
     * gutter_rgb: 0xE0E0E2 light, 0x121212 dark). `autohidesScrollers = NO` on
     * both macOS scroll views, so the trough is always visible -- which is only
     * worth anything if a reader can see where it starts and stops. */
    SpdfWinChromeColor scroll_trough;
    SpdfWinChromeColor scroll_thumb;
    SpdfWinChromeColor scroll_thumb_hot;
    SpdfWinChromeColor scroll_thumb_pressed;

    /* The search heat-map's ticks, and these two ARE literals on macOS
     * (SPDFMacUIHelpers.mm:453-479), so they transfer exactly:
     * calibrated(1.0, 0.38, 0.08, 0.95) for the ACTIVE match and
     * calibrated(1.0, 0.86, 0.12, 0.82) for every other one. Same in both
     * appearances -- a find marker is a signal, not a surface, and macOS does
     * not vary it either. */
    SpdfWinChromeColor find_mark_active;
    SpdfWinChromeColor find_mark;

    /* --- the minimap strip -----------------------------------------------
     *
     * THE ONE PLACE THE READING THEME REACHES INTO THIS FILE, and deliberately
     * so: the minimap is the same document on the same paper, and macOS gives it
     * the reading theme's gutter, paper and page border (SPDFMacMinimapViewTheme.mm,
     * 61070e502) rather than the window's chrome colours. Before that change its
     * strip was windowBackgroundColor with every slot filled WHITE under the
     * thumbnail -- which in dark put a #1E1E1E page on a backdrop of a similar
     * value with no edge at all, the defect the Windows wiring pass reported as
     * "light thumbnails on a dark strip".
     *
     * Light keeps the panel colour behind the sheets (the mac keeps
     * windowBackgroundColor there), white paper, and no border -- the light
     * theme separates pages with a shadow, and the strip is too small for one.
     * Dark takes the theme's gutter, paper and 1 px border. The values are the
     * mac's own literals (SPDFMarkdownTheme.mm after 61070e502): gutter #0A0A0A
     * under #1E1E1E paper is 20 of 255 levels, border #3D3D3D over that paper
     * is 31 -- the widened separation, measured there on a live dark window
     * because #121212 and #333333 read as no edge on a blank margin.
     *
     * The paper MUST stay the recolor transform's white endpoint
     * (spdf_win_d2d.h's paper_rgb): a thumbnail can fall a fraction of a pixel
     * short of its slot at fractional scales, and any other underlay leaks a
     * sliver along that edge. portable/win/tests/minimap_theme_test.c pins that
     * equality and the two gaps. The canvas's gutter and border live in
     * spdf_win_d2d.h and are another track's; this change's report asks for
     * them to take the same two values so the strip and the page agree. */
    SpdfWinChromeColor minimap_gutter;      /* behind the sheets */
    SpdfWinChromeColor minimap_paper;       /* under each thumbnail */
    SpdfWinChromeColor minimap_page_border; /* the 1 px frame; drawn only when minimap_draws_page_border */
    SpdfWinChromeColor minimap_placeholder; /* the ruled-lines stand-in for a page not rendered yet */
    int minimap_draws_page_border;
} SpdfWinChromeTheme;

/* Radii and strokes that ARE literals on macOS, so they transfer exactly. */
#define SPDF_WIN_CT_TAB_RADIUS 10.0f         /* :563; 26.9.2-1 rounded the tabs fully */
#define SPDF_WIN_CT_CONTROL_RADIUS 9.0f      /* :135-149, the + and overflow buttons */
#define SPDF_WIN_CT_TOGGLE_RADIUS 7.0f       /* SPDFMacUIHelpers.mm:144-246 pressed bg */
#define SPDF_WIN_CT_MENU_BUTTON_RADIUS 8.0f  /* SPDFMacUIHelpers.mm:250-306 */
#define SPDF_WIN_CT_TAB_STROKE_SELECTED 2.0f /* :566; 26.9.2-1 gave every tab a visible outline */
#define SPDF_WIN_CT_TAB_STROKE 1.0f          /* :566, the unselected/missing case */
#define SPDF_WIN_CT_HAIRLINE 1.0f

/* Fonts. macOS: systemFontOfSize:12 for a tab title (:565), 13 for the page
 * field, 12 Light for a toolbar toggle's title. Segoe UI Variable is the
 * Windows 11 UI face; Segoe UI is the fallback that exists everywhere. */
#define SPDF_WIN_CT_FONT_FAMILY L"Segoe UI Variable Text"
#define SPDF_WIN_CT_FONT_FAMILY_FALLBACK L"Segoe UI"
#define SPDF_WIN_CT_FONT_SIZE_TAB 12.0f
#define SPDF_WIN_CT_FONT_SIZE_FIELD 13.0f
#define SPDF_WIN_CT_FONT_SIZE_LABEL 12.0f

static SPDF_WIN_CT_INLINE SpdfWinChromeTheme spdf_win_chrome_theme_for(int dark) {
    SpdfWinChromeTheme t;
    /* Windows 11 default accent. Light and dark use the two ends of the same
     * accent ramp, as WinUI does: the dark variant is lightened so it keeps its
     * contrast against a dark band. */
    unsigned accent = dark ? 0x4CC2FFu : 0x0067C0u;

    if (dark) {
        t.band = spdf_win_ct_rgb(0x202020u, 1.0f);
        t.panel = spdf_win_ct_rgb(0x202020u, 1.0f);
        t.separator = spdf_win_ct_rgb(0x3A3A3Au, 1.0f);
        t.divider_fill = spdf_win_ct_rgb(0x202020u, 1.0f);
        t.label = spdf_win_ct_rgb(0xFFFFFFu, 1.0f);
        t.label_secondary = spdf_win_ct_rgb(0xC5C5C5u, 1.0f);
        t.tab_fill = spdf_win_ct_rgb(0x2D2D2Du, 1.0f);
        t.control_fill = spdf_win_ct_rgb(0x2D2D2Du, 1.0f);
        t.control_fill_hot = spdf_win_ct_rgb(0x383838u, 1.0f);
        t.control_fill_pressed = spdf_win_ct_rgb(0x272727u, 1.0f);
        t.control_stroke = spdf_win_ct_rgb(0x3D3D3Du, 1.0f);
        t.control_glyph = spdf_win_ct_rgb(0xE6E6E6u, 1.0f);
        t.field_fill = spdf_win_ct_rgb(0x2D2D2Du, 1.0f);
        t.field_stroke = spdf_win_ct_rgb(0x3D3D3Du, 1.0f);
        t.field_placeholder = spdf_win_ct_rgb(0x9A9A9Au, 1.0f);
        t.row_selected_fill = spdf_win_ct_rgb(accent, 0.28f);
        t.row_hot_fill = spdf_win_ct_rgb(0xFFFFFFu, 0.06f);
        t.close_fill_selected = spdf_win_ct_rgb(0xFFFFFFu, 0.16f);
        t.close_fill = spdf_win_ct_rgb(0xC5C5C5u, 0.13f);
        t.close_glyph_selected = spdf_win_ct_rgb(0xFFFFFFu, 0.76f);
        t.close_glyph = spdf_win_ct_rgb(0xC5C5C5u, 0.82f);
        /* One step up from the 0x121212 gutter, so the trough's extent is
         * readable without becoming a bright bar down the page. */
        t.scroll_trough = spdf_win_ct_rgb(0x1F1F1Fu, 1.0f);
        t.scroll_thumb = spdf_win_ct_rgb(0x8A8A8Au, 1.0f);
        t.scroll_thumb_hot = spdf_win_ct_rgb(0xA6A6A6u, 1.0f);
        t.scroll_thumb_pressed = spdf_win_ct_rgb(0xC4C4C4u, 1.0f);
        /* White at 6% over the band on hover, 4% when pressed: Windows 11's own
         * subtle-fill steps for a dark caption. */
        t.caption_fill_hot = spdf_win_ct_rgb(0xFFFFFFu, 0.0605f);
        t.caption_fill_pressed = spdf_win_ct_rgb(0xFFFFFFu, 0.0419f);
        t.caption_glyph = spdf_win_ct_rgb(0xFFFFFFu, 1.0f);
    } else {
        t.band = spdf_win_ct_rgb(0xF3F3F3u, 1.0f);
        t.panel = spdf_win_ct_rgb(0xF3F3F3u, 1.0f);
        t.separator = spdf_win_ct_rgb(0xE1E1E1u, 1.0f);
        t.divider_fill = spdf_win_ct_rgb(0xF3F3F3u, 1.0f);
        t.label = spdf_win_ct_rgb(0x1A1A1Au, 1.0f);
        t.label_secondary = spdf_win_ct_rgb(0x5D5D5Du, 1.0f);
        t.tab_fill = spdf_win_ct_rgb(0xFBFBFBu, 1.0f);
        t.control_fill = spdf_win_ct_rgb(0xFBFBFBu, 1.0f);
        t.control_fill_hot = spdf_win_ct_rgb(0xF0F0F0u, 1.0f);
        t.control_fill_pressed = spdf_win_ct_rgb(0xE5E5E5u, 1.0f);
        t.control_stroke = spdf_win_ct_rgb(0xD8D8D8u, 1.0f);
        t.control_glyph = spdf_win_ct_rgb(0x1A1A1Au, 1.0f);
        t.field_fill = spdf_win_ct_rgb(0xFFFFFFu, 1.0f);
        t.field_stroke = spdf_win_ct_rgb(0xD8D8D8u, 1.0f);
        t.field_placeholder = spdf_win_ct_rgb(0x8A8A8Au, 1.0f);
        t.row_selected_fill = spdf_win_ct_rgb(accent, 0.20f);
        t.row_hot_fill = spdf_win_ct_rgb(0x000000u, 0.05f);
        t.close_fill_selected = spdf_win_ct_rgb(0x1A1A1Au, 0.16f);
        t.close_fill = spdf_win_ct_rgb(0x5D5D5Du, 0.13f);
        t.close_glyph_selected = spdf_win_ct_rgb(0x1A1A1Au, 0.76f);
        t.close_glyph = spdf_win_ct_rgb(0x5D5D5Du, 0.82f);
        /* Lighter than the 0xE0E0E2 gutter, which is the Windows 11 arrangement:
         * the scrollbar reads as furniture attached to the window rather than as
         * part of the paper's surround. */
        t.scroll_trough = spdf_win_ct_rgb(0xF0F0F0u, 1.0f);
        t.scroll_thumb = spdf_win_ct_rgb(0x8A8A8Au, 1.0f);
        t.scroll_thumb_hot = spdf_win_ct_rgb(0x6E6E6Eu, 1.0f);
        t.scroll_thumb_pressed = spdf_win_ct_rgb(0x5A5A5Au, 1.0f);
        t.caption_fill_hot = spdf_win_ct_rgb(0x000000u, 0.0605f);
        t.caption_fill_pressed = spdf_win_ct_rgb(0x000000u, 0.0419f);
        t.caption_glyph = spdf_win_ct_rgb(0x1A1A1Au, 1.0f);
    }
    /* The close button's red is the same in both appearances; pressed is the
     * same red at 90%, which is how Windows 11 dims it under the pointer. */
    t.caption_close_hot = spdf_win_ct_rgb(0xC42B1Cu, 1.0f);
    t.caption_close_pressed = spdf_win_ct_rgb(0xC42B1Cu, 0.9f);
    t.caption_glyph_on_close = spdf_win_ct_rgb(0xFFFFFFu, 1.0f);

    /* The accent-derived tab values keep macOS's alphas exactly, because those
     * ARE literals there (:556-558). */
    t.accent = spdf_win_ct_rgb(accent, 1.0f);
    t.tab_selected_fill = spdf_win_ct_rgb(accent, 0.34f);
    t.tab_selected_stroke = spdf_win_ct_rgb(accent, 0.95f);

    /* systemRed at macOS's four alphas (:552-555). Windows 11's error red. */
    t.tab_missing_fill_selected = spdf_win_ct_rgb(0xC42B1Cu, 0.36f);
    t.tab_missing_fill = spdf_win_ct_rgb(0xC42B1Cu, 0.22f);
    t.tab_missing_stroke_selected = spdf_win_ct_rgb(0xC42B1Cu, 0.95f);
    t.tab_missing_stroke = spdf_win_ct_rgb(0xC42B1Cu, 0.65f);

    /* systemOrange / systemYellow analogues, fully opaque as macOS uses them. */
    t.readonly_dot = spdf_win_ct_rgb(0xF7630Cu, 1.0f);
    t.drop_indicator = spdf_win_ct_rgb(0xFFC83Du, 1.0f);

    /* SPDFMacUIHelpers.mm:453-479, component for component. */
    t.find_mark_active = spdf_win_ct_calibrated(1.0f, 0.38f, 0.08f, 0.95f);
    t.find_mark = spdf_win_ct_calibrated(1.0f, 0.86f, 0.12f, 0.82f);

    /* The minimap strip: the reading theme's chrome, see the struct. The
     * placeholder's ruled lines read as ink on the sheet, so dark paper gets a
     * light tint and light paper a grey one, both at the mac's 0.34 alpha
     * (calibratedWhite 0.62 -> 0x9E, 0.76 -> 0xC2). */
    if (dark) {
        t.minimap_gutter = spdf_win_ct_rgb(0x0A0A0Au, 1.0f);
        t.minimap_paper = spdf_win_ct_rgb(0x1E1E1Eu, 1.0f);
        t.minimap_page_border = spdf_win_ct_rgb(0x3D3D3Du, 1.0f);
        t.minimap_placeholder = spdf_win_ct_rgb(0x9E9E9Eu, 0.34f);
        t.minimap_draws_page_border = 1;
    } else {
        t.minimap_gutter = t.panel;
        t.minimap_paper = spdf_win_ct_rgb(0xFFFFFFu, 1.0f);
        t.minimap_page_border = spdf_win_ct_rgb(0xD0D7DEu, 1.0f);
        t.minimap_placeholder = spdf_win_ct_rgb(0xC2C2C2u, 0.34f);
        t.minimap_draws_page_border = 0;
    }
    return t;
}

#endif /* SPDF_WIN_CHROME_THEME_H */
