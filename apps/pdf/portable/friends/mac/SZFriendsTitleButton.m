// SZFriendsTitleButton: the Friends button in the host's title bar. Two people (never a speech bubble, which is
// AI chat), the helper's badge, and a drop target that spring-loads the dropdown open.

#import "mac/SZFriendsDropdownInternal.h"

@interface SZFriendsTitleButton ()
@property(nonatomic, readwrite) SZFriendsDropHighlight dropHighlight;
@end

@implementation SZFriendsTitleButton {
    __weak SZFriendsContext *_context;
    SZFriendsDropVerdict _verdict;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    CGFloat side = context.appearance.titleBarButtonSize;
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, side, side)])) return nil;
    _context = context;
    self.theme = context.appearance;
    self.style = SZFriendsButtonStylePlain;
    self.title = @"";
    self.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawPeopleIcon(rect, color); };
    self.iconSize = NSMakeSize(17, 17);
    self.accessibilityLabel = [context string:@"button_label"];
    self.identifier = SZFriendsIdentifierTitleButton; // the host's assistant skips it (SZFriendsUI.h)
    [self registerForDraggedTypes:[SZFriendsDrops draggedTypesForHost:context.host]];
    return self;
}

- (NSSize)intrinsicContentSize {
    CGFloat side = self.theme.titleBarButtonSize;
    return NSMakeSize(side, side);
}

// One color in every state, the host's title-bar icon color, so the button reads as one of the host's own; the
// selection fill and the drop outline mark its states.
- (NSColor *)iconColor {
    return self.theme.titleBarIconColor;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsAppearance *appearance = self.theme;
    NSRect bounds = self.bounds;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1) xRadius:6 yRadius:6];
    if (self.dropHighlight == SZFriendsDropHighlightAccept) {
        [appearance.selectionColor setFill];
        [shape fill];
        [appearance.accentColor setStroke];
        shape.lineWidth = 2;
        [shape stroke];
    } else if (self.selectedLook || self.cell.isHighlighted) {
        [appearance.selectionColor setFill];
        [shape fill];
    } else if (self.hovered) {
        // The title bar's own hover, not the dropdown's: the host's hover token is drawn on panels and nearly
        // matches a light title bar, so this keeps the faint selection tint the title bar has always used.
        [[appearance.selectionColor colorWithAlphaComponent:0.55] setFill];
        [shape fill];
    }
    self.icon([self iconRect], [self iconColor]);
    if (self.badgeLabel.length) SZFriendsDrawBadge(self.badgeLabel, [self badgeRect], [self badgeFont], appearance);
}

- (NSFont *)badgeFont {
    return [NSFont systemFontOfSize:9 weight:NSFontWeightBold];
}

// Inside the button's own frame, in its top-right corner, so the badge is part of its one hit area and never
// overlaps the title bar's draggable space next to it.
- (NSRect)badgeRect {
    if (!self.badgeLabel.length) return NSZeroRect;
    NSRect bounds = self.bounds;
    CGFloat width = MAX(12, SZFriendsTextWidth(self.badgeLabel, [self badgeFont]) + 6);
    return NSMakeRect(NSMaxX(bounds) - width, NSMinY(bounds), width, 12);
}

// Centred; with a badge, nudged down and left so the badge in the corner clears the second figure's head. Covered,
// the two-people icon read as one person, and two people is what tells Friends apart from AI chat.
- (NSRect)iconRect {
    NSRect bounds = self.bounds;
    NSSize icon = self.iconSize;
    NSRect rect = NSMakeRect(floor((NSWidth(bounds) - icon.width) / 2), floor((NSHeight(bounds) - icon.height) / 2),
                             icon.width, icon.height);
    if (!self.badgeLabel.length) return rect;
    NSRect badge = [self badgeRect];
    rect.origin.x -= 3;
    // Down until the head's top meets the badge's bottom, and no further than the button's bottom edge allows.
    CGFloat overlap = NSMaxY(badge) - NSMinY(SZFriendsPeopleIconSecondHeadRect(rect));
    if (overlap > 0) rect.origin.y = MIN(NSMaxY(bounds) - icon.height, rect.origin.y + ceil(overlap));
    return rect;
}

#pragma mark - Drop target

- (BOOL)hostAccepts:(id<NSDraggingInfo>)info {
    id<SZFriendsHost> host = _context.host;
    return ![host respondsToSelector:@selector(friendsButtonAcceptsDrag:)] || [host friendsButtonAcceptsDrag:info];
}

- (SZFriendsDropVerdict)verdictFor:(id<NSDraggingInfo>)info {
    if (![self hostAccepts:info]) return SZFriendsDropVerdictNone;
    return [SZFriendsDrops verdictForPasteboard:info.draggingPasteboard host:_context.host];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    _verdict = [self verdictFor:sender];
    self.dropHighlight = _verdict == SZFriendsDropVerdictAccept ? SZFriendsDropHighlightAccept
                                                                : SZFriendsDropHighlightNone;
    self.needsDisplay = YES;
    return _verdict == SZFriendsDropVerdictAccept ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    (void)sender;
    return _verdict == SZFriendsDropVerdictAccept ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlight = SZFriendsDropHighlightNone;
    self.needsDisplay = YES;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    return _verdict == SZFriendsDropVerdictAccept;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (_verdict != SZFriendsDropVerdictAccept) return NO;
    __weak SZFriendsTitleButton *weakSelf = self;
    [SZFriendsDrops readItemsFromPasteboard:sender.draggingPasteboard host:_context.host
                           promiseDirectory:_context.promiseDirectory
                                 completion:^(NSArray<SZFriendsAttachableItem *> *items, BOOL refusedFolder) {
                                     SZFriendsTitleButton *button = weakSelf;
                                     if (button.onDropItems && !refusedFolder && items.count) button.onDropItems(items);
                                 }];
    return YES;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlight = SZFriendsDropHighlightNone;
    self.needsDisplay = YES;
}

#pragma mark - Spring loading (as Finder folders do)

// Folders spring the dropdown open too, so the refusal shows where the person is looking instead of nothing.
- (NSSpringLoadingOptions)springLoadingEntered:(id<NSDraggingInfo>)draggingInfo {
    BOOL relevant = [self verdictFor:draggingInfo] != SZFriendsDropVerdictNone;
    return relevant ? NSSpringLoadingEnabled : NSSpringLoadingDisabled;
}

- (NSSpringLoadingOptions)springLoadingUpdated:(id<NSDraggingInfo>)draggingInfo {
    return [self springLoadingEntered:draggingInfo];
}

- (void)springLoadingActivated:(BOOL)activated draggingInfo:(id<NSDraggingInfo>)draggingInfo {
    if (!activated) return;
    SZFriendsDropVerdict verdict = [self verdictFor:draggingInfo];
    if (verdict != SZFriendsDropVerdictNone && self.onSpringLoad) self.onSpringLoad(verdict);
}

- (void)springLoadingHighlightChanged:(id<NSDraggingInfo>)draggingInfo {
    (void)draggingInfo;
    self.needsDisplay = YES;
}

@end
