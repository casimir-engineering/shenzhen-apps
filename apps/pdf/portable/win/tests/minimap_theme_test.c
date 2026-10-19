/* The minimap strip's reading-theme chrome: portable/win/src/spdf_win_chrome_theme.h's
 * minimap_* roles against portable/mac/SPDFMacMinimapViewTheme.mm and the
 * palette it reads (SPDFMarkdownTheme.mm after 61070e502).
 *
 * WHAT IT GUARDS. The mac's SPDFMacReadingThemeChromeTests.mm asserts the same
 * three things this does, in the same units: the dark gutter and border are the
 * stated hexes; the paper is the recolor transform's white endpoint, so a
 * thumbnail a fraction short of its slot cannot leak a bright sliver; and the
 * separation is worth SEEING rather than merely nonzero -- at least 16 levels
 * gutter-to-paper and 24 border-to-paper, because #121212 under #1E1E1E was 12
 * levels and read as no edge at all on a blank page margin. Light must keep the
 * panel behind the sheets, white paper and no frame, as the mac keeps
 * windowBackgroundColor and its shadow there.
 *
 * Header-only subject: no extra translation units. Judged by exit code.
 */

#include <math.h>
#include <stdio.h>

#include "spdf_win_chrome_theme.h"
#include "spdf_win_d2d.h" /* spdf_win_theme_for: the reading theme the paper must match */

static int failures;

static void expect(int condition, const char* what) {
    if (!condition) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

/* 0xRRGGBB of a theme colour, the units the palette is written in. */
static unsigned rgb_of(SpdfWinChromeColor c) {
    unsigned r = (unsigned)lround(c.r * 255.0), g = (unsigned)lround(c.g * 255.0), b = (unsigned)lround(c.b * 255.0);
    return (r << 16) | (g << 8) | b;
}

static int red_byte(SpdfWinChromeColor c) { return (int)lround(c.r * 255.0); }

int main(void) {
    SpdfWinChromeTheme dark = spdf_win_chrome_theme_for(1);
    SpdfWinChromeTheme light = spdf_win_chrome_theme_for(0);
    spdf_win_theme reading_dark = spdf_win_theme_for(1);
    spdf_win_theme reading_light = spdf_win_theme_for(0);

    printf("dark  gutter=%06X paper=%06X border=%06X placeholder=%06X@%.2f frame=%d\n", rgb_of(dark.minimap_gutter),
           rgb_of(dark.minimap_paper), rgb_of(dark.minimap_page_border), rgb_of(dark.minimap_placeholder),
           dark.minimap_placeholder.a, dark.minimap_draws_page_border);
    printf("light gutter=%06X paper=%06X placeholder=%06X@%.2f frame=%d\n", rgb_of(light.minimap_gutter),
           rgb_of(light.minimap_paper), rgb_of(light.minimap_placeholder), light.minimap_placeholder.a,
           light.minimap_draws_page_border);

    /* --- dark: the mac's literals ------------------------------------- */
    expect(rgb_of(dark.minimap_gutter) == 0x0A0A0Au, "dark gutter is #0A0A0A");
    expect(rgb_of(dark.minimap_paper) == 0x1E1E1Eu, "dark paper is #1E1E1E");
    expect(rgb_of(dark.minimap_page_border) == 0x3D3D3Du, "dark paper border is #3D3D3D");
    expect(dark.minimap_draws_page_border, "dark frames each sheet");
    expect(dark.minimap_gutter.a == 1.0f && dark.minimap_paper.a == 1.0f && dark.minimap_page_border.a == 1.0f,
           "gutter, paper and border are opaque");
    /* The paper is the recolor transform's white endpoint -- the one value that
     * must agree with the canvas's, or a thumbnail's edge shows a sliver. */
    expect(rgb_of(dark.minimap_paper) == reading_dark.paper_rgb, "dark paper is the reading theme's paper");
    /* A separation that exists but cannot be seen is the bug this guards. */
    expect(red_byte(dark.minimap_paper) - red_byte(dark.minimap_gutter) >= 16,
           "the gutter/paper gap is visible, not merely nonzero");
    expect(red_byte(dark.minimap_page_border) - red_byte(dark.minimap_paper) >= 24,
           "the paper border clears the paper it frames");
    /* Greys, so no tint creeps into the strip. */
    expect(dark.minimap_gutter.r == dark.minimap_gutter.g && dark.minimap_gutter.g == dark.minimap_gutter.b,
           "the dark gutter is neutral");
    expect(dark.minimap_page_border.r == dark.minimap_page_border.g &&
               dark.minimap_page_border.g == dark.minimap_page_border.b,
           "the dark border is neutral");
    /* The ruled-lines stand-in reads as ink: lighter than dark paper, at the
     * mac's 0.34 alpha (calibratedWhite 0.62). */
    expect(rgb_of(dark.minimap_placeholder) == 0x9E9E9Eu, "dark placeholder lines are white 0.62");
    expect(fabs(dark.minimap_placeholder.a - 0.34) < 0.001, "dark placeholder alpha is 0.34");
    expect(red_byte(dark.minimap_placeholder) > red_byte(dark.minimap_paper), "dark placeholder lines read over the paper");

    /* --- light: unchanged from before the theme work --------------------- */
    expect(rgb_of(light.minimap_gutter) == rgb_of(light.panel), "light keeps the panel behind the sheets");
    expect(rgb_of(light.minimap_paper) == 0xFFFFFFu, "light paper is white");
    expect(rgb_of(light.minimap_paper) == reading_light.paper_rgb, "light paper is the reading theme's paper");
    expect(!light.minimap_draws_page_border, "light draws no frame (the canvas separates with a shadow)");
    expect(rgb_of(light.minimap_placeholder) == 0xC2C2C2u, "light placeholder lines are white 0.76");
    expect(fabs(light.minimap_placeholder.a - 0.34) < 0.001, "light placeholder alpha is 0.34");
    expect(red_byte(light.minimap_placeholder) < red_byte(light.minimap_paper), "light placeholder lines read over the paper");
    expect(red_byte(light.minimap_paper) > red_byte(light.minimap_gutter), "light paper sits above its gutter");

    if (failures) {
        printf("%d minimap theme check(s) failed\n", failures);
        return 1;
    }
    printf("All minimap theme checks passed\n");
    return 0;
}
