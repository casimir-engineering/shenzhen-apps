#import "SPDFMacFillPalette.h"

#import "SPDFMacAnnotatePaletteButton.h"
#import "SPDFMacAnnotatePaletteGroups.h"
#import "SPDFMacAnnotatePaletteSupport.h"
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
    SPDFMacAnnotatePaletteGroups* _groups;  // Annotate's groups, after the Fill & Sign group
    NSStackView* _row2;         // the chosen tool's options: Fill & Sign's colours and widths, Annotate's options
    NSView* _annotateOptions;
    SPDFAnnotateDocumentKind _kind;
    NSStackView* _column;
    SPDFMacFillDrawingOptions* _options;
    NSLayoutConstraint* _textIconWidth;
    NSLayoutConstraint* _signatureIconWidth;
    // Narrow page area: Annotate's groups collapse first (SPDFMacAnnotatePaletteGroups); then 1, Text and Signature
    // show icons only; 2, the progress hides too and the buttons tighten.
    NSInteger _level;
    CGFloat _labelsExtra;    // what "Text" and "Signature" take beyond their icons
    NSMutableArray<NSArray*>* _widths;  // [constraint, full width] of every fixed-width button
    NSString* _progressText;
    __weak NSView* _area;  // the page area the palette sits over (narrower than its superview beside the minimap)
    BOOL _note;          // the second line holds a note
    BOOL _placing;       // the drawing tools can be chosen
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

- (void)keepWidth:(NSLayoutConstraint*)width {
    if (!_widths) _widths = [NSMutableArray array];
    [_widths addObject:@[ width, @(width.constant) ]];
}

// The Fill & Sign group's buttons: the Annotate palette's (SPDFMacAnnotatePaletteButton.h), so both groups share one
// size and spacing. A titled one ("Text", "Signature") shows only its icon once the palette is narrow.
- (NSButton*)tool:(NSString*)title symbol:(NSString*)symbol label:(NSString*)label action:(SEL)action {
    if (title.length) return SPDFPaletteTitleButton(title, symbol, label, self, action);
    return symbol ? SPDFPaletteIconButton(symbol, label, self, action) : SPDFPaletteMenuButton(label, self, action);
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
    _signatureMenu = [self tool:@"" symbol:nil label:@"Signatures and initials" action:@selector(showSignatureMenu:)];
    NSStackView* signature = SPDFPaletteSplit((SPDFPaletteButton*)_signature, (SPDFPaletteButton*)_signatureMenu);
    _text.toolTip = @"Text (T)";
    _textIconWidth = [_text.widthAnchor constraintEqualToConstant:SPDFPaletteButtonSize];
    _signatureIconWidth = [_signature.widthAnchor constraintEqualToConstant:SPDFPaletteButtonSize];
    for (NSButton* button in @[ _check, _cross, _signatureMenu ])
        if (SPDFPaletteWidthConstraint(button)) [self keepWidth:SPDFPaletteWidthConstraint(button)];
    [self keepWidth:_textIconWidth];
    [self keepWidth:_signatureIconWidth];
    _done = SPDFCollectionButton(@"Done", self, @selector(done:), @"normal");
    _done.refusesFirstResponder = YES;
    // Done keeps its name whatever the width: it is how the mode is left.
    [_done setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    _done.translatesAutoresizingMaskIntoConstraints = NO;
    [_done.heightAnchor constraintEqualToConstant:SPDFPaletteButtonSize].active = YES;
    NSView* gap2 = SPDFPaletteSeparator();
    // On a PDF the Fill & Sign group first, then on every document Annotate's groups, then Done.
    _groups = [[SPDFMacAnnotatePaletteGroups alloc] initWithController:_controller];
    NSMutableArray* views = [@[ _progress, _text, _check, _cross, signature ] mutableCopy];
    [views addObjectsFromArray:[_groups row1ForKind:SPDFAnnotateDocumentPDF]];
    [views addObjectsFromArray:@[ gap2, _done ]];
    _row = [NSStackView stackViewWithViews:views];
    _row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _row.alignment = NSLayoutAttributeCenterY;
    _row.spacing = SPDFPaletteSpacing;  // every unit and separator the same distance apart
    _row.detachesHiddenViews = YES;
    [_row setCustomSpacing:10 afterView:_progress];
    // Row 1 keeps its own width when row 2 is wider: its buttons never spread apart.
    [_row setHuggingPriority:NSLayoutPriorityRequired - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    _options = [[SPDFMacFillDrawingOptions alloc] initWithTarget:self];
    _options.hidden = YES;
    NSLayoutConstraint* snug = [_options.widthAnchor constraintEqualToConstant:0];  // as wide as its swatches
    snug.priority = NSLayoutPriorityDefaultLow;
    snug.active = YES;
    _annotateOptions = [_groups row2ForSession:nil];
    _row2 = [NSStackView stackViewWithViews:@[ _options, _annotateOptions ]];
    _row2.spacing = 12;
    _row2.detachesHiddenViews = YES;
    _row2.translatesAutoresizingMaskIntoConstraints = NO;
    [_row2 setHuggingPriority:NSLayoutPriorityRequired - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _hint = SPDFCollectionText(@"Click a highlighted field to type. What you enter is saved as you go.", 11,
                               NSFontWeightRegular, YES);
    _hint.translatesAutoresizingMaskIntoConstraints = NO;
    _hint.alignment = NSTextAlignmentCenter;
    // The tools, then the drawing options while a drawing tool is chosen, then the hint or note; hidden rows take
    // no room.
    _column = [NSStackView stackViewWithViews:@[ _row, _row2, _hint ]];
    _column.orientation = NSUserInterfaceLayoutOrientationVertical;
    _column.alignment = NSLayoutAttributeLeading;  // the options start under the first tool: one grid for both rows
    _column.spacing = 3;
    _column.detachesHiddenViews = YES;
    _column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_column];
    [NSLayoutConstraint activateConstraints:@[
        [_column.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
        [_column.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
        [_column.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [self.bottomAnchor constraintEqualToAnchor:_column.bottomAnchor constant:5],
    ]];
}

// On a narrow window Text and Signature drop their names before anything else is squeezed; narrower still, the
// progress hides and the buttons sit closer. Done always keeps its name.
- (void)layout {
    [super layout];
    NSView* area = _area ?: self.superview;
    if (!area) return;
    CGFloat available = NSWidth(area.bounds) - 16;
    // Annotate's groups get what the Fill & Sign group and Done leave. Text and Signature drop their names before
    // the Tools group folds into its icon (level 1); level 2 only once every group is in More and it still is too wide.
    CGFloat groups = _groups.currentWidth;
    CGFloat fixed = ceil(_row.fittingSize.width) + 16 - groups;
    if (_level == 0 && !_text.hidden)
        _labelsExtra = MAX(0, ceil(_text.fittingSize.width) + ceil(_signature.fittingSize.width) - 2 * SPDFPaletteButtonSize);
    CGFloat named = fixed + (_level >= 1 ? _labelsExtra : 0);
    [_groups layoutRow1InWidth:available - named];
    NSInteger level = _groups.collapseStep >= 3 ? 1 : 0;
    if (level >= 1) {
        [_groups layoutRow1InWidth:available - (named - _labelsExtra)];
        if (_groups.collapseStep >= 10 && named - _labelsExtra + _groups.currentWidth > available + 0.5) level = 2;
    }
    if (fabs(_groups.currentWidth - groups) > 0.5) self.needsLayout = YES;
    if (level == _level) return;
    _level = level;
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyLevel]; });
}

- (void)areaChanged:(NSNotification*)note {
    (void)note;
    self.needsLayout = YES;
}

- (void)applyLevel {
    BOOL compact = _level >= 1, tight = _level >= 2;
    _text.title = compact ? @"" : @"Text";
    _text.image = compact ? SPDFPaletteSymbol(@"textformat", @"Text") : nil;
    _signature.title = compact ? @"" : @"Signature";
    _textIconWidth.active = compact && _text.image;
    _signatureIconWidth.active = compact;
    if (compact && !_text.image) _text.title = @"Text";
    for (NSArray* kept in _widths) {
        NSLayoutConstraint* c = kept[0];
        c.constant = tight ? [kept[1] doubleValue] - 4 : [kept[1] doubleValue];
    }
    _row.spacing = tight ? 1 : SPDFPaletteSpacing;
    _progress.hidden = tight || !_progressText.length;
    self.needsLayout = YES;  // measure again: one level may not be enough
}

- (void)attachToContainer:(NSView*)container aboveView:(NSView*)view {
    [self removeFromSuperview];
    if (!container) return;
    [container addSubview:self positioned:NSWindowAbove relativeTo:nil];
    // The page area narrows when the side panels open: measure again then, even if the palette keeps its size.
    if (_area)
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:_area];
    _area = view;
    view.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(areaChanged:)
                                               name:NSViewFrameDidChangeNotification object:view];
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

// The Fill & Sign tool a PDF's session holds, as tool.choose names it.
static NSString* SPDFPaletteFillToolName(SPDFFillSession* session) {
    switch (session.tool) {
        case SPDFFillToolText: return @"form_text";
        case SPDFFillToolMark: return @"form_mark";
        case SPDFFillToolSignature: return @"form_signature";
        case SPDFFillToolPen: return @"pen";
        case SPDFFillToolArrow: return @"arrow";
        case SPDFFillToolEraser: return @"eraser";
        case SPDFFillToolSelect: return @"select";
    }
    return @"form_text";
}

- (void)updateFromSession:(SPDFFillSession*)session progress:(NSString*)progress note:(NSString*)note {
    _kind = SPDFAnnotateCurrentKind(_controller);
    BOOL pdf = _kind == SPDFAnnotateDocumentPDF;
    SPDFMacAnnotateSession* annotate = SPDFAnnotateCurrentSession(_controller, _kind != SPDFAnnotateDocumentNone);
    // On a PDF, Fill & Sign's own tools change inside Fill & Sign too (a signature placed goes back to Text): the
    // Annotate session follows it while one of them is chosen.
    NSString* tool = SPDFAnnotateChosenToolName(annotate);
    NSSet* fillTools = [NSSet setWithArray:@[ @"form_text", @"form_mark", @"form_signature", @"pen", @"arrow", @"select", @"" ]];
    if (pdf && session && [fillTools containsObject:tool]) {
        tool = SPDFPaletteFillToolName(session);
        if (annotate) annotate.tool = (SPDFAnnotateTool)[@{@"form_text" : @(SPDFAnnotateToolFormText),
            @"form_mark" : @(SPDFAnnotateToolFormMark), @"form_signature" : @(SPDFAnnotateToolFormSignature),
            @"pen" : @(SPDFAnnotateToolPen), @"arrow" : @(SPDFAnnotateToolArrow), @"eraser" : @(SPDFAnnotateToolEraser),
            @"select" : @(SPDFAnnotateToolSelect)}[tool] integerValue];
    }
    _progressText = pdf ? progress : nil;
    _progress.stringValue = _progressText ?: @"";
    _progress.hidden = _progressText.length == 0 || _level >= 2;
    for (NSView* v in @[ _text, _check, _cross, _signature.superview ]) v.hidden = !pdf;
    _text.state = [tool isEqual:@"form_text"] ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL mark = [tool isEqual:@"form_mark"];
    _check.state = mark && !session.markCross ? NSControlStateValueOn : NSControlStateValueOff;
    _cross.state = mark && session.markCross ? NSControlStateValueOn : NSControlStateValueOff;
    _signature.state = [tool isEqual:@"form_signature"] ? NSControlStateValueOn : NSControlStateValueOff;
    _signatureMenu.state = _done.state = NSControlStateValueOff;  // a click turns them on; they are never "chosen"
    // Fill & Sign's colours and widths: Pen and Arrow everywhere, Select on a PDF (restyles the selected lines).
    BOOL lines = [tool isEqual:@"pen"] || [tool isEqual:@"arrow"] || (pdf && [tool isEqual:@"select"]);
    _options.hidden = !lines;
    if (lines) {
        SPDFFillTool fillTool = [tool isEqual:@"pen"] ? SPDFFillToolPen : [tool isEqual:@"arrow"] ? SPDFFillToolArrow : SPDFFillToolSelect;
        [_options showTool:fillTool selectionColor:[_controller selectionColorIndex]
                     width:[_controller selectionWidthIndex] styleable:[_controller selectionHasDrawings]];
    }
    BOOL placing = !pdf || !session.hasSummary || session.summary.can_add_items;
    _groups.enabled = placing;
    [_groups updateFromSession:annotate progress:_progressText];
    _annotateOptions.hidden = !_groups.showsRow2;
    BOOL drawing = !_options.hidden || _groups.showsRow2;
    _row2.hidden = !drawing;
    _hint.stringValue = note.length ? note : @"Click a highlighted field to type. What you enter is saved as you go.";
    _hint.hidden = !note.length && (drawing || !pdf || !session.isForm || [SPDFMacSignatureStore sharedStore].formHintSeen);
    // A longer note wraps at the width of the tools (or of the first-form hint) instead of widening the palette.
    CGFloat wrap = MAX(ceil(_row.fittingSize.width) - 8, 370);
    if (_area && NSWidth(_area.bounds) > 100) wrap = MIN(wrap, NSWidth(_area.bounds) - 40);  // within the pages
    _hint.preferredMaxLayoutWidth = wrap;
    _note = note.length > 0;
    _placing = placing;
    for (NSButton* button in @[ _text, _check, _cross, _signature, _signatureMenu ]) button.enabled = placing;
}

- (SPDFMacAnnotatePaletteGroups*)annotateGroups {
    return _groups;
}

- (void)refresh {
    [_controller refreshChrome];
}

- (CGFloat)reservedHeight {
    [self layoutSubtreeIfNeeded];
    CGFloat height = ceil(self.fittingSize.height);
    if (!_placing) return height;
    // The tools, the drawing options under them, then the note if there is one (the first-form hint is shorter
    // than the options and gives way to them).
    CGFloat withOptions = 10 + ceil(_row.fittingSize.height) + 3 +
                          MAX(ceil(_options.fittingSize.height), _groups.tallestRow2Height);
    if (_note) withOptions += 3 + ceil(_hint.fittingSize.height);
    return MAX(height, withOptions);
}

#pragma mark - Actions

// The Fill & Sign group's tools are operations like every other tool (tool.choose), so keys and agents agree.
- (void)chooseText:(id)sender {
    (void)sender;
    SPDFAnnotateChooseTool(_controller, @"form_text", nil);
}

- (void)chooseMark:(BOOL)cross {
    SPDFAnnotateChooseTool(_controller, @"form_mark", @{@"kind" : cross ? @"cross" : @"check"});
}

#pragma mark - Drawing options

- (NSString*)hexForFillColor:(NSInteger)index {
    SPDFFillRGB c = [SPDFMacFillDrawingStyle colorAtIndex:index];
    return SPDFAnnotateHex(((spdf_paint_color)lround(c.r * 255) << 24) | ((spdf_paint_color)lround(c.g * 255) << 16) |
                           ((spdf_paint_color)lround(c.b * 255) << 8) | 0xFFu);
}

// Pen and Arrow remember the colour and width chosen here (tool.choose options) as well as Fill & Sign's style.
- (void)chooseLineOptions:(NSDictionary*)options {
    NSString* tool = SPDFAnnotateChosenToolName(SPDFAnnotateCurrentSession(_controller, NO));
    if ([tool isEqual:@"pen"] || [tool isEqual:@"arrow"]) SPDFAnnotateChooseTool(_controller, tool, options);
}

- (void)drawingOptionsChoseColor:(NSInteger)index {
    [SPDFMacFillDrawingStyle sharedStyle].colorIndex = index;
    [self chooseLineOptions:@{@"color" : [self hexForFillColor:index]}];
    if ([_controller session].tool == SPDFFillToolSelect) [_controller restyleSelectionWithColor:index width:-1];
    [self refresh];
}

- (void)drawingOptionsChoseWidth:(NSInteger)index {
    [SPDFMacFillDrawingStyle sharedStyle].widthIndex = index;
    [self chooseLineOptions:@{@"width" : @([SPDFMacFillDrawingStyle widthAtIndex:index])}];
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
    SPDFAnnotateChooseTool(_controller, @"form_signature", nil);  // the last signature used, or a new one
}

- (void)done:(id)sender {
    (void)sender;
    SPDFAnnotateSend(_controller, @{@"op" : @"mode.set", @"on" : @NO}, nil);
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
