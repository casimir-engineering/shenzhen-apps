// Zoom and pan in presentation mode (part of mac-page-display-tests).
//
// Presentation mode showed one page fitted to the screen and nothing else: the
// document view was exactly the screen, so a zoomed page could not pan, and the
// overlay that takes presentation clicks swallowed pinches and the wheel. Now
// the presented page zooms (pinch, Cmd+Plus, the Fit commands), pans within its
// own edges (wheel, arrows, drag), turns at an edge, and leaving restores the
// reader's view exactly. Driven through the real reader, for a PDF and for a
// Markdown document, with the window never ordered on screen.
#import "SPDFMacPageDisplayTestSupport.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacTabGroupIntegration.h"
#import <objc/runtime.h>

@interface ShenzhenMacDelegate (PresentationZoomAccess)
- (void)enterPresentationMode:(id)sender;
- (void)zoomIn:(id)sender;
- (void)scrollToPage:(NSInteger)pageIndex alignTop:(BOOL)alignTop;
@end

@interface PageDisplayReader (PresentationZoom)
@end
@implementation PageDisplayReader (PresentationZoom)
- (BOOL)presenting { return _presentationMode; }
// A laptop-sized screen, whatever display runs the tests.
- (NSRect)presentationScreenFrame { return NSMakeRect(0, 0, 1440, 900); }
// The test documents sit in a temporary folder; let them be edited in place
// (rotated) as documents in an ordinary folder are.
- (BOOL)pathIsInTemporaryLocation:(NSString*)path { (void)path; return NO; }
- (SPDFFitMode)readerFitMode { return _fitMode; }
- (NSScrollView*)pdfScrollView { return _pageScrollView; }
- (NSView*)overlayView { return _presentationOverlayView; }
// The part of the page on screen and the page, in the presented view's space.
- (void)visible:(NSRect*)visible page:(NSRect*)page {
    if ([self isMarkdownActive]) {
        SPDFMacMarkdownSession* session = self.activeMarkdownSession;
        *visible = session.documentVisibleRect;
        *page = session.documentPageRects[(NSUInteger)session.currentPageIndex].rectValue;
        return;
    }
    *visible = _pageScrollView.contentView.bounds;
    *page = [_pageView rectForPageAtIndex:_pageIndex];
}
- (NSInteger)shownPage {
    return [self isMarkdownActive] ? self.activeMarkdownSession.currentPageIndex : _pageIndex;
}
- (CGFloat)shownZoom {
    return [self isMarkdownActive] ? self.activeMarkdownSession.zoom : _zoom;
}
- (NSPoint)shownOrigin {
    return [self isMarkdownActive] ? self.activeMarkdownSession.documentVisibleRect.origin
                                   : _pageScrollView.contentView.bounds.origin;
}
- (BOOL)settled {
    if (_keyScrollTimer) return NO;
    return [self isMarkdownActive] || (!_liveZooming && !_zoomFinishTimer && self.allQueuesIdle);
}
@end

// Synthetic gesture events: AppKit offers no public constructor for pinches or
// trackpad scrolls, and the reader reads only these fields.
@interface PresentationFakeEvent : NSEvent
@property NSEventType fakeType;
@property NSPoint fakeLocation;
@property NSTimeInterval fakeTimestamp;
@property CGFloat fakeMagnification, fakeDeltaX, fakeDeltaY;
@property NSEventPhase fakePhase;
@property NSEventModifierFlags fakeFlags;
@end
@implementation PresentationFakeEvent
- (NSEventType)type { return self.fakeType; }
- (NSPoint)locationInWindow { return self.fakeLocation; }
- (NSTimeInterval)timestamp { return self.fakeTimestamp; }
- (CGFloat)magnification { return self.fakeMagnification; }
- (CGFloat)scrollingDeltaX { return self.fakeDeltaX; }
- (CGFloat)scrollingDeltaY { return self.fakeDeltaY; }
- (CGFloat)deltaX { return self.fakeDeltaX; }
- (CGFloat)deltaY { return self.fakeDeltaY; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (NSEventPhase)phase { return self.fakePhase; }
- (NSEventPhase)momentumPhase { return NSEventPhaseNone; }
- (NSEventModifierFlags)modifierFlags { return self.fakeFlags; }
@end

static NSTimeInterval gClock;
static NSTimeInterval Tick(void) { return gClock += 0.5; }  // apart enough to never read as a duplicate

static void InertWindowCall(id self, SEL _cmd, id sender) { (void)self; (void)_cmd; (void)sender; }
static void InertWindowOrder(id self, SEL _cmd) { (void)self; (void)_cmd; }

static NSString* gShots;
static void Snapshot(PageDisplayReader* reader, NSString* name) {
    if (!gShots.length) return;
    NSView* content = reader.testWindow.contentView;
    [content layoutSubtreeIfNeeded];
    NSBitmapImageRep* rep = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[gShots stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}

static void Settle(PageDisplayReader* reader) {
    PageDisplayRunFor(0.05);
    PageDisplayRunUntil(10.0, ^{ return [reader settled]; });
    PageDisplayRunFor(0.05);
}

static NSEvent* Key(PageDisplayReader* reader, unsigned short code, NSString* chars, NSEventModifierFlags flags,
                    BOOL repeat) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:Tick()
                        windowNumber:reader.testWindow.windowNumber context:nil characters:chars
         charactersIgnoringModifiers:chars isARepeat:repeat keyCode:code];
}
static void Press(PageDisplayReader* reader, unsigned short code, BOOL repeat) {
    [reader.testWindow sendEvent:Key(reader, code, @" ", 0, repeat)];
}
// A Zoom menu shortcut, the way AppKit routes it: the presentation key monitor
// sees it first and must let it through to the menu.
static BOOL MenuShortcutWith(PageDisplayReader* reader, NSString* key, NSEventModifierFlags flags) {
    NSEvent* event = Key(reader, 18, key, flags, NO);
    if ([reader handlePresentationEvent:event]) return NO;
    return [NSApp.mainMenu performKeyEquivalent:event];
}
static BOOL MenuShortcut(PageDisplayReader* reader, NSString* key) {
    return MenuShortcutWith(reader, key, NSEventModifierFlagCommand);
}
static void Pinch(PageDisplayReader* reader, NSPoint windowPoint, CGFloat delta) {
    PresentationFakeEvent* event = [PresentationFakeEvent new];
    event.fakeType = NSEventTypeMagnify;
    event.fakeLocation = windowPoint;
    event.fakeTimestamp = Tick();
    event.fakeMagnification = delta;
    [[reader.testWindow.contentView hitTest:windowPoint] magnifyWithEvent:event];
}
// One trackpad gesture: fingers down, then each delta.
static void Swipe(PageDisplayReader* reader, NSArray<NSValue*>* deltas) {
    NSView* content = reader.testWindow.contentView;
    NSPoint middle = NSMakePoint(NSMidX(content.bounds), NSMidY(content.bounds));
    NSView* target = [content hitTest:middle];
    for (NSUInteger i = 0; i <= deltas.count; ++i) {
        PresentationFakeEvent* event = [PresentationFakeEvent new];
        event.fakeType = NSEventTypeScrollWheel;
        event.fakeLocation = middle;
        event.fakeTimestamp = i == 0 ? Tick() : (gClock += 0.016);  // one gesture's events, a frame apart
        event.fakePhase = i == 0 ? NSEventPhaseBegan : NSEventPhaseChanged;
        if (i > 0) {
            event.fakeDeltaX = deltas[i - 1].pointValue.x;
            event.fakeDeltaY = deltas[i - 1].pointValue.y;
        }
        [target scrollWheel:event];
    }
}
static void Mouse(PageDisplayReader* reader, NSEventType type, NSPoint windowPoint) {
    [reader.testWindow sendEvent:[NSEvent mouseEventWithType:type location:windowPoint modifierFlags:0
                                                   timestamp:Tick() windowNumber:reader.testWindow.windowNumber
                                                     context:nil eventNumber:0 clickCount:1 pressure:1.0]];
}

static NSString* Describe(PageDisplayReader* reader) {
    NSRect visible, page;
    [reader visible:&visible page:&page];
    return [NSString stringWithFormat:@"page %ld zoom %.3f visible %@ page %@", (long)reader.shownPage + 1,
                                      reader.shownZoom, NSStringFromRect(visible), NSStringFromRect(page)];
}
static BOOL Near(CGFloat a, CGFloat b) { return fabs(a - b) <= 1.0; }

// Every presentation step, for one document.
static void PresentationScenario(PageDisplayReader* reader, NSString* label) {
    NSString* (^what)(NSString*) = ^NSString*(NSString* check) {
        return [NSString stringWithFormat:@"presentation (%@): %@ -- %@", label, check, Describe(reader)];
    };
    BOOL markdown = [reader isMarkdownActive];
    // A reader view to come back to: zoomed in, scrolled down a little.
    [reader zoomIn:nil];
    Settle(reader);
    if (markdown) [reader.activeMarkdownSession scrollByDocumentDeltaX:0 deltaY:150];
    else [reader documentViewPanToProposedOrigin:NSOffsetRect(reader.pdfScrollView.contentView.bounds, 0, 150).origin];
    Settle(reader);
    NSInteger page0 = reader.shownPage;
    CGFloat zoom0 = reader.shownZoom;
    NSPoint origin0 = reader.shownOrigin;
    SPDFFitMode fit0 = reader.readerFitMode;

    [reader enterPresentationMode:nil];
    Settle(reader);
    NSRect visible, page;
    [reader visible:&visible page:&page];
    PageDisplayCheck(reader.presenting && !reader.testWindow.visible, what(@"presents, still off screen"));
    PageDisplayCheck(NSContainsRect(NSInsetRect(visible, -1, -1), page) &&
                         (Near(NSWidth(page), NSWidth(visible)) || Near(NSHeight(page), NSHeight(visible))),
                     what(@"opens at Fit Page: the whole page, touching two edges of the screen"));
    NSScrollView* scroller = [reader presentationEventTargetView];
    PageDisplayCheck(!scroller.hasHorizontalScroller && !scroller.hasVerticalScroller, what(@"shows no scroll bars"));
    CGFloat fitZoom = reader.shownZoom;
    NSPoint fitOrigin = reader.shownOrigin;
    Snapshot(reader, [label stringByAppendingString:@" 1 fit page"]);

    PageDisplayCheck(MenuShortcut(reader, @"2"), what(@"Cmd+2 reaches Fit Width"));
    Settle(reader);
    [reader visible:&visible page:&page];
    PageDisplayCheck(reader.readerFitMode == SPDFFitModeWidth && Near(NSWidth(page), NSWidth(visible)) &&
                         NSHeight(page) > NSHeight(visible) && NSContainsRect(NSInsetRect(page, -1, -1), visible),
                     what(@"Fit Width fills the screen's width, the page taller than it, the view inside the page"));
    PageDisplayCheck(!scroller.hasHorizontalScroller && !scroller.hasVerticalScroller,
                     what(@"Fit Width shows no scroll bars"));
    Snapshot(reader, [label stringByAppendingString:@" 2 fit width"]);
    PageDisplayCheck(MenuShortcut(reader, @"1"), what(@"Cmd+1 reaches Fit Page"));
    Settle(reader);
    PageDisplayCheck(reader.readerFitMode == SPDFFitModePage && fabs(reader.shownZoom - fitZoom) < 0.001 &&
                         Near(reader.shownOrigin.x, fitOrigin.x) && Near(reader.shownOrigin.y, fitOrigin.y),
                     what(@"Cmd+1 is exactly the opening Fit Page view again"));

    // Pinch at a point a third of the way in: that point of the page stays put.
    NSView* content = reader.testWindow.contentView;
    NSPoint pointer = NSMakePoint(NSWidth(content.bounds) * 0.45, NSHeight(content.bounds) * 0.6);
    NSView* documentView = scroller.documentView;
    NSPoint before = [documentView convertPoint:pointer fromView:nil];
    [reader visible:&visible page:&page];
    NSPoint fraction = NSMakePoint((before.x - NSMinX(page)) / NSWidth(page), (before.y - NSMinY(page)) / NSHeight(page));
    for (int i = 0; i < 6; ++i) Pinch(reader, pointer, 0.25);
    Settle(reader);
    NSPoint after = [documentView convertPoint:pointer fromView:nil];
    [reader visible:&visible page:&page];
    NSPoint fractionAfter = NSMakePoint((after.x - NSMinX(page)) / NSWidth(page), (after.y - NSMinY(page)) / NSHeight(page));
    PageDisplayCheck(reader.shownZoom > fitZoom * 2.5 && reader.readerFitMode == SPDFFitModeCustom,
                     what(@"a pinch zooms the page in"));
    PageDisplayCheck(fabs(fraction.x - fractionAfter.x) < 0.02 && fabs(fraction.y - fractionAfter.y) < 0.02,
                     what([NSString stringWithFormat:@"the pinch keeps the page point under the pointer (%.3f,%.3f -> "
                                                     @"%.3f,%.3f)", fraction.x, fraction.y, fractionAfter.x,
                                                     fractionAfter.y]));
    CGFloat pinched = reader.shownZoom;
    PageDisplayCheck(MenuShortcut(reader, @"+"), what(@"Cmd+Plus reaches Zoom In"));
    Settle(reader);
    PageDisplayCheck(reader.shownZoom > pinched * 1.1, what(@"Cmd+Plus zooms in further"));
    PageDisplayCheck(!scroller.hasHorizontalScroller && !scroller.hasVerticalScroller,
                     what(@"a zoomed page shows no scroll bars"));

    // The wheel pans to each edge and no further.
    NSInteger page1 = reader.shownPage;
    for (NSValue* push in @[ [NSValue valueWithPoint:NSMakePoint(0, -20000)], [NSValue valueWithPoint:NSMakePoint(-20000, 0)] ])
        Swipe(reader, @[ push, push, push, push ]);
    Settle(reader);
    [reader visible:&visible page:&page];
    PageDisplayCheck(Near(NSMaxY(visible), NSMaxY(page)) && Near(NSMaxX(visible), NSMaxX(page)) && reader.shownPage == page1,
                     what(@"the wheel pans to the page's bottom right edge and stops there, on the same page"));
    Snapshot(reader, [label stringByAppendingString:@" 3 zoomed and panned"]);
    for (NSValue* push in @[ [NSValue valueWithPoint:NSMakePoint(0, 20000)], [NSValue valueWithPoint:NSMakePoint(20000, 0)] ])
        Swipe(reader, @[ push, push, push, push ]);
    Settle(reader);
    [reader visible:&visible page:&page];
    PageDisplayCheck(Near(NSMinY(visible), NSMinY(page)) && Near(NSMinX(visible), NSMinX(page)) && reader.shownPage == page1,
                     what(@"the wheel pans to the top left edge and stops there; a scroll toward the previous page "
                          @"that ends at the top does not turn it"));

    // A drag pans; a click turns the page.
    NSPoint origin = reader.shownOrigin;
    NSPoint start = NSMakePoint(NSMidX(content.bounds), NSMidY(content.bounds));
    Mouse(reader, NSEventTypeLeftMouseDown, start);
    Mouse(reader, NSEventTypeLeftMouseDragged, NSMakePoint(start.x - 40, start.y + 30));
    Mouse(reader, NSEventTypeLeftMouseDragged, NSMakePoint(start.x - 80, start.y + 60));
    Mouse(reader, NSEventTypeLeftMouseUp, NSMakePoint(start.x - 80, start.y + 60));
    Settle(reader);
    CGFloat magnified = markdown ? reader.shownZoom : 1.0;
    PageDisplayCheck(reader.shownPage == page1 && Near(reader.shownOrigin.x - origin.x, 80 / magnified) &&
                         Near(reader.shownOrigin.y - origin.y, 60 / magnified),
                     what(@"a drag pans the page with the pointer and does not turn it"));

    // Arrows pan; a held arrow stops at the edge; a fresh press there turns the page.
    for (int i = 0; i < 60 && reader.shownOrigin.y < NSMaxY(page) - NSHeight(visible) - 1; ++i) {
        Press(reader, 125, NO);
        Settle(reader);
        [reader visible:&visible page:&page];
    }
    [reader visible:&visible page:&page];
    PageDisplayCheck(Near(NSMaxY(visible), NSMaxY(page)) && reader.shownPage == page1,
                     what(@"the down arrow pans to the bottom edge without turning the page"));
    Press(reader, 125, YES);
    Settle(reader);
    PageDisplayCheck(reader.shownPage == page1, what(@"a held down arrow stops at the bottom edge"));
    CGFloat zoomed = reader.shownZoom;
    Press(reader, 125, NO);
    Settle(reader);
    [reader visible:&visible page:&page];
    PageDisplayCheck(reader.shownPage == page1 + 1 && fabs(reader.shownZoom - zoomed) < 0.001 &&
                         Near(NSMinX(visible), NSMinX(page)) && Near(NSMinY(visible), NSMinY(page)),
                     what(@"a fresh down arrow at the bottom turns the page, keeping the zoom, at its top left"));
    // A scroll starting at the bottom edge turns the page too.
    Swipe(reader, @[ [NSValue valueWithPoint:NSMakePoint(0, -20000)], [NSValue valueWithPoint:NSMakePoint(0, -20000)] ]);
    Settle(reader);
    Swipe(reader, @[ [NSValue valueWithPoint:NSMakePoint(0, -4)], [NSValue valueWithPoint:NSMakePoint(0, -4)] ]);
    Settle(reader);
    PageDisplayCheck(reader.shownPage == page1 + 2, what(@"a scroll starting at the bottom edge turns the page"));
    Mouse(reader, NSEventTypeLeftMouseDown, start);
    Mouse(reader, NSEventTypeLeftMouseUp, start);
    Settle(reader);
    PageDisplayCheck(reader.shownPage == page1 + 3, what(@"a click on a zoomed page turns it"));

    // Back on the first page, at Fit Page: the page fits, so the wheel and arrows
    // turn pages again.
    Press(reader, 115, NO);  // Home
    Settle(reader);
    MenuShortcut(reader, @"1");
    Settle(reader);
    Press(reader, 124, NO);
    Settle(reader);
    PageDisplayCheck(reader.shownPage == 1, what(@"at Fit Page the right arrow turns the page"));
    Swipe(reader, @[ [NSValue valueWithPoint:NSMakePoint(0, 4)], [NSValue valueWithPoint:NSMakePoint(0, 4)] ]);
    Settle(reader);
    PageDisplayCheck(reader.shownPage == 0, what(@"at Fit Page a scroll turns the page"));
    for (NSInteger i = 0; i < page0; ++i) {
        Press(reader, 124, NO);
        Settle(reader);
    }
    MenuShortcut(reader, @"+");
    Settle(reader);

    // Esc: the reader's view exactly as it was.
    Press(reader, 53, NO);
    Settle(reader);
    PageDisplayCheck(!reader.presenting, what(@"Esc leaves presentation mode"));
    PageDisplayCheck(reader.shownPage == page0 && fabs(reader.shownZoom - zoom0) < 0.0005 && reader.readerFitMode == fit0 &&
                         Near(reader.shownOrigin.x, origin0.x) && Near(reader.shownOrigin.y, origin0.y),
                     what([NSString stringWithFormat:@"leaving restores the reader's zoom %.3f, fit %ld and place %@",
                                                     zoom0, (long)fit0, NSStringFromPoint(origin0)]));
    SPDFDocumentTab* tab = [reader selectedTab];
    PageDisplayCheck(fabs(tab.zoom - zoom0) < 0.0005 && tab.fitMode == fit0,
                     what(@"the tab keeps the reader's zoom, not the presentation's"));
}

// Cmd+R while presenting: the page turns at once, and the fit in force fits
// the turned page; leaving shows the reader the same turn.
static void RotationScenario(PageDisplayReader* reader, NSString* label) {
    NSString* (^what)(NSString*) = ^NSString*(NSString* check) {
        return [NSString stringWithFormat:@"rotation (%@): %@ -- %@", label, check, Describe(reader)];
    };
    BOOL markdown = [reader isMarkdownActive];
    [reader enterPresentationMode:nil];
    Settle(reader);
    MenuShortcut(reader, @"2");
    Settle(reader);
    NSRect visible, page;
    [reader visible:&visible page:&page];
    CGFloat aspect = NSWidth(page) / NSHeight(page);
    NSInteger shown = reader.shownPage;
    PageDisplayCheck(MenuShortcut(reader, @"r"), what(@"Cmd+R reaches Rotate Clockwise"));
    PageDisplayRunUntil(10.0, ^{
        NSRect v, p;
        [reader visible:&v page:&p];
        return (BOOL)(fabs(NSWidth(p) / NSHeight(p) - 1.0 / aspect) < 0.02 &&
                      (!markdown || reader.activeMarkdownSession.navigationReady));
    });
    Settle(reader);
    [reader visible:&visible page:&page];
    PageDisplayCheck(reader.presenting && fabs(NSWidth(page) / NSHeight(page) - 1.0 / aspect) < 0.02,
                     what(@"the page turns while presenting"));
    PageDisplayCheck(reader.readerFitMode == SPDFFitModeWidth && Near(NSWidth(page), NSWidth(visible)) &&
                         NSContainsRect(NSInsetRect(page, -1, -1), visible),
                     what(@"Fit Width, still in force, fits the turned page"));
    PageDisplayCheck(markdown || reader.shownPage == shown, what(@"the same page is shown"));
    NSScrollView* scroller = [reader presentationEventTargetView];
    PageDisplayCheck(!scroller.hasHorizontalScroller && !scroller.hasVerticalScroller, what(@"no scroll bars"));
    Snapshot(reader, [label stringByAppendingString:@" 4 rotated, fit width"]);
    for (int i = 0; i < 4; ++i) Pinch(reader, NSMakePoint(300, 300), 0.25);
    Settle(reader);
    Swipe(reader, @[ [NSValue valueWithPoint:NSMakePoint(-20000, -20000)] ]);
    Settle(reader);
    [reader visible:&visible page:&page];
    PageDisplayCheck(reader.presenting && Near(NSMaxX(visible), NSMaxX(page)) && Near(NSMaxY(visible), NSMaxY(page)),
                     what(@"the turned page zooms and pans to its edges"));
    Press(reader, 53, NO);
    Settle(reader);
    [reader visible:&visible page:&page];
    PageDisplayCheck(!reader.presenting && fabs(NSWidth(page) / NSHeight(page) - 1.0 / aspect) < 0.02,
                     what(@"the reader shows the page turned after leaving"));
}

static NSString* WritePortraitDeck(NSString* dir) {
    NSString* path = [dir stringByAppendingPathComponent:@"Deck.pdf"];
    CGRect a4 = CGRectMake(0, 0, 595.28, 841.89);
    CGContextRef ctx = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &a4, NULL);
    for (int p = 0; p < 6; p++) {
        CGPDFContextBeginPage(ctx, NULL);
        CGContextSetRGBStrokeColor(ctx, 0.75, 0.80, 0.90, 1);
        for (int x = 0; x <= 595; x += 35) CGContextStrokeRect(ctx, CGRectMake(x, 0, 0.5, 842));
        for (int y = 0; y <= 842; y += 35) CGContextStrokeRect(ctx, CGRectMake(0, y, 595, 0.5));
        CGFloat colors[4][3] = {{0.85, 0.2, 0.1}, {0.1, 0.55, 0.2}, {0.15, 0.3, 0.85}, {0.9, 0.65, 0.05}};
        CGRect corners[4] = {CGRectMake(0, 782, 60, 60), CGRectMake(535, 782, 60, 60), CGRectMake(0, 0, 60, 60),
                             CGRectMake(535, 0, 60, 60)};
        for (int c = 0; c < 4; c++) {
            CGContextSetRGBFillColor(ctx, colors[c][0], colors[c][1], colors[c][2], 1);
            CGContextFillRect(ctx, corners[c]);
        }
        NSGraphicsContext* previous = NSGraphicsContext.currentContext;
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [[NSString stringWithFormat:@"Slide %d", p + 1] drawAtPoint:NSMakePoint(150, 420)
                                                    withAttributes:@{NSFontAttributeName : [NSFont boldSystemFontOfSize:64]}];
        NSGraphicsContext.currentContext = previous;
        CGPDFContextEndPage(ctx);
    }
    CGPDFContextClose(ctx);
    CGContextRelease(ctx);
    return path;
}

static NSString* WriteNotes(NSString* dir) {
    NSMutableString* text = [NSMutableString stringWithString:@"# Bring-up notes\n\n"];
    for (int section = 1; section <= 14; ++section) {
        [text appendFormat:@"## Section %d\n\n", section];
        for (int line = 0; line < 4; ++line)
            [text appendString:@"The flex is powered from the 3.3 V rail through the load switch, and the sensor "
                               @"wakes once the reset line is released, after the clocks have settled.\n\n"];
    }
    NSString* path = [dir stringByAppendingPathComponent:@"Notes.md"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

void PageDisplayPresentationChecks(PageDisplayReader* reader, NSString* root) {
    gShots = NSProcessInfo.processInfo.environment[@"SPDF_PRESENTATION_SNAPSHOTS"];
    gClock = NSProcessInfo.processInfo.systemUptime;
    // Presentation mode brings its window forward; this one stays off screen.
    for (NSString* name in @[ @"makeKeyAndOrderFront:", @"orderFront:" ])
        method_setImplementation(class_getInstanceMethod(NSWindow.class, NSSelectorFromString(name)), (IMP)InertWindowCall);
    method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(orderFrontRegardless)),
                             (IMP)InertWindowOrder);

    NSInteger tab = PageDisplayAddTab(reader, WritePortraitDeck(root), 2);
    [reader selectTabAtIndex:tab];
    PageDisplayCheck(PageDisplayRunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"presentation: the deck opens");
    PresentationScenario(reader, @"PDF");
    RotationScenario(reader, @"PDF");

    [reader selectTabAtIndex:[reader appendNewTabToActiveGroup:[reader newTabForPath:WriteNotes(root)]]];
    PageDisplayCheck(PageDisplayRunUntil(30.0, ^{
                         return (BOOL)([reader isMarkdownActive] && reader.activeMarkdownSession.navigationReady &&
                                       reader.activeMarkdownSession.pageCount >= 4);
                     }),
                     @"presentation: the Markdown notes open");
    PageDisplayRunFor(0.3);
    [reader.activeMarkdownSession goToPageAtIndex:1];
    PresentationScenario(reader, @"Markdown");
    RotationScenario(reader, @"Markdown");
    PageDisplayCheck(!reader.testWindow.visible, @"presentation: the test window never came on screen");
}
