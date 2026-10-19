static void check_empty_tab_groups(void) {
    SPDFGroupTestStrip* strip=[[SPDFGroupTestStrip alloc] initWithFrame:NSMakeRect(0,0,900,42)];
    SPDFGroupFakeReader* reader=[SPDFGroupFakeReader new]; strip.reader=(id)reader;
    SPDFTabGroup* empty=[SPDFTabGroup groupWithColor:@"Mint"]; empty.name=@"Next project";
    strip.tabs=@[]; strip.emptyGroups=@[empty]; strip.selectedIndex=-1;
    expect(strip.tabs.count==0 && [strip hasTabGroups],@"empty group must not manufacture a document tab");
    id layout=layout_for_group(strip,empty);
    expect(layout!=nil && [[layout valueForKey:@"members"] count]==0,@"empty group retains a header layout");
    NSRect header=[[layout valueForKey:@"header"] rectValue];
    expect(!NSIsEmptyRect(header) && [strip groupAtPoint:NSMakePoint(NSMidX(header),NSMidY(header)) headerOnly:YES]==empty,
           @"empty header is a real interaction target");
    BOOL originallyCollapsed=empty.collapsed;
    NSPoint click=NSMakePoint(NSMidX(header),NSMidY(header));
    [strip mouseDown:mouse(nil,NSEventTypeLeftMouseDown,click)];
    [strip mouseUp:mouse(nil,NSEventTypeLeftMouseUp,click)];
    expect(empty.collapsed!=originallyCollapsed && reader.toggles==1,@"empty header press toggles its real group");
    NSArray* children=strip.accessibilityChildren;
    expect([[children valueForKey:@"accessibilityLabel"] containsObject:empty.displayName],@"empty group is accessible");
    NSMenu* menu=[strip contextMenuForGroup:empty];
    expect([menu itemWithTitle:@"Rename Group…"] && [menu itemWithTitle:@"Hide Group"] &&
           [menu itemWithTitle:@"Close Group…"],@"empty group supports the regular group actions");
    [menu performActionForItemAtIndex:[menu indexOfItemWithTitle:@"Close Group…"]];
    expect(reader.closeRequests==1,@"empty group close uses confirmation route");
    NSView* picker=[strip groupPickerContentView]; NSButton* eye=nil; NSButton* collapse=nil; NSButton* row=nil;
    for (NSView* view in picker.subviews) {
        if (![view isKindOfClass:NSButton.class]) continue;
        NSButton* button=(NSButton*)view;
        if ([button.title isEqual:empty.displayName]) row=button;
        if (![button.identifier isEqual:empty.identifier]) continue;
        if (button.action==NSSelectorFromString(@"toggleGroupPickerVisibility:")) eye=button;
        if (button.action==NSSelectorFromString(@"toggleGroupPickerCollapse:")) collapse=button;
    }
    expect(row && eye && collapse && [row.accessibilityLabel containsString:@"0 documents"],@"picker lists empty groups with a zero count");
    [NSApp sendAction:eye.action to:eye.target from:eye];
    expect(empty.hidden,@"empty group picker eye hides the real group");
    strip.emptyGroups=@[empty];
    expect(!layout_for_group(strip,empty),@"updating empty groups invalidates cached layout");
    expect(![[strip.accessibilityChildren valueForKey:@"accessibilityLabel"] containsObject:empty.displayName],
           @"updating empty groups invalidates cached accessibility");
    [NSApp sendAction:row.action to:row.target from:row];
    expect(!empty.hidden,@"picker can reveal an empty group");
    BOOL collapsed=empty.collapsed; [NSApp sendAction:collapse.action to:collapse.target from:collapse];
    expect(empty.collapsed!=collapsed,@"picker toggles empty group disclosure");
    SPDFTabGroup* existing=[SPDFTabGroup groupWithColor:@"Blue"];
    strip.tabs=(id)@[tab(@"Existing",existing)]; empty.collapsed=NO; strip.emptyGroups=@[empty];
    expect([strip.orderedTabGroups.lastObject isEqual:empty],@"empty groups follow populated groups");
    NSMenu* moves=[strip moveToGroupMenuForTabAtIndex:0];
    expect([moves itemWithTitle:empty.displayName]!=nil,@"empty groups are available in Move to Group");
    header=[[layout_for_group(strip,empty) valueForKey:@"header"] rectValue];
    NSPoint center=NSMakePoint(NSMidX(header),NSMidY(header));
    [strip updateGroupDropForPoint:center sourceIndex:0];
    expect([strip performGroupDropWithTab:strip.tabs[0] sourceIndex:0 atPoint:center] && reader.lastDestination==empty,
           @"drop on empty header moves into that group");
    NSMutableArray* crowded=[NSMutableArray array];
    for (NSUInteger i=0;i<20;i++) {
        SPDFTabGroup* group=[SPDFTabGroup groupWithColor:@"Purple"];
        group.name=[NSString stringWithFormat:@"Empty project %lu",(unsigned long)i]; [crowded addObject:group];
    }
    [crowded addObject:empty]; strip.emptyGroups=crowded; strip.selectedIndex=0;
    [strip revealTabGroup:empty];
    header=[[layout_for_group(strip,empty) valueForKey:@"header"] rectValue];
    expect(NSMinX(header)>=[strip leftInset]-.5 && NSMaxX(header)<=[strip tabAreaRightWithOverflow:YES]+.5,
           @"new empty group can be revealed before naming in a crowded strip");
    expect(strip.selectedIndex==0,@"revealing the new group never switches the current document");
    strip.emptyGroups=@[];
    expect(!layout_for_group(strip,empty),@"removing empty group drops its header");
}
