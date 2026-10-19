// friends-e2e-check: Add by ID with two holders of one unreserved ID, asking again by ID after a decline, and what
// removing someone before an answer was delivered leaves unsent.

#import "SZFriendsE2EHost.h"
#import "SZFriendsE2EScenarios.h"

static NSDictionary *SZFE2EWaitingRequest(NSDictionary *list) {
    for (NSDictionary *row in list[@"rows"]) {
        if ([row[@"waiting"] isKindOfClass:[NSDictionary class]] && [row[@"waiting"][@"kind"] isEqual:@"request"]) {
            return row;
        }
    }
    return nil;
}

static BOOL SZFE2EIsFriendRow(NSDictionary *row) {
    return [row[@"drop_label"] isKindOfClass:[NSString class]];
}

// Brief § Friends ID (unreserved duplicates nearby): two devices may hold the same unreserved ID; both receive the
// request and the requester sees whoever accepts. The request used to be deleted at the first acceptance, so the
// second holder's answer was refused; it now stays until it expires. Neither is vouched for by a host, so the
// requester accepts each answer herself (wave-4 re-check).
BOOL SZFE2EScenarioTwoHolders(SZFE2EWorld *world) {
    SZFE2EHelper *helperA = nil, *helperB1 = nil, *helperB2 = nil;
    SZFE2EClient *a = nil, *b1 = nil, *b2 = nil;
    NSString *listA = nil, *listB1 = nil, *listB2 = nil;
    if (!SZFE2EStartSingle(world, @"a", @"Ana", nil, &helperA, &a, &listA)) return NO;
    if (!SZFE2EStartSingle(world, @"b1", @"Ben", nil, &helperB1, &b1, &listB1)) return NO;
    NSString *profile = [b1 subscribe:@"profile" params:nil];
    NSString *shared = [b1 dataFor:profile][@"id"][@"friends_id"];
    CHECK(shared.length > 0, "Ben's ID");
    if (!SZFE2EStartSingle(world, @"b2", @"Bea", @{@"SZFRIENDS_E2E_FRIENDS_ID" : shared}, &helperB2, &b2, &listB2)) {
        return NO;
    }
    NSString *profile2 = [b2 subscribe:@"profile" params:nil];
    CHECK([[b2 dataFor:profile2][@"id"][@"friends_id"] isEqual:shared], "Bea holds the same unreserved ID");
    NSDictionary *reply = [a intent:@"add_by_id" fields:@{@"friends_id" : shared}];
    CHECK([reply[@"ok"] boolValue], "add_by_id: %@", reply);
    CHECK(SZFE2EWaitUntil(25, ^BOOL {
              return SZFE2EWaitingRequest([b1 dataFor:listB1]) != nil &&
                     SZFE2EWaitingRequest([b2 dataFor:listB2]) != nil;
          }),
          "both holders received it: %@ / %@", [b1 dataFor:listB1], [b2 dataFor:listB2]);
    NSString *atB1 = SZFE2EWaitingRequest([b1 dataFor:listB1])[@"conversation_id"];
    NSString *atB2 = SZFE2EWaitingRequest([b2 dataFor:listB2])[@"conversation_id"];
    CHECK([[b1 intent:@"accept_request" fields:@{@"conversation_id" : atB1}][@"ok"] boolValue]);
    if (!SZFE2EAcceptAnswer(a, listA, @"Ben")) return NO; // Ben answered first
    CHECK([[b2 intent:@"accept_request" fields:@{@"conversation_id" : atB2}][@"ok"] boolValue]);
    // Bea's answer still gets in, as a person of her own.
    if (!SZFE2EAcceptAnswer(a, listA, @"Bea")) return NO;
    CHECK(SZFE2EIsFriendRow(SZFE2ERowTitled([a dataFor:listA], @"Ben")), "Ben is still a friend");
    NSString *benAtA = SZFE2ERowTitled([a dataFor:listA], @"Ben")[@"conversation_id"];
    NSString *beaAtA = SZFE2ERowTitled([a dataFor:listA], @"Bea")[@"conversation_id"];
    CHECK(benAtA && beaAtA && ![benAtA isEqual:beaAtA], "two conversations, never merged");
    return YES;
}

// Review (presence secret rotation): B accepts A while A is away, then removes A before anything was delivered. The
// acceptance and the presence secret queued with it used to stay pending and went out when A came back (the answer
// as a removed person's due); now nothing queued for A before the removal goes out.
BOOL SZFE2EScenarioRemoveBeforeDelivery(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2ERequestFromNearby(pair)) return NO;
    CHECK([[pair.b intent:@"stop_visibility" fields:nil][@"ok"] boolValue]);
    [pair.a close];
    CHECK([pair.helperA terminate], "A leaves before B answers");
    CHECK([[pair.b intent:@"accept_request" fields:@{@"conversation_id" : pair.aAtB}][@"ok"] boolValue]);
    CHECK([[pair.b intent:@"remove_friend" fields:@{@"conversation_id" : pair.aAtB}][@"ok"] boolValue]);
    CHECK([pair.helperA start], "A comes back");
    pair.a = [SZFE2EClient clientForHelper:pair.helperA];
    CHECK(pair.a != nil);
    NSString *listA = nil;
    if (!SZFE2EReconnect(pair.a, &listA)) return NO;
    // B sees A again at once (an unrecognised device it would probe); give it time to send anything it still would.
    SZFE2EPump(8);
    NSDictionary *row = SZFE2ERowWithID([pair.a dataFor:listA], pair.bAtA);
    CHECK(row != nil && !SZFE2EIsFriendRow(row), "no acceptance reached A: %@", row);
    CHECK(![row[@"route"][@"kind"] isEqual:@"local"], "and no session with B: %@", row);
    return YES;
}

// B restarts, so its one-request-an-hour limit per sender does not hold A's next request back.
static BOOL SZFE2ERestartB(SZFE2EPair *pair, NSString *_Nullable *_Nonnull listB) {
    [pair.b close];
    CHECK([pair.helperB terminate] && [pair.helperB start], "B restarts");
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.b != nil);
    return SZFE2EReconnect(pair.b, listB);
}

// A asks again for B's ID; B, whose row for A is aAtB, accepts; A's own row for B, bAtA, becomes the friendship and
// the fresh row add_by_id made folds into it; both show the same new code. Returns that code, or nil.
static NSString *_Nullable SZFE2EAskAgainAndAccept(SZFE2EPair *pair, NSString *friendsID, NSString *bAtA,
                                                   NSString *aAtB, NSString *listB) {
    NSDictionary *reply = [pair.a intent:@"add_by_id" fields:@{@"friends_id" : friendsID}];
    NSString *again = reply[@"result"][@"conversation_id"];
    __block NSString *code = nil;
    BOOL ok = again != nil && ![again isEqual:bAtA];
    if (!ok) SZFE2EFail(__FILE__, __LINE__, "a fresh row for the new request, not B's old one", reply.description);
    if (!ok) return nil;
    if (!SZFE2EWaitUntil(25, ^BOOL {
            return [SZFE2EWaitingRequest([pair.b dataFor:listB])[@"conversation_id"] isEqual:aAtB];
        })) {
        SZFE2EFail(__FILE__, __LINE__, "B received it again, on A's row", [[pair.b dataFor:listB] description]);
        return nil;
    }
    if (![[pair.b intent:@"accept_request" fields:@{@"conversation_id" : aAtB}][@"ok"] boolValue]) return nil;
    NSString *detailsA = [pair.a subscribe:@"details" params:@{@"conversation_id" : bAtA}];
    NSString *detailsB = [pair.b subscribe:@"details" params:@{@"conversation_id" : aAtB}];
    ok = SZFE2EWaitUntil(25, ^BOOL {
        id codeA = [pair.a dataFor:detailsA][@"verification"][@"comparison_code"];
        id codeB = [pair.b dataFor:detailsB][@"verification"][@"comparison_code"];
        code = [codeA isKindOfClass:[NSString class]] && [codeA isEqual:codeB] ? codeA : nil;
        return code != nil && SZFE2EIsFriendRow(SZFE2ERowWithID([pair.a dataFor:pair.listA], bAtA)) &&
               SZFE2ERowWithID([pair.a dataFor:pair.listA], again) == nil;
    });
    if (!ok) {
        NSString *detail = [NSString stringWithFormat:@"%@ / %@ / %@", [pair.a dataFor:detailsA][@"verification"],
                                                      [pair.b dataFor:detailsB][@"verification"],
                                                      [pair.a dataFor:pair.listA][@"rows"]];
        SZFE2EFail(__FILE__, __LINE__, "B's own row is the friendship, one row, the same fresh code", detail);
    }
    [pair.a intent:@"unsubscribe" fields:@{@"subscription" : detailsA}];
    [pair.b intent:@"unsubscribe" fields:@{@"subscription" : detailsB}];
    return ok ? code : nil;
}

static BOOL SZFE2EAskAgainSteps(SZFE2EWorld *world, NSDictionary *hostEnv) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, hostEnv, hostEnv)) return NO;
    NSString *friendsID = SZFE2EReservedAndAttested(pair.b, pair.helperB);
    CHECK(friendsID != nil, "B's ID, reserved and attested");
    NSDictionary *reply = [pair.a intent:@"add_by_id" fields:@{@"friends_id" : friendsID}];
    NSString *bAtA = reply[@"result"][@"conversation_id"];
    CHECK(bAtA != nil, "%@", reply);
    NSString *asked = SZFE2ERowWithID([pair.a dataFor:pair.listA], bAtA)[@"subtitle"];
    __block NSString *aAtB = nil;
    CHECK(SZFE2EWaitUntil(25, ^BOOL {
              aAtB = SZFE2EWaitingRequest([pair.b dataFor:pair.listB])[@"conversation_id"];
              return aAtB != nil;
          }),
          "B received the request: %@", [pair.b dataFor:pair.listB]);
    CHECK([[pair.b intent:@"decline_request" fields:@{@"conversation_id" : aAtB}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(25, ^BOOL {
              NSDictionary *row = SZFE2ERowWithID([pair.a dataFor:pair.listA], bAtA);
              return row != nil && ![row[@"subtitle"] isEqual:asked];
          }),
          "the decline reached A: %@", SZFE2ERowWithID([pair.a dataFor:pair.listA], bAtA));
    SZFE2EPump(2);
    CHECK(SZFE2EWaitingRequest([pair.b dataFor:pair.listB]) == nil, "the decline sticks: %@",
          SZFE2EWaitingRequest([pair.b dataFor:pair.listB]));
    NSString *listB = nil;
    if (!SZFE2ERestartB(pair, &listB)) return NO;
    NSString *first = SZFE2EAskAgainAndAccept(pair, friendsID, bAtA, aAtB, listB);
    CHECK(first != nil, "friends after asking again");
    // Both remove each other; B's row keeps the code they compared.
    CHECK([[pair.a intent:@"remove_friend" fields:@{@"conversation_id" : bAtA}][@"ok"] boolValue]);
    CHECK([[pair.b intent:@"remove_friend" fields:@{@"conversation_id" : aAtB}][@"ok"] boolValue]);
    if (!SZFE2ERestartB(pair, &listB)) return NO;
    CHECK(SZFE2EAskAgainAndAccept(pair, friendsID, bAtA, aAtB, listB) != nil, "friends again, with a new code");
    return YES;
}

// Wave-3 review (key change handling): asking again by ID for someone we had a row for used to turn that row, key and
// all, into the new request. Now the request gets a fresh row; when the same key answers, their old row comes back as
// the one friendship (the fresh row folds into it), and both sides compare a fresh code. Twice: after B declined (the
// decline must stick: our request is not delivered again on the session that brings it), and after both removed
// each other (B's row still holds the old friendship's code, which the new request clears). B checks in with the
// local host, so its answers show the attestation that tells A its row is coming back: a decline carries no PROFILE,
// and A keeps no ID it typed on an unattested answer's row (ADR 0004, Review amendments, 9).
BOOL SZFE2EScenarioAskAgainByID(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2ELocalHost *host = [SZFE2ELocalHost startInWorld:world skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip asking again by ID: %s\n", why.UTF8String);
        return why != nil;
    }
    @try {
        return SZFE2EAskAgainSteps(world, host.helperEnvironment);
    } @finally {
        [host stop];
    }
}
