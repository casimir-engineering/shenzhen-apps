#import "SPDFMacFillPalette.h"

#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillDrawingOptions.h"
#import "SPDFMacFillDrawingStyle.h"
#import "SPDFMacSignatureStore.h"

@interface SPDFMacFillPalette () <SPDFMacFillDrawingOptionsTarget>
@end

static NSImage* SPDFPaletteSymbol(NSString* name, NSString* description) {
    NSImage* image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    [image setTemplate:YES];
    return image;
}

@implementation SPDFMacFillPalette {
    __weak SPDFMacFillController* _controller;
    NSStackView* _row;
    NSTextField* _progress;
    NSTextField* _hint;
    NSButton* _text;
    NSButton* _check;
    NSButton* _cross;
    NSButton* _signature;
    NSButton* _signatureMenu;
    NSButton* _done;
    NSButton* _pen;
    NSButton* _arrow;
    NSButton* _eraser;
    NSButton* _select;
    NSStackView* _column;
    SPDFMacFillDrawingOptions* _options;
    NSLayoutConstraint* _textIconWidth;
    NSLayoutConstraint* _signatureIconWidth;
    CGFloat _fullWidth;  // the tools with their names, measured while they show them
    BOOL _compact;       // too narrow: Text and Signature show icons only
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _controller = controller;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.shadow = [NSShadow new];
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, -2);
        self.alphaValue = 0;
        [self build];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent*)event { (void)event; }  // clicks between buttons stay on the palette

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [SPDFCollectionColor(@"popover") setFill];
    [shape fill];
    [SPDFCollectionColor(@"lineStrong") setStroke];
    [shape stroke];
}

- (NSButton*)tool:(NSString*)title symbol:(NSString*)symbol label:(NSString*)label action:(SEL)action {
    NSButton* button = SPDFCollectionButton(title, self, action, @"quiet");
    if (symbol) button.image = SPDFPaletteSymbol(symbol, label);
    if (symbol && !button.image) button.title = label;  // a symbol this macOS lacks
    button.toolTip = label;
    button.accessibilityLabel = label;
    button.refusesFirstResponder = YES;  // the pages keep the keys: Command-Z, Delete, the tool letters
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:28].active = YES;
    if (!title.length) [button.widthAnchor constraintEqualToConstant:34].active = YES;
    return button;
}

- (void)build {
    _progress = SPDFCollectionText(@"", 11, NSFontWeightRegular, YES);
    _progress.translatesAutoresizingMaskIntoConstraints = NO;
    _progress.maximumNumberOfLines = 1;  // "3 of 12 filled" stays on one line; the note under the tools wraps instead
    [_progress setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    _text = [self tool:@"Text" symbol:nil label:@"Text" action:@selector(chooseText:)];
    _check = [self tool:@"" symbol:@"checkmark" label:@"Check" action:@selector(chooseCheck:)];
    _cross = [self tool:@"" symbol:@"xmark" label:@"Cross" action:@selector(chooseCross:)];
    _signature = [self tool:@"Signature" symbol:@"signature" label:@"Signature" action:@selector(chooseSignature:)];
    _signatureMenu = [self tool:@"" symbol:@"chevron.down" label:@"Signatures and initials" action:@selector(showSignatureMenu:)];
    for (NSLayoutConstraint* c in _signatureMenu.constraints)
        if (c.firstAttribute == NSLayoutAttributeWidth) c.constant = 24;
    _pen = [self tool:@"" symbol:@"pencil.tip" label:@"Pen" action:@selector(choosePen:)];
    _arrow = [self tool:@"" symbol:@"arrow.up.right" label:@"Arrow" action:@selector(chooseArrow:)];
    _eraser = [self tool:@"" symbol:@"eraser" label:@"Eraser" action:@selector(chooseEraser:)];
    _select = [self tool:@"" symbol:@"rectangle.dashed" label:@"Select" action:@selector(chooseSelect:)];
    NSDictionary* keys = @{@"Pen" : @"P", @"Arrow" : @"A", @"Eraser" : @"E", @"Select" : @"S"};
    for (NSButton* button in @[ _pen, _arrow, _eraser, _select ]) {
        button.toolTip = [NSString stringWithFormat:@"%@ (%@)", button.accessibilityLabel, keys[button.accessibilityLabel]];
        for (NSLayoutConstraint* c in button.constraints)
            if (c.firstAttribute == NSLayoutAttributeWidth) c.constant = 30;
    }
    _textIconWidth = [_text.widthAnchor constraintEqualToConstant:34];
    _signatureIconWidth = [_signature.widthAnchor constraintEqualToConstant:34];
    _done = SPDFCollectionButton(@"Done", self, @selector(done:), @"normal");
    _done.refusesFirstResponder = YES;
    _done.translatesAutoresizingMaskIntoConstraints = NO;
    [_done.heightAnchor constraintEqualToConstant:28].active = YES;
    NSView* gap1 = SPDFCollectionSurface(@"line");
    NSView* gap2 = SPDFCollectionSurface(@"line");
    NSView* gap3 = SPDFCollectionSurface(@"line");
    for (NSView* gap in @[ gap1, gap2, gap3 ]) {
        gap.translatesAutoresizingMaskIntoConstraints = NO;
        [gap.widthAnchor constraintEqualToConstant:1].active = YES;
        [gap.heightAnchor constraintEqualToConstant:18].active = YES;
    }
    _row = [NSStackView stackViewWithViews:@[
        _progress, _text, _check, _cross, gap1, _pen, _arrow, _eraser, _select, gap3, _signature, _signatureMenu, gap2,
        _done
    ]];
    _row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _row.alignment = NSLayoutAttributeCenterY;
    _row.spacing = 2;
    [_row setCustomSpacing:10 afterView:_progress];
    [_row setCustomSpacing:6 afterView:gap1];
    [_row setCustomSpacing:6 afterView:_cross];
    [_row setCustomSpacing:6 afterView:_signatureMenu];
    [_row setCustomSpacing:6 afterView:gap2];
    [_row setCustomSpacing:6 afterView:_select];
    [_row setCustomSpacing:6 afterView:gap3];
    [_row setCustomSpacing:0 afterView:_signature];
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    _options = [[SPDFMacFillDrawingOptions alloc] initWithTarget:self];
    _options.hidden = YES;
    _hint = SPDFCollectionText(@"Click a highlighted field to type. What you enter is saved as you go.", 11,
                               NSFontWeightRegular, YES);
    _hint.translatesAutoresizingMaskIntoConstraints = NO;
    _hint.alignment = NSTextAlignmentCenter;
    // The tools, then the drawing options while a drawing tool is chosen, then the hint or note; hidden rows take
    // no room.
    _column = [NSStackView stackViewWithViews:@[ _row, _options, _hint ]];
    _column.orientation = NSUserInterfaceLayoutOrientationVertical;
    _column.alignment = NSLayoutAttributeCenterX;
    _column.spacing = 3;
    _column.detachesHiddenViews = YES;
    _column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_column];
    [NSLayoutConstraint activateConstraints:@[
        [_column.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
        [_column.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_column.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [self.bottomAnchor constraintEqualToAnchor:_column.bottomAnchor constant:5],
        [_options.widthAnchor constraintEqualToAnchor:_column.widthAnchor],
    ]];
}

// On a narrow window Text and Signature drop their names before anything else is squeezed.
- (void)layout {
    [super layout];
    if (!_compact) _fullWidth = MAX(_fullWidth, ceil(_row.fittingSize.width) + 16);
    BOOL compact = self.superview && NSWidth(self.superview.bounds) - 16 < _fullWidth;
    if (compact == _compact) return;
    _compact = compact;
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyCompact]; });
}

- (void)applyCompact {
    _text.title = _compact ? @"" : @"Text";
    _text.image = _compact ? SPDFPaletteSymbol(@"textformat", @"Text") : nil;
    _signature.title = _compact ? @"" : @"Signature";
    _signature.imagePosition = _compact ? NSImageOnly : NSImageLeading;
    _textIconWidth.active = _compact && _text.image;
    _signatureIconWidth.active = _compact;
    if (_compact && !_text.image) _text.title = @"Text";
}

- (void)attachToContainer:(NSView*)container aboveView:(NSView*)view {
    [self removeFromSuperview];
    if (!container) return;
    [container addSubview:self positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [self.topAnchor constraintEqualToAnchor:view.topAnchor constant:10],
        [self.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [self.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor constant:-16],
    ]];
}

- (void)setHidden:(BOOL)hidden {
    BOOL appearing = self.hidden && !hidden;
    [super setHidden:hidden];
    if (appearing || (!hidden && self.alphaValue < 1)) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.15;
          self.animator.alphaValue = 1;
        }];
    }
    if (hidden) self.alphaValue = 0;
}

- (void)updateFromSession:(SPDFFillSession*)session progress:(NSString*)progress note:(NSString*)note {
    _progress.stringValue = progress ?: @"";
    _progress.hidden = progress.length == 0;
    _text.state = session.tool == SPDFFillToolText ? NSControlStateValueOn : NSControlStateValueOff;
    _check.state = session.tool == SPDFFillToolMark && !session.markCross ? NSControlStateValueOn : NSControlStateValueOff;
    _cross.state = session.tool == SPDFFillToolMark && session.markCross ? NSControlStateValueOn : NSControlStateValueOff;
    _signature.state = session.tool == SPDFFillToolSignature ? NSControlStateValueOn : NSControlStateValueOff;
    _signatureMenu.state = _done.state = NSControlStateValueOff;  // a click turns them on; they are never "chosen"
    NSDictionary* drawingTools = @{@(SPDFFillToolPen) : _pen, @(SPDFFillToolArrow) : _arrow,
                                   @(SPDFFillToolEraser) : _eraser, @(SPDFFillToolSelect) : _select};
    for (NSNumber* tool in drawingTools)
        [drawingTools[tool] setState:session.tool == tool.integerValue ? NSControlStateValueOn : NSControlStateValueOff];
    BOOL drawing = SPDFFillToolDraws(session.tool);
    _options.hidden = !drawing;
    if (drawing) [_options showTool:session.tool styleable:[_controller selectionHasDrawings]];
    _hint.stringValue = note.length ? note : @"Click a highlighted field to type. What you enter is saved as you go.";
    _hint.hidden = !note.length && (drawing || !session.isForm || [SPDFMacSignatureStore sharedStore].formHintSeen);
    // A longer note wraps at the width of the tools (or of the first-form hint) instead of widening the palette.
    _hint.preferredMaxLayoutWidth = MAX(ceil(_row.fittingSize.width) - 8, 370);
    BOOL placing = !session.hasSummary || session.summary.can_add_items;
    for (NSButton* button in @[ _text, _check, _cross, _signature, _signatureMenu, _pen, _arrow, _eraser, _select ])
        button.enabled = placing;
}

- (void)refresh {
    [_controller refreshChrome];
}

#pragma mark - Actions

- (void)chooseText:(id)sender {
    (void)sender;
    [_controller chooseTool:SPDFFillToolText];
}

- (void)chooseMark:(BOOL)cross {
    [_controller session].markCross = cross;
    [_controller chooseTool:SPDFFillToolMark];
}

- (void)choosePen:(id)sender { (void)sender; [_controller chooseTool:SPDFFillToolPen]; }
- (void)chooseArrow:(id)sender { (void)sender; [_controller chooseTool:SPDFFillToolArrow]; }
- (void)chooseEraser:(id)sender { (void)sender; [_controller chooseTool:SPDFFillToolEraser]; }
- (void)chooseSelect:(id)sender { (void)sender; [_controller chooseTool:SPDFFillToolSelect]; }

#pragma mark - Drawing options

- (void)drawingOptionsChoseColor:(NSInteger)index {
    [SPDFMacFillDrawingStyle sharedStyle].colorIndex = index;
    if ([_controller session].tool == SPDFFillToolSelect) [_controller restyleSelectionWithColor:index width:-1];
    [self refresh];
}

- (void)drawingOptionsChoseWidth:(NSInteger)index {
    [SPDFMacFillDrawingStyle sharedStyle].widthIndex = index;
    if ([_controller session].tool == SPDFFillToolSelect) [_controller restyleSelectionWithColor:-1 width:index];
    [self refresh];
}

- (void)drawingOptionsChoseEraserParts:(BOOL)parts {
    [SPDFMacFillDrawingStyle sharedStyle].eraserParts = parts;
    [self refresh];
}

- (void)drawingOptionsChoseEraserSize:(NSInteger)index {
    [SPDFMacFillDrawingStyle sharedStyle].eraserSizeIndex = index;
    [self refresh];
}

- (void)drawingOptionsRemoveAll {
    [_controller removeAllDrawings];
}

- (void)chooseCheck:(id)sender { (void)sender; [self chooseMark:NO]; }
- (void)chooseCross:(id)sender { (void)sender; [self chooseMark:YES]; }

- (void)chooseSignature:(id)sender {
    (void)sender;
    SPDFMacSignature* last = [[SPDFMacSignatureStore sharedStore] lastUsedForInitials:NO];
    if (last) [_controller pickUpSignature:last];
    else [_controller addSignatureWithInitials:NO];
}

- (void)done:(id)sender {
    (void)sender;
    [_controller setOn:NO];
}

- (NSMenuItem*)itemForSignature:(SPDFMacSignature*)signature action:(SEL)action {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"" action:action keyEquivalent:@""];
    item.image = [signature thumbnailWithHeight:28];
    item.representedObject = signature;
    item.target = self;
    item.accessibilityLabel = signature.initials ? @"Initials" : @"Signature";
    return item;
}

- (void)showSignatureMenu:(NSButton*)sender {
    sender.state = NSControlStateValueOff;  // not left looking chosen once the menu closes
    SPDFMacSignatureStore* store = [SPDFMacSignatureStore sharedStore];
    NSArray* signatures = [store signaturesForInitials:NO];
    NSArray* initials = [store signaturesForInitials:YES];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Signature"];
    for (SPDFMacSignature* s in signatures) [menu addItem:[self itemForSignature:s action:@selector(useSignature:)]];
    if (initials.count) {
        if (signatures.count) [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Initials" action:nil keyEquivalent:@""].enabled = NO;
        for (SPDFMacSignature* s in initials) [menu addItem:[self itemForSignature:s action:@selector(useSignature:)]];
    }
    if (menu.numberOfItems) [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Add Signature…" action:@selector(addSignature:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Add Initials…" action:@selector(addInitials:) keyEquivalent:@""].target = self;
    if (signatures.count || initials.count) {
        NSMenu* removeMenu = [[NSMenu alloc] initWithTitle:@"Remove"];
        for (SPDFMacSignature* s in [signatures arrayByAddingObjectsFromArray:initials])
            [removeMenu addItem:[self itemForSignature:s action:@selector(removeSignature:)]];
        NSMenuItem* remove = [menu addItemWithTitle:@"Remove" action:nil keyEquivalent:@""];
        remove.submenu = removeMenu;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}

- (void)useSignature:(NSMenuItem*)sender {
    [_controller pickUpSignature:sender.representedObject];
}

- (void)addSignature:(id)sender {
    (void)sender;
    [_controller addSignatureWithInitials:NO];
}

- (void)addInitials:(id)sender {
    (void)sender;
    [_controller addSignatureWithInitials:YES];
}

- (void)removeSignature:(NSMenuItem*)sender {
    [[SPDFMacSignatureStore sharedStore] removeSignature:sender.representedObject];
    SPDFFillSession* session = [_controller session];
    if ([session.pickedSignature.identifier isEqual:[sender.representedObject identifier]]) {
        [_controller endInteraction];
        [self refresh];
    }
}

@end
