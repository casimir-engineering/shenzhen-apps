#import "SPDFMacSidebarHitProbe.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacPaneDividerGeometry.h"
#import <objc/runtime.h>
#import "SPDFMacChromeButtonChecks.h"

static IMP OriginalWindowOrder;
static void GuardWindowOrder(id object,SEL action,NSInteger place,NSInteger other) {
    // AppKit can close its own text-input helper windows during event dispatch.
    if (place == NSWindowOut) {
        ((void(*)(id,SEL,NSInteger,NSInteger))OriginalWindowOrder)(object,action,place,other); return;
    }
    fprintf(stderr,"FAIL: headless reader attempted to display a window\n"); exit(1);
}
void spdf_sidebar_probe_install_order_guard(void) {
    OriginalWindowOrder=method_setImplementation(class_getInstanceMethod(NSWindow.class,@selector(orderWindow:relativeTo:)),(IMP)GuardWindowOrder);
}
static void OrderInvisible(NSWindow* window,NSInteger place) {
    if (window.alphaValue != 0 || NSMaxX(window.frame) >= -1000) {
        fprintf(stderr,"FAIL: click probe must remain transparent and offscreen\n"); exit(1);
    }
    ((void(*)(id,SEL,NSInteger,NSInteger))OriginalWindowOrder)(window,@selector(orderWindow:relativeTo:),place,0);
}
static BOOL ProbeAppActive(id object,SEL selector) { (void)object; (void)selector; return YES; }
static NSRect ProbeUnconstrainedFrame(id object,SEL selector,NSRect frame,NSScreen* screen) {
    (void)object; (void)selector; (void)screen; return frame;
}
@interface ShenzhenMacDelegate (SidebarHitFixture)
- (void)sidebarModeChanged:(id)sender;
- (void)setSidebarActuallyVisible:(BOOL)visible;
@end
static __unsafe_unretained NSView* DividerCursorTarget;
static NSRect DividerCursorRect;
static BOOL DividerResizeCursor;
static IMP OriginalAddCursorRect;
static void CaptureDividerCursor(id object,SEL action,NSRect rect,NSCursor* cursor) {
    if (object == DividerCursorTarget) {
        DividerCursorRect=NSUnionRect(DividerCursorRect,rect);
        DividerResizeCursor=cursor==NSCursor.resizeLeftRightCursor;
    } else ((void(*)(id,SEL,NSRect,id))OriginalAddCursorRect)(object,action,rect,cursor);
}
static __unsafe_unretained ShenzhenMacDelegate* DividerDragReader;
static NSUInteger DividerFocusCalls, DividerDragCalls, DividerFinishCalls, DividerCallbackKind;
static CGFloat DividerDeltas[2];
static IMP OriginalDividerFocus, OriginalSidebarDrag, OriginalMapDrag, OriginalSidebarFinish, OriginalMapFinish, OriginalCursorSet;
static void ProbeDividerFocus(id object,SEL action) {
    if (object==DividerDragReader) DividerFocusCalls++;
    else ((void(*)(id,SEL))OriginalDividerFocus)(object,action);
}
static void ProbeDividerDrag(id object,SEL action,CGFloat delta) {
    BOOL map=action==@selector(minimapDividerDraggedByDeltaX:);
    if (object==DividerDragReader) {
        if (DividerDragCalls<2) DividerDeltas[DividerDragCalls]=delta;
        DividerDragCalls++; DividerCallbackKind=map ? 2 : 1;
    } else ((void(*)(id,SEL,CGFloat))(map ? OriginalMapDrag : OriginalSidebarDrag))(object,action,delta);
}
static void ProbeDividerFinish(id object,SEL action) {
    BOOL map=action==@selector(minimapDividerDidFinishDragging);
    if (object==DividerDragReader) { DividerFinishCalls++; DividerCallbackKind=map ? 2 : 1; }
    else ((void(*)(id,SEL))(map ? OriginalMapFinish : OriginalSidebarFinish))(object,action);
}
static void ProbeCursorSet(id object,SEL action) {
    // Do not change the user's real cursor while exercising invisible controls.
    if (object!=NSCursor.resizeLeftRightCursor) ((void(*)(id,SEL))OriginalCursorSet)(object,action);
}
@implementation ShenzhenMacDelegate (SidebarHitProbe)
- (NSUInteger)probeDividerMouseDrags {
    NSUInteger failures=0;
    NSRect savedFrame=_window.frame;
    BOOL sidebar=_sidebarVisible,map=_minimapVisible;
    [_window setContentSize:NSMakeSize(1280,780)];
    [self setSidebarActuallyVisible:YES]; [self setMinimapActuallyVisible:YES]; [_window.contentView layoutSubtreeIfNeeded];
    DividerDragReader=self;
    Method focus=class_getInstanceMethod(ShenzhenMacDelegate.class,@selector(clearFindFieldFocus));
    Method sidebarDrag=class_getInstanceMethod(ShenzhenMacDelegate.class,@selector(sidebarDividerDraggedByDeltaX:));
    Method mapDrag=class_getInstanceMethod(ShenzhenMacDelegate.class,@selector(minimapDividerDraggedByDeltaX:));
    Method sidebarFinish=class_getInstanceMethod(ShenzhenMacDelegate.class,@selector(sidebarDividerDidFinishDragging));
    Method mapFinish=class_getInstanceMethod(ShenzhenMacDelegate.class,@selector(minimapDividerDidFinishDragging));
    Method cursor=class_getInstanceMethod(NSCursor.class,@selector(set));
    OriginalDividerFocus=method_setImplementation(focus,(IMP)ProbeDividerFocus);
    OriginalSidebarDrag=method_setImplementation(sidebarDrag,(IMP)ProbeDividerDrag);
    OriginalMapDrag=method_setImplementation(mapDrag,(IMP)ProbeDividerDrag);
    OriginalSidebarFinish=method_setImplementation(sidebarFinish,(IMP)ProbeDividerFinish);
    OriginalMapFinish=method_setImplementation(mapFinish,(IMP)ProbeDividerFinish);
    OriginalCursorSet=method_setImplementation(cursor,(IMP)ProbeCursorSet);
    NSInteger number=0;
    for (NSView* divider in @[_sidebarDividerView,_minimapDividerView])
        for (NSNumber* stale in @[@NO,@YES]) for (NSNumber* x in @[@.5,@4.5,@6.5,@8.5,@12.5])
            for (NSNumber* y in @[@20,@(NSHeight(divider.bounds)/2),@(NSMaxY(SPDFPaneDividerResizeRect(divider.bounds))-1)]) {
                DividerFocusCalls=DividerDragCalls=DividerFinishCalls=DividerCallbackKind=0;
                DividerDeltas[0]=DividerDeltas[1]=NAN;
                _tabStripCapturingMouse=stale.boolValue;
                NSPoint point=[divider convertPoint:NSMakePoint(x.doubleValue,y.doubleValue) toView:nil];
                NSArray* types=@[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseDragged),@(NSEventTypeLeftMouseDragged),@(NSEventTypeLeftMouseUp)];
                NSArray* shifts=@[@0,@4,@(-3),@(-3)];
                for (NSUInteger i=0;i<types.count;i++) {
                    NSEvent* event=[NSEvent mouseEventWithType:(NSEventType)[types[i] unsignedIntegerValue]
                        location:NSMakePoint(point.x+[shifts[i] doubleValue],point.y) modifierFlags:0
                        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:_window.windowNumber context:nil
                        eventNumber:++number clickCount:1 pressure:i==3 ? 0 : 1];
                    [_window sendEvent:event];
                }
                NSUInteger expected=divider==_sidebarDividerView ? 1 : 2;
                if (DividerFocusCalls!=1 || DividerDragCalls!=2 || DividerFinishCalls!=1 || DividerCallbackKind!=expected ||
                    fabs(DividerDeltas[0]-4)>.01 || fabs(DividerDeltas[1]+7)>.01 || _tabStripCapturingMouse) {
                    fprintf(stderr,"FAIL: native %s divider drag x=%.1f y=%.1f stale=%d callbacks=%lu/%lu/%lu kind=%lu\n",
                        expected==1 ? "sidebar" : "map",x.doubleValue,y.doubleValue,stale.boolValue,
                        (unsigned long)DividerFocusCalls,(unsigned long)DividerDragCalls,(unsigned long)DividerFinishCalls,(unsigned long)DividerCallbackKind);
                    failures++;
                }
            }
    _tabStripCapturingMouse=NO;
    method_setImplementation(focus,OriginalDividerFocus); method_setImplementation(sidebarDrag,OriginalSidebarDrag);
    method_setImplementation(mapDrag,OriginalMapDrag); method_setImplementation(sidebarFinish,OriginalSidebarFinish);
    method_setImplementation(mapFinish,OriginalMapFinish); method_setImplementation(cursor,OriginalCursorSet);
    DividerDragReader=nil;
    [_window setFrame:savedFrame display:NO];
    [self setSidebarActuallyVisible:sidebar]; [self setMinimapActuallyVisible:map]; [_window.contentView layoutSubtreeIfNeeded];
    return failures;
}
- (NSUInteger)probePanelDividerTargets {
    if (_presentationMode) return 0;
    NSUInteger failures=0;
    Method add=class_getInstanceMethod(NSView.class,@selector(addCursorRect:cursor:));
    OriginalAddCursorRect=method_setImplementation(add,(IMP)CaptureDividerCursor);
    for (NSView* divider in @[_sidebarDividerView,_minimapDividerView]) {
        if (divider.isHiddenOrHasHiddenAncestor) continue;
        NSString* name=divider==_sidebarDividerView ? @"sidebar" : @"map";
        if (fabs(NSWidth(divider.bounds)-13)>.01 || ![divider acceptsFirstMouse:nil] || divider.mouseDownCanMoveWindow) {
            fprintf(stderr,"FAIL: %s divider needs a 13pt first-click resize target, width %.1f\n",name.UTF8String,NSWidth(divider.bounds)); failures++;
        }
        if (divider==_minimapDividerView && fabs(NSMinX(_minimapView.frame)-NSMaxX(_pageScrollView.frame)-5)>.01) {
            fprintf(stderr,"FAIL: wider map resize target changed the 5pt reading-area gutter\n"); failures++;
        }
        NSView* frameView=_window.contentView.superview;
        NSRect painted=[divider convertRect:divider.bounds toView:_window.contentView];
        if(fabs(NSMinY(painted))>.01) {
            fprintf(stderr,"FAIL: %s divider drawing stops above the bottom edge\n",name.UTF8String); failures++;
        }
        NSPoint passive=[divider convertPoint:NSMakePoint(6.5,NSMaxY(divider.bounds)-3) toView:divider.superview];
        if([divider hitTest:passive]) {
            fprintf(stderr,"FAIL: %s divider claims native bottom-edge resize zone\n",name.UTF8String); failures++;
        }
        for (NSNumber* x in @[@.5,@3,@6.5,@10,@12.5])
            for (NSNumber* y in @[@1,@20,@(NSHeight(divider.bounds)/2),@(NSMaxY(SPDFPaneDividerResizeRect(divider.bounds))-1)]) {
                NSPoint point=[divider convertPoint:NSMakePoint(x.doubleValue,y.doubleValue) toView:frameView.superview];
                NSView* hit=[frameView hitTest:point];
                if (hit != divider) {
                    fprintf(stderr,"FAIL: %s resize x=%.1f y=%.1f hit %s instead of divider\n",name.UTF8String,
                        x.doubleValue,y.doubleValue,NSStringFromClass(hit.class).UTF8String); failures++;
                }
            }
        DividerCursorTarget=divider; DividerCursorRect=NSZeroRect; DividerResizeCursor=NO;
        [divider resetCursorRects];
        if (!DividerResizeCursor || !NSEqualRects(DividerCursorRect,SPDFPaneDividerResizeRect(divider.bounds))) {
            fprintf(stderr,"FAIL: %s resize cursor does not cover its complete hit target\n",name.UTF8String); failures++;
        }
        DividerCursorTarget=nil;
    }
    method_setImplementation(add,OriginalAddCursorRect);
    return failures;
}
- (NSUInteger)probeHistoryMouseClicks {
    NSUInteger failures=0;
    NSRect frame=_window.frame; CGFloat alpha=_window.alphaValue;
    // Swap methods, never the window's class: AppKit adds KVO subclasses while
    // realizing titlebar views, and replacing that class breaks observer cleanup.
    Method constrain=class_getInstanceMethod(NSWindow.class,@selector(constrainFrameRect:toScreen:));
    IMP oldConstrain=method_setImplementation(constrain,(IMP)ProbeUnconstrainedFrame);
    Method key=class_getInstanceMethod(NSWindow.class,@selector(isKeyWindow));
    IMP oldKey=method_setImplementation(key,(IMP)ProbeAppActive);
    _window.alphaValue=0; [_window setFrameOrigin:NSMakePoint(-10000,-10000)];
    // Unordered windows silently discard sendEvent. Realize an invisible window
    // without activating it so native frame/control routing really executes.
    OrderInvisible(_window,NSWindowBelow);
    Method active=class_getInstanceMethod(NSApplication.class,@selector(isActive));
    IMP oldActive=method_setImplementation(active,(IMP)ProbeAppActive);
    failures += [self probeDividerMouseDrags];
    NSView* collapse=nil;
    for(NSView* child in _sidebarModeControl.subviews)
        if([child.accessibilityLabel isEqual:@"Hide side panel"]) collapse=child;
    NSPoint openCenter=[collapse convertPoint:NSMakePoint(NSMidX(collapse.bounds),NSMidY(collapse.bounds)) toView:nil];
    [self setSidebarActuallyVisible:NO]; [_window.contentView layoutSubtreeIfNeeded];
    NSPoint closedCenter=[_sidebarToggleButton convertPoint:NSMakePoint(NSMidX(_sidebarToggleButton.bounds),NSMidY(_sidebarToggleButton.bounds)) toView:nil];
    if(fabs(openCenter.x-closedCenter.x)>.01 || fabs(openCenter.y-closedCenter.y)>.01) {
        fprintf(stderr,"FAIL: panel toggle moves open=%s closed=%s\n",NSStringFromPoint(openCenter).UTF8String,NSStringFromPoint(closedCenter).UTF8String); failures++;
    }
    [self setSidebarActuallyVisible:YES]; [_window.contentView layoutSubtreeIfNeeded];
    failures += CheckChromeButtonClicks(_window,@[_window.contentView]);
    NSInteger eventNumber=0;
    for (NSNumber* y in @[@1,@7,@14,@21,@27]) for (NSString* title in @[@"Groups",@"Search",@"Comments",@"History",@"History",@"Chapters"]) {
        [_window.contentView layoutSubtreeIfNeeded];
        NSButton* button=nil;
        for (NSButton* row in _sidebarModeControl.accessibilityChildren)
            if ([row.accessibilityLabel isEqual:title]) button=row;
        if (!button) { fprintf(stderr,"FAIL: missing %s button\n",title.UTF8String); failures++; continue; }
        NSInteger expected=button.enabled ? [_sidebarModeControl tagForSegment:button.tag] : _sidebarModeControl.spdf_selectedSidebarMode;
        NSPoint point=[button convertPoint:NSMakePoint(NSMidX(button.bounds),y.doubleValue) toView:nil];
        NSView* frameView=_window.contentView.superview;
        NSView* hit=[frameView hitTest:frameView.superview ? [frameView.superview convertPoint:point fromView:nil] : point];
        if (hit != button || NSPointInRect([_tabStrip convertPoint:point fromView:nil],_tabStrip.bounds)) {
            fprintf(stderr,"FAIL: reader overlay intercepts %s at y=%.0f\n",title.UTF8String,y.doubleValue); failures++;
        }
        NSTimeInterval timestamp=NSProcessInfo.processInfo.systemUptime;
        // Reproduce the retained multi-click count even when the next press
        // targets a different control after moving the window.
        NSInteger count=2; // A fast press after dragging may retain the prior click count.
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:timestamp
            windowNumber:_window.windowNumber context:nil eventNumber:++eventNumber clickCount:count pressure:1];
        NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:timestamp+.01
            windowNumber:_window.windowNumber context:nil eventNumber:++eventNumber clickCount:count pressure:0];
        _tabStripCapturingMouse=YES; // A prior tab popup consumed mouse-up.
        [NSApp postEvent:up atStart:YES]; [_window sendEvent:down];
        while ([NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp|NSEventMaskLeftMouseDragged untilDate:NSDate.distantPast inMode:NSEventTrackingRunLoopMode dequeue:YES]) {}
        [_window.contentView layoutSubtreeIfNeeded];
        if (_sidebarModeControl.spdf_selectedSidebarMode != expected || _tabStripCapturingMouse) {
            fprintf(stderr,"FAIL: %s click y=%.0f mode=%ld expected=%ld staleCapture=%d\n",title.UTF8String,y.doubleValue,
                (long)_sidebarModeControl.spdf_selectedSidebarMode,(long)expected,_tabStripCapturingMouse); failures++;
        }
    }
    method_setImplementation(active,oldActive);
    OrderInvisible(_window,NSWindowOut);
    method_setImplementation(constrain,oldConstrain); method_setImplementation(key,oldKey);
    [_window setFrame:frame display:NO]; _window.alphaValue=alpha;
    _sidebarModeControl.spdf_selectedSidebarMode=SPDFSidebarModeHistory; [self sidebarModeChanged:_sidebarModeControl];
    return failures;
}
@end
