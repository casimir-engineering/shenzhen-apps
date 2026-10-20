// friends-ui-e2e's driver (SPDFMacFriendsUIE2E.h): rigs, real events, the live view tree, screenshots.

#import "SPDFMacFriendsUIE2E.h"

#import "SPDFMacFriendsAppearance.h"
#import "SPDFMacFriendsTitleBar.h"
#import "mac/SZFriendsListPage.h"
#include "client/szfriends_client.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

int UIFailures = 0;
NSMutableArray<NSString*>* UIFlowResults;
NSString* UIRoot = @"";
NSString* UIShotsRoot = @"";
NSString* UIHelperExecutable = @"";
NSString* UIManifest = @"";

@implementation UIVariant
@end

@implementation UIBridge
- (instancetype)init {
    if ((self = [super init])) {
        _opened = [NSMutableArray array];
        _revealed = [NSMutableArray array];
        _dropdownWidth = 400;
    }
    return self;
}
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button { self.installed = button; }
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button {
    if (self.installed == button) self.installed = nil;
}
- (NSArray<NSDictionary*>*)friendsBridgeOpenDocuments { return @[]; }
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return nil; }
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { [self.opened addObjectsFromArray:paths]; }
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)fileURLs { [self.revealed addObjectsFromArray:fileURLs]; }
- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services { (void)services; }
// The reader's own tokens, at the width this variant asks for.
- (SZFriendsAppearance*)friendsBridgeAppearance {
    SZFriendsAppearance* appearance = SPDFMacFriendsReaderAppearance();
    appearance.dropdownWidth = self.dropdownWidth;
    return appearance;
}
@end

@implementation UIRig
- (SZFriendsDropdownContent*)content { return self.dropdown.content; }
- (SZFriendsListPage*)listPage { return self.dropdown.content.listPage; }
- (NSWindow*)popoverWindow { return self.dropdown.shown ? self.dropdown.content.window : nil; }
@end

#pragma mark - Failures

void UIFail(UIRig* rig, const char* file, int line, const char* condition, NSString* detail) {
    UIFailures++;
    NSString* where = rig ? [NSString stringWithFormat:@"[%@ %@ step %ld] ", rig.variant.name, rig.flow,
                                                       (long)rig.step] : @"";
    fprintf(stderr, "%s:%d: %sexpected %s\n  %s\n", file, line, where.UTF8String, condition, detail.UTF8String);
    if (!rig) return;
    NSView* root = rig.popoverWindow ? rig.content : nil;
    if (root) fprintf(stderr, "  the popover shows:\n%s\n", UIDescribe(root).UTF8String);
    if (rig.popoverWindow) UIShot(rig, @"FAILED");
}

#pragma mark - Off every screen

// Every window this run makes (the reader's, the popover, Settings, its sheets) lives left of and below every
// screen: the person at the Mac never sees the run. AppKit is kept from moving one back (a titled window is
// constrained onto a screen when it is ordered in; a popover may be placed by the screen it should fit), and a
// window found on a screen anyway is taken off at once and fails the run.

static NSRect UIScreensUnion(void) {
    NSRect all = NSZeroRect;
    for (NSScreen* screen in NSScreen.screens) all = NSUnionRect(all, screen.frame);
    return all;
}

BOOL UIOnAnyScreen(NSRect frame) {
    for (NSScreen* screen in NSScreen.screens)
        if (NSIntersectsRect(NSInsetRect(screen.frame, -2, -2), frame)) return YES;
    return NO;
}

NSPoint UIOffscreenOrigin(NSSize size) {
    NSRect all = UIScreensUnion();
    return NSMakePoint(NSMinX(all) - size.width - 3000, NSMinY(all) - size.height - 3000);
}

static NSRect UIKeptOffscreen(NSRect frame) {
    if (UIOnAnyScreen(frame)) frame.origin = UIOffscreenOrigin(frame.size);
    return frame;
}

static IMP UIOriginalSetFrame, UIOriginalSetFrameAnimate, UIOriginalSetOrigin, UIOriginalSetTopLeft,
    UIOriginalOrderWindow, UIOriginalOrderFront, UIOriginalOrderFrontRegardless, UIOriginalMakeKeyAndOrderFront,
    UIOriginalAddChild;

static void UIMoveOffBeforeOrdering(NSWindow* window) {
    if (UIOnAnyScreen(window.frame))
        ((void (*)(id, SEL, NSRect, BOOL))UIOriginalSetFrame)(window, @selector(setFrame:display:),
                                                             UIKeptOffscreen(window.frame), NO);
}

static void UISetFrame(NSWindow* self, SEL _cmd, NSRect frame, BOOL display) {
    ((void (*)(id, SEL, NSRect, BOOL))UIOriginalSetFrame)(self, _cmd, UIKeptOffscreen(frame), display);
}
static void UISetFrameAnimate(NSWindow* self, SEL _cmd, NSRect frame, BOOL display, BOOL animate) {
    (void)animate;
    ((void (*)(id, SEL, NSRect, BOOL, BOOL))UIOriginalSetFrameAnimate)(self, _cmd, UIKeptOffscreen(frame), display,
                                                                      NO);
}
static void UISetFrameOrigin(NSWindow* self, SEL _cmd, NSPoint origin) {
    NSRect frame = UIKeptOffscreen(NSMakeRect(origin.x, origin.y, NSWidth(self.frame), NSHeight(self.frame)));
    ((void (*)(id, SEL, NSPoint))UIOriginalSetOrigin)(self, _cmd, frame.origin);
}
static void UISetFrameTopLeftPoint(NSWindow* self, SEL _cmd, NSPoint point) {
    NSRect frame = NSMakeRect(point.x, point.y - NSHeight(self.frame), NSWidth(self.frame), NSHeight(self.frame));
    if (UIOnAnyScreen(frame)) {
        frame = UIKeptOffscreen(frame);
        point = NSMakePoint(NSMinX(frame), NSMaxY(frame));
    }
    ((void (*)(id, SEL, NSPoint))UIOriginalSetTopLeft)(self, _cmd, point);
}
static NSRect UIConstrainFrame(NSWindow* self, SEL _cmd, NSRect frame, NSScreen* screen) {
    (void)self, (void)_cmd, (void)screen;
    return UIKeptOffscreen(frame);
}
static void UIOrderWindow(NSWindow* self, SEL _cmd, NSWindowOrderingMode place, NSInteger other) {
    if (place != NSWindowOut) UIMoveOffBeforeOrdering(self);
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))UIOriginalOrderWindow)(self, _cmd, place, other);
}
static void UIOrderFront(NSWindow* self, SEL _cmd, id sender) {
    UIMoveOffBeforeOrdering(self);
    ((void (*)(id, SEL, id))UIOriginalOrderFront)(self, _cmd, sender);
}
static void UIOrderFrontRegardless(NSWindow* self, SEL _cmd) {
    UIMoveOffBeforeOrdering(self);
    ((void (*)(id, SEL))UIOriginalOrderFrontRegardless)(self, _cmd);
}
static void UIMakeKeyAndOrderFront(NSWindow* self, SEL _cmd, id sender) {
    UIMoveOffBeforeOrdering(self);
    ((void (*)(id, SEL, id))UIOriginalMakeKeyAndOrderFront)(self, _cmd, sender);
}
static void UIAddChildWindow(NSWindow* self, SEL _cmd, NSWindow* child, NSWindowOrderingMode place) {
    UIMoveOffBeforeOrdering(child);
    ((void (*)(id, SEL, NSWindow*, NSWindowOrderingMode))UIOriginalAddChild)(self, _cmd, child, place);
}

static BOOL UIClickMakesActive = NO;
static IMP UIOriginalIsActive;
static BOOL UIIsActive(NSApplication* self, SEL _cmd) {
    return UIClickMakesActive || ((BOOL (*)(id, SEL))UIOriginalIsActive)(self, _cmd);
}

static IMP UIReplace(SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(NSWindow.class, selector);
    return method ? method_setImplementation(method, replacement) : NULL;
}

void UIKeepWindowsOffscreen(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    UIOriginalSetFrame = UIReplace(@selector(setFrame:display:), (IMP)UISetFrame);
    UIOriginalSetFrameAnimate = UIReplace(@selector(setFrame:display:animate:), (IMP)UISetFrameAnimate);
    UIOriginalSetOrigin = UIReplace(@selector(setFrameOrigin:), (IMP)UISetFrameOrigin);
    UIOriginalSetTopLeft = UIReplace(@selector(setFrameTopLeftPoint:), (IMP)UISetFrameTopLeftPoint);
    UIReplace(@selector(constrainFrameRect:toScreen:), (IMP)UIConstrainFrame);
    UIOriginalOrderWindow = UIReplace(@selector(orderWindow:relativeTo:), (IMP)UIOrderWindow);
    UIOriginalOrderFront = UIReplace(@selector(orderFront:), (IMP)UIOrderFront);
    UIOriginalOrderFrontRegardless = UIReplace(@selector(orderFrontRegardless), (IMP)UIOrderFrontRegardless);
    UIOriginalMakeKeyAndOrderFront = UIReplace(@selector(makeKeyAndOrderFront:), (IMP)UIMakeKeyAndOrderFront);
    UIOriginalAddChild = UIReplace(@selector(addChildWindow:ordered:), (IMP)UIAddChildWindow);
    UIOriginalIsActive = method_setImplementation(class_getInstanceMethod(NSApplication.class, @selector(isActive)),
                                                  (IMP)UIIsActive);
}

// Any of this run's windows on a screen: off it at once, and the run fails.
static void UICheckOffscreen(void) {
    for (NSWindow* window in NSApp.windows) {
        if (!window.isVisible || !UIOnAnyScreen(window.frame)) continue;
        NSRect frame = window.frame;
        [window orderOut:nil];
        UIFailures++;
        fprintf(stderr, "a %s appeared on a screen at %s and was taken off\n", window.className.UTF8String,
                NSStringFromRect(frame).UTF8String);
    }
}

#pragma mark - Waiting

void UISpin(NSTimeInterval seconds) {
    UIWait(seconds, ^BOOL { return NO; });
}

BOOL UIWait(NSTimeInterval seconds, BOOL (^condition)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        @autoreleasepool {
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            // Window-server events (none are expected; ours go straight to the windows) never pile up.
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event) [NSApp sendEvent:event];
            SZFE2EPump(0);
            UICheckOffscreen();
        }
    }
    return YES;
}

NSInteger UISnapshotCount(UIRig* rig, NSString* view) {
    return rig.snapshotCounts[view].integerValue;
}

BOOL UIWaitNextSnapshot(UIRig* rig, NSString* view, NSInteger count, NSTimeInterval seconds) {
    BOOL arrived = UIWait(seconds, ^BOOL { return UISnapshotCount(rig, view) > count; });
    // The views' own subscriptions receive the same frame in the same turn; let them lay out before anyone looks.
    UISpin(0.05);
    return arrived;
}

void UIObserve(UIRig* rig, NSString* view) {
    if (rig.snapshotCounts[view]) return;
    rig.snapshotCounts[view] = @0;
    __weak UIRig* weakRig = rig;
    [rig.link subscribeToView:view params:nil handler:^(NSDictionary* data, NSInteger rev) {
        (void)rev;
        UIRig* strong = weakRig;
        strong.snapshots[view] = data;
        strong.snapshotCounts[view] = @(strong.snapshotCounts[view].integerValue + 1);
    }];
}

#pragma mark - The view tree

NSArray<NSView*>* UIAllViews(NSView* root) {
    NSMutableArray* views = [NSMutableArray arrayWithObject:root];
    for (NSView* subview in root.subviews) [views addObjectsFromArray:UIAllViews(subview)];
    return views;
}

BOOL UIVisible(NSView* view) {
    if (!view.window || NSWidth(view.bounds) < 1 || NSHeight(view.bounds) < 1) return NO;
    NSRect visible = view.bounds;
    for (NSView* v = view; v; v = v.superview) {
        if (v.hidden || v.alphaValue < 0.01) return NO;
        if (v != view && [v isKindOfClass:NSClipView.class]) {
            NSRect clip = [v convertRect:v.bounds toView:view];
            visible = NSIntersectionRect(visible, clip);
            if (NSIsEmptyRect(visible)) return NO;
        }
    }
    return YES;
}

static NSString* UIWords(NSView* view) {
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField* field = (NSTextField*)view;
        return field.stringValue.length ? field.stringValue : nil;
    }
    if ([view isKindOfClass:NSTextView.class]) return ((NSTextView*)view).string;
    if ([view isKindOfClass:NSButton.class]) {
        NSButton* button = (NSButton*)view;
        if (button.title.length) return button.title;
    }
    NSString* label = view.accessibilityLabel;
    return label.length ? label : nil;
}

NSView* UIFindText(NSView* root, NSString* text) {
    for (NSView* view in UIAllViews(root)) {
        NSString* words = UIWords(view);
        // Rows speak in lower case ("Kenji, request sent") what they draw as a capitalised subtitle.
        if (words && [words rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound && UIVisible(view))
            return view;
    }
    return nil;
}

NSButton* UIFindButton(NSView* root, NSString* title) {
    for (NSView* view in UIAllViews(root)) {
        if (![view isKindOfClass:NSButton.class]) continue;
        NSButton* button = (NSButton*)view;
        if (([button.title isEqualToString:title] || [button.accessibilityLabel isEqualToString:title]) &&
            UIVisible(button))
            return button;
    }
    return nil;
}

NSString* UIDescribe(NSView* root) {
    NSMutableArray* lines = [NSMutableArray array];
    for (NSView* view in UIAllViews(root)) {
        NSString* words = UIWords(view);
        if (!words.length || !UIVisible(view)) continue;
        NSString* kind = [view isKindOfClass:NSButton.class]
                             ? (((NSButton*)view).enabled ? @"button" : @"button (disabled)")
                             : NSStringFromClass(view.class);
        [lines addObject:[NSString stringWithFormat:@"    %@: %@", kind,
                                   [words stringByReplacingOccurrencesOfString:@"\n" withString:@" / "]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// Views of `view` (inclusive) lying outside `area` in `root`'s coordinates; a scroll view's document may extend past
// it (it scrolls), and controls are checked as a whole.
static void UIOutside(NSView* view, NSView* root, NSRect area, NSMutableArray* problems) {
    if (view.hidden || view.alphaValue < 0.01) return;
    NSRect frame = [view convertRect:view.bounds toView:root];
    if (NSWidth(frame) > 0 && NSHeight(frame) > 0 && !NSContainsRect(NSInsetRect(area, -0.5, -0.5), frame))
        [problems addObject:[NSString stringWithFormat:@"%@ \"%@\" lies outside the popover: %@ not in %@",
                                                       view.className, UIWords(view) ?: @"",
                                                       NSStringFromRect(frame), NSStringFromRect(area)]];
    if ([view isKindOfClass:NSScrollView.class] || [view isKindOfClass:NSControl.class]) return;
    for (NSView* subview in view.subviews) UIOutside(subview, root, area, problems);
}

NSArray<NSString*>* UILayoutProblems(UIRig* rig) {
    NSMutableArray* problems = [NSMutableArray array];
    SZFriendsDropdownContent* content = rig.content;
    NSView* frameView = content.superview;
    if (!frameView) return @[ @"the dropdown is in no popover" ];
    [content layoutSubtreeIfNeeded];
    // The content keeps the place the popover gave it (the 2026-10-20 report: shifted down and left, cropped).
    if (!NSContainsRect(NSInsetRect(frameView.bounds, -0.5, -0.5), content.frame))
        [problems addObject:[NSString stringWithFormat:@"the dropdown %@ leaves the popover %@",
                                                       NSStringFromRect(content.frame),
                                                       NSStringFromRect(frameView.bounds)]];
    UIOutside(content, frameView, content.frame, problems);
    for (NSView* view in UIAllViews(content)) {
        if (!UIVisible(view)) continue;
        if ([view isKindOfClass:NSTextField.class]) {
            NSTextField* label = (NSTextField*)view;
            if (label.editable || !label.stringValue.length || label.cell.lineBreakMode == NSLineBreakByTruncatingTail)
                continue;
            CGFloat needed = [label.cell cellSizeForBounds:NSMakeRect(0, 0, NSWidth(label.frame), CGFLOAT_MAX)].height;
            if (NSHeight(label.frame) + 0.5 < needed)
                [problems addObject:[NSString stringWithFormat:@"\"%@\" is cut: %.0f pt of %.0f", label.stringValue,
                                                               NSHeight(label.frame), needed]];
        } else if ([view isKindOfClass:SZFriendsButton.class]) {
            SZFriendsButton* button = (SZFriendsButton*)view;
            if (!button.title.length || button.style == SZFriendsButtonStylePlain) continue;
            if ([button fittingWidth] > NSWidth(button.frame) + 0.5)
                [problems addObject:[NSString stringWithFormat:@"button \"%@\" is cut: %.0f pt of %.0f", button.title,
                                                               NSWidth(button.frame), [button fittingWidth]]];
        }
    }
    return problems;
}

#pragma mark - Events

static NSInteger UIEventNumber = 1;
static BOOL UIWhollyShown(NSView* view);

// A press and release at the middle of `view`, through its window, as the window server would deliver them: the
// release is queued first, so a control's tracking loop finds it. The point must reach `view` by hit testing, so a
// control drawn under another view fails here as it would for a person.
BOOL UIClick(NSView* view, NSString** why) {
    // Out of sight in a scroll view, a person scrolls to it first.
    if (view.window && !UIWhollyShown(view)) UIScrollIntoView(view);
    NSWindow* window = view.window;
    if (!window || !UIVisible(view)) {
        if (why) *why = [NSString stringWithFormat:@"%@ \"%@\" is not on screen", view.className, UIWords(view) ?: @""];
        return NO;
    }
    [window layoutIfNeeded];
    NSRect bounds = view.bounds;
    NSPoint point = [view convertPoint:NSMakePoint(NSMidX(bounds), NSMidY(bounds)) toView:nil];
    NSView* top = window.contentView.superview ?: window.contentView;
    NSView* hit = [top hitTest:point];
    if (!(hit == view || [hit isDescendantOf:view])) {
        if (why) *why = [NSString stringWithFormat:@"a click on %@ \"%@\" lands on %@", view.className,
                                                   UIWords(view) ?: @"", hit.className];
        return NO;
    }
    if ([view isKindOfClass:NSControl.class] && !((NSControl*)view).enabled) {
        if (why) *why = [NSString stringWithFormat:@"%@ \"%@\" is disabled", view.className, UIWords(view) ?: @""];
        return NO;
    }
    // Key first, as the person's first click on a window makes it: the click itself then reaches the control.
    if (!window.isKeyWindow) {
        if (window.sheetParent && !window.sheetParent.isKeyWindow) [window.sheetParent makeKeyWindow];
        [window makeKeyWindow];
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSEvent* down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:now
                                   windowNumber:window.windowNumber context:nil eventNumber:UIEventNumber++
                                     clickCount:1 pressure:1];
    NSEvent* up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
                                    timestamp:now + 0.05 windowNumber:window.windowNumber context:nil
                                  eventNumber:UIEventNumber++ clickCount:1 pressure:0];
    [NSApp postEvent:up atStart:NO];
    // A person's click makes their app active before it lands. This run never activates (the person's own app keeps
    // focus), so for the length of the press AppKit is told the app is active: an inactive app drops a click on a
    // destructive button, such as the Reset Friends sheet's "Reset Friends" (the verifier's failures of 2026-10-20).
    UIClickMakesActive = YES;
    [window sendEvent:down];
    // A view that does not track the press leaves the release queued: deliver it as the window server would.
    NSEvent* left = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:nil inMode:NSDefaultRunLoopMode
                                         dequeue:YES];
    if (left) [left.window ?: window sendEvent:left];
    UIClickMakesActive = NO;
    UISpin(0.05);
    return YES;
}

// Is `view` wholly inside its scroll view's visible part (or in none)?
static BOOL UIWhollyShown(NSView* view) {
    NSScrollView* scroll = view.enclosingScrollView;
    if (!scroll) return UIVisible(view);
    NSRect inClip = [view convertRect:view.bounds toView:scroll.contentView];
    return NSContainsRect(NSInsetRect(scroll.contentView.bounds, -0.5, -0.5), inClip);
}

BOOL UIScrollIntoView(NSView* view) {
    NSScrollView* scroll = view.enclosingScrollView;
    for (int attempt = 0; scroll && !UIWhollyShown(view) && attempt < 80; attempt++) {
        NSRect inClip = [view convertRect:view.bounds toView:scroll.contentView];
        NSRect shown = scroll.contentView.bounds;
        BOOL below = scroll.contentView.isFlipped ? NSMaxY(inClip) > NSMaxY(shown) : NSMinY(inClip) < NSMinY(shown);
        // A wheel turn of 30 points, as a trackpad without momentum sends it, to the scroll view under the pointer.
        CGEventRef wheel = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, below ? -30 : 30);
        NSEvent* event = wheel ? [NSEvent eventWithCGEvent:wheel] : nil;
        if (wheel) CFRelease(wheel);
        if (!event) return NO;
        [scroll scrollWheel:event];
        UISpin(0.02);
    }
    return UIWhollyShown(view);
}

NSView* UIReveal(NSView* root, NSString* text) {
    for (NSView* view in UIAllViews(root)) {
        NSString* words = UIWords(view);
        if (!words || [words rangeOfString:text options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        BOOL shown = YES;
        for (NSView* v = view; v && v != root.superview; v = v.superview)
            if (v.hidden || v.alphaValue < 0.01) shown = NO;
        if (shown && UIScrollIntoView(view) && UIVisible(view)) return view;
    }
    return nil;
}

static NSTextView* UIEditor(NSWindow* window) {
    NSResponder* responder = window.firstResponder;
    return [responder isKindOfClass:NSTextView.class] ? (NSTextView*)responder : nil;
}

BOOL UIType(NSWindow* window, NSString* text) {
    NSTextView* editor = UIEditor(window);
    if (!editor) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:i];
        [editor insertText:[text substringWithRange:range] replacementRange:NSMakeRange(NSNotFound, 0)];
        i = NSMaxRange(range) - 1;
    }
    UISpin(0.02);
    return YES;
}

BOOL UIClearField(NSWindow* window) {
    NSTextView* editor = UIEditor(window);
    if (!editor) return NO;
    [editor selectAll:nil];
    [editor deleteBackward:nil];
    UISpin(0.02);
    return YES;
}

void UIKey(NSWindow* window, unsigned short keyCode, NSString* characters) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    const NSEventType types[] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
    for (NSEventType type : types) {
        NSEvent* event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:now
                                      windowNumber:window.windowNumber context:nil characters:characters
                                 charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
        [window sendEvent:event];
    }
    UISpin(0.05);
}

void UIPressReturn(NSWindow* window) { UIKey(window, 36, @"\r"); }
void UIPressEscape(NSWindow* window) { UIKey(window, 53, @"\x1b"); }

#pragma mark - Rigs

void UIBeginFlow(UIRig* rig, NSString* flow) {
    rig.flow = flow;
    rig.step = 0;
}

NSString* UIShotPathFor(UIRig* rig, NSString* name) {
    NSString* folder = [[UIShotsRoot stringByAppendingPathComponent:rig.variant.name]
        stringByAppendingPathComponent:rig.flow ?: @"setup"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    rig.step += 1;
    return [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%02ld-%@.png", (long)rig.step, name]];
}

// `view` drawn over the dropdown's own background, so the PNG reads like the screen whatever the popover's glass does.
static BOOL UIWritePNG(NSView* view, NSColor* background, NSString* path) {
    [view layoutSubtreeIfNeeded];
    NSRect bounds = view.bounds;
    if (NSIsEmptyRect(bounds)) return NO;
    CGFloat scale = 2;
    NSBitmapImageRep* layer = [view bitmapImageRepForCachingDisplayInRect:bounds];
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{ [view cacheDisplayInRect:bounds toBitmapImageRep:layer]; }];
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(NSWidth(bounds) * scale)
                      pixelsHigh:(NSInteger)(NSHeight(bounds) * scale) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                        isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = bounds.size;
    NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [background setFill];
        NSRectFill(NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds)));
        [layer drawInRect:NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds)) fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

#pragma mark - Colours as drawn

// The colour at `point` (in `view`'s coordinates) as `view`'s window shows it, two ways: drawn again by
// cacheDisplayInRect: (what the PNGs show), and from the layers the window itself composited (the backing stores
// AppKit drew into for the screen; a visual-effect backdrop renders transparent there, so the dropdown's own
// background is laid under both). The run never captures the screen: that would need a permission prompt.
static BOOL UIColorFromRep(NSBitmapImageRep* rep, NSInteger x, NSInteger y, double rgb[3]) {
    if (x < 0 || y < 0 || x >= rep.pixelsWide || y >= rep.pixelsHigh) return NO;
    NSColor* color = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color) return NO;
    rgb[0] = color.redComponent, rgb[1] = color.greenComponent, rgb[2] = color.blueComponent;
    return YES;
}

BOOL UISampleCached(UIRig* rig, NSView* view, NSPoint point, double rgb[3]) {
    NSView* root = rig.content;
    [root layoutSubtreeIfNeeded];
    NSRect bounds = root.bounds;
    NSBitmapImageRep* layer = [root bitmapImageRepForCachingDisplayInRect:bounds];
    [root.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:bounds toBitmapImageRep:layer];
    }];
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:layer.pixelsWide pixelsHigh:layer.pixelsHigh bitsPerSample:8
                 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0
                    bitsPerPixel:0];
    rep.size = bounds.size;
    NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [root.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [rig.bridge.friendsBridgeAppearance.backgroundColor setFill];
        NSRectFill(bounds);
        [layer drawInRect:bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
            respectFlipped:YES hints:nil];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSPoint inRoot = [view convertPoint:point toView:root];
    CGFloat scale = rep.pixelsWide / NSWidth(bounds);
    CGFloat fromTop = root.isFlipped ? inRoot.y : NSHeight(bounds) - inRoot.y;
    return UIColorFromRep(rep, (NSInteger)(inRoot.x * scale), (NSInteger)(fromTop * scale), rgb);
}

BOOL UISampleWindowLayers(UIRig* rig, NSView* view, NSPoint point, double rgb[3], NSString* _Nullable savePath) {
    NSWindow* window = view.window;
    NSView* frameView = window.contentView.superview ?: window.contentView;
    [window displayIfNeeded];
    CALayer* layer = frameView.layer;
    if (!layer) return NO;
    CGFloat scale = 2;
    NSSize size = frameView.bounds.size;
    size_t width = (size_t)(size.width * scale), height = (size_t)(size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NO;
    __block CGColorRef background = NULL;
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        background = CGColorRetain(rig.bridge.friendsBridgeAppearance.backgroundColor.CGColor);
    }];
    CGContextSetFillColorWithColor(context, background);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGColorRelease(background);
    CGContextScaleCTM(context, scale, scale);
    if (layer.geometryFlipped) {
        CGContextTranslateCTM(context, 0, size.height);
        CGContextScaleCTM(context, 1, -1);
    }
    [layer renderInContext:context];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!image) return NO;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    if (savePath) [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:savePath
                                                                                           atomically:YES];
    NSPoint inFrame = [frameView convertPoint:[view convertPoint:point toView:nil] fromView:nil];
    CGFloat fromTop = frameView.isFlipped ? inFrame.y : size.height - inFrame.y;
    return UIColorFromRep(rep, (NSInteger)(inFrame.x * scale), (NSInteger)(fromTop * scale), rgb);
}

static double UILuminance(const double rgb[3]) {
    double linear[3];
    for (int i = 0; i < 3; i++)
        linear[i] = rgb[i] <= 0.04045 ? rgb[i] / 12.92 : pow((rgb[i] + 0.055) / 1.055, 2.4);
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

double UIContrast(const double a[3], const double b[3]) {
    double la = UILuminance(a), lb = UILuminance(b);
    return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}

BOOL UIShot(UIRig* rig, NSString* name) {
    NSView* frameView = rig.content.superview;
    if (!rig.popoverWindow || !frameView) return NO;
    UISpin(0.05);
    NSArray* problems = UILayoutProblems(rig);
    NSString* path = UIShotPathFor(rig, name);
    BOOL written = UIWritePNG(rig.content, rig.bridge.friendsBridgeAppearance.backgroundColor, path);
    if (!written) {
        UIFailures++;
        fprintf(stderr, "[%s %s] no screenshot at %s\n", rig.variant.name.UTF8String, rig.flow.UTF8String,
                path.UTF8String);
        return NO;
    }
    NSString* real = UIRealComputerShown(rig.content);
    if (real) problems = [problems arrayByAddingObject:[NSString stringWithFormat:@"this Mac's own \"%@\" shows", real]];
    if (problems.count && ![name isEqualToString:@"FAILED"]) {
        UIFailures++;
        fprintf(stderr, "[%s %s step %ld %s] layout:\n  %s\n  (%s)\n", rig.variant.name.UTF8String,
                rig.flow.UTF8String, (long)rig.step, name.UTF8String,
                [problems componentsJoinedByString:@"\n  "].UTF8String, path.UTF8String);
        return NO;
    }
    return YES;
}

BOOL UIShotWindow(UIRig* rig, NSWindow* window, NSString* name) {
    UISpin(0.05);
    NSView* view = window.contentView;
    NSString* real = UIRealComputerShown(view);
    if (real) {
        UIFailures++;
        fprintf(stderr, "[%s %s %s] this Mac's own \"%s\" shows\n", rig.variant.name.UTF8String, rig.flow.UTF8String,
                name.UTF8String, real.UTF8String);
    }
    return UIWritePNG(view, NSColor.windowBackgroundColor, UIShotPathFor(rig, name));
}

// The reader's title bar, as the integration suite builds it: a strip with Search at its end, and the views' button
// placed between them by the reader's own placement code.
static NSWindow* UIReaderWindow(UIVariant* variant, NSView* button) {
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                              NSWindowStyleMaskFullSizeContentView;
    NSPoint origin = UIOffscreenOrigin(NSMakeSize(900, variant.windowHeight));
    NSRect frame = NSMakeRect(origin.x, origin.y, 900, variant.windowHeight);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Friends UI test";
    window.titlebarAppearsTransparent = YES;
    NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, variant.windowHeight)];
    window.contentView = content;
    NSView* strip = [NSView new];
    NSButton* search = [NSButton buttonWithTitle:@"" target:nil action:NSSelectorFromString(@"showFavoritesPalette:")];
    search.bordered = NO;
    for (NSView* view in @[ strip, search ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [strip.topAnchor constraintEqualToAnchor:content.topAnchor], [strip.heightAnchor constraintEqualToConstant:44],
        [strip.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:80],
        [strip.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-44],
        [search.widthAnchor constraintEqualToConstant:24], [search.heightAnchor constraintEqualToConstant:24],
        [search.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
        [search.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor]
    ]];
    SPDFMacFriendsTitleBarPlacement* placement = SPDFMacFriendsInstallTitleBarButton(
        button, content, strip, SPDFMacFriendsTrailingConstraint(content, strip), search, 28);
    (void)placement;
    [content layoutSubtreeIfNeeded];
    return window;
}

NSDictionary<NSString*, NSString*>* UIDeviceEnvironment(NSString* person) {
    return @{@"SZFRIENDS_E2E_DEVICE_NAME" : [NSString stringWithFormat:@"Test computer %@", person],
             @"SZFRIENDS_E2E_DEVICE_SYSTEM" : @"Test system 1.0"};
}

// This Mac's own name and system, which no screen of the run may show (the helpers are given test ones).
static NSArray<NSString*>* UIRealComputerWords(void) {
    static NSArray<NSString*>* words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray* list = [NSMutableArray array];
        NSString* name = NSHost.currentHost.localizedName;
        if (name.length >= 4) [list addObject:name];
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        [list addObject:[NSString stringWithFormat:@"macOS %ld.%ld", (long)v.majorVersion, (long)v.minorVersion]];
        words = list;
    });
    return words;
}

NSString* UIRealComputerShown(NSView* root) {
    NSString* shown = UIDescribe(root);
    for (NSString* word in UIRealComputerWords())
        if ([shown rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) return word;
    return nil;
}

UIRig* UIStartRig(SZFE2EWorld* world, UIVariant* variant, NSString* name,
                  NSDictionary<NSString*, NSString*>* environment) {
    UIRig* rig = [UIRig new];
    rig.variant = variant;
    rig.snapshotCounts = [NSMutableDictionary dictionary];
    rig.snapshots = [NSMutableDictionary dictionary];
    rig.openedURLs = [NSMutableArray array];
    rig.helper = [world helperNamed:name];
    NSString* home = [rig.helper.stateDirectory stringByAppendingString:@"-home"];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    NSMutableDictionary* env = [UIDeviceEnvironment(name) mutableCopy];
    env[@"HOME"] = home;
    [env addEntriesFromDictionary:environment ?: @{}];
    rig.helper.extraEnvironment = env;
    if (![rig.helper start]) {
        UIFail(nil, __FILE__, __LINE__, "the helper starts", rig.helper.log);
        return nil;
    }
    // What the reader's link connects to: the client library reads these when it starts. The reader's own state (tab
    // drag key, reading copies) goes to the test home too.
    setenv("SZFRIENDS_STATE_DIR", rig.helper.stateDirectory.fileSystemRepresentation, 1);
    setenv("SPDF_STATE_DIR", home.fileSystemRepresentation, 1);
    rig.bridge = [UIBridge new];
    rig.bridge.dropdownWidth = variant.dropdownWidth;
    // A bundle with no embedded helper: the link connects to the helper this run started and never spawns one.
    NSBundle* bundle = [NSBundle bundleWithPath:home] ?: NSBundle.mainBundle;
    rig.host = [[SPDFMacFriendsHost alloc] initWithBridge:rig.bridge bundle:bundle
                                                  formats:[NSSet setWithArray:@[ @"pdf", @"md", @"txt" ]]];
    rig.link = [[SZFriendsHelperLink alloc] initWithHost:rig.host];
    rig.dropdown = [[SZFriendsDropdownController alloc] initWithHost:rig.host link:rig.link];
    [rig.dropdown install];
    if (!rig.bridge.installed) {
        UIFail(nil, __FILE__, __LINE__, "the views hand their button to the reader", @"");
        return nil;
    }
    // Nothing a test presses may reach System Settings, Finder or the general pasteboard.
    SZFriendsContext* context = rig.dropdown.context;
    __weak UIRig* weakRig = rig;
    context.openURL = ^(NSURL* url) { [weakRig.openedURLs addObject:url]; };
    context.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    context.chooseImage = ^(void (^completion)(NSString*)) { completion(nil); };
    rig.window = UIReaderWindow(variant, rig.bridge.installed);
    rig.window.appearance = [NSAppearance appearanceNamed:variant.appearance];
    [rig.window orderFrontRegardless];
    SZFriendsHelperLink* link = rig.link;
    if (!UIWait(10, ^BOOL { return link.state == SZFriendsLinkStateReady; })) {
        UIFail(nil, __FILE__, __LINE__, "the reader's link reaches the helper",
               [NSString stringWithFormat:@"state %ld; helper log:\n%@", (long)link.state, rig.helper.log]);
        UIStopRig(rig);
        return nil;
    }
    UIObserve(rig, @"list");
    UIWait(5, ^BOOL { return UISnapshotCount(rig, @"list") > 0; });
    return rig;
}

// The fake helper's socket fallback folder (szfriends-<hash>) for a state path too long for a socket; removed with
// the rig so a run leaves nothing behind.
static void UIRemoveSocketFallback(NSString* state) {
    char path[1024];
    bool fallback = false;
    if (szfriends_socket_path(state.fileSystemRepresentation, path, sizeof path, &fallback) != SZFRIENDS_OK || !fallback)
        return;
    NSString* folder = [@(path) stringByDeletingLastPathComponent];
    if ([folder.lastPathComponent hasPrefix:@"szfriends-"])
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
}

void UIStopRig(UIRig* rig) {
    if (rig.dropdown.shown) [rig.dropdown close];
    [rig.dropdown uninstall];
    [rig.link stopDisablingFriends:NO];
    [rig.window orderOut:nil];
    [rig.window close];
    UISpin(0.05);
    [rig.helper terminate];
    UIRemoveSocketFallback(rig.helper.stateDirectory);
}

BOOL UIOpenDropdown(UIRig* rig) {
    if (rig.dropdown.shown) return YES;
    NSString* why = nil;
    if (!UIClick(rig.bridge.installed, &why)) {
        UIFail(rig, __FILE__, __LINE__, "the Friends button takes the click", why ?: @"");
        return NO;
    }
    if (!UIWait(5, ^BOOL { return rig.dropdown.shown && rig.popoverWindow.isVisible; })) {
        UIFail(rig, __FILE__, __LINE__, "the dropdown opens", @"");
        return NO;
    }
    [rig.popoverWindow makeKeyWindow];
    UISpin(0.2);
    return YES;
}

BOOL UICloseDropdown(UIRig* rig) {
    if (!rig.dropdown.shown) return YES;
    [rig.dropdown close];
    return UIWait(5, ^BOOL { return !rig.dropdown.shown; });
}
