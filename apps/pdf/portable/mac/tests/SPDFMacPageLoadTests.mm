// Page loading: once an open has painted, after an explicit jump, and when a
// scroll settles, every page the viewport shows renders at once, side by side on
// the user-initiated render queue -- not one after another on the one-wide
// background queue -- and trackpad scrolling itself keeps the gentle queue.
// Production-linked: the real coordinator and render queues run offscreen on a
// forced 2x backing scale; nothing is displayed and no state outside a temp dir
// is touched. The PDFs are synthetic, generated here with the traits of the
// drawing sets that loaded slowly (A3 vector-heavy sheets, one A4 sheet, 10+
// pages).
//
// The failure it guards (26.10.11): a 10-page A3 set restored at page 7 at Fit
// Page showed the neighbours peeking into the viewport sharp ~830 ms after the
// open, a jump to page 30 of 40 took ~530 ms, and paging with key repeat left
// the last page waiting behind renders queued for every page passed on the way.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFUpdater.h"
#import <objc/runtime.h>
#include "shenzhen_pdf_core.h"
#undef main

static NSUInteger failures;
static void Check(BOOL ok, NSString* what) {
    if (ok) return;
    failures++;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
}

static IMP gOriginalOrder;
static void RefuseOrder(id window, SEL sel, NSInteger place, NSInteger other) {
    if (place == NSWindowOut) ((void (*)(id, SEL, NSInteger, NSInteger))gOriginalOrder)(window, sel, place, other);
}
static void Inert(id self, SEL _cmd) { (void)self; (void)_cmd; }
static NSModalResponse NoModal(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    Check(NO, @"no modal alert during page-load scenarios");
    return NSAlertSecondButtonReturn;
}
// A 2x display, whatever screen the test machine has: the render scale is a
// parameter of every scenario below, not ambient state.
static CGFloat Retina(id self, SEL _cmd) { (void)self; (void)_cmd; return 2.0; }

static double NowMs(void) { return CFAbsoluteTimeGetCurrent() * 1000.0; }

// One full-page render as the coordinator ran it.
@interface PageLoadRender : NSObject
@property NSInteger page;
@property CGFloat scale;
@property(copy) NSString* queue; // "main", "render", "background" or another queue's name
@property double start, end;
@end
@implementation PageLoadRender
@end

static NSLock* gLock;
static NSMutableArray<PageLoadRender*>* gRenders;

@interface ShenzhenMacDelegate (PageLoadAccess)
- (SPDFDocumentTab*)newTabForPath:(NSString*)path;
- (void)applicationDidFinishLaunching:(NSNotification*)notification;
- (void)goToPage:(NSInteger)pageIndex preserveSinglePagePosition:(BOOL)preserveSinglePagePosition;
- (CGFloat)backingScale;
- (BOOL)renderedPageImage:(SPDFRenderedPage*)page matchesZoom:(CGFloat)zoom displayScale:(CGFloat)displayScale;
- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex document:(spdf_document*)doc zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale renderToken:(spdf_render_token*)renderToken
                                   error:(char*)err errorLength:(size_t)errLen;
// Declared here too so this file also builds against the code before the fix,
// where the checks report the serial background renders instead.
- (NSArray<NSNumber*>*)visibleDocumentPageIndexesWithExtraRadius:(NSInteger)radius
                                                   preferredPage:(NSInteger*)preferredPageOut;
- (void)spdf_queueViewportPageRendersNow;
@end

@interface PageLoadReader : ShenzhenMacDelegate
@property NSUInteger viewportQueueCalls;
@end

@implementation PageLoadReader
// Launch side effects unrelated to rendering.
- (void)showUnifiedSettingsAfterFirstPaint {}
- (void)showUnifiedSettings:(id)sender { (void)sender; }
- (void)installWindowArrangementShortcutMonitor {}
- (void)spawnPendingRestoredWindowsIfNeeded {}
- (void)resumePersistentStateSavesAfterLaunch {}
- (void)collectionDidOpenPath:(NSString*)path { (void)path; }
- (void)aiDocumentDidOpen:(NSString*)path { (void)path; }

- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                             renderToken:(spdf_render_token*)renderToken
                                   error:(char*)err
                             errorLength:(size_t)errLen {
    PageLoadRender* render = [PageLoadRender new];
    render.page = pageIndex;
    render.scale = zoom * displayScale;
    NSString* name = NSOperationQueue.currentQueue.name ?: @"?";
    render.queue = NSThread.isMainThread                                     ? @"main"
                   : [name isEqualToString:@"Shenzhen PDF page renderer"]            ? @"render"
                   : [name isEqualToString:@"Shenzhen PDF background page renderer"] ? @"background"
                                                                                     : name;
    render.start = NowMs();
    [gLock lock];
    [gRenders addObject:render]; // from its start, so one still running is seen too
    [gLock unlock];
    SPDFRenderedPage* page = [super renderedPageAtIndex:pageIndex document:doc zoom:zoom displayScale:displayScale
                                            renderToken:renderToken error:err errorLength:errLen];
    [gLock lock];
    render.end = NowMs();
    if (!page) [gRenders removeObject:render]; // canceled: nothing was rendered
    [gLock unlock];
    return page;
}
- (void)spdf_queueViewportPageRendersNow {
    self.viewportQueueCalls++;
    [super spdf_queueViewportPageRendersNow];
}

- (NSWindow*)testWindow { return _window; }
- (NSInteger)currentPage { return _pageIndex; }
- (CGFloat)currentZoom { return _zoom; }
- (NSUInteger)pageCount { return _renderedPages.count; }
- (BOOL)pageQueuesIdle {
    return _renderQueue.operationCount == 0 && _backgroundRenderQueue.operationCount == 0;
}
- (BOOL)allQueuesIdle {
    return self.pageQueuesIdle && _minimapQueue.operationCount == 0 && _zoomSeedRenderQueue.operationCount == 0 &&
           _cacheRenderQueue.operationCount == 0;
}
- (void)holdBackgroundQueue:(BOOL)hold { _backgroundRenderQueue.suspended = hold; }
- (void)holdRenderQueue:(BOOL)hold { _renderQueue.suspended = hold; }
- (NSArray<NSNumber*>*)viewportPages {
    NSInteger preferred = -1;
    return [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferred];
}
- (BOOL)viewportSharp {
    NSArray<NSNumber*>* pages = self.viewportPages;
    for (NSNumber* number in pages)
        if (![self renderedPageImage:_renderedPages[number.unsignedIntegerValue] matchesZoom:_zoom
                        displayScale:[self backingScale]])
            return NO;
    return pages.count > 0;
}
- (NSImage*)imageOfPage:(NSInteger)page { return _renderedPages[(NSUInteger)page].image; }
- (void)scrollViewportToPage:(NSInteger)page {
    // What a trackpad or scroller drag does: move the clip view; AppKit posts the
    // bounds change that drives the coordinator's scroll path.
    NSClipView* clip = _pageScrollView.contentView;
    [clip scrollToPoint:NSMakePoint(NSMinX(clip.bounds), NSMinY([_pageView rectForPageAtIndex:page]) - 20.0)];
    [_pageScrollView reflectScrolledClipView:clip];
}
@end

static void Pump(void) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
}
static void RunFor(NSTimeInterval seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) Pump();
}
static BOOL RunUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) {
        if (until.timeIntervalSinceNow <= 0) return NO;
        Pump();
    }
    return YES;
}
static void ResetRenders(void) {
    [gLock lock];
    [gRenders removeAllObjects];
    [gLock unlock];
}
static NSArray<PageLoadRender*>* Renders(void) {
    [gLock lock];
    NSArray* copy = [gRenders copy];
    [gLock unlock];
    return copy;
}
// The display-scale renders of `pages` since the last reset, earliest first.
static NSArray<PageLoadRender*>* RendersOf(NSArray<NSNumber*>* pages, CGFloat scale) {
    NSMutableArray* found = [NSMutableArray array];
    for (PageLoadRender* render in Renders())
        if ([pages containsObject:@(render.page)] && fabs(render.scale - scale) < 0.01) [found addObject:render];
    [found sortUsingComparator:^NSComparisonResult(PageLoadRender* a, PageLoadRender* b) {
      return a.start < b.start ? NSOrderedAscending : NSOrderedDescending;
    }];
    return found;
}
static NSString* Describe(NSArray<PageLoadRender*>* renders, double origin) {
    NSMutableArray* parts = [NSMutableArray array];
    for (PageLoadRender* r in renders)
        [parts addObject:[NSString stringWithFormat:@"p%ld %@ %+.0f..%+.0fms", (long)r.page + 1, r.queue,
                                                    r.start - origin, r.end - origin]];
    return parts.count ? [parts componentsJoinedByString:@", "] : @"none";
}

// Vector-heavy sheets: thousands of stroked curves per page. Page 4 is A4.
static NSString* WriteDrawingSet(NSString* dir, NSString* name, NSInteger pages, NSInteger curves) {
    NSString* path = [dir stringByAppendingPathComponent:name];
    CGRect a3 = CGRectMake(0, 0, 1190.55, 841.89), a4 = CGRectMake(0, 0, 595.28, 841.89);
    CGContextRef ctx = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &a3, NULL);
    for (NSInteger p = 0; p < pages; p++) {
        CGRect box = p == 3 ? a4 : a3;
        NSData* boxData = [NSData dataWithBytes:&box length:sizeof(box)];
        NSDictionary* info = @{(__bridge NSString*)kCGPDFContextMediaBox : boxData};
        CGPDFContextBeginPage(ctx, (__bridge CFDictionaryRef)info);
        CGContextSetRGBStrokeColor(ctx, 0, 0, 0, 1);
        CGContextSetLineWidth(ctx, 0.5);
        unsigned seed = (unsigned)(p * 7919 + 17);
        for (NSInteger i = 0; i < curves; i++) {
            seed = seed * 1103515245u + 12345u;
            CGFloat x = (seed >> 8) % (unsigned)box.size.width;
            seed = seed * 1103515245u + 12345u;
            CGFloat y = (seed >> 8) % (unsigned)box.size.height;
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, x, y);
            CGContextAddCurveToPoint(ctx, x + 6, y + 3, x + 2, y + 9, x + 11, y + (i % 7));
            CGContextStrokePath(ctx);
        }
        CGContextSetLineWidth(ctx, 3.0);
        CGContextStrokeRect(ctx, CGRectInset(box, 24, 24));
        CGPDFContextEndPage(ctx);
    }
    CGPDFContextClose(ctx);
    CGContextRelease(ctx);
    return path;
}

static NSInteger AddTab(PageLoadReader* reader, NSString* path, NSInteger page) {
    SPDFDocumentTab* tab = [reader newTabForPath:path];
    tab.pageIndex = page - 1;
    tab.fitMode = SPDFFitModePage;
    tab.showMinimap = YES;
    return [reader appendNewTabToActiveGroup:tab];
}

// Every viewport page but `except` (-1: none) renders once, on the render queue,
// side by side with the others, so the set is done in about one render's time.
static void ExpectViewportSideBySide(PageLoadReader* reader, NSString* scenario, NSArray<NSNumber*>* viewport,
                                     NSInteger except, double origin) {
    CGFloat scale = reader.currentZoom * 2.0;
    NSMutableArray<NSNumber*>* others = [viewport mutableCopy];
    [others removeObject:@(except)];
    NSArray<PageLoadRender*>* renders = RendersOf(others, scale);
    NSString* detail = Describe(renders, origin);
    Check(others.count >= 1, [scenario stringByAppendingString:@": more than one page shares the viewport"]);
    Check(renders.count == others.count,
          [NSString stringWithFormat:@"%@: each viewport page renders once (%@)", scenario, detail]);
    BOOL renderQueue = renders.count > 0;
    double longest = 0, first = INFINITY, last = 0;
    for (PageLoadRender* r in renders) {
        renderQueue = renderQueue && [r.queue isEqualToString:@"render"];
        longest = MAX(longest, r.end - r.start);
        first = MIN(first, r.start);
        last = MAX(last, r.end);
    }
    Check(renderQueue,
          [NSString stringWithFormat:@"%@: viewport pages render on the render queue (%@)", scenario, detail]);
    BOOL overlap = renders.count > 0;
    for (PageLoadRender* r in renders) overlap = overlap && r.start < [renders.firstObject end];
    Check(overlap, [NSString stringWithFormat:@"%@: viewport pages render side by side (%@)", scenario, detail]);
    // Serial rendering takes the sum of the renders; side by side, about the
    // longest one. 1.6x leaves room for start skew and contention.
    Check(renders.count < 2 || last - first < 1.6 * longest,
          [NSString stringWithFormat:@"%@: viewport sharp after about one render: %.0f ms for renders of up to %.0f ms "
                                     @"(%@)", scenario, last - first, longest, detail]);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString* state = [root stringByAppendingPathComponent:@"state"];
        [NSFileManager.defaultManager createDirectoryAtPath:state
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        setenv("SPDF_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("SPDF_NO_ACTIVATE", "1", 1);
        setenv("SPDF_NO_WINDOW_FIRST", "1", 1);
        setenv("SPDF_DISABLE_LAUNCH_PRERENDER", "1", 1);
        gLock = [NSLock new];
        gRenders = [NSMutableArray array];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        gOriginalOrder = method_setImplementation(
            class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:)), (IMP)RefuseOrder);
        method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)NoModal);
        method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(backingScaleFactor)), (IMP)Retina);
        for (NSString* name in @[ @"consumePendingUpdateMarkerAndSweep", @"scheduleDailyUpdateCheckIfNeeded",
                                  @"armRecurringUpdateCheck" ]) {
            Method method = class_getInstanceMethod(SPDFUpdater.class, NSSelectorFromString(name));
            if (method) method_setImplementation(method, (IMP)Inert);
        }

        NSString* sheets = WriteDrawingSet(root, @"Drawing set.pdf", 10, 12000);
        NSString* longSet = WriteDrawingSet(root, @"Long set.pdf", 40, 9000);

        PageLoadReader* reader = [PageLoadReader new];
        [reader applicationDidFinishLaunching:[NSNotification notificationWithName:@"PageLoadTests" object:nil]];
        [reader.testWindow setContentSize:NSMakeSize(1500, 940)];

        // Laziness: a launch with no document renders nothing and queues nothing.
        RunFor(0.6);
        Check(Renders().count == 0 && reader.viewportQueueCalls == 0 && reader.allQueuesIdle,
              @"a launch with no document renders and queues no page");

        // Open restored at page 7 at Fit Page, the case in the 26.10.11 screenshot.
        ResetRenders();
        NSInteger sheetsTab = AddTab(reader, sheets, 7);
        double opened = NowMs();
        [reader selectTabAtIndex:sheetsTab];
        double returned = NowMs();
        CGFloat scale = reader.currentZoom * 2.0;
        NSArray<NSNumber*>* viewport = reader.viewportPages;
        Check(reader.currentPage == 6 && viewport.count >= 2 && [viewport containsObject:@6],
              [NSString stringWithFormat:@"open restores page 7 with its neighbours peeking in (viewport %@)",
                                         [viewport componentsJoinedByString:@","]]);
        // Nothing new before the first paint: the open still renders exactly the
        // restored page, on the main thread, and nothing else at display scale.
        NSMutableArray<PageLoadRender*>* duringOpen = [NSMutableArray array];
        for (PageLoadRender* r in RendersOf(@[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9 ], scale))
            if (r.start <= returned) [duringOpen addObject:r];
        Check(duringOpen.count == 1 && [duringOpen.firstObject page] == 6 &&
                  [[duringOpen.firstObject queue] isEqualToString:@"main"] && reader.viewportQueueCalls == 0,
              [NSString stringWithFormat:@"the open itself renders only the restored page, on the main thread (%@)",
                                         Describe(duringOpen, opened)]);
        Check(RunUntil(20.0, ^{ return reader.viewportSharp; }), @"open: the viewport becomes sharp");
        double sharp = NowMs() - opened;
        Check(reader.viewportQueueCalls >= 1, @"open: the viewport is queued once the open has painted");
        ExpectViewportSideBySide(reader, @"open restored at page 7", viewport, 6, opened);
        // Generous: catches viewport pages queued behind prefetch or cache warming
        // (a dozen serial renders), not ordinary load.
        double longest = 0;
        for (PageLoadRender* r in RendersOf(viewport, scale)) longest = MAX(longest, r.end - r.start);
        Check(sharp < (returned - opened) + 4.0 * longest + 1500.0,
              [NSString stringWithFormat:@"open: viewport sharp in %.0f ms (open %.0f ms, renders up to %.0f ms)",
                                         sharp, returned - opened, longest]);

        // What is drawn is unchanged: each viewport page's bitmap equals a direct
        // core render at the same scale, byte for byte.
        char err[512];
        spdf_document* direct = spdf_open(sheets.fileSystemRepresentation, err, sizeof(err));
        Check(direct != NULL, @"fixture opens in the core");
        for (NSNumber* number in viewport) {
            if (!direct) break;
            NSImage* image = [reader imageOfPage:number.integerValue];
            NSBitmapImageRep* rep = (NSBitmapImageRep*)image.representations.firstObject;
            spdf_bitmap bitmap;
            BOOL rendered = spdf_render_page_rgba_opts(direct, number.intValue, (float)scale, SPDF_RENDER_DEFAULT, NULL,
                                                      &bitmap, err, sizeof(err));
            BOOL same = rendered && [rep isKindOfClass:NSBitmapImageRep.class] && rep.pixelsWide == bitmap.width &&
                        rep.pixelsHigh == bitmap.height;
            for (int y = 0; same && y < bitmap.height; y++)
                same = memcmp(rep.bitmapData + (size_t)y * (size_t)rep.bytesPerRow,
                              bitmap.rgba + (size_t)y * (size_t)bitmap.stride, (size_t)bitmap.width * 4) == 0;
            if (rendered) spdf_free_bitmap(&bitmap);
            Check(same, [NSString stringWithFormat:@"page %ld is drawn byte-identical to a direct render",
                                                   (long)number.integerValue + 1]);
        }
        if (direct) spdf_close(direct);

        // A jump far into a long set, to pages nothing has rendered yet.
        NSInteger longTab = AddTab(reader, longSet, 1);
        [reader selectTabAtIndex:longTab];
        Check(RunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"long set settles after opening");
        ResetRenders();
        double jumped = NowMs();
        [reader goToPage:29 preserveSinglePagePosition:NO];
        viewport = reader.viewportPages;
        Check(reader.currentPage == 29 && viewport.count >= 2,
              [NSString stringWithFormat:@"jump lands on page 30 with a neighbour in view (viewport %@)",
                                         [viewport componentsJoinedByString:@","]]);
        Check(RunUntil(20.0, ^{ return reader.viewportSharp; }), @"jump: the viewport becomes sharp");
        // The jump's own page goes to the render queue as before; the rest of the
        // viewport must join it there.
        ExpectViewportSideBySide(reader, @"jump to page 30", viewport, -1, jumped);

        // Paging with key repeat: the last press's viewport renders before the
        // renders still waiting for pages passed on the way. The render queue is
        // held while the keys repeat -- presses outpacing renders, as on heavy
        // sheets -- so every press's work is still waiting when it is released.
        Check(RunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"long set settles after the jump");
        [reader goToPage:9 preserveSinglePagePosition:NO];
        Check(RunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"long set settles at page 10");
        ResetRenders();
        [reader holdRenderQueue:YES];
        for (NSInteger page = 10; page <= 20; page++) {
            if (page > 10) RunFor(0.03);
            [reader goToPage:page preserveSinglePagePosition:NO];
        }
        double lastPress = NowMs();
        [reader holdRenderQueue:NO];
        NSArray<NSNumber*>* finalViewport = reader.viewportPages;
        Check(RunUntil(20.0, ^{ return reader.viewportSharp; }), @"key repeat: the last page becomes sharp");
        Check(RunUntil(30.0, ^{ return reader.pageQueuesIdle; }), @"key repeat: the passed pages' renders finish");
        // After the last press, the last viewport's pages must not wait for a free
        // slot: each starts before the first render started after the press ends.
        NSMutableArray<PageLoadRender*>* afterLastPress = [NSMutableArray array];
        for (PageLoadRender* r in RendersOf(@[ @9, @10, @11, @12, @13, @14, @15, @16, @17, @18, @19, @20, @21 ],
                                            reader.currentZoom * 2.0))
            if (r.start >= lastPress) [afterLastPress addObject:r];
        double firstEnd = INFINITY;
        NSUInteger staleRenders = 0;
        for (PageLoadRender* r in afterLastPress) {
            firstEnd = MIN(firstEnd, r.end);
            if (![finalViewport containsObject:@(r.page)]) staleRenders++;
        }
        BOOL viewportFirst = YES;
        for (PageLoadRender* r in afterLastPress)
            if ([finalViewport containsObject:@(r.page)] && r.start >= firstEnd) viewportFirst = NO;
        NSString* keyRepeatDetail = Describe(afterLastPress, lastPress);
        if (getenv("PAGE_LOAD_TEST_VERBOSE"))
            printf("key repeat: viewport %s after last press: %s\n",
                   [finalViewport componentsJoinedByString:@","].UTF8String, keyRepeatDetail.UTF8String);
        Check(staleRenders > 0, [NSString stringWithFormat:@"key repeat: renders for passed pages were still waiting "
                                                           @"at the last press (%@)", keyRepeatDetail]);
        Check(viewportFirst, [NSString stringWithFormat:@"key repeat: the last viewport (%@) renders without waiting "
                                                        @"behind the pages passed on the way (%@)",
                                                        [finalViewport componentsJoinedByString:@","],
                                                        keyRepeatDetail]);

        // Trackpad scrolling keeps the gentle background queue while it moves; once
        // it settles, viewport pages still waiting there render side by side. The
        // background queue is held so they are certainly still waiting.
        Check(RunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"long set settles before scrolling");
        [reader holdBackgroundQueue:YES];
        ResetRenders();
        double scrolled = NowMs();
        [reader scrollViewportToPage:33];
        RunFor(0.15);
        viewport = reader.viewportPages;
        NSArray<PageLoadRender*>* duringScroll = RendersOf(viewport, reader.currentZoom * 2.0);
        Check(duringScroll.count == 0,
              [NSString stringWithFormat:@"scrolling: viewport pages wait on the background queue while the scroll "
                                         @"moves (%@)", Describe(duringScroll, scrolled)]);
        Check(RunUntil(5.0, ^{ return reader.viewportSharp; }),
              @"scroll settled: viewport pages still waiting render without the background queue");
        NSArray<PageLoadRender*>* settled = RendersOf(viewport, reader.currentZoom * 2.0);
        BOOL onRenderQueue = settled.count == viewport.count;
        for (PageLoadRender* r in settled) onRenderQueue = onRenderQueue && [r.queue isEqualToString:@"render"];
        Check(onRenderQueue, [NSString stringWithFormat:@"scroll settled: waiting viewport pages move to the render "
                                                        @"queue (%@)", Describe(settled, scrolled)]);
        [reader holdBackgroundQueue:NO];
        RunUntil(30.0, ^{ return reader.allQueuesIdle; });

        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (failures) return 1;
    puts("SPDFMacPageLoadTests passed");
    return 0;
}
