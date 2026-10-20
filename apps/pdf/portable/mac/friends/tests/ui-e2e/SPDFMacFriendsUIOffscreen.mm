// friends-ui-e2e's driver (SPDFMacFriendsUIE2E.h): keeping every window of the run off every screen.

#import "SPDFMacFriendsUIDriverInternal.h"

#import <objc/runtime.h>

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

BOOL UIClickMakesActive = NO;
__weak NSWindow* UIClickWindow; // the window a press is going to, key for its length
static IMP UIOriginalIsActive, UIOriginalIsKeyWindow;
static BOOL UIIsActive(NSApplication* self, SEL _cmd) {
    return UIClickMakesActive || ((BOOL (*)(id, SEL))UIOriginalIsActive)(self, _cmd);
}
static BOOL UIIsKeyWindow(NSWindow* self, SEL _cmd) {
    return (UIClickMakesActive && self == UIClickWindow) || ((BOOL (*)(id, SEL))UIOriginalIsKeyWindow)(self, _cmd);
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
    UIOriginalIsKeyWindow = UIReplace(@selector(isKeyWindow), (IMP)UIIsKeyWindow);
}

// Any of this run's windows on a screen: off it at once, and the run fails.
void UICheckOffscreen(void) {
    for (NSWindow* window in NSApp.windows) {
        if (!window.isVisible || !UIOnAnyScreen(window.frame)) continue;
        NSRect frame = window.frame;
        [window orderOut:nil];
        UIFailures++;
        fprintf(stderr, "a %s appeared on a screen at %s and was taken off\n", window.className.UTF8String,
                NSStringFromRect(frame).UTF8String);
    }
}
