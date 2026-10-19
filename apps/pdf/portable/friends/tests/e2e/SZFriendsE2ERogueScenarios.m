// friends-e2e-check: one real helper against a peer under the scenario's control (SZFriendsE2ERogue.h), for what the
// security reviews said a stranger could do: grind comparison codes, answer an overheard Add by ID under many keys,
// flood the public entry, and hold sessions open.

#import "SZFriendsE2EScenarios.h"

#import "SZFriendsE2ERogue.h"

SZFriendsHandshakeOptions *SZFE2EOptions(SZFriendsHandshakePattern pattern, BOOL browseOnly) {
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = pattern;
    options.route = SZFriendsRouteMethodLAN;
    options.browseOnly = browseOnly;
    return options;
}

SZFE2ERogue *SZFE2EStartRogue(SZFE2EWorld *world, BOOL needPublic) {
    SZFE2ERogue *rogue = [[SZFE2ERogue alloc] initWithServiceType:world.serviceType];
    [rogue start];
    BOOL seen = SZFE2EWaitUntil(10, ^BOOL {
        return rogue.hiddenEndpoint != nil && (!needPublic || rogue.publicEndpoint != nil);
    });
    if (!seen) SZFE2EFail(__FILE__, __LINE__, "the rogue sees the helper", @"");
    return seen ? rogue : nil;
}

BOOL SZFE2EWaitEstablished(SZFE2ERogueSession *session) {
    return SZFE2EWaitUntil(10, ^BOOL { return session.established || session.closed; }) && session.established;
}

// Review (comparison codes): a stranger used to get the responder's code right after HELLO and leave without a trace,
// so codes could be ground. Now the code exists only once REQUEST is recorded as a visible request, and a second
// session with the same key never replaces it.
BOOL SZFE2EScenarioCodeAfterRequest(SZFE2EWorld *world) {
    SZFE2EHelper *helper = nil;
    SZFE2EClient *b = nil;
    NSString *list = nil;
    if (!SZFE2EStartSingle(world, @"b", @"Ben", nil, &helper, &b, &list)) return NO;
    CHECK([[b intent:@"start_visibility" fields:nil][@"ok"] boolValue], "Ben is visible");
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, YES);
    CHECK(rogue != nil);
    SZFE2ERogueSession *first = [rogue dial:rogue.publicEndpoint options:SZFE2EOptions(SZFriendsHandshakeXX, NO)];
    CHECK(SZFE2EWaitEstablished(first), "XX to the public entry: %@", first.closeError);
    [first runCodeExchange];
    SZFE2EPump(2.5);
    CHECK(first.code == nil, "no code without a request (got %@)", first.code);
    for (NSDictionary *row in [b dataFor:list][@"rows"]) CHECK(row[@"waiting"] == [NSNull null], "no row: %@", row);
    CHECK([first send:SZFE2EProfileFrame(@"Rogue")] && [first send:SZFE2ERequestFrame()]);
    __block NSString *rowID = nil;
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *row = SZFE2ERowTitled([b dataFor:list], @"Rogue");
              rowID = [row[@"waiting"] isKindOfClass:[NSDictionary class]] ? row[@"conversation_id"] : nil;
              return rowID != nil && first.code != nil;
          }),
          "the request is on Ben's list, then a code: %@ %@", [b dataFor:list], first.code);
    NSString *atB = [b openConversation:rowID];
    // The card groups the digits for reading ("447 765").
    NSString * (^shown)(void) = ^NSString * {
        id code = [b dataFor:atB][@"request"][@"comparison_code"];
        return [code isKindOfClass:[NSString class]] ? [code stringByReplacingOccurrencesOfString:@" " withString:@""]
                                                     : nil;
    };
    CHECK(SZFE2EWaitUntil(5, ^BOOL { return [shown() isEqual:first.code]; }),
          "both show the same code: %@ / %@", [b dataFor:atB][@"request"], first.code);
    // The same key again in a new session: acknowledged, but no second attempt at the code.
    SZFE2ERogueSession *second = [rogue dial:rogue.publicEndpoint options:SZFE2EOptions(SZFriendsHandshakeXX, NO)];
    CHECK(SZFE2EWaitEstablished(second), "a second session: %@", second.closeError);
    [second runCodeExchange];
    CHECK([second send:SZFE2ERequestFrame()]);
    CHECK(SZFE2EWaitUntil(5, ^BOOL { return [second firstArrivalOfType:SZFriendsFrameTypeAck] != nil; }),
          "the repeated request is acknowledged");
    SZFE2EPump(2);
    CHECK(second.code == nil, "no second code (got %@)", second.code);
    CHECK([shown() isEqual:first.code], "the stored code stands: %@", [b dataFor:atB][@"request"]);
    [rogue stop];
    return YES;
}

SZFriendsHandshakeOptions *SZFE2EOverheardAnswerOptions(SZFE2ERogue *rogue) {
    if (!SZFE2EWaitUntil(15, ^BOOL { return rogue.requestsByID.count > 0; })) {
        SZFE2EFail(__FILE__, __LINE__, "the rogue overhears the request", @"");
        return nil;
    }
    SZFE2ERogueSession *heard = rogue.requestsByID.firstObject;
    SZFriendsFrame *request = nil;
    for (SZFriendsFrame *frame in heard.frames) {
        if (frame.type == SZFriendsFrameTypeRequestByID) request = frame;
    }
    NSData *requesterKey = request ? SZFriendsVerifyRequestByIDFrame(request, heard.handshakeHash) : nil;
    if (requesterKey == nil) {
        SZFE2EFail(__FILE__, __LINE__, "a request signed for that session", @"");
        return nil;
    }
    SZFriendsHandshakeOptions *ik = SZFE2EOptions(SZFriendsHandshakeIK, NO);
    ik.remoteStaticKey = [request dataForTag:SZFriendsFieldStaticKey];
    ik.expectedIdentityKey = requesterKey;
    ik.requestToken = [request dataForTag:SZFriendsFieldToken];
    return ik;
}

// Review (Add by ID): every nearby device hears the request, so anyone can answer it. A token now admits at most
// three distinct keys, each its own person, and a session it let in carries friendship creation only until that
// person is a friend. Wave-3 re-check: only two of those may answer without the host's attestation, so throwaway keys
// can no longer take the slot the real holder needs. Wave-4 re-check: an unattested ACCEPT is a request Ana accepts,
// and our presence secret goes only once she does.
BOOL SZFE2EScenarioAnswersByID(SZFE2EWorld *world) {
    SZFE2EHelper *helper = nil;
    SZFE2EClient *a = nil;
    NSString *list = nil;
    if (!SZFE2EStartSingle(world, @"a", @"Ana", nil, &helper, &a, &list)) return NO;
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, NO);
    CHECK(rogue != nil);
    SZFriendsIDCodec *codec = [[SZFriendsIDCodec alloc] initWithWordList:[SZFriendsWordList bundledList]];
    NSString *target = [codec randomIDWithWordCount:2 generator:SZFriendsSystemRandomUniform()];
    NSDictionary *reply = [a intent:@"add_by_id" fields:@{@"friends_id" : target}];
    CHECK([reply[@"ok"] boolValue], "add_by_id %@: %@", target, reply);
    SZFriendsHandshakeOptions *ik = SZFE2EOverheardAnswerOptions(rogue);
    CHECK(ik != nil);
    NSMutableArray<SZFE2ERogueSession *> *answers = [NSMutableArray array];
    for (int i = 1; i <= 4; i++) {
        [rogue useFreshIdentity];
        SZFE2ERogueSession *answer = [rogue dial:rogue.hiddenEndpoint options:ik];
        BOOL live = SZFE2EWaitEstablished(answer);
        if (i <= 2) {
            CHECK(live, "answer %d is admitted: %@", i, answer.closeError);
            CHECK([answer send:SZFE2EProfileFrame([NSString stringWithFormat:@"Rogue %d", i])]);
            [answers addObject:answer];
        } else {
            CHECK(!live && answer.closed, "unattested key %d is refused before any reply", i);
        }
    }
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSArray *rows = [a dataFor:list][@"rows"];
              return rows.count == 2 && SZFE2ERowTitled([a dataFor:list], @"Rogue 1") &&
                     SZFE2ERowTitled([a dataFor:list], @"Rogue 2");
          }),
          "two people, never merged, no third: %@", [a dataFor:list][@"rows"]);
    // Before acceptance: a REQUEST (which used to count as acceptance) and a message are both dropped.
    SZFE2ERogueSession *one = answers.firstObject;
    CHECK([one send:SZFE2ERequestFrame()] && [one send:SZFE2EMessageFrame(@"before")]);
    SZFE2EPump(1.5);
    NSString *rowID = SZFE2ERowTitled([a dataFor:list], @"Rogue 1")[@"conversation_id"];
    CHECK(SZFE2ERowWithID([a dataFor:list], rowID)[@"drop_label"] == [NSNull null] ||
          SZFE2ERowWithID([a dataFor:list], rowID)[@"drop_label"] == nil, "not a friend: %@",
          SZFE2ERowWithID([a dataFor:list], rowID));
    NSString *atA = [a openConversation:rowID];
    SZFE2EPump(0.5);
    CHECK(SZFE2EItems([a dataFor:atA], @"message").count == 0, "nothing stored: %@", [a dataFor:atA][@"items"]);
    // ACCEPT from an answer nobody vouched for waits for Ana: still not a friend, nothing stored, no presence secret.
    CHECK([one send:SZFE2EAcceptFrame()]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EUnconfirmedAnswer([a dataFor:list], @"Rogue 1") != nil; }),
          "a request Ana answers, after ACCEPT: %@", SZFE2ERowWithID([a dataFor:list], rowID));
    CHECK([one send:SZFE2EMessageFrame(@"too soon")]);
    SZFE2EPump(1.0);
    CHECK([one firstArrivalOfType:SZFriendsFrameTypePresenceSecret] == nil, "no presence secret before she accepts");
    if (!SZFE2EAcceptAnswer(a, list, @"Rogue 1")) return NO;
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return [one firstArrivalOfType:SZFriendsFrameTypePresenceSecret] != nil; }),
          "her presence secret goes once she has accepted");
    CHECK([one send:SZFE2EMessageFrame(@"after")]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSArray *messages = SZFE2EItems([a dataFor:atA], @"message");
              return messages.count == 1 && [messages.firstObject[@"text"] isEqual:@"after"];
          }),
          "the message after acceptance arrives: %@", [a dataFor:atA][@"items"]);
    [rogue stop];
    return YES;
}

// Review (comparison codes; work before authentication): the public entry admits at most 3 XX handshakes a minute
// from one address (20 from everyone), refused before any Diffie-Hellman.
BOOL SZFE2EScenarioAdmission(SZFE2EWorld *world) {
    SZFE2EHelper *helper = nil;
    SZFE2EClient *b = nil;
    NSString *list = nil;
    if (!SZFE2EStartSingle(world, @"b", @"Ben", nil, &helper, &b, &list)) return NO;
    CHECK([[b intent:@"start_visibility" fields:nil][@"ok"] boolValue], "Ben is visible");
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, YES);
    CHECK(rogue != nil);
    int profiles = 0;
    for (int i = 0; i < 4; i++) {
        SZFE2ERogueSession *browse = [rogue dial:rogue.publicEndpoint options:SZFE2EOptions(SZFriendsHandshakeXX, YES)];
        CHECK(SZFE2EWaitUntil(10, ^BOOL { return browse.closed; }), "browse %d ends", i + 1);
        if (browse.publicProfile != nil) profiles++;
        if (i == 3) CHECK(browse.publicProfile == nil, "the fourth from one address in a minute gets nothing");
    }
    CHECK(profiles == 3, "three browses answered: %d", profiles);
    [rogue stop];
    return YES;
}

// Review (NN and stranger sessions held open): an NN session ends 2 s after RECEIVED whether or not this device holds
// the ID, and a stranger's session that says nothing ends after the idle limit (2 s here, 60 s in production).
BOOL SZFE2EScenarioStrangerLifetimes(SZFE2EWorld *world) {
    SZFE2EHelper *helper = nil;
    SZFE2EClient *b = nil;
    NSString *list = nil;
    if (!SZFE2EStartSingle(world, @"b", @"Ben", @{@"SZFRIENDS_E2E_IDLE_TIMEOUT" : @"2"}, &helper, &b, &list)) {
        return NO;
    }
    NSString *profile = [b subscribe:@"profile" params:nil];
    NSString *mine = [b dataFor:profile][@"id"][@"friends_id"];
    CHECK(mine.length > 0, "Ben's ID");
    CHECK([[b intent:@"start_visibility" fields:nil][@"ok"] boolValue], "Ben is visible");
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, YES);
    CHECK(rogue != nil);
    SZFriendsIDCodec *codec = [[SZFriendsIDCodec alloc] initWithWordList:[SZFriendsWordList bundledList]];
    NSString *other = [codec randomIDWithWordCount:2 generator:SZFriendsSystemRandomUniform()];
    for (NSString *target in @[ mine, other ]) {
        SZFE2ERogueSession *nn = [rogue dial:rogue.hiddenEndpoint options:SZFE2EOptions(SZFriendsHandshakeNN, NO)];
        CHECK(SZFE2EWaitEstablished(nn), "NN to the hidden listener: %@", nn.closeError);
        SZFriendsFrame *ask = SZFriendsMakeRequestByIDFrame(rogue.identity, target, SZFE2ERandomBytes(16),
                                                            SZFE2ERandomBytes(32), nn.handshakeHash);
        CHECK(ask != nil && [nn send:ask]);
        CHECK(SZFE2EWaitUntil(5, ^BOOL { return nn.closed; }), "closed by Ben within 5 s");
        NSDate *received = [nn firstArrivalOfType:SZFriendsFrameTypeReceived];
        NSTimeInterval after = [nn.closedAt timeIntervalSinceDate:received];
        CHECK(received != nil && after > 1.4 && after < 3.5, "closed %.2f s after RECEIVED (%@)", after,
              [target isEqual:mine] ? @"holder" : @"not the holder");
    }
    SZFE2ERogueSession *quiet = [rogue dial:rogue.publicEndpoint options:SZFE2EOptions(SZFriendsHandshakeXX, NO)];
    CHECK(SZFE2EWaitEstablished(quiet), "XX to the public entry: %@", quiet.closeError);
    CHECK(SZFE2EWaitUntil(8, ^BOOL { return quiet.closed; }), "a stranger who says nothing is let go");
    NSTimeInterval lived = [quiet.closedAt timeIntervalSinceDate:quiet.establishedAt];
    CHECK(lived > 1.5, "after the idle limit, not at once: %.2f s", lived);
    // Wave-3 review (idle limits): repeating a frame used to restart the idle clock, so a PROFILE every few seconds
    // held a stranger's session until its 24-hour maximum. Only the first PROFILE moves the request forward now.
    SZFE2ERogueSession *chatty = [rogue dial:rogue.publicEndpoint options:SZFE2EOptions(SZFriendsHandshakeXX, NO)];
    CHECK(SZFE2EWaitEstablished(chatty), "XX to the public entry again: %@", chatty.closeError);
    NSDate *firstProfile = [NSDate date];
    for (int i = 0; i < 10 && !chatty.closed; i++) {
        [chatty send:SZFE2EProfileFrame(@"Mallory")];
        SZFE2EPump(0.6);
    }
    CHECK(chatty.closed, "a stranger repeating PROFILE is let go all the same");
    NSTimeInterval after = [chatty.closedAt timeIntervalSinceDate:firstProfile];
    CHECK(after < 4.0, "at the idle limit after the first PROFILE: %.2f s", after);
    [rogue stop];
    return YES;
}
