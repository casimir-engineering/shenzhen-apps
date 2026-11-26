// What Annotate draws over a picture or each PDF page (SPDFMacAnnotateCanvasView.h): geometry, the composite tiles
// and the drawing order. Gestures are in +Gestures.mm, ants, handles and rulers in +Decorations.mm.
//
// Tiles. The composite is cached as 256 x 256 device-pixel tiles per page and level. A level is the render scale: 1
// (canvas pixels) for a picture at 100 % and above, where the tiles are drawn with nearest neighbour so pixels stay
// sharp; a power of two below 1 when zoomed out, never less than the screen needs. A change only drops the tiles under
// its damage (spdf_paint_take_damage), so an 8000 x 8000 picture redraws what one stroke touched, not the picture.
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateOperations.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacDocumentView.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacModels.h"
#import "SPDFMacPageRendering.h"

NSNotificationName const SPDFAnnotateCanvasPointerDidMoveNotification = @"SPDFAnnotateCanvasPointerDidMove";

static const int kTileSide = 256;  static const NSUInteger kMaxTiles = 600;  // device pixels; ~150 MB at most

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation SPDFMacAnnotateCanvasView {
    NSMutableDictionary<NSString*, id>* _tiles;  // "page:level:tx:ty" -> CGImageRef
    NSMutableDictionary<NSNumber*, NSNumber*>* _generations;
    NSTrackingArea* _tracking;
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _controller = controller;
        _tiles = [NSMutableDictionary dictionary];
        _generations = [NSMutableDictionary dictionary];
        _points = [NSMutableArray array];
        _pressures = [NSMutableArray array];
        _pointerPage = -1;
        _gesturePage = -1;
        self.wantsLayer = NO;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionChanged:)
                                                   name:SPDFAnnotateSessionDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editTextRequested:)
                                                   name:SPDFAnnotateEditTextNotification object:controller];
    }
    return self;
}

static char kSPDFAnnotateZoomContext;

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_zoomWatched removeObserver:self forKeyPath:@"zoom" context:&kSPDFAnnotateZoomContext];
    [_antsTimer invalidate];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return self.session != nil; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

#pragma mark - Placement

- (void)attachBelowOverlay:(SPDFMacFillOverlayView*)overlay {
    self.overlay = overlay;
    NSView* host = overlay.superview;
    if (!host) return;
    if (self.superview != host || host.subviews.lastObject != self) {
        [self removeFromSuperview];
        [host addSubview:self positioned:NSWindowAbove relativeTo:overlay];
    }
    self.frame = overlay.frame;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:nil];
    NSView* clip = [host isKindOfClass:NSScrollView.class] ? ((NSScrollView*)host).contentView : nil;
    if (clip) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(viewportChanged:)
                                                   name:NSViewBoundsDidChangeNotification object:clip];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(viewportChanged:)
                                                   name:NSViewFrameDidChangeNotification object:clip];
    }
    // A zoom that keeps the pages inside the window (a picture zoomed out from 100 %) neither scrolls nor resizes: the
    // canvas and the status bar followed only the others, and showed the old size and percentage.
    SPDFDocumentView* pages = [self documentView];
    if (pages != self.zoomWatched) {
        [self.zoomWatched removeObserver:self forKeyPath:@"zoom" context:&kSPDFAnnotateZoomContext];
        [pages addObserver:self forKeyPath:@"zoom" options:0 context:&kSPDFAnnotateZoomContext];
        self.zoomWatched = pages;
    }
    self.needsDisplay = YES;
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change
                       context:(void*)context {
    if (context != &kSPDFAnnotateZoomContext) return [super observeValueForKeyPath:keyPath ofObject:object
                                                                            change:change context:context];
    __weak SPDFMacAnnotateCanvasView* weakSelf = self;  // once the reader has laid the pages out at the new zoom
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf viewportChanged:nil]; });
}

- (void)viewportChanged:(NSNotification*)note {
    (void)note;
    if (self.hidden) return;
    if (self.overlay && !NSEqualRects(self.frame, self.overlay.frame)) self.frame = self.overlay.frame;
    if (self.textEditor) [self layoutTextEditor];
    self.needsDisplay = YES;
    // The status bar's zoom follows scrolling and zooming.
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFAnnotateCanvasPointerDidMoveNotification object:self];
}

- (void)setSession:(SPDFMacAnnotateSession*)session {
    if (session == _session) return;
    if (_session) [self commitTextEditor];
    [self cancelGesture];
    _session = session;
    self.hasPointer = NO;  // the pointer position of another document means nothing here
    [_tiles removeAllObjects];
    [_generations removeAllObjects];
    [self updateAntsTimer];
    self.needsDisplay = YES;
}

// Events go to the overlay below whenever the tool is one of Fill & Sign's own on a PDF.
- (NSView*)hitTest:(NSPoint)point {
    if (self.hidden || !self.session || self.holdsLastFrame) return nil;
    BOOL takes = [self takesEventsForTool:self.session.tool] || [self takesSelectPressAt:[self convertPoint:point fromView:self.superview]];
    return takes ? [super hitTest:point] : nil;
}

- (BOOL)takesEventsForTool:(SPDFAnnotateTool)tool {
    switch (tool) {
        case SPDFAnnotateToolFormText:
        case SPDFAnnotateToolFormMark:
        case SPDFAnnotateToolFormSignature:
            return NO;
        case SPDFAnnotateToolPen:
        case SPDFAnnotateToolArrow:
        case SPDFAnnotateToolSelect:
            return self.session.kind != SPDFAnnotateDocumentPDF;
        case SPDFAnnotateToolEraser:
            return self.session.kind != SPDFAnnotateDocumentPDF || self.session.eraserPixels;
        default:
            return YES;
    }
}

- (void)takeKeys {
    if (self.window && self.session && self.window.firstResponder != self && !self.textEditor)
        [self.window makeFirstResponder:self];
}

- (void)holdLastFrameUntilReload {
    [self commitTextEditor];
    self.holdsLastFrame = YES;
    self.needsDisplay = YES;
}

- (void)releaseHeldFrame {
    if (!self.holdsLastFrame) return;
    self.holdsLastFrame = NO;
    if (![self.controller isShowing]) {
        self.session = nil;
        self.hidden = YES;
    }
    self.needsDisplay = YES;
}

#pragma mark - Geometry

- (SPDFDocumentView*)documentView {
    NSView* host = self.superview;
    NSView* view = [host isKindOfClass:NSScrollView.class] ? ((NSScrollView*)host).documentView : nil;
    return [view isKindOfClass:SPDFDocumentView.class] ? (SPDFDocumentView*)view : nil;
}

- (spdf_paint_doc*)docForPage:(NSInteger)page {
    return [self.session canvasForPage:page document:NULL create:NO];
}

- (NSRect)canvasRectForPage:(NSInteger)page {
    SPDFDocumentView* view = [self documentView];
    spdf_paint_doc* doc = [self docForPage:page];
    // A PDF page is its own canvas, in points, before anything opened it (its canvas opens with the first gesture).
    if (!view || (!doc && page < 0)) return NSZeroRect;
    NSInteger index = page < 0 ? 0 : page;
    if (index >= (NSInteger)view.pages.count) return NSZeroRect;
    NSRect pageRect = [self convertRect:[view rectForPageAtIndex:index] fromView:view];
    if (!doc) return pageRect;
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    if (page >= 0) return pageRect;  // a PDF page canvas is the page, in points
    NSSize reader = self.session.readerPixelSize;
    CGFloat scale = reader.width > 0 ? NSWidth(pageRect) / reader.width : 1;
    return NSMakeRect(NSMinX(pageRect), NSMinY(pageRect), width * scale, height * scale);
}

- (CGFloat)scaleForPage:(NSInteger)page {
    spdf_paint_doc* doc = [self docForPage:page];
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    NSRect rect = [self canvasRectForPage:page];
    SPDFRenderedPage* shown = !doc && page >= 0 && page < (NSInteger)self.documentView.pages.count ? self.documentView.pages[page] : nil;
    if (shown) width = (int)lround(NSWidth(rect) > NSHeight(rect) != shown.pageWidth > shown.pageHeight ? shown.pageHeight : shown.pageWidth);
    return width > 0 && NSWidth(rect) > 0 ? NSWidth(rect) / width : 1;
}

// The zoom the status bar shows: on a PDF the reader's own, on a picture or canvas the canvas scale; the toolbar counts
// from -actualZoom, so both say the same number.
- (CGFloat)zoomLevel {
    // A picture's or canvas's 100% is one picture pixel per screen point (-actualZoom in SPDFMacFitViewport.mm).
    if (self.session && self.session.kind != SPDFAnnotateDocumentPDF) return [self scaleForPage:-1];
    CGFloat zoom = [self.controller.host fillZoom];
    if (zoom > 0) return zoom;
    NSInteger page = self.session.kind == SPDFAnnotateDocumentPDF ? MAX(0, self.session.currentPage) : -1;
    return [self scaleForPage:page];
}

- (NSArray<NSNumber*>*)pagesInView {
    if (!self.session) return @[];
    if (self.session.kind != SPDFAnnotateDocumentPDF) return @[@(-1)];
    NSMutableArray* pages = [NSMutableArray array];
    NSIndexSet* open = self.session.openPages;
    for (NSNumber* page in [self.overlay visiblePages])
        if ([open containsIndex:page.unsignedIntegerValue]) [pages addObject:page];
    return pages;
}

- (NSRect)viewRectForCanvasRect:(NSRect)rect page:(NSInteger)page {
    NSRect canvas = [self canvasRectForPage:page];
    CGFloat scale = [self scaleForPage:page];
    return NSMakeRect(NSMinX(canvas) + NSMinX(rect) * scale, NSMinY(canvas) + NSMinY(rect) * scale,
                      NSWidth(rect) * scale, NSHeight(rect) * scale);
}

- (NSPoint)viewPointForCanvasPoint:(NSPoint)point page:(NSInteger)page {
    NSRect canvas = [self canvasRectForPage:page];
    CGFloat scale = [self scaleForPage:page];
    return NSMakePoint(NSMinX(canvas) + point.x * scale, NSMinY(canvas) + point.y * scale);
}

- (BOOL)canvasPointForViewPoint:(NSPoint)point page:(NSInteger*)page canvasPoint:(NSPoint*)canvasPoint {
    NSInteger found = -1;
    if (self.session.kind == SPDFAnnotateDocumentPDF) {
        NSPoint ignored;
        if (![self.overlay locateViewPoint:point page:&found pagePoint:&ignored]) return NO;
    }
    NSRect canvas = [self canvasRectForPage:found];
    CGFloat scale = [self scaleForPage:found];
    if (NSIsEmptyRect(canvas) || scale <= 0) return NO;
    if (page) *page = found;
    if (canvasPoint) *canvasPoint = NSMakePoint((point.x - NSMinX(canvas)) / scale, (point.y - NSMinY(canvas)) / scale);
    return NSPointInRect(point, canvas);
}

- (void)redrawCanvasRect:(NSRect)rect page:(NSInteger)page inflate:(CGFloat)points {
    [self setNeedsDisplayInRect:NSInsetRect([self viewRectForCanvasRect:rect page:page], -points - 2, -points - 2)];
}

#pragma mark - Changes

- (void)sessionChanged:(NSNotification*)note {
    if (note.object != self.session) return;
    for (NSNumber* page in self.session.kind == SPDFAnnotateDocumentPDF ? (NSArray*)self.pagesInView : @[@(-1)])
        [self canvasDidChangeOnPage:page.integerValue];
    [self updateAntsTimer];
}

- (void)canvasDidChangeOnPage:(NSInteger)page {
    spdf_paint_doc* doc = [self docForPage:page];
    if (!doc) return;
    spdf_rect damage;
    uint64_t generation = spdf_paint_generation(doc);
    BOOL damaged = spdf_paint_take_damage(doc, &damage);
    BOOL changed = generation != _generations[@(page)].unsignedLongLongValue;
    _generations[@(page)] = @(generation);
    if (damaged) {
        NSRect rect = NSMakeRect(damage.x0, damage.y0, damage.x1 - damage.x0, damage.y1 - damage.y0);
        [self dropTilesOnPage:page inRect:rect];
        [self redrawCanvasRect:rect page:page inflate:2];
    } else if (changed) {
        [self dropTilesOnPage:page inRect:NSZeroRect];
        self.needsDisplay = YES;
    }
    [self setNeedsDisplayInRect:self.shownSelectionRect];  // the box and handles where they were, and are now
    self.shownSelectionRect = NSInsetRect([self selectedObjectsViewRect], -24, -36);
    [self setNeedsDisplayInRect:self.shownSelectionRect];
}

- (void)canvasSizeDidChange {
    [_tiles removeAllObjects];
    self.needsDisplay = YES;
}

- (void)toolDidChange {
    // A polygon or curve being clicked out ends unfinished when another tool is chosen.
    NSString* shape = self.gesture == SPDFAnnotateGesturePolygon ? @"polygon" : @"curve";
    if ((self.gesture == SPDFAnnotateGesturePolygon || self.gesture == SPDFAnnotateGestureCurve) &&
        !(self.session.tool == SPDFAnnotateToolShape && [self.session.shape isEqual:shape]))
        [self cancelGesture];
    if (self.textEditor && self.session.tool != SPDFAnnotateToolTextBox) [self commitTextEditor];  // as Paint
    [self.window invalidateCursorRectsForView:self];
    self.needsDisplay = YES;
}

#pragma mark - Tiles

static NSString* TileKey(NSInteger page, int level, int tx, int ty) {
    return [NSString stringWithFormat:@"%ld:%d:%d:%d", (long)page, level, tx, ty];
}

// A tile's box in canvas units at a level (render scale 2^level).
static NSRect TileRect(int level, int tx, int ty) {
    CGFloat unit = kTileSide / ldexp(1.0, level);
    return NSMakeRect(tx * unit, ty * unit, unit, unit);
}

- (void)dropTilesOnPage:(NSInteger)page inRect:(NSRect)rect {
    NSString* prefix = [NSString stringWithFormat:@"%ld:", (long)page];
    for (NSString* key in _tiles.allKeys) {
        if (![key hasPrefix:prefix]) continue;
        NSArray* parts = [key componentsSeparatedByString:@":"];
        NSRect tile = TileRect([parts[1] intValue], [parts[2] intValue], [parts[3] intValue]);
        if (NSIsEmptyRect(rect) || NSIntersectsRect(tile, rect)) [_tiles removeObjectForKey:key];
    }
}

- (int)levelForPage:(NSInteger)page {
    CGFloat device = [self scaleForPage:page] * (self.window.backingScaleFactor ?: 2.0);
    int level = (int)ceil(log2(MAX(device, 1.0 / 64)));
    if (page < 0) return MIN(level, 0);  // a picture's own pixels: never more than one tile pixel per canvas pixel
    return MAX(-6, MIN(level, 3));       // a PDF page's objects stay sharp up to 8 pixels per point
}

- (CGImageRef)tileOnPage:(NSInteger)page level:(int)level tx:(int)tx ty:(int)ty doc:(spdf_paint_doc*)doc {
    NSString* key = TileKey(page, level, tx, ty);
    id cached = _tiles[key];
    if (cached) return (__bridge CGImageRef)cached;
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    NSRect rect = NSIntersectionRect(TileRect(level, tx, ty), NSMakeRect(0, 0, width, height));
    if (NSIsEmptyRect(rect)) return NULL;
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = (spdf_rect){(float)NSMinX(rect), (float)NSMinY(rect), (float)NSMaxX(rect), (float)NSMaxY(rect)};
    options.scale = (float)ldexp(1.0, level);
    if (page >= 0) options.flags |= SPDF_PAINT_RENDER_SKIP_LOCKED_BACKGROUND;
    spdf_bitmap bitmap = {0, 0, 0, NULL};
    char err[256];
    if (spdf_paint_render(doc, &options, &bitmap, err, sizeof(err)) != SPDF_PAINT_OK || !bitmap.rgba) return NULL;
    NSData* data = [NSData dataWithBytes:bitmap.rgba length:(NSUInteger)bitmap.stride * (NSUInteger)bitmap.height];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image = CGImageCreate((size_t)bitmap.width, (size_t)bitmap.height, 8, 32, (size_t)bitmap.stride, srgb,
                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(srgb);
    spdf_free_bitmap(&bitmap);
    if (!image) return NULL;
    if (_tiles.count >= kMaxTiles) [self evictTilesKeepingLevel:level page:page];
    _tiles[key] = CFBridgingRelease(image);
    return image;
}

- (void)evictTilesKeepingLevel:(int)level page:(NSInteger)page {
    NSString* keep = [NSString stringWithFormat:@"%ld:%d:", (long)page, level];
    for (NSString* key in _tiles.allKeys)
        if (![key hasPrefix:keep]) [_tiles removeObjectForKey:key];
    if (_tiles.count >= kMaxTiles) [_tiles removeAllObjects];
}

static void DrawImage(CGContextRef context, CGImageRef image, NSRect rect) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, NSMinX(rect), NSMaxY(rect));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(rect), NSHeight(rect)), image);
    CGContextRestoreGState(context);
}

- (void)drawCanvasOfPage:(NSInteger)page inRect:(NSRect)dirty context:(CGContextRef)context {
    spdf_paint_doc* doc = [self docForPage:page];
    NSRect canvas = [self canvasRectForPage:page];
    NSRect visible = NSIntersectionRect(NSIntersectionRect(canvas, dirty), self.visibleRect);
    if (!doc || NSIsEmptyRect(visible)) return;
    if (page < 0) [self drawCheckerboardInRect:visible];
    CGFloat scale = [self scaleForPage:page];
    int level = [self levelForPage:page];
    CGFloat unit = kTileSide / ldexp(1.0, level);
    NSRect area = NSMakeRect((NSMinX(visible) - NSMinX(canvas)) / scale, (NSMinY(visible) - NSMinY(canvas)) / scale,
                             NSWidth(visible) / scale, NSHeight(visible) / scale);
    int tx0 = (int)floor(NSMinX(area) / unit), tx1 = (int)floor((NSMaxX(area) - 0.001) / unit);
    int ty0 = (int)floor(NSMinY(area) / unit), ty1 = (int)floor((NSMaxY(area) - 0.001) / unit);
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSRectToCGRect(visible));
    // Above 100 % a picture's pixels are drawn as squares (Paint, Preview); below, smoothly.
    CGContextSetInterpolationQuality(context, scale >= 1.0 && page < 0 ? kCGInterpolationNone : kCGInterpolationHigh);
    CGContextSetShouldAntialias(context, false);  // no hairline seams between tiles
    for (int ty = MAX(0, ty0); ty <= ty1; ++ty)
        for (int tx = MAX(0, tx0); tx <= tx1; ++tx) {
            CGImageRef tile = [self tileOnPage:page level:level tx:tx ty:ty doc:doc];
            if (!tile) continue;
            NSRect rect = NSMakeRect(NSMinX(canvas) + tx * unit * scale, NSMinY(canvas) + ty * unit * scale,
                                     CGImageGetWidth(tile) / ldexp(1.0, level) * scale,
                                     CGImageGetHeight(tile) / ldexp(1.0, level) * scale);
            DrawImage(context, tile, rect);
        }
    CGContextRestoreGState(context);
}

// A canvas made smaller shows the reader's picture of the file under it until the file is written again: what lies
// outside the canvas is painted as the page area's background, so only the canvas shows.
- (void)coverStalePageOutsideCanvas:(NSRect)dirty {
    NSRect canvas = [self canvasRectForPage:-1];
    NSScrollView* scroll = self.overlay.enclosingScrollView;
    NSColor* background = scroll.drawsBackground ? scroll.backgroundColor : NSColor.windowBackgroundColor;
    [background setFill];
    NSRect area = NSIntersectionRect(dirty, self.visibleRect);
    NSRect parts[4] = {
        NSMakeRect(NSMinX(area), NSMinY(area), NSWidth(area), MAX(0, NSMinY(canvas) - NSMinY(area))),
        NSMakeRect(NSMinX(area), NSMaxY(canvas), NSWidth(area), MAX(0, NSMaxY(area) - NSMaxY(canvas))),
        NSMakeRect(NSMinX(area), NSMinY(canvas), MAX(0, NSMinX(canvas) - NSMinX(area)), NSHeight(canvas)),
        NSMakeRect(NSMaxX(canvas), NSMinY(canvas), MAX(0, NSMaxX(area) - NSMaxX(canvas)), NSHeight(canvas))};
    for (int i = 0; i < 4; i++) NSRectFill(NSIntersectionRect(parts[i], area));
}

- (void)drawRect:(NSRect)dirty {
    if (!self.session) return;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    // A PDF page's added layers are in the file and the reader's page image already shows them (every change is
    // written back in the same turn): drawing them here too would draw them twice. Only decorations go over pages.
    if (self.session.kind != SPDFAnnotateDocumentPDF) [self coverStalePageOutsideCanvas:dirty];
    for (NSNumber* page in [self pagesInView])
        if (page.integerValue < 0) [self drawCanvasOfPage:page.integerValue inRect:dirty context:context];
    [self drawLiveTransformInRect:dirty];  // objects following a resize or a move (+Live.mm)
    if (!self.holdsLastFrame) [self drawDecorationsInRect:dirty];
}

#pragma mark - The state, read for hit tests and handles

- (NSArray<NSDictionary*>*)objectsOnPage:(NSInteger)page {
    NSArray* layers = [self.session stateForPage:page][@"layers"];
    NSMutableArray* objects = [NSMutableArray array];
    for (NSDictionary* layer in [layers isKindOfClass:NSArray.class] ? layers.reverseObjectEnumerator.allObjects : @[]) {
        if (![layer isKindOfClass:NSDictionary.class] || ![layer[@"kind"] isEqual:@"object"]) continue;
        if (layer[@"visible"] && ![layer[@"visible"] boolValue]) continue;
        NSDictionary* object = [layer[@"object"] isKindOfClass:NSDictionary.class] ? layer[@"object"] : layer;
        NSDictionary* box = [layer[@"bounds"] isKindOfClass:NSDictionary.class] ? layer[@"bounds"] : object[@"bounds"];
        NSDictionary* placed = [object[@"rect"] isKindOfClass:NSDictionary.class] ? object[@"rect"] : box;
        if (![box isKindOfClass:NSDictionary.class]) continue;
        NSRect bounds = NSMakeRect([box[@"x"] doubleValue], [box[@"y"] doubleValue], [box[@"w"] doubleValue],
                                   [box[@"h"] doubleValue]);
        NSRect rect = NSMakeRect([placed[@"x"] doubleValue], [placed[@"y"] doubleValue], [placed[@"w"] doubleValue],
                                 [placed[@"h"] doubleValue]);
        [objects addObject:@{@"id": layer[@"id"] ?: @0, @"kind": object[@"kind"] ?: @"", @"bounds": @(bounds),
                             @"rect": @(rect), @"rotation": object[@"rotation"] ?: @0, @"object": object,
                             @"locked": layer[@"locked"] ?: @NO}];
    }
    return objects;
}

- (NSRect)boundsOfObjects:(NSArray<NSNumber*>*)ids page:(NSInteger)page {
    NSRect all = NSZeroRect;
    for (NSDictionary* object in [self objectsOnPage:page])
        if ([ids containsObject:object[@"id"]]) all = NSUnionRect(all, [object[@"bounds"] rectValue]);
    return all;
}

- (NSDictionary*)selectionOnPage:(NSInteger)page {
    id selection = [self.session stateForPage:page][@"selection"];
    if (![selection isKindOfClass:NSDictionary.class]) return nil;
    if (selection[@"active"] && ![selection[@"active"] boolValue]) return nil;
    return [selection[@"bounds"] isKindOfClass:NSDictionary.class] || [selection[@"outline"] isKindOfClass:NSArray.class]
               ? selection : nil;
}

- (NSSize)selectionSize {
    NSInteger page = self.session.kind == SPDFAnnotateDocumentPDF ? self.session.currentPage : -1;
    if (self.session.selectedObjects.count) return [self boundsOfObjects:self.session.selectedObjects page:page].size;
    NSDictionary* box = [self selectionOnPage:page][@"bounds"];
    return [box isKindOfClass:NSDictionary.class] ? NSMakeSize([box[@"w"] doubleValue], [box[@"h"] doubleValue])
                                                  : NSZeroSize;
}

#pragma mark - Operations from gestures

- (void)operation:(NSDictionary*)op page:(NSInteger)page done:(void (^)(NSDictionary*))done {
    NSMutableDictionary* sent = [op mutableCopy];
    if (page < 0 && self.session.kind == SPDFAnnotateDocumentPDF) page = [self pageInView];  // a key before any click
    if (page >= 0) sent[@"page"] = @(page + 1);
    [self.controller applyOperation:sent tab:self.session.tab completion:^(NSDictionary* result) {
        if (![result[@"ok"] boolValue] && result[@"message"] && ![result[@"error"] isEqual:@"nothing_selected"])
            [self.controller.host fillShowError:@"Annotate couldn't do that" detail:result[@"message"]];
        if (done) done(result);
    }];
}

@end
#pragma clang diagnostic pop
