// Outbox: the whole state machine, persistence, idempotent intents, crash recovery and the 30-day expiry.

#import "SZFriendsStoreTestSupport.h"

static const SZFriendsOutboxState Q = SZFriendsOutboxStateQueued, C = SZFriendsOutboxStateConnecting,
                                  S = SZFriendsOutboxStateSending, D = SZFriendsOutboxStateDelivered,
                                  F = SZFriendsOutboxStateFailed;

static void TestStateMachineExhaustively(void) {
    // Rows: Queued, Connecting, Sending, Delivered, Failed. Columns: the events in SZFriendsOutboxEvent order:
    // RouteAvailable, SessionEstablished, Written, Acknowledged, SessionLost, Refused, SourceMissing, Retry, Expired.
    const SZFriendsOutboxState expected[5][9] = {
        {C, S, S, D, Q, F, F, Q, F},
        {C, S, S, D, Q, F, F, C, F},
        {S, S, S, D, Q, F, F, S, F},
        {D, D, D, D, D, D, D, D, D},
        {F, F, F, D, F, F, F, Q, F},
    };
    for (int state = 0; state < 5; state++) {
        for (int event = 0; event < 9; event++) {
            SZFriendsOutboxState next = SZFriendsOutboxNextState(state, event);
            SZFTExpect(next == expected[state][event], @"state %d event %d gave %ld, want %ld", state, event,
                (long)next,
                       (long)expected[state][event]);
        }
    }
    SZFTExpect(SZFriendsOutboxNextState(Q, 99) == Q && SZFriendsOutboxNextState(9, 0) == 9, @"unknown values");
}

static SZFriendsOutboxEntry *Entry(NSString *entryID, NSString *conversationID, SZFriendsOutboxKind kind,
                                   NSString *_Nullable itemID, NSDate *created) {
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = entryID;
    entry.conversationID = conversationID;
    entry.kind = kind;
    entry.itemID = itemID;
    entry.createdAt = created;
    entry.state = SZFriendsOutboxStateDelivered; // ignored: new entries always start Queued
    return entry;
}

static void TestEnqueueAndDeliver(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"outbox"));
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    NSDate *now = [NSDate date];
    SZFriendsOutboxEntry *entry = Entry(@"e1", @"mei", SZFriendsOutboxKindMessage, @"m1", now);
    entry.clientToken = @"token-0123456789abcdef";
    entry.payload = SZFTBytes(5, 3);
    SZFriendsItemRecord *item = SZFTMessage(@"mei", @"m1", @"hello", now.timeIntervalSince1970,
                                            SZFriendsDirectionOutgoing);
    NSError *error = nil;
    SZFTExpect([outbox enqueue:entry item:item error:&error], @"enqueue: %@", error);
    SZFriendsOutboxEntry *read = [outbox entryWithID:@"e1"];
    SZFTExpect(read.state == Q && [read.queuedAt isEqualToDate:read.createdAt] && read.attempts == 0 &&
                   [read.payload isEqualToData:SZFTBytes(5, 3)], @"starts queued");
    SZFriendsItemRecord *shown = [store itemsInConversation:@"mei" beforeItemID:nil limit:5
        hasEarlier:NULL].firstObject;
    SZFTExpect(shown.outboxState == Q, @"the item shows its delivery state: %ld", (long)shown.outboxState);
    SZFTExpect(![outbox enqueue:Entry(@"e1", @"mei", SZFriendsOutboxKindMessage, nil, now) error:&error] &&
                   error.code == SZFriendsStoreErrorConstraint, @"an entry id is used once");
    SZFTExpect(![outbox enqueue:Entry(@"e9", @"ghost", SZFriendsOutboxKindMessage, nil, now) error:&error] &&
                   error.code == SZFriendsStoreErrorNotFound, @"unknown person");
    // The item and its entry commit together: a failing entry leaves no orphan item.
    SZFriendsItemRecord *orphan = SZFTMessage(@"mei", @"m2", @"orphan?", now.timeIntervalSince1970,
                                              SZFriendsDirectionOutgoing);
    SZFTExpect(![outbox enqueue:Entry(@"e1", @"mei", SZFriendsOutboxKindMessage, @"m2", now) item:orphan error:NULL],
               @"duplicate entry");
    SZFTExpect([store itemsInConversation:@"mei" beforeItemID:nil limit:5 hasEarlier:NULL].count == 1,
        @"no orphan item");
    SZFriendsOutboxEntry *second = Entry(@"e2", @"mei", SZFriendsOutboxKindOffer, nil, [now
        dateByAddingTimeInterval:1]);
    second.clientToken = @"token-0123456789abcdef";
    [outbox enqueue:second error:NULL];
    SZFTExpect([[[outbox entriesWithClientToken:@"token-0123456789abcdef"] valueForKey:@"entryID"]
                   isEqual:(@[ @"e1", @"e2" ])], @"one intent, every entry");
    SZFTExpect([[outbox entryWithClientToken:@"token-0123456789abcdef"].entryID isEqualToString:@"e1"], @"first");
    SZFTExpect([[outbox entryForItemID:@"m1"].entryID isEqualToString:@"e1"], @"by item");
    for (NSNumber *event in @[ @(SZFriendsOutboxEventRouteAvailable), @(SZFriendsOutboxEventSessionEstablished),
                               @(SZFriendsOutboxEventWritten), @(SZFriendsOutboxEventSessionLost),
                               @(SZFriendsOutboxEventWritten) ]) {
        SZFTExpect([outbox applyEvent:event.integerValue toEntry:@"e1" error:NULL], @"event %@", event);
    }
    read = [outbox entryWithID:@"e1"];
    SZFTExpect(read.state == S && read.attempts == 2, @"sending, two attempts: %ld %lu", (long)read.state,
               (unsigned long)read.attempts);
    SZFTExpect([outbox pendingEntriesForConversation:@"mei"].count == 2 && outbox.allPendingEntries.count == 2,
               @"pending");
    [outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:@"e1" error:NULL];
    SZFTExpect([outbox entryWithID:@"e1"].state == D && [outbox pendingEntriesForConversation:@"mei"].count == 1,
               @"delivered leaves the queue");
    [outbox applyEvent:SZFriendsOutboxEventRefused toEntry:@"e2" error:NULL];
    read = [outbox entryWithID:@"e2"];
    SZFTExpect(read.state == F && [read.failureReason isEqualToString:SZFriendsOutboxFailureRefused], @"refused");
    SZFTExpect(![outbox applyEvent:SZFriendsOutboxEventRetry toEntry:@"nope" error:&error] &&
                   error.code == SZFriendsStoreErrorNotFound, @"unknown entry");
}

static void TestCrashReturnsInFlightEntriesToQueued(void) {
    NSString *directory = SZFTTemporaryDirectory(@"inflight");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    NSDate *now = [NSDate date];
    [outbox enqueue:Entry(@"c1", @"mei", SZFriendsOutboxKindMessage, nil, now) error:NULL];
    [outbox enqueue:Entry(@"c2", @"mei", SZFriendsOutboxKindMessage, nil, now) error:NULL];
    [outbox applyEvent:SZFriendsOutboxEventRouteAvailable toEntry:@"c1" error:NULL];
    [outbox applyEvent:SZFriendsOutboxEventWritten toEntry:@"c2" error:NULL];
    [store close];
    SZFriendsOutbox *again = [[SZFriendsOutbox alloc] initWithStore:SZFTOpenStore(directory)];
    SZFTExpect([again entryWithID:@"c1"].state == Q && [again entryWithID:@"c2"].state == Q,
               @"connecting and sending entries are queued again after a restart");
    SZFTExpect([again entryWithID:@"c2"].attempts == 1, @"attempts survive");
}

static SZFriendsTransferRecord *StageOffer(SZFriendsStore *store, NSString *transferID) {
    SZFriendsTransferRecord *record = [[SZFriendsTransferRecord alloc] init];
    record.transferID = transferID;
    record.conversationID = @"mei";
    record.outgoing = YES;
    record.fileName = @"Plan.pdf";
    record.size = 4;
    record.contentDigest = SZFTBytes(2, 32);
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        return SZFriendsTransferRowInsert(db, record, nil, error);
    } error:NULL];
    return record;
}

static SZFriendsTransferState TransferState(SZFriendsStore *store, NSString *transferID) {
    return (SZFriendsTransferState)[SZFTScalar(store, @"SELECT state FROM transfers WHERE transfer_id = ?",
                                               @[ transferID ]) integerValue];
}

static void TestThirtyDayExpiryAndTryAgain(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"expiry"));
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    NSDate *now = [NSDate date];
    NSTimeInterval day = 24 * 3600;
    [outbox enqueue:Entry(@"old", @"mei", SZFriendsOutboxKindMessage, nil, [now dateByAddingTimeInterval:-31 * day])
              error:NULL];
    [outbox enqueue:Entry(@"young", @"mei", SZFriendsOutboxKindMessage, nil, [now dateByAddingTimeInterval:-29 * day])
              error:NULL];
    [outbox enqueue:Entry(@"done", @"mei", SZFriendsOutboxKindMessage, nil, [now dateByAddingTimeInterval:-40 * day])
              error:NULL];
    [outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:@"done" error:NULL];
    StageOffer(store, @"offer1");
    [outbox enqueue:Entry(@"offer", @"mei", SZFriendsOutboxKindOffer, @"offer1", [now
        dateByAddingTimeInterval:-31 * day])
              error:NULL];
    NSError *error = nil;
    NSArray<SZFriendsOutboxEntry *> *expired = [outbox expireEntriesAtDate:now error:&error];
    NSSet *wanted = [NSSet setWithArray:@[ @"old", @"offer" ]];
    SZFTExpect([[NSSet setWithArray:[expired valueForKey:@"entryID"]] isEqualToSet:wanted], @"expired %@ (%@)",
               [expired valueForKey:@"entryID"], error);
    SZFriendsOutboxEntry *old = [outbox entryWithID:@"old"];
    SZFTExpect(old.state == F && [old.failureReason isEqualToString:SZFriendsOutboxFailureNotDelivered30Days],
               @"Not delivered in 30 days");
    SZFTExpect([outbox entryWithID:@"young"].state == Q && [outbox entryWithID:@"done"].state == D,
        @"others untouched");
    SZFTExpect(TransferState(store, @"offer1") == SZFriendsTransferStateFailed, @"the offer's transfer failed too");
    SZFTExpect([SZFTScalar(store, @"SELECT failure_reason FROM transfers WHERE transfer_id = 'offer1'", @[])
                   isEqual:SZFriendsOutboxFailureNotDelivered30Days], @"with the same reason");
    SZFTExpect([outbox applyEvent:SZFriendsOutboxEventRetry toEntry:@"old" error:NULL], @"Try again");
    [outbox applyEvent:SZFriendsOutboxEventRetry toEntry:@"offer" error:NULL];
    old = [outbox entryWithID:@"old"];
    SZFTExpect(old.state == Q && !old.failureReason && fabs([old.queuedAt timeIntervalSinceNow]) < 60,
               @"queued again with a fresh 30 days");
    SZFTExpect(TransferState(store, @"offer1") == SZFriendsTransferStateQueued, @"the offer is queued again");
    SZFTExpect([outbox expireEntriesAtDate:now error:NULL].count == 0, @"not again today");
    NSArray *later = [outbox expireEntriesAtDate:[now dateByAddingTimeInterval:31 * day] error:NULL];
    SZFTExpect(later.count == 3, @"but 30 days after the retry: %lu", (unsigned long)later.count);
}

static void TestDeliveredOfferMovesItsTransfer(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"offerack"));
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    StageOffer(store, @"t1");
    SZFriendsItemRecord *item = SZFTMessage(@"mei", @"t1", nil, 100, SZFriendsDirectionOutgoing);
    item.kind = SZFriendsItemKindTransfer;
    item.transferID = @"t1";
    [outbox enqueue:Entry(@"o1", @"mei", SZFriendsOutboxKindOffer, @"t1", [NSDate date]) item:item error:NULL];
    SZFTExpect([[store itemsInConversation:@"mei" beforeItemID:nil limit:1 hasEarlier:NULL].firstObject.text
                   isEqualToString:@"Plan.pdf"], @"a file's history row carries its name");
    [outbox applyEvent:SZFriendsOutboxEventWritten toEntry:@"o1" error:NULL];
    [outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:@"o1" error:NULL];
    SZFTExpect(TransferState(store, @"t1") == SZFriendsTransferStateOffered, @"delivered offer is Offered");
    // An acceptance processed before the ACK must not be undone by it.
    StageOffer(store, @"t2");
    [outbox enqueue:Entry(@"o2", @"mei", SZFriendsOutboxKindOffer, @"t2", [NSDate date]) error:NULL];
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        return SZFriendsTransferRowApplyEvent(db, @"t2", SZFriendsTransferEventAccepted, nil, error);
    } error:NULL];
    SZFTExpect([outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:@"o2" error:NULL], @"late ACK is fine");
    SZFTExpect(TransferState(store, @"t2") == SZFriendsTransferStateSending, @"still sending");
}

// cancel_message: only what has not left can be withdrawn. Queued and Connecting entries go with their item marked
// cancelled; from Sending on (it may already be on the friend's Mac) nothing changes, and the caller learns why. So for
// one written to a session that dropped before the acknowledgement: queued again, yet the friend's Mac may have it.
static void TestCancelWithdrawsOnlyWhatHasNotLeft(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"cancel"));
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"priya", 2, SZFriendsRelationFriend, 1000);
    NSDate *now = [NSDate date];
    NSDictionary<NSString *, NSArray<NSNumber *> *> *paths = @{
        @"q" : @[], @"c" : @[ @(SZFriendsOutboxEventRouteAvailable) ], @"s" : @[ @(SZFriendsOutboxEventWritten) ],
        @"d" : @[ @(SZFriendsOutboxEventWritten), @(SZFriendsOutboxEventAcknowledged) ],
        @"f" : @[ @(SZFriendsOutboxEventRefused) ],
        @"w" : @[ @(SZFriendsOutboxEventWritten), @(SZFriendsOutboxEventSessionLost) ],
        @"wc" : @[ @(SZFriendsOutboxEventWritten), @(SZFriendsOutboxEventSessionLost),
                   @(SZFriendsOutboxEventRouteAvailable) ]
    };
    for (NSString *name in paths) {
        NSString *itemID = [@"m_" stringByAppendingString:name];
        SZFriendsItemRecord *item = SZFTMessage(@"mei", itemID, name, now.timeIntervalSince1970,
                                                SZFriendsDirectionOutgoing);
        SZFTExpect([outbox enqueue:Entry(name, @"mei", SZFriendsOutboxKindMessage, itemID, now) item:item error:NULL],
                   @"enqueue %@", name);
        for (NSNumber *event in paths[name]) [outbox applyEvent:event.integerValue toEntry:name error:NULL];
    }
    [store insertItem:SZFTMessage(@"mei", @"m_in", @"theirs", now.timeIntervalSince1970, SZFriendsDirectionIncoming)
                error:NULL];
    [store insertItem:SZFTMessage(@"mei", @"m_old", @"no record", 10, SZFriendsDirectionOutgoing) error:NULL];
    NSError *error = nil;
    NSInteger state = 99;
    SZFTExpect([outbox cancelMessage:@"m_q" inConversation:@"mei" state:&state error:&error] && state == Q,
               @"a queued message is withdrawn: %@", error);
    SZFriendsItemRecord *cancelled = [store itemWithID:@"m_q" inConversation:@"mei"];
    SZFTExpect(![outbox entryWithID:@"q"] && cancelled.cancelled && cancelled.outboxState == -1 &&
                   ![[[outbox pendingEntriesForConversation:@"mei"] valueForKey:@"entryID"] containsObject:@"q"],
               @"its entry is gone, so nothing sends it, and the item says cancelled");
    SZFTExpect([outbox cancelMessage:@"m_q" inConversation:@"mei" state:NULL error:&error],
               @"cancelling again (a retry after a lost reply) succeeds: %@", error);
    SZFTExpect([outbox cancelMessage:@"m_c" inConversation:@"mei" state:&state error:NULL] && state == C &&
                   ![outbox entryWithID:@"c"] && [store itemWithID:@"m_c" inConversation:@"mei"].cancelled,
               @"so is one whose route is still being dialed");
    for (NSArray *refused in @[ @[ @"s", @(S) ], @[ @"d", @(D) ], @[ @"f", @(F) ], @[ @"old", @(-1) ] ]) {
        NSString *itemID = [@"m_" stringByAppendingString:refused[0]];
        error = nil;
        BOOL done = [outbox cancelMessage:itemID inConversation:@"mei" state:&state error:&error];
        SZFTExpect(!done && error.code == SZFriendsStoreErrorStale && state == [refused[1] integerValue] &&
                       ![store itemWithID:itemID inConversation:@"mei"].cancelled,
                   @"%@ has left or has no record, so it stays: %@ state %ld", itemID, error, (long)state);
    }
    SZFTExpect([outbox entryWithID:@"s"].state == S && [outbox entryWithID:@"d"].state == D,
               @"what already left keeps its state");
    SZFriendsItemRecord *unsent = [store itemWithID:@"m_q" inConversation:@"mei"];
    SZFriendsItemRecord *written = [store itemWithID:@"m_w" inConversation:@"mei"];
    SZFTExpect(written.outboxState == Q && written.outboxWritten && !unsent.outboxWritten &&
                   [outbox entryWithID:@"w"].attempts == 1,
               @"the item says its entry was written once, so a snapshot can leave Cancel out");
    for (NSString *name in @[ @"w", @"wc" ]) {
        NSString *itemID = [@"m_" stringByAppendingString:name];
        error = nil;
        state = 99;
        BOOL done = [outbox cancelMessage:itemID inConversation:@"mei" state:&state error:&error];
        SZFTExpect(!done && error.code == SZFriendsStoreErrorStale && state == SZFriendsOutboxCancelStateWritten &&
                       [outbox entryWithID:name] && ![store itemWithID:itemID inConversation:@"mei"].cancelled,
                   @"%@ was written before its session dropped, so it may be on Mei's Mac: %@ state %ld", name,
                   error, (long)state);
    }
    for (NSArray *missing in @[ @[ @"m_in", @"mei" ], @[ @"m_nope", @"mei" ], @[ @"m_s", @"priya" ] ]) {
        error = nil;
        SZFTExpect(![outbox cancelMessage:missing[0] inConversation:missing[1] state:NULL error:&error] &&
                       error.code == SZFriendsStoreErrorNotFound,
                   @"%@ in %@ is not this person's message there: %@", missing[0], missing[1], error);
    }
}

void SZFTRunOutboxTests(void) {
    TestStateMachineExhaustively();
    TestEnqueueAndDeliver();
    TestCrashReturnsInFlightEntriesToQueued();
    TestThirtyDayExpiryAndTryAgain();
    TestDeliveredOfferMovesItsTransfer();
    TestCancelWithdrawsOnlyWhatHasNotLeft();
}
