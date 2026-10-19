// Shenzhen Friends views tests: `/` in a conversation. Typing `/` into an empty composer opens the assistant's
// command field; Return runs it with a progress row and Cancel; a draft fills the composer for review, a send clears
// what was sent, an error keeps the command; the request outlives the composer that started it.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsComposerInternal.h"

static SZFriendsAttachableItem *SZFItem(NSString *path, NSString *document) {
    SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
    item.title = path.lastPathComponent;
    item.kindLabel = @"PDF";
    item.fileURL = [NSURL fileURLWithPath:path];
    if (document) item.revision = @{@"source" : @"com.example.friends-views-tests", @"document_id" : document,
                                    @"revision_id" : @"r_1", @"size" : @1};
    return item;
}

static SZFriendsConversationPage *SZFMeiPage(SZFriendsContext *context) {
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_mei"
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, 640);
    [page applySnapshot:SZFTestSnapshot(@"conversation-mei")];
    return page;
}

static void SZFType(NSTextView *text, NSString *string) {
    [text insertText:string replacementRange:NSMakeRange(NSNotFound, 0)];
}

static BOOL SZFSentMessage(SZFTestTransport *transport) {
    for (NSDictionary *frame in transport.sent)
        if ([frame[@"type"] isEqualToString:@"send_message"]) return YES;
    return NO;
}

// The field: `/` opens it only as the first thing typed and only with an assistant; Escape and Delete leave it.
static void SZFTestCommandField(void) {
    SZFTestHost *plain = [SZFTestHost new];
    SZFriendsConversationPage *noAssistant = SZFMeiPage(SZFTestContext(plain, SZFTestReadyLink(NULL)));
    SZFType(noAssistant.composer.textView, @"/");
    SZFExpect([noAssistant.composer.textView.string isEqualToString:@"/"] && !noAssistant.composer.command,
              @"without an assistant `/` is text");

    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsConversationPage *page = SZFMeiPage(SZFTestContext(host, SZFTestReadyLink(NULL)));
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFriendsComposerView *composer = page.composer;
    SZFriendsComposerTextView *text = (SZFriendsComposerTextView *)composer.textView;
    SZFType(text, @"/");
    [page layoutSubtreeIfNeeded];
    SZFExpect(composer.commandState == SZFriendsCommandStateEditing && text.string.length == 0,
              @"`/` in an empty composer opens the command field and is not typed");
    SZFExpect(!composer.command.tag.hidden && !composer.command.runButton.hidden && composer.sendButton.hidden &&
                  composer.hintLabel.hidden,
              @"the tag and the arrow show; Send and the hint go");
    SZFExpect([text.placeholder isEqualToString:host.assistant.commandPlaceholder] &&
                  text.placeholderIndent > composer.command.tagWidth,
              @"the assistant's placeholder, after the tag");
    SZFExpect(SZFTestMissedHits(composer.command.runButton, window.contentView) == 0, @"the arrow is one target");
    SZFExpect([composer.command.runButton.accessibilityLabel isEqualToString:@"Ask the assistant"],
              @"the arrow says what it does");
    SZFType(text, @"summarize");
    SZFExpect([page dismissInnermostPicker] && composer.commandState == SZFriendsCommandStateOff &&
                  [text.string isEqualToString:@"/summarize"] && !composer.sendButton.hidden,
              @"Escape leaves the field and keeps what was typed: %@", text.string);
    SZFExpect(![page dismissInnermostPicker], @"a second Escape is the dropdown's");
    SZFType(text, @"x");
    text.string = @"";
    SZFType(text, @"/");
    SZFType(text, @"draft");
    [text setSelectedRange:NSMakeRange(0, 0)];
    [text keyDown:SZFTestKeyEvent(@"\x7f", 51, 0)];
    SZFExpect(composer.commandState == SZFriendsCommandStateOff && [text.string isEqualToString:@"draft"],
              @"Delete at the start removes the tag like the `/` it stood for: %@", text.string);
    [text setSelectedRange:NSMakeRange(text.string.length, 0)];
    SZFType(text, @"/");
    SZFExpect(composer.commandState == SZFriendsCommandStateOff && [text.string isEqualToString:@"draft/"],
              @"`/` after other text stays text");
}

// The host's note on what a command reads: under the field beside the arrow, wrapping, only while a command is being
// written; gone while it runs and once the field is a message again; nothing from a host without one.
static void SZFTestCommandNote(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsConversationPage *page = SZFMeiPage(SZFTestContext(host, SZFTestReadyLink(NULL)));
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFriendsComposerView *composer = page.composer;
    NSTextField *note = composer.command.commandNoteLabel;
    [page layoutSubtreeIfNeeded];
    SZFExpect(note.superview == composer && note.hidden, @"no note while the field holds a message");
    CGFloat messageHeight = NSHeight(composer.frame);
    SZFType(composer.textView, @"/");
    SZFType(composer.textView, @"summarize pages 3-5");
    [page layoutSubtreeIfNeeded];
    SZFExpect(!note.hidden && [note.stringValue isEqualToString:host.assistant.commandNote],
              @"writing a command shows the host's note: %@", note.stringValue);
    NSRect field = [composer convertRect:composer.inputBox.bounds fromView:composer.inputBox];
    NSRect arrow = composer.command.runButton.frame;
    SZFExpect(NSMinY(note.frame) >= NSMaxY(field) && NSMaxX(note.frame) <= NSMinX(arrow) &&
                  NSMaxY(note.frame) <= NSHeight(composer.bounds),
              @"under the field, beside the arrow, inside the composer: %@ field %@ arrow %@",
              NSStringFromRect(note.frame), NSStringFromRect(field), NSStringFromRect(arrow));
    CGFloat oneLine = ceil(note.font.ascender - note.font.descender + note.font.leading);
    SZFExpect(NSHeight(note.frame) > 2 * oneLine &&
                  NSHeight(note.frame) >= [note.cell cellSizeForBounds:NSMakeRect(0, 0, NSWidth(note.frame),
                                                                                  CGFLOAT_MAX)].height - 0.5,
              @"it wraps, every line shown: %.1f pt", NSHeight(note.frame));
    SZFExpect(NSHeight(composer.frame) > messageHeight, @"the composer grows to hold it");
    SZFExpect(SZFTestMissedHits(composer.command.runButton, window.contentView) == 0, @"the arrow stays one target");
    [composer.command run];
    [page layoutSubtreeIfNeeded];
    SZFExpect(note.hidden, @"while the command runs, the progress row speaks instead");
    [composer.command cancel];
    [page layoutSubtreeIfNeeded];
    SZFExpect(!note.hidden, @"back to writing it, the note is back");
    SZFExpect([page dismissInnermostPicker] && note.hidden, @"Escape: a message again, no note");

    SZFTestAssistantHost *plainHost = [SZFTestAssistantHost new];
    plainHost.assistant = [SZFTestAssistant new];
    plainHost.assistant.plain = YES;
    SZFriendsConversationPage *plain = SZFMeiPage(SZFTestContext(plainHost, SZFTestReadyLink(NULL)));
    SZFTestHostWindow(plain, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFType(plain.composer.textView, @"/");
    [plain layoutSubtreeIfNeeded];
    SZFriendsComposerView *bare = plain.composer;
    SZFExpect(bare.commandState == SZFriendsCommandStateEditing && bare.command.commandNoteLabel.hidden,
              @"a host without a note shows none");
}

// Running: the command, the conversation and the person's chips go to the host; progress with Cancel; Cancel stops
// the request and keeps the command; a late answer changes nothing.
static void SZFTestRunAndCancel(void) {
    SZFTestTransport *transport = nil;
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(&transport));
    SZFriendsConversationPage *page = SZFMeiPage(context);
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    SZFriendsComposerView *composer = page.composer;
    SZFriendsAttachableItem *contract = SZFItem(@"/tmp/Contract.pdf", @"d_contract");
    [composer addAttachments:@[ contract ]];
    SZFType(composer.textView, @"/");
    SZFType(composer.textView, @"summarize pages 3-5 ");
    [composer.textView keyDown:SZFTestKeyEvent(@"\r", 36, 0)];
    NSDictionary *call = host.assistant.calls.lastObject;
    SZFExpect(host.assistant.calls.count == 1 && [call[@"command"] isEqualToString:@"summarize pages 3-5"] &&
                  [call[@"conversation_id"] isEqualToString:@"c_mei"] &&
                  [call[@"attachments"] isEqual:@[ contract ]],
              @"Return runs the command with this conversation and the person's chips: %@", call);
    [page layoutSubtreeIfNeeded];
    SZFExpect(composer.commandState == SZFriendsCommandStateRunning && !composer.command.progressRow.hidden &&
                  composer.command.runButton.hidden && !composer.textView.editable,
              @"running: the progress row replaces the arrow, the command can't change under it");
    host.assistant.progress(@"Reading pages 3–5");
    SZFExpect([composer.command.progressLabel.stringValue isEqualToString:@"Reading pages 3–5"],
              @"progress in the host's words");
    SZFriendsButton *cancel = composer.command.cancelButton;
    SZFExpect([cancel.title isEqualToString:@"Cancel"] && SZFTestMissedHits(cancel, window.contentView) == 0,
              @"Cancel, from the welcome strings, one full target");
    [composer.textView keyDown:SZFTestKeyEvent(@"\r", 36, 0)];
    SZFExpect(host.assistant.calls.count == 1, @"Return while running starts nothing");
    [cancel performClick:nil];
    SZFExpect(host.assistant.cancels == 1 && composer.commandState == SZFriendsCommandStateEditing &&
                  [composer.textView.string isEqualToString:@"summarize pages 3-5"] && composer.textView.editable,
              @"Cancel stops it and keeps the command to change and run again");
    SZFriendsAssistantResult *late = [SZFriendsAssistantResult new];
    late.text = @"Too late";
    host.assistant.completion(late, nil);
    SZFExpect(composer.commandState == SZFriendsCommandStateEditing &&
                  [composer.textView.string isEqualToString:@"summarize pages 3-5"] && !SZFSentMessage(transport),
              @"an answer after Cancel changes nothing");
    SZFExpect(context.assistantRuns.count == 0, @"and nothing is left running");
}

// Results: a draft fills the composer (only the person's chips, or pages cut from them); a send clears what went;
// an error keeps the command with the host's words. The views never send anything themselves.
static void SZFTestResults(void) {
    SZFTestTransport *transport = nil;
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(&transport));
    SZFriendsConversationPage *page = SZFMeiPage(context);
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    (void)window;
    SZFriendsComposerView *composer = page.composer;
    SZFriendsAttachableItem *contract = SZFItem(@"/tmp/Contract.pdf", @"d_contract");
    [composer addAttachments:@[ contract ]];
    SZFType(composer.textView, @"/");
    SZFType(composer.textView, @"draft a reply with pages 3-5");
    [composer.command run];
    SZFriendsAssistantResult *draft = [SZFriendsAssistantResult new];
    draft.text = @"Pages 3–5 look right. One question on the bracket.";
    draft.note = @"Not sent yet. Check it, then press Send.";
    draft.attachments = @[ contract, SZFItem(@"/tmp/Contract pages 3-5.pdf", @"d_contract"),
                           SZFItem(@"/Users/someone/.ssh/id_ed25519", nil) ];
    host.assistant.completion(draft, nil);
    NSArray<NSString *> *titles = [composer.attachments valueForKey:@"title"];
    SZFExpect(composer.commandState == SZFriendsCommandStateOff &&
                  [composer.textView.string isEqualToString:draft.text] && !composer.sendButton.hidden,
              @"a draft fills the composer for review, Send ready");
    SZFExpect([titles isEqual:(@[ @"Contract.pdf", @"Contract pages 3-5.pdf" ])],
              @"the chip stays, pages cut from it join, a file the person never attached does not: %@", titles);
    SZFExpect([composer.command.noteLabel.stringValue isEqualToString:draft.note] && !SZFSentMessage(transport),
              @"the host's note shows, and nothing was sent");
    [composer send];
    SZFExpect(SZFSentMessage(transport), @"the person's Send sends it");
    NSDictionary *sent = transport.sent.lastObject;
    SZFExpect(sent[@"fields"][@"via_assistant"] == nil, @"as their own message");

    composer.textView.string = @"";
    while (composer.attachments.count) [composer removeAttachmentAtIndex:0];
    SZFriendsAttachableItem *photos = SZFItem(@"/tmp/Site photos.pdf", @"d_photos");
    [composer addAttachments:@[ contract, photos ]];
    SZFType(composer.textView, @"/");
    SZFType(composer.textView, @"send Mei the contract");
    [composer.command run];
    NSUInteger frames = transport.sent.count;
    SZFriendsAssistantResult *done = [SZFriendsAssistantResult new];
    done.outcome = SZFriendsAssistantOutcomeSent;
    done.text = @"Here is the contract.";
    done.attachments = @[ contract ];
    host.assistant.completion(done, nil);
    SZFExpect(composer.commandState == SZFriendsCommandStateOff && composer.textView.string.length == 0 &&
                  [[composer.attachments valueForKey:@"title"] isEqual:@[ @"Site photos.pdf" ]] &&
                  transport.sent.count == frames,
              @"a send clears the command and what went with it; the views send nothing");

    SZFType(composer.textView, @"/");
    SZFType(composer.textView, @"send it to Kenji");
    [composer.command run];
    host.assistant.completion(nil, [NSError errorWithDomain:@"test" code:1 userInfo:@{
        NSLocalizedDescriptionKey : @"The assistant can only send to Mei here."}]);
    SZFExpect(composer.commandState == SZFriendsCommandStateEditing &&
                  [composer.textView.string isEqualToString:@"send it to Kenji"],
              @"an error keeps the command");
    [page layoutSubtreeIfNeeded];
    BOOL shown = NO;
    NSString *words = @"The assistant can only send to Mei here.";
    for (NSTextField *field in SZFTestSubviews(composer, NSTextField.class))
        shown = shown || (!field.hidden && [field.stringValue isEqualToString:words]);
    SZFExpect(shown, @"with the host's words");
}

// The request belongs to the conversation, not the composer: a new composer shows it running and gets its result;
// with no composer at all, the result waits in the conversation's draft. A command field comes back too.
static void SZFTestOutlivesComposer(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFriendsConversationPage *first = SZFMeiPage(context);
    SZFType(first.composer.textView, @"/");
    SZFType(first.composer.textView, @"draft a thank-you");
    [first.composer.command run];
    SZFriendsConversationPage *second = SZFMeiPage(context);
    SZFExpect(second.composer.commandState == SZFriendsCommandStateRunning &&
                  [second.composer.textView.string isEqualToString:@"draft a thank-you"],
              @"a new composer shows the request still running");
    SZFriendsAssistantResult *draft = [SZFriendsAssistantResult new];
    draft.text = @"Thank you, Mei!";
    host.assistant.completion(draft, nil);
    SZFExpect([second.composer.textView.string isEqualToString:@"Thank you, Mei!"] &&
                  second.composer.commandState == SZFriendsCommandStateOff,
              @"and gets its result");

    __weak SZFriendsConversationPage *gone = nil;
    @autoreleasepool {
        SZFriendsConversationPage *page = SZFMeiPage(context);
        page.composer.textView.string = @"";
        SZFType(page.composer.textView, @"/");
        SZFType(page.composer.textView, @"draft a reminder");
        [page.composer.command run];
        gone = page;
        page = nil;
        first = nil;
        second = nil;
    }
    SZFExpect(gone == nil, @"the page went away");
    SZFriendsAssistantResult *later = [SZFriendsAssistantResult new];
    later.text = @"Reminder: pages 3–5 by Friday.";
    host.assistant.completion(later, nil);
    SZFExpect([context.drafts[@"c_mei"].text isEqualToString:later.text] && !context.drafts[@"c_mei"].command,
              @"with no composer, the result waits in the draft");
    SZFriendsConversationPage *reopened = SZFMeiPage(context);
    SZFExpect([reopened.composer.textView.string isEqualToString:later.text], @"where the next composer finds it");

    reopened.composer.textView.string = @"";
    SZFType(reopened.composer.textView, @"/");
    SZFType(reopened.composer.textView, @"summarize");
    SZFriendsConversationPage *again = SZFMeiPage(context);
    SZFExpect(again.composer.commandState == SZFriendsCommandStateEditing &&
                  [again.composer.textView.string isEqualToString:@"summarize"],
              @"an unfinished command comes back as a command");
}

void SZFTestAssistantCommands(void) {
    SZFTestCommandField();
    SZFTestCommandNote();
    SZFTestRunAndCancel();
    SZFTestResults();
    SZFTestOutlivesComposer();
}
