// Schema v4 and the wave-4 re-check in the store: what the assistant sent stays marked on both sides, an unconfirmed
// Add by ID answer keeps the ID it was for only while it waits, and requests we sent that nobody can answer any more
// lapse instead of keeping a key that may reach our hidden listener for ever.

#import "SZFriendsStoreTestSupport.h"

static const NSTimeInterval SZFTDay = 24 * 3600;

static void TestAssistantMarks(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"assistant"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsItemRecord *sent = SZFTMessage(@"mei", @"m_out", @"Pages 3–5 changed.", 2000,
                                            SZFriendsDirectionOutgoing);
    sent.viaAssistant = YES;
    SZFTExpect([store insertItem:sent error:NULL], @"insert");
    SZFTExpect([store itemWithID:@"m_out" inConversation:@"mei"].viaAssistant, @"kept with the message");
    SZFTExpect([store insertItem:SZFTMessage(@"mei", @"m_in", @"Thanks", 2100, SZFriendsDirectionIncoming) error:NULL],
               @"insert");
    SZFTExpect(![store itemWithID:@"m_in" inConversation:@"mei"].viaAssistant, @"typed by Mei herself");
    SZFTExpect([store markItemSentByAssistant:@"m_in" inConversation:@"mei" error:NULL] &&
                   [store markItemSentByAssistant:@"m_in" inConversation:@"mei" error:NULL] &&
                   [store itemWithID:@"m_in" inConversation:@"mei"].viaAssistant,
               @"an incoming file or message marked afterwards, twice is harmless");
    NSError *error = nil;
    SZFTExpect(![store markItemSentByAssistant:@"m_in" inConversation:@"other" error:&error] &&
                   error.code == SZFriendsStoreErrorNotFound,
               @"never another conversation's item: %@", error);
    SZFriendsItemRecord *event = SZFTMessage(@"mei", @"e_1", nil, 2200, SZFriendsDirectionOutgoing);
    event.kind = SZFriendsItemKindEvent;
    event.eventKind = @"verified";
    event.viaAssistant = YES;
    SZFTExpect([store insertItem:event error:NULL] && ![store itemWithID:@"e_1" inConversation:@"mei"].viaAssistant,
               @"an event is never the assistant's");
}

static void TestUnconfirmedAnswerID(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"unconfirmed"));
    SZFriendsPersonRecord *answer = SZFTAddPerson(store, @"answer", 2, SZFriendsRelationIncomingRequest, 1000);
    answer.unconfirmedAnswerID = @"tulip-canyon";
    SZFTExpect([store savePerson:answer error:NULL], @"save");
    SZFTExpect([[store personWithConversationID:@"answer"].unconfirmedAnswerID isEqualToString:@"tulip-canyon"],
               @"kept while it waits");
    answer.relation = SZFriendsRelationFriend; // the person accepted; the stale copy still carries the ID
    SZFTExpect([store savePerson:answer error:NULL] && ![store personWithConversationID:@"answer"].unconfirmedAnswerID,
               @"accepted: the card's words go");
    answer.relation = SZFriendsRelationIncomingRequest;
    answer.unconfirmedAnswerID = nil;
    SZFTExpect([store savePerson:answer error:NULL] && ![store personWithConversationID:@"answer"].unconfirmedAnswerID,
               @"a later request of theirs is an ordinary request");
}

// An Add by ID request of ours, created `age` ago, answered by `key` (0: nobody yet) on conversation `answered`.
static NSData *AskByID(SZFriendsStore *store, NSString *friendsID, NSTimeInterval age, uint8_t key,
                       NSString *answered) {
    NSDate *created = [NSDate dateWithTimeIntervalSinceNow:-age];
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.targetFriendsID = friendsID;
    request.requestToken = SZFTRandomData(16);
    request.callbackSecret = SZFTRandomData(32);
    request.createdAt = created;
    request.expiresAt = [created dateByAddingTimeInterval:SZFriendsIDRequestLifetime];
    SZFTExpect([store startIDRequest:request error:NULL] != nil, @"ask %@", friendsID);
    if (key) {
        // Answered while the request was live: the answer is recorded at that moment.
        NSString *row = [store conversationForIDRequestAnswerWithToken:request.requestToken
                                                            identityKey:SZFTBytes(key, 32)
                                                              staticKey:SZFTBytes(key + 100, 32)
                                                               attested:NO
                                                                 atDate:[created dateByAddingTimeInterval:60]
                                                                  error:NULL];
        SZFTExpect([row isEqualToString:answered] || answered.length == 0, @"answer row %@", row);
    }
    return request.requestToken;
}

// Wave-4 re-check: an outgoing request admitted IK for ever. Now each kind ends: a nearby request after 7 days, an Add
// by ID row when the request that names it or admitted its key expires.
static void TestOutgoingRequestsLapse(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"outgoing"));
    NSDate *now = [NSDate date];
    // Nearby requests: one asked 8 days ago with nothing else, one 8 days ago with history (a former friend), one
    // 2 days ago still waiting.
    NSArray *nearby = @[ @[ @"old", @11, @8 ], @[ @"former", @12, @8 ], @[ @"recent", @13, @2 ] ];
    for (NSArray *row in nearby) {
        SZFriendsPersonRecord *person = SZFTAddPerson(store, row[0], (uint8_t)[row[1] intValue],
                                                      SZFriendsRelationOutgoingRequest, 1000);
        person.requestFoundNearby = YES;
        person.requestAt = [now dateByAddingTimeInterval:-[row[2] doubleValue] * SZFTDay];
        person.relation = SZFriendsRelationRemoved;
        [store savePerson:person error:NULL]; // a new request starts its clock at requestAt
        person.relation = SZFriendsRelationOutgoingRequest;
        SZFTExpect([store savePerson:person error:NULL], @"%@", row[0]);
    }
    SZFTExpect([store insertItem:SZFTMessage(@"former", @"m_old", @"from when we were friends", 500,
                                             SZFriendsDirectionIncoming)
                           error:NULL],
               @"history");
    // Add by ID: one whose request expired with nobody answering (a keyless row), one answered by a key whose request
    // has since expired, and one answered yesterday, still within its request's week.
    AskByID(store, @"expired-nobody", 8 * SZFTDay, 0, @"");
    AskByID(store, @"expired-answered", 8 * SZFTDay, 21, @"");
    AskByID(store, @"live-answered", 1 * SZFTDay, 22, @"");
    SZFTExpect([store identityKeyAnswersUnexpiredIDRequest:SZFTBytes(22, 32) atDate:now] &&
                   ![store identityKeyAnswersUnexpiredIDRequest:SZFTBytes(21, 32) atDate:now],
               @"IK stays open only while the request that admitted the key lasts");
    NSError *error = nil;
    NSArray<SZFriendsPersonRecord *> *lapsed = [store expireOutgoingRequestsAtDate:now error:&error];
    NSMutableSet *ids = [NSMutableSet set];
    for (SZFriendsPersonRecord *person in lapsed) [ids addObject:person.friendsID ?: person.conversationID];
    SZFTExpect([ids isEqual:([NSSet setWithArray:@[ @"old", @"former", @"expired-nobody", @"expired-answered" ]])],
               @"lapsed: %@ (%@)", ids, error);
    SZFTExpect(![store personWithConversationID:@"old"], @"nothing worth keeping: gone");
    SZFTExpect([store personWithConversationID:@"former"].relation == SZFriendsRelationRemoved &&
                   [store itemWithID:@"m_old" inConversation:@"former"] != nil,
               @"a former friend's history stays, as Removed");
    SZFTExpect([store personWithConversationID:@"recent"].relation == SZFriendsRelationOutgoingRequest,
               @"two days: still waiting");
    NSMutableArray<NSString *> *listed = [NSMutableArray array];
    for (SZFriendsPersonRecord *person in store.peopleByLatestInteraction)
        if (person.friendsID) [listed addObject:person.friendsID];
    SZFTExpect([listed isEqual:@[ @"live-answered" ]], @"only the answer within its week waits: %@", listed);
    SZFTExpect([store expireOutgoingRequestsAtDate:now error:NULL].count == 0, @"nothing more to lapse");
}

void SZFTRunLapseTests(void) {
    TestAssistantMarks();
    TestUnconfirmedAnswerID();
    TestOutgoingRequestsLapse();
}
