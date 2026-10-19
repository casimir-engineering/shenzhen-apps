// Tab-strip chip styling: every tab is outlined, the selected one still reads
// as selected, and the outline is crisp. Guards the defect this seam was
// extracted for — an unselected present tab had no stroke at all, over a fill
// identical to the strip background, so it was invisible in both themes.
#import <AppKit/AppKit.h>

#include <math.h>
#include <stdio.h>

#import "../SPDFMacTabStripStyle.h"

static int gFailureCount = 0;

static void Expect(NSString* label, BOOL condition) {
    if (condition) return;
    fprintf(stderr, "FAIL %s\n", label.UTF8String);
    ++gFailureCount;
}

static NSColor* SRGB(NSColor* color) {
    return [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}

// Perceived luminance of `src` composited over the opaque `dst`, which is what
// a translucent outline actually shows the reader.
static CGFloat CompositedLuminance(NSColor* src, NSColor* dst) {
    NSColor* s = SRGB(src);
    NSColor* d = SRGB(dst);
    CGFloat a = s.alphaComponent;
    CGFloat r = s.redComponent * a + d.redComponent * (1.0 - a);
    CGFloat g = s.greenComponent * a + d.greenComponent * (1.0 - a);
    CGFloat b = s.blueComponent * a + d.blueComponent * (1.0 - a);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

static CGFloat Luminance(NSColor* color) {
    return CompositedLuminance(color, NSColor.blackColor);
}

static BOOL ColorsEqual(NSColor* a, NSColor* b) {
    NSColor* x = SRGB(a);
    NSColor* y = SRGB(b);
    return fabs(x.redComponent - y.redComponent) < 0.002 && fabs(x.greenComponent - y.greenComponent) < 0.002 &&
           fabs(x.blueComponent - y.blueComponent) < 0.002 && fabs(x.alphaComponent - y.alphaComponent) < 0.002;
}

// The rect a stroke path is built from, mirroring the draw site.
static NSRect OutlineRect(NSRect tabRect, CGFloat strokeWidth) {
    CGFloat inset = spdf_tab_stroke_inset(strokeWidth);
    return NSInsetRect(tabRect, inset, inset);
}

// The outline's centreline must land on a device-pixel boundary at this scale,
// so the stroke covers whole pixels rather than smearing over two rows.
static BOOL CentrelineOnPixelBoundary(CGFloat edge, CGFloat strokeWidth, CGFloat backingScale) {
    CGFloat halfWidthInPixels = strokeWidth * backingScale / 2.0;
    CGFloat edgeInPixels = edge * backingScale;
    return fabs(edgeInPixels - halfWidthInPixels - round(edgeInPixels - halfWidthInPixels)) < 0.001;
}

static void CheckStateDecisions(void) {
    SPDFTabStyle plain = spdf_tab_style_for_state(NO, NO);
    SPDFTabStyle selected = spdf_tab_style_for_state(YES, NO);
    SPDFTabStyle missing = spdf_tab_style_for_state(NO, YES);
    SPDFTabStyle missingSelected = spdf_tab_style_for_state(YES, YES);

    // The defect: an unselected present tab must be outlined.
    Expect(@"unselected tab is outlined", plain.strokeAlpha > 0.0 && plain.strokeWidth > 0.0);
    Expect(@"every state is outlined", selected.strokeAlpha > 0.0 && missing.strokeAlpha > 0.0 &&
                                           missingSelected.strokeAlpha > 0.0);
    Expect(@"unselected tab outline is neutral", plain.strokeRole == SPDFTabStyleRoleSeparator);
    Expect(@"unselected tab body is untinted", plain.fillRole == SPDFTabStyleRoleControlBackground);

    // Selection must not be traded away for the new outline.
    Expect(@"selected outline is the accent", selected.strokeRole == SPDFTabStyleRoleAccent);
    Expect(@"selected fill is accent-tinted", selected.fillRole == SPDFTabStyleRoleAccent);
    Expect(@"selected outline is heavier", selected.strokeWidth > plain.strokeWidth);
    Expect(@"selected outline is more opaque", selected.strokeAlpha > plain.strokeAlpha + 0.3);

    // Missing-file red treatment preserved, alphas included.
    Expect(@"missing tab stays red", missing.fillRole == SPDFTabStyleRoleAlert &&
                                         missing.strokeRole == SPDFTabStyleRoleAlert);
    Expect(@"missing fill alphas unchanged", fabs(missing.fillAlpha - 0.22) < 0.001 &&
                                                fabs(missingSelected.fillAlpha - 0.36) < 0.001);
    Expect(@"missing stroke alphas unchanged", fabs(missing.strokeAlpha - 0.65) < 0.001 &&
                                                  fabs(missingSelected.strokeAlpha - 0.95) < 0.001);
    Expect(@"missing selection is heavier too", missingSelected.strokeWidth > missing.strokeWidth);
}

static void CheckCrispness(void) {
    // The strip lays tabs out on integral origins (see -rectForTabAtIndex:).
    NSRect tabRect = NSMakeRect(138.0, 7.0, 200.0, 28.0);
    const CGFloat scales[] = {1.0, 2.0};
    BOOL states[][2] = {{NO, NO}, {YES, NO}, {NO, YES}, {YES, YES}};
    for (NSUInteger i = 0; i < sizeof(states) / sizeof(states[0]); ++i) {
        SPDFTabStyle style = spdf_tab_style_for_state(states[i][0], states[i][1]);
        NSRect outline = OutlineRect(tabRect, style.strokeWidth);
        Expect(@"outline stays inside the filled chip", NSContainsRect(tabRect, outline));
        Expect(@"outline corners stay concave", kSPDFTabCornerRadius - spdf_tab_stroke_inset(style.strokeWidth) > 0.0);
        for (NSUInteger s = 0; s < 2; ++s) {
            Expect([NSString stringWithFormat:@"state %lu outline crisp at %.0fx", (unsigned long)i, scales[s]],
                   CentrelineOnPixelBoundary(NSMinX(outline), style.strokeWidth, scales[s]) &&
                       CentrelineOnPixelBoundary(NSMinY(outline), style.strokeWidth, scales[s]));
        }
    }
    Expect(@"inset is half the stroke width", fabs(spdf_tab_stroke_inset(1.0) - 0.5) < 0.001 &&
                                                 fabs(spdf_tab_stroke_inset(2.0) - 1.0) < 0.001);
}

// Runs the appearance-dependent checks with `appearance` current.
static void CheckResolvedColors(NSAppearanceName name) {
    NSString* label = (NSString*)name;
    SPDFTabStyle plain = spdf_tab_style_for_state(NO, NO);
    SPDFTabStyle selected = spdf_tab_style_for_state(YES, NO);

    NSColor* strip = NSColor.windowBackgroundColor;
    NSColor* plainFill = spdf_tab_style_color(plain.fillRole, plain.fillAlpha);
    NSColor* plainStroke = spdf_tab_style_color(plain.strokeRole, plain.strokeAlpha);
    NSColor* selectedStroke = spdf_tab_style_color(selected.strokeRole, selected.strokeAlpha);

    // Why the outline is load-bearing rather than a nicety: the tab body is the
    // very same colour as the strip behind it, in BOTH appearances. Should
    // AppKit ever separate the two this assertion is the place to revisit the
    // fill, but the outline must survive either way.
    Expect([label stringByAppendingString:@": tab fill matches the strip, so only the outline gives an edge"],
           ColorsEqual(plainFill, strip));

    // Raised well clear of separatorColor's shipped 0.098, but deliberately NOT
    // as far as the first attempt's 0.42, which read as harder than the content
    // it framed. The luminance-separation assertion below is what actually
    // guards visibility; this one only guards against falling back to the
    // invisible default.
    Expect([label stringByAppendingString:@": neutral outline alpha was raised off separatorColor's own"],
           SRGB(plainStroke).alphaComponent > SRGB(NSColor.separatorColor).alphaComponent + 0.1);

    // The neutral hairline must actually be visible against the strip. 0.15 of
    // luminance separation is a clearly readable edge at hairline width; the
    // shipped separatorColor alpha manages barely a third of that.
    CGFloat stripLuminance = Luminance(strip);
    CGFloat plainEdge = fabs(CompositedLuminance(plainStroke, strip) - stripLuminance);
    Expect([label stringByAppendingFormat:@": neutral outline reads against the strip (%.3f)", plainEdge],
           plainEdge > 0.15);
    Expect([label stringByAppendingString:@": raising the alpha is what made it read"],
           plainEdge > fabs(CompositedLuminance(NSColor.separatorColor, strip) - stripLuminance) + 0.1);

    // ...and the selected outline must still dominate it: chromatic accent
    // against a grey hairline, so compare distance from the neutral edge.
    NSColor* selectedOver = SRGB(selectedStroke);
    NSColor* plainOver = SRGB(plainStroke);
    CGFloat chroma = fabs(selectedOver.blueComponent - selectedOver.redComponent);
    Expect([label stringByAppendingFormat:@": selected outline is chromatic (%.3f)", chroma], chroma > 0.4);
    Expect([label stringByAppendingString:@": neutral outline is achromatic"],
           fabs(plainOver.blueComponent - plainOver.redComponent) < 0.02);
    Expect([label stringByAppendingString:@": selected outline is near-opaque"], selectedOver.alphaComponent > 0.9);
}

int main(void) {
    @autoreleasepool {
        NSApplicationLoad();
        CheckStateDecisions();
        CheckCrispness();
        for (NSAppearanceName name in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
            NSAppearance* appearance = [NSAppearance appearanceNamed:name];
            Expect(@"appearance is available", appearance != nil);
            if (!appearance) continue;
            [appearance performAsCurrentDrawingAppearance:^{
              CheckResolvedColors(name);
            }];
        }
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFMacTabStripStyleTests passed\n");
    return 0;
}
