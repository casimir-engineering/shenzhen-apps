// The selected objects follow a resize handle or a move while the button is held, every frame (SPDFMacAnnotateCanvasView.h).
// Nothing changes until the release: the region the objects cover, before and where the gesture puts them, is drawn
// again here from the canvas with the objects at their new boxes (spdf_paint_render_placed) over what is under them.
// On a picture or a canvas that covers the cached tiles; on a PDF page it covers the reader's page image, which
// still shows the objects where they were: the region is drawn with the page itself, as the reader draws it.
// The release applies the change and drops the preview in the same display pass, so no frame shows the old place.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacFillController.h"

#include <vector>

static const CGFloat kClickSlop = 4.0;  // as +Gestures.mm: under it, a press on an object moves nothing

@implementation SPDFMacAnnotateCanvasView (Live)

// Each selected object's box the resize to `to` gives (canvas units): one object takes `to`, several are mapped from
// the box around them onto it.
- (NSDictionary<NSNumber*, NSValue*>*)rectsForResizeTo:(NSRect)to page:(NSInteger)page {
    NSArray<NSNumber*>* ids = self.session.selectedObjects;
    NSRect from = self.originalRect;
    if (ids.count == 1 || NSWidth(from) <= 0 || NSHeight(from) <= 0)
        return ids.firstObject ? @{ids.firstObject: @(to)} : @{};
    NSMutableDictionary* rects = [NSMutableDictionary dictionary];
    CGFloat sx = NSWidth(to) / NSWidth(from), sy = NSHeight(to) / NSHeight(from);
    for (NSDictionary* object in [self objectsOnPage:page]) {
        if (![ids containsObject:object[@"id"]]) continue;
        NSRect r = [object[@"rect"] rectValue];
        rects[object[@"id"]] = @(NSMakeRect(NSMinX(to) + (NSMinX(r) - NSMinX(from)) * sx,
                                            NSMinY(to) + (NSMinY(r) - NSMinY(from)) * sy, NSWidth(r) * sx, NSHeight(r) * sy));
    }
    return rects;
}

// The boxes the gesture in progress puts objects at, or nil when it moves none.
- (NSDictionary<NSNumber*, NSValue*>*)livePlacements {
    NSInteger page = self.gesturePage;
    if (self.gesture == SPDFAnnotateGestureResize) return [self rectsForResizeTo:[self resizedRect] page:page];
    if (self.gesture != SPDFAnnotateGestureMove || !self.dragObjects.count) return nil;
    CGFloat dx = self.currentPoint.x - self.startPoint.x, dy = self.currentPoint.y - self.startPoint.y;
    if (hypot(dx, dy) * [self scaleForPage:page] < kClickSlop) return nil;
    NSMutableDictionary* rects = [NSMutableDictionary dictionary];
    for (NSDictionary* object in [self objectsOnPage:page])
        if ([self.dragObjects containsObject:object[@"id"]])
            rects[object[@"id"]] = @(NSOffsetRect([object[@"rect"] rectValue], dx, dy));
    return rects;
}

// What the objects cover, where they are and where they go (canvas units): an object's painted reach past its box (a
// thick outline, an arrowhead, a turned box's corners) is kept around the new box.
- (NSRect)liveRegionFor:(NSDictionary<NSNumber*, NSValue*>*)placements page:(NSInteger)page {
    NSRect region = NSZeroRect;
    for (NSDictionary* object in [self objectsOnPage:page]) {
        NSValue* placed = placements[object[@"id"]];
        if (!placed) continue;
        NSRect bounds = [object[@"bounds"] rectValue], rect = [object[@"rect"] rectValue], to = placed.rectValue;
        CGFloat reach = MAX(MAX(NSMinX(rect) - NSMinX(bounds), NSMaxX(bounds) - NSMaxX(rect)),
                            MAX(NSMinY(rect) - NSMinY(bounds), NSMaxY(bounds) - NSMaxY(rect)));
        if (fmod(fabs([object[@"rotation"] doubleValue]), 360) > 0.01)  // turned: the circle around the new box
            reach = MAX(reach, 0) + hypot(NSWidth(to), NSHeight(to)) / 2 - MIN(NSWidth(to), NSHeight(to)) / 2;
        NSRect around = NSInsetRect(to, -MAX(reach, 0) - 2, -MAX(reach, 0) - 2);
        region = NSUnionRect(region, NSUnionRect(NSInsetRect(bounds, -2, -2), around));
    }
    int width = 0, height = 0;
    spdf_paint_size([self docForPage:page], &width, &height);
    return NSIntersectionRect(region, NSMakeRect(0, 0, width, height));
}

- (void)drawLiveTransformInRect:(NSRect)dirty {
    if (self.gesture != SPDFAnnotateGestureResize && self.gesture != SPDFAnnotateGestureMove) return;
    NSInteger page = self.gesturePage;
    spdf_paint_doc* doc = [self docForPage:page];
    NSDictionary<NSNumber*, NSValue*>* placements = doc ? [self livePlacements] : nil;
    if (!placements.count) return;
    NSRect region = [self liveRegionFor:placements page:page];
    NSRect shown = NSIntersectionRect(NSIntersectionRect([self viewRectForCanvasRect:region page:page], dirty), self.visibleRect);
    if (NSIsEmptyRect(shown)) return;
    // Only the part to draw, in canvas units, its edges on whole pixels of the bitmap.
    NSRect canvas = [self canvasRectForPage:page];
    CGFloat scale = [self scaleForPage:page];
    CGFloat device = scale * (self.window.backingScaleFactor ?: 2.0);
    CGFloat pixels = page < 0 ? MIN(ldexp(1.0, (int)ceil(log2(MAX(device, 1.0 / 64)))), 1.0) : device;  // as the tiles
    NSRect area = NSMakeRect((NSMinX(shown) - NSMinX(canvas)) / scale, (NSMinY(shown) - NSMinY(canvas)) / scale,
                             NSWidth(shown) / scale, NSHeight(shown) / scale);
    CGFloat x0 = floor(NSMinX(area) * pixels) / pixels, y0 = floor(NSMinY(area) * pixels) / pixels;
    CGFloat x1 = ceil(NSMaxX(area) * pixels) / pixels, y1 = ceil(NSMaxY(area) * pixels) / pixels;
    std::vector<spdf_paint_placed> list;
    for (NSNumber* key in placements) {
        NSRect r = placements[key].rectValue;
        list.push_back({(spdf_paint_id)key.unsignedIntValue,
                        {(float)NSMinX(r), (float)NSMinY(r), (float)NSMaxX(r), (float)NSMaxY(r)}});
    }
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = (spdf_rect){(float)x0, (float)y0, (float)x1, (float)y1};
    options.scale = (float)pixels;
    if (page >= 0 && [self.controller.host fillDarkPages]) options.flags |= SPDF_PAINT_RENDER_DARK_PAGE;
    spdf_bitmap bitmap = {0, 0, 0, NULL};
    char err[256];
    if (spdf_paint_render_placed(doc, &options, list.data(), (int)list.size(), &bitmap, err, sizeof(err)) != SPDF_PAINT_OK ||
        !bitmap.rgba)
        return;
    NSData* data = [NSData dataWithBytesNoCopy:bitmap.rgba length:(NSUInteger)bitmap.stride * (NSUInteger)bitmap.height
                                  freeWhenDone:YES];
    // A page as the reader shows its page images: their pixels unconverted, in the display's own space
    // (SPDFFillDeviceColor); a picture as its tiles, in sRGB.
    CGColorSpaceRef display = page >= 0 ? self.window.colorSpace.CGColorSpace : NULL;
    CGColorSpaceRef srgb = display && CGColorSpaceGetModel(display) == kCGColorSpaceModelRGB
                               ? CGColorSpaceRetain(display) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image = CGImageCreate((size_t)bitmap.width, (size_t)bitmap.height, 8, 32, (size_t)bitmap.stride, srgb,
                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(srgb);
    if (!image) return;
    NSRect target = NSMakeRect(NSMinX(canvas) + x0 * scale, NSMinY(canvas) + y0 * scale,
                               bitmap.width / pixels * scale, bitmap.height / pixels * scale);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSRectToCGRect(NSIntersectionRect(shown, canvas)));
    if (page < 0) [self drawCheckerboardInRect:target];  // under transparency, as the tiles
    CGContextSetInterpolationQuality(context, scale >= 1.0 && page < 0 ? kCGInterpolationNone : kCGInterpolationHigh);
    CGContextTranslateCTM(context, NSMinX(target), NSMaxY(target));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(target), NSHeight(target)), image);
    CGContextRestoreGState(context);
    CGImageRelease(image);
}

@end
