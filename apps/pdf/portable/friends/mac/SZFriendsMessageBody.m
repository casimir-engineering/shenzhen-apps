// SZFriendsMessageBody: a bubble's words, plain or rendered by the host's Markdown engine. Wide blocks scroll sideways
// inside the bubble, and copying keeps what the friend typed.
//
// WHY one text view with placeholders rather than a stack of views: a person selects across a heading, a list and a
// table as one message, and Copy of the whole message must give its source. A wide block becomes a blank attachment
// as wide as the bubble in that one text view, and a sideways-scrolling strip showing the real block sits over it.

#import "mac/SZFriendsItemViewsInternal.h"
#import "mac/SZFriendsMentionViews.h"

// A few widths and both appearances; a conversation lays out at one width, so more would only hold memory.
static const NSUInteger SZFMaxCachedRenders = 4;

// How much of a message shown as plain text is laid out until the person presses Show all, in UTF-16 units. WHY: text
// layout costs about as much as the text is long, and plain text is what a hostile history falls back to once the
// host's Markdown allowance is spent (SZFriendsHost.h); 4,096 characters lay out in milliseconds, so fifty 32 KB
// messages still open at once. A cut prefers the last space or line break in its final 256 characters.
static const NSUInteger SZFPlainShownLength = 4096;
static const NSUInteger SZFPlainCutLookBack = 256;
static const CGFloat SZFShowAllGap = 6, SZFShowAllHeight = 18;

static NSSize SZFAttachmentSize(NSTextAttachment *attachment) {
    if (!NSIsEmptyRect(attachment.bounds)) return attachment.bounds.size;
    if (attachment.image) return attachment.image.size;
    return attachment.attachmentCell ? attachment.attachmentCell.cellSize : NSZeroSize;
}

BOOL SZFriendsTextMayBeMarkdown(NSString *text) {
    static NSCharacterSet *marks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ marks = [NSCharacterSet characterSetWithCharactersInString:@"*_`#[]|<~$\\&"]; });
    if ([text rangeOfCharacterFromSet:marks].location != NSNotFound) return YES;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSUInteger spaces = 0;
        while (spaces < line.length && [line characterAtIndex:spaces] == ' ') spaces++;
        if (spaces >= 4 || [line hasPrefix:@"\t"]) return YES; // an indented code block
        NSString *rest = [line substringFromIndex:spaces];
        if (rest.length && [@"-+>=" rangeOfString:[rest substringToIndex:1]].location != NSNotFound) return YES;
        NSUInteger digits = 0;
        while (digits < rest.length && [rest characterAtIndex:digits] >= '0' && [rest characterAtIndex:digits] <= '9')
            digits++;
        if (digits && digits < rest.length && ([rest characterAtIndex:digits] == '.' ||
                                               [rest characterAtIndex:digits] == ')'))
            return YES; // "1. " starts a numbered list
    }
    return NO;
}

NSString *SZFriendsMarkdownCopyText(NSAttributedString *rendered, NSRange range, NSString *source) {
    NSString *string = rendered.string;
    range = NSIntersectionRange(range, NSMakeRange(0, string.length));
    if (!range.length) return @"";
    NSCharacterSet *visible = NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet;
    NSRange first = [string rangeOfCharacterFromSet:visible];
    NSRange last = [string rangeOfCharacterFromSet:visible options:NSBackwardsSearch];
    // Everything visible is selected (Select All, or a drag over the whole bubble): the message as it was written.
    if (source.length && first.location != NSNotFound && range.location <= first.location &&
        NSMaxRange(range) >= NSMaxRange(last))
        return source;
    NSMutableString *text = [NSMutableString string];
    NSString *attachmentCharacter = [NSString stringWithFormat:@"%C", (unichar)NSAttachmentCharacter];
    [rendered enumerateAttribute:SZFriendsMarkdownSourceAttributeName inRange:range options:0
                      usingBlock:^(id value, NSRange run, BOOL *stop) {
                          (void)stop;
                          if ([value isKindOfClass:NSString.class]) {
                              [text appendString:value]; // a formula or a diagram is copied whole, never half
                              return;
                          }
                          [text appendString:[[string substringWithRange:run]
                                                 stringByReplacingOccurrencesOfString:attachmentCharacter
                                                                           withString:@""]];
                      }];
    return text;
}

// The first part of a long plain message, cut where a word ends; nil when the whole of it fits.
static NSAttributedString *SZFPlainPrefix(NSAttributedString *text) {
    NSString *string = text.string;
    if (string.length <= SZFPlainShownLength) return nil;
    NSRange tail = NSMakeRange(SZFPlainShownLength - SZFPlainCutLookBack, SZFPlainCutLookBack);
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSRange space = [string rangeOfCharacterFromSet:spaces options:NSBackwardsSearch range:tail];
    NSUInteger cut = space.location != NSNotFound
                         ? space.location
                         : [string rangeOfComposedCharacterSequenceAtIndex:SZFPlainShownLength].location;
    // Nothing but spaces after the cut: Show all would show nothing more.
    if ([string rangeOfCharacterFromSet:spaces.invertedSet options:0
                                  range:NSMakeRange(cut, string.length - cut)].location == NSNotFound)
        return nil;
    while (cut > 0 && [spaces characterIsMember:[string characterAtIndex:cut - 1]]) cut--;
    return [text attributedSubstringFromRange:NSMakeRange(0, cut)];
}

@interface SZFriendsMessageBody () <NSTextViewDelegate>
@end

@implementation SZFriendsMessageBody {
    NSString *_source;
    NSArray *_segments;
    NSArray *_mentions;                               // the item's mentions (PROTOCOL.md § Mentions)
    NSString *_itemID;
    BOOL _expanded;                                   // the person pressed Show all
    BOOL _plainCut;                                   // the plain text shown stops before the message ends
    NSMutableDictionary<NSString *, NSValue *> *_plainSizes; // "width|dark|expanded" -> the plain text's size
    NSSize _plainTextSize;                            // the last one measured, which layout places
    BOOL _wantsMarkdown;
    NSMutableDictionary<NSString *, id> *_renders; // "width|dark" -> the host's rendering, or NSNull when it had none
    id _lastAnswer;                                 // the host's latest answer for this text, at any width
    BOOL _lastAnswerDark;
    NSString *_installedKey;
    NSMutableArray<NSScrollView *> *_strips;
    NSArray<NSNumber *> *_stripIndexes; // the placeholder character under each strip
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 200, 20)])) return nil;
    _context = context;
    _source = @"";
    _renders = [NSMutableDictionary dictionary];
    _strips = [NSMutableArray array];
    _stripIndexes = @[];
    _segments = @[];
    _mentions = @[];
    _plainSizes = [NSMutableDictionary dictionary];
    // WHY a text view for plain text too: it lays the words out and measures them with the same layout manager, once
    // per width, where a label measured them twice with the cell (seconds for a long message) and drew them another
    // way. A 2 pt line padding keeps the label's metrics, so plain bubbles keep their size.
    _plainText = [self makeTextView];
    _plainText.textContainer.lineFragmentPadding = 2;
    _showAllButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleLink appearance:context.appearance];
    _showAllButton.font = context.appearance.secondaryFont;
    _showAllButton.hidden = YES;
    __weak SZFriendsMessageBody *weakSelf = self;
    _showAllButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf showAll];
    };
    [self addSubview:_showAllButton];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(markdownChanged:)
                                               name:SZFriendsMarkdownDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// The host's rendering of this text changed (an image the person asked to load arrived): ask again, at its new size.
- (void)markdownChanged:(NSNotification *)notification {
    if (!_wantsMarkdown || ![notification.object isKindOfClass:NSString.class] ||
        ![notification.object isEqualToString:_source])
        return;
    [_renders removeAllObjects];
    _lastAnswer = nil;
    _installedKey = nil;
    for (NSView *view = self; view; view = view.superview) view.needsLayout = YES;
}

- (BOOL)isFlipped {
    return YES;
}

// Frame-based layout, as SZFriendsFlippedView: a new size places the strips again.
- (void)setFrameSize:(NSSize)newSize {
    BOOL changed = !NSEqualSizes(newSize, self.frame.size);
    [super setFrameSize:newSize];
    if (changed) self.needsLayout = YES;
}

- (void)setEdgeColor:(NSColor *)edgeColor {
    _edgeColor = edgeColor;
    for (SZFriendsWideBlockScrollView *strip in _strips) [strip setFadeColor:edgeColor];
}

- (NSArray<NSScrollView *> *)wideBlocks {
    return [_strips copy];
}

- (void)applyItem:(NSDictionary *)item {
    NSString *text = SZFStr(item, @"text") ?: @"";
    NSArray *segments = SZFArr(item, @"segments");
    if (!segments.count && text.length) segments = @[ @{@"text" : text} ];
    NSArray *mentions = SZFArr(item, @"mentions");
    id<SZFriendsHost> host = _context.host;
    // Every message carries text_format "markdown"; most chat lines have nothing Markdown would draw differently,
    // and skipping the host's engine for them keeps opening a long history cheap. A mention's link source alone is
    // not such a thing: the plain segments draw it as a link too.
    BOOL markdown = [SZFStr(item, @"text_format") isEqualToString:@"markdown"] &&
                    [host respondsToSelector:@selector(friendsRenderMarkdown:width:appearance:)] &&
                    SZFriendsTextMayBeMarkdown(mentions.count ? SZFriendsTextOutsideMentions(segments) : text);
    BOOL mentionsChanged = ![mentions isEqualToArray:_mentions];
    if (![text isEqualToString:_source] || markdown != _wantsMarkdown) {
        [_renders removeAllObjects];
        _lastAnswer = nil;
    }
    if (![text isEqualToString:_source] || markdown != _wantsMarkdown || mentionsChanged) _installedKey = nil;
    BOOL plainChanged = ![text isEqualToString:_source] || ![segments isEqualToArray:_segments] || mentionsChanged;
    _mentions = [mentions copy];
    _itemID = [SZFStr(item, @"item_id") copy];
    if (![text isEqualToString:_source]) _expanded = NO;
    _source = [text copy];
    _segments = [segments copy];
    _wantsMarkdown = markdown;
    // Set whenever the words change (a snapshot repeats the same item often): it is what shows when the host has no
    // rendering for this message.
    if (plainChanged) [self showPlainText];
    self.needsLayout = YES;
}

#pragma mark - Plain text

- (void)showPlainText {
    SZFriendsAppearance *appearance = _context.appearance;
    NSMutableAttributedString *full = [SZFriendsRichText(_segments, appearance.bodyFont,
                                                         appearance.primaryTextColor, appearance) mutableCopy];
    SZFriendsLinkMentionSegments(full, _segments, _mentions);
    SZFriendsStyleMentions(full, _mentions, appearance);
    // Cut only with the catalog's words for the way to the rest: views never invent text, and a cut without a way
    // to read on would hide the message.
    NSString *showAll = [_context string:@"show_all"];
    NSAttributedString *prefix = !_expanded && showAll.length ? SZFPlainPrefix(full) : nil;
    _plainCut = prefix != nil;
    NSMutableAttributedString *shown = [(prefix ?: full) mutableCopy];
    [shown enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, shown.length) options:0
                   usingBlock:^(id value, NSRange range, BOOL *stop) {
                       (void)stop;
                       // The address on hover, as in a rendered message; a click shows it in the link menu.
                       if ([value isKindOfClass:NSURL.class])
                           [shown addAttribute:NSToolTipAttributeName value:[value absoluteString] range:range];
                   }];
    [_plainText.textStorage setAttributedString:shown];
    // Copying everything shown copies the whole message, cut or not.
    ((SZFriendsMarkdownTextView *)_plainText).source = _source;
    _showAllButton.title = showAll;
    _showAllButton.hidden = !_plainCut || _showsMarkdown;
    [_plainSizes removeAllObjects];
}

// Show all: the rest of the message, then a new layout of everything up to the conversation, as the bubble grows.
- (void)showAll {
    if (!_plainCut) return;
    _expanded = YES;
    [self showPlainText];
    for (NSView *view = self; view; view = view.superview) view.needsLayout = YES;
}

// The plain text's size at `width`, laid out once per width and appearance by the text view that draws it.
- (NSSize)plainSizeForWidth:(CGFloat)width {
    NSTextContainer *container = _plainText.textContainer;
    if (container.size.width != width) container.size = NSMakeSize(width, CGFLOAT_MAX);
    NSString *key = [NSString stringWithFormat:@"%.2f|%d|%d", width, [self dark], _expanded];
    NSValue *cached = _plainSizes[key];
    if (cached) {
        _plainTextSize = cached.sizeValue;
    } else {
        NSLayoutManager *layout = _plainText.layoutManager;
        [layout ensureLayoutForTextContainer:container];
        // The lines' own used rects: the container's used rect also holds the extra line fragment after a final line
        // break, which spans the whole width, so "See you Friday.\n" drew as wide as the bubble allows with a blank
        // line inside.
        __block NSRect used = NSZeroRect;
        [layout enumerateLineFragmentsForGlyphRange:[layout glyphRangeForTextContainer:container]
                                         usingBlock:^(NSRect line, NSRect lineUsed, NSTextContainer *inside,
                                                      NSRange glyphs, BOOL *stop) {
                                             (void)line, (void)inside, (void)glyphs, (void)stop;
                                             used = NSIsEmptyRect(used) ? lineUsed : NSUnionRect(used, lineUsed);
                                         }];
        if (NSIsEmptyRect(used)) used = [layout usedRectForTextContainer:container]; // no text: one empty line
        _plainTextSize = NSMakeSize(MIN(width, ceil(NSMaxX(used))), ceil(NSMaxY(used)));
        if (_plainSizes.count >= SZFMaxCachedRenders) [_plainSizes removeAllObjects];
        _plainSizes[key] = [NSValue valueWithSize:_plainTextSize];
    }
    if (!_plainCut) return _plainTextSize;
    CGFloat buttonWidth = MIN(width, [_showAllButton fittingWidth]);
    return NSMakeSize(MAX(_plainTextSize.width, buttonWidth), _plainTextSize.height + SZFShowAllGap + SZFShowAllHeight);
}

- (BOOL)dark {
    return [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                                          NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
}

#pragma mark - Rendering

- (NSAttributedString *)renderedForWidth:(CGFloat)width {
    NSAppearance *appearance = self.effectiveAppearance;
    BOOL dark = [self dark];
    NSString *key = [NSString stringWithFormat:@"%.0f|%d", width, dark];
    id cached = _renders[key];
    // While the width keeps changing, the last answer (or its absence) laid out at this width; kept out of the cache,
    // so the pass at the settled width asks the host. Another appearance needs other colours, so it asks at once.
    if (!cached && _lastAnswer && _lastAnswerDark == dark && _context.reusesMarkdownRenders) cached = _lastAnswer;
    if (cached) return cached == NSNull.null ? nil : cached;
    // Layout asks for heights often; the host renders once per width and appearance (diagrams and math have a cost).
    NSAttributedString *rendered = [_context.host friendsRenderMarkdown:_source width:width appearance:appearance];
    if (_renders.count >= SZFMaxCachedRenders) [_renders removeAllObjects];
    _renders[key] = rendered.length ? [rendered copy] : NSNull.null;
    _lastAnswer = _renders[key];
    _lastAnswerDark = dark;
    return rendered.length ? _renders[key] : nil;
}

// A selectable text view for the bubble's words, laid out by frame; its links answer through the link menu.
- (NSTextView *)makeTextView {
    SZFriendsMarkdownTextView *view = [[SZFriendsMarkdownTextView alloc] initWithFrame:self.bounds];
    view.editable = NO;
    view.selectable = YES;
    view.richText = YES;
    view.drawsBackground = NO;
    view.textContainerInset = NSZeroSize;
    view.textContainer.lineFragmentPadding = 0;
    view.textContainer.widthTracksTextView = NO;
    view.horizontallyResizable = NO;
    view.verticallyResizable = NO;
    // The host's colours and underline stay; the text view only adds the hand cursor over links.
    view.linkTextAttributes = @{NSCursorAttributeName : NSCursor.pointingHandCursor};
    view.delegate = self;
    [self addSubview:view];
    return view;
}

// Installs one rendering: wide blocks become placeholders with a strip each, and links show where they go.
- (void)install:(NSAttributedString *)rendered key:(NSString *)key width:(CGFloat)width {
    if (!_markdownView) _markdownView = [self makeTextView];
    if ([key isEqualToString:_installedKey]) return;
    _installedKey = key;
    for (NSScrollView *strip in _strips) [strip removeFromSuperview];
    [_strips removeAllObjects];
    NSMutableArray *indexes = [NSMutableArray array];
    NSMutableAttributedString *laid = [rendered mutableCopy];
    [rendered enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, rendered.length) options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop) {
                          (void)stop;
                          if (![value isKindOfClass:NSTextAttachment.class] || range.length != 1) return;
                          NSParagraphStyle *style = [rendered attribute:NSParagraphStyleAttributeName
                                                                atIndex:range.location effectiveRange:NULL];
                          CGFloat available = width - MAX(style.headIndent, style.firstLineHeadIndent) -
                                              (style.tailIndent < 0 ? -style.tailIndent : 0);
                          NSSize size = SZFAttachmentSize(value);
                          if (size.width <= available + 0.5 || available < 20) return;
                          // A blank as wide as the line holds the block's place; the strip over it shows the block.
                          NSTextAttachment *placeholder = [NSTextAttachment new];
                          placeholder.image = [NSImage imageWithSize:NSMakeSize(available, size.height) flipped:NO
                                                      drawingHandler:^BOOL(NSRect rect) {
                                                          (void)rect;
                                                          return YES;
                                                      }];
                          placeholder.bounds = NSMakeRect(0, 0, available, size.height);
                          [laid addAttribute:NSAttachmentAttributeName value:placeholder range:range];
                          [indexes addObject:@(range.location)];
                          NSScrollView *strip = [self stripForAttachment:value size:size];
                          ((SZFriendsAttachmentView *)strip.documentView).characterIndex = range.location;
                          [self->_strips addObject:strip];
                      }];
    [rendered enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, rendered.length) options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop) {
                          (void)stop;
                          NSURL *url = [value isKindOfClass:NSURL.class] ? value
                                       : [value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] : nil;
                          // The address on hover too; a click shows it in a menu before anything opens.
                          if (url && SZFriendsLinkMayOpen(url) &&
                              ![rendered attribute:NSToolTipAttributeName atIndex:range.location effectiveRange:NULL])
                              [laid addAttribute:NSToolTipAttributeName value:url.absoluteString range:range];
                      }];
    // Mentions drawn as mentions (a friend's and a stranger's as links, the reader's own highlighted); any other
    // Friends link as its words.
    SZFriendsStyleMentions(laid, _mentions, _context.appearance);
    _stripIndexes = indexes;
    ((SZFriendsMarkdownTextView *)_markdownView).source = _source;
    _markdownView.textContainer.size = NSMakeSize(width, CGFLOAT_MAX);
    [_markdownView.textStorage setAttributedString:laid];
    for (NSScrollView *strip in _strips) [_markdownView addSubview:strip];
    self.needsLayout = YES;
}

- (NSScrollView *)stripForAttachment:(NSTextAttachment *)attachment size:(NSSize)size {
    SZFriendsAttachmentView *block = [[SZFriendsAttachmentView alloc]
        initWithFrame:NSMakeRect(0, 0, ceil(size.width), ceil(size.height))];
    block.attachment = attachment;
    SZFriendsWideBlockScrollView *strip = [[SZFriendsWideBlockScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, 100, ceil(size.height))];
    [strip setFadeColor:self.edgeColor];
    strip.drawsBackground = NO;
    strip.hasHorizontalScroller = YES;
    strip.hasVerticalScroller = NO;
    strip.autohidesScrollers = YES;
    strip.scrollerStyle = NSScrollerStyleOverlay;
    strip.verticalScrollElasticity = NSScrollElasticityNone;
    strip.documentView = block;
    return strip;
}

- (NSSize)sizeForPlainWidth:(CGFloat)plainWidth markdownWidth:(CGFloat)markdownWidth {
    CGFloat width = floor(markdownWidth);
    NSAttributedString *rendered = _wantsMarkdown ? [self renderedForWidth:width] : nil;
    _showsMarkdown = rendered != nil;
    _plainText.hidden = _showsMarkdown;
    _showAllButton.hidden = _showsMarkdown || !_plainCut;
    _markdownView.hidden = !_showsMarkdown;
    if (!rendered) return [self plainSizeForWidth:plainWidth];
    // The rendering itself is part of the key: a reused one and the host's answer at the settled width differ.
    [self install:rendered key:[NSString stringWithFormat:@"%.0f|%d|%p", width, [self dark], rendered] width:width];
    NSLayoutManager *layout = _markdownView.layoutManager;
    [layout ensureLayoutForTextContainer:_markdownView.textContainer];
    NSRect used = [layout usedRectForTextContainer:_markdownView.textContainer];
    // A centred or right-aligned line (display math, a centred figure) sits where the full width put it: a bubble
    // shrunk to its text would show it off-centre, so such a message keeps the full width.
    __block BOOL aligned = NO;
    [rendered enumerateAttribute:NSParagraphStyleAttributeName inRange:NSMakeRange(0, rendered.length) options:0
                      usingBlock:^(NSParagraphStyle *style, NSRange range, BOOL *stop) {
                          (void)range;
                          if (style.alignment != NSTextAlignmentCenter && style.alignment != NSTextAlignmentRight)
                              return;
                          aligned = YES;
                          *stop = YES;
                      }];
    CGFloat natural = aligned ? width : MIN(width, ceil(NSMaxX(used)));
    return NSMakeSize(natural, ceil(NSHeight(used)));
}

#pragma mark - Layout

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _plainText.frame = NSMakeRect(0, 0, width, _plainCut ? _plainTextSize.height : NSHeight(self.bounds));
    _showAllButton.frame = NSMakeRect(0, _plainTextSize.height + SZFShowAllGap,
                                      MIN(width, [_showAllButton fittingWidth]), SZFShowAllHeight);
    if (!_markdownView || _markdownView.hidden) return;
    _markdownView.frame = self.bounds;
    NSLayoutManager *layout = _markdownView.layoutManager;
    NSTextContainer *container = _markdownView.textContainer;
    [layout ensureLayoutForTextContainer:container];
    NSPoint origin = _markdownView.textContainerOrigin;
    for (NSUInteger index = 0; index < _strips.count; index++) {
        NSUInteger character = _stripIndexes[index].unsignedIntegerValue;
        if (character >= _markdownView.textStorage.length) continue;
        NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:character];
        NSRect line = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
        NSPoint location = [layout locationForGlyphAtIndex:glyph]; // y is the baseline within the line
        NSSize size = [layout attachmentSizeForGlyphAtIndex:glyph];
        CGFloat x = origin.x + NSMinX(line) + location.x;
        CGFloat y = origin.y + NSMinY(line) + location.y - size.height;
        _strips[index].frame = NSMakeRect(x, y, MAX(0, MIN(size.width, NSWidth(self.bounds) - x)), size.height);
        [(SZFriendsWideBlockScrollView *)_strips[index] updateFades];
    }
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (!_wantsMarkdown) return;
    // The host's colours are concrete per appearance: draw again, and let every view up to the page lay out anew.
    _installedKey = nil;
    for (NSView *view = self; view; view = view.superview) view.needsLayout = YES;
}

#pragma mark - Links

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex {
    if (SZFriendsIsFriendsLink(link)) {
        SZFriendsOpenMentionLink(_context, link, textView, charIndex, _mentions, _itemID ?: @"");
        return YES; // a Friends link acts only as one of this message's mentions
    }
    // The address first, in a menu that opens it (SZFriendsLinkMenu.m); file: and app schemes show nothing.
    SZFriendsShowLinkMenu(_context, link, textView, charIndex);
    return YES; // handled either way: nothing in a friend's message opens on a click
}

@end
