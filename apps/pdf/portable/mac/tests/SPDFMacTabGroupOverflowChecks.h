#include "SPDFMacTabGroupPickerChecks.h"
// Focused tab-strip layout regressions; included by the interaction test TU.
static void check_group_overflow(void) {
    for (NSNumber* count in @[@50, @100]) for (NSNumber* customFirst in @[@NO, @YES])
        for (NSNumber* width in @[@700, @900]) {
            SPDFTabGroup* general = SPDFTabGroup.generalGroup;
            SPDFTabGroup* custom = [SPDFTabGroup groupWithColor:@"Purple"];
            SPDFGroupTestStrip* crowded = [[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,width.doubleValue,42)];
            NSMutableArray* fixture = [NSMutableArray array];
            for (NSInteger i = 0; i < count.integerValue; ++i) [fixture addObject:tab(@"General",general)];
            NSIndexSet* pair = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(customFirst.boolValue ? 0 : fixture.count,2)];
            [fixture insertObjects:@[tab(@"Grouped A",custom),tab(@"Grouped B",custom)] atIndexes:pair];
            crowded.tabs = (id)fixture;
            for (NSNumber* selectGeneral in @[@NO, @YES]) {
                general.collapsed=!selectGeneral.boolValue; custom.collapsed=selectGeneral.boolValue;
                crowded.tabs=(id)fixture;
                crowded.selectedIndex = selectGeneral.boolValue ? (customFirst.boolValue ? 2 : count.integerValue-1) : pair.lastIndex;
                NSArray* visible = crowded.groupedVisibleTabIndexes;
                expect(selectGeneral.boolValue || ([visible containsObject:@(pair.firstIndex)] && [visible containsObject:@(pair.lastIndex)]),
                       @"General tabs consumed space needed by the newly grouped pair");
                expect([visible containsObject:@(crowded.selectedIndex)], @"General selection became hidden during prioritized overflow");
                NSRect previous = NSZeroRect;
                for (id layout in crowded.groupLayouts) {
                    NSRect frame = [[layout valueForKey:@"frame"] rectValue];
                    if (NSIsEmptyRect(frame)) continue;
                    expect(NSMinX(frame) >= NSMaxX(previous) && NSMaxX(frame) <= [crowded tabAreaRightWithOverflow:YES]+8,
                           @"prioritized group layout overlapped another group or overflow controls");
                    previous = frame;
                }
                if (count.integerValue == 100 && width.integerValue == 900 && !selectGeneral.boolValue)
                    render_strip(crowded, [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],
                        customFirst.boolValue ? @"/tmp/spdf-group-overflow-left.png" : @"/tmp/spdf-group-overflow-right.png");
            }
        }
}

static void check_group_creation_side(void) {
    for (NSNumber* grouped in @[@NO,@YES]) {
        SPDFGroupTestStrip* strip = [[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,900,42)];
        SPDFGroupFakeReader* reader = [SPDFGroupFakeReader new];
        strip.reader = (id)reader;
        SPDFTabGroup* general = grouped.boolValue ? SPDFTabGroup.generalGroup : nil;
        NSMutableArray* tabs = [NSMutableArray array];
        for (NSInteger i=0;i<66;i++) [tabs addObject:tab(@"Crowded General",general)];
        strip.tabs = (id)tabs;
        strip.selectedIndex = 65;
        NSArray<NSNumber*>* visible = [strip.visibleTabIndexes filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSNumber* index, NSDictionary* _) {
                (void)_; NSRect rect=[strip rectForTabAtIndex:index.integerValue];
                return [strip tabIndexAtPoint:NSMakePoint(NSMidX(rect),NSMidY(rect))]==index.integerValue;
            }]];
        expect(visible.firstObject.integerValue > 33 && visible.count > 1,
               @"placement fixture must show only the trailing half of document indexes");
        expect([strip newGroupGoesBeforeTargetAtIndex:visible.firstObject.integerValue],
               @"leftmost visible tab was positioned using its hidden model index");
        expect(![strip newGroupGoesBeforeTargetAtIndex:visible.lastObject.integerValue],
               @"rightmost visible tab did not keep the new group on the right");
        for (NSNumber* index in @[visible.firstObject,visible.lastObject]) {
            NSMenuItem* item = [NSMenuItem new];
            item.representedObject = index;
            [strip tabContextNewGroup:item];
            expect(reader.createdBeforeTarget == [index isEqual:visible.firstObject],
                   @"context group creation lost its visible-side placement");
            NSRect rect = [strip rectForTabAtIndex:index.integerValue];
            NSPoint point = NSMakePoint(NSMidX(rect),NSMidY(rect));
            NSInteger source = [index isEqual:visible.firstObject] ? visible.lastObject.integerValue : visible.firstObject.integerValue;
            [strip updateGroupDropForPoint:point sourceIndex:source];
            [strip setValue:@(NSDate.timeIntervalSinceReferenceDate-1) forKey:@"groupHoverBegan"];
            [strip updateGroupDropForPoint:point sourceIndex:source];
            expect([strip performGroupDropWithTab:(id)tabs[(NSUInteger)source] sourceIndex:source atPoint:point],
                   @"pair creation drop was not recognized");
            expect(reader.createdBeforeTarget == [index isEqual:visible.firstObject],
                   @"pair drop lost its visible-side placement");
        }
    }
}

static void check_hidden_groups(void) {
    SPDFGroupTestStrip* strip=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,900,42)];
    SPDFTabGroup* general=SPDFTabGroup.generalGroup;
    SPDFTabGroup* custom=[SPDFTabGroup groupWithColor:@"Blue"];
    strip.tabs=(id)@[tab(@"General one",general),tab(@"General two",general),tab(@"Hidden one",custom),tab(@"Hidden two",custom)];
    custom.hidden=YES; strip.selectedIndex=3;
    expect([strip.groupedVisibleTabIndexes isEqual:@[@0,@1]],@"hidden custom tabs consume strip space");
    expect(!strip.groupedHasOverflow && !strip.hiddenTabIndexes.count,@"hidden group leaks into overflow");
    for (id child in strip.accessibilityChildren)
        expect(![[child accessibilityLabel] hasPrefix:@"Hidden"],@"hidden group leaks into strip accessibility");
    general.hidden=YES; strip.tabs=strip.tabs;
    expect(!strip.groupLayouts.count && !strip.visibleTabIndexes.count && !strip.groupedHasOverflow,
        @"all hidden groups leave only controls in the strip");
    expect(strip.tabs.count==4 && strip.selectedIndex==3,@"hiding groups removes tabs or changes selection");
    general.hidden=NO; strip.tabs=strip.tabs;
    expect([strip.groupedVisibleTabIndexes isEqual:@[@0,@1]],@"showing General does not restore its original member order");
}

static void check_compact_workspace_tabs(void) {
    check_group_picker_toggle();
    SPDFGroupTestStrip* strip=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,1050,44)];
    SPDFTabGroup* purple=[SPDFTabGroup groupWithColor:@"Purple"];
    SPDFTabGroup* general=SPDFTabGroup.generalGroup; general.collapsed=YES;
    SPDFTabGroup* hidden=[SPDFTabGroup groupWithColor:@"Teal"]; hidden.hidden=YES;
    strip.tabs=(id)@[tab(@"Interface specification",purple),tab(@"Driver datasheet",purple),
        tab(@"Power review",purple),tab(@"Notes",general),tab(@"Private",hidden)];
    strip.selectedIndex=0;
    NSRect selected=[strip rectForTabAtIndex:0];
    NSRect neighbor=[strip rectForTabAtIndex:1];
    expect([strip tabIndexAtPoint:NSMakePoint(NSMinX(neighbor)+1,NSMidY(neighbor))]==1,
        @"compact tab hit slop overlaps its neighbor's title");
    expect(NSHeight(selected)==24 && NSWidth(selected)<=200,@"compact document tab geometry regressed");
    expect(NSHeight([[layout_for_group(strip,purple) valueForKey:@"header"] rectValue])==20,
        @"group label is not visually smaller than document tabs");
    expect([[strip titleForTabAtIndex:0] isEqual:@"Interface specification"] &&
        [[strip fullTitleForTabAtIndex:0] isEqual:@"Interface specification.pdf"],
        @"strip filename shortening changed its full accessible filename");
    render_strip(strip,[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],@"/tmp/spdf-compact-workspace-tabs.png");
    [strip setValue:@0 forKey:@"hoverTabIndex"];
    expect(NSEqualRects(selected,[strip rectForTabAtIndex:0]),@"close hover changed title geometry");
    render_strip(strip,[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],@"/tmp/spdf-compact-workspace-tabs-hover.png");
    expect([strip valueForKey:@"groupPicker"]==nil,@"group picker allocated before first use");
    NSView* picker=[strip groupPickerContentView];
    expect(NSWidth(picker.frame)==264 && picker.subviews.count==11,@"all-groups picker omitted hidden groups or management");
    SPDFGroupFakeReader* pickerReader=[SPDFGroupFakeReader new]; strip.reader=(id)pickerReader;
    NSUInteger collapses=0;
    for(NSView* child in picker.subviews) if([child isKindOfClass:NSButton.class]) {
        NSButton* button=(NSButton*)child;
        if(button.action==NSSelectorFromString(@"toggleGroupPickerCollapse:")) {
            collapses++; NSInteger before=pickerReader.toggles;
            NSString* label=button.accessibilityLabel;
            [button performClick:nil]; [button performClick:nil];
            expect(pickerReader.toggles==before+2 && [label isEqual:button.accessibilityLabel],
                @"collapse toggle must roundtrip immediately without selecting a document");
        }
        if(button.action==NSSelectorFromString(@"browseGroupPickerRow:"))
            expect(NSWidth(button.frame)==198,@"collapse button stole group title space");
    }
    expect(collapses==3,@"every picker group needs a collapse toggle");
    BOOL hasHidden=NO;
    for (NSView* child in picker.subviews)
        if ([[child accessibilityLabel] containsString:@"hidden"]) hasHidden=YES;
    expect(hasHidden,@"all-groups picker must include hidden groups");
    picker.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSBitmapImageRep* bitmap=[picker bitmapImageRepForCachingDisplayInRect:picker.bounds];
    [picker cacheDisplayInRect:picker.bounds toBitmapImageRep:bitmap];
    expect([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:@"/tmp/spdf-compact-group-picker.png" atomically:YES],@"could not render group picker");
}

static void check_dense_group_controls(void) {
    for (NSNumber* width in @[@620,@900,@1400]) {
        SPDFTabGroup* group=[SPDFTabGroup groupWithColor:@"Purple"];
        SPDFGroupTestStrip* strip=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,width.doubleValue,42)];
        NSMutableArray* tabs=[NSMutableArray array];
        for (NSUInteger i=0;i<40;i++) [tabs addObject:tab(@"Document",group)];
        strip.tabs=(id)tabs; strip.selectedIndex=20;
        NSRect groupFrame=[[strip.groupLayouts.firstObject valueForKey:@"frame"] rectValue];
        NSRect plus=[strip plusRect], manager=[strip overflowRectAssumingVisible];
        expect(fabs(NSMaxX(groupFrame)-[strip tabAreaRightWithOverflow:YES])<0.01,
            @"dense group leaves unused width before trailing controls");
        expect(fabs(NSMinX(plus)-NSMaxX(groupFrame)-8)<0.01 && fabs(NSMinX(manager)-NSMaxX(plus)-6)<0.01,
            @"dense strip plus is not immediately beside group manager");
        expect([strip.visibleTabIndexes containsObject:@20],@"filling dense group hides selected document");
        for (NSNumber* index in strip.visibleTabIndexes)
            expect(NSWidth([strip rectForTabAtIndex:index.integerValue])>=96,@"dense group made titles unreadably narrow");
        expect(!NSIntersectsRect(spdf_tab_strip_control_interaction_rect(plus),spdf_tab_strip_control_interaction_rect(manager)),
            @"adjacent utility control hit targets overlap");
    }
    SPDFTabGroup* exactGroup=[SPDFTabGroup groupWithColor:@"Coral"];
    SPDFGroupTestStrip* exact=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,1000,42)];
    exact.tabs=(id)@[tab(@"One",exactGroup),tab(@"Two",exactGroup),tab(@"Three",exactGroup)]; exact.selectedIndex=0;
    CGFloat contentWidth=NSWidth([[exact.groupLayouts.firstObject valueForKey:@"frame"] rectValue]);
    CGFloat trailing=NSWidth(exact.bounds)-[exact tabAreaRightWithOverflow:YES];
    [exact setFrameSize:NSMakeSize([exact leftInset]+contentWidth+trailing,42)];
    expect(exact.visibleTabIndexes.count==3 && !exact.groupedHasOverflow,
        @"exactly fitting documents lose a tab to an unnecessary overflow button");
    SPDFTabGroup* group=[SPDFTabGroup groupWithColor:@"Teal"];
    SPDFGroupTestStrip* sparse=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,1400,42)];
    sparse.tabs=(id)@[tab(@"One",group),tab(@"Two",group)]; sparse.selectedIndex=0;
    expect(NSWidth([sparse rectForTabAtIndex:0])<=200 && NSMinX([sparse plusRect])<700,
        @"sparse group unnecessarily stretches short document tabs");
}
