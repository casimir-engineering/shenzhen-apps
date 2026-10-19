// friends-e2e-check: Delete chat history between real helpers (PROTOCOL.md intent delete_history). Ana chats with Ben
// and with a peer under the test's control. Deleting Ben's chat empties it, takes the words off his list row and out
// of search, and leaves the other chat, its row and its search hits as they were; both friends stay. Deleting all
// history then empties the other chat too.

#import "SZFriendsE2EScenarios.h"

#import "SZFriendsE2ERogue.h"
#import "service/identity/SZFriendsIdentity.h"

// The conversations search finds `query` in, in result order.
static NSArray<NSString *> *SZFE2EHistorySearch(SZFE2EClient *client, NSString *query) {
    NSDictionary *found = [client intent:@"search_messages" fields:@{@"query" : query}];
    if (![found[@"ok"] boolValue]) return nil;
    return [found[@"result"][@"results"] valueForKey:@"conversation_id"];
}

static NSString *SZFE2ESubtitle(NSDictionary *list, NSString *conversationID) {
    id subtitle = SZFE2ERowWithID(list, conversationID)[@"subtitle"];
    return [subtitle isKindOfClass:NSString.class] ? subtitle : @"";
}

BOOL SZFE2EScenarioDeleteHistory(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    SZFE2EClient *ana = pair.a;
    NSString *list = pair.listA, *ben = pair.bAtA;
    NSDictionary *mine = @{@"conversation_id" : ben, @"text" : @"kiwi orchard plan", @"client_token" : SZFE2EToken()};
    NSDictionary *his = @{@"conversation_id" : pair.aAtB, @"text" : @"kiwi reply from Ben",
                          @"client_token" : SZFE2EToken()};
    CHECK([[ana intent:@"send_message" fields:mine][@"ok"] boolValue], "Ana writes to Ben");
    CHECK([[pair.b intent:@"send_message" fields:his][@"ok"] boolValue], "Ben answers");
    NSString *atBen = [ana openConversation:ben];
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return SZFE2EItems([ana dataFor:atBen], @"message").count == 2; }),
          "both messages in Ana's chat with Ben: %@", [ana dataFor:atBen][@"items"]);
    // Ben goes, so the only device the peer below finds is Ana's.
    [pair.b close];
    CHECK([pair.helperB terminate], "Ben leaves");
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, NO);
    CHECK(rogue != nil);
    // The peer becomes Ana's friend the way any answer to Add by ID does, and says something of its own.
    SZFriendsIDCodec *codec = [[SZFriendsIDCodec alloc] initWithWordList:[SZFriendsWordList bundledList]];
    NSString *asked = [codec randomIDWithWordCount:2 generator:SZFriendsSystemRandomUniform()];
    CHECK([[ana intent:@"add_by_id" fields:@{@"friends_id" : asked}][@"ok"] boolValue]);
    SZFriendsHandshakeOptions *ik = SZFE2EOverheardAnswerOptions(rogue);
    CHECK(ik != nil);
    [rogue useFreshIdentity];
    SZFE2ERogueSession *session = [rogue dial:rogue.hiddenEndpoint options:ik];
    CHECK(SZFE2EWaitEstablished(session), "the answer is admitted: %@", session.closeError);
    CHECK([session send:SZFE2EProfileFrame(@"Cleo")] && [session send:SZFE2EAcceptFrame()]);
    if (!SZFE2EAcceptAnswer(ana, list, @"Cleo")) return NO;
    NSString *cleo = SZFE2ERowTitled([ana dataFor:list], @"Cleo")[@"conversation_id"];
    CHECK([session send:SZFE2EMessageFrame(@"mango tasting at noon")]);
    NSString *atCleo = [ana openConversation:cleo];
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EItems([ana dataFor:atCleo], @"message").count == 1; }),
          "Cleo's message: %@", [ana dataFor:atCleo][@"items"]);
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return [SZFE2ESubtitle([ana dataFor:list], ben) containsString:@"kiwi"] &&
                     [SZFE2ESubtitle([ana dataFor:list], cleo) containsString:@"mango"];
          }),
          "each row previews its chat: %@", [ana dataFor:list][@"rows"]);
    NSArray *bothBen = @[ ben, ben ], *onlyCleo = @[ cleo ];
    CHECK([SZFE2EHistorySearch(ana, @"kiwi") isEqual:bothBen] && [SZFE2EHistorySearch(ana, @"mango") isEqual:onlyCleo],
          "search finds both chats: %@ / %@", SZFE2EHistorySearch(ana, @"kiwi"), SZFE2EHistorySearch(ana, @"mango"));

    // Ben's chat only: it empties, his row loses its preview, and search no longer finds it; Cleo's chat is untouched.
    NSDictionary *deleted = [ana intent:@"delete_history" fields:@{@"conversation_id" : ben}];
    CHECK([deleted[@"ok"] boolValue], "delete Ben's chat: %@", deleted);
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return SZFE2EItems([ana dataFor:atBen], @"message").count == 0 &&
                     ![SZFE2ESubtitle([ana dataFor:list], ben) containsString:@"kiwi"];
          }),
          "Ben's chat is empty and his row says nothing of it: %@ / %@", [ana dataFor:atBen][@"items"],
          SZFE2ERowWithID([ana dataFor:list], ben));
    CHECK(SZFE2EHistorySearch(ana, @"kiwi").count == 0, "search finds nothing of Ben's chat: %@",
          SZFE2EHistorySearch(ana, @"kiwi"));
    CHECK(SZFE2EItems([ana dataFor:atCleo], @"message").count == 1 &&
              [SZFE2ESubtitle([ana dataFor:list], cleo) containsString:@"mango"] &&
              [SZFE2EHistorySearch(ana, @"mango") isEqual:onlyCleo],
          "Cleo's chat, row and search hits stay: %@", SZFE2ERowWithID([ana dataFor:list], cleo));
    NSString *details = [ana subscribe:@"details" params:@{@"conversation_id" : ben}];
    CHECK([[ana dataFor:details][@"auto_accept"][@"available"] isEqual:@YES] &&
              SZFE2ERowWithID([ana dataFor:list], ben) != nil,
          "Ben is still a friend: %@", [ana dataFor:details]);
    [ana intent:@"unsubscribe" fields:@{@"subscription" : details}];

    // Then every chat: Cleo's empties too, and both people stay.
    deleted = [ana intent:@"delete_history" fields:nil];
    CHECK([deleted[@"ok"] boolValue], "delete all history: %@", deleted);
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return SZFE2EItems([ana dataFor:atCleo], @"message").count == 0 &&
                     ![SZFE2ESubtitle([ana dataFor:list], cleo) containsString:@"mango"];
          }),
          "Cleo's chat is empty too: %@", [ana dataFor:atCleo][@"items"]);
    CHECK(SZFE2EHistorySearch(ana, @"mango").count == 0 && SZFE2EHistorySearch(ana, @"kiwi").count == 0,
          "search finds nothing at all");
    CHECK(SZFE2ERowWithID([ana dataFor:list], ben) && SZFE2ERowWithID([ana dataFor:list], cleo),
          "both people stay in the list: %@", [ana dataFor:list][@"rows"]);
    [rogue stop];
    return YES;
}
