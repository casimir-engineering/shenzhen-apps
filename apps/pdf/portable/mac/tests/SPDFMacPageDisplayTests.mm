// Page display bookkeeping, production-linked: the real coordinator and render
// queues run offscreen on a forced 2x backing scale; nothing is displayed and
// no state outside a temporary directory is touched.
//
// 1. Render-queue entries. When a scroll settles, viewport pages still waiting on
//    the one-wide background queue are withdrawn and re-queued on the render
//    queue. The background queue can start one between the withdraw's
//    isExecuting check and its -cancel; that operation's cleanup then removed
//    the replacement's entry by page number, so the next scroll tick queued the
//    page again and it rendered twice.
// 2. Sidebar rebuilds after an open: SPDFMacPageDisplaySidebarTests.mm.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFUpdater.h"
#import "SPDFMacPageDisplayTestSupport.h"
#import <objc/runtime.h>
#include "shenzhen_pdf_core.h"
#undef main

NSUInteger gPageDisplayFailures;
void PageDisplayCheck(BOOL ok, NSString* what) {
    if (ok) return;
    gPageDisplayFailures++;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
}

static IMP gOriginalOrder;
static void RefuseOrder(id window, SEL sel, NSInteger place, NSInteger other) {
    if (place == NSWindowOut) ((void (*)(id, SEL, NSInteger, NSInteger))gOriginalOrder)(window, sel, place, other);
}
static void Inert(id self, SEL _cmd) { (void)self; (void)_cmd; }
static NSModalResponse NoModal(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    PageDisplayCheck(NO, @"no modal alert during page-display scenarios");
    return NSAlertSecondButtonReturn;
}
static CGFloat Retina(id self, SEL _cmd) { (void)self; (void)_cmd; return 2.0; }

// The race, reproduced exactly: when the withdraw cancels the first viewport
// operation still waiting on the background queue, that queue is let go first
// and the operation is held inside its render until -cancel has run.
static IMP gOriginalCancel;
static BOOL gRaceArmed;
static NSOperationQueue* gBackgroundQueue;
static __weak NSOperation* gVictim;
static NSNumber* gVictimPage;
static BOOL gVictimStarted;
static dispatch_semaphore_t gGateEntered, gGateRelease;
static volatile int gGateArmed;
static __weak PageDisplayReader* gReader;
static void RaceCancel(NSOperation* operation, SEL _cmd) {
    if (gRaceArmed && NSThread.isMainThread && !operation.isExecuting &&
        [gBackgroundQueue.operations containsObject:operation]) {
        gRaceArmed = NO;
        gVictim = operation;
        gVictimPage = [gReader queuedPageForOperation:operation];
        for (NSOperation* other in gBackgroundQueue.operations)
            other.queuePriority = other == operation ? NSOperationQueuePriorityVeryHigh : NSOperationQueuePriorityVeryLow;
        __atomic_store_n(&gGateArmed, 1, __ATOMIC_SEQ_CST);
        gBackgroundQueue.suspended = NO;
        long timedOut = dispatch_semaphore_wait(gGateEntered, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        gVictimStarted = !timedOut && operation.isExecuting;
    }
    ((void (*)(id, SEL))gOriginalCancel)(operation, _cmd);
}

@implementation PageDisplayReader
- (void)showUnifiedSettingsAfterFirstPaint {}
- (void)showUnifiedSettings:(id)sender { (void)sender; }
- (void)installWindowArrangementShortcutMonitor {}
- (void)spawnPendingRestoredWindowsIfNeeded {}
- (void)resumePersistentStateSavesAfterLaunch {}
- (void)collectionDidOpenPath:(NSString*)path { (void)path; }
- (void)aiDocumentDidOpen:(NSString*)path { (void)path; }

- (spdf_document*)workerDocumentForPath:(NSString*)path
                             sourcePath:(NSString*)sourcePath
                                  error:(char*)err
                            errorLength:(size_t)errLen {
    int armed = 1;
    if (NSOperationQueue.currentQueue == gBackgroundQueue &&
        __atomic_compare_exchange_n(&gGateArmed, &armed, 0, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
        dispatch_semaphore_signal(gGateEntered);
        dispatch_semaphore_wait(gGateRelease, DISPATCH_TIME_FOREVER);
    }
    return [super workerDocumentForPath:path sourcePath:sourcePath error:err errorLength:errLen];
}
- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                             renderToken:(spdf_render_token*)renderToken
                                   error:(char*)err
                             errorLength:(size_t)errLen {
    SPDFRenderedPage* page = [super renderedPageAtIndex:pageIndex document:doc zoom:zoom displayScale:displayScale
                                            renderToken:renderToken error:err errorLength:errLen];
    if (page) {
        @synchronized(self) {
            [self.completedRenders addObject:@[ @(pageIndex), @(zoom * displayScale) ]];
        }
    }
    return page;
}
- (void)rebuildSidebar {
    self.sidebarRebuilds++;
    [super rebuildSidebar];
}

- (NSWindow*)testWindow { return _window; }
- (NSInteger)currentPage { return _pageIndex; }
- (CGFloat)currentZoom { return _zoom; }
- (BOOL)allQueuesIdle {
    return _renderQueue.operationCount == 0 && _backgroundRenderQueue.operationCount == 0 &&
           _minimapQueue.operationCount == 0 && _zoomSeedRenderQueue.operationCount == 0 &&
           _cacheRenderQueue.operationCount == 0 && _preloadQueue.operationCount == 0;
}
- (NSOperationQueue*)backgroundQueue { return _backgroundRenderQueue; }
- (void)holdBackgroundQueue:(BOOL)hold { _backgroundRenderQueue.suspended = hold; }
- (void)holdRenderQueue:(BOOL)hold { _renderQueue.suspended = hold; }
- (NSNumber*)queuedPageForOperation:(NSOperation*)operation {
    for (NSNumber* page in _queuedRenderOperations)
        if (_queuedRenderOperations[page] == operation) return page;
    return nil;
}
- (NSOperation*)queuedOperationForPage:(NSNumber*)page { return _queuedRenderOperations[page]; }
- (BOOL)pageIsQueued:(NSNumber*)page { return [_queuedRenderPages containsObject:page]; }
- (BOOL)renderQueueHolds:(NSOperation*)operation { return [_renderQueue.operations containsObject:operation]; }
- (NSUInteger)completedRendersOfPage:(NSInteger)page {
    NSUInteger count = 0;
    CGFloat scale = _zoom * 2.0;
    @synchronized(self) {
        for (NSArray* r in self.completedRenders)
            if ([r[0] integerValue] == page && fabs([r[1] doubleValue] - scale) < 0.01) count++;
    }
    return count;
}
- (NSArray<NSDictionary*>*)sidebarItemsCopy { return [_sidebarItems copy]; }
- (int)activeCommentCount { return _comments.count; }
- (int)activeOutlineCount { return _outline.count; }
- (void)scrollViewportToPage:(NSInteger)page {
    NSClipView* clip = _pageScrollView.contentView;
    [clip scrollToPoint:NSMakePoint(NSMinX(clip.bounds), NSMinY([_pageView rectForPageAtIndex:page]) - 20.0)];
    [_pageScrollView reflectScrolledClipView:clip];
}
@end

void PageDisplayPump(void) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
}
void PageDisplayRunFor(NSTimeInterval seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) PageDisplayPump();
}
BOOL PageDisplayRunUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) {
        if (until.timeIntervalSinceNow <= 0) return NO;
        PageDisplayPump();
    }
    return YES;
}
// Runs the main queue past everything already posted to it.
static void DrainMainQueue(void) {
    __block BOOL ran = NO;
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{ ran = YES; }];
    PageDisplayRunUntil(5.0, ^{ return ran; });
}

NSString* PageDisplayWriteDrawingSet(NSString* dir, NSString* name, NSInteger pages, NSInteger curves) {
    NSString* path = [dir stringByAppendingPathComponent:name];
    CGRect a3 = CGRectMake(0, 0, 1190.55, 841.89);
    CGContextRef ctx = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &a3, NULL);
    for (NSInteger p = 0; p < pages; p++) {
        NSDictionary* info = @{(__bridge NSString*)kCGPDFContextMediaBox : [NSData dataWithBytes:&a3 length:sizeof(a3)]};
        CGPDFContextBeginPage(ctx, (__bridge CFDictionaryRef)info);
        CGContextSetRGBStrokeColor(ctx, 0, 0, 0, 1);
        CGContextSetLineWidth(ctx, 0.5);
        unsigned seed = (unsigned)(p * 7919 + 17);
        for (NSInteger i = 0; i < curves; i++) {
            seed = seed * 1103515245u + 12345u;
            CGFloat x = (seed >> 8) % 1190u;
            seed = seed * 1103515245u + 12345u;
            CGFloat y = (seed >> 8) % 841u;
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, x, y);
            CGContextAddCurveToPoint(ctx, x + 6, y + 3, x + 2, y + 9, x + 11, y + (i % 7));
            CGContextStrokePath(ctx);
        }
        CGContextSetRGBFillColor(ctx, 0.85, 0.20, 0.10, 1);
        CGContextFillRect(ctx, CGRectMake(60, 60, 120, 80));
        CGPDFContextEndPage(ctx);
    }
    CGPDFContextClose(ctx);
    CGContextRelease(ctx);
    return path;
}

NSInteger PageDisplayAddTab(PageDisplayReader* reader, NSString* path, NSInteger page) {
    SPDFDocumentTab* tab = [reader newTabForPath:path];
    tab.pageIndex = page - 1;
    tab.fitMode = SPDFFitModePage;
    tab.showMinimap = YES;
    return [reader appendNewTabToActiveGroup:tab];
}

static void RenderQueueEntryScenario(PageDisplayReader* reader, NSString* longSet) {
    NSInteger tab = PageDisplayAddTab(reader, longSet, 1);
    [reader selectTabAtIndex:tab];
    PageDisplayCheck(PageDisplayRunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"race: the long set settles");

    // A trackpad scroll leaves the new viewport's pages waiting on the background
    // queue; when it settles they are withdrawn. The first withdrawal loses the
    // race, and the render queue is held so the replacement is still waiting.
    gBackgroundQueue = reader.backgroundQueue;
    [reader holdBackgroundQueue:YES];
    [reader scrollViewportToPage:30];
    [reader holdRenderQueue:YES];
    gRaceArmed = YES;
    PageDisplayCheck(PageDisplayRunUntil(5.0, ^{ return (BOOL)(gVictimPage != nil); }),
                     @"race: settling the scroll withdraws a viewport page waiting on the background queue");
    NSOperation* victim = gVictim;
    NSNumber* page = gVictimPage;
    PageDisplayCheck(gVictimStarted, @"race: the withdrawn operation started before it was cancelled");
    NSOperation* replacement = page ? [reader queuedOperationForPage:page] : nil;
    PageDisplayCheck(replacement && replacement != victim && [reader renderQueueHolds:replacement],
                     @"race: the withdrawn page is re-queued on the render queue");

    // The cancelled operation finishes; its cleanup must leave the replacement's
    // entry alone.
    dispatch_semaphore_signal(gGateRelease);
    PageDisplayCheck(PageDisplayRunUntil(10.0, ^{ return (BOOL)(!victim || victim.isFinished); }),
                     @"race: the cancelled operation finishes");
    DrainMainQueue();
    PageDisplayCheck(page && [reader queuedOperationForPage:page] == replacement && [reader pageIsQueued:page],
                     [NSString stringWithFormat:@"race: a cancelled-but-started operation's cleanup leaves the "
                                                @"replacement's entry for page %ld (entry %@)",
                                                (long)page.integerValue + 1,
                                                page ? [reader queuedOperationForPage:page] : nil]);
    // So the next scroll tick finds the page queued and does not queue it again.
    [reader queueVisibleDocumentPageRendersForCurrentViewportForceHighPriority:NO];
    PageDisplayCheck(page && [reader queuedOperationForPage:page] == replacement,
                     @"race: the next scroll tick does not queue the page a second time");

    [reader holdRenderQueue:NO];
    [reader holdBackgroundQueue:NO];
    PageDisplayCheck(PageDisplayRunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"race: renders settle");
    NSUInteger renders = page ? [reader completedRendersOfPage:page.integerValue] : 0;
    PageDisplayCheck(renders == 1, [NSString stringWithFormat:@"race: page %ld renders once at screen scale, not "
                                                              @"%lu times",
                                                              (long)page.integerValue + 1, (unsigned long)renders]);
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
        gGateEntered = dispatch_semaphore_create(0);
        gGateRelease = dispatch_semaphore_create(0);
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
        gOriginalCancel = method_setImplementation(
            class_getInstanceMethod(NSClassFromString(@"SPDFRenderOperation"), @selector(cancel)), (IMP)RaceCancel);

        NSString* longSet = PageDisplayWriteDrawingSet(root, @"Long set.pdf", 40, 3000);

        PageDisplayReader* reader = [PageDisplayReader new];
        reader.completedRenders = [NSMutableArray array];
        gReader = reader;
        [reader applicationDidFinishLaunching:[NSNotification notificationWithName:@"PageDisplayTests" object:nil]];
        [reader.testWindow setContentSize:NSMakeSize(1500, 940)];
        PageDisplayRunFor(0.4);

        RenderQueueEntryScenario(reader, longSet);
        PageDisplaySidebarChecks(reader, root);

        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (gPageDisplayFailures) return 1;
    puts("SPDFMacPageDisplayTests passed");
    return 0;
}
