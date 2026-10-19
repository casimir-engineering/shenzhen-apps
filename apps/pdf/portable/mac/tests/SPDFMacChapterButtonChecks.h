#import "SPDFMacSidebarChapters.h"
#import "SPDFMacPanelExpansionImage.h"
@interface WorkspaceReaderProbe (ChapterCheckHost)
- (NSSet*)collapsedChapterKeys;
- (void)setCollapsedChapterKeys:(NSSet*)keys;
@end
@implementation WorkspaceReaderProbe (ChapterButtons)
- (void)checkChapterButtons {
    Check(_outline.count>=3,@"chapter click fixture has three entries"); if(_outline.count<3) return;
    int levels[3]; for(int i=0;i<3;i++) { levels[i]=_outline.items[i].level; _outline.items[i].level=i; }
    if (!_documentStates) _documentStates=[NSMutableDictionary dictionary];
    _chapterFilterText=@""; _sidebarModeControl.spdf_selectedSidebarMode=SPDFSidebarModeChapters;
    [self setCollapsedChapterKeys:NSSet.set]; [self rebuildSidebar];
    [_window.contentView layoutSubtreeIfNeeded];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    [_window.contentView layoutSubtreeIfNeeded];
    NSButton* button=[_sidebarContainer viewWithTag:8801];
    Check(button && !button.hidden && NSHeight(button.bounds)==26,@"chapter toggle has a full-size visible target");
    Check(NSEqualSizes(button.image.size,SPDFGroupExpansionImage(YES).size),@"chapters use the Groups expansion icon size");
    for(NSNumber* x in @[@.1,@.5,@.9]) for(NSNumber* y in @[@.1,@.5,@.9]) {
        NSUInteger before=_sidebarItems.count;
        NSPoint p=[button convertPoint:NSMakePoint(NSWidth(button.bounds)*x.doubleValue,NSHeight(button.bounds)*y.doubleValue) toView:nil];
        NSTimeInterval t=NSProcessInfo.processInfo.systemUptime;
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:t windowNumber:_window.windowNumber context:nil eventNumber:1 clickCount:2 pressure:1];
        NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:t+.01 windowNumber:_window.windowNumber context:nil eventNumber:2 clickCount:2 pressure:0];
        [NSApp postEvent:up atStart:YES];
        Check(spdf_window_route_button_press(_window,down),@"chapter toggle accepts press over full target");
        Check(before!=_sidebarItems.count && (_sidebarItems.count==1 || _sidebarItems.count==3),@"each repeated chapter toggle expands/collapses the real outline");
    }
    [self setCollapsedChapterKeys:NSSet.set]; [self rebuildSidebar];
    for(NSNumber* y in @[@.1,@.5,@.9]) {
        [_sidebarTable layoutSubtreeIfNeeded];
        NSView* cell=[_sidebarTable viewAtColumn:0 row:0 makeIfNecessary:YES];
        NSButton* disclosure=[cell viewWithTag:8800]; NSUInteger before=_sidebarItems.count;
        Check(disclosure && !disclosure.hidden,@"root chapter exposes disclosure button");
        if (!disclosure) continue;
        NSPoint point=[disclosure convertPoint:NSMakePoint(NSWidth(disclosure.bounds)/2,NSHeight(disclosure.bounds)*y.doubleValue) toView:nil];
        NSTimeInterval t=NSProcessInfo.processInfo.systemUptime;
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:t windowNumber:_window.windowNumber context:nil eventNumber:3 clickCount:1 pressure:1];
        NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:t+.01 windowNumber:_window.windowNumber context:nil eventNumber:4 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:YES];
        Check(spdf_window_route_button_press(_window,down),@"individual chapter disclosure accepts click");
        Check(before!=_sidebarItems.count,@"individual chapter disclosure changes visible children");
    }
    [self setCollapsedChapterKeys:NSSet.set];
    for(int i=0;i<3;i++) _outline.items[i].level=levels[i];
    [self rebuildSidebar];
}
@end
