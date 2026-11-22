#import "SPDFMacOCRChoicePopover.h"
#import "SPDFMacPictureText.h"

@interface SPDFMacOCRChoicePopover () <NSPopoverDelegate>
@end
@implementation SPDFMacOCRChoicePopover {
    void (^_run)(NSString*, NSDictionary<NSString*, NSString*>*);
    NSStackView* _languageRow;
    NSTextField* _languageFound;
    NSButton* _button;
    id _keyMonitor;  // Tab, ⌘1, ⌘2, Return and Escape while the popover is open
}
static SPDFMacOCRChoicePopover* gShown;  // the popover on screen keeps its controller

+ (instancetype)shownPicker { return gShown; }
+ (instancetype)showRelativeToView:(NSView*)anchor languages:(NSArray<NSDictionary<NSString*, NSString*>*>*)languages
                               run:(void (^)(NSString*, NSDictionary<NSString*, NSString*>*))run {
    [gShown close];
    SPDFMacOCRChoicePopover* picker = [[self alloc] initWithLanguages:languages run:run];
    gShown = picker;
    [picker.popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxY];
    [picker.popover.contentViewController.view.window makeKeyWindow];
    __weak SPDFMacOCRChoicePopover* weakPicker = picker;
    picker->_keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event) {
        SPDFMacOCRChoicePopover* shown = weakPicker;
        if (!shown || gShown != shown) return event;
        NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSString* key = event.charactersIgnoringModifiers;
        if (flags == NSEventModifierFlagCommand && [key isEqualToString:@"1"]) { [shown chooseOpenSource:YES]; return nil; }
        if (flags == NSEventModifierFlagCommand && [key isEqualToString:@"2"]) { [shown chooseOpenSource:NO]; return nil; }
        if (event.keyCode == 48) { [shown chooseOpenSource:shown.engine.selectedSegment != 0]; return nil; }  // Tab
        if (event.keyCode == 36 || event.keyCode == 76) { [shown runChosen]; return nil; }                    // Return
        if (event.keyCode == 53) { [shown close]; return nil; }                                               // Escape
        return event;
    }];
    return picker;
}

- (instancetype)initWithLanguages:(NSArray<NSDictionary<NSString*, NSString*>*>*)languages
                              run:(void (^)(NSString*, NSDictionary<NSString*, NSString*>*))run {
    if (!(self = [super init])) return nil;
    _run = [run copy];
    _engine = [NSSegmentedControl segmentedControlWithLabels:@[@"Open source", @"macOS"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(engineClicked:)];
    _engine.segmentDistribution = NSSegmentDistributionFillEqually;
    _engine.refusesFirstResponder = YES;
    _engine.accessibilityLabel = @"Read the text with";
    [_engine setToolTip:@"Tesseract, the open-source OCR (Tab or ⌘1)" forSegment:0];
    [_engine setToolTip:@"Apple's text recognition, built into macOS (Tab or ⌘2)" forSegment:1];

    _language = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSString* chosen = SPDFMacOCROpenSourceLanguage();
    for (NSDictionary* language in languages) {
        [_language addItemWithTitle:language[@"name"] ?: language[@"code"]];
        _language.lastItem.representedObject = language;
        if ([language[@"code"] isEqualToString:chosen]) [_language selectItem:_language.lastItem];
    }
    _language.accessibilityLabel = @"Language";
    NSTextField* label = [NSTextField labelWithString:@"Language"];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    _languageRow = [NSStackView stackViewWithViews:@[label, _language]];
    _languageRow.spacing = 8;
    [_language setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    // macOS reads Chinese, English and the rest without being told which: the line says so where the menu was.
    _languageFound = [NSTextField labelWithString:@"It finds the language on its own."];
    _languageFound.textColor = NSColor.secondaryLabelColor;
    _languageFound.font = [NSFont systemFontOfSize:12];

    _button = [NSButton buttonWithTitle:@"Run OCR" target:self action:@selector(runChosen)];
    _button.keyEquivalent = @"\r";
    NSStackView* buttonRow = [NSStackView stackViewWithViews:@[[NSView new], _button]];

    NSStackView* stack = [NSStackView stackViewWithViews:@[_engine, _languageRow, _languageFound, buttonRow]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    stack.detachesHiddenViews = YES;
    for (NSView* view in @[_engine, _languageRow, buttonRow])
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24].active = YES;
    [stack.widthAnchor constraintEqualToConstant:320].active = YES;

    NSViewController* controller = [NSViewController new];
    controller.view = stack;
    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.contentViewController = controller;
    _popover.delegate = self;
    [self show:[SPDFMacOCREngine() isEqualToString:SPDFMacOCREngineOpenSource]];
    return self;
}

- (void)show:(BOOL)openSource {
    _engine.selectedSegment = openSource ? 0 : 1;
    _languageRow.hidden = !openSource;
    _languageFound.hidden = openSource;
}
- (void)chooseOpenSource:(BOOL)openSource {
    [self show:openSource];
    SPDFMacSetOCREngine(openSource ? SPDFMacOCREngineOpenSource : SPDFMacOCREngineMacOS);
}
- (void)engineClicked:(id)sender { (void)sender; [self chooseOpenSource:_engine.selectedSegment == 0]; }

- (void)runChosen {
    BOOL openSource = _engine.selectedSegment == 0;
    NSDictionary* language = openSource ? _language.selectedItem.representedObject : nil;
    if (openSource && ![language[@"code"] length]) { NSBeep(); return; }
    if (openSource) SPDFMacSetOCROpenSourceLanguage(language[@"code"]);
    void (^run)(NSString*, NSDictionary*) = _run;
    _run = nil;
    SPDFMacOCRChoicePopover* keep = self;
    [self close];
    if (run) run(openSource ? SPDFMacOCREngineOpenSource : SPDFMacOCREngineMacOS, language);
    (void)keep;
}

- (void)stopKeys { if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor]; _keyMonitor = nil; }
- (void)close { [_popover close]; [self stopKeys]; if (gShown == self) gShown = nil; }
- (void)popoverDidClose:(NSNotification*)note { (void)note; [self stopKeys]; if (gShown == self) gShown = nil; }
@end
