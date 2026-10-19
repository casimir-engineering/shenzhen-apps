// The Add by ID requests this person sent (table id_requests, ADR 0004 steps 1 to 4) and who answered each one
// (table id_request_answers, schema v2).
//
// A request stays until it expires, even once answered, so a second holder of an unreserved ID can still call back
// (brief § Friends ID, unreserved duplicates nearby). Its token is broadcast to every nearby device, so it proves
// nothing about who answers; that is why each distinct key gets its own conversation and a token admits at most
// SZFriendsIDRequestMaxAnswers of them (security review, Add by ID).

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSUInteger SZFriendsIDRequestMaxPending = 4;
const NSUInteger SZFriendsIDRequestMaxAnswers = 3;
const NSUInteger SZFriendsIDRequestMaxUnattestedAnswers = 2;
const NSTimeInterval SZFriendsIDRequestLifetime = 7 * 24 * 60 * 60;

static SZFriendsIDRequestRecord *SZFriendsIDRequestFromRow(sqlite3_stmt *s) {
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = SZFriendsColumnText(s, 0) ?: @"";
    request.targetFriendsID = SZFriendsColumnText(s, 1) ?: @"";
    request.requestToken = SZFriendsColumnBlob(s, 2) ?: [NSData data];
    request.callbackSecret = SZFriendsColumnBlob(s, 3) ?: [NSData data];
    request.createdAt = SZFriendsColumnDate(s, 4) ?: [NSDate dateWithTimeIntervalSince1970:0];
    request.expiresAt = SZFriendsColumnDate(s, 5) ?: request.createdAt;
    request.answeredAt = SZFriendsColumnDate(s, 6);
    request.answeringKeyCount = (NSUInteger)MAX(SZFriendsColumnInt(s, 7), 0);
    return request;
}

NSArray<SZFriendsIDRequestRecord *> *SZFriendsStoreIDRequests(SZFriendsStoreDB *db, NSString *whereClause,
                                                              NSArray *binds) {
    NSString *sql = [NSString stringWithFormat:@"SELECT conversation_id, target_friends_id, request_token, "
                                               @"callback_secret, created_at, expires_at, answered_at, (SELECT "
                                               @"count(*) FROM id_request_answers a WHERE a.request_token = "
                                               @"id_requests.request_token) FROM id_requests %@ "
                                               @"ORDER BY created_at, conversation_id",
                                               whereClause];
    NSMutableArray *requests = [NSMutableArray array];
    NSError *error = nil;
    if (![db run:sql binds:binds row:^(sqlite3_stmt *s) { [requests addObject:SZFriendsIDRequestFromRow(s)]; }
           error:&error]) {
        NSLog(@"Friends store: reading ID requests failed: %@", error.localizedDescription);
    }
    return requests;
}

BOOL SZFriendsStoreSaveIDRequest(SZFriendsStoreDB *db, SZFriendsIDRequestRecord *request, NSDate *now,
                                 NSError **error) {
    if (!SZFriendsStoreIsValidIdentifier(request.conversationID) || request.requestToken.length != 16 ||
        request.callbackSecret.length != 32 || request.targetFriendsID.length == 0) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad ID request"));
    }
    // ADR 0004 step 3: requests expire after 7 days; a longer expiry from a caller would keep callback tags
    // advertised, and an IK door open, past what the person was told.
    NSDate *latest = [request.createdAt dateByAddingTimeInterval:SZFriendsIDRequestLifetime];
    NSDate *expires = [request.expiresAt compare:latest] == NSOrderedDescending ? latest : request.expiresAt;
    NSNumber *known = [db scalar:@"SELECT count(*) FROM friends WHERE conversation_id = ?"
                           binds:@[ request.conversationID ]
                           error:error];
    if (!known) return NO;
    // Constraint means "four already pending" to the helper (rate_limited); a missing row is a different mistake.
    if (known.integerValue == 0) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"unknown conversation"));
    }
    if (![db run:@"DELETE FROM id_requests WHERE expires_at <= ?" binds:@[ now ] row:nil error:error]) return NO;
    // Answered requests no longer advertise callback tags, and the limit exists because tag slots are few.
    NSNumber *others = [db scalar:@"SELECT count(*) FROM id_requests WHERE conversation_id <> ? AND answered_at IS NULL"
                            binds:@[ request.conversationID ]
                            error:error];
    if (!others) return NO;
    if (others.unsignedIntegerValue >= SZFriendsIDRequestMaxPending) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorConstraint,
                                                            @"four Add by ID requests are already pending"));
    }
    // A new token is a new request: the old one, and who answered it, go (the answers cascade with it).
    if (![db run:@"DELETE FROM id_requests WHERE conversation_id = ? AND request_token <> ?"
           binds:@[ request.conversationID, request.requestToken ]
             row:nil
           error:error]) {
        return NO;
    }
    NSString *sql = @"INSERT INTO id_requests (conversation_id, target_friends_id, request_token, callback_secret, "
                    @"created_at, expires_at) VALUES (?,?,?,?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET "
                    @"target_friends_id = excluded.target_friends_id, callback_secret = excluded.callback_secret, "
                    @"created_at = excluded.created_at, expires_at = excluded.expires_at";
    NSArray *binds = @[
        request.conversationID, request.targetFriendsID, request.requestToken, request.callbackSecret,
        request.createdAt, expires
    ];
    return [db run:sql binds:binds row:nil error:error];
}

// The same key answering takes its own row back (wave-3 security re-check: reuse a keyed row only when the callback
// presents that key). add_by_id made a keyless "Request sent" row rather than reviving theirs; if it is still keyless,
// the request and whatever was queued or recorded on it move here and it goes, so the person stays one row. A newer
// request replaces an older one this row still holds, as a new token for one conversation always does.
static BOOL SZFriendsFoldRequestRow(SZFriendsStoreDB *db, SZFriendsIDRequestRecord *request, NSString *rowID,
                                    NSString *knownID, NSError **error) {
    NSArray *token = @[ knownID, request.requestToken ], *rows = @[ knownID, rowID ];
    NSArray<NSArray *> *moves = @[
        @[ @"DELETE FROM id_requests WHERE conversation_id = ? AND request_token <> ?", token ],
        @[ @"UPDATE id_requests SET conversation_id = ? WHERE request_token = ?", token ],
        @[ @"UPDATE outbox SET conversation_id = ? WHERE conversation_id = ?", rows ],
        @[ @"UPDATE messages SET conversation_id = ? WHERE conversation_id = ?", rows ],
        @[ @"UPDATE transfers SET conversation_id = ? WHERE conversation_id = ?", rows ],
        @[ @"UPDATE id_request_answers SET conversation_id = ? WHERE conversation_id = ?", rows ],
        @[ @"DELETE FROM friends WHERE conversation_id = ?", @[ rowID ] ],
    ];
    for (NSArray *move in moves) {
        if (![db run:move[0] binds:move[1] row:nil error:error]) return NO;
    }
    return YES;
}

// A known person (not blocked) whose own key answered. Only if they hold the ID asked for, by the host's word or as
// the ID they last told us (the row add_by_id would once have reused), is this their row coming back: anyone who hears
// a broadcast can answer it, and a removed person answering someone else's request stays removed, as before. Removed,
// they become an outgoing request again, as the request's row was, so the answer their session carries lands; what
// their old friendship earned does not come back with them: a new friendship gets its own comparison code, and files
// from them ask again.
static NSString *_Nullable SZFriendsReclaimKnownRow(SZFriendsStoreDB *db, SZFriendsIDRequestRecord *request,
                                                    SZFriendsPersonRecord *known, SZFriendsPersonRecord *_Nullable row,
                                                    BOOL attested, NSDate *now, NSError **error) {
    if (!attested && ![known.friendsID isEqualToString:request.targetFriendsID]) return known.conversationID;
    if (row && !row.identityKey && ![row.conversationID isEqualToString:known.conversationID] &&
        !SZFriendsFoldRequestRow(db, request, row.conversationID, known.conversationID, error)) {
        return nil;
    }
    if (known.relation != SZFriendsRelationRemoved) return known.conversationID;
    known.relation = SZFriendsRelationOutgoingRequest;
    known.requestAt = row.requestAt ?: request.createdAt;
    known.requestFoundNearby = NO;
    known.comparisonCode = nil;
    known.autoAccept = NO;
    known.lastInteractionAt = now;
    return SZFriendsStoreSavePerson(db, known, error) ? known.conversationID : nil;
}

// The conversation a newly admitted key belongs to (the rules are in SZFriendsStore.h).
static NSString *_Nullable SZFriendsAnswerConversation(SZFriendsStoreDB *db, SZFriendsIDRequestRecord *request,
                                                       SZFriendsPersonRecord *_Nullable known, NSData *identityKey,
                                                       NSData *staticKey, BOOL attested, NSDate *now,
                                                       NSError **error) {
    SZFriendsPersonRecord *row = SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ request.conversationID ])
                                     .firstObject;
    if (known) return SZFriendsReclaimKnownRow(db, request, known, row, attested, now, error);
    if (row && !row.identityKey) {
        row.identityKey = identityKey;
        row.staticKey = row.staticKey ?: staticKey;
        return SZFriendsStoreSavePerson(db, row, error) ? row.conversationID : nil;
    }
    SZFriendsPersonRecord *other = [[SZFriendsPersonRecord alloc] init];
    other.conversationID = SZFriendsNewIdentifier();
    other.identityKey = identityKey;
    other.staticKey = staticKey;
    other.friendsID = request.targetFriendsID;
    other.picture = [SZFriendsPicture placeholder];
    other.relation = SZFriendsRelationOutgoingRequest;
    other.requestAt = row.requestAt ?: request.createdAt;
    other.lastInteractionAt = now;
    return SZFriendsStoreSavePerson(db, other, error) ? other.conversationID : nil;
}

@implementation SZFriendsStore (AddByID)

- (NSArray<SZFriendsIDRequestRecord *> *)requestsWhere:(NSString *)where binds:(NSArray *)binds {
    __block NSArray *requests = @[];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) requests = SZFriendsStoreIDRequests(db, where, binds);
    }];
    return requests;
}

- (NSArray<SZFriendsIDRequestRecord *> *)pendingIDRequestsAtDate:(NSDate *)now {
    return [self requestsWhere:@"WHERE expires_at > ? AND answered_at IS NULL" binds:@[ now ]];
}

- (nullable SZFriendsIDRequestRecord *)idRequestWithToken:(NSData *)requestToken {
    return [self idRequestWithToken:requestToken atDate:[NSDate date]];
}

- (nullable SZFriendsIDRequestRecord *)idRequestWithToken:(NSData *)requestToken atDate:(NSDate *)now {
    return [self requestsWhere:@"WHERE request_token = ? AND expires_at > ?" binds:@[ requestToken, now ]].firstObject;
}

- (BOOL)saveIDRequest:(SZFriendsIDRequestRecord *)request error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsStoreSaveIDRequest(db, request, [NSDate date], inner);
    } error:error];
}

- (nullable NSString *)startIDRequest:(SZFriendsIDRequestRecord *)request error:(NSError **)error {
    if (request.targetFriendsID.length == 0) {
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"no Friends ID"));
        return nil;
    }
    __block NSString *conversationID = nil;
    NSString *asked = request.conversationID;
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        // Newest first (SZFriendsStorePeople's order), so asking again picks up the row the person saw last.
        SZFriendsPersonRecord *row =
            SZFriendsStorePeople(db, @"WHERE friends_id = ? AND identity_pk IS NULL AND relation IN (?, ?)",
                                 @[ request.targetFriendsID, @(SZFriendsRelationOutgoingRequest),
                                    @(SZFriendsRelationRemoved) ])
                .firstObject;
        if (!row) {
            row = [[SZFriendsPersonRecord alloc] init];
            row.friendsID = request.targetFriendsID;
            row.picture = [SZFriendsPicture placeholder];
        }
        row.relation = SZFriendsRelationOutgoingRequest;
        row.requestAt = request.createdAt;
        row.requestFoundNearby = NO;
        row.lastInteractionAt = request.createdAt;
        // The row first, since the request names its conversation; a refused request rolls the row back with it.
        if (!SZFriendsStoreSavePerson(db, row, inner)) return NO;
        request.conversationID = row.conversationID;
        if (!SZFriendsStoreSaveIDRequest(db, request, [NSDate date], inner)) return NO;
        conversationID = row.conversationID;
        return YES;
    } error:error];
    if (!ok) request.conversationID = asked; // the row it named was rolled back
    return ok ? conversationID : nil;
}

- (BOOL)deleteIDRequestForConversation:(NSString *)conversationID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"DELETE FROM id_requests WHERE conversation_id = ?" binds:@[ conversationID ] row:nil
                 error:inner];
    } error:error];
}

// Slots for answers: SZFriendsIDRequestMaxAnswers in all, of which keys without an attestation may take
// `unattestedLimit`. The forms without `attested:` pass the full count (any key may take every slot), as before the
// attestation phase.
- (BOOL)idRequestWithToken:(NSData *)requestToken
         admitsIdentityKey:(NSData *)identityKey
                  attested:(BOOL)attested
           unattestedLimit:(NSUInteger)unattestedLimit
                    atDate:(NSDate *)now {
    if (requestToken.length != 16 || identityKey.length != 32) return NO;
    __block BOOL admits = NO;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        NSString *sql = @"SELECT EXISTS (SELECT 1 FROM id_request_answers WHERE request_token = ?1 AND "
                        @"identity_pk = ?2) OR ((SELECT count(*) FROM id_request_answers WHERE request_token = ?1) "
                        @"< ?3 AND (?6 OR (SELECT count(*) FROM id_request_answers WHERE request_token = ?1 AND "
                        @"attested = 0) < ?7)) "
                        @"FROM id_requests WHERE request_token = ?1 AND expires_at > ?4 AND NOT EXISTS (SELECT 1 FROM "
                        @"friends WHERE identity_pk = ?2 AND relation = ?5)";
        NSArray *binds = @[ requestToken, identityKey, @(SZFriendsIDRequestMaxAnswers), now,
                            @(SZFriendsRelationBlocked), @(attested), @(unattestedLimit) ];
        admits = [[db scalar:sql binds:binds error:NULL] boolValue];
    }];
    return admits;
}

- (BOOL)idRequestWithToken:(NSData *)requestToken admitsIdentityKey:(NSData *)identityKey atDate:(NSDate *)now {
    return [self idRequestWithToken:requestToken admitsIdentityKey:identityKey attested:NO
                    unattestedLimit:SZFriendsIDRequestMaxAnswers atDate:now];
}

- (BOOL)idRequestWithToken:(NSData *)requestToken
         admitsIdentityKey:(NSData *)identityKey
                  attested:(BOOL)attested
                    atDate:(NSDate *)now {
    return [self idRequestWithToken:requestToken admitsIdentityKey:identityKey attested:attested
                    unattestedLimit:SZFriendsIDRequestMaxUnattestedAnswers atDate:now];
}

- (nullable NSString *)conversationForIDRequestAnswerWithToken:(NSData *)requestToken
                                                   identityKey:(NSData *)identityKey
                                                     staticKey:(NSData *)staticKey
                                                      attested:(BOOL)attested
                                               unattestedLimit:(NSUInteger)unattestedLimit
                                                        atDate:(NSDate *)now
                                                         error:(NSError **)error {
    if (requestToken.length != 16 || identityKey.length != 32 || staticKey.length != 32) {
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad answer keys"));
        return nil;
    }
    __block NSString *conversationID = nil;
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsIDRequestRecord *request =
            SZFriendsStoreIDRequests(db, @"WHERE request_token = ? AND expires_at > ?", @[ requestToken, now ])
                .firstObject;
        if (!request) return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"no request"));
        SZFriendsPersonRecord *known = SZFriendsStorePeople(db, @"WHERE identity_pk = ?", @[ identityKey ]).firstObject;
        if (known.relation == SZFriendsRelationBlocked) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"blocked"));
        }
        NSError *lookup = nil;
        conversationID = [db scalar:@"SELECT conversation_id FROM id_request_answers WHERE request_token = ? AND "
                                    @"identity_pk = ?"
                              binds:@[ requestToken, identityKey ]
                              error:&lookup];
        if (lookup) return SZFriendsFail(inner, lookup);
        if (conversationID) return YES; // the same key calling back again after a dropped session
        NSNumber *unattested = attested ? @0
                                        : [db scalar:@"SELECT count(*) FROM id_request_answers WHERE request_token = ? "
                                                     @"AND attested = 0"
                                               binds:@[ requestToken ]
                                               error:inner];
        if (!unattested) return NO;
        if (request.answeringKeyCount >= SZFriendsIDRequestMaxAnswers ||
            unattested.unsignedIntegerValue >= unattestedLimit) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorConstraint,
                                                                @"this request has all the answers it admits"));
        }
        conversationID = SZFriendsAnswerConversation(db, request, known, identityKey, staticKey, attested, now, inner);
        if (!conversationID) return NO;
        return [db run:@"INSERT INTO id_request_answers (request_token, identity_pk, conversation_id, answered_at, "
                       @"attested) VALUES (?, ?, ?, ?, ?)"
                 binds:@[ requestToken, identityKey, conversationID, now, @(attested) ]
                   row:nil
                 error:inner] &&
               [db run:@"UPDATE id_requests SET answered_at = coalesce(answered_at, ?) WHERE request_token = ?"
                 binds:@[ now, requestToken ]
                   row:nil
                 error:inner];
    } error:error];
    return ok ? conversationID : nil;
}

- (nullable NSString *)conversationForIDRequestAnswerWithToken:(NSData *)requestToken
                                                   identityKey:(NSData *)identityKey
                                                     staticKey:(NSData *)staticKey
                                                        atDate:(NSDate *)now
                                                         error:(NSError **)error {
    return [self conversationForIDRequestAnswerWithToken:requestToken identityKey:identityKey staticKey:staticKey
                                                attested:NO unattestedLimit:SZFriendsIDRequestMaxAnswers atDate:now
                                                   error:error];
}

- (nullable NSString *)conversationForIDRequestAnswerWithToken:(NSData *)requestToken
                                                   identityKey:(NSData *)identityKey
                                                     staticKey:(NSData *)staticKey
                                                      attested:(BOOL)attested
                                                        atDate:(NSDate *)now
                                                         error:(NSError **)error {
    return [self conversationForIDRequestAnswerWithToken:requestToken identityKey:identityKey staticKey:staticKey
                                                attested:attested
                                         unattestedLimit:SZFriendsIDRequestMaxUnattestedAnswers
                                                  atDate:now
                                                   error:error];
}

@end

NS_ASSUME_NONNULL_END
