#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacEmptyGroupReaderChecks.h"
#import "SPDFMacChapterButtonChecks.h"
static NSButton* GroupProbeButton(NSView* view,NSString* label) {
    if ([view isKindOfClass:NSButton.class] && [view.accessibilityLabel isEqual:label]) return (id)view;
    for(NSView* child in view.subviews) { NSButton* found=GroupProbeButton(child,label); if(found) return found; }
    return nil;
}
@implementation WorkspaceReaderProbe (GroupButtons)
- (void)checkGroupButtons {
    [self checkChapterButtons]; [self checkEmptyGroupAction];
    _sidebarModeControl.spdf_selectedSidebarMode=SPDFSidebarModeGroups;
    [self sidebarModeChanged:_sidebarModeControl]; [_window.contentView layoutSubtreeIfNeeded];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    [_window.contentView layoutSubtreeIfNeeded];
    NSButton* button=GroupProbeButton(_window.contentView,@"Collapse all groups");
    Check(button!=nil,@"real reader contains collapse-all button");
    if (!button) return;
    for(NSNumber* x in @[@.1,@.5,@.9]) for(NSNumber* y in @[@.1,@.5,@.9]) {
        NSUInteger before=[[self sidebarWorkspaceState][@"expandedGroups"] count];
        NSPoint point=[button convertPoint:NSMakePoint(NSWidth(button.bounds)*x.doubleValue,NSHeight(button.bounds)*y.doubleValue) toView:nil];
        NSView* root=_window.contentView;
        Check([root hitTest:[root.superview convertPoint:point fromView:nil]]==button,@"real reader group button is hit over its whole area");
        NSTimeInterval t=NSProcessInfo.processInfo.systemUptime;
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:t windowNumber:_window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:t+.01 windowNumber:_window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:YES];
        Check(spdf_window_route_button_press(_window,down),@"real reader routes group press");
        Check((before==0)!=([[self sidebarWorkspaceState][@"expandedGroups"] count]==0),@"actual reader mouse click toggles expansion");
    }
    NSUInteger beforeCancel=[[self sidebarWorkspaceState][@"expandedGroups"] count];
    NSPoint cancelPoint=[button convertPoint:NSMakePoint(13,13) toView:nil];
    NSTimeInterval cancelTime=NSProcessInfo.processInfo.systemUptime;
    NSEvent* cancelDown=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:cancelPoint modifierFlags:0 timestamp:cancelTime windowNumber:_window.windowNumber context:nil eventNumber:5 clickCount:1 pressure:1];
    NSEvent* cancelUp=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(-100,-100) modifierFlags:0 timestamp:cancelTime+.01 windowNumber:_window.windowNumber context:nil eventNumber:6 clickCount:1 pressure:0];
    [NSApp postEvent:cancelUp atStart:YES]; spdf_window_route_button_press(_window,cancelDown);
    Check([[self sidebarWorkspaceState][@"expandedGroups"] count]==beforeCancel,@"release outside group button cancels action");
    NSButton* jump=GroupProbeButton(_window.contentView,@"Jump to current document");
    Check(jump!=nil && jump.enabled,@"real reader exposes current-document target");
    if (!jump) return;
    NSView* panel=jump.superview;
    NSTableView* table=nil; NSSearchField* search=nil;
    for (NSView* child in panel.subviews) {
        if ([child isKindOfClass:NSScrollView.class]) table=(id)[(NSScrollView*)child documentView];
        if ([child isKindOfClass:NSSearchField.class]) search=(id)child;
    }
    search.stringValue=@"No matching document";
    [search.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
    for(NSNumber* y in @[@.1,@.5,@.9]) {
        NSPoint p=[jump convertPoint:NSMakePoint(NSWidth(jump.bounds)/2,NSHeight(jump.bounds)*y.doubleValue) toView:nil];
        NSTimeInterval t=NSProcessInfo.processInfo.systemUptime;
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:t windowNumber:_window.windowNumber context:nil eventNumber:3 clickCount:2 pressure:1];
        NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:t+.01 windowNumber:_window.windowNumber context:nil eventNumber:4 clickCount:2 pressure:0];
        [NSApp postEvent:up atStart:YES];
        Check(spdf_window_route_button_press(_window,down),@"real reader routes current-document press");
        Check(search.stringValue.length==0 && table.selectedRow>=0 && [[self sidebarWorkspaceState][@"expandedGroups"] count]>0,
            @"current-document mouse click clears filter and expands active group");
        NSRect row=[table rectOfRow:table.selectedRow], viewport=table.enclosingScrollView.contentView.bounds;
        Check(NSMinY(row)>=NSMinY(viewport) && NSMaxY(row)<=NSMaxY(viewport),@"current document scrolls into view");
    }
}
@end
