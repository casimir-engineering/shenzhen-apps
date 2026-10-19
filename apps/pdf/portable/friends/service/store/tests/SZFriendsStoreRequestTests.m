// Waiting requests and Friends ID attestations (schema v3): when a request began and that asking again cannot move it,
// unanswered requests lapsing after 14 days, and the host's confirmation of an ID, theirs and ours.

#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static NSDate *At(NSTimeInterval seconds) { return [NSDate dateWithTimeIntervalSince1970:seconds]; }

// Someone whose request arrived at `askedAt`: requestAt is set on the first save, which is when a request begins.
static SZFriendsPersonRecord *Asking(SZFriendsStore *store, NSString *conversationID, uint8_t key,
                                     NSTimeInterval askedAt) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    person.identityKey = SZFTBytes(key, 32);
    person.relation = SZFriendsRelationIncomingRequest;
    person.requestAt = At(askedAt);
    person.lastInteractionAt = At(askedAt);
    SZFTExpect([store savePerson:person error:NULL], @"asking %@", conversationID);
    return person;
}

// An Add by ID nobody has answered: a row with no key.
static void AddAskedRowWithoutKey(SZFriendsStore *store) {
    SZFriendsPersonRecord *asked = [[SZFriendsPersonRecord alloc] init];
    asked.conversationID = @"asked";
    asked.friendsID = @"tulip-canyon";
    asked.relation = SZFriendsRelationOutgoingRequest;
    SZFTExpect([store savePerson:asked error:NULL], @"asked row");
}

// Wave-3 re-check, key policy: the helper accepts IK from a requester only for hours after the request. If asking
// again restarted that clock, anyone could keep it open for good by asking every few hours.
static void TestARepeatedRequestKeepsItsStart(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"since"));
    SZFTAddPerson(store, @"lena", 3, SZFriendsRelationIncomingRequest, 1000);
    SZFriendsPersonRecord *lena = [store personWithConversationID:@"lena"];
    SZFTExpect(fabs(lena.pendingRequestSince.timeIntervalSinceNow) < 5, @"no requestAt: it began when it was saved");
    lena.requestAt = At(2000);
    [store savePerson:lena error:NULL];
    SZFTExpect(fabs(lena.pendingRequestSince.timeIntervalSinceNow) < 5, @"still waiting: the start stays");
    Asking(store, @"olu", 5, 3000);
    SZFriendsPersonRecord *olu = [store personWithConversationID:@"olu"];
    SZFTExpect([olu.pendingRequestSince isEqualToDate:At(3000)], @"began when asked: %@", olu.pendingRequestSince);
    olu.requestAt = At(9000); // the same request in a new session (+Inbound)
    olu.pendingRequestSince = At(9000);
    SZFTExpect([store savePerson:olu error:NULL], @"asked again");
    olu = [store personWithConversationID:@"olu"];
    SZFTExpect([olu.requestAt isEqualToDate:At(9000)] && [olu.pendingRequestSince isEqualToDate:At(3000)],
               @"the card's time moves, the start never does: %@", olu.pendingRequestSince);
    olu.relation = SZFriendsRelationFriend;
    [store savePerson:olu error:NULL];
    SZFTExpect([store personWithConversationID:@"olu"].pendingRequestSince == nil, @"answered: nothing waits");
    olu.relation = SZFriendsRelationIncomingRequest;
    olu.requestAt = At(12000);
    [store savePerson:olu error:NULL];
    SZFTExpect([[store personWithConversationID:@"olu"].pendingRequestSince isEqualToDate:At(12000)],
               @"a new request after that begins afresh");
    olu.relation = SZFriendsRelationOutgoingRequest;
    olu.requestAt = At(13000);
    [store savePerson:olu error:NULL];
    SZFTExpect([[store personWithConversationID:@"olu"].pendingRequestSince isEqualToDate:At(13000)],
               @"and so does one in the other direction");
    SZFriendsPersonRecord *kenji = SZFTAddPerson(store, @"kenji", 7, SZFriendsRelationRemoved, 1000);
    kenji.relation = SZFriendsRelationIncomingRequest;
    kenji.requestAt = [NSDate dateWithTimeIntervalSinceNow:400 * 24 * 3600];
    [store savePerson:kenji error:NULL];
    SZFTExpect([store personWithConversationID:@"kenji"].pendingRequestSince.timeIntervalSinceNow < 5,
               @"a request dated in the future starts now, so it cannot outlast its lifetime");
}

static void TestUnansweredRequestsLapseAfterFourteenDays(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"lapse"));
    // All in the past: a request dated after its save starts at the save (TestARepeatedRequestKeepsItsStart).
    const NSTimeInterval day = 24 * 3600, asked = floor(NSDate.date.timeIntervalSince1970) - 20 * day;
    // A stranger who asked during our visible minutes, with their photo.
    NSString *pictures = [store.stateDirectory stringByAppendingPathComponent:@"pictures"];
    [NSFileManager.defaultManager createDirectoryAtPath:pictures withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    NSString *photo = [pictures stringByAppendingPathComponent:@"stranger.jpg"];
    [SZFTRandomData(100) writeToFile:photo atomically:NO];
    SZFriendsPersonRecord *lena = Asking(store, @"lena", 3, asked);
    lena.picture = [SZFriendsPicture imageAtPath:photo sha256:SZFTBytes(1, 32)];
    lena.callbackToken = SZFTBytes(4, 16);
    lena.callbackSecret = SZFTBytes(5, 32);
    lena.requestAt = At(asked + 13 * day); // asking again a day before it lapses does not extend it
    [store savePerson:lena error:NULL];
    // A former friend asking again: their history stays.
    Asking(store, @"kenji", 7, asked);
    SZFriendsItemRecord *before = SZFTMessage(@"kenji", @"k1", @"from when we were friends", asked - 100,
                                              SZFriendsDirectionIncoming);
    SZFTExpect([store insertItem:before error:NULL], @"Kenji's history");
    SZFriendsPersonRecord *kenji = [store personWithConversationID:@"kenji"];
    kenji.callbackToken = SZFTBytes(8, 16);
    [store savePerson:kenji error:NULL];
    Asking(store, @"olu", 9, asked + 10 * day); // asked later: still has time
    SZFTAddPerson(store, @"mei", 11, SZFriendsRelationFriend, asked - 30 * day);
    NSError *error = nil;
    NSArray *none = [store expireIncomingRequestsAtDate:At(asked + 14 * day - 1) error:&error];
    SZFTExpect(none && none.count == 0 && [store personWithConversationID:@"lena"], @"not yet: %@", error);
    NSArray<SZFriendsPersonRecord *> *lapsed = [store expireIncomingRequestsAtDate:At(asked + 14 * day) error:&error];
    NSArray *ids = [[lapsed valueForKey:@"conversationID"] sortedArrayUsingSelector:@selector(compare:)];
    SZFTExpect([ids isEqual:(@[ @"kenji", @"lena" ])], @"14 days after asking: %@ %@", ids, error);
    SZFTExpect([store personWithConversationID:@"lena"] == nil && [store personWithIdentityKey:SZFTBytes(3, 32)] == nil,
               @"the stranger's row and key are gone");
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:photo], @"and their photo");
    kenji = [store personWithConversationID:@"kenji"];
    SZFTExpect(kenji.relation == SZFriendsRelationRemoved && !kenji.pendingRequestSince && !kenji.callbackToken &&
                   [[store itemsInConversation:@"kenji" beforeItemID:nil limit:5 hasEarlier:NULL] count] == 1,
               @"the former friend is back to removed, history kept");
    SZFTExpect([store personWithConversationID:@"olu"].relation == SZFriendsRelationIncomingRequest &&
                   [store personWithConversationID:@"mei"].relation == SZFriendsRelationFriend,
               @"a newer request and a friend are untouched");
    SZFTExpect([[store expireIncomingRequestsAtDate:At(asked + 14 * day) error:NULL] count] == 0, @"once only");
    // A photo another row still shows stays.
    NSString *shared = [pictures stringByAppendingPathComponent:@"shared.jpg"];
    [SZFTRandomData(100) writeToFile:shared atomically:NO];
    for (NSString *who in @[ @"priya", @"ana" ]) {
        SZFriendsPersonRecord *person = Asking(store, who, [who isEqual:@"priya"] ? 13 : 15, asked);
        person.picture = [SZFriendsPicture imageAtPath:shared sha256:SZFTBytes(2, 32)];
        if ([who isEqual:@"ana"]) person.relation = SZFriendsRelationFriend;
        [store savePerson:person error:NULL];
    }
    NSArray *later = [store expireIncomingRequestsAtDate:At(asked + 15 * day) error:&error];
    SZFTExpect([[later valueForKey:@"conversationID"] isEqual:@[ @"priya" ]] &&
                   [NSFileManager.defaultManager fileExistsAtPath:shared],
               @"a photo still in use stays: %@ %@", [later valueForKey:@"conversationID"], error);
}

static void TestTheirFriendsIDConfirmedByTheHost(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"attested"));
    SZFriendsPersonRecord *mei = SZFTAddPerson(store, @"mei", 1, SZFriendsRelationOutgoingRequest, 1000);
    mei.friendsID = @"tulip-canyon"; // what her PROFILE claimed
    [store savePerson:mei error:NULL];
    SZFTExpect(![store personWithConversationID:@"mei"].friendsIDConfirmed, @"self-asserted is not confirmed");
    NSData *proof = SZFTBytes(0xA5, 96);
    NSError *error = nil;
    SZFTExpect([store confirmFriendsID:@"tulip-canyon" attestation:proof day:@"2026-10-13" forConversation:@"mei"
                                 error:&error], @"confirm: %@", error);
    mei = [store personWithConversationID:@"mei"];
    SZFTExpect(mei.friendsIDConfirmed && [mei.friendsIDAttestation isEqualToData:proof] &&
                   [mei.friendsIDAttestationDay isEqualToString:@"2026-10-13"], @"confirmed, with what proved it");
    SZFriendsPersonRecord *stale = [mei copy];
    stale.friendsIDConfirmed = NO;
    stale.friendsIDAttestation = nil;
    SZFTExpect([store savePerson:stale error:NULL] && [store personWithConversationID:@"mei"].friendsIDConfirmed,
               @"a plain save neither sets nor clears it");
    stale.friendsIDConfirmed = YES;
    stale.friendsID = @"maple-harbor"; // a later PROFILE naming another ID
    [store savePerson:stale error:NULL];
    mei = [store personWithConversationID:@"mei"];
    SZFTExpect(!mei.friendsIDConfirmed && !mei.friendsIDAttestation && !mei.friendsIDAttestationDay,
               @"another ID is not what the host vouched for");
    SZFTExpect([store confirmFriendsID:@"tulip-canyon" attestation:proof day:@"2026-10-14" forConversation:@"mei"
                                 error:NULL] &&
                   [[store personWithConversationID:@"mei"].friendsID isEqualToString:@"tulip-canyon"],
               @"the host's word replaces the claim");
    SZFTExpect([store clearFriendsIDConfirmationForConversation:@"mei" error:NULL] &&
                   ![store personWithConversationID:@"mei"].friendsIDConfirmed, @"cleared");
    // Shapes the store checks; the signature is the helper's.
    AddAskedRowWithoutKey(store);
    NSArray *bad = @[
        @[ @"tulip-canyon", proof, @"2026-10-13", @"asked" ], @[ @"", proof, @"2026-10-13", @"mei" ],
        @[ @"tulip-canyon", [NSData data], @"2026-10-13", @"mei" ],
        @[ @"tulip-canyon", SZFTBytes(1, SZFriendsAttestationMaxLength + 1), @"2026-10-13", @"mei" ],
        @[ @"tulip-canyon", proof, @"2026-1-13", @"mei" ], @[ @"tulip-canyon", proof, @"13/10/2026", @"mei" ],
    ];
    for (NSArray *c in bad) {
        SZFTExpect(![store confirmFriendsID:c[0] attestation:c[1] day:c[2] forConversation:c[3] error:&error] &&
                       error.code == SZFriendsStoreErrorInvalid, @"refused: %@ %@ (%@)", c[0], c[2], error);
    }
    SZFTExpect(![store confirmFriendsID:@"tulip-canyon" attestation:proof day:@"2026-10-13" forConversation:@"ghost"
                                  error:&error] && error.code == SZFriendsStoreErrorNotFound, @"unknown person");
}

static void TestOurOwnAttestation(void) {
    NSString *directory = SZFTTemporaryDirectory(@"own");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTExpect(!store.friendsIDAttestation && !store.friendsIDAttestationDay, @"none before a check-in");
    NSData *proof = SZFTBytes(0x5A, 96);
    NSError *error = nil;
    SZFTExpect(![store saveFriendsIDAttestation:proof day:@"2026-10-13" forFriendsID:@"maple-river" error:&error] &&
                   error.code == SZFriendsStoreErrorStale, @"no ID yet: nothing to attach it to (%@)", error);
    store.friendsID = @"maple-river";
    SZFTExpect(![store saveFriendsIDAttestation:proof day:@"2026-10-13" forFriendsID:@"maple-harbor" error:&error] &&
                   error.code == SZFriendsStoreErrorStale, @"a reply about another ID is refused");
    SZFTExpect([store saveFriendsIDAttestation:proof day:@"2026-10-13" forFriendsID:@"maple-river" error:&error],
               @"saved: %@", error);
    [store close];
    store = SZFTOpenStore(directory);
    SZFTExpect([store.friendsIDAttestation isEqualToData:proof] &&
                   [store.friendsIDAttestationDay isEqualToString:@"2026-10-13"], @"kept across restarts");
    store.friendsID = @"maple-harbor"; // renamed after a collision
    SZFTExpect(!store.friendsIDAttestation && !store.friendsIDAttestationDay, @"the old ID's attestation is void");
    SZFTExpect(![store saveFriendsIDAttestation:proof day:@"2026-13" forFriendsID:@"maple-harbor" error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid, @"shape");
    SZFTExpect([store saveFriendsIDAttestation:proof day:@"2026-10-14" forFriendsID:@"maple-harbor" error:NULL],
               @"the new ID's");
    SZFTExpect([store deleteEverythingExceptReceivedFilesWithError:NULL] && !store.friendsIDAttestation,
               @"Reset forgets it");
}

void SZFTRunRequestTests(void) {
    TestARepeatedRequestKeepsItsStart();
    TestUnansweredRequestsLapseAfterFourteenDays();
    TestTheirFriendsIDConfirmedByTheHost();
    TestOurOwnAttestation();
}
