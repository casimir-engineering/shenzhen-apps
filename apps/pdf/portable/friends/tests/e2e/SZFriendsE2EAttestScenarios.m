// friends-e2e-check: Add by ID with host attestations (ADR 0004, Review amendments, 9), against the local Node host
// service on 127.0.0.1. The security re-check found that anyone who heard an Add by ID passed as the ID's holder: the
// holder now shows the host's attestation in its IK callback and the requester marks its ID confirmed; any other
// answer is a person of its own, unconfirmed; and an attestation naming another key is refused.

#import "SZFriendsE2EHost.h"
#import "SZFriendsE2ERogue.h"
#import "SZFriendsE2EScenarios.h"

static NSDictionary *SZFE2EWaitingRow(NSDictionary *list) {
    for (NSDictionary *row in list[@"rows"]) {
        if ([row[@"waiting"] isKindOfClass:[NSDictionary class]] && [row[@"waiting"][@"kind"] isEqual:@"request"]) {
            return row;
        }
    }
    return nil;
}

static BOOL SZFE2EIsFriend(NSDictionary *row) {
    return [row[@"drop_label"] isKindOfClass:[NSString class]];
}

static NSDictionary *SZFE2EDetails(SZFE2EClient *client, NSString *conversationID) {
    NSString *details = [client subscribe:@"details" params:@{@"conversation_id" : conversationID}];
    __block NSDictionary *data = nil;
    SZFE2EWaitUntil(5, ^BOOL {
        data = [client dataFor:details];
        return data != nil;
    });
    [client intent:@"unsubscribe" fields:@{@"subscription" : details}];
    return data;
}

static BOOL SZFE2EAttestedHolderSteps(SZFE2EWorld *world, NSDictionary *hostEnv) {
    SZFE2EHelper *helperA = nil, *helperB = nil, *helperC = nil;
    SZFE2EClient *a = nil, *b = nil, *c = nil;
    NSString *listA = nil, *listB = nil, *listC = nil;
    if (!SZFE2EStartSingle(world, @"b", @"Ben", hostEnv, &helperB, &b, &listB)) return NO;
    NSString *held = SZFE2EReservedAndAttested(b, helperB);
    CHECK(held != nil, "Ben holds a reserved ID");
    // A second device holding the same ID that never reached the host: nothing attests it.
    NSDictionary *envC = @{@"SZFRIENDS_E2E_FRIENDS_ID" : held};
    if (!SZFE2EStartSingle(world, @"c", @"Cora", envC, &helperC, &c, &listC)) return NO;
    if (!SZFE2EStartSingle(world, @"a", @"Ana", hostEnv, &helperA, &a, &listA)) return NO;
    NSDictionary *reply = [a intent:@"add_by_id" fields:@{@"friends_id" : held}];
    CHECK([reply[@"ok"] boolValue], "add_by_id %@: %@", held, reply);
    CHECK(SZFE2EWaitUntil(25, ^BOOL {
              return SZFE2EWaitingRow([b dataFor:listB]) != nil && SZFE2EWaitingRow([c dataFor:listC]) != nil;
          }),
          "both holders received it: %@ / %@", [b dataFor:listB], [c dataFor:listC]);
    NSString *atB = SZFE2EWaitingRow([b dataFor:listB])[@"conversation_id"];
    NSString *atC = SZFE2EWaitingRow([c dataFor:listC])[@"conversation_id"];
    CHECK([[b intent:@"accept_request" fields:@{@"conversation_id" : atB}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              NSDictionary *ben = SZFE2ERowTitled([a dataFor:listA], @"Ben");
              return SZFE2EIsFriend(ben) && [ben[@"id_confirmed"] boolValue];
          }),
          "Ben's answer carried the host's word: confirmed: %@", [a dataFor:listA][@"rows"]);
    CHECK([[c intent:@"accept_request" fields:@{@"conversation_id" : atC}][@"ok"] boolValue]);
    // Cora's answer still gets in, but nothing vouches for it, so it waits for Ana (wave-4 re-check).
    if (!SZFE2EAcceptAnswer(a, listA, @"Cora")) return NO;
    NSDictionary *ben = SZFE2ERowTitled([a dataFor:listA], @"Ben"), *cora = SZFE2ERowTitled([a dataFor:listA], @"Cora");
    CHECK(![ben[@"conversation_id"] isEqual:cora[@"conversation_id"]], "two people, never merged");
    CHECK([ben[@"id_confirmed"] boolValue] && [ben[@"id_confirmed_label"] isKindOfClass:[NSString class]],
          "Ben's row is marked: %@", ben);
    CHECK(![cora[@"id_confirmed"] boolValue] && cora[@"id_confirmed_label"] == [NSNull null],
          "Cora's is not, though she holds the same ID: %@", cora);
    NSDictionary *benDetails = SZFE2EDetails(a, ben[@"conversation_id"]);
    CHECK([benDetails[@"friends_id"] isEqual:held] && [benDetails[@"id_confirmed"] boolValue],
          "Ben's details: %@", benDetails);
    NSDictionary *coraDetails = SZFE2EDetails(a, cora[@"conversation_id"]);
    CHECK(coraDetails != nil && ![coraDetails[@"id_confirmed"] boolValue], "Cora's details: %@", coraDetails);
    return YES;
}

// The holder (Ben, checked in) and a second device holding the same unreserved ID (Cora, never online) both answer
// Ana's Add by ID: Ben's row says the Friends server confirmed his ID, Cora's is a separate person and does not.
BOOL SZFE2EScenarioAttestedHolder(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2ELocalHost *host = [SZFE2ELocalHost startInWorld:world skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip attested holder: %s\n", why.UTF8String);
        return why != nil;
    }
    @try {
        return SZFE2EAttestedHolderSteps(world, host.helperEnvironment);
    } @finally {
        [host stop];
    }
}

static BOOL SZFE2ECopiedAttestationSteps(SZFE2EWorld *world, NSDictionary *hostEnv) {
    // Ben checks in once and leaves; his attestation is what someone who once received it could show as their own.
    SZFE2EHelper *helperB = nil, *helperA = nil;
    SZFE2EClient *b = nil, *a = nil;
    NSString *listB = nil, *listA = nil;
    if (!SZFE2EStartSingle(world, @"b", @"Ben", hostEnv, &helperB, &b, &listB)) return NO;
    NSString *held = SZFE2EReservedAndAttested(b, helperB);
    NSData *copied = [NSData dataWithContentsOfFile:SZFE2EAttestationPath(helperB)];
    CHECK(held != nil && copied.length > 0, "Ben's attestation");
    [b close];
    CHECK([helperB terminate], "Ben leaves");
    if (!SZFE2EStartSingle(world, @"a", @"Ana", hostEnv, &helperA, &a, &listA)) return NO;
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, NO);
    CHECK(rogue != nil);
    NSDictionary *reply = [a intent:@"add_by_id" fields:@{@"friends_id" : held}];
    NSString *asked = reply[@"result"][@"conversation_id"];
    CHECK(asked != nil, "add_by_id %@: %@", held, reply);
    SZFriendsHandshakeOptions *ik = SZFE2EOverheardAnswerOptions(rogue);
    CHECK(ik != nil);
    [rogue useFreshIdentity];
    SZFE2ERogueSession *copier = [rogue dial:rogue.hiddenEndpoint options:ik attestation:copied];
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return copier.closed; }) && !copier.established,
          "an answer showing Ben's attestation under another key is refused before any reply");
    SZFE2EPump(0.5);
    NSArray *rows = [a dataFor:listA][@"rows"];
    CHECK(rows.count == 1 && [rows.firstObject[@"conversation_id"] isEqual:asked] &&
              ![rows.firstObject[@"title"] isEqual:@"Rogue"],
          "nothing of it reached Ana's list: %@", rows);
    // The same listener lets an honest-looking answer in, so the refusal was the attestation's, not a dead endpoint;
    // two of them fit, so the refused one took no slot.
    NSMutableArray<SZFE2ERogueSession *> *plain = [NSMutableArray array];
    for (NSString *name in @[ @"Rogue", @"Rogue Two" ]) {
        [rogue useFreshIdentity];
        SZFE2ERogueSession *answer = [rogue dial:rogue.hiddenEndpoint options:ik];
        CHECK(SZFE2EWaitEstablished(answer), "%@ without an attestation is let in: %@", name, answer.closeError);
        CHECK([answer send:SZFE2EProfileFrame(name)]);
        [plain addObject:answer];
    }
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return SZFE2ERowTitled([a dataFor:listA], @"Rogue") && SZFE2ERowTitled([a dataFor:listA], @"Rogue Two");
          }),
          "both appear: %@", [a dataFor:listA][@"rows"]);
    for (NSString *name in @[ @"Rogue", @"Rogue Two" ]) {
        NSDictionary *row = SZFE2ERowTitled([a dataFor:listA], name);
        CHECK(![row[@"id_confirmed"] boolValue], "%@ is not confirmed: %@", name, row);
        NSDictionary *details = SZFE2EDetails(a, row[@"conversation_id"]);
        // Their PROFILE named no ID, and the ID Ana typed is not theirs to show.
        CHECK(details != nil && details[@"friends_id"] == [NSNull null] && ![details[@"id_confirmed"] boolValue],
              "%@ shows no Friends ID: %@", name, details);
    }
    [rogue stop];
    return YES;
}

// Someone shows Ben's genuine attestation as their own answer to Ana's Add by ID for his ID: refused. Answers without
// one get in as people of their own, unconfirmed, without the ID Ana typed.
BOOL SZFE2EScenarioCopiedAttestation(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2ELocalHost *host = [SZFE2ELocalHost startInWorld:world skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip copied attestation: %s\n", why.UTF8String);
        return why != nil;
    }
    @try {
        return SZFE2ECopiedAttestationSteps(world, host.helperEnvironment);
    } @finally {
        [host stop];
    }
}
