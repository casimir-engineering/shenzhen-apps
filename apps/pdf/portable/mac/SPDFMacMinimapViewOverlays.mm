#import "SPDFMacMinimapViewOverlays.h"

#include <math.h>

@implementation SPDFMinimapView (Overlays)

- (void)drawRects:(NSArray<NSValue*>*)rects
         pageRect:(NSRect)pageRect
            scale:(CGFloat)scale
            color:(NSColor*)color
        minHeight:(CGFloat)minHeight {
    if (rects.count == 0) return;
    [color setFill];
    for (NSValue* value in rects) {
        NSRect r = [value rectValue];
        r.origin.x = NSMinX(pageRect) + r.origin.x * scale;
        r.origin.y = NSMinY(pageRect) + r.origin.y * scale;
        r.size.width = MAX(1.0, r.size.width * scale);
        r.size.height = MAX(minHeight, r.size.height * scale);
        NSRectFillUsingOperation(NSIntersectionRect(r, pageRect), NSCompositingOperationSourceOver);
    }
}

- (void)drawSearchRects:(NSArray<NSValue*>*)rects pageRect:(NSRect)pageRect scale:(CGFloat)scale {
    if (rects.count == 0) return;
    for (NSValue* value in rects) {
        NSRect r = [value rectValue];
        r.origin.x = NSMinX(pageRect) + r.origin.x * scale;
        r.origin.y = NSMinY(pageRect) + r.origin.y * scale;
        r.size.width = MAX(2.0, r.size.width * scale);
        r.size.height = MAX(3.0, r.size.height * scale);
        CGFloat cx = NSMidX(r);
        CGFloat cy = NSMidY(r);
        r.size.width *= 2.0;
        r.origin.x = cx - NSWidth(r) / 2.0;
        r.origin.y = cy - NSHeight(r) / 2.0;
        r = NSIntersectionRect(r, NSInsetRect(pageRect, -1.0, -1.0));
        if (NSIsEmptyRect(r)) continue;
        [[NSColor colorWithCalibratedRed:1.0 green:0.86 blue:0.06 alpha:0.88] setFill];
        NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:1.5 yRadius:1.5];
        [path fill];
        [[NSColor colorWithCalibratedRed:0.88 green:0.08 blue:0.03 alpha:0.96] setStroke];
        path.lineWidth = 1.1;
        [path stroke];
    }
}

@end
