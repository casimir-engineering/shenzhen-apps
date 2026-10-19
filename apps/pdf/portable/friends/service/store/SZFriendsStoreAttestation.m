// Host attestations of Friends IDs (schema v3): the host's signature over a Friends ID, an identity key and a day,
// which turns "someone answered my Add by ID" into "the holder of that ID answered" (wave-3 security re-check, Add by
// ID). The helper verifies signatures against the pinned host keys; the store keeps what was verified, bound to the
// ID it covers, so a later change of the ID voids it without anyone having to remember to clear it.

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSUInteger SZFriendsAttestationMaxLength = 1024;

// Shapes only; the signature is the helper's to check. A day is the host's calendar day, written as the host writes
// it (portable/server/friends/src/clock.js).
static BOOL SZFriendsAttestationShapeIsValid(NSString *friendsID, NSData *attestation, NSString *day) {
    NSUInteger idBytes = [friendsID lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (idBytes == 0 || idBytes > 64) return NO;
    if (attestation.length == 0 || attestation.length > SZFriendsAttestationMaxLength) return NO;
    if (day.length != 10) return NO;
    for (NSUInteger i = 0; i < 10; i++) {
        unichar c = [day characterAtIndex:i];
        BOOL dash = i == 4 || i == 7;
        if (dash ? c != '-' : (c < '0' || c > '9')) return NO;
    }
    return YES;
}

static NSError *SZFriendsAttestationInvalid(void) {
    return SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"malformed Friends ID attestation");
}

@implementation SZFriendsStore (Attestation)

- (BOOL)confirmFriendsID:(NSString *)friendsID
             attestation:(NSData *)attestation
                     day:(NSString *)day
         forConversation:(NSString *)conversationID
                   error:(NSError **)error {
    if (!SZFriendsAttestationShapeIsValid(friendsID, attestation, day)) {
        return SZFriendsFail(error, SZFriendsAttestationInvalid());
    }
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsPersonRecord *person =
            SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ conversationID ]).firstObject;
        if (!person) return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, conversationID));
        // An attestation binds an ID to an identity key; a row that has not met anyone yet has no key it could name.
        if (!person.identityKey) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"no identity key yet"));
        }
        // The host's word outranks what the person's PROFILE claimed, so the row shows the ID the host vouches for.
        return [db run:@"UPDATE friends SET friends_id = ?1, attested_friends_id = ?1, id_attestation = ?2, "
                       @"id_attestation_day = ?3 WHERE conversation_id = ?4"
                 binds:@[ friendsID, attestation, day, conversationID ]
                   row:nil
                 error:inner];
    } error:error];
}

- (BOOL)clearFriendsIDConfirmationForConversation:(NSString *)conversationID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (![db run:@"UPDATE friends SET attested_friends_id = NULL, id_attestation = NULL, id_attestation_day = NULL "
                     @"WHERE conversation_id = ?"
               binds:@[ conversationID ]
                 row:nil
               error:inner]) {
            return NO;
        }
        if (db.changes > 0) return YES;
        return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, conversationID));
    } error:error];
}

- (nullable id)ownAttestationColumn:(NSString *)column {
    __block id value = nil;
    // Only while it covers the ID this Mac has now: a rename leaves the old one in place, unreadable.
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM profile WHERE id = 1 AND attested_friends_id = "
                                               @"friends_id AND id_attestation IS NOT NULL",
                                               column];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) { value = [db scalar:sql binds:nil error:NULL]; }];
    return value;
}

- (nullable NSData *)friendsIDAttestation {
    id value = [self ownAttestationColumn:@"id_attestation"];
    return [value isKindOfClass:[NSData class]] ? value : nil;
}

- (nullable NSString *)friendsIDAttestationDay {
    id value = [self ownAttestationColumn:@"id_attestation_day"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (BOOL)saveFriendsIDAttestation:(NSData *)attestation
                             day:(NSString *)day
                    forFriendsID:(NSString *)friendsID
                           error:(NSError **)error {
    if (!SZFriendsAttestationShapeIsValid(friendsID, attestation, day)) {
        return SZFriendsFail(error, SZFriendsAttestationInvalid());
    }
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        // Checked in the same transaction as the write, so a rename committed meanwhile cannot slip between them.
        if (![db run:@"UPDATE profile SET attested_friends_id = ?1, id_attestation = ?2, id_attestation_day = ?3 "
                     @"WHERE id = 1 AND friends_id = ?1"
               binds:@[ friendsID, attestation, day ]
                 row:nil
               error:inner]) {
            return NO;
        }
        if (db.changes > 0) return YES;
        return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorStale,
                                                            @"the attestation is for another Friends ID"));
    } error:error];
}

@end

NS_ASSUME_NONNULL_END
