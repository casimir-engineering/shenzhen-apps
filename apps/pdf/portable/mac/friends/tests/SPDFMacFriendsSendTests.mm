// friends_send_message, instrumented (ai-agent-capabilities.md § Verification, Sending): no chip, no tool; chips
// limit recipients; attachments only from the person's own chips; at most 3 per request; nothing queued without the
// person's Send; injected instructions in friend messages, documents and tool results cannot add recipients or
// attachments; the card, Cancel and via_assistant. Every call goes through the AI tool registry, as the reader runs
// it; the fake sender records what reached Friends.

#import <AppKit/AppKit.h>
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacFriendsComposerText.h"
#import "SPDFMacFriendsSendProvider.h"
#import "SPDFMacFriendsToolProvider.h"
#import "SPDFMacFriendsTestSupport.h"
#import "SPDFMacFriendsScopeFakes.h"
#import "SPDFMacFriendsSendFakes.h"

static NSArray* Names(NSArray* definitions) { return [definitions valueForKeyPath:@"function.name"] ?: @[]; }

static SPDFMacAIRequestContext* Context(NSArray* chips, id<SPDFMacAIActivityReporting> activity) {
    return [[SPDFMacAIRequestContext alloc] initWithText:@"x" chips:chips origin:SPDFMacAIRequestOriginChat
                                      friendConversation:nil settings:nil budget:nil activity:activity];
}

static NSDictionary* Parameters(SPDFMacFriendsSendProvider* provider, SPDFMacAIRequestContext* context) {
    return [[provider toolDefinitionsForContext:context].firstObject valueForKeyPath:@"function.parameters.properties"];
}

static NSDictionary* Send(SPDFMacAIToolRegistry* registry, SPDFMacAIRequestContext* context, NSDictionary* arguments) {
    __block NSDictionary* result = nil;
    [registry performTool:SPDFMacFriendsSendToolName arguments:arguments context:context
               completion:^(NSDictionary* r) { result = r; }];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return result != nil; }), @"the send never completed");
    return result;
}

static NSDictionary* Card(SPDFMacAIChatActivity* activity) {
    for (NSDictionary* entry in activity.entries.reverseObjectEnumerator)
        if ([entry[SPDFMacAIActivityCardKindKey] isEqual:SPDFMacFriendsSendCardKind]) return entry;
    return nil;
}

static NSArray* ActionIDs(SPDFMacAIChatActivity* activity, NSDictionary* card) {
    return [[activity liveActionsForEntry:card[SPDFMacAIActivityIDKey]] valueForKey:@"id"];
}

// The tool's call, then the person's Send on the card it left: the only way anything reaches Friends.
static NSDictionary* SendAndPress(SPDFMacAIToolRegistry* registry, SPDFMacAIRequestContext* context,
                                  NSDictionary* arguments) {
    SPDFMacAIChatActivity* activity = (SPDFMacAIChatActivity*)context.activity;
    NSUInteger cards = activity.entries.count;
    NSDictionary* result = Send(registry, context, arguments);
    Expect(![result[@"sent"] isEqual:@YES], @"a call reported a send by itself: %@", result);
    if (activity.entries.count > cards)
        [activity performAction:@"send" forEntry:Card(activity)[SPDFMacAIActivityIDKey]];
    return result;
}

static SPDFMacAIToolRegistry* Registry(SPDFMacFriendsSendProvider* provider) {
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    [registry registerProvider:provider error:nil];
    return registry;
}

static void TestNoChipNoTool(void) {
    FakeSender* sender = [FakeSender new];
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    SPDFMacAIToolRegistry* registry = Registry(provider);
    NSURL* file = [NSURL fileURLWithPath:@"/tmp/Contract.pdf"];
    for (NSArray* chips in @[@[], @[[SPDFMacAIRequestChip attachmentChipWithFileURL:file displayName:@"Contract.pdf"]],
                             @[[SPDFMacAIRequestChip friendsChipWithConversationIDs:nil
                                                                         displayName:@"All Friends chats"]]]) {
        SPDFMacAIRequestContext* context = Context(chips, nil);
        Expect(![provider toolDefinitionsForContext:context].count &&
               ![registry toolDefinitionsForContext:context].count,
               @"a request without a chip naming a friend was offered sending: %@", chips);
        NSDictionary* result = Send(registry, context, @{@"to" : @"Mei", @"text" : @"hi"});
        Expect([result[@"error"] containsString:@"isn't part of this request"] && !sender.intents.count,
               @"a send without a chip reached Friends or was refused for the wrong reason: %@", result);
    }
}

static void TestChipsLimitRecipients(void) {
    FakeSender* sender = [FakeSender new];
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    SPDFMacAIToolRegistry* registry = Registry(provider);
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    SPDFMacAIRequestContext* context = Context(@[FriendChip(@"c_mei", @"Mei"), FriendChip(@"c_kenji", @"Kenji"),
        FriendChip(@"c_mei", @"Mei"), FriendChip(@"c_mei2", @"Mei")], activity);
    NSArray* allowed = Parameters(provider, context)[@"to"][@"enum"];
    Expect(([allowed isEqual:@[@"Mei", @"Kenji", @"Mei (2)"]]), @"recipients must be the chips, once each: %@",
           allowed);
    for (NSString* other in @[@"Priya", @"c_kenji", @"mei", @""]) {
        NSDictionary* result = Send(registry, context, @{@"to" : other, @"text" : @"hi"});
        Expect([result[@"error"] containsString:@"only to \"Mei\", \"Kenji\", \"Mei (2)\""] && !sender.intents.count &&
               !activity.entries.count, @"a recipient outside the chips (%@) reached a card or Friends: %@", other,
               result);
    }
    NSDictionary* result = SendAndPress(registry, context, @{@"to" : @"Mei (2)", @"text" : @"See you at 3."});
    NSDictionary* fields = sender.intents.lastObject[@"fields"];
    NSString* token = fields[@"client_token"];
    Expect([result[@"status"] isEqual:@"waiting for the person"] && sender.intents.count == 1 &&
           [fields[@"conversation_id"] isEqual:@"c_mei2"] &&
           [fields[@"text"] isEqual:@"See you at 3."] && [fields[@"via_assistant"] isEqual:@YES] &&
           !fields[@"attachments"] && token.length == 32 &&
           [token rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
               @"0123456789abcdef"].invertedSet].location == NSNotFound,
           @"Send must go to the second Mei's chat, marked via_assistant, with a fresh token: %@", fields);

    // `/` in Lena's composer: only Lena, whatever else the request carries.
    SPDFMacAIRequestContext* slash = [[SPDFMacAIRequestContext alloc] initWithText:@"send Lena the summary"
        chips:@[FriendChip(@"c_mei", @"Mei")] origin:SPDFMacAIRequestOriginFriendComposer
        friendConversation:FriendChip(@"c_lena", @"Lena") settings:nil budget:nil activity:nil];
    Expect(([Parameters(provider, slash)[@"to"][@"enum"] isEqual:@[@"Lena"]]), @"`/` may send only to its friend");
    result = Send(registry, slash, @{@"to" : @"Mei", @"text" : @"hi"});
    Expect(result[@"error"] && sender.intents.count == 1, @"`/` sent to someone other than its conversation's friend");
}

static void TestAttachmentsOnlyFromChips(void) {
    FakeSender* sender = [FakeSender new];
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    SPDFMacAIToolRegistry* registry = Registry(provider);
    NSURL* contract = [NSURL fileURLWithPath:@"/tmp/attach/Supplier contract v3.pdf"];
    SPDFMacAIRequestChip* document = [SPDFMacAIRequestChip documentChipWithFileURL:contract identifier:@"doc:1"
        revision:Revision(@"ab12") displayName:@"Supplier contract v3.pdf"];
    SPDFMacAIRequestChip* photo = [SPDFMacAIRequestChip attachmentChipWithFileURL:
        [NSURL fileURLWithPath:@"/tmp/attach/site.jpg"] displayName:@"site.jpg"];
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    SPDFMacAIRequestContext* context = Context(@[FriendChip(@"c_mei", @"Mei"), document, photo], activity);
    Expect(([Parameters(provider, context)[@"attachments"][@"items"][@"enum"]
                isEqual:@[@"Supplier contract v3.pdf", @"site.jpg"]]), @"the files offered must be the chips");
    NSArray* refused = @[
        @{@"to" : @"Mei", @"text" : @"x", @"attachments" : @[@"/Users/raph/.ssh/id_rsa"]},
        @{@"to" : @"Mei", @"text" : @"x", @"attachments" : @[@"id_rsa"]},
        @{@"to" : @"Mei", @"text" : @"x", @"attachments" : @"site.jpg"},
        @{@"to" : @"Mei", @"text" : @"x", @"files" : @[@{@"path" : @"/etc/passwd"}]},
        @{@"to" : @"Mei", @"text" : @"x", @"path" : @"/etc/passwd"},
        @{@"to" : @"Mei", @"text" : @"   "},
        @{@"to" : @"Mei", @"text" : [@"" stringByPaddingToLength:32 * 1024 + 1 withString:@"a" startingAtIndex:0]},
    ];
    for (NSDictionary* arguments in refused) {
        NSDictionary* result = Send(registry, context, arguments);
        Expect(result[@"error"] && [result[@"sent"] isEqual:@NO] && !sender.intents.count && !activity.entries.count,
               @"refused arguments reached a card or Friends: %@ -> %@", arguments.allKeys, result);
    }
    SendAndPress(registry, context, @{@"to" : @"Mei", @"attachments" :
        @[@"Supplier contract v3.pdf", @"Supplier contract v3.pdf"],
        @"text" : @"The contract, see [p. 3](shenzhenpdf://doc?id=doc:1&page=3) and [terms](https://example.com/t)."});
    NSDictionary* fields = sender.intents.lastObject[@"fields"];
    NSDictionary* sent = [fields[@"attachments"] firstObject];
    Expect([fields[@"attachments"] count] == 1 &&
           [sent[@"path"] isEqual:contract.path] && [sent[@"display_name"] isEqual:@"Supplier contract v3.pdf"] &&
           [sent[@"revision"] isEqual:Revision(@"ab12")],
           @"the chip's file, bound to its revision, must be sent once: %@", fields);
    Expect([fields[@"text"] isEqual:@"The contract, see p. 3 and [terms](https://example.com/t)."] &&
           [Card(activity)[SPDFMacAIActivityBodyKey] isEqual:fields[@"text"]],
           @"links to the person's own documents must not reach the friend, nor show on the card: %@", fields[@"text"]);

    SPDFMacAIRequestContext* bare = Context(@[FriendChip(@"c_mei", @"Mei")], [SPDFMacAIChatActivity new]);
    Expect(!Parameters(provider, bare)[@"attachments"], @"no files attached, no attachments field");
    NSDictionary* result = Send(registry, bare, @{@"to" : @"Mei", @"text" : @"x", @"attachments" : @[@"site.jpg"]});
    Expect([result[@"error"] containsString:@"attached no files"] && sender.intents.count == 1,
           @"a file from another request was sent: %@", result);
}

static void TestSendLimit(void) {
    FakeSender* sender = [FakeSender new];
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    SPDFMacAIToolRegistry* registry = Registry(provider);
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    SPDFMacAIRequestContext* context = Context(@[FriendChip(@"c_mei", @"Mei")], activity);
    for (NSUInteger index = 0; index < 3; index++)
        Expect([Send(registry, context, @{@"to" : @"Mei", @"text" : @"hi"})[@"status"]
                   isEqual:@"waiting for the person"],
               @"message %lu", (unsigned long)index);
    NSDictionary* result = Send(registry, context, @{@"to" : @"Mei", @"text" : @"one more"});
    Expect([result[@"error"] containsString:@"already prepared 3"] && activity.entries.count == 3 &&
           !sender.intents.count, @"a fourth message reached a card or Friends: %@", result);
    // Friends refuses at Send: the card says why, in Friends' words, and nothing was queued.
    sender.replies[@"send_message"] = @{@"code" : @"not_friends", @"message" : @"Mei isn’t your friend any more."};
    [activity performAction:@"send" forEntry:activity.entries[0][SPDFMacAIActivityIDKey]];
    NSDictionary* refused = activity.entries[0];
    Expect([refused[SPDFMacAIActivityTitleKey] isEqual:@"Not sent to Mei"] &&
           [refused[SPDFMacAIActivityStatusKey] isEqual:@"Mei isn’t your friend any more."] &&
           [refused[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateFailed] &&
           !ActionIDs(activity, refused).count,
           @"a send Friends refused must say so: %@", refused);
    // Its answer lost: it may have gone, so the card says where to check and offers no second Send.
    sender.replies[@"send_message"] = @{@"code" : @"connection_lost"};
    [activity performAction:@"send" forEntry:activity.entries[1][SPDFMacAIActivityIDKey]];
    NSDictionary* lost = activity.entries[1];
    Expect([lost[SPDFMacAIActivityTitleKey] isEqual:@"Message for Mei"] &&
           [lost[SPDFMacAIActivityStatusKey] isEqual:@"Friends stopped responding, so this may not have been sent. "
                                                     "Check your chat with Mei."] && !ActionIDs(activity, lost).count,
           @"a send whose answer was lost: %@", lost);
    // The limit is per request: the next message starts again.
    SPDFMacAIRequestContext* next = Context(@[FriendChip(@"c_mei", @"Mei")], activity);
    result = Send(registry, next, @{@"to" : @"Mei", @"text" : @"hi"});
    Expect([result[@"status"] isEqual:@"waiting for the person"] && [provider sendsLeftForContext:next] == 2,
           @"a new request may prepare 3 again: %@", result);
}

static void TestCardsAndCancel(void) {
    FakeSender* sender = [FakeSender new];
    sender.strings = @{@"queued_note" : kQueuedNote};
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    __block NSString* shown = nil;
    provider.showMessage = ^(NSString* conversation, NSString* message) {
        shown = [NSString stringWithFormat:@"%@/%@", conversation, message];
    };
    SPDFMacAIToolRegistry* registry = Registry(provider);
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    SPDFMacAIRequestChip* document = [SPDFMacAIRequestChip documentChipWithFileURL:[NSURL fileURLWithPath:
        @"/tmp/attach/Contract.pdf"] identifier:nil revision:Revision(@"cd34") displayName:@"Contract.pdf"];
    SPDFMacAIRequestContext* context = Context(@[FriendChip(@"c_mei", @"Mei"), document], activity);

    NSDictionary* result = Send(registry, context, @{@"to" : @"Mei", @"text" : @"**Draft** attached",
                                                     @"attachments" : @[@"Contract.pdf"]});
    NSDictionary* card = Card(activity);
    Expect([result[@"status"] isEqual:@"waiting for the person"] && !sender.intents.count &&
           [card[SPDFMacAIActivityTitleKey] isEqual:@"Message for Mei"] &&
           [card[SPDFMacAIActivityBodyKey] isEqual:@"**Draft** attached"] &&
           [card[SPDFMacAIActivityBodyStyleKey] isEqual:SPDFMacAIActivityBodyStyleLiteral] &&
           [card[SPDFMacAIActivityStatusKey] isEqual:@"Not sent yet. Check it, then press Send."] &&
           ([card[SPDFMacAIActivityAttachmentsKey] isEqual:@[@{@"name" : @"Contract.pdf",
                                                              @"detail" : @"PDF · version saved today, 14:02"}]]) &&
           ([ActionIDs(activity, card) isEqual:@[@"send", @"discard"]]),
           @"every message waits on a card showing its literal text and files, with Send and Discard: %@", card);
    sender.hold = YES;
    [activity performAction:@"send" forEntry:card[SPDFMacAIActivityIDKey]];
    card = Card(activity);
    Expect([card[SPDFMacAIActivityStatusKey] isEqual:@"Sending…"] && !ActionIDs(activity, card).count,
           @"while Friends has not answered, the card must say it is sending: %@", card);
    [sender releaseHeld];
    sender.hold = NO;
    card = Card(activity);
    // Queued, not sent: only Friends' delivery status may say it arrived, and when it goes is Friends' own sentence,
    // the one under its composer (SPDFMacFriendsSendCards.h).
    Expect([card[SPDFMacAIActivityTitleKey] isEqual:@"Message for Mei"] &&
           [card[SPDFMacAIActivityStatusKey] isEqual:@"Messages and files send when Mei is nearby with ShenzhenPDF, "
                                                     "Shenzhen Files or Shenzhen 3D open. Show opens your chat with "
                                                     "Mei, where you can see when it arrives."] &&
           [card[SPDFMacAIActivityInterruptedStatusKey] isEqual:@"Messages and files send when Mei is nearby with "
                                                                "ShenzhenPDF, Shenzhen Files or Shenzhen 3D open. "
                                                                "Your chat with Mei in Friends shows when it "
                                                                "arrives."],
           @"the queued card must use Friends' own condition: %@", card);
    // A helper without messages.cancel cannot take back a message's text, so no Cancel that would leave it on its way.
    Expect(([ActionIDs(activity, card) isEqual:@[@"show"]]), @"actions %@", ActionIDs(activity, card));
    [activity performAction:@"show" forEntry:card[SPDFMacAIActivityIDKey]];
    Expect([shown isEqual:@"c_mei/m_sent_1"], @"Show must open the sent message: %@", shown);

    sender.helperCapabilities = [NSSet setWithObject:SPDFMacFriendsCancelMessageCapability];
    SendAndPress(registry, context, @{@"to" : @"Mei", @"text" : @"second", @"attachments" : @[@"Contract.pdf"]});
    card = Card(activity);
    Expect([ActionIDs(activity, card) containsObject:SPDFMacAIActivityActionCancel], @"card %@", card);
    [activity performAction:SPDFMacAIActivityActionCancel forEntry:card[SPDFMacAIActivityIDKey]];
    card = Card(activity);
    NSArray* messages = [sender intentsOfType:@"cancel_message"];
    NSArray* transfers = [sender intentsOfType:@"cancel_transfer"];
    Expect(messages.count == 1 && [messages[0][@"fields"][@"message_id"] isEqual:@"m_sent_2"] && transfers.count == 1 &&
           [transfers[0][@"fields"][@"transfer_id"] isEqual:@"t_2_0"] &&
           [card[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped] &&
           [card[SPDFMacAIActivityTitleKey] isEqual:@"Not sent to Mei"] &&
           [card[SPDFMacAIActivityStatusKey] isEqual:@"Cancelled. Mei won’t get it."],
           @"Cancel must withdraw the message and its file: %@ %@", sender.intents, card);

    sender.replies[@"cancel_message"] = @{@"code" : @"stale", @"message" : @"It was already delivered."};
    sender.replies[@"cancel_transfer"] = @{@"code" : @"stale"};
    SendAndPress(registry, context, @{@"to" : @"Mei", @"text" : @"third", @"attachments" : @[@"Contract.pdf"]});
    card = Card(activity);
    [activity performAction:SPDFMacAIActivityActionCancel forEntry:card[SPDFMacAIActivityIDKey]];
    Expect([Card(activity)[SPDFMacAIActivityStatusKey] isEqual:@"It was already delivered."] &&
           ![Card(activity)[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped],
           @"a send that already arrived must say so, not claim it was cancelled: %@", Card(activity));
}

static void TestSubagentsCannotSend(void) {
    FakeSender* sender = [FakeSender new];
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    SPDFMacAIToolRegistry* registry = Registry(provider);
    SPDFMacAIRequestContext* parent = Context(@[FriendChip(@"c_mei", @"Mei")], nil);
    SPDFMacAIRequestContext* task = [parent childContextWithText:@"look something up"
        budget:[[SPDFMacAIRequestBudget alloc] initWithSteps:2 tokens:1000 toolCalls:2] error:nil];
    SPDFMacAIToolRegistry* readOnly = [registry registryWithFilter:SPDFMacAIToolFilter.readOnly];
    Expect(task.depth == 1 && ![readOnly toolDefinitionsForContext:task].count, @"a subagent was offered sending");
    __block NSDictionary* result = nil;
    [readOnly performTool:SPDFMacFriendsSendToolName arguments:@{@"to" : @"Mei", @"text" : @"hi"} context:task
               completion:^(NSDictionary* r) { result = r; }];
    Expect(result[@"error"] && !sender.intents.count, @"a subagent sent a message: %@", result);
    sender.friendsReady = NO;
    result = Send(registry, parent, @{@"to" : @"Mei", @"text" : @"hi"});
    Expect([result[@"error"] containsString:@"isn't connected"] && !sender.intents.count, @"sent while disconnected");
    sender.friendsReady = YES;
    [parent.cancellation cancel];
    result = Send(registry, parent, @{@"to" : @"Mei", @"text" : @"hi"});
    Expect([result[@"error"] containsString:@"stopped"] && !sender.intents.count, @"sent after Stop");
}

// AI chat's composer: a `#` chip alone (no `@`) still reaches the model as "#Title", never as an attachment character,
// and the request carries the file beside any friend chip.
static void TestComposerChips(void) {
    FakeServices* services = [FakeServices new];
    SPDFMacFriendsChatScopeGate* gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return services; }];
    __block NSAttributedString* composer = nil;
    SPDFMacFriendsChatRequestScoper* scoper = [[SPDFMacFriendsChatRequestScoper alloc] initWithGate:gate
        running:^BOOL { return NO; } composerText:^NSAttributedString* { return composer; }];
    __block NSString* sent = nil;
    SPDFMacFriendsSendText send = [scoper sendTextWrapping:^BOOL(NSString* text) { sent = text; return YES; }];
    NSFont* font = [NSFont systemFontOfSize:13];
    SPDFMacAIRequestChip* file = SPDFMacFriendsFileChip([NSURL fileURLWithPath:@"/tmp/attach/Contract.pdf"],
                                                        @"Contract.pdf", nil);
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] initWithString:@"Summarize "];
    [text appendAttributedString:[SPDFMacFriendsFileToken chipWithFile:file font:font]];
    composer = text;
    send(text.string);
    Expect([sent isEqual:@"Summarize #Contract.pdf"] && !gate.requestHasScope,
           @"a file chip must read as #Title even without a friend chip: %@", sent);

    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    [registry registerProvider:[[SPDFMacFriendsToolProvider alloc] initWithGate:gate] error:nil];
    [registry registerProvider:[[SPDFMacFriendsSendProvider alloc] initWithSender:^id { return nil; }] error:nil];
    [text appendAttributedString:[SPDFMacFriendsScopeToken chipWithScope:[SPDFMacFriendsScopeRequest
        conversationIDs:@[@"c_mei"] labels:@[@"Mei"]] font:font]];
    NSArray<SPDFMacAIRequestChip*>* chips = [registry requestChipsInComposerText:text];
    Expect(chips.count == 2 && [chips[0].kind isEqual:SPDFMacAIChipKindFriends] && chips[1] == file,
           @"the request must carry the friend and the file, once each: %@", chips);
}

#import "SPDFMacFriendsSendRig.h"
#import "SPDFMacFriendsSendSessionChecks.h"
#import "SPDFMacFriendsSendConfirmChecks.h"
#import "SPDFMacFriendsSendTextChecks.h"
#import "SPDFMacFriendsSendMarkChecks.h"

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TestNoChipNoTool();
        TestChipsLimitRecipients();
        TestAttachmentsOnlyFromChips();
        TestSendLimit();
        TestCardsAndCancel();
        TestSubagentsCannotSend();
        TestComposerChips();
        CheckInjectionThroughSession();
        CheckWaitingCards();
        CheckFriendMessageInjectionWaits();
        CheckDocumentInjectionDiscardAndReopen();
        CheckOwnTextWaitsToo();
        CheckChangedCardNeverSends();
        CheckDeliveryStatus();
        CheckCancelWhileQueuedOrConnecting();
        CheckVisibleText();
        CheckSharedInvisibleCases();
        CheckRepeatedMarksDrawnAlike();
        CheckCompatibilitySpellings();
        CheckHiddenConstructsReachTheCardWhole();
        CheckInvisibleCharactersRefused();
        CheckCardShowsComposedText();
        CheckChatRestoresCardsOnEveryChange();
    }
    puts("SPDFMacFriendsSendTests passed");
    return 0;
}
