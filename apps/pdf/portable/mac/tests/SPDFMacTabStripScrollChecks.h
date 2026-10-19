// Production strip geometry and mouse/wheel delivery, without displaying a window.
static void check_scrollable_group_strip(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1000,44)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    SPDFGroupTestStrip* strip=[[SPDFGroupTestStrip alloc] initWithFrame:window.contentView.bounds];
    SPDFGroupFakeReader* reader=[SPDFGroupFakeReader new]; strip.reader=(id)reader;
    [window.contentView addSubview:strip];
    SPDFTabGroup* before=[SPDFTabGroup groupWithColor:@"Teal"]; before.collapsed=YES;
    SPDFTabGroup* active=[SPDFTabGroup groupWithColor:@"Purple"];
    SPDFTabGroup* after=SPDFTabGroup.generalGroup; after.collapsed=YES;
    NSMutableArray* fixture=[NSMutableArray arrayWithObject:tab(@"Before",before)];
    for (NSUInteger i=0;i<60;i++) [fixture addObject:tab(@"Document",active)];
    [fixture addObject:tab(@"After",after)];
    strip.tabs=(id)fixture; strip.selectedIndex=1;
    NSRect leftHeader=[[layout_for_group(strip,before) valueForKey:@"header"] rectValue];
    NSRect rightHeader=[[layout_for_group(strip,after) valueForKey:@"header"] rectValue];
    expect(!NSIsEmptyRect(leftHeader) && !NSIsEmptyRect(rightHeader) && NSMinX(leftHeader)>=[strip leftInset] && NSMaxX(rightHeader)<=[strip tabAreaRightWithOverflow:YES],
        @"60 documents must not hide the other collapsed group names");
    expect([strip tabScrollHiddenCountOnLeft:YES]==0 && [strip tabScrollHiddenCountOnLeft:NO]>0,
        @"initial strip must expose a right overflow count without a false left count");
    __block NSUInteger changes=0; strip.tabScrollDidChange=^(CGFloat offset) { (void)offset; ++changes; };
    CGEventRef wheel=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,2,0,-120);
    [strip scrollWheel:[NSEvent eventWithCGEvent:wheel]]; CFRelease(wheel);
    expect(strip.tabScrollOffset>0 && changes==1 && reader.selectedTab==0,
        @"two-finger horizontal scroll must move the strip without selecting a document");
    expect([strip tabScrollHiddenCountOnLeft:YES]>0 && [strip tabScrollHiddenCountOnLeft:NO]>0,
        @"middle scroll position must show overflow on both sides");
    expect(NSEqualRects(leftHeader,[[layout_for_group(strip,before) valueForKey:@"header"] rectValue]) &&
        NSEqualRects(rightHeader,[[layout_for_group(strip,after) valueForKey:@"header"] rectValue]),
        @"scrolling document lane displaced a pinned collapsed group name");
    for (NSString* appearance in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
        NSBitmapImageRep* bitmap=render_strip(strip,[NSAppearance appearanceNamed:appearance],
            [@"/tmp/spdf-overflow-underline-" stringByAppendingFormat:@"%@.png",appearance]);
        for (NSNumber* left in @[@YES,@NO]) {
            NSRect badge=[strip tabScrollIndicatorRectOnLeft:left.boolValue];
            for (CGFloat x=NSMinX(badge)+1;x<NSMaxX(badge)-1;x+=2)
                expect(alpha_at(bitmap,NSMakePoint(x,NSHeight(strip.bounds)-5))>240,
                    @"overflow badge interrupts the group underline");
        }
    }
    CGFloat saved=strip.tabScrollOffset;
    strip.tabs=strip.tabs; strip.selectedIndex=strip.selectedIndex; [strip groupLayouts];
    expect(fabs(strip.tabScrollOffset-saved)<.01,@"ordinary refresh reset the user's manual scroll position");
    strip.tabScrollOffset=300; [strip groupLayouts];
    expect(strip.tabScrollOffset==300,@"restored manual scroll unexpectedly revealed the selected document");
    strip.selectedIndex=60; expect([strip.visibleTabIndexes containsObject:@60],@"newly selected trailing document stays offscreen");
    [strip scrollTabStripBy:1e9];
    expect([strip tabScrollHiddenCountOnLeft:YES]>0 && [strip tabScrollHiddenCountOnLeft:NO]==0,
        @"right edge must clamp scrolling and remove its overflow count");
    NSRect indicator=[strip tabScrollIndicatorRectOnLeft:YES];
    NSPoint click=NSMakePoint(NSMidX(indicator),NSMidY(indicator)); CGFloat end=strip.tabScrollOffset;
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,click)];
    expect(strip.tabScrollOffset==end && strip.hiddenListRequests==1 && strip.hiddenListLeft,
        @"left + count must open a list without moving the carousel");
    NSRect viewport=[strip tabViewportRect];
    NSRect expandedFrame=[[layout_for_group(strip,active) valueForKey:@"frame"] rectValue];
    NSRect expandedHeader=[[layout_for_group(strip,active) valueForKey:@"header"] rectValue];
    expect(fabs(NSMinX(viewport)-(NSMaxX(expandedHeader)+12))<.01 &&
        fabs(NSMaxX(viewport)-NSMaxX(expandedFrame))<.01,
        @"overflow indicators reserve blank lane width");
    expect(NSContainsRect(viewport,[strip tabScrollIndicatorRectOnLeft:YES]),@"left indicator is outside the tab lane");
    expect(strip.hiddenMenuBuilds==0,@"layout or scrolling eagerly builds overflow menus");
    NSMenu* list=[strip hiddenTabsMenuOnLeft:YES];
    NSMutableArray<NSNumber*>* listed=[NSMutableArray array];
    for (NSMenuItem* item in list.itemArray) if ([item.representedObject isKindOfClass:NSNumber.class]) {
        [listed addObject:item.representedObject];
    }
    expect((NSInteger)listed.count==[strip tabScrollHiddenCountOnLeft:YES],@"hidden tab list and count disagree");
    expect([listed containsObject:@1] && ![listed containsObject:@60],@"left list includes visible/opposite-side tabs");
    NSMenuItem* first=list.itemArray[1];
    [NSApp sendAction:first.action to:first.target from:first];
    expect(reader.selectedTab==1,@"hidden tab list does not open its chosen document");
    reader.selectedTab=0;
    strip.tabScrollOffset=0; [strip groupLayouts];
    NSRect rightIndicator=[strip tabScrollIndicatorRectOnLeft:NO];
    click=NSMakePoint(NSMidX(rightIndicator),NSMidY(rightIndicator));
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,click)];
    expect(strip.tabScrollOffset==0 && strip.hiddenListRequests==2 && !strip.hiddenListLeft,
        @"right + count must open a list without scrolling");
    expect(NSContainsRect([strip tabViewportRect],rightIndicator),@"right indicator is outside the tab lane");
    expect([strip tabIndexAtPoint:click]==-1 && [strip groupAtPoint:click headerOnly:YES]==nil,
        @"hidden-tabs overlay exposes an underlying hit target");
    [strip updateHoverForPoint:click];
    expect([[strip valueForKey:@"hoverTabIndex"] integerValue]==-1,@"overlay hover exposes an underlying title");
    NSMenu* rightList=[strip hiddenTabsMenuOnLeft:NO];
    expect([rightList.itemArray.lastObject.representedObject isEqual:@60],@"right list omits the final hidden document");
    NSRect header=[[layout_for_group(strip,before) valueForKey:@"header"] rectValue];
    CGFloat expected=MAX(48.0,ceil([before.displayName sizeWithAttributes:
        @{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}].width)+14);
    expect(fabs(NSWidth(header)-expected)<.01,@"group pill reserves space for hidden hover actions");
    NSRect name=NSMakeRect(NSMaxX(header)-40,NSMidY(header)-10,20,20);
    click=NSMakePoint(NSMidX(name),NSMidY(name)); [strip updateHoverForPoint:click];
    render_strip(strip,[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],@"/tmp/spdf-scroll-group-hover.png");
    expect(NSEqualRects(header,[[layout_for_group(strip,before) valueForKey:@"header"] rectValue]),
        @"hover changed group pill geometry");
    [strip handleGroupMouseDown:mouse(window,NSEventTypeLeftMouseDown,click)];
    [strip handleGroupMouseUp:mouse(window,NSEventTypeLeftMouseUp,click)];
    expect(strip.renameRequests==0 && reader.toggles==1,@"removed rename icon still intercepts group-name clicks");
    NSMenuItem* rename=[[strip contextMenuForGroup:before] itemWithTitle:@"Rename Group…"];
    [NSApp sendAction:rename.action to:rename.target from:rename];
    expect(strip.renameRequests==1,@"context-menu rename no longer opens the group prompt");
    NSRect hide=[strip groupHideRect:header]; click=NSMakePoint(NSMidX(hide),NSMidY(hide));
    [strip updateHoverForPoint:click];
    [strip handleGroupMouseDown:mouse(window,NSEventTypeLeftMouseDown,click)];
    [strip handleGroupMouseUp:mouse(window,NSEventTypeLeftMouseUp,click)];
    expect(before.hidden && reader.toggles==1,@"hover eye icon must hide only the intended group");
    NSMenuItem* show=[[strip contextMenuForGroup:before] itemWithTitle:@"Show Group"];
    expect(show!=nil,@"group menu must offer visibility independently of collapse");
    [NSApp sendAction:show.action to:show.target from:show];
    expect(!before.hidden,@"group menu visibility action failed to show group");
    strip.tabs=strip.tabs; render_strip(strip,[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],@"/tmp/spdf-scroll-groups.png");
    expect(!window.visible,@"strip regression must never display a window");
    NSMutableArray* many=[NSMutableArray array];
    for (NSUInteger i=0;i<20;i++) {
        SPDFTabGroup* group=[SPDFTabGroup groupWithColor:@"Teal"]; group.collapsed=YES;
        [many addObject:tab(@"Collapsed",group)];
    }
    strip.tabs=(id)many; strip.tabScrollOffset=0;
    expect(strip.groupLayouts.count==20,@"continuous fallback must retain every non-hidden group");
    [strip scrollTabStripBy:80];
    expect([strip tabScrollHiddenCountOnLeft:YES]>0 && [strip tabScrollHiddenCountOnLeft:NO]>0,
        @"overflowing collapsed headers must be scrollable on both edges");
    expect([strip groupAtPoint:NSMakePoint([strip leftInset]-1,22) headerOnly:YES]==nil,
        @"offscreen group header overlaps traffic-light/window drag territory");
    BOOL scrollAccessible=NO;
    for (NSAccessibilityElement* child in strip.accessibilityChildren)
        if ([child.accessibilityLabel hasPrefix:@"Show tabs to the left"]) {
            NSInteger requests=strip.hiddenListRequests; CGFloat offset=strip.tabScrollOffset;
            expect([child accessibilityPerformPress] && strip.hiddenListRequests==requests+1 &&
                strip.tabScrollOffset==offset,@"VoiceOver overflow action scrolls instead of opening a list");
            scrollAccessible=YES;
        }
    expect(scrollAccessible,@"left hidden-tabs list lacks a VoiceOver action");
    render_strip(strip,[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],@"/tmp/spdf-overlay-collapsed-groups.png");
    NSMenu* collapsedList=[strip hiddenTabsMenuOnLeft:YES];
    expect(collapsedList.numberOfItems>0,@"offscreen collapsed group has no document list");
}

static void benchmark_strip_scrolling(void) {
    for (NSNumber* count in @[@60,@200,@1000]) {
        SPDFGroupTestStrip* strip=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,1000,44)];
        SPDFTabGroup* group=[SPDFTabGroup groupWithColor:@"Purple"];
        NSMutableArray* tabs=[NSMutableArray array];
        for (NSUInteger i=0;i<count.unsignedIntegerValue;i++) [tabs addObject:tab(@"Document",group)];
        strip.tabs=(id)tabs; strip.selectedIndex=0; [strip groupLayouts];
        NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
        for (NSUInteger i=0;i<100;i++) { [strip scrollTabStripBy:i%2 ? -40 : 40]; [strip groupLayouts]; }
        double ms=(NSProcessInfo.processInfo.systemUptime-start)*10;
        NSLog(@"Scroll %@ tabs: %.3f ms per input",count,ms);
        expect(ms<12,@"scroll geometry exceeds a 60fps input budget");
    }
}
