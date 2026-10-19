// What the assistant work added to snapshots: "Via the assistant" on both sides, Markdown message text, rows that
// say why they refuse dragged files, an Add by ID answer the Friends server could not confirm waiting like a
// request, deletion confirmations that admit AI chats keep what they quoted, the message_status view AI chat follows
// its sends with, a queued note that stays true whichever app shows it, and Cancel on a message that has not left.

#import "SZFriendsPresentationWorld.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsOutbox.h"

static NSDictionary *ItemWithID(NSDictionary *conversation, NSString *itemID) {
    for (NSDictionary *item in conversation[@"items"])
        if ([item[@"item_id"] isEqual:itemID]) return item;
    return nil;
}

static NSDictionary *Conversation(SZFriendsSnapshotBuilder *builder, SZFriendsPersonFacts *person,
                                  NSArray<SZFriendsItemFacts *> *items) {
    NSDictionary *data = [builder conversationForPerson:person items:items hasEarlier:NO highlightItemID:nil
                                       waitingElsewhere:0 now:SZPNow()];
    SZPValidateSnapshot(data, @"conversation", person.conversationID);
    return data;
}

static void TestAssistantLabels(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    NSDictionary *mei = Conversation(builder, people[@"c_mei"], SZPItemsFor(@"c_mei"));
    NSDictionary *note = ItemWithID(mei, @"m_5f2a90c1"), *contract = ItemWithID(mei, @"t_91c4e2a7");
    SZPExpect([note[@"assistant_label"] isEqual:@"Via the assistant"] &&
                  [note[@"accessibility_label"] containsString:@"via the assistant"],
              @"the person’s own assistant: %@", note);
    SZPExpect([contract[@"assistant_label"] isEqual:@"Via the assistant"] &&
                  [contract[@"accessibility_label"] containsString:@"2.4 MB, via the assistant"],
              @"a file the assistant sent: %@", contract);
    SZPExpect(ItemWithID(mei, @"m_a4109f52")[@"assistant_label"] == [NSNull null], @"Mei typed this herself");
    for (NSDictionary *item in mei[@"items"])
        if ([item[@"kind"] isEqual:@"message"])
            SZPExpect([item[@"text_format"] isEqual:@"markdown"], @"people type Markdown: %@", item);

    // The friend's assistant is named as theirs, so nobody wonders whose it was.
    NSDictionary *kenji = Conversation(builder, people[@"c_kenji"], SZPItemsFor(@"c_kenji"));
    NSDictionary *incoming = ItemWithID(kenji, @"m_1b7e44d9");
    SZPExpect([incoming[@"assistant_label"] isEqual:@"Via Kenji’s assistant"] &&
                  [incoming[@"accessibility_label"] hasPrefix:@"Kenji Sato, 13:09, via Kenji’s assistant: "],
              @"Kenji’s assistant: %@", incoming);

    // A queued message reads its status as a sentence after the text; the assistant still comes with the time.
    SZFriendsItemFacts *queued = SZPMessage(@"m_q", YES, @"2026-10-12 14:40", @"On my way", 0);
    queued.outboxState = 0; // SZFriendsOutboxStateQueued
    queued.viaAssistant = YES;
    NSDictionary *priya = Conversation(builder, people[@"c_priya"], @[ queued ]);
    SZPExpect([ItemWithID(priya, @"m_q")[@"accessibility_label"] hasPrefix:@"You, 14:40, via the assistant: "],
              @"queued: %@", ItemWithID(priya, @"m_q"));
}

static NSDictionary *Row(NSDictionary *list, NSString *conversationID) {
    for (NSDictionary *row in list[@"rows"])
        if ([row[@"conversation_id"] isEqual:conversationID]) return row;
    return nil;
}

static NSDictionary *List(SZFriendsAudience *audience, NSArray<SZFriendsPersonFacts *> *people) {
    NSDictionary *data = [SZPBuilder(audience) listWithPeople:people previewItems:SZPPreviewItems()
                                                      profile:SZPProfileRaph() query:@"" now:SZPNow()];
    SZPValidateSnapshot(data, @"list", @"drop refusals");
    return data;
}

static void TestDropRefusals(void) {
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    people[@"c_priya"].relation = SZFriendsPersonRelationRemoved;
    people[@"c_daniel"].relation = SZFriendsPersonRelationOutgoingRequest;
    people[@"c_mei"].keyChangePending = YES;
    NSDictionary *list = List(SZPAudience(), people.allValues);
    NSDictionary<NSString *, NSString *> *expected = @{
        @"c_lena" : @"Lena isn’t your friend yet",
        @"c_daniel" : @"Daniel isn’t your friend yet",
        @"c_priya" : @"Priya isn’t your friend",
        @"c_jonas" : @"You blocked Jonas",
        @"c_mei" : @"Review Mei’s new key first",
    };
    for (NSDictionary *row in list[@"rows"]) {
        NSString *refusal = expected[row[@"conversation_id"]];
        if (refusal) {
            SZPExpect(row[@"drop_label"] == [NSNull null] && [row[@"drop_refusal"] isEqual:refusal],
                      @"%@ refuses and says why: %@", row[@"conversation_id"], row[@"drop_refusal"]);
        } else {
            SZPExpect([row[@"drop_label"] isKindOfClass:NSString.class] && row[@"drop_refusal"] == [NSNull null],
                      @"%@ takes files: %@", row[@"conversation_id"], row);
        }
    }
    // A client that takes no drops sees neither: nothing can be dragged over its rows.
    SZFriendsAudience *noDrops = SZPAudience();
    noDrops.capabilities = [NSSet setWithArray:@[ @"attach.items" ]];
    for (NSDictionary *row in List(noDrops, people.allValues)[@"rows"])
        SZPExpect(row[@"drop_label"] == [NSNull null] && row[@"drop_refusal"] == [NSNull null], @"no drops: %@",
                  row[@"conversation_id"]);
}

// Someone answered our Add by ID for tulip-canyon without the server's confirmation: it waits like a request, and the
// row and card say what was asked and why it waits, never "wants to be friends" as if they had asked.
static void TestUnconfirmedAnswer(void) {
    SZFriendsPersonFacts *answer = [[SZFriendsPersonFacts alloc] init];
    answer.conversationID = @"c_answer";
    answer.name = @"Lena";
    answer.relation = SZFriendsPersonRelationIncomingRequest;
    answer.unconfirmedAnswerID = @"tulip-canyon";
    answer.requestAt = answer.lastInteractionAt = SZPHongKong(@"2026-10-12 14:40");
    answer.comparisonCode = @"418270";
    NSDictionary *row = Row(List(SZPAudience(), @[ answer ]), @"c_answer");
    SZPExpect([row[@"subtitle"] isEqual:@"Answered your request for tulip‑canyon"] &&
                  [row[@"waiting"][@"kind"] isEqual:@"request"] && [row[@"actions"] count] == 3,
              @"row: %@", row);
    NSDictionary *card = Conversation(SZPBuilder(SZPAudience()), answer, @[])[@"request"];
    SZPExpect([card[@"title"] isEqual:@"Lena answered your request"], @"title: %@", card[@"title"]);
    SZPExpect([card[@"subtitle"] hasPrefix:@"You asked for tulip‑canyon · "], @"subtitle: %@", card[@"subtitle"]);
    SZPExpect([card[@"footnote"] hasPrefix:@"Friends couldn’t confirm that tulip‑canyon belongs to Lena."],
              @"footnote: %@", card[@"footnote"]);
    SZPExpect([card[@"direction"] isEqual:@"incoming"] && [card[@"actions"][0][@"action"] isEqual:@"accept_request"],
              @"accepted like a request: %@", card[@"actions"]);
}

static void TestDeletionWording(void) {
    NSArray<SZFriendsPersonFacts *> *people = SZPPeople().allValues;
    SZFriendsAudience *assistant = SZPAudience();
    assistant.capabilities = [assistant.capabilities setByAddingObject:@"assistant.chats"];
    NSDictionary *with = [SZPBuilder(assistant) settingsWithProfile:SZPProfileRaph() people:people];
    NSDictionary *without = [SZPBuilder(SZPAudience()) settingsWithProfile:SZPProfileRaph() people:people];
    SZPValidateSnapshot(with, @"settings", @"assistant.chats");
    NSString *quoted = @"AI chat answers that quoted";
    SZPExpect([with[@"history"][@"confirm"][@"body"] containsString:quoted] &&
                  [with[@"reset"][@"confirm"][@"body"] containsString:quoted],
              @"an AI chat may have quoted them: %@", with[@"history"][@"confirm"][@"body"]);
    SZPExpect(![without[@"history"][@"confirm"][@"body"] containsString:quoted] &&
                  ![without[@"reset"][@"confirm"][@"body"] containsString:quoted],
              @"a host whose AI never reads Friends: %@", without[@"history"][@"confirm"][@"body"]);
    SZFriendsProfileFacts *broken = SZPProfileRaph();
    broken.identityState = SZFriendsIdentityFactsStateUnavailable;
    NSDictionary *list = [SZPBuilder(assistant) listWithPeople:@[] previewItems:@{} profile:broken query:@""
                                                           now:SZPNow()];
    SZPExpect([list[@"banner"][@"action"][@"confirm"][@"body"] containsString:quoted], @"the banner’s Reset too: %@",
              list[@"banner"]);
}

// The world's items with these ids, each knowing its conversation as the helper's facts do.
static NSArray<SZFriendsItemFacts *> *ItemsByID(NSArray<NSString *> *itemIDs) {
    NSMutableArray<SZFriendsItemFacts *> *found = [NSMutableArray array];
    for (NSString *itemID in itemIDs)
        for (NSString *conversation in @[ @"c_mei", @"c_kenji", @"c_priya" ])
            for (SZFriendsItemFacts *item in SZPItemsFor(conversation))
                if ([item.itemID isEqualToString:itemID]) {
                    item.conversationID = conversation;
                    [found addObject:item];
                }
    return found;
}

// message_status (PROTOCOL.md § Views): AI chat follows what the person sent from it in the conversation's own words,
// and only for this person's outgoing messages, in the order it asked.
static void TestMessageStatus(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    // Mei's own question and Priya's queued file have no row; the message Raph cancelled has one, saying so.
    NSArray *asked = ItemsByID(@[ @"m_c4d27a19", @"m_7a3e5b21", @"m_a4109f52", @"t_6a2f90b8", @"m_5f2a90c1" ]);
    NSDictionary *data = [builder messageStatusWithMessages:asked people:people];
    SZPValidateSnapshot(data, @"message_status", @"message_status");
    NSString *difference = SZPDifference(data, SZPFixture(@"snapshots/message-status.json")[@"data"], @"data");
    if (difference) SZPFail(@"message-status.json differs at %@", difference);
    NSDictionary *priya = Conversation(builder, people[@"c_priya"], SZPItemsFor(@"c_priya"));
    SZPExpect([[data[@"messages"] firstObject][@"status"] isEqual:ItemWithID(priya, @"m_c4d27a19")[@"status"]],
              @"the same status as in the conversation: %@", data);
    // No delivery record, or nobody to name: no row rather than a guess.
    SZFriendsItemFacts *unrecorded = SZPMessage(@"m_old", YES, @"2026-10-01 09:00", @"Old", -1);
    unrecorded.conversationID = @"c_mei";
    SZFriendsItemFacts *orphan = SZPMessage(@"m_gone", YES, @"2026-10-01 09:00", @"Gone", SZFriendsOutboxStateQueued);
    orphan.conversationID = @"c_deleted";
    NSArray *rows = [builder messageStatusWithMessages:@[ unrecorded, orphan ] people:people][@"messages"];
    SZPExpect(rows.count == 0, @"nothing to say: %@", rows);
}

// Either app open on each Mac sends it, so the composer names the apps that run Friends, not the app showing it.
static void TestQueuedNoteNamesEveryApp(void) {
    SZFriendsAudience *files = SZPAudience();
    files.appName = @"Shenzhen Files";
    NSDictionary *priya = Conversation(SZPBuilder(files), SZPPeople()[@"c_priya"], SZPItemsFor(@"c_priya"));
    NSString *expected = @"Messages and files send when Priya is nearby with ShenzhenPDF, Shenzhen Files or "
                         @"Shenzhen 3D open.";
    SZPExpect([priya[@"composer"][@"note"] isEqual:expected], @"in Shenzhen Files: %@", priya[@"composer"][@"note"]);
    NSString *shared = [SZPBuilder(files).strings.staticStrings[@"queued_note"]
        stringByReplacingOccurrencesOfString:@"{first}" withString:@"Priya"];
    SZPExpect([shared isEqual:expected], @"the hosts’ copy says the same: %@", shared);
}

// cancel_message (PROTOCOL.md § Intents): Cancel shows only while nothing has left this Mac; a cancelled message says
// so in its conversation, its row and message_status; and a Cancel that lost the race says where the message is.
static void TestCancelWhileNothingLeft(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    NSArray<NSNumber *> *states = @[ @(SZFriendsOutboxStateQueued), @(SZFriendsOutboxStateConnecting),
                                     @(SZFriendsOutboxStateSending), @(SZFriendsOutboxStateDelivered),
                                     @(SZFriendsOutboxStateFailed) ];
    NSMutableArray<SZFriendsItemFacts *> *items = [NSMutableArray array];
    for (NSNumber *state in states)
        [items addObject:SZPMessage([NSString stringWithFormat:@"m_%@", state], YES, @"2026-10-12 09:00", @"Hi",
                                    state.integerValue)];
    SZFriendsItemFacts *cancelled = SZPMessage(@"m_cancelled", YES, @"2026-10-12 09:01", @"Wrong page", -1);
    cancelled.cancelled = YES;
    [items addObject:cancelled];
    NSDictionary *mei = Conversation(builder, people[@"c_mei"], items);
    for (NSNumber *state in states) {
        NSDictionary *item = ItemWithID(mei, [NSString stringWithFormat:@"m_%@", state]);
        BOOL waits = state.integerValue == SZFriendsOutboxStateQueued ||
                     state.integerValue == SZFriendsOutboxStateConnecting;
        BOOL offers = [[item[@"actions"] valueForKey:@"action"] containsObject:@"cancel_message"];
        SZPExpect(offers == waits, @"state %@: Cancel %@ while it %@ left: %@", state, offers ? @"shows" : @"hidden",
                  waits ? @"has not" : @"may have", item[@"actions"]);
    }
    NSDictionary *withdrawn = ItemWithID(mei, @"m_cancelled");
    SZPExpect([withdrawn[@"status"] isEqual:(@{@"state" : @"cancelled", @"label" : @"Cancelled"})] &&
                  [withdrawn[@"actions"] count] == 0 &&
                  [withdrawn[@"accessibility_label"] isEqual:@"You, 09:01: Wrong page. Cancelled."],
              @"a cancelled message says so and offers nothing: %@", withdrawn);
    cancelled.conversationID = @"c_mei";
    SZPExpect([[builder messageStatusWithMessages:@[ cancelled ] people:people][@"messages"]
                  isEqual:(@[ @{@"message_id" : @"m_cancelled", @"status" : withdrawn[@"status"]} ])],
              @"AI chat's card hears the same");
    NSString *spoken = nil;
    BOOL route = NO;
    SZPExpect([[builder previewForItem:cancelled person:people[@"c_mei"] spoken:&spoken explainsRoute:&route]
                  isEqual:@"Cancelled · Wrong page"] && [spoken isEqual:@"you said Wrong page, cancelled"],
              @"the row leads with it: %@", spoken);
    SZFriendsStrings *s = builder.strings;
    NSDictionary *mine = @{@"field" : @"message_id", @"name" : @"Mei Lin", @"friends_id" : @"orchid-summit"};
    NSMutableDictionary *details = [mine mutableCopy];
    details[@"state"] = @"delivered";
    SZPExpect([[s messageForErrorCode:@"stale" details:details]
                  isEqual:@"Mei already has it, so it can’t be cancelled."], @"delivered meanwhile");
    details[@"state"] = @"sending";
    SZPExpect([[s messageForErrorCode:@"stale" details:details]
                  isEqual:@"It’s already on its way to Mei, so it can’t be cancelled."], @"on its way");
    [details removeObjectForKey:@"name"];
    SZPExpect([[s messageForErrorCode:@"stale" details:details] containsString:@"orchid\u2011summit,"],
              @"a friend without a name is called by their ID");
    details[@"state"] = @"failed";
    SZPExpect([[s messageForErrorCode:@"stale" details:details] isEqual:[s messageForErrorCode:@"stale" details:@{}]],
              @"anything else is the general line");
}

void SZPRunAssistantTests(void) {
    TestAssistantLabels();
    TestDropRefusals();
    TestUnconfirmedAnswer();
    TestDeletionWording();
    TestMessageStatus();
    TestQueuedNoteNamesEveryApp();
    TestCancelWhileNothingLeft();
}
