// A group's title tab shows its full name under it on hover, through the same
// panel, position and dismissal as a document tab. The panel is never ordered
// on screen here: NSPanel's ordering is replaced by a recorder.
#import <objc/runtime.h>

static NSInteger gHoverPanelOrders;
static void record_panel_order(id self, SEL _cmd, NSWindowOrderingMode mode, NSInteger other) {
    (void)self, (void)_cmd, (void)mode, (void)other;
    gHoverPanelOrders++;
}

static void keep_hover_panels_off_screen(void) {
    SEL order = @selector(orderWindow:relativeTo:);
    Method method = class_getInstanceMethod(NSPanel.class, order);
    if (!class_addMethod(NSPanel.class, order, (IMP)record_panel_order, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(NSPanel.class, order), (IMP)record_panel_order);
}

// Where the label sits relative to what was hovered, in the strip's window.
static NSRect hover_label_offset(SPDFTabStripView* strip, NSRect hovered) {
    NSPanel* panel = [strip valueForKey:@"hoverPanel"];
    NSRect target = [strip.window convertRectToScreen:[strip convertRect:hovered toView:nil]];
    return NSMakeRect(NSMidX(panel.frame) - NSMidX(target), NSMinY(panel.frame) - NSMinY(target),
                      NSWidth(panel.frame), NSHeight(panel.frame));
}

static NSString* hover_label_text(SPDFTabStripView* strip) {
    return [[strip valueForKey:@"hoverLabel"] stringValue];
}

static BOOL hover_label_shown(SPDFTabStripView* strip) {
    return [[strip valueForKey:@"hoverPanel"] parentWindow] == strip.window;
}

static void check_group_title_hover(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 1100, 42)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    SPDFGroupTestStrip* strip = [[SPDFGroupTestStrip alloc] initWithFrame:window.contentView.bounds];
    SPDFGroupFakeReader* reader = [SPDFGroupFakeReader new];
    strip.reader = (id)reader;
    [window.contentView addSubview:strip];
    NSString* longName = @"Supplier quotes, samples and test reports for the camera flex, revision C";
    SPDFTabGroup* group = [SPDFTabGroup groupWithColor:@"Blue"];
    group.name = longName;
    SPDFTabGroup* general = SPDFTabGroup.generalGroup;
    strip.tabs = (id)@[ tab(@"Interface specification for the camera flex and its connector, revision C", general),
                        tab(@"Quote A", group), tab(@"Quote B", group) ];
    strip.selectedIndex = 0;

    NSRect docRect = [strip rectForTabAtIndex:0];
    NSInteger orders = gHoverPanelOrders;
    [strip updateHoverForPoint:NSMakePoint(NSMidX(docRect), NSMidY(docRect))];
    expect(hover_label_shown(strip) && gHoverPanelOrders == orders + 1, @"document tab hover shows no label");
    NSRect docOffset = hover_label_offset(strip, docRect);
    NSFont* docFont = [[strip valueForKey:@"hoverLabel"] font];

    NSRect header = [[layout_for_group(strip, group) valueForKey:@"header"] rectValue];
    NSDictionary* font = @{NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]};
    expect([longName sizeWithAttributes:font].width > NSWidth(header), @"fixture name must be truncated in its tab");
    NSPoint onHeader = NSMakePoint(NSMidX(header) - 10, NSMidY(header));
    [strip updateHoverForPoint:onHeader];
    expect(hover_label_shown(strip) && [hover_label_text(strip) isEqual:longName],
           [@"group title hover must show the full name, got " stringByAppendingString:hover_label_text(strip) ?: @""]);
    expect([[strip valueForKey:@"hoverTabIndex"] integerValue] == -1, @"group title hover highlights a document tab");
    NSRect groupOffset = hover_label_offset(strip, header);
    expect(fabs(NSMinX(groupOffset)) <= 1 && fabs(NSMinX(docOffset)) <= 1,
           @"group label is not centred under its title tab like a document's");
    expect(NSMinY(groupOffset) == NSMinY(docOffset) && NSHeight(groupOffset) == NSHeight(docOffset),
           @"group label does not sit under its title tab at the document label's distance");
    expect([[[strip valueForKey:@"hoverLabel"] font] isEqual:docFont], @"group label uses a different font");

    // Moving within the title tab keeps the label; leaving to empty strip dismisses it.
    orders = gHoverPanelOrders;
    [strip updateHoverForPoint:NSMakePoint(NSMidX(header) - 4, NSMidY(header))];
    expect(hover_label_shown(strip) && gHoverPanelOrders == orders, @"moving within a title tab re-shows its label");
    NSRect last = [strip rectForTabAtIndex:2];
    [strip updateHoverForPoint:NSMakePoint(NSMaxX(last) + 30, NSMidY(last))];
    expect(!hover_label_shown(strip), @"group label stays after the pointer leaves its title tab");

    // From the title tab straight onto a document tab: that document's label.
    [strip updateHoverForPoint:onHeader];
    NSRect quote = [strip rectForTabAtIndex:1];
    [strip updateHoverForPoint:NSMakePoint(NSMidX(quote), NSMidY(quote))];
    expect(hover_label_shown(strip) && [hover_label_text(strip) isEqual:@"Quote A.pdf"] &&
           [[strip valueForKey:@"hoverTabIndex"] integerValue] == 1,
           [@"document label after group label: " stringByAppendingString:hover_label_text(strip) ?: @""]);
    [strip updateHoverForPoint:onHeader];
    expect([hover_label_text(strip) isEqual:longName], @"document tab to title tab keeps the document's label");
    [strip mouseExited:[NSEvent enterExitEventWithType:NSEventTypeMouseExited location:onHeader modifierFlags:0
        timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL]];
    expect(!hover_label_shown(strip), @"group label stays after the pointer leaves the tab bar");

    // Collapsed: the same label under the collapsed title tab.
    group.collapsed = YES;
    strip.tabs = strip.tabs;
    header = [[layout_for_group(strip, group) valueForKey:@"header"] rectValue];
    [strip updateHoverForPoint:NSMakePoint(NSMidX(header), NSMidY(header))];
    expect(hover_label_shown(strip) && [hover_label_text(strip) isEqual:longName],
           @"collapsed group title hover must show the full name");
    expect(NSMinY(hover_label_offset(strip, header)) == NSMinY(docOffset),
           @"collapsed group label is not where a document label would be");
    [strip dismissHoverPanel];
    expect(!hover_label_shown(strip) && [strip valueForKey:@"hoverGroup"] == nil, @"dismiss leaves the group label");
    expect(!window.visible, @"group hover check must never display a window");
}

// The owner's report (26.10.25-3): in a group whose documents scroll, the pointer between the group's title tab
// and the "+N" badge sat over a document scrolled under the badge and showed that document's label. A label shows
// only over the part of a tab that is drawn; every gap dismisses it at once.
static void check_gap_hover(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 44)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    SPDFGroupTestStrip* strip = [[SPDFGroupTestStrip alloc] initWithFrame:window.contentView.bounds];
    strip.reader = (id)[SPDFGroupFakeReader new];
    [window.contentView addSubview:strip];
    SPDFTabGroup* active = SPDFTabGroup.generalGroup;
    active.collapsed = NO;
    SPDFTabGroup* other = [SPDFTabGroup groupWithColor:@"Teal"];
    other.collapsed = YES;
    NSMutableArray* fixture = [NSMutableArray array];
    for (NSUInteger i = 0; i < 40; i++) [fixture addObject:tab([NSString stringWithFormat:@"Sheet %02lu", (unsigned long)i], active)];
    [fixture addObject:tab(@"Other", other)];
    strip.tabs = (id)fixture;
    strip.selectedIndex = 0;
    NSRect header = [[layout_for_group(strip, active) valueForKey:@"header"] rectValue];
    // Scroll until a document is cut by the left badge.
    NSInteger cut = -1;
    for (int step = 0; step < 200 && cut < 0; step++) {
        [strip scrollTabStripBy:7];
        NSRect badge = [strip tabScrollHiddenCountOnLeft:YES] > 0 ? [strip tabScrollIndicatorRectOnLeft:YES] : NSZeroRect;
        for (NSInteger i = 0; i < 40 && !NSIsEmptyRect(badge); i++) {
            NSRect r = [strip rectForTabAtIndex:i], v = [strip visibleRectForTabAtIndex:i];
            if (NSMinX(r) < NSMaxX(header) && NSWidth(v) >= 40 && NSWidth(v) < NSWidth(r)) cut = i;
        }
    }
    expect(cut >= 0, @"no document scrolled half under the left badge");
    NSRect badge = [strip tabScrollIndicatorRectOnLeft:YES], visible = [strip visibleRectForTabAtIndex:cut];
    expect(NSMinX(visible) >= NSMaxX(badge), @"a tab's visible part reaches under the badge");
    NSPoint onVisible = NSMakePoint(NSMidX(visible), NSMidY(visible));
    NSArray* gaps = @[ [NSValue valueWithPoint:NSMakePoint((NSMaxX(header) + NSMinX(badge)) / 2, NSMidY(badge))],
                       [NSValue valueWithPoint:NSMakePoint(NSMidX(badge), NSMidY(badge))],
                       [NSValue valueWithPoint:NSMakePoint(NSMidX(visible), NSMaxY(visible) + 2)],
                       [NSValue valueWithPoint:NSMakePoint(NSMaxX(visible) + 2, NSMidY(visible))],
                       [NSValue valueWithPoint:NSMakePoint([strip leftInset] - 8, NSMidY(visible))] ];
    for (NSValue* gap in gaps) {
        [strip updateHoverForPoint:onVisible];
        expect(hover_label_shown(strip) && [[strip valueForKey:@"hoverTabIndex"] integerValue] == cut,
               @"the visible part of a cut tab shows no label");
        [strip updateHoverForPoint:gap.pointValue];
        expect(!hover_label_shown(strip) && [[strip valueForKey:@"hoverTabIndex"] integerValue] == -1,
               [@"a label over an empty place at " stringByAppendingString:NSStringFromPoint(gap.pointValue)]);
    }
    // The label hangs under the part of the tab that shows.
    [strip updateHoverForPoint:onVisible];
    expect(fabs(NSMinX(hover_label_offset(strip, visible))) <= 1, @"a cut tab's label is not under its visible part");
    [strip dismissHoverPanel];
    expect(!window.visible, @"gap hover check must never display a window");
}
