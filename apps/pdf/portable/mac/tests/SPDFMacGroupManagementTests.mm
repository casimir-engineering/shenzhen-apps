#import <Cocoa/Cocoa.h>
#import "SPDFMacGroupManagement.h"
#import "SPDFMacSidebarModeControl.h"
static int failures;
static void Check(BOOL ok, const char* label) { if (!ok) { fprintf(stderr,"FAIL: %s\n",label); failures++; } }
@interface GroupSurface : NSView
@end
@implementation GroupSurface
- (void)drawRect:(NSRect)rect { [NSColor.windowBackgroundColor setFill]; NSRectFill(rect); }
@end
static NSView* Find(NSView* view, Class type) {
    if ([view isKindOfClass:type]) return view;
    for (NSView* child in view.subviews) { NSView* found = Find(child,type); if (found) return found; }
    return nil;
}
static NSButton* Button(NSView* view, NSString* label) {
    if ([view isKindOfClass:NSButton.class] && [view.accessibilityLabel isEqual:label]) return (id)view;
    for (NSView* child in view.subviews) { NSButton* found = Button(child,label); if (found) return found; }
    return nil;
}
static NSArray* Groups(void) {
    NSMutableArray* groups = [NSMutableArray array];
    NSArray* names = @[@"General",@"Research",@"Travel plans",@"Design references",@"Project notes",@"Archive"];
    NSArray* colors = @[@"Gray",@"Blue",@"Teal",@"Purple",@"Coral",@"Green"];
    for (NSUInteger i=0;i<names.count;i++) {
        NSString* identifier = i ? [NSString stringWithFormat:@"group-%lu",i] : @"general";
        [groups addObject:@{@"id":identifier,@"name":names[i],@"color":colors[i],@"hidden":@(i==2 || i==5),@"selected":@(i==1),
            @"documents":@[@{@"title":@"Getting started.pdf",@"path":@"/Getting started.pdf"},
                @{@"title":@"Conference notes.md",@"path":@"/Conference notes.md",@"selected":@(i==1)}]}];
    }
    return groups;
}
#import "SPDFMacGroupManagementDragChecks.h"
static void Render(CGFloat width, CGFloat height, BOOL dark, NSInteger variant, NSString* output) {
    NSWindow* host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,width,height)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    host.releasedWhenClosed = NO; host.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    host.contentView = [[GroupSurface alloc] initWithFrame:NSMakeRect(0,0,width,height)];
    Check(fabs(NSWidth(host.contentView.bounds)-width)<.5,"fixture renders the requested sidebar width");
    SPDFSidebarNavigationControl* navigation = [SPDFSidebarNavigationControl new];
    spdf_sidebar_mode_control_configure_navigation(navigation,variant == 3 || variant == 4,YES);
    navigation.spdf_selectedSidebarMode = SPDFSidebarModeGroups;
    NSMutableArray* fixtureGroups = [Groups() mutableCopy];
    BOOL hiddenActive = variant == 1 || variant == 4;
    if (hiddenActive) {
        NSMutableDictionary* active = [fixtureGroups[1] mutableCopy]; active[@"hidden"] = @YES; fixtureGroups[1] = active;
        NSMutableDictionary* longName = [fixtureGroups[3] mutableCopy]; longName[@"name"] = @"Design references and archived project material"; fixtureGroups[3] = longName;
    }
    SPDFGroupManagementController* manager = [SPDFGroupManagementController new];
    [manager updateGroups:fixtureGroups state:@{@"expandedGroups":@[@"group-1"],@"groupScroll":@100}];
    for (NSView* child in @[navigation,manager.view]) { child.translatesAutoresizingMaskIntoConstraints = NO; [host.contentView addSubview:child]; }
    [NSLayoutConstraint activateConstraints:@[
        [navigation.topAnchor constraintEqualToAnchor:host.contentView.topAnchor constant:8],
        [navigation.leadingAnchor constraintEqualToAnchor:host.contentView.leadingAnchor constant:8],
        [navigation.trailingAnchor constraintEqualToAnchor:host.contentView.trailingAnchor constant:-8],
        [manager.view.topAnchor constraintEqualToAnchor:navigation.bottomAnchor constant:4],
        [manager.view.leadingAnchor constraintEqualToAnchor:host.contentView.leadingAnchor],
        [manager.view.trailingAnchor constraintEqualToAnchor:host.contentView.trailingAnchor],
        [manager.view.bottomAnchor constraintEqualToAnchor:host.contentView.bottomAnchor]]];
    [host.contentView layoutSubtreeIfNeeded];
    Check(fabs(NSWidth(host.contentView.bounds)-width)<.5,"layout preserves the requested sidebar width");
    NSTableView* table = (id)Find(manager.view,NSTableView.class);
    NSSearchField* search = (id)Find(manager.view,NSSearchField.class);
    NSScrollView* scroll = table.enclosingScrollView;
    Check(fabs(NSWidth(table.frame)-NSWidth(scroll.contentView.bounds))<1,"table width follows clip viewport");
    Check(fabs(scroll.contentView.bounds.origin.y-MIN(100,MAX(0,NSHeight(table.frame)-NSHeight(scroll.contentView.bounds))))<1,
        "initial detached scroll restore waits for real viewport and clamps to content");
    Check(table.numberOfRows == 8,"expanded group exposes documents inline");
    Check(NSWidth(scroll.frame) <= width && NSHeight(scroll.frame) > 35,"group list fits narrow and short panel");
    if (height <= 296) Check(NSHeight(scroll.contentView.bounds) >= 76,"minimum sidebar initially fits two complete group rows including gaps");
    Check([manager tableView:table heightOfRow:0] >= 36,"group metadata retains two readable lines");
    Check(NSHeight(search.frame) >= 26 && NSWidth(search.frame) >= 102,"search remains usable at minimum supported width");
    fprintf(stdout,"Groups geometry %.0fx%.0f modes=%ld list=%.0fpt first=%.0fpt\n",width,height,navigation.segmentCount,
        NSHeight(scroll.contentView.bounds),height-NSMaxY([scroll convertRect:scroll.bounds toView:host.contentView]));
    NSRect textRect=[(NSSearchFieldCell*)search.cell searchTextRectForBounds:search.bounds];
    Check(NSMaxX(textRect)>=NSWidth(search.bounds)-9,"empty placeholder uses the unused cancel-button space");
    Check([search.placeholderString sizeWithAttributes:@{NSFontAttributeName:search.font}].width<=NSWidth(textRect),
        "placeholder uses complete words that fit the actual text area");
    if (width>=400) Check([search.placeholderString isEqual:@"Search groups and documents"],"wide search retains full document wording");
    Check(search.focusRingType != NSFocusRingTypeNone,"search retains accessible keyboard focus feedback");
    Check(table.selectedRow == 3,"active document has selected-row feedback");
    NSButton* all = Button(manager.view,@"Collapse all groups");
    Check(all.image != nil,"all-groups toggle has a native symbol");
    Check(NSMinX(all.frame)>=NSMaxX(search.frame)+3 && fabs(NSMidY(all.frame)-NSMidY(search.frame))<1,
        "toggle sits beside and centered on the search field");
    NSButton* jump=Button(manager.view,@"Jump to current document");
    Check(jump.image!=nil && jump.enabled,"jump-to-current has a valid icon and active document");
    NSDictionary* initialState=manager.viewState;
    [all performClick:nil];
    Check(table.numberOfRows==6 && [manager.viewState[@"expandedGroups"] count]==0,"collapse all hides every document row");
    [all performClick:nil];
    Check(table.numberOfRows==18 && [manager.viewState[@"expandedGroups"] count]==6,"expand all restores every group's documents");
    NSDictionary* expandedState=manager.viewState;
    [manager updateGroups:fixtureGroups state:expandedState];
    Check(table.numberOfRows==18,"all-group expansion survives a state restore");
    [manager updateGroups:fixtureGroups state:@{@"groupQuery":@"No matching document",@"expandedGroups":@[]}];
    [jump performClick:nil];
    Check(search.stringValue.length==0 && table.selectedRow==3 && table.numberOfRows==8,
        "jump clears blocking filter, expands active group and selects current document");
    [manager updateGroups:fixtureGroups state:initialState];
    __block NSString* action; __block NSString* target; __block NSUInteger changes = 0;
    manager.actionHandler = ^(NSString* verb, NSString* group, NSString* value) { (void)value; action = verb; target = group; changes++; };
    NSView* research = [manager tableView:table viewForTableColumn:table.tableColumns.firstObject row:1];
    Check(Button(research,@"Collapse Research in tab bar").image!=nil,"tab-bar collapse has a valid distinct symbol");
    [Button(research,@"Collapse Research in tab bar") performClick:nil];
    Check([action isEqual:@"collapse"] && [target isEqual:@"group-1"] && changes==1,
        "tab-bar collapse is a distinct group action");
    changes=0;
    [Button(research,hiddenActive ? @"Show Research in tab bar" : @"Hide Research from tab bar") performClick:nil];
    Check([action isEqual:@"visibility"] && [target isEqual:@"group-1"] && changes == 1,"eye action changes visibility without jumping");
    [Button(research,@"Collapse Research documents") performClick:nil];
    Check(table.numberOfRows == 6 && changes == 1,"disclosure changes document expansion without navigation");
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    Check(changes == 1,"keyboard-style row selection alone does not navigate");
    NSEvent* enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
        windowNumber:host.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    [table keyDown:enter];
    Check(changes == 2 && [action isEqual:@"jump"] && [target isEqual:@"group-2"],"Return activates selected group independently of old mouse row");
    search.stringValue = @"Conference";
    [manager controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
    Check(table.numberOfRows == 12,"document-name search reveals matching documents under each owning group");
    [all performClick:nil];
    Check(table.numberOfRows==6 && [search.stringValue isEqual:@"Conference"],"collapse all works without clearing search");
    [all performClick:nil];
    Check(table.numberOfRows==12,"expand all reveals filtered matches");
    [manager updateGroups:fixtureGroups state:@{@"groupQuery":@"Conference",@"expandedGroups":@[]}];
    NSArray* matchedRows = [manager valueForKey:@"rows"];
    Check([matchedRows[1][@"document"][@"title"] isEqual:@"Conference notes.md"],"search excludes unrelated siblings");
    Check([manager.viewState[@"expandedGroups"] count] == 0,"temporary search expansion does not change saved groups");
    search.stringValue = @".MD";
    [manager controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
    Check(table.numberOfRows == 12,"filename extension search is case insensitive");
    search.stringValue = @"";
    [manager controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
    Check(table.numberOfRows == 6,"clearing search restores saved collapsed groups");
    search.stringValue = @"rEsEaRcH";
    [manager controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
    Check(table.numberOfRows == 3,"group-name search is case insensitive and shows its documents");
    Check([manager.viewState[@"groupQuery"] isEqual:@"rEsEaRcH"],"search is exposed for YAML persistence");
    [manager updateGroups:fixtureGroups state:@{@"expandedGroups":@[@"group-1"],@"groupScroll":@100}];
    [host.contentView layoutSubtreeIfNeeded];
    Check(fabs(scroll.contentView.bounds.origin.y-MIN(100,MAX(0,NSHeight(table.frame)-NSHeight(scroll.contentView.bounds))))<1,
        "saved list scroll restores after layout without blank overscroll");
    search.stringValue = @"Research";
    [manager controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
    [host makeFirstResponder:search];
    NSTextView* editor = (id)search.currentEditor; [editor setSelectedRange:NSMakeRange(2,3)];
    [manager updateGroups:fixtureGroups state:manager.viewState];
    Check(NSEqualRanges(editor.selectedRange,NSMakeRange(2,3)),"unchanged background refresh preserves field-editor selection");
    Check(search.cell.isScrollable && !search.cell.wraps && search.cell.usesSingleLineMode,
        "group search uses a scrolling single-line editor");
    NSString* longQuery=[@"long document name " stringByPaddingToLength:300 withString:@"more words " startingAtIndex:0];
    [editor selectAll:nil]; [editor insertText:longQuery replacementRange:editor.selectedRange];
    // Invisible fixtures need the layout pass normally driven by display.
    [editor.layoutManager ensureLayoutForTextContainer:editor.textContainer];
    [editor sizeToFit];
    [editor scrollRangeToVisible:NSMakeRange(editor.string.length,0)];
    Check(editor.selectedRange.location==longQuery.length && editor.superview.bounds.origin.x>22,
        "typing past field width scrolls horizontally to keep insertion point visible");
    [editor setSelectedRange:NSMakeRange(0,0)]; [editor scrollRangeToVisible:NSMakeRange(0,0)];
    Check(editor.visibleRect.origin.x<1,"moving caret to beginning scrolls back");
    [host makeFirstResponder:nil];
    [manager updateGroups:fixtureGroups state:@{@"expandedGroups":@[@"group-1"]}];
    [host.contentView layoutSubtreeIfNeeded];
    if (hiddenActive) [host makeFirstResponder:search];
    if (variant == 2) { search.stringValue = @"No such document"; [manager controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]]; }
    [table layoutSubtreeIfNeeded];
    NSView* visibleResearch = table.numberOfRows > 1 ? [table viewAtColumn:0 row:1 makeIfNecessary:YES] : nil;
    NSButton* eye = Button(visibleResearch,hiddenActive ? @"Show Research in tab bar" : @"Hide Research from tab bar");
    if (eye) {
        NSRect eyeBounds = [eye convertRect:eye.bounds toView:table];
        Check(NSWidth(eye.bounds) >= 26 && NSHeight(eye.bounds) >= 26,"visibility retains its full click target");
        Check(NSMinX(eyeBounds) >= 0 && NSMaxX(eyeBounds) <= NSWidth(table.bounds),"visibility target never clips at narrow width");
    }
    if (table.numberOfRows>0) {
    NSInteger priorRow=table.selectedRow;
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    NSMenu* groupMenu=[NSMenu new]; [manager menuNeedsUpdate:groupMenu];
    NSMenuItem* close=[groupMenu itemWithTitle:@"Close Group…"];
    Check(close!=nil,"group context menu includes Close Group with confirmation ellipsis");
    [NSApp sendAction:close.action to:close.target from:close];
    Check([action isEqual:@"close"] && [target isEqual:@"general"],"group menu routes close separately from visibility");
    [table selectRowIndexes:priorRow>=0 ? [NSIndexSet indexSetWithIndex:priorRow] : [NSIndexSet indexSet] byExtendingSelection:NO];
    }
    if (output.length) {
        NSBitmapImageRep* bitmap = [host.contentView bitmapImageRepForCachingDisplayInRect:host.contentView.bounds];
        [host.contentView cacheDisplayInRect:host.contentView.bounds toBitmapImageRep:bitmap];
        Check([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output atomically:YES],"integrated native PNG written");
    }
    Check(!host.visible,"group management tests never show app window");
}
static void CheckGroupScrolling(NSString* evidence) {
    NSWindow* host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,280,340)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    host.releasedWhenClosed = NO;
    SPDFGroupManagementController* manager = [SPDFGroupManagementController new];
    NSMutableArray* groups = [NSMutableArray array];
    for (NSUInteger groupIndex=0;groupIndex<3;groupIndex++) {
        NSMutableArray* documents = [NSMutableArray array];
        for (NSUInteger index=0;index<18;index++) {
            NSString* name = [NSString stringWithFormat:@"Document %lu.pdf",index];
            [documents addObject:@{@"title":name,@"path":[@"/" stringByAppendingString:name],
                @"selected":@(groupIndex==1 && index==12)}];
        }
        [groups addObject:@{@"id":[NSString stringWithFormat:@"g%lu",groupIndex],
            @"name":[NSString stringWithFormat:@"Group %lu",groupIndex],@"color":@"Blue",
            @"selected":@(groupIndex==1),@"documents":documents}];
    }
    [manager updateGroups:groups state:@{@"expandedGroups":@[@"g0",@"g2"],@"groupScroll":@0}];
    __block NSDictionary* savedExpansion=nil;
    manager.stateHandler=^(NSDictionary* state) { savedExpansion=state; };
    [manager revealSelectedDocument];
    Check([savedExpansion[@"expandedGroups"] containsObject:@"g1"],"active group expansion publishes before first layout");
    [manager updateGroups:groups state:savedExpansion];
    Check([manager.viewState[@"expandedGroups"] containsObject:@"g1"],"refresh cannot restore stale collapsed active group");
    manager.stateHandler=nil;
    host.contentView = [[GroupSurface alloc] initWithFrame:NSMakeRect(0,0,280,340)];
    manager.view.frame = host.contentView.bounds;
    manager.view.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    [host.contentView addSubview:manager.view];
    [host.contentView layoutSubtreeIfNeeded];
    NSTableView* table = (id)Find(manager.view,NSTableView.class);
    NSScrollView* scroll = table.enclosingScrollView;
    Check(table.floatsGroupRows,"native section headers float while their documents scroll");
    Check(scroll.wantsLayer && scroll.layer.masksToBounds,"departing headers clip at the list edge, below search");
    [manager revealSelectedDocument]; [host.contentView layoutSubtreeIfNeeded];
    Check([manager.viewState[@"expandedGroups"] containsObject:@"g1"],"entering Groups expands active document's group");
    NSRect selected = [table rectOfRow:table.selectedRow];
    NSRect viewport = scroll.contentView.bounds;
    Check(NSMinY(selected)>=NSMinY(viewport)+36 && NSMaxY(selected)<=NSMaxY(viewport),
        "entering Groups reveals active document below its pinned header");
    Check([manager tableView:table isGroupRow:19] && ![manager tableView:table isGroupRow:20],
        "only group headings pin, never document rows");
    CGFloat boundary = NSMinY([table rectOfRow:19]);
    for (NSNumber* position in @[@180,@(boundary-18),@(boundary+100),@(boundary-18),@180]) {
        [scroll.contentView scrollToPoint:NSMakePoint(0,position.doubleValue)];
        [scroll reflectScrolledClipView:scroll.contentView]; [table layoutSubtreeIfNeeded];
        [table displayIfNeeded];
        NSInteger heading = position.doubleValue >= boundary ? 19 : 0;
        NSTableRowView* row = [table rowViewAtRow:heading makeIfNecessary:YES];
        NSRect floating = [row convertRect:row.bounds toView:table];
        CGFloat expected = heading == 0 ? MIN(position.doubleValue,boundary-NSHeight(floating)) : position.doubleValue;
        fprintf(stdout,"Pinned header scroll=%.0f actual=%.0f expected=%.0f height=%.0f\n",position.doubleValue,NSMinY(floating),expected,NSHeight(floating));
        Check(fabs(NSMinY(floating)-expected)<3,"header pins and yields at the next section in both scroll directions");
    }
    [scroll.contentView scrollToPoint:NSMakePoint(0,boundary-18)];
    [scroll reflectScrolledClipView:scroll.contentView]; [table layoutSubtreeIfNeeded];
    CGFloat manualScroll = scroll.contentView.bounds.origin.y;
    __block NSString* actionGroup = nil;
    manager.actionHandler = ^(NSString* action,NSString* group,NSString* value) {
        (void)action; (void)value; actionGroup = group;
    };
    NSView* pinnedContent = [table viewAtColumn:0 row:19 makeIfNecessary:YES];
    [Button(pinnedContent,@"Hide Group 1 from tab bar") performClick:nil];
    Check([actionGroup isEqual:@"g1"],"pinned group controls keep their correct action target");
    [manager updateGroups:groups state:manager.viewState];
    Check(fabs(scroll.contentView.bounds.origin.y-manualScroll)<1,"ordinary refresh preserves manual scroll position");
    if (evidence.length) {
        NSBitmapImageRep* bitmap = [host.contentView bitmapImageRepForCachingDisplayInRect:host.contentView.bounds];
        [host.contentView cacheDisplayInRect:host.contentView.bounds toBitmapImageRep:bitmap];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[evidence stringByAppendingPathComponent:@"groups-sticky.png"] atomically:YES];
    }
    Check(!host.visible,"scroll checks never display the native app");
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSString* evidence = NSProcessInfo.processInfo.environment[@"SPDF_GROUP_MANAGEMENT_EVIDENCE_DIR"];
        if (evidence.length) [NSFileManager.defaultManager createDirectoryAtPath:evidence withIntermediateDirectories:YES attributes:nil error:nil];
        CheckGroupDocumentDragging(); CheckGroupHeaderColors();
        CheckGroupScrolling(evidence);
        Render(400,640,NO,3,evidence ? [evidence stringByAppendingPathComponent:@"groups-wide.png"] : nil);
        Render(176,296,NO,3,evidence ? [evidence stringByAppendingPathComponent:@"groups-minimum.png"] : nil);
        Render(220,296,NO,3,evidence ? [evidence stringByAppendingPathComponent:@"groups-220-minimum.png"] : nil);
        Render(240,640,YES,3,evidence ? [evidence stringByAppendingPathComponent:@"groups-default-dark.png"] : nil);
        Render(176,640,NO,4,evidence ? [evidence stringByAppendingPathComponent:@"groups-minimum-hidden-active.png"] : nil);
        Render(220,640,NO,NO,evidence ? [evidence stringByAppendingPathComponent:@"groups-narrow.png"] : nil);
        Render(280,640,YES,NO,evidence ? [evidence stringByAppendingPathComponent:@"groups-dark.png"] : nil);
        Render(220,340,NO,NO,evidence ? [evidence stringByAppendingPathComponent:@"groups-short.png"] : nil);
        Render(220,640,NO,YES,evidence ? [evidence stringByAppendingPathComponent:@"groups-hidden-active-focus.png"] : nil);
        Render(220,640,NO,2,evidence ? [evidence stringByAppendingPathComponent:@"groups-no-matches.png"] : nil);
        Render(220,340,NO,3,evidence ? [evidence stringByAppendingPathComponent:@"groups-pdf-short.png"] : nil);
        SPDFGroupManagementController* empty = [SPDFGroupManagementController new];
        [empty updateGroups:@[] state:@{}];
        NSTextField* message = [empty valueForKey:@"empty"];
        Check(!message.hidden && [message.stringValue containsString:@"Open a document"],"initial empty workspace shows guidance");
        if (!failures) puts("SPDFMacGroupManagementTests passed");
    }
    return failures ? 1 : 0;
}
