#import <objc/runtime.h>

@interface SPDFTabGroupPickerPopover : NSPopover
@property(nonatomic, weak) SPDFTabStripView* anchorStrip;
- (BOOL)shouldCloseForEvent:(NSEvent*)event;
@end

// Replace presentation only: production construction, policy and toggle execute,
// while no popover window can be displayed by this headless test.
static char pickerShownKey;
static NSUInteger pickerShows, pickerCloses;
static BOOL picker_is_shown(id object,SEL selector) {
    (void)selector; return [objc_getAssociatedObject(object,&pickerShownKey) boolValue];
}
static void picker_show(id object,SEL selector,NSRect rect,NSView* view,NSRectEdge edge) {
    (void)selector; (void)rect; (void)view; (void)edge;
    objc_setAssociatedObject(object,&pickerShownKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC); pickerShows++;
}
static void picker_close(id object,SEL selector) {
    (void)selector;
    objc_setAssociatedObject(object,&pickerShownKey,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC); pickerCloses++;
}
static NSEvent* picker_mouse(NSWindow* window,NSPoint point,NSEventType type) {
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:2 pressure:type==NSEventTypeLeftMouseUp ? 0 : 1];
}
static void check_group_picker_toggle(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,100)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    SPDFGroupTestStrip* strip=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,700,42)];
    strip.tabs=(id)@[tab(@"Document",[SPDFTabGroup groupWithColor:@"Purple"])]; strip.selectedIndex=0;
    [window.contentView addSubview:strip];
    expect([strip valueForKey:@"groupPicker"]==nil,@"picker must remain lazy before first use");
    Method shown=class_getInstanceMethod(NSPopover.class,@selector(isShown));
    Method show=class_getInstanceMethod(NSPopover.class,@selector(showRelativeToRect:ofView:preferredEdge:));
    Method close=class_getInstanceMethod(NSPopover.class,@selector(close));
    IMP oldShown=method_setImplementation(shown,(IMP)picker_is_shown);
    IMP oldShow=method_setImplementation(show,(IMP)picker_show);
    IMP oldClose=method_setImplementation(close,(IMP)picker_close);
    pickerShows=0; pickerCloses=0;
    NSRect anchor=[strip overflowRect];
    NSPoint center=[strip convertPoint:NSMakePoint(NSMidX(anchor),NSMidY(anchor)) toView:nil];
    for (NSUInteger click=0;click<10;click++) {
        NSEvent* event=picker_mouse(window,center,NSEventTypeLeftMouseDown);
        SPDFTabGroupPickerPopover* before=[strip valueForKey:@"groupPicker"];
        // AppKit attempts transient dismissal before dispatching the same press.
        if (before.shown && [before shouldCloseForEvent:event]) [before close];
        [strip showGroupPicker];
        SPDFTabGroupPickerPopover* after=[strip valueForKey:@"groupPicker"];
        if (after.shown && [after shouldCloseForEvent:picker_mouse(window,center,NSEventTypeLeftMouseUp)]) [after close];
        expect(after.shown == (click%2==0),@"repeated anchor presses must alternate open and closed without delay");
        expect(after.behavior==NSPopoverBehaviorTransient && !after.animates,@"picker must retain native dismissal and immediate presentation");
    }
    expect(pickerShows==5 && pickerCloses==5,@"anchor toggling must not close then reopen on the same press");
    [strip showGroupPicker];
    SPDFTabGroupPickerPopover* picker=[strip valueForKey:@"groupPicker"];
    NSPoint edge=[strip convertPoint:NSMakePoint(NSMinX(anchor)-2,NSMidY(anchor)) toView:nil];
    expect(![picker shouldCloseForEvent:picker_mouse(window,edge,NSEventTypeLeftMouseDown)] &&
           ![picker shouldCloseForEvent:picker_mouse(window,edge,NSEventTypeLeftMouseUp)],
           @"expanded anchor hit area owns both phases of its click");
    NSRect plus=[strip plusRect];
    NSPoint outside=[strip convertPoint:NSMakePoint(NSMidX(plus),NSMidY(plus)) toView:nil];
    expect([picker shouldCloseForEvent:picker_mouse(window,outside,NSEventTypeLeftMouseDown)],@"plus/outside press retains native dismissal");
    expect([picker shouldCloseForEvent:picker_mouse(window,center,NSEventTypeRightMouseDown)],@"unrelated mouse buttons retain native dismissal");
    NSEvent* escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:center modifierFlags:0 timestamp:1
        windowNumber:window.windowNumber context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
    expect([picker shouldCloseForEvent:escape] && [picker shouldCloseForEvent:nil],@"Escape and lifecycle closure must remain available");
    NSWindow* other=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,100)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    expect([picker shouldCloseForEvent:picker_mouse(other,center,NSEventTypeLeftMouseDown)],@"same coordinates in another window are not the anchor");
    [picker close]; [strip showGroupPicker];
    expect([[strip valueForKey:@"groupPicker"] isShown],@"a fresh anchor press immediately reopens after outside dismissal");
    [[strip valueForKey:@"groupPicker"] close];
    method_setImplementation(shown,oldShown); method_setImplementation(show,oldShow); method_setImplementation(close,oldClose);
    expect(!window.visible && !other.visible,@"picker regression must never display a window");
}
