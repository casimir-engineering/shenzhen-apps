// The text views inside a bubble and the strips that show a wide block (a table, a diagram) at its natural size,
// scrolling sideways inside the bubble (SZFriendsMessageBody.m places them).

#import "mac/SZFriendsItemViewsInternal.h"

@implementation SZFriendsMarkdownTextView
- (void)cancelOperation:(id)sender {
    (void)sender;
    SZFriendsForwardEscape(self); // as everywhere in the dropdown: the innermost picker first, then the dropdown
}
- (NSArray<NSPasteboardType> *)writablePasteboardTypes {
    return @[ NSPasteboardTypeString ];
}
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard type:(NSPasteboardType)type {
    if (![type isEqualToString:NSPasteboardTypeString]) return NO;
    NSString *text = SZFriendsMarkdownCopyText(self.textStorage, self.selectedRange, self.source ?: @"");
    return text.length > 0 && [pasteboard setString:text forType:NSPasteboardTypeString];
}
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard types:(NSArray<NSPasteboardType> *)types {
    if (![types containsObject:NSPasteboardTypeString]) return NO;
    [pasteboard declareTypes:@[ NSPasteboardTypeString ] owner:nil];
    return [self writeSelectionToPasteboard:pasteboard type:NSPasteboardTypeString];
}
@end

@implementation SZFriendsAttachmentView
- (BOOL)isFlipped {
    return YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    // A picture as a picture; a block drawn by its cell through the cell, as the text view would draw it.
    NSTextAttachment *attachment = self.attachment;
    NSImage *image = attachment.image;
    if (!image && attachment.attachmentCell) {
        [attachment.attachmentCell drawWithFrame:self.bounds inView:self];
        return;
    }
    if (!image) image = [attachment imageForBounds:self.bounds textContainer:nil characterIndex:self.characterIndex];
    [image drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
       respectFlipped:YES hints:nil];
}
- (void)mouseDown:(NSEvent *)event {
    id<NSTextAttachmentCell> cell = self.attachment.attachmentCell;
    if ([cell wantsToTrackMouseForEvent:event inRect:self.bounds ofView:self atCharacterIndex:self.characterIndex]) {
        [cell trackMouse:event inRect:self.bounds ofView:self atCharacterIndex:self.characterIndex untilMouseUp:YES];
        return;
    }
    [super mouseDown:event];
}
@end

@implementation SZFriendsWideBlockScrollView
- (instancetype)initWithFrame:(NSRect)frameRect {
    if (!(self = [super initWithFrame:frameRect])) return nil;
    // The bubble's colour fades in at an edge where more of the block lies beyond it: a table cut off at a column
    // boundary looked complete.
    _leadingFade = [SZFriendsEdgeFade new];
    _leadingFade.edge = NSMinXEdge;
    _trailingFade = [SZFriendsEdgeFade new];
    _trailingFade.edge = NSMaxXEdge;
    return self;
}
- (void)setFadeColor:(NSColor *)color {
    _leadingFade.color = color;
    _trailingFade.color = color;
    _leadingFade.needsDisplay = YES;
    _trailingFade.needsDisplay = YES;
}
- (void)updateFades {
    if (!_leadingFade) return; // NSScrollView may tile from its own initializer
    // Added after the clip view so they draw over the block; re-added after AppKit retiles its subviews.
    for (NSView *fade in @[ _leadingFade, _trailingFade ])
        if (fade.superview != self || self.subviews.lastObject != _trailingFade) [self addSubview:fade];
    CGFloat x = NSMinX(self.contentView.bounds);
    CGFloat end = NSWidth(self.documentView.frame) - NSWidth(self.contentView.bounds);
    CGFloat width = MIN(18, NSWidth(self.bounds) / 4), height = NSHeight(self.bounds);
    _leadingFade.frame = NSMakeRect(0, 0, width, height);
    _trailingFade.frame = NSMakeRect(NSWidth(self.bounds) - width, 0, width, height);
    _leadingFade.hidden = x <= 0.5;
    _trailingFade.hidden = x >= end - 0.5;
}
- (void)tile {
    [super tile];
    [self updateFades];
}
- (void)reflectScrolledClipView:(NSClipView *)clipView {
    [super reflectScrolledClipView:clipView];
    [self updateFades];
}
- (void)scrollWheel:(NSEvent *)event {
    if (fabs(event.scrollingDeltaY) > fabs(event.scrollingDeltaX)) {
        NSScrollView *conversation = self.superview.enclosingScrollView;
        if (conversation) [conversation scrollWheel:event];
        else [self.nextResponder scrollWheel:event];
        return;
    }
    [super scrollWheel:event];
}
@end
