// The outbox state machine and its table (brief § Outbox and delivery, ADR 0001 § Messages).

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSTimeInterval SZFriendsOutboxExpiryInterval = 30 * 24 * 60 * 60;
const NSInteger SZFriendsOutboxCancelStateWritten = 100; // apart from every SZFriendsOutboxState
NSString *const SZFriendsOutboxFailureNotDelivered30Days = @"not_delivered_30_days";
NSString *const SZFriendsOutboxFailureRefused = @"refused";
NSString *const SZFriendsOutboxFailureSourceMissing = @"source_missing";

static BOOL SZFriendsOutboxIsLive(SZFriendsOutboxState state) {
    return state == SZFriendsOutboxStateQueued || state == SZFriendsOutboxStateConnecting ||
           state == SZFriendsOutboxStateSending;
}

SZFriendsOutboxState SZFriendsOutboxNextState(SZFriendsOutboxState state, SZFriendsOutboxEvent event) {
    if (state < SZFriendsOutboxStateQueued || state > SZFriendsOutboxStateFailed) return state;
    BOOL waiting = state == SZFriendsOutboxStateQueued || state == SZFriendsOutboxStateConnecting;
    switch (event) {
        case SZFriendsOutboxEventRouteAvailable:
            return state == SZFriendsOutboxStateQueued ? SZFriendsOutboxStateConnecting : state;
        case SZFriendsOutboxEventSessionEstablished:
        case SZFriendsOutboxEventWritten:
            return waiting ? SZFriendsOutboxStateSending : state;
        case SZFriendsOutboxEventAcknowledged:
            // The recipient committed it: true whatever we believed meanwhile, even after a timeout marked it Failed.
            return SZFriendsOutboxStateDelivered;
        case SZFriendsOutboxEventSessionLost:
            return (state == SZFriendsOutboxStateConnecting || state == SZFriendsOutboxStateSending)
                       ? SZFriendsOutboxStateQueued
                       : state;
        case SZFriendsOutboxEventRefused:
        case SZFriendsOutboxEventSourceMissing:
        case SZFriendsOutboxEventExpired:
            return SZFriendsOutboxIsLive(state) ? SZFriendsOutboxStateFailed : state;
        case SZFriendsOutboxEventRetry:
            return state == SZFriendsOutboxStateFailed ? SZFriendsOutboxStateQueued : state;
    }
    return state;
}

static NSString *_Nullable SZFriendsOutboxFailureReason(SZFriendsOutboxEvent event) {
    switch (event) {
        case SZFriendsOutboxEventRefused: return SZFriendsOutboxFailureRefused;
        case SZFriendsOutboxEventSourceMissing: return SZFriendsOutboxFailureSourceMissing;
        case SZFriendsOutboxEventExpired: return SZFriendsOutboxFailureNotDelivered30Days;
        default: return nil;
    }
}

static NSString *const SZFriendsEntryColumns = @"entry_id, conversation_id, kind, state, created_at, queued_at, "
                                               @"attempts, item_id, client_token, failure_reason, payload";

static NSArray<SZFriendsOutboxEntry *> *SZFriendsEntries(SZFriendsStoreDB *_Nullable db, NSString *tail,
                                                         NSArray *binds) {
    NSMutableArray *entries = [NSMutableArray array];
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM outbox %@", SZFriendsEntryColumns, tail];
    NSError *error = nil;
    BOOL ok = [db run:sql binds:binds row:^(sqlite3_stmt *s) {
        SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
        entry.entryID = SZFriendsColumnText(s, 0) ?: @"";
        entry.conversationID = SZFriendsColumnText(s, 1) ?: @"";
        entry.kind = (SZFriendsOutboxKind)SZFriendsColumnInt(s, 2);
        entry.state = (SZFriendsOutboxState)SZFriendsColumnInt(s, 3);
        entry.createdAt = SZFriendsColumnDate(s, 4) ?: [NSDate dateWithTimeIntervalSince1970:0];
        entry.queuedAt = SZFriendsColumnDate(s, 5);
        entry.attempts = (NSUInteger)MAX(SZFriendsColumnInt(s, 6), 0);
        entry.itemID = SZFriendsColumnText(s, 7);
        entry.clientToken = SZFriendsColumnText(s, 8);
        entry.failureReason = SZFriendsColumnText(s, 9);
        entry.payload = SZFriendsColumnBlob(s, 10);
        [entries addObject:entry];
    } error:&error];
    if (db && !ok) NSLog(@"Friends store: reading the outbox failed: %@", error.localizedDescription);
    return entries;
}

// A transfer that has moved on (accepted before the offer's ACK was processed, cancelled meanwhile) simply does not
// follow its entry; anything else is a real failure and rolls the event back.
static BOOL SZFriendsOutboxMoveTransfer(SZFriendsStoreDB *db, NSString *transferID, SZFriendsTransferEvent event,
                                        NSString *_Nullable reason, NSError **error) {
    NSError *failure = nil;
    if (SZFriendsTransferRowApplyEvent(db, transferID, event, reason, &failure)) return YES;
    BOOL ignorable = [failure.domain isEqualToString:SZFriendsStoreErrorDomain] &&
                     (failure.code == SZFriendsStoreErrorStale || failure.code == SZFriendsStoreErrorNotFound);
    return ignorable ? YES : SZFriendsFail(error, failure);
}

// `sender` nil for this Mac's own events; otherwise the peer's conversation, which must own the entry.
static BOOL SZFriendsOutboxApply(SZFriendsStoreDB *db, NSString *entryID, SZFriendsOutboxEvent event,
                                 NSString *_Nullable sender, NSDate *now, NSError **error) {
    SZFriendsOutboxEntry *entry = SZFriendsEntries(db, @"WHERE entry_id = ?", @[ entryID ]).firstObject;
    if (!entry) return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"unknown entry"));
    if (sender && (sender.length == 0 || ![entry.conversationID isEqualToString:sender])) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"not this friend's entry"));
    }
    SZFriendsOutboxState next = SZFriendsOutboxNextState(entry.state, event);
    BOOL counts = event == SZFriendsOutboxEventWritten && SZFriendsOutboxIsLive(entry.state);
    if (next == entry.state && !counts) return YES;
    NSString *reason = next == SZFriendsOutboxStateFailed ? SZFriendsOutboxFailureReason(event) : nil;
    BOOL restart = event == SZFriendsOutboxEventRetry && next == SZFriendsOutboxStateQueued;
    NSString *sql = @"UPDATE outbox SET state = ?, attempts = attempts + ?, failure_reason = ?, "
                    @"queued_at = CASE WHEN ? THEN ? ELSE queued_at END, updated_at = ? WHERE entry_id = ?";
    NSArray *binds = @[ @(next), @(counts ? 1 : 0), SZFriendsSQL(reason), @(restart), now, now, entryID ];
    if (![db run:sql binds:binds row:nil error:error]) return NO;
    if (entry.kind != SZFriendsOutboxKindOffer || !entry.itemID || next == entry.state) return YES;
    if (next == SZFriendsOutboxStateDelivered) {
        return SZFriendsOutboxMoveTransfer(db, entry.itemID, SZFriendsTransferEventOfferDelivered, nil, error);
    }
    if (next == SZFriendsOutboxStateFailed) {
        return SZFriendsOutboxMoveTransfer(db, entry.itemID, SZFriendsTransferEventFailed, reason, error);
    }
    if (restart) return SZFriendsOutboxMoveTransfer(db, entry.itemID, SZFriendsTransferEventRetry, nil, error);
    return YES;
}

@implementation SZFriendsOutbox {
    SZFriendsStore *_store;
}

- (instancetype)initWithStore:(SZFriendsStore *)store {
    if ((self = [super init])) _store = store;
    return self;
}

- (BOOL)enqueue:(SZFriendsOutboxEntry *)entry error:(NSError **)error {
    return [self enqueue:entry item:nil error:error];
}

- (BOOL)enqueue:(SZFriendsOutboxEntry *)entry item:(nullable SZFriendsItemRecord *)item error:(NSError **)error {
    if (!SZFriendsStoreIsValidIdentifier(entry.entryID) || !SZFriendsStoreIsValidIdentifier(entry.conversationID) ||
        (entry.itemID && !SZFriendsStoreIsValidIdentifier(entry.itemID)) ||
        (entry.clientToken && (entry.clientToken.length == 0 || entry.clientToken.length > 64)) ||
        entry.kind < SZFriendsOutboxKindRequest || entry.kind > SZFriendsOutboxKindPresenceSecret) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad outbox entry"));
    }
    return [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (item && !SZFriendsStoreInsertItem(db, item, NULL, inner)) return NO;
        NSNumber *known = [db scalar:@"SELECT count(*) FROM friends WHERE conversation_id = ?"
                               binds:@[ entry.conversationID ]
                               error:inner];
        if (!known) return NO;
        if (known.integerValue == 0) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"unknown person"));
        }
        NSDate *created = entry.createdAt ?: [NSDate date];
        NSString *sql = [NSString stringWithFormat:@"INSERT INTO outbox (%@, updated_at) "
                                                   @"VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                                                   SZFriendsEntryColumns];
        NSArray *binds = @[
            entry.entryID, entry.conversationID, @(entry.kind), @(SZFriendsOutboxStateQueued), created, created, @0,
            SZFriendsSQL(entry.itemID), SZFriendsSQL(entry.clientToken), [NSNull null], SZFriendsSQL(entry.payload),
            [NSDate date]
        ];
        if (![db run:sql binds:binds row:nil error:inner]) return NO;
        entry.state = SZFriendsOutboxStateQueued;
        entry.queuedAt = created;
        entry.attempts = 0;
        entry.failureReason = nil;
        return YES;
    } error:error];
}

- (NSArray<SZFriendsOutboxEntry *> *)read:(NSString *)tail binds:(NSArray *)binds {
    __block NSArray *entries = @[];
    [_store performRead:^(SZFriendsStoreDB *_Nullable db) { entries = SZFriendsEntries(db, tail, binds); }];
    return entries;
}

- (nullable SZFriendsOutboxEntry *)entryWithClientToken:(NSString *)clientToken {
    return [self entriesWithClientToken:clientToken].firstObject;
}

- (NSArray<SZFriendsOutboxEntry *> *)entriesWithClientToken:(NSString *)clientToken {
    return [self read:@"WHERE client_token = ? ORDER BY created_at, entry_id" binds:@[ clientToken ]];
}

- (nullable SZFriendsOutboxEntry *)entryWithID:(NSString *)entryID {
    return [self read:@"WHERE entry_id = ?" binds:@[ entryID ]].firstObject;
}

- (nullable SZFriendsOutboxEntry *)entryForItemID:(NSString *)itemID {
    return [self read:@"WHERE item_id = ? ORDER BY created_at LIMIT 1" binds:@[ itemID ]].firstObject;
}

- (NSArray<SZFriendsOutboxEntry *> *)pendingEntriesForConversation:(NSString *)conversationID {
    return [self read:@"WHERE conversation_id = ? AND state IN (0, 1, 2) ORDER BY created_at, entry_id"
                binds:@[ conversationID ]];
}

- (NSArray<SZFriendsOutboxEntry *> *)allPendingEntries {
    return [self read:@"WHERE state IN (0, 1, 2) ORDER BY created_at, entry_id" binds:@[]];
}

- (BOOL)applyEvent:(SZFriendsOutboxEvent)event toEntry:(NSString *)entryID error:(NSError **)error {
    NSDate *now = [NSDate date];
    return [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsOutboxApply(db, entryID, event, nil, now, inner);
    } error:error];
}

- (BOOL)applyEvent:(SZFriendsOutboxEvent)event
           toEntry:(NSString *)entryID
  fromConversation:(NSString *)conversationID
             error:(NSError **)error {
    NSDate *now = [NSDate date];
    NSString *sender = conversationID ?: @""; // a peer with no conversation owns nothing
    return [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsOutboxApply(db, entryID, event, sender, now, inner);
    } error:error];
}

- (BOOL)cancelMessage:(NSString *)itemID
       inConversation:(NSString *)conversationID
                state:(NSInteger *_Nullable)state
                error:(NSError **)error {
    __block NSInteger found = -1;
    BOOL ok = [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        __block BOOL mine = NO, cancelled = NO;
        // Direction and kind matter: a friend chooses the ids of what they send, so an incoming message may carry the
        // id of one of ours and must never withdraw it.
        BOOL read = [db run:@"SELECT cancelled FROM messages WHERE conversation_id = ? AND item_id = ? AND "
                            @"direction = ? AND kind = ?"
                      binds:@[ conversationID, itemID, @(SZFriendsDirectionOutgoing), @(SZFriendsItemKindMessage) ]
                        row:^(sqlite3_stmt *s) {
                            mine = YES;
                            cancelled = SZFriendsColumnInt(s, 0) != 0;
                        }
                      error:inner];
        if (!read) return NO;
        if (!mine) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"no such message"));
        }
        if (cancelled) return YES;
        SZFriendsOutboxEntry *entry = SZFriendsEntries(db, @"WHERE conversation_id = ? AND item_id = ? AND kind = ?",
                                                       @[ conversationID, itemID, @(SZFriendsOutboxKindMessage) ])
                                          .firstObject;
        if (entry) found = entry.state;
        if (!entry || (entry.state != SZFriendsOutboxStateQueued && entry.state != SZFriendsOutboxStateConnecting)) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorStale, @"it already left"));
        }
        // Written before, then its session dropped (SessionLost, or the reset after a crash) before the friend's Mac
        // acknowledged it: that Mac may have committed it and only the acknowledgement was lost, so a "Cancelled"
        // here could be false on their side.
        if (entry.attempts > 0) {
            found = SZFriendsOutboxCancelStateWritten;
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorStale, @"it may have arrived"));
        }
        return [db run:@"DELETE FROM outbox WHERE entry_id = ?" binds:@[ entry.entryID ] row:nil error:inner] &&
               [db run:@"UPDATE messages SET cancelled = 1 WHERE conversation_id = ? AND item_id = ?"
                 binds:@[ conversationID, itemID ]
                   row:nil
                 error:inner];
    } error:error];
    if (state) *state = found;
    return ok;
}

- (nullable NSArray<SZFriendsOutboxEntry *> *)expireEntriesAtDate:(NSDate *)now error:(NSError **)error {
    NSDate *cutoff = [now dateByAddingTimeInterval:-SZFriendsOutboxExpiryInterval];
    __block NSArray<SZFriendsOutboxEntry *> *expired = @[];
    BOOL ok = [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSArray<SZFriendsOutboxEntry *> *due =
            SZFriendsEntries(db, @"WHERE state IN (0, 1, 2) AND queued_at <= ? ORDER BY created_at, entry_id",
                             @[ cutoff ]);
        NSMutableArray *ids = [NSMutableArray array];
        for (SZFriendsOutboxEntry *entry in due) {
            if (!SZFriendsOutboxApply(db, entry.entryID, SZFriendsOutboxEventExpired, nil, now, inner)) return NO;
            [ids addObject:entry.entryID];
        }
        NSMutableArray *reloaded = [NSMutableArray array];
        for (NSString *entryID in ids) {
            [reloaded addObjectsFromArray:SZFriendsEntries(db, @"WHERE entry_id = ?", @[ entryID ])];
        }
        expired = reloaded;
        return YES;
    } error:error];
    return ok ? expired : nil;
}

@end

NS_ASSUME_NONNULL_END
