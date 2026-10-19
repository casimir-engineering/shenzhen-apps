// Add by ID answers: a request outlives its first answer until it expires, admits at most three distinct keys, and
// gives each key its own conversation (brief § Friends ID, unreserved duplicates nearby; security review, Add by ID).

#import "SZFriendsStoreTestSupport.h"

static SZFriendsIDRequestRecord *Request(NSString *conversationID, uint8_t token, NSDate *created) {
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = conversationID;
    request.targetFriendsID = @"orchid-summit";
    request.requestToken = SZFTBytes(token, 16);
    request.callbackSecret = SZFTBytes((uint8_t)(token + 100), 32);
    request.createdAt = created;
    request.expiresAt = [created dateByAddingTimeInterval:SZFriendsIDRequestLifetime];
    return request;
}

// An outgoing request by ID nobody has answered: no keys yet.
static void AddAskedRow(SZFriendsStore *store, NSString *conversationID) {
    SZFriendsPersonRecord *asked = [[SZFriendsPersonRecord alloc] init];
    asked.conversationID = conversationID;
    asked.friendsID = @"orchid-summit";
    asked.relation = SZFriendsRelationOutgoingRequest;
    asked.requestAt = [NSDate dateWithTimeIntervalSince1970:5000];
    asked.lastInteractionAt = asked.requestAt;
    SZFTExpect([store savePerson:asked error:NULL], @"asked row %@", conversationID);
}

static NSString *_Nullable Answer(SZFriendsStore *store, uint8_t token, uint8_t key, NSDate *now, NSError **error) {
    return [store conversationForIDRequestAnswerWithToken:SZFTBytes(token, 16) identityKey:SZFTBytes(key, 32)
                                                staticKey:SZFTBytes((uint8_t)(key + 1), 32) atDate:now error:error];
}

static void TestEachAnsweringKeyGetsItsOwnConversation(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"answers"));
    NSDate *now = [NSDate date];
    AddAskedRow(store, @"asked");
    SZFTExpect([store saveIDRequest:Request(@"asked", 1, now) error:NULL], @"request");
    SZFTExpect([store pendingIDRequestsAtDate:now].count == 1, @"pending before any answer");
    SZFTExpect([store idRequestWithToken:SZFTBytes(1, 16) admitsIdentityKey:SZFTBytes(10, 32) atDate:now],
               @"the token admits a first key");
    NSError *error = nil;
    NSString *first = Answer(store, 1, 10, now, &error);
    SZFTExpect([first isEqualToString:@"asked"], @"the first holder fills the request's row: %@ %@", first, error);
    SZFriendsPersonRecord *row = [store personWithConversationID:@"asked"];
    SZFTExpect([row.identityKey isEqualToData:SZFTBytes(10, 32)] && [row.staticKey isEqualToData:SZFTBytes(11, 32)],
               @"the row learned who answered");
    SZFTExpect([store pendingIDRequestsAtDate:now].count == 0, @"answered: no longer offered or advertised");
    SZFriendsIDRequestRecord *read = [store idRequestWithToken:SZFTBytes(1, 16) atDate:now];
    SZFTExpect(read.answeredAt && read.answeringKeyCount == 1, @"still there, answered once");
    SZFTExpect([Answer(store, 1, 10, now, NULL) isEqualToString:@"asked"] &&
                   [store idRequestWithToken:SZFTBytes(1, 16) atDate:now].answeringKeyCount == 1,
               @"the same key calling back again is the same conversation, counted once");
    // A second holder of the unreserved ID: a second conversation, never the first one's row.
    NSString *second = Answer(store, 1, 20, now, &error);
    SZFTExpect(second && ![second isEqualToString:@"asked"], @"a second key gets its own conversation: %@", error);
    SZFriendsPersonRecord *other = [store personWithConversationID:second];
    SZFTExpect([other.identityKey isEqualToData:SZFTBytes(20, 32)] &&
                   [other.friendsID isEqualToString:@"orchid-summit"] &&
                   other.relation == SZFriendsRelationOutgoingRequest &&
                   [other.requestAt isEqualToDate:[NSDate dateWithTimeIntervalSince1970:5000]],
               @"an outgoing request to the same ID, asked when the person asked");
    SZFTExpect([[store personWithConversationID:@"asked"].identityKey isEqualToData:SZFTBytes(10, 32)],
               @"the first person's conversation keeps the first key");
    NSString *third = Answer(store, 1, 30, now, NULL);
    SZFTExpect(third && ![third isEqualToString:second], @"a third key, a third conversation");
    SZFTExpect(![store idRequestWithToken:SZFTBytes(1, 16) admitsIdentityKey:SZFTBytes(40, 32) atDate:now],
               @"a fourth key is not admitted");
    SZFTExpect(!Answer(store, 1, 40, now, &error) && error.code == SZFriendsStoreErrorConstraint,
               @"nor recorded: %@", error);
    SZFTExpect([store personWithIdentityKey:SZFTBytes(40, 32)] == nil, @"no row for it");
    SZFTExpect([store idRequestWithToken:SZFTBytes(1, 16) admitsIdentityKey:SZFTBytes(20, 32) atDate:now],
               @"keys that answered still are");
    // A blocked person stays out, whatever token they present.
    SZFTAddPerson(store, @"kenji", 60, SZFriendsRelationBlocked, 1000);
    AddAskedRow(store, @"asked2");
    [store saveIDRequest:Request(@"asked2", 2, now) error:NULL];
    SZFTExpect(![store idRequestWithToken:SZFTBytes(2, 16) admitsIdentityKey:SZFTBytes(60, 32) atDate:now] &&
                   !Answer(store, 2, 60, now, &error) && error.code == SZFriendsStoreErrorInvalid, @"blocked");
    NSDate *later = [now dateByAddingTimeInterval:SZFriendsIDRequestLifetime + 1];
    SZFTExpect(![store idRequestWithToken:SZFTBytes(1, 16) admitsIdentityKey:SZFTBytes(10, 32) atDate:later] &&
                   !Answer(store, 1, 10, later, &error) && error.code == SZFriendsStoreErrorNotFound,
               @"an expired token admits nobody, not even an earlier key");
    SZFTExpect(![store conversationForIDRequestAnswerWithToken:SZFTBytes(1, 15) identityKey:SZFTBytes(10, 32)
                                                     staticKey:SZFTBytes(11, 32) atDate:now error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid, @"token length");
}

// "Add by ID never reuses a row whose identity key is set unless the same key answers."
static void TestARowWithAKeyIsReusedOnlyByThatKey(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"reuse"));
    NSDate *now = [NSDate date];
    SZFriendsPersonRecord *priya = SZFTAddPerson(store, @"priya", 70, SZFriendsRelationRemoved, 1000);
    priya.friendsID = @"orchid-summit";
    priya.relation = SZFriendsRelationOutgoingRequest; // asked again by ID
    [store savePerson:priya error:NULL];
    [store saveIDRequest:Request(@"priya", 3, now) error:NULL];
    NSError *error = nil;
    NSString *stranger = Answer(store, 3, 80, now, &error);
    SZFTExpect(stranger && ![stranger isEqualToString:@"priya"], @"another key never takes Priya's row: %@", error);
    SZFTExpect([[store personWithConversationID:@"priya"].identityKey isEqualToData:SZFTBytes(70, 32)],
               @"Priya keeps her key and history");
    SZFTExpect([Answer(store, 3, 70, now, &error) isEqualToString:@"priya"], @"Priya's own key gets her row: %@",
               error);
    SZFTExpect([store idRequestWithToken:SZFTBytes(3, 16) atDate:now].answeringKeyCount == 2, @"two keys answered");
}

static void TestAnsweredRequestsFreeTheirSlot(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"slots"));
    NSDate *now = [NSDate date];
    for (int i = 0; i < 6; i++) AddAskedRow(store, [NSString stringWithFormat:@"r%d", i]);
    for (int i = 0; i < 4; i++) {
        [store saveIDRequest:Request([NSString stringWithFormat:@"r%d", i], (uint8_t)(10 + i), now) error:NULL];
    }
    NSError *error = nil;
    SZFTExpect(![store saveIDRequest:Request(@"r4", 14, now) error:&error] &&
                   error.code == SZFriendsStoreErrorConstraint, @"four pending: a fifth waits");
    SZFTExpect(Answer(store, 10, 90, now, NULL) != nil, @"one is answered");
    SZFTExpect([store saveIDRequest:Request(@"r4", 14, now) error:&error], @"which frees its slot: %@", error);
    SZFTExpect([store idRequestWithToken:SZFTBytes(10, 16) atDate:now] != nil, @"the answered one still admits");
    // A new token for a conversation is a new request: the old token and its answers are gone. (r0 counts as pending
    // again then, so one of the four others is withdrawn first.)
    SZFTExpect([store deleteIDRequestForConversation:@"r4" error:NULL], @"withdraw one");
    SZFTExpect([store saveIDRequest:Request(@"r0", 20, now) error:&error], @"asked again: %@", error);
    SZFTExpect(![store idRequestWithToken:SZFTBytes(10, 16) atDate:now], @"the old token admits nobody");
    SZFriendsIDRequestRecord *fresh = [store idRequestWithToken:SZFTBytes(20, 16) atDate:now];
    SZFTExpect(fresh.answeringKeyCount == 0 && !fresh.answeredAt, @"and the new one starts unanswered");
    SZFTExpect([SZFTScalar(store, @"SELECT count(*) FROM id_request_answers", @[]) integerValue] == 0,
               @"no answers are left behind");
    SZFTExpect([store deleteIDRequestForConversation:@"r0" error:NULL] &&
                   ![store idRequestWithToken:SZFTBytes(20, 16) atDate:now], @"withdrawn");
}

static NSUInteger PeopleCount(SZFriendsStore *store) {
    return [SZFTScalar(store, @"SELECT count(*) FROM friends", @[]) unsignedIntegerValue];
}

// Wave-3 re-check, key change handling: add_by_id once flipped Priya's removed row, matched only by the Friends ID she
// last told us, back to a request, which let her old key in by IK before anyone answered.
static void TestStartIDRequestNeverRevivesAKeyedRow(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"start"));
    NSDate *now = [NSDate date];
    SZFriendsPersonRecord *priya = SZFTAddPerson(store, @"priya", 70, SZFriendsRelationRemoved, 1000);
    priya.friendsID = @"orchid-summit";
    [store savePerson:priya error:NULL];
    NSError *error = nil;
    SZFriendsIDRequestRecord *request = Request(@"", 4, now);
    NSString *asked = [store startIDRequest:request error:&error];
    SZFTExpect(asked && ![asked isEqualToString:@"priya"] && [request.conversationID isEqualToString:asked],
               @"a fresh row, never Priya's: %@ %@", asked, error);
    SZFriendsPersonRecord *row = [store personWithConversationID:asked];
    SZFTExpect(!row.identityKey && !row.staticKey && row.relation == SZFriendsRelationOutgoingRequest &&
                   [row.friendsID isEqualToString:@"orchid-summit"] && !row.requestFoundNearby &&
                   fabs([row.requestAt timeIntervalSinceDate:now]) < 0.001, @"a keyless 'Request sent' row");
    SZFTExpect([store personWithConversationID:@"priya"].relation == SZFriendsRelationRemoved,
               @"Priya stays removed until her own key answers");
    SZFTExpect([[store idRequestWithToken:SZFTBytes(4, 16) atDate:now].conversationID isEqualToString:asked],
               @"the request names the fresh row");
    // Withdrawn and asked again: the keyless row comes back rather than a second one.
    row.relation = SZFriendsRelationRemoved;
    [store savePerson:row error:NULL];
    [store deleteIDRequestForConversation:asked error:NULL];
    NSString *again = [store startIDRequest:Request(@"", 5, now) error:&error];
    SZFTExpect([again isEqualToString:asked] && PeopleCount(store) == 2, @"the same keyless row: %@ %@", again, error);
    // Four pending: a fifth is refused and leaves no row behind (the helper answers rate_limited).
    for (uint8_t i = 0; i < 3; i++) {
        SZFriendsIDRequestRecord *other = Request(@"", (uint8_t)(20 + i), now);
        other.targetFriendsID = [NSString stringWithFormat:@"maple-%d", i];
        SZFTExpect([store startIDRequest:other error:NULL] != nil, @"request %d", i);
    }
    SZFriendsIDRequestRecord *fifth = Request(@"", 30, now);
    fifth.targetFriendsID = @"tulip-canyon";
    NSUInteger before = PeopleCount(store);
    SZFTExpect(![store startIDRequest:fifth error:&error] && error.code == SZFriendsStoreErrorConstraint &&
                   PeopleCount(store) == before && fifth.conversationID.length == 0,
               @"a fifth: Constraint and no orphan row (%lu people): %@", (unsigned long)PeopleCount(store), error);
    fifth.targetFriendsID = @"";
    SZFTExpect(![store startIDRequest:fifth error:&error] && error.code == SZFriendsStoreErrorInvalid, @"no ID");
}

// The same-key reuse rule: Priya's own key answering the fresh row's request gets her own row back, and the empty
// "Request sent" row folds into it with what was queued there, so she is one row and her answer lands.
static void TestTheSameKeyTakesItsRowBack(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"reclaim"));
    NSDate *now = [NSDate date];
    SZFriendsPersonRecord *priya = SZFTAddPerson(store, @"priya", 70, SZFriendsRelationRemoved, 1000);
    priya.friendsID = @"orchid-summit";
    priya.comparisonCode = @"418270";
    priya.verified = YES;
    priya.autoAccept = YES;
    [store savePerson:priya error:NULL];
    SZFTExpect([store insertItem:SZFTMessage(@"priya", @"m1", @"from before", 900, SZFriendsDirectionIncoming)
                           error:NULL], @"Priya's history");
    // As the helper makes it: a keyless row, its request, and the outbox entry offering it to devices nearby.
    AddAskedRow(store, @"asked");
    SZFTExpect([store saveIDRequest:Request(@"asked", 6, now) error:NULL], @"request");
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsNewIdentifier();
    entry.conversationID = @"asked";
    entry.kind = SZFriendsOutboxKindRequest;
    SZFTExpect([outbox enqueue:entry error:NULL], @"queued request");
    NSError *error = nil;
    NSString *answered = Answer(store, 6, 70, now, &error);
    SZFTExpect([answered isEqualToString:@"priya"], @"Priya's key gets Priya's row: %@ %@", answered, error);
    SZFTExpect([store personWithConversationID:@"asked"] == nil, @"the empty row folded into hers");
    SZFriendsPersonRecord *back = [store personWithConversationID:@"priya"];
    SZFTExpect(back.relation == SZFriendsRelationOutgoingRequest &&
                   [back.requestAt isEqualToDate:[NSDate dateWithTimeIntervalSince1970:5000]],
               @"an outgoing request again, asked when the person asked, so her ACCEPT lands");
    SZFTExpect(!back.comparisonCode && !back.autoAccept, @"nothing her old friendship earned comes back");
    SZFTExpect([[store itemsInConversation:@"priya" beforeItemID:nil limit:5 hasEarlier:NULL] count] == 1,
               @"her history stays");
    SZFTExpect([[outbox entryWithID:entry.entryID].conversationID isEqualToString:@"priya"],
               @"the queued request moved with the row, so her answer acknowledges it");
    SZFTExpect([[store idRequestWithToken:SZFTBytes(6, 16) atDate:now].conversationID isEqualToString:@"priya"] &&
                   [store pendingIDRequestsAtDate:now].count == 0, @"the request is hers now, and answered");
    SZFTExpect([Answer(store, 6, 70, now, NULL) isEqualToString:@"priya"], @"calling back again: still hers");
    NSString *other = Answer(store, 6, 80, now, &error);
    SZFTExpect(other && ![other isEqualToString:@"priya"] &&
                   [store personWithConversationID:other].relation == SZFriendsRelationOutgoingRequest,
               @"another key answering still gets a row of its own: %@", error);
    SZFTExpect([[store personWithConversationID:@"priya"].identityKey isEqualToData:SZFTBytes(70, 32)],
               @"and never Priya's");
}

// Anyone who hears a broadcast can answer it. Priya, removed, answering a request for someone else's ID is not her
// row coming back: she stays removed and the request's row stays as it was. The host's word that she holds the ID
// (an attested answer) is: her Friends ID had simply changed since.
static void TestOnlyAHolderOfTheIDTakesItsRowBack(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"reclaim-other"));
    NSDate *now = [NSDate date];
    SZFriendsPersonRecord *priya = SZFTAddPerson(store, @"priya", 70, SZFriendsRelationRemoved, 1000);
    priya.friendsID = @"maple-harbor";
    [store savePerson:priya error:NULL];
    AddAskedRow(store, @"asked"); // orchid-summit
    [store saveIDRequest:Request(@"asked", 8, now) error:NULL];
    NSError *error = nil;
    SZFTExpect([Answer(store, 8, 70, now, &error) isEqualToString:@"priya"], @"her own conversation: %@", error);
    SZFTExpect([store personWithConversationID:@"priya"].relation == SZFriendsRelationRemoved &&
                   [store personWithConversationID:@"asked"] != nil &&
                   [[store idRequestWithToken:SZFTBytes(8, 16) atDate:now].conversationID isEqualToString:@"asked"],
               @"still removed, and the request row untouched");
    AddAskedRow(store, @"asked2");
    [store saveIDRequest:Request(@"asked2", 9, now) error:NULL];
    NSString *attested = [store conversationForIDRequestAnswerWithToken:SZFTBytes(9, 16) identityKey:SZFTBytes(70, 32)
                                                              staticKey:SZFTBytes(71, 32) attested:YES atDate:now
                                                                  error:&error];
    SZFTExpect([attested isEqualToString:@"priya"] && [store personWithConversationID:@"asked2"] == nil &&
                   [store personWithConversationID:@"priya"].relation == SZFriendsRelationOutgoingRequest,
               @"attested as the holder: her row comes back: %@", error);
}

// Wave-3 re-check, Add by ID: three throwaway keys from one stranger used every answer slot, so the real holder's
// callback was refused. With attestations, keys without one share two slots and the third waits for the holder.
static void TestTheLastAnswerWaitsForAnAttestedHolder(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"attested-slot"));
    NSDate *now = [NSDate date];
    AddAskedRow(store, @"asked");
    [store saveIDRequest:Request(@"asked", 7, now) error:NULL];
    NSData *token = SZFTBytes(7, 16);
    NSError *error = nil;
    for (uint8_t key = 10; key <= 20; key += 10) {
        SZFTExpect([store idRequestWithToken:token admitsIdentityKey:SZFTBytes(key, 32) attested:NO atDate:now] &&
                       [store conversationForIDRequestAnswerWithToken:token identityKey:SZFTBytes(key, 32)
                                                            staticKey:SZFTBytes(key + 1, 32) attested:NO atDate:now
                                                                error:&error],
                   @"unattested answer %d: %@", key, error);
    }
    SZFTExpect(![store idRequestWithToken:token admitsIdentityKey:SZFTBytes(30, 32) attested:NO atDate:now],
               @"a third key without an attestation is not admitted");
    SZFTExpect(![store conversationForIDRequestAnswerWithToken:token identityKey:SZFTBytes(30, 32)
                                                     staticKey:SZFTBytes(31, 32) attested:NO atDate:now error:&error] &&
                   error.code == SZFriendsStoreErrorConstraint, @"nor recorded: %@", error);
    SZFTExpect([store idRequestWithToken:token admitsIdentityKey:SZFTBytes(10, 32) attested:NO atDate:now],
               @"a key that answered is still let back in");
    SZFTExpect([store idRequestWithToken:token admitsIdentityKey:SZFTBytes(40, 32) attested:YES atDate:now],
               @"the holder the host vouches for is");
    NSString *holder = [store conversationForIDRequestAnswerWithToken:token identityKey:SZFTBytes(40, 32)
                                                            staticKey:SZFTBytes(41, 32) attested:YES atDate:now
                                                                error:&error];
    SZFTExpect(holder != nil, @"and gets a row: %@", error);
    SZFTExpect(![store idRequestWithToken:token admitsIdentityKey:SZFTBytes(50, 32) attested:YES atDate:now],
               @"three answers in all, attested or not");
    NSNumber *attested = SZFTScalar(store, @"SELECT count(*) FROM id_request_answers WHERE attested = 1", @[]);
    SZFTExpect(attested.integerValue == 1, @"which answers were attested is recorded");
}

void SZFTRunAddByIDTests(void) {
    TestEachAnsweringKeyGetsItsOwnConversation();
    TestARowWithAKeyIsReusedOnlyByThatKey();
    TestAnsweredRequestsFreeTheirSlot();
    TestStartIDRequestNeverRevivesAKeyedRow();
    TestTheSameKeyTakesItsRowBack();
    TestOnlyAHolderOfTheIDTakesItsRowBack();
    TestTheLastAnswerWaitsForAnAttestedHolder();
}
