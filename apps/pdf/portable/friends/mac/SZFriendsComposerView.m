// SZFriendsComposerView: Return sends, Shift+Return inserts a line, `#` attaches, the paperclip (Attach files) and
// dropped files become chips, and
// `/` turns the field into a command for the host's assistant (SZFriendsComposerCommand.m).

#import "mac/SZFriendsComposerInternal.h"
#import "mac/SZFriendsMentionViews.h"
#import "mac/SZFriendsPromiseCopies.h"

@interface SZFriendsComposerView () <NSTextViewDelegate>
@property(nonatomic, readwrite) SZFriendsDropHighlight dropHighlight;
@property(nonatomic, copy, readwrite, nullable) NSString *mentionNote;
@end

@implementation SZFriendsComposerView {
    SZFriendsContext *_context;
    NSString *_conversationID;
    NSTextField *_noteLabel;
    NSTextField *_errorLabel;
    NSString *_shownRefusal; // the drop refusal _errorLabel shows, if any
    NSTextField *_hintLabel;
    SZFriendsFlippedView *_inputBox;
    NSScrollView *_inputScroll;
    SZFriendsComposerTextView *_input;
    NSMutableArray<SZFriendsAttachableItem *> *_items;
    NSMutableArray<SZFriendsButton *> *_chips;
    BOOL _enabled;
    BOOL _sending;
    BOOL _acceptsDrops;
    NSString *_messagePlaceholder;
}

- (instancetype)initWithContext:(SZFriendsContext *)context conversationID:(NSString *)conversationID {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, context.appearance.dropdownWidth, 110)])) return nil;
    _context = context;
    _conversationID = [conversationID copy];
    SZFriendsAppearance *appearance = context.appearance;
    _noteLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _errorLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.destructiveColor);
    _hintLabel = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    // "Type # to attach, @ to mention someone, or drop files here" takes two lines in a narrow dropdown.
    _hintLabel.maximumNumberOfLines = 2;
    _hintLabel.cell.lineBreakMode = NSLineBreakByWordWrapping;
    for (NSTextField *label in @[ _noteLabel, _errorLabel, _hintLabel ]) [self addSubview:label];
    _inputBox = [SZFriendsFlippedView new];
    _inputBox.fillColor = appearance.fieldBackgroundColor;
    _inputBox.strokeColor = appearance.controlBorderColor;
    _inputBox.cornerRadius = 10;
    [self addSubview:_inputBox];
    _inputScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 40)];
    _inputScroll.drawsBackground = NO;
    _inputScroll.hasVerticalScroller = YES;
    _inputScroll.autohidesScrollers = YES;
    _inputScroll.scrollerStyle = NSScrollerStyleOverlay;
    _input = [[SZFriendsComposerTextView alloc] initWithFrame:NSMakeRect(0, 0, 300, 40)];
    _input.font = appearance.bodyFont;
    _input.textColor = appearance.primaryTextColor;
    _input.insertionPointColor = appearance.primaryTextColor;
    _input.drawsBackground = NO;
    _input.richText = NO;
    _input.allowsUndo = YES;
    _input.automaticQuoteSubstitutionEnabled = NO;
    _input.textContainerInset = NSMakeSize(4, 6);
    _input.verticallyResizable = YES;
    _input.horizontallyResizable = NO;
    _input.autoresizingMask = NSViewWidthSizable;
    _input.textContainer.widthTracksTextView = YES;
    _input.placeholderColor = appearance.secondaryTextColor;
    _input.delegate = self;
    __weak SZFriendsComposerView *weakSelf = self;
    _input.onReturn = ^{
        SZFriendsComposerView *composer = weakSelf;
        if (composer.commandState == SZFriendsCommandStateEditing) [composer.command run];
        else [composer send];
    };
    _input.onHash = ^{
        SZFriendsComposerView *composer = weakSelf;
        if (composer.onOpenAttachPicker) composer.onOpenAttachPicker();
    };
    _input.onAt = ^{
        SZFriendsComposerView *composer = weakSelf;
        // Not inside a `/` command, where `@` means something else to the assistant (brief § Interface). A disabled
        // composer takes no typing; the page decides whether the helper takes mentions.
        if (composer.commandState == SZFriendsCommandStateOff && composer.onOpenMentionPicker)
            composer.onOpenMentionPicker();
    };
    _input.onSlash = ^BOOL { return [weakSelf.command begin]; };
    _input.onDeleteAtStart = ^BOOL {
        SZFriendsComposerView *composer = weakSelf;
        if (composer.commandState != SZFriendsCommandStateEditing) return NO;
        [composer.command deleteTag];
        return YES;
    };
    _inputScroll.documentView = _input;
    [_inputBox addSubview:_inputScroll];
    _sendButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    _sendButton.font = SZFriendsSemibold(appearance.bodyFont);
    _sendButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf send];
    };
    [self addSubview:_sendButton];
    // Attach files: any file the open panel reaches, beside Send; named by the helper (hidden without its words).
    _attachButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleIcon appearance:appearance];
    _attachButton.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawPaperclipIcon(rect, color); };
    _attachButton.iconSize = NSMakeSize(16, 16);
    NSString *attachLabel = [context string:@"attach_files"];
    _attachButton.toolTip = attachLabel.length ? attachLabel : nil;
    _attachButton.accessibilityLabel = attachLabel;
    _attachButton.hidden = attachLabel.length == 0;
    _attachButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf chooseFiles];
    };
    [self addSubview:_attachButton];
    _items = [NSMutableArray array];
    _chips = [NSMutableArray array];
    _enabled = YES;
    id<SZFriendsHost> host = context.host;
    if ([host respondsToSelector:@selector(friendsAssistant)] && host.friendsAssistant) {
        _command = [[SZFriendsComposerCommand alloc] initWithContext:context conversationID:_conversationID
                                                            composer:self];
        [_input addSubview:_command.tag];
        for (NSView *view in @[ _command.proposalView, _command.noteLabel, _command.commandNoteLabel,
                                _command.runButton, _command.progressRow ])
            [self addSubview:view];
    }
    SZFriendsDraft *draft = context.drafts[_conversationID];
    if (draft) {
        if (draft.command && _command) [_command restoreCommand:draft.text];
        // A command saved while the host had an assistant comes back as the text that was typed, `/` included.
        else if (draft.command && draft.text.length) _input.string = [@"/" stringByAppendingString:draft.text];
        else if ([draft.richText.string isEqualToString:draft.text])
            [_input.textStorage setAttributedString:draft.richText]; // its `@` chips too
        else _input.string = draft.text;
        [self addAttachments:draft.items];
    }
    [_command adoptRunningRequest];
    return self;
}

- (SZFriendsCommandState)commandState {
    return _command ? _command.state : SZFriendsCommandStateOff;
}

- (BOOL)leaveCommand {
    if (self.commandState != SZFriendsCommandStateEditing) return NO;
    [_command leave];
    return YES;
}

- (void)showError:(NSString *)message {
    _errorLabel.stringValue = message ?: @"";
    [self changedHeight];
}

- (NSTextView *)textView {
    return _input;
}

- (NSArray<SZFriendsAttachableItem *> *)attachments {
    return [_items copy];
}

- (NSArray<SZFriendsButton *> *)chipButtons {
    return [_chips copy];
}

- (void)applyComposer:(NSDictionary *)composer {
    SZFriendsAppearance *appearance = _context.appearance;
    _enabled = SZFBool(composer, @"enabled");
    _command.enabled = _enabled;
    // Disabled (blocked, no longer friends): the field must not look ready to type in. Its fill and placeholder
    // dim and the attach hint goes, so the note above it is what explains why.
    _inputBox.fillColor = _enabled ? appearance.fieldBackgroundColor
                                   : [appearance.fieldBackgroundColor colorWithAlphaComponent:0.45];
    _inputBox.strokeColor = _enabled ? appearance.controlBorderColor
                                     : [appearance.controlBorderColor colorWithAlphaComponent:0.5];
    _inputBox.needsDisplay = YES;
    _input.placeholderColor = _enabled ? appearance.secondaryTextColor
                                       : [appearance.secondaryTextColor colorWithAlphaComponent:0.5];
    _messagePlaceholder = SZFStr(composer, @"placeholder") ?: @"";
    self.mentionNote = SZFStr(composer, @"mention_note");
    [self applyCommandState];
    _input.needsDisplay = YES;
    _noteLabel.stringValue = SZFStr(composer, @"note") ?: @"";
    _hintLabel.attributedStringValue = SZFriendsRichText(SZFArr(composer, @"hint"), appearance.captionFont,
                                                         appearance.secondaryTextColor, appearance);
    _sendButton.title = SZFStr(composer, @"send_label") ?: @"";
    [_command setSendLabel:_sendButton.title];
    _acceptsDrops = SZFBool(composer, @"accepts_drops");
    if (_acceptsDrops) [self registerForDraggedTypes:[SZFriendsDrops draggedTypesForHost:_context.host]];
    else [self unregisterDraggedTypes];
    [self setNeedsLayout:YES];
}

#pragma mark - Attachments

- (void)insertMentionForConversation:(NSString *)conversationID label:(NSString *)label {
    NSTextView *text = _input;
    NSRange range = text.selectedRange;
    NSString *string = text.string ?: @"";
    if (range.location == NSNotFound || NSMaxRange(range) > string.length) range = NSMakeRange(string.length, 0);
    // The `@` typed to open the picker becomes the chip.
    if (range.location > 0 && [string characterAtIndex:range.location - 1] == '@') {
        range.location--;
        range.length++;
    }
    NSDictionary *typing = @{NSFontAttributeName : _context.appearance.bodyFont,
                             NSForegroundColorAttributeName : _context.appearance.primaryTextColor};
    NSMutableAttributedString *chip = [[SZFriendsMentionChip chipForConversation:conversationID label:label
                                                                      appearance:_context.appearance] mutableCopy];
    // A space after it, as after a typed word, unless one follows already.
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (NSMaxRange(range) >= string.length || ![spaces characterIsMember:[string characterAtIndex:NSMaxRange(range)]])
        [chip appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:typing]];
    // Through the text view's own change calls, so Undo removes the chip and the draft keeps it.
    if (![text shouldChangeTextInRange:range replacementString:chip.string]) return;
    [text.textStorage replaceCharactersInRange:range withAttributedString:chip];
    [text didChangeText];
    text.selectedRange = NSMakeRange(range.location + chip.length, 0);
    text.typingAttributes = typing;
}

- (void)addAttachments:(NSArray<SZFriendsAttachableItem *> *)items {
    SZFriendsAppearance *appearance = _context.appearance;
    for (SZFriendsAttachableItem *item in items) {
        [_items addObject:item];
        SZFriendsButton *chip = [SZFriendsButton buttonWithTitle:item.title style:SZFriendsButtonStyleSecondary
                                                      appearance:appearance];
        chip.font = appearance.secondaryFont;
        chip.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawCloseIcon(rect, color); };
        chip.iconSize = NSMakeSize(10, 10);
        chip.iconTrailing = YES;
        chip.toolTip = item.detail.length ? item.detail : nil;
        chip.accessibilityLabel = item.title;
        __weak SZFriendsComposerView *weakSelf = self;
        chip.onPress = ^(SZFriendsButton *pressed) {
            SZFriendsComposerView *composer = weakSelf;
            if (!composer) return;
            NSUInteger index = [composer->_chips indexOfObject:pressed];
            if (index != NSNotFound) [composer removeAttachmentAtIndex:index];
        };
        [_chips addObject:chip];
        [self addSubview:chip];
    }
    [self saveDraft];
    [self changedHeight];
}

- (void)chooseFiles {
    if (!_enabled || _sending || !_context.chooseFiles) return;
    __weak SZFriendsComposerView *weakSelf = self;
    _context.chooseFiles(self.window, ^(NSArray<NSURL *> *files) {
        SZFriendsComposerView *composer = weakSelf;
        if (!composer || !files.count) return;
        SZFriendsDropVerdict verdict = SZFriendsDropVerdictNone;
        NSArray<SZFriendsAttachableItem *> *items = [SZFriendsDrops itemsForChosenFiles:files verdict:&verdict];
        NSString *refusal = SZFriendsDropRefusalKey(verdict);
        if (refusal) {
            // As a drop says it: a folder or a link chosen sends nothing, in the helper's words.
            [composer showError:[composer->_context string:refusal]];
            [composer->_context announce:[composer->_context string:refusal]];
            return;
        }
        NSMutableArray<SZFriendsAttachableItem *> *fresh = [NSMutableArray array];
        for (SZFriendsAttachableItem *item in items) {
            BOOL there = NO;
            for (SZFriendsAttachableItem *old in composer->_items)
                there = there || (old.fileURL && [old.fileURL isEqual:item.fileURL]);
            if (!there) [fresh addObject:item];
        }
        [composer showError:nil];
        if (fresh.count) [composer addAttachments:fresh];
        [composer.window makeFirstResponder:composer->_input];
    });
}

- (void)removeAttachmentAtIndex:(NSUInteger)index {
    if (index >= _items.count) return;
    [_chips[index] removeFromSuperview];
    [_chips removeObjectAtIndex:index];
    [_items removeObjectAtIndex:index];
    [self saveDraft];
    [self changedHeight];
}

- (void)saveDraft {
    SZFriendsDraft *draft = [SZFriendsDraft new];
    draft.text = _input.string ?: @"";
    draft.richText = SZFriendsTextHoldsMentionChip(_input.textStorage) ? _input.textStorage : nil;
    draft.items = _items;
    draft.command = self.commandState != SZFriendsCommandStateOff;
    if (draft.text.length || draft.items.count) _context.drafts[_conversationID] = draft;
    else [_context.drafts removeObjectForKey:_conversationID];
}

- (void)changedHeight {
    [self applyCommandState];
    [self setNeedsLayout:YES];
    if (self.onHeightChange) self.onHeightChange();
}

// What the field says and does in the current `/` state: the message placeholder or the assistant's, the tag's room
// on the first line, and which of Send, the arrow and the progress row shows.
- (void)applyCommandState {
    SZFriendsCommandState state = self.commandState;
    BOOL command = state != SZFriendsCommandStateOff;
    _input.placeholder = command ? _command.placeholder : _messagePlaceholder ?: @"";
    _input.accessibilityLabel = _input.placeholder;
    _input.editable = _enabled && state != SZFriendsCommandStateRunning;
    _input.placeholderIndent = command ? [_command tagWidth] + 5 : 0;
    // The tag sits where the first line starts; the line's text flows after it, later lines use the full width.
    CGFloat padding = _input.textContainer.lineFragmentPadding;
    _input.textContainer.exclusionPaths = command ? @[ [NSBezierPath bezierPathWithRect:NSMakeRect(
                                                          0, 0, padding + [_command tagWidth], 15)] ]
                                                  : @[];
    _command.tag.frame = NSMakeRect(_input.textContainerInset.width + padding, _input.textContainerInset.height - 0.5,
                                    [_command tagWidth], 17);
    _hintLabel.hidden = !_enabled || command;
    _sendButton.hidden = command;
    NSString *attachLabel = [_context string:@"attach_files"];
    _attachButton.toolTip = attachLabel.length ? attachLabel : nil;
    _attachButton.accessibilityLabel = attachLabel;
    _attachButton.hidden = command || !attachLabel.length;
    _attachButton.enabled = _enabled && !_sending;
    // While a proposal waits above, its Send is the one primary action: the composer's own Send turns secondary, and
    // with nothing typed or attached it is disabled, since pressing it would do nothing.
    BOOL proposal = _command.proposalView.proposal != nil;
    SZFriendsButtonStyle style = proposal ? SZFriendsButtonStyleSecondary : SZFriendsButtonStylePrimary;
    if (_sendButton.style != style) {
        _sendButton.style = style;
        _sendButton.needsDisplay = YES;
    }
    _sendButton.enabled = _enabled && !_sending && !(proposal && !_input.string.length && !_items.count);
    _input.needsDisplay = YES;
}

#pragma mark - Sending

- (void)send {
    if (!_enabled || _sending || self.commandState != SZFriendsCommandStateOff) return;
    NSArray<NSDictionary *> *mentions = nil;
    NSString *text = SZFriendsComposerMessage(_input.textStorage, SZFriendsHelperTakesMentions(_context), &mentions);
    if (!text.length && !_items.count) return;
    NSMutableDictionary *fields = [@{@"conversation_id" : _conversationID, @"text" : text,
                                     @"client_token" : [SZFriendsContext clientToken]} mutableCopy];
    if (mentions.count) fields[@"mentions"] = mentions;
    if (_items.count) {
        NSMutableArray *files = [NSMutableArray array];
        for (SZFriendsAttachableItem *item in _items) [files addObject:[SZFriendsContext fileObjectForItem:item]];
        fields[@"attachments"] = files;
    }
    _sending = YES;
    _sendButton.enabled = NO;
    _errorLabel.stringValue = @"";
    NSArray<SZFriendsAttachableItem *> *sentItems = [_items copy];
    __weak SZFriendsComposerView *weakSelf = self;
    [_context.link sendIntent:@"send_message" fields:fields reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        (void)result;
        SZFriendsComposerView *composer = weakSelf;
        if (!composer) return;
        composer->_sending = NO;
        composer->_sendButton.enabled = composer->_enabled;
        if (error) {
            // The draft stays; the helper's message says what happened from the person's side.
            composer->_errorLabel.stringValue = error.message ?: @"";
            [composer->_context announce:error.message];
            [composer changedHeight];
            return;
        }
        composer->_input.string = @"";
        [composer->_command clearNote];
        // Promised files' copies were for this send; the helper holds its own now.
        [SZFriendsPromiseCopies discardCopiesForItems:sentItems after:0];
        while (composer->_items.count) [composer removeAttachmentAtIndex:0];
        [composer saveDraft];
        [composer changedHeight];
    }];
}

- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    if (!_input.string.length) [_command clearNote]; // the draft it described is gone
    [self saveDraft];
    [self changedHeight];
}

- (void)textDidBeginEditing:(NSNotification *)notification {
    (void)notification;
    _inputBox.strokeColor = _context.appearance.accentColor;
    _inputBox.needsDisplay = YES;
}

- (void)textDidEndEditing:(NSNotification *)notification {
    (void)notification;
    _inputBox.strokeColor = _context.appearance.controlBorderColor;
    _inputBox.needsDisplay = YES;
}

#pragma mark - Layout

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat inner = width - 20, y = 10;
    // A message the assistant proposed sits above everything else: it is what the person decides on next.
    CGFloat proposalHeight = _command ? [_command.proposalView heightForWidth:inner] : 0;
    if (apply && proposalHeight) _command.proposalView.frame = NSMakeRect(10, y, inner, proposalHeight);
    if (proposalHeight) y += proposalHeight + 8;
    NSMutableArray<NSTextField *> *labels = [@[ _noteLabel, _errorLabel ] mutableCopy];
    if (_command) [labels addObject:_command.noteLabel];
    for (NSTextField *label in labels) {
        CGFloat height = SZFriendsFieldHeight(label, inner);
        if (apply) {
            label.hidden = height == 0;
            if (height) label.frame = NSMakeRect(10, y, inner, height);
        }
        if (height) y += height + 6;
    }
    CGFloat x = 10, rowTop = y;
    for (SZFriendsButton *chip in _chips) {
        CGFloat chipWidth = MIN(inner, [chip fittingWidth]);
        if (x > 10 && x + chipWidth > 10 + inner) {
            x = 10;
            rowTop += 34;
        }
        if (apply) chip.frame = NSMakeRect(x, rowTop, chipWidth, 28);
        x += chipWidth + 6;
    }
    if (_chips.count) y = rowTop + 28 + 8;
    NSLayoutManager *layout = _input.layoutManager;
    [layout ensureLayoutForTextContainer:_input.textContainer];
    CGFloat textHeight = ceil([layout usedRectForTextContainer:_input.textContainer].size.height) + 12;
    CGFloat boxHeight = MIN(120, MAX(56, textHeight + 6));
    if (apply) {
        _inputBox.frame = NSMakeRect(10, y, inner, boxHeight);
        _inputScroll.frame = NSMakeRect(4, 3, inner - 8, boxHeight - 6);
    }
    y += boxHeight + 8;
    // While a command is being written, the host's note on what it reads takes the hint's place beside the arrow.
    NSTextField *commandNote = _command.commandNoteLabel;
    CGFloat noteHeight = commandNote && !commandNote.hidden ? SZFriendsFieldHeight(commandNote, inner - 28 - 10) : 0;
    if (apply && noteHeight) commandNote.frame = NSMakeRect(10, y + 1, inner - 28 - 10, noteHeight);
    CGFloat sendWidth = MAX(64, [_sendButton fittingWidth]);
    BOOL hintShown = _enabled && self.commandState == SZFriendsCommandStateOff;
    // The paperclip sits just left of Send; the hint gives it room.
    CGFloat attachWidth = _attachButton.hidden ? 0 : 30 + 6;
    CGFloat hintWidth = inner - sendWidth - attachWidth - 10;
    CGFloat hintHeight = hintShown ? SZFriendsFieldHeight(_hintLabel, hintWidth) : 0;
    if (apply) {
        _sendButton.frame = NSMakeRect(width - 10 - sendWidth, y, sendWidth, 28);
        _attachButton.frame = NSMakeRect(width - 10 - sendWidth - 6 - 30, y, 30, 28);
        // One line sits level with Send's title; two start at Send's top edge.
        _hintLabel.frame = NSMakeRect(10, y + (hintHeight > 18 ? 0 : 6), hintWidth, MAX(16, hintHeight));
        _hintLabel.hidden = !_enabled || self.commandState != SZFriendsCommandStateOff;
        // The arrow takes Send's place while the field holds a command; the progress row takes the whole line.
        _command.runButton.frame = NSMakeRect(width - 10 - 28, y, 28, 28);
        _command.progressRow.frame = NSMakeRect(10, y, inner, 28);
        CGFloat cancelWidth = [_command.cancelButton fittingWidth];
        _command.cancelButton.frame = NSMakeRect(inner - cancelWidth, 5, cancelWidth, 18);
        _command.progressLabel.frame = NSMakeRect(24, 6, MAX(0, inner - 24 - cancelWidth - 8), 16);
    }
    return y + MAX(MAX(28, noteHeight + 2), hintHeight) + 12;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [_context.appearance.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1));
    if (self.dropHighlight == SZFriendsDropHighlightNone) return;
    NSColor *color = self.dropHighlight == SZFriendsDropHighlightAccept ? _context.appearance.accentColor
                                                                        : _context.appearance.warningColor;
    NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(_inputBox.frame, -2, -2) xRadius:12
                                                         yRadius:12];
    ring.lineWidth = 2;
    [color setStroke];
    [ring stroke];
}

#pragma mark - Drops: chips, never an immediate send

- (void)setDropHighlight:(SZFriendsDropHighlight)dropHighlight {
    [self setDropHighlight:dropHighlight refusal:@""];
}

// The refusal (drop_folders_refused, drop_not_a_file) shows where an error would, and goes with the drag; an error
// of another kind stays.
- (void)setDropHighlight:(SZFriendsDropHighlight)dropHighlight refusal:(NSString *)refusal {
    _dropHighlight = dropHighlight;
    NSString *refused = dropHighlight == SZFriendsDropHighlightRefuse ? refusal : @"";
    if (refused.length || (_shownRefusal.length && [_errorLabel.stringValue isEqualToString:_shownRefusal]))
        _errorLabel.stringValue = refused;
    _shownRefusal = refused;
    if (refused.length) [_context announce:refused];
    self.needsDisplay = YES;
    [self changedHeight];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (!_acceptsDrops || !_enabled) return NSDragOperationNone;
    SZFriendsDropVerdict verdict = [SZFriendsDrops verdictForPasteboard:sender.draggingPasteboard host:_context.host];
    NSString *key = SZFriendsDropRefusalKey(verdict);
    [self setDropHighlight:SZFriendsDropHighlightForVerdict(verdict) refusal:key ? [_context string:key] : @""];
    return self.dropHighlight == SZFriendsDropHighlightAccept ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    (void)sender;
    return self.dropHighlight == SZFriendsDropHighlightAccept ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlight = SZFriendsDropHighlightNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (self.dropHighlight != SZFriendsDropHighlightAccept) return NO;
    __weak SZFriendsComposerView *weakSelf = self;
    [SZFriendsDrops readItemsFromPasteboard:sender.draggingPasteboard host:_context.host
                           promiseDirectory:_context.promiseDirectory
                                 completion:^(NSArray<SZFriendsAttachableItem *> *items, BOOL refusedFolder) {
                                     if (!refusedFolder && items.count) [weakSelf addAttachments:items];
                                 }];
    return YES;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlight = SZFriendsDropHighlightNone;
}

@end
