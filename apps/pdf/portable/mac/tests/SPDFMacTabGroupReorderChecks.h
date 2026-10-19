static void check_group_reorder(BOOL useGeneral) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1200,42)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    SPDFGroupTestStrip* strip = [[SPDFGroupTestStrip alloc] initWithFrame:window.contentView.bounds];
    SPDFGroupFakeReader* reader = [SPDFGroupFakeReader new];
    strip.reader = (id)reader;
    [window.contentView addSubview:strip];
    SPDFTabGroup* group = useGeneral ? SPDFTabGroup.generalGroup : [SPDFTabGroup groupWithColor:@"Blue"];
    SPDFTabGroup* other = [SPDFTabGroup groupWithColor:@"Green"];
    strip.tabs = (id)@[tab(@"Moving document",group), tab(@"Second",group), tab(@"Third",group),
                      tab(@"Other group",other)];
    NSMenuItem* rename=[[strip contextMenuForTabAtIndex:1] itemWithTitle:@"Rename Document…"];
    expect(rename && [rename.representedObject isEqual:[strip.tabs[1] path]],
        @"tab context rename must target the clicked document path");
    strip.selectedIndex = 0;
    NSRect first = [strip rectForTabAtIndex:0], second = [strip rectForTabAtIndex:1];
    NSRect third = [strip rectForTabAtIndex:2], outside = [strip rectForTabAtIndex:3];
    NSPoint start = NSMakePoint(NSMinX(first)+28, NSMidY(first));
    NSPoint right = NSMakePoint(NSMaxX(second)-NSWidth(second)*.10, start.y);
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,start)];
    [strip mouseDragged:mouse(window,NSEventTypeLeftMouseDragged,right)];
    expect(strip.isVisuallyReorderingTabs, @"grouped drag did not enable its moving preview");
    expect(fabs(NSMinX([strip visualRectForTabAtIndex:0])-floor(right.x-28)) < 0.1,
           @"moving grouped tab did not preserve the pointer's grab offset");
    expect(NSEqualRects([strip visualRectForTabAtIndex:1],NSOffsetRect(second,-NSWidth(first)-kTabGap,0)), @"rightward drag did not shift sibling left");
    expect(NSEqualRects([strip visualRectForTabAtIndex:2],third), @"uncrossed sibling moved");
    expect(NSEqualRects([strip visualRectForTabAtIndex:3],outside), @"reorder displaced another group's tabs");
    expect(reader.movedToGroup == 0, @"preview committed document order before mouse release");
    [strip updateGroupDropForPoint:right sourceIndex:0];
    expect([strip valueForKey:@"groupDropGroup"] == nil && [[strip valueForKey:@"groupDropTabIndex"] integerValue] < 0,
           @"quick sibling drag changed a reorder into group creation");
    render_strip(strip,[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],
                 useGeneral ? @"/tmp/spdf-group-reorder-general.png" : @"/tmp/spdf-group-reorder-blue.png");
    [strip mouseUp:mouse(window,NSEventTypeLeftMouseUp,right)];
    expect(reader.movedToGroup == 1 && reader.lastDestination == group && reader.lastInsertionIndex == 2,
           @"released tab did not use the previewed insertion position");
    expect(!strip.isVisuallyReorderingTabs && NSEqualRects([strip visualRectForTabAtIndex:1],second),
           @"drop left stale preview geometry");

    right=NSMakePoint(NSMidX(second),start.y);
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,start)];
    for (NSNumber* fraction in @[@.21,@.4,@.6,@.79]) {
        NSPoint middle=NSMakePoint(NSMinX(second)+NSWidth(second)*fraction.doubleValue,start.y);
        [strip mouseDragged:mouse(window,NSEventTypeLeftMouseDragged,middle)];
        expect(NSEqualRects([strip visualRectForTabAtIndex:1],second),
            @"target moved away while crossing the middle three fifths");
    }
    [strip mouseUp:mouse(window,NSEventTypeLeftMouseUp,right)];
    expect(reader.movedToGroup==1 && reader.createdGroups==0,@"unarmed center release must leave order unchanged");
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,start)];
    [strip mouseDragged:mouse(window,NSEventTypeLeftMouseDragged,right)];
    [strip setValue:@(NSDate.timeIntervalSinceReferenceDate-1) forKey:@"groupHoverBegan"];
    [strip updateGroupDropForPoint:right sourceIndex:0];
    expect([[strip valueForKey:@"groupDropTabIndex"] integerValue] == 1,
        @"dwelling over a sibling center must preview a new group");
    expect(NSEqualRects([strip visualRectForTabAtIndex:1],second),@"arming group preview moved the target tab");
    [strip mouseUp:mouse(window,NSEventTypeLeftMouseUp,right)];
    expect(reader.createdGroups == 1,@"sibling center drop must create a named pair");
    reader.createdGroups=0;
    strip.selectedIndex = 2;
    first = [strip rectForTabAtIndex:0]; second = [strip rectForTabAtIndex:1];
    third = [strip rectForTabAtIndex:2];
    start = NSMakePoint(NSMinX(third)+28,NSMidY(third));
    NSPoint left = NSMakePoint(NSMinX(first)+NSWidth(first)*.10,start.y);
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,start)];
    [strip mouseDragged:mouse(window,NSEventTypeLeftMouseDragged,left)];
    expect(NSEqualRects([strip visualRectForTabAtIndex:0],NSOffsetRect(first,NSWidth(third)+kTabGap,0)) &&
           NSEqualRects([strip visualRectForTabAtIndex:1],NSOffsetRect(second,NSWidth(third)+kTabGap,0)), @"leftward drag did not shift siblings right");
    [strip mouseUp:mouse(window,NSEventTypeLeftMouseUp,left)];
    expect(reader.lastInsertionIndex == 0 && reader.createdGroups == 0, @"leftward drop changed group membership");

    strip.selectedIndex = 0;
    first = [strip rectForTabAtIndex:0]; outside = [strip rectForTabAtIndex:3];
    start = NSMakePoint(NSMinX(first)+28,NSMidY(first));
    NSPoint across = NSMakePoint(NSMidX(outside),start.y);
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,start)];
    [strip mouseDragged:mouse(window,NSEventTypeLeftMouseDragged,across)];
    [strip setValue:@(NSDate.timeIntervalSinceReferenceDate-1) forKey:@"groupHoverBegan"];
    [strip updateGroupDropForPoint:across sourceIndex:0];
    expect([strip valueForKey:@"groupDropGroup"] == other && strip.isVisuallyReorderingTabs,
           @"joining another group lost either the destination highlight or moving tab");
    expect(NSEqualRects([strip visualRectForTabAtIndex:3],outside), @"cross-group preview overlapped the group header");
    [strip resetTabDragTracking];
    expect(NSEqualRects([strip visualRectForTabAtIndex:0],first), @"reset did not restore the original tab geometry");

    // A later group's handle means its own first slot, never the preceding
    // group's last tab. Its neighbors must remain outside this preview.
    strip.tabs = (id)@[tab(@"Other first",other),tab(@"Other second",other),
                      tab(@"First",group),tab(@"Second",group),tab(@"Moving",group)];
    strip.selectedIndex = 4;
    NSRect last = [strip rectForTabAtIndex:4];
    NSRect header = [[layout_for_group(strip,group) valueForKey:@"header"] rectValue];
    start = NSMakePoint(NSMinX(last)+28,NSMidY(last));
    left = NSMakePoint(NSMidX(header),NSMidY(header));
    [strip mouseDown:mouse(window,NSEventTypeLeftMouseDown,start)];
    [strip mouseDragged:mouse(window,NSEventTypeLeftMouseDragged,left)];
    expect([[strip valueForKey:@"dragTargetTabIndex"] integerValue] == 2,
           @"dragging onto the source group's handle targeted the previous group");
    expect(NSEqualRects([strip visualRectForTabAtIndex:1],[strip rectForTabAtIndex:1]),
           @"source header reorder displaced the preceding group");
    [strip mouseUp:mouse(window,NSEventTypeLeftMouseUp,left)];
    expect(reader.lastDestination == group && reader.lastInsertionIndex == 2,
           @"source handle drop appended instead of using the group's first slot");
}

