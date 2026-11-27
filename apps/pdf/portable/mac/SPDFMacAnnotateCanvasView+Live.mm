// The selected objects follow a resize handle, a move or the rotation handle while the button is held, every frame
// (SPDFMacAnnotateCanvasView.h).
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

// The boxes the gesture in progress puts objects at, or nil when it moves none (a rotation keeps the box).
- (NSDictionary<NSNumber*, NSValue*>*)livePlacements {
    NSInteger page = self.gesturePage;
    if (self.gesture == SPDFAnnotateGestureResize) return [self rectsForResizeTo:[self resizedRect] page:page];
    if (self.gesture == SPDFAnnotateGestureRotate) {
        CGFloat dx = self.currentPoint.x - self.startPoint.x, dy = self.currentPoint.y - self.startPoint.y;
        NSNumber* id = self.session.selectedObjects.firstObject;
        if (!id || hypot(dx, dy) * [self scaleForPage:page] < kClickSlop) return nil;  // as the release: no turn
        for (NSDictionary* object in [self objectsOnPage:page])
            if ([object[@"id"] isEqual:id]) return @{id: object[@"rect"]};
        return nil;
    }
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
        // Turned, or being turned: the circle around the new box.
        if (self.gesture == SPDFAnnotateGestureRotate || fmod(fabs([object[@"rotation"] doubleValue]), 360) > 0.01)
            reach = MAX(reach, 0) + hypot(NSWidth(to), NSHeight(to)) / 2 - MIN(NSWidth(to), NSHeight(to)) / 2;
        NSRect around = NSInsetRect(to, -MAX(reach, 0) - 2, -MAX(reach, 0) - 2);
        region = NSUnionRect(region, NSUnionRect(NSInsetRect(bounds, -2, -2), around));
    }
    return NSIntersectionRect(region, [self canvasBoundsOfPage:page]);
}

- (NSRect)canvasBoundsOfPage:(NSInteger)page {
    int width = 0, height = 0;
    spdf_paint_size([self docForPage:page], &width, &height);
    return NSMakeRect(0, 0, width, height);
}

- (void)drawLiveTransformInRect:(NSRect)dirty {
    [self drawLiveStrokeInRect:dirty];  // a stroke being drawn on a PDF page (+LiveStroke.mm)
    if (self.gesture != SPDFAnnotateGestureResize && self.gesture != SPDFAnnotateGestureMove &&
        self.gesture != SPDFAnnotateGestureRotate)
        return;
    BOOL turns = self.gesture == SPDFAnnotateGestureRotate;
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
    // On a page, where the reader's own picture puts its pixels: it is rendered on the same pixel grid but drawn
    // stretched onto the page by a hair when the page's size in pixels isn't whole (Fit Page), so the region is drawn
    // the same way (drawReaderPixels:).
    NSRect covered = NSZeroRect, drawn = NSZeroRect;
    NSSize shownPixels =
        page >= 0 ? [self.controller.host fillShownPictureOfPage:page covering:&covered drawnAt:&drawn] : NSZeroSize;
    BOOL asReader = shownPixels.width > 0 && shownPixels.height > 0;
    CGFloat x0 = floor(NSMinX(area) * pixels) / pixels, y0 = floor(NSMinY(area) * pixels) / pixels;
    CGFloat x1 = ceil(NSMaxX(area) * pixels) / pixels, y1 = ceil(NSMaxY(area) * pixels) / pixels;
    std::vector<spdf_paint_placed> list;
    for (NSNumber* key in placements) {
        NSRect r = placements[key].rectValue;
        // A rotation sends what the release sends: the object's own rect untouched, the rotation it ends at.
        spdf_paint_placed at = {(spdf_paint_id)key.unsignedIntValue,
                                {(float)NSMinX(r), (float)NSMinY(r), (float)NSMaxX(r), (float)NSMaxY(r)}, turns ? 1 : 0,
                                turns ? (double)(self.originalRotation + [self rotationDelta]) : 0.0};
        list.push_back(at);
    }
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = (spdf_rect){(float)x0, (float)y0, (float)x1, (float)y1};
    options.scale = (float)pixels;
    if (page >= 0 && [self.controller.host fillDarkPages]) {  // recoloured as the reader recolours the page
        options.flags |= SPDF_PAINT_RENDER_DARK_PAGE;
        if ([self.controller.host fillDarkPagesKeepImages]) options.flags |= SPDF_PAINT_RENDER_DARK_KEEP_IMAGES;
    }
    spdf_bitmap bitmap = {0, 0, 0, NULL};
    char err[256];
    if (spdf_paint_render_placed(doc, &options, list.data(), (int)list.size(), &bitmap, err, sizeof(err)) != SPDF_PAINT_OK ||
        !bitmap.rgba)
        return;
    BOOL dark = page >= 0 && [self.controller.host fillDarkPages];  // the reader frames a dark page with a 1 pt line
    NSRect clip = NSIntersectionRect(shown, dark ? NSInsetRect(canvas, 1, 1) : canvas);
    if (asReader) {  // the reader's pixel i is its first (fz_round_rect's floor) plus i, drawn at i * view / pixels
        NSRect view = [self convertRect:drawn fromView:nil];  // exactly where the reader draws it
        NSPoint at = NSMakePoint(round(x0 * pixels) - floor(NSMinX(covered) * pixels + 0.001),
                                 round(y0 * pixels) - floor(NSMinY(covered) * pixels + 0.001));
        [self drawReaderPixels:&bitmap at:at ofPicture:shownPixels in:view clip:clip];
        return;
    }
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
    CGContextClipToRect(context, NSRectToCGRect(clip));
    if (page < 0) [self drawCheckerboardInRect:target];  // under transparency, as the tiles
    CGContextSetInterpolationQuality(context, scale >= 1.0 && page < 0 ? kCGInterpolationNone : kCGInterpolationHigh);
    CGContextTranslateCTM(context, NSMinX(target), NSMaxY(target));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(target), NSHeight(target)), image);
    CGContextRestoreGState(context);
    CGImageRelease(image);
}

// Page pixels drawn as the reader draws its page pictures (renderedPageCropImageAtIndex: and
// spdf_mac_draw_page_image): a device RGB bitmap in an NSImage drawn unsmoothed into the rect of the picture shown.
// When that picture is stretched by a hair (a page whose width in pixels isn't whole), which source column lands on
// a screen column depends on where the picture starts, so the bitmap is placed at `at` in a transparent picture the
// size of the reader's and drawn as the reader draws its own. Frees the bitmap.
- (void)drawReaderPixels:(spdf_bitmap*)bitmap at:(NSPoint)at ofPicture:(NSSize)size in:(NSRect)view clip:(NSRect)clip {
    CGFloat backing = self.window.backingScaleFactor ?: 2.0;
    BOOL exact = fabs(NSWidth(view) * backing - size.width) < 1e-3 && fabs(NSHeight(view) * backing - size.height) < 1e-3;
    NSInteger x = exact ? 0 : (NSInteger)at.x, y = exact ? 0 : (NSInteger)at.y;
    NSInteger w = exact ? bitmap->width : (NSInteger)size.width, h = exact ? bitmap->height : (NSInteger)size.height;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
                                                                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                                                                      isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:w * 4 bitsPerPixel:32];
    unsigned char* pixels = rep.bitmapData;
    if (pixels) {
        if (!exact) memset(pixels, 0, (size_t)w * 4 * (size_t)h);
        for (NSInteger row = 0; row < bitmap->height; row++) {
            NSInteger to = y + row, from = MAX(0, -x), count = MIN((NSInteger)bitmap->width, w - x) - from;
            if (to < 0 || to >= h || count <= 0) continue;
            memcpy(pixels + ((size_t)to * w + (size_t)(x + from)) * 4,
                   bitmap->rgba + (size_t)row * bitmap->stride + (size_t)from * 4, (size_t)count * 4);
        }
    }
    spdf_free_bitmap(bitmap);
    if (!pixels) return;
    NSRect target = exact ? NSMakeRect(NSMinX(view) + at.x / backing, NSMinY(view) + at.y / backing, w / backing,
                                       h / backing)
                          : view;
    rep.size = target.size;
    NSImage* image = [[NSImage alloc] initWithSize:target.size];
    [image addRepresentation:rep];
    NSGraphicsContext* context = NSGraphicsContext.currentContext;
    NSImageInterpolation old = context.imageInterpolation;
    context.imageInterpolation = NSImageInterpolationNone;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(clip);
    [image drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
       respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationNone)}];
    [NSGraphicsContext restoreGraphicsState];
    context.imageInterpolation = old;
}

@end
