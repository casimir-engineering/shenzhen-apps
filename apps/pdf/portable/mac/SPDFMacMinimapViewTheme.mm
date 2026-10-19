#import "SPDFMacMinimapViewTheme.h"

#import "SPDFMacSupport.h"

#include <math.h>

@implementation SPDFMinimapView (Theme)

- (SPDFMarkdownTheme*)minimapTheme {
    return [SPDFMarkdownTheme themeForVariant:self.themeVariant];
}

- (NSColor*)stripBackgroundColor {
    return [self minimapTheme].viewportBackgroundColor ?: NSColor.windowBackgroundColor;
}

// The theme's paper rather than white: a thumbnail can fall a fraction of a
// point short of its slot at fractional scales, and white underneath a dark
// page leaks a bright sliver along that edge -- the same reason
// SPDFDocumentView.pageFillColor paints paper instead of white.
- (NSColor*)pageFillColor {
    return [self minimapTheme].paperColor;
}

// Dark draws no paper shadow (a black shadow is invisible on a dark gutter), so
// without this frame a #1E1E1E sheet has no edge against the gutter at all and
// the whole strip reads as one continuous dark column -- only the selected
// page, which gets its own overlay outline, stayed visible. Mirrors
// SPDFDocumentView -drawPageBorderInRect:, including the half-pixel inset that
// puts the 1px stroke's centerline on a device-pixel boundary at 1x and 2x.
- (void)drawPageBorderInRect:(NSRect)pageRect {
    SPDFMarkdownTheme* theme = [self minimapTheme];
    if (theme.drawsPaperShadow || !theme.paperBorderColor) return;
    if (NSHeight(pageRect) < 3.0 || NSWidth(pageRect) < 3.0) return;
    [theme.paperBorderColor setStroke];
    NSBezierPath* path = [NSBezierPath bezierPathWithRect:NSInsetRect(pageRect, 0.5, 0.5)];
    path.lineWidth = 1.0;
    [path stroke];
}

- (void)drawPlaceholderInRect:(NSRect)rect {
    if (NSHeight(rect) < 6.0 || NSWidth(rect) < 10.0) return;
    // Ruled lines read as ink on the sheet: dark paper needs a light tint, light
    // paper a grey one, both faint enough to stay a stand-in rather than text.
    SPDFMarkdownTheme* theme = [self minimapTheme];
    CGFloat white = theme.drawsPaperShadow ? 0.76 : 0.62;
    [[NSColor colorWithCalibratedWhite:white alpha:0.34] setFill];
    NSInteger lines = (NSInteger)MAX(2.0, MIN(16.0, floor(NSHeight(rect) / 7.0)));
    CGFloat y = NSMinY(rect) + MAX(2.0, NSHeight(rect) * 0.08);
    CGFloat lineHeight = MAX(1.0, NSHeight(rect) * 0.018);
    for (NSInteger i = 0; i < lines; ++i) {
        CGFloat widthFactor = (i % 5 == 4) ? 0.56 : 0.78;
        NSRect line = NSMakeRect(NSMinX(rect) + NSWidth(rect) * 0.12, y, NSWidth(rect) * widthFactor, lineHeight);
        NSRectFillUsingOperation(line, NSCompositingOperationSourceOver);
        y += MAX(3.0, NSHeight(rect) / (CGFloat)(lines + 2));
        if (y > NSMaxY(rect) - 2.0) break;
    }
}

@end
