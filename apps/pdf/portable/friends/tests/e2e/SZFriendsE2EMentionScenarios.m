// friends-e2e-check: mentions between real helpers (PROTOCOL.md § Mentions, ADR 0007). Ana mentions Cleo to Ben, who
// is not Cleo's friend: Ben sees her as a stranger, never her ID, and adds her from the mention; a second device
// holding Cleo's unreserved ID answers too and is refused, because the request is bound to Cleo's key. Then a peer
// under the test's control sends Ben a forged mention of Cleo and a malformed one, which show as plain text.

#import "SZFriendsE2EScenarios.h"

#import "SZFriendsE2ERogue.h"
#import "service/presentation/SZFriendsMentions.h"

// `asker` asks `visible` from Nearby and `visible` accepts; both rows' conversation ids come back.
static BOOL SZFE2EMentionBefriend(SZFE2EClient *asker, NSString *askerList, NSString *askerName, SZFE2EClient *visible,
                                  NSString *visibleList, NSString *visibleName, NSString *_Nullable *_Nonnull atAsker,
                                  NSString *_Nullable *_Nonnull atVisible) {
    CHECK([[visible intent:@"start_visibility" fields:nil][@"ok"] boolValue], "%@ is visible", visibleName);
    NSString *nearby = [asker subscribe:@"nearby" params:nil];
    __block NSString *nearbyID = nil;
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              for (NSDictionary *person in [asker dataFor:nearby][@"people"])
                  if ([person[@"title"] isEqual:visibleName] && [person[@"nearby_id"] isKindOfClass:NSString.class])
                      nearbyID = person[@"nearby_id"];
              return nearbyID != nil;
          }),
          "%@ appears in Nearby: %@", visibleName, [asker dataFor:nearby]);
    CHECK([[asker intent:@"send_request" fields:@{@"nearby_id" : nearbyID}][@"ok"] boolValue]);
    [asker intent:@"unsubscribe" fields:@{@"subscription" : nearby}];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              id waiting = SZFE2ERowTitled([visible dataFor:visibleList], askerName)[@"waiting"];
              return [waiting isKindOfClass:NSDictionary.class];
          }),
          "%@ is asked: %@", visibleName, [visible dataFor:visibleList]);
    *atVisible = SZFE2ERowTitled([visible dataFor:visibleList], askerName)[@"conversation_id"];
    CHECK([[visible intent:@"accept_request" fields:@{@"conversation_id" : *atVisible}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              id mine = SZFE2ERowTitled([asker dataFor:askerList], visibleName)[@"drop_label"];
              id theirs = SZFE2ERowTitled([visible dataFor:visibleList], askerName)[@"drop_label"];
              return [mine isKindOfClass:NSString.class] && [theirs isKindOfClass:NSString.class];
          }),
          "%@ and %@ are friends", askerName, visibleName);
    *atAsker = SZFE2ERowTitled([asker dataFor:askerList], visibleName)[@"conversation_id"];
    CHECK([[visible intent:@"stop_visibility" fields:nil][@"ok"] boolValue]);
    return YES;
}

// The one message in a conversation that has `prefix`, or nil.
static NSDictionary *SZFE2EMessageStarting(NSDictionary *conversation, NSString *prefix) {
    for (NSDictionary *item in SZFE2EItems(conversation, @"message"))
        if ([item[@"accessibility_label"] containsString:prefix]) return item;
    return nil;
}

// The row waiting for an answer to a request; a request by ID names nobody until its sender's profile arrives.
static NSDictionary *SZFE2EWaitingRequestRow(NSDictionary *list) {
    for (NSDictionary *row in list[@"rows"])
        if ([row[@"waiting"] isKindOfClass:NSDictionary.class] && [row[@"waiting"][@"kind"] isEqual:@"request"])
            return row;
    return nil;
}

static NSString *SZFE2EFriendsID(SZFE2EClient *client) {
    NSString *profile = [client subscribe:@"profile" params:nil];
    NSString *friendsID = [client dataFor:profile][@"id"][@"friends_id"];
    [client intent:@"unsubscribe" fields:@{@"subscription" : profile}];
    return friendsID;
}

BOOL SZFE2EScenarioMentionAddBound(SZFE2EWorld *world) {
    SZFE2EHelper *helperA = nil, *helperB = nil, *helperC = nil, *helperD = nil;
    SZFE2EClient *a = nil, *b = nil, *c = nil, *d = nil;
    NSString *listA = nil, *listB = nil, *listC = nil, *listD = nil;
    NSString *bAtA = nil, *aAtB = nil, *cAtA = nil, *aAtC = nil;
    if (!SZFE2EStartSingle(world, @"a", @"Ana", nil, &helperA, &a, &listA) ||
        !SZFE2EStartSingle(world, @"b", @"Ben", nil, &helperB, &b, &listB) ||
        !SZFE2EMentionBefriend(a, listA, @"Ana", b, listB, @"Ben", &bAtA, &aAtB)) {
        return NO;
    }
    // Every helper here dials from the same loopback address, and a public entry admits three XX handshakes a minute
    // from one address: Ben steps out while Ana befriends Cleo, so his browse does not spend one.
    [b close];
    CHECK([helperB terminate], "Ben leaves for a moment");
    if (!SZFE2EStartSingle(world, @"c", @"Cleo", nil, &helperC, &c, &listC) ||
        !SZFE2EMentionBefriend(a, listA, @"Ana", c, listC, @"Cleo", &cAtA, &aAtC)) {
        return NO;
    }
    CHECK([helperB start], "Ben is back");
    b = [SZFE2EClient clientForHelper:helperB];
    CHECK(b != nil);
    if (!SZFE2EReconnect(b, &listB)) return NO;
    NSString *cleoID = SZFE2EFriendsID(c);
    CHECK(cleoID.length > 0, "Cleo's ID");
    // Cora holds the same unreserved ID (brief § Friends ID): she hears Ben's request as Cleo does.
    if (!SZFE2EStartSingle(world, @"d", @"Cora", @{@"SZFRIENDS_E2E_FRIENDS_ID" : cleoID}, &helperD, &d, &listD))
        return NO;
    // Ana's composer names Cleo with an @ chip: U+FFFC where it sits, and her row in `mentions`.
    NSDictionary *sent = [a intent:@"send_message"
                            fields:@{@"conversation_id" : bAtA, @"text" : @"Ask ￼ about the drawing.",
                                     @"client_token" : SZFE2EToken(), @"mentions" : @[ @{@"conversation_id" : cAtA} ]}];
    CHECK([sent[@"ok"] boolValue], "sent with a mention: %@", sent);
    // Ben sees Cleo as someone he is not friends with, under Ana's name for her, and never her ID or key.
    SZFE2EClient *bm = [SZFE2EClient clientForHelper:helperB capabilities:@[ @"mentions" ]];
    CHECK(bm != nil);
    NSString *atB = [bm openConversation:aAtB], *plainAtB = [b openConversation:aAtB];
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return SZFE2EMessageStarting([bm dataFor:atB], @"@Cleo") != nil; }),
          "the message reaches Ben: %@", [bm dataFor:atB][@"items"]);
    NSDictionary *message = SZFE2EMessageStarting([bm dataFor:atB], @"@Cleo");
    NSDictionary *mention = [message[@"mentions"] firstObject];
    CHECK([message[@"text"] isEqual:@"Ask [@Cleo](szfriends:mention?ref=0) about the drawing."], "%@",
          message[@"text"]);
    CHECK([mention[@"kind"] isEqual:@"stranger"] && [mention[@"label"] isEqual:@"@Cleo"], "a stranger: %@", mention);
    NSString *shown = [NSString stringWithFormat:@"%@ %@", message[@"text"], message[@"segments"]];
    CHECK(![shown containsString:cleoID] && ![shown containsString:@"key="], "no ID or key shown: %@", shown);
    NSDictionary *add = [mention[@"card"][@"actions"] firstObject];
    CHECK([add[@"action"] isEqual:@"add_from_mention"] && [add[@"friends_id"] isEqual:cleoID], "Add: %@", mention);
    // A view that shows no mentions gets the same words as plain text.
    CHECK([SZFE2EMessageStarting([b dataFor:plainAtB], @"@Cleo")[@"text"] isEqual:@"Ask @Cleo about the drawing."]);
    NSDictionary *reply = [bm intent:@"add_from_mention" fields:@{@"friends_id" : add[@"friends_id"],
                                                                 @"identity_key" : add[@"identity_key"],
                                                                 @"name" : add[@"name"]}];
    CHECK([reply[@"ok"] boolValue] && [reply[@"result"][@"message"] hasPrefix:@"Request sent to Cleo."], "%@", reply);
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              NSDictionary *item = SZFE2EMessageStarting([bm dataFor:atB], @"@Cleo");
              return [[item[@"mentions"] firstObject][@"card"][@"status_label"] isEqual:@"Request sent"];
          }),
          "the card says the request went: %@", SZFE2EMessageStarting([bm dataFor:atB], @"@Cleo"));
    // Both holders of the ID hear it. Cora answers first: her key is not the one in the mention, so Ben never gets her.
    CHECK(SZFE2EWaitUntil(25, ^BOOL {
              return SZFE2EWaitingRequestRow([c dataFor:listC]) && SZFE2EWaitingRequestRow([d dataFor:listD]);
          }),
          "both holders were asked: %@ / %@", [c dataFor:listC], [d dataFor:listD]);
    NSString *benAtD = SZFE2EWaitingRequestRow([d dataFor:listD])[@"conversation_id"];
    CHECK([[d intent:@"accept_request" fields:@{@"conversation_id" : benAtD}][@"ok"] boolValue]);
    SZFE2EPump(6);
    CHECK(SZFE2ERowTitled([b dataFor:listB], @"Cora") == nil, "Cora's answer was refused: %@", [b dataFor:listB]);
    NSString *benAtC = SZFE2EWaitingRequestRow([c dataFor:listC])[@"conversation_id"];
    CHECK([[c intent:@"accept_request" fields:@{@"conversation_id" : benAtC}][@"ok"] boolValue]);
    // The mention named Cleo's key, and only that key could answer: her acceptance makes a friend at once, with no
    // host's word needed and nothing for Ben to accept again.
    CHECK(SZFE2EWaitUntil(30, ^BOOL {
              return [SZFE2ERowTitled([b dataFor:listB], @"Cleo")[@"drop_label"] isKindOfClass:NSString.class];
          }),
          "Cleo is Ben's friend once she accepts: %@", [b dataFor:listB][@"rows"]);
    NSString *cAtB = SZFE2ERowTitled([b dataFor:listB], @"Cleo")[@"conversation_id"];
    CHECK(SZFE2ERowTitled([b dataFor:listB], @"Cora") == nil, "still no Cora: %@", [b dataFor:listB]);
    // Now a friend: the same mention opens Ben's chat with Cleo.
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              NSDictionary *now = [SZFE2EMessageStarting([bm dataFor:atB], @"@Cleo")[@"mentions"] firstObject];
              return [now[@"kind"] isEqual:@"friend"] && [now[@"conversation_id"] isEqual:cAtB];
          }),
          "the mention is Cleo's chat now: %@", SZFE2EMessageStarting([bm dataFor:atB], @"@Cleo"));
    [bm close];
    return YES;
}

BOOL SZFE2EScenarioMentionForged(SZFE2EWorld *world) {
    SZFE2EHelper *helperB = nil, *helperC = nil;
    SZFE2EClient *b = nil, *c = nil;
    NSString *listB = nil, *listC = nil, *cAtB = nil, *bAtC = nil;
    if (!SZFE2EStartSingle(world, @"b", @"Ben", nil, &helperB, &b, &listB) ||
        !SZFE2EStartSingle(world, @"c", @"Cleo", nil, &helperC, &c, &listC) ||
        !SZFE2EMentionBefriend(b, listB, @"Ben", c, listC, @"Cleo", &cAtB, &bAtC)) {
        return NO;
    }
    NSString *cleoID = SZFE2EFriendsID(c);
    [c close];
    // Cleo goes, so the only device the peer below finds is Ben's.
    CHECK([helperC terminate], "Cleo leaves");
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, NO);
    CHECK(rogue != nil);
    // The peer becomes Ben's friend the way any answer to Add by ID does.
    SZFriendsIDCodec *codec = [[SZFriendsIDCodec alloc] initWithWordList:[SZFriendsWordList bundledList]];
    NSString *asked = [codec randomIDWithWordCount:2 generator:SZFriendsSystemRandomUniform()];
    CHECK([[b intent:@"add_by_id" fields:@{@"friends_id" : asked}][@"ok"] boolValue]);
    SZFriendsHandshakeOptions *ik = SZFE2EOverheardAnswerOptions(rogue);
    CHECK(ik != nil);
    [rogue useFreshIdentity];
    SZFE2ERogueSession *session = [rogue dial:rogue.hiddenEndpoint options:ik];
    CHECK(SZFE2EWaitEstablished(session), "the answer is admitted: %@", session.closeError);
    CHECK([session send:SZFE2EProfileFrame(@"Rogue")] && [session send:SZFE2EAcceptFrame()]);
    if (!SZFE2EAcceptAnswer(b, listB, @"Rogue")) return NO;
    NSString *rogueAtB = SZFE2ERowTitled([b dataFor:listB], @"Rogue")[@"conversation_id"];
    // A mention under Cleo's ID with another key, a malformed one, and an honest one of a stranger.
    NSString *forged = SZFriendsMentionLink(@"Cleo", cleoID, SZFE2ERandomBytes(32));
    NSString *stranger = SZFriendsMentionLink(@"Leo", asked, SZFE2ERandomBytes(32));
    NSString *malformed = @"[@Max](szfriends:mention?id=not-a-word&key=short)";
    for (NSString *text in @[ [@"Forged " stringByAppendingString:forged],
                              [@"Malformed " stringByAppendingString:malformed],
                              [@"Honest " stringByAppendingString:stranger] ]) {
        CHECK([session send:SZFE2EMessageFrame(text)]);
    }
    SZFE2EClient *bm = [SZFE2EClient clientForHelper:helperB capabilities:@[ @"mentions" ]];
    CHECK(bm != nil);
    NSString *atB = [bm openConversation:rogueAtB];
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EItems([bm dataFor:atB], @"message").count == 3; }),
          "three messages: %@", [bm dataFor:atB][@"items"]);
    NSDictionary *forgedItem = SZFE2EMessageStarting([bm dataFor:atB], @"Forged");
    CHECK([forgedItem[@"text"] isEqual:@"Forged @Cleo"] && forgedItem[@"mentions"] == nil,
          "a forged mention of Ben's friend is plain text: %@", forgedItem);
    NSDictionary *malformedItem = SZFE2EMessageStarting([bm dataFor:atB], @"Malformed");
    CHECK([malformedItem[@"text"] isEqual:@"Malformed @Max"] && malformedItem[@"mentions"] == nil,
          "a malformed one too, stored as text: %@", malformedItem);
    NSDictionary *honest = [SZFE2EMessageStarting([bm dataFor:atB], @"Honest")[@"mentions"] firstObject];
    CHECK([honest[@"kind"] isEqual:@"stranger"] && [honest[@"label"] isEqual:@"@Leo"],
          "the same peer's honest mention is one: %@", honest);
    // Search finds the words shown, not the link behind them.
    NSDictionary *found = [bm intent:@"search_messages" fields:@{@"query" : @"szfriends"}];
    CHECK([found[@"ok"] boolValue] && [found[@"result"][@"results"] count] == 0, "%@", found);
    [bm close];
    [rogue stop];
    return YES;
}
