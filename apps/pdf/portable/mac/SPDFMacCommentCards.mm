#import "SPDFMacCommentCards.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacGroupActionButton.h"
#import "SPDFMacIconGeometry.h"

// Geometry, in points. A row is its card plus kRowInsetY above and below, so two cards stand 2 * kRowInsetY apart.
static const CGFloat kRowInsetX = 10, kRowInsetY = 5, kReplyIndent = 22, kPad = 10, kRadius = 8;
static const CGFloat kAvatar = 20, kAvatarGap = 8, kHeader = 20, kActionSize = 20, kActionGap = 2;
static const CGFloat kQuoteGap = 8, kQuoteBar = 2, kQuoteInset = 9, kBodyGapAfterHeader = 7, kBodyGapAfterQuote = 6;
static const CGFloat kBodyLine = 18, kQuoteLine = 16;

static NSString* Text(NSDictionary* item, NSString* key) {
    id value = item[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static NSInteger Level(NSDictionary* item) { return [item[@"level"] respondsToSelector:@selector(integerValue)] ? [item[@"level"] integerValue] : 0; }
static NSInteger QuoteLines(NSDictionary* item) {
    NSInteger lines = [item[@"quoteLines"] respondsToSelector:@selector(integerValue)] ? [item[@"quoteLines"] integerValue] : 2;
    return MAX(1, MIN(2, lines));
}
static NSString* Author(NSDictionary* item) {
    NSString* author = Text(item, @"author");
    return author.length ? author : @"Anonymous";
}

// Fixed line heights make the measured height an exact number of lines, and the same number when drawn.
static NSAttributedString* Paragraph(NSString* text, NSFont* font, NSColor* color, CGFloat lineHeight) {
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByWordWrapping;
    style.minimumLineHeight = style.maximumLineHeight = lineHeight;
    CGFloat natural = font.ascender - font.descender;
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName : font, NSForegroundColorAttributeName : color, NSParagraphStyleAttributeName : style,
        NSBaselineOffsetAttributeName : @(MAX(0.0, floor((lineHeight - natural) / 2.0)))}];
}
static NSString* OneLine(NSString* text) {
    NSArray* words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}
static NSAttributedString* QuoteText(NSDictionary* item) {
    NSString* quote = OneLine(Text(item, @"quote"));
    return quote.length ? Paragraph(quote, [NSFont systemFontOfSize:12], SPDFCollectionColor(@"secondary"), kQuoteLine) : nil;
}
static NSAttributedString* BodyText(NSDictionary* item) {
    NSString* body = [Text(item, @"body") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return body.length ? Paragraph(body, [NSFont systemFontOfSize:13], SPDFCollectionColor(@"text"), kBodyLine) : nil;
}
static CGFloat Measure(NSAttributedString* text, CGFloat width) {
    if (!text.length) return 0;
    NSRect r = [text boundingRectWithSize:NSMakeSize(MAX(1.0, width), CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin];
    return ceil(NSHeight(r));
}

typedef struct {
    NSRect card, avatar, header, quoteBar, quote, body;
    CGFloat height;
} SPDFCommentCardLayout;

// The one layout: SPDFCommentCardRowHeight measures with it and the card draws with it.
static SPDFCommentCardLayout LayoutCard(NSDictionary* item, CGFloat width, NSAttributedString* quote,
                                        NSAttributedString* body) {
    SPDFCommentCardLayout l = {};
    CGFloat cardX = kRowInsetX + (Level(item) > 0 ? kReplyIndent : 0);
    CGFloat cardW = MAX(80.0, width - cardX - kRowInsetX);
    CGFloat innerX = cardX + kPad, innerW = MAX(20.0, cardW - 2 * kPad);
    CGFloat y = kRowInsetY + kPad;
    l.avatar = NSMakeRect(innerX, y, kAvatar, kAvatar);
    l.header = NSMakeRect(innerX + kAvatar + kAvatarGap, y, MAX(0.0, innerW - kAvatar - kAvatarGap), kHeader);
    y += kHeader;
    BOOL reserved = [item[@"quoteReserved"] boolValue];
    if (quote.length || reserved) {
        y += kQuoteGap;
        CGFloat textW = MAX(20.0, innerW - kQuoteBar - kQuoteInset);
        CGFloat h = reserved ? kQuoteLine * QuoteLines(item) : MIN(Measure(quote, textW), kQuoteLine * QuoteLines(item));
        l.quoteBar = NSMakeRect(innerX, y, kQuoteBar, h);
        l.quote = NSMakeRect(innerX + kQuoteBar + kQuoteInset, y, textW, h);
        y += h;
    }
    if (body.length) {
        y += quote.length || reserved ? kBodyGapAfterQuote : kBodyGapAfterHeader;
        CGFloat h = Measure(body, innerW);
        l.body = NSMakeRect(innerX, y, innerW, h);
        y += h;
    }
    y += kPad;
    l.card = NSMakeRect(cardX, kRowInsetY, cardW, y - kRowInsetY);
    l.height = ceil(y + kRowInsetY);
    return l;
}

CGFloat SPDFCommentCardRowHeight(NSDictionary* item, CGFloat width) {
    if (!isfinite(width) || width <= 0) width = 240;
    // Rebuilding the panel makes new items for the same comments, and a sidebar resize asks every row again: cache
    // by what decides the height, so 200 cards are measured once per width.
    static NSCache<NSString*, NSNumber*>* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 4000; });
    BOOL reserved = [item[@"quoteReserved"] boolValue];
    NSString* key = [NSString stringWithFormat:@"%.1f|%ld|%ld|%d|%@|%@", width, (long)Level(item), (long)QuoteLines(item),
                                               reserved, reserved ? @"" : OneLine(Text(item, @"quote")), Text(item, @"body")];
    NSNumber* known = [cache objectForKey:key];
    if (known) return known.doubleValue;
    CGFloat height = LayoutCard(item, width, QuoteText(item), BodyText(item)).height;
    [cache setObject:@(height) forKey:key];
    return height;
}

NSString* SPDFCommentInitials(NSString* author) {
    NSMutableString* initials = [NSMutableString string];
    for (NSString* word in [author ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (!word.length) continue;
        NSRange first = [word rangeOfComposedCharacterSequenceAtIndex:0];
        if (![NSCharacterSet.letterCharacterSet characterIsMember:[word characterAtIndex:0]]) continue;
        [initials appendString:[word substringWithRange:first].uppercaseString];
        if (initials.length >= 2) break;
    }
    return initials.length ? initials : @"?";
}

NSString* SPDFCommentDateText(NSDate* date, NSDate* now) {
    if (![date isKindOfClass:NSDate.class]) return nil;
    NSCalendar* calendar = NSCalendar.currentCalendar;
    static NSDateFormatter *time, *day, *dayYear;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSLocale* locale = NSLocale.autoupdatingCurrentLocale;
      time = [NSDateFormatter new];
      time.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:locale];
      day = [NSDateFormatter new];
      day.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"dMMM" options:0 locale:locale];
      dayYear = [NSDateFormatter new];
      dayYear.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"dMMMy" options:0 locale:locale];
    });
    NSDate* today = [calendar startOfDayForDate:now];
    NSDate* start = [calendar startOfDayForDate:date];
    NSInteger days = [calendar components:NSCalendarUnitDay fromDate:start toDate:today options:0].day;
    if (days == 0) return [@"Today " stringByAppendingString:[time stringFromDate:date]];
    if (days == 1) return [@"Yesterday " stringByAppendingString:[time stringFromDate:date]];
    BOOL sameYear = [calendar component:NSCalendarUnitYear fromDate:date] == [calendar component:NSCalendarUnitYear fromDate:now];
    return sameYear ? [NSString stringWithFormat:@"%@ %@", [day stringFromDate:date], [time stringFromDate:date]]
                    : [dayYear stringFromDate:date];
}

#pragma mark - The card

// The comment commands' host (SPDFMacCommentActions.h): where the comment editor should open.
@protocol SPDFCommentCardTarget <NSObject>
- (void)noteCommentEditorAnchorAtWindowPoint:(NSPoint)point;
@end

@interface SPDFCommentCardView : NSTableCellView
@property(nonatomic, copy) NSDictionary* item;
@property(nonatomic, weak) id target;
@end

@interface SPDFCommentCardRow : NSTableRowView
@end

@implementation SPDFCommentCardView {
    NSTrackingArea* _tracking;
    BOOL _hovered;
    NSButton *_edit, *_delete;
    NSAttributedString *_quote, *_body;
}

static NSButton* ActionButton(NSString* symbol, NSString* label, id target, SEL action) {
    NSButton* button = [SPDFGroupActionButton new];
    button.bordered = NO;
    button.showsBorderOnlyWhileMouseInside = YES;
    button.imagePosition = NSImageOnly;
    button.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightRegular]];
    button.contentTintColor = SPDFCollectionColor(@"secondary");
    button.toolTip = label;
    button.target = target;
    button.action = action;
    button.hidden = YES;
    return button;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.identifier = @"CommentCard";
    _edit = ActionButton(@"pencil", @"Edit Comment", self, @selector(editPressed:));
    _delete = ActionButton(@"trash", @"Delete Comment", self, @selector(deletePressed:));
    [self addSubview:_edit];
    [self addSubview:_delete];
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }

- (void)setItem:(NSDictionary*)item {
    _item = [item copy];
    _quote = QuoteText(_item);
    _body = BodyText(_item);
    BOOL hasIndex = [_item[@"commentIndex"] isKindOfClass:NSNumber.class];
    _edit.enabled = _delete.enabled = hasIndex;
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (BOOL)selected {
    NSView* row = self.superview;
    return [row isKindOfClass:NSTableRowView.class] && ((NSTableRowView*)row).isSelected;
}

- (void)layout {
    [super layout];
    SPDFCommentCardLayout l = LayoutCard(_item, NSWidth(self.bounds), _quote, _body);
    CGFloat y = NSMinY(l.header) + (kHeader - kActionSize) / 2;
    _delete.frame = NSMakeRect(NSMaxX(l.card) - kPad - kActionSize + 4, y, kActionSize, kActionSize);
    _edit.frame = NSOffsetRect(_delete.frame, -(kActionSize + kActionGap), 0);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp |
                                                     NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)setHovered:(BOOL)hovered {
    if (_hovered == hovered) return;
    _hovered = hovered;
    _edit.hidden = _delete.hidden = !hovered;
    self.needsDisplay = YES;
}
- (void)mouseEntered:(NSEvent*)event { (void)event; [self setHovered:YES]; }
- (void)mouseExited:(NSEvent*)event { (void)event; [self setHovered:NO]; }
- (void)prepareForReuse {
    [super prepareForReuse];
    [self setHovered:NO];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    // The attributed strings hold dynamic colors; redraw so they resolve for the new appearance.
    self.needsDisplay = YES;
}

- (void)sendCommand:(SEL)command {
    NSMenuItem* sender = [[NSMenuItem alloc] initWithTitle:@"" action:command keyEquivalent:@""];
    sender.representedObject = _item[@"commentIndex"];
    [NSApp sendAction:command to:_target from:sender];
}
- (void)editPressed:(id)sender {
    (void)sender;
    // The editor opens under this card rather than mid-window.
    if ([_target respondsToSelector:@selector(noteCommentEditorAnchorAtWindowPoint:)]) {
        SPDFCommentCardLayout l = LayoutCard(_item, NSWidth(self.bounds), _quote, _body);
        [(id<SPDFCommentCardTarget>)_target
            noteCommentEditorAnchorAtWindowPoint:[self convertPoint:NSMakePoint(NSMinX(l.card), NSMaxY(l.card))
                                                             toView:nil]];
    }
    [self sendCommand:NSSelectorFromString(@"editComment:")];
}
- (void)deletePressed:(id)sender { (void)sender; [self sendCommand:NSSelectorFromString(@"deleteComment:")]; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (!_item) return;
    BOOL selected = self.selected;
    SPDFCommentCardLayout l = LayoutCard(_item, NSWidth(self.bounds), _quote, _body);

    NSBezierPath* card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(l.card, .5, .5) xRadius:kRadius yRadius:kRadius];
    [SPDFCollectionColor(selected ? @"accentSoft" : @"popover") setFill];
    [card fill];
    [(selected ? [SPDFCollectionColor(@"accent") colorWithAlphaComponent:.6]
               : SPDFCollectionColor(_hovered ? @"lineStrong" : @"line")) setStroke];
    card.lineWidth = 1;
    [card stroke];

    // Avatar: initials on a soft accent disc (solid accent on a selected card, whose fill is the soft accent).
    [SPDFCollectionColor(selected ? @"accentFill" : @"accentSoft") setFill];
    [[NSBezierPath bezierPathWithOvalInRect:l.avatar] fill];
    NSString* initials = SPDFCommentInitials(Text(_item, @"author"));
    NSDictionary* initialsStyle = @{
        NSFontAttributeName : [NSFont systemFontOfSize:initials.length > 1 ? 8.5 : 9.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : SPDFCollectionColor(selected ? @"onAccent" : @"accent")};
    NSSize initialsSize = [initials sizeWithAttributes:initialsStyle];
    [initials drawAtPoint:NSMakePoint(NSMidX(l.avatar) - initialsSize.width / 2, NSMidY(l.avatar) - initialsSize.height / 2)
           withAttributes:initialsStyle];

    // Header: the author, then the date and page, muted. Space for the hover buttons is kept while they show.
    NSMutableParagraphStyle* truncate = [NSMutableParagraphStyle new];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary* nameStyle = @{NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName : SPDFCollectionColor(@"text"),
                                NSParagraphStyleAttributeName : truncate};
    NSDictionary* metaStyle = @{NSFontAttributeName : [NSFont systemFontOfSize:11],
                                NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary"),
                                NSParagraphStyleAttributeName : truncate};
    CGFloat available = NSWidth(l.header) - (_hovered ? 2 * kActionSize + kActionGap + 2 : 0);
    NSString* name = Author(_item);
    NSMutableArray* meta = [NSMutableArray array];
    NSString* date = SPDFCommentDateText(_item[@"date"], NSDate.date);
    if (date.length) [meta addObject:date];
    if (Text(_item, @"meta").length) [meta addObject:Text(_item, @"meta")];
    // The date and page whole, else the date alone, else nothing: never a date cut in the middle. A long name gives
    // way to the date down to 48 points.
    CGFloat natural = ceil([name sizeWithAttributes:nameStyle].width), nameW = MIN(natural, MAX(0.0, available));
    while (meta.count) {
        CGFloat metaNeed = ceil([[meta componentsJoinedByString:@" · "] sizeWithAttributes:metaStyle].width) + 6;
        if (natural + metaNeed <= available) break;
        if (meta.count == 1 && available - metaNeed >= 48) {
            nameW = available - metaNeed;
            break;
        }
        [meta removeLastObject];
    }
    [name drawWithRect:NSMakeRect(NSMinX(l.header), NSMidY(l.header) - 8, nameW, 16)
               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:nameStyle];
    CGFloat metaX = NSMinX(l.header) + nameW + 6, metaW = NSMinX(l.header) + available - metaX;
    if (meta.count)
        [[meta componentsJoinedByString:@" · "] drawWithRect:NSMakeRect(metaX, NSMidY(l.header) - 7.5, metaW, 15)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:metaStyle];

    if (NSHeight(l.quoteBar) > 0) {
        [[SPDFCollectionColor(@"accent") colorWithAlphaComponent:.55] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:l.quoteBar xRadius:1 yRadius:1] fill];
        [_quote drawWithRect:l.quote
                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
    }
    if (_body.length) [_body drawWithRect:l.body options:NSStringDrawingUsesLineFragmentOrigin];
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString*)accessibilityLabel {
    NSMutableArray* parts = [NSMutableArray arrayWithObject:Author(_item)];
    NSString* date = SPDFCommentDateText(_item[@"date"], NSDate.date);
    if (date.length) [parts addObject:date];
    if (_quote.length) [parts addObject:[NSString stringWithFormat:@"on “%@”", _quote.string]];
    if (_body.length) [parts addObject:_body.string];
    return [parts componentsJoinedByString:@", "];
}
@end

@implementation SPDFCommentCardRow
- (void)setSelected:(BOOL)selected {
    BOOL changed = selected != self.isSelected;
    [super setSelected:selected];
    if (changed)
        for (NSView* view in self.subviews) view.needsDisplay = YES;
}
- (void)drawBackgroundInRect:(NSRect)dirtyRect { (void)dirtyRect; }
- (void)drawSelectionInRect:(NSRect)dirtyRect { (void)dirtyRect; }
- (NSBackgroundStyle)interiorBackgroundStyle { return NSBackgroundStyleNormal; }
@end

NSView* SPDFCommentCardCell(NSTableView* table, NSDictionary* item, id target) {
    SPDFCommentCardView* card = [table makeViewWithIdentifier:@"CommentCard" owner:nil];
    if (!card) card = [[SPDFCommentCardView alloc] initWithFrame:NSMakeRect(0, 0, 240, 80)];
    card.target = target;
    card.item = item;
    return card;
}

NSTableRowView* SPDFCommentCardRowView(void) { return [SPDFCommentCardRow new]; }

#pragma mark - Empty state

NSDictionary* SPDFCommentsEmptyItem(NSString* filter) {
    NSString* title = filter.length ? [NSString stringWithFormat:@"No comments match “%@”.", filter]
                                    : @"No comments yet. Select text and choose Add Comment.";
    return @{@"kind" : @"commentsEmpty", @"title" : title, @"page" : @(-1)};
}

static NSAttributedString* EmptyText(NSDictionary* item) {
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    style.minimumLineHeight = style.maximumLineHeight = 17;
    return [[NSAttributedString alloc] initWithString:Text(item, @"title") attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:12], NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary"),
        NSParagraphStyleAttributeName : style}];
}

CGFloat SPDFCommentsEmptyRowHeight(NSDictionary* item, CGFloat width) {
    return Measure(EmptyText(item), MAX(40.0, width - 48)) + 48;
}

@interface SPDFCommentsEmptyView : NSView
@property(nonatomic, copy) NSDictionary* item;
@end
@implementation SPDFCommentsEmptyView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [EmptyText(_item) drawWithRect:NSMakeRect(24, 24, MAX(40.0, NSWidth(self.bounds) - 48), NSHeight(self.bounds) - 48)
                           options:NSStringDrawingUsesLineFragmentOrigin];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityStaticTextRole; }
- (NSString*)accessibilityValue { return Text(_item, @"title"); }
@end

NSView* SPDFCommentsEmptyCell(NSTableView* table, NSDictionary* item) {
    SPDFCommentsEmptyView* view = [table makeViewWithIdentifier:@"CommentsEmpty" owner:nil];
    if (!view) {
        view = [[SPDFCommentsEmptyView alloc] initWithFrame:NSMakeRect(0, 0, 240, 80)];
        view.identifier = @"CommentsEmpty";
    }
    view.item = item;
    view.needsDisplay = YES;
    return view;
}
