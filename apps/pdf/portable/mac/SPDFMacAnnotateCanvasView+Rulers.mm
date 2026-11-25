// The canvas view's rulers (px, top and left), gridlines (1 px from 400 %) and the thumbnail of the whole picture while
// zoomed in (docs/plans/annotate.md § 1 View). Screen only.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import <objc/runtime.h>

static const CGFloat kRuler = 18.0;

@implementation SPDFMacAnnotateCanvasView (Rulers)


static CGFloat RulerStep(CGFloat scale) {
    const CGFloat steps[] = {1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000};
    for (int i = 0; i < 12; ++i)
        if (steps[i] * scale >= 50) return steps[i];
    return 10000;
}

- (void)drawRulersOnPage:(NSInteger)page {
    NSRect visible = self.visibleRect;
    NSRect canvas = [self canvasRectForPage:page];
    CGFloat scale = [self scaleForPage:page];
    if (NSIsEmptyRect(canvas) || scale <= 0) return;
    // The palette floats over the top of the page area (which itself starts under the toolbar): the top ruler sits
    // just below the palette, where it is seen.
    NSView* palette = (NSView*)self.controller.palette;
    if (palette.window == self.window && !palette.hiddenOrHasHiddenAncestor) {
        NSRect over = [self convertRect:palette.bounds fromView:palette];
        if (NSMaxY(over) > NSMinY(visible) && NSMaxY(over) < NSMidY(visible)) {
            CGFloat below = NSMaxY(over) + 4 - NSMinY(visible);
            visible.origin.y += below, visible.size.height -= below;
        }
    }
    NSRect top = NSMakeRect(NSMinX(visible), NSMinY(visible), NSWidth(visible), kRuler);
    NSRect left = NSMakeRect(NSMinX(visible), NSMinY(visible), kRuler, NSHeight(visible));
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.95] setFill];
    NSRectFill(top);
    NSRectFill(left);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(NSMinX(top), NSMaxY(top) - 1, NSWidth(top), 1));
    NSRectFill(NSMakeRect(NSMaxX(left) - 1, NSMinY(left), 1, NSHeight(left)));
    CGFloat step = RulerStep(scale);
    NSDictionary* text = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],
                           NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    [NSColor.secondaryLabelColor setFill];
    CGFloat first = floor((NSMinX(visible) - NSMinX(canvas)) / scale / step) * step;
    for (CGFloat v = first; NSMinX(canvas) + v * scale < NSMaxX(visible); v += step) {
        CGFloat x = round(NSMinX(canvas) + v * scale) + 0.5;
        if (x < NSMinX(visible) + kRuler) continue;
        NSRectFill(NSMakeRect(x, NSMaxY(top) - 7, 1, 6));
        [[NSString stringWithFormat:@"%.0f", v] drawAtPoint:NSMakePoint(x + 2, NSMinY(top) + 2) withAttributes:text];
    }
    first = floor((NSMinY(visible) - NSMinY(canvas)) / scale / step) * step;
    for (CGFloat v = first; NSMinY(canvas) + v * scale < NSMaxY(visible); v += step) {
        CGFloat y = round(NSMinY(canvas) + v * scale) + 0.5;
        if (y < NSMinY(visible) + kRuler) continue;
        NSRectFill(NSMakeRect(NSMaxX(left) - 7, y, 6, 1));
        [[NSString stringWithFormat:@"%.0f", v] drawAtPoint:NSMakePoint(NSMinX(left) + 1, y + 1) withAttributes:text];
    }
}

// A 1 px grid from 400 % (§ 1 View > Gridlines).
- (void)drawGridlinesInRect:(NSRect)dirty page:(NSInteger)page {
    if (!self.showsGridlines) return;
    CGFloat scale = [self scaleForPage:page];
    if (scale < 4) return;
    NSRect canvas = [self canvasRectForPage:page];
    NSRect area = NSIntersectionRect(NSIntersectionRect(canvas, dirty), self.visibleRect);
    if (NSIsEmptyRect(area)) return;
    [[NSColor.gridColor colorWithAlphaComponent:0.6] setFill];
    for (CGFloat x = NSMinX(canvas) + ceil((NSMinX(area) - NSMinX(canvas)) / scale) * scale; x <= NSMaxX(area); x += scale)
        NSRectFill(NSMakeRect(round(x), NSMinY(area), 1.0 / (self.window.backingScaleFactor ?: 2), NSHeight(area)));
    for (CGFloat y = NSMinY(canvas) + ceil((NSMinY(area) - NSMinY(canvas)) / scale) * scale; y <= NSMaxY(area); y += scale)
        NSRectFill(NSMakeRect(NSMinX(area), round(y), NSWidth(area), 1.0 / (self.window.backingScaleFactor ?: 2)));
}

- (void)drawThumbnail {
    spdf_paint_doc* doc = self.session.canvas;
    NSRect canvas = [self canvasRectForPage:-1];
    NSRect visible = self.visibleRect;
    if (!doc || NSContainsRect(visible, canvas)) return;  // only while zoomed in
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    CGFloat side = 160, fit = side / MAX(width, height);
    NSRect box = NSMakeRect(NSMaxX(visible) - width * fit - 12, NSMaxY(visible) - height * fit - 12, width * fit,
                            height * fit);
    static char key;
    NSDictionary* cached = objc_getAssociatedObject(self, &key);
    CGImageRef image = (__bridge CGImageRef)cached[@"image"];
    if (!image || [cached[@"generation"] unsignedLongLongValue] != spdf_paint_generation(doc)) {
        spdf_paint_render_options options;
        memset(&options, 0, sizeof(options));
        options.scale = (float)(fit * 2);
        spdf_bitmap bitmap = {0, 0, 0, NULL};
        char err[128];
        if (spdf_paint_render(doc, &options, &bitmap, err, sizeof(err)) != SPDF_PAINT_OK) return;
        NSData* data = [NSData dataWithBytes:bitmap.rgba length:(NSUInteger)bitmap.stride * (NSUInteger)bitmap.height];
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        image = CGImageCreate((size_t)bitmap.width, (size_t)bitmap.height, 8, 32, (size_t)bitmap.stride, srgb,
                              kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false,
                              kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(srgb);
        spdf_free_bitmap(&bitmap);
        if (!image) return;
        objc_setAssociatedObject(self, &key, @{@"image": CFBridgingRelease(image),
                                               @"generation": @(spdf_paint_generation(doc))},
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSShadow* shadow = [NSShadow new];
    shadow.shadowBlurRadius = 6;
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    [self drawCheckerboardInRect:box];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, NSMinX(box), NSMaxY(box));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(box), NSHeight(box)), image);
    CGContextRestoreGState(context);
    CGFloat scale = [self scaleForPage:-1];
    NSRect seen = NSIntersectionRect(visible, canvas);
    NSRect view = NSMakeRect(NSMinX(box) + (NSMinX(seen) - NSMinX(canvas)) / scale * fit,
                             NSMinY(box) + (NSMinY(seen) - NSMinY(canvas)) / scale * fit,
                             NSWidth(seen) / scale * fit, NSHeight(seen) / scale * fit);
    NSBezierPath* frame = [NSBezierPath bezierPathWithRect:NSInsetRect(view, 0.5, 0.5)];
    [NSColor.systemRedColor setStroke];
    [frame stroke];
}

@end
