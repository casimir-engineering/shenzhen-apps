#import <Cocoa/Cocoa.h>

#import "SPDFMacMinimapView.h"
#import "markdown/SPDFMarkdownDecorations.h"

// The minimap strip's reading-theme chrome, split out of SPDFMacMinimapView.mm
// the way SPDFMacDocumentViewTheme.mm is split out of the document view: the
// palette decisions stay together (and stay probeable) without the
// layout/hit-testing half of the strip.
@interface SPDFMinimapView (Theme)

// Gutter behind the sheets. Dark names its own #121212, clearly below the
// #1E1E1E paper; light keeps windowBackgroundColor.
- (NSColor*)stripBackgroundColor;
// A sheet's own paper, painted under the thumbnail.
- (NSColor*)pageFillColor;
// Drawn after the page content: the 1px frame that separates a dark sheet from
// the gutter. No-op in a theme that draws a paper shadow instead (light).
- (void)drawPageBorderInRect:(NSRect)pageRect;
// The "not rendered yet" ruled-lines stand-in, tinted for the active theme.
- (void)drawPlaceholderInRect:(NSRect)rect;

@end
