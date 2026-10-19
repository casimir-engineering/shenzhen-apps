#import <Cocoa/Cocoa.h>

#import "SPDFMacMinimapView.h"

// Per-sheet overlays the strip draws over a thumbnail: find matches and the
// text selection. Split out of SPDFMacMinimapView.mm (a capped legacy file);
// both take page-space rects and the sheet's point-to-strip scale, and neither
// reads strip state, so the colors are concrete constants as in the document
// view.
@interface SPDFMinimapView (Overlays)

// Fills each page-space rect scaled into pageRect, clipped to the sheet.
- (void)drawRects:(NSArray<NSValue*>*)rects
         pageRect:(NSRect)pageRect
            scale:(CGFloat)scale
            color:(NSColor*)color
        minHeight:(CGFloat)minHeight;
// Find matches: widened yellow marks with a red outline, so a hit stays
// visible at thumbnail scale.
- (void)drawSearchRects:(NSArray<NSValue*>*)rects pageRect:(NSRect)pageRect scale:(CGFloat)scale;

@end
