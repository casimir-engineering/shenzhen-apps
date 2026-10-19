#import "SPDFMacChatMarkdownView.h"

#import "SPDFMacChatMarkdownParts.h"
#import "markdown/SPDFMarkdownDiagram.h"

// A block wider than the bubble keeps its natural size in the text (SPDFMacChatMarkdown.h); this view lays a strip
// over it that scrolls sideways, drawing the same attachment cell and passing it the clicks (links, Copy).

// The bubble's colour fading in at a strip's edge while more of the block lies beyond it: overlay scrollers stay
// hidden until scrolled, and a table cut off at a column boundary otherwise looks complete.
@interface SPDFMacChatStripFade : NSView
@property(nonatomic) BOOL trailing;
@property(nonatomic, strong) NSColor* color;
@end
@implementation SPDFMacChatStripFade
- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;  // clicks and swipes belong to the strip beneath
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSColor* solid = self.color ?: NSColor.clearColor;
    [[[NSGradient alloc] initWithStartingColor:[solid colorWithAlphaComponent:0] endingColor:solid]
        drawInRect:self.bounds angle:self.trailing ? 0 : 180];
}
@end

@interface SPDFMacChatStripScrollView : NSScrollView
@property(nonatomic, strong) SPDFMacChatStripFade* leadingFade;
@property(nonatomic, strong) SPDFMacChatStripFade* trailingFade;
@end
@implementation SPDFMacChatStripScrollView
- (void)updateFades {
    if (!self.leadingFade) {
        self.leadingFade = [SPDFMacChatStripFade new];
        self.trailingFade = [SPDFMacChatStripFade new];
        self.trailingFade.trailing = YES;
    }
    // Above the clip view, re-added when AppKit retiles the scroll view's subviews.
    for (NSView* fade in @[ self.leadingFade, self.trailingFade ])
        if (fade.superview != self || self.subviews.lastObject != self.trailingFade) [self addSubview:fade];
    CGFloat x = NSMinX(self.contentView.bounds);
    CGFloat end = NSWidth(self.documentView.frame) - NSWidth(self.contentView.bounds);
    CGFloat width = MIN(18, NSWidth(self.bounds) / 4);
    self.leadingFade.frame = NSMakeRect(0, 0, width, NSHeight(self.bounds));
    self.trailingFade.frame = NSMakeRect(NSWidth(self.bounds) - width, 0, width, NSHeight(self.bounds));
    self.leadingFade.hidden = x <= .5;
    self.trailingFade.hidden = x >= end - .5;
    for (SPDFMacChatStripFade* fade in @[ self.leadingFade, self.trailingFade ]) {
        fade.color = self.backgroundColor;
        fade.needsDisplay = YES;
    }
}
- (void)tile {
    [super tile];
    [self updateFades];
}
- (void)reflectScrolledClipView:(NSClipView*)clipView {
    [super reflectScrolledClipView:clipView];
    [self updateFades];
    // A code block's language and Copy stay in view as its long lines scroll by.
    id cell = [(id)self.documentView attachment].attachmentCell;
    if ([cell respondsToSelector:@selector(setHeaderOffset:)]) {
        [cell setHeaderOffset:NSMinX(clipView.bounds)];
        self.documentView.needsDisplay = YES;
    }
}
// The strip scrolls sideways only; an upward or downward swipe over it still scrolls the transcript.
- (void)scrollWheel:(NSEvent*)event {
    if (fabs(event.scrollingDeltaY) > fabs(event.scrollingDeltaX)) [self.nextResponder scrollWheel:event];
    else [super scrollWheel:event];
}
@end

@interface SPDFMacChatStripContent : NSView
@property(nonatomic, strong) NSTextAttachment* attachment;
@property(nonatomic) NSUInteger characterIndex;
@property(nonatomic, weak) NSTextView* textView;
@end
@implementation SPDFMacChatStripContent
- (BOOL)isFlipped { return YES; }
- (BOOL)isAccessibilityElement { return NO; }  // the text view already reads the message, this block included
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    id<NSTextAttachmentCell> cell = self.attachment.attachmentCell;
    if (cell) [cell drawWithFrame:self.bounds inView:self];
    else [self.attachment.image drawInRect:self.bounds];
}
- (void)mouseDown:(NSEvent*)event {
    id<NSTextAttachmentCell> cell = self.attachment.attachmentCell;
    if ([cell wantsToTrackMouseForEvent:event inRect:self.bounds ofView:self atCharacterIndex:self.characterIndex]) {
        [cell trackMouse:event inRect:self.bounds ofView:self atCharacterIndex:self.characterIndex untilMouseUp:YES];
        return;
    }
    // Anything else selects the block like the text around it.
    [self.textView setSelectedRange:NSMakeRange(self.characterIndex, 1)];
    [self.window makeFirstResponder:self.textView];
}
@end

@implementation SPDFMacChatMarkdownView {
    SPDFMacChatMarkdownOptions* _options;
    NSMutableArray<NSScrollView*>* _strips;
    CGFloat _renderedWidth;
    BOOL _renderedDark;
    BOOL _measurementScheduled;
}

- (instancetype)initWithMarkdown:(NSString*)markdown width:(CGFloat)width options:(SPDFMacChatMarkdownOptions*)options {
    return [self initWithMarkdown:markdown width:width options:options textInset:NSMakeSize(10, 8)];
}

- (instancetype)initWithMarkdown:(NSString*)markdown
                           width:(CGFloat)width
                         options:(SPDFMacChatMarkdownOptions*)options
                       textInset:(NSSize)inset {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, MAX(120, width), 40)])) return nil;
    _markdown = [markdown copy] ?: @"";
    _options = [options copy];
    // One diagram cache per message: a width change re-lays out its diagrams, an appearance change reuses them.
    if (!_options.diagramCache) _options.diagramCache = [SPDFMarkdownDiagramCache new];
    _strips = [NSMutableArray array];
    self.editable = NO;
    self.selectable = YES;
    self.drawsBackground = NO;
    self.verticallyResizable = NO;
    self.horizontallyResizable = NO;
    self.textContainerInset = NSMakeSize(MAX(0, inset.width), MAX(0, inset.height));
    self.textContainer.lineFragmentPadding = 0;
    self.textContainer.widthTracksTextView = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self renderNow];
    _contentHeight = [self.heightAnchor constraintEqualToConstant:[self measuredHeight]];
    return self;
}

- (NSArray<NSScrollView*>*)wideBlocks { return [_strips copy]; }

- (BOOL)isDark {
    return [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                                            NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)renderNow {
    SPDFMacChatMarkdownOptions* options = [_options copy];
    _renderedWidth = NSWidth(self.bounds);
    _renderedDark = [self isDark];
    options.width = MAX(100, _renderedWidth - 2 * self.textContainerInset.width);
    options.dark = _renderedDark;
    if (!_options.messageKey) options.messageKey = _markdown;
    __weak SPDFMacChatMarkdownView* weakSelf = self;
    // A loaded image gets its own size: render again and let the transcript take the new height.
    options.imageFinished = ^{
      SPDFMacChatMarkdownView* view = weakSelf;
      if (!view) return;
      [view renderNow];
      [view updateHeight];
    };
    // A link inside a table or diagram follows the same rules as one in the text: the delegate decides.
    if (!options.openLink) options.openLink = ^(NSURL* URL) {
      SPDFMacChatMarkdownView* view = weakSelf;
      if ([view.delegate respondsToSelector:@selector(textView:clickedOnLink:atIndex:)])
          [view.delegate textView:view clickedOnLink:URL atIndex:0];
    };
    self.linkTextAttributes = @{NSForegroundColorAttributeName : options.linkColor,
                                NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle),
                                NSCursorAttributeName : NSCursor.pointingHandCursor};
    // A re-render for a new width or appearance gives the same characters: keep what the chat's search highlighted
    // (temporary attributes, which replacing the text clears) and what the person selected.
    NSAttributedString* rendered = SPDFMacChatMarkdownRender(_markdown, options);
    BOOL same = [rendered.string isEqualToString:self.textStorage.string];
    NSMutableArray<NSArray*>* highlights = [NSMutableArray array];
    NSRange selection = self.selectedRange;
    if (same && rendered.length) {
        NSRange all = NSMakeRange(0, rendered.length), found;
        for (NSUInteger index = 0; index < all.length; index = MAX(NSMaxRange(found), index + 1)) {
            id color = [self.layoutManager temporaryAttribute:NSBackgroundColorAttributeName atCharacterIndex:index
                                            longestEffectiveRange:&found inRange:all];
            if (color) [highlights addObject:@[ color, [NSValue valueWithRange:found] ]];
        }
    }
    [self.textStorage setAttributedString:rendered];
    for (NSArray* highlight in highlights)
        [self.layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName value:highlight[0]
                                forCharacterRange:[highlight[1] rangeValue]];
    if (same && NSMaxRange(selection) <= rendered.length) self.selectedRange = selection;
    self.textContainer.containerSize = NSMakeSize(options.width, CGFLOAT_MAX);
    [self.layoutManager ensureLayoutForTextContainer:self.textContainer];
    [self placeStrips];
}

- (CGFloat)measuredHeight {
    CGFloat used = ceil(NSMaxY([self.layoutManager usedRectForTextContainer:self.textContainer]));
    return MAX(18, used) + 2 * self.textContainerInset.height;
}

- (void)updateHeight {
    CGFloat height = [self measuredHeight];
    if (fabs(height - self.contentHeight.constant) > .5) {
        self.contentHeight.constant = height;
        self.superview.needsLayout = YES;
    }
    self.needsDisplay = YES;
}

- (void)placeStrips {
    for (NSScrollView* strip in _strips) [strip removeFromSuperview];
    [_strips removeAllObjects];
    NSTextStorage* text = self.textStorage;
    CGFloat column = self.textContainer.containerSize.width;
    NSPoint origin = self.textContainerOrigin;
    [text enumerateAttribute:SPDFMacChatMarkdownBlockSizeAttribute inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(NSValue* size, NSRange range, BOOL* stop) {
                    (void)stop;
                    NSTextAttachment* attachment = [text attribute:NSAttachmentAttributeName atIndex:range.location
                                                    effectiveRange:NULL];
                    if (!size || !attachment) return;
                    NSUInteger glyph = [self.layoutManager glyphIndexForCharacterAtIndex:range.location];
                    NSRect line = [self.layoutManager lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
                    NSPoint location = [self.layoutManager locationForGlyphAtIndex:glyph];
                    CGFloat left = NSMinX(line) + location.x;
                    CGFloat visible = column - left;
                    if (size.sizeValue.width <= visible + .5) return;
                    // An attachment stands on its line's baseline; the strip covers exactly where it is drawn.
                    CGFloat height = size.sizeValue.height;
                    NSRect frame = NSMakeRect(origin.x + left, origin.y + NSMinY(line) + location.y - height,
                                              visible, height);
                    [self addStripWithFrame:frame attachment:attachment index:range.location size:size.sizeValue];
                  }];
}

- (void)addStripWithFrame:(NSRect)frame attachment:(NSTextAttachment*)attachment index:(NSUInteger)index
                     size:(NSSize)size {
    SPDFMacChatStripScrollView* strip = [[SPDFMacChatStripScrollView alloc] initWithFrame:frame];
    strip.hasHorizontalScroller = YES;
    strip.hasVerticalScroller = NO;
    strip.scrollerStyle = NSScrollerStyleOverlay;
    strip.horizontalScrollElasticity = NSScrollElasticityAllowed;
    strip.verticalScrollElasticity = NSScrollElasticityNone;
    // Opaque in the bubble's colour: the text view beneath draws the same block clipped at the bubble's edge.
    strip.drawsBackground = YES;
    strip.backgroundColor = self.backgroundColor ?: NSColor.clearColor;
    strip.identifier = @"chatWideBlock";
    SPDFMacChatStripContent* content = [[SPDFMacChatStripContent alloc] initWithFrame:NSMakeRect(0, 0, size.width,
                                                                                                 size.height)];
    content.attachment = attachment;
    content.characterIndex = index;
    content.textView = self;
    strip.documentView = content;
    [strip updateFades];
    [self addSubview:strip];
    [_strips addObject:strip];
}

- (void)setBackgroundColor:(NSColor*)color {
    [super setBackgroundColor:color];
    for (SPDFMacChatStripScrollView* strip in _strips) {
        strip.backgroundColor = color;
        [strip updateFades];
    }
}

- (void)drawRect:(NSRect)dirty {
    [self.backgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:7 yRadius:7] fill];
    [super drawRect:dirty];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if ([self isDark] != _renderedDark) {
        [self renderNow];
        [self updateHeight];
    }
    self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if (!self.contentHeight || _measurementScheduled || size.width <= 2 * self.textContainerInset.width ||
        self.hiddenOrHasHiddenAncestor)
        return;
    // NSStackView assigns its cached frames here, and a constraint changed inside that callback leaves rows one
    // layout behind; and a hidden dock's zero width would render one line hundreds of points tall. So render after
    // the current layout pass, and only at a real, changed width.
    _measurementScheduled = YES;
    __weak SPDFMacChatMarkdownView* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      SPDFMacChatMarkdownView* view = weakSelf;
      if (!view) return;
      view->_measurementScheduled = NO;
      if (view.hiddenOrHasHiddenAncestor || NSWidth(view.bounds) <= 2 * view.textContainerInset.width) return;
      if (fabs(NSWidth(view.bounds) - view->_renderedWidth) >= .5) [view renderNow];
      [view updateHeight];
    });
}

// Drawn blocks copy as their source, not as attachment characters: Copy, drags and services all take plain text.
- (NSArray<NSPasteboardType>*)writablePasteboardTypes {
    return @[ NSPasteboardTypeString ];
}
- (BOOL)writeSelectionToPasteboard:(NSPasteboard*)pasteboard type:(NSPasteboardType)type {
    if (![type isEqualToString:NSPasteboardTypeString] || !self.selectedRange.length) return NO;
    return [pasteboard setString:SPDFMacChatMarkdownCopyText(self.textStorage, self.selectedRange)
                         forType:NSPasteboardTypeString];
}
- (void)copy:(id)sender {
    (void)sender;
    NSRange range = self.selectedRange;
    if (!range.length) return;
    NSPasteboard* pasteboard = _options.pasteboard ?: NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:SPDFMacChatMarkdownCopyText(self.textStorage, range) forType:NSPasteboardTypeString];
}

@end
