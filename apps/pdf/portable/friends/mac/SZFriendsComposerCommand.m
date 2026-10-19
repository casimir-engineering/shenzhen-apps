// The composer's text view, and `/`: a command for the host's assistant typed into the composer, its progress with
// Cancel, and what its result does (a draft fills the composer for review; a proposed message waits on a card above
// it for the person's Send or Edit, SZFriendsComposerProposal.m).

#import "mac/SZFriendsComposerInternal.h"

@implementation SZFriendsComposerTextView
- (void)keyDown:(NSEvent *)event {
    BOOL returnKey = event.keyCode == 36 || event.keyCode == 76;
    if (returnKey && !self.hasMarkedText) {
        if (event.modifierFlags & NSEventModifierFlagShift) {
            [self insertText:@"\n" replacementRange:self.selectedRange];
        } else if (self.onReturn) {
            self.onReturn();
        }
        return;
    }
    if (event.keyCode == 53 && !self.hasMarkedText) {
        SZFriendsForwardEscape(self);
        return;
    }
    NSRange selection = self.selectedRange;
    if (event.keyCode == 51 && !self.hasMarkedText && selection.location == 0 && selection.length == 0 &&
        self.onDeleteAtStart && self.onDeleteAtStart())
        return;
    [super keyDown:event];
}
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSRange target = replacementRange.location == NSNotFound ? self.selectedRange : replacementRange;
    NSUInteger location = target.location;
    NSString *before = self.string;
    NSString *typed = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    // `/` asks the assistant only as the first thing typed, so "and/or" or a pasted path stays a message.
    if ([typed isEqualToString:@"/"] && before.length == 0 && !self.hasMarkedText && self.onSlash && self.onSlash())
        return;
    [super insertText:string replacementRange:replacementRange];
    // `#` and `@` open their pickers only where a word starts, so "C#", "#3" or an email address stays plain text.
    BOOL atWordStart = location == 0 || (location <= before.length &&
                                         [NSCharacterSet.whitespaceAndNewlineCharacterSet
                                             characterIsMember:[before characterAtIndex:location - 1]]);
    if ([typed isEqualToString:@"#"] && atWordStart && self.onHash) self.onHash();
    if ([typed isEqualToString:@"@"] && atWordStart && !self.hasMarkedText && self.onAt) self.onAt();
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.string.length || !self.placeholder.length) return;
    NSDictionary *attributes = @{NSFontAttributeName : self.font ?: [NSFont systemFontOfSize:13],
                                 NSForegroundColorAttributeName : self.placeholderColor ?: NSColor.secondaryLabelColor};
    CGFloat x = self.textContainerInset.width + self.textContainer.lineFragmentPadding + self.placeholderIndent;
    // Wrapped, not clipped: after the `/` tag a host's placeholder rarely fits one line.
    NSRect rect = NSMakeRect(x, self.textContainerInset.height, MAX(0, NSWidth(self.bounds) - x - 4),
                             MAX(0, NSHeight(self.bounds) - self.textContainerInset.height));
    [self.placeholder drawWithRect:rect options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes];
}
@end

#pragma mark - Requests

// One `/` request. The context holds it until it finishes, so its result has somewhere to go once the composer that
// started it is gone.
@interface SZFriendsAssistantRun : NSObject
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSArray<SZFriendsAttachableItem *> *attachments; // the chips when it ran
@property(nonatomic, copy) NSString *status;
@property(nonatomic, strong, nullable) id<SZFriendsAssistantTask> task;
@property(nonatomic) BOOL finished;
@property(nonatomic, weak, nullable) SZFriendsComposerCommand *observer;
@end

@implementation SZFriendsAssistantRun
@end

// A proposal the views can show as one: the host sends it on the person's Send, named the Edit that is the other
// choice, and every file it would send came from the person's chips, so the card shows all that `send` sends.
// Anything less is shown as a draft, which the person sends from the composer (SZFriendsHost.h).
static BOOL SZFShowsAsProposal(SZFriendsAssistantResult *result, id<SZFriendsAssistant> assistant,
                               NSArray<SZFriendsAttachableItem *> *chipsWhenRun) {
    if (result.outcome != SZFriendsAssistantOutcomeProposed || !result.send ||
        ![assistant respondsToSelector:@selector(proposalEditLabel)] || !assistant.proposalEditLabel.length)
        return NO;
    for (SZFriendsAttachableItem *item in result.attachments)
        if (!SZFriendsAssistantItemComesFrom(item, chipsWhenRun)) return NO;
    return YES;
}

#pragma mark - The command field

@interface SZFriendsComposerCommand () <SZFriendsProposalObserver>
@property(nonatomic, readwrite) SZFriendsCommandState state;
@end

@implementation SZFriendsComposerCommand {
    __weak SZFriendsContext *_context;
    NSString *_conversationID;
    __weak SZFriendsComposerView *_composer;
    SZFriendsAssistantRun *_run;
    NSProgressIndicator *_spinner;
    NSString *_label;
}

- (instancetype)initWithContext:(SZFriendsContext *)context conversationID:(NSString *)conversationID
                       composer:(SZFriendsComposerView *)composer {
    if (!(self = [super init])) return nil;
    _context = context;
    _conversationID = [conversationID copy];
    _composer = composer;
    _enabled = YES;
    SZFriendsAppearance *appearance = context.appearance;
    id<SZFriendsAssistant> assistant = [self assistant];
    _label = assistant.commandLabel ?: @"";
    _placeholder = assistant.commandPlaceholder ?: @"";
    _tag = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, [self tagWidth], 17)];
    _tag.fillColor = [appearance.accentColor colorWithAlphaComponent:0.14];
    _tag.cornerRadius = 8.5;
    _tag.hidden = YES;
    _tag.accessibilityElement = YES;
    _tag.accessibilityRole = NSAccessibilityStaticTextRole;
    _tag.accessibilityLabel = _label;
    NSString *label = _label;
    _tag.drawContents = ^(SZFriendsFlippedView *view) {
        (void)view;
        SZFriendsDrawAssistantIcon(NSMakeRect(6, 3.5, 10, 10), appearance.accentColor);
        NSDictionary *attributes = @{NSFontAttributeName : SZFriendsSemibold(appearance.captionFont),
                                     NSForegroundColorAttributeName : appearance.accentColor};
        [label drawAtPoint:NSMakePoint(19, 1.5) withAttributes:attributes];
    };
    __weak SZFriendsComposerCommand *weakSelf = self;
    _runButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    _runButton.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawArrowUpIcon(rect, color); };
    _runButton.iconSize = NSMakeSize(14, 14);
    _runButton.accessibilityLabel = _label;
    _runButton.toolTip = _label;
    _runButton.hidden = YES;
    _runButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf run];
    };
    _progressRow = [SZFriendsFlippedView new];
    _progressRow.hidden = YES;
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 6, 16, 16)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _progressLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _progressLabel.maximumNumberOfLines = 1;
    _progressLabel.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    _cancelButton = [SZFriendsButton buttonWithTitle:[context string:@"cancel"] style:SZFriendsButtonStyleLink
                                          appearance:appearance];
    _cancelButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf cancel];
    };
    for (NSView *view in @[ _spinner, _progressLabel, _cancelButton ]) [_progressRow addSubview:view];
    _noteLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    NSString *commandNote = [assistant respondsToSelector:@selector(commandNote)] ? assistant.commandNote : nil;
    _commandNoteLabel = SZFriendsLabel(commandNote, appearance.secondaryFont, appearance.secondaryTextColor);
    _commandNoteLabel.hidden = YES;
    _proposalView = [[SZFriendsProposalView alloc] initWithContext:context];
    _proposalView.enabled = YES;
    _proposalView.onSend = ^{ [weakSelf sendProposal]; };
    _proposalView.onEdit = ^{ [weakSelf editProposal]; };
    return self;
}

- (id<SZFriendsAssistant>)assistant {
    id<SZFriendsHost> host = _context.host;
    return [host respondsToSelector:@selector(friendsAssistant)] ? host.friendsAssistant : nil;
}

- (CGFloat)tagWidth {
    return _label.length ? 19 + SZFriendsTextWidth(_label, SZFriendsSemibold(_context.appearance.captionFont)) + 8 : 0;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    _proposalView.enabled = enabled; // blocked or no longer friends: the card's Send would only fail
    if (!enabled && _state == SZFriendsCommandStateEditing) [self leave];
}

- (void)setState:(SZFriendsCommandState)state {
    _state = state;
    _tag.hidden = state == SZFriendsCommandStateOff;
    _runButton.hidden = state != SZFriendsCommandStateEditing;
    // Read while deciding whether to run the command; once it runs, the progress row says what it is doing.
    _commandNoteLabel.hidden = state != SZFriendsCommandStateEditing || !_commandNoteLabel.stringValue.length;
    _progressRow.hidden = state != SZFriendsCommandStateRunning;
    if (state == SZFriendsCommandStateRunning) [_spinner startAnimation:nil];
    else [_spinner stopAnimation:nil];
    _progressLabel.stringValue = _run.status ?: @"";
    SZFriendsComposerView *composer = _composer;
    [composer saveDraft];
    [composer changedHeight];
}

- (BOOL)begin {
    if (!self.enabled || !_label.length || _state != SZFriendsCommandStateOff || ![self assistant]) return NO;
    [self clearNote];
    [_composer showError:nil];
    self.state = SZFriendsCommandStateEditing;
    return YES;
}

- (void)leave {
    if (_state != SZFriendsCommandStateEditing) return;
    NSTextView *text = _composer.textView;
    // The tag stood for the `/` typed: leaving puts it back, so nothing typed is lost and it is plainly a message now.
    if (text.string.length) text.string = [@"/" stringByAppendingString:text.string];
    self.state = SZFriendsCommandStateOff;
}

- (void)deleteTag {
    // Delete before the first character removes the tag as it would the `/`: the rest stays, as a message.
    self.state = SZFriendsCommandStateOff;
}

- (void)restoreCommand:(NSString *)command {
    // The text first: opening the field saves the draft, which must not lose the command.
    _composer.textView.string = command;
    if (![self begin]) _composer.textView.string = command.length ? [@"/" stringByAppendingString:command] : @"";
}

- (void)clearNote {
    if (!_noteLabel.stringValue.length) return;
    _noteLabel.stringValue = @"";
    [_composer changedHeight];
}

- (void)run {
    SZFriendsComposerView *composer = _composer;
    SZFriendsContext *context = _context;
    id<SZFriendsAssistant> assistant = [self assistant];
    NSString *command = [composer.textView.string
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (_state != SZFriendsCommandStateEditing || !command.length || !assistant || !composer || !context) return;
    SZFriendsAssistantRun *run = [SZFriendsAssistantRun new];
    run.conversationID = _conversationID;
    run.command = command;
    run.attachments = composer.attachments;
    run.status = @"";
    context.assistantRuns[_conversationID] = run;
    [composer showError:nil];
    [self showRun:run];
    __weak SZFriendsAssistantRun *weakRun = run;
    __weak SZFriendsContext *weakContext = context;
    id<SZFriendsAssistantTask> task = [assistant runCommand:command conversationID:_conversationID
        attachments:run.attachments
        progress:^(NSString *status) {
            SZFriendsAssistantRun *current = weakRun;
            if (!current || current.finished) return;
            current.status = status ?: @"";
            [current.observer showRun:current];
        }
        completion:^(SZFriendsAssistantResult *result, NSError *error) {
            SZFriendsAssistantRun *current = weakRun;
            if (!current || current.finished) return; // cancelled, or answered twice
            current.finished = YES;
            [SZFriendsComposerCommand finishRun:current result:result error:error context:weakContext];
        }];
    if (!run.finished) run.task = task;
}

- (void)showRun:(SZFriendsAssistantRun *)run {
    _run = run;
    run.observer = self;
    _composer.textView.string = run.command;
    self.state = SZFriendsCommandStateRunning;
}

// A request started from an earlier composer of this conversation, still running: show its progress here. A message
// it proposed and the person has not sent or edited yet: show its card.
- (void)adoptRunningRequest {
    SZFriendsAssistantProposal *proposal = _context.assistantProposals[_conversationID];
    if ([proposal isKindOfClass:SZFriendsAssistantProposal.class]) [self showProposal:proposal];
    SZFriendsAssistantRun *run = _context.assistantRuns[_conversationID];
    if ([run isKindOfClass:SZFriendsAssistantRun.class] && !run.finished) [self showRun:run];
}

- (void)cancel {
    SZFriendsAssistantRun *run = _run;
    if (_state != SZFriendsCommandStateRunning || !run) return;
    run.finished = YES;
    [run.task cancel];
    if (_context.assistantRuns[_conversationID] == run) [_context.assistantRuns removeObjectForKey:_conversationID];
    _run = nil;
    _composer.textView.string = run.command;
    self.state = SZFriendsCommandStateEditing;
    [_composer.window makeFirstResponder:_composer.textView];
}

+ (void)finishRun:(SZFriendsAssistantRun *)run result:(SZFriendsAssistantResult *)result error:(NSError *)error
          context:(SZFriendsContext *)context {
    if (context.assistantRuns[run.conversationID] == run) [context.assistantRuns removeObjectForKey:run.conversationID];
    SZFriendsComposerCommand *observer = run.observer;
    if (observer && observer->_run == run) {
        [observer applyResult:result error:error run:run];
        return;
    }
    if (!context) return;
    id<SZFriendsHost> host = context.host;
    id<SZFriendsAssistant> assistant = nil;
    if ([host respondsToSelector:@selector(friendsAssistant)]) assistant = host.friendsAssistant;
    if (SZFShowsAsProposal(result, assistant, run.attachments)) {
        // No composer shows this conversation now: the proposal waits with the context for the next one. As in a
        // composer showing it, the command is used up and its files leave the draft for the card.
        SZFriendsAssistantProposal *proposal = [[SZFriendsAssistantProposal alloc]
            initWithResult:result chipsWhenRun:run.attachments conversationID:run.conversationID];
        context.assistantProposals[run.conversationID] = proposal;
        SZFriendsDraft *draft = context.drafts[run.conversationID];
        NSMutableArray *kept = [NSMutableArray array];
        for (SZFriendsAttachableItem *item in draft.items)
            if (!SZFriendsAssistantItemComesFrom(item, proposal.attachments)) [kept addObject:item];
        draft.items = kept;
        if (draft.command) draft.text = @"";
        draft.command = NO;
        if (draft && !draft.text.length && !draft.items.count) [context.drafts removeObjectForKey:run.conversationID];
        return;
    }
    // No composer shows this conversation now: the result waits in its draft, where the next composer finds it.
    SZFriendsDraft *draft = context.drafts[run.conversationID] ?: [SZFriendsDraft new];
    if (!result) {
        draft.text = run.command;
        draft.command = YES;
    } else if (result.outcome == SZFriendsAssistantOutcomeSent) {
        draft.text = @"";
        draft.command = NO;
        NSMutableArray *kept = [NSMutableArray array];
        for (SZFriendsAttachableItem *item in draft.items)
            if (!SZFriendsAssistantItemComesFrom(item, result.attachments)) [kept addObject:item];
        draft.items = kept;
    } else {
        draft.text = result.text ?: @"";
        draft.command = NO;
        NSArray *additions = SZFriendsAssistantDraftAdditions(result, run.attachments, draft.items);
        draft.items = [draft.items arrayByAddingObjectsFromArray:additions];
    }
    if (draft.text.length || draft.items.count) context.drafts[run.conversationID] = draft;
    else [context.drafts removeObjectForKey:run.conversationID];
}

- (void)applyResult:(SZFriendsAssistantResult *)result error:(NSError *)error run:(SZFriendsAssistantRun *)run {
    SZFriendsComposerView *composer = _composer;
    SZFriendsContext *context = _context;
    _run = nil;
    if (!result) {
        // The command stays, so the person can change it and try again; the host's words say what went wrong.
        composer.textView.string = run.command;
        self.state = SZFriendsCommandStateEditing;
        [composer showError:error.localizedDescription ?: @""];
        [context announce:error.localizedDescription];
        return;
    }
    composer.textView.string = @"";
    if (SZFShowsAsProposal(result, [self assistant], run.attachments)) {
        // Nothing is sent yet: the card above shows exactly what would go, with Send and Edit.
        SZFriendsAssistantProposal *proposal = [[SZFriendsAssistantProposal alloc]
            initWithResult:result chipsWhenRun:run.attachments conversationID:_conversationID];
        context.assistantProposals[_conversationID] = proposal;
        // Its files now show on the card and go with its Send. Left in the composer too, the composer's own Send
        // would send them alone, without the message; Edit brings them back.
        NSArray<SZFriendsAttachableItem *> *chips = composer.attachments;
        for (NSUInteger index = chips.count; index > 0; index--)
            if (SZFriendsAssistantItemComesFrom(chips[index - 1], proposal.attachments))
                [composer removeAttachmentAtIndex:index - 1];
        [self showProposal:proposal];
        [composer.window makeFirstResponder:composer.textView];
    } else if (result.outcome == SZFriendsAssistantOutcomeSent) {
        // The message is in the history now, with its label; what went with it leaves the composer.
        NSArray<SZFriendsAttachableItem *> *chips = composer.attachments;
        for (NSUInteger index = chips.count; index > 0; index--)
            if (SZFriendsAssistantItemComesFrom(chips[index - 1], result.attachments))
                [composer removeAttachmentAtIndex:index - 1];
    } else {
        composer.textView.string = result.text ?: @"";
        [composer addAttachments:SZFriendsAssistantDraftAdditions(result, run.attachments, composer.attachments)];
        _noteLabel.stringValue = result.note ?: @"";
        [composer.window makeFirstResponder:composer.textView];
        [composer.textView setSelectedRange:NSMakeRange(composer.textView.string.length, 0)];
    }
    self.state = SZFriendsCommandStateOff;
    [context announce:result.note];
}

#pragma mark - A proposed message

- (void)showProposal:(SZFriendsAssistantProposal *)proposal {
    SZFriendsAssistantProposal *shown = _proposalView.proposal;
    if (shown.observer == self) shown.observer = nil;
    proposal.observer = self;
    _proposalView.sendLabel = _composer.sendButton.title ?: @"";
    _proposalView.proposal = proposal;
    [_composer changedHeight];
}

- (void)setSendLabel:(NSString *)label {
    _proposalView.sendLabel = label ?: @"";
}

- (void)sendProposal {
    SZFriendsAssistantProposal *proposal = _proposalView.proposal;
    SZFriendsContext *context = _context;
    if (proposal && context && _enabled) [proposal sendInContext:context];
}

// Edit: the message and its files move into the composer as a draft would, and the card goes. Text the person typed
// meanwhile stays first, so nothing of theirs is lost.
- (void)editProposal {
    SZFriendsAssistantProposal *proposal = _proposalView.proposal;
    SZFriendsComposerView *composer = _composer;
    if (!proposal || proposal.sending || !composer) return;
    if (_context.assistantProposals[_conversationID] == proposal)
        [_context.assistantProposals removeObjectForKey:_conversationID];
    proposal.observer = nil;
    _proposalView.proposal = nil;
    NSTextView *text = composer.textView;
    NSString *typed = text.string ?: @"", *message = proposal.result.text ?: @"";
    // Appended to what is there, so `@` chips typed meanwhile stay chips rather than bare U+FFFC.
    NSDictionary *plain = @{NSFontAttributeName : _context.appearance.bodyFont,
                            NSForegroundColorAttributeName : _context.appearance.primaryTextColor};
    if (typed.length)
        [text.textStorage appendAttributedString:[[NSAttributedString alloc]
                                                     initWithString:[@"\n\n" stringByAppendingString:message]
                                                         attributes:plain]];
    else text.string = message;
    [composer addAttachments:SZFriendsAssistantDraftAdditions(proposal.result, proposal.chipsWhenRun,
                                                              composer.attachments)];
    [composer.window makeFirstResponder:text];
    [text setSelectedRange:NSMakeRange(text.string.length, 0)];
    [composer saveDraft];
    [composer changedHeight];
}

- (void)proposalDidChange:(SZFriendsAssistantProposal *)proposal {
    if (proposal != _proposalView.proposal) return;
    [_proposalView refresh];
    [_composer changedHeight];
}

- (void)proposalWasSent:(SZFriendsAssistantProposal *)proposal {
    // The message shows in the history now; its files left the composer when the card took them.
    if (proposal == _proposalView.proposal) _proposalView.proposal = nil;
    [_composer changedHeight];
}

@end
