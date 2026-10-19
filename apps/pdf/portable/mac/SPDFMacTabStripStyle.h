#import <AppKit/AppKit.h>

// How one tab's background chip is painted: which semantic colour family, at
// what alpha, at what stroke width. Split out of SPDFMacTabStripView.mm so the
// per-state decision is a pure function a unit test can exercise directly (see
// tests/SPDFMacTabStripStyleTests.mm) instead of only through a rasterized
// view.
//
// Roles name the AppKit semantic colour rather than an RGB value: the light
// and dark reading themes are served by AppKit resolving the same role
// differently, so nothing here may be hard-coded.

typedef NS_ENUM(NSInteger, SPDFTabStyleRole) {
    // controlBackgroundColor: the body of a present tab.
    SPDFTabStyleRoleControlBackground = 0,
    // separatorColor: the neutral hairline outlining an unselected tab. The
    // strip's overflow button already uses this family for the same purpose.
    SPDFTabStyleRoleSeparator,
    // controlAccentColor: the selected tab, fill and outline both.
    SPDFTabStyleRoleAccent,
    // systemRedColor: a tab whose file has gone missing.
    SPDFTabStyleRoleAlert,
};

typedef struct {
    SPDFTabStyleRole fillRole;
    CGFloat fillAlpha;  // 0 means "the role's own alpha", i.e. leave it alone.
    SPDFTabStyleRole strokeRole;
    CGFloat strokeAlpha;
    CGFloat strokeWidth;
} SPDFTabStyle;

// Corner radius of the filled tab chip. Shared with the stroke path, which
// shrinks it by the stroke inset so the two stay concentric.
extern const CGFloat kSPDFTabCornerRadius;

// The fill and outline for one tab.
//
// EVERY tab is outlined. An unselected present tab used to get no stroke at
// all, and its controlBackgroundColor fill is byte-identical to
// windowBackgroundColor behind the strip in BOTH Aqua and Dark Aqua (asserted
// in the test), so it had no discernible edge whatsoever — the whole point of
// this seam.
//
// Selection stays unmistakable regardless: the selected tab keeps a nearly
// opaque accent outline at twice the neutral width, over an accent-tinted
// fill, where an unselected tab gets a translucent neutral hairline over an
// untinted one. The missing-file red treatment is unchanged apart from
// adopting the same selected/unselected widths.
SPDFTabStyle spdf_tab_style_for_state(BOOL selected, BOOL missing);

// Half the stroke width: inset the fill rect by this much and the outline's
// centreline lands on a device-pixel boundary, so the hairline stays crisp
// instead of straddling the fill edge and smearing across two rows of pixels.
// Mirrors -drawPageBorderInRect: in SPDFMacDocumentViewTheme.mm. Both widths
// spdf_tab_style_for_state() returns are chosen so this is exact at 1x and 2x.
CGFloat spdf_tab_stroke_inset(CGFloat strokeWidth);

// Resolves a role and alpha to the live AppKit colour. Passing alpha 0 keeps
// the semantic colour's own alpha.
NSColor* spdf_tab_style_color(SPDFTabStyleRole role, CGFloat alpha);
