#import "SPDFMacWindowChrome.h"
@interface SPDFChromeActionProbe : NSObject
@property NSUInteger calls;
- (void)clicked:(id)sender;
@end
@implementation SPDFChromeActionProbe
- (void)clicked:(id)sender { (void)sender; self.calls++; }
@end
static void CollectChromeControls(NSView* view, NSMutableArray<NSControl*>* controls) {
    if(view.hidden) return;
    if([view isKindOfClass:NSButton.class] || [view isKindOfClass:NSSegmentedControl.class])
        [controls addObject:(NSControl*)view];
    for(NSView* child in view.subviews) CollectChromeControls(child,controls);
}
static NSUInteger CheckChromeButtonClicks(NSWindow* window, NSArray<NSView*>* roots) {
    NSMutableArray<NSControl*>* controls=[NSMutableArray array];
    for(NSView* root in roots) CollectChromeControls(root,controls);
    SPDFChromeActionProbe* sink=[SPDFChromeActionProbe new];
    NSUInteger failures=0;
    for(NSControl* control in controls) {
        if(!control.enabled || !control.action || [control isKindOfClass:NSPopUpButton.class]) continue;
        id target=control.target; SEL action=control.action;
        control.target=sink; control.action=@selector(clicked:);
        for(int attempt=0;attempt<3;attempt++) {
            // Move the invisible fixture between presses, and retain a click
            // count of two as the window server can after a chrome gesture.
            [window setFrameOrigin:NSMakePoint(-10000+attempt*3,-10000+attempt*2)];
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            BOOL icon=[control isKindOfClass:NSClassFromString(@"SPDFWorkspaceIconButton")];
            CGFloat x=icon ? (attempt==0 ? 1 : attempt==1 ? NSMidX(control.bounds) : NSMaxX(control.bounds)-1) : NSMidX(control.bounds);
            NSPoint point=[control convertPoint:NSMakePoint(x,NSMidY(control.bounds)) toView:nil];
            if(icon) {
                NSView* reference=window.contentView.superview ?: window.contentView;
                NSPoint gap=[control convertPoint:NSMakePoint(-2,NSMidY(control.bounds)) toView:reference];
                if([window.contentView hitTest:gap]==control || NSWidth(control.frame)!=24 || NSHeight(control.frame)!=24) {
                    fprintf(stderr,"FAIL: icon owns extra space outside its compact 24-point target\n"); failures++;
                }
            }
            NSTimeInterval time=NSProcessInfo.processInfo.systemUptime;
            NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:time
                windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:2 pressure:1];
            NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:time+.01
                windowNumber:window.windowNumber context:nil eventNumber:2 clickCount:2 pressure:0];
            if(action==@selector(showFavoritesPalette:)) {
                NSPoint gap=[control convertPoint:NSMakePoint(-2,NSMidY(control.bounds)) toView:nil];
                NSEvent* drag=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:gap modifierFlags:0 timestamp:time
                    windowNumber:window.windowNumber context:nil eventNumber:3 clickCount:1 pressure:1];
                if(spdf_window_chrome_action_for_event(window,drag,NO,NO)!=SPDFWindowChromeActionDrag) {
                    fprintf(stderr,"FAIL: space beside command icon cannot drag the window\n"); failures++;
                }
            }
            NSUInteger before=sink.calls;
            NSView* hit=[window.contentView hitTest:[window.contentView.superview convertPoint:point fromView:nil]];
            if(icon && hit!=control) {
                fprintf(stderr,"FAIL: icon %s edge %.1f frame %s hits %s\n",NSStringFromSelector(action).UTF8String,x,NSStringFromRect(control.frame).UTF8String,NSStringFromClass(hit.class).UTF8String); failures++; continue;
            }
            [NSApp postEvent:up atStart:YES]; [window sendEvent:down];
            while([NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:NSDate.distantPast inMode:NSEventTrackingRunLoopMode dequeue:YES]) {}
            if(sink.calls!=before+1) {
                fprintf(stderr,"FAIL: post-move control %s action %s dispatched %lu times\n",NSStringFromClass(control.class).UTF8String,
                    NSStringFromSelector(action).UTF8String,(unsigned long)(sink.calls-before)); failures++;
            }
        }
        control.target=target; control.action=action;
    }
    return failures;
}
