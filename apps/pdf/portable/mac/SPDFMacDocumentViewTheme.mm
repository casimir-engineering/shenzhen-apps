#import "SPDFMacDocumentView.h"

#import "SPDFMacSupport.h"

// The document viewport's reading-theme chrome: the gutter behind the sheets
// and how a page is separated from it. Split out of SPDFMacDocumentView.mm so
// the decision can be linked (and probed) without the input/layout half.

// Canvas background for the (non-presentation) document viewport. Deliberately a
// touch darker than the surrounding chrome (which uses windowBackgroundColor) so
// the document region reads as a distinct surface. Built once as a dynamic color
// that resolves per appearance: in each appearance we take windowBackgroundColor,
// pull it into sRGB, and darken it slightly toward black. If resolution ever
// fails we fall back to plain windowBackgroundColor so the opaque fill is never
// nil/black.
static NSColor* spdf_canvas_background_color(void) {
    static NSColor* color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [NSColor colorWithName:nil
                       dynamicProvider:^NSColor*(NSAppearance* appearance) {
                           NSColor* base = NSColor.windowBackgroundColor;
                           // Resolve windowBackgroundColor (a dynamic catalog
                           // color) into concrete sRGB components for the
                           // appearance that is current for this invocation.
                           __block NSColor* rgb = nil;
                           [appearance performAsCurrentDrawingAppearance:^{
                               rgb = [base colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                           }];
                           if (!rgb) return base;
                           BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[
                               NSAppearanceNameAqua, NSAppearanceNameDarkAqua
                           ]] isEqualToString:NSAppearanceNameDarkAqua];
                           // Light: ~8% toward black. Dark: blend toward black a
                           // touch less so it stays subtle on an already-dark base.
                           CGFloat fraction = dark ? 0.06 : 0.08;
                           NSColor* darker = [rgb blendedColorWithFraction:fraction ofColor:NSColor.blackColor];
                           return darker ?: base;
                       }];
    });
    return color;
}

@implementation SPDFDocumentView (Theme)

// Page separation for the active reading theme, mirroring the Markdown canvas's
// paperFillColor/drawsPaperShadow seam: light keeps the soft drop shadow, dark
// swaps it for a crisp 1px paperBorderColor frame — on the dark #121212 gutter
// a black shadow is invisible, so only one page edge would ever read.
- (BOOL)drawsPageShadow {
    return [SPDFMarkdownTheme themeForVariant:self.themeVariant].drawsPaperShadow;
}

- (NSColor*)pageBorderColor {
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:self.themeVariant];
    return theme.drawsPaperShadow ? nil : theme.paperBorderColor;
}

// A page's bitmap does not always land exactly on the page rect: at fractional
// zooms the drawn image can fall short by a fraction of a point. Filling white
// underneath then leaked a bright sliver along that edge -- the lighter
// right-hand border seen on dark-theme PDFs. Paint the theme's own paper so a
// gap is invisible whichever edge it lands on.
- (NSColor*)pageFillColor {
    return [SPDFMarkdownTheme themeForVariant:self.themeVariant].paperColor;
}

- (NSColor*)viewportBackgroundColor {
    return [SPDFMarkdownTheme themeForVariant:self.themeVariant].viewportBackgroundColor
               ?: spdf_canvas_background_color();
}

// Drawn AFTER the page content so the hairline stays crisp at the page edge.
// The half-pixel inset puts the 1px stroke's centerline on a device-pixel
// boundary at 1x and 2x alike, exactly like the Markdown canvas's border.
- (void)drawPageBorderInRect:(NSRect)pageRect {
    NSColor* border = self.pageBorderColor;
    if (!border || self.presentationMode) return;
    [border setStroke];
    NSBezierPath* path = [NSBezierPath bezierPathWithRect:NSInsetRect(pageRect, 0.5, 0.5)];
    path.lineWidth = 1.0;
    [path stroke];
}

@end
