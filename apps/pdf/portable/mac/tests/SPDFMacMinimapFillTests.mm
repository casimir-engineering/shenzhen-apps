// Minimap thumbnails must fill on their own, with no scroll event, after a
// document opens (at page 1 or restored deeper), after a jump, a window resize
// and a tab switch. Production-linked: the real coordinator, render queues and
// strip run offscreen; nothing is displayed and no state outside a temp dir is
// touched. The PDFs are synthetic, generated here with the traits of the
// drawing sets that showed the bug (A3 vector-heavy sheets, one A4 sheet, 10+
// pages).
//
// The failure it guards (26.10.11): the strip draws its own snapshot of the
// reader's page objects. A full-page render replaces a page's object; a
// thumbnail finishing after that was stored on the replacement only, so the
// slot kept its grey placeholder until a scroll reassigned the snapshot. On a
// busy machine thumbnails routinely finish after their neighbours' page
// renders, so the scenarios below hold the thumbnail queue until those page
// renders have landed -- the interleaving the owner hit, made deterministic.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMinimapView.h"
#import "SPDFMacMinimapViewTheme.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFUpdater.h"
#import <objc/runtime.h>
#undef main

static NSUInteger failures;
static void Check(BOOL ok, NSString* what) {
    if (ok) return;
    failures++;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
}

static IMP gOriginalOrder;
static NSUInteger gDisplayAttempts;
// The reader under test never reaches the screen: ordering a window in is
// counted (and refused) instead.
static void RefuseOrder(id window, SEL sel, NSInteger place, NSInteger other) {
    if (place == NSWindowOut) {
        ((void (*)(id, SEL, NSInteger, NSInteger))gOriginalOrder)(window, sel, place, other);
        return;
    }
    gDisplayAttempts++;
}
static void Inert(id self, SEL _cmd) { (void)self; (void)_cmd; }
static NSModalResponse NoModal(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    Check(NO, @"no modal alert during minimap scenarios");
    return NSAlertSecondButtonReturn;
}

@interface SPDFMinimapView (FillTestLayout)
- (BOOL)layoutScale:(CGFloat*)scaleOut gap:(CGFloat*)gapOut contentTop:(CGFloat*)topOut
      contentHeight:(CGFloat*)heightOut visibleRect:(NSRect*)visibleOut;
- (NSRect)miniRectForPage:(SPDFRenderedPage*)targetPage scale:(CGFloat)scale gap:(CGFloat)gap;
@end

@interface ShenzhenMacDelegate (MinimapFillAccess)
- (SPDFDocumentTab*)newTabForPath:(NSString*)path;
- (void)applicationDidFinishLaunching:(NSNotification*)notification;
- (void)goToPage:(NSInteger)pageIndex preserveSinglePagePosition:(BOOL)preserveSinglePagePosition;
@end

// Declared here too so this file also builds against the pre-fix strip, where
// the check reports the missing adoption instead of failing to compile.
@interface SPDFMinimapView (FillTestAdoption)
- (void)noteThumbnailLoadedForPage:(SPDFRenderedPage*)page;
@end

@interface MinimapFillReader : ShenzhenMacDelegate
@end

@implementation MinimapFillReader
// Launch side effects unrelated to rendering: settings sheet, global shortcut
// monitor, sibling-window processes, history capture, AI indexing.
- (void)showUnifiedSettingsAfterFirstPaint {}
- (void)showUnifiedSettings:(id)sender { (void)sender; }
- (void)installWindowArrangementShortcutMonitor {}
- (void)spawnPendingRestoredWindowsIfNeeded {}
- (void)resumePersistentStateSavesAfterLaunch {}
- (void)collectionDidOpenPath:(NSString*)path { (void)path; }
- (void)aiDocumentDidOpen:(NSString*)path { (void)path; }

- (NSWindow*)fillWindow { return _window; }
- (SPDFMinimapView*)fillStrip { return _minimapView; }
- (NSArray<SPDFRenderedPage*>*)livePages { return [_renderedPages copy]; }
- (NSInteger)fillCurrentPage { return _pageIndex; }
- (BOOL)fillStripVisible { return _minimapVisible; }
- (NSUInteger)queuedThumbnails { return _queuedMinimapThumbnailPages.count; }
- (BOOL)pageRendersIdle { return _renderQueue.operationCount == 0 && _backgroundRenderQueue.operationCount == 0; }
// renderDocumentAndScrollToPage: resumes every render queue, so the hold is
// applied after the action under test has enqueued its first thumbnails.
- (void)holdThumbnails { _minimapQueue.suspended = YES; }
- (void)releaseThumbnails { _minimapQueue.suspended = NO; }
- (BOOL)visiblePageHasFullImage {
    if (_pageIndex < 0 || _pageIndex >= (NSInteger)_renderedPages.count) return NO;
    return _renderedPages[(NSUInteger)_pageIndex].image != nil;
}
- (NSUInteger)fullImagesNearCurrentPage {
    NSUInteger count = 0;
    for (NSInteger i = MAX((NSInteger)0, _pageIndex - 3); i <= _pageIndex + 3 && i < (NSInteger)_renderedPages.count; i++)
        count += _renderedPages[(NSUInteger)i].image ? 1 : 0;
    return count;
}
- (NSUInteger)modelThumbnailCount {
    NSUInteger count = 0;
    for (SPDFRenderedPage* page in _renderedPages) count += page.minimapImage ? 1 : 0;
    return count;
}
@end

static void RunFor(NSTimeInterval seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}

static BOOL RunUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) {
        if (until.timeIntervalSinceNow <= 0) return NO;
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return YES;
}

// Vector-heavy sheets: thousands of stroked curves per page, the shape of a
// schematic that takes MuPDF real time to rasterize. Page 4 is A4 portrait so
// the strip's mixed-size geometry is exercised too.
static NSString* WriteDrawingSet(NSString* dir, NSString* name, NSInteger pages, NSInteger curves, BOOL a4Only) {
    NSString* path = [dir stringByAppendingPathComponent:name];
    CGRect a3 = CGRectMake(0, 0, 1190.55, 841.89), a4 = CGRectMake(0, 0, 595.28, 841.89);
    CGContextRef ctx = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &a3, NULL);
    for (NSInteger p = 0; p < pages; p++) {
        CGRect box = a4Only || p == 3 ? a4 : a3;
        NSDictionary* info = @{(__bridge NSString*)kCGPDFContextMediaBox : [NSData dataWithBytes:&box length:sizeof(box)]};
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

// What the strip actually shows, read back from the pixels its own drawRect:
// produces. A slot counts as filled when it carries linework far from the
// sheet's paper; the placeholder's ruled lines stay within ~0.2 of it in both
// themes. Slots are inset past the viewport indicator and page outline.
static NSIndexSet* StripSlotsShowing(SPDFMinimapView* strip, BOOL thumbnails, NSIndexSet** visibleOut) {
    NSMutableIndexSet* matching = [NSMutableIndexSet indexSet];
    NSMutableIndexSet* visible = [NSMutableIndexSet indexSet];
    if (visibleOut) *visibleOut = visible;
    CGFloat scale = 1, gap = 4, top = 8, height = 0;
    NSRect indicator = NSZeroRect;
    if (![strip layoutScale:&scale gap:&gap contentTop:&top contentHeight:&height visibleRect:&indicator]) return matching;
    NSBitmapImageRep* rep = [strip bitmapImageRepForCachingDisplayInRect:strip.bounds];
    [strip cacheDisplayInRect:strip.bounds toBitmapImageRep:rep];
    NSColor* paper = [strip.pageFillColor colorUsingColorSpace:rep.colorSpace];
    CGFloat sx = rep.pixelsWide / NSWidth(strip.bounds), sy = rep.pixelsHigh / NSHeight(strip.bounds);
    for (SPDFRenderedPage* page in strip.pages) {
        NSRect slot = [strip miniRectForPage:page scale:scale gap:gap];
        slot.origin.y += top;
        slot = NSIntersectionRect(NSInsetRect(slot, 4, 4), strip.bounds);
        if (NSHeight(slot) < 6 || NSWidth(slot) < 6) continue;
        [visible addIndex:(NSUInteger)page.pageIndex];
        NSInteger ink = 0;
        for (NSInteger y = (NSInteger)(NSMinY(slot) * sy); y < (NSInteger)(NSMaxY(slot) * sy); y++) {
            for (NSInteger x = (NSInteger)(NSMinX(slot) * sx); x < (NSInteger)(NSMaxX(slot) * sx); x++) {
                NSColor* c = [rep colorAtX:x y:y];
                CGFloat d = MAX(fabs(c.redComponent - paper.redComponent),
                                MAX(fabs(c.greenComponent - paper.greenComponent),
                                    fabs(c.blueComponent - paper.blueComponent)));
                if (d > 0.35) ink++;
            }
        }
        if ((ink > 20) == thumbnails) [matching addIndex:(NSUInteger)page.pageIndex];
    }
    return matching;
}

static NSString* Describe(NSIndexSet* pages) {
    NSMutableArray* names = [NSMutableArray array];
    [pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      [names addObject:@(index + 1).stringValue];
    }];
    return names.count ? [names componentsJoinedByString:@","] : @"none";
}

// Called right after the action under test returns. With `visibleFirst`, the
// action must already have adopted the visible page's full render while no
// thumbnail of the new pages has landed: thumbnails never come before it.
// Thumbnails are then held until the page renders the action scheduled (the
// visible page plus its prefetch neighbourhood) have been adopted, and
// released; the run loop idles with no scroll event at all. Every slot the
// strip shows, plus a margin of two pages each side, must end up drawn.
static void ExpectStripFills(MinimapFillReader* reader, NSString* scenario, NSUInteger neighbours, BOOL visibleFirst) {
    [reader holdThumbnails];
    if (visibleFirst)
        Check(reader.visiblePageHasFullImage && reader.modelThumbnailCount == 0,
              [scenario stringByAppendingString:@": the visible page renders before any thumbnail"]);
    BOOL rendered = RunUntil(30.0, ^{
      return (BOOL)(reader.pageRendersIdle && reader.visiblePageHasFullImage &&
                    reader.fullImagesNearCurrentPage >= neighbours);
    });
    Check(rendered, [scenario stringByAppendingString:@": neighbour page renders land"]);
    [reader releaseThumbnails];
    NSIndexSet* visible = nil;
    StripSlotsShowing(reader.fillStrip, YES, &visible);
    Check(visible.count > 0, [scenario stringByAppendingString:@": strip lays out slots"]);
    NSMutableIndexSet* wanted = [NSMutableIndexSet indexSet];
    if (visible.count) {
        NSInteger first = MAX((NSInteger)0, (NSInteger)visible.firstIndex - 2);
        NSInteger last = MIN((NSInteger)reader.livePages.count - 1, (NSInteger)visible.lastIndex + 2);
        [wanted addIndexesInRange:NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1))];
    }
    BOOL modelFilled = RunUntil(30.0, ^{
      NSArray<SPDFRenderedPage*>* pages = reader.livePages;
      __block BOOL all = YES;
      [wanted enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
        if (index < pages.count && !pages[index].minimapImage) { all = NO; *stop = YES; }
      }];
      return (BOOL)(all && reader.queuedThumbnails == 0);
    });
    Check(modelFilled, [scenario stringByAppendingString:@": thumbnails render for the visible slots and margin"]);
    RunFor(0.4);  // Idle: nothing may depend on a later scroll tick.
    NSIndexSet* placeholders = StripSlotsShowing(reader.fillStrip, NO, &visible);
    Check(placeholders.count == 0,
          [NSString stringWithFormat:@"%@: strip still shows placeholders for page(s) %@ of visible %@ without a "
                                     @"scroll", scenario, Describe(placeholders), Describe(visible)]);
    NSArray<SPDFRenderedPage*>* held = reader.fillStrip.pages;
    __block NSUInteger stale = 0;
    [wanted enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      if (index < held.count && !held[index].minimapImage) stale++;
    }];
    Check(stale == 0, [NSString stringWithFormat:@"%@: %lu strip page(s) lack the thumbnail the reader rendered",
                                                 scenario, (unsigned long)stale]);
}

static NSInteger OpenTab(MinimapFillReader* reader, NSString* path, NSInteger page, BOOL map, BOOL select) {
    SPDFDocumentTab* tab = [reader newTabForPath:path];
    tab.pageIndex = page - 1;
    tab.fitMode = SPDFFitModePage;
    tab.showMinimap = map;
    NSInteger index = [reader appendNewTabToActiveGroup:tab];
    if (select) [reader selectTabAtIndex:index];
    return index;
}

// The adoption itself, without timing: a thumbnail stored on a replacement page
// object reaches the strip, and the strip's cached layout survives the swap.
static void CheckStripAdoptsReplacementPage(void) {
    SPDFMinimapView* strip = [[SPDFMinimapView alloc] initWithFrame:NSMakeRect(0, 0, 126, 860)];
    NSMutableArray<SPDFRenderedPage*>* pages = [NSMutableArray array];
    for (NSInteger i = 0; i < 6; i++) {
        SPDFRenderedPage* page = [SPDFRenderedPage new];
        page.pageIndex = i; page.pageWidth = 1190.55; page.pageHeight = 841.89;
        [pages addObject:page];
    }
    strip.pages = pages;
    strip.documentHeight = 6000; strip.documentWidth = 1300; strip.documentScale = 0.8;
    // Exactly sheet 1 in view, so the viewport indicator hugs slot 1 only.
    strip.documentVisibleRect = NSMakeRect(173, 22, 1190.55 * 0.8, 841.89 * 0.8);
    strip.liveViewportOnly = YES;
    StripSlotsShowing(strip, YES, NULL);  // builds the cached strip, as a display pass would
    SPDFRenderedPage* replacement = [SPDFRenderedPage new];
    replacement.pageIndex = 2; replacement.pageWidth = 1190.55; replacement.pageHeight = 841.89;
    NSImage* ink = [NSImage imageWithSize:NSMakeSize(108, 76) flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [NSColor.blackColor setFill];
      NSRectFill(NSInsetRect(rect, 8, 8));
      return YES;
    }];
    replacement.minimapImage = ink;
    BOOL adopts = [strip respondsToSelector:@selector(noteThumbnailLoadedForPage:)];
    Check(adopts, @"strip accepts the live page object a thumbnail was stored on");
    if (!adopts) return;
    [strip noteThumbnailLoadedForPage:replacement];
    Check(strip.pages[2] == replacement, @"strip adopts the live page object a thumbnail was stored on");
    NSIndexSet* filled = StripSlotsShowing(strip, YES, NULL);
    Check([filled containsIndex:2] && ![filled containsIndex:1] && ![filled containsIndex:3],
          [NSString stringWithFormat:@"adopted thumbnail is drawn into the cached strip (filled: %@)", Describe(filled)]);
    SPDFRenderedPage* resized = [SPDFRenderedPage new];
    resized.pageIndex = 3; resized.pageWidth = 595.28; resized.pageHeight = 841.89; resized.minimapImage = ink;
    [strip noteThumbnailLoadedForPage:resized];
    Check(strip.pages[3] != resized, @"a page object with different geometry is not swapped into the layout");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString* state = [root stringByAppendingPathComponent:@"state"];
        [NSFileManager.defaultManager createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("SPDF_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("SPDF_NO_ACTIVATE", "1", 1);
        setenv("SPDF_NO_WINDOW_FIRST", "1", 1);
        setenv("SPDF_DISABLE_LAUNCH_PRERENDER", "1", 1);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        gOriginalOrder = method_setImplementation(
            class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:)), (IMP)RefuseOrder);
        method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)NoModal);
        for (NSString* name in @[ @"consumePendingUpdateMarkerAndSweep", @"scheduleDailyUpdateCheckIfNeeded",
                                  @"armRecurringUpdateCheck" ]) {
            Method method = class_getInstanceMethod(SPDFUpdater.class, NSSelectorFromString(name));
            if (method) method_setImplementation(method, (IMP)Inert);
        }

        CheckStripAdoptsReplacementPage();

        NSString* setA = WriteDrawingSet(root, @"Drawing set A.pdf", 12, 9000, NO);
        NSString* setB = WriteDrawingSet(root, @"Drawing set B.pdf", 10, 9000, NO);
        NSString* setC = WriteDrawingSet(root, @"Drawing set C.pdf", 11, 9000, NO);
        NSString* longSet = WriteDrawingSet(root, @"Long set.pdf", 90, 700, YES);
        NSString* hiddenSet = WriteDrawingSet(root, @"Hidden map.pdf", 10, 2000, NO);

        MinimapFillReader* reader = [MinimapFillReader new];
        [reader applicationDidFinishLaunching:[NSNotification notificationWithName:@"MinimapFillTests" object:nil]];
        [reader.fillWindow setContentSize:NSMakeSize(1500, 940)];
        RunFor(0.2);

        // Laziness: with the map hidden, opening renders no thumbnail at all.
        OpenTab(reader, hiddenSet, 1, NO, YES);
        Check(!reader.fillStripVisible, @"hidden map stays hidden for the opened document");
        RunUntil(10.0, ^{ return reader.pageRendersIdle; });
        RunFor(0.4);
        Check(reader.modelThumbnailCount == 0 && reader.queuedThumbnails == 0,
              @"no thumbnail is rendered or queued while the map is hidden");

        OpenTab(reader, setA, 1, YES, YES);
        Check(reader.fillStripVisible, @"map shows for a document opened with it");
        ExpectStripFills(reader, @"open at page 1", 4, YES);

        // Restored deeper in the set: what the 26.10.11 screenshot showed.
        NSInteger tabB = OpenTab(reader, setB, 7, YES, YES);
        Check(reader.fillCurrentPage == 6, @"document restores at page 7");
        ExpectStripFills(reader, @"open restored at page 7", 5, YES);

        [reader.fillWindow setContentSize:NSMakeSize(1180, 780)];
        ExpectStripFills(reader, @"window resize", 5, YES);

        // Switching to a tab whose document has not been opened yet.
        NSInteger tabC = OpenTab(reader, setC, 5, YES, NO);
        [reader selectTabAtIndex:tabC];
        ExpectStripFills(reader, @"switch to an unopened tab", 5, YES);

        // Switching back to a tab that is already open re-uses its pages.
        [reader selectTabAtIndex:tabB];
        ExpectStripFills(reader, @"switch back to an open tab", 1, NO);

        // A jump far into a long document moves the strip to pages it never
        // drew; the jump renders its page asynchronously, so no visible-first
        // snapshot is taken at the moment it returns.
        OpenTab(reader, longSet, 1, YES, YES);
        RunUntil(20.0, ^{ return (BOOL)(reader.queuedThumbnails == 0 && reader.pageRendersIdle); });
        [reader goToPage:69 preserveSinglePagePosition:NO];
        Check(reader.fillCurrentPage == 69, @"jump lands on page 70");
        ExpectStripFills(reader, @"jump to page 70", 1, NO);

        Check(gDisplayAttempts > 0 && !reader.fillWindow.visible, @"reader stayed offscreen (launch still asked to show)");
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (failures) return 1;
    puts("SPDFMacMinimapFillTests passed");
    return 0;
}
