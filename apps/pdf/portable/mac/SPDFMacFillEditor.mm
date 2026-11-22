#import "SPDFMacFillEditor.h"

#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacSignatureStore.h"

@implementation SPDFMacFillSuggestion
+ (instancetype)suggestionWithText:(NSString*)text {
    SPDFMacFillSuggestion* s = [SPDFMacFillSuggestion new];
    s.text = text;
    return s;
}
@end

@class SPDFFillTextView;
@protocol SPDFFillTextViewOwner
- (BOOL)fillTextViewKeyEquivalent:(NSEvent*)event;
- (void)fillTextViewDidResign;
@end

// The text view itself: reports leaving (a click elsewhere commits) and the Command keys it takes over while typing.
@interface SPDFFillTextView : NSTextView
@property(nonatomic, weak) id<SPDFFillTextViewOwner> owner;
@end
@implementation SPDFFillTextView
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (self.window.firstResponder == self && [self.owner fillTextViewKeyEquivalent:event]) return YES;
    return [super performKeyEquivalent:event];
}
- (BOOL)resignFirstResponder {
    BOOL resigned = [super resignFirstResponder];
    if (resigned) dispatch_async(dispatch_get_main_queue(), ^{ [self.owner fillTextViewDidResign]; });
    return resigned;
}
@end

// The row of suggestions under an empty box.
@interface SPDFFillChipsView : NSView
@end
@implementation SPDFFillChipsView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:8 yRadius:8];
    [SPDFCollectionColor(@"popover") setFill];
    [shape fill];
    [SPDFCollectionColor(@"lineStrong") setStroke];
    [shape stroke];
}
@end

@interface SPDFMacFillEditor () <NSTextViewDelegate, SPDFFillTextViewOwner>
@end

@implementation SPDFMacFillEditor {
    SPDFFillTextView* _textView;
    SPDFFillChipsView* _chips;
    NSArray<SPDFMacFillSuggestion*>* _suggestions;
    NSInteger _highlighted;
    BOOL _closed;
    BOOL _committing;
    __weak SPDFMacFillOverlayView* _overlay;
}

- (BOOL)isFlipped { return YES; }

- (NSString*)text {
    return _textView.string ?: @"";
}

- (NSFont*)fontAtZoom:(CGFloat)zoom {
    return [NSFont fontWithName:@"Helvetica" size:MAX(1.0, self.fontSize * zoom)] ?: [NSFont systemFontOfSize:self.fontSize * zoom];
}

- (BOOL)placedText {
    return !self.field;
}

- (NSDictionary*)attributesAtZoom:(CGFloat)zoom {
    NSFont* font = [self fontAtZoom:zoom];
    NSMutableParagraphStyle* paragraph = [NSMutableParagraphStyle new];
    if ([self placedText]) {
        // MuPDF's typewriter text: lines 1.2 x the size apart (spdf_fill_text_rect).
        paragraph.minimumLineHeight = paragraph.maximumLineHeight = 1.2 * self.fontSize * zoom;
    }
    NSMutableDictionary* attrs = [@{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : self.darkPage ? [NSColor colorWithWhite:0.92 alpha:1] : NSColor.blackColor,
        NSParagraphStyleAttributeName : paragraph
    } mutableCopy];
    if (self.combCells.count) {
        CGFloat cell = NSWidth(self.combCells.firstObject.rectValue);
        CGFloat advance = [@"0" sizeWithAttributes:@{NSFontAttributeName : [self fontAtZoom:1]}].width;
        attrs[NSKernAttributeName] = @(MAX(0.0, cell - advance) * zoom);
    }
    return attrs;
}

// How far below the top of its first line the text view puts the first baseline.
static CGFloat SPDFFirstBaseline(NSDictionary* attrs) {
    NSTextStorage* storage = [[NSTextStorage alloc] initWithString:@"Hg" attributes:attrs];
    NSLayoutManager* layout = [NSLayoutManager new];
    NSTextContainer* container = [[NSTextContainer alloc] initWithSize:NSMakeSize(1e6, 1e6)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];
    [storage addLayoutManager:layout];
    [layout ensureLayoutForTextContainer:container];
    NSRect line = [layout lineFragmentRectForGlyphAtIndex:0 effectiveRange:NULL];
    return NSMinY(line) + [layout locationForGlyphAtIndex:0].y;
}

- (void)beginInOverlay:(SPDFMacFillOverlayView*)overlay
                  text:(NSString*)text
           suggestions:(NSArray<SPDFMacFillSuggestion*>*)suggestions
           highlighted:(NSInteger)highlighted {
    _overlay = overlay;
    self.originalText = text ?: @"";
    _suggestions = suggestions ?: @[];
    _highlighted = highlighted;
    _textView = [[SPDFFillTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 20)];
    _textView.owner = self;
    _textView.delegate = self;
    _textView.richText = NO;
    _textView.importsGraphics = NO;
    _textView.allowsUndo = YES;
    _textView.automaticQuoteSubstitutionEnabled = NO;
    _textView.automaticDashSubstitutionEnabled = NO;
    _textView.automaticTextReplacementEnabled = NO;
    _textView.automaticSpellingCorrectionEnabled = NO;
    _textView.textContainerInset = NSZeroSize;
    _textView.textContainer.lineFragmentPadding = 0;
    _textView.focusRingType = NSFocusRingTypeNone;
    _textView.insertionPointColor = NSColor.controlAccentColor;
    [self addSubview:_textView];
    _chips = [[SPDFFillChipsView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_chips];
    [overlay addSubview:self];
    [self layoutInOverlay:overlay];
    _textView.string = self.originalText;
    [self applyAttributes];
    [self rebuildChips];
    [self layoutInOverlay:overlay];
    [self.window makeFirstResponder:_textView];
    [_textView selectAll:nil];
}

- (void)applyAttributes {
    NSDictionary* attrs = [self attributesAtZoom:[_overlay zoom]];
    _textView.typingAttributes = attrs;
    if (_textView.textStorage.length) [_textView.textStorage setAttributes:attrs range:NSMakeRange(0, _textView.textStorage.length)];
    _textView.font = attrs[NSFontAttributeName];
}

- (void)layoutInOverlay:(SPDFMacFillOverlayView*)overlay {
    if (_closed || !overlay) return;
    _overlay = overlay;
    CGFloat zoom = [overlay zoom];
    NSRect box = [overlay viewRectForPageRect:self.box page:self.page];
    if (NSIsEmptyRect(box)) return;
    [self applyAttributes];
    NSDictionary* attrs = _textView.typingAttributes;
    NSFont* font = attrs[NSFontAttributeName];
    _textView.backgroundColor = self.darkPage ? [NSColor colorWithWhite:0.11 alpha:1] : NSColor.whiteColor;
    NSRect textFrame = box;
    if ([self placedText]) {
        // The first baseline goes where MuPDF will draw it.
        CGFloat baseline = spdf_fill_text_baseline(SPDFFillRectToCore(self.box), (float)self.fontSize);
        CGFloat baselineInView = [overlay viewRectForPageRect:NSMakeRect(self.box.origin.x, baseline, 1, 1) page:self.page].origin.y;
        CGFloat lineHeight = 1.2 * self.fontSize * zoom;
        NSUInteger lines = MAX((NSUInteger)1, (NSUInteger)[self lineCount]);
        CGFloat textWidth = 0;
        for (NSString* line in [self.text componentsSeparatedByString:@"\n"])
            textWidth = MAX(textWidth, [line sizeWithAttributes:attrs].width);
        textFrame.origin.y = baselineInView - SPDFFirstBaseline(attrs);
        textFrame.size.width = MAX(NSWidth(box), textWidth + 4 + font.pointSize * 0.5);
        textFrame.size.height = MAX(lineHeight * lines, font.ascender - font.descender);
        _textView.textContainer.containerSize = NSMakeSize(1e6, 1e6);
        _textView.textContainer.widthTracksTextView = NO;
        _textView.horizontallyResizable = YES;
        // Over existing text the box is opaque so the old words never show through; new text keeps the line visible.
        _textView.drawsBackground = self.item != nil || self.combItems.count > 0;
    } else {
        _textView.drawsBackground = YES;
        _textView.textContainer.widthTracksTextView = YES;
        _textView.horizontallyResizable = NO;
        CGFloat lineHeight = font.ascender - font.descender + font.leading;
        CGFloat inset = self.multiline ? 2 * zoom : MAX(0.0, (NSHeight(box) - lineHeight) / 2);
        CGFloat side = self.combCells.count ? MAX(0.0, (NSWidth(self.combCells.firstObject.rectValue) -
                                                   [@"0" sizeWithAttributes:@{NSFontAttributeName : [self fontAtZoom:1]}].width) / 2 * zoom)
                                            : 2 * zoom;
        _textView.textContainerInset = NSMakeSize(side, inset);
    }
    if ([self placedText] && self.combCells.count) {
        CGFloat side = MAX(0.0, (NSWidth(self.combCells.firstObject.rectValue) -
                                 [@"0" sizeWithAttributes:@{NSFontAttributeName : [self fontAtZoom:1]}].width) / 2 * zoom);
        _textView.textContainerInset = NSMakeSize(side, 0);
        textFrame.origin.x = box.origin.x;
    }
    BOOL chipsVisible = _suggestions.count > 0 && [self visibleSuggestions].count > 0;
    _chips.hidden = !chipsVisible;
    CGFloat chipsHeight = chipsVisible ? 34 : 0;
    CGFloat chipsWidth = chipsVisible ? [self chipsWidth] : 0;
    NSRect frame = NSMakeRect(NSMinX(textFrame), NSMinY(textFrame), MAX(NSWidth(textFrame), chipsWidth),
                              NSHeight(textFrame) + (chipsVisible ? chipsHeight + 6 : 0));
    self.frame = NSIntegralRectWithOptions(frame, NSAlignAllEdgesNearest);
    _textView.frame = NSMakeRect(0, 0, NSWidth(textFrame), NSHeight(textFrame));
    _chips.frame = NSMakeRect(0, NSHeight(textFrame) + 6, chipsWidth, chipsHeight);
}

- (NSInteger)lineCount {
    return (NSInteger)[self.text componentsSeparatedByString:@"\n"].count;
}

- (NSRect)placedTextBox {
    NSDictionary* attrs = [self attributesAtZoom:1];
    CGFloat width = 0;
    for (NSString* line in [self.text componentsSeparatedByString:@"\n"])
        width = MAX(width, [line sizeWithAttributes:attrs].width);
    CGFloat baseline = spdf_fill_text_baseline(SPDFFillRectToCore(self.box), (float)self.fontSize);
    return SPDFFillRectFromCore(spdf_fill_text_rect((float)NSMinX(self.box), baseline,
                                                    (float)MAX(NSWidth(self.box), width + 2), (float)self.fontSize,
                                                    (int)[self lineCount]));
}

#pragma mark - Suggestions

- (NSArray<SPDFMacFillSuggestion*>*)visibleSuggestions {
    NSString* typed = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([self.text containsString:@"\n"] || (typed.length && [typed isEqual:self.originalText])) return @[];
    NSMutableArray* shown = [NSMutableArray array];
    for (SPDFMacFillSuggestion* s in _suggestions) {
        if (typed.length && [s.text rangeOfString:typed options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == NSNotFound)
            continue;
        if (typed.length && [s.text caseInsensitiveCompare:typed] == NSOrderedSame) continue;
        [shown addObject:s];
    }
    return shown;
}

- (CGFloat)chipsWidth {
    CGFloat width = 8;
    for (NSView* chip in _chips.subviews) width += NSWidth(chip.frame) + 4;
    return width + 4;
}

- (void)rebuildChips {
    for (NSView* view in _chips.subviews.copy) [view removeFromSuperview];
    NSArray* shown = [self visibleSuggestions];
    CGFloat x = 8;
    for (NSUInteger i = 0; i < shown.count && i < 6; ++i) {
        SPDFMacFillSuggestion* s = shown[i];
        NSButton* chip = SPDFCollectionButton(s.text, self, @selector(chipClicked:), @"quiet");
        chip.tag = (NSInteger)i;
        chip.state = (NSInteger)i == _highlighted ? NSControlStateValueOn : NSControlStateValueOff;
        chip.frame = NSMakeRect(x, 2, MIN(220, chip.intrinsicContentSize.width), 30);
        [_chips addSubview:chip];
        x += NSWidth(chip.frame) + 4;
    }
    if (shown.count) {
        NSButton* edit = SPDFCollectionButton(@"Edit My Details…", self, @selector(editDetails:), @"link");
        edit.frame = NSMakeRect(x, 2, edit.intrinsicContentSize.width, 30);
        [_chips addSubview:edit];
    }
}

- (void)chipClicked:(NSButton*)sender {
    NSArray* shown = [self visibleSuggestions];
    if (sender.tag < 0 || sender.tag >= (NSInteger)shown.count) return;
    _textView.string = [shown[(NSUInteger)sender.tag] text];
    self.dirty = YES;
    [self.delegate fillEditor:self commitMoving:0];
}

- (void)editDetails:(id)sender {
    (void)sender;
    [self.delegate fillEditorEditDetails:self];
}

- (void)setSuggestions:(NSArray<SPDFMacFillSuggestion*>*)suggestions {
    _suggestions = suggestions ?: @[];
    [self rebuildChips];
    [self layoutInOverlay:_overlay];
}

#pragma mark - Typing

- (void)textDidChange:(NSNotification*)note {
    (void)note;
    self.dirty = YES;
    _highlighted = -1;
    [self rebuildChips];
    [self layoutInOverlay:_overlay];
}

- (BOOL)textView:(NSTextView*)textView shouldChangeTextInRange:(NSRange)range replacementString:(NSString*)string {
    (void)textView;
    NSInteger limit = self.combCells.count ? (NSInteger)self.combCells.count : self.maxLength;
    if (limit <= 0 || !string) return YES;
    NSInteger after = (NSInteger)self.text.length - (NSInteger)range.length + (NSInteger)string.length;
    return after <= limit || string.length == 0;
}

- (BOOL)textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)textView;
    NSArray* shown = [self visibleSuggestions];
    if (command == @selector(moveDown:) && shown.count && ![self.text containsString:@"\n"]) {
        _highlighted = (_highlighted + 1) % (NSInteger)MIN((NSUInteger)6, shown.count);
        [self rebuildChips];
        return YES;
    }
    if (command == @selector(moveUp:) && shown.count && _highlighted >= 0) {
        _highlighted = _highlighted - 1;
        [self rebuildChips];
        return YES;
    }
    if (command == @selector(insertNewline:)) {
        if (_highlighted >= 0 && _highlighted < (NSInteger)shown.count) {
            _textView.string = [shown[(NSUInteger)_highlighted] text];
            self.dirty = YES;
            [self.delegate fillEditor:self commitMoving:0];
            return YES;
        }
        if (self.multiline) return NO;  // a new line
        [self.delegate fillEditor:self commitMoving:self.field ? 1 : 0];
        return YES;
    }
    if (command == @selector(insertNewlineIgnoringFieldEditor:)) {
        if (self.multiline || ([self placedText] && !self.combCells.count)) {
            [_textView insertText:@"\n" replacementRange:_textView.selectedRange];
            return YES;
        }
        return NO;
    }
    if (command == @selector(insertTab:) || command == @selector(insertBacktab:)) {
        [self.delegate fillEditor:self commitMoving:command == @selector(insertTab:) ? 1 : -1];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        [self.delegate fillEditorDidCancel:self];
        return YES;
    }
    return NO;
}

- (BOOL)fillTextViewKeyEquivalent:(NSEvent*)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(mods & NSEventModifierFlagCommand)) return NO;
    NSString* key = event.charactersIgnoringModifiers;
    if ([key isEqual:@"\r"]) {
        [self.delegate fillEditor:self commitMoving:0];
        return YES;
    }
    if ([key.lowercaseString isEqual:@"y"] && _textView.undoManager.canRedo) {  // Command-Y redoes typing too
        [_textView.undoManager redo];
        return YES;
    }
    if ([self placedText] && ([key isEqual:@"+"] || [key isEqual:@"="] || [key isEqual:@"-"])) {
        self.fontSize = MAX(6.0, MIN(72.0, self.fontSize + ([key isEqual:@"-"] ? -1 : 1)));
        self.dirty = YES;
        [self layoutInOverlay:_overlay];
        return YES;
    }
    return NO;
}

- (void)fillTextViewDidResign {
    if (_closed || _committing) return;
    if (self.window.firstResponder == _textView) return;
    [self.delegate fillEditor:self commitMoving:0];
}

- (NSMenu*)textView:(NSTextView*)view menu:(NSMenu*)menu forEvent:(NSEvent*)event atIndex:(NSUInteger)index {
    (void)view;
    (void)event;
    (void)index;
    if (self.text.length) {
        [menu insertItem:[NSMenuItem separatorItem] atIndex:0];
        NSMenuItem* save = [[NSMenuItem alloc] initWithTitle:@"Save for Next Time" action:@selector(saveForNextTime:)
                                               keyEquivalent:@""];
        save.target = self;
        [menu insertItem:save atIndex:0];
    }
    return menu;
}

- (void)saveForNextTime:(id)sender {
    (void)sender;
    [[SPDFMacSignatureStore sharedStore] addSavedText:self.text];
}

#pragma mark - Ending

- (void)commitAndClose {
    if (_closed || _committing) return;
    [self.delegate fillEditor:self commitMoving:0];
}

- (void)flushIfNeeded {
    if (_closed || !self.dirty) return;
    [self.delegate fillEditorFlush:self];
    self.dirty = NO;
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    BOOL hadFocus = self.window.firstResponder == _textView;
    NSWindow* window = self.window;
    NSView* overlay = self.superview;
    [self removeFromSuperview];
    if (hadFocus && overlay.window) [window makeFirstResponder:overlay];
}

@end
