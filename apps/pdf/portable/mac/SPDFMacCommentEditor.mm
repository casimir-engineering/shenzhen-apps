// The inline comment editor (SPDFMacCommentEditor.h). It replaced an NSAlert with an author field: the alert slid in
// as a system dialog, took a moment to appear and saved only with the mouse or Return, which a multi-line comment
// needs for new lines.

#import "SPDFMacCommentEditor.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacCommentAuthorName.h"

#import <QuartzCore/QuartzCore.h>

static const CGFloat kWidth = 320, kHeight = 158, kPad = 10, kMargin = 8;

NSRect SPDFCommentEditorFrame(NSSize size, NSPoint anchor, NSRect bounds, BOOL flipped) {
    CGFloat x = MIN(MAX(anchor.x - 24, NSMinX(bounds) + kMargin), NSMaxX(bounds) - size.width - kMargin);
    // "Below" grows y in a flipped host and shrinks it otherwise.
    CGFloat below = flipped ? anchor.y + kMargin : anchor.y - kMargin - size.height;
    CGFloat above = flipped ? anchor.y - kMargin - size.height : anchor.y + kMargin;
    BOOL fitsBelow = flipped ? below + size.height <= NSMaxY(bounds) - kMargin : below >= NSMinY(bounds) + kMargin;
    CGFloat y = fitsBelow ? below : above;
    y = MIN(MAX(y, NSMinY(bounds) + kMargin), NSMaxY(bounds) - size.height - kMargin);
    return NSMakeRect(MAX(x, NSMinX(bounds)), MAX(y, NSMinY(bounds)), size.width, size.height);
}

@class SPDFMacCommentEditorView;

// ⌘↩ saves and Esc cancels from inside the text; plain Return stays a new line.
@interface SPDFCommentEditorTextView : NSTextView
@property(nonatomic, weak) SPDFMacCommentEditorView* editor;
@end

@interface SPDFMacCommentEditorView () <NSTextViewDelegate>
- (BOOL)isSaveKey:(NSEvent*)event;
@end

@implementation SPDFMacCommentEditorView {
    NSTextView* _textView;
    NSTextField* _heading;
    SPDFMacCommentAuthorByline* _by;
    NSButton* _save;
    NSButton* _cancel;
    NSUndoManager* _undo;
    id _clickMonitor;
    BOOL _done;
    BOOL _open;
}

- (instancetype)initWithTitle:(NSString*)title button:(NSString*)button author:(NSString*)author text:(NSString*)text {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)])) return nil;
    self.identifier = @"SPDFCommentEditor";
    NSTextField* heading = SPDFCollectionText(title, 12, NSFontWeightSemibold, NO);
    SPDFMacCommentAuthorByline* by = [[SPDFMacCommentAuthorByline alloc] initWithFrame:NSZeroRect];
    heading.frame = NSMakeRect(kPad, kHeight - kPad - 16, 150, 16);
    by.frame = NSMakeRect(kPad + 150, kHeight - kPad - 16, kWidth - 2 * kPad - 150, 16);

    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(kPad, 42, kWidth - 2 * kPad, kHeight - 42 - 34)];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.wantsLayer = YES;
    scroll.layer.cornerRadius = 6;
    SPDFCommentEditorTextView* textView = [[SPDFCommentEditorTextView alloc] initWithFrame:scroll.bounds];
    textView.editor = self;
    // Its own undo history: a reused box never undoes into what an earlier comment held.
    _undo = [NSUndoManager new];
    textView.delegate = self;
    textView.font = [NSFont systemFontOfSize:13];
    textView.textColor = SPDFCollectionColor(@"text");
    textView.insertionPointColor = SPDFCollectionColor(@"text");
    textView.backgroundColor = SPDFCollectionColor(@"field");
    textView.textContainerInset = NSMakeSize(4, 5);
    textView.richText = NO;
    textView.allowsUndo = YES;
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.autoresizingMask = NSViewWidthSizable;
    textView.textContainer.widthTracksTextView = YES;
    textView.accessibilityLabel = @"Comment";
    scroll.documentView = textView;
    _textView = textView;
    by.keyboardHome = textView;

    NSButton* save = SPDFCollectionButton(@"", self, @selector(save), @"normal");
    NSButton* cancel = SPDFCollectionButton(@"Cancel", self, @selector(cancel), @"normal");
    save.identifier = @"SPDFCommentEditorSave";
    cancel.identifier = @"SPDFCommentEditorCancel";
    save.toolTip = @"Command-Return";
    cancel.toolTip = @"Esc";
    _heading = heading;
    _by = by;
    _save = save;
    _cancel = cancel;
    for (NSView* view in @[ heading, by, scroll, cancel, save ]) [self addSubview:view];
    self.shadow = [NSShadow new];
    self.shadow.shadowBlurRadius = 10;
    self.shadow.shadowOffset = NSMakeSize(0, -2);
    self.shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
    [self resetWithTitle:title button:button author:author text:text];
    return self;
}

- (void)resetWithTitle:(NSString*)title button:(NSString*)button author:(NSString*)author text:(NSString*)text {
    _heading.stringValue = title ?: @"";
    self.changeAuthor = nil;
    _by.name = author.length ? author : @"";
    NSString* saveTitle = [NSString stringWithFormat:@"%@  ⌘↩", button ?: @""];
    if (![_save.title isEqualToString:saveTitle] || NSIsEmptyRect(_save.frame)) {
        _save.title = saveTitle;
        CGFloat saveWidth = ceil([_save.title sizeWithAttributes:@{NSFontAttributeName : _save.font}].width) + 22;
        CGFloat cancelWidth = ceil([_cancel.title sizeWithAttributes:@{NSFontAttributeName : _cancel.font}].width) + 22;
        _save.frame = NSMakeRect(kWidth - kPad - saveWidth, kPad, saveWidth, 24);
        _cancel.frame = NSMakeRect(NSMinX(_save.frame) - 6 - cancelWidth, kPad, cancelWidth, 24);
    }
    _textView.string = text ?: @"";
    [_undo removeAllActions];
    NSClipView* clip = (NSClipView*)_textView.superview;
    if ([clip isKindOfClass:NSClipView.class] && !NSEqualPoints(clip.bounds.origin, NSZeroPoint)) [_textView scrollPoint:NSZeroPoint];
    _done = NO;
}

- (NSUndoManager*)undoManagerForTextView:(NSTextView*)view {
    (void)view;
    return _undo;
}

- (void)warmUp {
    _textView.string = @"Warm up: the quick brown fox";
    NSBitmapImageRep* rep = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    if (rep) [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
    _textView.string = @"";
}

- (BOOL)isOpen {
    return _open;
}

- (void)setChangeAuthor:(void (^)(NSString*))changeAuthor {
    _changeAuthor = [changeAuthor copy];
    _by.editable = changeAuthor != nil;
    _by.changed = changeAuthor;
}

- (void)showAuthor:(NSString*)author {
    _by.name = author;
}

- (NSView*)authorByline {
    return _by;
}

- (NSTextView*)textView {
    return _textView;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:8 yRadius:8];
    [SPDFCollectionColor(@"popover") setFill];
    [shape fill];
    [SPDFCollectionColor(@"lineStrong") setStroke];
    [shape stroke];
}

// Clicks on the box stay with it rather than reaching the page underneath.
- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}
- (void)mouseDown:(NSEvent*)event {
    (void)event;
}

- (void)showInView:(NSView*)host near:(NSPoint)point {
    // In the frame being built now, with no implicit animation.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.frame = SPDFCommentEditorFrame(self.frame.size, point, host.bounds, host.isFlipped);
    if (self.superview != host || host.subviews.lastObject != self)
        [host addSubview:self positioned:NSWindowAbove relativeTo:nil];
    self.hidden = NO;
    [CATransaction commit];
    _open = YES;
    [self.window makeFirstResponder:_textView];
    [_textView setSelectedRange:NSMakeRange(_textView.string.length, 0)];
    __weak SPDFMacCommentEditorView* weakSelf = self;
    _clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                                                  NSEventMaskOtherMouseDown
                                                          handler:^NSEvent*(NSEvent* event) {
                                                            SPDFMacCommentEditorView* editor = weakSelf;
                                                            if (editor && ![editor containsEvent:event])
                                                                [editor closeKeepingDraft];
                                                            return event;
                                                          }];
}

- (BOOL)containsEvent:(NSEvent*)event {
    if (event.window != self.window) return NO;
    return NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
}

- (BOOL)performKeyEquivalent:(NSEvent*)event {
    // ⌘↩ adds the comment from the name field too, with the name typed there.
    if (_open && (self.window.firstResponder == _textView || _by.editing) && [self isSaveKey:event]) {
        [_by commitEditing];
        [self save];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (BOOL)isSaveKey:(NSEvent*)event {
    BOOL returnKey = event.keyCode == 36 || event.keyCode == 76;
    return returnKey && (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand;
}

- (void)finishWith:(NSString*)text saved:(BOOL)saved {
    if (_done) return;
    _done = YES;
    _open = NO;
    if (_clickMonitor) [NSEvent removeMonitor:_clickMonitor];
    _clickMonitor = nil;
    NSWindow* window = self.window;
    NSResponder* focus = window.firstResponder;
    BOOL hadFocus = [focus isKindOfClass:NSView.class] && [(NSView*)focus isDescendantOf:self];
    // Hidden, not removed: the next comment shows this same box at once.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.hidden = YES;
    [CATransaction commit];
    if (hadFocus || window.firstResponder == nil || window.firstResponder == window) [window makeFirstResponder:nil];
    if (self.finished) self.finished(text, saved);
    self.finished = nil;
}

- (void)save {
    NSString* text = [_textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) {
        NSBeep();
        return;
    }
    [self finishWith:text saved:YES];
}

- (void)cancel {
    [self finishWith:nil saved:NO];
}

- (void)closeKeepingDraft {
    NSString* text = [_textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self finishWith:text.length ? [_textView.string copy] : nil saved:NO];
}
@end

@implementation SPDFCommentEditorTextView
- (void)keyDown:(NSEvent*)event {
    if ([self.editor isSaveKey:event]) {
        [self.editor save];
        return;
    }
    [super keyDown:event];
}
- (void)cancelOperation:(id)sender {
    (void)sender;
    [self.editor cancel];
}
@end
