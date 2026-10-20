// People (table friends): reading, saving with the key rules, and the reviewed static-key change. The Add by ID
// requests this person sent are SZFriendsStoreAddByID.m.

#import "service/identity/SZFriendsIdentity.h"
#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

// The columns a save writes from the record. A save also writes request_since, which it works out itself; reads add
// that and the columns only other paths write (the reviewed key change, host attestations).
static NSString *const SZFriendsPersonColumns =
    @"conversation_id, identity_pk, static_pk, friends_id, name, picture_kind, picture_set, picture_index, "
    @"picture_path, picture_sha256, relation, verified, verified_at, comparison_code, auto_accept, "
    @"key_change_pending, presence_secret, callback_token, callback_secret, last_interaction_at, unread_count, "
    @"request_at, request_found_nearby";

// Unknown kinds and incomplete image rows read back as the placeholder rather than failing, so a row written by a
// newer helper still shows.
static SZFriendsPicture *SZFriendsPictureFromColumns(sqlite3_stmt *statement, int first) {
    int64_t kind = SZFriendsColumnInt(statement, first);
    if (kind == SZFriendsPictureKindAnimal) {
        return [SZFriendsPicture animalWithSet:(NSInteger)SZFriendsColumnInt(statement, first + 1)
                                         index:(NSInteger)SZFriendsColumnInt(statement, first + 2)];
    }
    NSString *path = SZFriendsColumnText(statement, first + 3);
    NSData *sha = SZFriendsColumnBlob(statement, first + 4);
    if (kind == SZFriendsPictureKindImage && path && sha) return [SZFriendsPicture imageAtPath:path sha256:sha];
    return [SZFriendsPicture placeholder];
}

static NSArray *SZFriendsPictureBinds(SZFriendsPicture *picture) {
    return @[
        @(picture.kind), @(picture.animalSet), @(picture.animalIndex), SZFriendsSQL(picture.imagePath),
        SZFriendsSQL(picture.imageSHA256)
    ];
}

static SZFriendsPersonRecord *SZFriendsPersonFromRow(sqlite3_stmt *s) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = SZFriendsColumnText(s, 0) ?: @"";
    person.identityKey = SZFriendsColumnBlob(s, 1);
    person.staticKey = SZFriendsColumnBlob(s, 2);
    person.friendsID = SZFriendsColumnText(s, 3);
    person.name = SZFriendsColumnText(s, 4);
    person.picture = SZFriendsPictureFromColumns(s, 5);
    person.relation = (SZFriendsRelation)SZFriendsColumnInt(s, 10);
    person.verified = SZFriendsColumnInt(s, 11) != 0;
    person.verifiedAt = SZFriendsColumnDate(s, 12);
    person.comparisonCode = SZFriendsColumnText(s, 13);
    person.autoAccept = SZFriendsColumnInt(s, 14) != 0;
    person.keyChangePending = SZFriendsColumnInt(s, 15) != 0;
    person.presenceSecret = SZFriendsColumnBlob(s, 16);
    person.callbackToken = SZFriendsColumnBlob(s, 17);
    person.callbackSecret = SZFriendsColumnBlob(s, 18);
    person.lastInteractionAt = SZFriendsColumnDate(s, 19) ?: [NSDate dateWithTimeIntervalSince1970:0];
    person.unreadCount = (NSInteger)SZFriendsColumnInt(s, 20);
    person.requestAt = SZFriendsColumnDate(s, 21);
    person.requestFoundNearby = SZFriendsColumnInt(s, 22) != 0;
    person.pendingStaticKey = SZFriendsColumnBlob(s, 23);
    person.pendingRequestSince = SZFriendsColumnDate(s, 24);
    // Only an attestation for the ID the person shows now confirms anything (see SZFriendsPersonReadColumns).
    person.friendsIDAttestation = SZFriendsColumnBlob(s, 25);
    person.friendsIDAttestationDay = person.friendsIDAttestation ? SZFriendsColumnText(s, 26) : nil;
    person.friendsIDConfirmed = person.friendsIDAttestation != nil && person.friendsIDAttestationDay != nil;
    person.unconfirmedAnswerID = SZFriendsColumnText(s, 27);
    person.leftListAt = SZFriendsColumnDate(s, 28);
    return person;
}

// After the saved columns: the pending key; when the waiting request began, only while one waits (rows a v2 helper
// made a request have no request_since, and count from when they were asked); the attestation with its day, only
// while it covers the Friends ID the row holds now, so changing the ID by any path, even an older helper's, voids it;
// an unconfirmed answer's ID, only while the row still waits as an incoming request; and when the person took them off
// the list, only while they are Removed or Blocked, so any other relation, even one an older helper wrote, voids it.
static NSString *const SZFriendsPersonReadColumns =
    @"pending_static_pk, CASE WHEN relation IN (0, 1) THEN coalesce(request_since, request_at, last_interaction_at) "
    @"END, CASE WHEN attested_friends_id = friends_id THEN id_attestation END, id_attestation_day, "
    @"CASE WHEN relation = 0 THEN unconfirmed_answer_id END, CASE WHEN relation IN (3, 4) THEN left_list_at END";

NSArray<SZFriendsPersonRecord *> *SZFriendsStorePeople(SZFriendsStoreDB *db, NSString *_Nullable whereClause,
                                                       NSArray *_Nullable binds) {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@, %@ FROM friends %@ ORDER BY "
                                               @"last_interaction_at DESC, conversation_id",
                                               SZFriendsPersonColumns, SZFriendsPersonReadColumns,
                                               whereClause ?: @""];
    NSMutableArray *people = [NSMutableArray array];
    NSError *error = nil;
    if (![db run:sql binds:binds row:^(sqlite3_stmt *s) { [people addObject:SZFriendsPersonFromRow(s)]; }
           error:&error]) {
        NSLog(@"Friends store: reading people failed: %@", error.localizedDescription);
    }
    return people;
}

// Only someone who is no longer a friend (Removed) or is blocked can be off the list: saving any other relation, such
// as a new request from either side, puts them back on it.
static BOOL SZFriendsMayBeOffTheList(SZFriendsRelation relation) {
    return relation == SZFriendsRelationRemoved || relation == SZFriendsRelationBlocked;
}

static BOOL SZFriendsHasLength(NSData *_Nullable data, NSUInteger length) { return !data || data.length == length; }

// When a request saved now would begin: when it was asked, but never later than now, so a date in the future cannot
// keep it from lapsing or hold the helper's IK window open. Nil for anyone who is not a request.
static NSDate *_Nullable SZFriendsRequestStart(SZFriendsPersonRecord *person) {
    if (person.relation != SZFriendsRelationIncomingRequest && person.relation != SZFriendsRelationOutgoingRequest) {
        return nil;
    }
    NSDate *now = [NSDate date];
    return person.requestAt && [person.requestAt compare:now] == NSOrderedAscending ? person.requestAt : now;
}

// A stored key may be set where none was, never replaced or cleared by a plain save.
static BOOL SZFriendsKeyKept(NSData *_Nullable stored, NSData *_Nullable saved) {
    return !stored || (saved && [stored isEqualToData:saved]);
}

BOOL SZFriendsStoreSavePerson(SZFriendsStoreDB *db, SZFriendsPersonRecord *person, NSError **error) {
    if (person.conversationID.length == 0) person.conversationID = SZFriendsNewIdentifier();
    if (!SZFriendsStoreIsValidIdentifier(person.conversationID)) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad conversation id"));
    }
    if (!SZFriendsHasLength(person.identityKey, 32) || !SZFriendsHasLength(person.staticKey, 32) ||
        !SZFriendsHasLength(person.presenceSecret, 32) || !SZFriendsHasLength(person.callbackToken, 16) ||
        !SZFriendsHasLength(person.callbackSecret, 32) || person.relation < SZFriendsRelationIncomingRequest ||
        person.relation > SZFriendsRelationBlocked) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad person fields"));
    }
    NSArray<SZFriendsPersonRecord *> *existing =
        SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ person.conversationID ]);
    SZFriendsPersonRecord *stored = existing.firstObject;
    // ADR 0001: identity keys never change, so a conversation never moves to another key; a different key is another
    // person with their own conversation. Re-binding here once let a second answer to an Add by ID take over the
    // first person's history and future messages (security review, "key change handling").
    if (!SZFriendsKeyKept(stored.identityKey, person.identityKey) ||
        !SZFriendsKeyKept(stored.staticKey, person.staticKey)) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorKeyChangeRefused,
                                                            @"a person's keys change only through review"));
    }
    BOOL autoAccept = person.autoAccept;
    if (person.relation == SZFriendsRelationBlocked || person.keyChangePending) autoAccept = NO;
    NSMutableArray *binds = [NSMutableArray arrayWithArray:@[
        person.conversationID, SZFriendsSQL(person.identityKey), SZFriendsSQL(person.staticKey),
        SZFriendsSQL(person.friendsID), SZFriendsSQL(person.name)
    ]];
    [binds addObjectsFromArray:SZFriendsPictureBinds(person.picture ?: [SZFriendsPicture placeholder])];
    [binds addObjectsFromArray:@[
        @(person.relation), @(person.verified), SZFriendsSQL(person.verifiedAt), SZFriendsSQL(person.comparisonCode),
        @(autoAccept),
        @(person.keyChangePending), SZFriendsSQL(person.presenceSecret), SZFriendsSQL(person.callbackToken),
        SZFriendsSQL(person.callbackSecret), person.lastInteractionAt ?: [NSDate date], @(MAX(person.unreadCount, 0)),
        SZFriendsSQL(person.requestAt), @(person.requestFoundNearby), SZFriendsSQL(SZFriendsRequestStart(person)),
        SZFriendsSQL(person.relation == SZFriendsRelationIncomingRequest ? person.unconfirmedAnswerID : nil),
        SZFriendsSQL(SZFriendsMayBeOffTheList(person.relation) ? person.leftListAt : nil)
    ]];
    // unread_count is not in the update list and the latest interaction only moves forward: a helper saving a copy
    // it read before a message arrived must not erase that message's unread mark or its place in the list.
    NSString *sql = [NSString stringWithFormat:
        @"INSERT INTO friends (%@, request_since, unconfirmed_answer_id, left_list_at) "
        @"VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
        @"ON CONFLICT(conversation_id) DO UPDATE SET identity_pk = excluded.identity_pk, "
        @"static_pk = excluded.static_pk, friends_id = excluded.friends_id, name = excluded.name, "
        @"picture_kind = excluded.picture_kind, picture_set = excluded.picture_set, "
        @"picture_index = excluded.picture_index, picture_path = excluded.picture_path, "
        @"picture_sha256 = excluded.picture_sha256, relation = excluded.relation, verified = excluded.verified, "
        @"verified_at = excluded.verified_at, comparison_code = excluded.comparison_code, "
        @"auto_accept = excluded.auto_accept, key_change_pending = excluded.key_change_pending, "
        @"pending_static_pk = CASE WHEN excluded.key_change_pending THEN friends.pending_static_pk END, "
        @"presence_secret = excluded.presence_secret, callback_token = excluded.callback_token, "
        @"callback_secret = excluded.callback_secret, "
        @"last_interaction_at = max(friends.last_interaction_at, excluded.last_interaction_at), "
        @"request_at = excluded.request_at, request_found_nearby = excluded.request_found_nearby, "
        @"unconfirmed_answer_id = excluded.unconfirmed_answer_id, left_list_at = excluded.left_list_at, "
        // A request keeps the moment it began while it waits in the same direction; anything else starts afresh.
        @"request_since = CASE WHEN excluded.relation NOT IN (0, 1) THEN NULL "
        @"WHEN friends.relation = excluded.relation AND friends.request_since IS NOT NULL THEN friends.request_since "
        @"ELSE excluded.request_since END",
        SZFriendsPersonColumns];
    return [db run:sql binds:binds row:nil error:error];
}

BOOL SZFriendsStoreNotePresentedStaticKey(SZFriendsStoreDB *db, NSString *conversationID, NSData *staticKey,
                                          NSData *certificate, NSError **error) {
    if (staticKey.length != 32 || certificate.length != 96) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad static key"));
    }
    SZFriendsPersonRecord *person = SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ conversationID ])
                                        .firstObject;
    if (!person) return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, conversationID));
    if (!person.identityKey) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"no identity key yet"));
    }
    // Checked here as well as in the session layer, so no caller can slip in a key the person's identity never
    // signed: only a certificate from this very identity key makes a static key theirs.
    NSData *certified = SZFriendsIdentityKeyFromCertificate(certificate, staticKey);
    if (!certified || ![certified isEqualToData:person.identityKey]) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorKeyChangeRefused,
                                                            @"the certificate names another identity"));
    }
    if (!person.staticKey) {
        return [db run:@"UPDATE friends SET static_pk = ? WHERE conversation_id = ?"
                 binds:@[ staticKey, conversationID ]
                   row:nil
                 error:error];
    }
    if ([person.staticKey isEqualToData:staticKey]) return YES;
    return [db run:@"UPDATE friends SET pending_static_pk = ?, key_change_pending = 1, auto_accept = 0 "
                   @"WHERE conversation_id = ?"
             binds:@[ staticKey, conversationID ]
               row:nil
             error:error];
}

BOOL SZFriendsStoreAcceptPendingStaticKey(SZFriendsStoreDB *db, NSString *conversationID, NSError **error) {
    SZFriendsPersonRecord *person = SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ conversationID ])
                                        .firstObject;
    if (!person) return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, conversationID));
    if (!person.pendingStaticKey) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorStale, @"no key change is pending"));
    }
    // Compared codes and files arriving unasked were trust in the old key's sessions; the person decides again.
    return [db run:@"UPDATE friends SET static_pk = pending_static_pk, pending_static_pk = NULL, "
                   @"key_change_pending = 0, verified = 0, verified_at = NULL, auto_accept = 0 "
                   @"WHERE conversation_id = ?"
             binds:@[ conversationID ]
               row:nil
             error:error];
}

NS_ASSUME_NONNULL_END
