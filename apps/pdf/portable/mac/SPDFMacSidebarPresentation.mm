#import "SPDFMacSidebarPresentation.h"
#import "SPDFSearchSnippet.h"
#import "SPDFMacCollectionStyle.h"

@interface SPDFWorkspaceSidebarRow : NSTableRowView
@property NSTrackingArea* hoverTracking;
@property BOOL hovered;
@end
@implementation SPDFWorkspaceSidebarRow
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTracking) [self removeTrackingArea:self.hoverTracking];
    self.hoverTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTracking];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)event { (void)event; self.hovered = NO; self.needsDisplay = YES; }
- (NSRect)selectionRect { return NSInsetRect(self.bounds,8,2); }
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    if (self.hovered && !self.selected) {
        [SPDFCollectionColor(@"hover") setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.selectionRect xRadius:5 yRadius:5] fill];
    }
}
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [SPDFCollectionColor(@"selected") setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.selectionRect xRadius:5 yRadius:5] fill];
}
- (NSBackgroundStyle)interiorBackgroundStyle { return NSBackgroundStyleNormal; }
@end
NSTableRowView* SPDFSidebarRowView(void) { return [SPDFWorkspaceSidebarRow new]; }
CGFloat SPDFSidebarFindRowHeight(NSDictionary* item) {
    return [item[@"kind"] isEqual:@"findResult"] ? 64 : 28;
}
static NSTextField* Label(NSString* identifier, CGFloat size, BOOL secondary) {
    NSTextField* label = [NSTextField labelWithString:@""];
    label.identifier = identifier; label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:size weight:NSFontWeightRegular];
    label.textColor = SPDFCollectionColor(secondary ? @"secondary" : @"text");
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}
NSTableCellView* SPDFSidebarFindCell(NSTableView* table, NSDictionary* item, NSArray<NSValue*>* matches) {
    NSString* kind = item[@"kind"];
    BOOL result = [kind isEqual:@"findResult"], divider = [kind isEqual:@"findDivider"];
    NSString* identifier = [@"WorkspaceSidebar." stringByAppendingString:kind];
    NSTableCellView* cell = [table makeViewWithIdentifier:identifier owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,240,SPDFSidebarFindRowHeight(item))];
        cell.identifier = identifier;
        NSTextField* text = Label(@"context",divider ? 10 : 12,!result);
        text.maximumNumberOfLines = result ? 2 : 1;
        text.cell.usesSingleLineMode = !result;
        if (result) text.lineBreakMode = NSLineBreakByWordWrapping;
        cell.textField = text; [cell addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:result ? 28 : 16],
            [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-16]]];
        if (result) {
            NSTextField* metadata = Label(@"metadata",10,YES); metadata.maximumNumberOfLines = 1;
            [cell addSubview:metadata];
            [NSLayoutConstraint activateConstraints:@[
                [metadata.leadingAnchor constraintEqualToAnchor:text.leadingAnchor],
                [metadata.trailingAnchor constraintEqualToAnchor:text.trailingAnchor],
                [metadata.topAnchor constraintEqualToAnchor:cell.topAnchor constant:7],
                [text.topAnchor constraintEqualToAnchor:metadata.bottomAnchor constant:3],
                [text.bottomAnchor constraintLessThanOrEqualToAnchor:cell.bottomAnchor constant:-6]]];
        } else {
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor].active = YES;
        }
    }
    NSString* title = item[@"title"] ?: @"";
    if (result) {
        NSArray* anchored = item[@"matchRanges"] ?: matches;
        // A two-line card must show the occurrence before any trailing context.
        // Normalize tabs/paragraph separators so list indentation cannot hide it.
        NSDictionary* snippet=anchored.count ? SPDFSearchSnippet(title,[anchored.firstObject rangeValue],12,72) : nil;
        NSString* display=snippet ? snippet[@"title"] : title;
        NSArray* highlights=snippet ? snippet[@"matchRanges"] : anchored;
        NSMutableParagraphStyle* paragraph = [NSMutableParagraphStyle new]; paragraph.lineBreakMode = NSLineBreakByWordWrapping;
        NSMutableAttributedString* context = [[NSMutableAttributedString alloc] initWithString:display attributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName:SPDFCollectionColor(@"text"),NSParagraphStyleAttributeName:paragraph}];
        for (NSValue* value in highlights) {
            NSRange range = value.rangeValue;
            if (range.location <= context.length && range.length <= context.length-range.location)
                [context addAttribute:NSBackgroundColorAttributeName value:SPDFCollectionColor(@"highlight") range:range];
        }
        cell.textField.attributedStringValue = context;
        for (NSView* view in cell.subviews) if ([view.identifier isEqual:@"metadata"])
            ((NSTextField*)view).stringValue = item[@"subtitle"] ?: @"";
    } else cell.textField.stringValue = divider ? title.uppercaseString : title;
    cell.toolTip = [@[title,item[@"subtitle"] ?: @""] componentsJoinedByString:@"\n"];
    return cell;
}

BOOL SPDFSidebarFitTableToViewport(NSTableView* table) {
    NSClipView* clip = table.enclosingScrollView.contentView;
    NSTableColumn* column = table.tableColumns.firstObject;
    CGFloat width = floor(NSWidth(clip.bounds));
    if (!clip || !column || !isfinite(width) || width < 1) return NO;
    BOOL changed = fabs(column.width-width)>.5 || fabs(NSWidth(table.frame)-width)>.5;
    table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    table.autoresizingMask = NSViewWidthSizable;
    column.minWidth = 0;
    column.width = width;
    [table setFrameSize:NSMakeSize(width,NSHeight(table.frame))];
    if (NSMinX(clip.bounds) != 0) [clip scrollToPoint:NSMakePoint(0,NSMinY(clip.bounds))];
    return changed;
}
