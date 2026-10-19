// The conversation's mention overlays: the `@` picker over the composer, and a stranger's card under its link.

#import "mac/SZFriendsItemViewsInternal.h"
#import "mac/SZFriendsMentionViews.h"

// The card's room in the page: the card under its link, and around it a clear layer that takes a click or a scroll
// elsewhere and only closes the card, as a click outside a popover does. WHY not an NSPopover: the dropdown is one
// already, and a frame-laid overlay draws offscreen in tests like every other part of the page.
@interface SZFMentionCardLayer : SZFriendsFlippedView
@property(nonatomic) NSRect anchor; // the link, in the page's coordinates
@property(nonatomic, copy, nullable) void (^onDismiss)(void);
@end

@implementation SZFMentionCardLayer
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onDismiss) self.onDismiss();
}
- (void)rightMouseDown:(NSEvent *)event {
    (void)event;
    if (self.onDismiss) self.onDismiss();
}
// The history would move away from under the card, which points at a link in it.
- (void)scrollWheel:(NSEvent *)event {
    (void)event;
    if (self.onDismiss) self.onDismiss();
}
- (BOOL)isAccessibilityElement {
    return NO;
}
// A soft shadow under the card, drawn here rather than by a layer, so the card lifts off the messages it covers in
// offscreen renders too.
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsFlippedView *card = (SZFriendsFlippedView *)self.subviews.firstObject;
    if (!card) return;
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.3];
    shadow.shadowBlurRadius = 14;
    shadow.shadowOffset = NSMakeSize(0, -4);
    [shadow set];
    [(card.fillColor ?: NSColor.windowBackgroundColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:card.frame xRadius:card.cornerRadius yRadius:card.cornerRadius] fill];
    [NSGraphicsContext restoreGraphicsState];
}
@end

@implementation SZFriendsConversationPage (SZFriendsMentionViews)

- (void)openMentionPicker {
    if (self.mentionPicker || self.composer.hidden || !SZFriendsHelperTakesMentions(self.context)) return;
    [self closeAttachPicker];
    [self closeMentionCard];
    SZFriendsMentionPicker *picker = [[SZFriendsMentionPicker alloc] initWithContext:self.context
                                                                                note:self.composer.mentionNote];
    __weak SZFriendsConversationPage *weakSelf = self;
    picker.onChoose = ^(NSDictionary *row) {
        SZFriendsConversationPage *page = weakSelf;
        NSString *conversationID = SZFStr(row, @"conversation_id");
        if (!page || !conversationID.length) return;
        // The reader's own name for that friend, as the list shows it; the helper writes the mention itself.
        NSString *label = [@"@" stringByAppendingString:SZFStr(row, @"title") ?: @""];
        [page.composer insertMentionForConversation:conversationID label:label];
        [page closeMentionPicker];
    };
    self.mentionPicker = picker;
    [self addSubview:picker];
    [picker start];
    [self layout];
    [self.window makeFirstResponder:picker.searchField];
}

- (void)closeMentionPicker {
    SZFriendsMentionPicker *picker = self.mentionPicker;
    if (!picker) return;
    [picker stop];
    [picker removeFromSuperview];
    self.mentionPicker = nil;
    if (self.window && !self.composer.hidden) [self.window makeFirstResponder:self.composer.textView];
}

- (void)showMentionCard:(NSDictionary *)mention itemID:(NSString *)itemID anchor:(NSRect)anchor {
    if (![SZFStr(mention, @"kind") isEqualToString:@"stranger"] || !SZFDict(mention, @"card")) return;
    // A new card for each click: an answer shown for one person never shows under another's name.
    [self closeMentionPicker];
    [self closeMentionCard];
    SZFMentionCardLayer *layer = [[SZFMentionCardLayer alloc] initWithFrame:self.bounds];
    __weak SZFriendsConversationPage *weakSelf = self;
    layer.onDismiss = ^{ [weakSelf closeMentionCard]; };
    SZFriendsMentionCardView *card = [[SZFriendsMentionCardView alloc] initWithContext:self.context];
    [layer addSubview:card];
    [self addSubview:layer positioned:NSWindowAbove relativeTo:nil];
    self.mentionCard = card;
    card.itemID = itemID;
    [card applyMention:mention];
    ((SZFMentionCardLayer *)card.superview).anchor = anchor;
    [self layout];
    // The keyboard moves to the card's first action; VoiceOver hears that the card appeared.
    if (card.actionButtons.count) [self.window makeFirstResponder:card.actionButtons.firstObject];
    if (self.context.postAccessibility)
        self.context.postAccessibility(card, NSAccessibilityLayoutChangedNotification,
                                       @{NSAccessibilityUIElementsKey : @[ card ]});
}

- (void)closeMentionCard {
    SZFriendsMentionCardView *card = self.mentionCard;
    if (!card) return;
    // The keyboard was on the card (its first action): it goes back to the composer rather than nowhere.
    id responder = self.window.firstResponder;
    BOOL focused = [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:card];
    [card.superview removeFromSuperview];
    self.mentionCard = nil;
    if (focused && !self.composer.hidden) [self.window makeFirstResponder:self.composer.textView];
}

- (void)refreshMentionCard {
    SZFriendsMentionCardView *card = self.mentionCard;
    if (!card) return;
    NSString *url = SZFStr(card.mention, @"url"), *label = SZFStr(card.mention, @"label");
    for (SZFriendsItemView *view in self.itemViews) {
        if (![view.itemID isEqualToString:card.itemID ?: @""]) continue;
        for (id mention in SZFArr(view.item, @"mentions")) {
            if (![SZFStr(mention, @"url") isEqualToString:url] || ![SZFStr(mention, @"label") isEqualToString:label])
                continue;
            // Still someone the reader is not friends with: the card follows (Request sent, Blocked). Otherwise the
            // link now opens a conversation, or nothing, and the card has nothing left to say.
            if ([SZFStr(mention, @"kind") isEqualToString:@"stranger"] && SZFDict(mention, @"card")) {
                [card applyMention:mention];
                self.needsLayout = YES;
                return;
            }
        }
    }
    [self closeMentionCard];
}

- (BOOL)dismissMentionOverlay {
    if (self.mentionCard) {
        [self closeMentionCard];
        return YES;
    }
    if (self.mentionPicker) {
        [self closeMentionPicker];
        return YES;
    }
    return NO;
}

- (void)layoutMentionOverlaysAbove:(CGFloat)composerTop {
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    SZFriendsMentionPicker *picker = self.mentionPicker;
    if (picker) {
        CGFloat pickerWidth = width - 20;
        CGFloat room = MAX(120, composerTop - SZFriendsHeaderHeight - 12);
        CGFloat pickerHeight = MIN([picker heightForWidth:pickerWidth], room);
        picker.frame = NSMakeRect(10, composerTop - pickerHeight - 6, pickerWidth, pickerHeight);
    }
    SZFriendsMentionCardView *card = self.mentionCard;
    SZFMentionCardLayer *layer = (SZFMentionCardLayer *)card.superview;
    if (!card || !layer) return;
    layer.frame = self.bounds;
    CGFloat cardWidth = MIN(300, width - 20), cardHeight = [card heightForWidth:cardWidth];
    NSRect anchor = layer.anchor;
    CGFloat x = MAX(10, MIN(NSMinX(anchor), width - 10 - cardWidth));
    CGFloat y = NSMaxY(anchor) + 6;
    // No room under the link: above it, as a menu would open.
    if (y + cardHeight > height - 10) y = MAX(SZFriendsHeaderHeight + 4, NSMinY(anchor) - 6 - cardHeight);
    card.frame = NSMakeRect(x, y, cardWidth, cardHeight);
    layer.needsDisplay = YES; // its shadow follows the card
}

@end
