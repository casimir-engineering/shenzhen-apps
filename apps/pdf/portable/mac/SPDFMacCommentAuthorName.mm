// Your name on comments, changed where it is shown (SPDFMacCommentAuthorName.h).

#import "SPDFMacCommentAuthorName.h"
#import "SPDFMacCollectionStyle.h"

#import <objc/runtime.h>

NSString* const SPDFCommentAuthorToolTip = @"Change your name";

static const CGFloat kPencilGap = 3;

NSImage* SPDFCommentAuthorPencil(CGFloat pointSize) {
    NSImageSymbolConfiguration* size = [NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                        weight:NSFontWeightRegular
                                                                                         scale:NSImageSymbolScaleSmall];
    NSImageSymbolConfiguration* colour =
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[ SPDFCollectionColor(@"secondary") ]];
    NSImage* pencil = [NSImage imageWithSystemSymbolName:@"pencil" accessibilityDescription:SPDFCommentAuthorToolTip];
    return [pencil imageWithSymbolConfiguration:[size configurationByApplyingConfiguration:colour]] ?: [NSImage new];
}

NSString* SPDFCommentAuthorEditedName(NSString* name, NSString* previous) {
    NSString* trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    NSString* old = [previous stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed isEqualToString:old ?: @""] ? nil : trimmed;
}

#pragma mark - The field

static char kEditKey;

@interface SPDFCommentAuthorNameEdit () <NSTextFieldDelegate>
@end

@implementation SPDFCommentAuthorNameEdit {
    NSTextField* _field;
    NSString* _original;
    void (^_done)(NSString*, BOOL);
    BOOL _finished;
}

+ (instancetype)editName:(NSString*)name
                  inView:(NSView*)host
                   frame:(NSRect)frame
                    font:(NSFont*)font
               alignment:(NSTextAlignment)alignment
                    done:(void (^)(NSString*, BOOL))done {
    SPDFCommentAuthorNameEdit* edit = [self new];
    NSTextField* field = [NSTextField textFieldWithString:name ?: @""];
    field.font = font;
    field.alignment = alignment;
    field.bordered = NO;
    field.bezeled = NO;
    field.drawsBackground = YES;
    field.backgroundColor = SPDFCollectionColor(@"field");
    field.textColor = SPDFCollectionColor(@"text");
    field.usesSingleLineMode = YES;
    field.lineBreakMode = NSLineBreakByClipping;
    field.cell.scrollable = YES;
    field.accessibilityLabel = @"Your name on comments";
    field.frame = frame;
    field.delegate = edit;
    edit->_field = field;
    edit->_original = [name copy] ?: @"";
    edit->_done = [done copy];
    // The field keeps its edit alive for as long as it is there.
    objc_setAssociatedObject(field, &kEditKey, edit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addSubview:field positioned:NSWindowAbove relativeTo:nil];
    [host.window makeFirstResponder:field];
    [field.currentEditor selectAll:nil];
    return edit;
}

- (NSTextField*)field {
    return _field;
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)control, (void)textView;
    if (command == @selector(insertNewline:)) {
        [self finishKeeping:YES byKey:YES];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        [self finishKeeping:NO byKey:YES];
        return YES;
    }
    return NO;
}

// The keyboard went elsewhere: a click outside the field.
- (void)controlTextDidEndEditing:(NSNotification*)note {
    (void)note;
    [self finishKeeping:YES byKey:NO];
}

- (void)commit {
    [self finishKeeping:YES byKey:NO];
}

- (void)cancel {
    [self finishKeeping:NO byKey:NO];
}

- (void)finishKeeping:(BOOL)keep byKey:(BOOL)byKey {
    if (_finished) return;
    _finished = YES;
    NSString* name = keep ? SPDFCommentAuthorEditedName(_field.stringValue, _original) : nil;
    NSTextField* field = _field;
    // Hidden now, gone after this event: the field editor may still be finishing with it.
    field.hidden = YES;
    void (^done)(NSString*, BOOL) = _done;
    _done = nil;
    if (done) done(name, byKey);
    dispatch_async(dispatch_get_main_queue(), ^{
      field.delegate = nil;
      [field removeFromSuperview];
      objc_setAssociatedObject(field, &kEditKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

@end

#pragma mark - A drawn name's hotspot

@implementation SPDFCommentAuthorHotspot {
    NSTrackingArea* _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.toolTip = SPDFCommentAuthorToolTip;
    self.accessibilityLabel = SPDFCommentAuthorToolTip;
    return self;
}
- (void)drawRect:(NSRect)dirty { (void)dirty; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)acceptsFirstResponder { return NO; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
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
- (void)mouseEntered:(NSEvent*)event { (void)event; if (self.hovered) self.hovered(YES); }
- (void)mouseExited:(NSEvent*)event { (void)event; if (self.hovered) self.hovered(NO); }
- (void)mouseDown:(NSEvent*)event {
    (void)event;
    if (self.pressed) self.pressed();
}
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (BOOL)accessibilityPerformPress {
    if (self.pressed) self.pressed();
    return YES;
}
@end

#pragma mark - The box's byline

@implementation SPDFMacCommentAuthorByline {
    NSTrackingArea* _tracking;
    SPDFCommentAuthorNameEdit* _edit;
    BOOL _hovered;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _name = @"";
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (NSDictionary*)nameStyle {
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    return @{NSFontAttributeName : [NSFont systemFontOfSize:11], NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary"),
             NSParagraphStyleAttributeName : style};
}

- (NSImage*)pencil {
    return SPDFCommentAuthorPencil(10);
}

// The pencil's place is kept while the name is editable, so the name does not move when it shows.
- (CGFloat)pencilSlot {
    return _editable ? ceil(self.pencil.size.width) + kPencilGap : 0;
}

- (NSRect)nameRect {
    CGFloat slot = [self pencilSlot];
    CGFloat width = MIN(ceil([_name sizeWithAttributes:[self nameStyle]].width), MAX(0.0, NSWidth(self.bounds) - slot));
    return NSMakeRect(NSMaxX(self.bounds) - slot - width, 0, width, NSHeight(self.bounds));
}

- (NSRect)nameArea {
    if (!_editable || !_name.length) return NSZeroRect;
    NSRect name = [self nameRect];
    name.size.width += [self pencilSlot];
    return name;
}

- (BOOL)isEditing {
    return _edit != nil;
}

- (BOOL)isHovered {
    return _hovered;
}

- (void)setName:(NSString*)name {
    if (_edit) return;  // the field has the name being typed
    _name = [name copy] ?: @"";
    self.accessibilityLabel = _name;
    [self refreshPointerAreas];
}

- (void)setEditable:(BOOL)editable {
    if (!editable) [self cancelEditing];
    _editable = editable;
    if (!editable) _hovered = NO;
    [self refreshPointerAreas];
}

- (void)refreshPointerAreas {
    [self.window invalidateCursorRectsForView:self];
    [self removeAllToolTips];
    NSRect area = self.nameArea;
    if (!NSIsEmptyRect(area)) [self addToolTipRect:area owner:self userData:NULL];
    self.needsDisplay = YES;
}

- (NSString*)view:(NSView*)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void*)data {
    (void)view, (void)tag, (void)point, (void)data;
    return SPDFCommentAuthorToolTip;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self refreshPointerAreas];
}

- (void)resetCursorRects {
    NSRect area = self.nameArea;
    if (!NSIsEmptyRect(area) && !_edit) [self addCursorRect:area cursor:NSCursor.pointingHandCursor];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                                                     NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)pointerAt:(NSEvent*)event {
    BOOL over = event && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.nameArea);
    if (over == _hovered) return;
    _hovered = over;
    self.needsDisplay = YES;
}
- (void)mouseEntered:(NSEvent*)event { [self pointerAt:event]; }
- (void)mouseMoved:(NSEvent*)event { [self pointerAt:event]; }
- (void)mouseExited:(NSEvent*)event { (void)event; [self pointerAt:nil]; }

// Like the rest of the box: a click on the name edits it even before the window has the keyboard.
- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return event && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.nameArea);
}

- (void)mouseDown:(NSEvent*)event {
    if (!NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.nameArea)) {
        [super mouseDown:event];
        return;
    }
    [self beginEditing];
}

- (void)beginEditing {
    if (!_editable || _edit) return;
    _hovered = NO;
    // The field takes the whole byline, so a long name has room while it is typed.
    NSFont* font = [NSFont systemFontOfSize:11];
    CGFloat height = ceil(font.ascender - font.descender) + 3;
    NSRect frame = NSMakeRect(0, floor((NSHeight(self.bounds) - height) / 2), NSWidth(self.bounds), height);
    __weak SPDFMacCommentAuthorByline* weakSelf = self;
    _edit = [SPDFCommentAuthorNameEdit editName:_name
                                         inView:self
                                          frame:frame
                                           font:font
                                      alignment:NSTextAlignmentRight
                                           done:^(NSString* name, BOOL byKey) {
                                             [weakSelf editEndedWith:name byKey:byKey];
                                           }];
    [self refreshPointerAreas];
}

- (void)editEndedWith:(NSString*)name byKey:(BOOL)byKey {
    _edit = nil;
    if (name) {
        self.name = name;
        if (self.changed) self.changed(name);
    }
    [self refreshPointerAreas];
    if (byKey && self.keyboardHome) [self.window makeFirstResponder:self.keyboardHome];
}

- (void)commitEditing {
    [_edit commit];
}

- (void)cancelEditing {
    [_edit cancel];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (_edit || !_name.length) return;
    NSRect name = [self nameRect];
    NSFont* font = [NSFont systemFontOfSize:11];
    CGFloat textHeight = ceil(font.ascender - font.descender);
    [_name drawWithRect:NSMakeRect(NSMinX(name), floor((NSHeight(self.bounds) - textHeight) / 2), NSWidth(name), textHeight)
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
             attributes:[self nameStyle]];
    if (_hovered && _editable) {
        NSImage* pencil = self.pencil;
        NSSize size = pencil.size;
        [pencil drawInRect:NSMakeRect(NSMaxX(name) + kPencilGap, floor((NSHeight(self.bounds) - size.height) / 2), size.width,
                                      size.height)];
    }
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    return _editable ? NSAccessibilityButtonRole : NSAccessibilityStaticTextRole;
}
- (NSString*)accessibilityHelp {
    return _editable ? SPDFCommentAuthorToolTip : nil;
}
- (BOOL)accessibilityPerformPress {
    if (!_editable) return NO;
    [self beginEditing];
    return YES;
}

@end
