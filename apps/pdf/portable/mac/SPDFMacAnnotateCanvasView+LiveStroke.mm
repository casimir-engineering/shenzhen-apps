// Pencil, the brushes, the Eraser and the Color Eraser shown as their release leaves them, every frame of the drag
// (SPDFMacAnnotateCanvasView.h). The core holds the stroke being drawn (spdf_paint_live_begin): its pixels in the
// active layer, with the layers above and below, the pen lines the Eraser cuts, without the lines the whole-line
// Eraser takes. Each new point costs only what it changes: on a picture or a canvas the screen tiles under that part
// are drawn again; on a PDF page that part of the page is drawn, as the reader will draw it on the release, into a
// picture of the same pixels laid over the reader's until the release. The release sends the same operation (the
// same seed: the Airbrush sprays the same dots), and the core lays exactly what was shown.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateLayersPanelPrivate.h"
#import "SPDFMacFillController.h"

#include <vector>

@implementation SPDFMacAnnotateCanvasView (LiveStroke)

- (NSMutableDictionary*)strokeOperationRight:(BOOL)right {
    SPDFMacAnnotateSession* session = self.session;
    if (session.tool == SPDFAnnotateToolPen)
        return [@{@"op": @"pen.add", @"color": [self colorFor:right], @"width": @([self toolSize])} mutableCopy];
    if (session.tool == SPDFAnnotateToolEraser && !session.eraserPixels)
        return [@{@"op": @"erase.lines", @"size": @(MAX(1, [self toolSize]))} mutableCopy];
    NSString* tool = session.tool == SPDFAnnotateToolEraser ? (right ? @"color_eraser" : @"eraser")
                                                            : SPDFAnnotateToolName(session.tool, session.brush);
    if (!self.liveStrokeSeed) self.liveStrokeSeed = arc4random() | 1;
    NSMutableDictionary* stroke = [@{@"op": @"paint.stroke", @"tool": tool,
                                     @"size": @(MAX(1, MIN(100, [self toolSize]))), @"seed": @(self.liveStrokeSeed)}
                                       mutableCopy];
    NSDictionary* options = [self toolOptions];
    if (options[@"opacity"]) stroke[@"opacity"] = options[@"opacity"];
    if (![tool isEqual:@"eraser"]) stroke[@"color"] = [self colorFor:right && ![tool isEqual:@"color_eraser"]];
    return stroke;
}

// What the core shows of the stroke changed over `changed` (canvas units): drawn again there.
- (void)liveStrokeShow:(spdf_rect)changed page:(NSInteger)page {
    if (changed.x1 <= changed.x0 || changed.y1 <= changed.y0) return;
    NSRect rect = NSMakeRect(changed.x0, changed.y0, changed.x1 - changed.x0, changed.y1 - changed.y0);
    self.liveStrokeRect = NSIsEmptyRect(self.liveStrokeRect) ? rect : NSUnionRect(self.liveStrokeRect, rect);
    if (page < 0) [self dropTilesOnPage:page inRect:rect];  // its screen tiles, small, drawn again
    else [self liveStrokePaintPicture:rect page:page];
    [self liveStrokeRedraw:rect page:page];
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFAnnotateLiveStrokeNotification object:self.controller];
}

// Drawn again on whole pixels of the screen: a part of a pixel drawn over blends with what was there before, and the
// stroke would keep that blend where no later point draws again.
- (void)liveStrokeRedraw:(NSRect)rect page:(NSInteger)page {
    NSRect view = NSInsetRect([self viewRectForCanvasRect:NSInsetRect(rect, -1, -1) page:page], -3, -3);
    [self setNeedsDisplayInRect:[self backingAlignedRect:view options:NSAlignAllEdgesOutward]];
}

- (void)liveStrokeSync {
    SPDFMacAnnotateSession* session = self.session;
    if ((self.gesture != SPDFAnnotateGestureStroke && !self.liveStroke) || session.tool == SPDFAnnotateToolPen) return;
    NSInteger page = self.liveStroke ? self.liveStrokePage : self.gesturePage;
    spdf_paint_doc* doc = [self docForPage:page];
    NSUInteger count = self.points.count, fed = self.liveStrokeFed;
    if (!doc || !count) return;
    // Shift straightens the stroke, a right-drag adds its press: the points so far are not the core's any more.
    if (!self.liveStroke || !spdf_paint_live_active(doc) || fed == 0 || fed > count ||
        !NSEqualPoints(self.points[fed - 1].pointValue, self.liveStrokeLastFed)) {
        [self liveStrokeDrop];
        if (self.gesture != SPDFAnnotateGestureStroke) return;
        NSData* json = [NSJSONSerialization dataWithJSONObject:[self strokeOperationRight:self.rightButton] options:0
                                                         error:nil];
        NSString* text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
        char err[256];
        if (!text || spdf_paint_live_begin(doc, text.UTF8String, err, sizeof(err)) != SPDF_PAINT_OK) return;
        self.liveStroke = YES;
        self.liveStrokePage = page;
        fed = 0;
    }
    // The values the release's operation will carry: two decimals, or as they are with a pressure.
    std::vector<float> xyp;
    for (NSUInteger i = fed; i < count; ++i) {
        NSPoint p = self.points[i].pointValue;
        double pressure = i < self.pressures.count ? self.pressures[i].doubleValue : 1;
        BOOL pressed = pressure < 0.999;
        xyp.push_back((float)(pressed ? p.x : round(p.x * 100) / 100));
        xyp.push_back((float)(pressed ? p.y : round(p.y * 100) / 100));
        xyp.push_back(pressed ? (float)pressure : 1.0f);
    }
    spdf_rect changed = {0, 0, 0, 0};
    spdf_paint_live_add(doc, xyp.data(), (int)(count - fed), &changed);
    self.liveStrokeFed = count;
    self.liveStrokeLastFed = self.points[count - 1].pointValue;
    [self liveStrokeShow:changed page:page];
}

// Puts back what the stroke shows (nothing when its release took it), keeping its seed.
- (void)liveStrokeDrop {
    NSInteger page = self.liveStrokePage;
    spdf_paint_doc* doc = self.liveStroke ? [self docForPage:page] : NULL;
    if (doc && spdf_paint_live_active(doc)) {
        spdf_rect changed;
        spdf_paint_live_cancel(doc, &changed);
        if (page < 0) [self dropTilesOnPage:page inRect:self.liveStrokeRect];
    }
    if (self.liveStroke && !NSIsEmptyRect(self.liveStrokeRect)) [self liveStrokeRedraw:self.liveStrokeRect page:page];
    self.liveStroke = NO;
    self.liveStrokeFed = 0;
    self.liveStrokeRect = NSZeroRect;
    self.liveStrokePicture = nil;
    self.liveStrokeArea = NSZeroRect;
}

- (void)liveStrokeEnded {
    [self liveStrokeDrop];
    self.liveStrokeSeed = 0;
}

#pragma mark - A PDF page: over the reader's picture

// The release writes the page and the reader draws again only what it reports changed (spdf_paint_live_written), two
// points around it, on its picture's pixels (fillPatchPage:area:); the rest of its picture stays as it is. So the
// stroke's picture holds that part only, drawn as the reader will draw it, and is clear elsewhere.
- (void)liveStrokePaintPicture:(NSRect)rect page:(NSInteger)page {
    spdf_paint_doc* doc = [self docForPage:page];
    NSRect covered = NSZeroRect, drawn = NSZeroRect;
    NSSize size = [self.controller.host fillShownPictureOfPage:page covering:&covered drawnAt:&drawn];
    CGFloat sx = [self.controller.host fillZoom] * (self.window.backingScaleFactor ?: 2.0);  // the reader's own scale
    spdf_rect written;
    if (!doc || size.width < 1 || size.height < 1 || sx <= 0 || !spdf_paint_live_written(doc, &written)) return;
    NSBitmapImageRep* picture = self.liveStrokePicture;
    NSRect before = self.liveStrokeArea;
    if (!picture || picture.pixelsWide != (NSInteger)size.width || picture.pixelsHigh != (NSInteger)size.height ||
        !NSEqualRects(covered, self.liveStrokeCovered)) {  // a new picture (the zoom changed): all of it again
        picture = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)size.width
                                                          pixelsHigh:(NSInteger)size.height bitsPerSample:8
                                                     samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                      colorSpaceName:NSDeviceRGBColorSpace
                                                         bytesPerRow:(NSInteger)size.width * 4 bitsPerPixel:32];
        if (!picture.bitmapData) return;
        memset(picture.bitmapData, 0, (size_t)picture.bytesPerRow * (size_t)picture.pixelsHigh);
        self.liveStrokePicture = picture;
        self.liveStrokeCovered = covered;
        before = NSZeroRect;
    }
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    NSRect area = NSIntersectionRect(NSInsetRect(NSMakeRect(written.x0, written.y0, written.x1 - written.x0,
                                                            written.y1 - written.y0), -2, -2),
                                     NSMakeRect(0, 0, width, height));
    // On the picture's pixels, as the reader cuts the part it draws again.
    NSRect pixelsOf = NSMakeRect(floor((NSMinX(area) - NSMinX(covered)) * sx), floor((NSMinY(area) - NSMinY(covered)) * sx), 0, 0);
    pixelsOf.size = NSMakeSize(ceil((NSMaxX(area) - NSMinX(covered)) * sx) - NSMinX(pixelsOf),
                               ceil((NSMaxY(area) - NSMinY(covered)) * sx) - NSMinY(pixelsOf));
    pixelsOf = NSIntersectionRect(pixelsOf, NSMakeRect(0, 0, size.width, size.height));
    if (NSIsEmptyRect(pixelsOf)) return;
    self.liveStrokeArea = pixelsOf;
    NSRect changed = NSMakeRect(floor((NSMinX(rect) - NSMinX(covered)) * sx), floor((NSMinY(rect) - NSMinY(covered)) * sx), 0, 0);
    changed.size = NSMakeSize(ceil((NSMaxX(rect) - NSMinX(covered)) * sx) - NSMinX(changed),
                              ceil((NSMaxY(rect) - NSMinY(covered)) * sx) - NSMinY(changed));
    // The release draws this part whole, from its own edges (spdf_paint_live_set_reader_crop): when it moves, all of
    // it is drawn again so, else only what changed in it.
    spdf_paint_live_set_reader_crop(doc, (spdf_rect){(float)(NSMinX(covered) + NSMinX(pixelsOf) / sx),
                                                     (float)(NSMinY(covered) + NSMinY(pixelsOf) / sx),
                                                     (float)(NSMinX(covered) + NSMaxX(pixelsOf) / sx),
                                                     (float)(NSMinY(covered) + NSMaxY(pixelsOf) / sx)}, (float)sx);
    NSMutableArray<NSValue*>* parts = [NSMutableArray arrayWithObject:@(NSIntersectionRect(changed, pixelsOf))];
    if (!NSEqualRects(before, pixelsOf)) parts = [NSMutableArray arrayWithObject:@(pixelsOf)];
    for (NSValue* value in parts) {
        NSRect px = NSIntersectionRect(value.rectValue, pixelsOf);
        if (!NSIsEmptyRect(px)) [self liveStrokeRender:px picture:picture covered:covered scale:sx doc:doc];
    }
    [self liveStrokeRedraw:NSMakeRect(NSMinX(covered) + NSMinX(pixelsOf) / sx, NSMinY(covered) + NSMinY(pixelsOf) / sx,
                                      NSWidth(pixelsOf) / sx, NSHeight(pixelsOf) / sx) page:page];
}

// Pixels px of the picture drawn from the page as it will be (spdf_paint_render_placed: the page, its annotations,
// the drawing layers as they will be written), in the reader's theme.
- (void)liveStrokeRender:(NSRect)px picture:(NSBitmapImageRep*)picture covered:(NSRect)covered scale:(CGFloat)sx
                     doc:(spdf_paint_doc*)doc {
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = (spdf_rect){(float)(NSMinX(covered) + NSMinX(px) / sx), (float)(NSMinY(covered) + NSMinY(px) / sx),
                                 (float)(NSMinX(covered) + NSMaxX(px) / sx), (float)(NSMinY(covered) + NSMaxY(px) / sx)};
    options.scale = (float)sx;
    if ([self.controller.host fillDarkPages]) {
        options.flags |= SPDF_PAINT_RENDER_DARK_PAGE;
        if ([self.controller.host fillDarkPagesKeepImages]) options.flags |= SPDF_PAINT_RENDER_DARK_KEEP_IMAGES;
    }
    spdf_bitmap part = {0, 0, 0, NULL};
    char err[256];
    if (spdf_paint_render_placed(doc, &options, NULL, 0, &part, err, sizeof(err)) != SPDF_PAINT_OK || !part.rgba) return;
    long w = picture.pixelsWide, h = picture.pixelsHigh, ax = (long)NSMinX(px), ay = (long)NSMinY(px);
    for (long y = 0; y < MIN((long)part.height, (long)NSHeight(px)); ++y) {
        long to = ay + y, n = MIN(MIN((long)part.width, (long)NSWidth(px)), w - ax);
        if (to < 0 || to >= h || n <= 0 || ax < 0) continue;
        memcpy(picture.bitmapData + (to * w + ax) * 4, part.rgba + y * part.stride, (size_t)n * 4);
    }
    spdf_free_bitmap(&part);
}

- (void)drawLiveStrokeInRect:(NSRect)dirty {
    NSBitmapImageRep* picture = self.liveStrokePicture;
    if (!picture || !self.liveStroke) return;
    NSInteger page = self.liveStrokePage;
    NSRect covered = NSZeroRect, drawn = NSZeroRect;
    NSSize size = [self.controller.host fillShownPictureOfPage:page covering:&covered drawnAt:&drawn];
    if (picture.pixelsWide != (NSInteger)size.width || picture.pixelsHigh != (NSInteger)size.height) return;
    NSRect view = [self convertRect:drawn fromView:nil];  // where the reader draws its picture
    NSRect canvas = [self canvasRectForPage:page];
    BOOL dark = [self.controller.host fillDarkPages];  // the reader frames a dark page with a 1 pt line
    NSRect clip = NSIntersectionRect(NSIntersectionRect(dirty, self.visibleRect), dark ? NSInsetRect(canvas, 1, 1) : canvas);
    if (NSIsEmptyRect(clip)) return;
    // In the display's own space, unconverted, as the reader's page pictures reach the screen (SPDFFillDeviceColor).
    CGColorSpaceRef display = self.window.colorSpace.CGColorSpace;
    CGColorSpaceRef space = display && CGColorSpaceGetModel(display) == kCGColorSpaceModelRGB
                                ? CGColorSpaceRetain(display) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSData* bytes = [NSData dataWithBytesNoCopy:picture.bitmapData length:(NSUInteger)picture.bytesPerRow * picture.pixelsHigh
                                   freeWhenDone:NO];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGImageRef image = CGImageCreate((size_t)picture.pixelsWide, (size_t)picture.pixelsHigh, 8, 32, (size_t)picture.bytesPerRow,
                                     space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    if (!image) return;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSRectToCGRect(clip));
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextTranslateCTM(context, NSMinX(view), NSMaxY(view));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(view), NSHeight(view)), image);
    CGContextRestoreGState(context);
    CGImageRelease(image);
}

@end
