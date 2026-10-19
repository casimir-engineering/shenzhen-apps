#import "SPDFMacWorkspaceChrome.h"

// Native switch drawing, keyboard and accessibility, with explicit tracking.
// NSButton's cell tracking can consume a correctly hit press without sending
// its action after this control moves from the toolbar into the Find stack.
@interface SPDFRegexCheckbox : NSButton
@end
@implementation SPDFRegexCheckbox
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsMake(0,0,0,0); }
- (void)mouseDown:(NSEvent*)event {
    if (!self.enabled || event.type!=NSEventTypeLeftMouseDown) return;
    NSWindow* window=self.window;
    [self highlight:YES];
    while (window) {
        NSEvent* next=[window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
        if (!next) break;
        BOOL inside=NSPointInRect([self convertPoint:next.locationInWindow fromView:nil],self.bounds);
        [self highlight:inside];
        if (next.type!=NSEventTypeLeftMouseUp) continue;
        [self highlight:NO];
        if (inside && self.enabled) {
            self.state=self.state==NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
            [self sendAction:self.action to:self.target];
        }
        return;
    }
    [self highlight:NO];
}
@end
NSButton* SPDFWorkspaceRegexCheckbox(id target,SEL action) {
    NSButton* button=[SPDFRegexCheckbox checkboxWithTitle:@"Regex" target:target action:action];
    button.ignoresMultiClick=NO;
    button.toolTip=@"Search using a regular expression";
    return button;
}
