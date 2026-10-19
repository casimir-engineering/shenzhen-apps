// A message a `/` command proposed: held per conversation until the person's Send gets it to Friends, or Edit moves
// it into the composer, and the card above the composer that shows it character for character. Also which of a
// result's files the composer accepts, for drafts and proposals alike.

#import "mac/SZFriendsComposerInternal.h"

// The tallest the message box grows before it scrolls; the history above must keep some room in a 640 pt dropdown.
static const CGFloat SZFMaxTextHeight = 168;

#pragma mark - What the assistant may hand back

static BOOL SZFSameFile(SZFriendsAttachableItem *a, SZFriendsAttachableItem *b) {
    return [a.fileURL.path isEqualToString:b.fileURL.path];
}

// WHY the views check too: the host's tool layer enforces it, and a second check costs nothing here, where the
// chips are (brief § AI boundaries: attachments only from the person's own `#` chips or drops).
BOOL SZFriendsAssistantItemComesFrom(SZFriendsAttachableItem *item, NSArray<SZFriendsAttachableItem *> *chips) {
    NSString *source = SZFStr(item.revision, @"source"), *document = SZFStr(item.revision, @"document_id");
    for (SZFriendsAttachableItem *chip in chips) {
        if (SZFSameFile(item, chip)) return YES;
        if (source.length && document.length && [source isEqualToString:SZFStr(chip.revision, @"source")] &&
            [document isEqualToString:SZFStr(chip.revision, @"document_id")])
            return YES;
    }
    return NO;
}

static BOOL SZFAlreadyChipped(SZFriendsAttachableItem *item, NSArray<SZFriendsAttachableItem *> *chips) {
    for (SZFriendsAttachableItem *chip in chips)
        if (SZFSameFile(item, chip) && (item.revision == chip.revision || [item.revision isEqual:chip.revision]))
            return YES;
    return NO;
}

NSArray<SZFriendsAttachableItem *> *SZFriendsAssistantDraftAdditions(SZFriendsAssistantResult *result,
                                                                     NSArray<SZFriendsAttachableItem *> *chipsWhenRun,
                                                                     NSArray<SZFriendsAttachableItem *> *chipsNow) {
    NSMutableArray *additions = [NSMutableArray array];
    for (SZFriendsAttachableItem *item in result.attachments)
        if (SZFriendsAssistantItemComesFrom(item, chipsWhenRun) && !SZFAlreadyChipped(item, chipsNow) &&
            !SZFAlreadyChipped(item, additions))
            [additions addObject:item];
    return additions;
}

#pragma mark - The proposal

@implementation SZFriendsAssistantProposal

- (instancetype)initWithResult:(SZFriendsAssistantResult *)result
                  chipsWhenRun:(NSArray<SZFriendsAttachableItem *> *)chips
                conversationID:(NSString *)conversationID {
    if (!(self = [super init])) return nil;
    _result = result;
    _chipsWhenRun = [chips copy] ?: @[];
    _conversationID = [conversationID copy];
    _problem = @"";
    // WHY the views check too: the host's tool layer enforces it, and the card must not show a file the host would
    // not send, nor the host send one the card did not show (brief § AI boundaries).
    NSMutableArray *kept = [NSMutableArray array];
    for (SZFriendsAttachableItem *item in result.attachments)
        if (SZFriendsAssistantItemComesFrom(item, _chipsWhenRun) && ![kept containsObject:item]) [kept addObject:item];
    _attachments = kept;
    return self;
}

- (void)sendInContext:(SZFriendsContext *)context {
    void (^send)(void (^)(NSError *)) = self.result.send;
    if (_sending || !send) return;
    _sending = YES;
    _problem = @"";
    [self.observer proposalDidChange:self];
    __weak SZFriendsAssistantProposal *weakSelf = self;
    __weak SZFriendsContext *weakContext = context;
    __block BOOL answered = NO;
    send(^(NSError *error) {
        SZFriendsAssistantProposal *proposal = weakSelf;
        if (answered || !proposal) return; // the host's done runs once; a second answer changes nothing
        answered = YES;
        [proposal finishSendWithError:error context:weakContext];
    });
}

- (void)finishSendWithError:(NSError *)error context:(SZFriendsContext *)context {
    _sending = NO;
    if (error) {
        // The card stays with the host's words, and Send can be pressed again.
        _problem = error.localizedDescription ?: @"";
        [context announce:_problem];
        [self.observer proposalDidChange:self];
        return;
    }
    if (context.assistantProposals[_conversationID] == self)
        [context.assistantProposals removeObjectForKey:_conversationID];
    [self.observer proposalWasSent:self];
}

@end

#pragma mark - The card

// The message, selectable for copying; Escape goes to the dropdown as from every Friends field.
@interface SZFriendsProposalTextView : NSTextView
@end

@implementation SZFriendsProposalTextView
- (void)cancelOperation:(id)sender {
    (void)sender;
    SZFriendsForwardEscape(self);
}
@end

// One of the assistant's optional words for the card (SZFriendsHost.h), or "" when the host has none.
static NSString *SZFAssistantWord(SZFriendsContext *context, SEL selector) {
    id<SZFriendsHost> host = context.host;
    id assistant = [host respondsToSelector:@selector(friendsAssistant)] ? host.friendsAssistant : nil;
    if (![assistant respondsToSelector:selector]) return @"";
    id word = ((id (*)(id, SEL))[assistant methodForSelector:selector])(assistant, selector);
    return [word isKindOfClass:NSString.class] ? word : @"";
}

@implementation SZFriendsProposalView {
    __weak SZFriendsContext *_context;
    SZFriendsFlippedView *_box;
    SZFriendsEdgeFade *_fade;
    NSMutableArray<NSView *> *_files;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 380, 120)])) return nil;
    _context = context;
    _sendLabel = @"";
    _files = [NSMutableArray array];
    SZFriendsAppearance *appearance = context.appearance;
    self.strokeColor = appearance.controlBorderColor;
    self.cornerRadius = 10;
    self.hidden = YES;
    _noteLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    NSTextField *note = _noteLabel;
    self.drawContents = ^(SZFriendsFlippedView *view) {
        // The spark before the host's note marks the card as the assistant's, as "Via the assistant" does under a
        // message it sent.
        (void)view;
        if (!note.hidden) SZFriendsDrawAssistantIcon(NSMakeRect(10, 12, 11, 11), appearance.secondaryTextColor);
    };
    // The message box looks like the bubble the message will become, so it reads as the message, not as a note.
    _box = [SZFriendsFlippedView new];
    _box.fillColor = appearance.outgoingBubbleColor;
    _box.cornerRadius = 10;
    _textScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 340, 40)];
    _textScroll.drawsBackground = NO;
    _textScroll.hasVerticalScroller = YES;
    _textScroll.hasHorizontalScroller = NO;
    _textScroll.autohidesScrollers = YES;
    // A scroller that stays drawn while there is more: an overlay one hides until scrolled, and the part below the
    // box would look like the end of the message.
    _textScroll.scrollerStyle = NSScrollerStyleLegacy;
    _textView = [[SZFriendsProposalTextView alloc] initWithFrame:NSMakeRect(0, 0, 340, 40)];
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.richText = NO;
    _textView.drawsBackground = NO;
    _textView.automaticLinkDetectionEnabled = NO;
    _textView.automaticDataDetectionEnabled = NO;
    _textView.textContainerInset = NSMakeSize(4, 6);
    _textView.verticallyResizable = YES;
    _textView.horizontallyResizable = NO;
    // The width is set from the layout, leaving the scroller's room even while it is hidden, so no line ever runs
    // under it or past the box (-layoutForWidth:apply:).
    _textView.textContainer.widthTracksTextView = NO;
    _textScroll.documentView = _textView;
    [_box addSubview:_textScroll];
    // The bubble's colour fading in over the last visible line while more lies below, so a long message never
    // looks finished where the box ends; the legacy scroller says the same where the system draws one.
    _fade = [SZFriendsEdgeFade new];
    _fade.edge = NSMinYEdge;
    _fade.color = appearance.outgoingBubbleColor;
    _fade.hidden = YES;
    [_box addSubview:_fade];
    _textScroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textScrolled:)
                                               name:NSViewBoundsDidChangeNotification
                                             object:_textScroll.contentView];
    _statusLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    __weak SZFriendsProposalView *weakSelf = self;
    _editButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary appearance:appearance];
    _editButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsProposalView *card = weakSelf;
        if (card.onEdit && !card.proposal.sending) card.onEdit();
    };
    _sendButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    _sendButton.font = SZFriendsSemibold(appearance.bodyFont);
    _sendButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsProposalView *card = weakSelf;
        if (card.onSend && card.enabled && !card.proposal.sending) card.onSend();
    };
    for (NSView *view in @[ _noteLabel, _box, _statusLabel, _spinner, _editButton, _sendButton ])
        [self addSubview:view];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)textScrolled:(NSNotification *)notification {
    (void)notification;
    [self updateFade];
}

- (void)updateFade {
    NSRect visible = _textScroll.contentView.bounds;
    _fade.hidden = NSMaxY(visible) >= NSHeight(_textView.frame) - 1;
}

- (void)setProposal:(SZFriendsAssistantProposal *)proposal {
    _proposal = proposal;
    self.hidden = proposal == nil;
    SZFriendsAppearance *appearance = _context.appearance;
    _noteLabel.stringValue = proposal.result.note ?: @"";
    [_textView.textStorage setAttributedString:SZFriendsLiteralText(proposal.result.text ?: @"", appearance.bodyFont,
                                                                    appearance.primaryTextColor,
                                                                    appearance.warningColor)];
    [_textView scrollRangeToVisible:NSMakeRange(0, 0)];
    for (NSView *file in _files) [file removeFromSuperview];
    [_files removeAllObjects];
    for (SZFriendsAttachableItem *item in proposal.attachments) {
        // Not a chip: nothing here can be removed. Edit moves the files into the composer, where they can.
        SZFriendsFlippedView *file = [SZFriendsFlippedView new];
        file.fillColor = appearance.controlColor;
        file.strokeColor = appearance.controlBorderColor;
        file.cornerRadius = 6;
        file.accessibilityElement = YES;
        file.accessibilityRole = NSAccessibilityStaticTextRole;
        file.accessibilityLabel = item.title;
        file.toolTip = item.detail.length ? item.detail : nil;
        NSString *title = item.title ?: @"", *kind = item.kindLabel;
        file.drawContents = ^(SZFriendsFlippedView *view) {
            SZFriendsDrawDocumentGlyph(NSMakeRect(6, 3, 14, 18), kind, appearance.secondaryTextColor);
            NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
            style.lineBreakMode = NSLineBreakByTruncatingMiddle;
            [title drawInRect:NSMakeRect(24, 4, MAX(0, NSWidth(view.bounds) - 30), 16)
                withAttributes:@{NSFontAttributeName : appearance.secondaryFont,
                                 NSForegroundColorAttributeName : appearance.primaryTextColor,
                                 NSParagraphStyleAttributeName : style}];
        };
        [_files addObject:file];
        [self addSubview:file];
    }
    _editButton.title = SZFAssistantWord(_context, @selector(proposalEditLabel));
    [self refresh];
}

- (NSArray<NSView *> *)fileViews {
    return [_files copy];
}

- (void)setSendLabel:(NSString *)sendLabel {
    _sendLabel = [sendLabel copy] ?: @"";
    [self refresh];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self refresh];
}

- (void)refresh {
    SZFriendsAppearance *appearance = _context.appearance;
    SZFriendsAssistantProposal *proposal = _proposal;
    BOOL sending = proposal.sending;
    _sendButton.title = _sendLabel;
    _sendButton.accessibilityLabel = _sendLabel;
    _sendButton.enabled = _enabled && !sending;
    _editButton.enabled = !sending;
    _statusLabel.stringValue = sending ? SZFAssistantWord(_context, @selector(proposalSendingStatus))
                                       : proposal.problem ?: @"";
    _statusLabel.textColor = sending ? appearance.secondaryTextColor : appearance.destructiveColor;
    if (sending) [_spinner startAnimation:nil];
    else [_spinner stopAnimation:nil];
    self.needsLayout = YES;
}

#pragma mark - Layout

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat inner = width - 20, y = 10;
    CGFloat noteHeight = SZFriendsFieldHeight(_noteLabel, inner - 16);
    if (apply) {
        _noteLabel.hidden = noteHeight == 0;
        _noteLabel.frame = NSMakeRect(26, y - 1, inner - 16, noteHeight);
    }
    if (noteHeight) y += noteHeight + 6;
    // The text at the box's width wraps every line, a long word or address included: nothing scrolls sideways.
    CGFloat textWidth = inner - 8 - [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
                                                              scrollerStyle:NSScrollerStyleLegacy];
    NSLayoutManager *layout = _textView.layoutManager;
    NSTextContainer *container = _textView.textContainer;
    CGFloat padding = 2 * _textView.textContainerInset.width;
    if (fabs(container.size.width - MAX(1, textWidth - padding)) > 0.5)
        container.size = NSMakeSize(MAX(1, textWidth - padding), CGFLOAT_MAX);
    [layout ensureLayoutForTextContainer:container];
    CGFloat textHeight = ceil([layout usedRectForTextContainer:container].size.height) +
                         2 * _textView.textContainerInset.height;
    CGFloat boxHeight = MIN(SZFMaxTextHeight, MAX(36, textHeight)) + 6;
    if (apply) {
        _box.frame = NSMakeRect(10, y, inner, boxHeight);
        _textScroll.frame = NSMakeRect(4, 3, inner - 8, boxHeight - 6);
        _textView.frame = NSMakeRect(0, 0, NSWidth(_textScroll.contentView.bounds), MAX(textHeight, boxHeight - 6));
        CGFloat scroller = _textScroll.verticalScroller.hidden ? 0 : NSWidth(_textScroll.verticalScroller.frame);
        _fade.frame = NSMakeRect(4, boxHeight - 3 - 22, MAX(0, inner - 8 - scroller), 22);
        [self updateFade];
    }
    y += boxHeight + 6;
    CGFloat x = 10;
    for (NSView *file in _files) {
        NSString *title = file.accessibilityLabel ?: @"";
        CGFloat fileWidth = MIN(inner, 30 + SZFriendsTextWidth(title, _context.appearance.secondaryFont));
        if (x > 10 && x + fileWidth > 10 + inner) {
            x = 10;
            y += 30;
        }
        if (apply) file.frame = NSMakeRect(x, y, fileWidth, 24);
        x += fileWidth + 6;
    }
    if (_files.count) y += 24 + 8;
    CGFloat sendWidth = MAX(64, [_sendButton fittingWidth]), editWidth = MAX(56, [_editButton fittingWidth]);
    CGFloat statusX = 10 + (_proposal.sending ? 22 : 0);
    CGFloat statusWidth = MAX(0, inner - sendWidth - editWidth - 8 - 10 - (statusX - 10));
    CGFloat statusHeight = SZFriendsFieldHeight(_statusLabel, statusWidth);
    if (apply) {
        _sendButton.frame = NSMakeRect(width - 10 - sendWidth, y, sendWidth, 28);
        _editButton.frame = NSMakeRect(NSMinX(_sendButton.frame) - 8 - editWidth, y, editWidth, 28);
        _spinner.frame = NSMakeRect(10, y + 6, 16, 16);
        _statusLabel.hidden = statusHeight == 0;
        _statusLabel.frame = NSMakeRect(statusX, y + 6, statusWidth, statusHeight);
    }
    return y + MAX(28, statusHeight + 6) + 10;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return self.hidden ? 0 : [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

@end
