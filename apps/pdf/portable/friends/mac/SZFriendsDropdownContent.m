// SZFriendsDropdownContent: the view stack inside the dropdown, the confirmation overlay, Escape and Cmd+[.

#import "mac/SZFriendsDropdownInternal.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsDevices.h"
#import "mac/SZFriendsLinkPage.h"

CGFloat SZFriendsDropdownHeight(CGFloat spaceBelowButton, CGFloat maxHeight) {
    // 24 pt for the popover's arrow and a margin above the window's bottom edge; 280 pt keeps a short window
    // usable (header, a few rows, the composer) rather than shrinking to nothing.
    return floor(MAX(280, MIN(maxHeight, spaceBelowButton - 24)));
}

@implementation SZFriendsConfirmView {
    SZFriendsFlippedView *_card;
    NSTextField *_title;
    NSTextField *_body;
    void (^_onConfirm)(BOOL);
}

- (instancetype)initWithContext:(SZFriendsContext *)context confirm:(NSDictionary *)confirm
                      onConfirm:(void (^)(BOOL))onConfirm {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 400)])) return nil;
    SZFriendsAppearance *appearance = context.appearance;
    _onConfirm = [onConfirm copy];
    self.identifier = SZFriendsIdentifierConfirmation;
    self.fillColor = [appearance.backgroundColor colorWithAlphaComponent:0.75];
    _card = [SZFriendsFlippedView new];
    _card.fillColor = appearance.backgroundColor;
    _card.strokeColor = appearance.controlBorderColor;
    _card.cornerRadius = 12;
    [self addSubview:_card];
    NSFont *titleFont = SZFriendsSemibold(appearance.bodyFont);
    _title = SZFriendsLabel(SZFStr(confirm, @"title"), titleFont, appearance.primaryTextColor);
    _body = SZFriendsLabel(SZFStr(confirm, @"body"), appearance.secondaryFont, appearance.secondaryTextColor);
    [_card addSubview:_title];
    [_card addSubview:_body];
    // "Also delete chat history": a choice inside the question, so it starts unticked and the plain answer keeps
    // the history.
    NSString *option = SZFStr(SZFDict(confirm, @"option"), @"label");
    if (option.length) {
        _optionCheckbox = [NSButton checkboxWithTitle:option target:nil action:nil];
        _optionCheckbox.font = appearance.secondaryFont;
        _optionCheckbox.state = NSControlStateValueOff;
        NSMutableAttributedString *title = [_optionCheckbox.attributedTitle mutableCopy];
        [title addAttribute:NSForegroundColorAttributeName value:appearance.primaryTextColor
                      range:NSMakeRange(0, title.length)];
        _optionCheckbox.attributedTitle = title;
        [_card addSubview:_optionCheckbox];
    }
    __weak SZFriendsConfirmView *weakSelf = self;
    _cancelButton = [SZFriendsButton buttonWithTitle:SZFStr(confirm, @"cancel_label")
                                               style:SZFriendsButtonStyleSecondary
                                          appearance:appearance];
    _cancelButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsConfirmView *view = weakSelf;
        if (view.onFinish) view.onFinish();
    };
    // A destructive confirmation (Remove, Block, Reset) never confirms in the blue that means "go ahead": its button
    // has a red title, as NSAlert draws hasDestructiveAction in Settings.
    BOOL destructive = SZFBool(confirm, @"destructive");
    _confirmButton = [SZFriendsButton buttonWithTitle:SZFStr(confirm, @"confirm_label")
                                                style:destructive ? SZFriendsButtonStyleDestructiveBordered
                                                                  : SZFriendsButtonStylePrimary
                                           appearance:appearance];
    _confirmButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsConfirmView *view = weakSelf;
        if (!view) return;
        void (^confirmed)(BOOL) = view->_onConfirm;
        BOOL ticked = view.optionCheckbox.state == NSControlStateValueOn;
        if (view.onFinish) view.onFinish();
        if (confirmed) confirmed(ticked);
    };
    [_card addSubview:_cancelButton];
    [_card addSubview:_confirmButton];
    return self;
}

- (void)layout {
    [super layout];
    CGFloat width = MIN(NSWidth(self.bounds) - 32, 340), inner = width - 32, y = 16;
    y = SZFriendsPlace(_title, 16, y, inner) + 6;
    y = SZFriendsPlace(_body, 16, y, inner) + 16;
    if (_optionCheckbox) {
        NSSize size = _optionCheckbox.fittingSize;
        _optionCheckbox.frame = NSMakeRect(16, y - 4, MIN(inner, ceil(size.width)), ceil(size.height));
        y = NSMaxY(_optionCheckbox.frame) + 14;
    }
    CGFloat confirmWidth = MAX(84, [_confirmButton fittingWidth]), cancelWidth = MAX(72, [_cancelButton fittingWidth]);
    _confirmButton.frame = NSMakeRect(width - 16 - confirmWidth, y, confirmWidth, 28);
    _cancelButton.frame = NSMakeRect(NSMinX(_confirmButton.frame) - 8 - cancelWidth, y, cancelWidth, 28);
    y += 28 + 16;
    // A third of the way down, where a dialog sits, not dead centre.
    CGFloat cardX = floor((NSWidth(self.bounds) - width) / 2), cardY = floor((NSHeight(self.bounds) - y) / 3);
    _card.frame = NSMakeRect(cardX, cardY, width, y);
}

// Clicks around the card land on the overlay, not on the page underneath.
- (void)mouseDown:(NSEvent *)event {
    (void)event;
}

@end

@implementation SZFriendsDropdownContent {
    NSMutableArray<SZFriendsPage *> *_pages;
    NSArray<NSDictionary *> *_sendFiles;
    SZFriendsFlippedView *_statusStrip;
    NSTextField *_statusLabel;
}

static const CGFloat SZFStatusStripHeight = 28;

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, context.appearance.dropdownWidth,
                                                 context.appearance.dropdownMaxHeight)])) return nil;
    _context = context;
    // Everything the dropdown shows sits under this view, so one mark keeps it all from the host's assistant.
    self.identifier = SZFriendsIdentifierDropdown;
    context.navigator = self;
    __weak SZFriendsDropdownContent *weakSelf = self;
    context.presentConfirmation = ^(NSDictionary *confirm, void (^onConfirm)(BOOL)) {
        [weakSelf presentConfirmation:confirm onConfirm:onConfirm];
    };
    self.fillColor = context.appearance.backgroundColor;
    _listPage = [[SZFriendsListPage alloc] initWithContext:context];
    _pages = [NSMutableArray arrayWithObject:_listPage];
    [self addSubview:_listPage];
    _statusStrip = [SZFriendsFlippedView new];
    _statusStrip.fillColor = context.appearance.fieldBackgroundColor;
    _statusLabel = SZFriendsLabel(@"", context.appearance.secondaryFont, context.appearance.secondaryTextColor);
    _statusLabel.alignment = NSTextAlignmentCenter;
    _statusLabel.maximumNumberOfLines = 1;
    [_statusStrip addSubview:_statusLabel];
    [self addSubview:_statusStrip];
    // Not Ready: every page keeps its last snapshot, and this one line says why nothing changes (the link's
    // contract); intents fail at once with not_ready meanwhile, so nothing waits behind the person's back.
    [context.link addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionInitial context:NULL];
    return self;
}

- (void)dealloc {
    [_context.link removeObserver:self forKeyPath:@"state"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change
                       context:(void *)context {
    (void)keyPath, (void)object, (void)change, (void)context;
    SZFriendsHelperLink *link = self.context.link;
    NSString *text = link.state == SZFriendsLinkStateReady ? nil : link.statusText;
    _statusText = text.length ? [text copy] : nil;
    _statusLabel.stringValue = _statusText ?: @"";
    _statusStrip.hidden = _statusText == nil;
    [self setNeedsLayout:YES];
}

- (NSArray<SZFriendsPage *> *)stack {
    return [_pages copy];
}

- (SZFriendsPage *)topPage {
    return _pages.lastObject;
}

- (void)setPresented:(BOOL)presented {
    if (presented == _presented) return;
    _presented = presented;
    if (presented) {
        [self.topPage pageWillAppear];
        [self focusTopPage];
    } else {
        [self.topPage pageDidDisappear];
        [self dismissConfirmation];
        [self finishSendPicker];
        [self setDropHint:nil];
    }
    if (self.onTopPageChange) self.onTopPageChange();
}

- (NSString *)shownConversationID {
    SZFriendsPage *top = self.topPage;
    if (!_presented || ![top isKindOfClass:SZFriendsConversationPage.class]) return nil;
    return ((SZFriendsConversationPage *)top).conversationID;
}

- (void)focusTopPage {
    NSView *responder = [self.topPage preferredFirstResponder];
    if (responder && self.window) [self.window makeFirstResponder:responder];
}

#pragma mark - Stack

- (void)pushPage:(SZFriendsPage *)page {
    if (_presented) [self.topPage pageDidDisappear];
    self.topPage.hidden = YES;
    [_pages addObject:page];
    page.frame = [self pageFrame];
    if (self.confirmation) [self addSubview:page positioned:NSWindowBelow relativeTo:self.confirmation];
    else [self addSubview:page];
    if (_presented) {
        [page pageWillAppear];
        [self focusTopPage];
    }
    if (self.onTopPageChange) self.onTopPageChange();
}

- (void)popPage {
    if (_pages.count < 2) return;
    SZFriendsPage *top = self.topPage;
    if (_presented) [top pageDidDisappear];
    [top removeFromSuperview];
    [_pages removeLastObject];
    self.topPage.hidden = NO;
    self.topPage.frame = [self pageFrame];
    if (_presented) {
        [self.topPage pageWillAppear];
        [self focusTopPage];
    }
    if (self.onTopPageChange) self.onTopPageChange();
}

- (void)popToList {
    while (_pages.count > 1) [self popPage];
}

#pragma mark - Navigator

- (void)openConversation:(NSString *)conversationID highlightMessage:(NSString *)messageID {
    SZFriendsPage *top = self.topPage;
    if ([top isKindOfClass:SZFriendsConversationPage.class] &&
        [((SZFriendsConversationPage *)top).conversationID isEqualToString:conversationID]) {
        if (messageID) [(SZFriendsConversationPage *)top highlightMessage:messageID];
        return;
    }
    [self popToList];
    [self pushPage:[[SZFriendsConversationPage alloc] initWithContext:self.context conversationID:conversationID
                                                     highlightMessage:messageID]];
}

- (void)openDetails:(NSString *)conversationID {
    if ([self.topPage isKindOfClass:SZFriendsDetailsPage.class]) return;
    [self pushPage:[[SZFriendsDetailsPage alloc] initWithContext:self.context conversationID:conversationID]];
}

- (void)openLinkPayload:(NSString *)payload {
    [self popToList];
    [self pushPage:[[SZFriendsLinkPage alloc] initWithContext:self.context payload:payload]];
}

- (void)openProfile {
    [self popToList];
    [self pushPage:[[SZFriendsProfilePage alloc] initWithContext:self.context]];
}

- (void)openJoin {
    [self popToList];
    [self pushPage:[[SZFriendsJoinPage alloc] initWithContext:self.context]];
}

- (void)goBack {
    [self dismissConfirmation];
    [self popPage];
}

- (void)closeDropdown {
    if (self.onClose) self.onClose();
}

- (NSArray<NSDictionary *> *)pendingSendFiles {
    return _sendFiles;
}

- (void)beginSendPickerWithFiles:(NSArray<NSDictionary *> *)files {
    [self popToList];
    [self.listPage showNearby:NO];
    _sendFiles = [files copy];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *file in files) {
        NSString *name = SZFStr(file, @"display_name") ?: SZFStr(file, @"path").lastPathComponent;
        if (name.length) [names addObject:name];
    }
    [self.listPage setSendPickerTitle:SZFriendsSendPickerTitle(self.context, names, files.count)
                              toolTip:names.count > 1 ? [names componentsJoinedByString:@"\n"] : nil];
}

NSString *SZFriendsSendPickerTitle(SZFriendsContext *context, NSArray<NSString *> *names, NSUInteger count) {
    NSString *(^fill)(NSString *, NSString *, NSUInteger) = ^NSString *(NSString *format, NSString *name,
                                                                       NSUInteger number) {
        NSString *text = [format stringByReplacingOccurrencesOfString:@"{name}" withString:name ?: @""];
        return [text stringByReplacingOccurrencesOfString:@"{count}"
                                               withString:[NSString stringWithFormat:@"%lu", (unsigned long)number]];
    };
    // Named, so the person sees which files are about to go ("Send Site photos.pdf and 1 more to…"); a helper
    // without those strings gets the count alone, never words the views made up.
    NSString *named = [context string:count == 1 ? @"drop_send_file" : @"drop_send_file_and_more"];
    if (names.count == count && count > 0 && named.length) return fill(named, names.firstObject, count - 1);
    NSString *counted = [context string:count == 1 ? @"drop_send_one" : @"drop_send_many"];
    return counted.length ? fill(counted, nil, count) : nil;
}

- (void)finishSendPicker {
    _sendFiles = nil;
    [self.listPage setSendPickerTitle:nil];
}

- (void)setDropHint:(NSString *)hint {
    [self.listPage setDropHint:hint];
}

- (void)setDropHint:(NSString *)hint refusing:(BOOL)refusing {
    [self.listPage setDropHint:hint refusing:refusing];
}

#pragma mark - Confirmation

- (void)presentConfirmation:(NSDictionary *)confirm onConfirm:(void (^)(BOOL))onConfirm {
    [self dismissConfirmation];
    SZFriendsConfirmView *view = [[SZFriendsConfirmView alloc] initWithContext:self.context confirm:confirm
                                                                     onConfirm:onConfirm];
    __weak SZFriendsDropdownContent *weakSelf = self;
    view.onFinish = ^{ [weakSelf dismissConfirmation]; };
    view.frame = self.bounds;
    _confirmation = view;
    [self addSubview:view positioned:NSWindowAbove relativeTo:nil];
    if (self.window) [self.window makeFirstResponder:view.cancelButton];
}

- (void)dismissConfirmation {
    [_confirmation removeFromSuperview];
    _confirmation = nil;
}

#pragma mark - Keyboard

- (void)friendsHandleEscape {
    if (_confirmation) {
        [self dismissConfirmation];
        return;
    }
    if ([self.topPage dismissInnermostPicker]) return;
    if (_sendFiles) {
        [self finishSendPicker];
        return;
    }
    // Escape never navigates back; with nothing open inside, it closes the dropdown.
    [self closeDropdown];
}

- (void)cancelOperation:(id)sender {
    (void)sender;
    [self friendsHandleEscape];
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) [self friendsHandleEscape];
    else [super keyDown:event];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers isEqualToString:@"["]) {
        [self goBack];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (NSRect)pageFrame {
    if (_statusStrip.hidden) return self.bounds;
    NSRect frame = self.bounds;
    frame.origin.y += SZFStatusStripHeight;
    frame.size.height -= SZFStatusStripHeight;
    return frame;
}

- (void)layout {
    [super layout];
    _statusStrip.frame = NSMakeRect(0, 0, NSWidth(self.bounds), SZFStatusStripHeight);
    _statusLabel.frame = NSMakeRect(12, 6, NSWidth(self.bounds) - 24, 16);
    for (SZFriendsPage *page in _pages) page.frame = [self pageFrame];
    _confirmation.frame = self.bounds;
}

@end
