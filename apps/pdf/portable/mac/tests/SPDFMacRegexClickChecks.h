#import "SPDFMacWindowChrome.h"
@interface RegexActionSink : NSObject
@property NSUInteger calls;
- (void)toggle:(id)sender;
@end
@implementation RegexActionSink
- (void)toggle:(id)sender { (void)sender; self.calls++; }
@end
static void CheckRegexClick(NSWindow* window,NSButton* button,NSSearchField* field) {
    NSRect fieldRect=[field convertRect:field.bounds toView:nil];
    NSRect buttonRect=[button convertRect:button.bounds toView:nil];
    Check(NSMinY(fieldRect)-NSMaxY(buttonRect)>=6,@"Regex has a modest gap below the search field");
    id target=button.target; SEL action=button.action; NSControlStateValue saved=button.state;
    RegexActionSink* sink=[RegexActionSink new]; button.target=sink; button.action=@selector(toggle:);
    for (NSNumber* x in @[@.15,@.5,@.85]) for (NSNumber* y in @[@.1,@.5,@.9]) {
        NSPoint p=[button convertPoint:NSMakePoint(NSWidth(button.bounds)*x.doubleValue,NSHeight(button.bounds)*y.doubleValue) toView:nil];
        NSView* root=window.contentView;
        NSView* hit=[root hitTest:[root.superview convertPoint:p fromView:nil]];
        NSControlStateValue before=button.state; NSUInteger calls=sink.calls;
        NSTimeInterval time=NSProcessInfo.processInfo.systemUptime;
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:time windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:2 pressure:1];
        NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:time+.01 windowNumber:window.windowNumber context:nil eventNumber:2 clickCount:2 pressure:0];
        [NSApp postEvent:up atStart:YES];
        BOOL routed=spdf_window_route_button_press(window,down);

        Check(routed,@"Regex press is routed to its button");
        Check(button.state!=before && sink.calls==calls+1,@"Regex native click toggles once");
        Check(hit==button,[NSString stringWithFormat:@"Regex click reaches its checkbox/text, got %@",hit.class]);
    }
    NSControlStateValue before=button.state;
    [button performClick:nil];
    Check(button.state!=before,@"Regex keeps native keyboard/accessibility activation");
    button.target=target; button.action=action; button.state=saved;
}
