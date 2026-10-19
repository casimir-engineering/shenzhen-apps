#import "SPDFMacIconGeometry.h"
#import "SPDFMacTabStripViewPrivate.h"

// Transient popovers dismiss before the anchor's mouseDown is delivered. Let
// the anchor own that click, otherwise its toggle sees "closed" and reopens it.
@interface SPDFTabGroupPickerPopover : NSPopover
@property(nonatomic, weak) SPDFTabStripView* anchorStrip;
- (BOOL)shouldCloseForEvent:(NSEvent*)event;
@end
@implementation SPDFTabGroupPickerPopover
- (BOOL)shouldCloseForEvent:(NSEvent*)event {
    SPDFTabStripView* strip = self.anchorStrip;
    if (!strip.window || event.window != strip.window ||
        (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeLeftMouseUp)) return YES;
    NSPoint point = [strip convertPoint:event.locationInWindow fromView:nil];
    return !NSPointInRect(point,spdf_tab_strip_control_interaction_rect([strip overflowRect]));
}
- (BOOL)popoverShouldClose:(NSPopover*)popover {
    (void)popover; return [self shouldCloseForEvent:NSApp.currentEvent];
}
@end

@interface SPDFTabGroupPickerContent : NSView
@end
@implementation SPDFTabGroupPickerContent
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
}
@end

@interface SPDFTabGroupPickerRow : NSButton
@property(nonatomic,strong) SPDFTabGroup* group;
@property(nonatomic,copy) NSString* detail;
@end
@implementation SPDFTabGroupPickerRow
- (BOOL)isFlipped { return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea* area in self.trackingAreas.copy) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent*)event { (void)event; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    BOOL hovered = self.window && NSPointInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream
        fromView:nil],self.bounds);
    if (hovered || self.highlighted || (self.group && !self.group.collapsed && !self.group.hidden)) {
        [[NSColor.labelColor colorWithAlphaComponent:0.07] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:5 yRadius:5] fill];
    }
    NSImage* icon = [NSImage imageWithSystemSymbolName:self.group.collectionBackups ? @"books.vertical" : self.group ? @"square.3.layers.3d" : @"slider.horizontal.3"
                            accessibilityDescription:nil];
    NSColor* color = self.group ? spdf_tab_group_accent(self.group.colorName) : NSColor.secondaryLabelColor;
    icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
    SPDFDrawVectorIcon(icon,NSMakeRect(8,8,16,16),YES);
    NSMutableParagraphStyle* paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary* attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:paragraph};
    CGFloat detailWidth = self.detail.length ? [self.detail sizeWithAttributes:attributes].width : 0;
    [self.title drawInRect:NSMakeRect(32,8,NSWidth(self.bounds)-48-detailWidth,16) withAttributes:attributes];
    if (self.detail.length) [self.detail drawInRect:NSMakeRect(NSWidth(self.bounds)-8-detailWidth,8,detailWidth,16)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
    if (self.window.firstResponder == self) {
        [NSColor.keyboardFocusIndicatorColor setStroke];
        NSBezierPath* focus = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:5 yRadius:5];
        focus.lineWidth=2; [focus stroke];
    }
}
@end

static void StylePickerEye(NSButton* button,SPDFTabGroup* group) {
    SPDFConfigureIconButtonRendering(button);
    button.image=[NSImage imageWithSystemSymbolName:group.hidden ? @"eye.slash" : @"eye" accessibilityDescription:nil];
    button.image=SPDFUncachedVectorIcon(button.image); [button.image setTemplate:YES];
    button.contentTintColor=group.hidden ? NSColor.secondaryLabelColor : NSColor.labelColor;
    button.toolTip=group.hidden ? @"Show group in tab bar" : @"Hide group from tab bar";
    button.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",group.hidden ? @"Show" : @"Hide",group.displayName];
}

static void StylePickerCollapse(NSButton* button,SPDFTabGroup* group) {
    SPDFConfigureIconButtonRendering(button);
    button.image=[NSImage imageWithSystemSymbolName:group.collapsed ? @"arrow.left.and.right" : @"arrow.right.and.line.vertical.and.arrow.left" accessibilityDescription:nil];
    button.image=SPDFUncachedVectorIcon(button.image); [button.image setTemplate:YES]; button.contentTintColor=NSColor.labelColor;
    button.toolTip=[NSString stringWithFormat:@"%@ group in tab bar",group.collapsed ? @"Expand" : @"Collapse"];
    button.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",group.collapsed ? @"Expand" : @"Collapse",group.displayName];
}

@implementation SPDFTabStripView (GroupPicker)
- (NSView*)groupPickerContentView {
    NSArray<SPDFTabGroup*>* groups = [self orderedTabGroups];
    NSMutableDictionary<NSString*,NSNumber*>* counts = [NSMutableDictionary dictionary];
    for (SPDFDocumentTab* tab in self.tabs) {
        SPDFTabGroup* group=tab.group;
        if (!group) continue;
        counts[group.identifier]=@([counts[group.identifier] integerValue]+1);
    }
    // Construct only on demand; no extra view tree or model traversal at launch.
    NSView* content = [[SPDFTabGroupPickerContent alloc] initWithFrame:NSMakeRect(0,0,264,groups.count*32+52)];
    CGFloat y=NSHeight(content.bounds)-38;
    for (SPDFTabGroup* group in groups) {
        SPDFTabGroupPickerRow* row=[[SPDFTabGroupPickerRow alloc] initWithFrame:NSMakeRect(6,y,224,32)];
        row.group=group; row.title=group.displayName;
        row.detail=(counts[group.identifier] ?: @0).stringValue;
        row.bordered=NO; row.target=self; row.action=@selector(browseGroupPickerRow:);
        row.accessibilityLabel=[NSString stringWithFormat:@"%@, %@ documents%@",group.displayName,counts[group.identifier] ?: @0,group.hidden ? @", hidden" : @""];
        row.toolTip=[NSString stringWithFormat:@"Show %@ tabs without changing the document",group.displayName];
        row.frame=NSMakeRect(6,y,198,32);
        NSButton* eye=[[NSButton alloc] initWithFrame:NSMakeRect(232,y+4,26,24)];
        eye.bordered=NO; StylePickerEye(eye,group);
        eye.target=self; eye.action=@selector(toggleGroupPickerVisibility:); eye.identifier=group.identifier;
        NSButton* collapse=[[NSButton alloc] initWithFrame:NSMakeRect(204,y+4,26,24)];
        collapse.bordered=NO; StylePickerCollapse(collapse,group);
        collapse.target=self; collapse.action=@selector(toggleGroupPickerCollapse:); collapse.identifier=group.identifier;
        [content addSubview:row]; [content addSubview:collapse]; [content addSubview:eye]; y-=32;
    }
    NSBox* line=[[NSBox alloc] initWithFrame:NSMakeRect(6,40,252,1)]; line.boxType=NSBoxSeparator;
    [content addSubview:line];
    SPDFTabGroupPickerRow* manage=[[SPDFTabGroupPickerRow alloc] initWithFrame:NSMakeRect(6,5,252,32)];
    manage.title=@"Manage groups"; manage.bordered=NO; manage.target=self; manage.action=@selector(manageGroupsFromPicker:);
    [content addSubview:manage];
    return content;
}
- (void)browseGroupPickerRow:(SPDFTabGroupPickerRow*)sender {
    [_groupPicker close];
    SPDFTabGroup* group=sender.group;
    if (group.hidden) [self.groupReader setTabGroup:group hidden:NO];
    if (group.collapsed) [self.groupReader toggleTabGroup:group];
}
- (void)toggleGroupPickerVisibility:(NSButton*)sender {
    for (SPDFTabGroup* group in [self orderedTabGroups]) if ([group.identifier isEqual:sender.identifier]) {
        [self.groupReader setTabGroup:group hidden:!group.hidden];
        StylePickerEye(sender,group);
        return;
    }
}
- (void)toggleGroupPickerCollapse:(NSButton*)sender {
    for (SPDFTabGroup* group in [self orderedTabGroups]) if ([group.identifier isEqual:sender.identifier]) {
        [self.groupReader toggleTabGroup:group];
        // Expanding one group can collapse others; refresh every toggle.
        for (NSView* child in sender.superview.subviews) {
            [child setNeedsDisplay:YES];
            if (![child isKindOfClass:NSButton.class]) continue;
            NSButton* button=(NSButton*)child;
            if (button.action!=@selector(toggleGroupPickerCollapse:)) continue;
            for (SPDFTabGroup* member in [self orderedTabGroups]) if ([member.identifier isEqual:button.identifier]) {
                StylePickerCollapse(button,member); break;
            }
        }
        [sender.superview setNeedsDisplay:YES]; return;
    }
}
- (void)manageGroupsFromPicker:(id)sender {
    [_groupPicker close];
    [NSApp sendAction:NSSelectorFromString(@"showGroupsSidebar:") to:self.reader from:sender];
}
- (BOOL)dismissGroupPickerIfShown {
    if (!_groupPicker.shown) return NO;
    [_groupPicker close]; return YES;
}
- (void)showGroupPicker {
    if (_groupPicker.shown) { [_groupPicker close]; return; }
    [self dismissHoverPanel];
    NSView* content=[self groupPickerContentView];
    NSViewController* controller=[NSViewController new];
    if (NSHeight(content.frame)>420) {
        NSScrollView* scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,264,420)];
        scroll.hasVerticalScroller=YES; scroll.drawsBackground=NO; scroll.documentView=content;
        controller.view=scroll;
        [content scrollPoint:NSMakePoint(0,NSHeight(content.frame)-420)];
    } else controller.view=content;
    SPDFTabGroupPickerPopover* picker=[SPDFTabGroupPickerPopover new]; picker.anchorStrip=self;
    _groupPicker=picker; _groupPicker.behavior=NSPopoverBehaviorTransient;
    _groupPicker.animates=NO; _groupPicker.contentViewController=controller;
    [_groupPicker showRelativeToRect:[self overflowRect] ofView:self preferredEdge:NSRectEdgeMinY];
}
@end
