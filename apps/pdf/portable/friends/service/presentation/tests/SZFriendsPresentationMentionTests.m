// Mention presentation tests (PROTOCOL.md § Mentions): every way a mention resolves for its reader, the cards and
// their actions, previews and search excerpts, and what a client without the `mentions` capability gets instead.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsMentions.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsOutbox.h"

static SZFriendsAudience *MentionAudience(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.capabilities = [audience.capabilities setByAddingObject:@"mentions"];
    return audience;
}

static SZFriendsSnapshotBuilder *Builder(SZFriendsAudience *audience, NSDictionary *people) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(audience);
    builder.mentionDirectory = [[SZFriendsMentionDirectory alloc] initWithPeople:[people allValues]
                                                                         profile:SZPProfileRaph()];
    return builder;
}

static NSDictionary *Daniel(SZFriendsSnapshotBuilder *builder, NSDictionary *people) {
    NSDictionary *built = [builder conversationForPerson:people[@"c_daniel"] items:SZPItemsFor(@"c_daniel")
                                              hasEarlier:NO highlightItemID:nil waitingElsewhere:2 now:SZPNow()];
    SZPValidateSnapshot(built, @"conversation", @"Daniel's mentions");
    return built;
}

static NSDictionary *Item(NSDictionary *conversation, NSString *itemID) {
    for (NSDictionary *item in conversation[@"items"])
        if ([item[@"item_id"] isEqual:itemID]) return item;
    SZPFail(@"no item %@", itemID);
    return @{};
}

// One message from Daniel naming Leo, built for `people` as Raph sees them.
static NSDictionary *LeoMention(NSDictionary *people) {
    SZFriendsItemFacts *message = SZPMessage(@"m_leo", NO, @"2026-10-12 10:41",
                                             SZFriendsMentionLink(@"Leo Park", @"bonfire-otter", SZPKey(SZPKeyLeo)), 0);
    NSDictionary *built = [Builder(MentionAudience(), people) conversationForPerson:people[@"c_daniel"]
                                                                              items:@[ message ]
                                                                         hasEarlier:NO
                                                                    highlightItemID:nil
                                                                   waitingElsewhere:0
                                                                                now:SZPNow()];
    SZPValidateSnapshot(built, @"conversation", @"a mention of Leo");
    return [Item(built, @"m_leo")[@"mentions"] firstObject];
}

static SZFriendsPersonFacts *Leo(SZFriendsPersonRelation relation) {
    SZFriendsPersonFacts *leo = [[SZFriendsPersonFacts alloc] init];
    leo.conversationID = @"c_leo";
    leo.name = @"Leo";
    leo.friendsID = @"bonfire-otter";
    leo.identityKey = SZPKey(SZPKeyLeo);
    leo.relation = relation;
    leo.lastInteractionAt = SZPHongKong(@"2026-10-10 09:00");
    return leo;
}

// The golden fixture: a friend, a stranger, the reader, someone who asked, someone blocked, and a forgery.
static void TestFixture(void) {
    NSDictionary *people = SZPPeople();
    SZPExpectFixture(Daniel(Builder(MentionAudience(), people), people), @"conversation-daniel-mentions.json",
                     @"conversation");
}

static void TestEachKind(void) {
    NSDictionary *people = SZPPeople();
    NSDictionary *conversation = Daniel(Builder(MentionAudience(), people), people);
    NSDictionary *mei = Item(conversation, @"m_d0a1");
    // A friend: Raph's name for her, not Daniel's ("Mei"), linking to her conversation.
    SZPExpect([mei[@"text"] isEqual:@"[@Mei Lin](szfriends:mention?ref=0) has the bracket drawing. Ask her for rev B."],
              @"friend text: %@", mei[@"text"]);
    SZPExpect([mei[@"mentions"][0][@"kind"] isEqual:@"friend"] &&
                  [mei[@"mentions"][0][@"conversation_id"] isEqual:@"c_mei"],
              @"friend: %@", mei[@"mentions"]);
    NSDictionary *linkSegment = @{@"text" : @"@Mei Lin", @"mention" : @0};
    SZPExpect([mei[@"segments"][0] isEqual:linkSegment], @"segments: %@", mei[@"segments"]);
    // Nothing a view shows carries an ID or key, except the stranger card's Add, which must send them.
    NSData *json = [NSJSONSerialization dataWithJSONObject:mei options:0 error:NULL];
    NSString *serialized = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    SZPExpect(![serialized containsString:@"jasmine"] && ![serialized containsString:SZPKeyMei], @"leak: %@",
              serialized);
    NSArray *two = Item(conversation, @"m_d0a2")[@"mentions"];
    SZPExpect([two[0][@"kind"] isEqual:@"stranger"] && [two[0][@"label"] isEqual:@"@Leo Park"] &&
                  [two[1][@"kind"] isEqual:@"you"] && [two[1][@"label"] isEqual:@"@Raph"] &&
                  two[1][@"tooltip"] == [NSNull null] && two[1][@"card"] == [NSNull null],
              @"stranger and you: %@", two);
    NSDictionary *add = [two[0][@"card"][@"actions"] firstObject];
    SZPExpect([add[@"action"] isEqual:@"add_from_mention"] && [add[@"friends_id"] isEqual:@"bonfire-otter"] &&
                  [add[@"identity_key"] isEqual:SZPKeyLeo] && [add[@"name"] isEqual:@"Leo Park"],
              @"Add carries what add_from_mention needs: %@", add);
    SZPExpect([two[0][@"card"][@"id_label"] isEqual:@"Friends ID bonfire‑otter"], @"%@", two[0][@"card"]);
    NSArray *three = Item(conversation, @"m_d0a3")[@"mentions"];
    NSArray *asked = [three[0][@"card"][@"actions"] valueForKey:@"action"];
    NSArray *answers = @[ @"accept_request", @"decline_request", @"block" ];
    SZPExpect([asked isEqual:answers] &&
                  [three[0][@"card"][@"conversation_id"] isEqual:@"c_lena"] &&
                  [three[0][@"card"][@"actions"][2][@"arm"] isKindOfClass:NSDictionary.class],
              @"a request from them: %@", three[0]);
    SZPExpect([three[1][@"card"][@"status_label"] isEqual:@"Blocked"] && [three[1][@"card"][@"actions"] count] == 0,
              @"blocked: %@", three[1]);
    // Forged: Kenji's ID under someone else's key is plain text, no link and no card.
    NSDictionary *forged = Item(conversation, @"m_d0a4");
    SZPExpect(forged[@"mentions"] == nil && [forged[@"text"] isEqual:@"Or ask @Kenji."] &&
                  [forged[@"segments"] isEqual:@[ @{@"text" : @"Or ask @Kenji."} ]],
              @"forged: %@", forged);
    // Raph's own message resolves the same way, and its spoken label reads the name.
    NSDictionary *reply = Item(conversation, @"m_d0a5");
    SZPExpect([reply[@"accessibility_label"] containsString:@"Thanks, I’ll ask @Priya Raman too."], @"%@",
              reply[@"accessibility_label"]);
}

// What is already between Raph and the person decides the card.
static void TestCardStates(void) {
    NSMutableDictionary *people = [SZPPeople() mutableCopy];
    NSDictionary *mention = LeoMention(people);
    SZPExpect([mention[@"tooltip"] isEqual:@"Leo Park isn’t your friend yet"] &&
                  mention[@"card"][@"status_label"] == [NSNull null] &&
                  mention[@"card"][@"conversation_id"] == [NSNull null],
              @"unknown: %@", mention);
    people[@"c_leo"] = Leo(SZFriendsPersonRelationOutgoingRequest);
    mention = LeoMention(people);
    SZPExpect([mention[@"card"][@"status_label"] isEqual:@"Request sent"] &&
                  [mention[@"card"][@"actions"] count] == 0 &&
                  [mention[@"tooltip"] isEqual:@"You asked Leo Park to be friends"],
              @"request sent: %@", mention);
    people[@"c_leo"] = Leo(SZFriendsPersonRelationRemoved);
    mention = LeoMention(people);
    SZPExpect([[mention[@"card"][@"actions"] firstObject][@"action"] isEqual:@"add_from_mention"],
              @"removed: Add again: %@", mention);
    // A friend shows under Raph's own name for him; the card is gone.
    people[@"c_leo"] = Leo(SZFriendsPersonRelationFriend);
    mention = LeoMention(people);
    SZPExpect([mention[@"kind"] isEqual:@"friend"] && [mention[@"label"] isEqual:@"@Leo"] &&
                  [mention[@"tooltip"] isEqual:@"Open your chat with Leo"],
              @"friend: %@", mention);
    // The host vouched that bonfire-otter now belongs to someone else: no Add, and the card says why.
    SZFriendsPersonFacts *holder = Leo(SZFriendsPersonRelationRemoved);
    holder.conversationID = @"c_holder";
    holder.identityKey = SZPKey(SZPKeyForged);
    holder.friendsIDConfirmed = YES;
    people[@"c_leo"] = nil;
    people[@"c_holder"] = holder;
    mention = LeoMention(people);
    SZPExpect([mention[@"card"][@"actions"] count] == 0 &&
                  [mention[@"card"][@"status_label"]
                      isEqual:@"This link no longer matches Leo Park: bonfire‑otter belongs to someone else now."],
              @"moved: %@", mention);
}

// A forgery of the reader's own ID, and a builder with nothing to resolve against, claim nothing.
static void TestPlainTextCases(void) {
    NSDictionary *people = SZPPeople();
    NSString *ownID = SZFriendsMentionLink(@"Raph", @"cottage-violet", SZPKey(SZPKeyLeo));
    NSString *mei = SZFriendsMentionLink(@"Mei", @"jasmine-street", SZPKey(SZPKeyMei));
    SZFriendsItemFacts *message = SZPMessage(@"m_x", NO, @"2026-10-12 10:41",
                                             [NSString stringWithFormat:@"%@ and %@", ownID, mei], 0);
    NSDictionary *built = [Builder(MentionAudience(), people) conversationForPerson:people[@"c_daniel"]
                                                                              items:@[ message ] hasEarlier:NO
                                                                    highlightItemID:nil waitingElsewhere:0
                                                                                now:SZPNow()];
    NSDictionary *item = Item(built, @"m_x");
    SZPExpect([item[@"text"] isEqual:@"@Raph and [@Mei Lin](szfriends:mention?ref=0)"] &&
                  [item[@"mentions"] count] == 1,
              @"own ID under another key is text; the next link is still ref 0: %@", item);
    SZFriendsSnapshotBuilder *bare = SZPBuilder(MentionAudience());
    built = [bare conversationForPerson:people[@"c_daniel"] items:@[ message ] hasEarlier:NO highlightItemID:nil
                       waitingElsewhere:0 now:SZPNow()];
    item = Item(built, @"m_x");
    SZPExpect([item[@"text"] isEqual:@"@Raph and @Mei"] && item[@"mentions"] == nil,
              @"no directory: the sender's names as text: %@", item);
}

// A client that never said it shows mentions gets their resolved names as text, and nothing to act on.
static void TestClientWithoutMentions(void) {
    NSDictionary *people = SZPPeople();
    SZFriendsSnapshotBuilder *builder = Builder(SZPAudience(), people);
    NSDictionary *conversation = Daniel(builder, people);
    NSDictionary *mei = Item(conversation, @"m_d0a1");
    SZPExpect([mei[@"text"] isEqual:@"@Mei Lin has the bracket drawing. Ask her for rev B."] &&
                  mei[@"mentions"] == nil &&
                  [mei[@"segments"] isEqual:@[ @{@"text" : @"@Mei Lin has the bracket drawing. Ask her for rev B."} ]],
              @"plain: %@", mei);
    SZPExpect(conversation[@"composer"][@"mention_note"] == nil, @"no picker note: %@", conversation[@"composer"]);
    NSDictionary *list = [builder listWithPeople:[people allValues] previewItems:SZPPreviewItems()
                                         profile:SZPProfileRaph() query:@"" now:SZPNow()];
    for (NSDictionary *row in list[@"rows"]) SZPExpect(row[@"mentionable"] == nil, @"row: %@", row);
}

// Rows say who the @ picker offers; the composer says what the friend can do with a name.
static void TestComposingMentions(void) {
    NSMutableDictionary *people = [SZPPeople() mutableCopy];
    SZFriendsSnapshotBuilder *builder = Builder(MentionAudience(), people);
    NSDictionary *composer = Daniel(builder, people)[@"composer"];
    SZPExpect([composer[@"mention_note"] isEqual:@"Daniel can click the name to open their chat with that person, or "
                                                 @"to add them if they aren’t friends yet."],
              @"note: %@", composer[@"mention_note"]);
    NSDictionary *key = @{@"text" : @"@", @"emphasis" : @YES};
    SZPExpect([composer[@"hint"] containsObject:key], @"hint: %@", composer[@"hint"]);
    NSDictionary *list = [builder listWithPeople:[people allValues] previewItems:SZPPreviewItems()
                                         profile:SZPProfileRaph() query:@"" now:SZPNow()];
    SZPValidateSnapshot(list, @"list", @"list with mentions");
    NSMutableDictionary *mentionable = [NSMutableDictionary dictionary];
    for (NSDictionary *row in list[@"rows"]) mentionable[row[@"conversation_id"]] = row[@"mentionable"];
    SZPExpect([mentionable[@"c_mei"] isEqual:@YES] && [mentionable[@"c_lena"] isEqual:@NO] &&
                  [mentionable[@"c_jonas"] isEqual:@NO],
              @"friends only: %@", mentionable);
    NSDictionary *lena = [builder conversationForPerson:people[@"c_lena"] items:@[] hasEarlier:NO highlightItemID:nil
                                       waitingElsewhere:1 now:SZPNow()];
    SZPExpect(lena[@"composer"][@"mention_note"] == [NSNull null], @"no note where nothing can be sent");
}

// List previews read "@Name", resolved against the people the list shows, never the link.
static void TestPreviews(void) {
    NSMutableDictionary *people = [SZPPeople() mutableCopy];
    SZFriendsPersonFacts *daniel = people[@"c_daniel"];
    daniel.lastMessageItemID = @"m_d0a1";
    daniel.lastInteractionAt = SZPHongKong(@"2026-10-12 14:45");
    NSMutableDictionary *previews = [SZPPreviewItems() mutableCopy];
    previews[@"m_d0a1"] = SZPItemsFor(@"c_daniel")[0];
    // No directory set: the list uses its own people and profile.
    NSDictionary *list = [SZPBuilder(SZPAudience()) listWithPeople:[people allValues] previewItems:previews
                                                           profile:SZPProfileRaph() query:@"" now:SZPNow()];
    NSDictionary *row = nil;
    for (NSDictionary *candidate in list[@"rows"])
        if ([candidate[@"conversation_id"] isEqual:@"c_daniel"]) row = candidate;
    SZPExpect([row[@"subtitle"] isEqual:@"Daniel: @Mei Lin has the bracket drawing. Ask her for rev B."],
              @"preview: %@", row[@"subtitle"]);
    SZPExpect([row[@"accessibility_label"] containsString:@"@Mei Lin has"], @"%@", row[@"accessibility_label"]);
}

static SZFriendsSearchHitFacts *Hit(NSString *text, NSString *term) {
    SZFriendsSearchHitFacts *hit = [[SZFriendsSearchHitFacts alloc] init];
    hit.conversationID = @"c_daniel";
    hit.itemID = @"m_hit";
    hit.sentAt = SZPHongKong(@"2026-10-12 10:40");
    hit.text = text;
    NSRange range = [text rangeOfString:term];
    hit.matchRanges = @[ [NSValue valueWithRange:range] ];
    return hit;
}

// Search excerpts show "@Name" too; a match in what only the link holds (its ID or key) is not a hit.
static void TestSearchExcerpts(void) {
    NSDictionary *people = SZPPeople();
    SZFriendsSnapshotBuilder *builder = Builder(SZPAudience(), people);
    NSString *text = [SZPItemsFor(@"c_daniel")[0] text];
    NSDictionary *result = [builder searchResultWithHits:@[ Hit(text, @"Mei"), Hit(text, @"jasmine"),
                                                            Hit(text, SZPKeyMei), Hit(text, @"drawing") ]
                                                  people:people more:NO now:SZPNow()];
    SZPValidateResult(result, @"search_messages", @"search with mentions");
    NSArray *results = result[@"results"];
    SZPExpect(results.count == 2, @"the ID and key matches are dropped: %@", results);
    NSArray *inName = @[ @{@"text" : @"@Mei Lin", @"match" : @YES},
                         @{@"text" : @" has the bracket drawing. Ask her for rev B."} ];
    NSArray *afterName = @[ @{@"text" : @"@Mei Lin has the bracket "}, @{@"text" : @"drawing", @"match" : @YES},
                            @{@"text" : @". Ask her for rev B."} ];
    SZPExpect([results[0][@"excerpt"] isEqual:inName], @"a match in the name lights up the name shown: %@",
              results[0][@"excerpt"]);
    SZPExpect([results[1][@"excerpt"] isEqual:afterName], @"a match after the mention moves with it: %@",
              results[1][@"excerpt"]);
}

// add_from_mention's reply and its refusal, written for the person who pressed Add.
static void TestReplies(void) {
    SZFriendsStrings *strings = SZPBuilder(SZPAudience()).strings;
    NSDictionary *reply = SZPFixture(@"replies/add_from_mention.json");
    SZPExpect([[strings addFromMentionSentMessageForName:@"Leo Park"] isEqual:reply[@"result"][@"message"]],
              @"add_from_mention: %@", [strings addFromMentionSentMessageForName:@"Leo Park"]);
    SZPValidateResult(reply[@"result"], @"add_from_mention", @"add_from_mention reply");
    NSString *named = [strings messageForErrorCode:@"mention_mismatch" details:@{@"name" : @"Leo Park"}];
    SZPExpect([named isEqual:@"This link no longer matches Leo Park, so no request was sent."], @"%@", named);
    SZPExpect([[strings messageForErrorCode:@"mention_mismatch" details:@{}]
                  isEqual:@"This link no longer matches that person, so no request was sent."],
              @"unnamed");
}

void SZPRunMentionTests(void) {
    TestFixture();
    TestEachKind();
    TestCardStates();
    TestPlainTextCases();
    TestClientWithoutMentions();
    TestComposingMentions();
    TestPreviews();
    TestSearchExcerpts();
    TestReplies();
}
