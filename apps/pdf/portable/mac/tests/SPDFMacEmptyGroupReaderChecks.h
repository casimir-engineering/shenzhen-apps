#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacTabStripViewPrivate.h"

// Keep the native prompt content and field-editor selection, replacing only
// presentation so the real reader action never displays a window.
static NSPopover* EmptyGroupProbePopover;
static NSWindow* EmptyGroupProbePromptWindow;
static NSRect EmptyGroupProbeAnchor;
static void EmptyGroupProbeShow(id object, SEL selector, NSRect rect, NSView* view, NSRectEdge edge) {
    (void)selector; (void)view; (void)edge;
    EmptyGroupProbePopover=object; EmptyGroupProbeAnchor=rect;
    NSView* content=EmptyGroupProbePopover.contentViewController.view;
    EmptyGroupProbePromptWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(-10000,-10000,292,112)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    EmptyGroupProbePromptWindow.alphaValue=0;
    EmptyGroupProbePromptWindow.contentView=content;
}
static NSTextField* EmptyGroupNameField(NSView* view) {
    if ([view isKindOfClass:NSTextField.class] && [view.identifier isEqual:@"GroupNameField"]) return (id)view;
    for (NSView* child in view.subviews) { NSTextField* field=EmptyGroupNameField(child); if (field) return field; }
    return nil;
}
@implementation WorkspaceReaderProbe (EmptyGroupAction)
- (void)checkEmptyGroupAction {
    SPDFDocumentTab* selected=[self selectedTab]; NSString* path=_path;
    NSInteger page=_pageIndex, index=_selectedTabIndex; NSUInteger count=_tabs.count;
    NSUInteger emptyCount=[self emptyTabGroups].count;
    Method method=class_getInstanceMethod(NSPopover.class,@selector(showRelativeToRect:ofView:preferredEdge:));
    IMP original=method_setImplementation(method,(IMP)EmptyGroupProbeShow);
    NSMenu* add=[_tabStrip newTabOrGroupMenu];
    auto activeDocument=_doc; _doc=NULL;
    Check(![self hasActiveDocument],@"menu-validation fixture has no active document");
    [add update];
    Check([add itemWithTitle:@"New Tab"].enabled && [add itemWithTitle:@"New Group…"].enabled,
          @"both plus actions remain enabled without an active document");
    _doc=activeDocument;
    NSInteger item=[add indexOfItemWithTitle:@"New Group…"];
    Check(item>=0,@"actual reader plus menu contains New Group");
    if (item>=0) [add performActionForItemAtIndex:item];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    method_setImplementation(method,original);
    SPDFTabGroup* created=[self emptyTabGroups].lastObject;
    Check(created && [self emptyTabGroups].count==emptyCount+1,@"actual New Group action creates a persistent empty group");
    Check([self selectedTab]==selected && _selectedTabIndex==index && [_path isEqual:path] && _pageIndex==page && _tabs.count==count,
          @"New Group preserves current document, page and selection without adding fake tabs");
    Check([[self sidebarWorkspaceState][@"pendingNewGroupID"] isEqual:created.identifier],@"new group becomes next-document destination");
    Check([_tabStrip.emptyGroups containsObject:created],@"actual reader sends its empty group to the tab strip");
    Check(!NSIsEmptyRect(EmptyGroupProbeAnchor),@"native name prompt anchors to a visible group header");
    NSTextField* field=EmptyGroupNameField(EmptyGroupProbePopover.contentViewController.view);
    Check([field.stringValue isEqual:created.displayName],@"native name prompt starts with the default group name");
    NSTextView* editor=(id)field.currentEditor;
    Check(editor && NSEqualRanges(editor.selectedRange,NSMakeRange(0,field.stringValue.length)),
          @"native prompt selects the whole default name for immediate replacement");
    [EmptyGroupProbePopover close];
    if ([EmptyGroupProbePopover.delegate respondsToSelector:@selector(popoverDidClose:)])
        [EmptyGroupProbePopover.delegate popoverDidClose:[NSNotification notificationWithName:NSPopoverDidCloseNotification object:EmptyGroupProbePopover]];
    [self closeTabGroup:created];
    Check([self emptyTabGroups].count==emptyCount && [self selectedTab]==selected,@"closing empty group preserves current reader");
    Check(!EmptyGroupProbePromptWindow.visible && !_window.visible,@"real-reader menu check never displays a window");
    EmptyGroupProbePopover=nil; EmptyGroupProbePromptWindow=nil;
}
@end
