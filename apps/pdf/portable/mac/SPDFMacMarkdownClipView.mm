#import "SPDFMacMarkdownClipView.h"

NSPoint spdf_mac_markdown_snap_origin(NSPoint origin, CGFloat magnification, CGFloat backingScale) {
    CGFloat pixelsPerUnit = MAX(0.0001, magnification) * MAX(1.0, backingScale);
    return NSMakePoint(round(origin.x * pixelsPerUnit) / pixelsPerUnit,
                       round(origin.y * pixelsPerUnit) / pixelsPerUnit);
}

@implementation SPDFMacMarkdownClipView

- (NSRect)constrainBoundsRect:(NSRect)proposedBounds {
    // The superclass applies the page-aware locks (a fitted page pinned
    // centered, a wide page panning within itself); snapping runs last so a
    // lock's exact value is never nudged back off the pixel grid by more than
    // it takes to sit on it.
    NSRect bounds = [super constrainBoundsRect:proposedBounds];
    NSScrollView* scrollView = self.enclosingScrollView;
    CGFloat backingScale = self.window ? self.window.backingScaleFactor : 2.0;
    bounds.origin = spdf_mac_markdown_snap_origin(bounds.origin, scrollView ? scrollView.magnification : 1.0,
                                                  backingScale);
    return bounds;
}

@end
