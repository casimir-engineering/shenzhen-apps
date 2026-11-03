#import "SPDFMacCommentCards.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacCommentAuthorName.h"
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

// The comment commands' host (SPDFMacCommentActions.h): where the comment editor should open, and your name on
// comments (a card whose author it is lets you change it).
@protocol SPDFCommentCardTarget <NSObject>
- (void)noteCommentEditorAnchorAtWindowPoint:(NSPoint)point;
@optional
- (NSString*)currentCommentAuthor;
- (BOOL)changeCommentAuthorTo:(NSString*)name;
@end

static const CGFloat kPencilPoint = 11, kPencilGap = 3;

// The header line: the author's name, the pencil's place after it on your own cards, then the date and page.
typedef struct {
    NSRect name, pencil;
    NSRect metaRect;
} SPDFCommentCardHeader;

static NSDictionary* NameStyle(void) {
    NSMutableParagraphStyle* truncate = [NSMutableParagraphStyle new];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    return @{NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
             NSForegroundColorAttributeName : SPDFCollectionColor(@"text"), NSParagraphStyleAttributeName : truncate};
}
static NSDictionary* MetaStyle(void) {
    NSMutableParagraphStyle* truncate = [NSMutableParagraphStyle new];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    return @{NSFontAttributeName : [NSFont systemFontOfSize:11], NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary"),
             NSParagraphStyleAttributeName : truncate};
}

// The date and page whole, else the date alone, else nothing: never a date cut in the middle. A long name gives way to
// the date down to 48 points. Space for the hover buttons is kept while they show, and for the pencil on your cards.
static SPDFCommentCardHeader LayoutHeader(NSDictionary* item, SPDFCommentCardLayout l, BOOL hovered, BOOL yours,
                                          NSString* __strong* metaText) {
    SPDFCommentCardHeader h = {};
    CGFloat slot = yours ? ceil(SPDFCommentAuthorPencil(kPencilPoint).size.width) + kPencilGap : 0;
    CGFloat available = NSWidth(l.header) - (hovered ? 2 * kActionSize + kActionGap + 2 : 0) - slot;
    NSString* name = Author(item);
    NSMutableArray* meta = [NSMutableArray array];
    NSString* date = SPDFCommentDateText(item[@"date"], NSDate.date);
    if (date.length) [meta addObject:date];
    if (Text(item, @"meta").length) [meta addObject:Text(item, @"meta")];
    CGFloat natural = ceil([name sizeWithAttributes:NameStyle()].width), nameW = MIN(natural, MAX(0.0, available));
    while (meta.count) {
        CGFloat metaNeed = ceil([[meta componentsJoinedByString:@" · "] sizeWithAttributes:MetaStyle()].width) + 6;
        if (natural + metaNeed <= available) break;
        if (meta.count == 1 && available - metaNeed >= 48) {
            nameW = available - metaNeed;
            break;
        }
        [meta removeLastObject];
    }
    h.name = NSMakeRect(NSMinX(l.header), NSMidY(l.header) - 8, nameW, 16);
    if (yours) h.pencil = NSMakeRect(NSMaxX(h.name) + kPencilGap, NSMinY(l.header), slot - kPencilGap, kHeader);
    CGFloat metaX = NSMaxX(h.name) + slot + 6, metaW = NSMinX(l.header) + available + slot - metaX;
    *metaText = meta.count ? [meta componentsJoinedByString:@" · "] : nil;
    h.metaRect = NSMakeRect(metaX, NSMidY(l.header) - 7.5, metaW, 15);
    return h;
}

@interface SPDFCommentCardView : NSTableCellView
@property(nonatomic, copy) NSDictionary* item;
@property(nonatomic, weak) id target;
@end

@interface SPDFCommentCardRow : NSTableRowView
@end

@implementation SPDFCommentCardView {
    NSTrackingArea* _tracking;
    BOOL _hovered, _yours, _nameHovered;
    SPDFCommentAuthorNameEdit* _nameEdit;
    SPDFCommentAuthorHotspot* _nameSpot;
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
    _nameSpot = [[SPDFCommentAuthorHotspot alloc] initWithFrame:NSZeroRect];
    _nameSpot.hidden = YES;
    __weak SPDFCommentCardView* weakSelf = self;
    _nameSpot.pressed = ^{ [weakSelf beginNameEdit]; };
    _nameSpot.hovered = ^(BOOL over) { [weakSelf setNameHovered:over]; };
    [self addSubview:_nameSpot];
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
    [_nameEdit cancel];
    _yours = [self authorIsYou];
    _nameHovered = NO;
    [self refreshNameArea];
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (BOOL)selected {
    NSView* row = self.superview;
    return [row isKindOfClass:NSTableRowView.class] && ((NSTableRowView*)row).isSelected;
}

// Your comment: written under the name new comments carry now. Agents' and other people's are not.
- (BOOL)authorIsYou {
    NSString* author = Text(_item, @"author");
    if (!author.length || ![_target respondsToSelector:@selector(currentCommentAuthor)] ||
        ![_target respondsToSelector:@selector(changeCommentAuthorTo:)])
        return NO;
    return [author isEqualToString:[(id<SPDFCommentCardTarget>)_target currentCommentAuthor]];
}

- (NSRect)nameArea {
    if (!_yours || !_item) return NSZeroRect;
    NSString* meta = nil;
    SPDFCommentCardHeader h = LayoutHeader(_item, LayoutCard(_item, NSWidth(self.bounds), _quote, _body), _hovered, YES, &meta);
    NSRect name = NSMakeRect(NSMinX(h.name), NSMinY(h.pencil), NSMaxX(h.pencil) - NSMinX(h.name), NSHeight(h.pencil));
    return name;
}

// The name's hotspot follows the name; the card draws the name and, while the pointer is on it, the pencil.
- (void)refreshNameArea {
    NSRect area = _nameEdit ? NSZeroRect : self.nameArea;
    _nameSpot.frame = area;
    _nameSpot.hidden = NSIsEmptyRect(area);
    if (_nameSpot.hidden) _nameHovered = NO;
    self.needsDisplay = YES;
}

- (void)setNameHovered:(BOOL)over {
    if (over == _nameHovered) return;
    _nameHovered = over && !_nameEdit;
    self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self refreshNameArea];
}

// The name becomes a field over the header, left of the hover buttons.
- (void)beginNameEdit {
    if (!_yours || _nameEdit) return;
    SPDFCommentCardLayout l = LayoutCard(_item, NSWidth(self.bounds), _quote, _body);
    CGFloat right = NSMaxX(l.header) - 2 * kActionSize - kActionGap - 4;
    NSRect frame = NSMakeRect(NSMinX(l.header) - 2, NSMidY(l.header) - 9, MAX(60.0, right - NSMinX(l.header) + 2), 18);
    __weak SPDFCommentCardView* weakSelf = self;
    _nameHovered = NO;
    _nameEdit = [SPDFCommentAuthorNameEdit editName:Author(_item)
                                             inView:self
                                              frame:frame
                                               font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                                          alignment:NSTextAlignmentLeft
                                               done:^(NSString* name, BOOL byKey) {
                                                 [weakSelf nameEditEndedWith:name byKey:byKey];
                                               }];
    [self refreshNameArea];
}

- (void)nameEditEndedWith:(NSString*)name byKey:(BOOL)byKey {
    _nameEdit = nil;
    NSTableView* table = (NSTableView*)self.superview.superview;
    if (byKey) [self.window makeFirstResponder:[table isKindOfClass:NSTableView.class] ? table : nil];
    [self refreshNameArea];
    // The panel is rebuilt with the new name: this card stays the old comment's, under the name it was written with.
    if (name) [(id<SPDFCommentCardTarget>)_target changeCommentAuthorTo:name];
}

- (BOOL)isEditingName {
    return _nameEdit != nil;
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
    [self refreshNameArea];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; [self setHovered:YES]; }
- (void)mouseExited:(NSEvent*)event { (void)event; [self setHovered:NO]; [self setNameHovered:NO]; }
- (void)prepareForReuse {
    [super prepareForReuse];
    [_nameEdit cancel];
    [self setHovered:NO];
    [self setNameHovered:NO];
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

    // Header: the author (with the pencil on your own card while the pointer is on the name), then the date and page.
    NSString* meta = nil;
    SPDFCommentCardHeader h = LayoutHeader(_item, l, _hovered, _yours, &meta);
    if (!_nameEdit)
        [Author(_item) drawWithRect:h.name
                            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                         attributes:NameStyle()];
    if (_nameHovered && _yours && !_nameEdit) {
        NSImage* pencil = SPDFCommentAuthorPencil(kPencilPoint);
        NSSize size = pencil.size;
        [pencil drawInRect:NSMakeRect(NSMinX(h.pencil), NSMidY(h.pencil) - size.height / 2, size.width, size.height)];
    }
    if (meta.length && (!_nameEdit))
        [meta drawWithRect:h.metaRect options:NSStringDrawingUsesLineFragmentOrigin attributes:MetaStyle()];

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
