#import "SPDFMacChatMarkdownParts.h"

// The attachments a chat message is made of beyond its text. Each draws itself in the view that shows it and
// tracks its own clicks (a link inside a table, Copy on code, Load image), so the same attributed string works in
// AI chat and in Friends' bubbles. Each also answers -imageForBounds: with the same drawing, for views that draw an
// attachment's image rather than its cell (TextKit 2, a sideways-scrolling strip).

NSAttributedStringKey const SPDFMacChatMarkdownSourceAttribute = @"SZFriendsMarkdownSource";
NSAttributedStringKey const SPDFMacChatMarkdownBlockSizeAttribute = @"SPDFMacChatMarkdownBlockSize";

NSColor* SPDFMacChatConcreteColor(NSColor* color, BOOL dark) {
    __block NSColor* concrete = nil;
    NSAppearance* appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    [appearance performAsCurrentDrawingAppearance:^{
      concrete = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    return concrete ?: (dark ? NSColor.whiteColor : NSColor.blackColor);
}

// Draws `body` with y running down from `frame`'s top whatever the view's orientation.
static void DrawFlipped(NSRect frame, NSView* view, void (^body)(CGContextRef context)) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context) return;
    CGContextSaveGState(context);
    if (view.isFlipped) {
        CGContextTranslateCTM(context, NSMinX(frame), NSMinY(frame));
    } else {
        CGContextTranslateCTM(context, NSMinX(frame), NSMaxY(frame));
        CGContextScaleCTM(context, 1, -1);
    }
    NSGraphicsContext* flipped = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = flipped;
    body(context);
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(context);
}

void SPDFMacChatDrawPill(NSRect rect, NSString* title, SPDFMarkdownTheme* theme, NSColor* ink) {
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, .5, .5) xRadius:5 yRadius:5];
    [theme.codeControlFillColor setFill];
    [shape fill];
    [theme.codeControlStrokeColor setStroke];
    [shape stroke];
    NSMutableParagraphStyle* centered = [NSMutableParagraphStyle new];
    centered.alignment = NSTextAlignmentCenter;
    centered.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary* attributes = @{NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName : ink, NSParagraphStyleAttributeName : centered};
    CGFloat height = [title sizeWithAttributes:attributes].height;
    [title drawInRect:NSMakeRect(NSMinX(rect) + 4, NSMidY(rect) - height / 2, NSWidth(rect) - 8, height)
        withAttributes:attributes];
}

// Waits for the button to come up; YES when it came up inside `rect` (in `view`'s coordinates).
static BOOL ReleasedInside(NSEvent* down, NSRect rect, NSView* view) {
    NSEvent* event = down;
    while (event.type != NSEventTypeLeftMouseUp) {
        event = [view.window nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!event) return NO;
    }
    return NSPointInRect([view convertPoint:event.locationInWindow fromView:nil], rect);
}

@implementation SPDFMacChatAttachment
+ (instancetype)attachmentWithCell:(NSTextAttachmentCell<SPDFMacChatContentCell>*)cell {
    SPDFMacChatAttachment* attachment = [self new];
    attachment.attachmentCell = cell;
    cell.attachment = attachment;
    return attachment;
}
- (NSImage*)imageForBounds:(CGRect)bounds textContainer:(NSTextContainer*)container characterIndex:(NSUInteger)index {
    (void)bounds, (void)container, (void)index;
    id<SPDFMacChatContentCell> cell = (id<SPDFMacChatContentCell>)self.attachmentCell;
    NSImage* image = [NSImage imageWithSize:cell.cellSize flipped:YES drawingHandler:^BOOL(NSRect rect) {
      (void)rect;
      [cell drawContent];
      return YES;
    }];
    // Drawn afresh at each scale: a 2000 pt table cached as a 2x bitmap would cost tens of megabytes.
    image.cacheMode = NSImageCacheNever;
    return image;
}
- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer*)container proposedLineFragment:(CGRect)fragment
                             glyphPosition:(CGPoint)position characterIndex:(NSUInteger)index {
    (void)container, (void)fragment, (void)position, (void)index;
    NSSize size = self.attachmentCell.cellSize;
    return CGRectMake(0, 0, size.width, size.height);
}
@end

@interface SPDFMacChatBlockCell : NSTextAttachmentCell <SPDFMacChatContentCell>
@property(nonatomic, strong) SPDFMacChatBlock* block;
@property(nonatomic) CGFloat scale;
@property(nonatomic, strong) SPDFMacChatMarkdownOptions* options;
@property(nonatomic) BOOL copied;
// Where the cell was last drawn, so its controls can tell assistive apps where they are and act there.
@property(nonatomic, weak) NSView* shownIn;
@property(nonatomic) NSRect shownFrame;
- (NSRect)copyRect;
- (BOOL)copyCodeInView:(NSView*)view frame:(NSRect)frame;
- (BOOL)openLink:(NSURL*)target range:(NSRange)range inView:(nullable NSView*)view atPoint:(NSPoint)point;
@end

// A control drawn inside a block, Copy on code or a link in a table, as VoiceOver and other assistive apps reach it:
// a button with a label and a press action, like Load image. The mouse reaches the same actions through the cell's
// own click tracking.
@interface SPDFMacChatControlElement : NSAccessibilityElement
@property(nonatomic, weak) SPDFMacChatBlockCell* cell;
@property(nonatomic, strong, nullable) NSURL* link;  // nil: Copy
@property(nonatomic) NSRange range;                 // the link's characters in the block's string
@end

@implementation SPDFMacChatControlElement
// In the cell, y down from its top, at the scale it is drawn.
- (NSRect)rectInCell {
    SPDFMacChatBlockCell* cell = self.cell;
    NSRect natural = self.link ? SPDFMacChatBlockRectForRange(cell.block, self.range) : [cell copyRect];
    return NSMakeRect(NSMinX(natural) * cell.scale, NSMinY(natural) * cell.scale, NSWidth(natural) * cell.scale,
                      NSHeight(natural) * cell.scale);
}
- (NSRect)rectInView {
    SPDFMacChatBlockCell* cell = self.cell;
    NSRect frame = cell.shownFrame, rect = [self rectInCell];
    CGFloat y = cell.shownIn.isFlipped ? NSMinY(frame) + NSMinY(rect) : NSMaxY(frame) - NSMaxY(rect);
    return NSMakeRect(NSMinX(frame) + NSMinX(rect), y, NSWidth(rect), NSHeight(rect));
}
- (NSRect)accessibilityFrame {
    NSView* view = self.cell.shownIn;
    if (!view.window) return NSZeroRect;
    return [view.window convertRectToScreen:[view convertRect:[self rectInView] toView:nil]];
}
- (BOOL)accessibilityPerformPress {
    SPDFMacChatBlockCell* cell = self.cell;
    if (!self.link) return [cell copyCodeInView:cell.shownIn frame:cell.shownFrame];
    NSRect rect = [self rectInView];
    return [cell openLink:self.link range:self.range inView:cell.shownIn
                  atPoint:NSMakePoint(NSMidX(rect), NSMidY(rect))];
}
@end

// What a link's button says: its text, then where it goes. A citation's address is the assistant's own scheme, so
// it is named for what it opens instead.
static NSString* LinkLabel(NSString* text, NSURL* URL) {
    NSString* scheme = URL.scheme.lowercaseString;
    NSString* destination = [scheme isEqualToString:@"spdf-ai"]                 ? @"opens the cited document"
                            : [scheme isEqualToString:@"shenzhenpdf-friends"] ? @"opens the message in Friends"
                                                                                : URL.absoluteString;
    return text.length ? [NSString stringWithFormat:@"%@, %@", text, destination] : destination;
}

@implementation SPDFMacChatBlockCell {
    NSArray<SPDFMacChatControlElement*>* _controls;
}
@synthesize headerOffset = _headerOffset;
- (NSRect)copyRect {
    NSRect copy = SPDFMacChatBlockCopyRect(self.block);
    return NSIsEmptyRect(copy) ? copy : NSOffsetRect(copy, self.headerOffset, 0);
}
- (NSSize)cellSize {
    return NSMakeSize(ceil(NSWidth(self.block.contentRect) * self.scale),
                      ceil(NSHeight(self.block.contentRect) * self.scale));
}
- (NSPoint)cellBaselineOffset { return NSZeroPoint; }
- (void)drawContent {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    SPDFMacChatBlock* block = self.block;
    CGFloat height = NSHeight(block.contentRect) * self.scale;
    // The block draws y-up from its bottom edge; this context runs y-down from the top.
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1, -1);
    SPDFMacChatDrawBlock(block, context, self.scale);
    CGContextRestoreGState(context);
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:block.variant];
    NSRect copy = [self copyRect];
    if (NSIsEmptyRect(copy) || self.scale != 1) return;
    if (block.language.length) {
        NSString* language = block.language.length > 24 ? [block.language substringToIndex:24] : block.language;
        [language drawAtPoint:NSMakePoint(12 + self.headerOffset, NSMidY(copy) - 7)
               withAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:11],
                                NSForegroundColorAttributeName : theme.codeControlTextColor}];
    }
    SPDFMacChatDrawPill(copy, self.copied ? @"Copied" : @"Copy", theme, theme.codeControlTextColor);
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    self.shownIn = view;
    self.shownFrame = frame;
    DrawFlipped(frame, view, ^(CGContextRef context) {
      (void)context;
      [self drawContent];
    });
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view characterIndex:(NSUInteger)index
        layoutManager:(NSLayoutManager*)layoutManager {
    (void)index, (void)layoutManager;
    [self drawWithFrame:frame inView:view];
}
// What a point (y down from the top of the attachment) does: a link's URL (its characters in *range), @"copy", or nil
// (the text view selects).
- (id)targetAtPoint:(NSPoint)point range:(NSRange*)range {
    NSPoint natural = NSMakePoint(point.x / self.scale, point.y / self.scale);
    if (self.scale == 1 && NSPointInRect(natural, [self copyRect])) return @"copy";
    NSUInteger index = SPDFMacChatBlockCharacterAtPoint(self.block, natural);
    if (index == NSNotFound) return nil;
    NSAttributedString* text = self.block.rendered.attributedString;
    id link = [text attribute:NSLinkAttributeName atIndex:index longestEffectiveRange:range
                      inRange:NSMakeRange(0, text.length)];
    return [link isKindOfClass:NSURL.class] ? link : nil;
}
- (NSPoint)pointForEvent:(NSEvent*)event inRect:(NSRect)frame ofView:(NSView*)view {
    NSPoint point = [view convertPoint:event.locationInWindow fromView:nil];
    return NSMakePoint(point.x - NSMinX(frame), view.isFlipped ? point.y - NSMinY(frame) : NSMaxY(frame) - point.y);
}
- (BOOL)wantsToTrackMouse { return YES; }
- (BOOL)wantsToTrackMouseForEvent:(NSEvent*)event inRect:(NSRect)frame ofView:(NSView*)view
                 atCharacterIndex:(NSUInteger)index {
    (void)index;
    NSRange range;
    return [self targetAtPoint:[self pointForEvent:event inRect:frame ofView:view] range:&range] != nil;
}
- (BOOL)trackMouse:(NSEvent*)event inRect:(NSRect)frame ofView:(NSView*)view atCharacterIndex:(NSUInteger)index
      untilMouseUp:(BOOL)flag {
    (void)index, (void)flag;
    NSRange range = NSMakeRange(0, 0);
    id target = [self targetAtPoint:[self pointForEvent:event inRect:frame ofView:view] range:&range];
    if (!target || !ReleasedInside(event, frame, view)) return YES;
    if ([target isKindOfClass:NSURL.class])
        [self openLink:target range:range inView:view atPoint:[view convertPoint:event.locationInWindow fromView:nil]];
    else [self copyCodeInView:view frame:frame];
    return YES;
}
- (BOOL)openLink:(NSURL*)target range:(NSRange)range inView:(NSView*)view atPoint:(NSPoint)point {
    NSURL* URL = self.block.aliases[target.absoluteString] ?: target;
    if (!SPDFMacChatMarkdownLinkAllowed(URL, self.options.links)) return NO;
    NSString* string = self.block.rendered.attributedString.string;
    NSString* shown = NSMaxRange(range) <= string.length ? [string substringWithRange:range] : @"";
    return SPDFMacChatOpenBlockLink(URL, shown, self.options, view, point);
}
- (BOOL)copyCodeInView:(NSView*)view frame:(NSRect)frame {
    if (NSIsEmptyRect([self copyRect])) return NO;
    NSPasteboard* pasteboard = self.options.pasteboard ?: NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:self.block.source forType:NSPasteboardTypeString];
    self.copied = YES;
    [view setNeedsDisplayInRect:frame];
    __weak SPDFMacChatBlockCell* weakSelf = self;
    __weak NSView* weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      weakSelf.copied = NO;
      weakView.needsDisplay = YES;
    });
    return YES;
}
- (NSString*)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString*)accessibilityLabel {
    SPDFMacChatBlockKind kind = self.block.kind;
    return kind == SPDFMacChatBlockTable ? @"Table" : kind == SPDFMacChatBlockDiagram ? @"Diagram" : @"Code";
}
- (NSArray*)accessibilityChildren {
    if (_controls) return _controls;
    NSMutableArray<SPDFMacChatControlElement*>* controls = [NSMutableArray array];
    // Copy is drawn only at natural size (SPDFMacChatBlockCell -drawContent), so only then is it offered.
    if (!NSIsEmptyRect([self copyRect]) && self.scale == 1)
        [controls addObject:[self controlFor:nil range:NSMakeRange(0, 0) label:@"Copy code"]];
    NSAttributedString* text = self.block.rendered.attributedString;
    [text enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
                    (void)stop;
                    if (![value isKindOfClass:NSURL.class]) return;
                    NSURL* URL = self.block.aliases[[value absoluteString]] ?: value;
                    if (!SPDFMacChatMarkdownLinkAllowed(URL, self.options.links)) return;
                    NSString* shown = [[text.string substringWithRange:range]
                        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    [controls addObject:[self controlFor:value range:range label:LinkLabel(shown, URL)]];
                  }];
    _controls = controls;
    return _controls;
}
- (SPDFMacChatControlElement*)controlFor:(NSURL*)link range:(NSRange)range label:(NSString*)label {
    SPDFMacChatControlElement* control = [SPDFMacChatControlElement new];
    control.cell = self;
    control.link = link;
    control.range = range;
    control.accessibilityRole = NSAccessibilityButtonRole;
    control.accessibilityLabel = label;
    control.accessibilityParent = self;
    return control;
}
@end

NSAttributedString* SPDFMacChatBlockAttachment(SPDFMacChatBlock* block, CGFloat scale,
                                               SPDFMacChatMarkdownOptions* options) {
    SPDFMacChatBlockCell* cell = [SPDFMacChatBlockCell new];
    cell.block = block;
    cell.scale = scale;
    cell.options = options;
    NSSize size = cell.cellSize;
    SPDFMacChatAttachment* attachment = [SPDFMacChatAttachment attachmentWithCell:cell];
    NSMutableAttributedString* result =
        [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    NSRange all = NSMakeRange(0, result.length);
    [result addAttribute:SPDFMacChatMarkdownSourceAttribute value:block.source range:all];
    [result addAttribute:SPDFMacChatMarkdownBlockSizeAttribute value:[NSValue valueWithSize:size] range:all];
    return result;
}

NSAttributedString* SPDFMacChatRuleAttachment(CGFloat width, SPDFMacChatMarkdownOptions* options) {
    NSColor* line = [SPDFMarkdownTheme themeForVariant:options.dark ? SPDFMarkdownThemeVariantDark
                                                                     : SPDFMarkdownThemeVariantLight]
                        .thematicBreakRuleColor;
    NSSize size = NSMakeSize(MAX(40, floor(width)), 9);
    NSTextAttachment* attachment = [NSTextAttachment new];
    attachment.image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [line setFill];
      NSRectFill(NSMakeRect(0, floor(NSMidY(rect)), NSWidth(rect), 1));
      return YES;
    }];
    attachment.bounds = NSMakeRect(0, 0, size.width, size.height);
    NSMutableAttributedString* result =
        [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    [result addAttribute:SPDFMacChatMarkdownSourceAttribute value:@"---" range:NSMakeRange(0, result.length)];
    return result;
}

NSString* SPDFMacChatMarkdownCopyText(NSAttributedString* rendered, NSRange range) {
    NSMutableString* text = [NSMutableString string];
    range = NSIntersectionRange(range, NSMakeRange(0, rendered.length));
    [rendered enumerateAttribute:SPDFMacChatMarkdownSourceAttribute inRange:range options:0
                      usingBlock:^(id source, NSRange part, BOOL* stop) {
                        (void)stop;
                        if ([source isKindOfClass:NSString.class]) {
                            [text appendString:source];
                            return;
                        }
                        NSString* shown = [rendered.string substringWithRange:part];
                        [text appendString:[shown stringByReplacingOccurrencesOfString:@"￼" withString:@""]];
                      }];
    return text;
}
