#import "SPDFMacTabGroupReaderProbe.h"
#import "SPDFMacTabStripViewPrivate.h"

// Actual strip geometry, event routing, group mutations and session codec.
// Only document loading, persistence I/O and presenting a name popup are stubbed.
@interface GapStrip : SPDFTabStripView
@property NSInteger namePrompts;
@end
@implementation GapStrip
- (void)promptForGroup:(SPDFTabGroup*)group creating:(BOOL)creating {
    (void)group; (void)creating; self.namePrompts++;
}
@end
@interface GapReader : GroupReaderProbe
@property(weak) GapStrip* strip;
@end
@implementation GapReader
- (void)updateTabStrip {
    [super updateTabStrip]; self.strip.tabs=self.tabs; self.strip.selectedIndex=self.selectedIndex;
}
- (void)selectTabAtIndex:(NSInteger)index {
    [super selectTabAtIndex:index]; [self updateTabStrip];
}
- (void)insertDraggedTab:(SPDFDocumentTab*)tab atIndex:(NSInteger)index {
    for (NSUInteger i=0;i<_tabs.count;i++) if ([_tabs[i].path isEqual:tab.path]) {
        [self selectTabAtIndex:i]; return;
    }
    [_tabs insertObject:tab atIndex:MAX(0,MIN(index,(NSInteger)_tabs.count))];
    _selectedTabIndex=[_tabs indexOfObjectIdenticalTo:tab];
    [self normalizeTabGroups]; [self activateSelectedTabGroup];
    self.activePath=tab.path; [self updateTabStrip]; [self savePersistentState];
}
@end
@interface GapDrag : NSObject
@property NSPasteboard* draggingPasteboard;
@property NSPoint draggingLocation;
@end
@implementation GapDrag
@end

NSString* spdf_display_label_without_extension(NSString* label) { return label ?: @""; }
NSString* spdf_display_name_for_path(NSString* path) { return path.lastPathComponent ?: @""; }
NSArray<NSString*>* spdf_disambiguated_display_names_for_paths(NSArray<NSString*>* paths) {
    return [paths valueForKey:@"lastPathComponent"];
}
void spdf_set_menu_item_system_symbol(NSMenuItem* item, NSString* symbol) { (void)item; (void)symbol; }

static int failures, scenarios;
static void Expect(BOOL value, NSString* message) {
    if (!value) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); failures++; }
}
static SPDFDocumentTab* Tab(NSString* path, SPDFTabGroup* group) {
    SPDFDocumentTab* tab=[SPDFDocumentTab new]; tab.path=path; tab.title=path.lastPathComponent;
    tab.group=group; tab.pageIndex=7; return tab;
}
static NSEvent* Mouse(NSWindow* window, NSEventType type, NSPoint point) {
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
        context:nil eventNumber:1 clickCount:1 pressure:1];
}
static id Layout(GapStrip* strip, SPDFTabGroup* group) {
    for (id layout in strip.groupLayouts) if ([layout valueForKey:@"group"]==group) return layout;
    return nil;
}
static void ArmOtherGroup(GapStrip* strip, NSPoint point, NSInteger source) {
    [strip updateGroupDropForPoint:point sourceIndex:source];
    [strip setValue:@(NSDate.timeIntervalSinceReferenceDate-1) forKey:@"groupHoverBegan"];
    [strip updateGroupDropForPoint:point sourceIndex:source];
}
static void CheckDrop(BOOL native, BOOL external, BOOL existingGeneral, BOOL pinned, BOOL stale,
    BOOL besideExpanded, CGFloat edge) {
    scenarios++;
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,pinned ? 800 : 1500,42)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    GapStrip* strip=[[GapStrip alloc] initWithFrame:window.contentView.bounds];
    [window.contentView addSubview:strip];
    GapReader* reader=[GapReader new]; reader.strip=strip; strip.reader=(id)reader;
    SPDFTabGroup* a=[SPDFTabGroup groupWithColor:@"Blue"];
    SPDFTabGroup* b=[SPDFTabGroup groupWithColor:@"Green"];
    SPDFTabGroup* c=[SPDFTabGroup groupWithColor:@"Purple"];
    b.collapsed=c.collapsed=YES;
    SPDFDocumentTab* moving=Tab(@"/moving.pdf",a);
    NSMutableArray* tabs=[@[moving,Tab(@"/a2.pdf",a),Tab(@"/b.pdf",b),Tab(@"/c.pdf",c)] mutableCopy];
    if (pinned) for (NSUInteger i=0;i<60;i++)
        [tabs insertObject:Tab([NSString stringWithFormat:@"/crowded-%lu.pdf",(unsigned long)i],a) atIndex:2];
    if (pinned) [tabs exchangeObjectAtIndex:0 withObjectAtIndex:1];
    SPDFDocumentTab* originalGeneral=nil;
    if (existingGeneral) {
        originalGeneral=Tab(@"/general.pdf",SPDFTabGroup.generalGroup);
        originalGeneral.group.hidden=YES; [tabs insertObject:originalGeneral atIndex:0];
    }
    [reader seed:tabs selected:[tabs indexOfObjectIdenticalTo:moving]]; [reader updateTabStrip];
    if (pinned) strip.tabScrollOffset=80;
    NSRect source=[strip rectForTabAtIndex:reader.selectedIndex];
    NSPoint start=NSMakePoint(NSMinX(source)+28,NSMidY(source));
    if (!native) [strip mouseDown:Mouse(window,NSEventTypeLeftMouseDown,start)];
    if (!native) Expect([[strip valueForKey:@"dragSourceTabIndex"] integerValue]==reader.selectedIndex,
        @"fixture presses a visible document, outside the overflow and close controls");
    // Re-read geometry after the real reader selects the source and refreshes.
    SPDFTabGroup* left=besideExpanded ? a : b;
    SPDFTabGroup* right=besideExpanded ? b : c;
    NSRect lf=[[Layout(strip,left) valueForKey:@"frame"] rectValue];
    NSRect rf=[[Layout(strip,right) valueForKey:@"frame"] rectValue];
    NSPoint gap=NSMakePoint(NSMaxX(lf)+4+edge,21);
    Expect(NSMinX(rf)-NSMaxX(lf)==8,@"test gap is the rendered 8-point inter-group space");
    NSInteger sourceIndex=[reader.tabs indexOfObjectIdenticalTo:moving];
    NSRect bh=[[Layout(strip,b) valueForKey:@"header"] rectValue];
    NSPoint prior=NSMakePoint(NSMidX(bh),NSMidY(bh));
    if (!native) {
        [strip mouseDragged:Mouse(window,NSEventTypeLeftMouseDragged,stale ? prior : gap)];
        if (stale) ArmOtherGroup(strip,prior,sourceIndex);
        if (!stale) Expect(fabs([[strip valueForKey:@"groupDropBoundaryX"] doubleValue]-(gap.x-edge))<.01,
            @"gap preview is centered on the visible group boundary");
        [strip mouseUp:Mouse(window,NSEventTypeLeftMouseUp,gap)];
    } else {
        GapDrag* drag=[GapDrag new]; drag.draggingPasteboard=[NSPasteboard pasteboardWithUniqueName];
        SPDFDocumentTab* incoming=external ? Tab(@"/incoming.pdf",[SPDFTabGroup groupWithColor:@"Coral"]) : moving;
        NSDictionary* payload=spdf_dictionary_from_tab(incoming,external ? window.windowNumber+100 : window.windowNumber);
        NSData* bytes=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        [drag.draggingPasteboard setString:[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]
            forType:SPDFTabDragPasteboardType];
        if (!external) [strip setValue:@(sourceIndex) forKey:@"dragSessionTabIndex"];
        drag.draggingLocation=stale ? prior : gap;
        [strip draggingEntered:(id)drag];
        if (stale) ArmOtherGroup(strip,prior,external ? -1 : sourceIndex);
        if (!stale) Expect(fabs([[strip valueForKey:@"groupDropBoundaryX"] doubleValue]-(gap.x-edge))<.01,
            @"native gap preview matches the local drag preview");
        drag.draggingLocation=gap;
        Expect([strip performDragOperation:(id)drag],@"native drop is accepted");
        [drag.draggingPasteboard releaseGlobally];
        if (external) moving=[reader.tabs filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"path == %@",incoming.path]].firstObject;
    }
    NSString* label=[NSString stringWithFormat:@"%@ %@ %@ %@ %@ edge %.1f",native ? @"native" : @"local",
        external ? @"external" : @"same window",pinned ? @"pinned" : @"normal",stale ? @"stale hover" : @"direct",
        besideExpanded ? @"expanded boundary" : @"collapsed boundary",edge];
    Expect(moving.group.general, [label stringByAppendingString:@": gap must land in General"]);
    Expect(moving.pageIndex==7 && reader.tabs.count==tabs.count+(external ? 1 : 0),
        [label stringByAppendingString:@": no document or reading position is lost"]);
    if (existingGeneral) Expect(moving.group==originalGeneral.group && !moving.group.hidden && reader.tabs.firstObject==originalGeneral,
        [label stringByAppendingString:@": reuse and reveal General at its existing position"]);
    else {
        NSUInteger moved=[reader.tabs indexOfObjectIdenticalTo:moving];
        Expect(moved>0 && moved+1<reader.tabs.count && ((SPDFDocumentTab*)reader.tabs[moved-1]).group==left &&
            ((SPDFDocumentTab*)reader.tabs[moved+1]).group==right,
            [label stringByAppendingString:@": new General belongs between the two destination groups"]);
    }
    NSMutableArray* restored=[NSMutableArray array];
    for (NSDictionary* row in reader.savedTabs) [restored addObject:spdf_tab_from_dictionary(row)];
    spdf_tab_groups_normalize(restored);
    Expect([[restored valueForKey:@"path"] isEqual:[reader.tabs valueForKey:@"path"]],
        [label stringByAppendingString:@": order persists through session restore"]);
    [window close];
}
int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        for (NSNumber* pinned in @[@NO,@YES]) for (NSNumber* general in @[@NO,@YES])
            for (NSNumber* stale in @[@NO,@YES]) for (NSNumber* mode in @[@0,@1,@2])
                for (NSNumber* expanded in @[@NO,@YES]) for (NSNumber* edge in @[@0,@-3.5,@3.5,@-6,@6])
                    CheckDrop(mode.intValue>0,mode.intValue==2,general.boolValue,pinned.boolValue,
                        stale.boolValue,expanded.boolValue,edge.doubleValue);
    }
    printf("Tab gap drop scenarios: %d; failures: %d\n",scenarios,failures);
    return failures ? 1 : 0;
}
