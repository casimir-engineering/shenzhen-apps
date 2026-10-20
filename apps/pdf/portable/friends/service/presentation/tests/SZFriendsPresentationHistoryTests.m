// Delete chat history: each friend's details offers it for that chat, and Settings for every chat. Both ask first, in
// red, and their questions say the same things: what goes (messages and file history, from this computer, and anything
// still waiting to go), and what stays (the person where they are, their own copy, files received, and AI chat
// answers where this host's AI chat may have quoted the chat). Every snapshot built here is validated against
// PROTOCOL.md's schemas.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationPrivate.h"

static SZFriendsPersonFacts *Mei(SZFriendsPersonRelation relation) {
    SZFriendsPersonFacts *person = [[SZFriendsPersonFacts alloc] init];
    person.conversationID = @"c_mei";
    person.name = @"Mei Lin";
    person.friendsID = @"jasmine-street";
    person.picture = [SZFriendsPicture animalWithSet:1 index:7];
    person.relation = relation;
    person.lastInteractionAt = SZPHongKong(@"2026-10-12 10:00");
    return person;
}

static SZFriendsAudience *WithAIChat(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.capabilities = [audience.capabilities setByAddingObject:@"assistant.chats"];
    return audience;
}

static NSDictionary *HistoryAction(SZFriendsAudience *audience, SZFriendsPersonFacts *person) {
    NSDictionary *data = [SZPBuilder(audience) detailsForPerson:person waitingElsewhere:0 now:SZPNow()];
    SZPValidateSnapshot(data, @"details", person.conversationID);
    for (NSDictionary *action in data[@"actions"])
        if ([action[@"action"] isEqual:@"delete_history"]) return action;
    return nil;
}

static void ExpectSaysWhatGoesAndStays(NSString *body, NSString *where) {
    for (NSString *part in @[ @"messages and file history", @"deleted from this computer", @"won’t be sent",
                              @"keep", @"Files you received stay where they were saved." ])
        SZPExpect([body containsString:part], @"%@ says \"%@\": %@", where, part, body);
}

// A friend's details: Delete chat history… first, asking in red, naming Mei, and sending delete_history for her chat
// (the view adds the details' conversation_id, as for Remove and Block).
static void TestDetailsOffersDeleteHistory(void) {
    SZFriendsPersonFacts *mei = Mei(SZFriendsPersonRelationFriend);
    NSDictionary *data = [SZPBuilder(SZPAudience()) detailsForPerson:mei waitingElsewhere:0 now:SZPNow()];
    NSDictionary *action = [data[@"actions"] firstObject];
    SZPExpect([action[@"action"] isEqual:@"delete_history"] && [action[@"label"] isEqual:@"Delete chat history…"] &&
                  [action[@"style"] isEqual:@"destructive"] && action[@"arm"] == nil,
              @"first among the details' actions, drawn destructive: %@", data[@"actions"]);
    NSDictionary *confirm = action[@"confirm"];
    SZPExpect([confirm[@"title"] isEqual:@"Delete your chat history with Mei?"] &&
                  [confirm[@"confirm_label"] isEqual:@"Delete History"] &&
                  [confirm[@"cancel_label"] isEqual:@"Cancel"] && [confirm[@"destructive"] isEqual:@YES],
              @"asks first, in red: %@", confirm);
    NSString *body = confirm[@"body"];
    ExpectSaysWhatGoesAndStays(body, @"Mei's question");
    SZPExpect([body hasPrefix:@"Your messages and file history with Mei are deleted from this computer"] &&
                  [body containsString:@"Mei stays your friend and keeps their own copy of the chat."] &&
                  ![body containsString:@"AI chat"],
              @"names Mei, keeps her as a friend, and says nothing of an AI chat this host lacks: %@", body);
    SZPExpect([action[@"note"] isEqual:@"Clears this chat on this computer. Mei stays your friend."], @"note: %@",
              action[@"note"]);

    // Blocked or no longer a friend, it is still there, and never says the person is a friend.
    NSString *blocked = HistoryAction(SZPAudience(), Mei(SZFriendsPersonRelationBlocked))[@"confirm"][@"body"];
    SZPExpect([blocked containsString:@"Mei stays blocked"] && ![blocked containsString:@"friend"],
              @"blocked: %@", blocked);
    NSDictionary *removed = HistoryAction(SZPAudience(), Mei(SZFriendsPersonRelationRemoved));
    SZPExpect(removed && ![removed[@"confirm"][@"body"] containsString:@"friend"] &&
                  ![removed[@"note"] containsString:@"friend"],
              @"removed: %@", removed);
    ExpectSaysWhatGoesAndStays(removed[@"confirm"][@"body"], @"a removed person's question");

    // Where the host's AI chat may read Friends chats, its answers that quoted this one stay, and the question says so.
    NSString *withAI = HistoryAction(WithAIChat(), mei)[@"confirm"][@"body"];
    SZPExpect([withAI hasSuffix:@"AI chat answers that quoted this chat stay in Chats until you delete them there."],
              @"AI chat answers stay: %@", withAI);
}

// Settings' Delete history… says the same things for every chat.
static void TestSettingsSaysTheSame(void) {
    NSArray<SZFriendsPersonFacts *> *people = SZPPeople().allValues;
    NSDictionary *plain = [SZPBuilder(SZPAudience()) settingsWithProfile:SZPProfileRaph() people:people];
    NSDictionary *ai = [SZPBuilder(WithAIChat()) settingsWithProfile:SZPProfileRaph() people:people];
    SZPValidateSnapshot(ai, @"settings", @"history with AI chat");
    NSString *body = plain[@"history"][@"confirm"][@"body"];
    ExpectSaysWhatGoesAndStays(body, @"Settings' question");
    SZPExpect([body hasPrefix:@"Your messages and file history with every friend are deleted from this computer"] &&
                  [body containsString:@"You keep your friends, and they keep their own copies of your chats."] &&
                  ![body containsString:@"AI chat"],
              @"every chat, and the friends stay: %@", body);
    NSString *withAI = ai[@"history"][@"confirm"][@"body"];
    ExpectSaysWhatGoesAndStays(withAI, @"Settings' question with AI chat");
    SZPExpect([withAI hasSuffix:@"AI chat answers that quoted your chats stay in Chats until you delete them there."],
              @"AI chat answers stay: %@", withAI);
    NSDictionary *mei = HistoryAction(SZPAudience(), Mei(SZFriendsPersonRelationFriend));
    SZPExpect([plain[@"history"][@"confirm"][@"confirm_label"] isEqual:mei[@"confirm"][@"confirm_label"]],
              @"one confirm button for both");
}

void SZPRunHistoryTests(void) {
    TestDetailsOffersDeleteHistory();
    TestSettingsSaysTheSame();
}
