// Mentions as text: the composer's `@` chips and what Send makes of them, and mention links in a bubble's words.

#import "mac/SZFriendsMentionViews.h"

BOOL SZFriendsHelperTakesMentions(SZFriendsContext *context) {
    return [context.link.helperCapabilities containsObject:@"mentions"];
}

#pragma mark - Chips

// Room around the label inside the pill.
static const CGFloat SZFChipPadding = 4;

// Draws the chip as a pill on the line's baseline. WHY a cell rather than an image: it is drawn in the text view's
// own appearance, so a chip typed in light mode reads right after switching to dark.
@interface SZFMentionChipCell : NSTextAttachmentCell
@property(nonatomic, copy) NSString *label;
@property(nonatomic, strong) NSFont *labelFont;
@property(nonatomic, strong) NSColor *labelColor;
@property(nonatomic, strong) NSColor *pillColor;
@end

@implementation SZFMentionChipCell
- (NSDictionary *)labelAttributes {
    return @{NSFontAttributeName : self.labelFont, NSForegroundColorAttributeName : self.labelColor};
}
- (NSSize)cellSize {
    CGFloat width = ceil([self.label sizeWithAttributes:[self labelAttributes]].width) + 2 * SZFChipPadding;
    return NSMakeSize(width, ceil(self.labelFont.ascender - self.labelFont.descender) + 2);
}
// The pill reaches one point below the descender, so the label inside sits on the line's baseline.
- (NSPoint)cellBaselineOffset {
    return NSMakePoint(0, floor(self.labelFont.descender) - 1);
}
- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    (void)controlView;
    [self.pillColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cellFrame, 0.5, 0) xRadius:4 yRadius:4] fill];
    [self.label drawAtPoint:NSMakePoint(NSMinX(cellFrame) + SZFChipPadding, NSMinY(cellFrame) + 1)
             withAttributes:[self labelAttributes]];
}
- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView characterIndex:(NSUInteger)charIndex {
    (void)charIndex;
    [self drawWithFrame:cellFrame inView:controlView];
}
- (BOOL)wantsToTrackMouse {
    return NO; // a chip is a word of the message: the caret and selection go through it, nothing opens
}
@end

@implementation SZFriendsMentionChip

+ (NSAttributedString *)chipForConversation:(NSString *)conversationID label:(NSString *)label
                                 appearance:(SZFriendsAppearance *)appearance {
    SZFriendsMentionChip *chip = [[SZFriendsMentionChip alloc] initWithData:nil ofType:nil];
    chip->_conversationID = [conversationID copy];
    chip->_label = [label copy];
    SZFMentionChipCell *cell = [SZFMentionChipCell new];
    cell.label = label;
    cell.labelFont = SZFriendsSemibold(appearance.bodyFont);
    cell.labelColor = appearance.accentColor;
    cell.pillColor = [appearance.accentColor colorWithAlphaComponent:0.16];
    cell.accessibilityLabel = label; // VoiceOver reads the name, not "attachment"
    chip.attachmentCell = cell;
    NSMutableAttributedString *text = [[NSAttributedString attributedStringWithAttachment:chip] mutableCopy];
    [text addAttributes:@{NSFontAttributeName : appearance.bodyFont,
                          NSForegroundColorAttributeName : appearance.primaryTextColor}
                  range:NSMakeRange(0, text.length)];
    return text;
}

@end

BOOL SZFriendsTextHoldsMentionChip(NSAttributedString *text) {
    __block BOOL found = NO;
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
                      (void)range;
                      if ([value isKindOfClass:SZFriendsMentionChip.class]) *stop = found = YES;
                  }];
    return found;
}

NSString *SZFriendsComposerMessage(NSAttributedString *text, BOOL helperTakesMentions, NSArray **mentionsOut) {
    NSString *string = text.string;
    NSString *object = [NSString stringWithFormat:@"%C", (unichar)NSAttachmentCharacter];
    BOOL chips = SZFriendsTextHoldsMentionChip(text);
    NSMutableString *message = [NSMutableString stringWithCapacity:string.length];
    NSMutableArray *mentions = [NSMutableArray array];
    for (NSUInteger cursor = 0; cursor < string.length;) {
        NSRange found = [string rangeOfString:object options:NSLiteralSearch
                                        range:NSMakeRange(cursor, string.length - cursor)];
        NSUInteger end = found.location == NSNotFound ? string.length : found.location;
        [message appendString:[string substringWithRange:NSMakeRange(cursor, end - cursor)]];
        if (found.location == NSNotFound) break;
        id attachment = [text attribute:NSAttachmentAttributeName atIndex:found.location effectiveRange:NULL];
        if ([attachment isKindOfClass:SZFriendsMentionChip.class]) {
            SZFriendsMentionChip *chip = attachment;
            // An older helper would send U+FFFC as it is, so the friend reads the name the chip showed instead.
            if (!helperTakesMentions) {
                [message appendString:chip.label];
            } else {
                [message appendString:object];
                [mentions addObject:@{@"conversation_id" : chip.conversationID}];
            }
        } else if (!(helperTakesMentions && chips)) {
            [message appendString:object];
        }
        cursor = NSMaxRange(found);
    }
    *mentionsOut = mentions;
    return message;
}

#pragma mark - Bubbles

static NSString *SZFLinkString(id link) {
    if ([link isKindOfClass:NSURL.class]) return ((NSURL *)link).absoluteString;
    return [link isKindOfClass:NSString.class] ? link : nil;
}

BOOL SZFriendsIsFriendsLink(id link) {
    return [SZFLinkString(link).lowercaseString hasPrefix:@"szfriends:"];
}

NSDictionary *SZFriendsMentionForLink(id link, NSString *words, NSArray *mentions) {
    NSString *destination = SZFLinkString(link);
    if (!destination.length) return nil;
    for (id mention in mentions) {
        NSString *url = SZFStr(mention, @"url"), *label = SZFStr(mention, @"label");
        if (url.length && [url isEqualToString:destination] && [label isEqualToString:words ?: @""]) return mention;
    }
    return nil;
}

static NSInteger SZFMentionIndex(id segment, NSArray *mentions) {
    id value = [segment isKindOfClass:NSDictionary.class] ? segment[@"mention"] : nil;
    if (![value isKindOfClass:NSNumber.class]) return -1;
    NSInteger index = [value integerValue];
    return index >= 0 && index < (NSInteger)mentions.count ? index : -1;
}

NSString *SZFriendsTextOutsideMentions(NSArray *segments) {
    NSMutableString *text = [NSMutableString string];
    for (id segment in segments) {
        // A mention segment stands for one link; "@" keeps the words around it apart, as the label did.
        if ([segment isKindOfClass:NSDictionary.class] && segment[@"mention"]) [text appendString:@"@"];
        else [text appendString:SZFStr(segment, @"text") ?: @""];
    }
    return text;
}

void SZFriendsLinkMentionSegments(NSMutableAttributedString *text, NSArray *segments, NSArray *mentions) {
    NSUInteger offset = 0;
    for (id segment in segments) {
        NSString *words = SZFStr(segment, @"text");
        if (!words.length) continue; // as SZFriendsRichText, which leaves empty segments out
        NSInteger index = SZFMentionIndex(segment, mentions);
        NSString *url = index >= 0 ? SZFStr(mentions[(NSUInteger)index], @"url") : nil;
        if (url.length && offset + words.length <= text.length)
            [text addAttribute:NSLinkAttributeName value:url range:NSMakeRange(offset, words.length)];
        offset += words.length;
    }
}

// What a mention of `kind` does when clicked: a friend's opens their conversation, a stranger's their card.
static BOOL SZFMentionOpens(NSDictionary *mention) {
    NSString *kind = SZFStr(mention, @"kind");
    if ([kind isEqualToString:@"friend"]) return SZFStr(mention, @"conversation_id").length > 0;
    return [kind isEqualToString:@"stranger"] && SZFDict(mention, @"card") != nil;
}

void SZFriendsStyleMentions(NSMutableAttributedString *text, NSArray *mentions, SZFriendsAppearance *appearance) {
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    [text enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
                      (void)stop;
                      if (value) [ranges addObject:[NSValue valueWithRange:range]];
                  }];
    for (NSValue *box in ranges) {
        NSRange range = box.rangeValue;
        id link = [text attribute:NSLinkAttributeName atIndex:range.location effectiveRange:NULL];
        NSDictionary *mention = SZFriendsMentionForLink(link, [text.string substringWithRange:range], mentions);
        if (!mention && !SZFriendsIsFriendsLink(link)) continue; // a web link: the link menu shows where it goes
        BOOL you = [SZFStr(mention, @"kind") isEqualToString:@"you"];
        NSFont *font = [text attribute:NSFontAttributeName atIndex:range.location effectiveRange:NULL];
        [text removeAttribute:NSUnderlineStyleAttributeName range:range];
        [text removeAttribute:NSToolTipAttributeName range:range];
        if (!mention || (!you && !SZFMentionOpens(mention))) {
            // No mention of this message's, or one these views cannot act on: its words, as plain text.
            [text removeAttribute:NSLinkAttributeName range:range];
            [text addAttribute:NSForegroundColorAttributeName value:appearance.primaryTextColor range:range];
            continue;
        }
        [text addAttribute:NSFontAttributeName value:SZFriendsSemibold(font ?: appearance.bodyFont) range:range];
        if (you) {
            // The reader's own name: highlighted so it is found at a glance, with nothing to click.
            [text removeAttribute:NSLinkAttributeName range:range];
            NSColor *highlight = [appearance.accentColor colorWithAlphaComponent:0.22];
            [text addAttributes:@{NSForegroundColorAttributeName : appearance.primaryTextColor,
                                  NSBackgroundColorAttributeName : highlight}
                          range:range];
            continue;
        }
        [text addAttribute:NSForegroundColorAttributeName value:appearance.accentColor range:range];
        NSString *tooltip = SZFStr(mention, @"tooltip");
        if (tooltip.length) [text addAttribute:NSToolTipAttributeName value:tooltip range:range];
    }
}

void SZFriendsOpenMentionLink(SZFriendsContext *context, id link, NSTextView *textView, NSUInteger charIndex,
                              NSArray *mentions, NSString *itemID) {
    NSTextStorage *storage = textView.textStorage;
    if (!context || charIndex >= storage.length) return;
    NSRange range = NSMakeRange(charIndex, 1);
    [storage attribute:NSLinkAttributeName atIndex:charIndex longestEffectiveRange:&range
               inRange:NSMakeRange(0, storage.length)];
    NSDictionary *mention = SZFriendsMentionForLink(link, [storage.string substringWithRange:range], mentions);
    NSString *kind = SZFStr(mention, @"kind");
    if ([kind isEqualToString:@"friend"]) {
        NSString *conversationID = SZFStr(mention, @"conversation_id");
        if (conversationID.length) [context.navigator openConversation:conversationID highlightMessage:nil];
        return;
    }
    if (![kind isEqualToString:@"stranger"]) return;
    SZFriendsConversationPage *page = nil;
    for (NSView *view = textView; view && !page; view = view.superview)
        if ([view isKindOfClass:SZFriendsConversationPage.class]) page = (SZFriendsConversationPage *)view;
    // Under the link's words, where the person is looking (a text view is flipped).
    NSLayoutManager *layout = textView.layoutManager;
    NSRange glyphs = [layout glyphRangeForCharacterRange:range actualCharacterRange:NULL];
    NSRect rect = [layout boundingRectForGlyphRange:glyphs inTextContainer:textView.textContainer];
    rect = NSOffsetRect(rect, textView.textContainerOrigin.x, textView.textContainerOrigin.y);
    if (page) [page showMentionCard:mention itemID:itemID anchor:[textView convertRect:rect toView:page]];
}
